//! The sorter used for ORDER BY, GROUP BY and CREATE INDEX (port of
//! vdbesort.c): an external merge sort that runs in bounded memory.
//!
//! Records are kept in memory until they would take more than
//! mxPmaSize bytes (derived from the page size and cache_size of the main
//! database). Then they are sorted and written to a temporary file as a
//! "Packed Memory Array" (PMA). Rewind() writes the last PMA and merges
//! all of them through a tree of MergeEngine and IncrMerger objects, at
//! most SORTER_MAX_MERGE_COUNT PMAs at a time. When nothing was spilled,
//! the records are sorted and read in memory.
//!
//! Only the single-threaded sorter is ported: the worker threads of the C
//! code (PRAGMA threads) are not, and the sort runs as with threads=0
//! whatever that pragma says. Nor is the memory-mapped reading of the
//! temporary files.
//!
//! The in-memory sort is C's list merge sort and the merge of the PMAs
//! prefers the older PMA on ties, so rows with equal keys come out in the
//! same order as from SQLite: the order they were inserted.
//!
//! Not in C: each in-memory record also carries a normalized key, an
//! order-preserving 64-bit prefix of its first field (normKey(), after
//! Turso's sorter). The in-memory sort compares those first and calls
//! the comparator only when they are equal, which spares most of the
//! visits to the records themselves. Not when the first field has a
//! collation other than BINARY. The order is unchanged: a smaller
//! normalized key always means a smaller record.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const serial = @import("serial.zig");
const int = @import("../sql/sqlite_int.zig");
const vfs = @import("xqlite_vfs").vfs;
const varint = @import("xqlite_storage").varint;
const record_fmt = @import("xqlite_storage").record;

const Allocator = std.mem.Allocator;
const Mem = vi.Mem;
const MEM = vi.MEM;
const KeyInfo = vi.KeyInfo;
const UnpackedRecord = vi.UnpackedRecord;
const VdbeCursor = vi.VdbeCursor;

pub const Error = vfs.Error || error{Corrupt};

/// SQLITE_MAX_PMASZ: the most data kept in memory before a level-0 PMA
/// is written, whatever the cache size, to avoid integer overflows.
const max_pmasz: i64 = 1 << 29;

/// SQLITE_SORTER_PMASZ (sqlite3GlobalConfig.szPma): the least memory used
/// before spilling, in pages.
const sorter_pmasz: i64 = 250;

/// SORTER_MAX_MERGE_COUNT: the most PMAs one MergeEngine merges.
const max_merge_count = 16;

/// sizeof(SorterRecord), the header C puts before each record held in
/// memory. It counts towards mxPmaSize as in C, so that PMAs are cut
/// where SQLite cuts them.
const sizeof_sorter_record: i64 = 16;

const type_integer: u8 = 0x01;
const type_text: u8 = 0x02;
const type_real: u8 = 0x04;

/// No next record in a sort list.
const end_of_list = std.math.maxInt(u32);

/// SorterFile: a temporary file and the amount of data stored in it.
const SorterFile = struct {
    fd: ?vfs.File = null,
    eof: i64 = 0,
};

/// VdbeSorter.
pub const Sorter = struct {
    gpa: Allocator,
    db: *int.Sqlite3,
    /// Minimum and maximum PMA size, in bytes. mx_pma_size 0 means no
    /// limit: nothing is spilled.
    mn_pma_size: i64 = 0,
    mx_pma_size: i64 = 0,
    /// Largest serialized key seen so far (mxKeysize).
    mx_keysize: i64 = 0,
    /// Main database page size.
    pgsz: u32,
    /// The PMAs are read from here after rewind(), if use_pma.
    merger: ?*MergeEngine = null,
    /// The cursor's KeyInfo, with n_key_field possibly reduced to the
    /// columns that decide the order.
    key_info: KeyInfo,
    /// The in-memory list (list): the records back to back in `data`,
    /// with their start and end in `records`, in insertion order.
    data: std.ArrayList(u8) = .empty,
    records: std.ArrayList(Span) = .empty,
    /// The normalized key of each record of the list, if norm_on.
    norms: std.ArrayList(u64) = .empty,
    /// Size of the list as a PMA in bytes (list.szPMA).
    sz_pma: i64 = 0,
    /// The memory C's list.aMemory would use for the list (iMemory).
    i_memory: i64 = 0,
    /// The next record of each record of the sorted list
    /// (SorterRecord.u.pNext).
    links: std.ArrayList(u32) = .empty,
    /// The record being read after rewind() of an in-memory sort.
    cur: u32 = end_of_list,
    /// One or more PMAs were written.
    use_pma: bool = false,
    /// SORTER_TYPE_* bits: what every record's first field could be, for
    /// the fast comparators.
    type_mask: u8 = 0,
    /// The sort uses normalized keys: the first field is not compared with
    /// a collation other than BINARY, which they could not mirror.
    norm_on: bool = false,
    /// The normalized keys of the in-memory list may decide the order: no
    /// record of the list has a first field normKey() cannot map.
    norm_ok: bool = true,
    /// The normalized keys of the list are not all the same (else they
    /// decide nothing, as with a long common prefix).
    norm_varied: bool = false,
    /// How normKey() maps the first field, from the KeyInfo.
    norm_desc: bool = false,
    norm_bignull: bool = false,
    /// The one task (aTask[0]).
    task: SortSubtask,
    /// Space to unpack a record into.
    cells: []Mem,

    const Span = struct { start: u32, end: u32 };

    fn record(s: *const Sorter, i: u32) []const u8 {
        const r = s.records.items[i];
        return s.data.items[r.start..r.end];
    }
};

const CompareFn = *const fn (t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32;

/// SortSubtask: the comparator and its unpacked record, and the
/// temporary files.
const SortSubtask = struct {
    sorter: *Sorter,
    /// Number of PMAs in `file`.
    n_pma: u32 = 0,
    unpacked: UnpackedRecord,
    cmp: CompareFn = compareGeneral,
    /// Temp file for level-0 PMAs.
    file: SorterFile = .{},
    /// Space for the output of IncrMergers.
    file2: SorterFile = .{},
    /// Total bytes written.
    n_spill: u64 = 0,
};

/// MergeEngine: merges the PMAs of `readers` with a tournament tree.
/// `tree[1]` is the index of the reader with the smallest key; the last
/// n_tree/2 entries hold the winners of pairs of readers, the n_tree/4
/// before them the winners of pairs of those, and so on.
const MergeEngine = struct {
    /// Used size of tree and readers (a power of 2).
    n_tree: u32,
    task: ?*SortSubtask = null,
    tree: []u32,
    readers: []PmaReader,
};

/// PmaReader: reads the records of a PMA, or of an IncrMerger, in order.
/// The next key is `key`. fd is null at EOF.
const PmaReader = struct {
    read_off: i64 = 0,
    /// One byte past the end of the PMA.
    eof: i64 = 0,
    /// Space for the key when it is not contiguous in `buffer` (aAlloc).
    alloc: []u8 = &.{},
    key: []const u8 = &.{},
    fd: ?vfs.File = null,
    /// The read buffer, a page in size.
    buffer: []u8 = &.{},
    incr: ?*IncrMerger = null,
};

/// IncrMerger, single-threaded: owns `mx_sz` bytes of task.file2 at
/// `start_off`, which it refills from `merger` whenever its PmaReader has
/// read them all.
const IncrMerger = struct {
    task: *SortSubtask,
    merger: *MergeEngine,
    start_off: i64 = 0,
    mx_sz: i64,
    /// The merge is finished.
    eof: bool = false,
    /// files[0] for reading, files[1] for writing.
    files: [2]SorterFile = .{ .{}, .{} },
};

/// PmaWriter: buffers the writes of a PMA so that they are made in
/// page-sized, page-aligned blocks.
const PmaWriter = struct {
    err: ?Error = null,
    buffer: []u8 = &.{},
    buf_start: usize = 0,
    buf_end: usize = 0,
    /// Offset of the start of `buffer` in the file.
    write_off: i64 = 0,
    fd: ?vfs.File = null,
    n_pma_spill: u64 = 0,
};

fn get(c: *VdbeCursor) *Sorter {
    return c.uc.sorter;
}

/// Port of sqlite3TempInMemory() for SQLITE_TEMP_STORE=1: temporary
/// files are in memory only with PRAGMA temp_store=MEMORY.
fn tempInMemory(db: *const int.Sqlite3) bool {
    return db.temp_store == 2;
}

// ================================================================ readers

/// Port of vdbePmaReaderClear().
fn pmaReaderClear(gpa: Allocator, p: *PmaReader) void {
    gpa.free(p.alloc);
    gpa.free(p.buffer);
    if (p.incr) |incr| incrFree(gpa, incr);
    p.* = .{};
}

/// Port of vdbePmaReadBlob(): read the next `n_byte` bytes. The result is
/// valid until the next call.
fn pmaReadBlob(gpa: Allocator, p: *PmaReader, n_byte: usize) Error![]const u8 {
    const n_buffer = p.buffer.len;
    // When the buffer is used up, read the next n_buffer bytes, or what
    // is left of the PMA.
    const i_buf: usize = @intCast(@mod(p.read_off, @as(i64, @intCast(n_buffer))));
    if (i_buf == 0) {
        const left = p.eof - p.read_off;
        const n_read: usize = if (left > n_buffer) n_buffer else @intCast(left);
        try p.fd.?.read(p.buffer[0..n_read], @intCast(p.read_off));
    }
    const n_avail = n_buffer - i_buf;

    if (n_byte <= n_avail) {
        p.read_off += @intCast(n_byte);
        return p.buffer[i_buf..][0..n_byte];
    }
    // The data is not all in the buffer: copy it to p.alloc.
    if (p.alloc.len < n_byte) {
        var n_new: usize = @max(128, 2 * p.alloc.len);
        while (n_byte > n_new) n_new *= 2;
        p.alloc = try gpa.realloc(p.alloc, n_new);
    }
    @memcpy(p.alloc[0..n_avail], p.buffer[i_buf..][0..n_avail]);
    p.read_off += @intCast(n_avail);
    var n_rem = n_byte - n_avail;
    while (n_rem > 0) {
        const n_copy = @min(n_rem, n_buffer);
        const next_part = try pmaReadBlob(gpa, p, n_copy);
        @memcpy(p.alloc[n_byte - n_rem ..][0..n_copy], next_part);
        n_rem -= n_copy;
    }
    return p.alloc[0..n_byte];
}

/// Port of vdbePmaReadVarint().
fn pmaReadVarint(gpa: Allocator, p: *PmaReader) Error!u64 {
    const n_buffer = p.buffer.len;
    const i_buf: usize = @intCast(@mod(p.read_off, @as(i64, @intCast(n_buffer))));
    if (i_buf != 0 and n_buffer - i_buf >= 9) {
        const d = varint.get(p.buffer[i_buf..]);
        p.read_off += d.len;
        return d.value;
    }
    var a: [16]u8 = @splat(0);
    var i: usize = 0;
    while (true) {
        const b = try pmaReadBlob(gpa, p, 1);
        a[i & 0xf] = b[0];
        i += 1;
        if (b[0] & 0x80 == 0) break;
    }
    return varint.get(&a).value;
}

/// Port of vdbePmaReaderSeek(): attach `p` to `file` at offset `off`.
fn pmaReaderSeek(t: *SortSubtask, p: *PmaReader, file: *const SorterFile, off: i64) Error!void {
    std.debug.assert(p.incr == null or !p.incr.?.eof);
    p.read_off = off;
    p.eof = file.eof;
    p.fd = file.fd;

    const pgsz: usize = t.sorter.pgsz;
    const i_buf: usize = @intCast(@mod(p.read_off, @as(i64, @intCast(pgsz))));
    if (p.buffer.len == 0) p.buffer = try t.sorter.gpa.alloc(u8, pgsz);
    if (i_buf != 0) {
        var n_read: i64 = @intCast(pgsz - i_buf);
        if (p.read_off + n_read > p.eof) n_read = p.eof - p.read_off;
        try p.fd.?.read(p.buffer[i_buf..][0..@intCast(n_read)], @intCast(p.read_off));
    }
}

/// Port of vdbePmaReaderNext(): advance to the next key, refilling an
/// IncrMerger's space when it has all been read.
fn pmaReaderNext(t: *SortSubtask, p: *PmaReader) Error!void {
    const gpa = t.sorter.gpa;
    if (p.read_off >= p.eof) {
        var at_eof = true;
        if (p.incr) |incr| {
            try incrSwap(incr);
            if (!incr.eof) {
                try pmaReaderSeek(incr.task, p, &incr.files[0], incr.start_off);
                at_eof = false;
            }
        }
        if (at_eof) {
            pmaReaderClear(gpa, p);
            return;
        }
    }
    const n_rec = try pmaReadVarint(gpa, p);
    if (n_rec > std.math.maxInt(i32)) return error.Corrupt;
    p.key = try pmaReadBlob(gpa, p, @intCast(n_rec));
}

/// Port of vdbePmaReaderInit(): read the PMA of `file` that starts at
/// `start`, leaving `p` on its first key. Adds the PMA size to `n_byte`.
fn pmaReaderInit(t: *SortSubtask, file: *const SorterFile, start: i64, p: *PmaReader, n_byte: *i64) Error!void {
    std.debug.assert(file.eof > start);
    std.debug.assert(p.alloc.len == 0 and p.buffer.len == 0);
    try pmaReaderSeek(t, p, file, start);
    const n = try pmaReadVarint(t.sorter.gpa, p);
    p.eof = p.read_off + @as(i64, @intCast(n));
    n_byte.* += @intCast(n);
    try pmaReaderNext(t, p);
}

// ============================================================ comparators

fn unpackKey2(t: *SortSubtask, key2_cached: *bool, key2: []const u8) void {
    if (!key2_cached.*) {
        t.unpacked.n_field = t.sorter.key_info.n_key_field;
        serial.recordUnpack(key2, &t.unpacked);
        key2_cached.* = true;
    }
}

/// Port of vdbeSorterCompare().
fn compareGeneral(t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    unpackKey2(t, key2_cached, key2);
    return serial.recordCompare(key1, &t.unpacked);
}

/// Port of vdbeSorterCompareTail(): the first fields are equal.
fn compareTail(t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    unpackKey2(t, key2_cached, key2);
    return serial.recordCompareWithSkip(key1, &t.unpacked, true);
}

/// The end of the fast comparators: break ties on the first field with
/// the rest, or apply DESC.
fn finishCompare(t: *SortSubtask, res: i32, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    if (res == 0) {
        if (t.sorter.key_info.n_key_field > 1) return compareTail(t, key2_cached, key1, key2);
        return 0;
    }
    return if (t.sorter.key_info.sort_flags[0] != 0) -res else res;
}

/// Port of vdbeSorterCompareText(): both first fields are TEXT, BINARY.
fn compareText(t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    const n1 = record_fmt.getVarint32(key1, 1).value;
    const n2 = record_fmt.getVarint32(key2, 1).value;
    const len = (@min(n1, n2) - 13) / 2;
    const v1 = key1[key1[0]..][0..len];
    const v2 = key2[key2[0]..][0..len];
    const c = record_fmt.memcmp(v1, v2);
    var res: i32 = if (c < 0) -1 else @intFromBool(c > 0);
    if (res == 0) res = @as(i32, @intCast(n1)) - @as(i32, @intCast(n2));
    return finishCompare(t, res, key2_cached, key1, key2);
}

/// Port of vdbeSorterCompareInt(): both first fields are integers.
fn compareInt(t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    const s1: i32 = key1[1];
    const s2: i32 = key2[1];
    const v1 = key1[key1[0]..];
    const v2 = key2[key2[0]..];
    var res: i32 = 0;
    if (s1 == s2) {
        // Same size: compare the big-endian bytes, minding the sign.
        const lens = [_]u8{ 0, 1, 2, 3, 4, 6, 8, 0, 0, 0 };
        for (0..lens[@intCast(s1)]) |i| {
            res = @as(i32, v1[i]) - @as(i32, v2[i]);
            if (res != 0) {
                if ((v1[0] ^ v2[0]) & 0x80 != 0) res = if (v1[0] & 0x80 != 0) -1 else 1;
                break;
            }
        }
    } else if (s1 > 7 and s2 > 7) {
        res = s1 - s2;
    } else {
        if (s2 > 7) {
            res = 1;
        } else if (s1 > 7) {
            res = -1;
        } else {
            res = s1 - s2;
        }
        if (res > 0) {
            if (v1[0] & 0x80 != 0) res = -1;
        } else {
            if (v2[0] & 0x80 != 0) res = 1;
        }
    }
    return finishCompare(t, res, key2_cached, key1, key2);
}

/// vdbeSorterGetReal(): the first field, a REAL or an integer.
fn getReal(p: []const u8) f64 {
    var m: Mem = .{};
    serial.serialGet(p, p[0], p[1], &m);
    return if (p[1] == 7) m.u.r else @floatFromInt(m.u.i);
}

/// Port of vdbeSorterCompareReal() and vdbeSorterCompareRealInt().
fn compareReal(t: *SortSubtask, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
    // 64-bit integers do not convert to doubles exactly.
    if ((key1[1] != 7 or key2[1] != 7) and (key1[1] == 6 or key2[1] == 6)) {
        return compareGeneral(t, key2_cached, key1, key2);
    }
    const r1 = getReal(key1);
    const r2 = getReal(key2);
    const res: i32 = if (r1 < r2) -1 else if (r1 > r2) 1 else 0;
    return finishCompare(t, res, key2_cached, key1, key2);
}

/// Port of vdbeSorterGetCompare().
fn getCompare(s: *const Sorter) CompareFn {
    const mask = s.type_mask;
    if (mask & type_integer != 0) return compareInt;
    if (mask & type_text != 0) return compareText;
    if (mask & type_real != 0) return compareReal;
    return compareGeneral;
}

// ========================================================= in-memory sort

/// Port of vdbeSorterMerge(): merge two sorted lists, taking from `p1`
/// on ties. `cmp` is t.cmp, fixed so that it can be called directly.
inline fn sorterMerge(comptime cmp: CompareFn, comptime use_norm: bool, t: *SortSubtask, p1_arg: u32, p2_arg: u32) u32 {
    const s = t.sorter;
    const links = s.links.items.ptr;
    const records = s.records.items.ptr;
    const data = s.data.items.ptr;
    const norms = s.norms.items.ptr;
    var p1 = p1_arg;
    var p2 = p2_arg;
    var first: u32 = end_of_list;
    var tail: ?*u32 = null;
    var key2_cached = false;
    while (true) {
        // Equal normalized keys leave the order to the comparator.
        const res = if (use_norm and norms[p1] != norms[p2])
            @as(i32, if (norms[p1] < norms[p2]) -1 else 1)
        else blk: {
            const r1 = records[p1];
            const r2 = records[p2];
            break :blk @call(.auto, cmp, .{ t, &key2_cached, data[r1.start..r1.end], data[r2.start..r2.end] });
        };
        const take = if (res <= 0) p1 else p2;
        if (tail) |tl| tl.* = take else first = take;
        tail = &links[take];
        if (res <= 0) {
            p1 = links[p1];
            if (p1 == end_of_list) {
                tail.?.* = p2;
                break;
            }
        } else {
            p2 = links[p2];
            key2_cached = false;
            if (p2 == end_of_list) {
                tail.?.* = p1;
                break;
            }
        }
    }
    return first;
}

/// Port of vdbeSorterSort(): sort the in-memory list. Returns its first
/// record; `links` holds the order.
fn sorterSort(t: *SortSubtask) Error!u32 {
    const s = t.sorter;
    const n = s.records.items.len;
    try s.links.resize(s.gpa, n);
    t.cmp = getCompare(s);
    const p = if (s.norm_on and s.norm_ok and s.norm_varied) sortWithCompare(true, t) else sortWithCompare(false, t);
    if (t.unpacked.err) |err| return err;
    return p;
}

/// sorterSortWith() for t.cmp.
fn sortWithCompare(comptime use_norm: bool, t: *SortSubtask) u32 {
    return if (t.cmp == &compareInt)
        sorterSortWith(compareInt, use_norm, t)
    else if (t.cmp == &compareText)
        sorterSortWith(compareText, use_norm, t)
    else if (t.cmp == &compareReal)
        sorterSortWith(compareReal, use_norm, t)
    else
        sorterSortWith(compareGeneral, use_norm, t);
}

/// The body of sorterSort() for the comparator `cmp`.
fn sorterSortWith(comptime cmp: CompareFn, comptime use_norm: bool, t: *SortSubtask) u32 {
    const s = t.sorter;
    const links = s.links.items;
    // The C list is newest first.
    var slots: [64]u32 = @splat(end_of_list);
    var k = s.records.items.len;
    while (k > 0) {
        k -= 1;
        var p: u32 = @intCast(k);
        links[p] = end_of_list;
        var i: usize = 0;
        while (slots[i] != end_of_list) : (i += 1) {
            p = sorterMerge(cmp, use_norm, t, p, slots[i]);
            slots[i] = end_of_list;
        }
        slots[i] = p;
    }
    var p: u32 = end_of_list;
    for (slots) |slot| {
        if (slot == end_of_list) continue;
        p = if (p == end_of_list) slot else sorterMerge(cmp, use_norm, t, p, slot);
    }
    return p;
}

/// Empty the in-memory list.
fn listClear(s: *Sorter) void {
    s.norm_ok = true;
    s.norm_varied = false;
    s.data.clearRetainingCapacity();
    s.records.clearRetainingCapacity();
    s.norms.clearRetainingCapacity();
    s.links.clearRetainingCapacity();
    s.cur = end_of_list;
}

// ================================================================ writing

/// Port of vdbePmaWriterInit().
fn pmaWriterInit(gpa: Allocator, fd: vfs.File, n_buf: usize, start: i64) PmaWriter {
    var p: PmaWriter = .{};
    p.buffer = gpa.alloc(u8, n_buf) catch {
        p.err = error.OutOfMemory;
        return p;
    };
    p.buf_start = @intCast(@mod(start, @as(i64, @intCast(n_buf))));
    p.buf_end = p.buf_start;
    p.write_off = start - @as(i64, @intCast(p.buf_start));
    p.fd = fd;
    return p;
}

/// Port of vdbePmaWriteBlob().
fn pmaWriteBlob(p: *PmaWriter, data: []const u8) void {
    var n_rem = data.len;
    while (n_rem > 0 and p.err == null) {
        const n_copy = @min(n_rem, p.buffer.len - p.buf_end);
        @memcpy(p.buffer[p.buf_end..][0..n_copy], data[data.len - n_rem ..][0..n_copy]);
        p.buf_end += n_copy;
        if (p.buf_end == p.buffer.len) {
            p.fd.?.write(p.buffer[p.buf_start..p.buf_end], @intCast(p.write_off + @as(i64, @intCast(p.buf_start)))) catch |err| {
                p.err = err;
            };
            p.n_pma_spill += p.buf_end - p.buf_start;
            p.buf_start = 0;
            p.buf_end = 0;
            p.write_off += @intCast(p.buffer.len);
        }
        n_rem -= n_copy;
    }
}

/// Port of vdbePmaWriterFinish(): flush the buffer and free it. Sets
/// `eof` to the end of the data written and adds the bytes written to
/// `n_spill`.
fn pmaWriterFinish(gpa: Allocator, p: *PmaWriter, eof: *i64, n_spill: *u64) Error!void {
    if (p.err == null and p.buffer.len > 0 and p.buf_end > p.buf_start) {
        p.fd.?.write(p.buffer[p.buf_start..p.buf_end], @intCast(p.write_off + @as(i64, @intCast(p.buf_start)))) catch |err| {
            p.err = err;
        };
        p.n_pma_spill += p.buf_end - p.buf_start;
    }
    eof.* = p.write_off + @as(i64, @intCast(p.buf_end));
    n_spill.* += p.n_pma_spill;
    gpa.free(p.buffer);
    const err = p.err;
    p.* = .{};
    if (err) |e| return e;
}

/// Port of vdbePmaWriteVarint().
fn pmaWriteVarint(p: *PmaWriter, value: u64) void {
    var buf: [10]u8 = undefined;
    const n = varint.put(&buf, value);
    pmaWriteBlob(p, buf[0..n]);
}

/// Port of vdbeSorterOpenTempFile(): open a temporary file that is
/// deleted when closed.
fn openTempFile(db: *int.Sqlite3) Error!vfs.File {
    return db.vfs.?.open(null, .{ .kind = .temp_journal });
}

/// Port of vdbeSorterListToPMA(): sort the in-memory list and append it
/// to the task's file as a level-0 PMA. A PMA is a varint with the size
/// of its content, then each record as a varint size and the record.
fn listToPMA(t: *SortSubtask) Error!void {
    const s = t.sorter;
    std.debug.assert(s.sz_pma > 0);
    if (t.file.fd == null) {
        t.file.fd = try openTempFile(s.db);
        std.debug.assert(t.file.eof == 0 and t.n_pma == 0);
    }
    const head = try sorterSort(t);

    var writer = pmaWriterInit(s.gpa, t.file.fd.?, s.pgsz, t.file.eof);
    t.n_pma += 1;
    if (@import("builtin").is_test) s.db.n_pma_written += 1;
    pmaWriteVarint(&writer, @intCast(s.sz_pma));
    var p = head;
    while (p != end_of_list) : (p = s.links.items[p]) {
        const rec = s.record(p);
        pmaWriteVarint(&writer, rec.len);
        pmaWriteBlob(&writer, rec);
    }
    listClear(s);
    try pmaWriterFinish(s.gpa, &writer, &t.file.eof, &t.n_spill);
}

/// Port of vdbeSorterFlushPMA() with no worker threads.
fn flushPMA(s: *Sorter) Error!void {
    s.use_pma = true;
    return listToPMA(&s.task);
}

// ================================================================ merging

/// Port of vdbeMergeEngineNew(): a MergeEngine for up to `n_reader`
/// PmaReaders, rounded up to a power of two.
fn mergeEngineNew(gpa: Allocator, n_reader: u32) Error!*MergeEngine {
    std.debug.assert(n_reader <= max_merge_count);
    var n: u32 = 2;
    while (n < n_reader) n += n;
    const m = try gpa.create(MergeEngine);
    errdefer gpa.destroy(m);
    const tree = try gpa.alloc(u32, n);
    errdefer gpa.free(tree);
    const readers = try gpa.alloc(PmaReader, n);
    @memset(tree, 0);
    @memset(readers, .{});
    m.* = .{ .n_tree = n, .tree = tree, .readers = readers };
    return m;
}

/// Port of vdbeMergeEngineFree().
fn mergeEngineFree(gpa: Allocator, m: *MergeEngine) void {
    for (m.readers) |*r| pmaReaderClear(gpa, r);
    gpa.free(m.readers);
    gpa.free(m.tree);
    gpa.destroy(m);
}

/// Port of vdbeIncrFree().
fn incrFree(gpa: Allocator, incr: *IncrMerger) void {
    mergeEngineFree(gpa, incr.merger);
    gpa.destroy(incr);
}

/// Port of vdbeMergeEngineStep(): advance to the next entry. Returns
/// true at the end of all the inputs.
fn mergeEngineStep(m: *MergeEngine) Error!bool {
    const t = m.task.?;
    const i_prev = m.tree[1];
    try pmaReaderNext(t, &m.readers[i_prev]);

    // Update the tree, from the reader just advanced up.
    var r1: u32 = i_prev & 0xfffe;
    var r2: u32 = i_prev | 0x0001;
    var key2_cached = false;
    var i = (m.n_tree + i_prev) / 2;
    while (i > 0) : (i /= 2) {
        const p1 = &m.readers[r1];
        const p2 = &m.readers[r2];
        const res: i32 = if (p1.fd == null)
            1
        else if (p2.fd == null)
            -1
        else
            t.cmp(t, &key2_cached, p1.key, p2.key);

        // On a tie, the older PMA (the lower reader) comes first. If
        // reader 2 won, the unpacked record still holds its key.
        if (res < 0 or (res == 0 and r1 < r2)) {
            m.tree[i] = r1;
            r2 = m.tree[i ^ 0x0001];
            key2_cached = false;
        } else {
            if (p1.fd != null) key2_cached = false;
            m.tree[i] = r2;
            r1 = m.tree[i ^ 0x0001];
        }
    }
    if (t.unpacked.err) |err| return err;
    return m.readers[m.tree[1]].fd == null;
}

/// Port of vdbeIncrPopulate(): fill files[1] of `incr` from its merger,
/// in PMA format without the leading size varint.
fn incrPopulate(incr: *IncrMerger) Error!void {
    std.debug.assert(!incr.eof);
    const start = incr.start_off;
    const out = &incr.files[1];
    const t = incr.task;
    const m = incr.merger;
    const gpa = t.sorter.gpa;
    var writer = pmaWriterInit(gpa, out.fd.?, t.sorter.pgsz, start);
    var failed: ?Error = null;
    while (true) {
        const reader = &m.readers[m.tree[1]];
        const n_key = reader.key.len;
        const eof = writer.write_off + @as(i64, @intCast(writer.buf_end));

        // Stop when the output is full or the input is used up.
        if (reader.fd == null) break;
        if (eof + @as(i64, @intCast(n_key)) + varint.len(n_key) > start + incr.mx_sz) break;

        pmaWriteVarint(&writer, n_key);
        pmaWriteBlob(&writer, reader.key);
        std.debug.assert(m.task == t);
        _ = mergeEngineStep(m) catch |err| {
            failed = err;
            break;
        };
    }
    const rc2 = pmaWriterFinish(gpa, &writer, &out.eof, &t.n_spill);
    if (failed) |err| return err;
    return rc2;
}

/// Port of vdbeIncrSwap(), single-threaded: refill the space of `incr`
/// once its PmaReader has read it all.
fn incrSwap(incr: *IncrMerger) Error!void {
    try incrPopulate(incr);
    incr.files[0] = incr.files[1];
    if (incr.files[0].eof == incr.start_off) incr.eof = true;
}

/// Port of vdbeIncrMergerNew(): an IncrMerger reading from `m`. Frees `m`
/// on failure.
fn incrMergerNew(t: *SortSubtask, m: *MergeEngine) Error!*IncrMerger {
    const gpa = t.sorter.gpa;
    const incr = gpa.create(IncrMerger) catch {
        mergeEngineFree(gpa, m);
        return error.OutOfMemory;
    };
    incr.* = .{
        .task = t,
        .merger = m,
        .mx_sz = @max(t.sorter.mx_keysize + 9, @divTrunc(t.sorter.mx_pma_size, 2)),
    };
    t.file2.eof += incr.mx_sz;
    return incr;
}

/// Port of vdbeMergeEngineCompare(): recompute tree[i_out] from the two
/// entries or readers below it.
fn mergeEngineCompare(m: *MergeEngine, i_out: u32) void {
    std.debug.assert(i_out < m.n_tree and i_out > 0);
    var i_1: u32 = undefined;
    var i_2: u32 = undefined;
    if (i_out >= m.n_tree / 2) {
        i_1 = (i_out - m.n_tree / 2) * 2;
        i_2 = i_1 + 1;
    } else {
        i_1 = m.tree[i_out * 2];
        i_2 = m.tree[i_out * 2 + 1];
    }
    const p1 = &m.readers[i_1];
    const p2 = &m.readers[i_2];
    var res: u32 = undefined;
    if (p1.fd == null) {
        res = i_2;
    } else if (p2.fd == null) {
        res = i_1;
    } else {
        const t = m.task.?;
        var key2_cached = false;
        res = if (t.cmp(t, &key2_cached, p1.key, p2.key) <= 0) i_1 else i_2;
    }
    m.tree[i_out] = res;
}

/// Port of vdbeMergeEngineInit() with INCRINIT_NORMAL: initialize the
/// readers of `m`, so that its first key can be read.
fn mergeEngineInit(t: *SortSubtask, m: *MergeEngine) Error!void {
    std.debug.assert(m.task == null);
    m.task = t;
    for (m.readers) |*r| try pmaReaderIncrInit(r);
    var i = m.n_tree - 1;
    while (i > 0) : (i -= 1) mergeEngineCompare(m, i);
    if (t.unpacked.err) |err| return err;
}

/// Port of vdbePmaReaderIncrMergeInit() with INCRINIT_NORMAL: initialize
/// the tree below the IncrMerger of `p`, give it its share of
/// task.file2, and move `p` to the first key.
fn pmaReaderIncrMergeInit(p: *PmaReader) Error!void {
    const incr = p.incr.?;
    const t = incr.task;
    try mergeEngineInit(t, incr.merger);
    if (t.file2.fd == null) {
        std.debug.assert(t.file2.eof > 0);
        t.file2.fd = try openTempFile(t.sorter.db);
        t.file2.eof = 0;
    }
    incr.files[1].fd = t.file2.fd;
    incr.start_off = t.file2.eof;
    t.file2.eof += incr.mx_sz;
    try pmaReaderNext(t, p);
}

/// Port of vdbePmaReaderIncrInit(), single-threaded.
fn pmaReaderIncrInit(p: *PmaReader) Error!void {
    if (p.incr != null) try pmaReaderIncrMergeInit(p);
}

/// Port of vdbeMergeEngineLevel0(): a MergeEngine over `n_pma` level-0
/// PMAs of task.file, starting at `off`, which is moved past them.
fn mergeEngineLevel0(t: *SortSubtask, n_pma: u32, off: *i64) Error!*MergeEngine {
    const gpa = t.sorter.gpa;
    const m = try mergeEngineNew(gpa, n_pma);
    errdefer mergeEngineFree(gpa, m);
    var i_off = off.*;
    for (m.readers[0..n_pma]) |*r| {
        var n_dummy: i64 = 0;
        try pmaReaderInit(t, &t.file, i_off, r, &n_dummy);
        i_off = r.eof;
    }
    off.* = i_off;
    return m;
}

/// Port of vdbeSorterTreeDepth(): the depth of a tree of `n_pma` PMAs
/// with a fanout of SORTER_MAX_MERGE_COUNT, not counting the leaves.
fn treeDepth(n_pma: u32) u32 {
    var n_depth: u32 = 0;
    var n_div: i64 = max_merge_count;
    while (n_div < n_pma) {
        n_div *= max_merge_count;
        n_depth += 1;
    }
    return n_depth;
}

/// Port of vdbeSorterAddToTree(): add `leaf`, the `i_seq`th leaf, to the
/// merge tree of depth `n_depth` at `root`. Frees `leaf` on failure.
fn addToTree(t: *SortSubtask, n_depth: u32, i_seq: u32, root: *MergeEngine, leaf: *MergeEngine) Error!void {
    const gpa = t.sorter.gpa;
    const incr = try incrMergerNew(t, leaf);
    errdefer incrFree(gpa, incr);

    var n_div: u32 = 1;
    var i: u32 = 1;
    while (i < n_depth) : (i += 1) n_div *= max_merge_count;

    var p = root;
    i = 1;
    while (i < n_depth) : (i += 1) {
        const r = &p.readers[(i_seq / n_div) % max_merge_count];
        if (r.incr == null) {
            const new = try mergeEngineNew(gpa, max_merge_count);
            r.incr = try incrMergerNew(t, new);
        }
        p = r.incr.?.merger;
        n_div /= max_merge_count;
    }
    p.readers[i_seq % max_merge_count].incr = incr;
}

/// Port of vdbeSorterMergeTreeBuild(), single-threaded: the tree of
/// MergeEngine, IncrMerger and PmaReader objects that merges every PMA.
fn mergeTreeBuild(s: *Sorter) Error!*MergeEngine {
    const t = &s.task;
    const gpa = s.gpa;
    std.debug.assert(t.n_pma > 0);
    const n_depth = treeDepth(t.n_pma);
    var read_off: i64 = 0;
    if (t.n_pma <= max_merge_count) return mergeEngineLevel0(t, t.n_pma, &read_off);

    const root = try mergeEngineNew(gpa, max_merge_count);
    errdefer mergeEngineFree(gpa, root);
    var i: u32 = 0;
    var i_seq: u32 = 0;
    while (i < t.n_pma) : (i += max_merge_count) {
        const n_reader = @min(t.n_pma - i, max_merge_count);
        const merger = try mergeEngineLevel0(t, n_reader, &read_off);
        try addToTree(t, n_depth, i_seq, root, merger);
        i_seq += 1;
    }
    return root;
}

/// Port of vdbeSorterSetupMerge(), single-threaded: set up `merger` to
/// read every record in order.
fn setupMerge(s: *Sorter) Error!void {
    // As in a build with worker threads, the comparator is picked again.
    s.task.cmp = getCompare(s);
    const main = try mergeTreeBuild(s);
    s.merger = main;
    try mergeEngineInit(&s.task, main);
}

// ============================================================= interface

/// Port of sqlite3VdbeSorterInit(). If `n_field` is not zero, a stable
/// sort on that many leading fields is enough.
pub fn init(db: *int.Sqlite3, n_field: i32, c: *VdbeCursor) Error!void {
    const gpa = db.gpa;
    const ki = c.key_info.?;
    const s = try gpa.create(Sorter);
    errdefer gpa.destroy(s);
    const n_cells = @as(usize, ki.n_all_field) + 1;
    const cells = try gpa.alloc(Mem, n_cells);
    @import("aux.zig").initMemArray(cells, db, .{ .Null = true });

    // A connection without a main b-tree (hand-built test programs) does
    // not spill.
    const main_bt = if (db.dbs.items.len > 0) db.dbs.items[0].bt else null;
    const pgsz: u32 = if (main_bt) |bt| bt.getPageSize() else 4096;
    s.* = .{
        .gpa = gpa,
        .db = db,
        .pgsz = pgsz,
        .key_info = ki.*,
        .cells = cells,
        .task = .{ .sorter = s, .unpacked = undefined },
    };
    // Without worker threads, the sort may stop at n_field fields.
    if (n_field != 0) s.key_info.n_key_field = @intCast(n_field);
    s.task.unpacked = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = s.key_info.n_key_field };

    if (main_bt != null and !tempInMemory(db)) {
        s.mn_pma_size = sorter_pmasz * pgsz;
        var mx_cache: i64 = db.dbs.items[0].schema.cache_size;
        if (mx_cache < 0) {
            // A negative cache size is in KiB.
            mx_cache = mx_cache * -1024;
        } else {
            mx_cache = mx_cache * pgsz;
        }
        mx_cache = @min(mx_cache, max_pmasz);
        s.mx_pma_size = @max(s.mn_pma_size, mx_cache);
        // C starts list.aMemory at a page.
        s.data.ensureTotalCapacity(gpa, pgsz) catch {};
    }

    s.norm_desc = ki.sort_flags[0] & int.KeyInfoOrder.desc != 0;
    s.norm_bignull = ki.sort_flags[0] & int.KeyInfoOrder.bignull != 0;
    s.norm_on = serial.isBinary(ki.coll[0]);
    if (ki.n_all_field < 13 and serial.isBinary(ki.coll[0]) and
        ki.sort_flags[0] & int.KeyInfoOrder.bignull == 0)
    {
        s.type_mask = type_integer | type_text | type_real;
    }
    c.uc = .{ .sorter = s };
}

/// Port of vdbeSortSubtaskCleanup().
fn subtaskCleanup(t: *SortSubtask) void {
    if (t.file.fd) |fd| fd.close();
    if (t.file2.fd) |fd| fd.close();
    t.file = .{};
    t.file2 = .{};
    t.n_pma = 0;
    t.n_spill = 0;
    t.unpacked.err = null;
}

/// Port of sqlite3VdbeSorterReset(): drop every record and PMA.
pub fn reset(db: *int.Sqlite3, c: *VdbeCursor) void {
    _ = db;
    const s = get(c);
    if (s.merger) |m| mergeEngineFree(s.gpa, m);
    s.merger = null;
    subtaskCleanup(&s.task);
    listClear(s);
    s.sz_pma = 0;
    s.use_pma = false;
    s.i_memory = 0;
    s.mx_keysize = 0;
}

/// Port of sqlite3VdbeSorterClose().
pub fn close(db: *int.Sqlite3, c: *VdbeCursor) void {
    reset(db, c);
    const s = get(c);
    s.data.deinit(s.gpa);
    s.records.deinit(s.gpa);
    s.norms.deinit(s.gpa);
    s.links.deinit(s.gpa);
    s.gpa.free(s.cells);
    s.gpa.destroy(s);
    c.uc = .none;
}

/// Bit position of the class of the first field in a normalized key.
const norm_class_shift = 61;

/// The normalized key of the record `z` (not in C): a u64 such that
/// normKey(a) < normKey(b) implies that `a` sorts before `b`. Its top 3
/// bits rank the type of the first field as the comparison does (NULL,
/// numbers, text, blob, then NULL again for KEYINFO_ORDER_BIGNULL), the
/// other 61 bits order the values of a type as far as they can, and the
/// whole is inverted for DESC. Null if the first field cannot be mapped
/// (a NaN or a malformed record).
fn normKey(s: *const Sorter, z: []const u8) ?u64 {
    if (z.len < 2) return null;
    const hdr = record_fmt.getVarint32(z, 0);
    const ty = record_fmt.getVarint32(z, hdr.len);
    if (hdr.value > z.len or hdr.len + ty.len > hdr.value) return null;
    const p = z[hdr.value..];
    const t = ty.value;
    const norm: u64 = switch (t) {
        0 => if (s.norm_bignull) 4 << norm_class_shift else 0,
        1...6, 8, 9 => blk: {
            const sizes = [_]u8{ 0, 1, 2, 3, 4, 6, 8 };
            const n: usize = if (t <= 6) sizes[t] else 0;
            if (p.len < n) return null;
            var i: i64 = if (t == 9) 1 else 0;
            if (n > 0) {
                var u: u64 = 0;
                for (p[0..n]) |b| u = u << 8 | b;
                // Sign-extend from n bytes.
                const shift: u6 = @intCast(64 - 8 * n);
                i = @as(i64, @bitCast(u << shift)) >> shift;
            }
            break :blk numberKey(@floatFromInt(i));
        },
        7 => blk: {
            if (p.len < 8) return null;
            const r: f64 = @bitCast(std.mem.readInt(u64, p[0..8], .big));
            if (std.math.isNan(r)) return null;
            break :blk numberKey(r);
        },
        10, 11 => return null,
        else => blk: {
            const n = (t - 12) / 2;
            if (p.len < n) return null;
            break :blk bytesKey(if (t & 1 == 0) 3 else 2, p[0..n]);
        },
    };
    return if (s.norm_desc) ~norm else norm;
}

/// The normalized key of a number: integers and reals are both mapped
/// through the double (round to nearest is monotonic, so it never
/// reverses the exact comparison of an integer and a real), to an
/// unsigned integer that orders as the double, of which the top 61 bits
/// are kept.
fn numberKey(r: f64) u64 {
    const bits: u64 = @bitCast(if (r == 0) 0.0 else r); // -0.0 is 0.0
    const ordered = if (bits >> 63 != 0) ~bits else bits | 1 << 63;
    return 1 << norm_class_shift | ordered >> 3;
}

/// The normalized key of a text or blob: its first 7 bytes and its length
/// up to 8, so that a value sorts before its extensions with zero bytes.
fn bytesKey(class: u64, b: []const u8) u64 {
    var prefix: [8]u8 = @splat(0);
    const n = @min(b.len, 7);
    @memcpy(prefix[0..n], b[0..n]);
    const p56 = std.mem.readInt(u64, &prefix, .big) >> 8;
    return class << norm_class_shift | p56 << 5 | @min(b.len, 8);
}

/// Port of sqlite3VdbeSorterWrite(): add the record in `m`, first writing
/// the in-memory records to a PMA if it would not fit.
pub fn write(c: *VdbeCursor, m: *const Mem) Error!void {
    const s = get(c);
    const z = m.bytes();
    // The serial type of the first field narrows the fast comparators.
    const t = record_fmt.getVarint32(z, 1).value;
    if (t > 0 and t < 10) {
        s.type_mask &= if (t == 7) type_real else type_integer | type_real;
    } else if (t > 10 and t & 1 != 0) {
        s.type_mask &= type_text;
    } else {
        s.type_mask = 0;
    }

    // C's list.aMemory: flush if the list is not empty and the new record
    // would take it over mx_pma_size.
    const n: i64 = @intCast(z.len);
    const n_req = n + sizeof_sorter_record;
    const n_pma = n + varint.len(@intCast(n));
    if (s.mx_pma_size != 0) {
        if (s.i_memory != 0 and s.i_memory + n_req > s.mx_pma_size) {
            try flushPMA(s);
            s.sz_pma = 0;
            s.i_memory = 0;
        }
    }
    s.sz_pma += n_pma;
    if (n_pma > s.mx_keysize) s.mx_keysize = n_pma;
    if (s.mx_pma_size != 0) s.i_memory += std.mem.alignForward(i64, n_req, 8);

    const start = s.data.items.len;
    if (start + z.len > std.math.maxInt(u32)) return error.OutOfMemory;
    try s.records.ensureUnusedCapacity(s.gpa, 1);
    try s.data.appendSlice(s.gpa, z);
    if (s.norm_on) {
        try s.norms.ensureUnusedCapacity(s.gpa, 1);
        const norm = if (s.norm_ok) normKey(s, z) else null;
        if (norm == null) s.norm_ok = false;
        if (s.norms.items.len > 0 and norm != s.norms.items[0]) s.norm_varied = true;
        s.norms.appendAssumeCapacity(norm orelse 0);
    }
    s.records.appendAssumeCapacity(.{ .start = @intCast(start), .end = @intCast(s.data.items.len) });
}

/// Port of sqlite3VdbeSorterRewind(): sort the records and move to the
/// first. Returns true if there are none.
pub fn rewind(c: *VdbeCursor) Error!bool {
    const s = get(c);
    // Nothing spilled: sort in memory.
    if (!s.use_pma) {
        if (s.records.items.len == 0) return true;
        s.cur = try sorterSort(&s.task);
        return false;
    }
    // Write the rest to a last PMA, which is never empty: write() always
    // adds a record after a flush.
    std.debug.assert(s.records.items.len > 0);
    std.debug.assert(s.merger == null);
    try flushPMA(s);
    try setupMerge(s);
    return false;
}

/// Port of sqlite3VdbeSorterNext(). Returns false at the end.
pub fn next(db: *int.Sqlite3, c: *VdbeCursor) Error!bool {
    _ = db;
    const s = get(c);
    if (s.use_pma) return !try mergeEngineStep(s.merger.?);
    s.cur = s.links.items[s.cur];
    return s.cur != end_of_list;
}

/// Port of vdbeSorterRowkey(): the current record.
fn currentKey(s: *const Sorter) []const u8 {
    if (s.use_pma) {
        const m = s.merger.?;
        return m.readers[m.tree[1]].key;
    }
    return s.record(s.cur);
}

/// Port of sqlite3VdbeSorterRowkey(): copy the current record into `out`.
pub fn rowkey(c: *VdbeCursor, out: *Mem) Error!void {
    const key = currentKey(get(c));
    mem.clearAndResize(out, key.len) catch return error.OutOfMemory;
    out.n = @intCast(key.len);
    out.setTypeFlag(.{ .Blob = true });
    @memcpy(out.z.?[0..key.len], key);
}

/// Port of sqlite3VdbeSorterCompare(): compare the first `n_key_col`
/// fields of the current record with the record in `val`. A NULL in the
/// current record compares as smaller.
pub fn compare(c: *VdbeCursor, val: *const Mem, n_key_col: i32) Error!i32 {
    const s = get(c);
    const key = currentKey(s);
    var r: UnpackedRecord = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = @intCast(n_key_col) };
    serial.recordUnpack(key, &r);
    for (s.cells[0..@min(r.n_field, @as(usize, @intCast(n_key_col)))]) |m| {
        if (m.flags.Null) return -1;
    }
    return serial.recordCompare(val.bytes(), &r);
}

// ================================================================== tests

const testing = std.testing;
const Conn = @import("../sql/sql_test.zig").Conn;

fn repeat(comptime ch: u8, comptime n: usize) [n]u8 {
    return @splat(ch);
}

/// A connection whose sorts spill early: 512-byte pages make the
/// smallest PMA 250 * 512 bytes. Table t has `n` rows of wide keys
/// with many duplicates.
fn openSpilling(c: *Conn, n: u32) !void {
    try c.open();
    errdefer c.close();
    try c.exec("PRAGMA page_size=512; PRAGMA cache_size=10");
    try c.exec("CREATE TABLE t(i INTEGER PRIMARY KEY, a INTEGER, b TEXT, m, pad)");
    var buf: [1200]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf,
        \\WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<{d})
        \\INSERT INTO t SELECT i, (i*7919)%331,
        \\  substr(CASE i%3 WHEN 0 THEN '{s}' WHEN 1 THEN '{s}' ELSE '{s}' END, 1, 60 + i%10*5) || (i%7),
        \\  CASE i%6 WHEN 0 THEN i%50 WHEN 1 THEN (i%50)+0.5 WHEN 2 THEN CAST(i%50 AS TEXT)
        \\    WHEN 3 THEN NULL WHEN 4 THEN 'K' || (i%40) ELSE 'k' || (i%40) END,
        \\  substr('{s}', 1, 40 + i%30)
        \\FROM s
    , .{ n, &repeat('a', 110), &repeat('b', 110), &repeat('c', 110), &repeat('p', 70) });
    try c.exec(sql);
}

/// Run `sql` spilling, then with temp_store=MEMORY, which sorts in memory;
/// the rows must be the same. Returns the number of PMAs written.
fn expectSameSpilled(c: *Conn, sql: []const u8) !u64 {
    try c.exec("PRAGMA temp_store=0");
    const before = c.db.n_pma_written;
    const spilled = try c.query(sql);
    defer testing.allocator.free(spilled);
    const n = c.db.n_pma_written - before;

    try c.exec("PRAGMA temp_store=2");
    const in_memory = try c.query(sql);
    defer testing.allocator.free(in_memory);
    try testing.expectEqual(before + n, c.db.n_pma_written);
    try c.exec("PRAGMA temp_store=0");
    testing.expectEqualStrings(in_memory, spilled) catch |err| {
        std.debug.print("query: {s}\n", .{sql});
        return err;
    };
    return n;
}

/// PRAGMA integrity_check, with a cache big enough to make it quick.
fn expectIntegrity(c: *Conn) !void {
    try c.exec("PRAGMA cache_size=-2000");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    try c.exec("PRAGMA cache_size=10");
}

test "sorter: ORDER BY spills and keeps the order of equal keys" {
    var c: Conn = undefined;
    try openSpilling(&c, 6000);
    defer c.close();
    // Text keys with duplicates, ascending and descending.
    try testing.expect(try expectSameSpilled(&c, "SELECT b, i FROM t ORDER BY b") > 1);
    try testing.expect(try expectSameSpilled(&c, "SELECT b, i, pad FROM t ORDER BY b DESC") > 1);
    // Integer keys: rows of the same key come out by rowid.
    try testing.expect(try expectSameSpilled(&c, "SELECT a, i, pad FROM t ORDER BY a") > 1);
    // Mixed types, and a collation.
    try testing.expect(try expectSameSpilled(&c, "SELECT m, i, pad FROM t ORDER BY m") > 1);
    try testing.expect(try expectSameSpilled(&c, "SELECT m, i, pad FROM t ORDER BY m COLLATE NOCASE DESC, a") > 1);
    try testing.expect(try expectSameSpilled(&c, "SELECT m, b, i FROM t ORDER BY 1 COLLATE NOCASE, 2 DESC") > 1);

    // Ties are in insertion order.
    const rows = try c.query("SELECT a, i, pad FROM t ORDER BY a");
    defer testing.allocator.free(rows);
    var it = std.mem.tokenizeScalar(u8, rows, '\n');
    var prev_a: i64 = -1;
    var prev_i: i64 = -1;
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        var f = std.mem.splitScalar(u8, line, '|');
        const a = try std.fmt.parseInt(i64, f.next().?, 10);
        const i = try std.fmt.parseInt(i64, f.next().?, 10);
        try testing.expect(a > prev_a or (a == prev_a and i > prev_i));
        prev_a = a;
        prev_i = i;
    }
    try testing.expectEqual(@as(usize, 6000), n);
}

test "sorter: GROUP BY, DISTINCT and LIMIT spill" {
    var c: Conn = undefined;
    try openSpilling(&c, 6000);
    defer c.close();
    try testing.expect(try expectSameSpilled(&c, "SELECT b, count(*), sum(i), max(pad) FROM t GROUP BY b") > 1);
    try testing.expect(try expectSameSpilled(&c, "SELECT m, count(*), group_concat(i) FROM t GROUP BY m") > 1);
    try testing.expect(try expectSameSpilled(&c, "SELECT DISTINCT b, a % 7 FROM t ORDER BY b") > 1);
    _ = try expectSameSpilled(&c, "SELECT count(*) FROM (SELECT DISTINCT b, pad FROM t)");
    try testing.expect(try expectSameSpilled(&c, "SELECT b, count(*) FROM t GROUP BY b ORDER BY b LIMIT 5 OFFSET 40") > 1);
    _ = try expectSameSpilled(&c, "SELECT b, i FROM t ORDER BY b LIMIT 10 OFFSET 3000");
    _ = try expectSameSpilled(&c, "SELECT a, i, pad FROM t ORDER BY a DESC LIMIT 2500");
}

test "sorter: CREATE INDEX spills" {
    var c: Conn = undefined;
    try openSpilling(&c, 6000);
    defer c.close();
    const before = c.db.n_pma_written;
    try c.exec("CREATE INDEX t_b ON t(b, pad)");
    try c.exec("CREATE INDEX t_m ON t(m COLLATE NOCASE DESC, a)");
    try c.exec("CREATE UNIQUE INDEX t_u ON t(b, i, pad)");
    try testing.expect(c.db.n_pma_written - before > 3);
    try c.expectRows("SELECT count(*) FROM t INDEXED BY t_b WHERE b > ''", "6000\n");
    // Duplicates found while merging PMAs.
    try c.expectError("CREATE UNIQUE INDEX t_bad ON t(b, pad)", "UNIQUE constraint failed: t.b, t.pad");
    try c.expectError("CREATE UNIQUE INDEX t_bad ON t(m COLLATE NOCASE)", "UNIQUE constraint failed: t.m");
    try expectIntegrity(&c);
}

/// The index `idx` on `cols` must hold the rows in the order a sort by
/// `cols` and the rowid gives.
fn expectIndexOrder(c: *Conn, idx: []const u8, cols: []const u8) !void {
    var buf: [400]u8 = undefined;
    const by_index = try c.query(try std.fmt.bufPrint(&buf, "SELECT {s}, i FROM t INDEXED BY {s} ORDER BY {s}", .{ cols, idx, cols }));
    defer testing.allocator.free(by_index);
    const by_sort = try c.query(try std.fmt.bufPrint(&buf, "SELECT {s}, i FROM t NOT INDEXED ORDER BY {s}, i", .{ cols, cols }));
    defer testing.allocator.free(by_sort);
    try testing.expectEqualStrings(by_sort, by_index);
}

test "sorter: more PMAs than one merge takes" {
    var c: Conn = undefined;
    try openSpilling(&c, 16000);
    defer c.close();
    try testing.expect(try expectSameSpilled(&c, "SELECT b, i, pad FROM t ORDER BY b") > max_merge_count);
    try testing.expect(try expectSameSpilled(&c, "SELECT a, b, pad, i FROM t ORDER BY a DESC") > max_merge_count);
    try testing.expect(try expectSameSpilled(&c, "SELECT b, count(*), sum(i) FROM (SELECT b, i, pad FROM t UNION ALL SELECT b, i, pad FROM t) GROUP BY b, pad") > max_merge_count);
    const before = c.db.n_pma_written;
    try c.exec("CREATE INDEX t_ab ON t(a, b, pad)");
    try testing.expect(c.db.n_pma_written - before > max_merge_count);
    try expectIndexOrder(&c, "t_ab", "a, b, pad");
}

test "sorter: tree depth" {
    try testing.expectEqual(@as(u32, 0), treeDepth(1));
    try testing.expectEqual(@as(u32, 0), treeDepth(16));
    try testing.expectEqual(@as(u32, 1), treeDepth(17));
    try testing.expectEqual(@as(u32, 1), treeDepth(256));
    try testing.expectEqual(@as(u32, 2), treeDepth(257));
}

test "sorter: normalized keys keep the order of the comparison" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // Values whose normalized keys tie or nearly tie: integers and reals
    // that the double cannot tell apart, -0.0, texts and blobs around the
    // 7-byte prefix, zero bytes. Each goes in twice, the second time in
    // reverse order, so that ties check the order of insertion.
    try c.exec(
        \\CREATE TABLE v(k INTEGER PRIMARY KEY, x);
        \\CREATE TABLE vals(x);
        \\INSERT INTO vals VALUES (NULL), (0), (-1), (1), (3), (3.0), (2.5),
        \\  (562949953421311), (562949953421312), (562949953421313),
        \\  (9007199254740992), (9007199254740993), (9007199254740992.0),
        \\  (9223372036854775807), (9223372036854775806), (-9223372036854775808),
        \\  (-9223372036854775807), (9.2233720368547758e18), (-9.2233720368547758e18),
        \\  (0.0), (-0.0), (0.5), (1e308), (-1e308), (1e-300), (-1e-300), (NULL),
        \\  (''), ('a'), ('a' || char(0)), ('A'), ('abc'), ('ABC'), ('abcdefg'), ('abcdefgg'),
        \\  ('abcdefgh'), ('abcdefgh' || char(0)), ('abcdefghi'), ('abcdefgi'), ('é'), ('Z'),
        \\  (x''), (x'00'), (x'0000'), (x'01'), (x'ff'), (x'00000000000000'),
        \\  (x'0000000000000000'), (x'000000000000000001'), (x'0000000000000001'),
        \\  (x'61626364656667'), (x'6162636465666768');
        \\INSERT INTO v(x) SELECT x FROM vals ORDER BY rowid;
        \\INSERT INTO v(x) SELECT x FROM vals ORDER BY rowid DESC;
        \\CREATE TABLE s(n INTEGER PRIMARY KEY, x, k);
    );
    // ORDER BY clause, then when two consecutive rows a and b are in
    // order: a NULL before a value, the values in order, equal values by k.
    const cases = [_][3][]const u8{
        .{ "x", "a.x IS NULL AND b.x IS NOT NULL", "a.x < b.x" },
        .{ "x DESC", "b.x IS NULL AND a.x IS NOT NULL", "b.x < a.x" },
        .{ "x NULLS LAST", "b.x IS NULL AND a.x IS NOT NULL", "a.x < b.x" },
        .{ "x DESC NULLS FIRST", "a.x IS NULL AND b.x IS NOT NULL", "b.x < a.x" },
        .{ "x COLLATE NOCASE", "a.x IS NULL AND b.x IS NOT NULL", "a.x < b.x COLLATE NOCASE" },
        .{ "x COLLATE NOCASE DESC", "b.x IS NULL AND a.x IS NOT NULL", "b.x < a.x COLLATE NOCASE" },
    };
    for (cases) |case| {
        var buf: [600]u8 = undefined;
        try c.exec("DELETE FROM s");
        try c.exec(try std.fmt.bufPrint(&buf, "INSERT INTO s(x, k) SELECT x, k FROM v ORDER BY {s}", .{case[0]}));
        const eq = if (std.mem.indexOf(u8, case[0], "NOCASE") != null) "a.x = b.x COLLATE NOCASE" else "a.x = b.x";
        const sql = try std.fmt.bufPrint(&buf,
            \\SELECT a.n FROM s a JOIN s b ON b.n = a.n + 1
            \\WHERE (({s}) OR ({s}) OR ((a.x IS NULL AND b.x IS NULL OR {s}) AND a.k < b.k)) IS NOT 1
        , .{ case[1], case[2], eq });
        c.expectRows(sql, "") catch |err| {
            std.debug.print("ORDER BY {s}\n", .{case[0]});
            return err;
        };
        try c.expectRows("SELECT count(*) = (SELECT count(*) FROM v) FROM s", "1\n");
    }
}
