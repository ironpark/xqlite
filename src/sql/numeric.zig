//! Conversions between numbers and text (port of the floating-point and
//! integer rendering parts of util.c, plus sqlite3RealToI64() and
//! sqlite3RealSameAsInt() of vdbemem.c).
//!
//! Text to double (`atoF`) and double to decimal digits (`fpDecode`) use
//! SQLite's own algorithms rather than the C library, so results are the
//! same on every platform. Integer parsing lives in util.zig.

const std = @import("std");
const ctype = @import("../util/ctype.zig");

/// SQLITE_U64_DIGITS: the most decimal digits of a u64.
pub const u64_digits = 20;

const largest_uint64: u64 = std.math.maxInt(u64);
const smallest_int64: i64 = std.math.minInt(i64);
const largest_int64: i64 = std.math.maxInt(i64);

/// Port of sqlite3IsNaN().
pub fn isNaN(x: f64) bool {
    const y: u64 = @bitCast(x);
    const exp754: u64 = 0x7ff << 52;
    const man754: u64 = (1 << 52) - 1;
    return y & exp754 == exp754 and y & man754 != 0;
}

/// Port of sqlite3IsOverflow(): NaN or an infinity.
pub fn isOverflow(x: f64) bool {
    const y: u64 = @bitCast(x);
    const exp754: u64 = 0x7ff << 52;
    return y & exp754 == exp754;
}

// ============================================== 128- and 160-bit products

/// Port of sqlite3Multiply128(): the high 64 bits of a*b; the low 64 go
/// to `lo`.
fn multiply128(a: u64, b: u64, lo: *u64) u64 {
    const r = @as(u128, a) * b;
    lo.* = @truncate(r);
    return @intCast(r >> 64);
}

/// Port of sqlite3Multiply160(): A = (a<<32)+a_lo times b, keeping the
/// upper 96 bits of the 160-bit product: the top 64 are returned, the
/// next 32 go to `lo`.
fn multiply160(a: u64, a_lo: u32, b: u64, lo: *u32) u64 {
    var r = @as(u128, a) * b;
    r += (@as(u128, a_lo) * b) >> 32;
    lo.* = @truncate(r >> 32);
    return @intCast(r >> 64);
}

fn bit(n: anytype) u64 {
    return @as(u64, 1) << @intCast(n);
}

/// The range of powers of ten that conversions need (POWERSOF10_*).
const powersof10_first = -348;
const powersof10_last = 347;

const a_base = [_]u64{
    0x8000000000000000, 0xa000000000000000, 0xc800000000000000,
    0xfa00000000000000, 0x9c40000000000000, 0xc350000000000000,
    0xf424000000000000, 0x9896800000000000, 0xbebc200000000000,
    0xee6b280000000000, 0x9502f90000000000, 0xba43b74000000000,
    0xe8d4a51000000000, 0x9184e72a00000000, 0xb5e620f480000000,
    0xe35fa931a0000000, 0x8e1bc9bf04000000, 0xb1a2bc2ec5000000,
    0xde0b6b3a76400000, 0x8ac7230489e80000, 0xad78ebc5ac620000,
    0xd8d726b7177a8000, 0x878678326eac9000, 0xa968163f0a57b400,
    0xd3c21bcecceda100, 0x84595161401484a0, 0xa56fa5b99019a5c8,
};
const a_scale = [_]u64{
    0x8049a4ac0c5811ae, 0xcf42894a5dce35ea, 0xa76c582338ed2621,
    0x873e4f75e2224e68, 0xda7f5bf590966848, 0xb080392cc4349dec,
    0x8e938662882af53e, 0xe65829b3046b0afa, 0xba121a4650e4ddeb,
    0x964e858c91ba2655, 0xf2d56790ab41c2a2, 0xc428d05aa4751e4c,
    0x9e74d1b791e07e48, 0xcccccccccccccccc, 0xcecb8f27f4200f3a,
    0xa70c3c40a64e6c51, 0x86f0ac99b4e8dafd, 0xda01ee641a708de9,
    0xb01ae745b101e9e4, 0x8e41ade9fbebc27d, 0xe5d3ef282a242e81,
    0xb9a74a0637ce2ee1, 0x95f83d0a1fb69cd9, 0xf24a01a73cf2dccf,
    0xc3b8358109e84f07, 0x9e19db92b4e31ba9,
};
const a_scale_lo = [_]u32{
    0x205b896d, 0x52064cad, 0xaf2af2b8, 0x5a7744a7, 0xaf39a475, 0xbd8d794e,
    0x547eb47b, 0x0cb4a5a3, 0x92f34d62, 0x3a6a07f9, 0xfae27299, 0xaa97e14c,
    0x775ea265, 0xcccccccc, 0x00000000, 0x999090b6, 0x69a028bb, 0xe80e6f48,
    0x5ec05dd0, 0x14588f14, 0x8f1668c9, 0x6d953e2c, 0x4abdaf10, 0xbc633b39,
    0x0a862f81, 0x6c07a2c2,
};

/// Port of powerOfTen(): the most significant 64 bits of pow(10,p), with
/// the next 32 bits in `lo`, for p in [-348, 347].
fn powerOfTen(p: i32, lo: *u32) u64 {
    std.debug.assert(p >= powersof10_first and p <= powersof10_last);
    var g: i32 = undefined;
    var n: i32 = undefined;
    if (p < 0) {
        if (p == -1) {
            lo.* = a_scale_lo[13];
            return a_scale[13];
        }
        g = @divTrunc(p, 27);
        n = @rem(p, 27);
        if (n != 0) {
            g -= 1;
            n += 27;
        }
    } else if (p < 27) {
        lo.* = 0;
        return a_base[@intCast(p)];
    } else {
        g = @divTrunc(p, 27);
        n = @rem(p, 27);
    }
    const gi: usize = @intCast(g + 13);
    const s = a_scale[gi];
    if (n == 0) {
        lo.* = a_scale_lo[gi];
        return s;
    }
    var l: u32 = undefined;
    var x = multiply160(s, a_scale_lo[gi], a_base[@intCast(n)], &l);
    if (bit(63) & x == 0) {
        x = x << 1 | ((l >> 31) & 1);
        l = (l << 1) | 1;
    }
    lo.* = l;
    return x;
}

/// floor(log2(pow(10,p))) and floor(log10(pow(2,p))), approximately.
fn pwr10to2(p: i32) i32 {
    return (p * 108853) >> 15;
}

fn pwr2to10(p: i32) i32 {
    return (p * 78913) >> 18;
}

/// Port of sqlite3Fp2Convert10(): for r = m*pow(2,e) (m with its top bit
/// set), find d and p with r = d*pow(10,p), d having at least n digits.
fn fp2Convert10(m: u64, e: i32, n: i32, d: *u64, p_out: *i32) void {
    std.debug.assert(n >= 1 and n <= 18);
    const p = n - 1 - pwr2to10(e + 63);
    var d2: u32 = undefined;
    var d1: u64 = undefined;
    var h = multiply128(m, powerOfTen(p, &d2), &d1);
    if (n == 18) {
        h >>= @intCast(-(e + pwr10to2(p) + 2));
        d.* = (h + ((h << 1) & 2)) >> 1;
    } else {
        d.* = h >> @intCast(-(e + pwr10to2(p) + 1));
    }
    p_out.* = -p;
}

/// Port of sqlite3Fp10Convert2(): the double nearest to d*pow(10,p)
/// (after Russ Cox's fpfmt).
pub fn fp10Convert2(d: u64, p: i32) f64 {
    if (p < powersof10_first) return 0.0;
    if (p > powersof10_last) return std.math.inf(f64);
    const b: i32 = 64 - @as(i32, @clz(d));
    const lp = pwr10to2(p);
    var e = 53 - b - lp;
    if (e > 1074) {
        if (e >= 1130) return 0.0;
        e = 1074;
    }
    const s = -(e - (64 - b) + lp + 3);
    var pwr10l: u32 = undefined;
    var pwr10h = powerOfTen(p, &pwr10l);
    if (pwr10l != 0) {
        pwr10h += 1;
        pwr10l = ~pwr10l;
    }
    const x = d << @intCast(64 - b);
    var lo: u64 = undefined;
    var hi = multiply128(x, pwr10h, &lo);
    const mid1: u32 = @truncate(lo >> 32);
    var sticky: u64 = 1;
    if (hi & (bit(s) - 1) == 0) {
        const mid2: u32 = @truncate(multiply128(x, @as(u64, pwr10l) << 32, &lo) >> 32);
        sticky = @intFromBool(mid1 -% mid2 > 1);
        hi -= @intFromBool(mid1 < mid2);
    }
    var u = (hi >> @intCast(s)) | sticky;
    const adj: u1 = @intFromBool(u >= bit(55) - 2);
    if (adj != 0) {
        u = (u >> adj) | (u & 1);
        e -= adj;
    }
    var m = (u + 1 + ((u >> 2) & 1)) >> 2;
    if (e <= -972) return std.math.inf(f64);
    if (m & bit(52) != 0) {
        m = (m & ~bit(52)) | (@as(u64, @intCast(1075 - e)) << 52);
    }
    return @bitCast(m);
}

// =========================================================== text to real

/// Port of sqlite3AtoF(): convert the NUL-terminated UTF-8 text `z` to a
/// double. Leading and trailing whitespace is ignored. The result is
/// positive if all of the text is a number, negative if only a prefix is,
/// and 0 if no prefix is. Its low bits describe the parse: 1 some prefix
/// is a number, 2 there is a decimal point or exponent, 4 the value is
/// exactly zero, 8 more than about 19 significant digits were given.
/// Hex is not accepted.
pub fn atoF(z: [*:0]const u8, result: *f64) i32 {
    var i: usize = 0;
    var neg = false;
    var s: u64 = 0;
    var d: i32 = 0;
    var m_state: i32 = 0;

    // The integer part, if any (the gotos of the C code).
    while (true) {
        var v: u8 = z[i] -% '0';
        if (v >= 10) {
            if (z[i] == '-') {
                neg = true;
                i += 1;
            } else if (z[i] == '+') {
                i += 1;
            } else if (ctype.isSpace(z[i])) {
                while (ctype.isSpace(z[i])) i += 1;
                continue;
            } else {
                s = 0;
                break;
            }
            v = z[i] -% '0';
            if (v >= 10) break;
        }
        // parse_integer_part:
        m_state = 1;
        s = v;
        i += 1;
        while (true) {
            v = z[i] -% '0';
            if (v >= 10) break;
            s = s * 10 + v;
            i += 1;
            if (s >= (largest_uint64 - 9) / 10) {
                m_state = 9;
                while (ctype.isDigit(z[i])) {
                    i += 1;
                    d += 1;
                }
                break;
            }
        }
        break;
    }

    if (z[i] == '.') {
        i += 1;
        if (ctype.isDigit(z[i])) {
            m_state |= 1;
            while (true) {
                if (s < (largest_uint64 - 9) / 10) {
                    s = s * 10 + (z[i] - '0');
                    d -= 1;
                } else {
                    m_state = 11;
                }
                i += 1;
                if (!ctype.isDigit(z[i])) break;
            }
        } else if (m_state == 0) {
            result.* = 0.0;
            return 0;
        }
        m_state |= 2;
    } else if (m_state == 0) {
        result.* = 0.0;
        return 0;
    }

    if (z[i] == 'e' or z[i] == 'E') {
        i += 1;
        var esign: i32 = 1;
        if (z[i] == '-') {
            esign = -1;
            i += 1;
        } else if (z[i] == '+') {
            i += 1;
        }
        var v: u8 = z[i] -% '0';
        if (v < 10) {
            var exp: i32 = v;
            i += 1;
            m_state |= 2;
            while (true) {
                v = z[i] -% '0';
                if (v >= 10) break;
                exp = if (exp < 10000) exp * 10 + v else 10000;
                i += 1;
            }
            d += esign * exp;
        } else {
            // Leave z[i] at 'e', '+' or '-' so the result is 0 or negative.
            i -= 1;
        }
    }

    if (s == 0) {
        result.* = 0.0;
        m_state |= 4;
    } else {
        result.* = fp10Convert2(s, d);
    }
    if (neg) result.* = -result.*;

    if (z[i] == 0) return m_state;
    if (ctype.isSpace(z[i])) {
        while (ctype.isSpace(z[i])) i += 1;
        if (z[i] == 0) return m_state;
    }
    return @bitCast(@as(u32, 0xfffffff0) | @as(u32, @intCast(m_state)));
}

// ========================================================= integer to text

const digit_pairs =
    "00010203040506070809" ++
    "10111213141516171819" ++
    "20212223242526272829" ++
    "30313233343536373839" ++
    "40414243444546474849" ++
    "50515253545556575859" ++
    "60616263646566676869" ++
    "70717273747576777879" ++
    "80818283848586878889" ++
    "90919293949596979899";

/// Writes the digits of `v` ending just before `buf[end]`, two at a time.
/// Returns the index of the first digit.
fn u64Digits(v_arg: u64, buf: []u8, end: usize) usize {
    var v = v_arg;
    var i = end;
    while (v >= 10) {
        const kk: usize = @intCast((v % 100) * 2);
        buf[i - 2] = digit_pairs[kk];
        buf[i - 1] = digit_pairs[kk + 1];
        i -= 2;
        v /= 100;
    }
    if (v != 0) {
        i -= 1;
        buf[i] = @intCast(v + '0');
    }
    return i;
}

/// Port of sqlite3Int64ToText(): write `v` in decimal followed by a NUL
/// into `out` (at least 21 bytes) and return the length without the NUL.
pub fn int64ToText(v: i64, out: []u8) usize {
    std.debug.assert(out.len >= u64_digits + 1);
    if (v == 0) {
        out[0] = '0';
        out[1] = 0;
        return 1;
    }
    const x: u64 = if (v > 0) @intCast(v) else if (v == smallest_int64) @as(u64, 1) << 63 else @intCast(-v);
    var a: [u64_digits + 1]u8 = undefined;
    var i = u64Digits(x, &a, u64_digits);
    a[u64_digits] = 0;
    if (v < 0) {
        i -= 1;
        a[i] = '-';
    }
    const len = u64_digits - i;
    @memcpy(out[0 .. len + 1], a[i..]);
    return len;
}

// ============================================================ real to text

/// FpDecode: the decimal digits of a double.
pub const FpDecode = struct {
    /// Significant digits.
    n: i32 = 0,
    /// Position of the decimal point: the value is 0.DIGITS * 10^i_dp.
    i_dp: i32 = 0,
    /// Offset in `buf` of the first digit.
    z: usize = 0,
    buf: [u64_digits + 1]u8 = undefined,
    /// '+' or '-'.
    sign: u8 = '+',
    /// 1 for infinity, 2 for NaN.
    is_special: u8 = 0,

    /// The significant digits (p->z[0..n]); not NUL-terminated.
    pub fn digits(p: *const FpDecode) []const u8 {
        return p.buf[p.z..][0..@intCast(p.n)];
    }
};

/// Port of sqlite3FpDecode(): decode `r` into decimal digits. If
/// `i_round` <= 0, round to -i_round digits after the decimal point, or
/// at most `mx_round` significant digits; otherwise round to
/// min(i_round, mx_round) significant digits. With exactly 17 digits
/// (the "!" flag of "%!.17g") fewer are used if they still round-trip.
pub fn fpDecode(p: *FpDecode, r_arg: f64, i_round_arg: i32, mx_round: i32) void {
    var r = r_arg;
    var i_round = i_round_arg;
    p.is_special = 0;
    std.debug.assert(mx_round > 0);
    if (r < 0.0) {
        p.sign = '-';
        r = -r;
    } else if (r == 0.0) {
        p.sign = '+';
        p.n = 1;
        p.i_dp = 1;
        p.buf[0] = '0';
        p.z = 0;
        return;
    } else {
        p.sign = '+';
    }
    var v: u64 = @bitCast(r);
    var e: i32 = @intCast((v >> 52) & 0x7ff);
    if (e == 0x7ff) {
        p.is_special = 1 + @as(u8, @intFromBool(v != 0x7ff0000000000000));
        p.n = 0;
        p.i_dp = 0;
        p.z = 0;
        return;
    }
    v &= 0x000fffffffffffff;
    if (e == 0) {
        const nn: u6 = @intCast(@clz(v));
        v <<= nn;
        e = -1074 - @as(i32, nn);
    } else {
        v = (v << 11) | bit(63);
        e -= 1086;
    }
    var exp: i32 = 0;
    fp2Convert10(v, e, if (i_round <= 0 or i_round >= 18) 18 else i_round + 1, &v, &exp);

    // The digits, right-aligned in buf.
    const buf = &p.buf;
    var i = u64Digits(v, buf, u64_digits);
    var n: i32 = @intCast(u64_digits - i);
    p.i_dp = n + exp;
    if (i_round <= 0) {
        i_round = p.i_dp - i_round;
        if (i_round == 0 and buf[i] >= '5') {
            i_round = 1;
            i -= 1;
            buf[i] = '0';
            n += 1;
            p.i_dp += 1;
        }
    }
    var z = i;
    if (i_round > 0 and (i_round < n or n > mx_round)) {
        if (i_round > mx_round) i_round = mx_round;
        if (i_round == 17) {
            // Prefer fewer digits that still round-trip: 49.47 rather than
            // 49.469999999999999.
            if (buf[z + 15] == '9' and buf[z + 14] == '9') {
                var jj: usize = 14;
                while (jj > 0 and buf[z + jj - 1] == '9') jj -= 1;
                var v2: u64 = undefined;
                if (jj == 0) {
                    v2 = 1;
                } else {
                    v2 = buf[z] - '0';
                    for (1..jj) |kk| v2 = v2 * 10 + (buf[z + kk] - '0');
                    v2 += 1;
                }
                if (r == fp10Convert2(v2, exp + n - @as(i32, @intCast(jj)))) i_round = @as(i32, @intCast(jj)) + 1;
            } else if (p.i_dp >= n or (buf[z + 15] == '0' and buf[z + 14] == '0' and buf[z + 13] == '0')) {
                std.debug.assert(buf[z] != '0');
                var jj: usize = 13;
                while (buf[z + jj - 1] == '0') jj -= 1;
                var v2: u64 = buf[z] - '0';
                for (1..jj) |kk| v2 = v2 * 10 + (buf[z + kk] - '0');
                if (r == fp10Convert2(v2, exp + n - @as(i32, @intCast(jj)))) i_round = @as(i32, @intCast(jj)) + 1;
            }
        }
        n = i_round;
        const ir: usize = @intCast(i_round);
        if (buf[z + ir] >= '5') {
            var j = ir - 1;
            while (true) {
                buf[z + j] += 1;
                if (buf[z + j] <= '9') break;
                buf[z + j] = '0';
                if (j == 0) {
                    z -= 1;
                    buf[z] = '1';
                    n += 1;
                    p.i_dp += 1;
                    break;
                } else {
                    j -= 1;
                }
            }
        }
    }
    std.debug.assert(n > 0);
    while (buf[z + @as(usize, @intCast(n)) - 1] == '0') n -= 1;
    p.n = n;
    p.z = z;
}

// ============================================================ conversions

/// Port of sqlite3RealToI64(): the integer nearest `r` (truncating),
/// saturating at the i64 limits.
pub fn realToI64(r: f64) i64 {
    if (r < -9223372036854774784.0) return smallest_int64;
    if (r > 9223372036854774784.0) return largest_int64;
    if (isNaN(r)) return 0;
    return @intFromFloat(r);
}

/// Port of sqlite3RealSameAsInt(): true if `r` (from which `i` was
/// computed) equals `i` within the precision of a double.
pub fn realSameAsInt(r: f64, i: i64) bool {
    const r2: f64 = @floatFromInt(i);
    return r == 0.0 or (@as(u64, @bitCast(r)) == @as(u64, @bitCast(r2)) and
        i >= -2251799813685248 and i < 2251799813685248);
}

/// Port of sqlite3GetUInt32(): a decimal u32 that is all of `z`, or null.
pub fn getUInt32(z: []const u8) ?u32 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < z.len and ctype.isDigit(z[i])) : (i += 1) {
        v = v * 10 + (z[i] - '0');
        if (v > 4294967295) return null;
    }
    if (i == 0 or i != z.len) return null;
    return @intCast(v);
}

// =================================================================== tests

fn expectAtoF(text: [:0]const u8, rc: i32, value: f64) !void {
    var r: f64 = undefined;
    const got = atoF(text.ptr, &r);
    errdefer std.debug.print("atoF(\"{s}\") = {d} {d}\n", .{ text, got, r });
    try std.testing.expectEqual(rc, got);
    try std.testing.expectEqual(value, r);
}

test "numeric: atoF" {
    const neg_bits: i32 = @bitCast(@as(u32, 0xfffffff0));
    try expectAtoF("1e10", 3, 1e10);
    try expectAtoF(" 12.5 ", 3, 12.5);
    try expectAtoF("1.", 3, 1.0);
    try expectAtoF(".5", 3, 0.5);
    try expectAtoF("123", 1, 123.0);
    try expectAtoF("-42", 1, -42.0);
    try expectAtoF("+3", 1, 3.0);
    try expectAtoF("0", 5, 0.0);
    try expectAtoF("0.0", 7, 0.0);
    try expectAtoF("1e", neg_bits | 1, 1.0);
    try expectAtoF("1e+", neg_bits | 1, 1.0);
    try expectAtoF("0x10", neg_bits | 5, 0.0);
    try expectAtoF("-", 0, 0.0);
    try expectAtoF("", 0, 0.0);
    try expectAtoF("abc", 0, 0.0);
    try expectAtoF(".", 0, 0.0);
    try expectAtoF("12abc", neg_bits | 1, 12.0);
    try expectAtoF("1e400", 3, std.math.inf(f64));
    try expectAtoF("1e-400", 3, 0.0);
    try expectAtoF("2.2250738585072014e-308", 3, 2.2250738585072014e-308);
    try expectAtoF("4.9406564584124654e-324", 3, 4.9406564584124654e-324);
    try expectAtoF("1.7976931348623157e308", 3, 1.7976931348623157e308);
    try expectAtoF("0.1", 3, 0.1);
    try expectAtoF("3.14159265358979323846", 11, 3.141592653589793);
    try expectAtoF("123456789012345678901234567890", 9, 1.2345678901234568e29);
    try expectAtoF("1e99999", 3, std.math.inf(f64));
}

test "numeric: atoF round-trips random doubles" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..2000) |_| {
        const bits = rand.int(u64) & 0x7fffffffffffffff;
        const x: f64 = @bitCast(bits);
        if (isOverflow(x) or x == 0) continue;
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&buf, "{e}", .{x}, 0) catch unreachable;
        var r: f64 = undefined;
        _ = atoF(s.ptr, &r);
        try std.testing.expectEqual(x, r);
    }
}

test "numeric: int64ToText" {
    var buf: [21]u8 = undefined;
    const cases = [_]struct { i64, []const u8 }{
        .{ 0, "0" },
        .{ 7, "7" },
        .{ -7, "-7" },
        .{ 100, "100" },
        .{ 1234567890, "1234567890" },
        .{ std.math.maxInt(i64), "9223372036854775807" },
        .{ std.math.minInt(i64), "-9223372036854775808" },
    };
    for (cases) |c| {
        const n = int64ToText(c[0], &buf);
        try std.testing.expectEqualStrings(c[1], buf[0..n]);
        try std.testing.expectEqual(@as(u8, 0), buf[n]);
    }
}

test "numeric: fpDecode" {
    var d: FpDecode = .{};
    fpDecode(&d, 0.1, 17, 20);
    try std.testing.expectEqualStrings("1", d.digits());
    try std.testing.expectEqual(@as(i32, 0), d.i_dp);
    fpDecode(&d, 49.47, 17, 20);
    try std.testing.expectEqualStrings("4947", d.digits());
    try std.testing.expectEqual(@as(i32, 2), d.i_dp);
    fpDecode(&d, -1234.5, 15, 16);
    try std.testing.expectEqual(@as(u8, '-'), d.sign);
    try std.testing.expectEqualStrings("12345", d.digits());
    fpDecode(&d, 9.99, -1, 16);
    try std.testing.expectEqualStrings("1", d.digits());
    try std.testing.expectEqual(@as(i32, 2), d.i_dp);
    fpDecode(&d, std.math.inf(f64), 6, 16);
    try std.testing.expectEqual(@as(u8, 1), d.is_special);
    fpDecode(&d, std.math.nan(f64), 6, 16);
    try std.testing.expectEqual(@as(u8, 2), d.is_special);
}

test "numeric: conversions" {
    try std.testing.expectEqual(@as(i64, 3), realToI64(3.9));
    try std.testing.expectEqual(@as(i64, -3), realToI64(-3.9));
    try std.testing.expectEqual(std.math.maxInt(i64), realToI64(1e300));
    try std.testing.expectEqual(std.math.minInt(i64), realToI64(-1e300));
    try std.testing.expect(realSameAsInt(3.0, 3));
    try std.testing.expect(!realSameAsInt(3.5, 3));
    try std.testing.expect(!realSameAsInt(1e17, realToI64(1e17)));
    try std.testing.expectEqual(@as(?u32, 4294967295), getUInt32("4294967295"));
    try std.testing.expectEqual(@as(?u32, null), getUInt32("4294967296"));
    try std.testing.expectEqual(@as(?u32, null), getUInt32("12x"));
    try std.testing.expectEqual(@as(?u32, null), getUInt32(""));
}
