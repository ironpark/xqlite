//! Byte loops sixteen bytes at a time (@Vector), for the text functions
//! and output paths that scan or rewrite long strings. Each gives exactly
//! what the byte-at-a-time loop it replaces gives; the tests below check
//! them against those loops.
const std = @import("std");
const ctype = @import("ctype.zig");

const lanes = 16;
const V = @Vector(lanes, u8);

/// The vector and lane mask a predicate of indexOfPred() works on.
pub const Bytes = V;
pub const Mask = @Vector(lanes, bool);

pub inline fn splat(c: u8) V {
    return @splat(c);
}

inline fn load(z: []const u8, i: usize) V {
    return z[i..][0..lanes].*;
}

/// A vector of another element type read from bytes. A bit cast of the
/// [N]u8 would be loaded a byte at a time; through an align(1) pointer
/// it is one vector load.
pub inline fn loadAs(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return @as(*align(1) const T, @ptrCast(bytes)).*;
}

/// The store of loadAs().
pub inline fn storeAs(comptime T: type, bytes: *[@sizeOf(T)]u8, v: T) void {
    @as(*align(1) T, @ptrCast(bytes)).* = v;
}

/// Lanes where the byte is a UTF-8 continuation byte (10xxxxxx).
inline fn cont(v: V) Mask {
    return (v & splat(0xc0)) == splat(0x80);
}

/// Count of true lanes over many blocks, summed in u8 lanes and widened
/// before they can wrap (cheaper than a reduction a block).
const Counter = struct {
    acc: V = @splat(0),
    rounds: u8 = 0,
    total: usize = 0,

    inline fn add(c: *Counter, m: Mask) void {
        c.acc +%= @intFromBool(m);
        c.rounds += 1;
        if (c.rounds == 255) c.flush();
    }

    inline fn flush(c: *Counter) void {
        c.total += @reduce(.Add, @as(@Vector(lanes, u16), c.acc));
        c.acc = @splat(0);
        c.rounds = 0;
    }

    inline fn sum(c: *Counter) usize {
        c.flush();
        return c.total;
    }
};

/// ctype.toUpper() or toLower() of every lane.
inline fn caseOf(v: V, comptime upper: bool) V {
    const lo: u8 = if (upper) 'a' else 'A';
    return @select(u8, (v >= splat(lo)) & (v <= splat(lo + 25)), v ^ splat(0x20), v);
}

/// `in` with ASCII letters made upper (`upper`) or lower case, into `out`
/// (at least as long; it may be `in` itself).
pub fn asciiCase(out: []u8, in: []const u8, comptime upper: bool) void {
    std.debug.assert(out.len >= in.len);
    var i: usize = 0;
    while (i + lanes <= in.len) : (i += lanes) out[i..][0..lanes].* = caseOf(load(in, i), upper);
    for (in[i..], out[i..in.len]) |c, *o| o.* = if (upper) ctype.toUpper(c) else ctype.toLower(c);
}

/// The hex digits of `in` (two per byte, high nibble first) into
/// out[0 .. 2 * in.len], in lower or upper case.
pub fn hexEncode(out: []u8, in: []const u8, comptime upper: bool) void {
    std.debug.assert(out.len >= 2 * in.len);
    const digits = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    const letter: u8 = if (upper) 'A' - '0' - 10 else 'a' - '0' - 10;
    const H = struct {
        inline fn hex(n: V) V {
            return n + splat('0') + @select(u8, n > splat(9), splat(letter), splat(0));
        }
    };
    var i: usize = 0;
    while (i + lanes <= in.len) : (i += lanes) {
        const v = load(in, i);
        out[2 * i ..][0 .. 2 * lanes].* = std.simd.interlace(.{ H.hex(v >> @splat(4)), H.hex(v & splat(0xf)) });
    }
    for (in[i..], i..) |c, k| {
        out[2 * k] = digits[c >> 4];
        out[2 * k + 1] = digits[c & 0xf];
    }
}

/// Decode the leading hex digit pairs (either case) of `in` into `out`,
/// sixteen digits at a time, as far as the first block with anything
/// else in it goes in whole pairs; returns the digits used (even). The
/// caller goes on from there one pair at a time.
pub fn hexDecodeBlocks(out: []u8, in: []const u8) usize {
    std.debug.assert(out.len >= in.len / 2);
    var i: usize = 0;
    while (i + lanes <= in.len) : (i += lanes) {
        const v = load(in, i);
        const digit = v -% splat('0');
        const letter = (v | splat(0x20)) -% splat('a');
        const is_digit = digit < splat(10);
        const val = @select(u8, is_digit, digit, letter +% splat(10));
        const pairs = std.simd.deinterlace(2, val);
        const bytes = (pairs[0] << @splat(4)) | pairs[1];
        const bad = !(is_digit | (letter < splat(6)));
        if (@reduce(.Or, bad)) {
            // The whole pairs before the first other character.
            const k = std.simd.firstTrue(bad).? / 2;
            const b: [lanes / 2]u8 = bytes;
            @memcpy(out[i / 2 ..][0..k], b[0..k]);
            return i + 2 * k;
        }
        out[i / 2 ..][0 .. lanes / 2].* = bytes;
    }
    return i;
}

/// Index of the first byte of `z` for which `pred` holds (given sixteen
/// bytes, the lanes where it does); z.len if none.
pub fn indexOfPred(z: []const u8, comptime pred: fn (V) Mask) usize {
    if (z.len < lanes) {
        // Padded with the first byte: a hit there is a hit at 0 anyway.
        if (z.len == 0) return 0;
        var short: [lanes]u8 = @splat(z[0]);
        @memcpy(short[0..z.len], z);
        return std.simd.firstTrue(pred(short)) orelse z.len;
    }
    var i: usize = 0;
    while (true) : (i += lanes) {
        // The last block overlaps the one before, whose bytes had no hit.
        if (i + lanes > z.len) i = z.len - lanes;
        const hit = pred(load(z, i));
        if (@reduce(.Or, hit)) return i + std.simd.firstTrue(hit).?;
        if (i + lanes == z.len) return z.len;
    }
}

/// Index of the first byte of `z` that is `a`, `b` or NUL; z.len if none.
pub fn indexOfAny2OrNul(z: []const u8, a: u8, b: u8) usize {
    var i: usize = 0;
    while (i + lanes <= z.len) : (i += lanes) {
        const v = load(z, i);
        const hit = (v == splat(a)) | (v == splat(b)) | (v == splat(0));
        if (@reduce(.Or, hit)) return i + std.simd.firstTrue(hit).?;
    }
    while (i < z.len and z[i] != a and z[i] != b and z[i] != 0) i += 1;
    return i;
}

/// Length of the common prefix of `a` and `b` ignoring ASCII case and
/// ending before a NUL in `a`: the first i < min(a.len, b.len) where
/// a[i] is NUL or toLower(a[i]) != toLower(b[i]), or that minimum.
pub fn noCasePrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const x = load(a, i);
        const stop = (x == splat(0)) | (caseOf(x, false) != caseOf(load(b, i), false));
        if (@reduce(.Or, stop)) return i + std.simd.firstTrue(stop).?;
    }
    while (i < n and a[i] != 0 and ctype.toLower(a[i]) == ctype.toLower(b[i])) i += 1;
    return i;
}

/// The first index below min(a.len, b.len) where `a` and `b` differ, or
/// null (std.mem.findDiff() without the length difference).
pub fn firstDiff(a: []const u8, b: []const u8) ?usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const ne = load(a, i) != load(b, i);
        if (@reduce(.Or, ne)) return i + std.simd.firstTrue(ne).?;
    }
    // Then eight bytes at a time as integers: in little-endian order the
    // first differing byte holds the lowest set bit of the difference.
    while (i + 8 <= n) : (i += 8) {
        const x = std.mem.readInt(u64, a[i..][0..8], .little) ^ std.mem.readInt(u64, b[i..][0..8], .little);
        if (x != 0) return i + @ctz(x) / 8;
    }
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return null;
}

/// std.mem.order(u8, a, b): bytes compared unsigned, then lengths.
pub fn order(a: []const u8, b: []const u8) std.math.Order {
    if (a.ptr != b.ptr) if (firstDiff(a, b)) |k| return std.math.order(a[k], b[k]);
    return std.math.order(a.len, b.len);
}

/// Bytes of `z` other than UTF-8 continuation bytes.
pub fn countNonCont(z: []const u8) usize {
    var c: Counter = .{};
    var i: usize = 0;
    while (i + lanes <= z.len) : (i += lanes) c.add(cont(load(z, i)));
    var n = c.sum();
    for (z[i..]) |x| n += @intFromBool(x & 0xc0 == 0x80);
    return z.len - n;
}

/// Whether byte `i` (> 0) of `z` belongs to the character before by the
/// rule of length() and substr() (tag-20260418-01): a continuation byte
/// right after a byte >= 0x80. A stray continuation byte after ASCII
/// starts a character of its own.
inline fn folded(z: []const u8, i: usize) bool {
    return z[i] & 0xc0 == 0x80 and z[i - 1] >= 0x80;
}

/// folded() of each lane of the block at `i` (> 0).
inline fn foldedBlock(z: []const u8, i: usize) Mask {
    return cont(load(z, i)) & (load(z, i - 1) >= splat(0x80));
}

/// Characters of `z` before its first NUL, as length() counts them
/// (folded()).
pub fn lengthChars(z: []const u8) usize {
    if (z.len == 0 or z[0] == 0) return 0;
    var c: Counter = .{};
    var k: usize = 1;
    while (k + lanes <= z.len and !@reduce(.Or, load(z, k) == splat(0))) : (k += lanes) c.add(foldedBlock(z, k));
    var n = c.sum();
    while (k < z.len and z[k] != 0) : (k += 1) n += @intFromBool(folded(z, k));
    return k - n;
}

/// The byte offset in `z` after `k` characters from offset `from` (a
/// character start), counted as length() does; the offset of the first
/// NUL, or z.len, if there are fewer. substr()'s walk to its start and
/// end.
pub fn skipChars(z: []const u8, from: usize, k: usize) usize {
    if (k == 0 or from == z.len or z[from] == 0) return from;
    // The k-th character start after the one at `from`.
    var need = k;
    var i = from + 1;
    while (i + lanes <= z.len) : (i += lanes) {
        const v = load(z, i);
        if (@reduce(.Or, v == splat(0))) break;
        const n = std.simd.countTrues(!foldedBlock(z, i));
        if (n >= need) break;
        need -= n;
    }
    while (i < z.len) : (i += 1) {
        if (z[i] == 0) return i;
        if (!folded(z, i)) {
            need -= 1;
            if (need == 0) return i;
        }
    }
    return z.len;
}

/// Characters of `z` (no NUL) as SQLITE_SKIP_UTF8() steps through them:
/// a byte >= 0xc0 takes the continuation bytes after it; any other byte,
/// a stray continuation byte too, is a character of its own. So a run of
/// continuation bytes counts as one character with the lead byte before
/// it, or one each after anything else.
pub fn countSkipUtf8(z: []const u8) usize {
    if (z.len == 0) return 0;
    // True while inside a run of continuation bytes that count one each
    // (the last byte was one); the vector blocks end outside one.
    var stray = z[0] & 0xc0 == 0x80;
    var n: usize = 1;
    var i: usize = 1;
    while (i < z.len) {
        if (!stray and i + lanes <= z.len) {
            const c = cont(load(z, i));
            // A continuation byte after ASCII starts a stray run; the
            // block goes one byte at a time then.
            if (!@reduce(.Or, c & (load(z, i - 1) < splat(0x80)))) {
                n += std.simd.countTrues(!c);
                i += lanes;
                continue;
            }
        }
        const end = @min(z.len, i + lanes);
        while (i < end) : (i += 1) {
            if (z[i] & 0xc0 == 0x80) {
                // Absorbed after a lead byte (directly or through the
                // run); counted after ASCII or in a stray run.
                stray = stray or z[i - 1] < 0x80;
                n += @intFromBool(stray);
            } else {
                n += 1;
                stray = false;
            }
        }
    }
    return n;
}

/// The leading sixteen-byte blocks of ASCII of `in` as UTF-16 units
/// (big- or little-endian) into `out`; returns the bytes of `in` used.
pub fn asciiToUtf16(in: []const u8, out: []u8, big: bool) usize {
    const native_big = @import("builtin").cpu.arch.endian() == .big;
    var i: usize = 0;
    while (i + lanes <= in.len) : (i += lanes) {
        const v = load(in, i);
        if (@reduce(.Max, v) >= 0x80) break;
        var w: @Vector(lanes, u16) = v;
        if (big != native_big) w = @byteSwap(w);
        storeAs(@Vector(lanes, u16), out[2 * i ..][0 .. 2 * lanes], w);
    }
    return i;
}

/// The leading blocks of sixteen UTF-16 units (big- or little-endian) of
/// `in` below 0x80 as bytes into `out`; returns the bytes of `in` used.
pub fn utf16ToAscii(in: []const u8, out: []u8, big: bool) usize {
    var i: usize = 0;
    while (i + 2 * lanes <= in.len) : (i += 2 * lanes) {
        const halves = std.simd.deinterlace(2, @as(@Vector(2 * lanes, u8), in[i..][0 .. 2 * lanes].*));
        const lo = if (big) halves[1] else halves[0];
        const hi = if (big) halves[0] else halves[1];
        if (@reduce(.Max, hi | (lo & splat(0x80))) != 0) break;
        out[i / 2 ..][0..lanes].* = lo;
    }
    return i;
}

const testing = std.testing;

/// Random text weighted to the bytes these loops treat specially.
fn randomText(rand: std.Random, buf: []u8) []u8 {
    const pool = [_]u8{ 'a', 'Z', 'q', '@', '[', '`', '{', 0x7f, 0x80, 0xbf, 0xc0, 0xc3, 0xe2, 0xf0, 0xff, 0x01 };
    const n = rand.uintLessThan(usize, buf.len);
    for (buf[0..n]) |*b| b.* = if (rand.boolean()) pool[rand.uintLessThan(usize, pool.len)] else rand.intRangeAtMost(u8, 1, 255);
    return buf[0..n];
}

test "simd: case, hex and searches equal their byte loops" {
    var prng = std.Random.DefaultPrng.init(0x51d);
    const rand = prng.random();
    var buf: [700]u8 = undefined;
    var other: [700]u8 = undefined;
    var out: [1400]u8 = undefined;
    var want: [1400]u8 = undefined;
    for (0..3000) |_| {
        const z = randomText(rand, &buf);
        inline for (.{ true, false }) |upper| {
            asciiCase(&out, z, upper);
            for (z, 0..) |c, i| want[i] = if (upper) ctype.toUpper(c) else ctype.toLower(c);
            try testing.expectEqualSlices(u8, want[0..z.len], out[0..z.len]);
            hexEncode(&out, z, upper);
            const digits = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
            for (z, 0..) |c, i| {
                want[2 * i] = digits[c >> 4];
                want[2 * i + 1] = digits[c & 0xf];
            }
            try testing.expectEqualSlices(u8, want[0 .. 2 * z.len], out[0 .. 2 * z.len]);
        }
        // Zero-free text, then now and then a NUL.
        for (z) |*c| c.* |= @intFromBool(c.* == 0);
        if (z.len > 0 and rand.uintLessThan(u8, 4) == 0) z[rand.uintLessThan(usize, z.len)] = 0;
        const a = if (z.len > 0 and rand.boolean()) z[rand.uintLessThan(usize, z.len)] else rand.int(u8);
        const b = rand.int(u8);
        var k: usize = 0;
        while (k < z.len and z[k] != a and z[k] != b and z[k] != 0) k += 1;
        try testing.expectEqual(k, indexOfAny2OrNul(z, a, b));
        const P = struct {
            fn pred(v: V) Mask {
                return (v < splat(0x20)) | (v == splat('"'));
            }
        };
        var q: usize = 0;
        while (q < z.len and z[q] >= 0x20 and z[q] != '"') q += 1;
        try testing.expectEqual(q, indexOfPred(z, P.pred));

        // Hex digits now and then broken by something else.
        var hx: [700]u8 = undefined;
        for (hx[0..z.len], z) |*h, c| h.* = if (rand.uintLessThan(u8, 40) == 0) c else "0123456789abcdefABCDEF"[rand.uintLessThan(usize, 22)];
        var bytes: [350]u8 = undefined;
        const used = hexDecodeBlocks(&bytes, hx[0..z.len]);
        try testing.expect(used % 2 == 0 and used <= z.len);
        for (0..used / 2) |j| {
            const want_b = try std.fmt.parseInt(u8, hx[2 * j ..][0..2], 16);
            try testing.expectEqual(want_b, bytes[j]);
        }
        // It stops at a pair with something else in it, or where no whole
        // block is left.
        const stopped = used + 2 <= z.len and !(std.ascii.isHex(hx[used]) and std.ascii.isHex(hx[used + 1]));
        try testing.expect(stopped or (used % 16 == 0 and used + 16 > z.len));

        // b: a copy of z with case flips and one change somewhere.
        const m = rand.uintLessThan(usize, buf.len);
        for (other[0..m], 0..) |*c, i| c.* = if (i < z.len) (if (rand.boolean()) ctype.toUpper(z[i]) else ctype.toLower(z[i])) else 'x';
        if (m > 0 and rand.boolean()) other[rand.uintLessThan(usize, m)] = rand.int(u8);
        var p: usize = 0;
        const lim = @min(z.len, m);
        while (p < lim and z[p] != 0 and ctype.toLower(z[p]) == ctype.toLower(other[p])) p += 1;
        try testing.expectEqual(p, noCasePrefix(z, other[0..m]));
        try testing.expectEqual(std.mem.order(u8, z, other[0..m]), order(z, other[0..m]));
        try testing.expectEqual(std.mem.order(u8, z, z[0 .. z.len / 2]), order(z, z[0 .. z.len / 2]));
        try testing.expectEqual(std.math.Order.eq, order(z, z));
    }
}

test "simd: character counts and walks equal their byte loops" {
    var prng = std.Random.DefaultPrng.init(0xc4a7);
    const rand = prng.random();
    var buf: [9000]u8 = undefined;
    for (0..400) |round| {
        const z = randomText(rand, if (round % 4 == 0) &buf else buf[0..300]);
        for (z) |*c| c.* |= @intFromBool(c.* == 0);

        var nc: usize = 0;
        for (z) |c| nc += @intFromBool(c & 0xc0 != 0x80);
        try testing.expectEqual(nc, countNonCont(z));

        // SQLITE_SKIP_UTF8() over the text.
        var n: usize = 0;
        var i: usize = 0;
        while (i < z.len) : (n += 1) {
            const c = z[i];
            i += 1;
            if (c >= 0xc0) while (i < z.len and z[i] & 0xc0 == 0x80) : (i += 1) {};
        }
        try testing.expectEqual(n, countSkipUtf8(z));

        // substr()'s walk: from a character start, k characters on, now and
        // then with a NUL to stop at.
        if (z.len > 0 and rand.uintLessThan(u8, 3) == 0) z[rand.uintLessThan(usize, z.len)] = 0;
        const from = blk: {
            var f: usize = 0;
            var steps = rand.uintLessThan(usize, 40);
            while (steps > 0 and f < z.len) : (steps -= 1) f = walk(z, f, 1);
            break :blk f;
        };
        for (0..8) |_| {
            const k = rand.uintLessThan(usize, z.len + 3);
            try testing.expectEqual(walk(z, from, k), skipChars(z, from, k));
        }
    }
    // More than 255 counted blocks.
    var many: [8192]u8 = undefined;
    for (&many, 0..) |*b, i| b.* = if (i % 2 == 0) 'a' else 0xc3;
    try testing.expectEqual(@as(usize, many.len), countNonCont(&many));
}

test "simd: length() counts characters as its byte loop did" {
    // The byte loop lengthFunc() had: a byte >= 0x80 takes the
    // continuation bytes after it.
    const reference = struct {
        fn count(z: []const u8) usize {
            var n: usize = 0;
            var i: usize = 0;
            while (i < z.len and z[i] != 0) : (n += 1) {
                const c = z[i];
                i += 1;
                if (c >= 0x80) while (i < z.len and z[i] & 0xc0 == 0x80) : (i += 1) {};
            }
            return n;
        }
    };
    var prng = std.Random.DefaultPrng.init(0x1e9);
    const rand = prng.random();
    var buf: [9000]u8 = undefined;
    // Mostly the bytes that matter: ASCII, continuation and lead bytes.
    const pool = [_]u8{ 'a', 'z', 0x7f, 0x80, 0xbf, 0xc3, 0xe2, 0xf0, 0xff, 0x01 };
    for (0..200) |_| {
        const n = rand.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = if (rand.boolean()) pool[rand.uintLessThan(usize, pool.len)] else rand.intRangeAtMost(u8, 1, 255);
        // Now and then a NUL, where length() stops.
        if (n > 0 and rand.uintLessThan(u8, 3) == 0) buf[rand.uintLessThan(usize, n)] = 0;
        try testing.expectEqual(reference.count(buf[0..n]), lengthChars(buf[0..n]));
    }
    // More than 255 vector rounds of folded bytes, so the u8 lane counts
    // are summed before they wrap.
    for (&buf, 0..) |*b, i| b.* = if (i % 2 == 0) 0xc3 else 0xa9;
    try testing.expectEqual(@as(usize, buf.len / 2), lengthChars(&buf));
}

/// substr()'s loop (tag-20260418-01), stopping at a NUL: the reference
/// for skipChars().
fn walk(z: []const u8, from: usize, k: usize) usize {
    var i = from;
    var left = k;
    while (left > 0 and i < z.len and z[i] != 0) : (left -= 1) {
        const c = z[i];
        i += 1;
        if (c >= 0x80) while (i < z.len and z[i] & 0xc0 == 0x80) : (i += 1) {};
    }
    return i;
}
