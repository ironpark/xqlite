//! Sequences, shared by PostgreSQL (CREATE SEQUENCE, SERIAL, IDENTITY)
//! and MariaDB (CREATE SEQUENCE, AUTO_INCREMENT): one row per sequence in
//! an ordinary table, created on demand:
//!
//!     CREATE TABLE xq_sequence(
//!       name TEXT PRIMARY KEY NOT NULL,
//!       last_value INTEGER NOT NULL, -- the last value handed out, or
//!                                    -- the next one while is_called=0
//!       start_value INTEGER NOT NULL,
//!       increment INTEGER NOT NULL,
//!       min_value INTEGER NOT NULL,
//!       max_value INTEGER NOT NULL,
//!       cycle INTEGER NOT NULL,      -- 0/1: wrap around at the end
//!       is_called INTEGER NOT NULL   -- 0/1: last_value was handed out
//!     )
//!
//! The semantics are PostgreSQL's (nextval/currval/setval/lastval), but
//! transactional: a value handed out by a transaction that rolls back is
//! handed out again (PostgreSQL never reuses one).
//!
//! Creating and dropping a sequence: code*() in a statement being
//! compiled, or create()/drop() now. The values: nextval() etc. now, or
//! the SQL functions `functions` lists, which the PostgreSQL and MariaDB
//! dialects register (Hooks.functions), from SQL or from an expression a
//! frontend builds with nextvalExpr() (the default of an identity
//! column). currval() and lastval() are per connection
//! (dialect.ConnState).

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const catalog = @import("catalog.zig");
const printf = @import("../sql/printf.zig");
const util = @import("../sql/util.zig");
const expr_mod = @import("../sql/expr.zig");
const main_mod = @import("../sql/main.zig");
const api = @import("../vdbe/api.zig");
const dfunc = @import("../dialect/func.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const Error = catalog.Error;

pub const table_name = "xq_sequence";

/// The CREATE TABLE of xq_sequence (%Q: the schema name).
pub const ddl = "CREATE TABLE IF NOT EXISTS %Q.xq_sequence(name TEXT PRIMARY KEY NOT NULL,last_value INTEGER NOT NULL,start_value INTEGER NOT NULL,increment INTEGER NOT NULL,min_value INTEGER NOT NULL,max_value INTEGER NOT NULL,cycle INTEGER NOT NULL,is_called INTEGER NOT NULL)";

/// CREATE SEQUENCE options; null is PostgreSQL's default.
pub const Options = struct {
    /// START WITH: min_value (ascending) or max_value (descending).
    start: ?i64 = null,
    /// INCREMENT BY, not 0.
    increment: i64 = 1,
    /// MINVALUE: 1 (ascending) or minInt(i64) (descending).
    min: ?i64 = null,
    /// MAXVALUE: maxInt(i64) (ascending) or -1 (descending).
    max: ?i64 = null,
    cycle: bool = false,
};

/// Options with every default filled in.
pub const Resolved = struct {
    start: i64,
    increment: i64,
    min: i64,
    max: i64,
    cycle: bool,
};

/// Fill in the defaults and check the options, as CREATE SEQUENCE does;
/// the error is PostgreSQL's message.
pub fn resolve(o: Options, msg: *[]const u8) ?Resolved {
    if (o.increment == 0) {
        msg.* = "INCREMENT must not be zero";
        return null;
    }
    const asc = o.increment > 0;
    const min: i64 = o.min orelse if (asc) 1 else std.math.minInt(i64);
    const max: i64 = o.max orelse if (asc) std.math.maxInt(i64) else -1;
    if (min >= max) {
        msg.* = "MINVALUE must be less than MAXVALUE";
        return null;
    }
    const start = o.start orelse if (asc) min else max;
    if (start < min) {
        msg.* = "START value cannot be less than MINVALUE";
        return null;
    }
    if (start > max) {
        msg.* = "START value cannot be greater than MAXVALUE";
        return null;
    }
    return .{ .start = start, .increment = o.increment, .min = min, .max = max, .cycle = o.cycle };
}

const insert_sql = "INSERT INTO %Q.xq_sequence VALUES(%Q,%lld,%lld,%lld,%lld,%lld,%d,0)";
const insert_or_ignore_sql = "INSERT OR IGNORE INTO %Q.xq_sequence VALUES(%Q,%lld,%lld,%lld,%lld,%lld,%d,0)";

fn insertArgs(schema: []const u8, name: []const u8, r: Resolved) [8]printf.Arg {
    return .{
        .{ .str = schema },      .{ .str = name },  .{ .int = r.start }, .{ .int = r.start },
        .{ .int = r.increment }, .{ .int = r.min }, .{ .int = r.max },   .{ .int = @intFromBool(r.cycle) },
    };
}

// ===================================================== code generation

/// CREATE SEQUENCE [IF NOT EXISTS] `name`, when the statement being
/// compiled runs. An existing sequence fails the statement (a UNIQUE
/// constraint error on xq_sequence.name) unless `if_not_exists`.
pub fn codeCreate(p: *Parse, schema: []const u8, name: []const u8, o: Options, if_not_exists: bool) void {
    var msg: []const u8 = "";
    const r = resolve(o, &msg) orelse return util.errorMsg(p, "{s}", .{msg});
    const args = insertArgs(schema, name, r);
    const fmt = if (if_not_exists) ddl ++ ";" ++ insert_or_ignore_sql else ddl ++ ";" ++ insert_sql;
    var all: [9]printf.Arg = undefined;
    all[0] = .{ .str = schema };
    @memcpy(all[1..], &args);
    catalog.codeExecFmt(p, schema, fmt, &all);
}

/// DROP SEQUENCE `name`, when the statement runs (nothing if there is
/// no such sequence).
pub fn codeDrop(p: *Parse, schema: []const u8, name: []const u8) void {
    if (!exists(p.db, schema)) return;
    catalog.codeExecFmt(p, schema, "DELETE FROM %Q.xq_sequence WHERE name=%Q", &.{ .{ .str = schema }, .{ .str = name } });
}

/// The expression nextval('name'), for the default value of an identity
/// column or an INSERT a frontend completes. Resolves in the PostgreSQL
/// and MariaDB dialects.
pub fn nextvalExpr(p: *Parse, name: []const u8) int.Oom!*int.Expr {
    const arg = try expr_mod.expr(p.arena, int.TK.STRING, name);
    const list = try expr_mod.listAppend(p, null, arg);
    return @import("../ir/ir.zig").expr.functionCall(p, "nextval", list);
}

/// Whether schema `schema` has the sequence table (as far as the schema
/// read so far knows).
pub fn exists(db: *Sqlite3, schema: []const u8) bool {
    return @import("../sql/build.zig").findTable(db, table_name, schema) != null;
}

// ============================================================== runtime

/// CREATE SEQUENCE now. error.Constraint if it exists and not
/// `if_not_exists`; error.Error for bad options (message in the
/// connection).
pub fn create(db: *Sqlite3, schema: []const u8, name: []const u8, o: Options, if_not_exists: bool) Error!void {
    var msg: []const u8 = "";
    const r = resolve(o, &msg) orelse {
        main_mod.errorWithMsg(db, int.RC.ERROR, "{s}", .{msg});
        return error.Error;
    };
    try catalog.execFmt(db, ddl, &.{.{ .str = schema }});
    const args = insertArgs(schema, name, r);
    try catalog.execFmt(db, if (if_not_exists) insert_or_ignore_sql else insert_sql, &args);
}

/// DROP SEQUENCE now; false if there was none.
pub fn drop(db: *Sqlite3, schema: []const u8, name: []const u8) Error!bool {
    if (!try catalog.tableExists(db, schema, table_name)) return false;
    try catalog.execFmt(db, "DELETE FROM %Q.xq_sequence WHERE name=%Q", &.{ .{ .str = schema }, .{ .str = name } });
    return db.n_change > 0;
}

/// The error of a call, left in the connection once its statements are
/// finalized (finalizing one clears the connection's error).
const Failure = struct {
    buf: [320]u8 = undefined,
    len: ?usize = null,

    fn set(f: *Failure, comptime fmt: []const u8, args: anytype) Error {
        f.len = if (std.fmt.bufPrint(&f.buf, fmt, args)) |z| z.len else |_| f.buf.len;
        return error.Error;
    }

    fn noSuchSequence(f: *Failure, name: []const u8) Error {
        return f.set("relation \"{s}\" does not exist", .{name});
    }

    fn report(f: *const Failure, db: *Sqlite3) void {
        if (f.len) |n| main_mod.errorWithMsg(db, int.RC.ERROR, "{s}", .{f.buf[0..n]});
    }
};

/// The sequence's next value (nextval()): one UPDATE, so that two
/// connections never get the same value.
pub fn nextval(db: *Sqlite3, schema: []const u8, name: []const u8) Error!i64 {
    var failure: Failure = .{};
    defer failure.report(db);
    if (!try catalog.tableExists(db, schema, table_name)) return failure.noSuchSequence(name);
    const q = try catalog.Query.initFmt(db,
        \\UPDATE %Q.xq_sequence SET is_called=1,last_value=CASE
        \\ WHEN is_called=0 THEN last_value
        \\ WHEN increment>0 AND last_value>max_value-increment THEN min_value
        \\ WHEN increment<0 AND last_value<min_value-increment THEN max_value
        \\ ELSE last_value+increment END
        \\WHERE name=?1 AND (is_called=0 OR cycle OR NOT(
        \\ (increment>0 AND last_value>max_value-increment) OR
        \\ (increment<0 AND last_value<min_value-increment)))
        \\RETURNING last_value
    , &.{.{ .str = schema }});
    defer q.deinit();
    try q.bindText(1, name);
    if (!try q.step()) {
        // No row: no such sequence, or at its end.
        const r = try catalog.Query.initFmt(db, "SELECT increment>0,max_value,min_value FROM %Q.xq_sequence WHERE name=?1", &.{.{ .str = schema }});
        defer r.deinit();
        try r.bindText(1, name);
        if (!try r.step()) return failure.noSuchSequence(name);
        if (api.columnInt64(r.v, 0) != 0) {
            return failure.set("nextval: reached maximum value of sequence \"{s}\" ({d})", .{ name, api.columnInt64(r.v, 1) });
        }
        return failure.set("nextval: reached minimum value of sequence \"{s}\" ({d})", .{ name, api.columnInt64(r.v, 2) });
    }
    const value = api.columnInt64(q.v, 0);
    while (try q.step()) {}
    try remember(db, name, value);
    return value;
}

/// currval(): the value nextval() last returned for the sequence on this
/// connection, or null if it has not been called.
pub fn currval(db: *Sqlite3, name: []const u8) ?i64 {
    return db.xq.currval.get(name);
}

/// lastval(): the value nextval() last returned on this connection, for
/// any sequence, or null.
pub fn lastval(db: *Sqlite3) ?i64 {
    const name = db.xq.last_sequence orelse return null;
    return db.xq.currval.get(name);
}

/// setval(): make `value` the last value handed out (is_called) or the
/// next one. Returns `value`.
pub fn setval(db: *Sqlite3, schema: []const u8, name: []const u8, value: i64, is_called: bool) Error!i64 {
    var failure: Failure = .{};
    defer failure.report(db);
    if (!try catalog.tableExists(db, schema, table_name)) return failure.noSuchSequence(name);
    const q = try catalog.Query.initFmt(db, "UPDATE %Q.xq_sequence SET last_value=?2,is_called=?3 WHERE name=?1 AND ?2 BETWEEN min_value AND max_value RETURNING 1", &.{.{ .str = schema }});
    defer q.deinit();
    try q.bindText(1, name);
    try q.bindInt(2, value);
    try q.bindInt(3, @intFromBool(is_called));
    if (!try q.step()) {
        const r = try catalog.Query.initFmt(db, "SELECT min_value,max_value FROM %Q.xq_sequence WHERE name=?1", &.{.{ .str = schema }});
        defer r.deinit();
        try r.bindText(1, name);
        if (!try r.step()) return failure.noSuchSequence(name);
        return failure.set("setval: value {d} is out of bounds for sequence \"{s}\" ({d}..{d})", .{
            value, name, api.columnInt64(r.v, 0), api.columnInt64(r.v, 1),
        });
    }
    while (try q.step()) {}
    if (is_called) try remember(db, name, value);
    return value;
}

/// Record `value` as the currval() of `name` and make it the lastval().
fn remember(db: *Sqlite3, name: []const u8, value: i64) Error!void {
    const s = &db.xq;
    const gop = s.currval.getOrPut(db.gpa, name) catch return oom(db);
    if (!gop.found_existing) {
        gop.key_ptr.* = db.gpa.dupe(u8, name) catch {
            s.currval.removeByPtr(gop.key_ptr);
            return oom(db);
        };
    }
    gop.value_ptr.* = value;
    if (s.last_sequence == null or !std.mem.eql(u8, s.last_sequence.?, name)) {
        const copy = db.gpa.dupe(u8, name) catch return oom(db);
        if (s.last_sequence) |old| db.gpa.free(old);
        s.last_sequence = copy;
    }
}

fn oom(db: *Sqlite3) Error {
    db.oomFault();
    return error.OutOfMemory;
}

// ======================================================== SQL functions

const Context = dfunc.Context;
const Mem = dfunc.Mem;

/// The functions on sequences of the main database, for the function
/// tables of the dialects: nextval(name), currval(name),
/// setval(name, value [, is_called]) and lastval(), with PostgreSQL's
/// errors. Not usable from the schema while trusted_schema is off.
pub const functions = [_]int.FuncDef{
    dfunc.scalar("nextval", 1, .{ .unsafe = true }, nextvalFunc),
    dfunc.scalar("currval", 1, .{ .unsafe = true }, currvalFunc),
    dfunc.scalar("setval", 2, .{ .unsafe = true }, setvalFunc),
    dfunc.scalar("setval", 3, .{ .unsafe = true }, setvalFunc),
    dfunc.scalar("lastval", 0, .{ .unsafe = true }, lastvalFunc),
};

/// Report the connection's error (left by a catalog call) as the error
/// of the function.
fn resultDbError(ctx: *Context, db: *Sqlite3, err: Error) void {
    if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
    api.resultError(ctx, main_mod.errmsg(db));
}

fn nameArg(ctx: *Context, argv: []*Mem) ?[]const u8 {
    return api.valueText(argv[0]) orelse {
        api.resultNull(ctx);
        return null;
    };
}

pub fn nextvalFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = nextval(db, catalog.main_schema, name) catch |err| return resultDbError(ctx, db, err);
    api.resultInt64(ctx, v);
}

pub fn currvalFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = nameArg(ctx, argv) orelse return;
    const v = currval(db, name) orelse {
        const msg = std.fmt.allocPrint(db.gpa, "currval of sequence \"{s}\" is not yet defined in this session", .{name}) catch return api.resultErrorNomem(ctx);
        defer db.gpa.free(msg);
        return api.resultError(ctx, msg);
    };
    api.resultInt64(ctx, v);
}

pub fn setvalFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = nameArg(ctx, argv) orelse return;
    if (api.valueType(argv[1]) == @import("../vdbe/vdbe_int.zig").SQLITE_NULL) return api.resultNull(ctx);
    const is_called = argv.len < 3 or api.valueInt64(argv[2]) != 0;
    const v = setval(db, catalog.main_schema, name, api.valueInt64(argv[1]), is_called) catch |err| return resultDbError(ctx, db, err);
    api.resultInt64(ctx, v);
}

pub fn lastvalFunc(ctx: *Context, _: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const v = lastval(db) orelse return api.resultError(ctx, "lastval is not yet defined in this session");
    api.resultInt64(ctx, v);
}
