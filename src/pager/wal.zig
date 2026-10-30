//! The write-ahead log (port of wal.c).
//!
//! In WAL mode the database file is never written by a transaction.
//! Instead every changed page is appended to the "-wal" file as a frame,
//! and a transaction commits when its last frame, carrying the commit
//! marker (the new database size), is written. Readers look a page up in
//! the WAL before the database file, ignoring frames newer than the last
//! commit they saw, so each reader keeps a consistent snapshot while a
//! writer appends. A checkpoint copies ("backfills") frames back into the
//! database file; once all of them are, the next writer restarts the WAL
//! from its beginning.
//!
//! WAL file format (all integers big-endian):
//!
//!     header (32 bytes): magic 0x377f0682|bigEndCksum, version 3007000,
//!       page size, checkpoint sequence, salt-1, salt-2, checksum-1/2
//!     frame header (24 bytes): page number, database size for a commit
//!       frame else 0, salt-1, salt-2, checksum-1/2; then the page
//!
//! The checksum of a frame covers the WAL header, every prior frame and
//! this one; it is computed on 32-bit words in the byte order the magic
//! number names. A frame is valid only if its salts and checksum match.
//!
//! The wal-index (the "-shm" file, mapped into every process using the
//! database) speeds up lookups: after a 136-byte header (two copies of
//! WalIndexHdr and the WalCkptInfo, in native byte order) come hash tables
//! mapping page numbers to frames, one per 32 KiB page of the index. The
//! index is rebuilt from the WAL (recovery) whenever its header is bad.
//! Locks on the shared memory (shmLock) serialize writers, checkpointers
//! and recovery, and readers hold a read mark that bounds how far a
//! checkpoint may backfill.
//!
//! Byte-compatible with SQLite 3.54.1 in all three files: xqlite and
//! sqlite3 processes may use the same WAL database at the same time.
//!
//! Not ported: snapshots (SQLITE_ENABLE_SNAPSHOT), blocking locks
//! (SQLITE_ENABLE_SETLK_TIMEOUT), SEH handling of -shm mapping faults,
//! sqlite3WalStat, ZIPVFS hooks.

const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("../vfs/vfs.zig");
const pcache = @import("pcache.zig");
const thunk = @import("../util/thunk.zig");
const journal = @import("journal.zig");

const Allocator = std.mem.Allocator;
const Page = pcache.Page;
pub const Pgno = pcache.Pgno;

pub const Error = vfs.Error || error{
    /// The WAL or wal-index is malformed (SQLITE_CORRUPT).
    Corrupt,
    /// Another connection is running recovery (SQLITE_BUSY_RECOVERY).
    BusyRecovery,
    /// The snapshot of a read transaction is out of date, so it cannot
    /// become a write transaction (SQLITE_BUSY_SNAPSHOT).
    BusySnapshot,
    /// The wal-index needs recovery but the shared memory is read-only
    /// (SQLITE_READONLY_RECOVERY).
    ReadOnlyRecovery,
    /// The WAL locking protocol failed persistently (SQLITE_PROTOCOL).
    Protocol,
    /// A checkpoint was interrupted (SQLITE_INTERRUPT).
    Interrupt,
    /// The shared memory is read-only and no connection that could
    /// initialize it is attached, and no read mark fits
    /// (SQLITE_READONLY_CANTINIT).
    ReadOnlyCantInit,
};

/// Error set of the routines that may ask to be retried (WAL_RETRY).
const RetryError = Error || error{Retry};

/// WAL_MAX_VERSION and WALINDEX_MAX_VERSION.
pub const max_version: u32 = 3007000;
pub const walindex_max_version: u32 = 3007000;

/// Shared-memory lock numbers.
const write_lock: u32 = 0;
const all_but_write: u32 = 1;
const ckpt_lock: u32 = 1;
const recover_lock: u32 = 2;
fn readLock(i: u32) u32 {
    return 3 + i;
}
/// WAL_NREADER: the number of read marks.
pub const n_reader: u32 = vfs.shm_nlock - 3;

/// A copy of the wal-index header (WalIndexHdr). The wal-index holds two
/// copies, written in opposite orders, so a torn read can be detected.
pub const IndexHdr = extern struct {
    /// Wal-index version (iVersion).
    version: u32 = 0,
    unused: u32 = 0,
    /// Counter incremented by each transaction (iChange).
    change: u32 = 0,
    /// 1 when initialized (isInit).
    is_init: u8 = 0,
    /// WAL checksums are big-endian (bigEndCksum).
    big_end_cksum: u8 = 0,
    /// Page size; 1 means 65536 (szPage).
    sz_page: u16 = 0,
    /// The last valid (committed) frame (mxFrame).
    mx_frame: u32 = 0,
    /// Size of the database in pages (nPage).
    n_page: u32 = 0,
    /// Checksum of the last frame (aFrameCksum).
    frame_cksum: [2]u32 = .{ 0, 0 },
    /// The salts copied from the WAL header, as raw bytes (aSalt).
    salt: [2]u32 = .{ 0, 0 },
    /// Checksum over the fields above (aCksum).
    cksum: [2]u32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(IndexHdr) == 48);
}

/// Word offset of IndexHdr.mx_frame in a header copy.
const hdr_mx_frame: usize = @offsetOf(IndexHdr, "mx_frame") / 4;

/// Word offsets in the wal-index of the WalCkptInfo fields, which follow
/// the two header copies.
const ci_base: usize = 2 * @sizeOf(IndexHdr) / 4;
const ci_backfill: usize = ci_base + 0;
const ci_read_mark: usize = ci_base + 1;
const ci_backfill_attempted: usize = ci_base + 8;
/// READMARK_NOT_USED.
const readmark_not_used: u32 = 0xffffffff;

/// WALINDEX_LOCK_OFFSET and WALINDEX_HDR_SIZE.
pub const index_lock_offset: u32 = 120;
pub const index_hdr_size: u32 = 136;
/// WAL_FRAME_HDRSIZE and WAL_HDRSIZE.
pub const frame_hdr_size: u32 = 24;
pub const hdr_size: u32 = 32;
/// WAL_MAGIC; the low bit set means big-endian checksums.
pub const magic: u32 = 0x377f0682;

/// HASHTABLE_NPAGE, HASHTABLE_HASH_1, HASHTABLE_NSLOT, HASHTABLE_NPAGE_ONE.
const hashtable_npage: u32 = 4096;
const hashtable_hash_1: u32 = 383;
const hashtable_nslot: u32 = hashtable_npage * 2;
const hashtable_npage_one: u32 = hashtable_npage - index_hdr_size / 4;
/// WALINDEX_PGSZ: the wal-index is mapped in pages of this size.
pub const index_pgsz: u32 = 2 * hashtable_nslot + hashtable_npage * 4;

comptime {
    std.debug.assert(hashtable_npage_one == 4062);
    std.debug.assert(index_pgsz == 32768);
    std.debug.assert(index_lock_offset == ci_base * 4 + 4 + 4 * n_reader);
}

const native_endian = builtin.cpu.arch.endian();
/// SQLITE_BIGENDIAN.
const sqlite_bigendian: u8 = @intFromBool(native_endian == .big);

/// walFrameOffset(): offset in the WAL of the header of frame `frame`.
pub fn frameOffset(frame: u32, sz_page: u32) u64 {
    return hdr_size + @as(u64, frame - 1) * (@as(u64, sz_page) + frame_hdr_size);
}

/// Wal.exclusive_mode values (exclusiveMode).
pub const Mode = enum(u8) {
    normal = 0,
    /// No shared-memory locks are taken: set while closing with an
    /// EXCLUSIVE lock on the database.
    exclusive = 1,
    /// The wal-index is in heap memory: while reading from a private
    /// index because the shared memory is unreliable.
    heap_memory = 2,
};

/// Wal.readOnly bits.
const rdonly: u8 = 1;
const shm_rdonly: u8 = 2;

/// SQLITE_CHECKPOINT_* modes.
pub const CheckpointMode = enum(i32) {
    noop = -1,
    passive = 0,
    full = 1,
    restart = 2,
    truncate = 3,

    pub fn atLeast(a: CheckpointMode, b: CheckpointMode) bool {
        return @backingInt(a) >= @backingInt(b);
    }
};

/// A busy handler (xBusyHandler): returns true to retry. Made with
/// BusyHandler.init(ctx, f) from a typed `f(ctx)`.
pub const BusyHandler = thunk.Closure(*const fn (ctx: ?*anyopaque) bool);

/// Called for each page whose frame a rollback drops (xUndo). Made with
/// UndoCallback.init(ctx, f) from a typed `f(ctx, pgno)`.
pub const UndoCallback = thunk.Closure(*const fn (ctx: *anyopaque, pgno: Pgno) Error!void);

/// WAL_SAVEPOINT_NDATA values saved by `savepoint`.
pub const SavepointData = [4]u32;

/// WAL_SYNC_FLAGS() and CKPT_SYNC_FLAGS(): the low two bits of the sync
/// flags passed in apply to WAL commits, the next two to checkpoints.
/// Each is 0 (no sync), 2 (SQLITE_SYNC_NORMAL) or 3 (SQLITE_SYNC_FULL).
pub fn walSyncFlags(x: u8) u8 {
    return x & 0x03;
}
pub fn ckptSyncFlags(x: u8) u8 {
    return (x >> 2) & 0x03;
}

/// sqlite3OsSync(): a no-op for flags 0.
fn osSync(f: vfs.File, flags: u8) vfs.Error!void {
    if (flags == 0) return;
    return f.sync(.{ .full = flags & 0x03 == 0x03 });
}

fn get4(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}

fn put4(b: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, b, v, .big);
}

/// A mapped wal-index page as 32-bit words.
fn words(pg: [*]align(8) u8) [*]volatile u32 {
    const p: [*]align(8) volatile u8 = pg;
    return @ptrCast(p);
}

/// Reads a header copy from shared memory one word at a time.
fn loadHdr(src: [*]const volatile u32) IndexHdr {
    var h: IndexHdr = undefined;
    const w: *[12]u32 = @ptrCast(&h);
    for (w, 0..) |*x, i| x.* = src[i];
    return h;
}

fn storeHdr(dst: [*]volatile u32, h: IndexHdr) void {
    const w: *const [12]u32 = @ptrCast(&h);
    for (w, 0..) |x, i| dst[i] = x;
}

fn hdrEql(a: *const IndexHdr, b: *const IndexHdr) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Port of walChecksumBytes(): extend the checksum `in` over `a`, read as
/// 32-bit words in byte order `endian`. `a.len` is a multiple of 8.
pub fn checksumBytes(endian: std.builtin.Endian, a: []const u8, in: [2]u32) [2]u32 {
    std.debug.assert(a.len >= 8 and a.len % 8 == 0 and a.len <= 65536);
    var s1 = in[0];
    var s2 = in[1];
    var i: usize = 0;
    while (i < a.len) : (i += 8) {
        s1 +%= std.mem.readInt(u32, a[i..][0..4], endian) +% s2;
        s2 +%= std.mem.readInt(u32, a[i + 4 ..][0..4], endian) +% s1;
    }
    return .{ s1, s2 };
}

/// The byte order of WAL checksums: big-endian if bigEndCksum is set
/// (walChecksumBytes' nativeCksum argument, made explicit).
fn cksumEndian(big_end_cksum: u8) std.builtin.Endian {
    return if (big_end_cksum != 0) .big else .little;
}

/// Port of walHash().
fn walHash(pgno: u32) u32 {
    std.debug.assert(pgno > 0);
    return (pgno *% hashtable_hash_1) & (hashtable_nslot - 1);
}

/// Port of walNextHash().
fn walNextHash(prior: u32) u32 {
    return (prior + 1) & (hashtable_nslot - 1);
}

/// Port of walFramePage(): the wal-index page indexing frame `frame`.
fn framePage(frame: u32) u32 {
    return (frame + hashtable_npage - hashtable_npage_one - 1) / hashtable_npage;
}

/// The number of page-number slots on wal-index page `i_hash`.
fn pgnoSlots(i_hash: u32) u32 {
    return if (i_hash == 0) hashtable_npage_one else hashtable_npage;
}

/// Where the hash table of one wal-index page lives (WalHashLoc).
const HashLoc = struct {
    /// The hash table (aHash).
    hash: [*]volatile u16,
    /// pgno[0] is the page of frame `zero + 1` (aPgno, 0-based here).
    pgno: [*]volatile u32,
    /// One less than the first frame indexed (iZero).
    zero: u32,
};

/// The size of a page as stored in IndexHdr.sz_page.
fn szPageField(sz_page: u32) u16 {
    return @intCast((sz_page & 0xff00) | (sz_page >> 16));
}

pub const Wal = struct {
    gpa: Allocator,
    /// The VFS used to open the WAL (pVfs).
    vfs: vfs.Vfs,
    /// The database file, which carries the shared memory (pDbFd).
    db_fd: vfs.File,
    /// The WAL file (pWalFd).
    wal_fd: vfs.File,
    /// Frames in the WAL after the last commit, for the WAL hook
    /// (iCallback).
    callback: u32 = 0,
    /// Truncate the WAL to this size on reset; negative for no limit
    /// (mxWalSize).
    mx_wal_size: i64,
    /// The mapped wal-index pages (apWiData).
    wi_data: std.ArrayList(?[*]align(8) u8) = .empty,
    /// Database page size (szPage).
    sz_page: u32 = 0,
    /// The read lock held, or -1 (readLock).
    read_lock: i16 = -1,
    exclusive_mode: Mode,
    /// 1 while in a write transaction; 2 while the write lock is held only
    /// to read the wal-index header (writeLock).
    write_lock: u8 = 0,
    /// Holding the checkpoint lock (ckptLock).
    ckpt_lock: bool = false,
    /// rdonly and shm_rdonly bits (readOnly).
    read_only: u8 = 0,
    /// Truncate the WAL to the size limit on commit (truncateOnCommit).
    truncate_on_commit: bool = false,
    /// Sync the WAL header when it is written (syncHeader).
    sync_header: bool = true,
    /// Pad commits to a sector boundary (padToSectorBoundary).
    pad_to_sector_boundary: bool = true,
    /// The shared memory is read-only and unreliable, so the wal-index is
    /// kept on the heap (bShmUnreliable).
    shm_unreliable: bool = false,
    /// The wal-index header of the current transaction (hdr).
    hdr: IndexHdr = .{},
    /// Frames before this one are ignored (minFrame).
    min_frame: u32 = 0,
    /// On commit, recompute checksums from this frame (iReCksum).
    re_cksum: u32 = 0,
    /// Name of the WAL file, owned by the pager (zWalName).
    wal_name: []const u8,
    /// Checkpoint sequence number of the WAL header (nCkpt).
    n_ckpt: u32 = 0,

    // ======================================================== wal-index

    /// Port of walIndexPageRealloc(): map (or allocate) wal-index page
    /// `i_page`. The page is null only for page 0 without the write lock,
    /// when the shared memory is still empty, or with `cant_init`
    /// (SQLITE_READONLY_CANTINIT).
    fn indexPageRealloc(w: *Wal, i_page: u32) Error!vfs.ShmRegion {
        if (w.wi_data.items.len <= i_page) {
            try w.wi_data.appendNTimes(w.gpa, null, i_page + 1 - w.wi_data.items.len);
        }
        std.debug.assert(w.wi_data.items[i_page] == null);
        if (w.exclusive_mode == .heap_memory) {
            const pg = try w.gpa.alignedAlloc(u8, .@"8", index_pgsz);
            @memset(pg, 0);
            w.wi_data.items[i_page] = pg.ptr;
            return .{ .ptr = pg.ptr };
        }
        const r = try w.db_fd.shmMap(i_page, index_pgsz, w.write_lock != 0);
        if (r.read_only) w.read_only |= shm_rdonly;
        w.wi_data.items[i_page] = r.ptr;
        return r;
    }

    /// Port of walIndexPage().
    fn indexPage(w: *Wal, i_page: u32) Error!vfs.ShmRegion {
        if (w.wi_data.items.len > i_page) {
            if (w.wi_data.items[i_page]) |pg| return .{ .ptr = pg };
        }
        return w.indexPageRealloc(i_page);
    }

    /// Port of walIndexHdr(): the header copies in the wal-index.
    fn indexHdr(w: *const Wal) [*]volatile u32 {
        return words(w.wi_data.items[0].?);
    }

    /// Port of walCkptInfo(): the wal-index, indexed with the ci_* offsets.
    fn ckptInfo(w: *const Wal) [*]volatile u32 {
        return words(w.wi_data.items[0].?);
    }

    /// Port of walShmBarrier().
    fn shmBarrier(w: *Wal) void {
        if (w.exclusive_mode != .heap_memory) w.db_fd.shmBarrier();
    }

    /// Port of walIndexWriteHdr(): checksum `hdr` and write it to the
    /// wal-index, second copy first.
    fn indexWriteHdr(w: *Wal) void {
        std.debug.assert(w.write_lock != 0);
        w.hdr.is_init = 1;
        w.hdr.version = walindex_max_version;
        w.hdr.cksum = checksumBytes(native_endian, std.mem.asBytes(&w.hdr)[0..40], .{ 0, 0 });
        const a = w.indexHdr();
        storeHdr(a + 12, w.hdr);
        w.shmBarrier();
        storeHdr(a, w.hdr);
    }

    /// Port of walEncodeFrame(): fill in the frame header for page `pgno`
    /// with content `data`, extending the running checksum.
    fn encodeFrame(w: *Wal, pgno: u32, n_truncate: u32, data: []const u8, frame: *[frame_hdr_size]u8) void {
        put4(frame[0..4], pgno);
        put4(frame[4..8], n_truncate);
        if (w.re_cksum == 0) {
            @memcpy(frame[8..16], std.mem.asBytes(&w.hdr.salt));
            const e = cksumEndian(w.hdr.big_end_cksum);
            var ck = checksumBytes(e, frame[0..8], w.hdr.frame_cksum);
            ck = checksumBytes(e, data[0..w.sz_page], ck);
            w.hdr.frame_cksum = ck;
            put4(frame[16..20], ck[0]);
            put4(frame[20..24], ck[1]);
        } else {
            @memset(frame[8..24], 0);
        }
    }

    const Decoded = struct { pgno: u32, n_truncate: u32 };

    /// Port of walDecodeFrame(): the page number and commit size of a
    /// frame, or null if it is invalid. Extends the running checksum.
    fn decodeFrame(w: *Wal, data: []const u8, frame: *const [frame_hdr_size]u8) ?Decoded {
        if (!std.mem.eql(u8, std.mem.asBytes(&w.hdr.salt), frame[8..16])) return null;
        const pgno = get4(frame[0..4]);
        if (pgno == 0) return null;
        if (w.sz_page == 0) return null;
        const e = cksumEndian(w.hdr.big_end_cksum);
        var ck = checksumBytes(e, frame[0..8], w.hdr.frame_cksum);
        ck = checksumBytes(e, data[0..w.sz_page], ck);
        w.hdr.frame_cksum = ck;
        if (ck[0] != get4(frame[16..20]) or ck[1] != get4(frame[20..24])) return null;
        return .{ .pgno = pgno, .n_truncate = get4(frame[4..8]) };
    }

    // ============================================================ locks

    // Port of walLockShared(), walUnlockShared(), walLockExclusive() and
    // walUnlockExclusive(). No-ops in exclusive and heap-memory mode.

    fn lockShared(w: *Wal, idx: u32) Error!void {
        if (w.exclusive_mode != .normal) return;
        return w.db_fd.shmLock(idx, 1, .{});
    }

    fn unlockShared(w: *Wal, idx: u32) void {
        if (w.exclusive_mode != .normal) return;
        w.db_fd.shmLock(idx, 1, .{ .unlock = true }) catch {};
    }

    fn lockExclusive(w: *Wal, idx: u32, n: u32) Error!void {
        if (w.exclusive_mode != .normal) return;
        return w.db_fd.shmLock(idx, n, .{ .exclusive = true });
    }

    fn unlockExclusive(w: *Wal, idx: u32, n: u32) void {
        if (w.exclusive_mode != .normal) return;
        w.db_fd.shmLock(idx, n, .{ .unlock = true, .exclusive = true }) catch {};
    }

    /// Port of walBusyLock(): take an exclusive lock, retrying through
    /// the busy handler.
    fn busyLock(w: *Wal, busy: ?BusyHandler, idx: u32, n: u32) Error!void {
        while (true) {
            w.lockExclusive(idx, n) catch |err| {
                if (err == error.Busy) if (busy) |b| {
                    if (b.call(.{})) continue;
                };
                return err;
            };
            return;
        }
    }

    // ===================================================== hash tables

    /// Port of walHashGet(): the hash table on wal-index page `i_hash`.
    fn hashGet(w: *Wal, i_hash: u32) Error!HashLoc {
        // Only page 0 can be unmapped without an error, and the callers
        // never ask for it then.
        const pg = (try w.indexPage(i_hash)).ptr orelse return error.IoErr;
        const p32 = words(pg);
        const hash: [*]volatile u16 = @ptrCast(p32 + hashtable_npage);
        if (i_hash == 0) {
            return .{ .hash = hash, .pgno = p32 + index_hdr_size / 4, .zero = 0 };
        }
        return .{ .hash = hash, .pgno = p32, .zero = hashtable_npage_one + (i_hash - 1) * hashtable_npage };
    }

    /// Port of walFramePgno(): the page of frame `frame`.
    fn framePgno(w: *const Wal, frame: u32) u32 {
        const i_hash = framePage(frame);
        if (i_hash == 0) return words(w.wi_data.items[0].?)[index_hdr_size / 4 + frame - 1];
        return words(w.wi_data.items[i_hash].?)[(frame - 1 - hashtable_npage_one) % hashtable_npage];
    }

    /// Port of walCleanupHash(): drop hash entries for frames past
    /// `hdr.mx_frame`, after a rollback.
    fn cleanupHash(w: *Wal) void {
        std.debug.assert(w.write_lock != 0);
        if (w.hdr.mx_frame == 0) return;
        const i_hash = framePage(w.hdr.mx_frame);
        std.debug.assert(w.wi_data.items.len > i_hash and w.wi_data.items[i_hash] != null);
        const loc = w.hashGet(i_hash) catch return;
        const limit = w.hdr.mx_frame - loc.zero;
        std.debug.assert(limit > 0);
        for (0..hashtable_nslot) |i| {
            if (loc.hash[i] > limit) loc.hash[i] = 0;
        }
        var i = limit;
        while (i < pgnoSlots(i_hash)) : (i += 1) loc.pgno[i] = 0;
    }

    /// Port of walIndexAppend(): record that frame `frame` holds page
    /// `pgno`.
    fn indexAppend(w: *Wal, frame: u32, pgno: u32) Error!void {
        const i_hash = framePage(frame);
        const loc = try w.hashGet(i_hash);
        const idx = frame - loc.zero;
        std.debug.assert(idx <= hashtable_nslot / 2 + 1);

        // The first entry of a hash table: clear it, the page numbers and
        // the hash slots after them, first.
        if (idx == 1) {
            const start: [*]u8 = @ptrCast(@volatileCast(loc.pgno));
            const end: [*]u8 = @ptrCast(@volatileCast(loc.hash + hashtable_nslot));
            @memset(start[0 .. end - start], 0);
        }

        // A writer that died mid-transaction left entries behind: remove
        // them before writing new ones.
        if (loc.pgno[idx - 1] != 0) {
            w.cleanupHash();
            std.debug.assert(loc.pgno[idx - 1] == 0);
        }

        var n_collide = idx;
        var key = walHash(pgno);
        while (loc.hash[key] != 0) : (key = walNextHash(key)) {
            if (n_collide == 0) return error.Corrupt;
            n_collide -= 1;
        }
        loc.pgno[(idx - 1) & (hashtable_npage - 1)] = pgno;
        loc.hash[key] = @intCast(idx);
    }

    /// Port of walIndexRecover(): rebuild the wal-index from the WAL.
    /// Takes every lock not already held, so nothing else can touch the
    /// WAL meanwhile. The caller holds the write lock.
    fn indexRecover(w: *Wal) Error!void {
        std.debug.assert(w.write_lock != 0);
        const i_lock = all_but_write + @intFromBool(w.ckpt_lock);
        try w.lockExclusive(i_lock, readLock(0) - i_lock);
        defer w.unlockExclusive(i_lock, readLock(0) - i_lock);

        var frame_cksum: [2]u32 = .{ 0, 0 };
        w.hdr = .{};
        const n_size = try w.wal_fd.fileSize();

        recovered: {
            if (n_size <= hdr_size) break :recovered;
            var buf: [hdr_size]u8 = undefined;
            try w.wal_fd.read(&buf, 0);

            // A bad magic number or page size means the WAL holds nothing.
            const magic_v = get4(buf[0..4]);
            const sz_page = get4(buf[8..12]);
            if (magic_v & 0xFFFFFFFE != magic or
                !std.math.isPowerOfTwo(sz_page) or sz_page > 65536 or sz_page < 512)
            {
                break :recovered;
            }
            w.hdr.big_end_cksum = @intCast(magic_v & 1);
            w.sz_page = sz_page;
            w.n_ckpt = get4(buf[12..16]);
            @memcpy(std.mem.asBytes(&w.hdr.salt), buf[16..24]);

            // The WAL header checksum.
            w.hdr.frame_cksum = checksumBytes(cksumEndian(w.hdr.big_end_cksum), buf[0..24], .{ 0, 0 });
            if (w.hdr.frame_cksum[0] != get4(buf[24..28]) or w.hdr.frame_cksum[1] != get4(buf[28..32])) {
                break :recovered;
            }
            if (get4(buf[4..8]) != max_version) return error.CantOpen;

            // One allocation for a frame and the hash table being built,
            // which is private until it is complete.
            const sz_frame = sz_page + frame_hdr_size;
            const data = try w.gpa.alignedAlloc(u8, .@"8", index_pgsz + sz_frame);
            defer w.gpa.free(data);
            const private = data[0..index_pgsz];
            const frame = data[index_pgsz..];
            // Defensive (C leaves it uninitialized): indexAppend() clears a
            // page with its first frame, but a page whose first frame is
            // invalid is copied to the shared memory as it is.
            @memset(private, 0);

            const i_last_frame: u32 = @intCast((n_size - hdr_size) / sz_frame);
            var i_pg: u32 = 0;
            while (i_pg <= framePage(i_last_frame)) : (i_pg += 1) {
                const i_last = @min(i_last_frame, hashtable_npage_one + i_pg * hashtable_npage);
                const i_first = 1 + if (i_pg == 0) 0 else hashtable_npage_one + (i_pg - 1) * hashtable_npage;
                const share = (try w.indexPage(i_pg)).ptr orelse break;
                w.wi_data.items[i_pg] = private.ptr;
                var err: ?Error = null;
                var i_frame = i_first;
                while (i_frame <= i_last) : (i_frame += 1) {
                    w.wal_fd.read(frame, frameOffset(i_frame, sz_page)) catch |e| {
                        err = e;
                        break;
                    };
                    const fr = w.decodeFrame(frame[frame_hdr_size..], frame[0..frame_hdr_size]) orelse break;
                    w.indexAppend(i_frame, fr.pgno) catch |e| {
                        err = e;
                        break;
                    };
                    // A commit frame.
                    if (fr.n_truncate != 0) {
                        w.hdr.mx_frame = i_frame;
                        w.hdr.n_page = fr.n_truncate;
                        w.hdr.sz_page = szPageField(sz_page);
                        frame_cksum = w.hdr.frame_cksum;
                    }
                }
                w.wi_data.items[i_pg] = share;
                const n_hdr: usize = if (i_pg == 0) index_hdr_size else 0;
                @memcpy(share[n_hdr..index_pgsz], private[n_hdr..]);
                if (err) |e| return e;
                if (i_frame <= i_last) break;
            }
        }

        w.hdr.frame_cksum = frame_cksum;
        w.indexWriteHdr();

        // Reset the checkpoint information. No other writer or
        // checkpointer can run: we hold their locks.
        const info = w.ckptInfo();
        info[ci_backfill] = 0;
        info[ci_backfill_attempted] = w.hdr.mx_frame;
        info[ci_read_mark] = 0;
        var i: u32 = 1;
        while (i < n_reader) : (i += 1) {
            if (w.lockExclusive(readLock(i), 1)) |_| {
                info[ci_read_mark + i] = if (i == 1 and w.hdr.mx_frame != 0) w.hdr.mx_frame else readmark_not_used;
                w.unlockExclusive(readLock(i), 1);
            } else |err| {
                if (err != error.Busy) return err;
            }
        }
        // C logs SQLITE_NOTICE_RECOVER_WAL here; there is no log.
    }

    /// Port of walIndexClose().
    fn indexClose(w: *Wal, is_delete: bool) void {
        if (w.exclusive_mode == .heap_memory or w.shm_unreliable) {
            for (w.wi_data.items) |*pg| {
                if (pg.*) |p| w.gpa.free(@as([]align(8) u8, p[0..index_pgsz]));
                pg.* = null;
            }
        }
        if (w.exclusive_mode != .heap_memory) w.db_fd.shmUnmap(is_delete);
    }

    // ===================================================== open/close

    /// Port of sqlite3WalOpen(): open the WAL file `wal_name` (which must
    /// outlive the Wal) of the open database `db_fd`, read-only if the
    /// VFS can only open it so. A SHARED lock must be held, so that no
    /// one deletes the WAL meanwhile. `sqlite_filename`: the name is the
    /// pager's, in SQLite's filename layout (vfs.OpenFlags).
    pub fn open(gpa: Allocator, v: vfs.Vfs, db_fd: vfs.File, wal_name: []const u8, mx_wal_size: i64, sqlite_filename: bool) Error!*Wal {
        std.debug.assert(wal_name.len > 0);
        const w = try gpa.create(Wal);
        errdefer gpa.destroy(w);
        const wal_fd = try v.open(wal_name, .{ .kind = .wal, .create = true, .sqlite_filename = sqlite_filename });
        w.* = .{
            .gpa = gpa,
            .vfs = v,
            .db_fd = db_fd,
            .wal_fd = wal_fd,
            .mx_wal_size = mx_wal_size,
            .wal_name = wal_name,
            .exclusive_mode = .normal,
            .read_only = if (wal_fd.isReadOnly()) rdonly else 0,
        };
        const dc = db_fd.deviceCharacteristics();
        if (dc.sequential) w.sync_header = false;
        if (dc.powersafe_overwrite) w.pad_to_sector_boundary = false;
        return w;
    }

    /// Port of sqlite3WalLimit().
    pub fn setLimit(w: *Wal, limit: i64) void {
        w.mx_wal_size = limit;
    }

    /// Port of sqlite3WalClose(): close the WAL and free `w`. Given a
    /// page-sized `buf`, first try for an EXCLUSIVE lock on the database
    /// (kept on return): if this is the only connection, checkpoint and
    /// delete the WAL and wal-index.
    pub fn close(w: *Wal, interrupt: ?*const std.atomic.Value(bool), sync_flags: u8, buf: ?[]u8) Error!void {
        var result: Error!void = {};
        var is_delete = false;
        if (buf) |b| {
            if (w.db_fd.lock(.exclusive)) |_| {
                if (w.exclusive_mode == .normal) w.exclusive_mode = .exclusive;
                if (w.checkpoint(interrupt, .passive, null, sync_flags, b, null, null)) |_| {
                    // No SQLITE_FCNTL_PERSIST_WAL: always delete.
                    is_delete = true;
                } else |err| result = err;
            } else |err| result = err;
        }
        w.indexClose(is_delete);
        w.wal_fd.close();
        if (is_delete) w.vfs.delete(w.wal_name, false) catch {};
        w.wi_data.deinit(w.gpa);
        w.gpa.destroy(w);
        return result;
    }

    // ======================================================= checkpoint

    /// Port of walPagesize().
    fn pagesize(w: *const Wal) u32 {
        return (@as(u32, w.hdr.sz_page) & 0xfe00) + ((@as(u32, w.hdr.sz_page) & 0x0001) << 16);
    }

    /// Port of walRestartHdr(): make the next writer start at frame 1. The
    /// write lock is held, the WAL is fully backfilled and no reader uses
    /// it.
    fn restartHdr(w: *Wal, salt1: [4]u8) void {
        const info = w.ckptInfo();
        w.n_ckpt +%= 1;
        w.hdr.mx_frame = 0;
        const salt = std.mem.asBytes(&w.hdr.salt);
        put4(salt[0..4], get4(salt[0..4]) +% 1);
        @memcpy(salt[4..8], &salt1);
        w.indexWriteHdr();
        info[ci_backfill] = 0;
        info[ci_backfill_attempted] = 0;
        info[ci_read_mark + 1] = 0;
        var i: u32 = 2;
        while (i < n_reader) : (i += 1) info[ci_read_mark + i] = readmark_not_used;
        std.debug.assert(info[ci_read_mark] == 0);
    }

    /// Port of walCheckpoint(): copy as many frames as readers allow back
    /// into the database. For FULL and up, fails with Busy unless every
    /// frame was copied; RESTART and TRUNCATE also wait for readers to
    /// leave the WAL, and TRUNCATE empties it. The checkpoint lock is
    /// held.
    fn checkpointFrames(
        w: *Wal,
        interrupt: ?*const std.atomic.Value(bool),
        mode: CheckpointMode,
        busy_arg: ?BusyHandler,
        sync_flags: u8,
        buf: []u8,
    ) Error!void {
        var busy = busy_arg;
        const sz_page = w.pagesize();
        const info = w.ckptInfo();
        if (info[ci_backfill] < w.hdr.mx_frame) {
            std.debug.assert(mode != .passive or busy == null);

            // The last frame that can be written without overwriting a
            // page that an active reader may still need.
            var mx_safe = w.hdr.mx_frame;
            const mx_page = w.hdr.n_page;
            var i: u32 = 1;
            while (i < n_reader) : (i += 1) {
                const y = info[ci_read_mark + i];
                if (mx_safe > y) {
                    std.debug.assert(y <= w.hdr.mx_frame);
                    if (w.busyLock(busy, readLock(i), 1)) |_| {
                        info[ci_read_mark + i] = if (i == 1) mx_safe else readmark_not_used;
                        w.unlockExclusive(readLock(i), 1);
                    } else |err| switch (err) {
                        error.Busy => {
                            mx_safe = y;
                            busy = null;
                        },
                        else => return err,
                    }
                }
            }

            if (info[ci_backfill] < mx_safe) {
                var it = try Iterator.init(w, info[ci_backfill]);
                defer it.deinit();
                if (w.busyLock(busy, readLock(0), 1)) |_| {
                    defer w.unlockExclusive(readLock(0), 1);
                    const n_backfill = info[ci_backfill];
                    // With read lock 0 held, make sure the WAL was not
                    // restarted since the header was read: then there was
                    // nothing to do, and fewer frames may be valid.
                    const live = loadHdr(w.indexHdr());
                    if (std.mem.eql(u8, std.mem.asBytes(&live.salt), std.mem.asBytes(&w.hdr.salt))) {
                        info[ci_backfill_attempted] = mx_safe;
                        try osSync(w.wal_fd, ckptSyncFlags(sync_flags));

                        const n_req = @as(u64, mx_page) * sz_page;
                        const n_size = try w.db_fd.fileSize();
                        // Growing by more than the WAL holds (plus a
                        // lock page) means corruption.
                        if (n_size < n_req and n_size + 65536 + @as(u64, w.hdr.mx_frame) * sz_page < n_req) {
                            return error.Corrupt;
                        }

                        while (it.next()) |e| {
                            std.debug.assert(w.framePgno(e.frame) == e.pgno);
                            if (interrupt) |flag| if (flag.load(.monotonic)) return error.Interrupt;
                            if (e.frame <= n_backfill or e.frame > mx_safe or e.pgno > mx_page) continue;
                            try w.wal_fd.read(buf[0..sz_page], frameOffset(e.frame, sz_page) + frame_hdr_size);
                            try w.db_fd.write(buf[0..sz_page], @as(u64, e.pgno - 1) * sz_page);
                        }

                        // The database is complete only if every frame
                        // made it.
                        if (mx_safe == w.indexHdr()[hdr_mx_frame]) {
                            try w.db_fd.truncate(@as(u64, w.hdr.n_page) * sz_page);
                            try osSync(w.db_fd, ckptSyncFlags(sync_flags));
                        }
                        info[ci_backfill] = mx_safe;
                    }
                } else |err| {
                    // Active readers are not a checkpoint failure.
                    if (err != error.Busy) return err;
                }
            }
        }

        // RESTART and TRUNCATE: once everything is copied, wait for the
        // readers to leave the WAL so the next writer restarts it.
        if (mode != .passive) {
            std.debug.assert(w.write_lock != 0);
            if (info[ci_backfill] < w.hdr.mx_frame) return error.Busy;
            if (mode.atLeast(.restart)) {
                var salt1: [4]u8 = undefined;
                w.vfs.randomness(&salt1);
                std.debug.assert(info[ci_backfill] == w.hdr.mx_frame);
                try w.busyLock(busy, readLock(1), n_reader - 1);
                defer w.unlockExclusive(readLock(1), n_reader - 1);
                if (mode == .truncate) {
                    // Also reset the wal-index header, so that it agrees
                    // with the now empty WAL.
                    w.restartHdr(salt1);
                    try w.wal_fd.truncate(0);
                }
            }
        }
    }

    /// Port of walLimitSize(): truncate the WAL to `n_max` bytes if it is
    /// larger. Errors are ignored.
    fn limitSize(w: *Wal, n_max: i64) void {
        const sz = w.wal_fd.fileSize() catch return;
        if (sz > n_max) w.wal_fd.truncate(@intCast(n_max)) catch {};
    }

    /// Port of sqlite3WalCheckpoint() (sqlite3_wal_checkpoint_v2()): take
    /// the checkpoint lock (and for FULL and up the write lock, retrying
    /// through `busy`), then backfill. `buf` is a page of scratch space.
    /// `n_log` and `n_ckpt` receive the WAL size and the frames
    /// backfilled, also when Busy is returned.
    pub fn checkpoint(
        w: *Wal,
        interrupt: ?*const std.atomic.Value(bool),
        mode: CheckpointMode,
        busy: ?BusyHandler,
        sync_flags: u8,
        buf: []u8,
        n_log: ?*i32,
        n_ckpt: ?*i32,
    ) Error!void {
        std.debug.assert(!w.ckpt_lock and w.write_lock == 0);
        // The busy handler is never invoked in PASSIVE mode.
        std.debug.assert(mode.atLeast(.full) or busy == null);
        if (w.read_only != 0) return error.ReadOnly;

        var mode2 = mode;
        var busy2 = busy;
        var changed = false;
        var result: Error!void = {};

        // Another checkpointer means Busy, without the busy handler.
        if (mode != .noop) {
            if (w.lockExclusive(ckpt_lock, 1)) |_| {
                w.ckpt_lock = true;
                // FULL, RESTART and TRUNCATE also need the writer lock;
                // without it the checkpoint is PASSIVE.
                if (mode != .passive) {
                    if (w.busyLock(busy2, write_lock, 1)) |_| {
                        w.write_lock = 1;
                    } else |err| switch (err) {
                        error.Busy => {
                            mode2 = .passive;
                            busy2 = null;
                        },
                        else => result = err,
                    }
                }
            } else |err| result = err;
        }

        if (result) |_| {
            result = noRetry(w.indexReadHdr(&changed));
            if (result) |_| {
                if (w.hdr.mx_frame != 0 and w.pagesize() != buf.len) {
                    result = error.Corrupt;
                } else if (mode2 != .noop) {
                    result = w.checkpointFrames(interrupt, mode2, busy2, sync_flags, buf);
                }
                const ok = if (result) |_| true else |err| err == error.Busy;
                if (ok) {
                    if (n_log) |p| p.* = @bitCast(w.hdr.mx_frame);
                    if (n_ckpt) |p| p.* = @bitCast(w.ckptInfo()[ci_backfill]);
                }
            } else |_| {}
        } else |_| {}

        // A newer header was loaded, so the pager's cache is out of date:
        // make the next read transaction notice.
        if (changed) w.hdr = .{};

        w.endWriteTransaction();
        if (w.ckpt_lock) {
            w.unlockExclusive(ckpt_lock, 1);
            w.ckpt_lock = false;
        }
        try result;
        if (mode != mode2) return error.Busy;
    }

    // =============================================== read transactions

    /// Port of walIndexTryHdr(): copy the wal-index header into `hdr` if
    /// both copies agree and the checksum holds. Returns true if the
    /// header is bad; sets `changed` if it differs from the last one.
    fn indexTryHdr(w: *Wal, changed: *bool) bool {
        const a = w.indexHdr();
        const h1 = loadHdr(a);
        w.shmBarrier();
        const h2 = loadHdr(a + 12);
        if (!hdrEql(&h1, &h2)) return true;
        if (h1.is_init == 0) return true;
        const ck = checksumBytes(native_endian, std.mem.asBytes(&h1)[0..40], .{ 0, 0 });
        if (ck[0] != h1.cksum[0] or ck[1] != h1.cksum[1]) return true;
        if (!hdrEql(&w.hdr, &h1)) {
            changed.* = true;
            w.hdr = h1;
            w.sz_page = w.pagesize();
        }
        return false;
    }

    /// Port of walIndexReadHdr(): read the wal-index header into `hdr`,
    /// running recovery if it is bad even under the write lock.
    fn indexReadHdr(w: *Wal, changed: *bool) RetryError!void {
        var result: RetryError!void = {};
        const r0 = try w.indexPage(0);
        const page0 = r0.ptr;
        if (r0.cant_init) {
            // The shared memory can be opened but not written, and no
            // writer is around to vouch for it: build a private wal-index
            // on the heap instead.
            std.debug.assert(w.write_lock == 0 and w.read_only & shm_rdonly != 0);
            w.shm_unreliable = true;
            w.exclusive_mode = .heap_memory;
            changed.* = true;
        }

        // Usually the header can be read without a lock.
        var bad = if (page0 != null) w.indexTryHdr(changed) else true;

        // Retry under the write lock, in case of a race with a writer.
        if (bad) {
            if (!w.shm_unreliable and w.read_only & shm_rdonly != 0) {
                if (w.lockShared(write_lock)) |_| {
                    w.unlockShared(write_lock);
                    result = error.ReadOnlyRecovery;
                } else |err| result = err;
            } else {
                const had_lock = w.write_lock != 0;
                const locked = if (had_lock) {} else w.lockExclusive(write_lock, 1);
                if (locked) |_| {
                    // Lets indexPage extend the shared memory.
                    if (!had_lock) w.write_lock = 2;
                    if (w.indexPage(0)) |r| {
                        if (r.ptr == null) {
                            result = error.IoErr;
                        } else {
                            bad = w.indexTryHdr(changed);
                            if (bad) {
                                // Still bad under the write lock: rebuild.
                                result = w.indexRecover();
                                changed.* = true;
                            }
                        }
                    } else |err| result = err;
                    if (!had_lock) {
                        w.write_lock = 0;
                        w.unlockExclusive(write_lock, 1);
                    }
                } else |err| result = err;
            }
        }

        // A wal-index of a future format.
        if (!bad and w.hdr.version != walindex_max_version) result = error.CantOpen;
        if (w.shm_unreliable) {
            if (result) |_| {} else |err| {
                w.indexClose(false);
                w.shm_unreliable = false;
                // A concurrent writer truncated the WAL during recovery,
                // which means it fixed the shared memory: retry.
                if (err == error.ShortRead) result = error.Retry;
            }
            w.exclusive_mode = .normal;
        }
        return result;
    }

    /// Port of walBeginShmUnreliable(): open a read transaction on the
    /// private heap wal-index built because the shared memory is
    /// read-only. Retry means the shared memory became reliable or the
    /// WAL changed: the heap copy has been discarded.
    fn beginShmUnreliable(w: *Wal, changed: *bool) RetryError!void {
        std.debug.assert(w.shm_unreliable and w.read_only & shm_rdonly != 0);
        const result = w.beginShmUnreliableBody(changed);
        if (result) |_| {} else |_| {
            for (w.wi_data.items) |*pg| {
                if (pg.*) |p| w.gpa.free(@as([]align(8) u8, p[0..index_pgsz]));
                pg.* = null;
            }
            w.shm_unreliable = false;
            w.endReadTransaction();
            changed.* = true;
        }
        return result;
    }

    fn beginShmUnreliableBody(w: *Wal, changed: *bool) RetryError!void {
        // Read lock 0 keeps writers from checkpointing, but not from
        // running recovery.
        w.lockShared(readLock(0)) catch |err| return if (err == error.Busy) error.Retry else err;
        w.read_lock = 0;

        // A writer has attached since, making the shared memory reliable
        // (xShmMap now reports plain READONLY).
        if (!(try w.db_fd.shmMap(0, index_pgsz, false)).cant_init) return error.Retry;

        w.hdr = loadHdr(w.indexHdr());

        // A writer may have changed the WAL and disconnected meanwhile.
        const sz_wal = try w.wal_fd.fileSize();
        if (sz_wal < hdr_size) {
            // Too small for a header: if the index says it is empty, the
            // database file alone is the snapshot, but the cache may be
            // stale.
            changed.* = true;
            return if (w.hdr.mx_frame == 0) {} else error.Retry;
        }

        var buf: [hdr_size]u8 = undefined;
        try w.wal_fd.read(&buf, 0);
        // The WAL was restarted.
        if (!std.mem.eql(u8, std.mem.asBytes(&w.hdr.salt), buf[16..24])) return error.Retry;

        std.debug.assert(w.sz_page == 0 or std.math.isPowerOfTwo(w.sz_page));
        const sz_frame = w.sz_page + frame_hdr_size;
        const frame = try w.gpa.alloc(u8, sz_frame);
        defer w.gpa.free(frame);

        // A whole transaction appended since the heap index was built
        // makes it stale.
        const saved = w.hdr.frame_cksum;
        defer w.hdr.frame_cksum = saved;
        var off = frameOffset(w.hdr.mx_frame + 1, w.sz_page);
        while (off + sz_frame <= sz_wal) : (off += sz_frame) {
            try w.wal_fd.read(frame, off);
            const fr = w.decodeFrame(frame[frame_hdr_size..], frame[0..frame_hdr_size]) orelse break;
            if (fr.n_truncate != 0) return error.Retry;
        }
    }

    /// WAL_RETRY_PROTOCOL_LIMIT.
    const retry_protocol_limit = 100;

    /// Port of walTryBeginRead(): take a read lock on the read mark that
    /// best fits the current WAL. Retry means a race was lost; `cnt`
    /// counts attempts, sleeping more and more after five and failing
    /// with Protocol after 100. With `use_wal` the WAL is never bypassed
    /// and the header is assumed loaded.
    fn tryBeginRead(w: *Wal, changed: *bool, use_wal: bool, cnt: *u32) RetryError!void {
        std.debug.assert(w.read_lock < 0);
        std.debug.assert(w.read_only & shm_rdonly == 0 or !use_wal);

        cnt.* += 1;
        if (cnt.* > 5) {
            var delay: u32 = 1;
            const n = cnt.*;
            if (n > retry_protocol_limit) return error.Protocol;
            if (n >= 10) delay = (n - 9) * (n - 9) * 39;
            _ = w.vfs.sleep(delay);
        }

        if (!use_wal) {
            var res: RetryError!void = {};
            if (!w.shm_unreliable) res = w.indexReadHdr(changed);
            res catch |err| {
                if (err == error.Busy) {
                    // Busy without recovery running elsewhere is a race:
                    // retry. With recovery running, report it.
                    if (w.wi_data.items.len == 0 or w.wi_data.items[0] == null) return error.Retry;
                    if (w.lockShared(recover_lock)) |_| {
                        w.unlockShared(recover_lock);
                        return error.Retry;
                    } else |e2| {
                        return if (e2 == error.Busy) error.BusyRecovery else e2;
                    }
                }
                return err;
            };
            if (w.shm_unreliable) return w.beginShmUnreliable(changed);
        }

        std.debug.assert(w.wi_data.items.len > 0 and w.wi_data.items[0] != null);
        const info = w.ckptInfo();
        var busy = false;
        if (!use_wal and info[ci_backfill] == w.hdr.mx_frame) {
            // Everything is backfilled (or the WAL is empty): read the
            // database file only.
            const r = w.lockShared(readLock(0));
            w.shmBarrier();
            if (r) |_| {
                // Frames appended before the lock was taken might have
                // been partly backfilled by a checkpointer that crashed.
                const live = loadHdr(w.indexHdr());
                if (!hdrEql(&live, &w.hdr)) {
                    w.unlockShared(readLock(0));
                    return error.Retry;
                }
                w.read_lock = 0;
                return;
            } else |err| {
                if (err != error.Busy) return err;
                busy = true;
            }
        }

        // Use the WAL: pick the read mark closest to, but not past,
        // mx_frame.
        var mx_read_mark: u32 = 0;
        var mx_i: u32 = 0;
        const mx_frame = w.hdr.mx_frame;
        var i: u32 = 1;
        while (i < n_reader) : (i += 1) {
            const this_mark = info[ci_read_mark + i];
            if (mx_read_mark <= this_mark and this_mark <= mx_frame) {
                std.debug.assert(this_mark != readmark_not_used);
                mx_read_mark = this_mark;
                mx_i = i;
            }
        }
        if (w.read_only & shm_rdonly == 0 and (mx_read_mark < mx_frame or mx_i == 0)) {
            i = 1;
            while (i < n_reader) : (i += 1) {
                if (w.lockExclusive(readLock(i), 1)) |_| {
                    info[ci_read_mark + i] = mx_frame;
                    mx_read_mark = mx_frame;
                    mx_i = i;
                    w.unlockExclusive(readLock(i), 1);
                    busy = false;
                    break;
                } else |err| {
                    if (err != error.Busy) return err;
                    busy = true;
                }
            }
        }
        if (mx_i == 0) {
            std.debug.assert(busy or w.read_only & shm_rdonly != 0);
            return if (busy) error.Retry else error.ReadOnlyCantInit;
        }

        w.lockShared(readLock(mx_i)) catch |err| return if (err == error.Busy) error.Retry else err;

        // With the lock held, the read mark and the header must not have
        // changed: the WAL may have been restarted, or frames past our
        // mx_frame backfilled. Frames up to nBackfill can be read from the
        // database file (minFrame); the barrier makes sure the
        // checkpointer that set it had no newer header than ours.
        w.min_frame = info[ci_backfill] + 1;
        w.shmBarrier();
        const live = loadHdr(w.indexHdr());
        if (info[ci_read_mark + mx_i] != mx_read_mark or !hdrEql(&live, &w.hdr)) {
            w.unlockShared(readLock(mx_i));
            return error.Retry;
        }
        std.debug.assert(mx_read_mark <= w.hdr.mx_frame);
        w.read_lock = @intCast(mx_i);
    }

    /// Port of sqlite3WalBeginReadTransaction(): take a snapshot of the
    /// WAL. Returns true if the database changed since the last one, so
    /// the page cache must be discarded.
    pub fn beginReadTransaction(w: *Wal) Error!bool {
        std.debug.assert(!w.ckpt_lock);
        var changed = false;
        var cnt: u32 = 0;
        while (true) {
            w.tryBeginRead(&changed, false, &cnt) catch |err| switch (err) {
                error.Retry => continue,
                else => |e| return e,
            };
            return changed;
        }
    }

    /// Port of sqlite3WalEndReadTransaction(): release the read lock.
    pub fn endReadTransaction(w: *Wal) void {
        if (w.read_lock >= 0) {
            w.endWriteTransaction();
            w.unlockShared(readLock(@intCast(w.read_lock)));
            w.read_lock = -1;
        }
    }

    /// Port of walFindFrame() (sqlite3WalFindFrame()): the frame of the
    /// snapshot holding page `pgno`, or 0 to read it from the database
    /// file.
    pub fn findFrame(w: *Wal, pgno: Pgno) Error!u32 {
        var i_read: u32 = 0;
        const i_last = w.hdr.mx_frame;
        // Nothing to find, or the WAL is bypassed (read lock 0).
        if (i_last == 0 or (w.read_lock == 0 and !w.shm_unreliable)) return 0;

        // Entries may be added concurrently by a writer, so only those
        // within this snapshot and naming `pgno` count.
        const i_min_hash = framePage(w.min_frame);
        var i_hash: i64 = framePage(i_last);
        while (i_hash >= i_min_hash) : (i_hash -= 1) {
            const loc = try w.hashGet(@intCast(i_hash));
            var n_collide = hashtable_nslot;
            var key = walHash(pgno);
            while (true) : (key = walNextHash(key)) {
                const h: u32 = loc.hash[key];
                if (h == 0) break;
                const frame = h + loc.zero;
                if (frame <= i_last and frame >= w.min_frame and loc.pgno[(h - 1) & (hashtable_npage - 1)] == pgno) {
                    i_read = frame;
                }
                if (n_collide == 0) return error.Corrupt;
                n_collide -= 1;
            }
            if (i_read != 0) break;
        }
        return i_read;
    }

    /// Port of sqlite3WalReadFrame(): read the page of frame `frame` into
    /// `out`, zero-filling past the WAL's page size.
    pub fn readFrame(w: *Wal, frame: u32, out: []u8) Error!void {
        const sz = w.pagesize();
        var n = out.len;
        if (n > sz) {
            @memset(out[sz..], 0);
            n = sz;
        }
        try w.wal_fd.read(out[0..n], frameOffset(frame, sz) + frame_hdr_size);
    }

    /// Port of sqlite3WalDbsize(): the database size of the snapshot in
    /// pages, or 0 if unknown.
    pub fn dbsize(w: ?*const Wal) Pgno {
        if (w) |x| if (x.read_lock >= 0) return x.hdr.n_page;
        return 0;
    }

    // ============================================== write transactions

    /// Port of sqlite3WalBeginWriteTransaction(): take the write lock. A
    /// read transaction is open; if another connection committed since it
    /// started, fails with BusySnapshot.
    pub fn beginWriteTransaction(w: *Wal) Error!void {
        std.debug.assert(w.read_lock >= 0);
        std.debug.assert(w.write_lock == 0 and w.re_cksum == 0);
        if (w.read_only != 0) return error.ReadOnly;
        try w.lockExclusive(write_lock, 1);
        w.write_lock = 1;
        const live = loadHdr(w.indexHdr());
        if (!hdrEql(&w.hdr, &live)) {
            w.unlockExclusive(write_lock, 1);
            w.write_lock = 0;
            return error.BusySnapshot;
        }
    }

    /// Port of sqlite3WalEndWriteTransaction(): release the write lock.
    pub fn endWriteTransaction(w: *Wal) void {
        if (w.write_lock != 0) {
            w.unlockExclusive(write_lock, 1);
            w.write_lock = 0;
            w.re_cksum = 0;
            w.truncate_on_commit = false;
        }
    }

    /// Port of sqlite3WalUndo(): forget the frames written by the
    /// transaction, calling `undo` for the page of each.
    pub fn undo(w: *Wal, cb: UndoCallback) Error!void {
        if (w.write_lock == 0) return;
        const i_max = w.hdr.mx_frame;
        // Back to the header as it was before this transaction wrote.
        w.hdr = loadHdr(w.indexHdr());
        var result: Error!void = {};
        var frame = w.hdr.mx_frame + 1;
        while (frame <= i_max) : (frame += 1) {
            // Page 1 is only written at commit.
            std.debug.assert(w.framePgno(frame) != 1);
            cb.call(.{w.framePgno(frame)}) catch |err| {
                result = err;
                break;
            };
        }
        if (i_max != w.hdr.mx_frame) w.cleanupHash();
        w.re_cksum = 0;
        return result;
    }

    /// Port of sqlite3WalSavepoint(): the write position, to roll back to.
    pub fn savepoint(w: *const Wal, data: *SavepointData) void {
        std.debug.assert(w.write_lock != 0);
        data.* = .{ w.hdr.mx_frame, w.hdr.frame_cksum[0], w.hdr.frame_cksum[1], w.n_ckpt };
    }

    /// Port of sqlite3WalSavepointUndo(): move the write position back to
    /// `data`.
    pub fn savepointUndo(w: *Wal, data: *SavepointData) Error!void {
        std.debug.assert(w.write_lock != 0);
        std.debug.assert(data[3] != w.n_ckpt or data[0] <= w.hdr.mx_frame);
        // The WAL was restarted right after the savepoint opened.
        if (data[3] != w.n_ckpt) {
            data[0] = 0;
            data[3] = w.n_ckpt;
        }
        if (data[0] < w.hdr.mx_frame) {
            w.hdr.mx_frame = data[0];
            w.hdr.frame_cksum = .{ data[1], data[2] };
            w.cleanupHash();
            if (w.re_cksum > w.hdr.mx_frame) w.re_cksum = 0;
        }
    }

    /// Port of walRestartLog(): before writing, restart the WAL from frame
    /// 1 if it is fully backfilled and no reader uses it. Then the read
    /// lock moves off read mark 0.
    fn restartLog(w: *Wal) Error!void {
        if (w.read_lock != 0) return;
        const info = w.ckptInfo();
        std.debug.assert(info[ci_backfill] == w.hdr.mx_frame);
        if (info[ci_backfill] > 0) {
            var salt1: [4]u8 = undefined;
            w.vfs.randomness(&salt1);
            if (w.lockExclusive(readLock(1), n_reader - 1)) |_| {
                // Updating the wal-index header too means a rollback of
                // this transaction needs no special case.
                w.restartHdr(salt1);
                w.unlockExclusive(readLock(1), n_reader - 1);
            } else |err| {
                if (err != error.Busy) return err;
            }
        }
        w.unlockShared(readLock(0));
        w.read_lock = -1;
        var cnt: u32 = 0;
        while (true) {
            var not_used = false;
            w.tryBeginRead(&not_used, true, &cnt) catch |err| switch (err) {
                error.Retry => continue,
                else => |e| return e,
            };
            return;
        }
    }

    /// Where the next sync of a commit happens (WalWriter).
    const Writer = struct {
        w: *Wal,
        fd: vfs.File,
        /// Sync at this offset (iSyncPoint).
        sync_point: u64 = 0,
        sync_flags: u8,
        sz_page: u32,

        /// Port of walWriteToLog(): write `content` at `off`, syncing when
        /// crossing `sync_point`.
        fn writeToLog(wr: *Writer, content_arg: []const u8, off_arg: u64) Error!void {
            var content = content_arg;
            var off = off_arg;
            if (off < wr.sync_point and off + content.len >= wr.sync_point) {
                const first: usize = @intCast(wr.sync_point - off);
                try wr.fd.write(content[0..first], off);
                off += first;
                content = content[first..];
                std.debug.assert(walSyncFlags(wr.sync_flags) != 0);
                try osSync(wr.fd, walSyncFlags(wr.sync_flags));
                if (content.len == 0) return;
            }
            try wr.fd.write(content, off);
        }

        /// Port of walWriteOneFrame().
        fn writeOneFrame(wr: *Writer, pg: *Page, n_truncate: u32, off: u64) Error!void {
            var frame: [frame_hdr_size]u8 = undefined;
            wr.w.encodeFrame(pg.pgno, n_truncate, pg.data, &frame);
            try wr.writeToLog(&frame, off);
            try wr.writeToLog(pg.data[0..wr.sz_page], off + frame_hdr_size);
        }
    };

    /// Port of walRewriteChecksums(): recompute the checksums of the
    /// transaction's frames from `re_cksum` to `i_last`, after some were
    /// overwritten in place.
    fn rewriteChecksums(w: *Wal, i_last: u32) Error!void {
        const sz_page = w.sz_page;
        const buf = try w.gpa.alloc(u8, sz_page + frame_hdr_size);
        defer w.gpa.free(buf);
        std.debug.assert(w.re_cksum > 0);
        // The checksum to start from: the WAL header's, or the frame
        // before the first one rewritten.
        const ck_off: u64 = if (w.re_cksum == 1) 24 else frameOffset(w.re_cksum - 1, sz_page) + 16;
        const r = w.wal_fd.read(buf[0..8], ck_off);
        w.hdr.frame_cksum = .{ get4(buf[0..4]), get4(buf[4..8]) };
        var i_read = w.re_cksum;
        w.re_cksum = 0;
        try r;
        while (i_read <= i_last) : (i_read += 1) {
            const off = frameOffset(i_read, sz_page);
            try w.wal_fd.read(buf, off);
            var frame: [frame_hdr_size]u8 = undefined;
            w.encodeFrame(get4(buf[0..4]), get4(buf[4..8]), buf[frame_hdr_size..], &frame);
            try w.wal_fd.write(&frame, off);
        }
    }

    /// Port of walFrames() (sqlite3WalFrames()): append the pages of
    /// `list` (linked through `Page.dirty`, ascending) as frames. A commit
    /// (`n_truncate` != 0, the new database size) marks the last frame,
    /// syncs the WAL as `sync_flags` say and publishes the new header.
    /// Pages already written by this transaction are overwritten in
    /// place. The write lock is held.
    pub fn frames(w: *Wal, sz_page: u32, list: *Page, n_truncate: Pgno, is_commit: bool, sync_flags: u8) Error!void {
        std.debug.assert(w.write_lock != 0);
        std.debug.assert(is_commit == (n_truncate != 0));

        // Frames from `first` on were written by this transaction and
        // may be overwritten.
        var first: u32 = 0;
        const live = loadHdr(w.indexHdr());
        if (!hdrEql(&w.hdr, &live)) first = live.mx_frame + 1;

        // Maybe write at the start of the WAL instead of appending.
        try w.restartLog();

        // The first frame of the WAL: write its header.
        var i_frame = w.hdr.mx_frame;
        if (i_frame == 0) {
            var whdr: [hdr_size]u8 = undefined;
            put4(whdr[0..4], magic | sqlite_bigendian);
            put4(whdr[4..8], max_version);
            put4(whdr[8..12], sz_page);
            put4(whdr[12..16], w.n_ckpt);
            if (w.n_ckpt == 0) w.vfs.randomness(std.mem.asBytes(&w.hdr.salt));
            @memcpy(whdr[16..24], std.mem.asBytes(&w.hdr.salt));
            const ck = checksumBytes(native_endian, whdr[0..24], .{ 0, 0 });
            put4(whdr[24..28], ck[0]);
            put4(whdr[28..32], ck[1]);

            w.sz_page = sz_page;
            w.hdr.big_end_cksum = sqlite_bigendian;
            w.hdr.frame_cksum = ck;
            w.truncate_on_commit = true;

            try w.wal_fd.write(&whdr, 0);
            // Sync the header, or an out-of-order write after a restart
            // could corrupt the database (ticket ff5be73dee).
            if (w.sync_header) try osSync(w.wal_fd, ckptSyncFlags(sync_flags));
        }
        if (w.sz_page != sz_page) return error.Corrupt;

        var wr: Writer = .{ .w = w, .fd = w.wal_fd, .sync_flags = sync_flags, .sz_page = sz_page };
        var off = frameOffset(i_frame + 1, sz_page);
        const sz_frame: u64 = @as(u64, sz_page) + frame_hdr_size;

        var last: ?*Page = null;
        var it: ?*Page = list;
        while (it) |pg| : (it = pg.dirty) {
            // Already in the WAL from this transaction: overwrite it and
            // recompute the checksums at commit.
            if (first != 0 and (pg.dirty != null or !is_commit)) {
                const i_write = w.findFrame(pg.pgno) catch 0;
                if (i_write >= first) {
                    if (w.re_cksum == 0 or i_write < w.re_cksum) w.re_cksum = i_write;
                    try w.wal_fd.write(pg.data[0..sz_page], frameOffset(i_write, sz_page) + frame_hdr_size);
                    pg.flags.wal_append = false;
                    continue;
                }
            }
            i_frame += 1;
            std.debug.assert(off == frameOffset(i_frame, sz_page));
            const n_db_size: u32 = if (is_commit and pg.dirty == null) n_truncate else 0;
            try wr.writeOneFrame(pg, n_db_size, off);
            last = pg;
            off += sz_frame;
            pg.flags.wal_append = true;
        }

        if (is_commit and w.re_cksum != 0) try w.rewriteChecksums(i_frame);

        // With synchronous=FULL, sync the commit; without powersafe
        // overwrite, first repeat the last frame up to a sector boundary
        // and sync before the part past it.
        var n_extra: u32 = 0;
        if (is_commit and walSyncFlags(sync_flags) != 0) {
            var do_sync = true;
            if (w.pad_to_sector_boundary) {
                const sector: u64 = journal.sectorSize(w.wal_fd.sectorSize());
                wr.sync_point = ((off + sector - 1) / sector) * sector;
                do_sync = wr.sync_point == off;
                while (off < wr.sync_point) {
                    try wr.writeOneFrame(last.?, n_truncate, off);
                    off += sz_frame;
                    n_extra += 1;
                }
            }
            if (do_sync) try osSync(wr.fd, walSyncFlags(sync_flags));
        }

        // The first transaction of a restarted WAL: honor
        // journal_size_limit.
        if (is_commit and w.truncate_on_commit and w.mx_wal_size >= 0) {
            var sz = w.mx_wal_size;
            const end: i64 = @intCast(frameOffset(i_frame + n_extra + 1, sz_page));
            if (end > w.mx_wal_size) sz = end;
            w.limitSize(sz);
            w.truncate_on_commit = false;
        }

        // Index the new frames. The write lock keeps other writers out,
        // and readers ignore frames past their snapshot.
        i_frame = w.hdr.mx_frame;
        it = list;
        while (it) |pg| : (it = pg.dirty) {
            if (!pg.flags.wal_append) continue;
            i_frame += 1;
            try w.indexAppend(i_frame, pg.pgno);
        }
        while (n_extra > 0) : (n_extra -= 1) {
            i_frame += 1;
            try w.indexAppend(i_frame, last.?.pgno);
        }

        w.hdr.sz_page = szPageField(sz_page);
        w.hdr.mx_frame = i_frame;
        if (is_commit) {
            w.hdr.change +%= 1;
            w.hdr.n_page = n_truncate;
            w.indexWriteHdr();
            w.callback = i_frame;
        }
    }

    /// Port of sqlite3WalCallback(): the WAL size at the last commit since
    /// the previous call, for the WAL hook, or 0.
    pub fn takeCallback(w: ?*Wal) u32 {
        const x = w orelse return 0;
        defer x.callback = 0;
        return x.callback;
    }
};

/// Port of walMerge(): merge the sorted `left` into the sorted `right`
/// (which directly follows it in memory) by `content` of each index,
/// dropping entries of `left` whose page is also in `right`. The result
/// replaces `right`, starting at `left.ptr`.
fn merge(content: [*]const volatile u32, left: []u16, right: *[]u16, tmp: []u16) void {
    std.debug.assert(left.len > 0 and right.len > 0);
    const r = right.*;
    var il: usize = 0;
    var ir: usize = 0;
    var out: usize = 0;
    while (ir < r.len or il < left.len) {
        var logpage: u16 = undefined;
        if (il < left.len and (ir >= r.len or content[left[il]] < content[r[ir]])) {
            logpage = left[il];
            il += 1;
        } else {
            logpage = r[ir];
            ir += 1;
        }
        const dbpage = content[logpage];
        tmp[out] = logpage;
        out += 1;
        if (il < left.len and content[left[il]] == dbpage) il += 1;
    }
    right.* = left.ptr[0..out];
    @memcpy(left.ptr[0..out], tmp[0..out]);
}

/// Port of walMergesort(): sort `list` (indexes into `content`) by page,
/// keeping only the last (largest) index of each page. Returns the new
/// length. `buffer` holds at least `list.len` entries.
fn mergesort(content: [*]const volatile u32, buffer: []u16, list: []u16) usize {
    std.debug.assert(list.len <= hashtable_npage and list.len > 0);
    var sub: [13][]u16 = @splat(&.{});
    var merged: []u16 = &.{};
    var i_sub: u5 = 0;
    for (0..list.len) |i_list| {
        merged = list[i_list..][0..1];
        i_sub = 0;
        while (i_list & (@as(usize, 1) << i_sub) != 0) : (i_sub += 1) {
            merge(content, sub[i_sub], &merged, buffer);
        }
        sub[i_sub] = merged;
    }
    i_sub += 1;
    while (i_sub < sub.len) : (i_sub += 1) {
        if (list.len & (@as(usize, 1) << i_sub) != 0) merge(content, sub[i_sub], &merged, buffer);
    }
    std.debug.assert(merged.ptr == list.ptr);
    return merged.len;
}

/// Iterates over the pages in the WAL in page order, giving the last frame
/// of each (WalIterator). Two algorithms, as in SQLite 3.54: a merge of the
/// sorted hash-table pages (WALITER-1), or a map indexed by page number
/// (WALITER-2), whichever needs less memory.
const Iterator = struct {
    gpa: Allocator,
    /// The last page returned (iPrior).
    prior: u32 = 0,
    /// Pages in the page map, 0 for WALITER-1 (nPagemap).
    n_pagemap: u32 = 0,
    /// WALITER-2: the last frame of each page, indexed by page number.
    pagemap: []u32 = &.{},
    /// WALITER-1: one segment per wal-index page.
    segments: []Segment = &.{},
    /// Storage for the segments' sorted indexes.
    index: []u16 = &.{},

    const Segment = struct {
        /// Next entry of `index` to return (iNext).
        next: usize = 0,
        /// Indexes into `pgno`, ascending by page (aIndex).
        index: []u16 = &.{},
        pgno: [*]const volatile u32 = undefined,
        /// Entries in `index` (nEntry).
        n_entry: usize = 0,
        /// Frame of pgno[0] (iZero).
        zero: u32 = 0,
    };

    fn deinit(it: *Iterator) void {
        it.gpa.free(it.pagemap);
        it.gpa.free(it.segments);
        it.gpa.free(it.index);
    }

    /// Port of walIteratorInit(): iterate over the frames after
    /// `n_backfill` (earlier ones may be included). The checkpoint lock
    /// is held and the WAL is not empty.
    fn init(w: *Wal, n_backfill: u32) Error!Iterator {
        std.debug.assert(w.ckpt_lock and w.hdr.mx_frame > 0);
        const gpa = w.gpa;
        const i_last = w.hdr.mx_frame;
        const first_page = framePage(n_backfill + 1);
        const last_page = framePage(i_last);
        const i_zero: u32 = if (first_page != 0) hashtable_npage_one + (first_page - 1) * hashtable_npage else 0;

        var it: Iterator = .{ .gpa = gpa };
        errdefer it.deinit();
        var tmp: []u16 = &.{};
        defer gpa.free(tmp);
        const alg2 = @as(u64, i_last - i_zero) * @sizeOf(u16) > @as(u64, w.hdr.n_page) * @sizeOf(u32);
        if (alg2) {
            it.n_pagemap = w.hdr.n_page;
            it.pagemap = try gpa.alloc(u32, @as(usize, w.hdr.n_page) + 1);
            @memset(it.pagemap, 0);
        } else {
            it.segments = try gpa.alloc(Segment, last_page - first_page + 1);
            @memset(it.segments, .{});
            it.index = try gpa.alloc(u16, i_last - i_zero);
            tmp = try gpa.alloc(u16, @min(i_last, hashtable_npage));
        }

        var i = first_page;
        while (i <= last_page) : (i += 1) {
            var loc = try w.hashGet(i);
            const n_entry: u32 = if (i == last_page) i_last - loc.zero else pgnoSlots(i);
            if (alg2) {
                for (0..n_entry) |j| {
                    const pgno = loc.pgno[j];
                    if (pgno <= it.n_pagemap) it.pagemap[pgno] = loc.zero + @as(u32, @intCast(j)) + 1;
                }
            } else {
                std.debug.assert(i != first_page or i_zero == loc.zero);
                const index = it.index[loc.zero - i_zero ..][0..n_entry];
                loc.zero += 1;
                for (index, 0..) |*x, j| x.* = @intCast(j);
                const n = mergesort(loc.pgno, tmp, index);
                it.segments[i - first_page] = .{
                    .zero = loc.zero,
                    .n_entry = n,
                    .index = index,
                    .pgno = loc.pgno,
                };
            }
        }
        return it;
    }

    const Entry = struct { pgno: u32, frame: u32 };

    /// Port of walIteratorNext(): the next page after the last one
    /// returned, and its last frame, or null at the end.
    fn next(it: *Iterator) ?Entry {
        var ret: u32 = 0xFFFFFFFF;
        var frame: u32 = 0;
        if (it.n_pagemap != 0) {
            while (it.prior < it.n_pagemap) {
                it.prior += 1;
                if (it.pagemap[it.prior] != 0) {
                    ret = it.prior;
                    frame = it.pagemap[it.prior];
                    break;
                }
            }
        } else {
            const min = it.prior;
            std.debug.assert(min < 0xffffffff);
            var i = it.segments.len;
            while (i > 0) {
                i -= 1;
                const seg = &it.segments[i];
                while (seg.next < seg.n_entry) {
                    const pg = seg.pgno[seg.index[seg.next]];
                    if (pg > min) {
                        if (pg < ret) {
                            ret = pg;
                            frame = seg.zero + seg.index[seg.next];
                        }
                        break;
                    }
                    seg.next += 1;
                }
            }
        }
        it.prior = ret;
        if (ret == 0xFFFFFFFF) return null;
        return .{ .pgno = ret, .frame = frame };
    }
};

/// Narrows a RetryError for callers that cannot see Retry.
fn noRetry(r: RetryError!void) Error!void {
    r catch |err| switch (err) {
        // Only a read-only (unreliable) shared memory retries, and
        // checkpoints refuse read-only WALs before reading the header.
        error.Retry => return error.Protocol,
        else => |e| return e,
    };
}

test {
    _ = @import("wal_test.zig");
}
