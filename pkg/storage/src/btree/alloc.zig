//! Page allocation (part of btree.c): the freelist, from which
//! `allocatePage` takes pages and to which `freePage` returns them, and
//! the overflow chains of cells, which `fillInCell` builds and `clearCell`
//! frees. Functions of a b-tree, which btree.zig uses as its methods.

const std = @import("std");
const corrupt = @import("../corrupt.zig").corrupt;
const checking = @import("../corrupt.zig").checking;
const pager_mod = @import("../pager/pager.zig");
const varint = @import("../varint.zig");
const btree = @import("btree.zig");
const header = btree.header;
const page = @import("page.zig");
const ptrmap = @import("ptrmap.zig");

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

/// How `allocatePage` uses its `nearby` argument (BTALLOC_*).
pub const AllocMode = enum {
    /// Prefer a page close to `nearby`.
    any,
    /// Return `nearby` itself if it is on the freelist.
    exact,
    /// Return a page no larger than `nearby` if there is one.
    le,
};

/// Port of allocateBtreePage(): take a page from the freelist, or
/// append one. The page is writable and referenced, its content
/// undefined. Modes other than `any` are only for auto-vacuum.
pub fn allocatePage(bt: *Btree, nearby: Pgno, mode: AllocMode) Error!*MemPage {
    std.debug.assert(mode == .any or (nearby > 0 and bt.isAutoVacuum()));
    const p1 = bt.page1.?;
    const mx_page = bt.n_page;
    const n_free = header.get(p1.data, .freelist_count);
    if (n_free >= mx_page) return corrupt(@src());
    if (n_free == 0) return appendPage(bt);

    // Searching walks every trunk until the wanted page turns up.
    const search_list = switch (mode) {
        .any => false,
        .le => true,
        .exact => nearby <= mx_page and (try ptrmap.get(bt, nearby)).e_type == .free_page,
    };

    try bt.pager.write(p1.db_page);
    header.put(p1.data, .freelist_count, n_free - 1);

    var trunk: ?*MemPage = null;
    var prev: ?*MemPage = null;
    defer {
        if (trunk) |t| releasePage(t);
        if (prev) |t| releasePage(t);
    }
    var n_search: u32 = 0;
    while (true) {
        if (prev) |pt| releasePage(pt);
        prev = trunk;
        trunk = null;
        const i_trunk = if (prev) |pt| get4(pt.data) else header.get(p1.data, .first_freelist_trunk);
        if (i_trunk > mx_page or n_search > n_free) return corrupt(@src());
        n_search += 1;
        trunk = try page.getUnusedPage(bt, i_trunk, .{});
        const t = trunk.?;
        const k = get4(t.data + 4);

        if (k == 0 and !search_list) {
            // A trunk without leaves: allocate the trunk itself.
            std.debug.assert(prev == null);
            try bt.pager.write(t.db_page);
            header.put(p1.data, .first_freelist_trunk, get4(t.data));
            trunk = null;
            return t;
        }
        if (k > bt.usable_size / 4 - 2) return corrupt(@src());

        if (search_list and (nearby == i_trunk or (i_trunk < nearby and mode == .le))) {
            // The trunk itself is the page wanted. Unlink it, promoting
            // its first leaf to trunk if it has leaves.
            try bt.pager.write(t.db_page);
            var next_trunk = t.data[0..4].*;
            if (k > 0) {
                const i_new_trunk = get4(t.data + 8);
                if (i_new_trunk > mx_page) return corrupt(@src());
                const nt = try page.getUnusedPage(bt, i_new_trunk, .{});
                defer releasePage(nt);
                try bt.pager.write(nt.db_page);
                nt.data[0..4].* = t.data[0..4].*;
                put4(nt.data + 4, k - 1);
                @memcpy(nt.data[8..][0 .. (k - 1) * 4], t.data[12..][0 .. (k - 1) * 4]);
                put4(&next_trunk, i_new_trunk);
            }
            if (prev) |pt| {
                try bt.pager.write(pt.db_page);
                pt.data[0..4].* = next_trunk;
            } else {
                header.put(p1.data, .first_freelist_trunk, get4(&next_trunk));
            }
            trunk = null;
            return t;
        }

        if (k > 0) {
            // Take a leaf: the first one no larger than `nearby` (le),
            // or the one closest to it.
            const a = t.data;
            var closest: u32 = 0;
            if (nearby > 0) {
                if (mode == .le) {
                    for (0..k) |i| {
                        if (get4(a + 8 + i * 4) <= nearby) {
                            closest = @intCast(i);
                            break;
                        }
                    }
                } else {
                    var dist = absInt32(get4(a + 8) -% nearby);
                    for (1..k) |i| {
                        const d2 = absInt32(get4(a + 8 + i * 4) -% nearby);
                        if (d2 < dist) {
                            closest = @intCast(i);
                            dist = d2;
                        }
                    }
                }
            }
            const pgno = get4(a + 8 + closest * 4);
            if (pgno > mx_page or pgno < 2) return corrupt(@src());
            if (!search_list or pgno == nearby or (pgno < nearby and mode == .le)) {
                try bt.pager.write(t.db_page);
                if (closest < k - 1) a[8 + closest * 4 ..][0..4].* = a[4 + k * 4 ..][0..4].*;
                put4(a + 4, k - 1);
                // A page freed earlier in this transaction may still need
                // its old content journaled; others can skip the read.
                const no_content = !bt.has_content.contains(pgno);
                const pg = try page.getUnusedPage(bt, pgno, .{ .no_content = no_content });
                errdefer releasePage(pg);
                try bt.pager.write(pg.db_page);
                return pg;
            }
        }
        std.debug.assert(search_list);
    }
}

/// The append half of allocateBtreePage(): extend the database by one
/// page (two if the next one must be a pointer-map page).
pub fn appendPage(bt: *Btree) Error!*MemPage {
    const p1 = bt.page1.?;
    // After an incremental vacuum, pages between the image and the end
    // of the file may hold content a rollback needs: read (and journal)
    // them instead of assuming they are blank.
    const flags: pager_mod.GetFlags = .{ .no_content = !bt.do_truncate };
    try bt.pager.write(p1.db_page);
    bt.n_page += 1;
    if (bt.pager.isLockPage(bt.n_page)) bt.n_page += 1;
    if (bt.isAutoVacuum() and ptrmap.isPage(bt, bt.n_page)) {
        const map = try page.getUnusedPage(bt, bt.n_page, flags);
        defer releasePage(map);
        try bt.pager.write(map.db_page);
        bt.n_page += 1;
        if (bt.pager.isLockPage(bt.n_page)) bt.n_page += 1;
    }
    header.put(p1.data, .database_size, bt.n_page);
    const pg = try page.getUnusedPage(bt, bt.n_page, flags);
    errdefer releasePage(pg);
    try bt.pager.write(pg.db_page);
    return pg;
}

/// Port of freePage2(): put page `pgno` on the freelist. `mem` is the
/// page if the caller has it; its reference count is not changed.
pub fn freePage2(bt: *Btree, mem: ?*MemPage, pgno: Pgno) Error!void {
    const p1 = bt.page1.?;
    if (pgno < 2 or pgno > bt.n_page) return corrupt(@src());
    var pg: ?*MemPage = null;
    if (mem) |m| {
        pg = m;
        bt.pager.ref(m.db_page);
    } else {
        pg = page.lookupPage(bt, pgno);
    }
    var trunk: ?*MemPage = null;
    defer {
        if (pg) |x| {
            x.is_init = false;
            releasePage(x);
        }
        if (trunk) |t| releasePage(t);
    }

    try bt.pager.write(p1.db_page);
    const n_free = header.get(p1.data, .freelist_count);
    header.put(p1.data, .freelist_count, n_free +% 1);

    if (bt.secure_delete == .on) {
        if (pg == null) pg = try page.getPage(bt, pgno, .{});
        try bt.pager.write(pg.?.db_page);
        @memset(pg.?.data[0..bt.page_size], 0);
    }
    if (bt.isAutoVacuum()) try ptrmap.put(bt, pgno, .free_page, 0);

    var i_trunk: Pgno = 0;
    if (n_free != 0) {
        i_trunk = header.get(p1.data, .first_freelist_trunk);
        if (i_trunk > bt.n_page) return corrupt(@src());
        trunk = try page.getPage(bt, i_trunk, .{});
        const t = trunk.?;
        const n_leaf = get4(t.data + 4);
        if (n_leaf > bt.usable_size / 4 - 2) return corrupt(@src());
        // Trunks hold at most usableSize/4-8 leaves: versions before
        // 3.6.0 reported fuller trunks as corrupt.
        if (n_leaf < bt.usable_size / 4 - 8) {
            try bt.pager.write(t.db_page);
            put4(t.data + 4, n_leaf + 1);
            put4(t.data + 8 + n_leaf * 4, pgno);
            if (pg) |x| if (bt.secure_delete != .on) bt.pager.dontWrite(x.db_page);
            try bt.has_content.put(bt.gpa, pgno, {});
            return;
        }
    }

    // The freelist is empty or its first trunk is full: the page becomes
    // the new first trunk.
    if (pg == null) pg = try page.getPage(bt, pgno, .{});
    const x = pg.?;
    try bt.pager.write(x.db_page);
    put4(x.data, i_trunk);
    put4(x.data + 4, 0);
    header.put(p1.data, .first_freelist_trunk, pgno);
}

pub fn freePage(bt: *Btree, pg: *MemPage) Error!void {
    return freePage2(bt, pg, pg.pgno);
}

/// Port of getOverflowPage(): the overflow page after `ovfl`, or 0.
/// `page` is `ovfl` itself, referenced, unless `want_page` is false or
/// the pointer map answered without reading it.
pub fn getOverflowPage(bt: *Btree, ovfl: Pgno, want_page: bool) Error!struct { next: Pgno, page: ?*MemPage } {
    if (bt.isAutoVacuum()) {
        // Guess that the chain continues on the next page and check
        // the guess against the pointer map.
        var guess = ovfl + 1;
        while (ptrmap.isReserved(bt, guess)) guess += 1;
        if (guess <= bt.n_page) {
            const e = try ptrmap.get(bt, guess);
            if (e.e_type == .overflow2 and e.parent == ovfl) return .{ .next = guess, .page = null };
        }
    }
    const pg = try page.getPage(bt, ovfl, .{});
    const next = get4(pg.data);
    if (want_page) return .{ .next = next, .page = pg };
    releasePage(pg);
    return .{ .next = next, .page = null };
}

/// Port of clearCellOverflow(): free the overflow chain of a cell.
pub fn clearCellOverflow(bt: *Btree, pg: *MemPage, cell: [*]u8, info: CellInfo) Error!void {
    if (@intFromPtr(cell) + info.n_size > @intFromPtr(pg.data_end)) return corrupt(@src());
    var ovfl = get4(cell + info.n_size - 4);
    const ovfl_size = bt.usable_size - 4;
    var n_ovfl = (info.n_payload -% info.n_local +% ovfl_size -% 1) / ovfl_size; // u32, wraps as in C
    while (n_ovfl > 0) : (n_ovfl -= 1) {
        if (ovfl < 2 or ovfl > bt.n_page) return corrupt(@src());
        var next: Pgno = 0;
        var op: ?*MemPage = null;
        if (n_ovfl > 1) {
            const r = try getOverflowPage(bt, ovfl, true);
            next = r.next;
            op = r.page;
        }
        if (op == null) op = page.lookupPage(bt, ovfl);
        defer if (op) |o| bt.pager.unref(o.db_page);
        // No cursor should be using an overflow page of a cell being
        // deleted. More references mean it is not an overflow page.
        if (op) |o| if (o.db_page.n_ref != 1) return corrupt(@src());
        try freePage2(bt, op, ovfl);
        ovfl = next;
    }
}

/// BTREE_CLEAR_CELL: parse a cell and free its overflow chain.
pub fn clearCell(bt: *Btree, pg: *MemPage, cell: [*]u8) Error!CellInfo {
    const info = pg.parseCell(cell);
    if (info.n_local != info.n_payload) try clearCellOverflow(bt, pg, cell, info);
    return info;
}

/// Port of fillInCell(): build the cell for `x` in `cell`, allocating
/// and filling overflow pages as needed. Returns the cell size.
pub fn fillInCell(bt: *Btree, pg: *MemPage, cell: [*]u8, x: Payload) Error!u32 {
    const n_size = try fillInCellUnchecked(bt, pg, cell, x);
    if (checking()) {
        // The cell parses back to what was written.
        const info = pg.parseCell(cell);
        std.debug.assert(info.n_size == n_size);
        std.debug.assert(info.n_payload == if (pg.int_key) x.data.len + x.n_zero else x.key.?.len);
        if (pg.int_key) std.debug.assert(info.n_key == x.rowid);
    }
    return n_size;
}

pub fn fillInCellUnchecked(bt: *Btree, pg: *MemPage, cell: [*]u8, x: Payload) Error!u32 {
    var n_header: u32 = pg.child_ptr_size;
    var n_payload: u32 = undefined;
    var src: []const u8 = undefined;
    if (pg.int_key) {
        std.debug.assert(pg.int_key_leaf);
        n_payload = @intCast(x.data.len + x.n_zero);
        src = x.data;
        n_header += varint.put(cell[n_header..][0..9], n_payload);
        n_header += varint.put(cell[n_header..][0..9], @bitCast(x.rowid));
    } else {
        src = x.key.?;
        n_payload = @intCast(src.len);
        n_header += varint.put(cell[n_header..][0..9], n_payload);
    }

    var payload = cell + n_header;
    if (n_payload <= pg.max_local) {
        // The common case: everything fits on the page.
        var n = n_header + n_payload;
        if (n < 4) {
            n = 4;
            payload[n_payload] = 0;
        }
        @memcpy(payload[0..src.len], src);
        @memset(payload[src.len..n_payload], 0);
        return n;
    }

    const local = pg.payloadToLocal(n_payload);
    var space_left: u32 = local;
    const size = local + n_header + 4;
    var prior = cell + n_header + local;
    var pgno_ovfl: Pgno = 0;
    var to_release: ?*MemPage = null;
    defer if (to_release) |r| releasePage(r);

    var remaining = n_payload;
    while (true) {
        var n = @min(remaining, space_left);
        if (src.len >= n) {
            @memcpy(payload[0..n], src[0..n]);
        } else if (src.len > 0) {
            n = @intCast(src.len);
            @memcpy(payload[0..n], src);
        } else {
            @memset(payload[0..n], 0);
        }
        remaining -= n;
        if (remaining == 0) break;
        payload += n;
        src = src[@min(n, src.len)..];
        space_left -= n;
        if (space_left == 0) {
            // The pointer-map entry of the previous page in the chain.
            const pgno_ptrmap = pgno_ovfl;
            if (bt.isAutoVacuum()) {
                pgno_ovfl += 1;
                while (ptrmap.isReserved(bt, pgno_ovfl)) pgno_ovfl += 1;
            }
            const ovfl = try allocatePage(bt, pgno_ovfl, .any);
            if (bt.isAutoVacuum()) {
                // Even the first page gets an entry now (completed when
                // the cell is inserted), or getOverflowPage() could
                // misread a stale one while freeing the chain.
                const e_type: ptrmap.Type = if (pgno_ptrmap != 0) .overflow2 else .overflow1;
                ptrmap.put(bt, ovfl.pgno, e_type, pgno_ptrmap) catch |err| {
                    releasePage(ovfl);
                    return err;
                };
            }
            put4(prior, ovfl.pgno);
            if (to_release) |r| releasePage(r);
            to_release = ovfl;
            pgno_ovfl = ovfl.pgno;
            prior = ovfl.data;
            put4(prior, 0);
            payload = ovfl.data + 4;
            space_left = bt.usable_size - 4;
        }
    }
    return size;
}

/// sqlite3AbsInt32() applied to a 32-bit difference.
pub fn absInt32(x: u32) u32 {
    const v: i32 = @bitCast(x);
    if (v >= 0) return @intCast(v);
    if (v == std.math.minInt(i32)) return std.math.maxInt(i32);
    return @intCast(-v);
}
