//! The functions on sequences in the extension: nextval(), currval(),
//! setval(), lastval() and their dialects' qualified names
//! (dialect/abi.zig's Sequence), on the sqlite3 connection itself.
//!
//! The engine's (catalog/sequence.zig) run SQL on the xqlite connection;
//! these run the same statements on the sqlite3 connection that called
//! them, on the same table (main.xq_sequence), with the same errors: a
//! value one engine hands out, the other never hands out again. currval()
//! and lastval() are per connection, as in xqlite (Session).

const std = @import("std");
const abi = @import("../dialect/abi.zig");
const c = @import("c.zig");
const root = @import("root.zig");

/// The catalogue's functions on sequences that the extension registers.
pub const functions = blk: {
    @setEvalBranchQuota(1_000_000);
    var n = 0;
    for (abi.catalogue) |e| {
        if (e.sequence != null) n += 1;
    }
    var all: [n]abi.Entry = undefined;
    var i = 0;
    for (abi.catalogue) |e| if (e.sequence != null) {
        all[i] = e;
        i += 1;
    };
    const final = all;
    break :blk final;
};

/// currval() of each sequence nextval() or setval() gave a value on the
/// connection, and the one lastval() reads (catalog/sequence.zig's
/// remember()).
pub const Session = struct {
    currval: std.StringHashMapUnmanaged(i64) = .empty,
    last: ?[]u8 = null,

    pub fn deinit(s: *Session, a: std.mem.Allocator) void {
        var it = s.currval.keyIterator();
        while (it.next()) |k| a.free(k.*);
        s.currval.deinit(a);
        if (s.last) |z| a.free(z);
        s.* = .{};
    }

    fn remember(s: *Session, a: std.mem.Allocator, name: []const u8, value: i64) error{OutOfMemory}!void {
        const gop = try s.currval.getOrPut(a, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = a.dupe(u8, name) catch |e| {
                s.currval.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = value;
        if (s.last == null or !std.mem.eql(u8, s.last.?, name)) {
            const copy = try a.dupe(u8, name);
            if (s.last) |old| a.free(old);
            s.last = copy;
        }
    }
};

const gpa = std.heap.c_allocator;

/// The C function of entry `e` (one of `functions`).
pub fn thunk(comptime e: *const abi.Entry) c.StepFn {
    return switch (e.sequence.?) {
        .nextval => nextvalCall,
        .currval => currvalCall,
        .setval => setvalCall,
        .lastval => lastvalCall,
        .lastval_of => lastvalOfCall,
    };
}

fn connOf(ctx: *c.sqlite3_context) *root.Conn {
    const b: *root.Bind = @ptrCast(@alignCast(c.xqe_user_data(ctx).?));
    return b.conn;
}

/// The error of a call; error.Failed once it is the result.
const Failed = error{Failed};

fn fail(ctx: *c.sqlite3_context, comptime fmt: []const u8, args: anytype) Failed {
    var buf: [320]u8 = undefined;
    const z = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    c.xqe_result_error(ctx, z.ptr, @intCast(z.len));
    return error.Failed;
}

fn failDb(ctx: *c.sqlite3_context, db: *c.sqlite3) Failed {
    const z = std.mem.span(c.xqe_errmsg(db));
    c.xqe_result_error(ctx, z.ptr, @intCast(z.len));
    return error.Failed;
}

/// A statement on the connection, finalized by deinit().
const Stmt = struct {
    s: *c.sqlite3_stmt,

    fn init(ctx: *c.sqlite3_context, db: *c.sqlite3, sql: []const u8) Failed!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.xqe_prepare(db, sql.ptr, @intCast(sql.len), &s) != c.SQLITE_OK) return failDb(ctx, db);
        return .{ .s = s.? };
    }

    fn deinit(st: Stmt) void {
        _ = c.xqe_finalize(st.s);
    }

    fn text(st: Stmt, i: c_int, z: []const u8) void {
        _ = c.xqe_bind_text(st.s, i, z.ptr, @intCast(z.len));
    }

    fn int(st: Stmt, i: c_int, v: i64) void {
        _ = c.xqe_bind_int64(st.s, i, v);
    }

    /// Whether there is a row.
    fn step(st: Stmt, ctx: *c.sqlite3_context, db: *c.sqlite3) Failed!bool {
        return switch (c.xqe_step(st.s)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => failDb(ctx, db),
        };
    }

    fn column(st: Stmt, i: c_int) i64 {
        return c.xqe_column_int64(st.s, i);
    }
};

/// catalog.tableExists(db, "main", "xq_sequence").
fn tableExists(ctx: *c.sqlite3_context, db: *c.sqlite3) Failed!bool {
    const q = try Stmt.init(ctx, db, "SELECT 1 FROM main.sqlite_schema WHERE type='table' AND name='xq_sequence' COLLATE NOCASE");
    defer q.deinit();
    return q.step(ctx, db);
}

fn noSuchSequence(ctx: *c.sqlite3_context, name: []const u8) Failed {
    return fail(ctx, "relation \"{s}\" does not exist", .{name});
}

/// The sequence name, the first argument; null (the result NULL) if it
/// is NULL.
fn nameArg(ctx: *c.sqlite3_context, argv: ?[*]?*c.sqlite3_value) ?[]const u8 {
    const v = argv.?[0].?;
    const z = c.xqe_value_text(v) orelse {
        c.xqe_result_null(ctx);
        return null;
    };
    return z[0..@intCast(c.xqe_value_bytes(v))];
}

/// catalog/sequence.zig's nextval(): one UPDATE, so that two
/// connections never get the same value.
fn nextval(ctx: *c.sqlite3_context, conn: *root.Conn, db: *c.sqlite3, name: []const u8) Failed!i64 {
    if (!try tableExists(ctx, db)) return noSuchSequence(ctx, name);
    const value = blk: {
        const q = try Stmt.init(ctx, db,
            \\UPDATE main.xq_sequence SET is_called=1,last_value=CASE
            \\ WHEN is_called=0 THEN last_value
            \\ WHEN increment>0 AND last_value>max_value-increment THEN min_value
            \\ WHEN increment<0 AND last_value<min_value-increment THEN max_value
            \\ ELSE last_value+increment END
            \\WHERE name=?1 AND (is_called=0 OR cycle OR NOT(
            \\ (increment>0 AND last_value>max_value-increment) OR
            \\ (increment<0 AND last_value<min_value-increment)))
            \\RETURNING last_value
        );
        defer q.deinit();
        q.text(1, name);
        if (try q.step(ctx, db)) {
            const v = q.column(0);
            while (try q.step(ctx, db)) {}
            break :blk v;
        }
        // No row: no such sequence, or at its end.
        const r = try Stmt.init(ctx, db, "SELECT increment>0,max_value,min_value FROM main.xq_sequence WHERE name=?1");
        defer r.deinit();
        r.text(1, name);
        if (!try r.step(ctx, db)) return noSuchSequence(ctx, name);
        if (r.column(0) != 0) return fail(ctx, "nextval: reached maximum value of sequence \"{s}\" ({d})", .{ name, r.column(1) });
        return fail(ctx, "nextval: reached minimum value of sequence \"{s}\" ({d})", .{ name, r.column(2) });
    };
    conn.seq.remember(gpa, name, value) catch {
        c.xqe_result_error_nomem(ctx);
        return error.Failed;
    };
    return value;
}

/// catalog/sequence.zig's setval().
fn setval(ctx: *c.sqlite3_context, conn: *root.Conn, db: *c.sqlite3, name: []const u8, value: i64, is_called: bool) Failed!i64 {
    if (!try tableExists(ctx, db)) return noSuchSequence(ctx, name);
    {
        const q = try Stmt.init(ctx, db, "UPDATE main.xq_sequence SET last_value=?2,is_called=?3 WHERE name=?1 AND ?2 BETWEEN min_value AND max_value RETURNING 1");
        defer q.deinit();
        q.text(1, name);
        q.int(2, value);
        q.int(3, @intFromBool(is_called));
        if (!try q.step(ctx, db)) {
            const r = try Stmt.init(ctx, db, "SELECT min_value,max_value FROM main.xq_sequence WHERE name=?1");
            defer r.deinit();
            r.text(1, name);
            if (!try r.step(ctx, db)) return noSuchSequence(ctx, name);
            return fail(ctx, "setval: value {d} is out of bounds for sequence \"{s}\" ({d}..{d})", .{ value, name, r.column(0), r.column(1) });
        }
        while (try q.step(ctx, db)) {}
    }
    if (is_called) conn.seq.remember(gpa, name, value) catch {
        c.xqe_result_error_nomem(ctx);
        return error.Failed;
    };
    return value;
}

fn nextvalCall(ctx_c: ?*c.sqlite3_context, _: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const ctx = ctx_c.?;
    const conn = connOf(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = nextval(ctx, conn, c.xqe_context_db_handle(ctx), name) catch return;
    c.xqe_result_int64(ctx, v);
}

fn currvalCall(ctx_c: ?*c.sqlite3_context, _: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const ctx = ctx_c.?;
    const conn = connOf(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = conn.seq.currval.get(name) orelse {
        _ = fail(ctx, "currval of sequence \"{s}\" is not yet defined in this session", .{name}) catch {};
        return;
    };
    c.xqe_result_int64(ctx, v);
}

fn setvalCall(ctx_c: ?*c.sqlite3_context, argc: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const ctx = ctx_c.?;
    const conn = connOf(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = argv.?[1].?;
    if (c.xqe_value_type(v) == c.SQLITE_NULL) return c.xqe_result_null(ctx);
    const is_called = argc < 3 or c.xqe_value_int64(argv.?[2].?) != 0;
    const r = setval(ctx, conn, c.xqe_context_db_handle(ctx), name, c.xqe_value_int64(v), is_called) catch return;
    c.xqe_result_int64(ctx, r);
}

fn lastvalCall(ctx_c: ?*c.sqlite3_context, _: c_int, _: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const ctx = ctx_c.?;
    const s = &connOf(ctx).seq;
    const v = if (s.last) |name| s.currval.get(name) else null;
    if (v) |x| return c.xqe_result_int64(ctx, x);
    const msg = "lastval is not yet defined in this session";
    c.xqe_result_error(ctx, msg, msg.len);
}

/// MariaDB's LASTVAL(seq): NULL rather than an error.
fn lastvalOfCall(ctx_c: ?*c.sqlite3_context, _: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const ctx = ctx_c.?;
    const conn = connOf(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = conn.seq.currval.get(name) orelse return c.xqe_result_null(ctx);
    c.xqe_result_int64(ctx, v);
}
