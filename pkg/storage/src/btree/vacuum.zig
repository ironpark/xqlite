//! Page relocation for auto-vacuum (part of btree.c): moving pages from
//! the end of the file into free slots, with the pointers to them fixed
//! up through the pointer map. The entry points (incremental vacuum,
//! auto-vacuum at commit) stay in btree.zig.

const std = @import("std");
const corrupt = @import("../corrupt.zig").corrupt;
const checking = @import("../corrupt.zig").checking;
const pager_mod = @import("../pager/pager.zig");
const varint = @import("../varint.zig");
const btree = @import("btree.zig");
const header = btree.header;
const page = @import("page.zig");
const ptrmap = @import("ptrmap.zig");
const alloc = @import("alloc.zig");

const Btree = btree.Btree;
const Error = btree.Error;
const Pgno = btree.Pgno;
const Payload = btree.Payload;
const MemPage = page.MemPage;
const CellInfo = page.CellInfo;
const releasePage = btree.releasePage;
const get2 = page.get2;
const put2 = page.put2;
const get4 = page.get4;
const put4 = page.put4;

/// Port of invalidateAllOverflowCache(): pages are about to move, so
/// cached overflow page numbers may go stale.
pub fn invalidateAllOverflowCache(bt: *Btree) void {
    var it = bt.cursors;
    while (it) |c| : (it = c.next_cursor) c.flags.valid_ovfl = false;
}

/// Port of relocatePage(): move `pg` (whose pointer-map entry is
/// `e_type`/`ptr_page`) to the unused location `free_pgno`, fixing the
/// pointer to it and the pointer-map entries of the pages it points
/// to. `pg` stays referenced. See `Pager.movePage` for `is_commit`.
pub fn relocatePage(bt: *Btree, pg: *MemPage, e_type: ptrmap.Type, ptr_page: Pgno, free_pgno: Pgno, is_commit: bool) Error!void {
    std.debug.assert(e_type != .free_page);
    const old_pgno = pg.pgno;
    if (old_pgno < 3) return corrupt(@src());

    try bt.pager.movePage(pg.db_page, free_pgno, is_commit);
    pg.pgno = free_pgno;

    if (e_type == .btree_page or e_type == .root_page) {
        try ptrmap.setChildPtrmaps(pg);
    } else {
        const next_ovfl = get4(pg.data);
        if (next_ovfl != 0) try ptrmap.put(bt, next_ovfl, .overflow2, free_pgno);
    }

    if (e_type != .root_page) {
        const ptr_pg = try page.getPage(bt, ptr_page, .{});
        defer releasePage(ptr_pg);
        try bt.pager.write(ptr_pg.db_page);
        try modifyPagePointer(ptr_pg, old_pgno, free_pgno, e_type);
        try ptrmap.put(bt, free_pgno, e_type, ptr_page);
    }
}

/// Port of incrVacuumStep(): make `last_pg` unused, moving its content
/// to a free page if it has any. `n_fin` is the size the database will
/// have when vacuuming is done. With `at_commit` the caller keeps calling
/// until the file is `n_fin` pages and then drops the whole freelist;
/// otherwise each call also shrinks `n_page`. Returns false when there
/// is nothing left to do.
pub fn incrVacuumStep(bt: *Btree, n_fin: Pgno, last_pg_arg: Pgno, at_commit: bool) Error!bool {
    std.debug.assert(last_pg_arg > n_fin);
    var last_pg = last_pg_arg;
    if (!ptrmap.isReserved(bt, last_pg)) {
        if (header.get(bt.page1.?.data, .freelist_count) == 0) return false;
        const e = try ptrmap.get(bt, last_pg);
        if (e.e_type == .root_page) return corrupt(@src());

        if (e.e_type == .free_page) {
            // Take it off the freelist. Unneeded at commit: the whole
            // freelist is dropped afterwards.
            if (!at_commit) {
                const free_pg = try alloc.allocatePage(bt, last_pg, .exact);
                std.debug.assert(free_pg.pgno == last_pg);
                releasePage(free_pg);
            }
        } else {
            const last = try page.getPage(bt, last_pg, .{});
            defer releasePage(last);
            // Without `at_commit`, swap with the first free page at or
            // below `n_fin`; with it, keep allocating until one lands
            // within the final size.
            const mode: alloc.AllocMode = if (at_commit) .any else .le;
            const near: Pgno = if (at_commit) 0 else n_fin;
            var free_pgno: Pgno = undefined;
            while (true) {
                const db_size = bt.n_page;
                const free_pg = try alloc.allocatePage(bt, near, mode);
                free_pgno = free_pg.pgno;
                releasePage(free_pg);
                if (free_pgno > db_size) return corrupt(@src());
                if (!at_commit or free_pgno <= n_fin) break;
            }
            std.debug.assert(free_pgno < last_pg);
            try relocatePage(bt, last, e.e_type, e.parent, free_pgno, at_commit);
        }
    }

    if (!at_commit) {
        last_pg -= 1;
        while (ptrmap.isReserved(bt, last_pg)) last_pg -= 1;
        bt.do_truncate = true;
        bt.n_page = last_pg;
    }
    return true;
}

/// Port of finalDbSize(): the size of a database of `n_orig` pages
/// after vacuuming away `n_free` free pages, along with the
/// pointer-map pages no longer needed.
pub fn finalDbSize(bt: *Btree, n_orig: Pgno, n_free: Pgno) Pgno {
    const n_entry = bt.usable_size / 5;
    const n_ptrmap = (n_free -% n_orig +% ptrmap.pageno(bt, n_orig) +% n_entry) / n_entry;
    var n_fin = n_orig -% n_free -% n_ptrmap;
    const lck = bt.pager.lockPage();
    if (n_orig > lck and n_fin < lck) n_fin -%= 1;
    while (ptrmap.isReserved(bt, n_fin)) n_fin -%= 1;
    return n_fin;
}

/// Port of modifyPagePointer(): change the pointer to `from` on `pg` to
/// point at `to`. `e_type` says which pointer: a child (btree_page), the
/// overflow chain of a cell (overflow1), or the next-page link of an
/// overflow page (overflow2). `pg` must be writable.
pub fn modifyPagePointer(pg: *MemPage, from: Pgno, to: Pgno, e_type: ptrmap.Type) Error!void {
    if (e_type == .overflow2) {
        if (get4(pg.data) != from) return corrupt(@src());
        put4(pg.data, to);
        return;
    }
    if (!pg.is_init) try pg.init();
    const usable_end = pg.data + pg.bt.usable_size;
    for (0..pg.n_cell) |i| {
        const cell = pg.findCell(i);
        if (e_type == .overflow1) {
            const info = pg.parseCell(cell);
            if (info.n_local < info.n_payload) {
                if (@intFromPtr(cell + info.n_size) > @intFromPtr(usable_end)) return corrupt(@src());
                if (get4(cell + info.n_size - 4) == from) {
                    put4(cell + info.n_size - 4, to);
                    return;
                }
            }
        } else {
            if (@intFromPtr(cell + 4) > @intFromPtr(usable_end)) return corrupt(@src());
            if (get4(cell) == from) {
                put4(cell, to);
                return;
            }
        }
    }
    if (e_type != .btree_page or pg.rightChild() != from) return corrupt(@src());
    put4(pg.data + pg.hdr_offset + 8, to);
}
