//! The PostgreSQL protocol over loopback TCP, with a minimal client of
//! the test's own: the startup and the password exchanges, simple and
//! extended queries, a cancel request. Each answer is written as text, a
//! line a message, up to ReadyForQuery.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const pg = @import("root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const b64 = std.base64.standard;

const Server = server.Server(pg.Protocol);

/// A server on a database of its own, on a free port.
const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [256]u8 = undefined,
    protocol: pg.Protocol,
    srv: Server,
    running: std.Io.Future(std.Io.Cancelable!void),

    fn start(f: *Fixture, config: pg.Config) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        const path = try std.fmt.bufPrint(&f.path_buf, ".zig-cache/tmp/{s}/pg.db", .{f.tmp.sub_path});
        f.protocol = .init(io, config);
        f.srv = try Server.init(io, gpa, &f.protocol, .{
            .address = try .parse("127.0.0.1", 0),
            .path = path,
            .max_connections = 4,
        });
        f.running = try io.concurrent(Server.run, .{&f.srv});
    }

    fn stop(f: *Fixture) void {
        f.running.cancel(io) catch {};
        f.srv.deinit();
        f.tmp.cleanup();
    }
};

const Client = struct {
    stream: std.Io.net.Stream = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    rbuf: [8192]u8 = undefined,
    wbuf: [8192]u8 = undefined,
    msg: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    log: std.ArrayList(u8) = .empty,
    pid: u32 = 0,
    key: u32 = 0,
    server_version: [32]u8 = undefined,
    server_version_len: usize = 0,

    fn deinit(c: *Client) void {
        c.msg.deinit(gpa);
        c.body.deinit(gpa);
        c.log.deinit(gpa);
    }

    fn open(c: *Client, addr: std.Io.net.IpAddress) !void {
        c.stream = try addr.connect(io, .{ .mode = .stream });
        c.reader = c.stream.reader(io, &c.rbuf);
        c.writer = c.stream.writer(io, &c.wbuf);
    }

    fn close(c: *Client) void {
        c.stream.close(io);
    }

    /// Connect as `user` with `password`, through to ReadyForQuery; the
    /// error message if the server refused.
    fn connect(c: *Client, addr: std.Io.net.IpAddress, user: []const u8, password: []const u8) !?[]const u8 {
        try c.open(addr);
        // SSL first, refused.
        try c.writer.interface.writeInt(u32, 8, .big);
        try c.writer.interface.writeInt(u32, 80877103, .big);
        try c.writer.interface.flush();
        try testing.expectEqual(@as(u8, 'N'), try c.reader.interface.takeByte());

        c.msg.clearRetainingCapacity();
        try c.int(u32, 196608);
        for ([_][]const u8{ "user", user, "database", "x", "application_name", "pgtest" }) |s| try c.str(s);
        try c.msg.append(gpa, 0);
        try c.writer.interface.writeInt(u32, @intCast(c.msg.items.len + 4), .big);
        try c.writer.interface.writeAll(c.msg.items);
        try c.writer.interface.flush();

        var client_first_bare: [64]u8 = undefined;
        var bare_len: usize = 0;
        var want_sig: [32]u8 = undefined;
        while (true) {
            const t = try c.recv();
            var body = c.body.items;
            switch (t) {
                'R' => {
                    const code = std.mem.readInt(u32, body[0..4], .big);
                    body = body[4..];
                    switch (code) {
                        0 => {},
                        3 => {
                            c.msg.clearRetainingCapacity();
                            try c.str(password);
                            try c.send('p');
                        },
                        5 => {
                            const r = pg.auth.md5Response(user, password, body[0..4].*);
                            c.msg.clearRetainingCapacity();
                            try c.str(&r);
                            try c.send('p');
                        },
                        10 => {
                            try testing.expectEqualStrings("SCRAM-SHA-256\x00\x00", body);
                            const bare = try std.fmt.bufPrint(&client_first_bare, "n=,r=clientnonce{d}", .{c.pid});
                            bare_len = bare.len;
                            c.msg.clearRetainingCapacity();
                            try c.str("SCRAM-SHA-256");
                            try c.int(i32, @intCast(3 + bare.len));
                            try c.msg.appendSlice(gpa, "n,,");
                            try c.msg.appendSlice(gpa, bare);
                            try c.send('p');
                        },
                        11 => {
                            var buf: [256]u8 = undefined;
                            const final, want_sig = try pg.auth.clientFinal(&buf, password, client_first_bare[0..bare_len], body, "n,,");
                            c.msg.clearRetainingCapacity();
                            try c.msg.appendSlice(gpa, final);
                            try c.send('p');
                        },
                        12 => {
                            var enc: [44]u8 = undefined;
                            try testing.expectEqualStrings(b64.Encoder.encode(&enc, &want_sig), body[2..]);
                        },
                        else => return error.UnexpectedAuth,
                    }
                },
                'S' => {
                    const name = std.mem.sliceTo(body, 0);
                    const value = std.mem.sliceTo(body[name.len + 1 ..], 0);
                    if (std.mem.eql(u8, name, "server_version")) {
                        @memcpy(c.server_version[0..value.len], value);
                        c.server_version_len = value.len;
                    }
                },
                'K' => {
                    c.pid = std.mem.readInt(u32, body[0..4], .big);
                    c.key = std.mem.readInt(u32, body[4..8], .big);
                },
                'Z' => return null,
                'E' => {
                    c.log.clearRetainingCapacity();
                    try c.describeError(body);
                    return c.log.items;
                },
                else => return error.UnexpectedMessage,
            }
        }
    }

    fn int(c: *Client, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try c.msg.appendSlice(gpa, &b);
    }

    fn str(c: *Client, s: []const u8) !void {
        try c.msg.appendSlice(gpa, s);
        try c.msg.append(gpa, 0);
    }

    /// Send c.msg as a message of type `t` (buffered until sync()/query()).
    fn send(c: *Client, t: u8) !void {
        try c.writer.interface.writeByte(t);
        try c.writer.interface.writeInt(u32, @intCast(c.msg.items.len + 4), .big);
        try c.writer.interface.writeAll(c.msg.items);
        try c.writer.interface.flush();
    }

    fn recv(c: *Client) !u8 {
        const t = try c.reader.interface.takeByte();
        const len = try c.reader.interface.takeInt(u32, .big);
        try c.body.resize(gpa, len - 4);
        try c.reader.interface.readSliceAll(c.body.items);
        return t;
    }

    /// The messages up to ReadyForQuery, a line each.
    fn answer(c: *Client) ![]const u8 {
        c.log.clearRetainingCapacity();
        while (true) {
            const t = try c.recv();
            const body = c.body.items;
            switch (t) {
                'T' => {
                    try c.log.append(gpa, 'T');
                    var rest = body[2..];
                    for (0..std.mem.readInt(u16, body[0..2], .big)) |_| {
                        const name = std.mem.sliceTo(rest, 0);
                        rest = rest[name.len + 1 ..];
                        const oid = std.mem.readInt(u32, rest[6..10], .big);
                        const typmod = std.mem.readInt(i32, rest[12..16], .big);
                        const format = std.mem.readInt(u16, rest[16..18], .big);
                        try c.log.print(gpa, " {s}:{d}", .{ name, oid });
                        if (typmod != -1) try c.log.print(gpa, "({d})", .{typmod});
                        if (format == 1) try c.log.appendSlice(gpa, "b");
                        rest = rest[18..];
                    }
                },
                'D' => {
                    try c.log.append(gpa, 'D');
                    var rest = body[2..];
                    for (0..std.mem.readInt(u16, body[0..2], .big)) |_| {
                        const len = std.mem.readInt(i32, rest[0..4], .big);
                        rest = rest[4..];
                        if (len < 0) {
                            try c.log.appendSlice(gpa, " NULL");
                            continue;
                        }
                        const v = rest[0..@intCast(len)];
                        rest = rest[@intCast(len)..];
                        const printable = for (v) |ch| {
                            if (ch < 0x20 or ch > 0x7e) break false;
                        } else true;
                        if (printable) try c.log.print(gpa, " {s}", .{v}) else try c.log.print(gpa, " 0x{x}", .{v});
                    }
                },
                'C' => try c.log.print(gpa, "C {s}", .{std.mem.sliceTo(body, 0)}),
                'E', 'N' => {
                    try c.log.append(gpa, t);
                    try c.describeError(body);
                },
                't' => {
                    try c.log.append(gpa, 't');
                    for (0..std.mem.readInt(u16, body[0..2], .big)) |i| try c.log.print(gpa, " {d}", .{std.mem.readInt(u32, body[2 + 4 * i ..][0..4], .big)});
                },
                'Z' => {
                    try c.log.print(gpa, "Z {c}\n", .{body[0]});
                    return c.log.items;
                },
                '1', '2', '3', 'n', 's', 'I' => try c.log.append(gpa, t),
                else => try c.log.print(gpa, "? {c}", .{t}),
            }
            try c.log.append(gpa, '\n');
        }
    }

    /// " CODE message [@position]" of an ErrorResponse or NoticeResponse.
    fn describeError(c: *Client, body: []const u8) !void {
        var rest = body;
        var code: []const u8 = "";
        var msg: []const u8 = "";
        var pos: []const u8 = "";
        var severity: []const u8 = "";
        while (rest.len > 0 and rest[0] != 0) {
            const k = rest[0];
            const v = std.mem.sliceTo(rest[1..], 0);
            rest = rest[v.len + 2 ..];
            switch (k) {
                'C' => code = v,
                'M' => msg = v,
                'P' => pos = v,
                'V' => severity = v,
                else => {},
            }
        }
        if (!std.mem.eql(u8, severity, "ERROR")) try c.log.print(gpa, " {s}", .{severity});
        try c.log.print(gpa, " {s} {s}", .{ code, msg });
        if (pos.len > 0) try c.log.print(gpa, " @{s}", .{pos});
    }

    fn query(c: *Client, sql: []const u8) ![]const u8 {
        c.msg.clearRetainingCapacity();
        try c.str(sql);
        try c.send('Q');
        return c.answer();
    }

    fn parse(c: *Client, name: []const u8, sql: []const u8, oids: []const u32) !void {
        c.msg.clearRetainingCapacity();
        try c.str(name);
        try c.str(sql);
        try c.int(u16, @intCast(oids.len));
        for (oids) |o| try c.int(u32, o);
        try c.send('P');
    }

    const Param = union(enum) { null, text: []const u8, binary: []const u8 };

    fn bind(c: *Client, portal: []const u8, stmt: []const u8, params: []const Param, result_formats: []const u16) !void {
        c.msg.clearRetainingCapacity();
        try c.str(portal);
        try c.str(stmt);
        try c.int(u16, @intCast(params.len));
        for (params) |p| try c.int(u16, @intFromBool(p == .binary));
        try c.int(u16, @intCast(params.len));
        for (params) |p| switch (p) {
            .null => try c.int(i32, -1),
            .text, .binary => |v| {
                try c.int(i32, @intCast(v.len));
                try c.msg.appendSlice(gpa, v);
            },
        };
        try c.int(u16, @intCast(result_formats.len));
        for (result_formats) |f| try c.int(u16, f);
        try c.send('B');
    }

    fn describe(c: *Client, kind: u8, name: []const u8) !void {
        c.msg.clearRetainingCapacity();
        try c.msg.append(gpa, kind);
        try c.str(name);
        try c.send('D');
    }

    fn execute(c: *Client, portal: []const u8, max_rows: u32) !void {
        c.msg.clearRetainingCapacity();
        try c.str(portal);
        try c.int(u32, max_rows);
        try c.send('E');
    }

    fn closeStatement(c: *Client, kind: u8, name: []const u8) !void {
        c.msg.clearRetainingCapacity();
        try c.msg.append(gpa, kind);
        try c.str(name);
        try c.send('C');
    }

    fn sync(c: *Client) ![]const u8 {
        c.msg.clearRetainingCapacity();
        try c.send('S');
        return c.answer();
    }

    fn terminate(c: *Client) !void {
        c.msg.clearRetainingCapacity();
        try c.send('X');
    }
};

test "pg: startup, simple queries, errors, transactions" {
    if (!xqlite.Dialect.postgres.built()) return;
    var f: Fixture = undefined;
    try f.start(.{});
    defer f.stop();
    var c: Client = .{};
    defer c.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try c.connect(f.srv.address(), "alice", ""));
    defer c.close();
    try testing.expectEqualStrings("17.0 (xqlite)", c.server_version[0..c.server_version_len]);
    try testing.expect(c.pid != 0);

    try testing.expectEqualStrings(
        \\C CREATE TABLE
        \\C INSERT 0 3
        \\T id:23 name:1043(14) price:1700(655366) ok:16 data:17 f:701
        \\D 1 apple 1.50 t \x0102 0.1
        \\D 2 pear NULL f NULL 100
        \\D 3 it's 2.00 NULL NULL NULL
        \\C SELECT 3
        \\C UPDATE 1
        \\Z I
        \\
    , try c.query(
        \\CREATE TABLE fruit (id int PRIMARY KEY, name varchar(10), price numeric(10,2), ok boolean, data bytea, f float8);
        \\INSERT INTO fruit VALUES (1, 'apple', 1.5, true, '\x0102'::bytea, 0.1), (2, 'pear', NULL, false, NULL, 100), (3, 'it''s', 2, NULL, NULL, NULL);
        \\SELECT * FROM fruit ORDER BY id;
        \\UPDATE fruit SET price = 1 WHERE id = 2
    ));
    // Expressions; an empty query; an error and its position (from 1, in
    // characters); the statements after it do not run.
    try testing.expectEqualStrings(
        \\T ?column?:23 b:16 t:25
        \\D 2 t x
        \\C SELECT 1
        \\Z I
        \\
    , try c.query("SELECT 1 + 1, 1 < 2 AS b, 'x'::text AS t"));
    try testing.expectEqualStrings("I\nZ I\n", try c.query("  ;"));
    try testing.expectEqualStrings(
        \\E 42601 syntax error at or near ")" @13
        \\Z I
        \\
    , try c.query("SELECT 'é', ) FROM t; SELECT 1"));
    try testing.expectEqualStrings(
        \\E 42P01 relation "nope" does not exist
        \\Z I
        \\
    , try c.query("SELECT * FROM nope; SELECT 1"));
    // A failure rolls back the statements of the query before it.
    try testing.expectEqualStrings(
        \\C DELETE 3
        \\E 22012 division by zero
        \\Z I
        \\
    , try c.query("DELETE FROM fruit; SELECT 1/0"));
    try testing.expectEqualStrings("T count:20\nD 3\nC SELECT 1\nZ I\n", try c.query("SELECT count(*) FROM fruit"));
    // The transaction states of ReadyForQuery.
    try testing.expectEqualStrings("C BEGIN\nC DELETE 1\nZ T\n", try c.query("BEGIN; DELETE FROM fruit WHERE id = 1"));
    try testing.expectEqualStrings("E 23505 duplicate key value violates unique constraint \"fruit_pkey\"\nZ E\n", try c.query("INSERT INTO fruit (id) VALUES (2)"));
    try testing.expectEqualStrings("E 25P02 current transaction is aborted, commands ignored until end of transaction block\nZ E\n", try c.query("SELECT 1"));
    try testing.expectEqualStrings("C ROLLBACK\nZ I\n", try c.query("COMMIT"));
    try testing.expectEqualStrings("N WARNING 25P01 there is no transaction in progress\nC COMMIT\nZ I\n", try c.query("COMMIT"));
    try testing.expectEqualStrings("T count:20\nD 3\nC SELECT 1\nZ I\n", try c.query("SELECT count(*) FROM fruit"));
    // SET has no result (the dialect runs set_config()); COPY is refused.
    try testing.expectEqualStrings("C SET\nT application_name:25\nD pgtest2\nC SHOW\nZ I\n", try c.query("SET application_name = 'pgtest2'; SHOW application_name"));
    try testing.expectEqualStrings("E 0A000 COPY is not supported by this server @1\nZ I\n", try c.query("COPY fruit TO STDOUT"));
    try testing.expectEqualStrings("T t:25\nD character varying(10)\nC SELECT 1\nZ I\n", try c.query("SELECT pg_catalog.format_type(1043, 14) AS t"));
    try c.terminate();
}

test "pg: extended queries" {
    if (!xqlite.Dialect.postgres.built()) return;
    var f: Fixture = undefined;
    try f.start(.{});
    defer f.stop();
    var c: Client = .{};
    defer c.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try c.connect(f.srv.address(), "bob", ""));
    defer c.close();
    _ = try c.query("CREATE TABLE t (id int, name text, score float8, ok boolean, data bytea); INSERT INTO t VALUES (1, 'a', 1.5, true, NULL), (2, 'b', 2.5, false, NULL), (3, 'c', NULL, NULL, NULL)");

    // A named statement: its parameter and result types before it runs;
    // a portal fetched a row at a time.
    try c.parse("q", "SELECT id, name, id > $1 AS big FROM t WHERE id >= $1 ORDER BY id", &.{});
    try c.describe('S', "q");
    try c.bind("p", "q", &.{.{ .text = "2" }}, &.{});
    try c.execute("p", 1);
    try c.execute("p", 1);
    try c.execute("p", 1);
    try testing.expectEqualStrings(
        \\1
        \\t 23
        \\T id:23 name:25 big:16
        \\2
        \\D 2 b f
        \\s
        \\D 3 c t
        \\s
        \\C SELECT 0
        \\Z I
        \\
    , try c.sync());

    // Binary parameters and results; the client's parameter types.
    var be8: [8]u8 = undefined;
    std.mem.writeInt(i64, &be8, 3, .big);
    var f8: [8]u8 = undefined;
    std.mem.writeInt(u64, &f8, @bitCast(@as(f64, 9.25)), .big);
    try c.parse("", "INSERT INTO t VALUES ($1, $2, $3, $4, $5)", &.{ 20, 0, 701, 16, 17 });
    try c.bind("", "", &.{ .{ .binary = &be8 }, .{ .text = "d" }, .{ .binary = &f8 }, .{ .binary = "\x01" }, .{ .binary = "\x00\xff" } }, &.{});
    try c.execute("", 0);
    try c.parse("", "SELECT id, score, ok, data, name FROM t WHERE id = $1", &.{});
    try c.bind("", "", &.{.{ .text = "3" }}, &.{1});
    try c.describe('P', "");
    try c.execute("", 0);
    try testing.expectEqualStrings(
        \\1
        \\2
        \\C INSERT 0 1
        \\1
        \\2
        \\T id:23b score:701b ok:16b data:17b name:25b
        \\D 0x00000003 NULL NULL NULL c
        \\D 0x00000003 0x4022800000000000 0x01 0x00ff d
        \\C SELECT 2
        \\Z I
        \\
    , try c.sync());

    // A text parameter that is not of its type; the rest is skipped to
    // Sync, and the implicit transaction rolled back.
    try c.parse("", "DELETE FROM t", &.{});
    try c.bind("", "", &.{}, &.{});
    try c.execute("", 0);
    try c.parse("", "SELECT * FROM t WHERE id = $1", &.{});
    try c.bind("", "", &.{.{ .text = "x" }}, &.{});
    try c.execute("", 0);
    try testing.expectEqualStrings(
        \\1
        \\2
        \\C DELETE 4
        \\1
        \\E 22P02 invalid input syntax for type integer: "x"
        \\Z I
        \\
    , try c.sync());
    try testing.expectEqualStrings("T count:20\nD 4\nC SELECT 1\nZ I\n", try c.query("SELECT count(*) FROM t"));

    // Errors: no such statement, a statement that does not compile; an
    // empty one; Close.
    try c.bind("", "nope", &.{}, &.{});
    try testing.expectEqualStrings("E 26000 prepared statement \"nope\" does not exist\nZ I\n", try c.sync());
    try c.parse("", "SELECT * FROM nope", &.{});
    try testing.expectEqualStrings("E 42P01 relation \"nope\" does not exist\nZ I\n", try c.sync());
    try c.parse("", "", &.{});
    try c.bind("", "", &.{}, &.{});
    try c.describe('P', "");
    try c.execute("", 0);
    try c.closeStatement('S', "q");
    try c.closeStatement('S', "q");
    try testing.expectEqualStrings("1\n2\nn\nI\n3\n3\nZ I\n", try c.sync());

    // In a transaction, a portal lives across Syncs; a failure aborts it.
    _ = try c.query("BEGIN");
    try c.parse("", "SELECT id FROM t ORDER BY id", &.{});
    try c.bind("cur", "", &.{}, &.{});
    try c.execute("cur", 2);
    try testing.expectEqualStrings("1\n2\nD 1\nD 2\ns\nZ T\n", try c.sync());
    try c.execute("cur", 0);
    try testing.expectEqualStrings("D 3\nD 3\nC SELECT 2\nZ T\n", try c.sync());
    try c.parse("", "SELECT 1/0", &.{});
    try c.bind("", "", &.{}, &.{});
    try c.execute("", 0);
    try testing.expectEqualStrings("1\n2\nE 22012 division by zero\nZ E\n", try c.sync());
    try c.parse("", "SELECT 1", &.{});
    try testing.expectEqualStrings("E 25P02 current transaction is aborted, commands ignored until end of transaction block\nZ E\n", try c.sync());
    try c.parse("", "ROLLBACK", &.{});
    try c.bind("", "", &.{}, &.{});
    try c.execute("", 0);
    try testing.expectEqualStrings("1\n2\nC ROLLBACK\nZ I\n", try c.sync());

    // Two portals of one statement at once; a portal outlives its
    // statement.
    try c.parse("two", "SELECT id FROM t WHERE id >= $1 ORDER BY id", &.{});
    try c.bind("a", "two", &.{.{ .text = "2" }}, &.{});
    try c.bind("b", "two", &.{.{ .text = "3" }}, &.{});
    try c.execute("a", 1);
    try c.execute("b", 1);
    try c.closeStatement('S', "two");
    try c.execute("a", 0);
    try c.execute("b", 0);
    try testing.expectEqualStrings("1\n2\n2\nD 2\ns\nD 3\ns\n3\nD 3\nD 3\nC SELECT 2\nD 3\nC SELECT 1\nZ I\n", try c.sync());
    // The portals ended with the implicit transaction.
    try c.execute("a", 0);
    try testing.expectEqualStrings("E 34000 portal \"a\" does not exist\nZ I\n", try c.sync());

    // A portal of a statement whose result changed with the schema.
    _ = try c.query("CREATE TABLE w (a int); INSERT INTO w VALUES (1); BEGIN");
    try c.parse("", "SELECT * FROM w", &.{});
    try c.bind("wp", "", &.{}, &.{1});
    _ = try c.sync();
    _ = try c.query("ALTER TABLE w ADD COLUMN b int");
    try c.execute("wp", 0);
    try testing.expectEqualStrings("E 0A000 cached plan must not change result type\nZ E\n", try c.sync());
    _ = try c.query("ROLLBACK");
    try c.terminate();
}

fn canceler(addr: std.Io.net.IpAddress, pid: u32, key: u32, stop: *std.atomic.Value(bool)) void {
    // The interrupt is cleared when a statement starts, so ask until the
    // query fails.
    for (0..1000) |_| {
        if (stop.load(.acquire)) return;
        var c: Client = .{};
        defer c.deinit();
        c.open(addr) catch return;
        c.writer.interface.writeInt(u32, 16, .big) catch return;
        c.writer.interface.writeInt(u32, 80877102, .big) catch return;
        c.writer.interface.writeInt(u32, pid, .big) catch return;
        c.writer.interface.writeInt(u32, key, .big) catch return;
        c.writer.interface.flush() catch return;
        // The server closes the connection without an answer.
        _ = c.reader.interface.takeByte() catch {};
        c.close();
        io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
}

test "pg: a cancel request stops a query" {
    if (!xqlite.Dialect.postgres.built()) return;
    var f: Fixture = undefined;
    try f.start(.{});
    defer f.stop();
    var c: Client = .{};
    defer c.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try c.connect(f.srv.address(), "u", ""));
    defer c.close();
    var stop: std.atomic.Value(bool) = .init(false);
    var task = try io.concurrent(canceler, .{ f.srv.address(), c.pid, c.key, &stop });
    const got = c.query("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c");
    stop.store(true, .release);
    task.await(io);
    try testing.expectEqualStrings("E 57014 canceling statement due to user request\nZ I\n", try got);
    try testing.expectEqualStrings("T ?column?:23\nD 1\nC SELECT 1\nZ I\n", try c.query("SELECT 1"));
}

test "pg: password authentication" {
    if (!xqlite.Dialect.postgres.built()) return;
    inline for (.{ .password, .md5, .@"scram-sha-256" }) |method| {
        var f: Fixture = undefined;
        try f.start(.{ .auth = .{ .method = method, .user = "carol", .password = "s3cret" } });
        defer f.stop();
        {
            var c: Client = .{};
            defer c.deinit();
            try testing.expectEqual(@as(?[]const u8, null), try c.connect(f.srv.address(), "carol", "s3cret"));
            defer c.close();
            try testing.expectEqualStrings("T ?column?:23\nD 1\nC SELECT 1\nZ I\n", try c.query("SELECT 1"));
        }
        {
            var c: Client = .{};
            defer c.deinit();
            const err = (try c.connect(f.srv.address(), "carol", "wrong")) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(" FATAL 28P01 password authentication failed for user \"carol\"", err);
            c.close();
        }
        {
            var c: Client = .{};
            defer c.deinit();
            const err = (try c.connect(f.srv.address(), "mallory", "s3cret")) orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings(" FATAL 28000 role \"mallory\" does not exist", err);
            c.close();
        }
    }
}
