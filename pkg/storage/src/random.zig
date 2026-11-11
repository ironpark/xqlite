//! Where the storage layer takes its random bytes (C: sqlite3_randomness()
//! in pager.c and wal.c): the journal's checksum seed and the WAL's salts.
//! The engine sets `hook` to its PRNG, which tests save, restore and seed
//! (SQLITE_TESTCTRL_PRNG_*), so that the sequence of random numbers is
//! SQLite's; without it, the VFS's randomness.

const vfs = @import("xqlite_vfs").vfs;

/// Fills the buffer with random bytes; `v` is the VFS of the file, for
/// a generator not seeded yet. Set it once, before opening databases:
/// it is read without synchronization.
pub var hook: ?*const fn (v: vfs.Vfs, buf: []u8) void = null;

/// `buf` filled from the hook, or from `v` if none is set.
pub fn fill(v: vfs.Vfs, buf: []u8) void {
    if (hook) |h| return h(v, buf);
    v.randomness(buf);
}
