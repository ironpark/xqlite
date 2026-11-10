//! Text encoding conversion between UTF-8 and UTF-16 (port of the
//! translation loops of utf.c's sqlite3VdbeMemTranslate()). The engine
//! keeps text in the encoding of the database; values change encoding
//! when an interface or a function asks for another (mem.changeEncoding()).

const std = @import("std");
const simd = @import("xqlite_base").simd;
const vi = @import("vdbe_int.zig");
const utf8_trans1 = @import("../sql/func/func.zig").utf8_trans1;

const ENC = vi.ENC;

/// SQLITE_UTF16NATIVE.
pub const UTF16NATIVE: u8 = if (@import("builtin").cpu.arch.endian() == .little) ENC.UTF16LE else ENC.UTF16BE;

/// The size of the buffer translate() needs for `n` bytes of input,
/// with room for the terminator (one NUL byte for UTF-8, two for UTF-16).
pub fn maxLen(n: usize, desired: u8) usize {
    return if (desired == ENC.UTF8) 2 * n + 1 else 2 * n + 2;
}

/// Translate `in` (in encoding `from`) to `desired` into `out`, which
/// holds maxLen() bytes; returns the bytes written, not counting the
/// terminator, which is written too. UTF-16 input has an even length.
/// As SQLite without SQLITE_REPLACE_INVALID_UTF: malformed UTF-8 and
/// surrogates read as U+FFFD, unpaired UTF-16 surrogates are combined
/// with whatever follows.
pub fn translate(in: []const u8, from: u8, desired: u8, out: []u8) usize {
    std.debug.assert(from != desired);
    var o: usize = 0;
    var i: usize = 0;
    if (from == ENC.UTF8) {
        // READ_UTF8, WRITE_UTF16LE/BE.
        while (i < in.len) {
            if (in[i] < 0x80) {
                // A run of ASCII, sixteen bytes at a time.
                const run = simd.asciiToUtf16(in[i..], out[o..], desired == ENC.UTF16BE);
                i += run;
                o += 2 * run;
                if (i == in.len) break;
            }
            var c: u32 = in[i];
            i += 1;
            if (c >= 0xc0) {
                c = utf8_trans1[c - 0xc0];
                while (i < in.len and in[i] & 0xc0 == 0x80) {
                    c = (c << 6) +% (0x3f & in[i]);
                    i += 1;
                }
                if (c < 0x80 or c & 0xFFFFF800 == 0xD800) c = 0xFFFD;
            }
            var units: [4]u8 = undefined;
            var k: usize = 2;
            if (c <= 0xFFFF) {
                units[0] = @truncate(c);
                units[1] = @truncate(c >> 8);
            } else {
                units[0] = @truncate(((c >> 10) & 0x003F) +% (((c -% 0x10000) >> 10) & 0x00C0));
                units[1] = @truncate(0x00D8 +% (((c -% 0x10000) >> 18) & 0x03));
                units[2] = @truncate(c);
                units[3] = @truncate(0x00DC +% ((c >> 8) & 0x03));
                k = 4;
            }
            var j: usize = 0;
            while (j < k) : (j += 2) {
                if (desired == ENC.UTF16LE) {
                    out[o] = units[j];
                    out[o + 1] = units[j + 1];
                } else {
                    out[o] = units[j + 1];
                    out[o + 1] = units[j];
                }
                o += 2;
            }
        }
        out[o] = 0;
        out[o + 1] = 0;
        return o;
    }
    std.debug.assert(desired == ENC.UTF8);
    const big = from == ENC.UTF16BE;
    const n = in.len & ~@as(usize, 1);
    while (i < n) {
        if (unit(in, i, big) < 0x80) {
            // A run of units below 0x80, sixteen at a time.
            const run = simd.utf16ToAscii(in[i..n], out[o..], big);
            i += run;
            o += run / 2;
            if (i == n) break;
        }
        var c: u32 = unit(in, i, big);
        i += 2;
        if (c >= 0xd800 and c < 0xe000) {
            if (i < n) {
                const c2: u32 = unit(in, i, big);
                i += 2;
                c = (c2 & 0x03FF) + ((c & 0x003F) << 10) + (((c & 0x03C0) + 0x0040) << 10);
            }
        }
        o += writeUtf8(out[o..], c);
    }
    out[o] = 0;
    return o;
}

fn unit(in: []const u8, i: usize, big: bool) u32 {
    return if (big) @as(u32, in[i]) << 8 | in[i + 1] else @as(u32, in[i + 1]) << 8 | in[i];
}

/// WRITE_UTF8.
fn writeUtf8(out: []u8, c: u32) usize {
    if (c < 0x80) {
        out[0] = @truncate(c);
        return 1;
    } else if (c < 0x800) {
        out[0] = 0xC0 + @as(u8, @truncate((c >> 6) & 0x1F));
        out[1] = 0x80 + @as(u8, @truncate(c & 0x3F));
        return 2;
    } else if (c < 0x10000) {
        out[0] = 0xE0 + @as(u8, @truncate((c >> 12) & 0x0F));
        out[1] = 0x80 + @as(u8, @truncate((c >> 6) & 0x3F));
        out[2] = 0x80 + @as(u8, @truncate(c & 0x3F));
        return 3;
    }
    out[0] = 0xF0 + @as(u8, @truncate((c >> 18) & 0x07));
    out[1] = 0x80 + @as(u8, @truncate((c >> 12) & 0x3F));
    out[2] = 0x80 + @as(u8, @truncate((c >> 6) & 0x3F));
    out[3] = 0x80 + @as(u8, @truncate(c & 0x3F));
    return 4;
}

test "utf: UTF-8 to UTF-16 and back" {
    const s = "a\u{e9}\u{4e2d}\u{1f600}";
    var buf16: [64]u8 = undefined;
    const n16 = translate(s, ENC.UTF8, ENC.UTF16LE, &buf16);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 0xe9, 0, 0x2d, 0x4e, 0x3d, 0xd8, 0x00, 0xde }, buf16[0..n16]);
    var be: [64]u8 = undefined;
    const nbe = translate(s, ENC.UTF8, ENC.UTF16BE, &be);
    try std.testing.expectEqualSlices(u8, &.{ 0, 'a', 0, 0xe9, 0x4e, 0x2d, 0xd8, 0x3d, 0xde, 0x00 }, be[0..nbe]);
    var back: [64]u8 = undefined;
    const n8 = translate(buf16[0..n16], ENC.UTF16LE, ENC.UTF8, &back);
    try std.testing.expectEqualStrings(s, back[0..n8]);
    const n8b = translate(be[0..nbe], ENC.UTF16BE, ENC.UTF8, &back);
    try std.testing.expectEqualStrings(s, back[0..n8b]);
    // A lone continuation byte and an encoded surrogate read as U+FFFD.
    const n = translate("\xc3\xed\xa0\x80", ENC.UTF8, ENC.UTF16LE, &buf16);
    try std.testing.expectEqualSlices(u8, &.{ 0xfd, 0xff, 0xfd, 0xff }, buf16[0..n]);
}

test "utf: the ASCII runs translate as the character loop does" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0x7f16);
    const rand = prng.random();
    const pool = [_]u8{ 'a', 'Z', 0, 0x7f, 0x80, 0xbf, 0xc3, 0xa9, 0xe2, 0x82, 0xac, 0xed, 0xa0, 0xf0, 0x9f, 0xff };
    var in: [600]u8 = undefined;
    var got: [1300]u8 = undefined;
    var want: [1300]u8 = undefined;
    for (0..1500) |round| {
        const n = rand.uintLessThan(usize, in.len / 2) * 2;
        // Mostly ASCII, so that runs of sixteen occur.
        for (in[0..n]) |*b| b.* = if (rand.uintLessThan(u8, 8) != 0) rand.intRangeAtMost(u8, 0x20, 0x7e) else pool[rand.uintLessThan(usize, pool.len)];
        const z = in[0..n];
        if (round % 2 == 0) {
            // UTF-8 to UTF-16: pieces shorter than sixteen bytes, cut only
            // before a byte that is no continuation byte.
            inline for (.{ ENC.UTF16LE, ENC.UTF16BE }) |enc| {
                const g = translate(z, ENC.UTF8, enc, &got);
                var w: usize = 0;
                var start: usize = 0;
                var i: usize = 1;
                while (i <= n) : (i += 1) {
                    if (i == n or (z[i] & 0xc0 != 0x80 and i - start >= 1 + rand.uintLessThan(usize, 15))) {
                        w += translate(z[start..i], ENC.UTF8, enc, want[w..]);
                        start = i;
                    }
                }
                try testing.expectEqualSlices(u8, want[0..w], got[0..g]);
            }
        } else {
            // UTF-16 to UTF-8: pieces under sixteen units, cut only where
            // a unit does not pair with the one before it.
            inline for (.{ ENC.UTF16LE, ENC.UTF16BE }) |enc| {
                const big = enc == ENC.UTF16BE;
                const g = translate(z, enc, ENC.UTF8, &got);
                var w: usize = 0;
                var start: usize = 0;
                var i: usize = 0;
                while (i < n) {
                    const c = unit(z, i, big);
                    i += if (c >= 0xd800 and c < 0xe000 and i + 2 < n) 4 else 2;
                    if (i >= n or i - start >= 2 * (1 + rand.uintLessThan(usize, 15))) {
                        w += translate(z[start..@min(i, n)], enc, ENC.UTF8, want[w..]);
                        start = @min(i, n);
                    }
                }
                try testing.expectEqualSlices(u8, want[0..w], got[0..g]);
            }
        }
    }
}
