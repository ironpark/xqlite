//! B-tree pages: the page-level half of btree.c.
//!
//! A b-tree page has a header (8 bytes on leaves, 12 on interior pages,
//! after the 100-byte file header on page 1), an array of 2-byte cell
//! offsets, unallocated space, and the cell content area growing down from
//! the end of the usable space. Freed space inside the content area forms a
//! list of freeblocks; gaps of 1-3 bytes are counted as fragments instead.
//!
//!     offset 0  page type (PTF_* flags)
//!            1  first freeblock, or 0
//!            3  number of cells
//!            5  start of the cell content area (0 means 65536)
//!            7  fragmented free bytes
//!            8  right child (interior pages only)
//!
//! Cells are addressed with raw pointers, as in the C original, because a
//! cell being balanced may live on a page, in an overflow slot, or in a
//! scratch buffer. Every page buffer is followed by 8 zero bytes so that
//! parsers can run slightly past the end of a corrupt page without faulting.

const std = @import("std");
const corruptPage = @import("../corrupt.zig").corruptPage;
const checking = @import("../corrupt.zig").checking;
const pager_mod = @import("../pager/pager.zig");
const varint = @import("../varint.zig");
const btree = @import("btree.zig");
const corrupt = @import("../corrupt.zig").corrupt;
const ptrmap = @import("ptrmap.zig");

const Btree = btree.Btree;
const releasePage = btree.releasePage;
const Error = btree.Error;
pub const Pgno = pager_mod.Pgno;

/// Page type flags (PTF_*), ORed together in the first header byte.
pub const ptf_intkey: u8 = 0x01;
pub const ptf_zerodata: u8 = 0x02;
pub const ptf_leafdata: u8 = 0x04;
pub const ptf_leaf: u8 = 0x08;

/// The four legal page types.
pub const table_leaf = ptf_leafdata | ptf_intkey | ptf_leaf;
pub const table_interior = ptf_leafdata | ptf_intkey;
pub const index_leaf = ptf_zerodata | ptf_leaf;
pub const index_interior = ptf_zerodata;

/// Which cell parser a page uses (replaces xParseCell/xCellSize).
pub const Kind = enum(u8) {
    /// Table leaf: payload size, rowid, payload.
    table_leaf,
    /// Table interior: child pointer, rowid. No payload.
    table_interior,
    /// Index page: [child pointer,] payload size, payload.
    index,
};

/// A parsed cell (CellInfo).
pub const CellInfo = struct {
    /// The rowid for table b-trees, the payload size otherwise.
    n_key: i64 = 0,
    payload: [*]u8 = undefined,
    n_payload: u32 = 0,
    /// Bytes of payload stored on the page itself.
    n_local: u16 = 0,
    /// Bytes the cell occupies on the page, overflow pointer included.
    n_size: u16 = 0,
};

/// Maximum b-tree depth; deeper trees are treated as corrupt.
pub const max_depth = 20;

/// Per-page b-tree state (MemPage), stored in the pager's per-page extra
/// space. The pager zeroes the first 8 bytes whenever a cache slot is
/// (re)used, which clears `is_init` and makes `pgno` stale; the layout is
/// fixed so that holds.
pub const MemPage = extern struct {
    is_init: bool,
    int_key: bool,
    int_key_leaf: bool,
    _reserved: u8,
    pgno: Pgno,
    // Only the fields above are zeroed by the pager.
    leaf: bool,
    /// 100 on page 1, 0 elsewhere.
    hdr_offset: u8,
    /// 4 on interior pages, 0 on leaves.
    child_ptr_size: u8,
    /// min(max_local, 127): the largest payload whose size fits in one byte.
    max1byte_payload: u8,
    /// Cells waiting in `ap_ovfl` because they did not fit.
    n_overflow: u8,
    kind: Kind,
    max_local: u16,
    min_local: u16,
    /// Offset of the cell pointer array.
    cell_offset: u16,
    n_cell: u16,
    mask_page: u16,
    /// Free bytes on the page, or -1 if not yet computed.
    n_free: i32,
    /// `ap_ovfl[i]` is inserted before the `ai_ovfl[i]`-th cell on the page.
    ai_ovfl: [4]u16,
    ap_ovfl: [4][*]u8,
    bt: *Btree,
    data: [*]u8,
    /// One past the end of the whole page (not just the usable part).
    data_end: [*]u8,
    cell_idx: [*]u8,
    /// `data` on leaves, `data + 4` on interior pages.
    data_ofst: [*]u8,
    db_page: *pager_mod.Page,

    pub fn of(pg: *pager_mod.Page) *MemPage {
        return @ptrCast(pg.extra.ptr);
    }

    /// Port of findCell(): the cell at index `i`. No overflow cells allowed.
    pub fn findCell(p: *const MemPage, i: usize) [*]u8 {
        return p.data + (p.mask_page & get2(p.cell_idx + 2 * i));
    }

    /// Port of findCellPastPtr(): like findCell, skipping the child pointer.
    pub fn findCellPastPtr(p: *const MemPage, i: usize) [*]u8 {
        return p.data_ofst + (p.mask_page & get2(p.cell_idx + 2 * i));
    }

    pub fn offsetOf(p: *const MemPage, ptr: [*]const u8) usize {
        return @intFromPtr(ptr) - @intFromPtr(p.data);
    }

    pub fn rightChild(p: *const MemPage) Pgno {
        return get4(p.data + p.hdr_offset + 8);
    }

    // ============================================================= cells

    /// Port of the xParseCell methods.
    pub fn parseCell(p: *const MemPage, cell: [*]u8) CellInfo {
        switch (p.kind) {
            .table_interior => {
                // btreeParseCellPtrNoPayload
                const d = varint.get(cell[4..][0..9]);
                return .{ .n_key = @bitCast(d.value), .payload = cell + 4 + d.len, .n_size = @intCast(4 + d.len) };
            },
            .table_leaf => {
                // btreeParseCellPtr: the payload size, then the rowid,
                // each with the one-byte case inline.
                const sz = getPayloadSize(cell);
                const key_at = cell + sz.len;
                var info: CellInfo = undefined;
                if (key_at[0] < 0x80) {
                    info.n_key = key_at[0];
                    info.payload = key_at + 1;
                } else {
                    const key = varint.get(key_at[0..9]);
                    info.n_key = @bitCast(key.value);
                    info.payload = key_at + key.len;
                }
                info.n_payload = sz.value;
                p.finishParse(cell, &info);
                return info;
            },
            .index => {
                // btreeParseCellPtrIndex
                const body = cell + p.child_ptr_size;
                const sz = getPayloadSize(body);
                var info: CellInfo = .{
                    .n_key = sz.value,
                    .n_payload = sz.value,
                    .payload = body + sz.len,
                };
                p.finishParse(cell, &info);
                return info;
            },
        }
    }

    /// The end of btreeParseCellPtr() and btreeParseCellPtrIndex(): the
    /// local size, and the size on the page.
    inline fn finishParse(p: *const MemPage, cell: [*]u8, info: *CellInfo) void {
        if (info.n_payload <= p.max_local) {
            const hdr = @intFromPtr(info.payload) - @intFromPtr(cell);
            info.n_size = @truncate(@max(info.n_payload + hdr, 4));
            info.n_local = @intCast(info.n_payload);
        } else {
            p.adjustSizeForOverflow(cell, info);
        }
    }

    /// Port of btreeParseCellAdjustSizeForOverflow(): the local part and
    /// size on the page of a cell that spills onto overflow pages.
    noinline fn adjustSizeForOverflow(p: *const MemPage, cell: [*]u8, info: *CellInfo) void {
        info.n_local = p.payloadToLocal(info.n_payload);
        info.n_size = p.sizeOnPage(info.n_payload, @intFromPtr(info.payload) - @intFromPtr(cell));
    }

    /// Bytes a cell with an `hdr`-byte header (child pointer and varints)
    /// occupies on the page: the local payload, plus an overflow pointer if
    /// it spills, but at least 4 bytes (btreeParseCellAdjustSizeForOverflow).
    fn sizeOnPage(p: *const MemPage, n_payload: u32, hdr: usize) u16 {
        if (n_payload <= p.max_local) return @truncate(@max(n_payload + hdr, 4));
        return @truncate(hdr + p.payloadToLocal(n_payload) + 4);
    }

    /// Port of btreePayloadToLocal(): how much of an `n_payload`-byte payload
    /// is stored on the page. Changing this breaks the file format.
    pub fn payloadToLocal(p: *const MemPage, n_payload: u64) u16 {
        if (n_payload <= p.max_local) return @intCast(n_payload);
        // Fill the overflow pages exactly, keeping the local part between
        // min_local and max_local.
        const surplus = p.min_local + (n_payload - p.min_local) % (p.bt.usable_size - 4);
        return if (surplus <= p.max_local) @intCast(surplus) else p.min_local;
    }

    /// Port of the xCellSize methods: bytes the cell occupies on the page,
    /// without decoding the rest of the cell.
    pub fn cellSize(p: *const MemPage, cell: [*]u8) u16 {
        const n = p.cellSizeFast(cell);
        // The same as a full parse (the assert at the end of each method).
        if (checking()) std.debug.assert(n == p.parseCell(cell).n_size);
        return n;
    }

    inline fn cellSizeFast(p: *const MemPage, cell: [*]u8) u16 {
        switch (p.kind) {
            .table_interior => {
                // cellSizePtrNoPayload: a child pointer and a rowid varint.
                var i: usize = 4;
                while (cell[i] & 0x80 != 0 and i < 4 + 8) i += 1;
                return @intCast(i + 1);
            },
            .table_leaf => {
                // cellSizePtrTableLeaf: skip the rowid varint.
                const sz = getPayloadSize(cell);
                var i: usize = sz.len;
                const end = i + 9;
                while (i < end) {
                    const byte = cell[i];
                    i += 1;
                    if (byte & 0x80 == 0) break;
                }
                return p.sizeOnPage(sz.value, i);
            },
            .index => {
                const sz = getPayloadSize(cell + p.child_ptr_size);
                return p.sizeOnPage(sz.value, p.child_ptr_size + sz.len);
            },
        }
    }

    /// parseCell() of the cell at index `i`, in line (as getCellInfo()
    /// calls it for every row).
    pub inline fn parseCellAt(p: *const MemPage, i: usize) CellInfo {
        return @call(.always_inline, parseCell, .{ p, p.findCell(i) });
    }

    // ======================================================= header/init

    /// Port of decodeFlags(): set the page type fields from the flag byte.
    pub fn decodeFlags(p: *MemPage, flags: u8) Error!void {
        const bt = p.bt;
        p.max1byte_payload = bt.max1byte_payload;
        p.leaf = flags >= ptf_zerodata | ptf_leaf;
        p.child_ptr_size = if (p.leaf) 0 else 4;
        p.int_key = false;
        p.int_key_leaf = false;
        p.kind = .index;
        p.max_local = bt.max_local;
        p.min_local = bt.min_local;
        switch (flags) {
            table_leaf, table_interior => {
                p.int_key = true;
                p.int_key_leaf = p.leaf;
                p.kind = if (p.leaf) .table_leaf else .table_interior;
                p.max_local = bt.max_leaf;
                p.min_local = bt.min_leaf;
            },
            index_leaf, index_interior => {},
            else => return corruptPage(p.pgno, @src()),
        }
    }

    /// Port of btreeInitPage(). Decodes the header; the free space is
    /// computed lazily by `computeFreeSpace`. Success does not guarantee
    /// the page is well formed, only that no corruption was noticed.
    pub fn init(p: *MemPage) Error!void {
        std.debug.assert(!p.is_init);
        const bt = p.bt;
        const hdr = p.data + p.hdr_offset;
        try p.decodeFlags(hdr[0]);
        p.setLayout();
        p.n_cell = get2(hdr + 3);
        if (p.n_cell > btree.maxCells(bt.page_size)) return corruptPage(p.pgno, @src());
        p.n_free = -1;
        p.is_init = true;
        if (bt.cell_size_check) try p.cellSizeCheck();
    }

    /// Port of btreeComputeFreeSpace(). Validates the freeblock list.
    pub fn computeFreeSpace(p: *MemPage) Error!void {
        std.debug.assert(p.is_init and p.n_free < 0);
        const usable = p.bt.usable_size;
        const hdr = p.hdr_offset;
        const data = p.data;
        const top = get2NotZero(data + hdr + 5);
        const first: u32 = hdr + 8 + @as(u32, p.child_ptr_size) + 2 * @as(u32, p.n_cell);
        const last = usable - 4;

        var pc: u32 = get2(data + hdr + 1);
        var n_free: u32 = data[hdr + 7] + top;
        if (pc > 0) {
            // A well-formed page has at least one cell before the first
            // freeblock.
            if (pc < top) return corruptPage(p.pgno, @src());
            var next: u32 = undefined;
            var size: u32 = undefined;
            while (true) {
                if (pc > last) return corruptPage(p.pgno, @src());
                next = get2(data + pc);
                size = get2(data + pc + 2);
                if (size < 4) return corruptPage(p.pgno, @src());
                n_free += size;
                if (next < pc + size + 4) break;
                pc = next;
            }
            // Freeblocks out of order, or the last one past the page end.
            if (next > 0) return corruptPage(p.pgno, @src());
            if (pc + size > usable) return corruptPage(p.pgno, @src());
        }
        // n_free counts the content-area start plus free bytes inside it, so
        // this also checks that the content area starts inside the page.
        if (n_free > usable or n_free < first) return corruptPage(p.pgno, @src());
        p.n_free = @intCast(n_free - first);
    }

    /// Port of btreeCellSizeCheck() (PRAGMA cell_size_check=ON).
    fn cellSizeCheck(p: *MemPage) Error!void {
        const first: u32 = p.cell_offset + 2 * @as(u32, p.n_cell);
        const usable = p.bt.usable_size;
        var last = usable - 4;
        if (!p.leaf) last -= 1;
        for (0..p.n_cell) |i| {
            const pc: u32 = get2(p.data + p.cell_offset + i * 2);
            if (pc < first or pc > last) return corruptPage(p.pgno, @src());
            if (pc + p.cellSize(p.data + pc) > usable) return corruptPage(p.pgno, @src());
        }
    }

    /// Port of zeroPage(): turn the page into an empty page of type `flags`.
    pub fn zero(p: *MemPage, flags: u8) void {
        const bt = p.bt;
        const data = p.data;
        const hdr = p.hdr_offset;
        if (bt.secure_delete != .off) @memset(data[hdr..bt.usable_size], 0);
        data[hdr] = flags;
        const first: u16 = hdr + @as(u16, if (flags & ptf_leaf == 0) 12 else 8);
        @memset(data[hdr + 1 ..][0..4], 0);
        data[hdr + 7] = 0;
        put2(data + hdr + 5, bt.usable_size);
        p.n_free = @intCast(bt.usable_size - first);
        // As in C, an illegal type is left for the next read of the page to
        // report: clearDatabasePage() passes a byte of a page that a
        // corrupt tree may have overwritten.
        p.decodeFlags(flags) catch {};
        p.setLayout();
        p.n_cell = 0;
        p.is_init = true;
    }

    /// The fields derived from the header offset and page type.
    fn setLayout(p: *MemPage) void {
        p.cell_offset = p.hdr_offset + 8 + p.child_ptr_size;
        p.cell_idx = p.data + p.cell_offset;
        p.data_end = p.data + p.bt.page_size;
        p.data_ofst = p.data + p.child_ptr_size;
        p.mask_page = @intCast(p.bt.page_size - 1);
        p.n_overflow = 0;
    }

    // ===================================================== space management

    /// Port of defragmentPage(): pack all cells at the end of the page so
    /// that no more than `max_frag` fragmented bytes remain (-1 forces a
    /// full rebuild).
    pub fn defragment(p: *MemPage, max_frag: i32) Error!void {
        std.debug.assert(p.n_overflow == 0);
        const data = p.data;
        const hdr = p.hdr_offset;
        const cell_offset: u32 = p.cell_offset;
        const n_cell: u32 = p.n_cell;
        const first = cell_offset + 2 * n_cell;
        const usable = p.bt.usable_size;
        var cbrk: u32 = undefined;

        quick: {
            // With at most two freeblocks and few fragments, moving the one
            // or two runs of cells is faster than rebuilding the page.
            if (@as(i32, data[hdr + 7]) > max_frag) break :quick;
            const free1: u32 = get2(data + hdr + 1);
            if (free1 > usable - 4) return corruptPage(p.pgno, @src());
            if (free1 == 0) break :quick;
            const free2: u32 = get2(data + free1);
            if (free2 > usable - 4) return corruptPage(p.pgno, @src());
            if (!(free2 == 0 or (data[free2] == 0 and data[free2 + 1] == 0))) break :quick;

            var sz: u32 = get2(data + free1 + 2);
            var sz2: u32 = 0;
            const top: u32 = get2(data + hdr + 5);
            if (top >= free1) return corruptPage(p.pgno, @src());
            if (free2 != 0) {
                if (free1 + sz > free2) return corruptPage(p.pgno, @src());
                sz2 = get2(data + free2 + 2);
                if (free2 + sz2 > usable) return corruptPage(p.pgno, @src());
                @memmove(data[free1 + sz + sz2 .. free2 + sz2], data[free1 + sz .. free2]);
                sz += sz2;
            } else if (free1 + sz > usable) {
                return corruptPage(p.pgno, @src());
            }
            cbrk = top + sz;
            @memmove(data[cbrk .. cbrk + (free1 - top)], data[top..free1]);
            var addr = cell_offset;
            while (addr < first) : (addr += 2) {
                const pc: u32 = get2(data + addr);
                if (pc < free1) {
                    put2(data + addr, pc + sz);
                } else if (pc < free2) {
                    put2(data + addr, pc + sz2);
                }
            }
            return p.finishDefragment(cbrk);
        }

        cbrk = usable;
        const last = usable - 4;
        const start: u32 = get2(data + hdr + 5);
        if (n_cell > 0) {
            const temp = p.bt.pager.tempSpace();
            @memcpy(temp[0..usable], data[0..usable]);
            for (0..n_cell) |i| {
                const addr = data + cell_offset + i * 2;
                const pc: u32 = get2(addr);
                if (pc > last) return corruptPage(p.pgno, @src());
                const size = p.cellSize(temp.ptr + pc);
                if (size > cbrk) return corruptPage(p.pgno, @src());
                cbrk -= size;
                if (cbrk < start or pc + size > usable) return corruptPage(p.pgno, @src());
                put2(addr, cbrk);
                @memcpy(data[cbrk..][0..size], temp[pc..][0..size]);
            }
        }
        data[hdr + 7] = 0;
        return p.finishDefragment(cbrk);
    }

    fn finishDefragment(p: *MemPage, cbrk: u32) Error!void {
        const data = p.data;
        const hdr = p.hdr_offset;
        const first: u32 = p.cell_offset + 2 * @as(u32, p.n_cell);
        std.debug.assert(p.n_free >= 0);
        if (@as(i64, data[hdr + 7]) + cbrk - first != p.n_free or cbrk < first) return corruptPage(p.pgno, @src());
        put2(data + hdr + 5, cbrk);
        data[hdr + 1] = 0;
        data[hdr + 2] = 0;
        @memset(data[first..cbrk], 0);
    }

    /// Port of pageFindSlot(): take `n_byte` bytes from the freeblock list.
    /// Returns the offset of the space, or null if no freeblock fits.
    /// Slots 1-3 bytes too big are skipped if the leftover would push the
    /// fragment count past 60.
    pub fn findSlot(p: *MemPage, n_byte: u32) Error!?u32 {
        const hdr = p.hdr_offset;
        const data = p.data;
        var addr: u32 = hdr + 1;
        var pc: u32 = get2(data + addr);
        const max_pc = p.bt.usable_size - n_byte;
        std.debug.assert(pc > 0);
        while (pc <= max_pc) {
            const size: u32 = get2(data + pc + 2);
            if (size >= n_byte) {
                const x = size - n_byte;
                if (x < 4) {
                    // A well-formed page has at most 60 fragmented bytes.
                    if (data[hdr + 7] > 57) return null;
                    // Unlink the slot and count the leftover as fragments.
                    data[addr] = data[pc];
                    data[addr + 1] = data[pc + 1];
                    data[hdr + 7] += @intCast(x);
                    return pc;
                } else if (x + pc > max_pc) {
                    return corruptPage(p.pgno, @src());
                }
                // Keep the front of the slot on the list.
                put2(data + pc + 2, x);
                return pc + x;
            }
            addr = pc;
            pc = get2(data + pc);
            if (pc <= addr) {
                if (pc != 0) return corruptPage(p.pgno, @src());
                return null;
            }
        }
        if (pc > max_pc + n_byte - 4) return corruptPage(p.pgno, @src());
        return null;
    }

    /// Port of allocateSpace(): find `n_byte` bytes for a new cell, which
    /// will also need a new cell pointer. The caller guarantees the space
    /// exists; defragmenting may be needed to make it contiguous.
    pub fn allocateSpace(p: *MemPage, n_byte: u32) Error!u32 {
        const hdr = p.hdr_offset;
        const data = p.data;
        std.debug.assert(p.n_free >= n_byte and p.n_overflow == 0);
        const gap: u32 = p.cell_offset + 2 * @as(u32, p.n_cell);
        var top: u32 = get2(data + hdr + 5);
        if (gap > top) {
            // 65536 does not fit in two bytes and is stored as 0.
            if (top == 0 and p.bt.usable_size == 65536) {
                top = 65536;
            } else {
                return corruptPage(p.pgno, @src());
            }
        } else if (top > p.bt.usable_size) {
            return corruptPage(p.pgno, @src());
        }

        if ((data[hdr + 2] != 0 or data[hdr + 1] != 0) and gap + 2 <= top) {
            if (try p.findSlot(n_byte)) |idx| {
                if (idx <= gap) return corruptPage(p.pgno, @src());
                return idx;
            }
        }

        if (gap + 2 + n_byte > top) {
            try p.defragment(@min(4, p.n_free - @as(i32, @intCast(2 + n_byte))));
            top = get2NotZero(data + hdr + 5);
            std.debug.assert(gap + 2 + n_byte <= top);
        }
        top -= n_byte;
        put2(data + hdr + 5, top);
        return top;
    }

    /// Port of freeSpace(): return `size` bytes at `start` to the freeblock
    /// list, coalescing with neighbours.
    pub fn freeSpace(p: *MemPage, start_arg: u32, size_arg: u32) Error!void {
        const data = p.data;
        const hdr: u32 = p.hdr_offset;
        const usable = p.bt.usable_size;
        var start = start_arg;
        var size = size_arg;
        var end = start + size;
        var ptr: u32 = hdr + 1;
        var free_blk: u32 = 0;
        std.debug.assert(size >= 4);

        if (data[ptr + 1] != 0 or data[ptr] != 0) {
            // Find the insertion point in the ascending freeblock list.
            while (true) {
                free_blk = get2(data + ptr);
                if (free_blk >= start) break;
                if (free_blk <= ptr) {
                    if (free_blk == 0) break;
                    return corruptPage(p.pgno, @src());
                }
                ptr = free_blk;
            }
            if (free_blk > usable - 4) return corruptPage(p.pgno, @src());

            // Coalesce with the following freeblock.
            var n_frag: u32 = 0;
            if (free_blk != 0 and end + 3 >= free_blk) {
                if (end > free_blk) return corruptPage(p.pgno, @src());
                n_frag = free_blk - end;
                end = free_blk + get2(data + free_blk + 2);
                if (end > usable) return corruptPage(p.pgno, @src());
                size = end - start;
                free_blk = get2(data + free_blk);
            }
            // Coalesce with the preceding freeblock.
            if (ptr > hdr + 1) {
                const ptr_end = ptr + get2(data + ptr + 2);
                if (ptr_end + 3 >= start) {
                    if (ptr_end > start) return corruptPage(p.pgno, @src());
                    n_frag += start - ptr_end;
                    size = end - ptr;
                    start = ptr;
                }
            }
            if (n_frag > data[hdr + 7]) return corruptPage(p.pgno, @src());
            data[hdr + 7] -= @intCast(n_frag);
        }
        const content: u32 = get2(data + hdr + 5);
        if (p.bt.secure_delete != .off) @memset(data[start..][0..size], 0);
        if (start <= content) {
            // The block starts the content area: grow the unallocated space
            // instead of adding a freeblock.
            if (start < content) return corruptPage(p.pgno, @src());
            if (ptr != hdr + 1) return corruptPage(p.pgno, @src());
            put2(data + hdr + 1, free_blk);
            put2(data + hdr + 5, end);
        } else {
            put2(data + ptr, start);
            put2(data + start, free_blk);
            put2(data + start + 2, size);
        }
        p.n_free += @intCast(size_arg);
    }

    /// Port of dropCell(): remove cell `idx` (of `sz` bytes) from the page.
    /// The content is not freed elsewhere (overflow pages are untouched).
    pub fn dropCell(p: *MemPage, idx: usize, sz: u32) Error!void {
        std.debug.assert(idx < p.n_cell and p.n_free >= 0);
        const data = p.data;
        const ptr = p.cell_idx + 2 * idx;
        const pc: u32 = get2(ptr);
        const hdr = p.hdr_offset;
        if (pc + sz > p.bt.usable_size) return corruptPage(p.pgno, @src());
        try p.freeSpace(pc, sz);
        p.n_cell -= 1;
        if (p.n_cell == 0) {
            @memset(data[hdr + 1 ..][0..4], 0);
            data[hdr + 7] = 0;
            put2(data + hdr + 5, p.bt.usable_size);
            p.n_free = @intCast(p.bt.usable_size - hdr - p.child_ptr_size - 8);
        } else {
            const n = 2 * (p.n_cell - idx);
            @memmove(ptr[0..n], ptr[2..][0..n]);
            put2(data + hdr + 3, p.n_cell);
            p.n_free += 2;
        }
    }

    /// Port of insertCell(): insert `cell` (`sz` bytes) as cell `i`. If it
    /// does not fit it becomes an overflow cell, copied into `temp` when
    /// given (so the caller's buffer can be reused). The first 4 bytes are
    /// replaced with `child`.
    pub fn insertCell(p: *MemPage, i: usize, cell_arg: [*]u8, sz: u32, temp: ?[*]u8, child: Pgno) Error!void {
        std.debug.assert(i <= p.n_cell + p.n_overflow and child > 0 and p.n_free >= 0);
        var cell = cell_arg;
        if (p.n_overflow != 0 or @as(i64, sz) + 2 > p.n_free) {
            if (temp) |t| {
                @memcpy(t[0..sz], cell[0..sz]);
                cell = t;
            }
            put4(cell, child);
            p.addOverflowCell(i, cell);
            return;
        }
        try p.bt.pager.write(p.db_page);
        const idx = try p.allocateSpace(sz);
        p.n_free -= @intCast(2 + sz);
        // A corrupt cell index may point up to 4 bytes before the source
        // buffer; never read those bytes.
        @memcpy(p.data[idx + 4 ..][0 .. sz - 4], cell[4..sz]);
        put4(p.data + idx, child);
        p.insertCellPointer(i, idx);
        if (p.bt.isAutoVacuum()) try ptrmap.putOvflPtr(p, p, p.data + idx);
    }

    /// Port of insertCellFast(): `insertCell` for leaf cells built in a
    /// buffer the caller keeps alive until balancing is done.
    pub fn insertCellFast(p: *MemPage, i: usize, cell: [*]u8, sz: u32) Error!void {
        std.debug.assert(p.n_overflow == 0 and p.n_free >= 0);
        if (@as(i64, sz) + 2 > p.n_free) {
            p.addOverflowCell(i, cell);
            return;
        }
        try p.bt.pager.write(p.db_page);
        const idx = try p.allocateSpace(sz);
        p.n_free -= @intCast(2 + sz);
        @memcpy(p.data[idx..][0..sz], cell[0..sz]);
        p.insertCellPointer(i, idx);
        if (p.bt.isAutoVacuum()) try ptrmap.putOvflPtr(p, p, p.data + idx);
    }

    fn addOverflowCell(p: *MemPage, i: usize, cell: [*]u8) void {
        const j = p.n_overflow;
        // At most 3 overflow cells ever occur; the 4th slot is spare.
        std.debug.assert(j < p.ap_ovfl.len - 1);
        // Multiple overflows only come from inserting adjacent divider
        // cells during balancing, so they are sequential.
        std.debug.assert(j == 0 or i == p.ai_ovfl[j - 1] + 1);
        p.n_overflow += 1;
        p.ap_ovfl[j] = cell;
        p.ai_ovfl[j] = @intCast(i);
    }

    fn insertCellPointer(p: *MemPage, i: usize, idx: u32) void {
        const ins = p.cell_idx + i * 2;
        const n = 2 * (p.n_cell - i);
        @memmove(ins[2..][0..n], ins[0..n]);
        put2(ins, idx);
        p.n_cell += 1;
        // Bump the on-page count in place, as the C code does.
        const hdr = p.data + p.hdr_offset;
        hdr[4] +%= 1;
        if (hdr[4] == 0) hdr[3] +%= 1;
    }
};

/// The payload-size varint at the start of a cell, as the C parsers read
/// it: at most 9 bytes, 7 bits each, truncated to 32 bits.
inline fn getPayloadSize(p: [*]const u8) struct { value: u32, len: u8 } {
    var n: u32 = p[0];
    var i: u8 = 0;
    if (n >= 0x80) {
        n &= 0x7f;
        while (true) {
            i += 1;
            n = (n << 7) | (p[i] & 0x7f);
            if (p[i] < 0x80 or i >= 8) break;
        }
    }
    return .{ .value = n, .len = i + 1 };
}

pub fn get2(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .big);
}

/// Writes the low 16 bits of `v` (so 65536 is stored as 0).
pub fn put2(p: [*]u8, v: u32) void {
    std.mem.writeInt(u16, p[0..2], @truncate(v), .big);
}

/// get2byteNotZero(): a 2-byte value where 0 means 65536.
pub fn get2NotZero(p: [*]const u8) u32 {
    return ((@as(u32, get2(p)) -% 1) & 0xffff) + 1;
}

pub fn get4(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

pub fn put4(p: [*]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .big);
}

// ====================================================== page access

/// Port of btreePageFromDbPage().
pub fn pageFromDbPage(bt: *Btree, pg: *pager_mod.Page, pgno: Pgno) *MemPage {
    const mp = MemPage.of(pg);
    if (pgno != mp.pgno) {
        mp.data = pg.data.ptr;
        mp.db_page = pg;
        mp.bt = bt;
        mp.pgno = pgno;
        mp.hdr_offset = if (pgno == 1) 100 else 0;
    }
    return mp;
}

/// Port of btreeGetPage(). The page is not initialized.
pub fn getPage(bt: *Btree, pgno: Pgno, flags: pager_mod.GetFlags) Error!*MemPage {
    const pg = try bt.pager.get(pgno, flags);
    return pageFromDbPage(bt, pg, pgno);
}

/// Port of btreePageLookup(): the page if it is cached, referenced.
pub fn lookupPage(bt: *Btree, pgno: Pgno) ?*MemPage {
    const pg = bt.pager.lookup(pgno) orelse return null;
    return pageFromDbPage(bt, pg, pgno);
}

/// Port of getAndInitPage().
pub fn getAndInitPage(bt: *Btree, pgno: Pgno) Error!*MemPage {
    if (pgno > bt.n_page) return corrupt(@src());
    const pg = try bt.pager.get(pgno, .{});
    const mp = MemPage.of(pg);
    if (!mp.is_init) {
        _ = pageFromDbPage(bt, pg, pgno);
        mp.init() catch |err| {
            releasePage(mp);
            return err;
        };
    }
    return mp;
}

/// Port of btreeGetUnusedPage(): a page about to be reused, which no one
/// else may be referencing.
pub fn getUnusedPage(bt: *Btree, pgno: Pgno, flags: pager_mod.GetFlags) Error!*MemPage {
    const mp = try getPage(bt, pgno, flags);
    if (mp.db_page.n_ref > 1) {
        releasePage(mp);
        return corrupt(@src());
    }
    mp.is_init = false;
    return mp;
}

pub fn within(p: [*]const u8, start: [*]const u8, end: [*]const u8) bool {
    return @intFromPtr(p) >= @intFromPtr(start) and @intFromPtr(p) < @intFromPtr(end);
}

/// SQLITE_OVERFLOW(P,S,E): the range [S,E) crosses P.
pub fn straddles(p: [*]const u8, start: [*]const u8, end: [*]const u8) bool {
    return @intFromPtr(start) < @intFromPtr(p) and @intFromPtr(end) > @intFromPtr(p);
}

pub fn ptrDiff(a: [*]const u8, b: [*]const u8) isize {
    return @as(isize, @intCast(@intFromPtr(a))) - @as(isize, @intCast(@intFromPtr(b)));
}
