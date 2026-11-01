//! The MySQL/MariaDB client/server protocol, for Server(Protocol): the
//! state the connections share (the accepted user and password, the
//! connections by id for KILL), and serve().
//!
//!     var proto: mysql.Protocol = .{ .user = "app", .password = "secret" };
//!     defer proto.deinit(gpa);
//!     var srv = try server.Server(mysql.Protocol).init(io, gpa, &proto, .{
//!         .address = try .parse("0.0.0.0", 3306),
//!         .path = "app.db",
//!     });
//!     defer srv.deinit();
//!     try srv.run(); // until canceled
//!
//! Sessions are in the MariaDB dialect (the SQLite dialect in a build
//! without it, `-Ddialects=`). See docs/server.md, "MySQL 프로토콜".

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const Handler = @import("Handler.zig");

const Protocol = @This();

/// The user a client must log in as; null accepts any.
user: ?[]const u8 = null,
/// The password (mysql_native_password); null accepts any client
/// without checking what it sends.
password: ?[]const u8 = null,
/// The dialect of the sessions.
dialect: xqlite.Dialect = default_dialect,
/// The version the handshake announces. MariaDB's clients look for
/// "MariaDB" in it.
version: []const u8 = default_version,

/// The connections, by id (the session's Registry ticket), for KILL.
mutex: std.Io.Mutex = .init,
clients: std.AutoHashMapUnmanaged(u32, *Handler) = .empty,
/// When the first client came (COM_STATISTICS's uptime), in ms of the
/// awake clock.
started: std.atomic.Value(i64) = .init(0),
/// The commands received (COM_STATISTICS's questions).
questions: std.atomic.Value(u64) = .init(0),

pub const default_dialect: xqlite.Dialect = if (xqlite.Dialect.mariadb.built()) .mariadb else .sqlite;

/// MariaDB 11.8, which the dialect follows (`SELECT VERSION()` says
/// the same).
pub const default_version = "11.8.0-MariaDB-xqlite";

pub fn deinit(p: *Protocol, gpa: std.mem.Allocator) void {
    p.clients.deinit(gpa);
    p.* = undefined;
}

/// Speak the protocol to one client (Server(Protocol)).
pub fn serve(p: *Protocol, c: *server.Connection) !void {
    const now = std.Io.Timestamp.now(c.io, .awake).toMilliseconds();
    _ = p.started.cmpxchgStrong(0, now, .monotonic, .monotonic);
    var h: Handler = .init(p, c);
    defer h.deinit();
    try h.run();
}

/// Register a connection under its id.
pub fn add(p: *Protocol, io: std.Io, gpa: std.mem.Allocator, h: *Handler) !void {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    try p.clients.put(gpa, h.id, h);
}

pub fn remove(p: *Protocol, io: std.Io, id: u32) void {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    _ = p.clients.remove(id);
}

pub const KillResult = enum { killed, unknown };

/// KILL [QUERY] `id` from connection `from`: stop the statement of that
/// connection (Registry.cancel()) and, unless `query_only`, end the
/// connection (its socket is shut down, which ends its next read).
pub fn kill(p: *Protocol, from: *server.Connection, id: u32, query_only: bool) KillResult {
    p.mutex.lockUncancelable(from.io);
    defer p.mutex.unlock(from.io);
    // Under the lock: the connection stays until it removes itself.
    const target = p.clients.get(id) orelse return .unknown;
    if (!query_only) target.killed.store(true, .release);
    _ = from.registry.cancel(id, null);
    if (!query_only) target.conn.stream.shutdown(from.io, .both) catch {};
    return .killed;
}

/// How many connections there are.
pub fn count(p: *Protocol, io: std.Io) usize {
    p.mutex.lockUncancelable(io);
    defer p.mutex.unlock(io);
    return p.clients.count();
}
