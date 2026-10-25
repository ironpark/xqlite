//! The connection (port of main.c and the error helpers of util.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("../btree/btree.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;

/// Extended result codes used by the port.

/// The result code of a Zig error from the lower layers.
pub fn errorCode(err: anyerror) i32 {
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
        else => RC.ERROR,
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
