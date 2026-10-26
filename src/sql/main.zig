//! The connection (port of main.c and the error helpers of util.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const util = @import("util.zig");

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
        error.OutOfMemory => RC.NOMEM,
        error.Corrupt => RC.CORRUPT,
        error.ReadOnlyRollback => RC.READONLY_ROLLBACK,
        error.Abort => RC.ABORT,
        error.NotADatabase => RC.NOTADB,
        error.TooBig => RC.TOOBIG,
    };
}

/// The Zig error for a result code, as passed to b-tree rollbacks.
fn tripError(code: i32) ?btree.Error {
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
    if (schema_change) {
        @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
        @import("build.zig").resetAllSchemasOfConnection(db);
    }
    db.n_deferred_cons = 0;
    db.n_deferred_imm_cons = 0;
    db.flags &= ~(int.DbFlag.DeferFKs | int.DbFlag.CorruptRdOnly);
}

/// Port of sqlite3CloseSavepoints().
pub fn closeSavepoints(db: *Sqlite3) void {
    db.n_savepoint = 0;
    db.n_statement = 0;
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
        db.malloc_failed = false;
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
/// the error recorded; it must be closed with close().
pub fn open(gpa: std.mem.Allocator, v: @import("../vfs/vfs.zig").Vfs, filename: []const u8, flags: OpenFlags, out: **Sqlite3) i32 {
    const db = gpa.create(Sqlite3) catch return RC.NOMEM;
    db.* = .{ .gpa = gpa, .vfs = v };
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
    const bt = btree.Btree.open(gpa, v, path, .{
        .read_only = flags.read_only,
        .create = flags.create and !flags.read_only,
    }) catch |err| {
        const rc = errorCode(err);
        errorWithMsg(db, rc, "{s}", .{util.errStr(rc)});
        return rc;
    };
    db.dbs.items[0].bt = bt;
    db.dbs.items[0].schema.enc = db.enc;
    @import("func.zig").registerPerConnectionBuiltinFunctions(db);
    errorClear(db);
    return RC.OK;
}

fn oomOnOpen(db: *Sqlite3) i32 {
    db.malloc_failed = true;
    db.err_code = RC.NOMEM;
    return RC.NOMEM;
}

/// Port of sqlite3_close(): close the connection. Fails with BUSY if
/// statements are not finalized.
pub fn close(db: *Sqlite3) i32 {
    if (db.vdbe != null) {
        errorWithMsg(db, RC.BUSY, "unable to close due to unfinalized statements or unfinished backups", .{});
        return RC.BUSY;
    }
    rollbackAll(db, RC.OK);
    const gpa = db.gpa;
    for (db.dbs.items) |*d| {
        @import("build.zig").schemaFree(db, d.schema);
        gpa.destroy(d.schema);
        if (d.bt) |bt| bt.close();
    }
    db.dbs.deinit(gpa);
    @import("coll.zig").freeAll(db);
    @import("callback.zig").freeFunctions(db);
    if (db.err) |e| {
        mem.release(e);
        gpa.destroy(e);
    }
    gpa.destroy(db);
    return RC.OK;
}

/// Port of sqlite3_last_insert_rowid().
pub fn lastInsertRowid(db: *const Sqlite3) i64 {
    return db.last_rowid;
}

/// Port of sqlite3_get_autocommit().
pub fn getAutocommit(db: *const Sqlite3) bool {
    return db.auto_commit;
}
