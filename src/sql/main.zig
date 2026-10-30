//! The connection (port of main.c and the error helpers of util.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("xqlite_storage").btree;
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const util = @import("util.zig");
const vtab = @import("vtab.zig");
const malloc = @import("malloc.zig");
const thunk = @import("xqlite_base").thunk;

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;

/// Port of sqlite3RollbackAll(): roll back every open transaction.
/// Cursors are tripped with `trip` unless it is null (C: tripCode
/// SQLITE_OK); the callers trip with error.Abort (SQLITE_ABORT_ROLLBACK).
pub fn rollbackAll(db: *Sqlite3, trip: ?btree.Error) void {
    const schema_change = db.m_db_flags.SchemaChange and !db.init.busy;
    var in_trans = false;
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        if (bt.txnState() == .write) in_trans = true;
        bt.rollback(trip, !schema_change) catch {};
    }
    vtab.rollback(db);
    if (schema_change) {
        @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
        @import("build.zig").resetAllSchemasOfConnection(db);
    }
    db.n_deferred_cons = 0;
    db.n_deferred_imm_cons = 0;
    db.flags.clear(.{ .DeferFKs = true, .CorruptRdOnly = true });
    // The rollback hook, if a transaction was rolled back.
    if (db.rollback_hook) |f| if (in_trans or !db.auto_commit) f(db.rollback_arg);
}

/// Port of sqlite3CloseSavepoints(): forget every SAVEPOINT.
pub fn closeSavepoints(db: *Sqlite3) void {
    while (db.savepoint) |sp| {
        db.savepoint = sp.next;
        freeSavepoint(db, sp);
    }
    db.n_savepoint = 0;
    db.n_statement = 0;
    db.is_transaction_savepoint = false;
}

pub fn freeSavepoint(db: *Sqlite3, sp: *int.Savepoint) void {
    db.gpa.free(sp.name);
    db.gpa.destroy(sp);
}

/// Port of sqlite3CommitInternalChanges() (build.c).
pub fn commitInternalChanges(db: *Sqlite3) void {
    db.m_db_flags.SchemaChange = false;
}

/// Port of sqlite3MayAbort() (build.c): the statement may abort part way,
/// so it needs a statement transaction.
pub fn mayAbort(p: *Parse) void {
    (p.toplevel orelse p).may_abort = true;
}

/// Port of sqlite3MultiWrite() (build.c).
pub fn multiWrite(p: *Parse) void {
    (p.toplevel orelse p).is_multi_write = true;
}

/// Store `msg` (copied) as the connection's error message, or clear it.
pub fn setErrorMessage(db: *Sqlite3, msg: ?[:0]const u8) void {
    if (msg) |m| {
        if (db.err == null) {
            const e = db.gpa.create(vi.Mem) catch return;
            e.* = .{ .db = db };
            db.err = e;
        }
        mem.setTextZ(db.err.?, m, .transient) catch {};
    } else if (db.err) |e| {
        mem.setNull(e);
    }
}

/// Port of sqlite3Error(): set the error code; the message is cleared.
pub fn setError(db: *Sqlite3, code: i32) void {
    db.err_code = code;
    if (db.err) |e| mem.setNull(e);
    db.err_byte_offset = -1;
}

/// Port of sqlite3ErrorWithMsg().
pub fn errorWithMsg(db: *Sqlite3, code: i32, comptime fmt: []const u8, args: anytype) void {
    db.err_code = code;
    const msg = std.fmt.allocPrintSentinel(db.gpa, fmt, args, 0) catch return;
    defer db.gpa.free(msg);
    setErrorMessage(db, msg);
}

/// Port of sqlite3ErrorClear().
pub fn errorClear(db: *Sqlite3) void {
    db.err_code = RC.OK;
    db.err_byte_offset = -1;
    if (db.err) |e| mem.setNull(e);
}

/// Port of sqlite3ApiExit(): the result of an API call, as seen by the
/// application. Running out of memory is reported (and cleared) here.
pub fn apiExit(db: *Sqlite3, rc: i32) i32 {
    if (db.malloc_failed or rc == RC.NOMEM) {
        malloc.oomClear(db);
        setError(db, RC.NOMEM);
        return RC.NOMEM;
    }
    return rc & db.err_mask;
}

/// Port of sqlite3_errmsg(): the English text of the last error.
pub fn errmsg(db: *Sqlite3) [:0]const u8 {
    if (db.malloc_failed) return util.errStr(RC.NOMEM);
    if (db.err_code != RC.OK) {
        if (db.err) |e| if (e.flags.Str) return e.z.?[0..@intCast(e.n) :0];
    }
    return util.errStr(db.err_code);
}

/// Port of sqlite3_errcode() and sqlite3_extended_errcode().
pub fn errcode(db: *const Sqlite3) i32 {
    if (db.malloc_failed) return RC.NOMEM;
    return db.err_code & db.err_mask;
}

pub fn extendedErrcode(db: *const Sqlite3) i32 {
    if (db.malloc_failed) return RC.NOMEM;
    return db.err_code;
}

/// Port of sqlite3_extended_result_codes().
pub fn extendedResultCodes(db: *Sqlite3, on: bool) void {
    db.err_mask = if (on) -1 else 0xff;
}

/// Port of sqlite3_error_offset().
pub fn errorOffset(db: *const Sqlite3) i32 {
    return if (db.err_code != RC.OK) db.err_byte_offset else -1;
}

/// sqlite3_open_v2() flags this port understands.
pub const OpenFlags = struct {
    read_only: bool = false,
    create: bool = true,
    /// Filenames that start with "file:" are URIs (SQLITE_OPEN_URI), here
    /// and in ATTACH (see uri.zig).
    uri: bool = false,
    /// An in-memory database (SQLITE_OPEN_MEMORY, a URI's mode=memory).
    memory: bool = false,
    /// xqlite: the caller has resolved a URI's "vfs" parameter itself
    /// (the C ABI's VFS registry), so uri.parse() skips it.
    vfs_resolved: bool = false,
};

/// Port of openDatabase() (sqlite3_open_v2()): open a connection to the
/// database file `filename` (":memory:" or "" for a private temporary
/// database). The connection is returned in `out` even when opening
/// fails, with the error recorded; it must be closed with close(). `out`
/// is null only if the connection object itself could not be allocated
/// (C: `*ppDb = 0`). Its memory comes from sqlite3_malloc()
/// (malloc.configMalloc() chooses the allocator).
pub fn open(v: @import("xqlite_vfs").vfs.Vfs, filename: []const u8, flags: OpenFlags, out: *?*Sqlite3) i32 {
    out.* = null;
    const db = malloc.allocator.create(Sqlite3) catch return RC.NOMEM;
    // Lookaside is off until set up at the end.
    db.* = .{ .gpa = malloc.dbAllocator(db), .vfs = v };
    const gpa = db.gpa;
    out.* = db;
    const s_main = gpa.create(int.Schema) catch return oomOnOpen(db);
    s_main.* = .{};
    db.dbs.append(gpa, .{ .name = "main", .schema = s_main }) catch {
        gpa.destroy(s_main);
        return oomOnOpen(db);
    };
    const s_temp = gpa.create(int.Schema) catch return oomOnOpen(db);
    s_temp.* = .{};
    db.dbs.append(gpa, .{ .name = "temp", .schema = s_temp, .safety_level = 1 }) catch {
        gpa.destroy(s_temp);
        return oomOnOpen(db);
    };
    db.enc = 1;
    db.open_flags = flags;

    var parsed = @import("uri.zig").parse(gpa, filename, flags);
    defer parsed.deinit(gpa);
    if (parsed.rc != RC.OK) {
        if (parsed.rc == RC.NOMEM) return oomOnOpen(db);
        errorWithMsg(db, parsed.rc, "{s}", .{parsed.err_msg orelse util.errStr(parsed.rc)});
        return parsed.rc;
    }
    const of = parsed.flags;
    const name = parsed.filename();
    const path: ?[]const u8 = if (of.memory or name.len == 0 or std.mem.eql(u8, name, ":memory:")) null else name;
    const bt = btree.Btree.open(malloc.allocator, v, path, .{
        .read_only = of.read_only,
        .create = of.create and !of.read_only,
        .n_vdbe_read = &db.n_vdbe_read,
        .autovac_pages = btreeAutovacPages(db),
        .busy_handler = btreeBusyHandler(db),
        .uri_params = parsed.params(),
    }) catch |err| {
        const rc = int.errorCode(err);
        errorWithMsg(db, rc, "{s}", .{util.errStr(rc)});
        return rc;
    };
    db.dbs.items[0].bt = bt;
    db.dbs.items[0].schema.enc = db.enc;
    @import("func.zig").registerPerConnectionBuiltinFunctions(db);
    // The built-in extensions (sqlite3BuiltinExtensions): the reference
    // build has SQLITE_ENABLE_BYTECODE_VTAB.
    _ = @import("../vdbe/vdbevtab.zig").init(db);
    errorClear(db);
    // Enable the lookaside-malloc subsystem.
    const cfg = malloc.configLookasideDefaults();
    _ = malloc.setupLookaside(db, null, cfg.sz, cfg.n);
    // SQLITE_DEFAULT_WAL_AUTOCHECKPOINT.
    _ = walAutocheckpoint(db, 1000);
    return RC.OK;
}

fn oomOnOpen(db: *Sqlite3) i32 {
    db.oomFault();
    db.err_code = RC.NOMEM;
    return RC.NOMEM;
}

/// xqlite: make `d` the SQL dialect of the connection, with its own
/// frontend, for the statements prepared from now on (those prepared
/// before keep theirs). PRAGMA xq_dialect and the shell's .dialect come
/// here.
pub fn setDialect(db: *Sqlite3, d: @import("../dialect/dialect.zig").Dialect) void {
    db.xq.lang = .of(d);
}

/// xqlite: the SQL dialect of the connection.
pub fn getDialect(db: *const Sqlite3) @import("../dialect/dialect.zig").Dialect {
    return db.xq.lang.dialect;
}

/// xqlite: compile the statements prepared from now on with `frontend`,
/// keeping the semantic hooks of the connection's dialect: for frontend
/// development and tests (e.g. SQLite's grammar with PostgreSQL's
/// functions). setDialect() goes back to the dialect's own frontend.
pub fn setFrontend(db: *Sqlite3, frontend: *const @import("../dialect/dialect.zig").Frontend) void {
    db.xq.lang.frontend = frontend;
}

/// Port of connectionIsBusy(): the connection has statements not
/// finalized or backups not finished.
fn connectionIsBusy(db: *Sqlite3) bool {
    if (db.vdbe != null) return true;
    for (db.dbs.items) |d| {
        if (d.bt) |bt| if (bt.isInBackup()) return true;
    }
    return false;
}

/// Port of sqlite3_close(): close the connection. Fails with BUSY if
/// statements are not finalized or backups not finished.
pub fn close(db: *Sqlite3) i32 {
    // Disconnect the virtual tables, and those with a transaction too.
    disconnectAllVtab(db);
    vtab.rollback(db);
    if (connectionIsBusy(db)) {
        errorWithMsg(db, RC.BUSY, "unable to close due to unfinalized statements or unfinished backups", .{});
        return RC.BUSY;
    }
    rollbackAll(db, null);
    closeSavepoints(db);
    const gpa = db.gpa;
    for (db.dbs.items, 0..) |*d, i| {
        @import("build.zig").schemaFree(db, d.schema);
        gpa.destroy(d.schema);
        if (d.bt) |bt| bt.close(pagerConn(db));
        if (i >= 2) gpa.free(d.name);
    }
    db.dbs.deinit(gpa);
    @import("coll.zig").freeAll(db);
    @import("callback.zig").freeFunctions(db);
    db.xq.deinit(gpa);
    {
        vtab.unlockList(db);
        var it = db.modules.valueIterator();
        while (it.next()) |m| {
            vtab.epoTableClear(db, m.*);
            vtab.moduleUnref(db, m.*);
        }
        db.modules.deinit(gpa);
    }
    if (db.err) |e| {
        mem.release(e);
        gpa.destroy(e);
    }
    malloc.freeLookaside(db);
    malloc.allocator.destroy(db);
    return RC.OK;
}

/// Port of disconnectAllVtab(): disconnect every virtual table of the
/// connection, as it closes.
fn disconnectAllVtab(db: *Sqlite3) void {
    for (db.dbs.items) |d| {
        var it = d.schema.tbl_hash.valueIterator();
        while (it.next()) |t| {
            if (t.*.isVirtual()) vtab.disconnect(db, t.*);
        }
    }
    var it = db.modules.valueIterator();
    while (it.next()) |m| {
        if (m.*.epo_tab) |t| vtab.disconnect(db, t);
    }
    vtab.unlockList(db);
}

/// The sqlite3_db_config() options that set or clear connection flags
/// (the aFlagOp table of sqlite3_db_config()), valued by their
/// SQLITE_DBCONFIG_* codes.
pub const DbConfig = enum(c_int) {
    enable_fkey = 1002,
    enable_trigger = 1003,
    enable_view = 1015,
    enable_fts3_tokenizer = 1004,
    enable_load_extension = 1005,
    no_ckpt_on_close = 1006,
    enable_qpsg = 1007,
    trigger_eqp = 1008,
    reset_database = 1009,
    defensive = 1010,
    writable_schema = 1011,
    legacy_alter_table = 1012,
    dqs_ddl = 1014,
    dqs_dml = 1013,
    legacy_file_format = 1016,
    trusted_schema = 1017,
    stmt_scanstatus = 1018,
    reverse_scanorder = 1019,
    enable_attach_create = 1020,
    enable_attach_write = 1021,
    enable_comments = 1022,

    pub fn mask(op: DbConfig) int.DbFlag {
        return switch (op) {
            .enable_fkey => .{ .ForeignKeys = true },
            .enable_trigger => .{ .EnableTrigger = true },
            .enable_view => .{ .EnableView = true },
            .enable_fts3_tokenizer => .{ .Fts3Tokenizer = true },
            .enable_load_extension => .{ .LoadExtension = true },
            .no_ckpt_on_close => .{ .NoCkptOnClose = true },
            .enable_qpsg => .{ .EnableQPSG = true },
            .trigger_eqp => .{ .TriggerEQP = true },
            .reset_database => .{ .ResetDatabase = true },
            .defensive => .{ .Defensive = true },
            .writable_schema => .{ .WriteSchema = true, .NoSchemaError = true },
            .legacy_alter_table => .{ .LegacyAlter = true },
            .dqs_ddl => .{ .DqsDDL = true },
            .dqs_dml => .{ .DqsDML = true },
            .legacy_file_format => .{ .LegacyFileFmt = true },
            .trusted_schema => .{ .TrustedSchema = true },
            .stmt_scanstatus => .{ .StmtScanStatus = true },
            .reverse_scanorder => .{ .ReverseOrder = true },
            .enable_attach_create => .{ .AttachCreate = true },
            .enable_attach_write => .{ .AttachWrite = true },
            .enable_comments => .{ .Comments = true },
        };
    }
};

/// Port of sqlite3_db_config() for the flag options: set (`onoff` > 0) or
/// clear (0) the flag, or leave it (< 0); returns whether it is set.
/// Changing a flag expires the prepared statements.
pub fn dbConfig(db: *Sqlite3, op: DbConfig, onoff: i32) bool {
    const m = op.mask();
    const old_flags = db.flags;
    if (onoff > 0) {
        db.flags.set(m);
    } else if (onoff == 0) {
        db.flags.clear(m);
    }
    if (old_flags != db.flags) @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
    return db.flags.intersects(m);
}

/// Port of sqlite3_db_config(SQLITE_DBCONFIG_LOOKASIDE): `cnt` lookaside
/// slots of `sz` bytes, in `buf` or (if null) in memory from
/// sqlite3_malloc(); 0 for either turns lookaside off. BUSY while any
/// slot is in use.
pub fn dbConfigLookaside(db: *Sqlite3, buf: ?[]align(8) u8, sz: i32, cnt: i32) i32 {
    return malloc.setupLookaside(db, buf, sz, cnt);
}

/// Port of sqlite3_db_config(SQLITE_DBCONFIG_FP_DIGITS): set the digits
/// of REAL to text conversions if `n` is 4-23; returns the setting.
pub fn dbConfigFpDigits(db: *Sqlite3, n: i32) i32 {
    if (n > 3 and n < 24) db.n_fp_digit = @intCast(n);
    return db.n_fp_digit;
}

/// Port of sqlite3_last_insert_rowid().
pub fn lastInsertRowid(db: *const Sqlite3) i64 {
    return db.last_rowid;
}

/// Port of sqlite3DbNameToBtree(): the b-tree of database `name` (main
/// if null), or null.
pub fn dbNameToBtree(db: *Sqlite3, name: ?[]const u8) ?*btree.Btree {
    const i_db = if (name) |n| @import("build.zig").findDbName(db, n) orelse return null else 0;
    return db.dbs.items[i_db].bt;
}

/// Port of sqlite3_db_name(): the name of database `n` (0 main, 1 temp,
/// then the attached ones), or null.
pub fn dbName(db: *const Sqlite3, n: usize) ?[:0]const u8 {
    if (n >= db.dbs.items.len) return null;
    return db.dbs.items[n].name;
}

/// Port of sqlite3_db_filename(): the full name of the file of database
/// `name` (main if null), "" for a temporary or in-memory database, null
/// if there is no such database.
pub fn dbFilename(db: *Sqlite3, name: ?[]const u8) ?[]const u8 {
    const bt = dbNameToBtree(db, name) orelse return null;
    return bt.pager.filename();
}

/// Port of sqlite3_db_readonly(): whether database `name` (main if null)
/// is read-only, or null if there is no such database.
pub fn dbReadonly(db: *Sqlite3, name: ?[]const u8) ?bool {
    const bt = dbNameToBtree(db, name) orelse return null;
    return bt.read_only;
}

/// Port of sqlite3_get_autocommit().
pub fn getAutocommit(db: *const Sqlite3) bool {
    return db.auto_commit;
}

/// The hard upper bounds of sqlite3_limit() (aHardLimit): the defaults,
/// except that worker threads default to 0 out of SQLITE_MAX_WORKER_THREADS.
const hard_limits = blk: {
    var a = int.Limit.defaults;
    a.set(.worker_threads, 8);
    break :blk a;
};

/// SQLITE_MIN_LENGTH.
const min_length = 30;

/// Port of sqlite3_limit(): set limit `id` to `new_limit` (capped at its
/// hard bound) unless it is negative; returns the prior value.
pub fn limit(db: *Sqlite3, id: int.Limit, new_limit_arg: i32) i32 {
    const old = db.limits.get(id);
    var new_limit = new_limit_arg;
    if (new_limit >= 0) {
        if (new_limit > hard_limits.get(id)) {
            new_limit = hard_limits.get(id);
        } else if (new_limit < min_length and id == .length) {
            new_limit = min_length;
        }
        db.limits.set(id, new_limit);
    }
    return old;
}

/// Port of sqlite3InvokeBusyHandler(): whether to retry an operation
/// that found a lock taken. Once the handler declines, it is not called
/// again until `n_busy` is reset.
pub fn invokeBusyHandler(p: *int.BusyHandler) bool {
    const func = p.func orelse return false;
    if (p.n_busy < 0) return false;
    const rc = func(p.arg, p.n_busy);
    if (rc == 0) {
        p.n_busy = -1;
    } else {
        p.n_busy += 1;
    }
    return rc != 0;
}

/// The busy handler given to the pagers of the connection (C passes
/// sqlite3InvokeBusyHandler with &db->busyHandler).
pub fn btreeBusyHandler(db: *Sqlite3) @import("xqlite_storage").pager.BusyHandler {
    return .init(db, pagerBusy);
}

/// What the pagers of the connection need of it for WAL closes and
/// checkpoints (C passes db): the interrupt flag, and whether the last
/// connection checkpoints the WAL on close (not with
/// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE).
pub fn pagerConn(db: *Sqlite3) @import("xqlite_storage").pager.Conn {
    return .{
        .interrupt = &db.is_interrupted,
        .no_ckpt_on_close = db.flags.NoCkptOnClose,
    };
}

/// The autovacuum-pages callback of the b-trees of the connection.
pub fn btreeAutovacPages(db: *Sqlite3) btree.AutovacPages {
    return .init(db, autovacPages);
}

/// The xAutovacPages part of autoVacuumCommit(): ask the application how
/// many free pages of `bt` to give back.
fn autovacPages(db: *Sqlite3, bt: *btree.Btree, n_orig: u32, n_free: u32, page_size: u32) ?u32 {
    const f = db.autovac_pages orelse return null;
    for (db.dbs.items) |d| {
        if (d.bt == bt) return f(db.autovac_pages_arg, d.name, n_orig, n_free, page_size);
    }
    return null;
}

fn pagerBusy(db: *Sqlite3) bool {
    return invokeBusyHandler(&db.busy_handler);
}

/// Port of sqliteDefaultBusyCallback(): sleep a little longer each time,
/// until `busy_timeout` milliseconds have passed.
fn defaultBusyCallback(db: *Sqlite3, count: i32) i32 {
    const delays = [_]u8{ 1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100 };
    const totals = [_]u8{ 0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228 };
    const tmout = db.busy_timeout;
    std.debug.assert(count >= 0);
    var delay: i32 = undefined;
    var prior: i32 = undefined;
    if (count < delays.len) {
        delay = delays[@intCast(count)];
        prior = totals[@intCast(count)];
    } else {
        delay = delays[delays.len - 1];
        prior = totals[totals.len - 1] + delay * (count - @as(i32, delays.len - 1));
    }
    if (prior + delay > tmout) {
        delay = tmout - prior;
        if (delay <= 0) return 0;
    }
    if (db.vfs) |v| _ = v.sleep(@intCast(delay * 1000));
    return 1;
}

/// Port of sqlite3_busy_handler().
pub fn busyHandler(db: *Sqlite3, func: ?int.BusyHandler.Fn, arg: ?*anyopaque) i32 {
    db.busy_handler = .{ .func = func, .arg = arg, .n_busy = 0 };
    db.busy_timeout = 0;
    return RC.OK;
}

/// Port of sqlite3_busy_timeout(): retry locks for up to `ms`
/// milliseconds; 0 or less turns the busy handler off.
pub fn busyTimeout(db: *Sqlite3, ms: i32) i32 {
    if (ms > 0) {
        const cb: thunk.Closure(int.BusyHandler.Fn) = .init(db, defaultBusyCallback);
        _ = busyHandler(db, cb.func, cb.ctx);
        db.busy_timeout = ms;
    } else {
        _ = busyHandler(db, null, null);
    }
    return RC.OK;
}

// ===================================================================== WAL

/// Port of sqlite3_wal_hook(): register the WAL hook, returning the
/// previous argument.
pub fn walHook(db: *Sqlite3, func: ?int.WalCallback, arg: ?*anyopaque) ?*anyopaque {
    const old = db.wal_arg;
    db.wal_callback = func;
    db.wal_arg = arg;
    return old;
}

/// Port of sqlite3WalDefaultHook(): the hook of sqlite3_wal_autocheckpoint(),
/// a PASSIVE checkpoint once the WAL holds the given number of frames.
pub fn walDefaultHook(arg: ?*anyopaque, db: *Sqlite3, name: [:0]const u8, n_frame: i32) i32 {
    if (n_frame >= @as(i32, @intCast(@intFromPtr(arg)))) {
        _ = walCheckpointV2(db, name, .passive, null, null);
    }
    return RC.OK;
}

/// Port of sqlite3_wal_autocheckpoint(): checkpoint after commits that
/// leave at least `n_frame` frames in the WAL; 0 or less turns it off.
pub fn walAutocheckpoint(db: *Sqlite3, n_frame: i32) i32 {
    if (n_frame > 0) {
        _ = walHook(db, walDefaultHook, @ptrFromInt(@as(usize, @intCast(n_frame))));
    } else {
        _ = walHook(db, null, null);
    }
    return RC.OK;
}

/// The wal_autocheckpoint setting: the frame count if the default hook is
/// installed, else 0.
pub fn walAutocheckpointValue(db: *const Sqlite3) i32 {
    if (db.wal_callback == walDefaultHook) return @intCast(@intFromPtr(db.wal_arg));
    return 0;
}

/// Port of sqlite3Checkpoint(): checkpoint database `i_db`, or all of them
/// for MAX_DB. `n_log` and `n_ckpt` are only set by the first. Busy from
/// one database does not stop the others; it is reported at the end.
pub fn checkpoint(db: *Sqlite3, i_db: i32, mode: @import("xqlite_storage").pager.CheckpointMode, n_log_arg: ?*i32, n_ckpt_arg: ?*i32) int.Error!void {
    var seen_busy = false;
    var n_log = n_log_arg;
    var n_ckpt = n_ckpt_arg;
    for (db.dbs.items, 0..) |d, i| {
        if (i == i_db or i_db == int.MAX_DB) {
            if (d.bt) |bt| {
                bt.checkpoint(pagerConn(db), mode, n_log, n_ckpt) catch |err| switch (err) {
                    error.Busy => seen_busy = true,
                    else => |e| return e,
                };
            }
            n_log = null;
            n_ckpt = null;
        }
    }
    if (seen_busy) return error.Busy;
}

/// Port of sqlite3_wal_checkpoint_v2(): checkpoint the database named
/// `zdb` (all of them if null or empty). `n_log` and `n_ckpt` receive the
/// WAL size and the frames checkpointed, or -1.
pub fn walCheckpointV2(db: *Sqlite3, zdb: ?[]const u8, mode: @import("xqlite_storage").pager.CheckpointMode, n_log: ?*i32, n_ckpt: ?*i32) i32 {
    if (n_log) |p| p.* = -1;
    if (n_ckpt) |p| p.* = -1;
    var rc: i32 = undefined;
    const i_db: i32 = if (zdb != null and zdb.?.len > 0)
        if (@import("build.zig").findDbName(db, zdb.?)) |i| @intCast(i) else -1
    else
        int.MAX_DB;
    if (i_db < 0) {
        errorWithMsg(db, RC.ERROR, "unknown database: {s}", .{zdb.?});
        rc = RC.ERROR;
    } else {
        db.busy_handler.n_busy = 0;
        rc = if (checkpoint(db, i_db, mode, n_log, n_ckpt)) |_| RC.OK else |err| int.errorCode(err);
        setError(db, rc);
    }
    rc = apiExit(db, rc);
    // With no statement running, a pending interrupt is cleared here.
    if (db.n_vdbe_active == 0) db.is_interrupted.store(false, .monotonic);
    return rc;
}

/// Port of sqlite3_wal_checkpoint(): a PASSIVE checkpoint.
pub fn walCheckpoint(db: *Sqlite3, zdb: ?[]const u8) i32 {
    return walCheckpointV2(db, zdb, .passive, null, null);
}

const soft_heap_limit = &@import("global.zig").heap_limit.soft;
const hard_heap_limit = &@import("global.zig").heap_limit.hard;

/// Port of sqlite3_soft_heap_limit64(): set the soft limit unless `n` is
/// negative; returns the prior value.
pub fn softHeapLimit64(n_arg: i64) i64 {
    const prior = soft_heap_limit.load(.monotonic);
    if (n_arg < 0) return prior;
    var n = n_arg;
    const hard = hard_heap_limit.load(.monotonic);
    if (hard > 0 and (n > hard or n == 0)) n = hard;
    soft_heap_limit.store(n, .monotonic);
    return prior;
}

/// Port of sqlite3_hard_heap_limit64(): set the hard limit unless `n` is
/// negative, lowering the soft limit to it; returns the prior value.
pub fn hardHeapLimit64(n: i64) i64 {
    const prior = hard_heap_limit.load(.monotonic);
    if (n >= 0) {
        hard_heap_limit.store(n, .monotonic);
        const soft = soft_heap_limit.load(.monotonic);
        if (n < soft or soft == 0) soft_heap_limit.store(n, .monotonic);
    }
    return prior;
}
