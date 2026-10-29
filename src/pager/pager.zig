//! The pager (port of pager.c).
//!
//! The pager reads database pages into the page cache, tracks which ones a
//! write transaction modified, saves their original content to the rollback
//! journal before the database file is touched, and plays the journal back
//! on rollback or after a crash. The journal format (journal.zig) is
//! byte-compatible with SQLite, so either library can recover the other's
//! hot journals.
//!
//! In WAL mode (journal_mode=WAL, wal.zig) there is no rollback journal:
//! pages are read through the WAL, commits and cache spills append frames
//! to it, and a rollback just forgets the transaction's frames. The pager
//! then never goes past `writer_cachemod`, and keeps a SHARED lock on the
//! database file while the WAL is open, so that no one deletes the WAL.
//!
//! State machine (see the big comment at the top of pager.c):
//!
//!     open -> reader -> writer_locked -> writer_cachemod -> writer_dbmod
//!          -> writer_finished -> reader -> open
//!
//! plus `err`, entered when an I/O error leaves the cache untrustworthy.
//!
//! Savepoints (and the statement transactions built on them) save pages
//! changed after the savepoint opened to the sub-journal, which is kept in
//! memory (as with SQLITE_STMTJRNL_SPILL=-1).
//!
//! A transaction that writes several databases names a super journal in
//! each journal (commitPhaseOneSuper); recovery plays a journal back only
//! while its super journal exists.
//!
//! Backups reading the database (src/sql/backup.zig) hook into the pager
//! (Backup): they are told of every page written, and start over when
//! the cache is discarded.
//!
//! Not ported yet: journal_mode=MEMORY,
//! locking_mode=EXCLUSIVE (and with it the heap-memory WAL mode),
//! in-memory databases, mmap, WAL snapshots.

const std = @import("std");
const vfs = @import("../vfs/vfs.zig");
const pcache_mod = @import("pcache.zig");
const journal = @import("journal.zig");
const wal_mod = @import("wal.zig");
pub const wal = wal_mod;
const root = @import("../root.zig");

const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const PCache = pcache_mod.PCache;

pub const Page = pcache_mod.Page;
pub const Pgno = pcache_mod.Pgno;

pub const Error = wal_mod.Error || error{
    /// A hot journal must be rolled back but the database is read-only
    /// (SQLITE_READONLY_ROLLBACK).
    ReadOnlyRollback,
    /// A transaction with journal_mode=OFF was rolled back; the cache can no
    /// longer be trusted (SQLITE_ABORT).
    Abort,
};

/// SQLITE_MAX_PAGE_COUNT.
pub const max_page_count: Pgno = 0xfffffffe;

/// PAGER_JOURNALMODE_*, with SQLite's values.
pub const JournalMode = enum(u3) {
    /// Delete the journal at the end of each transaction.
    delete = 0,
    /// Keep the file but zero its header.
    persist = 1,
    /// No journal: rollback is impossible and a crash may corrupt the file.
    off = 2,
    /// Truncate the journal to zero bytes.
    truncate = 3,
    /// The journal is kept in memory. Not supported yet.
    memory = 4,
    /// Write-ahead log.
    wal = 5,

    /// sqlite3JournalModename().
    pub fn name(m: JournalMode) [:0]const u8 {
        return @tagName(m);
    }
};

pub const Synchronous = enum { off, normal, full, extra };

/// Returns true to retry.
pub const BusyHandler = wal_mod.BusyHandler;

/// What WAL closes and checkpoints need of the connection (C passes db to
/// sqlite3PagerClose() and sqlite3PagerCheckpoint()). The defaults suit a
/// pager used on its own.
pub const Conn = struct {
    /// Checked by checkpoints (db->u1.isInterrupted).
    interrupt: ?*const std.atomic.Value(bool) = null,
    /// Do not checkpoint the WAL on close (SQLITE_NoCkptOnClose).
    no_ckpt_on_close: bool = false,
};

pub const CheckpointMode = wal_mod.CheckpointMode;

pub const Options = struct {
    page_size: u32 = 4096,
    read_only: bool = false,
    /// Create the database file if it does not exist.
    create: bool = true,
    journal_mode: JournalMode = .delete,
    synchronous: Synchronous = .full,
    /// Use F_FULLFSYNC where available (PRAGMA fullfsync).
    full_fsync: bool = false,
    /// Bytes of per-page space for the layer above (nExtra).
    extra_size: u32 = 8,
    /// PRAGMA cache_size.
    cache_size: i32 = -2000,
    busy_handler: ?BusyHandler = null,
    /// Called after a page's content is restored during rollback (xReiniter).
    reiniter: ?*const fn (page: *Page) void = null,
};

pub const State = enum(u8) {
    open,
    reader,
    writer_locked,
    writer_cachemod,
    writer_dbmod,
    writer_finished,
    err,

    fn atLeast(a: State, b: State) bool {
        return @backingInt(a) >= @backingInt(b);
    }
};

/// SAVEPOINT_RELEASE and SAVEPOINT_ROLLBACK.
pub const SavepointOp = enum { release, rollback };

/// Port of PagerSavepoint.
const Savepoint = struct {
    /// Offset in the main journal of the first record written after the
    /// savepoint opened.
    offset: u64,
    /// Offset of the first journal header written after it, or 0.
    hdr_offset: u64 = 0,
    /// Pages already saved for the savepoint, in the main journal or the
    /// sub-journal (pInSavepoint).
    in_savepoint: std.AutoHashMapUnmanaged(Pgno, void) = .empty,
    /// Size of the image when it opened.
    n_orig: Pgno,
    /// Index of its first record in the sub-journal.
    i_sub_rec: u32,
    /// Releasing it may truncate the sub-journal: no later savepoint
    /// shares records with it (bTruncateOnRelease).
    truncate_on_release: bool = true,
    /// The WAL write position when it opened (aWalData).
    wal_data: wal_mod.SavepointData = .{ 0, 0, 0, 0 },
};

/// Size of a sub-journal record: a page number and the page.
fn subRecordSize(page_size: u32) u64 {
    return @as(u64, page_size) + 4;
}

/// A backup copying the database of a pager (sqlite3_backup as the pager
/// sees it; the list is Pager.pBackup): `update` is called with each page
/// written to the file or the WAL, `restart` when the cache is discarded
/// and what was copied may be stale.
pub const Backup = struct {
    next: ?*Backup = null,
    update: *const fn (b: *Backup, pgno: Pgno, data: []const u8) void,
    restart: *const fn (b: *Backup) void,
};

pub const GetFlags = struct {
    /// The caller will overwrite the page, so skip reading it (PAGER_GET_NOCONTENT).
    no_content: bool = false,
};

pub const Pager = struct {
    gpa: Allocator,
    vfs: vfs.Vfs,
    fd: vfs.File,
    jfd: ?vfs.File = null,
    /// Empty for a temporary database.
    path: []u8,
    journal_path: []u8,
    /// Name of the WAL file (zWal). Empty for a temporary database.
    wal_path: []u8,
    /// The open WAL, in WAL mode (pWal).
    wal: ?*wal_mod.Wal = null,
    /// Sync flags for the WAL (walSyncFlags): the low two bits for
    /// commits, the next two for checkpoints, each 0, 2 (normal) or 3
    /// (full), as wal.walSyncFlags() reads them.
    wal_sync_flags: u8 = 0,
    /// An anonymous temporary database (tempFile): its journal is anonymous
    /// too, and there is no hot journal to look for.
    temp_file: bool,

    state: State = .open,
    /// Lock held on the database file; null is UNKNOWN_LOCK, which arises
    /// when an unlock fails in the error state.
    lock: ?LockLevel = .none,
    err: ?Error = null,
    /// Why the last cache spill failed; reported by the fetch that needed it.
    spill_err: ?Error = null,

    read_only: bool,
    journal_mode: JournalMode,
    no_sync: bool = false,
    full_sync: bool = false,
    extra_sync: bool = false,
    sync_flags: vfs.SyncFlags = .{},
    /// Spilling is suspended during rollback (SPILLFLAG_ROLLBACK), and for
    /// pages needing a journal sync while a new journal header would be
    /// unsafe (SPILLFLAG_NOSYNC).
    no_spill_rollback: bool = false,
    no_spill_nosync: bool = false,
    /// PRAGMA cache_spill=OFF (SPILLFLAG_OFF).
    no_spill_off: bool = false,
    /// The change counter on page 1 has been bumped in this transaction.
    change_count_done: bool = false,
    busy_handler: ?BusyHandler,
    reiniter: ?*const fn (page: *Page) void,

    /// Size of the database image in pages.
    db_size: Pgno = 0,
    /// `db_size` when the write transaction started.
    db_orig_size: Pgno = 0,
    /// Size of the database file in pages, as far as we know.
    db_file_size: Pgno = 0,
    mx_pgno: Pgno = max_page_count,

    page_size: u32 = 0,
    n_reserve: u8 = 0,
    /// The page holding the lock bytes, which is never read or written.
    lck_pgno: Pgno = 0,
    sector_size: u32 = 512,

    /// Write offset in the journal.
    journal_off: u64 = 0,
    /// Offset of the current journal header.
    journal_hdr: u64 = 0,
    /// Page records written after the current header.
    n_rec: u32 = 0,
    /// The super-journal name is written into the journal (setSuper).
    set_super: bool = false,
    cksum_init: u32 = 0,
    /// PRAGMA journal_size_limit; negative means no limit.
    journal_size_limit: i64 = -1,
    /// Pages of the original image already saved in the journal. Only
    /// meaningful while `journal_on`; kept allocated across transactions.
    in_journal: std.AutoHashMapUnmanaged(Pgno, void) = .empty,
    journal_on: bool = false,

    /// Open savepoints, outermost first (aSavepoint).
    savepoints: std.ArrayListUnmanaged(Savepoint) = .empty,
    /// The sub-journal: records of a 4-byte page number and the page's
    /// content as it was when first written after a savepoint opened.
    sub_journal: std.ArrayListUnmanaged(u8) = .empty,
    /// Records in the sub-journal (nSubRec).
    n_sub_rec: u32 = 0,

    /// Bytes 24..39 of the database file as last seen. Used to detect writes
    /// by other connections.
    db_file_vers: [16]u8 = @splat(0),
    /// A shared lock has been held before (hasHeldSharedLock).
    has_held_shared_lock: bool = false,
    /// Bumped whenever the cache is discarded or a write commits.
    data_version: u32 = 0,

    /// Page-sized scratch buffer (+8 bytes of zero overrun).
    tmp_space: []u8 = &.{},
    /// One journal record, so each is written or read with a single call.
    record_buf: []u8 = &.{},
    cache: PCache,
    /// The backups reading this database (pBackup).
    backup: ?*Backup = null,

    // ================================================================ open

    /// Port of sqlite3PagerOpen(). A null path opens an anonymous temporary
    /// database, deleted on close.
    pub fn open(gpa: Allocator, v: vfs.Vfs, path_arg: ?[]const u8, opts: Options) Error!*Pager {
        const p = try gpa.create(Pager);
        errdefer gpa.destroy(p);

        // The database is known by its full name (sqlite3OsFullPathname()).
        const path_copy = if (path_arg) |a| try v.fullPathname(gpa, a) else try gpa.dupe(u8, "");
        errdefer gpa.free(path_copy);
        const path = path_copy;
        const journal_path = if (path_arg == null) try gpa.dupe(u8, "") else try std.mem.concat(gpa, u8, &.{ path, "-journal" });
        errdefer gpa.free(journal_path);
        const wal_path = if (path_arg == null) try gpa.dupe(u8, "") else try std.mem.concat(gpa, u8, &.{ path, "-wal" });
        errdefer gpa.free(wal_path);

        const fd = try v.open(if (path_arg != null) path else null, .{
            .kind = .main_db,
            .read_write = !opts.read_only,
            .create = opts.create and !opts.read_only,
        });
        errdefer fd.close();

        p.* = .{
            .gpa = gpa,
            .vfs = v,
            .fd = fd,
            .path = path_copy,
            .journal_path = journal_path,
            .wal_path = wal_path,
            .temp_file = path_arg == null,
            // The VFS may fall back to read-only (pOutFlags).
            .read_only = opts.read_only or fd.isReadOnly(),
            .journal_mode = opts.journal_mode,
            .busy_handler = opts.busy_handler,
            .reiniter = opts.reiniter,
            .cache = PCache.init(gpa, opts.page_size, std.mem.alignForward(u32, opts.extra_size, 8), .init(p, stressCallback)),
        };
        errdefer p.cache.deinit();
        p.cache.setCacheSize(opts.cache_size);
        p.setFlags(opts.synchronous, opts.full_fsync, false, true);
        p.setSectorSize();
        try p.setPageSize(opts.page_size, null);
        return p;
    }

    /// Port of sqlite3PagerClose(). Rolls back any open transaction; if that
    /// fails a hot journal is left for the next connection. In WAL mode,
    /// where no write transaction may be open, the last connection
    /// checkpoints and deletes the WAL unless `db` says not to.
    pub fn close(p: *Pager, db: Conn) void {
        if (p.wal) |w| {
            const buf: ?[]u8 = if (db.no_ckpt_on_close) null else p.tmp_space[0..p.page_size];
            w.close(db.interrupt, p.wal_sync_flags, buf) catch {};
            p.wal = null;
        }
        p.reset();
        if (p.jfd != null) {
            p.syncHotJournal() catch |err| p.noteError(err);
        }
        p.unlockAndRollback();
        if (p.jfd) |j| j.close();
        p.fd.close();
        p.in_journal.deinit(p.gpa);
        p.releaseAllSavepoints();
        p.savepoints.deinit(p.gpa);
        p.gpa.free(p.tmp_space);
        p.gpa.free(p.record_buf);
        p.cache.deinit();
        p.gpa.free(p.path);
        p.gpa.free(p.journal_path);
        p.gpa.free(p.wal_path);
        p.gpa.destroy(p);
    }

    /// Port of sqlite3PagerSetFlags(). `ckpt_full_fsync` is
    /// PAGER_CKPT_FULLFSYNC: full syncs for checkpoints.
    pub fn setFlags(p: *Pager, level: Synchronous, full_fsync: bool, ckpt_full_fsync: bool, cache_spill: bool) void {
        p.no_sync = p.temp_file or level == .off;
        p.full_sync = !p.no_sync and (level == .full or level == .extra);
        p.extra_sync = !p.no_sync and level == .extra;
        p.sync_flags = .{ .full = !p.no_sync and full_fsync };
        // SQLITE_SYNC_NORMAL is 2, SQLITE_SYNC_FULL 3.
        const sync: u8 = if (p.no_sync) 0 else if (full_fsync) 3 else 2;
        p.wal_sync_flags = sync << 2;
        if (p.full_sync) p.wal_sync_flags |= sync;
        if (ckpt_full_fsync and !p.no_sync) p.wal_sync_flags |= 3 << 2;
        // PAGER_CACHESPILL: dirty pages may be spilled before commit.
        p.no_spill_off = !cache_spill;
    }

    pub fn setCacheSize(p: *Pager, n: i32) void {
        p.cache.setCacheSize(n);
    }

    pub fn setSpillSize(p: *Pager, n: i32) u32 {
        return p.cache.setSpillSize(n);
    }

    /// Port of sqlite3PagerSetJournalMode(). MEMORY is not supported yet
    /// and leaves the mode unchanged. Opening and closing the WAL is the
    /// caller's (OP_JournalMode's) business. Returns the mode in effect.
    pub fn setJournalMode(p: *Pager, mode_arg: JournalMode) JournalMode {
        const old = p.journal_mode;
        std.debug.assert(!p.temp_file or mode_arg != .wal);
        const mode = switch (mode_arg) {
            .memory => old,
            else => mode_arg,
        };
        if (mode == old) return old;
        std.debug.assert(p.state != .err);
        p.journal_mode = mode;
        const old_bits = @backingInt(old);
        const new_bits = @backingInt(mode);
        if (old_bits & 5 == 1 and new_bits & 1 == 0) {
            // Leaving TRUNCATE or PERSIST for DELETE or OFF: delete the
            // journal, under at least a RESERVED lock so that no other
            // connection mistakes it for a hot journal meanwhile.
            if (p.jfd) |j| j.close();
            p.jfd = null;
            if (p.temp_file) return mode;
            if (p.lock != null and p.lock.?.atLeast(.reserved)) {
                p.vfs.delete(p.journal_path, false) catch {};
            } else {
                const state = p.state;
                var ok = true;
                if (state == .open) p.sharedLock() catch {
                    ok = false;
                };
                if (ok and p.state == .reader) p.lockDb(.reserved) catch {
                    ok = false;
                };
                if (ok) p.vfs.delete(p.journal_path, false) catch {};
                if (ok and state == .reader) {
                    p.unlockDb(.shared) catch {};
                } else if (state == .open) {
                    p.unlock();
                }
            }
        } else if (mode == .off) {
            if (p.jfd) |j| j.close();
            p.jfd = null;
        }
        return mode;
    }

    /// Port of sqlite3PagerOkToChangeJournalMode(): not while a write
    /// transaction has changed the cache.
    pub fn okToChangeJournalMode(p: *const Pager) bool {
        if (p.state.atLeast(.writer_cachemod)) return false;
        return !(p.jfd != null and p.journal_off > 0);
    }

    /// Port of sqlite3PagerJournalSizeLimit(): set the limit if `limit` >=
    /// -1 (negative means no limit), and return it.
    pub fn journalSizeLimit(p: *Pager, limit: i64) i64 {
        if (limit >= -1) {
            p.journal_size_limit = limit;
            if (p.wal) |w| w.setLimit(limit);
        }
        return p.journal_size_limit;
    }

    /// Port of sqlite3PagerMaxPageCount(): set the largest page count if
    /// `mx` is not 0, and return it.
    pub fn maxPageCount(p: *Pager, mx: Pgno) Pgno {
        if (mx > 0) p.mx_pgno = mx;
        std.debug.assert(p.state != .open);
        return p.mx_pgno;
    }

    /// Bumped whenever the content seen by this connection may have changed
    /// (sqlite3PagerDataVersion).
    pub fn dataVersion(p: *const Pager) u32 {
        return p.data_version;
    }

    /// Port of setSectorSize(). With POWERSAFE_OVERWRITE a crash cannot
    /// damage bytes we did not write, so the minimum of 512 is used.
    fn setSectorSize(p: *Pager) void {
        p.sector_size = if (p.fd.deviceCharacteristics().powersafe_overwrite)
            512
        else
            journal.sectorSize(p.fd.sectorSize());
    }

    /// Port of sqlite3PagerSetPagesize(). Takes effect only when no page is
    /// referenced. `reserve` null keeps the current reserve.
    pub fn setPageSize(p: *Pager, page_size: u32, reserve: ?u8) Error!void {
        std.debug.assert(std.math.isPowerOfTwo(page_size) and page_size >= 512 and page_size <= 65536);
        if (p.cache.refCount() == 0 and page_size != p.page_size) {
            var n_byte: u64 = 0;
            if (p.state.atLeast(.reader)) n_byte = try p.fd.fileSize();
            const tmp = try p.gpa.alloc(u8, page_size + 8);
            errdefer p.gpa.free(tmp);
            const rec = try p.gpa.alloc(u8, journal.recordSize(page_size));
            @memset(tmp[page_size..], 0);
            p.reset();
            p.cache.setPageSize(page_size);
            p.gpa.free(p.tmp_space);
            p.gpa.free(p.record_buf);
            p.tmp_space = tmp;
            p.record_buf = rec;
            p.db_size = @intCast(std.math.divCeil(u64, n_byte, page_size) catch unreachable);
            p.page_size = page_size;
            p.lck_pgno = @intCast(vfs.pending_byte / page_size + 1);
        }
        if (reserve) |r| p.n_reserve = r;
    }

    /// Port of sqlite3PagerReadFileheader(). A file shorter than `buf`
    /// reads as zeros.
    pub fn readFileHeader(p: *Pager, buf: []u8) Error!void {
        try readPadded(p.fd, buf, 0);
    }

    /// Number of pages in the database image. Requires a read transaction.
    pub fn pageCount(p: *const Pager) Pgno {
        std.debug.assert(p.state.atLeast(.reader) and p.state != .writer_finished);
        return p.db_size;
    }

    /// The page holding the lock bytes is never part of the image.
    pub fn isLockPage(p: *const Pager, pgno: Pgno) bool {
        return pgno == p.lck_pgno;
    }

    pub fn lockPage(p: *const Pager) Pgno {
        return p.lck_pgno;
    }

    pub fn refCount(p: *const Pager) u64 {
        return p.cache.refCount();
    }

    // ============================================================= locking

    /// Port of pagerLockDb().
    fn lockDb(p: *Pager, level: LockLevel) Error!void {
        if (p.lock) |held| if (held.atLeast(level)) return;
        try p.fd.lock(level);
        if (p.lock != null or level == .exclusive) p.lock = level;
    }

    /// Port of pagerUnlockDb(). The recorded lock follows the attempt even
    /// if the unlock fails.
    fn unlockDb(p: *Pager, level: LockLevel) Error!void {
        defer p.change_count_done = false;
        const r = p.fd.unlock(level);
        if (p.lock != null) p.lock = level;
        return r;
    }

    /// Port of pager_wait_on_lock(): retry through the busy handler.
    fn waitOnLock(p: *Pager, level: LockLevel) Error!void {
        while (true) {
            p.lockDb(level) catch |err| {
                if (err == error.Busy) {
                    if (p.busy_handler) |h| if (h.call(.{})) continue;
                }
                return err;
            };
            return;
        }
    }

    /// Enters the error state: nothing but unlocking is possible until the
    /// last page reference is dropped.
    fn enterError(p: *Pager, err: Error) void {
        p.err = err;
        p.state = .err;
    }

    /// Port of pager_error(): only I/O failures poison the cache.
    fn noteError(p: *Pager, err: Error) void {
        switch (err) {
            error.IoErr, error.ShortRead, error.LockErr, error.DiskFull => p.enterError(err),
            else => {},
        }
    }

    fn setError(p: *Pager, err: Error) Error {
        p.noteError(err);
        return err;
    }

    /// Port of pager_reset(): discard the whole cache.
    fn reset(p: *Pager) void {
        p.data_version +%= 1;
        p.backupRestart();
        p.cache.clear();
    }

    /// Port of sqlite3BackupUpdate(): page `pgno` now holds `data`.
    fn backupUpdate(p: *Pager, pgno: Pgno, data: []const u8) void {
        var it = p.backup;
        while (it) |b| : (it = b.next) b.update(b, pgno, data);
    }

    /// Port of sqlite3BackupRestart().
    fn backupRestart(p: *Pager) void {
        var it = p.backup;
        while (it) |b| : (it = b.next) b.restart(b);
    }

    /// Port of sqlite3PagerClearCache(): discard the cache.
    pub fn clearCache(p: *Pager) void {
        p.reset();
    }

    fn inJournal(p: *const Pager, pgno: Pgno) bool {
        return p.journal_on and p.in_journal.contains(pgno);
    }

    /// Records that `pgno` needs no journaling. Failing to record it only
    /// costs a redundant journal write later, as with sqlite3BitvecSet.
    fn markInJournal(p: *Pager, pgno: Pgno) void {
        if (p.journal_on) p.in_journal.put(p.gpa, pgno, {}) catch {};
    }

    fn stopJournaling(p: *Pager) void {
        p.journal_on = false;
        p.in_journal.clearRetainingCapacity();
    }

    /// Whether playback may write to the database file: only once it is
    /// being modified, or during hot-journal recovery.
    fn mayWriteDb(p: *const Pager) bool {
        return p.state.atLeast(.writer_dbmod) or p.state == .open;
    }

    /// Port of pager_unlock(): drop every lock and return to `open`. In WAL
    /// mode only the WAL read lock is dropped; the SHARED lock on the
    /// database stays while the WAL is open.
    fn unlock(p: *Pager) void {
        p.stopJournaling();
        p.releaseAllSavepoints();
        if (p.wal) |w| {
            std.debug.assert(p.jfd == null);
            // An I/O error while restarting the WAL may leave the write
            // lock held without a read lock.
            if (p.state == .err) w.endWriteTransaction();
            w.endReadTransaction();
        } else {
            // Close the journal so that another connection in DELETE mode
            // can delete it, unless the OS refuses to delete open files
            // and the journal is meant to persist anyway.
            const keep_open = p.fd.deviceCharacteristics().undeletable_when_open and
                (p.journal_mode == .truncate or p.journal_mode == .persist);
            if (!keep_open) {
                if (p.jfd) |j| j.close();
                p.jfd = null;
            }
            p.unlockDb(.none) catch {
                if (p.state == .err) p.lock = null;
            };
        }
        p.state = .open;
        if (p.err != null) {
            p.reset();
            p.change_count_done = false;
            p.err = null;
        }
        p.journal_off = 0;
        p.journal_hdr = 0;
        p.set_super = false;
    }

    /// Port of pagerUnlockAndRollback().
    fn unlockAndRollback(p: *Pager) void {
        if (p.state != .err and p.state != .open) {
            if (p.state.atLeast(.writer_locked)) {
                p.rollback() catch {};
            } else {
                p.endTransaction(false, false) catch {};
            }
        }
        p.unlock();
    }

    /// Port of pagerUnlockIfUnused().
    fn unlockIfUnused(p: *Pager) void {
        if (p.cache.refCount() == 0) p.unlockAndRollback();
    }

    // ===================================================== read transaction

    /// Port of sqlite3PagerSharedLock(). Takes a SHARED lock, rolls back a
    /// hot journal if one is found, and discards the cache if another
    /// connection changed the file. Must be called with no page referenced.
    pub fn sharedLock(p: *Pager) Error!void {
        std.debug.assert(p.cache.refCount() == 0);
        std.debug.assert(p.state == .open or p.state == .reader);
        if (p.state == .open) {
            p.sharedLockOpen() catch |err| {
                p.unlock();
                return err;
            };
        }
        p.state = .reader;
    }

    fn sharedLockOpen(p: *Pager) Error!void {
        if (p.wal == null) try p.sharedLockRollback();
        if (p.wal != null) try p.beginReadTransaction();
        if (!p.temp_file and p.state == .open) p.db_size = try p.pagecountFromFile();
        p.has_held_shared_lock = true;
    }

    /// The rollback-mode part of sqlite3PagerSharedLock(): take SHARED,
    /// roll back a hot journal, check for changes, and switch to WAL mode
    /// if a WAL exists.
    fn sharedLockRollback(p: *Pager) Error!void {
        try p.waitOnLock(.shared);

        // With an UNKNOWN lock, assume the worst and treat the journal as hot.
        const hot = if (p.temp_file)
            false
        else if (p.lock) |held| held.atLeast(.reserved) or try p.hasHotJournal() else true;
        if (hot) {
            if (p.read_only) return error.ReadOnlyRollback;
            // Go straight to EXCLUSIVE. Passing through RESERVED would tell
            // other connections the file is safe to read mid-rollback.
            try p.lockDb(.exclusive);
            if (p.jfd == null and p.journal_mode != .off) {
                if (try p.vfs.access(p.journal_path, .exists)) {
                    p.jfd = try p.vfs.open(p.journal_path, .{ .kind = .main_journal });
                }
            }
            if (p.jfd != null) {
                // The crashed writer may not have synced the journal, and
                // we must never play back unsynced content.
                p.syncHotJournal() catch |err| return p.setError(err);
                p.playback(true) catch |err| return p.setError(err);
                p.state = .open;
            } else {
                try p.unlockDb(.shared);
            }
        }

        // Another connection may have written since our last transaction.
        // Not checked on the very first access (hasHeldSharedLock), when
        // the cache is empty anyway, so that data_version starts at 1.
        if (!p.temp_file and p.has_held_shared_lock) {
            var vers: [16]u8 = undefined;
            try readPadded(p.fd, &vers, 24);
            if (!std.mem.eql(u8, &p.db_file_vers, &vers)) p.reset();
        }

        // A WAL in the file system means WAL mode.
        try p.openWalIfPresent();
    }

    /// Port of pagerPagecount(): the database size, from the WAL snapshot
    /// if it knows it, else from the file size.
    fn pagecountFromFile(p: *Pager) Error!Pgno {
        var n: Pgno = wal_mod.Wal.dbsize(p.wal);
        if (n == 0) {
            const n_byte = try p.fd.fileSize();
            n = @intCast(std.math.divCeil(u64, n_byte, p.page_size) catch unreachable);
        }
        if (n > p.mx_pgno) p.mx_pgno = n;
        return n;
    }

    /// Port of hasHotJournal(). A journal is hot if it exists, nobody holds
    /// RESERVED, the database is not empty and the journal's first byte is
    /// not zero. May give a false positive, which playback detects.
    fn hasHotJournal(p: *Pager) Error!bool {
        const jrnl_open = p.jfd != null;
        if (!jrnl_open and !try p.vfs.access(p.journal_path, .exists)) return false;
        if (try p.fd.checkReservedLock()) return false;

        const n_page = try p.pagecountFromFile();
        if (n_page == 0 and !jrnl_open) {
            // Leftover from a deleted database, or the rollback of the
            // transaction that created this one. Either way, discard it.
            if (p.lockDb(.reserved)) |_| {
                p.vfs.delete(p.journal_path, false) catch {};
                p.unlockDb(.shared) catch {};
            } else |_| {}
            return false;
        }

        const j = p.jfd orelse p.vfs.open(p.journal_path, .{
            .kind = .main_journal,
            .read_write = false,
        }) catch |err| switch (err) {
            // Possibly a race with a writer deleting it; assume hot and let
            // playback sort it out under the EXCLUSIVE lock.
            error.CantOpen => return true,
            else => return err,
        };
        defer if (!jrnl_open) j.close();
        var first: [1]u8 = undefined;
        try readPadded(j, &first, 0);
        return first[0] != 0;
    }

    fn syncHotJournal(p: *Pager) Error!void {
        const j = p.jfd.?;
        if (!p.no_sync) try j.sync(.{});
        p.journal_hdr = try j.fileSize();
    }

    // ================================================================ pages

    /// Port of getPageNormal(). Returns a referenced page; release it with
    /// `unref` (or `unrefPageOne` for page 1).
    pub fn get(p: *Pager, pgno: Pgno, flags: GetFlags) Error!*Page {
        if (p.err) |e| return e;
        std.debug.assert(p.state.atLeast(.reader));
        if (pgno == 0) return error.Corrupt;

        const pg = p.cache.fetch(pgno) catch |err| {
            p.unlockIfUnused();
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SpillFailed => p.takeSpillError(),
            };
        };
        if (pg.owner != null and !flags.no_content) return pg;

        p.loadPage(pg, flags) catch |err| {
            if (err == error.DiskFull and pgno <= p.db_size) {
                p.cache.release(pg);
            } else {
                p.cache.drop(pg);
            }
            p.unlockIfUnused();
            return err;
        };
        return pg;
    }

    fn takeSpillError(p: *Pager) Error {
        defer p.spill_err = null;
        return p.spill_err.?;
    }

    fn loadPage(p: *Pager, pg: *Page, flags: GetFlags) Error!void {
        if (p.isLockPage(pg.pgno)) return error.Corrupt;
        pg.owner = p;
        if (p.db_size < pg.pgno or flags.no_content) {
            if (pg.pgno > p.mx_pgno) return error.DiskFull;
            // The page will be overwritten; no need to journal its old
            // content.
            if (flags.no_content) {
                if (pg.pgno <= p.db_orig_size) p.markInJournal(pg.pgno);
                // Benign if it fails, as for the journal.
                p.addToSavepoints(pg.pgno) catch {};
            }
            @memset(pg.data, 0);
        } else {
            try p.readDbPage(pg);
        }
    }

    /// Port of readDbPage(): read the page from the WAL if the snapshot has
    /// it there, else from the database file. Reading past the end of the
    /// file yields zeros.
    fn readDbPage(p: *Pager, pg: *Page) wal_mod.Error!void {
        p.readDbPageInner(pg) catch |err| {
            if (pg.pgno == 1) @memset(&p.db_file_vers, 0xff);
            return err;
        };
        if (pg.pgno == 1) @memcpy(&p.db_file_vers, pg.data[24..40]);
    }

    fn readDbPageInner(p: *Pager, pg: *Page) wal_mod.Error!void {
        if (p.wal) |w| {
            const frame = try w.findFrame(pg.pgno);
            if (frame != 0) return w.readFrame(frame, pg.data);
        }
        try readPadded(p.fd, pg.data, @as(u64, pg.pgno - 1) * p.page_size);
    }

    /// Port of sqlite3PagerLookup(): a referenced page if cached, else null.
    pub fn lookup(p: *Pager, pgno: Pgno) ?*Page {
        return p.cache.lookup(pgno);
    }

    /// Releases a page other than the last reference to page 1.
    pub fn unref(p: *Pager, pg: *Page) void {
        p.cache.release(pg);
        std.debug.assert(p.cache.refCount() > 0);
    }

    /// Releases page 1. When nothing is referenced any more, ends the read
    /// transaction (rolling back any open write transaction).
    pub fn unrefPageOne(p: *Pager, pg: *Page) void {
        std.debug.assert(pg.pgno == 1);
        p.cache.release(pg);
        p.unlockIfUnused();
    }

    pub fn ref(p: *Pager, pg: *Page) void {
        p.cache.ref(pg);
    }

    /// Exchanges the page numbers of two referenced, writable pages; the
    /// b-tree does this to keep sibling pages in ascending order. Done as
    /// in balance_nonroot(), with three sqlite3PagerRekey() calls through
    /// the lock page, which is never cached.
    pub fn swapPageNumbers(p: *Pager, a: *Page, b: *Page) void {
        const pgno_a = a.pgno;
        const pgno_b = b.pgno;
        const flags_a = a.flags;
        const flags_b = b.flags;
        p.rekey(a, p.lck_pgno, flags_b);
        p.rekey(b, pgno_a, flags_a);
        p.rekey(a, pgno_b, flags_b);
    }

    /// Port of sqlite3PagerMovepage(): move the referenced page `pg` to
    /// location `pgno`, discarding whatever was cached there (it must not
    /// be referenced elsewhere). The page's extra data is the caller's to
    /// update. `is_commit` promises the old location is not written again
    /// in this transaction, so its pending journal sync can be forgotten.
    pub fn movePage(p: *Pager, pg: *Page, pgno: Pgno, is_commit: bool) Error!void {
        std.debug.assert(pg.n_ref > 0);
        std.debug.assert(p.state == .writer_cachemod or p.state == .writer_dbmod);
        if (p.temp_file) try p.write(pg);
        // A dirty page not yet saved for the latest savepoint is saved now,
        // under its old number.
        if (pg.flags.dirty) try p.subjournalPageIfRequired(pg);

        // The journal must be synced before the old location is written:
        // remember to keep that requirement on whatever lands there.
        const need_sync_pgno: Pgno = if (pg.flags.need_sync and !is_commit) pg.pgno else 0;
        pg.flags.need_sync = false;
        if (p.lookup(pgno)) |old| {
            if (old.n_ref > 1) {
                p.unref(old);
                return error.Corrupt;
            }
            pg.flags.need_sync = old.flags.need_sync;
            p.cache.drop(old);
        }
        p.cache.move(pg, pgno);
        p.cache.makeDirty(pg);

        if (need_sync_pgno != 0) {
            const moved = p.get(need_sync_pgno, .{}) catch |err| {
                // Let a later write journal it again rather than reach the
                // file before the journal is synced.
                if (need_sync_pgno <= p.db_orig_size) _ = p.in_journal.remove(need_sync_pgno);
                return err;
            };
            moved.flags.need_sync = true;
            p.cache.makeDirty(moved);
            p.unref(moved);
        }
    }

    /// Port of sqlite3PagerRekey().
    fn rekey(p: *Pager, pg: *Page, pgno: Pgno, flags: pcache_mod.Flags) void {
        std.debug.assert(pg.pgno != pgno);
        pg.flags = flags;
        p.cache.move(pg, pgno);
    }

    /// Page-sized scratch space (sqlite3PagerTempSpace). Its content is
    /// clobbered by any pager call that rolls back or spills.
    pub fn tempSpace(p: *Pager) []u8 {
        return p.tmp_space[0..p.page_size];
    }

    pub fn isReadOnly(p: *const Pager) bool {
        return p.read_only;
    }

    // ==================================================== write transaction

    /// Port of sqlite3PagerBegin(). Takes RESERVED (or EXCLUSIVE when
    /// `exclusive`) and enters `writer_locked`. A no-op if already writing.
    pub fn begin(p: *Pager, exclusive: bool) Error!void {
        if (p.err) |e| return e;
        std.debug.assert(p.state.atLeast(.reader) and p.state != .err);
        if (p.state != .reader) return;
        if (p.read_only) return error.ReadOnly;
        if (p.wal) |w| {
            // The busy handler is not invoked if another connection holds
            // the write lock; the b-tree may invoke it.
            try w.beginWriteTransaction();
        } else {
            try p.lockDb(.reserved);
            if (exclusive) try p.waitOnLock(.exclusive);
        }
        // WAL mode never goes past writer_cachemod: in writer_dbmod a
        // savepoint rollback could write the sub-journal to the database.
        p.state = .writer_locked;
        p.db_file_size = p.db_size;
        p.db_orig_size = p.db_size;
        p.journal_off = 0;
    }

    /// Port of pager_open_journal(): open the journal and write its first
    /// header. Called on the first write of a transaction.
    fn openJournal(p: *Pager) Error!void {
        std.debug.assert(p.state == .writer_locked);
        if (p.wal == null and p.journal_mode != .off) {
            p.journal_on = true;
            errdefer {
                p.stopJournaling();
                p.journal_off = 0;
            }
            if (p.jfd == null) {
                p.jfd = if (p.temp_file)
                    try p.vfs.open(null, .{ .kind = .temp_journal })
                else
                    try p.vfs.open(p.journal_path, .{ .kind = .main_journal, .create = true });
            }
            p.n_rec = 0;
            p.journal_off = 0;
            p.set_super = false;
            p.journal_hdr = 0;
            try p.writeJournalHdr();
        }
        p.state = .writer_cachemod;
    }

    /// Port of sqlite3PagerWrite(). Must be called before modifying a page.
    /// Journals the original content the first time a page is written.
    pub fn write(p: *Pager, pg: *Page) Error!void {
        std.debug.assert(p.state.atLeast(.writer_locked));
        if (pg.flags.writeable and p.db_size >= pg.pgno) {
            if (p.savepoints.items.len > 0) return p.subjournalPageIfRequired(pg);
            return;
        }
        if (p.err) |e| return e;
        if (p.sector_size > p.page_size) return p.writeLargeSector(pg);
        return p.writeOne(pg);
    }

    /// Port of pager_write().
    fn writeOne(p: *Pager, pg: *Page) Error!void {
        std.debug.assert(!p.read_only);
        // Open the journal before marking the page dirty, so that a failure
        // cannot leave dirty pages in `writer_locked`.
        if (p.state == .writer_locked) try p.openJournal();
        p.cache.makeDirty(pg);

        if (p.journal_on and !p.in_journal.contains(pg.pgno)) {
            if (pg.pgno <= p.db_orig_size) {
                try p.addToJournal(pg);
            } else if (p.state != .writer_dbmod) {
                // A new page past the original end. Nothing to journal, but
                // writing it before the journal is synced could still let a
                // crash leave a half-updated file.
                pg.flags.need_sync = true;
            }
        }
        pg.flags.writeable = true;
        // Save the page for the savepoints that do not have it yet.
        if (p.savepoints.items.len > 0) try p.subjournalPageIfRequired(pg);
        if (p.db_size < pg.pgno) p.db_size = pg.pgno;
    }

    /// Port of pagerAddPageToRollbackJournal().
    fn addToJournal(p: *Pager, pg: *Page) Error!void {
        std.debug.assert(!p.isLockPage(pg.pgno));
        // Set before writing: even a partially written record must be
        // synced before the page reaches the database file.
        pg.flags.need_sync = true;
        journal.encodeRecord(p.record_buf, pg.pgno, pg.data, p.cksum_init);
        try p.jfd.?.write(p.record_buf, p.journal_off);
        p.journal_off += p.record_buf.len;
        p.n_rec += 1;
        p.markInJournal(pg.pgno);
        try p.addToSavepoints(pg.pgno);
    }

    /// Port of pagerWriteLargeSector(). When several pages share a disk
    /// sector, a torn write can damage all of them, so all are journaled.
    fn writeLargeSector(p: *Pager, pg: *Page) Error!void {
        std.debug.assert(!p.no_spill_nosync);
        p.no_spill_nosync = true;
        defer p.no_spill_nosync = false;

        const per_sector: Pgno = p.sector_size / p.page_size;
        const first: Pgno = ((pg.pgno - 1) & ~(per_sector - 1)) + 1;
        const end: Pgno = if (pg.pgno > p.db_size)
            pg.pgno + 1
        else
            @min(first + per_sector, p.db_size + 1);

        var need_sync = false;
        var pgno = first;
        while (pgno < end) : (pgno += 1) {
            if (pgno == pg.pgno or !p.inJournal(pgno)) {
                if (p.isLockPage(pgno)) continue;
                const page = try p.get(pgno, .{});
                defer p.unref(page);
                try p.writeOne(page);
                if (page.flags.need_sync) need_sync = true;
            } else if (p.lookup(pgno)) |page| {
                if (page.flags.need_sync) need_sync = true;
                p.unref(page);
            }
        }
        if (need_sync) {
            pgno = first;
            while (pgno < end) : (pgno += 1) {
                const page = p.lookup(pgno) orelse continue;
                page.flags.need_sync = true;
                p.unref(page);
            }
        }
    }

    /// Port of sqlite3PagerDontWrite(): the page's content no longer matters
    /// (e.g. it became a freelist leaf), so skip writing it.
    pub fn dontWrite(p: *Pager, pg: *Page) void {
        // A savepoint rollback may still need the page's content.
        if (!p.temp_file and pg.flags.dirty and p.savepoints.items.len == 0) {
            pg.flags.dont_write = true;
            pg.flags.writeable = false;
        }
    }

    /// Port of sqlite3PagerTruncateImage(). Shrinks the image; the file is
    /// truncated at commit.
    pub fn truncateImage(p: *Pager, n_page: Pgno) void {
        std.debug.assert(p.state.atLeast(.writer_cachemod));
        p.db_size = n_page;
    }

    // ================================================================= WAL

    /// pagerUseWal().
    pub fn useWal(p: *const Pager) bool {
        return p.wal != null;
    }

    /// Port of sqlite3PagerWalSupported(): whether the VFS has the shared
    /// memory WAL mode needs (exclusive locking mode is not ported).
    pub fn walSupported(p: *const Pager) bool {
        return p.fd.hasShm();
    }

    /// Port of pagerUndoCallback(): a page the rolled-back transaction
    /// wrote to the WAL is discarded from the cache, or reloaded if it is
    /// still referenced. Backups start over: they may have copied what
    /// the transaction wrote to the WAL.
    fn undoCallback(p: *Pager, pgno: Pgno) wal_mod.Error!void {
        std.debug.assert(p.wal != null);
        defer p.backupRestart();
        const pg = p.lookup(pgno) orelse return;
        if (pg.n_ref == 1) {
            p.cache.drop(pg);
        } else {
            defer p.cache.release(pg);
            try p.readDbPage(pg);
            if (p.reiniter) |r| r(pg);
        }
    }

    /// Port of pagerRollbackWal(): forget the transaction's frames and
    /// revert every page it changed, cached or already in the WAL.
    fn rollbackWal(p: *Pager) Error!void {
        p.db_size = p.db_orig_size;
        const cb: wal_mod.UndoCallback = .init(p, undoCallback);
        try p.wal.?.undo(cb);
        var it = p.cache.dirtyList();
        while (it) |pg| {
            it = pg.dirty;
            try undoCallback(p, pg.pgno);
        }
    }

    /// Port of pagerWalFrames(): write the pages of `list` (sorted by page
    /// number) to the WAL. A commit leaves out pages past the new end of
    /// the database and stamps the change counter on page 1.
    fn walFrames(p: *Pager, list_arg: *Page, n_truncate: Pgno, is_commit: bool) Error!void {
        std.debug.assert(list_arg.dirty == null or is_commit);
        var list: ?*Page = list_arg;
        if (is_commit) {
            // Pages past the end are never read again; drop them.
            var link: *?*Page = &list;
            var it: ?*Page = list_arg;
            while (it) |pg| : (it = pg.dirty) {
                link.* = pg;
                if (pg.pgno <= n_truncate) link = &pg.dirty;
            }
            link.* = null;
        }
        const head = list orelse return;
        if (head.pgno == 1) p.writeChangeCounter(head);
        try p.wal.?.frames(p.page_size, head, n_truncate, is_commit, p.wal_sync_flags);
        if (p.backup != null) {
            var it: ?*Page = head;
            while (it) |pg| : (it = pg.dirty) p.backupUpdate(pg.pgno, pg.data);
        }
    }

    /// Port of pagerBeginReadTransaction(): take a WAL snapshot, discarding
    /// the cache if the database changed since the last one.
    fn beginReadTransaction(p: *Pager) Error!void {
        const w = p.wal.?;
        std.debug.assert(p.state == .open or p.state == .reader);
        // The previous read transaction may still be open (as in
        // exclusive locking mode); ending it again is harmless.
        w.endReadTransaction();
        const changed = w.beginReadTransaction() catch |err| {
            p.reset();
            return err;
        };
        if (changed) p.reset();
    }

    /// Port of pagerOpenWalIfPresent(): with a SHARED lock held, open the
    /// WAL if one exists and the database is not empty, deleting a WAL
    /// left next to an empty database. Without a WAL, a journal_mode of
    /// WAL falls back to DELETE.
    fn openWalIfPresent(p: *Pager) Error!void {
        std.debug.assert(p.state == .open);
        if (p.temp_file) return;
        if (try p.vfs.access(p.wal_path, .exists)) {
            const n_page = try p.pagecountFromFile();
            if (n_page == 0) {
                try p.vfs.delete(p.wal_path, false);
            } else {
                _ = try p.openWal();
            }
        } else if (p.journal_mode == .wal) {
            p.journal_mode = .delete;
        }
    }

    /// Port of pagerOpenWal(): open the WAL on the shared memory.
    fn openWalHandle(p: *Pager) Error!void {
        std.debug.assert(p.wal == null and !p.temp_file);
        std.debug.assert(p.lock == .shared or p.lock == .exclusive);
        p.wal = try wal_mod.Wal.open(p.gpa, p.vfs, p.fd, p.wal_path, p.journal_size_limit);
    }

    /// Port of sqlite3PagerOpenWal(): switch to WAL mode, holding a SHARED
    /// lock. Returns true if there was nothing to do (a temporary
    /// database, or the WAL is already open). Fails with CantOpen if the
    /// VFS has no shared memory.
    pub fn openWal(p: *Pager) Error!bool {
        if (p.temp_file or p.wal != null) return true;
        if (!p.walSupported()) return error.CantOpen;
        // Close any rollback journal still open.
        if (p.jfd) |j| j.close();
        p.jfd = null;
        try p.openWalHandle();
        p.journal_mode = .wal;
        p.state = .open;
        return false;
    }

    /// Port of pagerExclusiveLock(): take EXCLUSIVE, dropping a PENDING
    /// lock left by a failed attempt.
    fn exclusiveLockDb(p: *Pager) Error!void {
        std.debug.assert(p.lock != null and p.lock.?.atLeast(.shared));
        const orig = p.lock.?;
        p.lockDb(.exclusive) catch |err| {
            p.unlockDb(orig) catch {};
            return err;
        };
    }

    /// Port of sqlite3PagerCloseWal(): checkpoint and close the WAL before
    /// leaving WAL mode. Needs the EXCLUSIVE lock, which is kept; fails
    /// with Busy (WAL still open) if another connection uses the
    /// database.
    pub fn closeWal(p: *Pager, db: Conn) Error!void {
        std.debug.assert(p.journal_mode == .wal);
        // A WAL that exists but is not open may still need a checkpoint.
        if (p.wal == null) {
            try p.lockDb(.shared);
            if (try p.vfs.access(p.wal_path, .exists)) try p.openWalHandle();
        }
        const w = p.wal orelse return;
        try p.exclusiveLockDb();
        p.wal = null;
        w.close(db.interrupt, p.wal_sync_flags, p.tmp_space[0..p.page_size]) catch |err| {
            p.unlockDb(.shared) catch {};
            return err;
        };
    }

    /// Port of sqlite3PagerCheckpoint(): checkpoint the WAL, if open (see
    /// wal.Wal.checkpoint). The busy handler is only used by FULL and up.
    /// `n_log` and `n_ckpt` are left alone outside WAL mode.
    pub fn checkpoint(p: *Pager, db: Conn, mode: CheckpointMode, n_log: ?*i32, n_ckpt: ?*i32) Error!void {
        const w = p.wal orelse return;
        const busy = if (mode.atLeast(.full)) p.busy_handler else null;
        try w.checkpoint(db.interrupt, mode, busy, p.wal_sync_flags, p.tmp_space[0..p.page_size], n_log, n_ckpt);
    }

    /// Port of sqlite3PagerWalCallback(): frames in the WAL after the last
    /// commit since the previous call, or 0.
    pub fn walCallback(p: *Pager) u32 {
        return wal_mod.Wal.takeCallback(p.wal);
    }

    // ============================================================== journal

    /// Port of writeJournalHdr(). nRec stays 0 until the records are synced,
    /// unless no sync will ever happen (or appends are atomic), in which case
    /// 0xffffffff tells recovery to use the file size.
    fn writeJournalHdr(p: *Pager) Error!void {
        const j = p.jfd.?;
        const n_header = @min(p.page_size, p.sector_size);
        const hdr = p.tmp_space[0..n_header];

        // Savepoints opened since the last header end their first segment
        // of records here.
        for (p.savepoints.items) |*sp| {
            if (sp.hdr_offset == 0) sp.hdr_offset = p.journal_off;
        }
        p.journal_off = journal.headerOffset(p.journal_off, p.sector_size);
        p.journal_hdr = p.journal_off;

        var rand: [4]u8 = undefined;
        p.vfs.randomness(&rand);
        p.cksum_init = std.mem.readInt(u32, &rand, .little);
        const final_nrec = p.no_sync or p.fd.deviceCharacteristics().safe_append;
        const h: journal.Header = .{
            .n_rec = if (final_nrec) 0xffffffff else 0,
            .cksum_init = p.cksum_init,
            .db_size = p.db_orig_size,
            .sector_size = p.sector_size,
            .page_size = p.page_size,
        };
        h.encode(hdr[0..journal.header_len], final_nrec);
        @memset(hdr[journal.header_len..], 0);

        // Writing the whole sector is faster on some systems than leaving a
        // gap for the OS to fill.
        var written: u32 = 0;
        while (written < p.sector_size) : (written += n_header) {
            try j.write(hdr, p.journal_off);
            p.journal_off += n_header;
        }
    }

    /// Port of readJournalHdr(). Returns null if there is no further valid
    /// header (SQLITE_DONE). The first header also sets the page and sector
    /// size to the writer's, so later headers and records are found.
    fn readJournalHdr(p: *Pager, is_hot: bool, journal_size: u64) Error!?journal.Header {
        p.journal_off = journal.headerOffset(p.journal_off, p.sector_size);
        if (p.journal_off + p.sector_size > journal_size) return null;
        const hdr_off = p.journal_off;

        var buf: [journal.header_len]u8 = undefined;
        try p.jfd.?.read(&buf, hdr_off);
        if ((is_hot or hdr_off != p.journal_hdr) and !std.mem.eql(u8, buf[0..8], &journal.magic)) return null;
        var h = journal.Header.decode(&buf);
        p.cksum_init = h.cksum_init;

        if (hdr_off == 0) {
            // SQLite before 3.5.8 wrote zero here.
            if (h.page_size == 0) h.page_size = p.page_size;
            if (!h.sizesValid()) return null;
            try p.setPageSize(h.page_size, null);
            // playback() restores our own sector size afterwards.
            p.sector_size = h.sector_size;
        }
        p.journal_off += p.sector_size;
        return h;
    }

    /// Port of zeroJournalHdr(): invalidate a persistent journal.
    fn zeroJournalHdr(p: *Pager, do_truncate: bool) Error!void {
        const j = p.jfd.?;
        if (p.journal_off == 0) return;
        if (do_truncate or p.journal_size_limit == 0) {
            try j.truncate(0);
        } else {
            const zeros: [journal.header_len]u8 = @splat(0);
            try j.write(&zeros, 0);
        }
        if (!p.no_sync) {
            var flags = p.sync_flags;
            flags.data_only = true;
            try j.sync(flags);
        }
        if (p.journal_size_limit > 0) {
            const limit: u64 = @intCast(p.journal_size_limit);
            if (try j.fileSize() > limit) try j.truncate(limit);
        }
    }

    /// Port of readSuperJournal(). Returns the super-journal name stored at
    /// the end of the journal (caller frees), or null if there is none or it
    /// fails validation.
    fn readSuperJournal(p: *Pager, j: vfs.File) Error!?[]u8 {
        const sz = try j.fileSize();
        if (sz < journal.super_trailer_len) return null;
        var tail: [journal.super_trailer_len]u8 = undefined;
        try j.read(&tail, sz - journal.super_trailer_len);
        const len = journal.superNameLen(&tail, sz, std.fs.max_path_bytes) orelse return null;

        const name = try p.gpa.alloc(u8, len);
        errdefer p.gpa.free(name);
        try j.read(name, sz - journal.super_trailer_len - len);
        if (!journal.superNameValid(&tail, name)) {
            p.gpa.free(name);
            return null;
        }
        return name;
    }

    /// Port of pager_delsuper(): delete the super-journal once no child
    /// journal still refers to it.
    fn deleteSuperJournal(p: *Pager, super: []const u8) Error!void {
        const sj = try p.vfs.open(super, .{ .kind = .super_journal, .read_write = false });
        defer sj.close();
        const contents = try p.gpa.alloc(u8, @intCast(try sj.fileSize()));
        defer p.gpa.free(contents);
        try sj.read(contents, 0);

        var seen = false;
        var it = std.mem.splitScalar(u8, contents, 0);
        while (it.next()) |child| {
            if (child.len == 0) continue;
            if (std.mem.eql(u8, child, p.journal_path)) {
                seen = true;
                continue;
            }
            if (!try p.vfs.access(child, .exists)) continue;
            const cj = try p.vfs.open(child, .{ .kind = .super_journal, .read_write = false });
            defer cj.close();
            const child_super = try p.readSuperJournal(cj) orelse continue;
            defer p.gpa.free(child_super);
            // Another child still needs the super-journal.
            if (std.mem.eql(u8, child_super, super)) return;
        }
        if (seen) try p.vfs.delete(super, false);
    }

    // ============================================================ playback

    /// pager_playback_one_page() for the main journal during a transaction
    /// rollback or hot-journal recovery. Returns false when the record is
    /// invalid, which ends the playback (SQLITE_DONE).
    fn playbackOnePage(p: *Pager) Error!bool {
        return p.playbackRecord(&p.journal_off, null, true, false);
    }

    /// Port of pager_playback_one_page(): play back the record at `off.*`
    /// of the main journal (`is_main`) or the sub-journal, advancing
    /// `off.*` past it. Records past the image, or already in `done`, are
    /// skipped; `done` records the others. Returns false when the record is
    /// invalid (never during a savepoint rollback).
    fn playbackRecord(p: *Pager, off: *u64, done: ?*std.AutoHashMapUnmanaged(Pgno, void), is_main: bool, is_savepoint: bool) Error!bool {
        var pgno: Pgno = undefined;
        var data: []const u8 = undefined;
        if (is_main) {
            try p.jfd.?.read(p.record_buf, off.*);
            off.* += p.record_buf.len;
            const rec = journal.decodeRecord(p.record_buf);
            pgno = rec.pgno;
            data = rec.page;
            // Garbage from a crash while the journal was being written.
            if (pgno == 0 or p.isLockPage(pgno)) {
                std.debug.assert(!is_savepoint);
                return false;
            }
            if (pgno > p.db_size or (done != null and done.?.contains(pgno))) return true;
            if (!is_savepoint and journal.checksum(p.cksum_init, data) != rec.cksum) return false;
        } else {
            const rec = p.sub_journal.items[@intCast(off.*)..][0..@intCast(subRecordSize(p.page_size))];
            off.* += rec.len;
            pgno = std.mem.readInt(u32, rec[0..4], .big);
            data = rec[4..];
            std.debug.assert(pgno != 0 and !p.isLockPage(pgno));
            if (pgno > p.db_size or done.?.contains(pgno)) return true;
        }
        if (done) |d| try d.put(p.gpa, pgno, {});

        if (pgno == 1) p.n_reserve = data[20];

        // In WAL mode the record always goes to the cache.
        var page = if (p.wal == null) p.lookup(pgno) else null;
        // Main-journal records after `journal_hdr` were never synced and
        // must not reach the database file. A sub-journal record may hold
        // content newer than the transaction's start, which may only reach
        // the file once the original is synced in the main journal.
        const is_synced = if (is_main)
            p.no_sync or off.* <= p.journal_hdr
        else
            page == null or !page.?.flags.need_sync;
        // A failed write still updates and releases the cached page, as
        // in C; the error is returned after.
        var write_err: ?Error = null;
        if (p.mayWriteDb() and is_synced) {
            p.fd.write(data, @as(u64, pgno - 1) * p.page_size) catch |err| {
                write_err = err;
            };
            if (pgno > p.db_file_size) p.db_file_size = pgno;
            p.backupUpdate(pgno, data);
        } else if (!is_main and page == null) {
            // Not written and not cached: the next read would see the
            // file. Cache the record's content instead, dirty.
            std.debug.assert(is_savepoint and !p.no_spill_rollback);
            p.no_spill_rollback = true;
            defer p.no_spill_rollback = false;
            page = try p.get(pgno, .{ .no_content = true });
            p.cache.makeDirty(page.?);
        }
        if (page) |pg| {
            @memcpy(pg.data, data);
            if (p.reiniter) |r| r(pg);
            if (pgno == 1) @memcpy(&p.db_file_vers, pg.data[24..40]);
            p.cache.release(pg);
        }
        if (write_err) |err| return err;
        return true;
    }

    /// Port of pager_playback(). Restores the database to its state before
    /// the transaction, then finalizes the journal. A corrupt tail stops the
    /// playback without error, as in SQLite.
    fn playback(p: *Pager, is_hot: bool) Error!void {
        const j = p.jfd.?;
        const saved_page_size = p.page_size;
        const sz_j = try j.fileSize();

        // A journal naming a super-journal that no longer exists belongs to
        // a committed multi-database transaction: it is not hot, but it is
        // still finalized below.
        const super = try p.readSuperJournal(j);
        defer if (super) |s| p.gpa.free(s);
        const super_exists = if (super) |s| try p.vfs.access(s, .exists) else true;

        p.journal_off = 0;
        var need_reset = is_hot;
        records: while (super_exists) {
            const hdr = try p.readJournalHdr(is_hot, sz_j) orelse break;
            const rec_size = journal.recordSize(p.page_size);
            var n_rec = hdr.n_rec;
            // Written without syncs: everything after the header is records.
            if (n_rec == 0xffffffff) {
                n_rec = @intCast((sz_j - p.sector_size) / rec_size);
            }
            // Our own unsynced last segment: count records from the size.
            if (n_rec == 0 and !is_hot and p.journal_hdr + p.sector_size == p.journal_off) {
                n_rec = @intCast((sz_j - p.journal_off) / rec_size);
            }
            // The first header holds the size to truncate back to.
            if (p.journal_off == p.sector_size) {
                try p.truncateFile(hdr.db_size);
                p.db_size = hdr.db_size;
                if (p.mx_pgno < hdr.db_size) p.mx_pgno = hdr.db_size;
            }
            for (0..n_rec) |_| {
                if (need_reset) {
                    p.reset();
                    need_reset = false;
                }
                const valid = p.playbackOnePage() catch |err| switch (err) {
                    // A truncated journal was never fully synced, so the
                    // database was never written. Stop here.
                    error.ShortRead => break :records,
                    else => return err,
                };
                if (!valid) {
                    p.journal_off = sz_j;
                    break;
                }
            }
        }

        try p.setPageSize(saved_page_size, null);
        p.change_count_done = false;
        if (p.mayWriteDb()) try p.syncDb();
        try p.endTransaction(super != null, false);
        if (super) |s| {
            if (super_exists) try p.deleteSuperJournal(s);
        }
        p.setSectorSize();
    }

    /// Port of pager_truncate(): make the file exactly `n_page` pages long.
    fn truncateFile(p: *Pager, n_page: Pgno) Error!void {
        if (!p.mayWriteDb()) return;
        std.debug.assert(p.lock == .exclusive);
        const cur = try p.fd.fileSize();
        const new = @as(u64, p.page_size) * n_page;
        if (cur == new) return;
        if (cur > new) {
            try p.fd.truncate(new);
        } else if (cur + p.page_size <= new) {
            // Growing by truncate confuses some systems; write a zero page
            // at the end instead.
            const zeros = p.tmp_space[0..p.page_size];
            @memset(zeros, 0);
            try p.fd.write(zeros, new - p.page_size);
        }
        p.db_file_size = n_page;
    }

    // ========================================================= commit/end

    /// The journal-finalizing part of pager_end_transaction(): afterwards
    /// the journal can no longer be played back.
    fn finalizeJournal(p: *Pager, has_super: bool) Error!void {
        const j = p.jfd orelse return;
        switch (p.journal_mode) {
            .truncate => {
                defer p.journal_off = 0;
                if (p.journal_off == 0) return;
                try j.truncate(0);
                // Make sure the size reaches the inode, or the journal can
                // resurrect after a power loss.
                if (p.full_sync) try j.sync(p.sync_flags);
            },
            .persist => {
                defer p.journal_off = 0;
                try p.zeroJournalHdr(has_super);
            },
            .memory => unreachable,
            // A journal is open in WAL mode only while the transaction
            // that switches to WAL commits through the rollback journal.
            .delete, .off, .wal => {
                j.close();
                p.jfd = null;
                if (!p.temp_file) try p.vfs.delete(p.journal_path, p.extra_sync);
            },
        }
    }

    /// Port of pager_end_transaction(): finalize the journal, then drop to
    /// SHARED (in WAL mode: release the WAL write lock). The unlock is
    /// attempted even if finalizing fails.
    fn endTransaction(p: *Pager, has_super: bool, commit: bool) Error!void {
        if (!p.state.atLeast(.writer_locked) and !(p.lock orelse LockLevel.exclusive).atLeast(.reserved)) return;
        p.releaseAllSavepoints();

        const finalized = p.finalizeOrError(has_super, commit);
        // In WAL mode the database lock stays SHARED (WalExclusiveMode(0)
        // is false outside exclusive mode).
        const unlocked = if (p.wal == null) p.unlockDb(.shared) else {};
        p.state = .reader;
        p.set_super = false;
        try finalized;
        return unlocked;
    }

    fn finalizeOrError(p: *Pager, has_super: bool, commit: bool) Error!void {
        defer {
            p.stopJournaling();
            p.n_rec = 0;
            if (p.wal) |w| w.endWriteTransaction();
        }
        if (p.jfd != null) {
            std.debug.assert(p.wal == null);
            try p.finalizeJournal(has_super);
        }
        p.cache.cleanAll();
        p.cache.truncate(p.db_size);
        if (p.wal == null and commit and p.db_file_size > p.db_size) {
            std.debug.assert(p.lock == .exclusive);
            try p.truncateFile(p.db_size);
        }
    }

    /// Port of sqlite3PagerSync(): sync the database file.
    pub fn syncDb(p: *Pager) Error!void {
        if (!p.no_sync) try p.fd.sync(p.sync_flags);
    }

    fn exclusiveLock(p: *Pager) Error!void {
        if (p.err) |e| return e;
        try p.waitOnLock(.exclusive);
    }

    /// Port of sqlite3PagerExclusiveLock(): take the EXCLUSIVE lock of a
    /// write transaction ahead of the commit, unless in WAL mode.
    pub fn exclusiveLockForCommit(p: *Pager) Error!void {
        if (p.err) |e| return e;
        std.debug.assert(p.state.atLeast(.writer_locked) and !p.state.atLeast(.writer_finished));
        if (p.wal == null) try p.waitOnLock(.exclusive);
    }

    /// Port of writeSuperJournal(): append the super-journal name `super`
    /// to the journal (see journal.superNameLen), once per transaction.
    fn writeSuperJournal(p: *Pager, super_name: ?[]const u8) Error!void {
        std.debug.assert(!p.set_super and p.wal == null);
        const super = super_name orelse return;
        const j = p.jfd orelse return;
        if (p.journal_mode == .memory) return;
        p.set_super = true;
        std.debug.assert(p.journal_hdr <= p.journal_off);

        // The checksum adds the name's bytes as (signed) chars.
        var cksum: u32 = 0;
        for (super) |c| cksum +%= @bitCast(@as(i32, @as(i8, @bitCast(c))));

        // In full-sync mode, go on to the next sector, in case the last
        // record written is already synced.
        if (p.full_sync) p.journal_off = journal.headerOffset(p.journal_off, p.sector_size);
        const off = p.journal_off;
        var be: [4]u8 = undefined;
        std.mem.writeInt(u32, &be, p.lck_pgno, .big);
        try j.write(&be, off);
        try j.write(super, off + 4);
        std.mem.writeInt(u32, &be, @intCast(super.len), .big);
        try j.write(&be, off + 4 + super.len);
        std.mem.writeInt(u32, &be, cksum, .big);
        try j.write(&be, off + 4 + super.len + 4);
        try j.write(&journal.magic, off + 4 + super.len + 8);
        p.journal_off += super.len + 20;

        // A persistent journal may go on past the name; recovery would
        // then not find it. Truncate.
        if (try j.fileSize() > p.journal_off) try j.truncate(p.journal_off);
    }

    /// Port of syncJournal(). Makes every journaled page durable before any
    /// database page is overwritten, and records nRec in the header.
    fn syncJournal(p: *Pager, new_hdr: bool) Error!void {
        std.debug.assert(p.state == .writer_cachemod or p.state == .writer_dbmod);
        try p.exclusiveLock();

        if (!p.no_sync) {
            if (p.jfd) |j| {
                const dc = p.fd.deviceCharacteristics();
                if (!dc.safe_append) {
                    // A leftover header from a previous PERSIST-mode
                    // transaction right after ours could be mistaken for
                    // part of this journal after a crash. Spoil its magic.
                    const next_hdr = journal.headerOffset(p.journal_off, p.sector_size);
                    var magic: [8]u8 = undefined;
                    try readPadded(j, &magic, next_hdr);
                    if (std.mem.eql(u8, &magic, &journal.magic)) try j.write(&.{0}, next_hdr);

                    // In full-sync mode the records must be on disk before
                    // nRec claims them.
                    if (p.full_sync and !dc.sequential) try j.sync(p.sync_flags);
                    try j.write(&journal.nrecBytes(p.n_rec), p.journal_hdr);
                }
                if (!dc.sequential) {
                    var flags = p.sync_flags;
                    if (flags.full) flags.data_only = true;
                    try j.sync(flags);
                }
                p.journal_hdr = p.journal_off;
                if (new_hdr and !dc.safe_append) {
                    p.n_rec = 0;
                    try p.writeJournalHdr();
                }
            } else {
                p.journal_hdr = p.journal_off;
            }
        }
        p.cache.clearSyncFlags();
        p.state = .writer_dbmod;
    }

    /// Port of pager_write_pagelist(). Writes pages linked through
    /// `Page.dirty` to the database file.
    fn writePageList(p: *Pager, list: ?*Page) Error!void {
        std.debug.assert(p.lock == .exclusive);
        var it = list;
        while (it) |pg| : (it = pg.dirty) {
            if (pg.pgno > p.db_size or pg.flags.dont_write) continue;
            std.debug.assert(!pg.flags.need_sync);
            if (pg.pgno == 1) p.writeChangeCounter(pg);
            try p.fd.write(pg.data, @as(u64, pg.pgno - 1) * p.page_size);
            if (pg.pgno == 1) @memcpy(&p.db_file_vers, pg.data[24..40]);
            if (pg.pgno > p.db_file_size) p.db_file_size = pg.pgno;
            p.backupUpdate(pg.pgno, pg.data);
        }
    }

    /// Port of pager_write_changecounter(): bump the change counter at
    /// offset 24, mirror it at 92 and stamp the library version at 96.
    fn writeChangeCounter(p: *Pager, pg: *Page) void {
        const counter = std.mem.readInt(u32, p.db_file_vers[0..4], .big) +% 1;
        std.mem.writeInt(u32, pg.data[24..28], counter, .big);
        std.mem.writeInt(u32, pg.data[92..96], counter, .big);
        std.mem.writeInt(u32, pg.data[96..100], root.sqlite_version_number, .big);
    }

    /// Port of pager_incr_changecounter(): once per transaction, journal
    /// page 1 and update its change counter.
    fn incrChangeCounter(p: *Pager) Error!void {
        if (p.change_count_done or p.db_size == 0) return;
        const pg = try p.get(1, .{});
        defer p.unref(pg);
        try p.write(pg);
        p.writeChangeCounter(pg);
        p.change_count_done = true;
    }

    /// Port of sqlite3PagerCommitPhaseOne(). Syncs the journal, writes every
    /// dirty page and syncs the database. After this only finalizing the
    /// journal (phase two) remains. `no_sync_db` skips the final database
    /// sync, for callers that sync several files themselves.
    pub fn commitPhaseOne(p: *Pager, no_sync_db: bool) Error!void {
        return p.commitPhaseOneSuper(null, no_sync_db);
    }

    /// sqlite3PagerCommitPhaseOne() with a super-journal: `super` (if not
    /// null) is written into the journal before it is synced, so that a
    /// multi-database transaction commits or rolls back as a whole.
    pub fn commitPhaseOneSuper(p: *Pager, super: ?[]const u8, no_sync_db: bool) Error!void {
        if (p.err) |e| return e;
        if (!p.state.atLeast(.writer_cachemod)) return;

        if (p.wal != null) {
            // A commit needs at least one frame to carry the commit mark.
            var page_one: ?*Page = null;
            defer if (page_one) |pg| p.unref(pg);
            var list = p.cache.dirtyList();
            if (list == null) {
                page_one = try p.get(1, .{});
                list = page_one;
                list.?.dirty = null;
            }
            try p.walFrames(list.?, p.db_size, true);
            p.cache.cleanAll();
            return;
        }

        try p.incrChangeCounter();
        try p.writeSuperJournal(super);
        try p.syncJournal(false);
        try p.writePageList(p.cache.dirtyList());
        p.cache.cleanAll();

        // The image grew but its last page was never written (e.g. it went
        // straight to the freelist): extend the file.
        if (p.db_size > p.db_file_size) {
            const n_new = p.db_size - @intFromBool(p.isLockPage(p.db_size));
            try p.truncateFile(n_new);
        }
        if (!no_sync_db) try p.syncDb();
        p.state = .writer_finished;
    }

    /// Port of sqlite3PagerCommitPhaseTwo(): finalize the journal. The
    /// transaction is durable once this returns.
    pub fn commitPhaseTwo(p: *Pager) Error!void {
        if (p.err) |e| return e;
        std.debug.assert(p.state == .writer_locked or p.state == .writer_finished or
            (p.wal != null and p.state == .writer_cachemod));
        p.data_version +%= 1;
        p.endTransaction(p.set_super, true) catch |err| return p.setError(err);
    }

    /// Port of sqlite3PagerRollback().
    pub fn rollback(p: *Pager) Error!void {
        if (p.err) |e| return e;
        if (!p.state.atLeast(.writer_locked)) return;

        if (p.wal != null) {
            const r = p.savepoint(.rollback, -1);
            const r2 = p.endTransaction(p.set_super, false);
            r catch |err| return p.setError(err);
            r2 catch |err| return p.setError(err);
            return;
        }
        if (p.jfd == null or p.state == .writer_locked) {
            const prev = p.state;
            p.endTransaction(false, false) catch |err| return p.setError(err);
            // journal_mode=OFF: the changes cannot be undone.
            if (prev.atLeast(.writer_cachemod)) p.enterError(error.Abort);
            return;
        }
        p.no_spill_rollback = true;
        defer p.no_spill_rollback = false;
        p.playback(false) catch |err| return p.setError(err);
    }

    // ========================================================== savepoints

    /// Port of releaseAllSavepoints(): forget every savepoint and empty the
    /// sub-journal.
    fn releaseAllSavepoints(p: *Pager) void {
        for (p.savepoints.items) |*sp| sp.in_savepoint.deinit(p.gpa);
        p.savepoints.clearRetainingCapacity();
        p.sub_journal.clearAndFree(p.gpa);
        p.n_sub_rec = 0;
    }

    /// Port of addToSavepointBitvecs(): `pgno` is saved for every open
    /// savepoint it was part of.
    fn addToSavepoints(p: *Pager, pgno: Pgno) Error!void {
        for (p.savepoints.items) |*sp| {
            if (pgno <= sp.n_orig) try sp.in_savepoint.put(p.gpa, pgno, {});
        }
    }

    /// Port of subjRequiresPage(): whether an open savepoint lacks the
    /// page. Savepoints opened after that one then share its record, so
    /// releasing them must not truncate the sub-journal.
    fn subjRequiresPage(p: *Pager, pg: *const Page) bool {
        const items = p.savepoints.items;
        for (items, 0..) |*sp, i| {
            if (sp.n_orig >= pg.pgno and !sp.in_savepoint.contains(pg.pgno)) {
                for (items[i + 1 ..]) |*later| later.truncate_on_release = false;
                return true;
            }
        }
        return false;
    }

    /// Port of subjournalPage(): append the page's current content to the
    /// sub-journal.
    fn subjournalPage(p: *Pager, pg: *const Page) Error!void {
        if (p.journal_mode != .off) {
            std.debug.assert(p.wal != null or p.inJournal(pg.pgno) or pg.pgno > p.db_orig_size);
            var pgno_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &pgno_bytes, pg.pgno, .big);
            try p.sub_journal.ensureUnusedCapacity(p.gpa, @intCast(subRecordSize(p.page_size)));
            p.sub_journal.appendSliceAssumeCapacity(&pgno_bytes);
            p.sub_journal.appendSliceAssumeCapacity(pg.data);
        }
        p.n_sub_rec += 1;
        std.debug.assert(p.savepoints.items.len > 0);
        try p.addToSavepoints(pg.pgno);
    }

    /// Port of subjournalPageIfRequired().
    fn subjournalPageIfRequired(p: *Pager, pg: *const Page) Error!void {
        if (p.subjRequiresPage(pg)) try p.subjournalPage(pg);
    }

    /// Port of sqlite3PagerOpenSavepoint(): make sure at least `n`
    /// savepoints are open, opening new ones at the current state.
    /// Requires a write transaction.
    pub fn openSavepoint(p: *Pager, n: u32) Error!void {
        std.debug.assert(p.state.atLeast(.writer_locked));
        if (n <= p.savepoints.items.len) return;
        try p.savepoints.ensureTotalCapacity(p.gpa, n);
        while (p.savepoints.items.len < n) {
            const sp = p.savepoints.addOneAssumeCapacity();
            sp.* = .{
                .n_orig = p.db_size,
                .offset = if (p.jfd != null and p.journal_off > 0) p.journal_off else p.sector_size,
                .i_sub_rec = p.n_sub_rec,
            };
            if (p.wal) |w| w.savepoint(&sp.wal_data);
        }
    }

    /// Port of sqlite3PagerSavepoint(): release savepoint `i` (and those
    /// opened after it), or roll back to it, keeping it open. Rolling back
    /// to -1 restores the start of the transaction, without ending it.
    pub fn savepoint(p: *Pager, op: SavepointOp, i: i32) Error!void {
        if (p.err) |e| return e;
        std.debug.assert(i >= 0 or op == .rollback);
        if (i >= @as(i32, @intCast(p.savepoints.items.len))) return;
        const n_new: usize = @intCast(i + @intFromBool(op == .rollback));
        for (p.savepoints.items[n_new..]) |*sp| sp.in_savepoint.deinit(p.gpa);
        const items = p.savepoints.items;
        p.savepoints.shrinkRetainingCapacity(n_new);
        switch (op) {
            .release => {
                // Drop the sub-journal records only the released
                // savepoints used.
                const rel = items[n_new];
                if (rel.truncate_on_release) {
                    p.sub_journal.shrinkRetainingCapacity(@intCast(subRecordSize(p.page_size) * rel.i_sub_rec));
                    p.n_sub_rec = rel.i_sub_rec;
                }
            },
            .rollback => {
                // Without a journal (or WAL) nothing has changed yet.
                if (p.wal != null or p.jfd != null) {
                    const sp: ?*Savepoint = if (n_new == 0) null else &p.savepoints.items[n_new - 1];
                    p.playbackSavepoint(sp) catch |err| return p.setError(err);
                }
            },
        }
    }

    /// Port of pagerPlaybackSavepoint(): restore the pages changed since
    /// `sp` opened (since the transaction started if null), from the main
    /// journal records written after it and then its sub-journal records.
    fn playbackSavepoint(p: *Pager, sp: ?*Savepoint) Error!void {
        std.debug.assert(p.state != .err and p.state.atLeast(.writer_locked));
        // Pages played back, so each is restored only from its oldest
        // record.
        var done: std.AutoHashMapUnmanaged(Pgno, void) = .empty;
        defer done.deinit(p.gpa);
        const done_opt: ?*std.AutoHashMapUnmanaged(Pgno, void) = if (sp != null) &done else null;

        p.db_size = if (sp) |s| s.n_orig else p.db_orig_size;
        p.change_count_done = p.temp_file;

        // Rolling back the whole transaction in WAL mode.
        if (sp == null and p.wal != null) return p.rollbackWal();

        // The journal's effective size: anything past journal_off belongs
        // to an earlier transaction (TRUNCATE or PERSIST mode).
        const sz_j = p.journal_off;

        std.debug.assert(p.wal == null or sz_j == 0);

        // The records from the savepoint up to the next journal header.
        if (sp != null and p.wal == null) {
            const s = sp.?;
            const hdr_off = if (s.hdr_offset != 0) s.hdr_offset else sz_j;
            p.journal_off = s.offset;
            while (p.journal_off < hdr_off) _ = try p.playbackRecord(&p.journal_off, done_opt, true, true);
        } else {
            p.journal_off = 0;
        }

        // Then every later segment of the journal.
        const rec_size = journal.recordSize(p.page_size);
        while (p.journal_off < sz_j) {
            const hdr = try p.readJournalHdr(false, sz_j) orelse break;
            var n_rec = hdr.n_rec;
            if (n_rec == 0 and p.journal_hdr + p.sector_size == p.journal_off) {
                n_rec = @intCast((sz_j - p.journal_off) / rec_size);
            }
            var ii: u32 = 0;
            while (ii < n_rec and p.journal_off < sz_j) : (ii += 1) {
                _ = try p.playbackRecord(&p.journal_off, done_opt, true, true);
            }
        }

        // Finally the sub-journal records of the savepoint.
        if (sp) |s| {
            if (p.wal) |w| try w.savepointUndo(&s.wal_data);
            var off: u64 = subRecordSize(p.page_size) * s.i_sub_rec;
            var ii = s.i_sub_rec;
            while (ii < p.n_sub_rec) : (ii += 1) _ = try p.playbackRecord(&off, done_opt, false, true);
        }
        p.journal_off = sz_j;
    }

    /// Port of pagerStress(): write one dirty page so its slot can be reused.
    /// Busy means "not now" and is not an error for the fetch.
    fn spill(p: *Pager, pg: *Page) Error!void {
        if (p.err != null or p.no_spill_rollback or p.no_spill_off) return;
        if (p.no_spill_nosync and pg.flags.need_sync) return;

        pg.dirty = null;
        if (p.wal != null) {
            // Write the page to the WAL as a frame without a commit mark.
            try p.subjournalPageIfRequired(pg);
            try p.walFrames(pg, 0, false);
        } else {
            if (pg.flags.need_sync or p.state == .writer_cachemod) try p.syncJournal(true);
            try p.writePageList(pg);
        }
        p.cache.makeClean(pg);
    }

    fn stressCallback(p: *Pager, pg: *Page) error{SpillFailed}!void {
        p.spill(pg) catch |err| switch (err) {
            error.Busy => {},
            else => {
                p.spill_err = p.setError(err);
                return error.SpillFailed;
            },
        };
    }

    /// Port of sqlite3PagerFlush(): spill every unreferenced dirty page.
    pub fn flush(p: *Pager) Error!void {
        if (p.err) |e| return e;
        var it = p.cache.dirtyList();
        while (it) |pg| {
            it = pg.dirty;
            if (pg.n_ref == 0) p.spill(pg) catch |err| return p.setError(err);
        }
    }
};

/// Reads `buf` at `off`, treating a short read as success. The unread tail
/// has been zero-filled by `File.read`.
fn readPadded(f: vfs.File, buf: []u8, off: u64) vfs.Error!void {
    f.read(buf, off) catch |err| switch (err) {
        error.ShortRead => {},
        else => return err,
    };
}

test {
    _ = @import("journal.zig");
    _ = @import("wal.zig");
    _ = @import("pager_test.zig");
}
