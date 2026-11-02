//! Exact decimal numbers, computed as PostgreSQL computes its `numeric`,
//! and the key a number is stored as: a BLOB whose byte order (memcmp,
//! SQLite's BINARY) is the order of the numbers, and whose bytes are the
//! same for the same number. Indexes, range scans, ORDER BY, GROUP BY,
//! DISTINCT, min()/max(), PRIMARY KEY, UNIQUE and foreign keys work on
//! such a column as SQLite does on any value.
//!
//! The library of every dialect's exact numbers (decimal_sql.zig makes
//! the engine functions xq_dec_*() of it), outside the dialect
//! directories so that a build with any set of dialects has it. What
//! differs between dialects (messages, rounding, the scale of a
//! quotient) is the caller's; what is here is PostgreSQL's: half away
//! from zero, select_div_scale(), NaN equal to itself and above every
//! number, +-Infinity.
//!
//! A number (Dec) is a sign, its decimal digits without leading or
//! trailing zeros (none for zero), where the point goes, and its display
//! scale (PostgreSQL's dscale: the digits after the point it is written
//! with, 1.50 has 2), or NaN, +Infinity, -Infinity.
//!
//! # The key (a disk format: it never changes)
//!
//! The first byte is the class, in the order of the classes:
//!
//!     0x10 -Infinity   0x20 negative   0x30 zero   0x40 positive
//!     0x50 +Infinity   0x60 NaN
//!
//! A positive number is 0.c1 c2 ... cn x 100^E with base-100 digits c
//! (c1 and cn not 0): after the class, E, then the digits.
//!  - E: one byte E + 0x80 (0x02 .. 0xFD) for -126 <= E <= 125; else
//!    0xFE and two bytes big-endian E - 126 (E up to 65661), or 0x01 and
//!    two bytes big-endian E + 65661 (E down to -65661). PostgreSQL's
//!    range (131072 digits before the point, 16383 after) is E from -8191
//!    to 65536.
//!  - each digit c as one byte 2c + 1, the last as 2c (so a longer
//!    number with the same leading digits is larger, and no key is a
//!    proper prefix of another).
//! A negative number is the class 0x20 and the bytes of its absolute
//! value after the class complemented (255 - b), which reverses their
//! order. Zero, NaN and the infinities are their class byte alone.
//!
//! The key of a value stored is that alone (normalized: 1.50 and 1.5 are
//! one key), and its display scale is not known: it shows its own digits.
//! A value computed from numbers of known scales carries its display
//! scale after it: two bytes big-endian, at least the digits after the
//! point (`1.50` is the key of 1.5 and 00 02); one computed from a value
//! of no known scale (a stored one, a double) has none, as PostgreSQL's
//! would have the scale of the stored value, which is not kept. Keys of
//! different numbers differ before that suffix, so it never changes their
//! order; equal numbers of different scales are different BLOBs, which
//! the comparisons a dialect makes take care of (decimal_sql.zig's
//! xq_dec_key() drops the suffix).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { finite, nan, pinf, ninf };

/// The most digits before the point (PostgreSQL's 131072: a weight of
/// 32767 in base 10000).
pub const max_point: i32 = 131072;
/// The largest display scale (NUMERIC_DSCALE_MAX).
pub const max_dscale: u32 = 16383;
/// The largest scale of a quotient (NUMERIC_MAX_DISPLAY_SCALE).
pub const max_display_scale: i32 = 1000;
/// The significant digits a quotient has at least (NUMERIC_MIN_SIG_DIGITS).
pub const min_sig_digits: i32 = 16;
/// The bounds of a type modifier: numeric(p, s) has 1 <= p <= 1000,
/// -1000 <= s <= 1000.
pub const max_precision: i32 = 1000;

pub const Error = error{
    OutOfMemory,
    /// Not a number (invalid input syntax for type numeric).
    Invalid,
    /// Out of the range of the type (value overflows numeric format).
    Overflow,
    DivisionByZero,
};

pub const Dec = struct {
    kind: Kind = .finite,
    neg: bool = false,
    /// Decimal digits 0..9, the first and the last not 0; none for zero.
    digits: []const u8 = &.{},
    /// value = 0.d1 d2 ... dn x 10^point.
    point: i32 = 0,
    /// The digits after the point it is written with (at least
    /// fracDigits()).
    dscale: u32 = 0,
    /// Whether dscale is the number's own (of a literal, of numeric(p, s),
    /// of an operation of such), not the digits of a value whose scale
    /// was dropped (a key stored, a double): only then does its key carry
    /// it.
    scale_known: bool = true,

    pub const zero: Dec = .{};
    pub const nan: Dec = .{ .kind = .nan };
    pub const pinf: Dec = .{ .kind = .pinf };
    pub const ninf: Dec = .{ .kind = .ninf };

    pub fn isZero(d: Dec) bool {
        return d.kind == .finite and d.digits.len == 0;
    }

    pub fn isFinite(d: Dec) bool {
        return d.kind == .finite;
    }

    /// The digits after the point the number needs (PostgreSQL's
    /// min_scale()).
    pub fn fracDigits(d: Dec) u32 {
        if (d.kind != .finite) return 0;
        const f = @as(i64, @intCast(d.digits.len)) - d.point;
        return if (f > 0) @intCast(f) else 0;
    }

    /// The sign: -1, 0, 1 (NaN is 0).
    pub fn sign(d: Dec) i2 {
        return switch (d.kind) {
            .nan => 0,
            .pinf => 1,
            .ninf => -1,
            .finite => if (d.digits.len == 0) 0 else if (d.neg) -1 else 1,
        };
    }

    /// The digit at power of ten `p` (0 outside the digits).
    pub fn digitAt(d: Dec, p: i64) u8 {
        const i = @as(i64, d.point) - 1 - p;
        if (i < 0 or i >= d.digits.len) return 0;
        return d.digits[@intCast(i)];
    }

    /// -d.
    pub fn negate(d: Dec) Dec {
        var r = d;
        switch (d.kind) {
            .pinf => r.kind = .ninf,
            .ninf => r.kind = .pinf,
            .nan => {},
            .finite => r.neg = !d.neg and d.digits.len > 0,
        }
        return r;
    }

    /// |d|.
    pub fn abs(d: Dec) Dec {
        var r = d;
        if (d.kind == .ninf) r.kind = .pinf;
        r.neg = false;
        return r;
    }

    /// d with display scale `s` (at least its digits).
    pub fn withScale(d: Dec, s: u32) Dec {
        var r = d;
        r.dscale = @max(s, d.fracDigits());
        r.scale_known = true;
        return r;
    }
};

/// The number of digits `raw[0..]` with the first at power point-1,
/// without its leading and trailing zeros (sharing `raw`).
fn normalize(raw: []const u8, point: i64, neg: bool, dscale: u32) Dec {
    var i: usize = 0;
    while (i < raw.len and raw[i] == 0) i += 1;
    if (i == raw.len) return .{ .dscale = dscale };
    var j = raw.len;
    while (raw[j - 1] == 0) j -= 1;
    const p = point - @as(i64, @intCast(i));
    return .{ .neg = neg, .digits = raw[i..j], .point = @intCast(std.math.clamp(p, std.math.minInt(i32), std.math.maxInt(i32))), .dscale = dscale };
}

/// Whether finite `d` is within PostgreSQL's range: at most 131072 digits
/// before the point, a display scale of at most 16383.
pub fn check(d: Dec) Error!void {
    if (d.kind != .finite) return;
    if (d.dscale > max_dscale) return error.Overflow;
    if (d.digits.len > 0 and d.point > max_point) return error.Overflow;
}

// ================================================================ input

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

/// numeric_in(): a number as PostgreSQL reads one. Spaces around it; NaN,
/// [+-]Infinity, [+-]inf (any case); a sign, digits with a point and an
/// exponent; `_` between digits; 0x, 0o and 0b integers. The display
/// scale is the digits after the point less the exponent (1.50 has 2,
/// 1.5e1 none). error.Invalid if it is no number, error.Overflow if it is
/// out of range.
pub fn parse(a: Allocator, text: []const u8) Error!Dec {
    var s = text;
    while (s.len > 0 and isSpace(s[0])) s = s[1..];
    while (s.len > 0 and isSpace(s[s.len - 1])) s = s[0 .. s.len - 1];
    if (std.ascii.eqlIgnoreCase(s, "nan")) return .nan;
    var neg = false;
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const rest = s[i..];
    if (std.ascii.eqlIgnoreCase(rest, "infinity") or std.ascii.eqlIgnoreCase(rest, "inf")) return if (neg) .ninf else .pinf;
    if (rest.len > 2 and rest[0] == '0') {
        const base: u8 = switch (rest[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (base != 0) return parseBased(a, rest[2..], base, neg);
    }
    var digits: std.ArrayList(u8) = try .initCapacity(a, rest.len);
    var int_digits: i64 = 0;
    var frac_digits: i64 = 0;
    var seen_point = false;
    var k: usize = 0;
    var any = false;
    while (k < rest.len) : (k += 1) {
        const c = rest[k];
        if (std.ascii.isDigit(c)) {
            digits.appendAssumeCapacity(c - '0');
            if (seen_point) frac_digits += 1 else int_digits += 1;
            any = true;
        } else if (c == '.' and !seen_point) {
            seen_point = true;
        } else if (c == '_') {
            // Between two digits.
            if (k == 0 or !std.ascii.isDigit(rest[k - 1]) or k + 1 >= rest.len or !std.ascii.isDigit(rest[k + 1])) return error.Invalid;
        } else break;
    }
    if (!any) return error.Invalid;
    var exp: i64 = 0;
    if (k < rest.len and (rest[k] == 'e' or rest[k] == 'E')) {
        k += 1;
        var eneg = false;
        if (k < rest.len and (rest[k] == '+' or rest[k] == '-')) {
            eneg = rest[k] == '-';
            k += 1;
        }
        const start = k;
        var big = false;
        while (k < rest.len) : (k += 1) {
            const c = rest[k];
            if (std.ascii.isDigit(c)) {
                exp = exp * 10 + (c - '0');
                if (exp > 1 << 40) big = true;
                if (big) exp = 1 << 40;
            } else if (c == '_') {
                if (k == start or !std.ascii.isDigit(rest[k - 1]) or k + 1 >= rest.len or !std.ascii.isDigit(rest[k + 1])) return error.Invalid;
            } else break;
        }
        if (k == start) return error.Invalid;
        if (k != rest.len) return error.Invalid;
        if (big) return error.Overflow;
        if (eneg) exp = -exp;
    }
    if (k != rest.len) return error.Invalid;
    const ds = frac_digits - exp;
    if (ds > max_dscale) return error.Overflow;
    const d = normalize(digits.items, int_digits + exp, neg, @intCast(@max(ds, 0)));
    if (d.digits.len > 0 and @as(i64, d.point) > max_point) return error.Overflow;
    try check(d);
    return d;
}

/// An integer of base 2, 8 or 16 (0x1F: its digits after the prefix),
/// `_` allowed before and between digits.
fn parseBased(a: Allocator, z: []const u8, base: u8, neg: bool) Error!Dec {
    // Decimal digits, least significant first.
    var acc: std.ArrayList(u8) = .empty;
    var any = false;
    for (z, 0..) |c, k| {
        if (c == '_') {
            if (k + 1 >= z.len or z[k + 1] == '_') return error.Invalid;
            continue;
        }
        const v = std.fmt.charToDigit(c, base) catch return error.Invalid;
        any = true;
        // acc = acc * base + v.
        var carry: u32 = v;
        for (acc.items) |*d| {
            const t = @as(u32, d.*) * base + carry;
            d.* = @intCast(t % 10);
            carry = t / 10;
        }
        while (carry > 0) {
            try acc.append(a, @intCast(carry % 10));
            carry /= 10;
        }
        if (acc.items.len > max_point) return error.Overflow;
    }
    if (!any) return error.Invalid;
    std.mem.reverse(u8, acc.items);
    return normalize(acc.items, @intCast(acc.items.len), neg, 0);
}

/// The number of an integer.
pub fn fromInt(a: Allocator, v: i64) Error!Dec {
    var buf: [20]u8 = undefined;
    var m: u64 = @abs(v);
    var n: usize = 0;
    while (m > 0) : (m /= 10) {
        buf[buf.len - 1 - n] = @intCast(m % 10);
        n += 1;
    }
    const raw = try a.dupe(u8, buf[buf.len - n ..]);
    return normalize(raw, @intCast(n), v < 0, 0);
}

/// The number of a double as PostgreSQL converts one (float8_numeric():
/// its 15 significant digits, %.15g, read as numeric_in() reads them).
pub fn fromFloat(a: Allocator, v: f64) Error!Dec {
    if (std.math.isNan(v)) return .nan;
    if (std.math.isInf(v)) return if (v > 0) .pinf else .ninf;
    if (v == 0) return .zero;
    var buf: [64]u8 = undefined;
    // d.dddddddddddddde[-]x: 15 significant digits.
    const z = std.fmt.bufPrint(&buf, "{e:.14}", .{@abs(v)}) catch return error.Invalid;
    const e_at = std.mem.indexOfScalar(u8, z, 'e') orelse return error.Invalid;
    const e10 = std.fmt.parseInt(i64, z[e_at + 1 ..], 10) catch return error.Invalid;
    var raw = try a.alloc(u8, 15);
    var n: usize = 0;
    for (z[0..e_at]) |c| {
        if (c == '.') continue;
        raw[n] = c - '0';
        n += 1;
    }
    raw = raw[0..n];
    var sig = n;
    while (sig > 1 and raw[sig - 1] == 0) sig -= 1;
    // %g's digits after the point, as numeric_in() reads them: its own
    // digits, no scale of its own.
    const ds = @max(@as(i64, @intCast(sig)) - 1 - e10, 0);
    var d = normalize(raw[0..sig], e10 + 1, v < 0, @intCast(ds));
    d.scale_known = false;
    return d;
}

// =============================================================== output

/// numeric_out(): the text of `d` with its display scale (at least the
/// digits it has): NaN, Infinity, -Infinity, -12.50.
pub fn write(w: *std.Io.Writer, d: Dec) std.Io.Writer.Error!void {
    switch (d.kind) {
        .nan => return w.writeAll("NaN"),
        .pinf => return w.writeAll("Infinity"),
        .ninf => return w.writeAll("-Infinity"),
        .finite => {},
    }
    if (d.neg and d.digits.len > 0) try w.writeByte('-');
    if (d.point <= 0 or d.digits.len == 0) {
        try w.writeByte('0');
    } else {
        var p: i64 = d.point - 1;
        while (p >= 0) : (p -= 1) try w.writeByte('0' + d.digitAt(p));
    }
    const scale = @max(d.dscale, d.fracDigits());
    if (scale > 0) {
        try w.writeByte('.');
        var p: i64 = -1;
        while (p >= -@as(i64, scale)) : (p -= 1) try w.writeByte('0' + d.digitAt(p));
    }
}

/// The length of write()'s text of `d`.
pub fn textLen(d: Dec) usize {
    switch (d.kind) {
        .nan => return 3,
        .pinf => return 8,
        .ninf => return 9,
        .finite => {},
    }
    var n: usize = @intFromBool(d.neg and d.digits.len > 0);
    n += if (d.point <= 0 or d.digits.len == 0) 1 else @intCast(d.point);
    const scale = @max(d.dscale, d.fracDigits());
    if (scale > 0) n += 1 + scale;
    return n;
}

/// write() into memory of `a`.
pub fn toText(a: Allocator, d: Dec) Error![]u8 {
    const buf = try a.alloc(u8, textLen(d));
    var w: std.Io.Writer = .fixed(buf);
    write(&w, d) catch unreachable;
    return buf;
}

// ================================================================== key

pub const class_ninf: u8 = 0x10;
pub const class_neg: u8 = 0x20;
pub const class_zero: u8 = 0x30;
pub const class_pos: u8 = 0x40;
pub const class_pinf: u8 = 0x50;
pub const class_nan: u8 = 0x60;

/// The base-100 exponent of finite nonzero `d` and whether its digits
/// start at the second place of the first base-100 digit (an odd point).
fn exponent100(d: Dec) struct { e: i64, shift: bool } {
    const p: i64 = d.point;
    if (@mod(p, 2) == 0) return .{ .e = @divExact(p, 2), .shift = false };
    return .{ .e = @divFloor(p + 1, 2), .shift = true };
}

fn exponentLen(e: i64) usize {
    return if (e >= -126 and e <= 125) 1 else 3;
}

/// The length of key(d, null).
pub fn keyLen(d: Dec) usize {
    if (d.kind != .finite or d.digits.len == 0) return 1;
    const x = exponent100(d);
    const n = d.digits.len + @intFromBool(x.shift);
    return 1 + exponentLen(x.e) + (n + 1) / 2;
}

/// The key of `d` (the file's comment), with the display scale after it
/// if `with_scale` and it is known. The number must be in range
/// (check()).
pub fn key(a: Allocator, d: Dec, with_scale: bool) Error![]u8 {
    const suffix = with_scale and d.kind == .finite and d.scale_known;
    const n = keyLen(d);
    const out = try a.alloc(u8, n + @as(usize, if (suffix) 2 else 0));
    writeKey(out[0..n], d);
    if (suffix) std.mem.writeInt(u16, out[n..][0..2], @intCast(d.dscale), .big);
    return out;
}

fn writeKey(out: []u8, d: Dec) void {
    switch (d.kind) {
        .nan => out[0] = class_nan,
        .pinf => out[0] = class_pinf,
        .ninf => out[0] = class_ninf,
        .finite => if (d.digits.len == 0) {
            out[0] = class_zero;
        } else {
            out[0] = if (d.neg) class_neg else class_pos;
            const x = exponent100(d);
            var i: usize = 1;
            if (exponentLen(x.e) == 1) {
                out[1] = @intCast(x.e + 0x80);
                i = 2;
            } else if (x.e > 0) {
                out[1] = 0xFE;
                std.mem.writeInt(u16, out[2..4], @intCast(x.e - 126), .big);
                i = 4;
            } else {
                out[1] = 0x01;
                std.mem.writeInt(u16, out[2..4], @intCast(x.e + 65661), .big);
                i = 4;
            }
            // The base-100 digits.
            const ds = d.digits;
            const shift: usize = @intFromBool(x.shift);
            const n = ds.len + shift;
            var k: usize = 0;
            while (k < n) : (k += 2) {
                const hi: u8 = if (k < shift) 0 else ds[k - shift];
                const lo: u8 = if (k + 1 - shift < ds.len) ds[k + 1 - shift] else 0;
                const c = hi * 10 + lo;
                const last = k + 2 >= n;
                out[i] = if (last) 2 * c else 2 * c + 1;
                i += 1;
            }
            std.debug.assert(i == out.len);
            if (d.neg) for (out[1..]) |*b| {
                b.* = 255 - b.*;
            };
        },
    }
}

pub const Decoded = struct {
    dec: Dec,
    /// The display scale after the key, if there was one.
    scale: ?u32,
};

/// The number of key `k` (key()): its display scale the suffix's, else
/// its digits after the point (and not known). error.Invalid if `k` is no key (not as
/// key() writes one).
pub fn decodeKey(a: Allocator, k: []const u8) Error!Decoded {
    const n = try pureLen(k);
    var d: Dec = switch (k[0]) {
        class_nan => .nan,
        class_pinf => .pinf,
        class_ninf => .ninf,
        class_zero => .zero,
        else => try decodeFinite(a, k[0..n]),
    };
    var scale: ?u32 = null;
    if (k.len == n + 2) {
        if (d.kind != .finite) return error.Invalid;
        const s = std.mem.readInt(u16, k[n..][0..2], .big);
        if (s < d.fracDigits() or s > max_dscale) return error.Invalid;
        scale = s;
    } else if (k.len != n) return error.Invalid;
    d.dscale = scale orelse d.fracDigits();
    d.scale_known = scale != null or d.kind != .finite;
    return .{ .dec = d, .scale = scale };
}

/// The length of the key at the start of `k`, without a suffix;
/// error.Invalid if `k` does not start with one.
pub fn pureLen(k: []const u8) Error!usize {
    if (k.len == 0) return error.Invalid;
    switch (k[0]) {
        class_nan, class_pinf, class_ninf, class_zero => return 1,
        class_pos, class_neg => {},
        else => return error.Invalid,
    }
    const neg = k[0] == class_neg;
    const at = struct {
        fn f(z: []const u8, i: usize, flip: bool) u8 {
            return if (flip) 255 - z[i] else z[i];
        }
    }.f;
    if (k.len < 3) return error.Invalid;
    var i: usize = 1;
    const e0 = at(k, 1, neg);
    if (e0 == 0x01 or e0 == 0xFE) {
        if (k.len < 5) return error.Invalid;
        const v = @as(u16, at(k, 2, neg)) << 8 | at(k, 3, neg);
        // The short form where it fits.
        if (e0 == 0xFE and v > 65661 - 126) return error.Invalid;
        if (e0 == 0x01 and @as(i64, v) - 65661 >= -126) return error.Invalid;
        i = 4;
    } else if (e0 < 0x02 or e0 > 0xFD) {
        return error.Invalid;
    } else i = 2;
    const first = i;
    while (i < k.len) : (i += 1) {
        const b = at(k, i, neg);
        if (b > 199) return error.Invalid;
        if (b % 2 == 0) {
            // The last digit: not 0; the first not 0 either.
            if (b == 0) return error.Invalid;
            if (i == first and b < 2) return error.Invalid;
            return i + 1;
        }
        if (i == first and b == 1) return error.Invalid;
    }
    return error.Invalid;
}

fn decodeFinite(a: Allocator, k: []const u8) Error!Dec {
    const neg = k[0] == class_neg;
    var buf = try a.alloc(u8, k.len);
    defer a.free(buf);
    @memcpy(buf, k);
    if (neg) for (buf[1..]) |*b| {
        b.* = 255 - b.*;
    };
    var e: i64 = undefined;
    var i: usize = undefined;
    if (buf[1] == 0xFE) {
        e = @as(i64, std.mem.readInt(u16, buf[2..4], .big)) + 126;
        i = 4;
    } else if (buf[1] == 0x01) {
        e = @as(i64, std.mem.readInt(u16, buf[2..4], .big)) - 65661;
        i = 4;
    } else {
        e = @as(i64, buf[1]) - 0x80;
        i = 2;
    }
    const pairs = buf[i..];
    const raw = try a.alloc(u8, pairs.len * 2);
    for (pairs, 0..) |b, j| {
        const c = b / 2;
        raw[2 * j] = c / 10;
        raw[2 * j + 1] = c % 10;
    }
    // raw[0] is at power 2e - 1.
    var d = normalize(raw, 2 * e, neg, 0);
    d.dscale = d.fracDigits();
    return d;
}

/// Whether `k` is a key without a suffix (what a column stores).
pub fn isPureKey(k: []const u8) bool {
    const n = pureLen(k) catch return false;
    if (n != k.len) return false;
    // The digits of a key of no class but these are checked by pureLen.
    return true;
}

/// The text of key `k` (with or without a scale after it), with at least
/// `scale` digits after the point if given (the scale of its type: a
/// numeric(10,2) column's 1.5 is 1.50), else its own display scale;
/// error.Invalid if `k` is no key.
/// The result alone is `a`'s (the caller frees it).
pub fn keyText(a: Allocator, k: []const u8, scale: ?u32) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var d = (try decodeKey(arena.allocator(), k)).dec;
    if (scale) |s| d.dscale = @max(@min(s, max_dscale), d.fracDigits());
    return toText(a, d);
}

// =========================================================== comparison

/// The order of `x` and `y`: NaN equal to NaN and above everything, then
/// +Infinity, numbers, -Infinity (PostgreSQL's cmp_numerics()).
pub fn order(x: Dec, y: Dec) std.math.Order {
    const rank = struct {
        fn f(d: Dec) u8 {
            return switch (d.kind) {
                .ninf => 0,
                .finite => 1,
                .pinf => 2,
                .nan => 3,
            };
        }
    }.f;
    const rx = rank(x);
    const ry = rank(y);
    if (rx != ry or rx != 1) return std.math.order(rx, ry);
    const sx = x.sign();
    const sy = y.sign();
    if (sx != sy) return std.math.order(sx, sy);
    const m = orderMag(x, y);
    return if (sx < 0) m.invert() else m;
}

/// The order of |x| and |y|, finite.
fn orderMag(x: Dec, y: Dec) std.math.Order {
    if (x.digits.len == 0 or y.digits.len == 0) return std.math.order(x.digits.len, y.digits.len);
    if (x.point != y.point) return std.math.order(x.point, y.point);
    const n = @min(x.digits.len, y.digits.len);
    for (x.digits[0..n], y.digits[0..n]) |a, b| if (a != b) return std.math.order(a, b);
    return std.math.order(x.digits.len, y.digits.len);
}

// =========================================================== arithmetic

/// |x| + |y| (finite), signed `neg`.
fn addMag(a: Allocator, x: Dec, y: Dec, neg: bool) Error!Dec {
    if (x.digits.len == 0) return withSign(y, neg);
    if (y.digits.len == 0) return withSign(x, neg);
    const hi: i64 = @max(x.point, y.point);
    const lo: i64 = @min(@as(i64, x.point) - @as(i64, @intCast(x.digits.len)), @as(i64, y.point) - @as(i64, @intCast(y.digits.len)));
    const n: usize = @intCast(hi - lo + 1);
    const raw = try a.alloc(u8, n);
    @memset(raw, 0);
    // raw[0] is at power hi.
    for ([_]Dec{ x, y }) |v| {
        const off: usize = @intCast(hi - v.point + 1);
        for (v.digits, 0..) |dg, i| raw[off + i] += dg;
    }
    var carry: u8 = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        const t = raw[i] + carry;
        raw[i] = t % 10;
        carry = t / 10;
    }
    std.debug.assert(carry == 0);
    return normalize(raw, hi + 1, neg, 0);
}

/// |x| - |y| (finite, |x| >= |y|), signed `neg`.
fn subMag(a: Allocator, x: Dec, y: Dec, neg: bool) Error!Dec {
    if (y.digits.len == 0) return withSign(x, neg);
    const hi: i64 = x.point;
    const lo: i64 = @min(@as(i64, x.point) - @as(i64, @intCast(x.digits.len)), @as(i64, y.point) - @as(i64, @intCast(y.digits.len)));
    const n: usize = @intCast(hi - lo);
    const raw = try a.alloc(u8, n);
    @memset(raw, 0);
    for (x.digits, 0..) |dg, i| raw[i] = dg;
    const off: usize = @intCast(hi - y.point);
    var borrow: u8 = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        const sv: u8 = (if (i >= off and i - off < y.digits.len) y.digits[i - off] else 0) + borrow;
        if (raw[i] >= sv) {
            raw[i] -= sv;
            borrow = 0;
        } else {
            raw[i] = raw[i] + 10 - sv;
            borrow = 1;
        }
    }
    std.debug.assert(borrow == 0);
    return normalize(raw, hi, neg, 0);
}

fn withSign(d: Dec, neg: bool) Dec {
    var r = d;
    r.neg = neg and d.digits.len > 0;
    return r;
}

/// x + y; display scale the larger of theirs.
pub fn add(a: Allocator, x: Dec, y: Dec) Error!Dec {
    if (x.kind != .finite or y.kind != .finite) return addSpecial(x, y);
    var r: Dec = undefined;
    if (x.neg == y.neg) {
        r = try addMag(a, x, y, x.neg);
    } else switch (orderMag(x, y)) {
        .eq => r = .zero,
        .gt => r = try subMag(a, x, y, x.neg),
        .lt => r = try subMag(a, y, x, y.neg),
    }
    r.dscale = @max(x.dscale, y.dscale);
    r.scale_known = x.scale_known and y.scale_known;
    try check(r);
    return r;
}

fn addSpecial(x: Dec, y: Dec) Dec {
    if (x.kind == .nan or y.kind == .nan) return .nan;
    if (x.kind == .finite) return y;
    if (y.kind == .finite) return x;
    return if (x.kind == y.kind) x else .nan;
}

/// x - y.
pub fn sub(a: Allocator, x: Dec, y: Dec) Error!Dec {
    return add(a, x, y.negate());
}

/// x * y, exact (display scale the sum of theirs, rounded to 16383).
pub fn mul(a: Allocator, x: Dec, y: Dec) Error!Dec {
    if (x.kind != .finite or y.kind != .finite) {
        if (x.kind == .nan or y.kind == .nan) return .nan;
        // Infinity times zero is NaN; else the sign of the product.
        if (x.isZero() or y.isZero()) return .nan;
        return if ((x.sign() < 0) != (y.sign() < 0)) .ninf else .pinf;
    }
    const ds: u64 = @as(u64, x.dscale) + y.dscale;
    if (x.digits.len == 0 or y.digits.len == 0) {
        var z: Dec = .zero;
        z.dscale = @intCast(@min(ds, max_dscale));
        z.scale_known = x.scale_known and y.scale_known;
        return z;
    }
    const lx = x.digits.len;
    const ly = y.digits.len;
    const acc = try a.alloc(u64, lx + ly);
    defer a.free(acc);
    @memset(acc, 0);
    // acc[i + j + 1] holds digit products at power (point - 1 - i - j - 1).
    for (x.digits, 0..) |dx, i| {
        if (dx == 0) continue;
        for (y.digits, 0..) |dy, j| acc[i + j + 1] += @as(u64, dx) * dy;
    }
    carryAll(acc);
    const raw = try a.alloc(u8, lx + ly);
    for (acc, raw) |v, *r| r.* = @intCast(v);
    var r = normalize(raw, @as(i64, x.point) + y.point, x.neg != y.neg, 0);
    if (ds > max_dscale) {
        r = try round(a, r, max_dscale);
        r.dscale = max_dscale;
    } else r.dscale = @intCast(ds);
    r.scale_known = x.scale_known and y.scale_known;
    try check(r);
    return r;
}

fn carryAll(acc: []u64) void {
    var carry: u64 = 0;
    var i = acc.len;
    while (i > 0) {
        i -= 1;
        const t = acc[i] + carry;
        acc[i] = t % 10;
        carry = t / 10;
    }
}

/// PostgreSQL's select_div_scale(): the display scale of x / y.
pub fn divScale(x: Dec, y: Dec) u32 {
    const w1, const f1 = weightFirst(x);
    const w2, const f2 = weightFirst(y);
    var qweight = w1 - w2;
    if (f1 <= f2) qweight -= 1;
    var rscale: i64 = min_sig_digits - qweight * 4;
    rscale = @max(rscale, @as(i64, x.dscale));
    rscale = @max(rscale, @as(i64, y.dscale));
    rscale = @max(rscale, 0);
    rscale = @min(rscale, max_display_scale);
    return @intCast(rscale);
}

/// The weight (in base 10000) and first base-10000 digit of `d`, as
/// PostgreSQL's NumericVar has them (0, 0 for zero).
fn weightFirst(d: Dec) struct { i64, u32 } {
    if (d.kind != .finite or d.digits.len == 0) return .{ 0, 0 };
    const top: i64 = @as(i64, d.point) - 1;
    const w = @divFloor(top, 4);
    var f: u32 = 0;
    var p: i64 = w * 4 + 3;
    while (p >= w * 4) : (p -= 1) f = f * 10 + d.digitAt(p);
    return .{ w, f };
}

/// x / y with `rscale` digits after the point, rounded half away from
/// zero if `rnd`, else truncated; error.DivisionByZero for y zero.
pub fn divide(a: Allocator, x: Dec, y: Dec, rscale: i64, rnd: bool) Error!Dec {
    if (x.kind == .nan or y.kind == .nan) return .nan;
    if (y.isZero()) return error.DivisionByZero;
    if (x.kind != .finite) {
        if (y.kind != .finite) return .nan;
        return if ((x.sign() < 0) != (y.sign() < 0)) .ninf else .pinf;
    }
    if (y.kind != .finite) return .zero;
    var r = try divMag(a, x, y, rscale, rnd);
    r.neg = (x.neg != y.neg) and r.digits.len > 0;
    r.dscale = @intCast(@max(rscale, 0));
    try check(r);
    return r;
}

/// |x| / |y| (finite, y not 0) at `rscale`.
fn divMag(a: Allocator, x: Dec, y: Dec, rscale: i64, rnd: bool) Error!Dec {
    if (x.digits.len == 0) return .zero;
    const lx: i64 = @intCast(x.digits.len);
    const ly: i64 = @intCast(y.digits.len);
    // x = X * 10^ex, y = Y * 10^ey with X, Y the digits as integers.
    const ex = @as(i64, x.point) - lx;
    const ey = @as(i64, y.point) - ly;
    const extra: i64 = @intFromBool(rnd);
    // Q = floor(X * 10^k / Y): the quotient with rscale + extra digits
    // after the point.
    const k = ex - ey + rscale + extra;
    const ln = lx + @max(k, 0);
    const ld = ly + @max(-k, 0);
    if (ln < ld) return .zero;
    if (ln - ld > max_point * 2 + 4) return error.Overflow;
    const num = try a.alloc(u8, @intCast(ln));
    defer a.free(num);
    @memset(num, 0);
    @memcpy(num[0..x.digits.len], x.digits);
    const den = try a.alloc(u8, @intCast(ld));
    defer a.free(den);
    @memset(den, 0);
    @memcpy(den[0..y.digits.len], y.digits);
    const q = try a.alloc(u8, @intCast(ln));
    // Long division, a remainder of at most ld + 1 digits.
    const rem = try a.alloc(u8, @intCast(ld + 1));
    defer a.free(rem);
    @memset(rem, 0);
    for (num, 0..) |dg, i| {
        // rem = rem * 10 + dg.
        std.mem.copyForwards(u8, rem[0 .. rem.len - 1], rem[1..]);
        rem[rem.len - 1] = dg;
        var qd: u8 = 0;
        while (geShifted(rem, den)) {
            subShifted(rem, den);
            qd += 1;
        }
        q[i] = qd;
    }
    // q is at powers ln - 1 .. 0 of the integer Q.
    var qd = q;
    var qpoint: i64 = ln;
    if (rnd) {
        const last = qd[qd.len - 1];
        qd = qd[0 .. qd.len - 1];
        qpoint -= 1;
        if (last >= 5) {
            var i = qd.len;
            var carry = true;
            while (carry and i > 0) {
                i -= 1;
                if (qd[i] == 9) {
                    qd[i] = 0;
                } else {
                    qd[i] += 1;
                    carry = false;
                }
            }
            if (carry) {
                const grown = try a.alloc(u8, qd.len + 1);
                grown[0] = 1;
                @memcpy(grown[1..], qd);
                qd = grown;
                qpoint += 1;
            }
        }
    }
    // Q x 10^-rscale.
    return normalize(qd, qpoint - rscale, false, 0);
}

/// rem >= den, rem having one digit more (most significant first).
fn geShifted(rem: []const u8, den: []const u8) bool {
    if (rem[0] != 0) return true;
    for (rem[1..], den) |r, d| if (r != d) return r > d;
    return true;
}

fn subShifted(rem: []u8, den: []const u8) void {
    var borrow: u8 = 0;
    var i = rem.len;
    while (i > 0) {
        i -= 1;
        const s: u8 = (if (i >= 1) den[i - 1] else 0) + borrow;
        if (rem[i] >= s) {
            rem[i] -= s;
            borrow = 0;
        } else {
            rem[i] = rem[i] + 10 - s;
            borrow = 1;
        }
    }
}

/// x / y as PostgreSQL's `/` (scale select_div_scale(), rounded; known
/// if theirs are).
pub fn div(a: Allocator, x: Dec, y: Dec) Error!Dec {
    var r = try divide(a, x, y, divScale(x, y), true);
    if (r.kind == .finite) r.scale_known = x.scale_known and y.scale_known;
    return r;
}

/// div(x, y): the quotient truncated to an integer.
pub fn divTrunc(a: Allocator, x: Dec, y: Dec) Error!Dec {
    return divide(a, x, y, 0, false);
}

/// x % y (mod()): the sign of x, display scale the larger of theirs.
pub fn mod(a: Allocator, x: Dec, y: Dec) Error!Dec {
    if (x.kind == .nan or y.kind == .nan) return .nan;
    if (y.isZero()) return error.DivisionByZero;
    if (x.kind != .finite) return .nan;
    if (y.kind != .finite) return x;
    const q = try divTrunc(a, x, y);
    var p = try mul(a, q, y);
    p.dscale = y.dscale;
    return sub(a, x, p);
}

/// d rounded half away from zero to `s` digits after the point (s may be
/// negative: round(1234.5, -2) is 1200); display scale max(s, 0).
pub fn round(a: Allocator, d: Dec, s: i64) Error!Dec {
    return roundImpl(a, d, s, true);
}

/// d truncated to `s` digits after the point.
pub fn trunc(a: Allocator, d: Dec, s: i64) Error!Dec {
    return roundImpl(a, d, s, false);
}

fn roundImpl(a: Allocator, d: Dec, s: i64, rnd: bool) Error!Dec {
    if (d.kind != .finite) return d;
    var r = try cut(a, d, s, if (rnd) .half else .down);
    r.dscale = @intCast(@max(s, 0));
    r.scale_known = true;
    try check(r);
    return r;
}

const Cut = enum { half, down, up };

/// The digits of `d` from power -s up, the rest dropped: rounded half
/// away from zero, towards zero, or away from zero (if any is dropped).
/// Display scale unchanged.
fn cut(a: Allocator, d: Dec, s: i64, how: Cut) Error!Dec {
    const keep: i64 = @as(i64, d.point) + s;
    if (keep >= d.digits.len) return d;
    var up = false;
    if (keep < 0) {
        up = how == .up;
    } else {
        const next = d.digits[@intCast(keep)];
        up = switch (how) {
            .half => next >= 5,
            .down => false,
            // Every dropped digit after a first 0 is not 0 at the end.
            .up => true,
        };
    }
    if (keep <= 0) {
        if (!up) return withScale(Dec.zero, d.dscale);
        // 1 at power -s.
        const one = try a.dupe(u8, &.{1});
        return .{ .neg = d.neg, .digits = one, .point = @intCast(-s + 1), .dscale = d.dscale };
    }
    const raw = try a.alloc(u8, @as(usize, @intCast(keep)) + 1);
    raw[0] = 0;
    @memcpy(raw[1..], d.digits[0..@intCast(keep)]);
    if (up) {
        var i = raw.len;
        while (i > 0) {
            i -= 1;
            if (raw[i] == 9) {
                raw[i] = 0;
            } else {
                raw[i] += 1;
                break;
            }
        }
    }
    return normalize(raw, @as(i64, d.point) + 1, d.neg, d.dscale);
}

fn withScale(d: Dec, s: u32) Dec {
    var r = d;
    r.dscale = s;
    return r;
}

/// ceil(d): the smallest integer not less (display scale 0).
pub fn ceil(a: Allocator, d: Dec) Error!Dec {
    if (d.kind != .finite) return d;
    var r = try cut(a, d, 0, if (d.neg) .down else .up);
    r.dscale = 0;
    r.scale_known = true;
    return r;
}

/// floor(d): the largest integer not more.
pub fn floor(a: Allocator, d: Dec) Error!Dec {
    if (d.kind != .finite) return d;
    var r = try cut(a, d, 0, if (d.neg) .up else .down);
    r.dscale = 0;
    r.scale_known = true;
    try check(r);
    return r;
}

/// The integer `d` rounds to (half away from zero), if it fits an i64;
/// error.Overflow if not, error.Invalid for NaN and infinities.
pub fn toInt(a: Allocator, d: Dec) Error!i64 {
    if (d.kind != .finite) return error.Invalid;
    const r = try cut(a, d, 0, .half);
    if (r.digits.len == 0) return 0;
    if (r.point > 19) return error.Overflow;
    var v: i128 = 0;
    var p: i64 = r.point - 1;
    while (p >= 0) : (p -= 1) v = v * 10 + r.digitAt(p);
    if (r.neg) v = -v;
    return std.math.cast(i64, v) orelse error.Overflow;
}

/// The double nearest to `d` (as strtod() reads its text);
/// error.Overflow if it is beyond the doubles.
pub fn toFloat(a: Allocator, d: Dec) Error!f64 {
    switch (d.kind) {
        .nan => return std.math.nan(f64),
        .pinf => return std.math.inf(f64),
        .ninf => return -std.math.inf(f64),
        .finite => {},
    }
    if (d.digits.len == 0) return 0;
    if (d.point > 310) return error.Overflow;
    // 0.ddd...e<point>
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.ensureTotalCapacity(a, d.digits.len + 16);
    if (d.neg) buf.appendAssumeCapacity('-');
    buf.appendSliceAssumeCapacity("0.");
    for (d.digits) |c| buf.appendAssumeCapacity('0' + c);
    try buf.print(a, "e{d}", .{d.point});
    const v = std.fmt.parseFloat(f64, buf.items) catch return error.Invalid;
    if (std.math.isInf(v)) return error.Overflow;
    return v;
}

/// numeric(p, s) of `d` (apply_typmod()): rounded to s digits, display
/// scale max(s, 0); error.Overflow ("numeric field overflow") if the
/// number has more than p - s digits before the point or is infinite.
/// NaN fits any.
pub fn applyTypmod(a: Allocator, d: Dec, p: i32, s: i32) Error!Dec {
    switch (d.kind) {
        .nan => return d,
        .pinf, .ninf => return error.Overflow,
        .finite => {},
    }
    var r = try cut(a, d, s, .half);
    r.dscale = @intCast(@max(s, 0));
    r.scale_known = true;
    const maxdigits = p - s;
    if (r.digits.len > 0 and r.point > maxdigits) return error.Overflow;
    return r;
}

/// The DETAIL of applyTypmod()'s "numeric field overflow" of `d`
/// (apply_typmod()'s), in `buf` (160 bytes hold any).
pub fn overflowDetail(buf: []u8, d: Dec, p: i64, s: i64) []const u8 {
    const head = "A field with precision {d}, scale {d} ";
    const maxdigits = p - s;
    return (if (d.kind != .finite)
        std.fmt.bufPrint(buf, head ++ "cannot hold an infinite value.", .{ p, s })
    else if (maxdigits != 0)
        std.fmt.bufPrint(buf, head ++ "must round to an absolute value less than 10^{d}.", .{ p, s, maxdigits })
    else
        std.fmt.bufPrint(buf, head ++ "must round to an absolute value less than 1.", .{ p, s })) catch "";
}

/// Whether finite `d` is a value of numeric(p, s) as is: no digit after
/// power -s, at most p - s digits before the point.
pub fn fitsTypmod(d: Dec, p: i32, s: i32) bool {
    switch (d.kind) {
        .nan => return true,
        .pinf, .ninf => return false,
        .finite => {},
    }
    if (d.digits.len == 0) return true;
    if (@as(i64, @intCast(d.digits.len)) - d.point > s) return false;
    return d.point <= p - s;
}

// ======================================================= PostgreSQL wire

/// PostgreSQL's binary numeric (numeric_send()): ndigits, weight, sign,
/// dscale (int16 each, big-endian), then the base-10000 digits.
pub fn toPgBinary(a: Allocator, d: Dec) Error![]u8 {
    const sign: u16 = switch (d.kind) {
        .nan => 0xC000,
        .pinf => 0xD000,
        .ninf => 0xF000,
        .finite => if (d.neg) 0x4000 else 0x0000,
    };
    if (d.kind != .finite or d.digits.len == 0) {
        const out = try a.alloc(u8, 8);
        std.mem.writeInt(u16, out[0..2], 0, .big);
        std.mem.writeInt(i16, out[2..4], 0, .big);
        std.mem.writeInt(u16, out[4..6], sign, .big);
        std.mem.writeInt(u16, out[6..8], if (d.kind == .finite) @intCast(d.dscale) else 0, .big);
        return out;
    }
    const top: i64 = @as(i64, d.point) - 1;
    const low: i64 = @as(i64, d.point) - @as(i64, @intCast(d.digits.len));
    const w_hi = @divFloor(top, 4);
    const w_lo = @divFloor(low, 4);
    const n: usize = @intCast(w_hi - w_lo + 1);
    const out = try a.alloc(u8, 8 + 2 * n);
    std.mem.writeInt(u16, out[0..2], @intCast(n), .big);
    std.mem.writeInt(i16, out[2..4], @intCast(w_hi), .big);
    std.mem.writeInt(u16, out[4..6], sign, .big);
    std.mem.writeInt(u16, out[6..8], @intCast(d.dscale), .big);
    var w = w_hi;
    var i: usize = 0;
    while (w >= w_lo) : (w -= 1) {
        var v: u16 = 0;
        var p: i64 = w * 4 + 3;
        while (p >= w * 4) : (p -= 1) v = v * 10 + d.digitAt(p);
        std.mem.writeInt(u16, out[8 + 2 * i ..][0..2], v, .big);
        i += 1;
    }
    return out;
}

/// numeric_recv(): the number of PostgreSQL's binary numeric.
pub fn fromPgBinary(a: Allocator, b: []const u8) Error!Dec {
    if (b.len < 8) return error.Invalid;
    const n = std.mem.readInt(u16, b[0..2], .big);
    const weight = std.mem.readInt(i16, b[2..4], .big);
    const sign = std.mem.readInt(u16, b[4..6], .big);
    const dscale = std.mem.readInt(u16, b[6..8], .big);
    switch (sign) {
        0xC000 => return .nan,
        0xD000 => return .pinf,
        0xF000 => return .ninf,
        0x0000, 0x4000 => {},
        else => return error.Invalid,
    }
    if (b.len != 8 + 2 * @as(usize, n)) return error.Invalid;
    if (dscale > max_dscale) return error.Invalid;
    const raw = try a.alloc(u8, 4 * @as(usize, n));
    for (0..n) |i| {
        const v = std.mem.readInt(u16, b[8 + 2 * i ..][0..2], .big);
        if (v >= 10000) return error.Invalid;
        raw[4 * i] = @intCast(v / 1000);
        raw[4 * i + 1] = @intCast(v / 100 % 10);
        raw[4 * i + 2] = @intCast(v / 10 % 10);
        raw[4 * i + 3] = @intCast(v % 10);
    }
    // raw[0] is at power 4 * weight + 3.
    var d = normalize(raw, 4 * @as(i64, weight) + 4, sign == 0x4000, 0);
    // PostgreSQL truncates digits the scale hides.
    if (d.fracDigits() > dscale) d = try trunc(a, d, dscale);
    d.dscale = dscale;
    try check(d);
    return d;
}

// ================================================================ tests

const testing = std.testing;

fn pz(a: Allocator, z: []const u8) !Dec {
    return parse(a, z);
}

fn expectText(want: []const u8, d: Dec) !void {
    const z = try toText(testing.allocator, d);
    defer testing.allocator.free(z);
    try testing.expectEqualStrings(want, z);
}

test "decimal: numeric_in and numeric_out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "0", "0" },               .{ "1.50", "1.50" },          .{ "-1.50", "-1.50" },
        .{ " 12.3400 ", "12.3400" }, .{ "00012.3400", "12.3400" }, .{ "-000.000", "0.000" },
        .{ "1e-3", "0.001" },        .{ "1.5E-1", "0.15" },        .{ ".5", "0.5" },
        .{ "5.", "5" },              .{ "1.5e+2", "150" },         .{ "1.55e1", "15.5" },
        .{ "+.5e-3", "0.0005" },     .{ "1_000.5", "1000.5" },     .{ "0x1F", "31" },
        .{ "0x_1F", "31" },          .{ "-0b101", "-5" },          .{ "0o17", "15" },
        .{ "NaN", "NaN" },           .{ " nan ", "NaN" },          .{ "-Infinity", "-Infinity" },
        .{ "inf", "Infinity" },      .{ "+INF", "Infinity" },      .{ "1.5_5e1_0", "15500000000" },
        .{ "-0", "0" },              .{ "0e10", "0" },             .{ "0.000e-3", "0.000000" },
        .{ "100", "100" },           .{ "0.01", "0.01" },          .{ "123456789012345678901234567890.123", "123456789012345678901234567890.123" },
    };
    for (cases) |c| try expectText(c[1], try pz(a, c[0]));
    for ([_][]const u8{ "abc", "1_000_", "1__0", "0x", "0x1.5", "1e", ".", "1_.5", "1._5", "1e+", "1 2", "-nan", "", "+", "1.2.3" }) |z| {
        try testing.expectError(error.Invalid, pz(a, z));
    }
    try testing.expectError(error.Overflow, pz(a, "1e-16384"));
    try testing.expectError(error.Overflow, pz(a, "1e131072"));
    try testing.expectError(error.Overflow, pz(a, "1e2147483648"));
    try testing.expectEqual(@as(usize, 131072), textLen(try pz(a, "1e131071")));
    try testing.expectEqual(@as(usize, 16385), textLen(try pz(a, "1e-16383")));
}

test "decimal: arithmetic and scales as PostgreSQL's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectText("2.50", try add(a, try pz(a, "1.50"), try pz(a, "1")));
    try expectText("0.3", try add(a, try pz(a, "0.1"), try pz(a, "0.2")));
    try expectText("2.000000000000000000001", try add(a, try pz(a, "1.000000000000000000001"), try pz(a, "1")));
    try expectText("-0.5", try sub(a, try pz(a, "1"), try pz(a, "1.5")));
    try expectText("0.0", try sub(a, try pz(a, "1.5"), try pz(a, "1.5")));
    try expectText("1000", try add(a, try pz(a, "999"), try pz(a, "1")));
    try expectText("2.2500", try mul(a, try pz(a, "1.50"), try pz(a, "1.50")));
    try expectText("-6", try mul(a, try pz(a, "-2"), try pz(a, "3")));
    try expectText("2.5000000000000000", try div(a, try pz(a, "10.0"), try pz(a, "4")));
    try expectText("0.66666666666666666667", try div(a, try pz(a, "2"), try pz(a, "3")));
    try expectText("0.33333333333333333333", try div(a, try pz(a, "1"), try pz(a, "3")));
    try expectText("33.3333333333333333", try div(a, try pz(a, "100"), try pz(a, "3")));
    try expectText("0.000003333333333333333333", try div(a, try pz(a, "1"), try pz(a, "300000")));
    try expectText("1763668414462081127", try div(a, try pz(a, "12345678901234567890"), try pz(a, "7")));
    try expectText("0.000000333333333333333333", try div(a, try pz(a, "0.000001"), try pz(a, "3")));
    try testing.expectError(error.DivisionByZero, div(a, try pz(a, "1"), try pz(a, "0")));
    try expectText("NaN", try div(a, Dec.nan, try pz(a, "0")));
    try expectText("1.5", try mod(a, try pz(a, "7.5"), try pz(a, "2")));
    try expectText("-1.5", try mod(a, try pz(a, "-7.5"), try pz(a, "2")));
    try expectText("2.0", try mod(a, try pz(a, "7"), try pz(a, "2.5")));
    try expectText("3", try divTrunc(a, try pz(a, "7.5"), try pz(a, "2")));
    try expectText("-3", try divTrunc(a, try pz(a, "-7.5"), try pz(a, "2")));
    try expectText("NaN", try mod(a, Dec.pinf, try pz(a, "2")));
    try expectText("2", try mod(a, try pz(a, "2"), Dec.pinf));
    try expectText("NaN", try add(a, Dec.pinf, Dec.ninf));
    try expectText("NaN", try mul(a, Dec.pinf, try pz(a, "0")));
    try expectText("NaN", try div(a, Dec.pinf, Dec.pinf));
    try expectText("0", try div(a, try pz(a, "1"), Dec.pinf));
    try expectText("3", try round(a, try pz(a, "2.5"), 0));
    try expectText("-3", try round(a, try pz(a, "-2.5"), 0));
    try expectText("1.23", try round(a, try pz(a, "1.2345"), 2));
    try expectText("1200", try round(a, try pz(a, "1234.5"), -2));
    try expectText("10", try round(a, try pz(a, "5"), -1));
    try expectText("1.500", try round(a, try pz(a, "1.5"), 3));
    try expectText("1.000", try round(a, try pz(a, "0.9995"), 3));
    try expectText("0", try round(a, try pz(a, "0.4"), 0));
    try expectText("-1", try trunc(a, try pz(a, "-1.99"), 0));
    try expectText("-1", try ceil(a, try pz(a, "-1.5")));
    try expectText("-2", try floor(a, try pz(a, "-1.5")));
    try expectText("1", try ceil(a, try pz(a, "1.000")));
    try expectText("2", try ceil(a, try pz(a, "1.001")));
    try expectText("1", try ceil(a, try pz(a, "0.001")));
    try expectText("0", try ceil(a, try pz(a, "-0.5")));
    try expectText("-1", try floor(a, try pz(a, "-0.5")));
    try expectText("12.35", try applyTypmod(a, try pz(a, "12.345"), 4, 2));
    try testing.expectError(error.Overflow, applyTypmod(a, try pz(a, "999.995"), 5, 2));
    try testing.expectError(error.Overflow, applyTypmod(a, try pz(a, "9.5"), 1, 0));
    try testing.expectError(error.Overflow, applyTypmod(a, Dec.pinf, 5, 2));
    try testing.expectError(error.Overflow, applyTypmod(a, try pz(a, "0.0123"), 2, 4));
    try expectText("1", try applyTypmod(a, try pz(a, "0.5"), 1, 0));
    try expectText("0", try applyTypmod(a, try pz(a, "1.23"), 3, -1));
    try expectText("20", try applyTypmod(a, try pz(a, "15"), 2, -1));
    try expectText("0.333333333333333", try fromFloat(a, 1.0 / 3.0));
    try expectText("0.3", try fromFloat(a, 0.1 + 0.2));
    try expectText("0.00000000015", try fromFloat(a, 1.5e-10));
    try expectText("-2", try fromFloat(a, -2.0));
    try testing.expectEqual(@as(i64, 3), try toInt(a, try pz(a, "2.5")));
    try testing.expectEqual(@as(i64, -3), try toInt(a, try pz(a, "-2.5")));
    try testing.expectError(error.Overflow, toInt(a, try pz(a, "9223372036854775807.5")));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try toInt(a, try pz(a, "-9223372036854775808")));
    try testing.expectEqual(@as(f64, 0.1), try toFloat(a, try pz(a, "0.1")));
    try testing.expectError(error.Overflow, toFloat(a, try pz(a, "1e400")));
    try testing.expectEqual(@as(u32, 20), divScale(try pz(a, "1"), try pz(a, "3")));
    try testing.expectEqual(@as(usize, 16385), textLen(try mul(a, try pz(a, "1e-16383"), try pz(a, "1e-5"))));
    try testing.expectError(error.Overflow, mul(a, try pz(a, "1e131071"), try pz(a, "10")));
}

test "decimal: keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k = struct {
        fn of(al: Allocator, z: []const u8) ![]u8 {
            return key(al, try parse(al, z), false);
        }
    }.of;
    try testing.expectEqualSlices(u8, &.{0x30}, try k(a, "0.00"));
    try testing.expectEqualSlices(u8, &.{0x60}, try k(a, "NaN"));
    // 1 = 0.01 x 100^1; 1.5 = 0.0150 x 100^1.
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 2 }, try k(a, "1"));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 3, 100 }, try k(a, "1.5"));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 3, 100 }, try k(a, "1.50"));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 198 }, try k(a, "99"));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x82, 2 }, try k(a, "100"));
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x80, 20 }, try k(a, "0.1"));
    try testing.expectEqualSlices(u8, &.{ 0x20, 255 - 0x81, 255 - 2 }, try k(a, "-1"));
    // The long exponents.
    const big = try k(a, "1e300");
    try testing.expectEqualSlices(u8, &.{ 0x40, 0xFE, 0, 25, 2 }, big);
    const small = try k(a, "1e-300");
    try testing.expectEqual(@as(u8, 0x01), small[1]);
    // The scale after the key.
    const s = try key(a, try parse(a, "1.50"), true);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 3, 100, 0, 2 }, s);
    const back = try decodeKey(a, s);
    try expectText("1.50", back.dec);
    try testing.expectEqual(@as(?u32, 2), back.scale);
    try testing.expect(isPureKey(try k(a, "1.5")));
    // A scale equal to the digits is kept (it is known); a stored key has
    // none, a double's either.
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 3, 100, 0, 1 }, try key(a, try parse(a, "1.5"), true));
    try testing.expect(!(try decodeKey(a, try k(a, "1.5"))).dec.scale_known);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x81, 3, 100 }, try key(a, try fromFloat(a, 1.5), true));
    const sum = try add(a, (try decodeKey(a, try k(a, "1.5"))).dec, try parse(a, "1.00"));
    try testing.expect(!sum.scale_known);
    try testing.expect(!isPureKey(s));
    for ([_][]const u8{ "", "\x00", "\x40", "\x40\x81", "\x40\x81\x03", "\x40\x81\x01\x02", "\x40\x81\x00", "\x40\x01\xFF\xFF\x02", "\x30\x40\x00", "\x40\x81\x02\x00\x00\x00", "\x40\x81\x02\x00", "\x40\x81\xc9", "x" }) |bad| {
        try testing.expectError(error.Invalid, decodeKey(a, bad));
    }
}

/// A random decimal text: a sign, up to `n` digits around a point, an
/// exponent; or NaN, an infinity.
fn randomText(r: std.Random, buf: []u8, n: usize) []const u8 {
    switch (r.uintLessThan(u8, 40)) {
        0 => return "NaN",
        1 => return "Infinity",
        2 => return "-Infinity",
        3 => return "0",
        else => {},
    }
    var w: std.Io.Writer = .fixed(buf);
    if (r.boolean()) w.writeByte('-') catch {};
    const len = 1 + r.uintLessThan(usize, n);
    const pt = r.uintAtMost(usize, len);
    for (0..len) |i| {
        if (i == pt and i > 0) w.writeByte('.') catch {};
        // Mostly few distinct digits, so that numbers often share a prefix.
        const dg: u8 = if (r.uintLessThan(u8, 3) == 0) r.uintLessThan(u8, 10) else @as(u8, if (r.boolean()) 0 else 9);
        w.writeByte('0' + dg) catch {};
    }
    if (r.uintLessThan(u8, 4) == 0) w.print("e{d}", .{r.intRangeAtMost(i32, -400, 400)}) catch {};
    return w.buffered();
}

/// The rational value of finite `d` as a fraction num / 10^den_pow, for
/// the reference of std.math.big.
fn toBig(a: Allocator, d: Dec, scale: i64) !std.math.big.int.Managed {
    // d x 10^scale, an integer (scale at least the digits after the point).
    var m = try std.math.big.int.Managed.init(a);
    if (d.digits.len > 0) {
        const z = try a.alloc(u8, d.digits.len);
        for (d.digits, z) |dg, *c| c.* = '0' + dg;
        try m.setString(10, z);
    }
    const shift = scale - (@as(i64, @intCast(d.digits.len)) - d.point);
    var ten = try std.math.big.int.Managed.initSet(a, 10);
    var pw = try std.math.big.int.Managed.init(a);
    try pw.pow(&ten, @intCast(shift));
    try m.mul(&m, &pw);
    if (d.neg) m.negate();
    return m;
}

test "decimal: memcmp order is the numbers' order, keys round-trip (property)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed_decf);
    const r = prng.random();
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    for (0..4000) |_| {
        _ = arena.reset(.retain_capacity);
        const x = parse(a, randomText(r, &b1, 40)) catch continue;
        const y = parse(a, randomText(r, &b2, 40)) catch continue;
        const kx = try key(a, x, false);
        const ky = try key(a, y, false);
        try testing.expectEqual(order(x, y), std.mem.order(u8, kx, ky));
        try testing.expectEqual(order(x, y) == .eq, std.mem.eql(u8, kx, ky));
        // The scale suffix never changes the order of different numbers.
        const sx = try key(a, x, true);
        const sy = try key(a, y, true);
        if (order(x, y) != .eq) try testing.expectEqual(order(x, y), std.mem.order(u8, sx, sy));
        // Round trip, and the one key of a number.
        const back = try decodeKey(a, sx);
        try testing.expectEqual(std.math.Order.eq, order(x, back.dec));
        try testing.expectEqual(@max(x.dscale, x.fracDigits()), back.dec.dscale);
        try testing.expectEqualSlices(u8, kx, try key(a, back.dec, false));
        // The order of the numbers is the order of the reference.
        if (x.kind == .finite and y.kind == .finite) {
            const sc: i64 = @max(x.fracDigits(), y.fracDigits());
            var bx = try toBig(a, x, sc);
            var by = try toBig(a, y, sc);
            try testing.expectEqual(bx.order(by), order(x, y));
            _ = .{ &bx, &by };
        }
    }
}

test "decimal: arithmetic against std.math.big (property)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0xdec_a7e5);
    const r = prng.random();
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    for (0..3000) |_| {
        _ = arena.reset(.retain_capacity);
        const x = parse(a, randomText(r, &b1, 30)) catch continue;
        const y = parse(a, randomText(r, &b2, 30)) catch continue;
        if (x.kind != .finite or y.kind != .finite) continue;
        if (@abs(@as(i64, x.point)) > 200 or @abs(@as(i64, y.point)) > 200) continue;
        const sc: i64 = @max(x.fracDigits(), y.fracDigits());
        const bx = try toBig(a, x, sc);
        const by = try toBig(a, y, sc);
        // x + y, x - y at scale sc; x * y at 2 sc.
        var want = try std.math.big.int.Managed.init(a);
        try want.add(&bx, &by);
        var got = try toBig(a, try add(a, x, y), sc);
        try testing.expect(want.eql(got));
        try want.sub(&bx, &by);
        got = try toBig(a, try sub(a, x, y), sc);
        try testing.expect(want.eql(got));
        try want.mul(&bx, &by);
        got = try toBig(a, try mul(a, x, y), 2 * sc);
        try testing.expect(want.eql(got));
        // x / y truncated at 6 digits: floor of |x| 10^6 / |y|.
        if (!y.isZero()) {
            const q = try divide(a, x, y, 6, false);
            var n6 = try toBig(a, x, sc + 6);
            var dd = try toBig(a, y, sc);
            n6.abs();
            dd.abs();
            var qq = try std.math.big.int.Managed.init(a);
            var rr = try std.math.big.int.Managed.init(a);
            try qq.divTrunc(&rr, &n6, &dd);
            if ((x.neg != y.neg) and !qq.eqlZero()) qq.negate();
            got = try toBig(a, q, 6);
            try testing.expect(qq.eql(got));
            // x = div(x, y) * y + x % y.
            const t = try divTrunc(a, x, y);
            const m = try mod(a, x, y);
            const back = try add(a, try mul(a, t, y), m);
            try testing.expectEqual(std.math.Order.eq, order(back, x));
        }
        // round and trunc agree with each other.
        const s = r.intRangeAtMost(i64, -5, 8);
        const rd = try round(a, x, s);
        const tr = try trunc(a, x, s);
        const diff = try sub(a, rd, tr);
        try testing.expect(diff.isZero() or diff.digits.len == 1 and diff.digits[0] == 1 and diff.point == -s + 1);
        // The PostgreSQL binary form round-trips.
        const bin = try toPgBinary(a, x);
        const back = try fromPgBinary(a, bin);
        try testing.expectEqual(std.math.Order.eq, order(back, x));
        try testing.expectEqual(x.dscale, back.dscale);
    }
}
