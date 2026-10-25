//! The sorter used for ORDER BY, GROUP BY and CREATE INDEX (port of
//! vdbesort.c). Records are kept and sorted in memory; the PMA spilling and
//! worker threads of the C code are not ported.
//!
//! The C sorter keeps records newest first and merge-sorts them, preferring
//! the newer record on ties; sorting a reversed list stably gives the same
//! order, which matters because SQLite emits rows with equal ORDER BY keys
//! in that order.

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
    c.uc = .{ .sorter = s };
}

/// Port of sqlite3VdbeSorterReset(): drop every record.
pub fn reset(db: *int.Sqlite3, c: *VdbeCursor) void {
    _ = db;
    const s = get(c);
    s.data.clearRetainingCapacity();
    s.records.clearRetainingCapacity();
    s.pos = 0;
}

/// Port of sqlite3VdbeSorterClose().
pub fn close(db: *int.Sqlite3, c: *VdbeCursor) void {
    reset(db, c);
    const s = get(c);
    s.data.deinit(s.gpa);
    s.records.deinit(s.gpa);
    s.gpa.free(s.cells);
    s.gpa.destroy(s);
    c.uc = .none;
}

/// Port of sqlite3VdbeSorterWrite(): add the record in `m`.
pub fn write(c: *VdbeCursor, m: *const Mem) Error!void {
    const s = get(c);
    const start = s.data.items.len;
    if (start + m.bytes().len > std.math.maxInt(u32)) return error.OutOfMemory;
    try s.records.ensureUnusedCapacity(s.gpa, 1);
    try s.data.appendSlice(s.gpa, m.bytes());
    s.records.appendAssumeCapacity(.{ .start = @intCast(start), .end = @intCast(s.data.items.len) });
}

const SortCtx = struct {
    s: *Sorter,
    failed: bool = false,

    /// vdbeSorterCompare(): key1 against key2 unpacked.
    fn lessThan(ctx: *SortCtx, a: Sorter.Span, b: Sorter.Span) bool {
        const s = ctx.s;
        var r: UnpackedRecord = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = s.key_info.n_key_field };
        serial.recordUnpack(s.record(b), &r);
        const res = serial.recordCompare(s.record(a), &r);
        if (r.err_code != 0) ctx.failed = true;
        return res < 0;
    }
};

/// Port of sqlite3VdbeSorterRewind(): sort the records and move to the
/// first. Returns true if there are none.
pub fn rewind(c: *VdbeCursor) Error!bool {
    const s = get(c);
    const items = s.records.items;
    std.mem.reverse(Sorter.Span, items);
    var ctx: SortCtx = .{ .s = s };
    std.sort.block(Sorter.Span, items, &ctx, SortCtx.lessThan);
    if (ctx.failed) return error.Corrupt;
    s.pos = 0;
    return items.len == 0;
}

/// Port of sqlite3VdbeSorterNext(). Returns false at the end.
pub fn next(db: *int.Sqlite3, c: *VdbeCursor) Error!bool {
    _ = db;
    const s = get(c);
    s.pos += 1;
    return s.pos < s.records.items.len;
}

/// Port of sqlite3VdbeSorterRowkey(): copy the current record into `out`.
pub fn rowkey(c: *VdbeCursor, out: *Mem) Error!void {
    const s = get(c);
    const key = s.record(s.records.items[s.pos]);
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
    const key = s.record(s.records.items[s.pos]);
    var r: UnpackedRecord = .{ .key_info = &s.key_info, .mem = s.cells.ptr, .n_field = @intCast(n_key_col) };
    serial.recordUnpack(key, &r);
    for (s.cells[0..@min(r.n_field, @as(usize, @intCast(n_key_col)))]) |m| {
        if (m.flags & MEM.Null != 0) return -1;
    }
    return serial.recordCompare(val.bytes(), &r);
}
