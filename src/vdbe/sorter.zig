//! The sorter used for ORDER BY, GROUP BY and CREATE INDEX (port of
//! vdbesort.c). Records are kept and sorted in memory; the PMA spilling and
//! worker threads of the C code are not ported.
//!
//! The sort is C's list merge sort, so rows with equal keys come out in
//! the same order as from SQLite: the order they were inserted.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const serial = @import("serial.zig");
const int = @import("../sql/sqlite_int.zig");

const Allocator = std.mem.Allocator;
const Mem = vi.Mem;
const MEM = vi.MEM;
const KeyInfo = vi.KeyInfo;
const UnpackedRecord = vi.UnpackedRecord;
const VdbeCursor = vi.VdbeCursor;

pub const Error = error{ OutOfMemory, Corrupt };

const Sorter = struct {
    gpa: Allocator,
    /// The cursor's KeyInfo, with n_key_field possibly reduced to the
    /// columns that decide the order.
    key_info: KeyInfo,
    /// The records, back to back.
    data: std.ArrayList(u8) = .empty,
    /// Start and end of each record in `data`, in insertion order until
    /// `rewind` sorts them.
    records: std.ArrayList(Span) = .empty,
    /// The record being read after `rewind`.
    pos: usize = 0,
    /// An unpacked record for comparisons.
    cells: []Mem,
    /// SORTER_TYPE_* bits: what every record's first field could be, for
    /// the fast comparators.
    type_mask: u8 = 0,
    /// The sorted order: indexes into `records`.
    order: std.ArrayList(u32) = .empty,

    const Span = struct { start: u32, end: u32 };

    fn record(s: *const Sorter, r: Span) []u8 {
        return s.data.items[r.start..r.end];
    }
};

fn get(c: *VdbeCursor) *Sorter {
    return @ptrCast(@alignCast(c.uc.sorter));
}

/// Port of sqlite3VdbeSorterInit(). If `n_field` is not zero, a stable
/// sort on that many leading fields is enough.
pub fn init(db: *int.Sqlite3, n_field: i32, c: *VdbeCursor) Error!void {
    const gpa = db.gpa;
    const ki = c.key_info.?;
    const s = try gpa.create(Sorter);
    errdefer gpa.destroy(s);
    const n_cells = @as(usize, ki.n_all_field) + 1;
    const cells = try gpa.alloc(Mem, n_cells);
    @import("aux.zig").initMemArray(cells, db, MEM.Null);
    s.* = .{ .gpa = gpa, .key_info = ki.*, .cells = cells };
    if (n_field != 0) s.key_info.n_key_field = @intCast(n_field);
    if (ki.n_all_field < 13 and serial.isBinary(ki.coll[0]) and
        ki.sort_flags[0] & int.KeyInfoOrder.bignull == 0)
    {
        s.type_mask = type_integer | type_text | type_real;
    }
    c.uc = .{ .sorter = s };
}

/// Port of sqlite3VdbeSorterReset(): drop every record.
pub fn reset(db: *int.Sqlite3, c: *VdbeCursor) void {
    _ = db;
    const s = get(c);
    s.data.clearRetainingCapacity();
    s.records.clearRetainingCapacity();
    s.order.clearRetainingCapacity();
    s.pos = 0;
}

/// Port of sqlite3VdbeSorterClose().
pub fn close(db: *int.Sqlite3, c: *VdbeCursor) void {
    reset(db, c);
    const s = get(c);
    s.data.deinit(s.gpa);
    s.records.deinit(s.gpa);
    s.order.deinit(s.gpa);
    s.gpa.free(s.cells);
    s.gpa.destroy(s);
    c.uc = .none;
}

/// Port of sqlite3VdbeSorterWrite(): add the record in `m`.
pub fn write(c: *VdbeCursor, m: *const Mem) Error!void {
    const s = get(c);
    const z = m.bytes();
    // The serial type of the first field narrows the fast comparators.
    const t = serial.getVarint32(z, 1).value;
    if (t > 0 and t < 10) {
        s.type_mask &= if (t == 7) type_real else type_integer | type_real;
    } else if (t > 10 and t & 1 != 0) {
        s.type_mask &= type_text;
    } else {
        s.type_mask = 0;
    }
    const start = s.data.items.len;
    if (start + m.bytes().len > std.math.maxInt(u32)) return error.OutOfMemory;
    try s.records.ensureUnusedCapacity(s.gpa, 1);
    try s.data.appendSlice(s.gpa, m.bytes());
    s.records.appendAssumeCapacity(.{ .start = @intCast(start), .end = @intCast(s.data.items.len) });
}

const type_integer: u8 = 0x01;
const type_text: u8 = 0x02;
const type_real: u8 = 0x04;

/// No next record in a sort list.
const end_of_list = std.math.maxInt(u32);

/// SortSubtask during a sort: the comparator and the cached unpacked key.
const Sort = struct {
    s: *Sorter,
    /// Next record of each list being merged (SorterRecord.u.pNext).
    next: []u32,
    cmp: *const fn (st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32,
    unpacked: UnpackedRecord,

    /// Port of vdbeSorterGetCompare().
    fn init(s: *Sorter, links: []u32) Sort {
        const mask = s.type_mask;
        return .{
            .s = s,
            .next = links,
            .cmp = if (mask & type_integer != 0)
                compareInt
            else if (mask & type_text != 0)
                compareText
            else if (mask & type_real != 0)
                compareReal
            else
                compareGeneral,
            .unpacked = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = s.key_info.n_key_field },
        };
    }

    fn unpackKey2(st: *Sort, key2_cached: *bool, key2: []const u8) void {
        if (!key2_cached.*) {
            st.unpacked.n_field = st.s.key_info.n_key_field;
            serial.recordUnpack(key2, &st.unpacked);
            key2_cached.* = true;
        }
    }

    /// Port of vdbeSorterCompare().
    fn compareGeneral(st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
        st.unpackKey2(key2_cached, key2);
        return serial.recordCompare(key1, &st.unpacked);
    }

    /// Port of vdbeSorterCompareTail(): the first fields are equal.
    fn compareTail(st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
        st.unpackKey2(key2_cached, key2);
        return serial.recordCompareWithSkip(key1, &st.unpacked, true);
    }

    /// The end of the fast comparators: break ties on the first field with
    /// the rest, or apply DESC.
    fn finish(st: *Sort, res: i32, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
        if (res == 0) {
            if (st.s.key_info.n_key_field > 1) return st.compareTail(key2_cached, key1, key2);
            return 0;
        }
        return if (st.s.key_info.sort_flags[0] != 0) -res else res;
    }

    /// Port of vdbeSorterCompareText(): both first fields are TEXT, BINARY.
    fn compareText(st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
        const n1 = serial.getVarint32(key1, 1).value;
        const n2 = serial.getVarint32(key2, 1).value;
        const len = (@min(n1, n2) - 13) / 2;
        const v1 = key1[key1[0]..][0..len];
        const v2 = key2[key2[0]..][0..len];
        var res: i32 = switch (std.mem.order(u8, v1, v2)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
        if (res == 0) res = @as(i32, @intCast(n1)) - @as(i32, @intCast(n2));
        return st.finish(res, key2_cached, key1, key2);
    }

    /// Port of vdbeSorterCompareInt(): both first fields are integers.
    fn compareInt(st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
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
        return st.finish(res, key2_cached, key1, key2);
    }

    /// vdbeSorterGetReal(): the first field, a REAL or an integer.
    fn getReal(p: []const u8) f64 {
        var m: Mem = .{};
        serial.serialGet(p, p[0], p[1], &m);
        return if (p[1] == 7) m.u.r else @floatFromInt(m.u.i);
    }

    /// Port of vdbeSorterCompareReal() and vdbeSorterCompareRealInt().
    fn compareReal(st: *Sort, key2_cached: *bool, key1: []const u8, key2: []const u8) i32 {
        // 64-bit integers do not convert to doubles exactly.
        if ((key1[1] != 7 or key2[1] != 7) and (key1[1] == 6 or key2[1] == 6)) {
            return st.compareGeneral(key2_cached, key1, key2);
        }
        const r1 = getReal(key1);
        const r2 = getReal(key2);
        const res: i32 = if (r1 < r2) -1 else if (r1 > r2) 1 else 0;
        return st.finish(res, key2_cached, key1, key2);
    }

    /// Port of vdbeSorterMerge(): merge two sorted lists, taking from `p1`
    /// on ties.
    fn merge(st: *Sort, p1_arg: u32, p2_arg: u32) u32 {
        var p1 = p1_arg;
        var p2 = p2_arg;
        var first: u32 = end_of_list;
        var tail: ?*u32 = null;
        var key2_cached = false;
        while (true) {
            const res = st.cmp(st, &key2_cached, st.s.record(st.s.records.items[p1]), st.s.record(st.s.records.items[p2]));
            const take = if (res <= 0) p1 else p2;
            if (tail) |t| t.* = take else first = take;
            tail = &st.next[take];
            if (res <= 0) {
                p1 = st.next[p1];
                if (p1 == end_of_list) {
                    tail.?.* = p2;
                    break;
                }
            } else {
                p2 = st.next[p2];
                key2_cached = false;
                if (p2 == end_of_list) {
                    tail.?.* = p1;
                    break;
                }
            }
        }
        return first;
    }
};

/// Port of sqlite3VdbeSorterRewind() and vdbeSorterSort(): sort the records
/// and move to the first. Returns true if there are none.
pub fn rewind(c: *VdbeCursor) Error!bool {
    const s = get(c);
    const n = s.records.items.len;
    s.pos = 0;
    s.order.clearRetainingCapacity();
    if (n == 0) return true;
    const links = try s.gpa.alloc(u32, n);
    defer s.gpa.free(links);
    var st: Sort = .init(s, links);

    // The C list is newest first.
    var slots: [64]u32 = @splat(end_of_list);
    var k = n;
    while (k > 0) {
        k -= 1;
        var p: u32 = @intCast(k);
        links[p] = end_of_list;
        var i: usize = 0;
        while (slots[i] != end_of_list) : (i += 1) {
            p = st.merge(p, slots[i]);
            slots[i] = end_of_list;
        }
        slots[i] = p;
    }
    var p: u32 = end_of_list;
    for (slots) |slot| {
        if (slot == end_of_list) continue;
        p = if (p == end_of_list) slot else st.merge(p, slot);
    }
    if (st.unpacked.err_code != 0) {
        return if (st.unpacked.err_code == int.RC.NOMEM) error.OutOfMemory else error.Corrupt;
    }
    try s.order.ensureTotalCapacity(s.gpa, n);
    while (p != end_of_list) : (p = links[p]) s.order.appendAssumeCapacity(p);
    return false;
}

/// Port of sqlite3VdbeSorterNext(). Returns false at the end.
pub fn next(db: *int.Sqlite3, c: *VdbeCursor) Error!bool {
    _ = db;
    const s = get(c);
    s.pos += 1;
    return s.pos < s.order.items.len;
}

/// Port of sqlite3VdbeSorterRowkey(): copy the current record into `out`.
pub fn rowkey(c: *VdbeCursor, out: *Mem) Error!void {
    const s = get(c);
    const key = s.record(s.records.items[s.order.items[s.pos]]);
    mem.clearAndResize(out, key.len) catch return error.OutOfMemory;
    out.n = @intCast(key.len);
    out.setTypeFlag(MEM.Blob);
    @memcpy(out.z.?[0..key.len], key);
}

/// Port of sqlite3VdbeSorterCompare(): compare the first `n_key_col`
/// fields of the current record with the record in `val`. A NULL in the
/// current record compares as smaller.
pub fn compare(c: *VdbeCursor, val: *const Mem, n_key_col: i32) Error!i32 {
    const s = get(c);
    const key = s.record(s.records.items[s.order.items[s.pos]]);
    var r: UnpackedRecord = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = @intCast(n_key_col) };
    serial.recordUnpack(key, &r);
    for (s.cells[0..@min(r.n_field, @as(usize, @intCast(n_key_col)))]) |m| {
        if (m.flags & MEM.Null != 0) return -1;
    }
    return serial.recordCompare(val.bytes(), &r);
}
