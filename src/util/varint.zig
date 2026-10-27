//! SQLite variable-length integers (port of the varint routines in util.c).
//!
//! A varint is 1 to 9 bytes, big-endian. Each of the first 8 bytes carries
//! 7 bits of data with the high bit set when more bytes follow. A 9th byte,
//! if present, carries a full 8 bits.
//!
//!      7 bits - A
//!     14 bits - BA
//!     21 bits - BBA
//!     ...
//!     56 bits - BBBBBBBA
//!     64 bits - BBBBBBBBC
//!
//! A = 0xxxxxxx, B = 1xxxxxxx, C = xxxxxxxx

const std = @import("std");

/// Maximum encoded length of a varint.
pub const max_len = 9;

pub const Decoded = struct {
    value: u64,
    len: u8,
};

pub const Decoded32 = struct {
    value: u32,
    len: u8,
};

/// Encodes `v` into `buf` and returns the number of bytes written (1-9).
/// Port of sqlite3PutVarint(), with the one- and two-byte cases in line
/// (as the putVarint32() macro and sqlite3PutVarint() have them).
pub inline fn put(buf: []u8, v: u64) u8 {
    if (v <= 0x7f) {
        buf[0] = @intCast(v);
        return 1;
    }
    if (v <= 0x3fff) {
        buf[0] = @intCast(((v >> 7) & 0x7f) | 0x80);
        buf[1] = @intCast(v & 0x7f);
        return 2;
    }
    return put64(buf, v);
}

noinline fn put64(buf: []u8, value: u64) u8 {
    var v = value;
    if (v & (@as(u64, 0xff000000) << 32) != 0) {
        buf[8] = @truncate(v);
        v >>= 8;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            buf[i] = @as(u8, @truncate(v & 0x7f)) | 0x80;
            v >>= 7;
        }
        return 9;
    }
    var tmp: [10]u8 = undefined;
    var n: u8 = 0;
    while (true) {
        tmp[n] = @as(u8, @truncate(v & 0x7f)) | 0x80;
        n += 1;
        v >>= 7;
        if (v == 0) break;
    }
    tmp[0] &= 0x7f;
    std.debug.assert(n <= 9);
    for (0..n) |i| buf[i] = tmp[n - 1 - i];
    return n;
}

/// Decodes a varint from the start of `p`. Port of sqlite3GetVarint().
///
/// Like the C original, this does not bounds-check: `p` must contain a
/// complete varint (callers working on untrusted pages should guarantee at
/// least `max_len` readable bytes or use `getChecked`).
pub fn get(p: []const u8) Decoded {
    var key: u64 = p[0];
    if (key < 0x80) return .{ .value = key, .len = 1 };

    var x: u8 = p[1];
    key = (key << 7) ^ x;
    if (x < 0x80) return .{ .value = key ^ 0x4000, .len = 2 };

    x = p[2];
    key = (key << 7) ^ x;
    if (x < 0x80) return .{ .value = key ^ 0x204000, .len = 3 };

    x = p[3];
    key = (key << 7) ^ 0x10204000 ^ x;
    if (x < 0x80) return .{ .value = key, .len = 4 };

    var i: u8 = 4;
    while (i < 8) : (i += 1) {
        x = p[i];
        key = (key << 7) ^ 0x4000 ^ x;
        if (x < 0x80) return .{ .value = key, .len = i + 1 };
    }
    key = (key << 8) ^ 0x8000 ^ p[8];
    return .{ .value = key, .len = 9 };
}

/// Bounds-checked variant of `get` for data that may be truncated.
pub fn getChecked(p: []const u8) error{Truncated}!Decoded {
    if (p.len >= max_len) return get(p);
    var tmp: [max_len]u8 = @splat(0);
    @memcpy(tmp[0..p.len], p);
    const d = get(&tmp);
    if (d.len > p.len) return error.Truncated;
    return d;
}

/// Decodes a varint as a 32-bit value. Values that do not fit are clamped to
/// 0xffffffff. Port of sqlite3GetVarint32() including its 1-byte fast path.
pub fn get32(p: []const u8) Decoded32 {
    if (p[0] < 0x80) return .{ .value = p[0], .len = 1 };
    if (p[1] & 0x80 == 0) {
        return .{ .value = (@as(u32, p[0] & 0x7f) << 7) | p[1], .len = 2 };
    }
    if (p[2] & 0x80 == 0) {
        return .{
            .value = (@as(u32, p[0] & 0x7f) << 14) | (@as(u32, p[1] & 0x7f) << 7) | p[2],
            .len = 3,
        };
    }
    const d = get(p);
    return .{
        .value = std.math.cast(u32, d.value) orelse 0xffffffff,
        .len = d.len,
    };
}

/// Number of bytes needed to encode `v`. Port of sqlite3VarintLen(), with
/// the one-byte case in line.
pub inline fn len(v: u64) u8 {
    if (v < 0x80) return 1;
    return lenSlow(v);
}

fn lenSlow(v: u64) u8 {
    if (v > 0x00ff_ffff_ffff_ffff) return 9;
    var n: u8 = 1;
    var x = v >> 7;
    while (x != 0) : (x >>= 7) n += 1;
    return n;
}

const testing = std.testing;

fn roundTrip(v: u64) !void {
    var buf: [max_len]u8 = undefined;
    const n = put(&buf, v);
    try testing.expectEqual(len(v), n);
    const d = get(&buf);
    try testing.expectEqual(v, d.value);
    try testing.expectEqual(n, d.len);
    const c = try getChecked(buf[0..n]);
    try testing.expectEqual(v, c.value);
}

test "varint round trip at every length boundary" {
    var shift: u7 = 0;
    while (shift < 64) : (shift += 1) {
        const p = @as(u64, 1) << @intCast(shift);
        try roundTrip(p - 1);
        try roundTrip(p);
        try roundTrip(p + 1);
    }
    try roundTrip(0);
    try roundTrip(std.math.maxInt(u64));
    try roundTrip(@bitCast(@as(i64, -1)));
}

test "varint known encodings" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0x00}, buf[0..put(&buf, 0)]);
    try testing.expectEqualSlices(u8, &.{0x7f}, buf[0..put(&buf, 127)]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, buf[0..put(&buf, 128)]);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x7f }, buf[0..put(&buf, 0x3fff)]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x80, 0x00 }, buf[0..put(&buf, 0x4000)]);
    try testing.expectEqualSlices(
        u8,
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        buf[0..put(&buf, std.math.maxInt(u64))],
    );
}

test "varint get32 clamps" {
    var buf: [max_len]u8 = undefined;
    _ = put(&buf, 0x1_0000_0000);
    try testing.expectEqual(@as(u32, 0xffffffff), get32(&buf).value);
    _ = put(&buf, 0xdead_beef);
    try testing.expectEqual(@as(u32, 0xdead_beef), get32(&buf).value);
    _ = put(&buf, 200);
    try testing.expectEqual(Decoded32{ .value = 200, .len = 2 }, get32(&buf));
}

test "varint truncated input" {
    try testing.expectError(error.Truncated, getChecked(&.{ 0x81, 0x80 }));
    try testing.expectError(error.Truncated, getChecked(&.{}));
}

test "varint fuzz round trip" {
    try testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *testing.Smith) !void {
    while (!smith.eos()) try roundTrip(smith.value(u64));
}
