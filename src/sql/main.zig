//! The connection (port of main.c and the error helpers of util.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const util = @import("util.zig");
const vtab = @import("vtab.zig");
const malloc = @import("malloc.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;

/// Every error the storage and VM layers report. errorCode() and
/// tripError() map them to and from result codes.
pub const Error = btree.Error || error{TooBig};

/// The result code of an error from the lower layers.
pub fn errorCode(err: Error) i32 {
    return switch (err) {
        error.Busy => RC.BUSY,
        error.CantOpen => RC.CANTOPEN,
        error.ShortRead => RC.IOERR_SHORT_READ,
        error.DiskFull => RC.FULL,
        error.ReadOnly => RC.READONLY,
        error.IoErr => RC.IOERR,
        error.LockErr => RC.IOERR_LOCK,
        error.ShmOpen => RC.IOERR_SHMOPEN,
        error.ShmSize => RC.IOERR_SHMSIZE,
        error.ShmMap => RC.IOERR_SHMMAP,
        error.ShmLock => RC.IOERR_SHMLOCK,
        error.ReadOnlyCantInit => RC.READONLY_CANTINIT,
        error.BusyRecovery => RC.BUSY_RECOVERY,
        error.BusySnapshot => RC.BUSY_SNAPSHOT,
        error.ReadOnlyRecovery => RC.READONLY_RECOVERY,
        error.Protocol => RC.PROTOCOL,
        error.Interrupt => RC.INTERRUPT,
        error.OutOfMemory => RC.NOMEM,
        error.Corrupt => RC.CORRUPT,
        error.ReadOnlyRollback => RC.READONLY_ROLLBACK,
        error.Abort => RC.ABORT,
        error.NotADatabase => RC.NOTADB,
        error.TooBig => RC.TOOBIG,
    };
}

/// The Zig error for a result code, as passed to b-tree rollbacks.
pub fn tripError(code: i32) ?btree.Error {
    if (code == RC.OK) return null;
    return switch (code & 0xff) {
        RC.NOMEM => error.OutOfMemory,
        RC.CORRUPT => error.Corrupt,
        RC.BUSY => error.Busy,
        RC.IOERR => error.IoErr,
        RC.FULL => error.DiskFull,
        RC.READONLY => error.ReadOnly,
        else => error.Abort,
    };
}

/// Port of sqlite3RollbackAll(): roll back every open transaction.
/// Cursors are tripped with `trip_code` unless it is OK.
pub fn rollbackAll(db: *Sqlite3, trip_code: i32) void {
    const schema_change = db.m_db_flags & int.DBFLAG.SchemaChange != 0 and !db.init.busy;
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        bt.rollback(tripError(trip_code), !schema_change) catch {};
    }
    _ = vtab.rollback(db);
    if (schema_change) {
        @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
        @import("build.zig").resetAllSchemasOfConnection(db);
    }
    db.n_deferred_cons = 0;
    db.n_deferred_imm_cons = 0;
    db.flags &= ~(int.DbFlag.DeferFKs | int.DbFlag.CorruptRdOnly);
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
    db.m_db_flags &= ~int.DBFLAG.SchemaChange;
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
        if (db.err) |e| if (e.flags & vi.MEM.Str != 0) return e.z.?[0..@intCast(e.n) :0];
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
};

/// Port of openDatabase() (sqlite3_open_v2()): open a connection to the
/// database file `filename` (":memory:" or "" for a private temporary
/// database). The connection is returned even when opening fails, with
/// the error recorded; it must be closed with close(). Its memory comes
/// from sqlite3_malloc() (malloc.configMalloc() chooses the allocator).
pub fn open(v: @import("../vfs/vfs.zig").Vfs, filename: []const u8, flags: OpenFlags, out: **Sqlite3) i32 {
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

    const path: ?[]const u8 = if (filename.len == 0 or std.mem.eql(u8, filename, ":memory:")) null else filename;
    const bt = btree.Btree.open(malloc.allocator, v, path, .{
        .read_only = flags.read_only,
        .create = flags.create and !flags.read_only,
        .n_vdbe_read = &db.n_vdbe_read,
        .busy_handler = btreeBusyHandler(db),
    }) catch |err| {
        const rc = errorCode(err);
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

/// Port of sqlite3_close(): close the connection. Fails with BUSY if
/// statements are not finalized.
pub fn close(db: *Sqlite3) i32 {
    // Disconnect the virtual tables, and those with a transaction too.
    disconnectAllVtab(db);
    _ = vtab.rollback(db);
    if (db.vdbe != null) {
        errorWithMsg(db, RC.BUSY, "unable to close due to unfinalized statements or unfinished backups", .{});
        return RC.BUSY;
    }
    rollbackAll(db, RC.OK);
    closeSavepoints(db);
    const gpa = db.gpa;
    for (db.dbs.items) |*d| {
        @import("build.zig").schemaFree(db, d.schema);
        gpa.destroy(d.schema);
        if (d.bt) |bt| bt.close(pagerConn(db));
    }
    db.dbs.deinit(gpa);
    @import("coll.zig").freeAll(db);
    @import("callback.zig").freeFunctions(db);
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
/// (the aFlagOp table of sqlite3_db_config()).
pub const DbConfig = enum {
    enable_fkey,
    enable_trigger,
    enable_view,
    enable_fts3_tokenizer,
    enable_load_extension,
    no_ckpt_on_close,
    enable_qpsg,
    trigger_eqp,
    reset_database,
    defensive,
    writable_schema,
    legacy_alter_table,
    dqs_ddl,
    dqs_dml,
    legacy_file_format,
    trusted_schema,
    stmt_scanstatus,
    reverse_scanorder,
    enable_attach_create,
    enable_attach_write,
    enable_comments,

    pub fn mask(op: DbConfig) u64 {
        const F = int.DbFlag;
        return switch (op) {
            .enable_fkey => F.ForeignKeys,
            .enable_trigger => F.EnableTrigger,
            .enable_view => F.EnableView,
            .enable_fts3_tokenizer => F.Fts3Tokenizer,
            .enable_load_extension => F.LoadExtension,
            .no_ckpt_on_close => F.NoCkptOnClose,
            .enable_qpsg => F.EnableQPSG,
            .trigger_eqp => F.TriggerEQP,
            .reset_database => F.ResetDatabase,
            .defensive => F.Defensive,
            .writable_schema => F.WriteSchema | F.NoSchemaError,
            .legacy_alter_table => F.LegacyAlter,
            .dqs_ddl => F.DqsDDL,
            .dqs_dml => F.DqsDML,
            .legacy_file_format => F.LegacyFileFmt,
            .trusted_schema => F.TrustedSchema,
            .stmt_scanstatus => F.StmtScanStatus,
            .reverse_scanorder => F.ReverseOrder,
            .enable_attach_create => F.AttachCreate,
            .enable_attach_write => F.AttachWrite,
            .enable_comments => F.Comments,
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
        db.flags |= m;
    } else if (onoff == 0) {
        db.flags &= ~m;
    }
    if (old_flags != db.flags) @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
    return db.flags & m != 0;
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
pub fn btreeBusyHandler(db: *Sqlite3) @import("../pager/pager.zig").BusyHandler {
    return .{ .ctx = db, .func = pagerBusy };
}

/// What the pagers of the connection need of it for WAL closes and
/// checkpoints (C passes db): the interrupt flag, and whether the last
/// connection checkpoints the WAL on close (not with
/// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE).
pub fn pagerConn(db: *Sqlite3) @import("../pager/pager.zig").Conn {
    return .{
        .interrupt = &db.is_interrupted,
        .no_ckpt_on_close = db.flags & int.DbFlag.NoCkptOnClose != 0,
    };
}

fn pagerBusy(ctx: ?*anyopaque) bool {
    const db: *Sqlite3 = @ptrCast(@alignCast(ctx.?));
    return invokeBusyHandler(&db.busy_handler);
}

/// Port of sqliteDefaultBusyCallback(): sleep a little longer each time,
/// until `busy_timeout` milliseconds have passed.
fn defaultBusyCallback(ptr: ?*anyopaque, count: i32) i32 {
    const delays = [_]u8{ 1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100 };
    const totals = [_]u8{ 0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228 };
    const db: *Sqlite3 = @ptrCast(@alignCast(ptr.?));
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
pub fn busyHandler(db: *Sqlite3, func: ?*const fn (arg: ?*anyopaque, count: i32) i32, arg: ?*anyopaque) i32 {
    db.busy_handler = .{ .func = func, .arg = arg, .n_busy = 0 };
    db.busy_timeout = 0;
    return RC.OK;
}

/// Port of sqlite3_busy_timeout(): retry locks for up to `ms`
/// milliseconds; 0 or less turns the busy handler off.
pub fn busyTimeout(db: *Sqlite3, ms: i32) i32 {
    if (ms > 0) {
        _ = busyHandler(db, defaultBusyCallback, db);
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
pub fn checkpoint(db: *Sqlite3, i_db: i32, mode: @import("../pager/pager.zig").CheckpointMode, n_log_arg: ?*i32, n_ckpt_arg: ?*i32) i32 {
    var rc: i32 = RC.OK;
    var seen_busy = false;
    var n_log = n_log_arg;
    var n_ckpt = n_ckpt_arg;
    for (db.dbs.items, 0..) |d, i| {
        if (rc != RC.OK) break;
        if (i == i_db or i_db == int.MAX_DB) {
            if (d.bt) |bt| {
                bt.checkpoint(pagerConn(db), mode, n_log, n_ckpt) catch |err| {
                    rc = switch (err) {
                        error.Locked => RC.LOCKED,
                        else => |e| errorCode(e),
                    };
                };
            }
            n_log = null;
            n_ckpt = null;
            if (rc == RC.BUSY) {
                seen_busy = true;
                rc = RC.OK;
            }
        }
    }
    return if (rc == RC.OK and seen_busy) RC.BUSY else rc;
}

/// Port of sqlite3_wal_checkpoint_v2(): checkpoint the database named
/// `zdb` (all of them if null or empty). `n_log` and `n_ckpt` receive the
/// WAL size and the frames checkpointed, or -1.
pub fn walCheckpointV2(db: *Sqlite3, zdb: ?[]const u8, mode: @import("../pager/pager.zig").CheckpointMode, n_log: ?*i32, n_ckpt: ?*i32) i32 {
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
        rc = checkpoint(db, i_db, mode, n_log, n_ckpt);
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

/// The process-wide heap limits (mem0.alarmThreshold and mem0.hardLimit).
/// Memory comes from the application's allocator, so they are only
/// recorded, not enforced.
var soft_heap_limit: std.atomic.Value(i64) = .init(0);
var hard_heap_limit: std.atomic.Value(i64) = .init(0);

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
