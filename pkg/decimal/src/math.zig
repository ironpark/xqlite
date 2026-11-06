//! numeric's sqrt(), exp(), ln(), log(), power() and factorial() as
//! PostgreSQL 18 computes them (numeric.c): the same result scale, the
//! same digits, the same errors.
//!
//! In the decimal package with root.zig, whose numbers (Dec) these
//! take and give; src/dialect/decimal_sql.zig makes the engine functions
//! xq_dec_sqrt() ... of them.
//!
//! PostgreSQL computes these in base 10000 (NBASE) with scales chosen
//! from the weights of base-10000 digits (sqrt's result scale, the
//! estimate of ln()'s weight, power()'s working precision) and with
//! intermediate results that are rounded, or truncated, where it rounds
//! them. To give its digits, this file does the same steps on the same
//! representation (Var, PostgreSQL's NumericVar):
//!  - add(), sub(), the exact division (div_var() with a short or exact
//!    divisor, div_var_int()) and sqrtVar() (div_var()'s Karatsuba square
//!    root, whose result is the exact root truncated past the result
//!    scale) are exact, then rounded half away from zero (round_var());
//!  - mul() is mul_var(): it leaves out the digit products that fall
//!    beyond its guard digits, as mul_var() does;
//!  - div() of a long divisor and an inexact result is div_var()'s
//!    approximate long division, with its floating-point quotient digits
//!    and its carry propagation;
//!  - the rest (exp_var(), ln_var(), log_var(), power_var(),
//!    power_var_int(), estimate_ln_dweight()) is PostgreSQL's code.

const std = @import("std");
const dec = @import("root.zig");

const Dec = dec.Dec;
const Allocator = std.mem.Allocator;
const Big = std.math.big.int.Managed;

/// What these fail with; errorInfo() gives PostgreSQL's SQLSTATE and
/// message of each.
pub const Error = error{
    OutOfMemory,
    Overflow,
    DivisionByZero,
    SqrtNegative,
    LogZero,
    LogNegative,
    ZeroNegativePower,
    ComplexPower,
    FactorialNegative,
    /// width_bucket()'s (of numerics and of doubles).
    BucketCount,
    BucketNaN,
    BucketInfinite,
    BucketEqual,
    IntegerRange,
};

/// The SQLSTATE and message of an error, null for OutOfMemory.
pub fn errorInfo(err: Error) ?struct { [5]u8, []const u8 } {
    return switch (err) {
        error.OutOfMemory => null,
        error.Overflow => .{ "22003".*, "value overflows numeric format" },
        error.DivisionByZero => .{ "22012".*, "division by zero" },
        error.SqrtNegative => .{ "2201F".*, "cannot take square root of a negative number" },
        error.LogZero => .{ "2201E".*, "cannot take logarithm of zero" },
        error.LogNegative => .{ "2201E".*, "cannot take logarithm of a negative number" },
        error.ZeroNegativePower => .{ "2201F".*, "zero raised to a negative power is undefined" },
        error.ComplexPower => .{ "2201F".*, "a negative number raised to a non-integer power yields a complex result" },
        error.FactorialNegative => .{ "22003".*, "factorial of a negative number is undefined" },
        error.BucketCount => .{ "2201G".*, "count must be greater than zero" },
        error.BucketNaN => .{ "2201G".*, "operand, lower bound, and upper bound cannot be NaN" },
        error.BucketInfinite => .{ "2201G".*, "lower and upper bounds must be finite" },
        error.BucketEqual => .{ "2201G".*, "lower bound cannot equal upper bound" },
        error.IntegerRange => .{ "22003".*, "integer out of range" },
    };
}

const nbase: i32 = 10000;
const half_nbase: i32 = 5000;
const nbase_sqr: i64 = 10000 * 10000;
const dec_digits: i32 = 4;
const mul_guard_digits: i32 = 2;
const div_guard_digits: i32 = 4;
const min_sig_digits = dec.min_sig_digits;
const min_display_scale: i32 = 0;
const max_display_scale = dec.max_display_scale;
const max_result_scale: i32 = 2000;
const weight_max: i32 = 32767;
const round_powers = [4]i32{ 0, 1000, 100, 10 };

/// PostgreSQL's NumericVar: value = sum digits[i] x 10000^(weight - i).
const Var = struct {
    neg: bool = false,
    weight: i32 = 0,
    digits: []const i32 = &.{},
    dscale: i32 = 0,

    fn isZero(v: Var) bool {
        for (v.digits) |d| if (d != 0) return false;
        return true;
    }
};

const one: Var = .{ .digits = &.{1} };
const two: Var = .{ .digits = &.{2} };
const ten: Var = .{ .digits = &.{10} };
const zero_point_nine: Var = .{ .weight = -1, .digits = &.{9000}, .dscale = 1 };
const one_point_one: Var = .{ .digits = &.{ 1, 1000 }, .dscale = 1 };

fn zeroScale(rscale: i32) Var {
    return .{ .dscale = rscale };
}

// ======================================================= representation

fn fromDec(a: Allocator, d: Dec) Allocator.Error!Var {
    std.debug.assert(d.kind == .finite);
    const ds: i32 = @intCast(d.dscale);
    if (d.digits.len == 0) return .{ .dscale = ds };
    const n: i64 = @intCast(d.digits.len);
    const hi = @divFloor(@as(i64, d.point) - 1, dec_digits);
    const lo = @divFloor(@as(i64, d.point) - n, dec_digits);
    const out = try a.alloc(i32, @intCast(hi - lo + 1));
    @memset(out, 0);
    for (d.digits, 0..) |c, i| {
        const p = @as(i64, d.point) - 1 - @as(i64, @intCast(i));
        const g = @divFloor(p, dec_digits);
        const shift: u2 = @intCast(p - g * dec_digits);
        const mult: i32 = switch (shift) {
            0 => 1,
            1 => 10,
            2 => 100,
            3 => 1000,
        };
        out[@intCast(hi - g)] += @as(i32, c) * mult;
    }
    return .{ .neg = d.neg, .weight = @intCast(hi), .digits = out, .dscale = ds };
}

fn toDec(a: Allocator, v0: Var) Error!Dec {
    const v = strip(v0);
    const ds: u32 = @intCast(@max(v.dscale, 0));
    if (v.digits.len == 0) return .{ .dscale = ds };
    const raw = try a.alloc(u8, v.digits.len * 4);
    for (v.digits, 0..) |d, i| {
        var x: u32 = @intCast(d);
        var k: usize = 4;
        while (k > 0) : (k -= 1) {
            raw[i * 4 + k - 1] = @intCast(x % 10);
            x /= 10;
        }
    }
    var s: usize = 0;
    while (raw[s] == 0) s += 1;
    var e = raw.len;
    while (raw[e - 1] == 0) e -= 1;
    const point = (@as(i64, v.weight) + 1) * dec_digits - @as(i64, @intCast(s));
    if (point > dec.max_point) return error.Overflow;
    return .{ .neg = v.neg, .digits = raw[s..e], .point = @intCast(point), .dscale = ds };
}

/// strip_var(): without leading and trailing zero digits; zero is
/// positive of weight 0.
fn strip(v: Var) Var {
    var r = v;
    var d = v.digits;
    while (d.len > 0 and d[0] == 0) {
        d = d[1..];
        r.weight -= 1;
    }
    while (d.len > 0 and d[d.len - 1] == 0) d = d[0 .. d.len - 1];
    if (d.len == 0) {
        r.neg = false;
        r.weight = 0;
    }
    r.digits = d;
    return r;
}

/// round_var(): rounded half away from zero to `rscale` digits after
/// the point (before it if negative); its dscale is rscale.
fn roundVar(a: Allocator, v: Var, rscale: i32) Allocator.Error!Var {
    var r = v;
    r.dscale = rscale;
    var di: i32 = (v.weight + 1) * dec_digits + rscale;
    if (di < 0) {
        r.digits = &.{};
        r.weight = 0;
        r.neg = false;
        return r;
    }
    const count: i32 = @divTrunc(di + dec_digits - 1, dec_digits);
    di = @rem(di, dec_digits);
    const n: i32 = @intCast(v.digits.len);
    if (!(count < n or (count == n and di > 0))) return r;
    // A spare digit before them for a carry.
    const buf = try a.alloc(i32, v.digits.len + 1);
    buf[0] = 0;
    @memcpy(buf[1..], v.digits);
    var k: i32 = count;
    var carry: i32 = 0;
    if (di == 0) {
        carry = if (buf[@intCast(k + 1)] >= half_nbase) 1 else 0;
    } else {
        k -= 1;
        var pow10 = round_powers[@intCast(di)];
        const at: usize = @intCast(k + 1);
        const extra = @rem(buf[at], pow10);
        buf[at] -= extra;
        if (extra >= @divTrunc(pow10, 2)) {
            pow10 += buf[at];
            if (pow10 >= nbase) {
                pow10 -= nbase;
                carry = 1;
            }
            buf[at] = pow10;
        }
    }
    while (carry != 0) {
        k -= 1;
        const at: usize = @intCast(k + 1);
        carry += buf[at];
        if (carry >= nbase) {
            buf[at] = carry - nbase;
            carry = 1;
        } else {
            buf[at] = carry;
            carry = 0;
        }
    }
    const c: usize = @intCast(count);
    if (k < 0) {
        r.digits = buf[0 .. c + 1];
        r.weight += 1;
    } else r.digits = buf[1 .. c + 1];
    return r;
}

/// trunc_var(): truncated to `rscale` digits after the point.
fn truncVar(a: Allocator, v: Var, rscale: i32) Allocator.Error!Var {
    var r = v;
    r.dscale = rscale;
    var di: i32 = (v.weight + 1) * dec_digits + rscale;
    if (di <= 0) {
        r.digits = &.{};
        r.weight = 0;
        r.neg = false;
        return r;
    }
    const count: i32 = @divTrunc(di + dec_digits - 1, dec_digits);
    if (count > v.digits.len) return r;
    const buf = try a.dupe(i32, v.digits[0..@intCast(count)]);
    di = @rem(di, dec_digits);
    if (di > 0) {
        const pow10 = round_powers[@intCast(di)];
        const last = buf.len - 1;
        buf[last] -= @rem(buf[last], pow10);
    }
    r.digits = buf;
    return r;
}

fn cmpAbs(x0: Var, y0: Var) std.math.Order {
    const x = strip(x0);
    const y = strip(y0);
    if (x.digits.len == 0) return if (y.digits.len == 0) .eq else .lt;
    if (y.digits.len == 0) return .gt;
    if (x.weight != y.weight) return std.math.order(x.weight, y.weight);
    const n = @max(x.digits.len, y.digits.len);
    for (0..n) |i| {
        const dx = if (i < x.digits.len) x.digits[i] else 0;
        const dy = if (i < y.digits.len) y.digits[i] else 0;
        if (dx != dy) return std.math.order(dx, dy);
    }
    return .eq;
}

fn sign(v: Var) i2 {
    if (v.isZero()) return 0;
    return if (v.neg) -1 else 1;
}

fn cmp(x: Var, y: Var) std.math.Order {
    const sx = sign(x);
    const sy = sign(y);
    if (sx != sy) return std.math.order(sx, sy);
    const o = cmpAbs(x, y);
    return if (sx < 0) o.invert() else o;
}

/// The lowest power of 10000 of `v`'s digits.
fn lowWeight(v: Var) i32 {
    return v.weight - @as(i32, @intCast(v.digits.len)) + 1;
}

fn addAbs(a: Allocator, x0: Var, y0: Var) Allocator.Error!Var {
    const x = strip(x0);
    const y = strip(y0);
    const ds = @max(x.dscale, y.dscale);
    if (x.digits.len == 0) return .{ .weight = y.weight, .digits = y.digits, .dscale = ds };
    if (y.digits.len == 0) return .{ .weight = x.weight, .digits = x.digits, .dscale = ds };
    const hi = @max(x.weight, y.weight) + 1;
    const lo = @min(lowWeight(x), lowWeight(y));
    const out = try a.alloc(i32, @intCast(hi - lo + 1));
    var carry: i32 = 0;
    var p = lo;
    while (p <= hi) : (p += 1) {
        const s = digitAt(x, p) + digitAt(y, p) + carry;
        carry = if (s >= nbase) 1 else 0;
        out[@intCast(hi - p)] = s - carry * nbase;
    }
    return strip(.{ .weight = hi, .digits = out, .dscale = ds });
}

/// |x| - |y| for |x| >= |y|.
fn subAbs(a: Allocator, x0: Var, y0: Var) Allocator.Error!Var {
    const x = strip(x0);
    const y = strip(y0);
    const ds = @max(x.dscale, y.dscale);
    if (y.digits.len == 0) return .{ .weight = x.weight, .digits = x.digits, .dscale = ds };
    const hi = x.weight;
    const lo = @min(lowWeight(x), lowWeight(y));
    const out = try a.alloc(i32, @intCast(hi - lo + 1));
    var borrow: i32 = 0;
    var p = lo;
    while (p <= hi) : (p += 1) {
        var s = digitAt(x, p) - digitAt(y, p) - borrow;
        borrow = 0;
        if (s < 0) {
            s += nbase;
            borrow = 1;
        }
        out[@intCast(hi - p)] = s;
    }
    return strip(.{ .weight = hi, .digits = out, .dscale = ds });
}

fn digitAt(v: Var, p: i32) i32 {
    const i = v.weight - p;
    if (i < 0 or i >= v.digits.len) return 0;
    return v.digits[@intCast(i)];
}

/// add_var().
fn add(a: Allocator, x: Var, y: Var) Allocator.Error!Var {
    const xn = x.neg and !x.isZero();
    const yn = y.neg and !y.isZero();
    if (xn == yn) {
        var r = try addAbs(a, x, y);
        r.neg = xn and r.digits.len > 0;
        return r;
    }
    switch (cmpAbs(x, y)) {
        .eq => return zeroScale(@max(x.dscale, y.dscale)),
        .gt => {
            var r = try subAbs(a, x, y);
            r.neg = xn and r.digits.len > 0;
            return r;
        },
        .lt => {
            var r = try subAbs(a, y, x);
            r.neg = yn and r.digits.len > 0;
            return r;
        },
    }
}

/// sub_var().
fn sub(a: Allocator, x: Var, y: Var) Allocator.Error!Var {
    var ny = y;
    ny.neg = !y.neg;
    return add(a, x, ny);
}

/// The base-10000^2 digit pair i of `d` (the last one shifted up if the
/// digits are odd).
fn pair(d: []const i32, i: usize) u64 {
    const hi: u64 = @intCast(d[2 * i]);
    const lo: u64 = if (2 * i + 1 < d.len) @intCast(d[2 * i + 1]) else 0;
    return hi * @as(u64, nbase) + lo;
}

/// mul_var(): x * y rounded to `rscale`, leaving out the digit products
/// beyond its guard digits as mul_var() does.
fn mul(a: Allocator, x0: Var, y0: Var, rscale: i32) Allocator.Error!Var {
    var x = strip(x0);
    var y = strip(y0);
    if (x.digits.len > y.digits.len) std.mem.swap(Var, &x, &y);
    if (x.digits.len == 0) return zeroScale(rscale);
    const exact = x.digits.len <= 6 and rscale == x.dscale + y.dscale;
    const n1: i32 = @intCast(x.digits.len);
    const n2: i32 = @intCast(y.digits.len);
    var p1 = @divTrunc(n1 + 1, 2);
    var p2 = @divTrunc(n2 + 1, 2);
    const res_ndigits = n1 + n2;
    var res_pairs = @divTrunc(res_ndigits, 2) + 1;
    const pair_offset = res_pairs - p1 - p2 + 1;
    const res_weight = x.weight + y.weight + 1 + 2 * res_pairs - res_ndigits - (n1 & 1) - (n2 & 1);
    if (!exact) {
        // mul_var_short() (exact) otherwise.
        const maxdigits = res_weight + 1 + @divTrunc(rscale + dec_digits - 1, dec_digits) + mul_guard_digits;
        res_pairs = @min(res_pairs, @divTrunc(maxdigits, 2) + 1);
    }
    if (res_pairs <= pair_offset) return zeroScale(rscale);
    p1 = @min(p1, res_pairs - pair_offset);
    p2 = @min(p2, res_pairs - pair_offset);
    const dig = try a.alloc(u128, @intCast(res_pairs));
    @memset(dig, 0);
    var j1: i32 = 0;
    while (j1 < p1) : (j1 += 1) {
        const d1 = pair(x.digits, @intCast(j1));
        if (d1 == 0) continue;
        const lim = @min(p2, res_pairs - j1 - pair_offset);
        var j2: i32 = 0;
        while (j2 < lim) : (j2 += 1) {
            dig[@intCast(j1 + j2 + pair_offset)] += @as(u128, d1) * pair(y.digits, @intCast(j2));
        }
    }
    const out = try a.alloc(i32, @intCast(2 * res_pairs));
    var carry: u128 = 0;
    var i: usize = dig.len;
    while (i > 0) {
        i -= 1;
        const v = dig[i] + carry;
        carry = v / @as(u128, nbase_sqr);
        const d: u64 = @intCast(v % @as(u128, nbase_sqr));
        out[2 * i] = @intCast(d / @as(u64, nbase));
        out[2 * i + 1] = @intCast(d % @as(u64, nbase));
    }
    std.debug.assert(carry == 0);
    const r = try roundVar(a, .{ .neg = x.neg != y.neg, .weight = res_weight, .digits = out }, rscale);
    return strip(r);
}

const Limb = std.math.big.Limb;
/// 10000^4, the base-10000 digits a limb takes at a time.
const chunk_base: u64 = 10000 * 10000 * 10000 * 10000;

/// The digits as a big integer: |v| / 10000^lowWeight(v), times
/// 10000^extra (extra may be negative: then truncated).
fn toBig(a: Allocator, v: Var, extra: i64) Error!Big {
    const total: usize = @intCast(@max(@as(i64, @intCast(v.digits.len)) + extra, 0));
    // log2(10000) < 14 bits a digit.
    const limbs = try a.alloc(Limb, total * 14 / @bitSizeOf(Limb) + 2);
    var len: usize = 1;
    limbs[0] = 0;
    // Four digits (10000^4 < 2^64) at a time, the first group shorter.
    var i: usize = 0;
    while (i < total) {
        const n = if (i == 0 and total % 4 != 0) total % 4 else 4;
        var group: u64 = 0;
        var mult: u64 = 1;
        for (i..i + n) |k| {
            group = group * 10000 + if (k < v.digits.len) @as(u64, @intCast(v.digits[k])) else 0;
            mult *= 10000;
        }
        i += n;
        var carry: u128 = group;
        for (limbs[0..len]) |*l| {
            const t = @as(u128, l.*) * mult + carry;
            l.* = @truncate(t);
            carry = t >> @bitSizeOf(Limb);
        }
        if (carry != 0) {
            limbs[len] = @intCast(carry);
            len += 1;
        }
    }
    var b: Big = .{ .allocator = a, .limbs = limbs, .metadata = 0 };
    b.setMetadata(true, len);
    return b;
}

/// The number b x 10000^low.
fn fromBig(a: Allocator, b: *const Big, low: i32, neg: bool) Error!Var {
    const c = b.toConst();
    if (c.eqlZero()) return .{};
    // Its groups of four digits (base 10000^4), the lowest first, by
    // repeated short division.
    const q = try a.dupe(Limb, c.limbs);
    var len = q.len;
    const groups = try a.alloc(u64, q.len * @bitSizeOf(Limb) / 53 + 2);
    var ng: usize = 0;
    while (len > 0) {
        var rem: u128 = 0;
        var k = len;
        while (k > 0) {
            k -= 1;
            const t = (rem << @bitSizeOf(Limb)) | q[k];
            q[k] = @intCast(t / chunk_base);
            rem = t % chunk_base;
        }
        groups[ng] = @intCast(rem);
        ng += 1;
        while (len > 0 and q[len - 1] == 0) len -= 1;
    }
    const out = try a.alloc(i32, ng * 4);
    for (0..ng) |g| {
        var x = groups[ng - 1 - g];
        var k: usize = 4;
        while (k > 0) {
            k -= 1;
            out[g * 4 + k] = @intCast(x % 10000);
            x /= 10000;
        }
    }
    return strip(.{ .neg = neg, .weight = low + @as(i32, @intCast(out.len)) - 1, .digits = out });
}

/// The quotient |x| / d (div_var_int()'s short division) truncated at
/// 10000^-f, of the sign `neg`.
fn divShort(a: Allocator, x: Var, d: u64, f: i32, neg: bool) Allocator.Error!Var {
    const n = @as(i64, x.weight) + f + 1;
    if (n <= 0) return .{};
    const out = try a.alloc(i32, @intCast(n));
    // r < d: r * 10000 + 9999 in a u64 while d is below 2^64 / 10000.
    if (d <= std.math.maxInt(u64) / 10000) {
        var r: u64 = 0;
        for (out, 0..) |*o, i| {
            r = r * 10000 + @as(u64, @intCast(digitAt(x, x.weight - @as(i32, @intCast(i)))));
            o.* = @intCast(r / d);
            r %= d;
        }
    } else {
        var r: u128 = 0;
        for (out, 0..) |*o, i| {
            r = r * 10000 + @as(u128, @intCast(digitAt(x, x.weight - @as(i32, @intCast(i)))));
            o.* = @intCast(r / d);
            r %= d;
        }
    }
    return strip(.{ .neg = neg, .weight = x.weight, .digits = out });
}

/// |v| as an integer if it is one below 10000^4.
fn shortInt(v: Var) ?u64 {
    if (lowWeight(v) < 0 or v.weight > 3) return null;
    var d: u64 = 0;
    var p = v.weight;
    while (p >= 0) : (p -= 1) d = d * 10000 + @as(u64, @intCast(digitAt(v, p)));
    return d;
}

/// x / y exactly, rounded (or truncated) to `rscale`: div_var() with an
/// exact result, div_var_int(), div_var_int64().
fn divExact(a: Allocator, x0: Var, y0: Var, rscale: i32, round: bool) Error!Var {
    const x = strip(x0);
    const y = strip(y0);
    if (y.digits.len == 0) return error.DivisionByZero;
    if (x.digits.len == 0) return zeroScale(rscale);
    // Truncated at 10000^-f, past rscale + 1 digits.
    const f = @divFloor(rscale, dec_digits) + 2;
    const r = if (shortInt(y)) |d| try divShort(a, x, d, f, x.neg != y.neg) else blk: {
        const t: i64 = @as(i64, lowWeight(x)) - lowWeight(y) + f;
        var n = try toBig(a, x, @max(t, 0));
        var d = try toBig(a, y, @max(-t, 0));
        var q = try Big.init(a);
        var rem = try Big.init(a);
        try q.divTrunc(&rem, &n, &d);
        break :blk try fromBig(a, &q, -f, x.neg != y.neg);
    };
    return strip(if (round) try roundVar(a, r, rscale) else try truncVar(a, r, rscale));
}

fn intVar(a: Allocator, v: i64) Allocator.Error!Var {
    var buf: [8]i32 = undefined;
    var m: u64 = @abs(v);
    var n: usize = 0;
    while (m > 0) : (m /= @as(u64, nbase)) {
        buf[buf.len - 1 - n] = @intCast(m % @as(u64, nbase));
        n += 1;
    }
    return .{ .neg = v < 0, .weight = @as(i32, @intCast(n)) - 1, .digits = try a.dupe(i32, buf[buf.len - n ..]) };
}

/// div_var_int(x, ival, 0, rscale, round).
fn divInt(a: Allocator, x0: Var, ival: i64, rscale: i32, round: bool) Error!Var {
    if (ival == 0) return error.DivisionByZero;
    const x = strip(x0);
    if (x.digits.len == 0) return zeroScale(rscale);
    const f = @divFloor(rscale, dec_digits) + 2;
    const r = try divShort(a, x, @abs(ival), f, x.neg != (ival < 0));
    return strip(if (round) try roundVar(a, r, rscale) else try truncVar(a, r, rscale));
}

/// div_var(x, y, rscale, round, exact).
fn div(a: Allocator, x0: Var, y0: Var, rscale: i32, round: bool, exact0: bool) Error!Var {
    const x = strip(x0);
    const y = strip(y0);
    if (y.digits.len == 0) return error.DivisionByZero;
    // A short divisor (div_var_int(), div_var_int64()), or one too short
    // for the approximate division to pay: exact.
    if (exact0 or y.digits.len <= 2 * (div_guard_digits + 2)) return divExact(a, x, y, rscale, round);
    if (x.digits.len == 0) return zeroScale(rscale);
    const n1: i32 = @intCast(x.digits.len);
    const n2: i32 = @intCast(y.digits.len);
    const res_weight = x.weight - y.weight + 1;
    var res_ndigits = @max(res_weight + 1 + @divTrunc(rscale + dec_digits - 1, dec_digits), 1);
    if (round) res_ndigits += 1;
    res_ndigits += div_guard_digits;
    var p1 = @divTrunc(n1 + 1, 2);
    var p2 = @divTrunc(n2 + 1, 2);
    const res_pairs = @divTrunc(res_ndigits + 1, 2);
    res_ndigits = 2 * res_pairs;
    const div_pairs = res_pairs;
    p1 = @min(p1, div_pairs);
    p2 = @min(p2, div_pairs);
    const dividend = try a.alloc(i64, @intCast(div_pairs + 1));
    @memset(dividend, 0);
    for (0..@intCast(p1)) |i| dividend[i] = @intCast(pair(x.digits, i));
    const divisor = try a.alloc(i64, @intCast(p2));
    for (divisor, 0..) |*d, i| d.* = @intCast(pair(y.digits, i));
    const fnbase_sqr: f64 = @floatFromInt(nbase_sqr);
    var fdivisor = @as(f64, @floatFromInt(divisor[0])) * fnbase_sqr;
    if (p2 > 1) fdivisor += @floatFromInt(divisor[1]);
    const fdivisorinverse = 1.0 / fdivisor;
    const int64_max = std.math.maxInt(i64);
    const limit = @divTrunc(int64_max - @divTrunc(int64_max, nbase_sqr) - 1, nbase_sqr - 1);
    var maxdiv: i64 = 1;
    var qi: i32 = 0;
    while (qi < res_pairs) : (qi += 1) {
        const q: usize = @intCast(qi);
        var qdigit = quotientDigit(dividend[q], dividend[q + 1], fdivisorinverse);
        if (qdigit != 0) {
            maxdiv += @intCast(@abs(qdigit));
            if (maxdiv > limit) {
                var carry: i64 = 0;
                var i: i32 = @min(qi + p2 - 2, div_pairs - 1);
                while (i > qi) : (i -= 1) {
                    const at: usize = @intCast(i);
                    const nd = normalize(dividend[at] + carry, &carry);
                    dividend[at] = nd;
                }
                dividend[q] += carry;
                maxdiv = 1;
                qdigit = quotientDigit(dividend[q], dividend[q + 1], fdivisorinverse);
                maxdiv += @intCast(@abs(qdigit));
            }
            if (qdigit != 0) {
                const istop: usize = @intCast(@min(p2, div_pairs - qi));
                for (0..istop) |i| dividend[q + i] -%= @as(i64, qdigit) *% divisor[i];
            }
        }
        dividend[q + 1] +%= dividend[q] *% nbase_sqr;
        dividend[q] = qdigit;
    }
    const out = try a.alloc(i32, @intCast(res_ndigits));
    var carry: i64 = 0;
    var i: usize = @intCast(res_pairs);
    while (i > 0) {
        i -= 1;
        const nd = normalize(dividend[i] + carry, &carry);
        out[2 * i + 1] = @intCast(@rem(nd, nbase));
        out[2 * i] = @intCast(@divTrunc(nd, nbase));
    }
    std.debug.assert(carry == 0);
    const r: Var = .{ .neg = x.neg != y.neg, .weight = res_weight, .digits = out };
    return strip(if (round) try roundVar(a, r, rscale) else try truncVar(a, r, rscale));
}

/// div_var()'s estimate of a quotient digit, truncated towards -infinity.
fn quotientDigit(d0: i64, d1: i64, inverse: f64) i32 {
    const fdividend = @as(f64, @floatFromInt(d0)) * @as(f64, @floatFromInt(nbase_sqr)) + @as(f64, @floatFromInt(d1));
    const fq = fdividend * inverse;
    const t: i32 = @intFromFloat(fq);
    return if (fq >= 0) t else t - 1;
}

/// A base-10000^2 digit in 0 .. 10000^2 - 1 and its carry.
fn normalize(newdig0: i64, carry: *i64) i64 {
    var newdig = newdig0;
    if (newdig < 0) {
        carry.* = -@divTrunc(-newdig - 1, nbase_sqr) - 1;
        newdig -= carry.* * nbase_sqr;
    } else if (newdig >= nbase_sqr) {
        carry.* = @divTrunc(newdig, nbase_sqr);
        newdig -= carry.* * nbase_sqr;
    } else carry.* = 0;
    return newdig;
}

/// sqrt_var(): the square root rounded to `rscale` (which may be
/// negative). PostgreSQL's Karatsuba root is the exact root truncated
/// past rscale + 1 digits, then rounded: the exact root rounded.
fn sqrtVar(a: Allocator, x0: Var, rscale: i32) Error!Var {
    const x = strip(x0);
    switch (sign(x)) {
        0 => return zeroScale(rscale),
        -1 => return error.SqrtNegative,
        else => {},
    }
    // The root truncated at 10000^-f, past rscale + 1 digits.
    const f = @divFloor(rscale + 1, dec_digits) + 1;
    var n = try toBig(a, x, @as(i64, lowWeight(x)) + 2 * @as(i64, f));
    var s = try Big.init(a);
    s.sqrt(&n) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    const r = try fromBig(a, &s, -f, false);
    return strip(try roundVar(a, r, rscale));
}

/// numericvar_to_double_no_overflow(): the double of the text.
fn toDouble(a: Allocator, v0: Var) Error!f64 {
    const v = strip(v0);
    if (v.digits.len == 0) return 0;
    var buf: std.ArrayList(u8) = .empty;
    if (v.neg) try buf.append(a, '-');
    try buf.appendSlice(a, "0.");
    for (v.digits) |d| try buf.print(a, "{d:0>4}", .{@as(u32, @intCast(d))});
    try buf.print(a, "e{d}", .{(@as(i64, v.weight) + 1) * dec_digits});
    return std.fmt.parseFloat(f64, buf.items) catch unreachable;
}

/// numericvar_to_int64(): v rounded to an integer, null beyond int64.
fn toInt64(a: Allocator, v: Var) Error!?i64 {
    const r = strip(try roundVar(a, v, 0));
    if (r.digits.len == 0) return 0;
    var val: i128 = 0;
    var i: i32 = 0;
    while (i <= r.weight) : (i += 1) {
        val = val * nbase + (if (i < r.digits.len) r.digits[@intCast(i)] else 0);
        if (val > std.math.maxInt(i64) + 1) return null;
    }
    if (r.neg) val = -val;
    return std.math.cast(i64, val);
}

/// Whether v is integral by its digits (ndigits <= weight + 1).
fn integral(v0: Var) bool {
    const v = strip(v0);
    return v.digits.len == 0 or v.digits.len <= v.weight + 1;
}

/// Whether v is an odd integer by its digits.
fn odd(v0: Var) bool {
    const v = strip(v0);
    return v.digits.len > 0 and v.digits.len == v.weight + 1 and (v.digits[v.digits.len - 1] & 1) == 1;
}

fn clampScale(s: i32) i32 {
    return @min(@max(s, min_display_scale), max_display_scale);
}

/// (int) of a double: truncated, within i32.
fn cint(x: f64) i32 {
    return @intFromFloat(std.math.clamp(@trunc(x), -2147483648.0, 2147483647.0));
}

// ======================================================= the functions

/// exp_var().
fn expVar(a: Allocator, arg: Var, rscale: i32) Error!Var {
    var x = arg;
    var val = try toDouble(a, x);
    if (@abs(val) >= @as(f64, max_result_scale * 3)) {
        if (val > 0) return error.Overflow;
        return zeroScale(rscale);
    }
    const dweight = cint(val * 0.434294481903252);
    var ndiv2: i32 = 0;
    if (@abs(val) > 0.01) {
        ndiv2 = 1;
        val /= 2;
        while (@abs(val) > 0.01) {
            ndiv2 += 1;
            val /= 2;
        }
        x = try divInt(a, x, @as(i64, 1) << @intCast(ndiv2), x.dscale + ndiv2, true);
    }
    var sig_digits = 1 + dweight + rscale + cint(@as(f64, @floatFromInt(ndiv2)) * 0.301029995663981);
    sig_digits = @max(sig_digits, 0) + 8;
    var local_rscale = sig_digits - 1;
    var result = try add(a, one, x);
    var elem = try mul(a, x, x, local_rscale);
    var ni: i64 = 2;
    elem = try divInt(a, elem, ni, local_rscale, true);
    while (elem.digits.len != 0) {
        result = try add(a, result, elem);
        elem = try mul(a, elem, x, local_rscale);
        ni += 1;
        elem = try divInt(a, elem, ni, local_rscale, true);
    }
    while (ndiv2 > 0) : (ndiv2 -= 1) {
        local_rscale = sig_digits - result.weight * 2 * dec_digits;
        local_rscale = @max(local_rscale, min_display_scale);
        result = try mul(a, result, result, local_rscale);
    }
    return roundVar(a, result, rscale);
}

/// estimate_ln_dweight(): the decimal weight of ln(v), roughly.
fn estimateLnDweight(a: Allocator, v0: Var) Error!i32 {
    const v = strip(v0);
    if (v.neg) return 0;
    if (cmp(v, zero_point_nine) != .lt and cmp(v, one_point_one) != .gt) {
        const x = try sub(a, v, one);
        if (x.digits.len > 0) return x.weight * dec_digits + cint(std.math.log10(@as(f64, @floatFromInt(x.digits[0]))));
        return 0;
    }
    if (v.digits.len == 0) return 0;
    var digits: f64 = @floatFromInt(v.digits[0]);
    var dweight: i32 = v.weight * dec_digits;
    if (v.digits.len > 1) {
        digits = digits * @as(f64, @floatFromInt(nbase)) + @as(f64, @floatFromInt(v.digits[1]));
        dweight -= dec_digits;
    }
    const ln_var = @log(digits) + @as(f64, @floatFromInt(dweight)) * 2.302585092994046;
    return cint(std.math.log10(@abs(ln_var)));
}

/// ln_var().
fn lnVar(a: Allocator, arg: Var, rscale: i32) Error!Var {
    switch (sign(arg)) {
        0 => return error.LogZero,
        -1 => return error.LogNegative,
        else => {},
    }
    var x = strip(arg);
    var fact = two;
    var nsqrt: i32 = 0;
    while (cmp(x, zero_point_nine) != .gt) {
        const local_rscale = rscale - @divTrunc(x.weight * dec_digits, 2) + 8;
        x = try sqrtVar(a, x, local_rscale);
        fact = try mul(a, fact, two, 0);
        nsqrt += 1;
    }
    while (cmp(x, one_point_one) != .lt) {
        const local_rscale = rscale - @divTrunc(x.weight * dec_digits, 2) + 8;
        x = try sqrtVar(a, x, local_rscale);
        fact = try mul(a, fact, two, 0);
        nsqrt += 1;
    }
    const local_rscale = rscale + cint(@as(f64, @floatFromInt(nsqrt + 1)) * 0.301029995663981) + 8;
    var result = try sub(a, x, one);
    var elem = try add(a, x, one);
    result = try div(a, result, elem, local_rscale, true, false);
    var xx = result;
    x = try mul(a, result, result, local_rscale);
    var ni: i64 = 1;
    while (true) {
        ni += 2;
        xx = try mul(a, xx, x, local_rscale);
        elem = try divInt(a, xx, ni, local_rscale, true);
        if (elem.digits.len == 0) break;
        result = try add(a, result, elem);
        if (elem.weight < result.weight - @divTrunc(local_rscale * 2, dec_digits)) break;
    }
    return mul(a, result, fact, rscale);
}

/// log_var(): log of num in base `base`, of its own scale.
fn logVar(a: Allocator, base: Var, num: Var) Error!Var {
    const ln_base_dweight = try estimateLnDweight(a, base);
    const ln_num_dweight = try estimateLnDweight(a, num);
    const result_dweight = ln_num_dweight - ln_base_dweight;
    var rscale = min_sig_digits - result_dweight;
    rscale = @max(rscale, base.dscale);
    rscale = @max(rscale, num.dscale);
    rscale = clampScale(rscale);
    const ln_base_rscale = @max(rscale + result_dweight - ln_base_dweight + 8, min_display_scale);
    const ln_num_rscale = @max(rscale + result_dweight - ln_num_dweight + 8, min_display_scale);
    const ln_base = try lnVar(a, base, ln_base_rscale);
    const ln_num = try lnVar(a, num, ln_num_rscale);
    return div(a, ln_num, ln_base, rscale, true, false);
}

/// power_var(): base ^ exp, of its own scale.
fn powerVar(a: Allocator, base0: Var, ex: Var) Error!Var {
    if (integral(ex)) {
        if (try toInt64(a, ex)) |e| if (e >= std.math.minInt(i32) and e <= std.math.maxInt(i32)) {
            return powerVarInt(a, base0, @intCast(e), ex.dscale);
        };
    }
    var base = strip(base0);
    if (base.digits.len == 0) return zeroScale(min_sig_digits);
    var res_neg = false;
    if (base.neg) {
        if (!integral(ex)) return error.ComplexPower;
        res_neg = odd(ex);
        base.neg = false;
    }
    const ln_dweight = try estimateLnDweight(a, base);
    var local_rscale = @max(8 - ln_dweight, min_display_scale);
    var ln_base = try lnVar(a, base, local_rscale);
    var ln_num = try mul(a, ln_base, ex, local_rscale);
    var val = try toDouble(a, ln_num);
    if (@abs(val) > @as(f64, max_result_scale) * 3.01) {
        if (val > 0) return error.Overflow;
        return zeroScale(max_display_scale);
    }
    val *= 0.434294481903252;
    var rscale = min_sig_digits - cint(val);
    rscale = @max(rscale, base.dscale);
    rscale = @max(rscale, ex.dscale);
    rscale = clampScale(rscale);
    const sig_digits = @max(rscale + cint(val), 0);
    local_rscale = @max(sig_digits - ln_dweight + 8, min_display_scale);
    ln_base = try lnVar(a, base, local_rscale);
    ln_num = try mul(a, ln_base, ex, local_rscale);
    var result = try expVar(a, ln_num, rscale);
    if (res_neg and !result.isZero()) result.neg = true;
    return result;
}

/// power_var_int(): base ^ exp for an integer exp.
fn powerVarInt(a: Allocator, base0: Var, ex: i32, exp_dscale: i32) Error!Var {
    const base = strip(base0);
    var f: f64 = 0;
    if (base.digits.len != 0) {
        f = @floatFromInt(base.digits[0]);
        var p: i32 = base.weight * dec_digits;
        var i: usize = 1;
        while (i < base.digits.len and i * 4 < 16) : (i += 1) {
            f = f * @as(f64, @floatFromInt(nbase)) + @as(f64, @floatFromInt(base.digits[i]));
            p -= dec_digits;
        }
        f = @as(f64, @floatFromInt(ex)) * (std.math.log10(f) + @as(f64, @floatFromInt(p)));
    }
    if (f > @as(f64, @floatFromInt((weight_max + 1) * dec_digits))) return error.Overflow;
    if (f + 1 < -@as(f64, max_display_scale)) return zeroScale(max_display_scale);
    var rscale = min_sig_digits - cint(f);
    rscale = @max(rscale, base.dscale);
    rscale = @max(rscale, exp_dscale);
    rscale = clampScale(rscale);
    switch (ex) {
        0 => {
            var r = one;
            r.dscale = rscale;
            return r;
        },
        1 => return roundVar(a, base, rscale),
        -1 => return div(a, one, base, rscale, true, true),
        2 => return mul(a, base, base, rscale),
        else => {},
    }
    if (base.digits.len == 0) {
        if (ex < 0) return error.DivisionByZero;
        return zeroScale(rscale);
    }
    var sig_digits = 1 + rscale + cint(f);
    sig_digits += cint(@log(@abs(@as(f64, @floatFromInt(ex))))) + 8;
    var neg = ex < 0;
    var mask: u32 = @abs(ex);
    var base_prod = base;
    var result = if (mask & 1 != 0) base else one;
    while (true) {
        mask >>= 1;
        if (mask == 0) break;
        var local_rscale = sig_digits - 2 * base_prod.weight * dec_digits;
        local_rscale = @min(local_rscale, 2 * base_prod.dscale);
        local_rscale = @max(local_rscale, min_display_scale);
        base_prod = try mul(a, base_prod, base_prod, local_rscale);
        if (mask & 1 != 0) {
            local_rscale = sig_digits - (base_prod.weight + result.weight) * dec_digits;
            local_rscale = @min(local_rscale, base_prod.dscale + result.dscale);
            local_rscale = @max(local_rscale, min_display_scale);
            result = try mul(a, base_prod, result, local_rscale);
        }
        if (base_prod.weight > weight_max or result.weight > weight_max) {
            if (!neg) return error.Overflow;
            result = .{};
            neg = false;
            break;
        }
    }
    if (neg) return div(a, one, result, rscale, true, false);
    return roundVar(a, result, rscale);
}

// ================================================= numeric_*() of Decs

/// The scale of a result: NUMERIC_MIN_SIG_DIGITS digits, not less than
/// the argument's, at most NUMERIC_MAX_DISPLAY_SCALE.
fn resultScale(weight: i32, dscale: i32) i32 {
    return clampScale(@max(min_sig_digits - weight, dscale));
}

/// numeric_sqrt().
pub fn sqrt(a: Allocator, x: Dec) Error!Dec {
    switch (x.kind) {
        .ninf => return error.SqrtNegative,
        .nan, .pinf => return x,
        .finite => {},
    }
    const v = strip(try fromDec(a, x));
    // floor(weight * 4 / 2 + 1) digits before the point.
    const sweight = @divTrunc(v.weight * dec_digits, 2) + 1;
    return toDec(a, try sqrtVar(a, v, resultScale(sweight, v.dscale)));
}

/// numeric_exp().
pub fn exp(a: Allocator, x: Dec) Error!Dec {
    switch (x.kind) {
        .ninf => return Dec.zero,
        .nan, .pinf => return x,
        .finite => {},
    }
    const v = strip(try fromDec(a, x));
    var val = try toDouble(a, v);
    val *= 0.434294481903252;
    val = std.math.clamp(val, -@as(f64, max_result_scale), @as(f64, max_result_scale));
    return toDec(a, try expVar(a, v, resultScale(cint(val), v.dscale)));
}

/// numeric_ln().
pub fn ln(a: Allocator, x: Dec) Error!Dec {
    switch (x.kind) {
        .ninf => return error.LogNegative,
        .nan, .pinf => return x,
        .finite => {},
    }
    const v = strip(try fromDec(a, x));
    const ln_dweight = try estimateLnDweight(a, v);
    return toDec(a, try lnVar(a, v, resultScale(ln_dweight, v.dscale)));
}

/// numeric_log(): the logarithm of x in base b (log(x) is log(10, x)).
pub fn log(a: Allocator, b: Dec, x: Dec) Error!Dec {
    if (b.kind != .finite or x.kind != .finite) {
        if (b.kind == .nan or x.kind == .nan) return Dec.nan;
        if (b.sign() < 0 or x.sign() < 0) return error.LogNegative;
        if (b.sign() == 0 or x.sign() == 0) return error.LogZero;
        if (b.kind == .pinf) return if (x.kind == .pinf) Dec.nan else Dec.zero;
        return Dec.pinf;
    }
    return toDec(a, try logVar(a, strip(try fromDec(a, b)), strip(try fromDec(a, x))));
}

/// log(10, x).
pub fn log10(a: Allocator, x: Dec) Error!Dec {
    return log(a, try toDec(a, ten), x);
}

/// Whether d is an integer (numeric_is_integral(): the infinities are).
fn isIntegral(d: Dec) bool {
    return switch (d.kind) {
        .nan => false,
        .pinf, .ninf => true,
        .finite => d.fracDigits() == 0,
    };
}

/// numeric_power(): x ^ y.
pub fn power(a: Allocator, x: Dec, y: Dec) Error!Dec {
    if (x.kind != .finite or y.kind != .finite) {
        // pow(3) of POSIX: NaN ^ 0 = 1, 1 ^ NaN = 1, else NaN.
        if (x.kind == .nan) return if (y.isZero()) try oneDec(a) else Dec.nan;
        if (y.kind == .nan) return if (isOne(x)) try oneDec(a) else Dec.nan;
        const s1 = x.sign();
        const s2 = y.sign();
        if (s1 == 0 and s2 < 0) return error.ZeroNegativePower;
        if (s1 < 0 and !isIntegral(y)) return error.ComplexPower;
        if (isOne(x)) return oneDec(a);
        if (s2 == 0) return oneDec(a);
        if (s1 == 0 and s2 > 0) return Dec.zero;
        if (y.kind != .finite) {
            var gt_one = true;
            if (x.kind == .finite) {
                if (x.neg and isOne(x.negate())) return oneDec(a);
                gt_one = dec.order(x.abs(), try oneDec(a)) == .gt;
            }
            return if (gt_one == (s2 > 0)) Dec.pinf else Dec.zero;
        }
        if (x.kind == .pinf) return if (s2 > 0) Dec.pinf else Dec.zero;
        // -Infinity.
        if (s2 < 0) return Dec.zero;
        return if (odd(try fromDec(a, y))) Dec.ninf else Dec.pinf;
    }
    if (x.sign() == 0 and y.sign() < 0) return error.ZeroNegativePower;
    return toDec(a, try powerVar(a, try fromDec(a, x), try fromDec(a, y)));
}

fn oneDec(a: Allocator) Allocator.Error!Dec {
    return toDec(a, one) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn isOne(d: Dec) bool {
    return d.kind == .finite and !d.neg and d.digits.len == 1 and d.digits[0] == 1 and d.point == 1;
}

/// numeric_fac(): n! (factorial(bigint)), exact (mul_var() of scale 0):
/// multiplied in place, by as many factors at a time as stay below
/// 10^12, in base-10000 digits from the lowest.
pub fn factorial(a: Allocator, n: i64) Error!Dec {
    if (n < 0) return error.FactorialNegative;
    if (n <= 1) return oneDec(a);
    if (n > 32177) return error.Overflow;
    // n! < n^n: n * log10(n) / 4 digits and one.
    const nf: f64 = @floatFromInt(n);
    const cap: usize = @intFromFloat(nf * @log10(nf) / dec_digits + 2);
    const low = try a.alloc(i32, cap);
    var len: usize = 1;
    low[0] = 1;
    var k: u64 = 2;
    const top: u64 = @intCast(n);
    while (k <= top) {
        var m: u64 = 1;
        while (k <= top and m * k < 1_000_000_000_000) : (k += 1) m *= k;
        var carry: u64 = 0;
        for (low[0..len]) |*d| {
            const t = @as(u64, @intCast(d.*)) * m + carry;
            d.* = @intCast(t % 10000);
            carry = t / 10000;
        }
        while (carry != 0) : (carry /= 10000) {
            low[len] = @intCast(carry % 10000);
            len += 1;
        }
    }
    std.mem.reverse(i32, low[0..len]);
    return toDec(a, .{ .weight = @as(i32, @intCast(len)) - 1, .digits = low[0..len] });
}

/// width_bucket_numeric(): the bucket of `op` among `count` buckets of
/// equal width from b1 (inclusive) to b2 (exclusive), 0 before them,
/// count + 1 after.
pub fn widthBucket(a: Allocator, op: Dec, b1: Dec, b2: Dec, count: i64) Error!i32 {
    if (count <= 0) return error.BucketCount;
    if (op.kind == .nan or b1.kind == .nan or b2.kind == .nan) return error.BucketNaN;
    if (b1.kind != .finite or b2.kind != .finite) return error.BucketInfinite;
    const r: i64 = switch (dec.order(b1, b2)) {
        .eq => return error.BucketEqual,
        .lt => if (dec.order(op, b1) == .lt) 0 else if (dec.order(op, b2) != .lt) count + 1 else try bucket(a, op, b1, b2, count),
        .gt => if (dec.order(op, b1) == .gt) 0 else if (dec.order(op, b2) != .gt) count + 1 else try bucket(a, op, b1, b2, count),
    };
    return std.math.cast(i32, r) orelse error.IntegerRange;
}

/// compute_bucket(): ((op - b1) * count) / (b2 - b1), truncated, + 1.
fn bucket(a: Allocator, op: Dec, b1: Dec, b2: Dec, count: i64) Error!i64 {
    return bucketDec(a, op, b1, b2, count) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IntegerRange,
    };
}

fn bucketDec(a: Allocator, op: Dec, b1: Dec, b2: Dec, count: i64) dec.Error!i64 {
    const x = try dec.mul(a, try dec.sub(a, op, b1), try dec.fromInt(a, count));
    const q = try dec.divTrunc(a, x, try dec.sub(a, b2, b1));
    return try dec.toInt(a, q) + 1;
}

// ================================================================ tests

fn expectFn(want: []const u8, got: Error!Dec) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = try got;
    const z = try dec.toText(arena.allocator(), d);
    try std.testing.expectEqualStrings(want, z);
}

fn numOf(a: Allocator, z: []const u8) Dec {
    return dec.parse(a, z) catch unreachable;
}

test "decimal_math: PostgreSQL's digits and scales" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFn("1.414213562373095", sqrt(a, numOf(a, "2")));
    try expectFn("0.01000000000000000", sqrt(a, numOf(a, "0.0001")));
    try expectFn("11111.11106611111", sqrt(a, numOf(a, "123456789.123456789")));
    try expectFn("2.7182818284590452", exp(a, numOf(a, "1.0")));
    try expectFn("26881171418161354484126255515800135873611118.8", exp(a, numOf(a, "100.0")));
    try expectFn("0.00000000000000000000000000000000000000000003720075976020836", exp(a, numOf(a, "-100.0")));
    try expectFn("0.6931471805599453", ln(a, numOf(a, "2.0")));
    try expectFn("0.00000009999999500000033", ln(a, numOf(a, "1.0000001")));
    try expectFn("230.25850929940457", ln(a, numOf(a, "1e100")));
    try expectFn("0.3010299956639812", log10(a, numOf(a, "2")));
    try expectFn("3.0000000000000000", log(a, numOf(a, "2"), numOf(a, "8")));
    try expectFn("1.4142135623730950", power(a, numOf(a, "2"), numOf(a, "0.5")));
    try expectFn("1267650600228229401496703205376", power(a, numOf(a, "2"), numOf(a, "100")));
    try expectFn("-512.00000000000000", power(a, numOf(a, "-8.0"), numOf(a, "3")));
    try expectFn("2.7556759606310754", power(a, numOf(a, "1.5"), numOf(a, "2.5")));
    try expectFn("0.010000000000000000", power(a, numOf(a, "10"), numOf(a, "-2")));
    try expectFn("15511210043330985984000000", factorial(a, 25));
    try std.testing.expectEqual(3, try widthBucket(a, numOf(a, "5.35"), numOf(a, "0.024"), numOf(a, "10.06"), 5));
    try std.testing.expectEqual(0, try widthBucket(a, numOf(a, "11"), numOf(a, "10"), numOf(a, "0"), 5));
    try std.testing.expectError(error.BucketEqual, widthBucket(a, numOf(a, "1"), numOf(a, "2"), numOf(a, "2.0"), 5));
    try std.testing.expectError(error.SqrtNegative, sqrt(a, numOf(a, "-1")));
    try std.testing.expectError(error.LogZero, log(a, numOf(a, "0.0"), numOf(a, "2.0")));
    try std.testing.expectError(error.ComplexPower, power(a, numOf(a, "-2.0"), numOf(a, "0.5")));
    try std.testing.expectError(error.Overflow, power(a, numOf(a, "10"), numOf(a, "200000")));
    try std.testing.expectError(error.Overflow, exp(a, numOf(a, "10000.0")));
}
