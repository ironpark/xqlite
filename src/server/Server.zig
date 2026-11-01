//! A TCP server for one wire protocol: it accepts clients and runs each
//! on a task of its own, with a Session on the server's database.
//!
//! `Protocol` is the protocol's state, shared by its connections, with
//!
//!     pub fn serve(p: *Protocol, conn: *Connection) !void
//!
//! which speaks the protocol to one client until it leaves: the
//! handshake, Connection.openSession() in the client's dialect, then the
//! client's requests. The server closes the session and the socket when
//! serve() returns; an error it returns ends the connection, and is
//! logged.
//!
//! run() accepts until it is canceled (the caller runs it with
//! `io.concurrent()` and cancels the future), which cancels the
//! connections too. The tasks are those of the `Io` (a thread each with
//! `std.Io.Threaded`); a session's statements run on its task, so a slow
//! query holds only its own client.

const std = @import("std");
const xqlite = @import("xqlite");
const Session = @import("Session.zig");
const Registry = @import("Registry.zig");

const net = std.Io.net;
const log = std.log.scoped(.xqlite_server);

pub const Config = struct {
    address: net.IpAddress,
    /// The database file the sessions open. Each session opens it on its
    /// own (":memory:" would give each client a database of its own).
    path: []const u8,
    /// How the sessions open it; the dialect is the protocol's
    /// (Connection.openSession()). WAL lets readers run while one
    /// session writes, and the busy timeout makes a writer wait for
    /// another rather than fail at once.
    open: xqlite.OpenOptions = .{ .journal_mode = .wal, .busy_timeout_ms = 5000 },
    max_connections: u32 = 64,
};

/// What a protocol chooses of its sessions.
pub const SessionOptions = struct {
    dialect: xqlite.Dialect,
    abort_failed_transactions: bool = false,
};

/// One client.
pub const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *const Config,
    registry: *Registry,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    /// The session, once openSession() made it, and its ticket.
    session: ?struct { s: Session, ticket: Registry.Ticket } = null,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,

    /// The bytes from the client.
    pub fn in(c: *Connection) *std.Io.Reader {
        return &c.reader.interface;
    }

    /// The bytes to the client (flush to send them).
    pub fn out(c: *Connection) *std.Io.Writer {
        return &c.writer.interface;
    }

    /// Open the session of this client on the server's database, and
    /// register it (`ticket`). error.TooManySessions past the server's
    /// max_connections; the engine's errors when the database cannot be
    /// opened.
    pub fn openSession(c: *Connection, options: SessionOptions) !*Session {
        std.debug.assert(c.session == null);
        var open = c.config.open;
        open.dialect = options.dialect;
        c.session = .{ .s = try Session.open(c.gpa, c.io, c.config.path, .{
            .open = open,
            .abort_failed_transactions = options.abort_failed_transactions,
        }), .ticket = undefined };
        const held = &c.session.?;
        errdefer {
            held.s.close();
            c.session = null;
        }
        held.ticket = try c.registry.add(&held.s);
        return &held.s;
    }

    /// The ticket of the session (openSession() made it).
    pub fn ticket(c: *const Connection) Registry.Ticket {
        return c.session.?.ticket;
    }

    fn close(c: *Connection) void {
        if (c.session) |*held| {
            c.registry.remove(held.ticket.id);
            held.s.close();
            c.session = null;
        }
        c.stream.close(c.io);
    }
};

pub fn Server(comptime Protocol: type) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        config: Config,
        protocol: *Protocol,
        registry: Registry,
        listener: net.Server,
        connections: std.Io.Group = .init,

        const Self = @This();

        /// Listen on `config.address` (port 0 picks a free one: see
        /// address()).
        pub fn init(io: std.Io, gpa: std.mem.Allocator, protocol: *Protocol, config: Config) !Self {
            return .{
                .io = io,
                .gpa = gpa,
                .config = config,
                .protocol = protocol,
                .registry = .init(io, gpa, config.max_connections),
                .listener = try config.address.listen(io, .{}),
            };
        }

        /// Call after run() returned.
        pub fn deinit(s: *Self) void {
            s.listener.deinit(s.io);
            s.registry.deinit();
            s.* = undefined;
        }

        /// The address listened on, with its port.
        pub fn address(s: *const Self) net.IpAddress {
            return s.listener.socket.address;
        }

        /// Accept clients until canceled; then cancel the connections and
        /// wait for them.
        pub fn run(s: *Self) std.Io.Cancelable!void {
            defer s.connections.cancel(s.io);
            while (true) {
                const stream = s.listener.accept(s.io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        log.warn("accept: {t}", .{err});
                        // Out of descriptors and the like: wait for a
                        // connection to end.
                        try s.io.sleep(.fromMilliseconds(10), .awake);
                        continue;
                    },
                };
                s.connections.concurrent(s.io, serveOne, .{ s, stream }) catch |err| {
                    log.warn("no task for a connection: {t}", .{err});
                    stream.close(s.io);
                };
            }
        }

        fn serveOne(s: *Self, stream: net.Stream) void {
            var c: Connection = .{
                .io = s.io,
                .gpa = s.gpa,
                .config = &s.config,
                .registry = &s.registry,
                .stream = stream,
                .reader = undefined,
                .writer = undefined,
            };
            c.reader = stream.reader(s.io, &c.read_buf);
            c.writer = stream.writer(s.io, &c.write_buf);
            defer c.close();
            s.protocol.serve(&c) catch |err| switch (@as(anyerror, err)) {
                // The client left, or the server stops: nothing to tell.
                error.EndOfStream, error.ReadFailed, error.WriteFailed, error.Canceled => {},
                else => log.info("connection {d}: {t}", .{ if (c.session) |h| h.ticket.id else 0, err }),
            };
        }
    };
}
