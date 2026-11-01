//! `xqlite serve DB --pg PORT --mysql PORT ...`: the wire protocol
//! servers on one database file (module xqlite_server). Each protocol
//! given a port listens on it, all at once; they run until SIGINT or
//! SIGTERM.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("xqlite_server");

const Io = std.Io;
const pg = server.pg;
const mysql = server.mysql;
const PgServer = server.Server(pg.Protocol);
const MysqlServer = server.Server(mysql.Protocol);

pub const usage =
    \\usage: xqlite serve DB [--pg PORT] [--mysql PORT] [options]
    \\
    \\Serve the database file DB (created if missing) to the clients of
    \\the wire protocols given a port (at least one), until SIGINT or
    \\SIGTERM.
    \\
    \\protocols:
    \\  --pg PORT               PostgreSQL's (v3), in the postgres dialect
    \\  --mysql PORT            MySQL's (MariaDB's clients too), in the
    \\                          mariadb dialect
    \\
    \\options:
    \\  --host ADDR             the address to listen on (default 127.0.0.1;
    \\                          0.0.0.0 for every interface)
    \\  --max-connections N     the most clients at a time, of each protocol
    \\                          (default 64)
    \\  --user NAME             the one user name accepted (default: any)
    \\  --password PW           the password of every user (else
    \\                          $XQLITE_PASSWORD; default: none, trust);
    \\                          MySQL checks it with mysql_native_password
    \\  --auth METHOD           PostgreSQL's: trust, password, md5 or
    \\                          scram-sha-256 (default: scram-sha-256 with a
    \\                          password, else trust); trust lets in MySQL's
    \\                          clients without a password too
    \\  --database NAME         PostgreSQL's: the one database name accepted
    \\                          (default: any)
    \\
;

const Options = struct {
    path: []const u8,
    host: []const u8 = "127.0.0.1",
    max_connections: u32 = 64,
    /// The port of each protocol; null: not served.
    pg_port: ?u16 = null,
    mysql_port: ?u16 = null,
    auth: pg.auth.Config = .{},
    database: ?[]const u8 = null,
};

/// The options, or a message for the user (static or in `buf`).
fn parse(args: []const []const u8, buf: []u8) union(enum) { ok: Options, bad: []const u8, help } {
    var o: Options = .{ .path = "" };
    var method: ?pg.auth.Method = null;
    var password: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
        if (!std.mem.startsWith(u8, a, "-")) {
            if (o.path.len > 0) return .{ .bad = std.fmt.bufPrint(buf, "more than one database file: {s}", .{a}) catch "more than one database file" };
            o.path = a;
            continue;
        }
        const flags = [_][]const u8{ "--pg", "--mysql", "--host", "--max-connections", "--user", "--password", "--auth", "--database" };
        const known = for (flags) |f| {
            if (std.mem.eql(u8, a, f)) break true;
        } else false;
        if (!known) return .{ .bad = std.fmt.bufPrint(buf, "unknown option {s}", .{a}) catch "unknown option" };
        if (i + 1 >= args.len) return .{ .bad = std.fmt.bufPrint(buf, "{s} needs a value", .{a}) catch "an option needs a value" };
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--pg") or std.mem.eql(u8, a, "--mysql")) {
            const port = std.fmt.parseInt(u16, v, 10) catch return .{ .bad = std.fmt.bufPrint(buf, "bad port: {s}", .{v}) catch "bad port" };
            if (a[2] == 'p') o.pg_port = port else o.mysql_port = port;
        } else if (std.mem.eql(u8, a, "--host")) {
            o.host = v;
        } else if (std.mem.eql(u8, a, "--max-connections")) {
            o.max_connections = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = "bad --max-connections" };
            if (o.max_connections == 0) return .{ .bad = "bad --max-connections" };
        } else if (std.mem.eql(u8, a, "--user")) {
            o.auth.user = v;
        } else if (std.mem.eql(u8, a, "--password")) {
            password = v;
        } else if (std.mem.eql(u8, a, "--auth")) {
            method = std.meta.stringToEnum(pg.auth.Method, v) orelse return .{ .bad = std.fmt.bufPrint(buf, "unknown --auth method {s} (trust, password, md5, scram-sha-256)", .{v}) catch "unknown --auth method" };
        } else if (std.mem.eql(u8, a, "--database")) {
            o.database = v;
        }
    }
    if (o.path.len == 0) return .{ .bad = "no database file" };
    if (o.pg_port == null and o.mysql_port == null) return .{ .bad = "no protocol to serve (--pg PORT, --mysql PORT)" };
    if (o.pg_port != null and o.pg_port == o.mysql_port and o.pg_port != 0) return .{ .bad = "--pg and --mysql on the same port" };
    if (password == null) if (std.c.getenv("XQLITE_PASSWORD")) |z| {
        password = std.mem.span(z);
    };
    o.auth.method = method orelse if (password != null) .@"scram-sha-256" else .trust;
    if (o.auth.method != .trust) {
        o.auth.password = password orelse return .{ .bad = "--auth needs a password (--password or $XQLITE_PASSWORD)" };
    }
    return .{ .ok = o };
}

/// The servers of the protocols given a port, listening once listen()
/// returned (not accepting until run with io.concurrent()). Not moved
/// after listen(): the servers point at the protocols.
const Listeners = struct {
    pg_protocol: pg.Protocol = undefined,
    mysql_protocol: mysql.Protocol = .{},
    pg: ?PgServer = null,
    mysql: ?MysqlServer = null,

    /// Listen on the ports of `o` (port 0: a free one). False if one
    /// cannot, the reason written to `err`.
    fn listen(l: *Listeners, io: Io, gpa: std.mem.Allocator, o: Options, err: *Io.Writer) !bool {
        const config: server.Config = .{
            .address = undefined,
            .path = o.path,
            .max_connections = o.max_connections,
        };
        if (o.pg_port) |port| {
            l.pg_protocol = .init(io, .{ .auth = o.auth, .database = o.database });
            var c = config;
            c.address = try address(o.host, port, err) orelse return false;
            l.pg = PgServer.init(io, gpa, &l.pg_protocol, c) catch |e| return cannotListen(o.host, port, e, err);
        }
        if (o.mysql_port) |port| {
            // One user and password for both protocols; PostgreSQL's
            // trust lets in any MySQL client too.
            l.mysql_protocol = .{
                .user = o.auth.user,
                .password = if (o.auth.method == .trust) null else o.auth.password,
            };
            var c = config;
            c.address = try address(o.host, port, err) orelse return false;
            l.mysql = MysqlServer.init(io, gpa, &l.mysql_protocol, c) catch |e| return cannotListen(o.host, port, e, err);
        }
        return true;
    }

    /// After the servers' run() returned (or before it started).
    fn deinit(l: *Listeners, gpa: std.mem.Allocator) void {
        if (l.pg) |*s| s.deinit();
        if (l.mysql) |*s| s.deinit();
        l.mysql_protocol.deinit(gpa);
        l.* = undefined;
    }

    fn address(host: []const u8, port: u16, err: *Io.Writer) !?std.Io.net.IpAddress {
        return std.Io.net.IpAddress.parse(host, port) catch {
            try err.print("xqlite serve: bad --host {s}\n", .{host});
            return null;
        };
    }

    fn cannotListen(host: []const u8, port: u16, e: anyerror, err: *Io.Writer) !bool {
        try err.print("xqlite serve: cannot listen on {s}:{d}: {t}\n", .{ host, port, e });
        return false;
    }
};

/// Run the servers; the exit code.
pub fn run(gpa: std.mem.Allocator, io: Io, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    var msg_buf: [256]u8 = undefined;
    const o = switch (parse(args, &msg_buf)) {
        .ok => |o| o,
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .bad => |m| {
            try err.print("xqlite serve: {s}\n{s}", .{ m, usage });
            try err.flush();
            return 2;
        },
    };
    // A protocol's sessions are in its dialect: without it in the build,
    // the protocol is not served (rather than in another dialect).
    if (o.pg_port != null and !xqlite.Dialect.postgres.built()) {
        try err.writeAll("xqlite serve: --pg needs the postgres dialect, which this build leaves out (-Ddialects)\n");
        try err.flush();
        return 1;
    }
    if (o.mysql_port != null and !xqlite.Dialect.mariadb.built()) {
        try err.writeAll("xqlite serve: --mysql needs the mariadb dialect, which this build leaves out (-Ddialects)\n");
        try err.flush();
        return 1;
    }
    // The database opens (and is made) now, so that a bad path fails here
    // rather than at the first client.
    {
        const config: server.Config = .{ .address = undefined, .path = o.path };
        var db = xqlite.Db.open(gpa, io, o.path, config.open) catch |e| {
            try err.print("xqlite serve: cannot open {s}: {t}\n", .{ o.path, e });
            try err.flush();
            return 1;
        };
        db.close();
    }

    // SIGINT and SIGTERM are waited for below (sigwait()), blocked before
    // any thread starts so that every thread inherits the mask.
    var signals = std.posix.sigemptyset();
    std.posix.sigaddset(&signals, .INT);
    std.posix.sigaddset(&signals, .TERM);
    std.posix.sigprocmask(std.c.SIG.BLOCK, &signals, null);

    var l: Listeners = .{};
    defer l.deinit(gpa);
    if (!try l.listen(io, gpa, o, err)) {
        try err.flush();
        return 1;
    }
    var pg_running = if (l.pg) |*s| try io.concurrent(PgServer.run, .{s}) else null;
    defer if (pg_running) |*f| f.cancel(io) catch {};
    if (l.pg) |*s| try err.print("xqlite serve: listening on {f} (postgres, auth {t}) for {s}\n", .{ s.address(), o.auth.method, o.path });
    var mysql_running = if (l.mysql) |*s| try io.concurrent(MysqlServer.run, .{s}) else null;
    defer if (mysql_running) |*f| f.cancel(io) catch {};
    if (l.mysql) |*s| try err.print("xqlite serve: listening on {f} (mysql, {s}) for {s}\n", .{
        s.address(),
        if (l.mysql_protocol.password != null) "mysql_native_password" else "no password",
        o.path,
    });
    try err.flush();

    var sig: c_int = 0;
    _ = std.c.sigwait(&signals, &sig);
    try err.print("xqlite serve: stopping (signal {d})\n", .{sig});
    try err.flush();
    return 0;
}

test parse {
    var buf: [256]u8 = undefined;
    const t = std.testing;
    const r = parse(&.{ "app.db", "--pg", "5432", "--host", "0.0.0.0", "--password", "pw" }, &buf);
    try t.expectEqual(@as(?u16, 5432), r.ok.pg_port);
    try t.expectEqual(@as(?u16, null), r.ok.mysql_port);
    try t.expectEqualStrings("app.db", r.ok.path);
    try t.expectEqual(pg.auth.Method.@"scram-sha-256", r.ok.auth.method);
    try t.expectEqualStrings("unknown option --pq", parse(&.{ "app.db", "--pq", "1" }, &buf).bad);
    try t.expectEqualStrings("no database file", parse(&.{ "--pg", "1" }, &buf).bad);
    try t.expectEqualStrings("--pg needs a value", parse(&.{ "x.db", "--pg" }, &buf).bad);
    try t.expectEqual(pg.auth.Method.md5, parse(&.{ "x.db", "--pg", "1", "--auth", "md5", "--password", "p" }, &buf).ok.auth.method);
    const m = parse(&.{ "x.db", "--mysql", "3306" }, &buf).ok;
    try t.expectEqual(@as(?u16, 3306), m.mysql_port);
    try t.expectEqual(@as(?u16, null), m.pg_port);
    try t.expectEqualStrings("no protocol to serve (--pg PORT, --mysql PORT)", parse(&.{"x.db"}, &buf).bad);
    try t.expectEqualStrings("--pg and --mysql on the same port", parse(&.{ "x.db", "--pg", "1", "--mysql", "1" }, &buf).bad);
}

test "both protocols listen and greet their clients" {
    if (!xqlite.Dialect.postgres.built() or !xqlite.Dialect.mariadb.built()) return error.SkipZigTest;
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/both.db", .{tmp.sub_path});
    var discard: Io.Writer.Discarding = .init(&.{});
    var l: Listeners = .{};
    defer l.deinit(t.allocator);
    try t.expect(try l.listen(io, t.allocator, .{ .path = path, .pg_port = 0, .mysql_port = 0 }, &discard.writer));
    var pg_running = try io.concurrent(PgServer.run, .{&l.pg.?});
    defer pg_running.cancel(io) catch {};
    var mysql_running = try io.concurrent(MysqlServer.run, .{&l.mysql.?});
    defer mysql_running.cancel(io) catch {};

    // PostgreSQL: an SSLRequest is answered 'N'.
    {
        const s = try l.pg.?.address().connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [64]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.writeAll(&.{ 0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f });
        try w.interface.flush();
        var rbuf: [64]u8 = undefined;
        var r = s.reader(io, &rbuf);
        try t.expectEqual(@as(u8, 'N'), try r.interface.takeByte());
    }
    // MySQL: the server speaks first, a handshake of protocol 10.
    {
        const s = try l.mysql.?.address().connect(io, .{ .mode = .stream });
        defer s.close(io);
        var rbuf: [256]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const head = try r.interface.takeArray(5);
        try t.expectEqual(@as(u8, 10), head[4]);
    }
}
