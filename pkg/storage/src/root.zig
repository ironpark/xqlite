//! xqlite_storage: the storage layer of xqlite (pager.c, pcache.c, wal.c
//! and btree.c), a package of its own above xqlite_vfs and xqlite_base.
//! It depends on nothing of the engine: the engine hands it an allocator,
//! the VFS and its callbacks (busy handler, page spill, key comparison,
//! ...).
//!
//! Besides the layers themselves it holds the file format the engine
//! shares: the record format (serial types, header varints, integer
//! decoding) and varints.

/// The pager: journal, savepoints, locking, and WAL through `pager.wal`.
pub const pager = @import("pager/pager.zig");
/// The page cache.
pub const pcache = @import("pager/pcache.zig");
/// The rollback journal's format.
pub const journal = @import("pager/journal.zig");
/// The b-tree layer, with the file header (`btree.header`).
pub const btree = @import("btree/btree.zig");
/// The record format: serial types, header varints, integer decoding,
/// and a Value codec with sqlite3VdbeRecordCompare for the tests.
pub const record = @import("record.zig");
/// SQLite's variable-length integers.
pub const varint = @import("varint.zig");
/// Where corruption was found: `corrupt.hook`.
pub const corrupt = @import("corrupt.zig");
/// The b-tree fuzzers (`model`, `corrupt`).
pub const btree_fuzz = @import("btree/btree_fuzz.zig");

/// The SQLite release this port tracks (SQLITE_VERSION_NUMBER), which the
/// pager writes into the file header. Keep in sync with sqlite_version in
/// tools/xqt/fetch.zig.
pub const sqlite_version_number = 3054001;

test {
    @import("std").testing.refAllDecls(@This());
    inline for (.{ pager, pcache, journal, btree, record, varint, btree_fuzz, corrupt }) |file| {
        @import("std").testing.refAllDecls(file);
    }
}
