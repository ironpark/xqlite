//! The online backup API (port of backup.c): copy the content of one
//! database into another page by page, sqlite3_backup_init() to
//! sqlite3_backup_finish(). VACUUM copies its rebuilt database back into
//! the original the same way (copyFile, sqlite3BtreeCopyFile()).
//!
//! A backup registers with the pager of its source (pager.Backup): pages
//! the source connection writes after they were copied are copied again,
//! and a change by another connection (the cache is discarded) starts the
//! copy over. The destination is locked from the first step() to the
//! last, and committed by the step that copies the last page.

const std = @import("std");
const int = @import("sqlite_int.zig");
const btree = @import("xqlite_storage").btree;
const pager_mod = @import("xqlite_storage").pager;
const vfs = @import("xqlite_vfs").vfs;
const main_mod = @import("main.zig");
const build = @import("build.zig");
const malloc = @import("malloc.zig");

const Sqlite3 = int.Sqlite3;
const Btree = btree.Btree;
const Pgno = btree.Pgno;
const RC = int.RC;

/// A backup in progress (sqlite3_backup).
pub const Backup = struct {
    /// The destination connection; null for copyFile().
    dest_db: ?*Sqlite3,
    /// The name of the destination database in `dest_db`.
    dest_name: [:0]const u8 = "",
    /// The destination b-tree, once it is locked by the first step().
    dest: ?*Btree = null,
    /// The schema cookie of the destination when it was locked.
    i_dest_schema: u32 = 0,
    dest_locked: bool = false,
    /// The next source page to copy.
    i_next: Pgno = 1,
    src_db: *Sqlite3,
    src: *Btree,
    /// The result of the last step(): OK, BUSY or LOCKED to go on, DONE,
    /// or an error that ends the backup.
    rc: i32 = RC.OK,
    /// Pages left to copy and pages in the source, as of the last step().
    n_remaining: Pgno = 0,
    n_pagecount: Pgno = 0,
    /// Registered with the source pager (isAttached).
    is_attached: bool = false,
    /// The pager's view of the backup (pNext and the callbacks).
    hook: pager_mod.Backup = .{ .update = hookUpdate, .restart = hookRestart },
};

/// Port of findBtree(): the b-tree of database `name` of `db`, opening
/// TEMP if needed. Errors go to `err_db`.
fn findBtree(err_db: *Sqlite3, db: *Sqlite3, name: []const u8) ?*Btree {
    const i = build.findDbName(db, name) orelse {
        main_mod.errorWithMsg(err_db, RC.ERROR, "unknown database {s}", .{name});
        return null;
    };
    if (i == 1) {
        var arena: std.heap.ArenaAllocator = .init(db.gpa);
        defer arena.deinit();
        var p: int.Parse = .{ .db = db, .arena = arena.allocator() };
        build.openTempDatabase(&p) catch {
            main_mod.errorWithMsg(err_db, p.rc, "{s}", .{p.err_msg orelse ""});
            return null;
        };
    }
    return db.dbs.items[i].bt;
}

/// Port of setDestPgsz(): give the destination the page size of the
/// source, if it can still change.
fn setDestPgsz(dest: *Btree, src: *Btree) btree.Error!void {
    dest.setPageSize(src.getPageSize(), 0, false) catch |err| switch (err) {
        error.ReadOnly => {},
        else => return err,
    };
}

/// Port of checkReadTransaction(): no transaction may be open on the
/// destination.
fn checkReadTransaction(db: *Sqlite3, bt: *Btree) bool {
    if (bt.txnState() != .none) {
        main_mod.errorWithMsg(db, RC.ERROR, "destination database is in use", .{});
        return false;
    }
    return true;
}

/// Port of sqlite3_backup_init(): start copying database `src_name` of
/// `src_db` into database `dest_name` of `dest_db`. Null on error, which
/// is recorded on `dest_db`. Release the backup with finish().
pub fn init(dest_db: *Sqlite3, dest_name: []const u8, src_db: *Sqlite3, src_name: []const u8) ?*Backup {
    if (src_db == dest_db) {
        main_mod.errorWithMsg(dest_db, RC.ERROR, "source and destination must be distinct", .{});
        return null;
    }
    const name = malloc.allocator.dupeSentinel(u8, dest_name, 0) catch {
        main_mod.setError(dest_db, RC.NOMEM);
        return null;
    };
    // The destination b-tree is looked up again by each step(): it may
    // be detached meanwhile.
    const dest = findBtree(dest_db, dest_db, dest_name);
    const src = findBtree(dest_db, src_db, src_name);
    if (src == null or dest == null or !checkReadTransaction(dest_db, dest.?)) {
        malloc.allocator.free(name);
        return null;
    }
    const b = malloc.allocator.create(Backup) catch {
        malloc.allocator.free(name);
        main_mod.setError(dest_db, RC.NOMEM);
        return null;
    };
    b.* = .{ .dest_db = dest_db, .dest_name = name, .src_db = src_db, .src = src.? };
    b.src.n_backup += 1;
    return b;
}

/// Port of isFatalError(): BUSY and LOCKED let the backup try again.
fn isFatalError(rc: i32) bool {
    return rc != RC.OK and rc != RC.BUSY and rc != RC.LOCKED;
}

/// Port of backupOnePage(): copy source page `i_src_pg`, whose content is
/// `src_data`, to the destination pages it spans (or the part of the
/// destination page it covers). `update` is set when the page is copied
/// again because the source changed it.
fn backupOnePage(b: *Backup, i_src_pg: Pgno, src_data: []const u8, update: bool) btree.Error!void {
    const dest = b.dest.?;
    const dest_pager = dest.pager;
    const n_src_pgsz: i64 = b.src.getPageSize();
    const n_dest_pgsz: i64 = dest.getPageSize();
    const n_copy: usize = @intCast(@min(n_src_pgsz, n_dest_pgsz));
    const i_end: i64 = @as(i64, i_src_pg) * n_src_pgsz;
    std.debug.assert(b.dest_locked);
    std.debug.assert(!isFatalError(b.rc));
    std.debug.assert(i_src_pg != b.src.pager.lockPage());
    std.debug.assert(n_src_pgsz == n_dest_pgsz or !dest.isMemdb());

    // Once per destination page the source page spans: more than once
    // if the destination pages are smaller.
    var i_off = i_end - n_src_pgsz;
    while (i_off < i_end) : (i_off += n_dest_pgsz) {
        const i_dest: Pgno = @intCast(@divTrunc(i_off, n_dest_pgsz) + 1);
        if (i_dest == dest_pager.lockPage()) continue;
        const pg = try dest_pager.get(i_dest, .{});
        defer dest_pager.unref(pg);
        try dest_pager.write(pg);
        const in = src_data[@intCast(@mod(i_off, n_src_pgsz))..];
        const out = pg.data[@intCast(@mod(i_off, n_dest_pgsz))..];
        // The destination may use another page size: only the content
        // is copied, and the b-tree page is decoded again when used.
        @memcpy(out[0..n_copy], in[0..n_copy]);
        btree.MemPage.of(pg).is_init = false;
        if (i_off == 0 and !update) {
            std.mem.writeInt(u32, out[28..32], b.src.lastPage(), .big);
        }
    }
}

/// Port of backupTruncateFile(): make `file` no larger than `size`.
fn backupTruncateFile(file: vfs.File, size: u64) vfs.Error!void {
    const current = try file.fileSize();
    if (current > size) try file.truncate(size);
}

/// Port of attachBackupObject(): register with the source pager.
fn attachBackupObject(b: *Backup) void {
    const p = b.src.pager;
    b.hook.next = p.backup;
    p.backup = &b.hook;
    b.is_attached = true;
}

/// Port of sqlite3_backup_step(): copy up to `n_page` more pages (all of
/// them if negative). Returns OK while pages remain, DONE once the copy
/// is complete and committed, BUSY or LOCKED if a lock could not be had
/// (step() may be called again), or another error, which ends the backup.
pub fn step(b: *Backup, n_page: i32) i32 {
    var rc = b.rc;
    if (isFatalError(rc)) return rc;
    const src_pager = b.src.pager;
    var dest: ?*Btree = null;
    var n_src_page: i64 = -1;
    var close_trans = false;
    var dest_mode: pager_mod.JournalMode = .delete;
    var pgsz_src: u32 = 0;
    var pgsz_dest: u32 = 0;

    // The source connection is writing: try again later.
    rc = if (b.dest_db != null and b.src.in_trans == .write) RC.BUSY else RC.OK;

    // A read transaction on the source, closed again before returning if
    // opened here.
    if (rc == RC.OK and b.src.txnState() == .none) {
        rc = code(b.src.beginTrans(.read, 0));
        close_trans = true;
    }

    // The destination.
    dest = b.dest orelse if (b.dest_db) |ddb| findBtree(ddb, ddb, b.dest_name) else null;
    if (dest == null) rc = RC.ERROR;

    // On the first step, try to give the destination the source's page
    // size.
    if (!b.dest_locked and rc == RC.OK) {
        setDestPgsz(dest.?, b.src) catch |err| {
            if (err == error.OutOfMemory) rc = RC.NOMEM;
        };
    }

    // Lock the destination.
    if (rc == RC.OK and !b.dest_locked) {
        const n_savepoint: u32 = if (b.dest_db) |ddb| @intCast(ddb.n_savepoint) else 0;
        rc = code(dest.?.beginTrans(.exclusive, n_savepoint));
        if (rc == RC.OK) {
            b.i_dest_schema = dest.?.getMeta(.schema_version);
            b.dest_locked = true;
            b.dest = dest;
        }
    }

    // A destination in WAL mode (or kept in memory) cannot change its
    // page size.
    if (rc == RC.OK) {
        pgsz_src = b.src.getPageSize();
        pgsz_dest = b.dest.?.getPageSize();
        dest_mode = b.dest.?.pager.journal_mode;
        if ((dest_mode == .wal or b.dest.?.isMemdb()) and pgsz_src != pgsz_dest) rc = RC.READONLY;
    }

    // With the source read-locked, its size is known.
    n_src_page = b.src.lastPage();
    var ii: i32 = 0;
    while ((n_page < 0 or ii < n_page) and b.i_next <= n_src_page and rc == RC.OK) : (ii += 1) {
        const i_src_pg = b.i_next;
        if (i_src_pg != src_pager.lockPage()) {
            if (src_pager.get(i_src_pg, .{})) |pg| {
                defer src_pager.unref(pg);
                rc = code(backupOnePage(b, i_src_pg, pg.data, false));
            } else |err| rc = int.errorCode(err);
        }
        b.i_next += 1;
    }
    if (rc == RC.OK) {
        b.n_pagecount = @intCast(n_src_page);
        b.n_remaining = @intCast(n_src_page + 1 - b.i_next);
        if (b.i_next > n_src_page) {
            rc = RC.DONE;
        } else if (!b.is_attached) {
            attachBackupObject(b);
        }
    }

    // Done: commit the destination, with a schema cookie that changed
    // even if the source's is the same.
    if (rc == RC.DONE) {
        rc = finishCopy(b, &n_src_page, dest_mode, pgsz_src, pgsz_dest);
    }

    // Close the read transaction opened here; that cannot fail.
    if (close_trans) {
        b.src.commitPhaseOne() catch {};
        b.src.commitPhaseTwo(false) catch {};
    }
    if (rc == RC.IOERR_NOMEM) rc = RC.NOMEM;
    b.rc = rc;
    return rc;
}

/// The rc==SQLITE_DONE part of sqlite3_backup_step(): set the schema
/// cookie, size the destination and commit it. Returns DONE or an error.
fn finishCopy(b: *Backup, n_src_page_arg: *i64, dest_mode: pager_mod.JournalMode, pgsz_src: u32, pgsz_dest: u32) i32 {
    const dest = b.dest.?;
    const dest_pager = dest.pager;
    var rc: i32 = RC.DONE;
    if (n_src_page_arg.* == 0) {
        rc = code(dest.newDb());
        n_src_page_arg.* = 1;
    }
    const n_src_page = n_src_page_arg.*;
    if (rc == RC.OK or rc == RC.DONE) rc = code(dest.updateMeta(.schema_version, b.i_dest_schema +% 1));
    if (rc == RC.OK) {
        if (b.dest_db) |ddb| build.resetAllSchemasOfConnection(ddb);
        if (dest_mode == .wal) rc = code(dest.setVersion(2));
    }
    if (rc != RC.OK) return rc;

    // The final size of the destination in its own pages: rounded up if
    // those are larger, without ending on the lock page. The image is
    // truncated now so that the commit journals any page dropped.
    const lck_pgno: i64 = dest_pager.lockPage();
    var n_dest_truncate: i64 = undefined;
    if (pgsz_src < pgsz_dest) {
        const ratio: i64 = pgsz_dest / pgsz_src;
        n_dest_truncate = @divTrunc(n_src_page + ratio - 1, ratio);
        if (n_dest_truncate == lck_pgno) n_dest_truncate -= 1;
    } else {
        n_dest_truncate = n_src_page * (pgsz_src / pgsz_dest);
    }
    std.debug.assert(n_dest_truncate > 0);

    if (pgsz_src < pgsz_dest) {
        // The destination may need truncating, and the source pages
        // right after the lock-byte page copying into it. First journal
        // (and sync) every destination page that may change, so that
        // the file can then be written directly.
        const size: i64 = @as(i64, pgsz_src) * n_src_page;
        const file = dest_pager.fd;
        const n_dst_page = dest_pager.pageCount();
        var i_pg: Pgno = @intCast(n_dest_truncate);
        while (rc == RC.OK and i_pg <= n_dst_page) : (i_pg += 1) {
            if (i_pg == lck_pgno) continue;
            if (dest_pager.get(i_pg, .{})) |pg| {
                rc = code(dest_pager.write(pg));
                dest_pager.unref(pg);
            } else |err| rc = int.errorCode(err);
        }
        if (rc == RC.OK) rc = code(dest_pager.commitPhaseOne(true));

        // The extra pages, and the truncation.
        const end = @min(@as(i64, vfs.pending_byte) + pgsz_dest, size);
        const src_pager = b.src.pager;
        var off: i64 = @as(i64, vfs.pending_byte) + pgsz_src;
        while (rc == RC.OK and off < end) : (off += pgsz_src) {
            const i_src_pg: Pgno = @intCast(@divTrunc(off, pgsz_src) + 1);
            if (src_pager.get(i_src_pg, .{})) |pg| {
                defer src_pager.unref(pg);
                rc = code(file.write(pg.data, @intCast(off)));
            } else |err| rc = int.errorCode(err);
        }
        if (rc == RC.OK) rc = code(backupTruncateFile(file, @intCast(size)));
        // Sync the database file.
        if (rc == RC.OK) rc = code(dest_pager.syncDb());
    } else {
        dest_pager.truncateImage(@intCast(n_dest_truncate));
        rc = code(dest_pager.commitPhaseOne(false));
    }

    // Finish the commit.
    if (rc == RC.OK) {
        rc = code(dest.commitPhaseTwo(false));
        if (rc == RC.OK) rc = RC.DONE;
    }
    return rc;
}

/// The result code of a b-tree or pager call.
fn code(r: anytype) i32 {
    if (r) |_| return RC.OK else |err| return int.errorCode(err);
}

/// Port of sqlite3_backup_finish(): end the backup, rolling back the
/// destination if it is not complete, and free it. Returns OK if the
/// backup completed (or just has not failed), else its error, which is
/// also recorded on the destination connection.
pub fn finish(b_arg: ?*Backup) i32 {
    const b = b_arg orelse return RC.OK;
    const rc = release(b);
    if (b.dest_db) |ddb| {
        main_mod.setError(ddb, rc);
        malloc.allocator.free(b.dest_name);
        malloc.allocator.destroy(b);
    }
    return rc;
}

/// The part of finish() a copyFile() backup, which lives on the stack,
/// needs too.
fn release(b: *Backup) i32 {
    // Unregister from the source pager.
    if (b.dest_db != null) b.src.n_backup -= 1;
    if (b.is_attached) {
        var link = &b.src.pager.backup;
        while (link.* != &b.hook) link = &link.*.?.next;
        link.* = b.hook.next;
    }
    // Roll back a transaction still open on the destination.
    if (b.dest) |d| d.rollback(null, false) catch {};
    return if (b.rc == RC.DONE) RC.OK else b.rc;
}

/// Port of sqlite3_backup_remaining().
pub fn remaining(b: *const Backup) i32 {
    return @bitCast(b.n_remaining);
}

/// Port of sqlite3_backup_pagecount().
pub fn pagecount(b: *const Backup) i32 {
    return @bitCast(b.n_pagecount);
}

/// Port of backupUpdate(): source page `pgno` changed; copy it again if
/// it was copied already.
fn hookUpdate(h: *pager_mod.Backup, pgno: Pgno, data: []const u8) void {
    const b: *Backup = @fieldParentPtr("hook", h);
    if (!isFatalError(b.rc) and pgno < b.i_next) {
        std.debug.assert(b.dest_db != null);
        backupOnePage(b, pgno, data, true) catch |err| {
            b.rc = int.errorCode(err);
        };
    }
}

/// Port of sqlite3BackupRestart(): another connection changed the source;
/// copy everything again.
fn hookRestart(h: *pager_mod.Backup) void {
    const b: *Backup = @fieldParentPtr("hook", h);
    b.i_next = 1;
}

/// Port of sqlite3BtreeCopyFile(): copy all of `from` into `to`, both in
/// a transaction (a write transaction on `to`). The transaction on `to`
/// is committed on success, rolled back otherwise; `to` may shrink. Its
/// page size may change afterwards (VACUUM gives it that of `from`).
/// Returns a result code.
pub fn copyFile(to: *Btree, from: *Btree, db: *Sqlite3) i32 {
    std.debug.assert(to.txnState() == .write);
    // (SQLITE_FCNTL_OVERWRITE, which C sends here, is for VFSes the port
    // does not have.)
    var b: Backup = .{ .dest_db = null, .src_db = db, .src = from, .dest = to };
    // 0x7FFFFFFF, the most pages a database can have: one step copies
    // everything (unless it fails).
    _ = step(&b, 0x7FFFFFFF);
    std.debug.assert(b.rc != RC.OK);
    const rc = release(&b);
    if (rc == RC.OK) {
        to.page_size_fixed = false;
    } else {
        to.pager.clearCache();
    }
    std.debug.assert(to.txnState() != .write);
    return rc;
}
