//! Sets of rowids for DELETE, UPDATE and OR-optimized WHERE loops (port of
//! rowset.c, with a sorted array and a hash set in place of the C forest).
//!
//! Rowids are either inserted and then read back in ascending order without
//! duplicates (`next`), or tested for membership in batches (`testBatch`):
//! a test sees only rowids inserted before the batch number last changed.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");

const Allocator = std.mem.Allocator;
const Mem = vi.Mem;
const MEM = vi.MEM;

pub const RowSet = struct {
    gpa: Allocator,
    /// Inserted since the last sort or batch change.
    pending: std.ArrayList(i64) = .empty,
    /// Sorted, distinct rowids being read by `next`.
    sorted: []i64 = &.{},
    pos: usize = 0,
    /// Rowids visible to `testBatch`.
    tested: std.AutoHashMapUnmanaged(i64, void) = .empty,
    batch: i32 = 0,
    /// `next` was called: no more inserts.
    reading: bool = false,

    pub fn create(gpa: Allocator) Allocator.Error!*RowSet {
        const r = try gpa.create(RowSet);
        r.* = .{ .gpa = gpa };
        return r;
    }

    pub fn destroy(r: *RowSet) void {
        r.pending.deinit(r.gpa);
        r.gpa.free(r.sorted);
        r.tested.deinit(r.gpa);
        r.gpa.destroy(r);
    }

    /// Port of sqlite3RowSetInsert().
    pub fn insert(r: *RowSet, rowid: i64) Allocator.Error!void {
        std.debug.assert(!r.reading);
        try r.pending.append(r.gpa, rowid);
    }

    /// Port of sqlite3RowSetNext(): the smallest rowid not yet returned.
    pub fn next(r: *RowSet) Allocator.Error!?i64 {
        if (!r.reading) {
            r.reading = true;
            const items = r.pending.items;
            std.mem.sort(i64, items, {}, std.sort.asc(i64));
            var n: usize = 0;
            for (items, 0..) |x, i| {
                if (i == 0 or x != items[n - 1]) {
                    items[n] = x;
                    n += 1;
                }
            }
            r.pending.shrinkRetainingCapacity(n);
            r.sorted = try r.pending.toOwnedSlice(r.gpa);
        }
        if (r.pos >= r.sorted.len) return null;
        r.pos += 1;
        return r.sorted[r.pos - 1];
    }

    /// Port of sqlite3RowSetTest(): whether `rowid` was inserted before
    /// batch `batch` began.
    pub fn testBatch(r: *RowSet, batch: i32, rowid: i64) Allocator.Error!bool {
        if (batch != r.batch) {
            try r.tested.ensureUnusedCapacity(r.gpa, @intCast(r.pending.items.len));
            for (r.pending.items) |x| r.tested.putAssumeCapacity(x, {});
            r.pending.clearRetainingCapacity();
            r.batch = batch;
        }
        return r.tested.contains(rowid);
    }
};

fn destructor(p: ?*anyopaque) void {
    const r: *RowSet = @ptrCast(@alignCast(p.?));
    r.destroy();
}

/// Port of sqlite3VdbeMemSetRowSet(): make `m` hold a new, empty RowSet.
pub fn memSetRowSet(m: *Mem, gpa: Allocator) Allocator.Error!void {
    const r = try RowSet.create(gpa);
    mem.release(m);
    m.z = @ptrCast(r);
    m.n = 0;
    m.flags = MEM.Blob | MEM.Dyn;
    m.x_del = destructor;
}

/// The RowSet of a register set by memSetRowSet().
pub fn fromMem(m: *Mem) *RowSet {
    return @ptrCast(@alignCast(m.z.?));
}

test "rowset: read and test" {
    const gpa = std.testing.allocator;
    const r = try RowSet.create(gpa);
    defer r.destroy();
    for ([_]i64{ 5, 3, 9, 3, 1 }) |x| try r.insert(x);
    var got: [4]i64 = undefined;
    for (&got) |*g| g.* = (try r.next()).?;
    try std.testing.expectEqualSlices(i64, &.{ 1, 3, 5, 9 }, &got);
    try std.testing.expectEqual(@as(?i64, null), try r.next());

    const t = try RowSet.create(gpa);
    defer t.destroy();
    try t.insert(7);
    try std.testing.expect(!try t.testBatch(0, 7));
    try std.testing.expect(try t.testBatch(1, 7));
    try t.insert(8);
    try std.testing.expect(!try t.testBatch(1, 8));
    try std.testing.expect(try t.testBatch(2, 8));
}
