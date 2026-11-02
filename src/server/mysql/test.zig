//! The MySQL protocol over loopback TCP, with a small client of the
//! test's own: the handshake and mysql_native_password, COM_QUERY (text
//! result sets, OK, ERR, several statements), the prepared statements
//! of the binary protocol, USE, ping, KILL.
//!
//! The client writes each response as lines, for comparison:
//!
//!     ok affected=2 id=2 [trans] [more] [warnings=1]
//!     err 1146 42S02 Table 'main.nope' doesn't exist
//!     cols id:LONGLONG name:VAR_STRING
//!     row 1|a|NULL
//!     end [trans] [more]

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const mysql = @import("root.zig");
const c = @import("consts.zig");
const packet = @import("packet.zig");
const auth = @import("auth.zig");
const columns = @import("columns.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const Server = server.Server(mysql.Protocol);

const maria = xqlite.Dialect.mariadb.built();

pub const Client = struct {
    stream: std.Io.net.Stream = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    rbuf: [16 * 1024]u8 = undefined,
    wbuf: [16 * 1024]u8 = undefined,
    wire: packet.Wire = undefined,
    caps: u32 = 0,
    id: u32 = 0,
    /// The column types of the last result set (binary rows).
    types: std.ArrayList(c.Type) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Show the key flags of the columns (nn, pk, ai, uk, mk).
    show_keys: bool = false,

    pub const Options = struct {
        user: []const u8 = "u",
        password: []const u8 = "",
        db: []const u8 = "",
        /// The capabilities left out.
        without: u32 = 0,
        /// The auth plugin the client says it uses.
        plugin: []const u8 = auth.plugin,
    };

    /// Connect and log in: null when logged in, else the ERR as a line.
    pub fn connect(cl: *Client, addr: std.Io.net.IpAddress, o: Options) !?[]const u8 {
        cl.stream = try addr.connect(io, .{ .mode = .stream });
        cl.reader = cl.stream.reader(io, &cl.rbuf);
        cl.writer = cl.stream.writer(io, &cl.wbuf);
        cl.wire = .{ .gpa = gpa, .in = &cl.reader.interface, .out = &cl.writer.interface };
        var r: packet.Reader = .{ .data = try cl.wire.read() };
        if (r.data[0] == c.err_header) return try cl.errLine(r.data);
        try testing.expectEqual(@as(u8, 10), try r.byte());
        try testing.expect(std.mem.indexOf(u8, r.strNul(), "MariaDB") != null);
        cl.id = try r.int(u32);
        var scramble: [20]u8 = undefined;
        @memcpy(scramble[0..8], try r.bytes(8));
        _ = try r.byte();
        var server_caps: u32 = try r.int(u16);
        _ = try r.byte(); // charset
        _ = try r.int(u16); // status
        server_caps |= @as(u32, try r.int(u16)) << 16;
        _ = try r.byte();
        _ = try r.bytes(10);
        @memcpy(scramble[8..], (try r.bytes(13))[0..12]);
        try testing.expectEqualStrings(auth.plugin, r.strNul());

        const want = c.Cap.protocol_41 | c.Cap.secure_connection | c.Cap.plugin_auth | c.Cap.plugin_auth_lenenc_client_data |
            c.Cap.multi_statements | c.Cap.multi_results | c.Cap.ps_multi_results | c.Cap.deprecate_eof | c.Cap.transactions |
            c.Cap.connect_with_db | c.Cap.connect_attrs;
        cl.caps = want & ~o.without & server_caps;
        if (o.db.len == 0) cl.caps &= ~c.Cap.connect_with_db;
        const b = cl.wire.begin();
        try packet.int4(gpa, b, cl.caps);
        try packet.int4(gpa, b, 1 << 24);
        try packet.int1(gpa, b, 45);
        try b.appendNTimes(gpa, 0, 23);
        try packet.strNul(gpa, b, o.user);
        var resp: [20]u8 = undefined;
        const proof = if (std.mem.eql(u8, o.plugin, auth.plugin)) auth.response(o.password, &scramble, &resp) else "xx";
        try packet.lenencStr(gpa, b, proof);
        if (cl.caps & c.Cap.connect_with_db != 0) try packet.strNul(gpa, b, o.db);
        try packet.strNul(gpa, b, o.plugin);
        if (cl.caps & c.Cap.connect_attrs != 0) {
            // _client_name=test
            try packet.lenenc(gpa, b, 1 + 12 + 1 + 4);
            try packet.lenencStr(gpa, b, "_client_name");
            try packet.lenencStr(gpa, b, "test");
        }
        try cl.wire.send();
        try cl.wire.flush();
        var reply = try cl.wire.read();
        if (reply[0] == c.eof_header) {
            // AuthSwitchRequest.
            var s: packet.Reader = .{ .data = reply, .pos = 1 };
            try testing.expectEqualStrings(auth.plugin, s.strNul());
            const sw = try s.bytes(20);
            @memcpy(&scramble, sw);
            _ = cl.wire.begin();
            try cl.wire.buf.appendSlice(gpa, auth.response(o.password, &scramble, &resp));
            try cl.wire.send();
            try cl.wire.flush();
            reply = try cl.wire.read();
        }
        if (reply[0] == c.err_header) return try cl.errLine(reply);
        try testing.expectEqual(c.ok_header, reply[0]);
        return null;
    }

    pub fn deinit(cl: *Client) void {
        cl.stream.close(io);
        cl.wire.deinit();
        cl.types.deinit(gpa);
        cl.out.deinit(gpa);
    }

    fn errLine(cl: *Client, p: []const u8) ![]const u8 {
        cl.out.clearRetainingCapacity();
        var r: packet.Reader = .{ .data = p, .pos = 1 };
        const n = try r.int(u16);
        _ = try r.byte();
        const state = try r.bytes(5);
        try cl.out.print(gpa, "err {d} {s} {s}\n", .{ n, state, r.rest() });
        return cl.out.items;
    }

    /// Send a command (sequence 0).
    pub fn command(cl: *Client, com: c.Com, payload: []const u8) !void {
        cl.wire.seq = 0;
        const b = cl.wire.begin();
        try b.append(gpa, @backingInt(com));
        try b.appendSlice(gpa, payload);
        try cl.wire.send();
        try cl.wire.flush();
    }

    pub fn query(cl: *Client, sql: []const u8) ![]const u8 {
        try cl.command(.query, sql);
        return cl.results(false);
    }

    /// Read the responses to a command, up to the one without
    /// MORE_RESULTS_EXISTS, as lines.
    pub fn results(cl: *Client, binary: bool) ![]const u8 {
        cl.out.clearRetainingCapacity();
        while (true) {
            const p = try cl.wire.read();
            const more = switch (p[0]) {
                c.ok_header => try cl.okLine(p, "ok"),
                c.err_header => {
                    var r: packet.Reader = .{ .data = p, .pos = 1 };
                    const n = try r.int(u16);
                    _ = try r.byte();
                    const state = try r.bytes(5);
                    try cl.out.print(gpa, "err {d} {s} {s}\n", .{ n, state, r.rest() });
                    return cl.out.items;
                },
                else => try cl.resultSet(p, binary),
            };
            if (!more) return cl.out.items;
        }
    }

    /// An OK packet (or the OK that ends a result set): whether more
    /// results follow.
    fn okLine(cl: *Client, p: []const u8, word: []const u8) !bool {
        var r: packet.Reader = .{ .data = p, .pos = 1 };
        const affected = try r.lenenc();
        const id = try r.lenenc();
        const status = try r.int(u16);
        const warnings = try r.int(u16);
        if (std.mem.eql(u8, word, "ok")) {
            try cl.out.print(gpa, "ok affected={d} id={d}", .{ affected, id });
        } else try cl.out.appendSlice(gpa, word);
        try cl.flags(status, warnings);
        return status & c.Status.more_results_exists != 0;
    }

    fn flags(cl: *Client, status: u16, warnings: u16) !void {
        if (status & c.Status.in_trans != 0) try cl.out.appendSlice(gpa, " trans");
        if (status & c.Status.more_results_exists != 0) try cl.out.appendSlice(gpa, " more");
        if (warnings > 0) try cl.out.print(gpa, " warnings={d}", .{warnings});
        try cl.out.append(gpa, '\n');
    }

    fn resultSet(cl: *Client, first: []const u8, binary: bool) !bool {
        var r: packet.Reader = .{ .data = first };
        const n = try r.lenenc();
        try cl.columnDefs(n, "cols");
        if (cl.caps & c.Cap.deprecate_eof == 0) {
            const e = try cl.wire.read();
            try testing.expectEqual(c.eof_header, e[0]);
        }
        while (true) {
            const p = try cl.wire.read();
            if (p[0] == c.eof_header and p.len < 0xFF_FFFF) return cl.endOf(p);
            try cl.out.appendSlice(gpa, "row ");
            var rr: packet.Reader = .{ .data = p };
            if (binary) try cl.binaryRow(&rr) else try cl.textRow(&rr, n);
            try cl.out.append(gpa, '\n');
        }
    }

    fn endOf(cl: *Client, p: []const u8) !bool {
        if (cl.caps & c.Cap.deprecate_eof != 0) return cl.okLine(p, "end");
        var r: packet.Reader = .{ .data = p, .pos = 1 };
        const warnings = try r.int(u16);
        const status = try r.int(u16);
        try cl.out.appendSlice(gpa, "end");
        try cl.flags(status, warnings);
        return status & c.Status.more_results_exists != 0;
    }

    fn columnDefs(cl: *Client, n: u64, word: []const u8) !void {
        cl.types.clearRetainingCapacity();
        try cl.out.appendSlice(gpa, word);
        for (0..n) |_| {
            var d: packet.Reader = .{ .data = try cl.wire.read() };
            try testing.expectEqualStrings("def", try d.lenencStr());
            const schema = try d.lenencStr();
            const table = try d.lenencStr();
            _ = try d.lenencStr();
            const name = try d.lenencStr();
            _ = try d.lenencStr();
            _ = try d.lenenc();
            _ = try d.int(u16);
            _ = try d.int(u32);
            const t: c.Type = @fromBackingInt(@intCast(try d.byte()));
            const fl = try d.int(u16);
            const decimals = try d.byte();
            try cl.types.append(gpa, t);
            try cl.out.print(gpa, " {s}:", .{name});
            for (typeName(t)) |ch| try cl.out.append(gpa, std.ascii.toUpper(ch));
            if (fl & c.Flag.unsigned != 0) try cl.out.appendSlice(gpa, ",unsigned");
            if (cl.show_keys) for ([_]struct { u16, []const u8 }{ .{ c.Flag.not_null, ",nn" }, .{ c.Flag.pri_key, ",pk" }, .{ c.Flag.auto_increment, ",ai" }, .{ c.Flag.unique_key, ",uk" }, .{ c.Flag.multiple_key, ",mk" } }) |k| {
                if (fl & k[0] != 0) try cl.out.appendSlice(gpa, k[1]);
            };
            if (t == .newdecimal) try cl.out.print(gpa, ",{d}", .{decimals});
            if (table.len > 0) try cl.out.print(gpa, "@{s}.{s}", .{ schema, table });
        }
        try cl.out.append(gpa, '\n');
    }

    fn textRow(cl: *Client, r: *packet.Reader, n: u64) !void {
        for (0..n) |i| {
            if (i > 0) try cl.out.append(gpa, '|');
            if (r.rest()[0] == c.null_value) {
                r.pos += 1;
                try cl.out.appendSlice(gpa, "NULL");
            } else try cl.out.appendSlice(gpa, try r.lenencStr());
        }
    }

    fn binaryRow(cl: *Client, r: *packet.Reader) !void {
        try testing.expectEqual(@as(u8, 0), try r.byte());
        const n = cl.types.items.len;
        const bitmap = try r.bytes((n + 9) / 8);
        for (cl.types.items, 0..) |t, i| {
            if (i > 0) try cl.out.append(gpa, '|');
            if (bitmap[(i + 2) / 8] & (@as(u8, 1) << @intCast((i + 2) % 8)) != 0) {
                try cl.out.appendSlice(gpa, "NULL");
                continue;
            }
            switch (t) {
                .tiny => try cl.out.print(gpa, "{d}", .{try r.int(i8)}),
                .short, .year => try cl.out.print(gpa, "{d}", .{try r.int(i16)}),
                .long, .int24 => try cl.out.print(gpa, "{d}", .{try r.int(i32)}),
                .longlong => try cl.out.print(gpa, "{d}", .{try r.int(i64)}),
                .float => try cl.out.print(gpa, "{d}", .{@as(f32, @bitCast(try r.int(u32)))}),
                .double => try cl.out.print(gpa, "{d}", .{@as(f64, @bitCast(try r.int(u64)))}),
                .date, .datetime, .timestamp => {
                    const len = try r.byte();
                    var d: columns.DateTime = .{};
                    if (len >= 4) {
                        d.year = try r.int(u16);
                        d.month = try r.byte();
                        d.day = try r.byte();
                    }
                    if (len >= 7) {
                        d.hour = try r.byte();
                        d.minute = try r.byte();
                        d.second = try r.byte();
                    }
                    if (len >= 11) d.micro = try r.int(u32);
                    try cl.out.print(gpa, "{d}-{d}-{d} {d}:{d}:{d}.{d}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second, d.micro });
                },
                .time => {
                    const len = try r.byte();
                    if (len == 0) {
                        try cl.out.appendSlice(gpa, "0:0:0");
                    } else {
                        const neg = try r.byte();
                        const days = try r.int(u32);
                        try cl.out.print(gpa, "{s}{d}d{d}:{d}:{d}", .{ if (neg != 0) "-" else "", days, try r.byte(), try r.byte(), try r.byte() });
                        if (len == 12) try cl.out.print(gpa, ".{d}", .{try r.int(u32)});
                    }
                },
                else => try cl.out.appendSlice(gpa, try r.lenencStr()),
            }
        }
    }

    /// COM_STMT_PREPARE: the statement id, and its definitions as lines.
    pub fn prepare(cl: *Client, sql: []const u8) !struct { id: u32, text: []const u8 } {
        try cl.command(.stmt_prepare, sql);
        const p = try cl.wire.read();
        if (p[0] == c.err_header) return .{ .id = 0, .text = try cl.errLine(p) };
        var r: packet.Reader = .{ .data = p, .pos = 1 };
        const id = try r.int(u32);
        const n_cols = try r.int(u16);
        const n_params = try r.int(u16);
        cl.out.clearRetainingCapacity();
        if (n_params > 0) {
            try cl.columnDefs(n_params, "params");
            if (cl.caps & c.Cap.deprecate_eof == 0) _ = try cl.wire.read();
        }
        if (n_cols > 0) {
            try cl.columnDefs(n_cols, "cols");
            if (cl.caps & c.Cap.deprecate_eof == 0) _ = try cl.wire.read();
        }
        return .{ .id = id, .text = cl.out.items };
    }

    pub const Param = union(enum) {
        null,
        int: i64,
        double: f64,
        string: []const u8,
        blob: []const u8,
        datetime: columns.DateTime,
        time: columns.Time,
        /// Sent with COM_STMT_SEND_LONG_DATA before.
        long,
    };

    /// COM_STMT_EXECUTE with `params` (types bound each time).
    pub fn execute(cl: *Client, id: u32, params: []const Param) ![]const u8 {
        cl.wire.seq = 0;
        const b = cl.wire.begin();
        try b.append(gpa, @backingInt(c.Com.stmt_execute));
        try packet.int4(gpa, b, id);
        try packet.int1(gpa, b, 0);
        try packet.int4(gpa, b, 1);
        if (params.len > 0) {
            const at = b.items.len;
            try b.appendNTimes(gpa, 0, (params.len + 7) / 8);
            for (params, 0..) |p, i| if (p == .null) {
                b.items[at + i / 8] |= @as(u8, 1) << @intCast(i % 8);
            };
            try packet.int1(gpa, b, 1);
            for (params) |p| {
                const t: c.Type = switch (p) {
                    .null => .null,
                    .int => .longlong,
                    .double => .double,
                    .string => .var_string,
                    .blob, .long => .blob,
                    .datetime => .datetime,
                    .time => .time,
                };
                try packet.int1(gpa, b, @backingInt(t));
                try packet.int1(gpa, b, 0);
            }
            for (params) |p| switch (p) {
                .null, .long => {},
                .int => |v| try packet.int8(gpa, b, @bitCast(v)),
                .double => |v| try packet.int8(gpa, b, @bitCast(v)),
                .string, .blob => |v| try packet.lenencStr(gpa, b, v),
                .datetime => |v| try columns.writeDateTime(gpa, b, v, false),
                .time => |v| try columns.writeTime(gpa, b, v),
            };
        }
        try cl.wire.send();
        try cl.wire.flush();
        return cl.results(true);
    }

    pub fn sendLongData(cl: *Client, id: u32, param: u16, data: []const u8) !void {
        var payload: [64]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], id, .little);
        std.mem.writeInt(u16, payload[4..6], param, .little);
        @memcpy(payload[6..][0..data.len], data);
        try cl.command(.stmt_send_long_data, payload[0 .. 6 + data.len]);
    }

    pub fn closeStmt(cl: *Client, id: u32) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, id, .little);
        try cl.command(.stmt_close, &payload);
    }
};

fn typeName(t: c.Type) []const u8 {
    return switch (t) {
        _ => "?",
        else => |x| @tagName(x),
    };
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_buf: [256]u8 = undefined,
    proto: mysql.Protocol,
    srv: Server = undefined,
    running: std.Io.Future(std.Io.Cancelable!void) = undefined,

    fn start(f: *Fixture) !void {
        const path = try std.fmt.bufPrint(&f.path_buf, ".zig-cache/tmp/{s}/mysql.db", .{f.tmp.sub_path});
        f.srv = try Server.init(io, gpa, &f.proto, .{ .address = try .parse("127.0.0.1", 0), .path = path, .max_connections = 8 });
        f.running = try io.concurrent(Server.run, .{&f.srv});
    }

    fn stop(f: *Fixture) void {
        f.running.cancel(io) catch {};
        f.srv.deinit();
        f.proto.deinit(gpa);
        f.tmp.cleanup();
    }
};

fn expectLines(want: []const u8, got: []const u8) !void {
    try testing.expectEqualStrings(want, got);
}

test "mysql: handshake and native password" {
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{ .user = "app", .password = "secret" } };
    try f.start();
    defer f.stop();
    const addr = f.srv.address();

    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(addr, .{ .user = "app", .password = "secret" }));
    try expectLines("cols x:VAR_STRING\nrow y\nend\n", try a.query("SELECT 'y' AS x"));

    var b: Client = .{};
    defer b.deinit();
    try expectLines("err 1045 28000 Access denied for user 'app'@'%' (using password: YES)\n", (try b.connect(addr, .{ .user = "app", .password = "wrong" })).?);

    var d: Client = .{};
    defer d.deinit();
    try expectLines("err 1045 28000 Access denied for user 'bob'@'%' (using password: YES)\n", (try d.connect(addr, .{ .user = "bob", .password = "secret" })).?);

    // A client of another plugin is switched to mysql_native_password.
    var e: Client = .{};
    defer e.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try e.connect(addr, .{ .user = "app", .password = "secret", .plugin = "caching_sha2_password" }));
    try e.command(.ping, "");
    try expectLines("ok affected=0 id=0\n", try e.results(false));
    try testing.expect(a.id != e.id);
}

test "mysql: queries, result sets, errors, several statements" {
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{} };
    try f.start();
    defer f.stop();
    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(f.srv.address(), .{ .user = "anyone", .password = "anything" }));
    if (!maria) {
        try expectLines("cols 1:LONGLONG\nrow 1\nend\n", try a.query("SELECT 1"));
        return;
    }
    try expectLines("ok affected=0 id=0\n", try a.query(
        \\CREATE TABLE t(id int unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY, name varchar(10) NOT NULL UNIQUE,
        \\  price decimal(10,2), at datetime, b bool, bits bit(4), y year, j json, raw varbinary(8))
    ));
    try expectLines("ok affected=2 id=2\n", try a.query("INSERT INTO t(name, price, at, b, bits, y, j, raw) VALUES ('a', 1.5, '2024-01-02 03:04:05', true, 5, 2024, '{\"k\": 1}', x'0001'), ('b', NULL, NULL, NULL, NULL, NULL, NULL, NULL)"));
    try expectLines(
        \\cols id:LONG,unsigned@main.t name:VAR_STRING@main.t price:NEWDECIMAL,2@main.t at:DATETIME@main.t b:TINY@main.t y:YEAR,unsigned@main.t j:BLOB@main.t
        \\row 1|a|1.50|2024-01-02 03:04:05|1|2024|{"k": 1}
        \\row 2|b|NULL|NULL|NULL|NULL|NULL
        \\end
        \\
    , try a.query("SELECT id, name, price, at, b, y, j FROM t ORDER BY id"));
    // BIT values are bytes, as in MariaDB.
    try expectLines("cols bits:BIT,unsigned@main.t raw:VAR_STRING@main.t\nrow \x05|\x00\x01\nend\n", try a.query("SELECT bits, raw FROM t WHERE id = 1"));
    // The flags of the table's constraints.
    try expectLines("ok affected=0 id=0\n", try a.query("CREATE INDEX t_at ON t(at)"));
    a.show_keys = true;
    try expectLines("cols id:LONG,unsigned,nn,pk,ai@main.t name:VAR_STRING,nn,uk@main.t at:DATETIME,mk@main.t\nend\n", try a.query("SELECT id, name, at FROM t WHERE 0"));
    a.show_keys = false;
    // Expressions.
    try expectLines("cols 1 + 1:LONGLONG 7 / 2:NEWDECIMAL,4 x:VAR_STRING NULL:VAR_STRING\nrow 2|3.5000|x|NULL\nend\n", try a.query("SELECT 1 + 1, 7 / 2, 'x', NULL"));
    // Errors, with MariaDB's numbers and SQLSTATEs.
    try expectLines("err 1146 42S02 Table 'main.nope' doesn't exist\n", try a.query("SELECT * FROM nope"));
    try expectLines("err 1062 23000 Duplicate entry 'a' for key 'name'\n", try a.query("INSERT INTO t(name) VALUES ('a')"));
    try expectLines("err 1065 42000 Query was empty\n", try a.query(" -- nothing\n"));
    const syntax = try a.query("SELEC 1");
    try testing.expect(std.mem.startsWith(u8, syntax, "err 1064 42000 You have an error in your SQL syntax"));
    // Several statements: MORE_RESULTS_EXISTS between them; a failure
    // ends the script.
    try expectLines(
        \\ok affected=1 id=3 more
        \\cols n:LONGLONG
        \\row 3
        \\end more
        \\err 1146 42S02 Table 'main.nope' doesn't exist
        \\
    , try a.query("INSERT INTO t(name) VALUES ('c'); SELECT count(*) AS n FROM t; SELECT * FROM nope; SELECT 1"));
    // Transactions: SERVER_STATUS_IN_TRANS.
    try expectLines("ok affected=0 id=0 trans more\nok affected=1 id=0 trans\n", try a.query("START TRANSACTION; UPDATE t SET name = 'z' WHERE id = 3"));
    try expectLines("ok affected=0 id=0\n", try a.query("ROLLBACK"));
    try expectLines("cols name:VAR_STRING@main.t\nrow c\nend\n", try a.query("SELECT name FROM t WHERE id = 3"));
    // Warnings of the statement.
    try expectLines("ok affected=0 id=0 more\nok affected=1 id=4 warnings=1\n", try a.query("SET sql_mode = ''; INSERT INTO t(name) VALUES ('toolongtoolong')"));
    try expectLines("cols Level:VAR_STRING Code:LONG Message:VAR_STRING\nrow Warning|1265|Data truncated for column 'name' at row 1\nend warnings=1\n", try a.query("SHOW WARNINGS"));
}

test "mysql: without multi-statements or DEPRECATE_EOF" {
    if (!maria) return error.SkipZigTest;
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{} };
    try f.start();
    defer f.stop();
    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(f.srv.address(), .{ .without = c.Cap.multi_statements | c.Cap.deprecate_eof | c.Cap.connect_attrs }));
    try expectLines("err 1064 42000 You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'SELECT 2' at line 1\n", try a.query("SELECT 1; SELECT 2"));
    try expectLines("cols 1:LONG\nrow 1\nend\n", try a.query("SELECT 1;"));
    // COM_SET_OPTION MYSQL_OPTION_MULTI_STATEMENTS_ON: an EOF.
    try a.command(.set_option, &.{ 0, 0 });
    const p = try a.wire.read();
    try testing.expectEqual(@as(usize, 5), p.len);
    try expectLines("cols 1:LONG\nrow 1\nend more\ncols 2:LONG\nrow 2\nend\n", try a.query("SELECT 1; SELECT 2"));
}

test "mysql: databases, ping, statistics, field list, reset" {
    if (!maria) return error.SkipZigTest;
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{} };
    try f.start();
    defer f.stop();
    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(f.srv.address(), .{}));
    try expectLines("ok affected=0 id=0 more\nok affected=0 id=0 more\nok affected=1 id=1\n", try a.query("CREATE DATABASE sales; CREATE TABLE sales.o(id int PRIMARY KEY, v text); INSERT INTO sales.o VALUES (1, 'x')"));
    try a.command(.init_db, "sales");
    try expectLines("ok affected=0 id=0\n", try a.results(false));
    try expectLines("cols DATABASE():VAR_STRING id:LONG@sales.o\nrow sales|1\nend\n", try a.query("SELECT DATABASE(), id FROM o"));
    try a.command(.init_db, "nope");
    try expectLines("err 1049 42000 Unknown database 'nope'\n", try a.results(false));
    try a.command(.ping, "");
    try expectLines("ok affected=0 id=0\n", try a.results(false));
    try a.command(.statistics, "");
    try testing.expect(std.mem.startsWith(u8, try a.wire.read(), "Uptime: "));
    // COM_FIELD_LIST: the definitions, then the end.
    try a.command(.field_list, "o\x00");
    var defs: usize = 0;
    while ((try a.wire.read())[0] != c.eof_header) defs += 1;
    try testing.expectEqual(@as(usize, 2), defs);
    // Connect to a database.
    var b: Client = .{};
    defer b.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try b.connect(f.srv.address(), .{ .db = "sales" }));
    try expectLines("cols v:BLOB@sales.o\nrow x\nend\n", try b.query("SELECT v FROM o"));
    var e: Client = .{};
    defer e.deinit();
    try expectLines("err 1049 42000 Unknown database 'nope'\n", (try e.connect(f.srv.address(), .{ .db = "nope" })).?);
    // COM_RESET_CONNECTION: back to main, no user variables.
    try expectLines("ok affected=0 id=0\n", try b.query("SET @x = 1"));
    try b.command(.reset_connection, "");
    try expectLines("ok affected=0 id=0\n", try b.results(false));
    try expectLines("cols DATABASE():VAR_STRING @x:VAR_STRING\nrow main|NULL\nend\n", try b.query("SELECT DATABASE(), @x"));
}

test "mysql: prepared statements" {
    if (!maria) return error.SkipZigTest;
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{} };
    try f.start();
    defer f.stop();
    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(f.srv.address(), .{}));
    try expectLines("ok affected=0 id=0\n", try a.query("CREATE TABLE t(id bigint PRIMARY KEY, f double, s varchar(20), at datetime(6), d time, b blob)"));
    const ins = try a.prepare("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)");
    try expectLines("params ?:LONGLONG ?:DOUBLE ?:VAR_STRING ?:DATETIME ?:TIME ?:BLOB\n", ins.text);
    try expectLines("ok affected=1 id=1\n", try a.execute(ins.id, &.{
        .{ .int = 1 },
        .{ .double = 2.5 },
        .{ .string = "héllo" },
        .{ .datetime = .{ .year = 2024, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 58, .micro = 123456 } },
        .{ .time = .{ .negative = true, .hours = 30, .minute = 1, .second = 2 } },
        .{ .blob = "\x00\xff" },
    }));
    try a.sendLongData(ins.id, 5, "long ");
    try a.sendLongData(ins.id, 5, "data");
    try expectLines("ok affected=1 id=2\n", try a.execute(ins.id, &.{ .{ .int = 2 }, .null, .null, .null, .null, .long }));
    try expectLines("err 1062 23000 Duplicate entry '2' for key 'PRIMARY'\n", try a.execute(ins.id, &.{ .{ .int = 2 }, .null, .null, .null, .null, .null }));

    const sel = try a.prepare("SELECT id, f, s, at, d, b, id * 2 AS twice FROM t WHERE id >= ? ORDER BY id");
    // The parameter compared with the INTEGER PRIMARY KEY is of its type.
    try expectLines("params ?:LONGLONG\ncols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t twice:LONGLONG\n", sel.text);
    try expectLines(
        \\cols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t twice:LONGLONG
        \\row 1|2.5|héllo|2024-2-29 23:59:58.123456|-1d6:1:2|
    ++ "\x00\xff" ++
        \\|2
        \\row 2|NULL|NULL|NULL|NULL|long data|4
        \\end
        \\
    , try a.execute(sel.id, &.{.{ .int = 0 }}));
    // Executed again, with another value.
    try expectLines("cols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t twice:LONGLONG\nrow 2|NULL|NULL|NULL|NULL|long data|4\nend\n", try a.execute(sel.id, &.{.{ .int = 2 }}));
    // The text protocol shows the same values as text.
    try expectLines("cols at:DATETIME@main.t d:TIME@main.t\nrow 2024-02-29 23:59:58.123456|-30:01:02\nend\n", try a.query("SELECT at, d FROM t WHERE id = 1"));
    // The types the statement knows are described before it runs.
    const typed = try a.prepare("SELECT id = ? AS eq, CAST(id AS CHAR) AS c, id + 0.5 AS h FROM t WHERE id = 1");
    try expectLines("params ?:LONGLONG\ncols eq:TINY c:STRING h:NEWDECIMAL,1\n", typed.text);
    try expectLines("cols eq:TINY c:STRING h:NEWDECIMAL,1\nrow 1|1|1.5\nend\n", try a.execute(typed.id, &.{.{ .int = 1 }}));
    // A statement prepared before a schema change is compiled again, and
    // described again.
    const star = try a.prepare("SELECT * FROM t WHERE id = ?");
    try expectLines("ok affected=0 id=0\n", try a.query("ALTER TABLE t ADD COLUMN extra int"));
    try expectLines("cols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t twice:LONGLONG\nrow 2|NULL|NULL|NULL|NULL|long data|4\nend\n", try a.execute(sel.id, &.{.{ .int = 2 }}));
    try expectLines("cols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t extra:LONG@main.t\nrow 2|NULL|NULL|NULL|NULL|long data|NULL\nend\n", try a.execute(star.id, &.{.{ .int = 2 }}));
    // -1: the statement prepared last.
    try expectLines("cols id:LONGLONG@main.t f:DOUBLE@main.t s:VAR_STRING@main.t at:DATETIME@main.t d:TIME@main.t b:BLOB@main.t extra:LONG@main.t\nrow 2|NULL|NULL|NULL|NULL|long data|NULL\nend\n", try a.execute(std.math.maxInt(u32), &.{.{ .int = 2 }}));
    try a.closeStmt(sel.id);
    try expectLines("err 1243 HY000 Unknown prepared statement handler (2) given to mysqld_stmt_execute\n", try a.execute(sel.id, &.{.{ .int = 2 }}));
    // Errors of prepare.
    try expectLines("err 1146 42S02 Table 'main.nope' doesn't exist\n", (try a.prepare("SELECT * FROM nope")).text);
    try expectLines("err 1064 42000 You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'SELECT 2' at line 1\n", (try a.prepare("SELECT 1; SELECT 2")).text);
    try expectLines("err 1065 42000 Query was empty\n", (try a.prepare(" ")).text);
    // A statement without parameters or results.
    const begin = try a.prepare("START TRANSACTION");
    try expectLines("ok affected=0 id=0 trans\n", try a.execute(begin.id, &.{}));
    try expectLines("ok affected=0 id=0\n", try a.query("COMMIT"));
}

/// The victim of the KILL test: a query that would run for minutes, then
/// (after `next` is set) a query on a connection that KILL ended.
const Victim = struct {
    id: std.atomic.Value(u32) = .init(0),
    out: [256]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    next: std.atomic.Value(bool) = .init(false),
    /// What the query after KILL CONNECTION got: an error of the
    /// connection, as it should.
    gone: std.atomic.Value(bool) = .init(false),

    fn run(v: *Victim, addr: std.Io.net.IpAddress) void {
        var cl: Client = .{};
        defer cl.deinit();
        const refused = cl.connect(addr, .{}) catch return;
        if (refused != null) return;
        v.id.store(cl.id, .release);
        const got = cl.query("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c) SELECT count(*) FROM c") catch return;
        const n = @min(got.len, v.out.len);
        @memcpy(v.out[0..n], got[0..n]);
        v.len.store(n, .release);
        while (!v.next.load(.acquire)) io.sleep(.fromMilliseconds(1), .awake) catch return;
        _ = cl.query("SELECT 1") catch {
            v.gone.store(true, .release);
            return;
        };
    }
};

test "mysql: KILL QUERY and KILL CONNECTION" {
    var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .proto = .{} };
    try f.start();
    defer f.stop();
    const addr = f.srv.address();
    var a: Client = .{};
    defer a.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try a.connect(addr, .{}));
    var buf: [64]u8 = undefined;
    if (maria) try expectLines(try std.fmt.bufPrint(&buf, "cols CONNECTION_ID():LONG\nrow {d}\nend\n", .{a.id}), try a.query("SELECT CONNECTION_ID()"));
    try expectLines("err 1094 HY000 Unknown thread id: 999\n", try a.query("KILL 999"));
    try expectLines("err 1317 70100 Query execution was interrupted\n", try a.query(try std.fmt.bufPrint(&buf, "KILL QUERY {d}", .{a.id})));

    var v: Victim = .{};
    var task = try io.concurrent(Victim.run, .{ &v, addr });
    while (v.id.load(.acquire) == 0) try io.sleep(.fromMilliseconds(1), .awake);
    const id = v.id.load(.acquire);
    // The interrupt is cleared when a statement starts: ask until the
    // victim reports it.
    var tries: usize = 0;
    while (v.len.load(.acquire) == 0 and tries < 2000) : (tries += 1) {
        try expectLines("ok affected=0 id=0\n", try a.query(try std.fmt.bufPrint(&buf, "KILL QUERY {d}", .{id})));
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    while (v.len.load(.acquire) == 0) try io.sleep(.fromMilliseconds(1), .awake);
    try expectLines("err 1317 70100 Query execution was interrupted\n", v.out[0..v.len.load(.acquire)]);
    // KILL CONNECTION (COM_PROCESS_KILL): the victim's next query finds
    // the connection closed.
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, id, .little);
    try a.command(.process_kill, &payload);
    try expectLines("ok affected=0 id=0\n", try a.results(false));
    v.next.store(true, .release);
    task.await(io);
    try testing.expect(v.gone.load(.acquire));
    // The connection is gone.
    var tries_gone: usize = 0;
    while (tries_gone < 1000) : (tries_gone += 1) {
        const r = try a.query(try std.fmt.bufPrint(&buf, "KILL {d}", .{id}));
        if (std.mem.startsWith(u8, r, "err 1094")) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    } else return error.TestUnexpectedResult;
}

test "mysql: a database that cannot be opened" {
    var proto: mysql.Protocol = .{};
    defer proto.deinit(gpa);
    var srv = try Server.init(io, gpa, &proto, .{ .address = try .parse("127.0.0.1", 0), .path = "/nonexistent-xqlite-dir/x.db", .open = .{} });
    defer srv.deinit();
    var running = try io.concurrent(Server.run, .{&srv});
    defer running.cancel(io) catch {};
    // Refused at the first packet, twice: the server goes on.
    for (0..2) |_| {
        var a: Client = .{};
        defer a.deinit();
        try expectLines("err 1105 HY000 xqlite: cannot open the database\n", (try a.connect(srv.address(), .{})).?);
    }
}
