//! Balancing (part of btree.c): after an insert or delete leaves a page
//! too full or too empty, redistribute its cells among it and its
//! siblings (`balanceNonroot`), push the root's content down a level
//! (`balanceDeeper`), or start a new rightmost leaf (`balanceQuick`).
//! The pages are rebuilt or edited in place from a `CellArray` of all
//! their cells. Functions of a b-tree, which btree.zig uses as its
//! methods.

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

/// Port of balance_quick(): `pg` is the rightmost leaf of a table and
/// overflows with one cell at its end, as when appending rows. Put that
/// cell alone on a new right sibling instead of redistributing.
pub fn balanceQuick(bt: *Btree, parent: *MemPage, pg: *MemPage, space: *[13]u8) Error!void {
    std.debug.assert(pg.n_overflow == 1);
    if (pg.n_cell == 0) return corrupt(@src());
    const new = try alloc.allocatePage(bt, 0, .any);
    defer releasePage(new);

    var cells = [1][*]u8{pg.ap_ovfl[0]};
    var sizes = [1]u16{pg.cellSize(pg.ap_ovfl[0])};
    new.zero(page.table_leaf);
    var b: CellArray = .{ .n_cell = 1, .ref = pg, .cells = &cells, .sizes = &sizes };
    b.ap_end[0] = pg.data_end;
    b.ix_nx[0] = 2;
    try rebuildPage(&b, 0, 1, new);
    new.n_free = @intCast(bt.usable_size - new.cell_offset - 2 - sizes[0]);
    if (bt.isAutoVacuum()) {
        try ptrmap.put(bt, new.pgno, .btree_page, parent.pgno);
        if (sizes[0] > new.min_local) try ptrmap.putOvflPtr(new, new, cells[0]);
    }

    // The divider is the largest rowid on `pg`: skip the payload size
    // of its last cell and copy the rowid varint.
    var cell = pg.findCell(pg.n_cell - 1);
    var stop = cell + 9;
    while (true) {
        const byte = cell[0];
        cell += 1;
        if (byte & 0x80 == 0 or @intFromPtr(cell) >= @intFromPtr(stop)) break;
    }
    stop = cell + 9;
    var out: u32 = 4;
    while (true) {
        const byte = cell[0];
        space[out] = byte;
        out += 1;
        cell += 1;
        if (byte & 0x80 == 0 or @intFromPtr(cell) >= @intFromPtr(stop)) break;
    }
    const r = parent.insertCell(parent.n_cell, space, out, null, pg.pgno);
    put4(parent.data + parent.hdr_offset + 8, new.pgno);
    return r;
}

/// Port of balance_deeper(): the root overflows. Move its content to a
/// new child and leave the root empty with that child on the right.
/// Returns the child, referenced.
pub fn balanceDeeper(bt: *Btree, root: *MemPage) Error!*MemPage {
    std.debug.assert(root.n_overflow > 0);
    try bt.pager.write(root.db_page);
    const child = try alloc.allocatePage(bt, root.pgno, .any);
    errdefer releasePage(child);
    try copyNodeContent(root, child);
    if (bt.isAutoVacuum()) try ptrmap.put(bt, child.pgno, .btree_page, root.pgno);

    const n = root.n_overflow;
    @memcpy(child.ai_ovfl[0..n], root.ai_ovfl[0..n]);
    @memcpy(child.ap_ovfl[0..n], root.ap_ovfl[0..n]);
    child.n_overflow = n;

    root.zero(child.data[0] & ~page.ptf_leaf);
    put4(root.data + root.hdr_offset + 8, child.pgno);
    return child;
}

/// Port of balance_nonroot(): redistribute the cells of child
/// `i_parent_idx` of `parent` and up to two siblings so that all are
/// about equally full, adding or removing siblings as needed. The
/// parent may end up over- or underfull; the caller balances it next.
/// `ovfl_space` (page-sized) holds divider cells that overflow the
/// parent and must live until the parent is balanced. On error the
/// database may be inconsistent and must be rolled back.
pub fn balanceNonroot(
    bt: *Btree,
    parent: *MemPage,
    i_parent_idx: u32,
    ovfl_space: []u8,
    is_root: bool,
    bulk: bool,
) Error!void {
    std.debug.assert(parent.n_overflow == 0 or (parent.n_overflow == 1 and parent.ai_ovfl[0] == i_parent_idx));
    std.debug.assert(parent.n_free >= 0);
    var s: Balance = .{
        .bt = bt,
        .parent = parent,
        .i_parent_idx = i_parent_idx,
        .ovfl_space = ovfl_space,
        .bulk = bulk,
    };
    defer s.deinit();
    const n_max_cells = try s.gatherSiblings();
    try s.loadCells(n_max_cells);
    try s.distribute();
    try s.assignPages();
    if (bt.isAutoVacuum()) try s.updatePtrmap();
    try s.insertDividers();
    try s.rewriteSiblings();
    try s.finish(is_root);
}

/// The state of one balanceNonroot(), whose steps (the sections of
/// balance_nonroot()) are its methods, in the order they run.
const Balance = struct {
    bt: *Btree,
    parent: *MemPage,
    i_parent_idx: u32,
    ovfl_space: []u8,
    bulk: bool,

    /// The siblings before (ap_old) and after (ap_new) the balance; the
    /// old pages that are reused move from one to the other.
    ap_old: [nb]?*MemPage = @splat(null),
    ap_new: [nb + 2]?*MemPage = @splat(null),
    n_old: u32 = 0,
    n_new: usize = 0,
    /// The dividers of the siblings, from the parent.
    ap_div: [nb - 1][*]u8 = undefined,
    /// Index in the parent of the divider left of the first sibling.
    nx_div: u32 = 0,
    /// Where the parent points to the last sibling.
    right: [*]u8 = undefined,
    /// A page number near which to allocate new siblings.
    pgno: Pgno = 0,
    /// Index in b.cells of the first cell right of the i-th page, before
    /// and after; the bytes the i-th new page uses.
    cnt_old: [nb + 2]i32 = undefined,
    cnt_new: [nb + 2]i32 = undefined,
    sz_new: [nb + 2]i32 = undefined,
    /// Pages the cells go on.
    k: usize = 0,

    b: CellArray = .{ .ref = undefined, .cells = &.{}, .sizes = &.{} },
    /// Copies of the dividers, which leave the parent.
    space1: []u8 = undefined,
    scratch: []align(@alignOf([*]u8)) u8 = &.{},
    n_cell_total: i32 = 0,
    /// 4 on leaves, whose dividers lose their child pointer.
    leaf_correction: u16 = 0,
    /// Table leaves: no divider cells among the cells.
    leaf_data: bool = false,
    usable_space: i32 = 0,
    /// The page numbers of ap_new before they are put in order.
    a_pgno: [nb + 2]Pgno = undefined,

    fn deinit(s: *Balance) void {
        s.bt.gpa.free(s.scratch);
        for (s.ap_old) |o| if (o) |x| releasePage(x);
        for (s.ap_new) |o| if (o) |x| releasePage(x);
    }

    /// Choose the siblings: NN on each side of the page if possible,
    /// more from one side at the edges, all children if there are at
    /// most NB. Their divider cells are dropped from the parent now so
    /// that the parent has no overflow cells left. Returns how many cells
    /// they may hold.
    inline fn gatherSiblings(s: *Balance) Error!u32 {
        const bt = s.bt;
        const parent = s.parent;
        var i: u32 = parent.n_overflow + parent.n_cell;
        if (i >= 2) {
            const bulk_n: u32 = @intFromBool(s.bulk);
            if (s.i_parent_idx == 0) {
                s.nx_div = 0;
            } else if (s.i_parent_idx == i) {
                s.nx_div = i - 2 + bulk_n;
            } else {
                s.nx_div = s.i_parent_idx - 1;
            }
            i = 2 - bulk_n;
        }
        const nx_div = s.nx_div;
        s.n_old = i + 1;
        s.right = if (i + nx_div - parent.n_overflow == parent.n_cell)
            parent.data + parent.hdr_offset + 8
        else
            parent.findCell(i + nx_div - parent.n_overflow);
        s.pgno = get4(s.right);
        var n_max_cells: u32 = 0;
        while (true) {
            const old = try page.getAndInitPage(bt, s.pgno);
            s.ap_old[i] = old;
            if (old.n_free < 0) try old.computeFreeSpace();
            n_max_cells += old.n_cell + @as(u32, old.ap_ovfl.len);
            if (i == 0) break;
            i -= 1;

            if (parent.n_overflow != 0 and i + nx_div == parent.ai_ovfl[0]) {
                s.ap_div[i] = parent.ap_ovfl[0];
                s.pgno = get4(s.ap_div[i]);
                s.sz_new[i] = parent.cellSize(s.ap_div[i]);
                parent.n_overflow = 0;
            } else {
                s.ap_div[i] = parent.findCell(i + nx_div - parent.n_overflow);
                s.pgno = get4(s.ap_div[i]);
                const sz: u32 = parent.cellSize(s.ap_div[i]);
                s.sz_new[i] = @intCast(sz);
                // Dropping a cell overwrites only its first 4 bytes, which
                // are not needed. Secure delete zeroes it all, so keep a
                // copy in ovfl_space until aSpace1 exists.
                if (bt.secure_delete != .off) {
                    const off = parent.offsetOf(s.ap_div[i]);
                    if (off + sz <= bt.usable_size) {
                        @memcpy(s.ovfl_space[off..][0..sz], s.ap_div[i][0..sz]);
                        s.ap_div[i] = s.ovfl_space.ptr + off;
                    }
                }
                try parent.dropCell(i + nx_div - parent.n_overflow, sz);
            }
        }
        return n_max_cells;
    }

    /// Gather pointers to every cell of the siblings and copies of the
    /// dividers (from space1). On leaves the dividers lose their child
    /// pointer, on interior pages they take the left sibling's right
    /// pointer, so all cells in b look alike.
    inline fn loadCells(s: *Balance, n_max_cells_arg: u32) Error!void {
        const bt = s.bt;
        const b = &s.b;
        // Multiple of 4 to keep the original 8-byte alignment reasoning.
        const n_max_cells = (n_max_cells_arg + 3) & ~@as(u32, 3);
        // One allocation holds the cell pointers, their sizes and aSpace1.
        const ptrs_len = n_max_cells * @sizeOf([*]u8);
        const sizes_len = n_max_cells * @sizeOf(u16);
        s.scratch = try bt.gpa.alignedAlloc(u8, .of([*]u8), ptrs_len + sizes_len + bt.page_size);
        b.cells = @as([*][*]u8, @ptrCast(s.scratch.ptr))[0..n_max_cells];
        b.sizes = @as([*]u16, @ptrCast(@alignCast(s.scratch.ptr + ptrs_len)))[0..n_max_cells];
        s.space1 = s.scratch[ptrs_len + sizes_len ..];

        b.ref = s.ap_old[0].?;
        s.leaf_correction = if (b.ref.leaf) 4 else 0;
        s.leaf_data = b.ref.int_key_leaf;
        var i_space1: u32 = 0;
        for (0..s.n_old) |ii| {
            const old = s.ap_old[ii].?;
            const data = old.data;
            const mask = old.mask_page;
            var pi_cell = data + old.cell_offset;
            // All siblings must be the same kind of page.
            if (old.data[0] != b.ref.data[0]) return corrupt(@src());

            @memset(b.sizes[b.n_cell..][0 .. old.n_cell + old.n_overflow], 0);
            if (old.n_overflow > 0) {
                if (old.n_cell < old.ai_ovfl[0]) return corrupt(@src());
                for (0..old.ai_ovfl[0]) |_| {
                    b.cells[b.n_cell] = data + (mask & get2(pi_cell));
                    pi_cell += 2;
                    b.n_cell += 1;
                }
                // Multiple overflow cells are always adjacent.
                for (old.ap_ovfl[0..old.n_overflow]) |c| {
                    b.cells[b.n_cell] = c;
                    b.n_cell += 1;
                }
            }
            // The cell pointers, with the count and array in locals (a
            // store through b.cells may alias b.n_cell).
            const pi_end = data + old.cell_offset + 2 * @as(u32, old.n_cell);
            const cells = b.cells.ptr;
            var n_cell = b.n_cell;
            while (@intFromPtr(pi_cell) < @intFromPtr(pi_end)) {
                cells[n_cell] = data + (mask & get2(pi_cell));
                pi_cell += 2;
                n_cell += 1;
            }
            b.n_cell = n_cell;

            s.cnt_old[ii] = @intCast(b.n_cell);
            if (ii < s.n_old - 1 and !s.leaf_data) {
                const sz: u16 = @intCast(s.sz_new[ii]);
                const temp = s.space1.ptr + i_space1;
                i_space1 += sz;
                if (i_space1 > bt.page_size) return corrupt(@src());
                @memcpy(temp[0..sz], s.ap_div[ii][0..sz]);
                b.cells[b.n_cell] = temp + s.leaf_correction;
                b.sizes[b.n_cell] = sz - s.leaf_correction;
                if (!old.leaf) {
                    // The right pointer of `old` becomes the left pointer of
                    // the divider.
                    b.cells[b.n_cell][0..4].* = old.data[8..12].*;
                } else {
                    // No cell may be smaller than 4 bytes; pad with zeros.
                    while (b.sizes[b.n_cell] < 4) {
                        s.space1[i_space1] = 0;
                        i_space1 += 1;
                        b.sizes[b.n_cell] += 1;
                    }
                }
                b.n_cell += 1;
            }
        }
        s.n_cell_total = @intCast(b.n_cell);
    }

    /// Work out how many pages the cells need (k), the bytes used on each
    /// (sz_new) and where each page ends (cnt_new): a first packing that
    /// fills pages from the left, then cells shifted right to even it out.
    inline fn distribute(s: *Balance) Error!void {
        const b = &s.b;
        const leaf_data = s.leaf_data;
        const n_cell_total = s.n_cell_total;
        const sz_new = &s.sz_new;
        const cnt_new = &s.cnt_new;
        s.usable_space = @intCast(s.bt.usable_size - 12 + s.leaf_correction);
        const usable_space = s.usable_space;
        var k: usize = 0;
        for (0..s.n_old) |ii| {
            const p = s.ap_old[ii].?;
            b.ap_end[k] = p.data_end;
            b.ix_nx[k] = @intCast(s.cnt_old[ii]);
            // Skip entries for siblings without cells.
            if (k > 0 and b.ix_nx[k] == b.ix_nx[k - 1]) k -= 1;
            if (!leaf_data) {
                k += 1;
                b.ap_end[k] = s.parent.data_end;
                b.ix_nx[k] = @intCast(s.cnt_old[ii] + 1);
            }
            sz_new[ii] = usable_space - p.n_free;
            for (p.ap_ovfl[0..p.n_overflow]) |c| sz_new[ii] += 2 + @as(i32, p.cellSize(c));
            cnt_new[ii] = s.cnt_old[ii];
            k += 1;
        }
        k = s.n_old;
        var ii: usize = 0;
        while (ii < k) : (ii += 1) {
            while (sz_new[ii] > usable_space) {
                if (ii + 1 >= k) {
                    k = ii + 2;
                    if (k > nb + 2) return corrupt(@src());
                    sz_new[k - 1] = 0;
                    cnt_new[k - 1] = n_cell_total;
                }
                if (cnt_new[ii] < 1) return corrupt(@src());
                var sz: i32 = 2 + @as(i32, b.cellSizeAt(cnt_new[ii] - 1));
                sz_new[ii] -= sz;
                if (!leaf_data) {
                    sz = if (cnt_new[ii] < n_cell_total) 2 + @as(i32, b.cellSizeAt(cnt_new[ii])) else 0;
                }
                sz_new[ii + 1] += sz;
                cnt_new[ii] -= 1;
            }
            while (cnt_new[ii] < n_cell_total) {
                var sz: i32 = 2 + @as(i32, b.cellSizeAt(cnt_new[ii]));
                if (sz_new[ii] + sz > usable_space) break;
                sz_new[ii] += sz;
                cnt_new[ii] += 1;
                if (!leaf_data) {
                    sz = if (cnt_new[ii] < n_cell_total) 2 + @as(i32, b.cellSizeAt(cnt_new[ii])) else 0;
                }
                sz_new[ii + 1] -= sz;
            }
            if (cnt_new[ii] >= n_cell_total) {
                k = ii + 1;
            } else if (cnt_new[ii] <= (if (ii > 0) cnt_new[ii - 1] else 0)) {
                return corrupt(@src());
            }
        }

        // The packing above leaves the rightmost page nearly empty, maybe
        // completely. Shift cells right to even it out; this is required,
        // not just an optimization.
        ii = k - 1;
        while (ii > 0) : (ii -= 1) {
            var sz_right = sz_new[ii];
            var sz_left = sz_new[ii - 1];
            var r = cnt_new[ii - 1] - 1;
            var d = r + 1 - @intFromBool(leaf_data);
            while (true) {
                const sz_r: i32 = b.cellSizeAt(r);
                const sz_d: i32 = b.cellSizeAt(d);
                if (sz_right != 0 and
                    (s.bulk or sz_right + sz_d + 2 > sz_left - (sz_r + @as(i32, if (ii == k - 1) 0 else 2))))
                    break;
                sz_right += sz_d + 2;
                sz_left -= sz_r + 2;
                cnt_new[ii - 1] = r;
                r -= 1;
                d -= 1;
                if (r < 0) break;
            }
            sz_new[ii] = sz_right;
            sz_new[ii - 1] = sz_left;
            if (cnt_new[ii - 1] <= (if (ii > 1) cnt_new[ii - 2] else 0)) return corrupt(@src());
        }
        s.k = k;
    }

    /// Reuse the old pages, allocating more if needed, and give them
    /// ascending page numbers.
    inline fn assignPages(s: *Balance) Error!void {
        const bt = s.bt;
        const n_old = s.n_old;
        const page_flags = s.ap_old[0].?.data[0];
        for (0..s.k) |j| {
            if (j < n_old) {
                const new = s.ap_old[j].?;
                s.ap_new[j] = new;
                s.ap_old[j] = null;
                s.n_new += 1;
                try bt.pager.write(new.db_page);
                // Only the cursor (for the page being balanced) may hold
                // another reference.
                const expected = @as(u32, 1) + @intFromBool(@as(i64, @intCast(j)) == @as(i64, s.i_parent_idx) - s.nx_div);
                if (new.db_page.n_ref != expected) return corrupt(@src());
            } else {
                const new = try alloc.allocatePage(bt, if (s.bulk) 1 else s.pgno, .any);
                s.pgno = new.pgno;
                new.zero(page_flags);
                s.ap_new[j] = new;
                s.n_new += 1;
                s.cnt_old[j] = s.n_cell_total;
                if (bt.isAutoVacuum()) try ptrmap.put(bt, new.pgno, .btree_page, s.parent.pgno);
            }
        }
        const n_new = s.n_new;
        const ap_new = &s.ap_new;

        for (0..n_new) |j| s.a_pgno[j] = ap_new[j].?.pgno;

        // Swap page numbers so the new pages are in ascending order, which
        // keeps table scans close to sequential I/O. N is at most 5.
        for (0..n_new - 1) |j| {
            var ib = j;
            for (j + 1..n_new) |m| {
                if (ap_new[m].?.pgno < ap_new[ib].?.pgno) ib = m;
            }
            if (ib != j) {
                const pa = ap_new[j].?;
                const pb = ap_new[ib].?;
                bt.pager.swapPageNumbers(pa.db_page, pb.db_page);
                std.mem.swap(Pgno, &pa.pgno, &pb.pgno);
            }
        }

        put4(s.right, ap_new[n_new - 1].?.pgno);
        // The rightmost new sibling inherits the right child of the
        // rightmost old one.
        if (page_flags & page.ptf_leaf == 0 and n_old != n_new) {
            const old = if (n_new > n_old) ap_new[n_old - 1].? else s.ap_old[n_old - 1].?;
            ap_new[n_new - 1].?.data[8..12].* = old.data[8..12].*;
        }
    }

    /// Pointer-map entries for cells changing pages: their child (on
    /// interior pages) and the start of their overflow chain. Dividers
    /// inserted into the parent are handled by insertCell, the right
    /// children of the siblings after the siblings are filled.
    inline fn updatePtrmap(s: *Balance) Error!void {
        const b = &s.b;
        var old = s.ap_new[0].?;
        var new = old;
        var cnt_old_next: u32 = @as(u32, new.n_cell) + new.n_overflow;
        var i_new: usize = 0;
        var i_old: usize = 0;
        for (0..b.n_cell) |ci| {
            const cell = b.cells[ci];
            while (ci == cnt_old_next) {
                i_old += 1;
                std.debug.assert(i_old < s.n_new or i_old < s.n_old);
                old = if (i_old < s.n_new) s.ap_new[i_old].? else s.ap_old[i_old].?;
                cnt_old_next += @as(u32, old.n_cell) + old.n_overflow + @intFromBool(!s.leaf_data);
            }
            if (ci == @as(usize, @intCast(s.cnt_new[i_new]))) {
                i_new += 1;
                new = s.ap_new[i_new].?;
                if (!s.leaf_data) continue;
            }
            // A cell that stays on the same page needs no update; a
            // divider or overflow cell always does.
            if (i_old >= s.n_new or new.pgno != s.a_pgno[i_old] or !page.within(cell, old.data, old.data_end)) {
                if (s.leaf_correction == 0) try ptrmap.put(s.bt, get4(cell), .btree_page, new.pgno);
                if (b.cellSizeAt(@intCast(ci)) > new.min_local) try ptrmap.putOvflPtr(new, old, cell);
            }
        }
    }

    /// Insert the new dividers into the parent.
    inline fn insertDividers(s: *Balance) Error!void {
        const b = &s.b;
        const parent = s.parent;
        var i_ovfl_space: u32 = 0;
        for (0..s.n_new - 1) |j| {
            const new = s.ap_new[j].?;
            var cj: u32 = @intCast(s.cnt_new[j]);
            var cell = b.cells[cj];
            var sz: u32 = b.sizes[cj] + s.leaf_correction;
            var temp: ?[*]u8 = s.ovfl_space.ptr + i_ovfl_space;
            if (!new.leaf) {
                new.data[8..12].* = cell[0..4].*;
            } else if (s.leaf_data) {
                // Table leaves have no divider cells; the divider is the
                // largest rowid of the left sibling.
                cj -= 1;
                const info = new.parseCell(b.cells[cj]);
                cell = temp.?;
                sz = 4 + @as(u32, varint.put(cell[4..][0..9], @bitCast(info.n_key)));
                temp = null;
            } else {
                cell -= 4;
                // A leaf cell reported as 4 bytes may really be shorter
                // (the minimum size); reparse it for the exact size.
                if (b.sizes[cj] == 4) sz = parent.cellSize(cell);
            }
            i_ovfl_space += sz;
            if (page.straddles(b.ap_end[b.endIndex(cj)], cell, cell + sz)) return corrupt(@src());
            try parent.insertCell(s.nx_div + j, cell, sz, temp, new.pgno);
        }
    }

    /// Rewrite the siblings without clobbering cells still to be read:
    /// when cells move left, page i only after page i-1; when they move
    /// right, only after page i+1. A downward pass then an upward pass
    /// covers every page once.
    inline fn rewriteSiblings(s: *Balance) Error!void {
        const n_new: i32 = @intCast(s.n_new);
        var done: [nb + 2]bool = @splat(false);
        var signed_i: i32 = 1 - n_new;
        while (signed_i < n_new) : (signed_i += 1) {
            const i_pg: usize = @abs(signed_i);
            if (done[i_pg]) continue;
            if (signed_i >= 0 or s.cnt_old[i_pg - 1] >= s.cnt_new[i_pg - 1]) {
                var i_new: u32 = 0;
                var i_old: u32 = 0;
                var n_new_cell: u32 = @intCast(s.cnt_new[0]);
                if (i_pg > 0) {
                    const shift = @intFromBool(!s.leaf_data);
                    i_old = if (i_pg < s.n_old) @intCast(s.cnt_old[i_pg - 1] + shift) else s.b.n_cell;
                    i_new = @intCast(s.cnt_new[i_pg - 1] + shift);
                    n_new_cell = @intCast(s.cnt_new[i_pg] - @as(i32, @intCast(i_new)));
                }
                try editPage(s.ap_new[i_pg].?, i_old, i_new, n_new_cell, &s.b);
                done[i_pg] = true;
                s.ap_new[i_pg].?.n_free = s.usable_space - s.sz_new[i_pg];
            }
        }
    }

    /// Make the tree shallower if the root lost its last divider, fix the
    /// pointer map for the right children, and free the old pages that
    /// were not reused.
    inline fn finish(s: *Balance, is_root: bool) Error!void {
        const bt = s.bt;
        const parent = s.parent;
        const n_new = s.n_new;
        if (is_root and parent.n_cell == 0 and parent.hdr_offset <= s.ap_new[0].?.n_free) {
            // The root lost its last divider: copy the only child into it,
            // making the tree one level shallower (balance-shallower). The
            // child must be defragmented first because page 1 is smaller.
            const child = s.ap_new[0].?;
            try child.defragment(-1);
            try copyNodeContent(child, parent);
            try alloc.freePage(bt, child);
        } else if (bt.isAutoVacuum() and s.leaf_correction == 0) {
            // The right children of the siblings.
            for (s.ap_new[0..n_new]) |new| try ptrmap.put(bt, get4(new.?.data + 8), .btree_page, new.?.pgno);
        }

        if (n_new < s.n_old) {
            for (n_new..s.n_old) |j| try alloc.freePage(bt, s.ap_old[j].?);
        }

        if (checking() and bt.isAutoVacuum()) {
            if (parent.is_init) try ptrmapCheckPage(parent);
            if (s.ap_new[0].?.is_init) for (s.ap_new[0..n_new]) |new| try ptrmapCheckPage(new.?);
        }
    }
};

/// NB: pages taking part in a balance (the page and one neighbour on each
/// side). Has been 3 since SQLite's inception; other values are untested.
pub const nb = 3;

/// The cells of the pages being balanced, in order (CellArray). For index
/// b-trees the parent's dividers sit between the siblings' cells; table
/// b-trees have no dividers. `ap_end[k]` is the end of the page holding
/// cells up to `ix_nx[k]`, used to detect cells that cross a page end.
pub const CellArray = struct {
    n_cell: u32 = 0,
    /// A page of the same kind, for parsing.
    ref: *MemPage,
    cells: [][*]u8,
    /// Cell sizes; 0 means not yet computed.
    sizes: []u16,
    ap_end: [nb * 2][*]u8 = undefined,
    ix_nx: [nb * 2]u32 = @splat(std.math.maxInt(u32)),

    fn cellSizeAt(b: *CellArray, n: i32) u16 {
        const i: usize = @intCast(n);
        if (b.sizes[i] == 0) b.sizes[i] = b.ref.cellSize(b.cells[i]);
        return b.sizes[i];
    }

    fn populate(b: *CellArray, first: u32, n: u32) void {
        for (first..first + n) |i| _ = b.cellSizeAt(@intCast(i));
    }

    /// Index into ap_end of the page holding cell `i`.
    fn endIndex(b: *const CellArray, i: u32) usize {
        var k: usize = 0;
        while (b.ix_nx[k] <= i) k += 1;
        return k;
    }
};

/// Port of rebuildPage(): replace the content of `pg` with cells
/// [first, first+n) of `b`. Cells already on `pg` are copied out first.
/// Leaves `n_free` stale.
pub fn rebuildPage(b: *CellArray, first: u32, n: u32, pg: *MemPage) Error!void {
    std.debug.assert(n > 0);
    const hdr = pg.hdr_offset;
    const a = pg.data;
    const usable = pg.bt.usable_size;
    const end = a + usable;
    const tmp = pg.bt.pager.tempSpace().ptr;
    var j: u32 = get2(a + hdr + 5);
    if (j > usable) j = 0;
    @memcpy(tmp[j..usable], a[j..usable]);

    var k = b.endIndex(first);
    var src_end = b.ap_end[k];
    var cellptr = pg.cell_idx;
    var data = end;
    var i = first;
    while (true) {
        var cell = b.cells[i];
        const sz = b.sizes[i];
        std.debug.assert(sz > 0);
        if (page.within(cell, a + j, end)) {
            if (@intFromPtr(cell) + sz > @intFromPtr(end)) return corrupt(@src());
            cell = tmp + (@intFromPtr(cell) - @intFromPtr(a));
        } else if (page.straddles(src_end, cell, cell + sz)) {
            return corrupt(@src());
        }
        data -= sz;
        // C stores the offset before this check; checking first keeps the
        // offset from going below the start of the page.
        if (@intFromPtr(data) < @intFromPtr(cellptr) + 2) return corrupt(@src());
        put2(cellptr, @intCast(@intFromPtr(data) - @intFromPtr(a)));
        cellptr += 2;
        @memmove(data[0..sz], cell[0..sz]);
        i += 1;
        if (i >= first + n) break;
        if (b.ix_nx[k] <= i) {
            k += 1;
            src_end = b.ap_end[k];
        }
    }

    pg.n_cell = @intCast(n);
    pg.n_overflow = 0;
    put2(a + hdr + 1, 0);
    put2(a + hdr + 3, n);
    put2(a + hdr + 5, @intCast(@intFromPtr(data) - @intFromPtr(a)));
    a[hdr + 7] = 0;
}

/// Port of pageInsertArray(): add cells [first, first+n) of `b`, writing
/// their pointers at `cellptr`. `data` is the start of the content area
/// and `begin` the end of the final cell pointer array. Returns true if
/// they do not fit without defragmenting.
pub fn pageInsertArray(pg: *MemPage, begin: [*]u8, data: *[*]u8, cellptr_arg: [*]u8, first: u32, n: u32, b: *CellArray) bool {
    if (n == 0) return false;
    std.debug.assert(pg.hdr_offset == 0);
    const a = pg.data;
    var p_data = data.*;
    var cellptr = cellptr_arg;
    var k = b.endIndex(first);
    var end = b.ap_end[k];
    var i = first;
    while (true) {
        const sz = b.sizes[i];
        const cell = b.cells[i];
        const free_slot: ?u32 = if (a[1] == 0 and a[2] == 0) null else pg.findSlot(sz) catch null;
        var slot: [*]u8 = undefined;
        if (free_slot) |s| {
            slot = a + s;
        } else {
            if (page.ptrDiff(p_data, begin) < sz) return true;
            p_data -= sz;
            slot = p_data;
        }
        // A cell crossing the end of its page means corruption.
        if (page.straddles(end, cell, cell + sz)) return true;
        @memmove(slot[0..sz], cell[0..sz]);
        put2(cellptr, @intCast(@intFromPtr(slot) - @intFromPtr(a)));
        cellptr += 2;
        i += 1;
        if (i >= first + n) break;
        if (b.ix_nx[k] <= i) {
            k += 1;
            end = b.ap_end[k];
        }
    }
    data.* = p_data;
    return false;
}

/// Port of pageFreeArray(): free the space of those cells in
/// [first, first+n) that live on `pg`. Returns how many there were.
pub fn pageFreeArray(pg: *MemPage, first: u32, n: u32, b: *CellArray) u32 {
    const a = pg.data;
    const end = a + pg.bt.usable_size;
    const start = a + pg.hdr_offset + 8 + pg.child_ptr_size;
    var n_ret: u32 = 0;
    // Adjacent cells are merged before calling freeSpace.
    var n_free: usize = 0;
    var ofst: [10]u32 = undefined;
    var after: [10]u32 = undefined;
    for (first..first + n) |i| {
        const cell = b.cells[i];
        if (!page.within(cell, start, end)) continue;
        const sz: u32 = b.sizes[i];
        const i_ofst: u32 = @intCast(@intFromPtr(cell) - @intFromPtr(a));
        const i_after = i_ofst + sz;
        var j: usize = 0;
        while (j < n_free) : (j += 1) {
            if (ofst[j] == i_after) {
                ofst[j] = i_ofst;
                break;
            } else if (after[j] == i_ofst) {
                after[j] = i_after;
                break;
            }
        }
        if (j >= n_free) {
            if (n_free >= ofst.len) {
                for (0..n_free) |m| pg.freeSpace(ofst[m], after[m] - ofst[m]) catch {};
                n_free = 0;
            }
            ofst[n_free] = i_ofst;
            after[n_free] = i_after;
            if (@intFromPtr(a) + i_after > @intFromPtr(end)) return 0;
            n_free += 1;
        }
        n_ret += 1;
    }
    for (0..n_free) |m| pg.freeSpace(ofst[m], after[m] - ofst[m]) catch {};
    return n_ret;
}

/// Port of editPage(): `pg` holds its cells starting at b.cells[old]; make
/// it hold n cells starting at b.cells[new] by trimming and adding at the
/// edges, or rebuild it if that does not work out. Leaves `n_free` stale.
pub fn editPage(pg: *MemPage, i_old: u32, i_new: u32, n_new: u32, b: *CellArray) Error!void {
    const a = pg.data;
    const hdr = pg.hdr_offset;
    const begin = pg.cell_idx + n_new * 2;
    var n_cell: u32 = pg.n_cell;
    const i_old_end = i_old + pg.n_cell + pg.n_overflow;
    const i_new_end = i_new + n_new;
    // The page as it was, for checking the result: cells of `b` may lie
    // on it and be overwritten.
    const usable = pg.bt.usable_size;
    const before = if (checking()) pg.bt.pager.tempSpace().ptr else undefined;
    if (checking()) @memcpy(before[0..usable], a[0..usable]);

    edit: {
        // Remove cells from the start and end of the page.
        if (i_old < i_new) {
            const n_shift = pageFreeArray(pg, i_old, i_new - i_old, b);
            if (n_shift > n_cell) return corrupt(@src());
            @memmove(pg.cell_idx[0 .. n_cell * 2], pg.cell_idx[n_shift * 2 ..][0 .. n_cell * 2]);
            n_cell -= n_shift;
        }
        if (i_new_end < i_old_end) {
            const n_tail = pageFreeArray(pg, i_new_end, i_old_end - i_new_end, b);
            if (n_tail > n_cell) return corrupt(@src());
            n_cell -= n_tail;
        }

        var data = a + get2(a + hdr + 5);
        if (@intFromPtr(data) < @intFromPtr(begin)) break :edit;
        if (@intFromPtr(data) > @intFromPtr(pg.data_end)) break :edit;

        // Add cells to the start of the page.
        if (i_new < i_old) {
            const n_add = @min(n_new, i_old - i_new);
            @memmove(pg.cell_idx[n_add * 2 ..][0 .. n_cell * 2], pg.cell_idx[0 .. n_cell * 2]);
            if (pageInsertArray(pg, begin, &data, pg.cell_idx, i_new, n_add, b)) break :edit;
            n_cell += n_add;
        }

        // Add the overflow cells.
        for (pg.ai_ovfl[0..pg.n_overflow]) |ovfl_idx| {
            const i_cell = @as(i64, i_old) + ovfl_idx - i_new;
            if (i_cell < 0 or i_cell >= n_new) continue;
            const ic: u32 = @intCast(i_cell);
            const cellptr = pg.cell_idx + ic * 2;
            if (n_cell > ic) @memmove(cellptr[2..][0 .. (n_cell - ic) * 2], cellptr[0 .. (n_cell - ic) * 2]);
            n_cell += 1;
            _ = b.cellSizeAt(@intCast(ic + i_new));
            if (pageInsertArray(pg, begin, &data, cellptr, ic + i_new, 1, b)) break :edit;
        }

        // Append cells to the end of the page.
        const n_append = if (n_new > n_cell) n_new - n_cell else 0;
        if (pageInsertArray(pg, begin, &data, pg.cell_idx + n_cell * 2, i_new + n_cell, n_append, b)) break :edit;

        pg.n_cell = @intCast(n_new);
        pg.n_overflow = 0;
        put2(a + hdr + 3, n_new);
        put2(a + hdr + 5, @intCast(@intFromPtr(data) - @intFromPtr(a)));
        if (checking()) {
            // Every cell of the page is the one it should be.
            for (0..n_new) |i| {
                var cell = b.cells[i_new + i];
                if (page.within(cell, a, a + usable)) cell = before + (@intFromPtr(cell) - @intFromPtr(a));
                const on_page = a + get2(pg.cell_idx + i * 2);
                const sz = b.ref.cellSize(cell);
                std.debug.assert(std.mem.eql(u8, cell[0..sz], on_page[0..sz]));
            }
        }
        return;
    }
    // Editing in place failed; rebuild from scratch.
    if (n_new < 1) return corrupt(@src());
    b.populate(i_new, n_new);
    return rebuildPage(b, i_new, n_new, pg);
}

/// Port of ptrmapCheckPages(), which SQLite leaves out (#if 0) because a
/// corrupt file fails it: the pointer map knows `pg` as the parent of its
/// children and of the first overflow page of each of its cells.
pub fn ptrmapCheckPage(pg: *MemPage) Error!void {
    const bt = pg.bt;
    for (0..pg.n_cell) |i| {
        const cell = pg.findCell(i);
        const info = pg.parseCell(cell);
        if (info.n_local < info.n_payload) {
            const e = try ptrmap.get(bt, get4(cell + info.n_size - 4));
            std.debug.assert(e.e_type == .overflow1 and e.parent == pg.pgno);
        }
        if (!pg.leaf) {
            const e = try ptrmap.get(bt, get4(cell));
            std.debug.assert(e.e_type == .btree_page and e.parent == pg.pgno);
        }
    }
    if (!pg.leaf) {
        const e = try ptrmap.get(bt, pg.rightChild());
        std.debug.assert(e.e_type == .btree_page and e.parent == pg.pgno);
    }
}

/// Port of copyNodeContent(): copy the b-tree node on `from` to `to` (not
/// its overflow cells) and reinitialize `to`.
pub fn copyNodeContent(from: *MemPage, to: *MemPage) Error!void {
    const usable = from.bt.usable_size;
    const to_hdr = to.hdr_offset;
    std.debug.assert(from.is_init and from.n_free >= to_hdr);
    const i_data: u32 = get2(from.data + from.hdr_offset + 5);
    @memcpy(to.data[i_data..usable], from.data[i_data..usable]);
    const n = from.cell_offset + 2 * @as(u32, from.n_cell);
    @memcpy(to.data[to_hdr..][0..n], from.data[from.hdr_offset..][0..n]);
    to.is_init = false;
    try to.init();
    try to.computeFreeSpace();
    // `to` now holds the pointers to the children and overflow chains.
    if (to.bt.isAutoVacuum()) try ptrmap.setChildPtrmaps(to);
}
