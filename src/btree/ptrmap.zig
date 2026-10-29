//! The pointer map of auto-vacuum databases (the ptrmap* routines of
//! btree.c).
//!
//! Every page after page 1 has a 5-byte entry recording what kind of page
//! it is and which page points at it, so that a page can be moved and the
//! pointer to it fixed up. The entries live on pointer-map pages: page 2,
//! then every usableSize/5+1 pages after it (skipping the lock page).

const std = @import("std");
const btree = @import("btree.zig");
const page = @import("page.zig");

const Btree = btree.Btree;
const Pgno = btree.Pgno;
const Error = btree.Error;
const MemPage = page.MemPage;
const get4 = page.get4;
const put4 = page.put4;

/// Entry types (PTRMAP_*).
pub const Type = enum(u8) {
    /// A b-tree root page; the parent is 0.
    root_page = 1,
    /// A freelist page; the parent is 0.
    free_page = 2,
    /// The first page of an overflow chain; the parent is the b-tree page
    /// holding the cell.
    overflow1 = 3,
    /// A later page of an overflow chain; the parent is the previous page.
    overflow2 = 4,
    /// A non-root b-tree page; the parent is its parent page.
    btree_page = 5,
};

pub const Entry = struct { e_type: Type, parent: Pgno };

/// Port of ptrmapPageno(): the pointer-map page holding the entry for
/// `pgno` (`pgno` itself if it is a pointer-map page). 0 for page 1.
pub fn pageno(bt: *const Btree, pgno: Pgno) Pgno {
    if (pgno < 2) return 0;
    const per_page = bt.usable_size / 5 + 1;
    const i_ptrmap = (pgno - 2) / per_page;
    var ret = i_ptrmap * per_page + 2;
    if (bt.pager.isLockPage(ret)) ret += 1;
    return ret;
}

/// PTRMAP_ISPAGE.
pub fn isPage(bt: *const Btree, pgno: Pgno) bool {
    return pageno(bt, pgno) == pgno;
}

/// PTRMAP_ISPAGE or the lock page: pages that never hold b-tree data.
pub fn isReserved(bt: *const Btree, pgno: Pgno) bool {
    return isPage(bt, pgno) or bt.pager.isLockPage(pgno);
}

/// PTRMAP_PTROFFSET, or null if `key` has no entry on `i_ptrmap`.
fn offsetOf(bt: *const Btree, i_ptrmap: Pgno, key: Pgno) ?u32 {
    if (key <= i_ptrmap) return null;
    const offset = 5 * (key - i_ptrmap - 1);
    if (offset > bt.usable_size - 5) return null;
    return offset;
}

/// Port of ptrmapGet().
pub fn get(bt: *Btree, key: Pgno) Error!Entry {
    const i_ptrmap = pageno(bt, key);
    const pg = try bt.pager.get(i_ptrmap, .{});
    defer bt.pager.unref(pg);
    const offset = offsetOf(bt, i_ptrmap, key) orelse return error.Corrupt;
    const data = pg.data.ptr;
    if (data[offset] < 1 or data[offset] > 5) return error.Corrupt;
    return .{ .e_type = @fromBackingInt(@intCast(data[offset])), .parent = get4(data + offset + 1) };
}

/// Port of ptrmapPut(): record that page `key` is of type `e_type` and
/// pointed to by `parent`.
pub fn put(bt: *Btree, key: Pgno, e_type: Type, parent: Pgno) Error!void {
    std.debug.assert(bt.isAutoVacuum());
    if (key == 0) return error.Corrupt;
    const i_ptrmap = pageno(bt, key);
    const pg = try bt.pager.get(i_ptrmap, .{});
    defer bt.pager.unref(pg);
    // A pointer-map page in use as a b-tree page means corruption.
    if (MemPage.of(pg).is_init) return error.Corrupt;
    const offset = offsetOf(bt, i_ptrmap, key) orelse return error.Corrupt;
    const data = pg.data.ptr;
    if (@backingInt(e_type) != data[offset] or get4(data + offset + 1) != parent) {
        try bt.pager.write(pg);
        data[offset] = @backingInt(e_type);
        put4(data + offset + 1, parent);
    }
}

/// Port of ptrmapPutOvflPtr(): `cell` will be part of `pg`; if it spills
/// into an overflow chain, point the chain's first page at `pg`. `src` is
/// the page the cell currently lives on.
pub fn putOvflPtr(pg: *MemPage, src: *const MemPage, cell: [*]u8) Error!void {
    const info = pg.parseCell(cell);
    if (info.n_local < info.n_payload) {
        if (btree.straddles(src.data_end, cell, cell + info.n_local)) return error.Corrupt;
        const ovfl = get4(cell + info.n_size - 4);
        try put(pg.bt, ovfl, .overflow1, pg.pgno);
    }
}
