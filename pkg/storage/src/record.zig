//! The record format: how a row or index key is serialized into a b-tree
//! payload (the serial-type routines and sqlite3VdbeRecordCompare from
//! vdbeaux.c).
//!
//! A record is a header followed by a body:
//!
//!     varint  header size in bytes, including this varint
//!     varint  serial type of each column
//!     ...     the column values, in order
//!
//! Serial types: 0 NULL, 1-6 big-endian integers of 1/2/3/4/6/8 bytes,
//! 7 an IEEE 754 double, 8 and 9 the integers 0 and 1, N>=12 even a blob
//! of (N-12)/2 bytes, N>=13 odd a string of (N-13)/2 bytes. 10 and 11 are
//! reserved.
//!
//! Only the BINARY collating sequence is supported until the VDBE brings
//! collation functions.

const std = @import("std");
const varint = @import("varint.zig");
const btree = @import("btree/btree.zig");

const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub const Error = error{ Corrupt, OutOfMemory };

/// A column value. Text and blob slices point into the record they were
/// decoded from.
pub const Value = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// Bytes of data for a serial type (sqlite3VdbeSerialTypeLen).
pub fn serialTypeLen(serial_type: u64) u64 {
    return switch (serial_type) {
        0, 8, 9, 10, 11 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6, 7 => 8,
        else => (serial_type - 12) / 2,
    };
}

/// The serial type used to store `v` (sqlite3VdbeSerialType, file format
/// 4: integers 0 and 1 take no data bytes).
pub fn serialType(v: Value) u64 {
    return switch (v) {
        .null => 0,
        .int => |i| blk: {
            const u: u64 = if (i < 0) ~@as(u64, @bitCast(i)) else @intCast(i);
            if (u <= 127) {
                if (i == 0 or i == 1) break :blk @intCast(8 + i);
                break :blk 1;
            }
            if (u <= 32767) break :blk 2;
            if (u <= 8388607) break :blk 3;
            if (u <= 2147483647) break :blk 4;
            if (u <= 0x7fff_ffff_ffff) break :blk 5;
            break :blk 6;
        },
        .real => 7,
        .text => |t| t.len * 2 + 13,
        .blob => |b| b.len * 2 + 12,
    };
}

/// Size of the record encoding `values`.
pub fn encodedLen(values: []const Value) usize {
    var n_body: usize = 0;
    for (values) |v| n_body += @intCast(serialTypeLen(serialType(v)));
    return headerLen(values) + n_body;
}

/// The header size. The size varint counts itself (as in OP_MakeRecord).
fn headerLen(values: []const Value) usize {
    var n_types: usize = 0;
    for (values) |v| n_types += varint.len(serialType(v));
    if (n_types <= 126) return n_types + 1;
    const n_varint = varint.len(n_types);
    var n = n_types + n_varint;
    if (n_varint < varint.len(n)) n += 1;
    return n;
}

/// Encodes `values` into `out`, which must be `encodedLen(values)` bytes.
pub fn encode(values: []const Value, out: []u8) void {
    const hdr_len = headerLen(values);

    var h: usize = varint.put(out, hdr_len);
    var d: usize = hdr_len;
    for (values) |v| {
        const t = serialType(v);
        h += varint.put(out[h..], t);
        const n: usize = @intCast(serialTypeLen(t));
        switch (v) {
            .null => {},
            .int => |i| {
                const bytes: u64 = @bitCast(i);
                for (0..n) |k| out[d + k] = @truncate(bytes >> @intCast(8 * (n - 1 - k)));
            },
            .real => |r| std.mem.writeInt(u64, out[d..][0..8], @bitCast(r), .big),
            .text, .blob => |s| @memcpy(out[d..][0..n], s),
        }
        d += n;
    }
    std.debug.assert(h == hdr_len and d == out.len);
}

/// Encodes `values` at the start of `buf` and returns the record.
pub fn encodeBuf(values: []const Value, buf: []u8) []u8 {
    const out = buf[0..encodedLen(values)];
    encode(values, out);
    return out;
}

pub fn encodeAlloc(gpa: Allocator, values: []const Value) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, encodedLen(values));
    encode(values, out);
    return out;
}

/// A varint in a record header, with getVarint32's one-byte fast path.
fn headerVarint(hdr: []const u8) Error!varint.Decoded {
    if (hdr.len > 0 and hdr[0] < 0x80) return .{ .value = hdr[0], .len = 1 };
    return varint.getChecked(hdr) catch error.Corrupt;
}

/// Decodes the value of serial type `t` from `data` (sqlite3VdbeSerialGet).
/// A NaN real reads as NULL.
fn decodeValue(t: u64, data: []const u8) Value {
    return switch (t) {
        0, 10, 11 => .null,
        8 => .{ .int = 0 },
        9 => .{ .int = 1 },
        1, 2, 3, 4, 5, 6 => .{ .int = decodeInt(t, data) },
        7 => blk: {
            const r: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .big));
            break :blk if (std.math.isNan(r)) .null else .{ .real = r };
        },
        else => if (t & 1 == 1) .{ .text = data } else .{ .blob = data },
    };
}

/// Port of vdbeRecordDecodeInt(): a big-endian two's-complement integer.
fn decodeInt(t: u64, data: []const u8) i64 {
    const n: usize = @intCast(serialTypeLen(t));
    var v: u64 = if (data[0] & 0x80 != 0) std.math.maxInt(u64) else 0;
    for (data[0..n]) |b| v = (v << 8) | b;
    return @bitCast(v);
}

/// Decodes up to `out.len` columns of `record`. Returns the number of
/// columns decoded. Text and blob values point into `record`.
pub fn decode(record: []const u8, out: []Value) Error!usize {
    const hdr = try headerVarint(record);
    const hdr_len = hdr.value;
    if (hdr_len > record.len or hdr_len < hdr.len) return error.Corrupt;
    var h: usize = hdr.len;
    var d: u64 = hdr_len;
    var n: usize = 0;
    while (h < hdr_len and n < out.len) : (n += 1) {
        const t = try headerVarint(record[h..@intCast(hdr_len)]);
        h += t.len;
        const len = serialTypeLen(t.value);
        if (d + len > record.len) return error.Corrupt;
        out[n] = decodeValue(t.value, record[@intCast(d)..@intCast(d + len)]);
        d += len;
    }
    return n;
}

pub const SortOrder = enum { asc, desc };

/// How the keys of one index compare (KeyInfo): column count and sort
/// order. All text compares with BINARY.
pub const KeyInfo = struct {
    /// Allocates the unpacked copy of a packed key with many columns.
    gpa: Allocator,
    /// Sort order of each key column. Columns beyond the end sort
    /// ascending; the length is also the most columns a key may have
    /// (nAllField).
    sort_orders: []const SortOrder,

    pub fn btreeKeyInfo(ki: *const KeyInfo) btree.KeyInfo {
        return .init(ki, seekPacked);
    }

    /// btreeMoveto(): unpack the key once, then search with it.
    fn seekPacked(ki: *const KeyInfo, cur: *btree.Cursor, key: []const u8) btree.Error!Order {
        var stack: [16]Value = undefined;
        const n_all = ki.sort_orders.len;
        const values = if (n_all <= stack.len) stack[0..n_all] else try ki.gpa.alloc(Value, n_all);
        defer if (n_all > stack.len) ki.gpa.free(values);
        const n = try decode(key, values);
        if (n == 0) return error.Corrupt;
        const unpacked: UnpackedRecord = .{ .info = ki, .values = values[0..n] };
        return cur.indexMoveto(unpacked.indexKey());
    }
};

/// A search key (UnpackedRecord).
pub const UnpackedRecord = struct {
    info: *const KeyInfo,
    values: []const Value,
    /// Result when every column present in both keys is equal (default_rc):
    /// .eq for an exact search, .lt or .gt to land after or before all
    /// entries with this prefix.
    default_order: Order = .eq,

    pub fn indexKey(r: *const UnpackedRecord) btree.IndexKey {
        return .init(r, compareCtx);
    }

    fn compareCtx(r: *const UnpackedRecord, stored: []const u8) btree.CompareError!Order {
        return r.compare(stored);
    }

    /// Port of sqlite3VdbeRecordCompareWithSkip(): the order of the stored
    /// record relative to this key.
    pub fn compare(r: *const UnpackedRecord, stored: []const u8) Error!Order {
        if (stored.len == 0) return error.Corrupt;
        const hdr = try headerVarint(stored);
        const hdr_len = hdr.value;
        var idx: u64 = hdr.len;
        var d: u64 = hdr_len;
        if (d > stored.len) return error.Corrupt;

        for (r.values, 0..) |rhs, i| {
            if (idx >= hdr_len) return error.Corrupt;
            const tv = try headerVarint(stored[@intCast(idx)..@intCast(hdr_len)]);
            const t = tv.value;
            const len = serialTypeLen(t);
            if (d + len > stored.len) return error.Corrupt;
            if (rhs == .text and i >= r.info.sort_orders.len) return error.Corrupt;
            const lhs = decodeValue(t, stored[@intCast(d)..@intCast(d + len)]);
            var c = compareValues(lhs, t, rhs);
            if (c != .eq) {
                if (i < r.info.sort_orders.len and r.info.sort_orders[i] == .desc) c = c.invert();
                return c;
            }
            d += len;
            idx += tv.len;
            if (i + 1 == r.values.len) break;
            if (d > stored.len) break;
            // A stored key with fewer columns than the search key.
            if (idx >= hdr_len) return error.Corrupt;
        }
        return r.default_order;
    }
};

/// Compares a stored value (with its serial type) against a search value
/// the way sqlite3VdbeRecordCompareWithSkip does: NULLs first, then
/// numbers, text, and blobs.
fn compareValues(lhs: Value, t: u64, rhs: Value) Order {
    // Reserved type 11 sorts above numbers and below text and blobs.
    if (t == 11) return switch (rhs) {
        .int, .real, .null => .gt,
        .text, .blob => .lt,
    };
    switch (rhs) {
        .int => |ri| return switch (lhs) {
            // NULL, reserved type 10, or a NaN real.
            .null => .lt,
            .int => |li| std.math.order(li, ri),
            .real => |lr| intFloatCompare(ri, lr).invert(),
            .text, .blob => .gt,
        },
        .real => |rr| return switch (lhs) {
            // A stored NaN reads as NULL.
            .null => .lt,
            .int => |li| intFloatCompare(li, rr),
            .real => |lr| if (lr < rr) .lt else if (lr > rr) .gt else .eq,
            .text, .blob => .gt,
        },
        .text => |rs| return switch (lhs) {
            .null, .int, .real => .lt,
            .text => |ls| std.mem.order(u8, ls, rs),
            .blob => .gt,
        },
        .blob => |rb| return switch (lhs) {
            .blob => |lb| std.mem.order(u8, lb, rb),
            else => .lt,
        },
        .null => return switch (lhs) {
            .null => .eq,
            else => .gt,
        },
    }
}

/// Port of sqlite3IntFloatCompare(): order of an integer relative to a
/// double, exact for all values. NaN counts as NULL, below every integer.
pub fn intFloatCompare(i: i64, r: f64) Order {
    if (std.math.isNan(r)) return .gt;
    if (r < -9223372036854775808.0) return .gt;
    if (r >= 9223372036854775808.0) return .lt;
    const y: i64 = @intFromFloat(r);
    if (i < y) return .lt;
    if (i > y) return .gt;
    const fi: f64 = @floatFromInt(i);
    return if (fi < r) .lt else if (fi > r) .gt else .eq;
}

const testing = std.testing;

test "record: encode and decode round trip" {
    const values = [_]Value{
        .null,
        .{ .int = 0 },
        .{ .int = 1 },
        .{ .int = -1 },
        .{ .int = 300 },
        .{ .int = -8388608 },
        .{ .int = 1 << 40 },
        .{ .int = std.math.minInt(i64) },
        .{ .real = 3.25 },
        .{ .text = "hello" },
        .{ .blob = &.{ 0, 1, 2 } },
    };
    const rec = try encodeAlloc(testing.allocator, &values);
    defer testing.allocator.free(rec);
    var out: [values.len]Value = undefined;
    try testing.expectEqual(values.len, try decode(rec, &out));
    for (values, out) |want, got| {
        switch (want) {
            .text => |s| try testing.expectEqualStrings(s, got.text),
            .blob => |s| try testing.expectEqualSlices(u8, s, got.blob),
            else => try testing.expectEqual(want, got),
        }
    }
    // Serial types chosen like SQLite's.
    try testing.expectEqual(@as(u64, 8), serialType(.{ .int = 0 }));
    try testing.expectEqual(@as(u64, 2), serialType(.{ .int = 300 }));
    try testing.expectEqual(@as(u64, 3), serialType(.{ .int = -8388608 }));
    try testing.expectEqual(@as(u64, 23), serialType(.{ .text = "hello" }));
}

test "record: header longer than 127 bytes" {
    var values: [130]Value = undefined;
    for (&values, 0..) |*v, i| v.* = .{ .int = @intCast(i + 2) };
    const rec = try encodeAlloc(testing.allocator, &values);
    defer testing.allocator.free(rec);
    var out: [130]Value = undefined;
    try testing.expectEqual(@as(usize, 130), try decode(rec, &out));
    try testing.expectEqual(@as(i64, 131), out[129].int);
}

test "record: comparison order" {
    const ki: KeyInfo = .{ .gpa = testing.allocator, .sort_orders = &.{ .asc, .desc } };
    const rec = try encodeAlloc(testing.allocator, &.{ .{ .text = "b" }, .{ .int = 5 } });
    defer testing.allocator.free(rec);

    const Case = struct { key: []const Value, want: Order };
    const cases = [_]Case{
        .{ .key = &.{.{ .text = "a" }}, .want = .gt },
        .{ .key = &.{.{ .text = "c" }}, .want = .lt },
        .{ .key = &.{.{ .int = 99 }}, .want = .gt }, // text sorts after numbers
        .{ .key = &.{.{ .blob = "a" }}, .want = .lt }, // and before blobs
        .{ .key = &.{ .{ .text = "b" }, .{ .int = 4 } }, .want = .lt }, // descending column
        .{ .key = &.{ .{ .text = "b" }, .{ .int = 6 } }, .want = .gt },
        .{ .key = &.{ .{ .text = "b" }, .{ .real = 5.0 } }, .want = .eq },
        .{ .key = &.{.{ .text = "b" }}, .want = .eq }, // prefix: default order
    };
    for (cases) |cs| {
        const r: UnpackedRecord = .{ .info = &ki, .values = cs.key };
        try testing.expectEqual(cs.want, try r.compare(rec));
    }
    const r: UnpackedRecord = .{ .info = &ki, .values = &.{.{ .text = "b" }}, .default_order = .lt };
    try testing.expectEqual(Order.lt, try r.compare(rec));

    try testing.expectEqual(Order.lt, intFloatCompare(1, 1.5));
    try testing.expectEqual(Order.eq, intFloatCompare(2, 2.0));
    try testing.expectEqual(Order.gt, intFloatCompare(std.math.maxInt(i64), 9.2233720368547748e18));
}
