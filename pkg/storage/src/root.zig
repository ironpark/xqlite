//! xqlite_storage: the storage layer of xqlite (pager.c, pcache.c, wal.c
//! and btree.c), a package of its own above xqlite_vfs. It depends on
//! nothing of the engine: the engine hands it an allocator, the VFS and
//! its callbacks (busy handler, page spill, key comparison, ...).
//!
//! Besides the layers themselves it holds what they share with the
//! engine, so that each exists once: the varint and record formats, the
//! callback closures (thunk), the sqlite3_status() counters and the
//! helpers of the seeded fuzzers.

/// The pager: journal, savepoints, locking, and WAL through `pager.wal`.
pub const pager = @import("pager/pager.zig");
/// The page cache.
pub const pcache = @import("pager/pcache.zig");
/// The rollback journal's format.
pub const journal = @import("pager/journal.zig");
/// The b-tree layer, with the file header (`btree.header`).
pub const btree = @import("btree/btree.zig");
/// The record format (serial types, sqlite3VdbeRecordCompare).
pub const record = @import("record.zig");
/// SQLite's variable-length integers.
pub const varint = @import("varint.zig");
/// Closures: a function and its context, for callbacks.
pub const thunk = @import("thunk.zig");
/// The status counters of the library (sqlite3_status()).
pub const status = @import("status.zig");
/// Helpers of the seeded fuzzers (src/fuzz_tests.zig).
pub const fuzz = @import("fuzz.zig");
/// The b-tree fuzzers (`model`, `corrupt`).
pub const btree_fuzz = @import("btree/btree_fuzz.zig");

/// The SQLite release this port tracks (SQLITE_VERSION_NUMBER), which the
/// pager writes into the file header. Keep in sync with sqlite_version in
/// tools/xqt/fetch.zig.
pub const sqlite_version_number = 3054001;

test {
    @import("std").testing.refAllDecls(@This());
    inline for (.{ pager, pcache, journal, btree, record, varint, thunk, status, fuzz, btree_fuzz }) |file| {
        @import("std").testing.refAllDecls(file);
    }
}
