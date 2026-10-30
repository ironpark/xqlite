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
const backup_mod = @import("../sql/backup.zig");
const blob_mod = @import("../vdbe/blob.zig");
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

pub const Vfs = @import("xqlite_vfs").vfs.Vfs;
pub const MemVfs = @import("xqlite_vfs").mem.MemVfs;
/// The file-system VFS of the target (UnixVfs, WasiVfs or HostVfs).
pub const OsVfs = @import("xqlite_vfs").vfs.OsVfs;
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

// ================================================================ backup

/// An online backup (sqlite3_backup*).
pub const BackupHandle = backup_mod.Backup;

/// sqlite3_backup_init(): the error is recorded on `dest`.
pub fn backupInit(dest: *Handle, dest_name: []const u8, src: *Handle, src_name: []const u8) Error!*BackupHandle {
    return backup_mod.init(dest, dest_name, src, src_name) orelse {
        const rc = main_mod.errcode(dest);
        return codeError(if (rc != RC.OK) rc else RC.ERROR);
    };
}

/// sqlite3_backup_step(): true once the copy is complete (SQLITE_DONE).
/// An error is recorded on `dest` (sqlite3_backup_step() itself leaves
/// that to sqlite3_backup_finish()).
pub fn backupStep(b: *BackupHandle, dest: *Handle, n_page: i32) Error!bool {
    const rc = backup_mod.step(b, n_page);
    if (rc == RC.DONE) return true;
    if (rc == RC.OK) return false;
    main_mod.setError(dest, rc);
    return codeError(rc);
}

/// sqlite3_backup_finish().
pub fn backupFinish(b: *BackupHandle) Error!void {
    return int.check(backup_mod.finish(b));
}

/// sqlite3_backup_remaining() and sqlite3_backup_pagecount().
pub fn backupRemaining(b: *const BackupHandle) u32 {
    return @bitCast(backup_mod.remaining(b));
}

pub fn backupPagecount(b: *const BackupHandle) u32 {
    return @bitCast(backup_mod.pagecount(b));
}

// ============================================================== blobs

/// An open blob (sqlite3_blob*).
pub const BlobHandle = blob_mod.Incrblob;

/// sqlite3_blob_open(): the error is recorded on `h`.
pub fn blobOpen(h: *Handle, database: ?[]const u8, table: []const u8, column: []const u8, rowid: i64, writable: bool) Error!*BlobHandle {
    var out: ?*BlobHandle = null;
    try int.check(blob_mod.open(h, database, table, column, rowid, writable, &out));
    return out.?;
}

/// sqlite3_serialize(): a copy of database `schema` from the library
/// allocator (free with libFree()), or null if there is no such database
/// (error.NotFound) or no memory.
pub fn serialize(h: *Handle, schema: []const u8) Error![]u8 {
    const r = @import("../sql/serialize.zig").serialize(h, schema, 0);
    if (r.size < 0) return error.NotFound;
    if (r.size == 0) return &.{};
    const d = r.data orelse return error.OutOfMemory;
    return d[0..@intCast(r.size)];
}

/// sqlite3_free() of memory from serialize().
pub fn libFree(p: []u8) void {
    if (p.len > 0) @import("../sql/malloc.zig").free(p.ptr);
}

/// sqlite3_deserialize() of a copy of `bytes` (resizable, or read-only).
pub fn deserialize(h: *Handle, schema: []const u8, bytes: []const u8, read_only: bool) Error!void {
    const ser = @import("../sql/serialize.zig");
    const m = @import("../sql/malloc.zig");
    const buf = m.malloc(@max(bytes.len, 1)) orelse return error.OutOfMemory;
    @memcpy(buf[0..bytes.len], bytes);
    const flags = ser.DESERIALIZE_FREEONCLOSE | (if (read_only) ser.DESERIALIZE_READONLY else ser.DESERIALIZE_RESIZEABLE);
    const n: i64 = @intCast(bytes.len);
    return int.check(ser.deserialize(h, schema, buf, n, n, flags));
}

/// sqlite3_blob_reopen(), sqlite3_blob_read() and sqlite3_blob_write().
pub fn blobReopen(b: *BlobHandle, rowid: i64) Error!void {
    return int.check(blob_mod.reopen(b, rowid));
}

pub fn blobRead(b: *BlobHandle, buf: []u8, offset: i32) Error!void {
    return int.check(blob_mod.read(b, buf, offset));
}

pub fn blobWrite(b: *BlobHandle, data: []const u8, offset: i32) Error!void {
    return int.check(blob_mod.write(b, data, offset));
}

/// sqlite3_blob_bytes(): 0 once the blob has expired.
pub fn blobBytes(b: *const BlobHandle) i32 {
    return blob_mod.bytes(b);
}

/// sqlite3_blob_close().
pub fn blobClose(b: *BlobHandle) Error!void {
    return int.check(blob_mod.close(b));
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
