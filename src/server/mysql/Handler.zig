//! One MySQL client: the handshake and authentication, then its
//! commands until it quits.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const Protocol = @import("Protocol.zig");
const c = @import("consts.zig");
const packet = @import("packet.zig");
const auth = @import("auth.zig");
const cdef = @import("columns.zig");
const errors = @import("errors.zig");
const prepared = @import("prepared.zig");

const Allocator = std.mem.Allocator;
const Session = server.Session;
const Connection = server.Connection;
const Handler = @This();

proto: *Protocol,
conn: *Connection,
gpa: Allocator,
wire: packet.Wire,
session: *Session = undefined,
/// The connection id (the session's ticket).
id: u32 = 0,
/// The capabilities both sides have.
caps: u32 = 0,
/// COM_SET_OPTION: whether a COM_QUERY may hold several statements.
multi_statements: bool = false,
stmts: prepared.Statements,
/// The fields of the result set being sent.
fields: std.ArrayList(cdef.Field) = .empty,
/// KILL CONNECTION from another connection.
killed: std.atomic.Value(bool) = .init(false),

pub fn init(proto: *Protocol, conn: *Connection) Handler {
    return .{
        .proto = proto,
        .conn = conn,
        .gpa = conn.gpa,
        .wire = .{ .gpa = conn.gpa, .in = conn.in(), .out = conn.out() },
        .stmts = .init(conn.gpa),
    };
}

pub fn deinit(h: *Handler) void {
    h.stmts.deinit();
    h.fields.deinit(h.gpa);
    h.wire.deinit();
}

pub fn run(h: *Handler) !void {
    h.session = h.conn.openSession(.{ .dialect = h.proto.dialect }) catch |err| {
        // The first packet: what a client shows for "Too many
        // connections".
        switch (err) {
            error.TooManySessions => try h.sendError(1040, "Too many connections"),
            error.OutOfMemory => return error.OutOfMemory,
            else => try h.sendError(errors.unknown, "xqlite: cannot open the database"),
        }
        return h.wire.flush();
    };
    h.id = h.conn.ticket().id;
    // CONNECTION_ID(), for KILL.
    h.session.db.raw().xq.mariadb.connection_id = h.id;
    try h.proto.add(h.conn.io, h.gpa, h);
    defer h.proto.remove(h.conn.io, h.id);
    if (!try h.handshake()) return;
    while (!h.killed.load(.acquire)) {
        const msg = try h.wire.read();
        _ = h.proto.questions.fetchAdd(1, .monotonic);
        if (!try h.dispatch(msg)) return;
        try h.wire.flush();
    }
}

// ================================================================ handshake

/// The handshake and authentication: false if the client was refused
/// (the ERR sent).
fn handshake(h: *Handler) !bool {
    const scramble = auth.newScramble(h.conn.io);
    const b = h.wire.begin();
    const g = h.gpa;
    try packet.int1(g, b, 10);
    try packet.strNul(g, b, h.proto.version);
    try packet.int4(g, b, h.id);
    try b.appendSlice(g, scramble[0..8]);
    try packet.int1(g, b, 0);
    try packet.int2(g, b, @truncate(c.server_caps));
    try packet.int1(g, b, @intCast(c.Charset.utf8mb4));
    try packet.int2(g, b, h.status());
    try packet.int2(g, b, @truncate(c.server_caps >> 16));
    try packet.int1(g, b, auth.scramble_len + 1);
    try b.appendNTimes(g, 0, 10);
    try b.appendSlice(g, scramble[8..]);
    try packet.int1(g, b, 0);
    try packet.strNul(g, b, auth.plugin);
    try h.wire.send();
    try h.wire.flush();

    var r: packet.Reader = .{ .data = try h.wire.read() };
    const client_caps = r.int(u32) catch return h.refuse(1043, "Bad handshake");
    if (client_caps & c.Cap.protocol_41 == 0) return h.refuse(1043, "xqlite: the client must speak the 4.1 protocol");
    _ = r.int(u32) catch return h.refuse(1043, "Bad handshake"); // max packet
    _ = r.byte() catch return h.refuse(1043, "Bad handshake"); // charset: results are utf8mb4
    _ = r.bytes(23) catch return h.refuse(1043, "Bad handshake");
    if (client_caps & c.Cap.ssl != 0 and r.atEnd()) return h.refuse(1043, "xqlite: SSL is not supported (connect without it)");
    h.caps = client_caps & c.server_caps;
    h.multi_statements = h.caps & c.Cap.multi_statements != 0;
    var user_buf: [128]u8 = undefined;
    const user = copy(&user_buf, r.strNul());
    var response_buf: [256]u8 = undefined;
    const raw_response = if (client_caps & c.Cap.plugin_auth_lenenc_client_data != 0)
        r.lenencStr() catch return h.refuse(1043, "Bad handshake")
    else if (client_caps & c.Cap.secure_connection != 0) blk: {
        const n = r.byte() catch return h.refuse(1043, "Bad handshake");
        break :blk r.bytes(n) catch return h.refuse(1043, "Bad handshake");
    } else r.strNul();
    var response = copy(&response_buf, raw_response);
    var db_buf: [256]u8 = undefined;
    const db = if (client_caps & c.Cap.connect_with_db != 0) copy(&db_buf, r.strNul()) else "";
    const client_plugin = if (client_caps & c.Cap.plugin_auth != 0) r.strNul() else auth.plugin;

    if (h.proto.user) |want| if (!std.mem.eql(u8, user, want)) return h.denied(user, response.len > 0);
    if (h.proto.password) |password| {
        if (!std.mem.eql(u8, client_plugin, auth.plugin)) {
            // AuthSwitchRequest: the client answers with the response of
            // mysql_native_password to the same scramble.
            const s = h.wire.begin();
            try packet.int1(g, s, c.eof_header);
            try packet.strNul(g, s, auth.plugin);
            try s.appendSlice(g, &scramble);
            try packet.int1(g, s, 0);
            try h.wire.send();
            try h.wire.flush();
            response = copy(&response_buf, try h.wire.read());
        }
        if (!auth.check(password, &scramble, response)) return h.denied(user, response.len > 0);
    }
    if (db.len > 0 and !try h.use(db)) {
        try h.wire.flush();
        return false;
    }
    try h.sendOk(0, 0, "");
    try h.wire.flush();
    return true;
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn refuse(h: *Handler, number: u16, message: []const u8) !bool {
    try h.sendError(number, message);
    try h.wire.flush();
    return false;
}

fn denied(h: *Handler, user: []const u8, with_password: bool) !bool {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Access denied for user '{s}'@'%' (using password: {s})", .{
        user[0..@min(user.len, 64)],
        if (with_password) "YES" else "NO",
    }) catch unreachable;
    return h.refuse(1045, msg);
}

/// USE `db` (the handshake's database, COM_INIT_DB): false if it failed
/// (the ERR sent).
fn use(h: *Handler, db: []const u8) !bool {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(h.gpa);
    try sql.appendSlice(h.gpa, "USE `");
    for (db) |ch| {
        if (ch == '`') try sql.append(h.gpa, '`');
        try sql.append(h.gpa, ch);
    }
    try sql.append(h.gpa, '`');
    var silent: Silent = .{};
    try h.session.run(sql.items, &silent);
    if (silent.failure) |f| {
        try h.sendError(f.number, f.message.slice());
        return false;
    }
    return true;
}

/// A sink that keeps the first failure only (USE).
const Silent = struct {
    failure: ?struct { number: u16, message: Message } = null,

    const Message = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn slice(m: *const Message) []const u8 {
            return m.buf[0..m.len];
        }
    };

    pub fn columns(_: *Silent, _: []const Session.Column) !void {}
    pub fn row(_: *Silent, _: *Session.Row) !void {}
    pub fn complete(_: *Silent, _: Session.Complete) !void {}
    pub fn failed(s: *Silent, f: Session.Failure) !void {
        var m: Message = .{};
        m.len = copy(&m.buf, f.message).len;
        s.failure = .{ .number = errors.of(f).number, .message = m };
    }
};

// ================================================================= commands

/// One command: false if the connection ends.
fn dispatch(h: *Handler, msg: []const u8) !bool {
    if (msg.len == 0) {
        try h.sendError(1047, "Unknown command");
        return true;
    }
    var r: packet.Reader = .{ .data = msg, .pos = 1 };
    switch (@as(c.Com, @fromBackingInt(@intCast(msg[0])))) {
        .quit => return false,
        .query => return h.query(msg[1..]),
        .init_db => {
            if (try h.use(msg[1..])) try h.sendOk(0, 0, "");
        },
        .ping => try h.sendOk(0, 0, ""),
        .statistics => try h.statistics(),
        .process_kill => {
            const id = r.int(u32) catch return h.malformed();
            return h.kill(id, false);
        },
        .field_list => try h.fieldList(r.strNul()),
        .set_option => {
            const option = r.int(u16) catch return h.malformed();
            switch (option) {
                0 => h.multi_statements = true,
                1 => h.multi_statements = false,
                else => {
                    try h.sendError(1047, "Unknown command");
                    return true;
                },
            }
            try h.sendEnd(h.after(), 0);
        },
        .reset_connection => {
            try h.resetConnection();
            try h.sendOk(0, 0, "");
        },
        .stmt_prepare => try h.prepare(msg[1..]),
        .stmt_execute => {
            const id = r.int(u32) catch return h.malformed();
            const p = h.stmts.get(id) orelse return h.unknownStatement(id, "mysqld_stmt_execute");
            var results: Results = .{ .h = h, .binary = true };
            prepared.execute(p, &r, &results) catch |err| switch (err) {
                error.Malformed, error.Unbindable => {
                    try h.sendError(1210, "Incorrect arguments to mysqld_stmt_execute");
                    return true;
                },
                else => |e| return e,
            };
            try results.finish();
        },
        .stmt_send_long_data => {
            // No response, not even an error.
            const id = r.int(u32) catch return true;
            const param = r.int(u16) catch return true;
            if (h.stmts.get(id)) |p| try prepared.appendLongData(h.gpa, p, param, r.rest());
        },
        .stmt_close => {
            const id = r.int(u32) catch return true;
            h.stmts.close(id);
        },
        .stmt_reset => {
            const id = r.int(u32) catch return h.malformed();
            const p = h.stmts.get(id) orelse return h.unknownStatement(id, "mysqld_stmt_reset");
            prepared.reset(p);
            try h.sendOk(0, 0, "");
        },
        .stmt_fetch => try h.sendError(1235, "xqlite: cursors are not supported (COM_STMT_FETCH)"),
        .change_user => try h.sendError(1235, "xqlite: COM_CHANGE_USER is not supported"),
        .shutdown => try h.sendError(1227, "Access denied; you need (at least one of) the SHUTDOWN privilege(s) for this operation"),
        else => try h.sendError(1047, "Unknown command"),
    }
    return true;
}

fn malformed(h: *Handler) !bool {
    try h.sendError(1047, "Malformed packet");
    return true;
}

fn unknownStatement(h: *Handler, id: u32, what: []const u8) !bool {
    var buf: [128]u8 = undefined;
    try h.sendError(1243, std.fmt.bufPrint(&buf, "Unknown prepared statement handler ({d}) given to {s}", .{ id, what }) catch unreachable);
    return true;
}

fn query(h: *Handler, sql: []const u8) !bool {
    if (parseKill(sql)) |k| switch (k) {
        .id => |x| return h.kill(x.id, x.query_only),
        .query_id => {
            try h.sendError(1235, "xqlite: KILL QUERY ID is not supported (use KILL QUERY with the connection id)");
            return true;
        },
    };
    if (!h.multi_statements) if (secondStatement(sql)) |at| {
        try h.syntaxErrorNear(sql[at..]);
        return true;
    };
    var results: Results = .{ .h = h, .binary = false };
    try h.session.run(sql, &results);
    if (!results.sent and results.pending == null) {
        try h.sendError(1065, "Query was empty");
        return true;
    }
    try results.finish();
    return true;
}

/// MariaDB's error for a second statement where one is allowed.
fn syntaxErrorNear(h: *Handler, near: []const u8) !void {
    var buf: [256]u8 = undefined;
    try h.sendError(1064, std.fmt.bufPrint(&buf, "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '{s}' at line 1", .{near[0..@min(near.len, 80)]}) catch unreachable);
}

/// KILL `id`: false if this connection ends.
fn kill(h: *Handler, id: u32, query_only: bool) !bool {
    if (id == h.id) {
        if (query_only) {
            try h.sendError(1317, "Query execution was interrupted");
            return true;
        }
        try h.sendError(1927, "Connection was killed");
        return false;
    }
    switch (h.proto.kill(h.conn, id, query_only)) {
        .killed => try h.sendOk(0, 0, ""),
        .unknown => {
            var buf: [64]u8 = undefined;
            try h.sendError(1094, std.fmt.bufPrint(&buf, "Unknown thread id: {d}", .{id}) catch unreachable);
        },
    }
    return true;
}

fn statistics(h: *Handler) !void {
    const started = h.proto.started.load(.monotonic);
    const now = std.Io.Timestamp.now(h.conn.io, .awake).toMilliseconds();
    const uptime: u64 = @intCast(@max(@divTrunc(now - started, 1000), 1));
    const questions = h.proto.questions.load(.monotonic);
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Uptime: {d}  Threads: {d}  Questions: {d}  Slow queries: 0  Opens: 0  Open tables: 0  Queries per second avg: {d:.3}", .{
        uptime,
        h.proto.count(h.conn.io),
        questions,
        @as(f64, @floatFromInt(questions)) / @as(f64, @floatFromInt(uptime)),
    }) catch unreachable;
    try h.wire.sendBytes(text);
}

/// COM_RESET_CONNECTION: roll back, close the prepared statements, and
/// give the MariaDB session (sql_mode, user variables, current database,
/// warnings) its defaults.
fn resetConnection(h: *Handler) !void {
    if (h.session.db.inTransaction()) h.session.db.rollback() catch {};
    h.session.aborted = false;
    h.stmts.closeAll();
    const raw = h.session.db.raw();
    raw.xq.mariadb.deinit(raw.gpa);
    raw.xq.mariadb.connection_id = h.id;
    h.multi_statements = h.caps & c.Cap.multi_statements != 0;
}

/// COM_FIELD_LIST (deprecated): the column definitions of a table, with
/// their default (NULL here), then EOF.
fn fieldList(h: *Handler, table: []const u8) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(h.gpa);
    try sql.appendSlice(h.gpa, "SELECT * FROM `");
    for (table) |ch| {
        if (ch == '`') try sql.append(h.gpa, '`');
        try sql.append(h.gpa, ch);
    }
    try sql.appendSlice(h.gpa, "` LIMIT 0");
    var results: Results = .{ .h = h, .binary = false };
    const p = try h.session.prepare(sql.items, &results) orelse return;
    defer p.close();
    for (p.columns) |col| {
        const b = h.wire.begin();
        try cdef.writeDefinition(h.gpa, b, cdef.source(col.name, col.origin), h.fieldOf(col), true);
        try h.wire.send();
    }
    try h.sendEnd(h.after(), 0);
}

/// COM_STMT_PREPARE: one statement, described before it runs (the types
/// of its parameters and result columns as the statement gives them).
fn prepare(h: *Handler, sql: []const u8) !void {
    // One statement, even with CLIENT_MULTI_STATEMENTS.
    if (secondStatement(sql)) |at| return h.syntaxErrorNear(sql[at..]);
    var results: Results = .{ .h = h, .binary = true };
    const sp = try h.session.prepare(sql, &results) orelse return;
    if (sp.stmt == null) {
        sp.close();
        return h.sendError(1065, "Query was empty");
    }
    const p = h.stmts.add(sp) catch |err| {
        sp.close();
        return err;
    };
    const n_params = p.paramCount();
    const cols = p.prepared.columns;
    const n_cols = cols.len;
    const b = h.wire.begin();
    try packet.int1(h.gpa, b, c.ok_header);
    try packet.int4(h.gpa, b, p.id);
    try packet.int2(h.gpa, b, @intCast(@min(n_cols, std.math.maxInt(u16))));
    try packet.int2(h.gpa, b, @intCast(@min(n_params, std.math.maxInt(u16))));
    try packet.int1(h.gpa, b, 0);
    try packet.int2(h.gpa, b, h.warnings());
    try h.wire.send();
    if (n_params > 0) {
        for (0..n_params) |i| {
            const d = h.wire.begin();
            try cdef.writeDefinition(h.gpa, d, .{ .name = "?" }, prepared.paramField(p, i + 1), false);
            try h.wire.send();
        }
        if (!h.deprecateEof()) try h.sendEof(h.after(), 0);
    }
    if (n_cols > 0) {
        for (cols) |col| {
            const d = h.wire.begin();
            try cdef.writeDefinition(h.gpa, d, h.sourceOf(col), h.fieldOf(col), false);
            try h.wire.send();
        }
        if (!h.deprecateEof()) try h.sendEof(h.after(), 0);
    }
}

fn sourceOf(h: *Handler, col: Session.Column) cdef.Source {
    _ = h;
    return cdef.source(col.name, col.origin);
}

/// The field of a result column: its type, and for a table column the
/// flags of its constraints.
fn fieldOf(h: *Handler, col: Session.Column) cdef.Field {
    const f = cdef.field(col.type, col.type_name);
    const o = col.origin orelse return f;
    return cdef.withConstraints(f, h.session.db.columnConstraints(o.database, o.table, o.column));
}

// ================================================================ responses

fn deprecateEof(h: *const Handler) bool {
    return h.caps & c.Cap.deprecate_eof != 0;
}

/// The status flags after the last statement.
fn status(h: *Handler) u16 {
    var s: u16 = c.Status.autocommit;
    if (h.id != 0) {
        if (h.session.status() != .idle) s |= c.Status.in_trans;
        if (h.session.db.raw().xq.mariadb.sql_mode.has(.NO_BACKSLASH_ESCAPES)) s |= c.Status.no_backslash_escapes;
    }
    return s;
}

/// The warnings of the last statement (the MariaDB session's).
fn warnings(h: *Handler) u16 {
    if (h.session.dialect() != .mariadb) return 0;
    return @intCast(@min(h.session.db.raw().xq.mariadb.n_warnings, std.math.maxInt(u16)));
}

/// The status flags and the warning count after a statement.
const After = struct { status: u16, warnings: u16 };

fn after(h: *Handler) After {
    return .{ .status = h.status(), .warnings = if (h.id != 0) h.warnings() else 0 };
}

fn sendOk(h: *Handler, affected: u64, last_insert_id: u64, info: []const u8) !void {
    try h.sendOkWith(c.ok_header, affected, last_insert_id, h.after(), 0, info);
}

fn sendOkWith(h: *Handler, header: u8, affected: u64, last_insert_id: u64, a: After, more: u16, info: []const u8) !void {
    const b = h.wire.begin();
    try packet.int1(h.gpa, b, header);
    try packet.lenenc(h.gpa, b, affected);
    try packet.lenenc(h.gpa, b, last_insert_id);
    try packet.int2(h.gpa, b, a.status | more);
    try packet.int2(h.gpa, b, a.warnings);
    if (info.len > 0) try b.appendSlice(h.gpa, info);
    try h.wire.send();
}

/// The EOF packet (without DEPRECATE_EOF).
fn sendEof(h: *Handler, a: After, more: u16) !void {
    const b = h.wire.begin();
    try packet.int1(h.gpa, b, c.eof_header);
    try packet.int2(h.gpa, b, a.warnings);
    try packet.int2(h.gpa, b, a.status | more);
    try h.wire.send();
}

/// The end of a result set: EOF, or with DEPRECATE_EOF an OK packet with
/// the EOF header.
fn sendEnd(h: *Handler, a: After, more: u16) !void {
    if (h.deprecateEof()) return h.sendOkWith(c.eof_header, 0, 0, a, more, "");
    try h.sendEof(a, more);
}

fn sendError(h: *Handler, number: u16, message: []const u8) !void {
    const b = h.wire.begin();
    try packet.int1(h.gpa, b, c.err_header);
    try packet.int2(h.gpa, b, number);
    try packet.int1(h.gpa, b, '#');
    try b.appendSlice(h.gpa, errors.sqlstateOf(number));
    try b.appendSlice(h.gpa, message);
    try h.wire.send();
}

fn sendFailure(h: *Handler, f: Session.Failure) !void {
    const e = errors.of(f);
    const b = h.wire.begin();
    try packet.int1(h.gpa, b, c.err_header);
    try packet.int2(h.gpa, b, e.number);
    try packet.int1(h.gpa, b, '#');
    try b.appendSlice(h.gpa, e.sqlstate);
    try b.appendSlice(h.gpa, e.message orelse f.message);
    try h.wire.send();
}

/// The sink of Session.run(), Session.prepare() (its failure) and
/// prepared.execute(): each statement's
/// result set (text or binary rows) or OK packet, and the ERR of a
/// failed one. A statement's last packet waits for the next event, which
/// tells whether more results follow (SERVER_MORE_RESULTS_EXISTS).
const Results = struct {
    h: *Handler,
    binary: bool,
    /// The last packet of the statement before, not yet sent.
    pending: ?End = null,
    /// The statement being reported has a result set.
    in_result_set: bool = false,
    /// Something was sent.
    sent: bool = false,

    const End = struct {
        /// An OK packet, else the end of a result set.
        ok: bool,
        affected: u64 = 0,
        last_insert_id: u64 = 0,
        /// As the statement left them.
        after: After,
    };

    fn flushPending(r: *Results, more: bool) !void {
        const end = r.pending orelse return;
        r.pending = null;
        const flag: u16 = if (more) c.Status.more_results_exists else 0;
        if (end.ok) {
            try r.h.sendOkWith(c.ok_header, end.affected, end.last_insert_id, end.after, flag, "");
        } else try r.h.sendEnd(end.after, flag);
        r.sent = true;
    }

    pub fn finish(r: *Results) !void {
        try r.flushPending(false);
    }

    pub fn columns(r: *Results, cols: []const Session.Column) !void {
        try r.flushPending(true);
        const h = r.h;
        h.fields.clearRetainingCapacity();
        const b = h.wire.begin();
        try packet.lenenc(h.gpa, b, cols.len);
        try h.wire.send();
        for (cols) |col| {
            const f = h.fieldOf(col);
            try h.fields.append(h.gpa, f);
            const d = h.wire.begin();
            try cdef.writeDefinition(h.gpa, d, h.sourceOf(col), f, false);
            try h.wire.send();
        }
        if (!h.deprecateEof()) try h.sendEof(h.after(), 0);
        r.in_result_set = true;
        r.sent = true;
    }

    pub fn row(r: *Results, rw: *Session.Row) !void {
        const h = r.h;
        const viewer = h.session.dialect();
        const b = h.wire.begin();
        if (r.binary) {
            try packet.int1(h.gpa, b, 0);
            const n = h.fields.items.len;
            const bitmap_at = b.items.len;
            try b.appendNTimes(h.gpa, 0, (n + 7 + 2) / 8);
            for (h.fields.items, 0..) |f, i| {
                const cell: cdef.Cell = .{ .stmt = rw.stmt, .i = i };
                if (cdef.isNull(cell)) {
                    b.items[bitmap_at + (i + 2) / 8] |= @as(u8, 1) << @intCast((i + 2) % 8);
                    continue;
                }
                try cdef.writeBinary(h.gpa, b, viewer, f, cell);
            }
        } else {
            for (h.fields.items, 0..) |f, i| {
                try cdef.writeText(h.gpa, b, viewer, f, .{ .stmt = rw.stmt, .i = i });
            }
        }
        try h.wire.send();
    }

    pub fn complete(r: *Results, done: Session.Complete) !void {
        try r.flushPending(true);
        r.pending = .{
            .ok = !r.in_result_set,
            .affected = if (r.in_result_set) 0 else done.changes,
            .last_insert_id = if (!r.in_result_set and done.command.verb == .insert and done.changes > 0) @bitCast(done.last_insert_id) else 0,
            .after = r.h.after(),
        };
        r.in_result_set = false;
    }

    pub fn failed(r: *Results, f: Session.Failure) !void {
        try r.flushPending(true);
        try r.h.sendFailure(f);
        r.in_result_set = false;
        r.sent = true;
    }
};

// ==================================================================== text

const Kill = union(enum) {
    id: struct { id: u32, query_only: bool },
    /// KILL QUERY ID n: a query id, which xqlite does not have.
    query_id,
};

/// `KILL [HARD | SOFT] [CONNECTION | QUERY [ID]] n [;]`, which the
/// protocol runs itself (the dialect has no KILL); null for any other
/// text.
pub fn parseKill(sql: []const u8) ?Kill {
    var it = std.mem.tokenizeAny(u8, sql, " \t\r\n;");
    const first = it.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(first, "kill")) return null;
    var word = it.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(word, "hard") or std.ascii.eqlIgnoreCase(word, "soft")) word = it.next() orelse return null;
    var query_only = false;
    if (std.ascii.eqlIgnoreCase(word, "connection")) {
        word = it.next() orelse return null;
    } else if (std.ascii.eqlIgnoreCase(word, "query")) {
        query_only = true;
        word = it.next() orelse return null;
        if (std.ascii.eqlIgnoreCase(word, "id")) {
            _ = it.next() orelse return null;
            return if (it.next() == null) .query_id else null;
        }
    }
    const id = std.fmt.parseInt(u32, word, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .id = .{ .id = id, .query_only = query_only } };
}

/// Where a second statement starts in `sql`, if it has one: text after
/// a `;` outside quotes and comments. For a client without
/// CLIENT_MULTI_STATEMENTS, which MariaDB answers with a syntax error.
pub fn secondStatement(sql: []const u8) ?usize {
    var i: usize = 0;
    var after_semicolon = false;
    while (i < sql.len) {
        const ch = sql[i];
        if (ch == '#' or (ch == '-' and i + 2 <= sql.len and std.mem.startsWith(u8, sql[i..], "--") and (i + 2 == sql.len or std.ascii.isWhitespace(sql[i + 2])))) {
            i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
            continue;
        }
        if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, sql, i + 2, "*/") orelse sql.len;
            // An executable comment (/*! ... */) is code.
            if (after_semicolon and i + 2 < sql.len and sql[i + 2] == '!') return i;
            i = @min(end + 2, sql.len);
            continue;
        }
        if (std.ascii.isWhitespace(ch) or ch == ';') {
            if (ch == ';') after_semicolon = true;
            i += 1;
            continue;
        }
        if (after_semicolon) return i;
        if (ch == '\'' or ch == '"' or ch == '`') {
            i += 1;
            while (i < sql.len) : (i += 1) {
                if (sql[i] == '\\' and ch != '`') {
                    i += 1;
                    continue;
                }
                if (sql[i] == ch) {
                    if (i + 1 < sql.len and sql[i + 1] == ch) {
                        i += 1;
                        continue;
                    }
                    break;
                }
            }
        }
        i += 1;
    }
    return null;
}

test parseKill {
    const T = std.testing;
    try T.expectEqual(@as(u32, 7), parseKill("KILL 7").?.id.id);
    try T.expect(!parseKill("kill connection 7;").?.id.query_only);
    try T.expect(parseKill(" KILL HARD QUERY 12 ").?.id.query_only);
    try T.expect(parseKill("KILL QUERY ID 3").? == .query_id);
    try T.expectEqual(@as(?Kill, null), parseKill("KILL USER bob"));
    try T.expectEqual(@as(?Kill, null), parseKill("SELECT 1"));
    try T.expectEqual(@as(?Kill, null), parseKill("KILL 1; SELECT 2"));
}

test secondStatement {
    const T = std.testing;
    try T.expectEqual(@as(?usize, null), secondStatement("SELECT 1;"));
    try T.expectEqual(@as(?usize, null), secondStatement("SELECT ';x' ; -- y\n # z\n /* w */ ;"));
    try T.expectEqual(@as(?usize, 10), secondStatement("SELECT 1; SELECT 2"));
    try T.expectEqual(@as(?usize, null), secondStatement("SELECT 'a\\';b', `x;``y`"));
    try T.expectEqual(@as(?usize, null), secondStatement("SELECT 1 --x"));
}
