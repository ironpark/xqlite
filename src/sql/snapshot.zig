//! Snapshots of WAL databases (SQLITE_ENABLE_SNAPSHOT: port of
//! sqlite3_snapshot_get(), sqlite3_snapshot_open(),
//! sqlite3_snapshot_recover() and sqlite3_snapshot_cmp() of main.c and
//! wal.c). A snapshot is a copy of the wal-index header of a read
//! transaction (wal.IndexHdr); opening it later starts a read
//! transaction on that state of the database, as long as no checkpoint
//! has written frames past it into the database file and the WAL has not
//! been restarted.
//!
//! What this costs a connection that does not use it: two tests of a
//! null pointer when a read transaction starts on a WAL database.

const std = @import("std");
const int = @import("sqlite_int.zig");
const build = @import("build.zig");
const malloc = @import("malloc.zig");
const wal = @import("xqlite_storage").pager.wal;

const Sqlite3 = int.Sqlite3;
const RC = int.RC;

/// sqlite3_snapshot: from the library allocator, freed with malloc.free().
pub const Snapshot = wal.IndexHdr;

/// The database `z_db` names if a snapshot may be taken or opened on it:
/// main or an attached one, not TEMP.
fn snapshotBtree(db: *Sqlite3, z_db: ?[]const u8) ?*@import("xqlite_storage").btree.Btree {
    const i_db = build.findDbName(db, z_db) orelse return null;
    if (i_db == 1) return null;
    return db.dbs.items[i_db].bt;
}

/// Port of sqlite3_snapshot_get(): a snapshot of the read transaction
/// open on database `z_db`, opened here if need be. The connection must
/// be in a transaction (BEGIN) and not writing that database.
pub fn get(db: *Sqlite3, z_db: ?[]const u8, out: *?*Snapshot) i32 {
    if (db.auto_commit) return RC.ERROR;
    const bt = snapshotBtree(db, z_db) orelse return RC.ERROR;
    if (bt.txnState() == .write) return RC.ERROR;
    const pager = bt.pager;
    // Version 0: for sqlite3_snapshot_get(), not on read lock 0.
    const dummy: Snapshot = .{};
    pager.snapshotOpen(&dummy) catch {};
    const r = bt.beginTrans(.read, 0);
    pager.snapshotOpen(null) catch {};
    r catch |err| return int.errorCode(err);
    const hdr = (pager.snapshotGet() catch return RC.ERROR) orelse {
        out.* = null;
        return RC.ERROR;
    };
    const p: *Snapshot = @ptrCast(@alignCast(malloc.malloc(@sizeOf(Snapshot)) orelse return RC.NOMEM));
    p.* = hdr;
    out.* = p;
    return RC.OK;
}

/// Port of sqlite3_snapshot_open(): start a read transaction on database
/// `z_db` at `snap`. The connection must be in a transaction; one already
/// reading that database (with no statement running) moves to the
/// snapshot if it is still available.
pub fn open(db: *Sqlite3, z_db: ?[]const u8, snap: *const Snapshot) i32 {
    if (db.auto_commit) return RC.ERROR;
    const bt = snapshotBtree(db, z_db) orelse return RC.ERROR;
    if (bt.txnState() == .write) return RC.ERROR;
    const pager = bt.pager;
    var rc: i32 = RC.OK;
    var unlock = false;
    if (bt.txnState() != .none) {
        rc = RC.ERROR;
        if (db.n_vdbe_active == 0) {
            if (pager.snapshotCheck(snap)) |_| {
                unlock = true;
                rc = RC.OK;
                bt.commit() catch |err| {
                    rc = int.errorCode(err);
                };
            } else |err| rc = code(err);
        }
    }
    if (rc == RC.OK) pager.snapshotOpen(snap) catch {
        rc = RC.ERROR;
    };
    if (rc == RC.OK) {
        bt.beginTrans(.read, 0) catch |err| {
            rc = int.errorCode(err);
        };
        pager.snapshotOpen(null) catch {};
    }
    if (unlock) pager.snapshotUnlock();
    return rc;
}

/// Port of sqlite3_snapshot_recover(): make as many old snapshots of
/// database `z_db` openable again as the WAL allows. No transaction may
/// be open on it.
pub fn recover(db: *Sqlite3, z_db: ?[]const u8) i32 {
    const bt = snapshotBtree(db, z_db) orelse return RC.ERROR;
    if (bt.txnState() != .none) return RC.ERROR;
    bt.beginTrans(.read, 0) catch |err| return int.errorCode(err);
    var rc: i32 = RC.OK;
    bt.pager.snapshotRecover() catch |err| {
        rc = code(err);
    };
    bt.commit() catch {};
    return rc;
}

/// The result code of a pager snapshot error; not a WAL database is
/// SQLITE_ERROR.
const SnapError = @import("xqlite_storage").pager.Error || error{NotWal};

fn code(err: SnapError) i32 {
    return switch (err) {
        error.NotWal => RC.ERROR,
        else => |e| int.errorCode(e),
    };
}

/// Port of sqlite3_snapshot_cmp(): positive if `a` is newer than `b`,
/// negative if older, 0 if the same snapshot. The salt grows with each
/// restart of the WAL.
pub fn cmp(a: *const Snapshot, b: *const Snapshot) i32 {
    if (a.salt[0] < b.salt[0]) return -1;
    if (a.salt[0] > b.salt[0]) return 1;
    if (a.mx_frame < b.mx_frame) return -1;
    if (a.mx_frame > b.mx_frame) return 1;
    return 0;
}
