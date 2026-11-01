//! One client of the PostgreSQL protocol: the startup and authentication,
//! then its simple and extended queries on its Session, until it leaves.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const wire = @import("wire.zig");
const values = @import("values.zig");
const auth = @import("auth.zig");
const pg = @import("root.zig");

const Allocator = std.mem.Allocator;
const Session = server.Session;
const Connection = server.Connection;
const Prepared = Session.Prepared;
const Column = Session.Column;
const Oid = values.Oid;
const Body = wire.Body;
const command = server.command;

const Backend = @This();

protocol: *pg.Protocol,
c: *Connection,
gpa: Allocator,
out: wire.Out,
in_buf: std.ArrayList(u8) = .empty,
session: *Session = undefined,
/// Prepared statements and portals by name ("" the unnamed ones).
statements: std.StringHashMapUnmanaged(*Statement) = .empty,
portals: std.StringHashMapUnmanaged(*Portal) = .empty,
/// An extended query message failed: the others are skipped up to Sync.
skipping: bool = false,
/// The text of the query being run (for an error's position).
query: []const u8 = "",
/// Per message: the parameters a Bind decodes.
scratch: std.heap.ArenaAllocator,
/// The column types of the statement of a simple query being sent.
col_types: std.ArrayList(xqlite.types.Type) = .empty,

/// A prepared statement (Parse).
const Statement = struct {
    prepared: *Prepared,
    /// Each parameter's OID: the client's, else the statement's type's,
    /// else text. At least as many as the statement has.
    oids: []Oid,
    /// What the client gave (0: unspecified), for reading text values.
    client_oids: []Oid,
    /// The portal that executes `prepared`, if any (another portal of the
    /// statement prepares a copy).
    user: ?*Portal = null,
};

/// A bound statement (Bind), executed by Execute.
const Portal = struct {
    /// Null once the statement is closed: the portal then owns `prepared`.
    statement: ?*Statement,
    prepared: *Prepared,
    owned: bool,
    /// Each column's type, OID and whether it is sent in the binary
    /// format.
    types: []xqlite.types.Type,
    oids: []Oid,
    binary: []bool,
    /// The execution ran to its end.
    done: bool = false,
};

pub fn serve(p: *pg.Protocol, c: *Connection) !void {
    var b: Backend = .{
        .protocol = p,
        .c = c,
        .gpa = c.gpa,
        .out = .{ .gpa = c.gpa, .w = c.out() },
        .scratch = .init(c.gpa),
    };
    defer b.deinit();
    if (!try b.startup()) return;
    try b.loop();
}

fn deinit(b: *Backend) void {
    var pit = b.portals.iterator();
    while (pit.next()) |e| {
        b.destroyPortal(e.value_ptr.*);
        b.gpa.free(e.key_ptr.*);
    }
    b.portals.deinit(b.gpa);
    var sit = b.statements.iterator();
    while (sit.next()) |e| {
        b.destroyStatement(e.value_ptr.*);
        b.gpa.free(e.key_ptr.*);
    }
    b.statements.deinit(b.gpa);
    b.col_types.deinit(b.gpa);
    b.scratch.deinit();
    b.in_buf.deinit(b.gpa);
    b.out.deinit();
}

fn flush(b: *Backend) !void {
    try b.c.out().flush();
}

// ================================================================ startup

const ssl_request = 80877103;
const gss_request = 80877104;
const cancel_request = 80877102;

/// The startup packet, authentication and the session: false if the
/// connection ends there (a cancel request, a failure reported).
fn startup(b: *Backend) !bool {
    var user: []const u8 = "";
    var database: []const u8 = "";
    var app_name: []const u8 = "";
    var options: []const u8 = "";
    // The packet's text, kept for the names above.
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(b.gpa);
    while (true) {
        const m = try wire.read(b.c.in(), b.gpa, &b.in_buf, true, wire.max_startup);
        var body: Body = .{ .rest = m.body };
        const code = try body.int(u32);
        switch (code) {
            // No TLS and no GSSAPI encryption: the client goes on in the
            // clear (or gives up).
            ssl_request, gss_request => {
                try b.c.out().writeByte('N');
                try b.flush();
                continue;
            },
            cancel_request => {
                const pid = try body.int(u32);
                const key = try body.int(u32);
                // Nothing is answered, whether it canceled or not.
                _ = b.c.registry.cancel(pid, key);
                return false;
            },
            else => {},
        }
        if (code >> 16 != 3) {
            try b.fatal("0A000", "unsupported frontend protocol {d}.{d}: server supports 3.0", .{ code >> 16, code & 0xffff });
            return false;
        }
        try packet.appendSlice(b.gpa, body.rest);
        var params: Body = .{ .rest = packet.items };
        var unknown: std.ArrayList([]const u8) = .empty;
        defer unknown.deinit(b.gpa);
        while (true) {
            const name = params.string() catch break;
            if (name.len == 0) break;
            const v = try params.string();
            if (std.mem.eql(u8, name, "user")) {
                user = v;
            } else if (std.mem.eql(u8, name, "database")) {
                database = v;
            } else if (std.mem.eql(u8, name, "application_name")) {
                app_name = v;
            } else if (std.mem.eql(u8, name, "options")) {
                options = v;
            } else if (std.mem.startsWith(u8, name, "_pq_.")) {
                try unknown.append(b.gpa, name);
            }
            // The other settings (client_encoding, DateStyle,
            // extra_float_digits ...) are ignored: the server's are
            // reported below.
        }
        // A newer minor version, or protocol options: we speak 3.0.
        if (code & 0xffff != 0 or unknown.items.len > 0) {
            try b.out.begin('v');
            try b.out.int(i32, 0);
            try b.out.int(i32, @intCast(unknown.items.len));
            for (unknown.items) |n| try b.out.string(n);
            try b.out.end();
        }
        break;
    }
    if (user.len == 0) {
        try b.fatal("28000", "no PostgreSQL user name specified in startup packet", .{});
        return false;
    }
    if (database.len == 0) database = user;
    if (!try b.authenticate(user)) return false;
    if (b.protocol.config.database) |want| if (!std.mem.eql(u8, want, database)) {
        try b.fatal("3D000", "database \"{s}\" does not exist", .{database});
        return false;
    };

    b.session = b.c.openSession(.{
        .dialect = .postgres,
        .abort_failed_transactions = true,
        .implicit_transactions = true,
    }) catch |err| switch (err) {
        error.TooManySessions => {
            try b.fatal(server.errors.too_many_connections, "sorry, too many clients already", .{});
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try b.fatal("58000", "could not open the database: {t}", .{err});
            return false;
        },
    };
    if (app_name.len > 0) try b.setStartup("application_name", app_name);
    if (!try b.applyOptions(options)) return false;

    const reported = [_]struct { []const u8, []const u8 }{
        .{ "server_version", b.protocol.config.server_version },
        .{ "server_encoding", "UTF8" },
        .{ "client_encoding", "UTF8" },
        .{ "DateStyle", "ISO, MDY" },
        .{ "integer_datetimes", "on" },
        .{ "standard_conforming_strings", "on" },
        .{ "TimeZone", "UTC" },
        .{ "IntervalStyle", "postgres" },
        .{ "is_superuser", "on" },
        .{ "session_authorization", user },
        .{ "application_name", app_name },
        .{ "default_transaction_read_only", "off" },
        .{ "in_hot_standby", "off" },
    };
    for (reported) |r| try b.parameterStatus(r[0], r[1]);
    const t = b.c.ticket();
    try b.out.begin('K');
    try b.out.int(u32, t.id);
    try b.out.int(u32, t.key);
    try b.out.end();
    try b.readyForQuery();
    return true;
}

fn parameterStatus(b: *Backend, name: []const u8, value: []const u8) !void {
    try b.out.begin('S');
    try b.out.string(name);
    try b.out.string(value);
    try b.out.end();
}

/// Run `SET name = 'value'` for a setting of the startup packet.
fn setStartup(b: *Backend, name: []const u8, value: []const u8) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(b.gpa);
    try sql.print(b.gpa, "SET {s} = '", .{name});
    for (value) |ch| {
        if (ch == '\'') try sql.append(b.gpa, '\'');
        try sql.append(b.gpa, ch);
    }
    try sql.append(b.gpa, '\'');
    var sink: StartupSink = .{};
    try b.session.run(sql.items, &sink);
    if (sink.bad) return error.BadStartupSetting;
}

const StartupSink = struct {
    bad: bool = false,
    pub fn columns(_: *StartupSink, _: []const Column) !void {}
    pub fn row(_: *StartupSink, _: *Session.Row) !void {}
    pub fn complete(_: *StartupSink, _: Session.Complete) !void {}
    pub fn failed(s: *StartupSink, _: Session.Failure) !void {
        s.bad = true;
    }
};

/// The `options` of the startup packet: `-c name=value` and
/// `--name=value`, each a SET. False if one failed (reported).
fn applyOptions(b: *Backend, options: []const u8) !bool {
    var words = std.mem.tokenizeAny(u8, options, " \t");
    while (words.next()) |w0| {
        var w = w0;
        if (std.mem.eql(u8, w, "-c")) {
            w = words.next() orelse break;
        } else if (std.mem.startsWith(u8, w, "--")) {
            w = w[2..];
        } else if (std.mem.startsWith(u8, w, "-c")) {
            w = w[2..];
        } else continue;
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse {
            try b.fatal("42601", "invalid command-line argument for server process: {s}", .{w0});
            return false;
        };
        var name_buf: [64]u8 = undefined;
        if (eq > name_buf.len) {
            try b.fatal("42704", "unrecognized configuration parameter \"{s}\"", .{w[0..eq]});
            return false;
        }
        const name = name_buf[0..eq];
        for (name, w[0..eq]) |*d, ch| d.* = if (ch == '-') '_' else ch;
        b.setStartup(name, w[eq + 1 ..]) catch |err| switch (err) {
            error.BadStartupSetting => {
                try b.fatal("42704", "invalid value for parameter \"{s}\": \"{s}\"", .{ name, w[eq + 1 ..] });
                return false;
            },
            else => return err,
        };
    }
    return true;
}

/// The authentication exchange of Protocol.config.auth; false if it
/// failed (reported).
fn authenticate(b: *Backend, user: []const u8) !bool {
    const a = b.protocol.config.auth;
    if (a.user) |u| if (!std.mem.eql(u8, u, user)) {
        try b.fatal("28000", "role \"{s}\" does not exist", .{user});
        return false;
    };
    switch (a.method) {
        .trust => {},
        .password => {
            try b.authRequest(3, "");
            const m = try b.passwordMessage() orelse return false;
            var body: Body = .{ .rest = m };
            const pw = body.string() catch m;
            if (!auth.eqlSecret(pw, a.password)) return b.authFailed(user);
        },
        .md5 => {
            var salt: [4]u8 = undefined;
            b.c.io.random(&salt);
            try b.authRequest(5, &salt);
            const m = try b.passwordMessage() orelse return false;
            var body: Body = .{ .rest = m };
            const got = body.string() catch m;
            const want = auth.md5Response(user, a.password, salt);
            if (!auth.eqlSecret(got, &want)) return b.authFailed(user);
        },
        .@"scram-sha-256" => {
            try b.authRequest(10, auth.mechanism ++ "\x00\x00");
            const first = try b.passwordMessage() orelse return false;
            var body: Body = .{ .rest = first };
            const mech = try body.string();
            if (!std.mem.eql(u8, mech, auth.mechanism)) {
                try b.fatal("08P01", "client selected an invalid SASL authentication mechanism", .{});
                return false;
            }
            const len = try body.int(i32);
            const data = if (len < 0) "" else try body.bytes(@intCast(len));
            var scram: auth.Scram = .{ .secret = &b.protocol.scram };
            var random: [18]u8 = undefined;
            b.c.io.random(&random);
            scram.start(data, random) catch |err| switch (err) {
                error.ChannelBinding => {
                    try b.fatal("08P01", "channel binding is not supported", .{});
                    return false;
                },
                else => {
                    try b.fatal("08P01", "malformed SCRAM message", .{});
                    return false;
                },
            };
            try b.authRequest(11, scram.serverFirst());
            const final = try b.passwordMessage() orelse return false;
            var sig: [64]u8 = undefined;
            const server_final = scram.finish(final, &sig) catch |err| switch (err) {
                error.AuthFailed => return b.authFailed(user),
                else => {
                    try b.fatal("08P01", "malformed SCRAM message", .{});
                    return false;
                },
            };
            try b.authRequest(12, server_final);
        },
    }
    try b.authRequest(0, "");
    return true;
}

fn authRequest(b: *Backend, code: i32, data: []const u8) !void {
    try b.out.begin('R');
    try b.out.int(i32, code);
    try b.out.bytes(data);
    try b.out.end();
    if (code != 0) try b.flush();
}

/// The body of the client's next message, which must be a password
/// message ('p'); null if it is not (reported).
fn passwordMessage(b: *Backend) !?[]const u8 {
    const m = try wire.read(b.c.in(), b.gpa, &b.in_buf, false, wire.max_startup);
    if (m.type != 'p') {
        try b.fatal("08P01", "expected password response, got message type {d}", .{m.type});
        return null;
    }
    return m.body;
}

fn authFailed(b: *Backend, user: []const u8) !bool {
    try b.fatal("28P01", "password authentication failed for user \"{s}\"", .{user});
    return false;
}

// ================================================================ the loop

fn loop(b: *Backend) !void {
    while (true) {
        const m = try wire.read(b.c.in(), b.gpa, &b.in_buf, false, wire.max_message);
        _ = b.scratch.reset(.retain_capacity);
        // The text of the last query is gone with the last message.
        b.query = "";
        if (b.skipping and m.type != 'S' and m.type != 'X') continue;
        var body: Body = .{ .rest = m.body };
        (switch (m.type) {
            'Q' => b.simpleQuery(&body),
            'P' => b.parse(&body),
            'B' => b.bind(&body),
            'D' => b.describe(&body),
            'E' => b.execute(&body),
            'C' => b.close(&body),
            'H' => b.flush(),
            'S' => b.sync(),
            'X' => return,
            'F' => {
                try b.errorResponse("ERROR", "0A000", "the function call protocol is not supported", null);
                try b.readyForQuery();
                continue;
            },
            // Copy messages outside a copy are ignored, as PostgreSQL does.
            'd', 'c', 'f' => continue,
            else => {
                try b.fatal("08P01", "invalid frontend message type {d}", .{m.type});
                return;
            },
        }) catch |err| switch (err) {
            error.BadMessage => {
                try b.fatal("08P01", "invalid message format", .{});
                return;
            },
            else => return err,
        };
    }
}

fn readyForQuery(b: *Backend) !void {
    try b.out.begin('Z');
    try b.out.int(u8, switch (b.session.status()) {
        .idle => 'I',
        .in_transaction => 'T',
        .aborted => 'E',
    });
    try b.out.end();
    try b.flush();
}

// =========================================================== simple query

fn simpleQuery(b: *Backend, body: *Body) !void {
    const sql = try body.string();
    // A simple query drops the unnamed statement and portal.
    b.dropPortal("");
    b.dropStatement("");
    b.query = sql;
    var sink: SimpleSink = .{ .b = b };
    try b.session.run(sql, &sink);
    if (!sink.any) try b.out.empty('I');
    try b.readyForQuery();
}

const SimpleSink = struct {
    b: *Backend,
    /// Anything reported (else the query was empty).
    any: bool = false,

    pub fn columns(s: *SimpleSink, cols: []const Column) !void {
        s.any = true;
        s.b.col_types.clearRetainingCapacity();
        for (cols) |c| try s.b.col_types.append(s.b.gpa, c.type);
        try s.b.rowDescription(cols, null);
    }

    pub fn row(s: *SimpleSink, r: *Session.Row) !void {
        try s.b.dataRow(r, s.b.col_types.items, null, null);
    }

    pub fn complete(s: *SimpleSink, c: Session.Complete) !void {
        s.any = true;
        try s.b.commandComplete(c);
    }

    pub fn failed(s: *SimpleSink, f: Session.Failure) !void {
        s.any = true;
        try s.b.failure(f);
    }

    pub fn notice(s: *SimpleSink, n: Session.Notice) !void {
        try s.b.errorResponse("WARNING", &n.sqlstate, n.message, null);
    }
};

// ========================================================= extended query

/// Reports of Parse and Execute: a failure skips to Sync.
const ExtendedSink = struct {
    b: *Backend,
    portal: ?*Portal = null,

    pub fn columns(s: *ExtendedSink, cols: []const Column) !void {
        // Describe sent them. A statement compiled again for a schema
        // change may have other columns: PostgreSQL's "cached plan must
        // not change result type", rather than rows the client was not
        // told of (and formats it did not choose).
        if (s.portal) |p| if (cols.len != p.types.len) return error.ResultChanged;
    }

    pub fn row(s: *ExtendedSink, r: *Session.Row) !void {
        const p = s.portal.?;
        if (r.len() != p.types.len) return error.ResultChanged;
        try s.b.dataRow(r, p.types, p.oids, p.binary);
    }

    pub fn complete(s: *ExtendedSink, c: Session.Complete) !void {
        try s.b.commandComplete(c);
    }

    pub fn failed(s: *ExtendedSink, f: Session.Failure) !void {
        try s.b.failure(f);
        s.b.skipping = true;
    }

    pub fn notice(s: *ExtendedSink, n: Session.Notice) !void {
        try s.b.errorResponse("WARNING", &n.sqlstate, n.message, null);
    }
};

/// An error of an extended query message of the server's own: reported,
/// and the rest skipped to Sync.
fn extendedError(b: *Backend, code: *const [5]u8, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    try b.errorResponse("ERROR", code, msg, null);
    b.skipping = true;
    // As a failed statement: the implicit transaction rolls back, an open
    // one fails.
    b.session.markFailed();
}

fn parse(b: *Backend, body: *Body) !void {
    const name = try body.string();
    const sql = try body.string();
    const n: usize = @intCast(@max(try body.int(i16), 0));
    const client_oids = try b.scratch.allocator().alloc(Oid, n);
    for (client_oids) |*o| o.* = try body.int(u32);
    if (name.len > 0 and b.statements.contains(name)) return b.extendedError("42P05", "prepared statement \"{s}\" already exists", .{name});
    if (name.len == 0) b.dropStatement("");
    b.query = sql;
    var sink: ExtendedSink = .{ .b = b };
    const prepared = try b.session.prepare(sql, &sink) orelse return;
    errdefer prepared.close();
    const count = @max(n, prepared.parameterCount());
    const st = try b.gpa.create(Statement);
    errdefer b.gpa.destroy(st);
    st.* = .{ .prepared = prepared, .oids = try b.gpa.alloc(Oid, count), .client_oids = undefined };
    errdefer b.gpa.free(st.oids);
    st.client_oids = try b.gpa.alloc(Oid, count);
    errdefer b.gpa.free(st.client_oids);
    for (st.oids, st.client_oids, 0..) |*o, *co, i| {
        co.* = if (i < n) client_oids[i] else 0;
        o.* = if (co.* != 0) co.* else if (prepared.parameterType(i + 1)) |t| values.ofType(t) else values.oid.text;
    }
    const key = try b.gpa.dupe(u8, name);
    errdefer b.gpa.free(key);
    try b.statements.put(b.gpa, key, st);
    try b.out.empty('1');
}

fn bind(b: *Backend, body: *Body) !void {
    const a = b.scratch.allocator();
    const portal_name = try body.string();
    const stmt_name = try body.string();
    const n_formats: usize = @intCast(@max(try body.int(i16), 0));
    const formats = try a.alloc(i16, n_formats);
    for (formats) |*f| f.* = try body.int(i16);
    const n_params: usize = @intCast(@max(try body.int(i16), 0));

    const st = b.statements.get(stmt_name) orelse return b.extendedError("26000", "prepared statement \"{s}\" does not exist", .{stmt_name});
    if (n_params != st.oids.len) return b.extendedError("08P01", "bind message supplies {d} parameters, but prepared statement \"{s}\" requires {d}", .{ n_params, stmt_name, st.oids.len });
    if (n_formats > 1 and n_formats != n_params) return b.extendedError("08P01", "bind message has {d} parameter formats but {d} parameters", .{ n_formats, n_params });
    if (portal_name.len > 0 and b.portals.contains(portal_name)) return b.extendedError("42P03", "portal \"{s}\" already exists", .{portal_name});
    if (portal_name.len == 0) b.dropPortal("");

    // The statement's own, unless another portal executes it.
    const owned = st.user != null;
    const prepared = if (owned) blk: {
        b.query = st.prepared.sql;
        var sink: ExtendedSink = .{ .b = b };
        break :blk try b.session.prepare(st.prepared.sql, &sink) orelse return;
    } else st.prepared;
    var keep = false;
    defer if (!keep) {
        if (owned) prepared.close() else prepared.reset();
    };

    const count = prepared.parameterCount();
    for (0..n_params) |i| {
        const len = try body.int(i32);
        const raw: ?[]const u8 = if (len < 0) null else try body.bytes(@intCast(len));
        const format = if (n_formats == 0) 0 else if (n_formats == 1) formats[0] else formats[i];
        const v: xqlite.Value = if (raw) |z| (if (format == 1)
            values.decodeBinary(a, st.oids[i], z)
        else
            values.decodeText(a, if (st.client_oids[i] != 0) values.typeOf(st.client_oids[i]) else prepared.parameterType(i + 1), z)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidText => return b.extendedError("22P02", "invalid input syntax for type {s}: \"{s}\"", .{ typeName(st.oids[i]), z }),
            error.InvalidBinary => return b.extendedError("22P03", "incorrect binary data format in bind parameter {d}", .{i + 1}),
            error.UnsupportedBinary => return b.extendedError("0A000", "the binary format is not supported for parameter {d} of type {s}", .{ i + 1, typeName(st.oids[i]) }),
        } else .null;
        if (i < count) prepared.bind(i + 1, v) catch return b.extendedError("08P01", "could not bind parameter {d}", .{i + 1});
    }

    const n_results: usize = @intCast(@max(try body.int(i16), 0));
    const cols = prepared.columns;
    if (n_results > 1 and n_results != cols.len) return b.extendedError("08P01", "bind message has {d} result formats but query has {d} columns", .{ n_results, cols.len });
    const portal = try b.gpa.create(Portal);
    errdefer b.gpa.destroy(portal);
    portal.* = .{ .statement = st, .prepared = prepared, .owned = owned, .types = try b.gpa.alloc(xqlite.types.Type, cols.len), .oids = undefined, .binary = undefined };
    errdefer b.gpa.free(portal.types);
    portal.oids = try b.gpa.alloc(Oid, cols.len);
    errdefer b.gpa.free(portal.oids);
    portal.binary = try b.gpa.alloc(bool, cols.len);
    errdefer b.gpa.free(portal.binary);
    var results: [1]i16 = .{0};
    var result_formats: []i16 = results[0..0];
    if (n_results > 0) {
        result_formats = try a.alloc(i16, n_results);
        for (result_formats) |*f| f.* = try body.int(i16);
    }
    for (cols, portal.types, portal.oids, portal.binary, 0..) |col, *t, *o, *bin, i| {
        t.* = col.type;
        o.* = values.ofType(col.type);
        const f = if (n_results == 0) 0 else if (n_results == 1) result_formats[0] else result_formats[i];
        bin.* = f == 1;
        if (bin.* and !values.binaryOut(o.*)) {
            b.gpa.free(portal.binary);
            b.gpa.free(portal.oids);
            b.gpa.free(portal.types);
            b.gpa.destroy(portal);
            return b.extendedError("0A000", "the binary format is not supported for column \"{s}\" of type {s}", .{ col.name, typeName(o.*) });
        }
    }
    const key = try b.gpa.dupe(u8, portal_name);
    errdefer b.gpa.free(key);
    try b.portals.put(b.gpa, key, portal);
    keep = true;
    if (!owned) st.user = portal;
    try b.out.empty('2');
}

fn describe(b: *Backend, body: *Body) !void {
    const kind = try body.byte();
    const name = try body.string();
    switch (kind) {
        'S' => {
            const st = b.statements.get(name) orelse return b.extendedError("26000", "prepared statement \"{s}\" does not exist", .{name});
            try b.out.begin('t');
            try b.out.int(i16, @intCast(st.oids.len));
            for (st.oids) |o| try b.out.int(u32, o);
            try b.out.end();
            if (st.prepared.columns.len == 0) try b.out.empty('n') else try b.rowDescription(st.prepared.columns, null);
        },
        'P' => {
            const p = b.portals.get(name) orelse return b.extendedError("34000", "portal \"{s}\" does not exist", .{name});
            if (p.prepared.columns.len == 0) try b.out.empty('n') else try b.rowDescription(p.prepared.columns, p.binary);
        },
        else => return b.extendedError("08P01", "invalid DESCRIBE message subtype {d}", .{kind}),
    }
}

fn execute(b: *Backend, body: *Body) !void {
    const name = try body.string();
    const max_rows: u64 = @intCast(@max(try body.int(i32), 0));
    const p = b.portals.get(name) orelse return b.extendedError("34000", "portal \"{s}\" does not exist", .{name});
    if (p.done) {
        // Run to its end already: nothing more.
        return b.commandComplete(.{ .command = p.prepared.command, .rows = 0, .changes = 0, .last_insert_id = 0 });
    }
    b.query = p.prepared.sql;
    var sink: ExtendedSink = .{ .b = b, .portal = p };
    const outcome = p.prepared.execute(max_rows, &sink) catch |err| switch (err) {
        error.Unencodable => {
            b.out.abandon();
            p.done = true;
            b.session.markFailed();
            return b.extendedError("22P03", "a value of the result cannot be sent in the binary format of its column's type", .{});
        },
        error.ResultChanged => {
            b.out.abandon();
            p.done = true;
            b.session.markFailed();
            return b.extendedError("0A000", "cached plan must not change result type", .{});
        },
        else => return err,
    };
    switch (outcome) {
        .suspended => try b.out.empty('s'),
        .complete, .failed => p.done = true,
        .empty => {
            p.done = true;
            try b.out.empty('I');
        },
    }
}

fn close(b: *Backend, body: *Body) !void {
    const kind = try body.byte();
    const name = try body.string();
    switch (kind) {
        'S' => b.dropStatement(name),
        'P' => b.dropPortal(name),
        else => return b.extendedError("08P01", "invalid CLOSE message subtype {d}", .{kind}),
    }
    try b.out.empty('3');
}

fn sync(b: *Backend) !void {
    b.skipping = false;
    // The end of the implicit transaction, or of none: the portals end
    // with it, as PostgreSQL's (not holdable) do.
    if (b.session.implicit or !b.session.db.inTransaction()) b.dropPortals();
    var sink: ExtendedSink = .{ .b = b };
    try b.session.sync(&sink);
    b.skipping = false;
    try b.readyForQuery();
}

fn dropStatement(b: *Backend, name: []const u8) void {
    const e = b.statements.fetchRemove(name) orelse return;
    b.gpa.free(e.key);
    b.destroyStatement(e.value);
}

fn destroyStatement(b: *Backend, st: *Statement) void {
    if (st.user) |p| {
        // The portal keeps executing it.
        p.owned = true;
        p.statement = null;
    } else st.prepared.close();
    b.gpa.free(st.oids);
    b.gpa.free(st.client_oids);
    b.gpa.destroy(st);
}

fn dropPortal(b: *Backend, name: []const u8) void {
    const e = b.portals.fetchRemove(name) orelse return;
    b.gpa.free(e.key);
    b.destroyPortal(e.value);
}

fn dropPortals(b: *Backend) void {
    var it = b.portals.iterator();
    while (it.next()) |e| {
        b.destroyPortal(e.value_ptr.*);
        b.gpa.free(e.key_ptr.*);
    }
    b.portals.clearRetainingCapacity();
}

fn destroyPortal(b: *Backend, p: *Portal) void {
    if (p.owned) p.prepared.close() else {
        p.prepared.reset();
        if (p.statement) |st| st.user = null;
    }
    b.gpa.free(p.types);
    b.gpa.free(p.oids);
    b.gpa.free(p.binary);
    b.gpa.destroy(p);
}

// ================================================================ messages

fn rowDescription(b: *Backend, cols: []const Column, binary: ?[]const bool) !void {
    try b.out.begin('T');
    try b.out.int(i16, @intCast(cols.len));
    for (cols, 0..) |c, i| {
        const o = values.ofType(c.type);
        try b.out.string(c.name);
        // The table's OID and the column's number: not known.
        try b.out.int(u32, 0);
        try b.out.int(i16, 0);
        try b.out.int(u32, o);
        try b.out.int(i16, values.typeLen(o));
        try b.out.int(i32, values.typeMod(c.type));
        try b.out.int(i16, if (binary) |bin| @intFromBool(bin[i]) else 0);
    }
    try b.out.end();
}

/// A DataRow of the current row, of columns of `types`, sent in text, or
/// in binary where `binary` says (with the columns' `oids`).
fn dataRow(b: *Backend, r: *Session.Row, types: []const xqlite.types.Type, oids: ?[]const Oid, binary: ?[]const bool) !void {
    try b.out.begin('D');
    const n = r.len();
    try b.out.int(i16, @intCast(n));
    for (0..n) |i| {
        const v = r.value(i) catch return error.OutOfMemory;
        const t: xqlite.types.Type = if (i < types.len) types[i] else .{ .logical = .unknown };
        if (v == .null) {
            try b.out.int(i32, -1);
        } else if (binary != null and binary.?[i]) {
            try values.writeBinary(&b.out, oids.?[i], t, v);
        } else try values.writeText(&b.out, t, v);
    }
    try b.out.end();
}

fn commandComplete(b: *Backend, c: Session.Complete) !void {
    try b.out.begin('C');
    switch (c.command.verb) {
        .select, .values => try b.out.print("SELECT {d}", .{c.rows}),
        .insert => try b.out.print("INSERT 0 {d}", .{c.changes}),
        .update => try b.out.print("UPDATE {d}", .{c.changes}),
        .delete => try b.out.print("DELETE {d}", .{c.changes}),
        .merge => try b.out.print("MERGE {d}", .{c.changes}),
        .truncate => try b.out.print("TRUNCATE TABLE", .{}),
        .execute => try b.out.print("CALL", .{}),
        else => try b.out.print("{f}", .{c.command}),
    }
    try b.out.string("");
    try b.out.end();
}

fn failure(b: *Backend, f: Session.Failure) !void {
    // PostgreSQL's position counts characters from 1.
    const pos: ?usize = if (f.offset) |o| if (o <= b.query.len) (std.unicode.utf8CountCodepoints(b.query[0..o]) catch o) + 1 else null else null;
    if (f.offset) |o| if (o + 5 <= b.query.len and std.ascii.eqlIgnoreCase(b.query[o..][0..4], "copy") and std.ascii.isWhitespace(b.query[o + 4])) {
        // COPY, which the dialect does not parse.
        return b.errorResponse("ERROR", "0A000", "COPY is not supported by this server", pos);
    };
    const message = if (f.code == .interrupt) "canceling statement due to user request" else f.message;
    try b.errorResponse("ERROR", &f.sqlstate, message, pos);
}

fn errorResponse(b: *Backend, severity: []const u8, code: *const [5]u8, message: []const u8, position: ?usize) !void {
    try b.out.begin(if (std.mem.eql(u8, severity, "ERROR") or std.mem.eql(u8, severity, "FATAL")) 'E' else 'N');
    for ([_]u8{ 'S', 'V' }) |k| {
        try b.out.int(u8, k);
        try b.out.string(severity);
    }
    try b.out.int(u8, 'C');
    try b.out.string(code);
    try b.out.int(u8, 'M');
    try b.out.string(message);
    if (position) |p| {
        try b.out.int(u8, 'P');
        try b.out.print("{d}", .{p});
        try b.out.string("");
    }
    try b.out.int(u8, 0);
    try b.out.end();
}

/// A FATAL error, sent at once: the connection ends.
fn fatal(b: *Backend, code: *const [5]u8, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    try b.errorResponse("FATAL", code, msg, null);
    try b.flush();
}

/// The name of a type OID, for messages.
fn typeName(o: Oid) []const u8 {
    return switch (o) {
        values.oid.bool => "boolean",
        values.oid.int2 => "smallint",
        values.oid.int4 => "integer",
        values.oid.int8 => "bigint",
        values.oid.float4 => "real",
        values.oid.float8 => "double precision",
        values.oid.numeric => "numeric",
        values.oid.bytea => "bytea",
        values.oid.date => "date",
        values.oid.time => "time without time zone",
        values.oid.timestamp => "timestamp without time zone",
        values.oid.timestamptz => "timestamp with time zone",
        values.oid.interval => "interval",
        values.oid.uuid => "uuid",
        values.oid.json => "json",
        values.oid.jsonb => "jsonb",
        values.oid.varchar => "character varying",
        values.oid.bpchar => "character",
        else => "text",
    };
}
