//! PRAGMA integrity_check at the b-tree level (port of
//! sqlite3BtreeIntegrityCheck and its helpers in btree.c). Messages match
//! SQLite's word for word so results can be compared directly.

const std = @import("std");
const btree = @import("btree.zig");
const page = @import("page.zig");
const header = @import("header.zig");
const ptrmap = @import("ptrmap.zig");

const Btree = btree.Btree;
const Pgno = btree.Pgno;
const Error = btree.Error;
const MemPage = page.MemPage;
const get2 = page.get2;
const get4 = page.get4;

pub const Report = struct {
    /// Number of problems found (may exceed the messages kept).
    n_err: u32,
    /// Messages separated by newlines; empty if none.
    message: []u8,
    /// Entries counted in each b-tree, in the order of the roots given.
    row_counts: []i64,

    pub fn deinit(r: *Report, gpa: std.mem.Allocator) void {
        gpa.free(r.message);
        gpa.free(r.row_counts);
        r.* = undefined;
    }
};

const Prefix = enum { none, freelist, tree_page, tree_cell, tree_right_child };

/// IntegrityCk.
const Check = struct {
    bt: *Btree,
    gpa: std.mem.Allocator,
    /// One bit per page: referenced so far.
    pg_ref: std.DynamicBitSetUnmanaged = .{},
    n_ck_page: Pgno,
    /// Stop collecting messages when this reaches zero.
    mx_err: u32,
    n_err: u32 = 0,
    /// Out of memory while checking (reported as an error).
    oom: bool = false,
    /// Current b-tree recursion depth.
    n_above: u8 = 0,
    prefix: Prefix = .none,
    /// Values for the prefix: root page, current page, cell index.
    v0: Pgno = 0,
    v1: Pgno = 0,
    v2: i64 = 0,
    msg: std.ArrayList(u8) = .empty,
    /// Min-heap for cell coverage analysis; heap[0] is its size.
    heap: []u32,
    n_row: i64 = 0,

    /// Port of checkAppendMsg().
    fn appendMsg(c: *Check, comptime fmt: []const u8, args: anytype) void {
        if (c.mx_err == 0) return;
        c.mx_err -= 1;
        c.n_err += 1;
        c.write(fmt, args) catch {
            c.oom = true;
            c.mx_err = 0;
        };
    }

    fn write(c: *Check, comptime fmt: []const u8, args: anytype) !void {
        if (c.msg.items.len != 0) try c.msg.append(c.gpa, '\n');
        switch (c.prefix) {
            .none => {},
            .freelist => try c.msg.appendSlice(c.gpa, "Freelist: "),
            .tree_page => try c.msg.print(c.gpa, "Tree {d} page {d}: ", .{ c.v0, c.v1 }),
            .tree_cell => try c.msg.print(c.gpa, "Tree {d} page {d} cell {d}: ", .{ c.v0, c.v1, c.v2 }),
            .tree_right_child => try c.msg.print(c.gpa, "Tree {d} page {d} right child: ", .{ c.v0, c.v1 }),
        }
        try c.msg.print(c.gpa, fmt, args);
    }

    /// Port of checkRef(): count a reference to `pgno`. Returns true if it
    /// is out of range or referenced twice.
    fn checkRef(c: *Check, pgno: Pgno) bool {
        if (pgno > c.n_ck_page or pgno == 0) {
            c.appendMsg("invalid page number {d}", .{pgno});
            return true;
        }
        if (c.pg_ref.isSet(pgno)) {
            c.appendMsg("2nd reference to page {d}", .{pgno});
            return true;
        }
        c.pg_ref.set(pgno);
        return false;
    }

    /// Port of checkPtrmap().
    fn checkPtrmap(c: *Check, child: Pgno, e_type: ptrmap.Type, parent: Pgno) void {
        const entry = ptrmap.get(c.bt, child) catch |err| {
            if (err == error.OutOfMemory) c.oom = true;
            c.appendMsg("Failed to read ptrmap key={d}", .{child});
            return;
        };
        if (entry.e_type != e_type or entry.parent != parent) {
            c.appendMsg("Bad ptr map entry key={d} expected=({d},{d}) got=({d},{d})", .{
                child, @backingInt(e_type), parent, @backingInt(entry.e_type), entry.parent,
            });
        }
    }

    /// Port of checkList(): walk the freelist or an overflow chain and
    /// check that it has `expected` pages.
    fn checkList(c: *Check, is_freelist: bool, first: Pgno, expected: u32) void {
        var n: i64 = expected;
        var pgno = first;
        const n_err_start = c.n_err;
        const bt = c.bt;
        while (pgno != 0 and c.mx_err != 0) {
            if (c.checkRef(pgno)) break;
            n -= 1;
            const pg = bt.pager.get(pgno, .{}) catch {
                c.appendMsg("failed to get page {d}", .{pgno});
                break;
            };
            defer bt.pager.unref(pg);
            const data = pg.data.ptr;
            if (is_freelist) {
                const n_leaf = get4(data + 4);
                if (bt.isAutoVacuum()) c.checkPtrmap(pgno, .free_page, 0);
                if (n_leaf > bt.usable_size / 4 - 2) {
                    c.appendMsg("freelist leaf count too big on page {d}", .{pgno});
                    n -= 1;
                } else {
                    for (0..n_leaf) |i| {
                        const free_page = get4(data + 8 + i * 4);
                        if (bt.isAutoVacuum()) c.checkPtrmap(free_page, .free_page, 0);
                        _ = c.checkRef(free_page);
                    }
                    n -= n_leaf;
                }
            } else if (bt.isAutoVacuum() and n > 0) {
                // The next page of the chain must point back here.
                c.checkPtrmap(get4(data), .overflow2, pgno);
            }
            pgno = get4(data);
        }
        if (n != 0 and n_err_start == c.n_err) {
            c.appendMsg("{s} is {d} but should be {d}", .{
                if (is_freelist) "size" else "overflow list length",
                @as(i64, expected) - n,
                expected,
            });
        }
    }

    /// Port of checkTreePage(): check one page and, recursively, its
    /// children. Returns the depth of the subtree (0 for a leaf).
    ///
    ///  1. cells and freeblocks do not overlap and cover the page exactly
    ///  2. integer keys are in order (and within `max_key`)
    ///  3. overflow chains are intact
    ///  4. all children have the same depth
    fn checkTreePage(c: *Check, pgno: Pgno, min_key: *i64, max_key_arg: i64) i32 {
        var max_key = max_key_arg;
        if (c.mx_err == 0) return 0;
        const bt = c.bt;
        const usable = bt.usable_size;
        if (pgno == 0) return 0;
        if (c.checkRef(pgno)) return 0;

        const saved_prefix = c.prefix;
        const saved_v1 = c.v1;
        const saved_v2 = c.v2;
        c.prefix = .tree_page;
        c.v1 = pgno;
        c.n_above += 1;
        defer {
            c.prefix = saved_prefix;
            c.v1 = saved_v1;
            c.v2 = saved_v2;
            c.n_above -= 1;
        }

        var depth: i32 = -1;
        const pg = bt.getPage(pgno, .{}) catch |err| {
            c.appendMsg("unable to get the page. error code={d}", .{errorCode(err)});
            if (err == error.OutOfMemory) c.oom = true;
            return depth + 1;
        };
        defer btree.releasePage(pg);
        if (c.n_above > btree.max_depth) {
            c.appendMsg("btree depth exceeds {d}", .{btree.max_depth});
            return depth + 1;
        }

        // Force the corruption checks in init to run again.
        const saved_is_init = pg.is_init;
        var coverage = true;
        defer if (!coverage) {
            pg.is_init = saved_is_init;
        };
        pg.is_init = false;
        pg.init() catch {
            c.appendMsg("btreeInitPage() returns error code {d}", .{corrupt_code});
            return depth + 1;
        };
        pg.computeFreeSpace() catch {
            c.appendMsg("free space corruption", .{});
            return depth + 1;
        };

        const data = pg.data;
        const hdr = pg.hdr_offset;
        c.prefix = .tree_cell;
        const content_offset = page.get2NotZero(data + hdr + 5);
        const n_cell: u32 = get2(data + hdr + 3);
        if (pg.leaf or !pg.int_key) c.n_row += n_cell;
        const cell_start: u32 = hdr + @as(u32, if (pg.leaf) 8 else 12);

        var key_can_be_equal = true;
        if (!pg.leaf) {
            const right = get4(data + hdr + 8);
            if (bt.isAutoVacuum()) {
                c.prefix = .tree_right_child;
                c.checkPtrmap(right, .btree_page, pgno);
            }
            depth = c.checkTreePage(right, &max_key, max_key);
            key_can_be_equal = false;
        } else {
            c.heap[0] = 0;
        }

        var i: i64 = @as(i64, n_cell) - 1;
        while (i >= 0 and c.mx_err != 0) : (i -= 1) {
            c.v2 = i;
            const pc: u32 = get2(data + cell_start + @as(u32, @intCast(i)) * 2);
            if (pc < content_offset or pc > usable - 4) {
                c.appendMsg("Offset {d} out of range {d}..{d}", .{ pc, content_offset, usable - 4 });
                coverage = false;
                continue;
            }
            const cell = data + pc;
            const info = pg.parseCell(cell);
            if (pc + info.n_size > usable) {
                c.appendMsg("Extends off end of page", .{});
                coverage = false;
                continue;
            }
            if (info.n_payload != 0 and info.payload[0] < 2) {
                c.appendMsg("Bad cell header size", .{});
                coverage = false;
                continue;
            }

            if (pg.int_key) {
                if (if (key_can_be_equal) info.n_key > max_key else info.n_key >= max_key) {
                    c.appendMsg("Rowid {d} out of order", .{info.n_key});
                }
                max_key = info.n_key;
                // Only the first key on a page may equal max_key.
                key_can_be_equal = false;
            }

            if (info.n_payload > info.n_local) {
                const n_page = (info.n_payload - info.n_local + usable - 5) / (usable - 4);
                const ovfl = get4(cell + info.n_size - 4);
                if (bt.isAutoVacuum()) c.checkPtrmap(ovfl, .overflow1, pgno);
                c.checkList(false, ovfl, n_page);
            }

            if (!pg.leaf) {
                const child = get4(cell);
                if (bt.isAutoVacuum()) c.checkPtrmap(child, .btree_page, pgno);
                const d2 = c.checkTreePage(child, &max_key, max_key);
                key_can_be_equal = false;
                if (d2 != depth) {
                    c.appendMsg("Child page depth differs", .{});
                    depth = d2;
                }
            } else {
                heapInsert(c.heap, (pc << 16) | (pc + info.n_size - 1));
            }
        }
        min_key.* = max_key;

        // Every byte must belong to exactly one of: the header and cell
        // pointers, a cell, a freeblock, or a fragment.
        c.prefix = .none;
        if (coverage and c.mx_err > 0) {
            if (!pg.leaf) {
                c.heap[0] = 0;
                var j: i64 = @as(i64, n_cell) - 1;
                while (j >= 0) : (j -= 1) {
                    const pc: u32 = get2(data + cell_start + @as(u32, @intCast(j)) * 2);
                    const size: u32 = pg.cellSize(data + pc);
                    heapInsert(c.heap, (pc << 16) | (pc + size - 1));
                }
            }
            var fb: u32 = get2(data + hdr + 1);
            while (fb > 0) {
                const size: u32 = get2(data + fb + 2);
                heapInsert(c.heap, (fb << 16) | (fb + size - 1));
                fb = get2(data + fb);
            }
            // Entries are (first byte << 16) | last byte. The implied first
            // entry covers everything before the content area.
            var n_frag: u32 = 0;
            var prev: u32 = content_offset - 1;
            while (heapPull(c.heap)) |x| {
                if (prev & 0xffff >= x >> 16) {
                    c.appendMsg("Multiple uses for byte {d} of page {d}", .{ x >> 16, pgno });
                    break;
                }
                n_frag += (x >> 16) - (prev & 0xffff) - 1;
                prev = x;
            }
            n_frag += usable - (prev & 0xffff) - 1;
            if (c.heap[0] == 0 and n_frag != data[hdr + 7]) {
                c.appendMsg("Fragmentation of {d} bytes reported as {d} on page {d}", .{
                    n_frag, data[hdr + 7], pgno,
                });
            }
        }
        return depth + 1;
    }
};

/// SQLITE_CORRUPT, as printed by "btreeInitPage() returns error code".
const corrupt_code = 11;

/// The primary SQLite result code for an error, for messages that print it.
fn errorCode(err: Error) u32 {
    return switch (err) {
        error.Corrupt => corrupt_code,
        error.OutOfMemory => 7,
        error.Busy => 5,
        error.ReadOnly => 8,
        error.DiskFull => 13,
        error.CantOpen => 14,
        error.NotADatabase => 26,
        else => 10, // SQLITE_IOERR
    };
}

/// Port of btreeHeapInsert().
fn heapInsert(heap: []u32, x: u32) void {
    heap[0] += 1;
    var i = heap[0];
    heap[i] = x;
    while (i / 2 > 0 and heap[i / 2] > heap[i]) : (i /= 2) {
        std.mem.swap(u32, &heap[i / 2], &heap[i]);
    }
}

/// Port of btreeHeapPull(): remove and return the smallest entry.
fn heapPull(heap: []u32) ?u32 {
    const n = heap[0];
    if (n == 0) return null;
    const out = heap[1];
    heap[1] = heap[n];
    heap[n] = 0xffffffff;
    heap[0] -= 1;
    var i: u32 = 1;
    while (i * 2 <= heap[0]) {
        var j = i * 2;
        if (heap[j] > heap[j + 1]) j += 1;
        if (heap[i] < heap[j]) break;
        std.mem.swap(u32, &heap[i], &heap[j]);
        i = j;
    }
    return out;
}

/// Port of sqlite3BtreeIntegrityCheck(). `roots` lists the root pages of
/// every b-tree. If roots[0] is 0 this is a partial check of the trees
/// that follow: unreferenced pages are not reported, and the freelist is
/// only checked if roots[1] is 1. A read transaction must be open.
pub fn check(bt: *Btree, gpa: std.mem.Allocator, roots: []const Pgno, max_err: u32) Error!Report {
    std.debug.assert(roots.len > 0 and bt.in_trans != .none);
    const partial = roots[0] == 0;
    const check_freelist = !partial or (roots.len > 1 and roots[1] == 1);
    const ref_count = bt.pager.refCount();
    defer std.debug.assert(bt.pager.refCount() == ref_count);

    const row_counts = try gpa.alloc(i64, roots.len);
    errdefer gpa.free(row_counts);
    @memset(row_counts, 0);
    var c: Check = .{
        .bt = bt,
        .gpa = gpa,
        .n_ck_page = bt.n_page,
        .mx_err = max_err,
        .heap = &.{},
    };
    defer c.pg_ref.deinit(gpa);
    defer gpa.free(c.heap);
    errdefer c.msg.deinit(gpa);

    if (c.n_ck_page != 0) {
        c.pg_ref = try .initEmpty(gpa, c.n_ck_page + 1);
        c.heap = try gpa.alloc(u32, bt.page_size / 2);
        if (bt.pager.lockPage() <= c.n_ck_page) c.pg_ref.set(bt.pager.lockPage());

        if (check_freelist) {
            c.prefix = .freelist;
            const p1 = bt.page1.?.data;
            c.checkList(true, header.get(p1, .first_freelist_trunk), header.get(p1, .freelist_count));
            c.prefix = .none;
        }

        if (!partial) {
            const p1 = bt.page1.?.data;
            if (bt.isAutoVacuum()) {
                var mx: Pgno = 0;
                for (roots) |r| mx = @max(mx, r);
                const mx_in_hdr = header.get(p1, .largest_root_page);
                if (mx != mx_in_hdr) {
                    c.appendMsg("max rootpage ({d}) disagrees with header ({d})", .{ mx, mx_in_hdr });
                }
            } else if (header.get(p1, .incremental_vacuum) != 0) {
                c.appendMsg("incremental_vacuum enabled with a max rootpage of zero", .{});
            }
        }

        // cell_size_check would only duplicate the checks made here.
        const saved_cell_size_check = bt.cell_size_check;
        bt.cell_size_check = false;
        defer bt.cell_size_check = saved_cell_size_check;
        for (roots, row_counts) |root, *count| {
            if (c.mx_err == 0) break;
            c.n_row = 0;
            if (root != 0) {
                if (bt.isAutoVacuum() and root > 1 and !partial) c.checkPtrmap(root, .root_page, 0);
                c.v0 = root;
                var not_used: i64 = undefined;
                _ = c.checkTreePage(root, &not_used, std.math.maxInt(i64));
            }
            count.* = c.n_row;
        }

        if (!partial) {
            var i: Pgno = 1;
            while (i <= c.n_ck_page and c.mx_err != 0) : (i += 1) {
                const is_ptrmap = bt.isAutoVacuum() and ptrmap.isPage(bt, i);
                if (!c.pg_ref.isSet(i) and !is_ptrmap) c.appendMsg("Page {d}: never used", .{i});
                if (c.pg_ref.isSet(i) and is_ptrmap) c.appendMsg("Page {d}: pointer map referenced", .{i});
            }
        }
    }

    if (c.oom) return error.OutOfMemory;
    return .{
        .n_err = c.n_err,
        .message = try c.msg.toOwnedSlice(gpa),
        .row_counts = row_counts,
    };
}
