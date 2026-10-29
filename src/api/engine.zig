//! The seam between the public Zig API (src/api/*.zig) and the engine.
//!
//! This is the *only* file of the API layer that imports engine
//! internals. Everything else in src/api talks to the engine through the
//! functions and type aliases below, which follow the C API
//! (sqlite3_open_v2(), sqlite3_step(), sqlite3_column_*(), ...) but speak
//! the engine's error set, `Error`: the result code of each engine call
//! becomes an error here (int.check()), while the connection keeps the
//! extended code and the message, as in C.
//!
//! Callbacks that the engine calls (functions, collations, modules) are
//! C-shaped, with a `void*` context. The API builds them with the
//! engine's typed helpers re-exported here (destructor(), withUserData(),
//! Module.constructor(), thunk() ...), so no cast from `void*` is written
//! by hand above this file.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");
const legacy = @import("../sql/legacy.zig");
const prepare_mod = @import("../sql/prepare.zig");
const api = @import("../vdbe/api.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const callback = @import("../sql/callback.zig");
const coll = @import("../sql/coll.zig");
const vtab = @import("../sql/vtab.zig");
const sql_func = @import("../sql/func.zig");
const util = @import("../sql/util.zig");
const printf = @import("../sql/printf.zig");
const tokenize = @import("../parse/tokenize.zig");
const TK = @import("../parse/grammar.zig").TK;
const thunk_mod = @import("../util/thunk.zig");

pub const Vfs = @import("../vfs/vfs.zig").Vfs;
pub const MemVfs = @import("../vfs/mem.zig").MemVfs;
pub const UnixVfs = @import("../vfs/unix.zig").UnixVfs;
/// PRAGMA journal_mode values.
pub const JournalMode = @import("../pager/pager.zig").JournalMode;

/// A connection (sqlite3*).
pub const Handle = int.Sqlite3;
/// A prepared statement (sqlite3_stmt*).
pub const Vm = vi.Vdbe;
/// A value (sqlite3_value*): a function argument or a column.
pub const Mem = vi.Mem;
/// The context of a function call (sqlite3_context*).
pub const Context = vi.Context;

/// The errors of the engine, one per result code (see int.Error).
pub const Error = int.Error;
/// The result codes (SQLITE_OK ...), primary and extended.
pub const RC = int.RC;
/// The error of a result code that is not OK.
pub const codeError = int.codeError;
/// The result code of an error, for C-shaped callbacks that return one.
pub const errorCode = int.errorCode;

/// Fundamental datatypes (SQLITE_INTEGER ...).
pub const type_integer = vi.SQLITE_INTEGER;
pub const type_float = vi.SQLITE_FLOAT;
pub const type_text = vi.SQLITE_TEXT;
pub const type_blob = vi.SQLITE_BLOB;

/// The English text of a result code (sqlite3_errstr()).
pub fn errStr(code: i32) [:0]const u8 {
    return util.errStr(code);
}

// ============================================================ connection

pub const OpenFlags = main_mod.OpenFlags;

/// sqlite3_open_v2(). `out` receives the connection, which must be
/// closed even if opening failed; it stays null only if the connection
/// object itself could not be allocated.
pub fn open(v: Vfs, path: []const u8, flags: OpenFlags, out: *?*Handle) Error!void {
    return int.check(main_mod.open(v, path, flags, out));
}

/// sqlite3_close(): error.Busy while statements are not finalized.
pub fn close(h: *Handle) Error!void {
    return int.check(main_mod.close(h));
}

/// sqlite3_exec() without a callback.
pub fn exec(h: *Handle, sql: []const u8) Error!void {
    return int.check(legacy.exec(h, sql, null, null, null));
}

/// sqlite3_prepare_v2(): the statement, or null if `sql` holds none;
/// `tail` receives the text after it.
pub fn prepare(h: *Handle, sql: []const u8, tail: *[]const u8) Error!?*Vm {
    var vm: ?*Vm = null;
    try int.check(prepare_mod.prepareV2(h, sql, &vm, tail));
    return vm;
}

/// Whether `sql` holds no token but white space, comments and
/// semicolons, by the rules of the SQL tokenizer.
pub fn onlyTrivia(gpa: std.mem.Allocator, sql: []const u8) error{OutOfMemory}!bool {
    if (sql.len == 0) return true;
    // The tokenizer reads NUL-terminated text.
    var buf: [256]u8 = undefined;
    const z: [:0]const u8 = if (sql.len < buf.len) blk: {
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;
        break :blk buf[0..sql.len :0];
    } else try gpa.dupeSentinel(u8, sql, 0);
    defer if (z.ptr != &buf) gpa.free(z);
    var i: usize = 0;
    while (i < z.len) {
        const t = tokenize.getToken(z[i..].ptr);
        switch (t.tk) {
            TK.SPACE, TK.COMMENT, TK.SEMI => i += t.len,
            else => return false,
        }
    }
    return true;
}

pub fn extendedErrcode(h: *const Handle) i32 {
    return main_mod.extendedErrcode(h);
}

pub fn errmsg(h: *Handle) [:0]const u8 {
    return main_mod.errmsg(h);
}

pub fn errorOffset(h: *const Handle) i32 {
    return main_mod.errorOffset(h);
}

/// Set the error of the connection to `code` with a formatted message
/// (sqlite3ErrorWithMsg()). The error offset is cleared, and if the
/// message cannot be allocated the connection reports the English text
/// of `code` rather than an older message.
pub fn setError(h: *Handle, code: i32, comptime fmt: []const u8, args: anytype) void {
    main_mod.setError(h, code);
    main_mod.errorWithMsg(h, code, fmt, args);
}

/// The error of a connection (code, message and offset), taken out of
/// it by saveError() and put back by restoreError(). The message is
/// moved, not copied, so it is kept whole and saving cannot fail.
pub const SavedError = struct {
    code: i32,
    offset: i32,
    message: ?*Mem,
};

/// Take the error of `h` out of the connection: calls made until
/// restoreError() start from a connection without a message.
pub fn saveError(h: *Handle) SavedError {
    const s: SavedError = .{ .code = h.err_code, .offset = h.err_byte_offset, .message = h.err };
    h.err = null;
    return s;
}

/// Make `s` the error of `h` again, dropping any error set since
/// saveError().
pub fn restoreError(h: *Handle, s: SavedError) void {
    if (h.err) |e| {
        mem.release(e);
        h.gpa.destroy(e);
    }
    h.err = s.message;
    h.err_code = s.code;
    h.err_byte_offset = s.offset;
}

pub fn lastInsertRowid(h: *const Handle) i64 {
    return main_mod.lastInsertRowid(h);
}

pub fn changes(h: *const Handle) i64 {
    return api.changes(h);
}

pub fn totalChanges(h: *const Handle) i64 {
    return api.totalChanges(h);
}

pub fn autocommit(h: *const Handle) bool {
    return main_mod.getAutocommit(h);
}

pub fn busyTimeout(h: *Handle, ms: i32) void {
    _ = main_mod.busyTimeout(h, ms);
}

/// The SQL dialects.
pub const Dialect = @import("../dialect/dialect.zig").Dialect;

/// xqlite: the dialect of the statements prepared from now on.
pub fn setDialect(h: *Handle, d: Dialect) void {
    main_mod.setDialect(h, d);
}

pub fn getDialect(h: *const Handle) Dialect {
    return main_mod.getDialect(h);
}

/// sqlite3_db_config(SQLITE_DBCONFIG_ENABLE_FKEY).
pub fn setForeignKeys(h: *Handle, on: bool) void {
    _ = main_mod.dbConfig(h, .enable_fkey, @intFromBool(on));
}

/// One argument of printSql().
pub const PrintArg = printf.Arg;

/// Render `fmt` with SQLite's printf (%w, %q ...) into `buf`; null if it
/// does not fit, or if `gpa` (for the temporary buffer of a long %w or
/// %q argument) is out of memory.
pub fn printSql(gpa: std.mem.Allocator, buf: []u8, fmt: []const u8, args: []const PrintArg) ?[]const u8 {
    var acc = printf.StrAccum.init(gpa, buf, 0);
    acc.appendf(fmt, args);
    if (acc.acc_error != 0) return null;
    return acc.slice();
}

// ============================================================= statement

/// sqlite3_step(): true for a row, false once the statement is done.
pub fn step(v: *Vm) Error!bool {
    return switch (api.step(v)) {
        RC.ROW => true,
        RC.DONE => false,
        else => |r| int.codeError(r),
    };
}

/// sqlite3_reset(). Its result, the error of the last step, has already
/// been reported by step().
pub fn reset(v: *Vm) void {
    _ = api.reset(v);
}

/// sqlite3_finalize(). As for reset(), the result is not needed.
pub fn finalize(v: *Vm) void {
    _ = api.finalize(v);
}

pub fn clearBindings(v: *Vm) void {
    api.clearBindings(v);
}

/// sqlite3_sql(): the text of the statement.
pub fn sqlText(v: *const Vm) ?[]const u8 {
    return v.sql;
}

/// sqlite3_stmt_readonly().
pub fn stmtReadonly(v: *const Vm) bool {
    return v.read_only;
}

/// How many times the statement has been compiled again after a schema
/// change (sqlite3_stmt_status(SQLITE_STMTSTATUS_REPREPARE)): its result
/// columns may have changed when this does.
pub fn reprepareCount(v: *const Vm) u32 {
    return v.counters[vi.STMTSTATUS.REPREPARE];
}

pub fn bindNull(v: *Vm, i: usize) Error!void {
    return int.check(api.bindNull(v, i));
}

pub fn bindInt64(v: *Vm, i: usize, x: i64) Error!void {
    return int.check(api.bindInt64(v, i, x));
}

pub fn bindDouble(v: *Vm, i: usize, x: f64) Error!void {
    return int.check(api.bindDouble(v, i, x));
}

/// The text is copied (SQLITE_TRANSIENT).
pub fn bindText(v: *Vm, i: usize, x: []const u8) Error!void {
    return int.check(api.bindText(v, i, x));
}

/// The blob is copied (SQLITE_TRANSIENT).
pub fn bindBlob(v: *Vm, i: usize, x: []const u8) Error!void {
    return int.check(api.bindBlob(v, i, x));
}

pub fn bindZeroblob(v: *Vm, i: usize, n: i32) Error!void {
    return int.check(api.bindZeroblob(v, i, n));
}

pub fn bindParameterCount(v: *const Vm) usize {
    return api.bindParameterCount(v);
}

/// 0 if there is no parameter of that name (prefix included).
pub fn bindParameterIndex(v: *const Vm, name: []const u8) usize {
    return api.bindParameterIndex(v, name);
}

pub fn bindParameterName(v: *const Vm, i: usize) ?[]const u8 {
    return api.bindParameterName(v, i);
}

pub fn columnCount(v: *const Vm) usize {
    return api.columnCount(v);
}

pub fn columnName(v: *Vm, i: usize) ?[:0]const u8 {
    return api.columnName(v, i);
}

pub fn columnDecltype(v: *Vm, i: usize) ?[:0]const u8 {
    return api.columnDecltype(v, i);
}

pub fn columnType(v: *Vm, i: usize) i32 {
    return api.columnType(v, i);
}

pub fn columnInt64(v: *Vm, i: usize) i64 {
    return api.columnInt64(v, i);
}

pub fn columnDouble(v: *Vm, i: usize) f64 {
    return api.columnDouble(v, i);
}

pub fn columnText(v: *Vm, i: usize) ?[:0]const u8 {
    return api.columnText(v, i);
}

pub fn columnBlob(v: *Vm, i: usize) ?[]const u8 {
    return api.columnBlob(v, i);
}

// ================================================================ values

pub fn valueType(m: *const Mem) i32 {
    return api.valueType(m);
}

pub fn valueInt64(m: *Mem) i64 {
    return api.valueInt64(m);
}

pub fn valueDouble(m: *Mem) f64 {
    return api.valueDouble(m);
}

pub fn valueText(m: *Mem) ?[:0]const u8 {
    return api.valueText(m);
}

pub fn valueBlob(m: *Mem) ?[]const u8 {
    return api.valueBlob(m);
}

// ======================================================= typed callbacks

/// A C-shaped destructor (`void(*)(void*)`): xDestroy.
pub const DestructorFn = int.DestructorFn;
/// The DestructorFn of a typed destructor `fn (*T) void`.
pub const destructor = int.destructor;
/// The C-shaped function of type `Fn` that calls `f`, a function taking
/// the `void*` context of `Fn` typed (thunk.thunk()).
pub const thunk = thunk_mod.thunk;
/// A context pointer, maybe to const, as a C-shaped `void*`.
pub const eraseConst = thunk_mod.eraseConst;

// ============================================================= functions

/// A scalar function or aggregate step (xFunc / xStep).
pub const StepFn = int.FuncDef.StepFn;
/// An aggregate finalizer or window xValue.
pub const FinalFn = int.FuncDef.FinalFn;
/// The StepFn of `f` (`fn (*Context, []*Mem, data: *T) void`), which
/// takes the user data of its function typed. Register it with
/// userDataFor(f, data).
pub const withUserData = int.FuncDef.withUserData;
pub const userDataFor = int.FuncDef.userDataFor;

/// The user data of the function `ctx` calls, registered with
/// withUserData(f), as `f` takes it: for an xFinal or xValue (which have
/// no typed form of their own) of the function whose step is `f`.
pub fn userDataOf(ctx: *const Context, comptime f: anytype) int.FuncDef.UserData(f) {
    return ctx.func.userDataOf(f);
}

/// The aggregate context of `ctx` as a `T` (sqlite3_aggregate_context()),
/// zeroed on the first call of a group; null if out of memory. 8-byte
/// aligned.
pub fn aggContext(comptime T: type, ctx: *Context) ?*T {
    return sql_func.aggContext(T, ctx, true);
}

/// Options of an application-defined function (the flags of
/// sqlite3_create_function_v2()).
pub const FunctionFlags = struct {
    /// The function always gives the same result for the same arguments
    /// (SQLITE_DETERMINISTIC), so it may be used in indexes and CHECK
    /// constraints, and calls with constant arguments may be folded.
    deterministic: bool = false,
    /// Only callable from top-level SQL, not from views, triggers or
    /// schema structures (SQLITE_DIRECTONLY).
    direct_only: bool = false,
    /// Safe to call from schema structures even with trusted_schema off
    /// (SQLITE_INNOCUOUS).
    innocuous: bool = false,
};

/// sqlite3_create_window_function() (and sqlite3_create_function_v2()):
/// a scalar function if `x_final` is null, else an aggregate whose step
/// is `x_func` (a window aggregate with `x_value` and `x_inverse` too).
/// `x_destroy` runs on `user_data` when the function is replaced or the
/// connection closes, or at once if registration fails.
pub fn createFunction(
    h: *Handle,
    name: []const u8,
    n_arg: i32,
    flags: FunctionFlags,
    user_data: ?*anyopaque,
    x_func: StepFn,
    x_final: ?FinalFn,
    x_value: ?FinalFn,
    x_inverse: ?StepFn,
    x_destroy: ?DestructorFn,
) Error!void {
    var fn_flags: callback.FUNC = .{};
    if (flags.deterministic) fn_flags.set(callback.FNFLAG.DETERMINISTIC);
    if (flags.direct_only) fn_flags.set(callback.FNFLAG.DIRECTONLY);
    if (flags.innocuous) fn_flags.set(callback.FNFLAG.INNOCUOUS);
    return int.check(callback.createFunctionV2(h, name, n_arg, vi.ENC.UTF8 | fn_flags.int(), user_data, x_func, x_final, x_value, x_inverse, x_destroy));
}

pub fn resultNull(ctx: *Context) void {
    api.resultNull(ctx);
}

pub fn resultInt64(ctx: *Context, x: i64) void {
    api.resultInt64(ctx, x);
}

pub fn resultDouble(ctx: *Context, x: f64) void {
    api.resultDouble(ctx, x);
}

/// The text is copied.
pub fn resultText(ctx: *Context, x: []const u8) void {
    api.resultText(ctx, x, .transient);
}

/// The blob is copied.
pub fn resultBlob(ctx: *Context, x: []const u8) void {
    api.resultBlob(ctx, x, .transient);
}

pub fn resultZeroblob(ctx: *Context, n: u64) void {
    api.resultZeroblob(ctx, n);
}

/// Fail the function with `msg` (copied).
pub fn resultError(ctx: *Context, msg: []const u8) void {
    api.resultError(ctx, msg);
}

pub fn resultErrorNomem(ctx: *Context) void {
    api.resultErrorNomem(ctx);
}

pub fn resultErrorTooBig(ctx: *Context) void {
    api.resultErrorTooBig(ctx);
}

// ============================================================ collations

/// A collation (xCompare), with its `void*` context first.
pub const CollationFn = int.CollSeq.CmpFn;

/// sqlite3_create_collation(). The name is copied.
pub fn createCollation(h: *Handle, name: []const u8, user: ?*anyopaque, cmp: CollationFn) Error!void {
    return int.check(main_mod.apiExit(h, coll.createCollation(h, name, user, cmp)));
}

// ======================================================== virtual tables

/// sqlite3_module. Make the constructors with Module.constructor(f) and
/// register the module with Module.auxFor(f, aux).
pub const Module = vtab.Module;
pub const Vtab = vtab.Vtab;
pub const VtabCursor = vtab.VtabCursor;
pub const IndexInfo = vtab.IndexInfo;
pub const index_constraint_eq = vtab.INDEX_CONSTRAINT.EQ;

/// sqlite3_create_module_v2(). `x_destroy` runs on `aux` at once if
/// registration fails.
pub fn createModule(h: *Handle, name: []const u8, module: *const Module, aux: ?*anyopaque, x_destroy: ?DestructorFn) Error!void {
    return int.check(vtab.createModuleV2(h, name, module, aux, x_destroy));
}

/// sqlite3_declare_vtab().
pub fn declareVtab(h: *Handle, create_table: [:0]const u8) Error!void {
    return int.check(vtab.declareVtab(h, create_table));
}

/// Report `msg` as the error of a virtual table method.
pub fn setVtabError(h: *Handle, t: *Vtab, msg: []const u8) void {
    vtab.setErrMsg(h, t, "{s}", .{msg});
}

/// The connection's allocator, which the core uses to free strings that
/// modules hand it.
pub fn connAllocator(h: *Handle) std.mem.Allocator {
    return h.gpa;
}
