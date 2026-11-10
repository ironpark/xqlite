//! A bit-exact port of musl libm's double-precision exp, log, pow, the
//! hyperbolic functions and their inverses, tgamma, lgamma, log1p, expm1, erf
//! and erfc; and sin, cos, tan, log10 and log2 as Zig's compiler-rt ports
//! them (see their section).
//!
//! The SQLite dialect's math functions (src/sql/func/math.zig) use them
//! too, so that they compute the same bits on every platform and in every
//! build mode, where SQLite's call the platform's libm.
//!
//! PostgreSQL's float8 functions (exp, ln, power, cosh, gamma, lgamma, ...)
//! call the C library directly, and the reference server for the postgres
//! dialect runs on musl (Alpine Linux, aarch64). The system libm on other
//! platforms, LLVM's builtins and `std.math` round differently in the last
//! bit, so these functions follow musl's code operation for operation to give
//! the same bits as PostgreSQL on musl on every platform.
//!
//! The configuration is musl's build for aarch64 with gcc: no TOINT
//! intrinsics, EXP_USE_TOINT_NARROW off, `__FP_FAST_FMA` on (so the fma
//! branches of log and pow are taken, here as `@mulAdd`), and no
//! floating-point contraction anywhere else (`-std=c99`). The error helpers
//! (`__math_oflow` and friends) return their IEEE results without setting
//! errno or raising exceptions.
//!
//! Sources: src/math/{exp,exp_data,log,log_data,pow,pow_data}.c (Arm
//! optimized routines, MIT), and cosh, sinh, tanh, __expo2, asinh, acosh,
//! atanh, tgamma, lgamma_r, log1p, expm1, erf, __sin, __cos (FreeBSD/Sun and
//! musl, MIT-compatible), musl 1.2.x.

const std = @import("std");

inline fn asU64(x: f64) u64 {
    return @bitCast(x);
}

inline fn asF64(i: u64) f64 {
    return @bitCast(i);
}

fn bits(comptime i: u64) f64 {
    return @bitCast(i);
}

inline fn top12(x: f64) u32 {
    return @intCast(asU64(x) >> 52);
}

const inf = std.math.inf(f64);

fn invalid(x: f64) f64 {
    return (x - x) / (x - x);
}

// ---------------------------------------------------------------- exp

const exp_table_bits = 7;
const exp_n = 1 << exp_table_bits;
const invln2n: f64 = @as(f64, 0x1.71547652b82fep0) * exp_n;
const negln2hin: f64 = -0x1.62e42fefa0000p-8;
const negln2lon: f64 = -0x1.cf79abc9e3b3ap-47;
const exp_shift: f64 = 0x1.8p52;
const exp_c2: f64 = 0x1.ffffffffffdbdp-2;
const exp_c3: f64 = 0x1.555555555543cp-3;
const exp_c4: f64 = 0x1.55555cf172b91p-5;
const exp_c5: f64 = 0x1.1111167a4d017p-7;

/// scale*(1+tmp) without intermediate overflow or double rounding in the
/// subnormal range (exp.c and pow.c specialcase; pow's handles a negative
/// scale, which is the same as exp's for a positive one).
fn expSpecial(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if ((ki & 0x80000000) == 0) {
        // k > 0, the exponent of scale might have overflowed by <= 460.
        sbits -%= 1009 << 52;
        const scale = asF64(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0, need special care in the subnormal range.
    sbits +%= 1022 << 52;
    const scale = asF64(sbits);
    var y = scale + scale * tmp;
    if (@abs(y) < 1.0) {
        var one: f64 = 1.0;
        if (y < 0.0) one = -1.0;
        var lo = scale - y + scale * tmp;
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (hi + lo) - one;
        // Fix the sign of 0.
        if (y == 0.0) y = asF64(sbits & 0x8000000000000000);
    }
    return 0x1p-1022 * y;
}

/// sign*exp(x+xtail); exp.c is this with xtail = 0 and sign_bias = 0.
fn expInline(x: f64, xtail: f64, sign_bias: u32) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            // Avoid spurious underflow for tiny x.
            const one = 1.0 + x;
            return if (sign_bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            if (asU64(x) >> 63 != 0)
                return if (sign_bias != 0) -0.0 else 0.0;
            return if (sign_bias != 0) -inf else inf;
        }
        // Large x is special cased below.
        abstop = 0;
    }
    // exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)].
    const z = invln2n * x;
    var kd = z + exp_shift;
    const ki = asU64(kd);
    kd -= exp_shift;
    var r = x + kd * negln2hin + kd * negln2lon;
    r += xtail;
    const idx: usize = @intCast(2 * (ki % exp_n));
    const top = (ki +% sign_bias) << (52 - exp_table_bits);
    const tail = asF64(exp_tab[idx]);
    const sbits = exp_tab[idx + 1] +% top;
    const r2 = r * r;
    const tmp = tail + r + r2 * (exp_c2 + r * exp_c3) + r2 * r2 * (exp_c4 + r * exp_c5);
    if (abstop == 0) return expSpecial(tmp, sbits, ki);
    const scale = asF64(sbits);
    return scale + scale * tmp;
}

/// e^x (musl exp.c).
pub fn exp(x: f64) f64 {
    const abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x80000000) return 1.0 + x;
        if (abstop >= top12(1024.0)) {
            if (asU64(x) == asU64(-inf)) return 0.0;
            if (abstop >= top12(inf)) return 1.0 + x;
            if (asU64(x) >> 63 != 0) return 0.0;
            return inf;
        }
    }
    return expInline(x, 0.0, 0);
}

// ---------------------------------------------------------------- log

const log_table_bits = 7;
const log_n = 1 << log_table_bits;
const log_ln2hi: f64 = 0x1.62e42fefa3800p-1;
const log_ln2lo: f64 = 0x1.ef35793c76730p-45;
const log_a = [5]f64{
    -0x1.0000000000001p-1,
    0x1.555555551305bp-2,
    -0x1.fffffffeb459p-3,
    0x1.999b324f10111p-3,
    -0x1.55575e506c89fp-3,
};
const log_b = [11]f64{
    -0x1p-1,
    0x1.5555555555577p-2,
    -0x1.ffffffffffdcbp-3,
    0x1.999999995dd0cp-3,
    -0x1.55555556745a7p-3,
    0x1.24924a344de3p-3,
    -0x1.fffffa4423d65p-4,
    0x1.c7184282ad6cap-4,
    -0x1.999eb43b068ffp-4,
    0x1.78182f7afd085p-4,
    -0x1.5521375d145cdp-4,
};

/// Natural logarithm (musl log.c).
pub fn log(x: f64) f64 {
    var ix = asU64(x);
    const top: u32 = @intCast(ix >> 48);
    const lo_bound = asU64(1.0 - 0x1p-4);
    const hi_bound = asU64(1.0 + 0x1.09p-4);
    if (ix -% lo_bound < hi_bound - lo_bound) {
        // Handle close to 1.0 inputs separately.
        if (ix == asU64(1.0)) return 0;
        const B = log_b;
        const r = x - 1.0;
        const r2 = r * r;
        const r3 = r * r2;
        var y = r3 * (B[1] + r * B[2] + r2 * B[3] +
            r3 * (B[4] + r * B[5] + r2 * B[6] +
                r3 * (B[7] + r * B[8] + r2 * B[9] + r3 * B[10])));
        var w = r * 0x1p27;
        const rhi = r + w - w;
        const rlo = r - rhi;
        w = rhi * rhi * B[0];
        const hi = r + w;
        var lo = r - hi + w;
        lo += B[0] * rlo * (rhi + r);
        y += lo;
        y += hi;
        return y;
    }
    if (top -% 0x0010 >= 0x7ff0 - 0x0010) {
        // x < 0x1p-1022 or inf or nan.
        if (ix *% 2 == 0) return -inf;
        if (ix == asU64(inf)) return x;
        if ((top & 0x8000) != 0 or (top & 0x7ff0) == 0x7ff0) return invalid(x);
        // x is subnormal, normalize it.
        ix = asU64(x * 0x1p52);
        ix -%= 52 << 52;
    }
    const off: u64 = 0x3fe6000000000000;
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - log_table_bits)) % log_n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const invc = log_tab[i][0];
    const logc = log_tab[i][1];
    const z = asF64(iz);
    const r = @mulAdd(f64, z, invc, -1.0);
    const kd: f64 = @floatFromInt(k);
    const w = kd * log_ln2hi + logc;
    const hi = w + r;
    const lo = w - hi + r + kd * log_ln2lo;
    const A = log_a;
    const r2 = r * r;
    return lo + r2 * A[0] + r * r2 * (A[1] + r * A[2] + r2 * (A[3] + r * A[4])) + hi;
}

// ---------------------------------------------------------------- pow

const pow_table_bits = 7;
const pow_n = 1 << pow_table_bits;
const pow_a = [7]f64{
    -0x1p-1,
    @as(f64, 0x1.555555555556p-2) * -2,
    @as(f64, -0x1.0000000000006p-2) * -2,
    @as(f64, 0x1.999999959554ep-3) * 4,
    @as(f64, -0x1.555555529a47ap-3) * 4,
    @as(f64, 0x1.2495b9b4845e9p-3) * -8,
    @as(f64, -0x1.0002b8b263fc3p-3) * -8,
};

const LogResult = struct { hi: f64, lo: f64 };

/// log(x) as hi + lo with about 15 extra bits (pow.c log_inline).
fn powLog(ix: u64) LogResult {
    const off: u64 = 0x3fe6955500000000;
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - pow_table_bits)) % pow_n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52;
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z = asF64(iz);
    const kd: f64 = @floatFromInt(k);
    const invc = pow_tab[i][0];
    const logc = pow_tab[i][1];
    const logctail = pow_tab[i][2];
    const r = @mulAdd(f64, z, invc, -1.0);
    const t1 = kd * log_ln2hi + logc;
    const t2 = t1 + r;
    const lo1 = kd * log_ln2lo + logctail;
    const lo2 = t1 - t2 + r;
    const A = pow_a;
    const ar = A[0] * r;
    const ar2 = r * ar;
    const ar3 = r * ar2;
    const hi = t2 + ar2;
    const lo3 = @mulAdd(f64, ar, r, -ar2);
    const lo4 = t2 - hi + ar2;
    const p = ar3 * (A[1] + r * A[2] + ar2 * (A[3] + r * A[4] + ar2 * (A[5] + r * A[6])));
    const lo = lo1 + lo2 + lo3 + lo4 + p;
    const y = hi + lo;
    return .{ .hi = y, .lo = hi - y + lo };
}

/// 0 if not an integer, 1 if odd, 2 if even; iy is a non-zero finite value.
fn checkint(iy: u64) u32 {
    const e: u32 = @intCast(iy >> 52 & 0x7ff);
    if (e < 0x3ff) return 0;
    if (e > 0x3ff + 52) return 2;
    const sh: u6 = @intCast(0x3ff + 52 - e);
    if (iy & ((@as(u64, 1) << sh) - 1) != 0) return 0;
    if (iy & (@as(u64, 1) << sh) != 0) return 1;
    return 2;
}

fn zeroinfnan(i: u64) bool {
    return 2 *% i -% 1 >= 2 *% asU64(inf) -% 1;
}

const sign_bias_neg: u32 = 0x800 << exp_table_bits;

/// x^y (musl pow.c).
pub fn pow(x: f64, y: f64) f64 {
    var sign_bias: u32 = 0;
    var ix = asU64(x);
    const iy = asU64(y);
    var topx = top12(x);
    const topy = top12(y);
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        if (zeroinfnan(iy)) {
            if (2 *% iy == 0) return 1.0;
            if (ix == asU64(1.0)) return 1.0;
            if (2 *% ix > 2 *% asU64(inf) or 2 *% iy > 2 *% asU64(inf)) return x + y;
            if (2 *% ix == 2 *% asU64(1.0)) return 1.0;
            if ((2 *% ix < 2 *% asU64(1.0)) == (iy >> 63 == 0)) return 0.0;
            return y * y;
        }
        if (zeroinfnan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkint(iy) == 1) x2 = -x2;
            return if (iy >> 63 != 0) 1 / x2 else x2;
        }
        // Here x and y are non-zero finite.
        if (ix >> 63 != 0) {
            const yint = checkint(iy);
            if (yint == 0) return invalid(x);
            if (yint == 1) sign_bias = sign_bias_neg;
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            if (ix == asU64(1.0)) return 1.0;
            if ((topy & 0x7ff) < 0x3be)
                return if (ix > asU64(1.0)) 1.0 + y else 1.0 - y;
            return if ((ix > asU64(1.0)) == (topy < 0x800)) inf else 0.0;
        }
        if (topx == 0) {
            // Normalize subnormal x so exponent becomes negative.
            ix = asU64(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix -%= 52 << 52;
        }
    }
    const l = powLog(ix);
    const ehi = y * l.hi;
    const elo = y * l.lo + @mulAdd(f64, y, l.hi, -ehi);
    return expInline(ehi, elo, sign_bias);
}

// ---------------------------------------------------------------- expm1, log1p

const ln2_hi: f64 = 0x1.62e42fee00000p-1;
const ln2_lo: f64 = 0x1.a39ef35793c76p-33;

/// e^x - 1 (musl expm1.c).
pub fn expm1(x_in: f64) f64 {
    const o_threshold: f64 = 0x1.62e42fefa39efp+9;
    const invln2: f64 = 0x1.71547652b82fep+0;
    const Q1: f64 = -0x1.11111111110f4p-5;
    const Q2: f64 = 0x1.a01a019fe5585p-10;
    const Q3: f64 = -0x1.4ce199eaadbb7p-14;
    const Q4: f64 = 0x1.0cfca86e65239p-18;
    const Q5: f64 = -0x1.afdb76e09c32dp-23;

    var x = x_in;
    const hx: u32 = @intCast(asU64(x) >> 32 & 0x7fffffff);
    const sign = asU64(x) >> 63 != 0;
    var k: i32 = undefined;
    var c: f64 = 0;

    // filter out huge and non-finite argument
    if (hx >= 0x4043687A) {
        if (std.math.isNan(x)) return x;
        if (sign) return -1;
        if (x > o_threshold) return x * 0x1p1023;
    }

    // argument reduction
    if (hx > 0x3fd62e42) {
        var hi: f64 = undefined;
        var lo: f64 = undefined;
        if (hx < 0x3FF0A2B2) {
            if (!sign) {
                hi = x - ln2_hi;
                lo = ln2_lo;
                k = 1;
            } else {
                hi = x + ln2_hi;
                lo = -ln2_lo;
                k = -1;
            }
        } else {
            k = @intFromFloat(invln2 * x + @as(f64, if (sign) -0.5 else 0.5));
            const t: f64 = @floatFromInt(k);
            hi = x - t * ln2_hi;
            lo = t * ln2_lo;
        }
        x = hi - lo;
        c = (hi - x) - lo;
    } else if (hx < 0x3c900000) {
        return x;
    } else k = 0;

    // x is now in primary range
    const hfx = 0.5 * x;
    const hxs = x * hfx;
    const r1 = 1.0 + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))));
    const t = 3.0 - r1 * hfx;
    var e = hxs * ((r1 - t) / (6.0 - x * t));
    if (k == 0) return x - (x * e - hxs);
    e = x * (e - c) - c;
    e -= hxs;
    if (k == -1) return 0.5 * (x - e) - 0.5;
    if (k == 1) {
        if (x < -0.25) return -2.0 * (e - (x + 0.5));
        return 1.0 + 2.0 * (x - e);
    }
    const twopk = asF64(@as(u64, @intCast(0x3ff + k)) << 52);
    if (k < 0 or k > 56) {
        var y = x - e + 1.0;
        if (k == 1024)
            y = y * 2.0 * 0x1p1023
        else
            y = y * twopk;
        return y - 1.0;
    }
    const u = asF64(@as(u64, @intCast(0x3ff - k)) << 52);
    if (k < 20) return (x - e + (1 - u)) * twopk;
    return (x - (e + u) + 1) * twopk;
}

/// log(1+x) (musl log1p.c).
pub fn log1p(x: f64) f64 {
    const Lg1: f64 = 0x1.5555555555593p-1;
    const Lg2: f64 = 0x1.999999997fa04p-2;
    const Lg3: f64 = 0x1.2492494229359p-2;
    const Lg4: f64 = 0x1.c71c51d8e78afp-3;
    const Lg5: f64 = 0x1.7466496cb03dep-3;
    const Lg6: f64 = 0x1.39a09d078c69fp-3;
    const Lg7: f64 = 0x1.2f112df3e5244p-3;

    const hx: u32 = @intCast(asU64(x) >> 32);
    var k: i32 = 1;
    var c: f64 = 0;
    var f: f64 = 0;
    if (hx < 0x3fda827a or hx >> 31 != 0) {
        if (hx >= 0xbff00000) {
            if (x == -1) return -inf;
            return invalid(x);
        }
        if (hx << 1 < 0x3ca00000 << 1) return x;
        if (hx <= 0xbfd2bec4) {
            k = 0;
            c = 0;
            f = x;
        }
    } else if (hx >= 0x7ff00000) return x;
    if (k != 0) {
        var ui = asU64(1 + x);
        const uf = asF64(ui);
        var hu: u32 = @intCast(ui >> 32);
        hu +%= 0x3ff00000 - 0x3fe6a09e;
        k = @as(i32, @intCast(hu >> 20)) - 0x3ff;
        // correction term ~ log(1+x)-log(u), avoid underflow in c/u
        if (k < 54) {
            c = if (k >= 2) 1 - (uf - x) else x - (uf - 1);
            c /= uf;
        } else c = 0;
        // reduce u into [sqrt(2)/2, sqrt(2)]
        hu = (hu & 0x000fffff) + 0x3fe6a09e;
        ui = @as(u64, hu) << 32 | (ui & 0xffffffff);
        f = asF64(ui) - 1;
    }
    const hfsq = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;
    const dk: f64 = @floatFromInt(k);
    return s * (hfsq + R) + (dk * ln2_lo + c) - hfsq + f + dk * ln2_hi;
}

// ---------------------------------------------------------------- hyperbolic

/// exp(x)/2 for x >= log(DBL_MAX) (musl __expo2.c).
fn expo2(x: f64, sign: f64) f64 {
    const k = 2043;
    const kln2: f64 = 0x1.62066151add8bp+10;
    const scale = asF64(@as(u64, 0x3ff + k / 2) << 52);
    return exp(x - kln2) * (sign * scale) * scale;
}

/// Hyperbolic cosine (musl cosh.c).
pub fn cosh(x_in: f64) f64 {
    const ui = asU64(x_in) & (std.math.maxInt(u64) / 2);
    const x = asF64(ui);
    const w: u32 = @intCast(ui >> 32);
    // |x| < log(2)
    if (w < 0x3fe62e42) {
        if (w < 0x3ff00000 - (26 << 20)) return 1;
        const t = expm1(x);
        return 1 + t * t / (2 * (1 + t));
    }
    // |x| < log(DBL_MAX)
    if (w < 0x40862e42) {
        const t = exp(x);
        return 0.5 * (t + 1 / t);
    }
    // |x| > log(DBL_MAX) or nan
    return expo2(x, 1.0);
}

/// Hyperbolic sine (musl sinh.c).
pub fn sinh(x: f64) f64 {
    var h: f64 = 0.5;
    if (asU64(x) >> 63 != 0) h = -h;
    const ui = asU64(x) & (std.math.maxInt(u64) / 2);
    const absx = asF64(ui);
    const w: u32 = @intCast(ui >> 32);
    // |x| < log(DBL_MAX)
    if (w < 0x40862e42) {
        const t = expm1(absx);
        if (w < 0x3ff00000) {
            if (w < 0x3ff00000 - (26 << 20)) return x;
            return h * (2 * t - t * t / (t + 1));
        }
        return h * (t + t / (t + 1));
    }
    // |x| > log(DBL_MAX) or nan
    return expo2(absx, 2 * h);
}

/// Hyperbolic tangent (musl tanh.c).
pub fn tanh(x_in: f64) f64 {
    const sign = asU64(x_in) >> 63 != 0;
    const ui = asU64(x_in) & (std.math.maxInt(u64) / 2);
    const x = asF64(ui);
    const w: u32 = @intCast(ui >> 32);
    var t: f64 = undefined;
    if (w > 0x3fe193ea) {
        // |x| > log(3)/2 ~= 0.5493 or nan
        if (w > 0x40340000) {
            // |x| > 20 or nan
            t = 1 - 0 / x;
        } else {
            t = expm1(2 * x);
            t = 1 - 2 / (t + 2);
        }
    } else if (w > 0x3fd058ae) {
        // |x| > log(5/3)/2 ~= 0.2554
        t = expm1(2 * x);
        t = t / (t + 2);
    } else if (w >= 0x00100000) {
        // |x| >= 0x1p-1022
        t = expm1(-2 * x);
        t = -t / (t + 2);
    } else {
        // |x| is subnormal
        t = x;
    }
    return if (sign) -t else t;
}

const ln2: f64 = 0x1.62e42fefa39efp-1;

/// Inverse hyperbolic sine (musl asinh.c).
pub fn asinh(x_in: f64) f64 {
    const e = asU64(x_in) >> 52 & 0x7ff;
    const s = asU64(x_in) >> 63 != 0;
    var x = asF64(asU64(x_in) & (std.math.maxInt(u64) / 2));
    if (e >= 0x3ff + 26) {
        // |x| >= 0x1p26 or inf or nan
        x = log(x) + ln2;
    } else if (e >= 0x3ff + 1) {
        // |x| >= 2
        x = log(2 * x + 1 / (@sqrt(x * x + 1) + x));
    } else if (e >= 0x3ff - 26) {
        // |x| >= 0x1p-26
        x = log1p(x + x * x / (@sqrt(x * x + 1) + 1));
    }
    return if (s) -x else x;
}

/// Inverse hyperbolic cosine (musl acosh.c).
pub fn acosh(x: f64) f64 {
    const e = asU64(x) >> 52;
    // 0 <= x < 2
    if (e < 0x3ff + 1) return log1p(x - 1 + @sqrt((x - 1) * (x - 1) + 2 * (x - 1)));
    // 2 <= x < 0x1p26
    if (e < 0x3ff + 26) return log(2 * x - 1 / (x + @sqrt(x * x - 1)));
    // x < 0 or x = -0, invalid
    if (e & 0x800 != 0) return invalid(x);
    // x >= 0x1p26 or nan
    return log(x) + ln2;
}

/// Inverse hyperbolic tangent (musl atanh.c).
pub fn atanh(x: f64) f64 {
    const e = asU64(x) >> 52 & 0x7ff;
    const s = asU64(x) >> 63 != 0;
    var y = asF64(asU64(x) & (std.math.maxInt(u64) / 2));
    if (e < 0x3ff - 1) {
        if (e >= 0x3ff - 32) {
            // |x| < 0.5
            y = 0.5 * log1p(2 * y + 2 * y * y / (1 - y));
        }
    } else {
        // avoid overflow
        y = 0.5 * log1p(2 * (y / (1 - y)));
    }
    return if (s) -y else y;
}

// ---------------------------------------------------------------- sin/cos kernels

/// sin(pi*x) for x > 0x1p-100 (tgamma.c sinpi and lgamma_r.c sin_pi, which
/// compute the same thing).
fn sinPi(x_in: f64) f64 {
    var x = x_in * 0.5;
    x = 2 * (x - @floor(x));
    const n0: i32 = @intFromFloat(4 * x);
    const n = @divTrunc(n0 + 1, 2);
    x -= @as(f64, @floatFromInt(n)) * 0.5;
    x *= gamma_pi;
    return switch (n) {
        1 => kcos(x, 0),
        2 => ksin(-x, 0, 0),
        3 => -kcos(x, 0),
        else => ksin(x, 0, 0),
    };
}

// ---------------------------------------------------------------- tgamma

const gamma_pi: f64 = 0x1.921fb54442d18p+1;
const gmhalf: f64 = 0x1.61945b9800000p+2;

/// Lanczos S(x) for positive x (tgamma.c).
fn lanczosS(x: f64) f64 {
    var num: f64 = 0;
    var den: f64 = 0;
    if (x < 8) {
        var i: usize = snum.len;
        while (i > 0) {
            i -= 1;
            num = num * x + snum[i];
            den = den * x + sden[i];
        }
    } else {
        for (snum, sden) |a, b| {
            num = num / x + a;
            den = den / x + b;
        }
    }
    return num / den;
}

/// The gamma function (musl tgamma.c).
pub fn tgamma(x_in: f64) f64 {
    var x = x_in;
    const ix: u32 = @intCast(asU64(x) >> 32 & 0x7fffffff);
    const sign = asU64(x) >> 63 != 0;

    // tgamma(nan)=nan, tgamma(inf)=inf, tgamma(-inf)=nan
    if (ix >= 0x7ff00000) return x + inf;
    // |x| < 2^-54: tgamma(x) ~ 1/x
    if (ix < (0x3ff - 54) << 20) return 1 / x;

    // integer arguments
    if (x == @floor(x)) {
        if (sign) return std.math.nan(f64);
        if (x <= fact.len) return fact[@as(usize, @intFromFloat(x)) - 1];
    }

    // |x| >= 184
    if (ix >= 0x40670000) {
        if (sign) {
            if (@floor(x) * 0.5 == @floor(x * 0.5)) return 0;
            return -0.0;
        }
        x *= 0x1p1023;
        return x;
    }

    const absx = if (sign) -x else x;

    // handle the error of x + g - 0.5
    var y = absx + gmhalf;
    var dy: f64 = undefined;
    if (absx > gmhalf) {
        dy = y - absx;
        dy -= gmhalf;
    } else {
        dy = y - gmhalf;
        dy -= absx;
    }

    var z = absx - 0.5;
    var r = lanczosS(absx) * exp(-y);
    if (x < 0) {
        // reflection formula for negative x
        r = -gamma_pi / (sinPi(absx) * absx * r);
        dy = -dy;
        z = -z;
    }
    r += dy * (gmhalf + 0.5) * r / y;
    z = pow(y, 0.5 * z);
    y = r * z * z;
    return y;
}

// ---------------------------------------------------------------- lgamma

/// log|Gamma(x)| (musl lgamma_r.c; the sign of Gamma(x) is not returned).
pub fn lgamma(x_in: f64) f64 {
    var x = x_in;
    const ui = asU64(x);
    const sign = ui >> 63 != 0;
    const ix: u32 = @intCast(ui >> 32 & 0x7fffffff);
    var nadj: f64 = 0;

    if (ix >= 0x7ff00000) return x * x;
    if (ix < (0x3ff - 70) << 20) {
        // |x|<2**-70, return -log(|x|)
        if (sign) x = -x;
        return -log(x);
    }
    if (sign) {
        x = -x;
        var t = sinPi(x);
        if (t == 0.0) return inf; // -integer
        if (t <= 0.0) t = -t;
        nadj = log(lg_pi / (t * x));
    }

    var r: f64 = undefined;
    // purge off 1 and 2
    if ((ix == 0x3ff00000 or ix == 0x40000000) and @as(u32, @truncate(ui)) == 0) {
        r = 0;
    } else if (ix < 0x40000000) {
        // for x < 2.0
        var y: f64 = undefined;
        var i: u32 = undefined;
        if (ix <= 0x3feccccc) {
            // lgamma(x) = lgamma(x+1)-log(x)
            r = -log(x);
            if (ix >= 0x3FE76944) {
                y = 1.0 - x;
                i = 0;
            } else if (ix >= 0x3FCDA661) {
                y = x - (lg_tc - 1.0);
                i = 1;
            } else {
                y = x;
                i = 2;
            }
        } else {
            r = 0.0;
            if (ix >= 0x3FFBB4C3) {
                // [1.7316,2]
                y = 2.0 - x;
                i = 0;
            } else if (ix >= 0x3FF3B4C4) {
                // [1.23,1.73]
                y = x - lg_tc;
                i = 1;
            } else {
                y = x - 1.0;
                i = 2;
            }
        }
        switch (i) {
            0 => {
                const z = y * y;
                const p1 = lg_a0 + z * (lg_a2 + z * (lg_a4 + z * (lg_a6 + z * (lg_a8 + z * lg_a10))));
                const p2 = z * (lg_a1 + z * (lg_a3 + z * (lg_a5 + z * (lg_a7 + z * (lg_a9 + z * lg_a11)))));
                const p = y * p1 + p2;
                r += (p - 0.5 * y);
            },
            1 => {
                const z = y * y;
                const w = z * y;
                const p1 = lg_t0 + w * (lg_t3 + w * (lg_t6 + w * (lg_t9 + w * lg_t12)));
                const p2 = lg_t1 + w * (lg_t4 + w * (lg_t7 + w * (lg_t10 + w * lg_t13)));
                const p3 = lg_t2 + w * (lg_t5 + w * (lg_t8 + w * (lg_t11 + w * lg_t14)));
                const p = z * p1 - (lg_tt - w * (p2 + y * p3));
                r += lg_tf + p;
            },
            else => {
                const p1 = y * (lg_u0 + y * (lg_u1 + y * (lg_u2 + y * (lg_u3 + y * (lg_u4 + y * lg_u5)))));
                const p2 = 1.0 + y * (lg_v1 + y * (lg_v2 + y * (lg_v3 + y * (lg_v4 + y * lg_v5))));
                r += -0.5 * y + p1 / p2;
            },
        }
    } else if (ix < 0x40200000) {
        // x < 8.0
        const i: i32 = @intFromFloat(x);
        const y = x - @as(f64, @floatFromInt(i));
        const p = y * (lg_s0 + y * (lg_s1 + y * (lg_s2 + y * (lg_s3 + y * (lg_s4 + y * (lg_s5 + y * lg_s6))))));
        const q = 1.0 + y * (lg_r1 + y * (lg_r2 + y * (lg_r3 + y * (lg_r4 + y * (lg_r5 + y * lg_r6)))));
        r = 0.5 * y + p / q;
        var z: f64 = 1.0; // lgamma(1+s) = log(s) + lgamma(s)
        if (i >= 7) z *= y + 6.0;
        if (i >= 6) z *= y + 5.0;
        if (i >= 5) z *= y + 4.0;
        if (i >= 4) z *= y + 3.0;
        if (i >= 3) {
            z *= y + 2.0;
            r += log(z);
        }
    } else if (ix < 0x43900000) {
        // 8.0 <= x < 2**58
        const t = log(x);
        const z = 1.0 / x;
        const y = z * z;
        const w = lg_w0 + z * (lg_w1 + y * (lg_w2 + y * (lg_w3 + y * (lg_w4 + y * (lg_w5 + y * lg_w6)))));
        r = (x - 0.5) * (t - 1.0) + w;
    } else {
        // 2**58 <= x <= inf
        r = x * (log(x) - 1.0);
    }
    if (sign) r = nadj - r;
    return r;
}

// ---------------------------------------------------------------- data

// lgamma_r.c coefficients, from the bit patterns in its comments.
const lg_pi = bits(0x400921FB54442D18); // 3.14159265358979311600e+00
const lg_a0 = bits(0x3FB3C467E37DB0C8); // 7.72156649015328655494e-02
const lg_a1 = bits(0x3FD4A34CC4A60FAD); // 3.22467033424113591611e-01
const lg_a2 = bits(0x3FB13E001A5562A7); // 6.73523010531292681824e-02
const lg_a3 = bits(0x3F951322AC92547B); // 2.05808084325167332806e-02
const lg_a4 = bits(0x3F7E404FB68FEFE8); // 7.38555086081402883957e-03
const lg_a5 = bits(0x3F67ADD8CCB7926B); // 2.89051383673415629091e-03
const lg_a6 = bits(0x3F538A94116F3F5D); // 1.19270763183362067845e-03
const lg_a7 = bits(0x3F40B6C689B99C00); // 5.10069792153511336608e-04
const lg_a8 = bits(0x3F2CF2ECED10E54D); // 2.20862790713908385557e-04
const lg_a9 = bits(0x3F1C5088987DFB07); // 1.08011567247583939954e-04
const lg_a10 = bits(0x3EFA7074428CFA52); // 2.52144565451257326939e-05
const lg_a11 = bits(0x3F07858E90A45837); // 4.48640949618915160150e-05
const lg_tc = bits(0x3FF762D86356BE3F); // 1.46163214496836224576e+00
const lg_tf = bits(0xBFBF19B9BCC38A42); // -1.21486290535849611461e-01
const lg_tt = bits(0xBC50C7CAA48A971F); // -3.63867699703950536541e-18
const lg_t0 = bits(0x3FDEF72BC8EE38A2); // 4.83836122723810047042e-01
const lg_t1 = bits(0xBFC2E4278DC6C509); // -1.47587722994593911752e-01
const lg_t2 = bits(0x3FB08B4294D5419B); // 6.46249402391333854778e-02
const lg_t3 = bits(0xBFA0C9A8DF35B713); // -3.27885410759859649565e-02
const lg_t4 = bits(0x3F9266E7970AF9EC); // 1.79706750811820387126e-02
const lg_t5 = bits(0xBF851F9FBA91EC6A); // -1.03142241298341437450e-02
const lg_t6 = bits(0x3F78FCE0E370E344); // 6.10053870246291332635e-03
const lg_t7 = bits(0xBF6E2EFFB3E914D7); // -3.68452016781138256760e-03
const lg_t8 = bits(0x3F6282D32E15C915); // 2.25964780900612472250e-03
const lg_t9 = bits(0xBF56FE8EBF2D1AF1); // -1.40346469989232843813e-03
const lg_t10 = bits(0x3F4CDF0CEF61A8E9); // 8.81081882437654011382e-04
const lg_t11 = bits(0xBF41A6109C73E0EC); // -5.38595305356740546715e-04
const lg_t12 = bits(0x3F34AF6D6C0EBBF7); // 3.15632070903625950361e-04
const lg_t13 = bits(0xBF347F24ECC38C38); // -3.12754168375120860518e-04
const lg_t14 = bits(0x3F35FD3EE8C2D3F4); // 3.35529192635519073543e-04
const lg_u0 = bits(0xBFB3C467E37DB0C8); // -7.72156649015328655494e-02
const lg_u1 = bits(0x3FE4401E8B005DFF); // 6.32827064025093366517e-01
const lg_u2 = bits(0x3FF7475CD119BD6F); // 1.45492250137234768737e+00
const lg_u3 = bits(0x3FEF497644EA8450); // 9.77717527963372745603e-01
const lg_u4 = bits(0x3FCD4EAEF6010924); // 2.28963728064692451092e-01
const lg_u5 = bits(0x3F8B678BBF2BAB09); // 1.33810918536787660377e-02
const lg_v1 = bits(0x4003A5D7C2BD619C); // 2.45597793713041134822e+00
const lg_v2 = bits(0x40010725A42B18F5); // 2.12848976379893395361e+00
const lg_v3 = bits(0x3FE89DFBE45050AF); // 7.69285150456672783825e-01
const lg_v4 = bits(0x3FBAAE55D6537C88); // 1.04222645593369134254e-01
const lg_v5 = bits(0x3F6A5ABB57D0CF61); // 3.21709242282423911810e-03
const lg_s0 = bits(0xBFB3C467E37DB0C8); // -7.72156649015328655494e-02
const lg_s1 = bits(0x3FCB848B36E20878); // 2.14982415960608852501e-01
const lg_s2 = bits(0x3FD4D98F4F139F59); // 3.25778796408930981787e-01
const lg_s3 = bits(0x3FC2BB9CBEE5F2F7); // 1.46350472652464452805e-01
const lg_s4 = bits(0x3F9B481C7E939961); // 2.66422703033638609560e-02
const lg_s5 = bits(0x3F5E26B67368F239); // 1.84028451407337715652e-03
const lg_s6 = bits(0x3F00BFECDD17E945); // 3.19475326584100867617e-05
const lg_r1 = bits(0x3FF645A762C4AB74); // 1.39200533467621045958e+00
const lg_r2 = bits(0x3FE71A1893D3DCDC); // 7.21935547567138069525e-01
const lg_r3 = bits(0x3FC601EDCCFBDF27); // 1.71933865632803078993e-01
const lg_r4 = bits(0x3F9317EA742ED475); // 1.86459191715652901344e-02
const lg_r5 = bits(0x3F497DDACA41A95B); // 7.77942496381893596434e-04
const lg_r6 = bits(0x3EDEBAF7A5B38140); // 7.32668430744625636189e-06
const lg_w0 = bits(0x3FDACFE390C97D69); // 4.18938533204672725052e-01
const lg_w1 = bits(0x3FB555555555553B); // 8.33333333333329678849e-02
const lg_w2 = bits(0xBF66C16C16B02E5C); // -2.77777777728775536470e-03
const lg_w3 = bits(0x3F4A019F98CF38B6); // 7.93650558643019558500e-04
const lg_w4 = bits(0xBF4380CB8C0FE741); // -5.95187557450339963135e-04
const lg_w5 = bits(0x3F4B67BA4CDAD5D1); // 8.36339918996282139126e-04
const lg_w6 = bits(0xBF5AB89D0B9E43E4); // -1.63092934096575273989e-03

// 2^(k/N) ~= H[k]*(1 + T[k]) for int k in [0,N): tab[2*k] = asuint64(T[k]),
// tab[2*k+1] = asuint64(H[k]) - (k << 52)/N (exp_data.c).
const exp_tab = [256]u64{
    0x0,                0x3ff0000000000000,
    0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
    0xbc7160139cd8dc5d, 0x3fefec9a3e778061,
    0xbc905e7a108766d1, 0x3fefe315e86e7f85,
    0x3c8cd2523567f613, 0x3fefd9b0d3158574,
    0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
    0x3c60f74e61e6c861, 0x3fefc74518759bc8,
    0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
    0x3c979aa65d837b6d, 0x3fefb5586cf9890f,
    0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
    0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2,
    0xbc6a033489906e0b, 0x3fef9b66affed31b,
    0xbc9556522a2fbd0e, 0x3fef9301d0125b51,
    0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
    0xbc91c923b9d5f416, 0x3fef829aaea92de0,
    0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
    0xbc801b15eaa59348, 0x3fef72b83c7d517b,
    0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
    0x3c8b898c3f1353bf, 0x3fef635beb6fcb75,
    0xbc96d99c7611eb26, 0x3fef5be084045cd4,
    0x3c9aecf73e3a2f60, 0x3fef54873168b9aa,
    0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
    0x3c8a6f4144a6c38d, 0x3fef463b88628cd6,
    0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
    0x3c968efde3a8a894, 0x3fef387a6e756238,
    0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
    0x3c80472b981fe7f2, 0x3fef2b4565e27cdd,
    0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
    0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1,
    0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
    0x3c8b3782720c0ab4, 0x3fef1285a6e4030b,
    0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
    0x3c834d754db0abb6, 0x3fef06fe0a31b715,
    0x3c864201e2ac744c, 0x3fef0170fc4cd831,
    0x3c8fdd395dd3f84a, 0x3feefc08b26416ff,
    0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
    0xbc924aedcc4b5068, 0x3feef1a7373aa9cb,
    0xbc9907f81b512d8e, 0x3feeecae6d05d866,
    0xbc71d1e83e9436d2, 0x3feee7db34e59ff7,
    0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
    0x3c859f48a72a4c6d, 0x3feedea64c123422,
    0xbc9312607a28698a, 0x3feeda4504ac801c,
    0xbc58a78f4817895b, 0x3feed60a21f72e2a,
    0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
    0x3c4363ed60c2ac11, 0x3feece086061892d,
    0x3c9666093b0664ef, 0x3feeca41ed1d0057,
    0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0,
    0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
    0x3c7690cebb7aafb0, 0x3feebfdad5362a27,
    0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
    0xbc8f94340071a38e, 0x3feeb9b2769d2ca7,
    0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
    0xbc78dec6bd0f385f, 0x3feeb42b569d4f82,
    0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
    0x3c93350518fdd78e, 0x3feeaf4736b527da,
    0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
    0x3c9063e1e21c5409, 0x3feeab07dd485429,
    0x3c34c7855019c6ea, 0x3feea9268a5946b7,
    0x3c9432e62b64c035, 0x3feea76f15ad2148,
    0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
    0xbc8c33c53bef4da8, 0x3feea47eb03a5585,
    0xbc845378892be9ae, 0x3feea34634ccc320,
    0xbc93cedd78565858, 0x3feea23882552225,
    0x3c5710aa807e1964, 0x3feea155d44ca973,
    0xbc93b3efbf5e2228, 0x3feea09e667f3bcd,
    0xbc6a12ad8734b982, 0x3feea012750bdabf,
    0xbc6367efb86da9ee, 0x3fee9fb23c651a2f,
    0xbc80dc3d54e08851, 0x3fee9f7df9519484,
    0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74,
    0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
    0xbc8619321e55e68a, 0x3fee9feb564267c9,
    0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
    0xbc7b32dcb94da51d, 0x3feea11473eb0187,
    0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
    0x3c65ebe1abd66c55, 0x3feea2f336cf4e62,
    0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
    0xbc9369b6f13b3734, 0x3feea589994cce13,
    0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
    0xbc94d450d872576e, 0x3feea8d99b4492ed,
    0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
    0x3c8db72fc1f0eab4, 0x3feeace5422aa0db,
    0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
    0x3c7bf68359f35f44, 0x3feeb1ae99157736,
    0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
    0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5,
    0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
    0xbc92434322f4f9aa, 0x3feebd829fde4e50,
    0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
    0x3c71affc2b91ce27, 0x3feec49182a3f090,
    0x3c6dd235e10a73bb, 0x3feec86319e32323,
    0xbc87c50422622263, 0x3feecc667b5de565,
    0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
    0xbc91bbd1d3bcbb15, 0x3feed503b23e255d,
    0x3c90cc319cee31d2, 0x3feed99e1330b358,
    0x3c8469846e735ab3, 0x3feede6b5579fdbf,
    0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
    0x3c8c1a7792cb3387, 0x3feee89f995ad3ad,
    0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
    0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb,
    0xbc90a40e3da6f640, 0x3feef9728de5593a,
    0xbc68d6f438ad9334, 0x3feeff76f2fb5e47,
    0xbc91eee26b588a35, 0x3fef05b030a1064a,
    0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2,
    0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
    0x3c736eae30af0cb3, 0x3fef199bdd85529c,
    0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
    0x3c84e08fd10959ac, 0x3fef27f12e57d14b,
    0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
    0x3c676b2c6c921968, 0x3fef3720dcef9069,
    0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
    0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c,
    0xbc900dae3875a949, 0x3fef4f87080d89f2,
    0x3c74a385a63d07a7, 0x3fef5818dcfba487,
    0xbc82919e2040220f, 0x3fef60e316c98398,
    0x3c8e5a50d5c192ac, 0x3fef69e603db3285,
    0x3c843a59ac016b4b, 0x3fef7321f301b460,
    0xbc82d52107b43e1f, 0x3fef7c97337b9b5f,
    0xbc892ab93b470dc9, 0x3fef864614f5a129,
    0x3c74b604603a88d3, 0x3fef902ee78b3ff6,
    0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
    0xbc8ff7128fd391f0, 0x3fefa4afa2a490da,
    0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
    0x3c8ec3bc41aa2008, 0x3fefba1bee615a27,
    0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
    0x3c8a64a931d185ee, 0x3fefd0765b6e4540,
    0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
    0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8,
    0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
};

const log_tab = [128][2]f64{
    .{ 0x1.734f0c3e0de9fp+0, -0x1.7cc7f79e69000p-2 },
    .{ 0x1.713786a2ce91fp+0, -0x1.76feec20d0000p-2 },
    .{ 0x1.6f26008fab5a0p+0, -0x1.713e31351e000p-2 },
    .{ 0x1.6d1a61f138c7dp+0, -0x1.6b85b38287800p-2 },
    .{ 0x1.6b1490bc5b4d1p+0, -0x1.65d5590807800p-2 },
    .{ 0x1.69147332f0cbap+0, -0x1.602d076180000p-2 },
    .{ 0x1.6719f18224223p+0, -0x1.5a8ca86909000p-2 },
    .{ 0x1.6524f99a51ed9p+0, -0x1.54f4356035000p-2 },
    .{ 0x1.63356aa8f24c4p+0, -0x1.4f637c36b4000p-2 },
    .{ 0x1.614b36b9ddc14p+0, -0x1.49da7fda85000p-2 },
    .{ 0x1.5f66452c65c4cp+0, -0x1.445923989a800p-2 },
    .{ 0x1.5d867b5912c4fp+0, -0x1.3edf439b0b800p-2 },
    .{ 0x1.5babccb5b90dep+0, -0x1.396ce448f7000p-2 },
    .{ 0x1.59d61f2d91a78p+0, -0x1.3401e17bda000p-2 },
    .{ 0x1.5805612465687p+0, -0x1.2e9e2ef468000p-2 },
    .{ 0x1.56397cee76bd3p+0, -0x1.2941b3830e000p-2 },
    .{ 0x1.54725e2a77f93p+0, -0x1.23ec58cda8800p-2 },
    .{ 0x1.52aff42064583p+0, -0x1.1e9e129279000p-2 },
    .{ 0x1.50f22dbb2bddfp+0, -0x1.1956d2b48f800p-2 },
    .{ 0x1.4f38f4734ded7p+0, -0x1.141679ab9f800p-2 },
    .{ 0x1.4d843cfde2840p+0, -0x1.0edd094ef9800p-2 },
    .{ 0x1.4bd3ec078a3c8p+0, -0x1.09aa518db1000p-2 },
    .{ 0x1.4a27fc3e0258ap+0, -0x1.047e65263b800p-2 },
    .{ 0x1.4880524d48434p+0, -0x1.feb224586f000p-3 },
    .{ 0x1.46dce1b192d0bp+0, -0x1.f474a7517b000p-3 },
    .{ 0x1.453d9d3391854p+0, -0x1.ea4443d103000p-3 },
    .{ 0x1.43a2744b4845ap+0, -0x1.e020d44e9b000p-3 },
    .{ 0x1.420b54115f8fbp+0, -0x1.d60a22977f000p-3 },
    .{ 0x1.40782da3ef4b1p+0, -0x1.cc00104959000p-3 },
    .{ 0x1.3ee8f5d57fe8fp+0, -0x1.c202956891000p-3 },
    .{ 0x1.3d5d9a00b4ce9p+0, -0x1.b81178d811000p-3 },
    .{ 0x1.3bd60c010c12bp+0, -0x1.ae2c9ccd3d000p-3 },
    .{ 0x1.3a5242b75dab8p+0, -0x1.a45402e129000p-3 },
    .{ 0x1.38d22cd9fd002p+0, -0x1.9a877681df000p-3 },
    .{ 0x1.3755bc5847a1cp+0, -0x1.90c6d69483000p-3 },
    .{ 0x1.35dce49ad36e2p+0, -0x1.87120a645c000p-3 },
    .{ 0x1.34679984dd440p+0, -0x1.7d68fb4143000p-3 },
    .{ 0x1.32f5cceffcb24p+0, -0x1.73cb83c627000p-3 },
    .{ 0x1.3187775a10d49p+0, -0x1.6a39a9b376000p-3 },
    .{ 0x1.301c8373e3990p+0, -0x1.60b3154b7a000p-3 },
    .{ 0x1.2eb4ebb95f841p+0, -0x1.5737d76243000p-3 },
    .{ 0x1.2d50a0219a9d1p+0, -0x1.4dc7b8fc23000p-3 },
    .{ 0x1.2bef9a8b7fd2ap+0, -0x1.4462c51d20000p-3 },
    .{ 0x1.2a91c7a0c1babp+0, -0x1.3b08abc830000p-3 },
    .{ 0x1.293726014b530p+0, -0x1.31b996b490000p-3 },
    .{ 0x1.27dfa5757a1f5p+0, -0x1.2875490a44000p-3 },
    .{ 0x1.268b39b1d3bbfp+0, -0x1.1f3b9f879a000p-3 },
    .{ 0x1.2539d838ff5bdp+0, -0x1.160c8252ca000p-3 },
    .{ 0x1.23eb7aac9083bp+0, -0x1.0ce7f57f72000p-3 },
    .{ 0x1.22a012ba940b6p+0, -0x1.03cdc49fea000p-3 },
    .{ 0x1.2157996cc4132p+0, -0x1.f57bdbc4b8000p-4 },
    .{ 0x1.201201dd2fc9bp+0, -0x1.e370896404000p-4 },
    .{ 0x1.1ecf4494d480bp+0, -0x1.d17983ef94000p-4 },
    .{ 0x1.1d8f5528f6569p+0, -0x1.bf9674ed8a000p-4 },
    .{ 0x1.1c52311577e7cp+0, -0x1.adc79202f6000p-4 },
    .{ 0x1.1b17c74cb26e9p+0, -0x1.9c0c3e7288000p-4 },
    .{ 0x1.19e010c2c1ab6p+0, -0x1.8a646b372c000p-4 },
    .{ 0x1.18ab07bb670bdp+0, -0x1.78d01b3ac0000p-4 },
    .{ 0x1.1778a25efbcb6p+0, -0x1.674f145380000p-4 },
    .{ 0x1.1648d354c31dap+0, -0x1.55e0e6d878000p-4 },
    .{ 0x1.151b990275fddp+0, -0x1.4485cdea1e000p-4 },
    .{ 0x1.13f0ea432d24cp+0, -0x1.333d94d6aa000p-4 },
    .{ 0x1.12c8b7210f9dap+0, -0x1.22079f8c56000p-4 },
    .{ 0x1.11a3028ecb531p+0, -0x1.10e4698622000p-4 },
    .{ 0x1.107fbda8434afp+0, -0x1.ffa6c6ad20000p-5 },
    .{ 0x1.0f5ee0f4e6bb3p+0, -0x1.dda8d4a774000p-5 },
    .{ 0x1.0e4065d2a9fcep+0, -0x1.bbcece4850000p-5 },
    .{ 0x1.0d244632ca521p+0, -0x1.9a1894012c000p-5 },
    .{ 0x1.0c0a77ce2981ap+0, -0x1.788583302c000p-5 },
    .{ 0x1.0af2f83c636d1p+0, -0x1.5715e67d68000p-5 },
    .{ 0x1.09ddb98a01339p+0, -0x1.35c8a49658000p-5 },
    .{ 0x1.08cabaf52e7dfp+0, -0x1.149e364154000p-5 },
    .{ 0x1.07b9f2f4e28fbp+0, -0x1.e72c082eb8000p-6 },
    .{ 0x1.06ab58c358f19p+0, -0x1.a55f152528000p-6 },
    .{ 0x1.059eea5ecf92cp+0, -0x1.63d62cf818000p-6 },
    .{ 0x1.04949cdd12c90p+0, -0x1.228fb8caa0000p-6 },
    .{ 0x1.038c6c6f0ada9p+0, -0x1.c317b20f90000p-7 },
    .{ 0x1.02865137932a9p+0, -0x1.419355daa0000p-7 },
    .{ 0x1.0182427ea7348p+0, -0x1.81203c2ec0000p-8 },
    .{ 0x1.008040614b195p+0, -0x1.0040979240000p-9 },
    .{ 0x1.fe01ff726fa1ap-1, 0x1.feff384900000p-9 },
    .{ 0x1.fa11cc261ea74p-1, 0x1.7dc41353d0000p-7 },
    .{ 0x1.f6310b081992ep-1, 0x1.3cea3c4c28000p-6 },
    .{ 0x1.f25f63ceeadcdp-1, 0x1.b9fc114890000p-6 },
    .{ 0x1.ee9c8039113e7p-1, 0x1.1b0d8ce110000p-5 },
    .{ 0x1.eae8078cbb1abp-1, 0x1.58a5bd001c000p-5 },
    .{ 0x1.e741aa29d0c9bp-1, 0x1.95c8340d88000p-5 },
    .{ 0x1.e3a91830a99b5p-1, 0x1.d276aef578000p-5 },
    .{ 0x1.e01e009609a56p-1, 0x1.07598e598c000p-4 },
    .{ 0x1.dca01e577bb98p-1, 0x1.253f5e30d2000p-4 },
    .{ 0x1.d92f20b7c9103p-1, 0x1.42edd8b380000p-4 },
    .{ 0x1.d5cac66fb5ccep-1, 0x1.606598757c000p-4 },
    .{ 0x1.d272caa5ede9dp-1, 0x1.7da76356a0000p-4 },
    .{ 0x1.cf26e3e6b2ccdp-1, 0x1.9ab434e1c6000p-4 },
    .{ 0x1.cbe6da2a77902p-1, 0x1.b78c7bb0d6000p-4 },
    .{ 0x1.c8b266d37086dp-1, 0x1.d431332e72000p-4 },
    .{ 0x1.c5894bd5d5804p-1, 0x1.f0a3171de6000p-4 },
    .{ 0x1.c26b533bb9f8cp-1, 0x1.067152b914000p-3 },
    .{ 0x1.bf583eeece73fp-1, 0x1.147858292b000p-3 },
    .{ 0x1.bc4fd75db96c1p-1, 0x1.2266ecdca3000p-3 },
    .{ 0x1.b951e0c864a28p-1, 0x1.303d7a6c55000p-3 },
    .{ 0x1.b65e2c5ef3e2cp-1, 0x1.3dfc33c331000p-3 },
    .{ 0x1.b374867c9888bp-1, 0x1.4ba366b7a8000p-3 },
    .{ 0x1.b094b211d304ap-1, 0x1.5933928d1f000p-3 },
    .{ 0x1.adbe885f2ef7ep-1, 0x1.66acd2418f000p-3 },
    .{ 0x1.aaf1d31603da2p-1, 0x1.740f8ec669000p-3 },
    .{ 0x1.a82e63fd358a7p-1, 0x1.815c0f51af000p-3 },
    .{ 0x1.a5740ef09738bp-1, 0x1.8e92954f68000p-3 },
    .{ 0x1.a2c2a90ab4b27p-1, 0x1.9bb3602f84000p-3 },
    .{ 0x1.a01a01393f2d1p-1, 0x1.a8bed1c2c0000p-3 },
    .{ 0x1.9d79f24db3c1bp-1, 0x1.b5b515c01d000p-3 },
    .{ 0x1.9ae2505c7b190p-1, 0x1.c2967ccbcc000p-3 },
    .{ 0x1.9852ef297ce2fp-1, 0x1.cf635d5486000p-3 },
    .{ 0x1.95cbaeea44b75p-1, 0x1.dc1bd3446c000p-3 },
    .{ 0x1.934c69de74838p-1, 0x1.e8c01b8cfe000p-3 },
    .{ 0x1.90d4f2f6752e6p-1, 0x1.f5509c0179000p-3 },
    .{ 0x1.8e6528effd79dp-1, 0x1.00e6c121fb800p-2 },
    .{ 0x1.8bfce9fcc007cp-1, 0x1.071b80e93d000p-2 },
    .{ 0x1.899c0dabec30ep-1, 0x1.0d46b9e867000p-2 },
    .{ 0x1.87427aa2317fbp-1, 0x1.13687334bd000p-2 },
    .{ 0x1.84f00acb39a08p-1, 0x1.1980d67234800p-2 },
    .{ 0x1.82a49e8653e55p-1, 0x1.1f8ffe0cc8000p-2 },
    .{ 0x1.8060195f40260p-1, 0x1.2595fd7636800p-2 },
    .{ 0x1.7e22563e0a329p-1, 0x1.2b9300914a800p-2 },
    .{ 0x1.7beb377dcb5adp-1, 0x1.3187210436000p-2 },
    .{ 0x1.79baa679725c2p-1, 0x1.377266dec1800p-2 },
    .{ 0x1.77907f2170657p-1, 0x1.3d54ffbaf3000p-2 },
    .{ 0x1.756cadbd6130cp-1, 0x1.432eee32fe000p-2 },
};

const pow_tab = [128][3]f64{
    .{ 0x1.6a00000000000p+0, -0x1.62c82f2b9c800p-2, 0x1.ab42428375680p-48 },
    .{ 0x1.6800000000000p+0, -0x1.5d1bdbf580800p-2, -0x1.ca508d8e0f720p-46 },
    .{ 0x1.6600000000000p+0, -0x1.5767717455800p-2, -0x1.362a4d5b6506dp-45 },
    .{ 0x1.6400000000000p+0, -0x1.51aad872df800p-2, -0x1.684e49eb067d5p-49 },
    .{ 0x1.6200000000000p+0, -0x1.4be5f95777800p-2, -0x1.41b6993293ee0p-47 },
    .{ 0x1.6000000000000p+0, -0x1.4618bc21c6000p-2, 0x1.3d82f484c84ccp-46 },
    .{ 0x1.5e00000000000p+0, -0x1.404308686a800p-2, 0x1.c42f3ed820b3ap-50 },
    .{ 0x1.5c00000000000p+0, -0x1.3a64c55694800p-2, 0x1.0b1c686519460p-45 },
    .{ 0x1.5a00000000000p+0, -0x1.347dd9a988000p-2, 0x1.5594dd4c58092p-45 },
    .{ 0x1.5800000000000p+0, -0x1.2e8e2bae12000p-2, 0x1.67b1e99b72bd8p-45 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
    .{ 0x1.5400000000000p+0, -0x1.22941fbcf7800p-2, -0x1.65a242853da76p-46 },
    .{ 0x1.5200000000000p+0, -0x1.1c898c1699800p-2, -0x1.fafbc68e75404p-46 },
    .{ 0x1.5000000000000p+0, -0x1.1675cababa800p-2, 0x1.f1fc63382a8f0p-46 },
    .{ 0x1.4e00000000000p+0, -0x1.1058bf9ae4800p-2, -0x1.6a8c4fd055a66p-45 },
    .{ 0x1.4c00000000000p+0, -0x1.0a324e2739000p-2, -0x1.c6bee7ef4030ep-47 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
    .{ 0x1.4800000000000p+0, -0x1.fb9186d5e4000p-3, 0x1.d572aab993c87p-47 },
    .{ 0x1.4600000000000p+0, -0x1.ef0adcbdc6000p-3, 0x1.b26b79c86af24p-45 },
    .{ 0x1.4400000000000p+0, -0x1.e27076e2af000p-3, -0x1.72f4f543fff10p-46 },
    .{ 0x1.4200000000000p+0, -0x1.d5c216b4fc000p-3, 0x1.1ba91bbca681bp-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
    .{ 0x1.3e00000000000p+0, -0x1.bc286742d9000p-3, 0x1.94eb0318bb78fp-46 },
    .{ 0x1.3c00000000000p+0, -0x1.af3c94e80c000p-3, 0x1.a4e633fcd9066p-52 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
    .{ 0x1.3800000000000p+0, -0x1.9525a9cf45000p-3, -0x1.ad1d904c1d4e3p-45 },
    .{ 0x1.3600000000000p+0, -0x1.87fa06520d000p-3, 0x1.bbdbf7fdbfa09p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
    .{ 0x1.3200000000000p+0, -0x1.6d60fe719d000p-3, -0x1.0e46aa3b2e266p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
    .{ 0x1.2e00000000000p+0, -0x1.526e5e3a1b000p-3, -0x1.0de8b90075b8fp-45 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
    .{ 0x1.2a00000000000p+0, -0x1.371fc201e9000p-3, 0x1.178864d27543ap-48 },
    .{ 0x1.2800000000000p+0, -0x1.29552f81ff000p-3, -0x1.48d301771c408p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
    .{ 0x1.2200000000000p+0, -0x1.fec9131dbe000p-4, -0x1.575545ca333f2p-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
    .{ 0x1.1e00000000000p+0, -0x1.c5e548f5bc000p-4, -0x1.d0c57585fbe06p-46 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
    .{ 0x1.1800000000000p+0, -0x1.6f0d28ae56000p-4, -0x1.69737c93373dap-45 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
    .{ 0x1.1200000000000p+0, -0x1.16536eea38000p-4, 0x1.47c5e768fa309p-46 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
    .{ 0x1.0600000000000p+0, -0x1.7b91b07d58000p-6, -0x1.88d5493faa639p-45 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
    .{ 0x1.fc00000000000p-1, 0x1.0101575890000p-7, -0x1.0c76b999d2be8p-46 },
    .{ 0x1.f800000000000p-1, 0x1.0205658938000p-6, -0x1.3dc5b06e2f7d2p-45 },
    .{ 0x1.f400000000000p-1, 0x1.8492528c90000p-6, -0x1.aa0ba325a0c34p-45 },
    .{ 0x1.f000000000000p-1, 0x1.0415d89e74000p-5, 0x1.111c05cf1d753p-47 },
    .{ 0x1.ec00000000000p-1, 0x1.466aed42e0000p-5, -0x1.c167375bdfd28p-45 },
    .{ 0x1.e800000000000p-1, 0x1.894aa149fc000p-5, -0x1.97995d05a267dp-46 },
    .{ 0x1.e400000000000p-1, 0x1.ccb73cdddc000p-5, -0x1.a68f247d82807p-46 },
    .{ 0x1.e200000000000p-1, 0x1.eea31c006c000p-5, -0x1.e113e4fc93b7bp-47 },
    .{ 0x1.de00000000000p-1, 0x1.1973bd1466000p-4, -0x1.5325d560d9e9bp-45 },
    .{ 0x1.da00000000000p-1, 0x1.3bdf5a7d1e000p-4, 0x1.cc85ea5db4ed7p-45 },
    .{ 0x1.d600000000000p-1, 0x1.5e95a4d97a000p-4, -0x1.c69063c5d1d1ep-45 },
    .{ 0x1.d400000000000p-1, 0x1.700d30aeac000p-4, 0x1.c1e8da99ded32p-49 },
    .{ 0x1.d000000000000p-1, 0x1.9335e5d594000p-4, 0x1.3115c3abd47dap-45 },
    .{ 0x1.cc00000000000p-1, 0x1.b6ac88dad6000p-4, -0x1.390802bf768e5p-46 },
    .{ 0x1.ca00000000000p-1, 0x1.c885801bc4000p-4, 0x1.646d1c65aacd3p-45 },
    .{ 0x1.c600000000000p-1, 0x1.ec739830a2000p-4, -0x1.dc068afe645e0p-45 },
    .{ 0x1.c400000000000p-1, 0x1.fe89139dbe000p-4, -0x1.534d64fa10afdp-45 },
    .{ 0x1.c000000000000p-1, 0x1.1178e8227e000p-3, 0x1.1ef78ce2d07f2p-45 },
    .{ 0x1.be00000000000p-1, 0x1.1aa2b7e23f000p-3, 0x1.ca78e44389934p-45 },
    .{ 0x1.ba00000000000p-1, 0x1.2d1610c868000p-3, 0x1.39d6ccb81b4a1p-47 },
    .{ 0x1.b800000000000p-1, 0x1.365fcb0159000p-3, 0x1.62fa8234b7289p-51 },
    .{ 0x1.b400000000000p-1, 0x1.4913d8333b000p-3, 0x1.5837954fdb678p-45 },
    .{ 0x1.b200000000000p-1, 0x1.527e5e4a1b000p-3, 0x1.633e8e5697dc7p-45 },
    .{ 0x1.ae00000000000p-1, 0x1.6574ebe8c1000p-3, 0x1.9cf8b2c3c2e78p-46 },
    .{ 0x1.ac00000000000p-1, 0x1.6f0128b757000p-3, -0x1.5118de59c21e1p-45 },
    .{ 0x1.aa00000000000p-1, 0x1.7898d85445000p-3, -0x1.c661070914305p-46 },
    .{ 0x1.a600000000000p-1, 0x1.8beafeb390000p-3, -0x1.73d54aae92cd1p-47 },
    .{ 0x1.a400000000000p-1, 0x1.95a5adcf70000p-3, 0x1.7f22858a0ff6fp-47 },
    .{ 0x1.a000000000000p-1, 0x1.a93ed3c8ae000p-3, -0x1.8724350562169p-45 },
    .{ 0x1.9e00000000000p-1, 0x1.b31d8575bd000p-3, -0x1.c358d4eace1aap-47 },
    .{ 0x1.9c00000000000p-1, 0x1.bd087383be000p-3, -0x1.d4bc4595412b6p-45 },
    .{ 0x1.9a00000000000p-1, 0x1.c6ffbc6f01000p-3, -0x1.1ec72c5962bd2p-48 },
    .{ 0x1.9600000000000p-1, 0x1.db13db0d49000p-3, -0x1.aff2af715b035p-45 },
    .{ 0x1.9400000000000p-1, 0x1.e530effe71000p-3, 0x1.212276041f430p-51 },
    .{ 0x1.9200000000000p-1, 0x1.ef5ade4dd0000p-3, -0x1.a211565bb8e11p-51 },
    .{ 0x1.9000000000000p-1, 0x1.f991c6cb3b000p-3, 0x1.bcbecca0cdf30p-46 },
    .{ 0x1.8c00000000000p-1, 0x1.07138604d5800p-2, 0x1.89cdb16ed4e91p-48 },
    .{ 0x1.8a00000000000p-1, 0x1.0c42d67616000p-2, 0x1.7188b163ceae9p-45 },
    .{ 0x1.8800000000000p-1, 0x1.1178e8227e800p-2, -0x1.c210e63a5f01cp-45 },
    .{ 0x1.8600000000000p-1, 0x1.16b5ccbacf800p-2, 0x1.b9acdf7a51681p-45 },
    .{ 0x1.8400000000000p-1, 0x1.1bf99635a6800p-2, 0x1.ca6ed5147bdb7p-45 },
    .{ 0x1.8200000000000p-1, 0x1.214456d0eb800p-2, 0x1.a87deba46baeap-47 },
    .{ 0x1.7e00000000000p-1, 0x1.2bef07cdc9000p-2, 0x1.a9cfa4a5004f4p-45 },
    .{ 0x1.7c00000000000p-1, 0x1.314f1e1d36000p-2, -0x1.8e27ad3213cb8p-45 },
    .{ 0x1.7a00000000000p-1, 0x1.36b6776be1000p-2, 0x1.16ecdb0f177c8p-46 },
    .{ 0x1.7800000000000p-1, 0x1.3c25277333000p-2, 0x1.83b54b606bd5cp-46 },
    .{ 0x1.7600000000000p-1, 0x1.419b423d5e800p-2, 0x1.8e436ec90e09dp-47 },
    .{ 0x1.7400000000000p-1, 0x1.4718dc271c800p-2, -0x1.f27ce0967d675p-45 },
    .{ 0x1.7200000000000p-1, 0x1.4c9e09e173000p-2, -0x1.e20891b0ad8a4p-45 },
    .{ 0x1.7000000000000p-1, 0x1.522ae0738a000p-2, 0x1.ebe708164c759p-45 },
    .{ 0x1.6e00000000000p-1, 0x1.57bf753c8d000p-2, 0x1.fadedee5d40efp-46 },
    .{ 0x1.6c00000000000p-1, 0x1.5d5bddf596000p-2, -0x1.a0b2a08a465dcp-47 },
};

const snum = [13]f64{
    0x1.5ea5143c1a49ep+34, // 23531376880.410759688572007674451636754734846804940
    0x1.3fc7075f54c57p+35, // 42919803642.649098768957899047001988850926355848959
    0x1.0a132818ab61ap+35, // 35711959237.355668049440185451547166705960488635843
    0x1.0b0b522e8261ap+34, // 17921034426.037209699919755754458931112671403265390
    0x1.67fc1b3a5a1e8p+32, // 6039542586.3520280050642916443072979210699388420708
    0x1.57418f5d3f33fp+30, // 1439720407.3117216736632230727949123939715485786772
    0x1.dab0c7bb95f2ap+27, // 248874557.86205415651146038641322942321632125127801
    0x1.df876f95dcc98p+24, // 31426415.585400194380614231628318205362874684987640
    0x1.5f1e95080f44cp+21, // 2876370.6289353724412254090516208496135991145378768
    0x1.6b6421f8787ebp+17, // 186056.26539522349504029498971604569928220784236328
    0x1.f87ac0858d804p+12, // 8071.6720023658162106380029022722506138218516325024
    0x1.a5a607bbc3b52p+7, // 210.82427775157934587250973392071336271166969580291
    0x1.40d931ff62705p+1, // 2.5066282746310002701649081771338373386264310793408
};

const sden = [13]f64{
    0x0.0p+0, // 0
    0x1.308a800000000p+25, // 39916800
    0x1.cbd6980000000p+26, // 120543840
    0x1.1fda6b0000000p+27, // 150917976
    0x1.9187170000000p+26, // 105258076
    0x1.5eeb690000000p+25, // 45995730
    0x1.97171e0000000p+23, // 13339535
    0x1.41f7b00000000p+21, // 2637558
    0x1.5d0bc00000000p+18, // 357423
    0x1.fe78000000000p+14, // 32670
    0x1.e140000000000p+10, // 1925
    0x1.0800000000000p+6, // 66
    0x1.0000000000000p+0, // 1
};

const fact = [23]f64{
    0x1.0000000000000p+0, // 1
    0x1.0000000000000p+0, // 1
    0x1.0000000000000p+1, // 2
    0x1.8000000000000p+2, // 6
    0x1.8000000000000p+4, // 24
    0x1.e000000000000p+6, // 120
    0x1.6800000000000p+9, // 720
    0x1.3b00000000000p+12, // 5040.0
    0x1.3b00000000000p+15, // 40320.0
    0x1.6260000000000p+18, // 362880.0
    0x1.baf8000000000p+21, // 3628800.0
    0x1.308a800000000p+25, // 39916800.0
    0x1.c8cfc00000000p+28, // 479001600.0
    0x1.7328cc0000000p+32, // 6227020800.0
    0x1.44c3b28000000p+36, // 87178291200.0
    0x1.3077775800000p+40, // 1307674368000.0
    0x1.3077775800000p+44, // 20922789888000.0
    0x1.437eeecd80000p+48, // 355687428096000.0
    0x1.6beecca730000p+52, // 6402373705728000.0
    0x1.b02b930689000p+56, // 121645100408832000.0
    0x1.0e1b3be415a00p+61, // 2432902008176640000.0
    0x1.6283be9b5c620p+65, // 51090942171709440000.0
    0x1.e77526159f06cp+69, // 1124000727777607680000.0
};

// musl's erf.c.
const erx = 8.45062911510467529297e-01;
const efx8 = 1.02703333676410069053e+00;
const pp0 = 1.28379167095512558561e-01;
const pp1 = -3.25042107247001499370e-01;
const pp2 = -2.84817495755985104766e-02;
const pp3 = -5.77027029648944159157e-03;
const pp4 = -2.37630166566501626084e-05;
const qq1 = 3.97917223959155352819e-01;
const qq2 = 6.50222499887672944485e-02;
const qq3 = 5.08130628187576562776e-03;
const qq4 = 1.32494738004321644526e-04;
const qq5 = -3.96022827877536812320e-06;
const pa0 = -2.36211856075265944077e-03;
const pa1 = 4.14856118683748331666e-01;
const pa2 = -3.72207876035701323847e-01;
const pa3 = 3.18346619901161753674e-01;
const pa4 = -1.10894694282396677476e-01;
const pa5 = 3.54783043256182359371e-02;
const pa6 = -2.16637559486879084300e-03;
const qa1 = 1.06420880400844228286e-01;
const qa2 = 5.40397917702171048937e-01;
const qa3 = 7.18286544141962662868e-02;
const qa4 = 1.26171219808761642112e-01;
const qa5 = 1.36370839120290507362e-02;
const qa6 = 1.19844998467991074170e-02;
const ra0 = -9.86494403484714822705e-03;
const ra1 = -6.93858572707181764372e-01;
const ra2 = -1.05586262253232909814e+01;
const ra3 = -6.23753324503260060396e+01;
const ra4 = -1.62396669462573470355e+02;
const ra5 = -1.84605092906711035994e+02;
const ra6 = -8.12874355063065934246e+01;
const ra7 = -9.81432934416914548592e+00;
const sa1 = 1.96512716674392571292e+01;
const sa2 = 1.37657754143519042600e+02;
const sa3 = 4.34565877475229228821e+02;
const sa4 = 6.45387271733267880336e+02;
const sa5 = 4.29008140027567833386e+02;
const sa6 = 1.08635005541779435134e+02;
const sa7 = 6.57024977031928170135e+00;
const sa8 = -6.04244152148580987438e-02;
const rb0 = -9.86494292470009928597e-03;
const rb1 = -7.99283237680523006574e-01;
const rb2 = -1.77579549177547519889e+01;
const rb3 = -1.60636384855821916062e+02;
const rb4 = -6.37566443368389627722e+02;
const rb5 = -1.02509513161107724954e+03;
const rb6 = -4.83519191608651397019e+02;
const sb1 = 3.03380607434824582924e+01;
const sb2 = 3.25792512996573918826e+02;
const sb3 = 1.53672958608443695994e+03;
const sb4 = 3.19985821950859553908e+03;
const sb5 = 2.55305040643316442583e+03;
const sb6 = 4.74528541206955367215e+02;
const sb7 = -2.24409524465858183362e+01;

fn highWord(x: f64) u32 {
    return @truncate(@as(u64, @bitCast(x)) >> 32);
}

fn erfc1(x: f64) f64 {
    const s = @abs(x) - 1;
    const P = pa0 + s * (pa1 + s * (pa2 + s * (pa3 + s * (pa4 + s * (pa5 + s * pa6)))));
    const Q = 1 + s * (qa1 + s * (qa2 + s * (qa3 + s * (qa4 + s * (qa5 + s * qa6)))));
    return 1 - erx - P / Q;
}

fn erfc2(ix: u32, x0: f64) f64 {
    if (ix < 0x3ff40000) return erfc1(x0);
    const x = @abs(x0);
    const s = 1 / (x * x);
    var R: f64 = undefined;
    var S: f64 = undefined;
    if (ix < 0x4006db6d) {
        R = ra0 + s * (ra1 + s * (ra2 + s * (ra3 + s * (ra4 + s * (ra5 + s * (ra6 + s * ra7))))));
        S = 1.0 + s * (sa1 + s * (sa2 + s * (sa3 + s * (sa4 + s * (sa5 + s * (sa6 + s * (sa7 + s * sa8)))))));
    } else {
        R = rb0 + s * (rb1 + s * (rb2 + s * (rb3 + s * (rb4 + s * (rb5 + s * rb6)))));
        S = 1.0 + s * (sb1 + s * (sb2 + s * (sb3 + s * (sb4 + s * (sb5 + s * (sb6 + s * sb7))))));
    }
    const z: f64 = @bitCast(@as(u64, @bitCast(x)) & 0xffffffff00000000);
    return exp(-z * z - 0.5625) * exp((z - x) * (z + x) + R / S) / x;
}

pub fn erf(x: f64) f64 {
    var ix = highWord(x);
    const sign = ix >> 31 != 0;
    ix &= 0x7fffffff;
    if (ix >= 0x7ff00000) return @as(f64, if (sign) -1 else 1) + 1 / x;
    if (ix < 0x3feb0000) {
        if (ix < 0x3e300000) return 0.125 * (8 * x + efx8 * x);
        const z = x * x;
        const r = pp0 + z * (pp1 + z * (pp2 + z * (pp3 + z * pp4)));
        const s = 1.0 + z * (qq1 + z * (qq2 + z * (qq3 + z * (qq4 + z * qq5))));
        const y = r / s;
        return x + x * y;
    }
    const y = if (ix < 0x40180000) 1 - erfc2(ix, x) else 1 - 0x1p-1022;
    return if (sign) -y else y;
}

pub fn erfc(x: f64) f64 {
    var ix = highWord(x);
    const sign = ix >> 31 != 0;
    ix &= 0x7fffffff;
    if (ix >= 0x7ff00000) return @as(f64, if (sign) 2 else 0) + 1 / x;
    if (ix < 0x3feb0000) {
        if (ix < 0x3c700000) return 1.0 - x;
        const z = x * x;
        const r = pp0 + z * (pp1 + z * (pp2 + z * (pp3 + z * pp4)));
        const s = 1.0 + z * (qq1 + z * (qq2 + z * (qq3 + z * (qq4 + z * qq5))));
        const y = r / s;
        if (sign or ix < 0x3fd00000) return 1.0 - (x + x * y);
        return 0.5 - (x - 0.5 + x * y);
    }
    if (ix < 0x403c0000) return if (sign) 2 - erfc2(ix, x) else erfc2(ix, x);
    return if (sign) 2 - 0x1p-1022 else 0x1p-1022 * 0x1p-1022;
}

// ---------------------------------------------------------------- sin, cos, tan
//
// musl's sin.c, cos.c, tan.c, __sin.c, __cos.c, __tan.c, __rem_pio2.c
// and __rem_pio2_large.c (FreeBSD/Sun), as Zig's compiler-rt ports them
// (lib/compiler_rt/{sin,cos,tan,trig,rem_pio2,rem_pio2_large}.zig, Zig
// 0.17), the f64 functions only, without the floating-point exceptions.
// Here and not @sin, @cos and @tan, which call the C library's where one
// is linked in a release build and compiler-rt's otherwise.

/// kernel cos function on [-pi/4, pi/4], pi/4 ~ 0.785398164
/// Input x is assumed to be bounded by ~pi/4 in magnitude.
/// Input y is the tail of x.
///
/// Algorithm
///      1. Since cos(-x) = cos(x), we need only to consider positive x.
///      2. if x < 2^-27 (hx<0x3e400000 0), return 1 with inexact if x!=0.
///      3. cos(x) is approximated by a polynomial of degree 14 on
///         [0,pi/4]
///                                       4            14
///              cos(x) ~ 1 - x*x/2 + C1*x + ... + C6*x
///         where the remez error is
///
///      |              2     4     6     8     10    12     14 |     -58
///      |cos(x)-(1-.5*x +C1*x +C2*x +C3*x +C4*x +C5*x  +C6*x  )| <= 2
///      |                                                      |
///
///                     4     6     8     10    12     14
///      4. let r = C1*x +C2*x +C3*x +C4*x +C5*x  +C6*x  , then
///             cos(x) ~ 1 - x*x/2 + r
///         since cos(x+y) ~ cos(x) - sin(x)*y
///                        ~ cos(x) - x*y,
///         a correction term is necessary in cos(x) and hence
///              cos(x+y) = 1 - (x*x/2 - (r - x*y))
///         For better accuracy, rearrange to
///              cos(x+y) ~ w + (tmp + (r-x*y))
///         where w = 1 - x*x/2 and tmp is a tiny correction term
///         (1 - x*x/2 == w + tmp exactly in infinite precision).
///         The exactness of w + tmp in infinite precision depends on w
///         and tmp having the same precision as x.  If they have extra
///         precision due to compiler bugs, then the extra precision is
///         only good provided it is retained in all terms of the final
///         expression for cos().  Retention happens in all cases tested
///         under FreeBSD, so don't pessimize things by forcibly clipping
///         any extra precision in w.
fn kcos(x: f64, y: f64) f64 {
    const C1 = 4.16666666666666019037e-02; // 0x3FA55555, 0x5555554C
    const C2 = -1.38888888888741095749e-03; // 0xBF56C16C, 0x16C15177
    const C3 = 2.48015872894767294178e-05; // 0x3EFA01A0, 0x19CB1590
    const C4 = -2.75573143513906633035e-07; // 0xBE927E4F, 0x809C52AD
    const C5 = 2.08757232129817482790e-09; // 0x3E21EE9E, 0xBDB4B1C4
    const C6 = -1.13596475577881948265e-11; // 0xBDA8FAE9, 0xBE8838D4

    const z = x * x;
    const zs = z * z;
    const r = z * (C1 + z * (C2 + z * C3)) + zs * zs * (C4 + z * (C5 + z * C6));
    const hz = 0.5 * z;
    const w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + (z * r - x * y));
}

/// kernel sin function on ~[-pi/4, pi/4] (except on -0), pi/4 ~ 0.7854
/// Input x is assumed to be bounded by ~pi/4 in magnitude.
/// Input y is the tail of x.
/// Input iy indicates whether y is 0. (if iy=0, y assume to be 0).
///
/// Algorithm
///      1. Since sin(-x) = -sin(x), we need only to consider positive x.
///      2. Callers must return sin(-0) = -0 without calling here since our
///         odd polynomial is not evaluated in a way that preserves -0.
///         Callers may do the optimization sin(x) ~ x for tiny x.
///      3. sin(x) is approximated by a polynomial of degree 13 on
///         [0,pi/4]
///                               3            13
///              sin(x) ~ x + S1*x + ... + S6*x
///         where
///
///      |sin(x)         2     4     6     8     10     12  |     -58
///      |----- - (1+S1*x +S2*x +S3*x +S4*x +S5*x  +S6*x   )| <= 2
///      |  x                                               |
///
///      4. sin(x+y) = sin(x) + sin'(x')*y
///                  ~ sin(x) + (1-x*x/2)*y
///         For better accuracy, let
///                   3      2      2      2      2
///              r = x *(S2+x *(S3+x *(S4+x *(S5+x *S6))))
///         then                   3    2
///              sin(x) = x + (S1*x + (x *(r-y/2)+y))
fn ksin(x: f64, y: f64, iy: i32) f64 {
    const S1 = -1.66666666666666324348e-01; // 0xBFC55555, 0x55555549
    const S2 = 8.33333333332248946124e-03; // 0x3F811111, 0x1110F8A6
    const S3 = -1.98412698298579493134e-04; // 0xBF2A01A0, 0x19C161D5
    const S4 = 2.75573137070700676789e-06; // 0x3EC71DE3, 0x57B1FE7D
    const S5 = -2.50507602534068634195e-08; // 0xBE5AE5E6, 0x8A2B9CEB
    const S6 = 1.58969099521155010221e-10; // 0x3DE5D93A, 0x5ACFD57C

    const z = x * x;
    const w = z * z;
    const r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    const v = z * x;
    if (iy == 0) {
        return x + v * (S1 + z * r);
    } else {
        return x - ((z * (0.5 * y - v * r) - y) - v * S1);
    }
}

/// kernel tan function on ~[-pi/4, pi/4] (except on -0), pi/4 ~ 0.7854
/// Input x is assumed to be bounded by ~pi/4 in magnitude.
/// Input y is the tail of x.
/// Input odd indicates whether tan (if odd = 0) or -1/tan (if odd = 1) is returned.
///
/// Algorithm
///      1. Since tan(-x) = -tan(x), we need only to consider positive x.
///      2. Callers must return tan(-0) = -0 without calling here since our
///         odd polynomial is not evaluated in a way that preserves -0.
///         Callers may do the optimization tan(x) ~ x for tiny x.
///      3. tan(x) is approximated by a odd polynomial of degree 27 on
///         [0,0.67434]
///                               3             27
///              tan(x) ~ x + T1*x + ... + T13*x
///         where
///
///              |tan(x)         2     4            26   |     -59.2
///              |----- - (1+T1*x +T2*x +.... +T13*x    )| <= 2
///              |  x                                    |
///
///         Note: tan(x+y) = tan(x) + tan'(x)*y
///                        ~ tan(x) + (1+x*x)*y
///         Therefore, for better accuracy in computing tan(x+y), let
///                   3      2      2       2       2
///              r = x *(T2+x *(T3+x *(...+x *(T12+x *T13))))
///         then
///                                  3    2
///              tan(x+y) = x + (T1*x + (x *(r+y)+y))
///
///      4. For x in [0.67434,pi/4],  let y = pi/4 - x, then
///              tan(x) = tan(pi/4-y) = (1-tan(y))/(1+tan(y))
///                     = 1 - 2*(tan(y) - (tan(y)^2)/(1+tan(y)))
fn ktan(x_: f64, y_: f64, odd: bool) f64 {
    var x = x_;
    var y = y_;

    const T = [_]f64{
        3.33333333333334091986e-01, // 3FD55555, 55555563
        1.33333333333201242699e-01, // 3FC11111, 1110FE7A
        5.39682539762260521377e-02, // 3FABA1BA, 1BB341FE
        2.18694882948595424599e-02, // 3F9664F4, 8406D637
        8.86323982359930005737e-03, // 3F8226E3, E96E8493
        3.59207910759131235356e-03, // 3F6D6D22, C9560328
        1.45620945432529025516e-03, // 3F57DBC8, FEE08315
        5.88041240820264096874e-04, // 3F4344D8, F2F26501
        2.46463134818469906812e-04, // 3F3026F7, 1A8D1068
        7.81794442939557092300e-05, // 3F147E88, A03792A6
        7.14072491382608190305e-05, // 3F12B80F, 32F0A7E9
        -1.85586374855275456654e-05, // BEF375CB, DB605373
        2.59073051863633712884e-05, // 3EFB2A70, 74BF7AD4
    };
    const pio4 = 7.85398163397448278999e-01; // 3FE921FB, 54442D18
    const pio4lo = 3.06161699786838301793e-17; // 3C81A626, 33145C07

    var z: f64 = undefined;
    var r: f64 = undefined;
    var v: f64 = undefined;
    var w: f64 = undefined;
    var s: f64 = undefined;
    var a: f64 = undefined;
    var w0: f64 = undefined;
    var a0: f64 = undefined;
    var hx: u32 = undefined;
    var sign: bool = undefined;

    hx = @intCast(@as(u64, @bitCast(x)) >> 32);
    const big = (hx & 0x7fffffff) >= 0x3FE59428; // |x| >= 0.6744
    if (big) {
        sign = hx >> 31 != 0;
        if (sign) {
            x = -x;
            y = -y;
        }
        x = (pio4 - x) + (pio4lo - y);
        y = 0.0;
    }
    z = x * x;
    w = z * z;

    // Break x^5*(T[1]+x^2*T[2]+...) into
    // x^5(T[1]+x^4*T[3]+...+x^20*T[11]) +
    // x^5(x^2*(T[2]+x^4*T[4]+...+x^22*[T12]))
    r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
    v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
    s = z * x;
    r = y + z * (s * (r + v) + y) + s * T[0];
    w = x + r;
    if (big) {
        s = @floatFromInt(1 - 2 * @as(i3, @intFromBool(odd)));
        v = s - 2.0 * (x + (r - w * w / (w + s)));
        return if (sign) -v else v;
    }
    if (!odd) {
        return w;
    }
    // -1.0/(x+r) has up to 2ulp error, so compute it accurately
    w0 = w;
    w0 = @bitCast(@as(u64, @bitCast(w0)) & 0xffffffff00000000);
    v = r - (w0 - x); // w0+v = r+x
    a = -1.0 / w;
    a0 = a;
    a0 = @bitCast(@as(u64, @bitCast(a0)) & 0xffffffff00000000);
    return a0 + a * (1.0 + a0 * w0 + a0 * v);
}

const rp_toint = 1.5 / std.math.floatEps(f64);
// pi/4
const rp_pio4 = 0x1.921fb54442d18p-1;
// rp_invpio2:  53 bits of 2/pi
const rp_invpio2 = 6.36619772367581382433e-01; // 0x3FE45F30, 0x6DC9C883
// rp_pio2_1:   first  33 bit of pi/2
const rp_pio2_1 = 1.57079632673412561417e+00; // 0x3FF921FB, 0x54400000
// rp_pio2_1t:  pi/2 - rp_pio2_1
const rp_pio2_1t = 6.07710050650619224932e-11; // 0x3DD0B461, 0x1A626331
// rp_pio2_2:   second 33 bit of pi/2
const rp_pio2_2 = 6.07710050630396597660e-11; // 0x3DD0B461, 0x1A600000
// rp_pio2_2t:  pi/2 - (rp_pio2_1+rp_pio2_2)
const rp_pio2_2t = 2.02226624879595063154e-21; // 0x3BA3198A, 0x2E037073
// rp_pio2_3:   third  33 bit of pi/2
const rp_pio2_3 = 2.02226624871116645580e-21; // 0x3BA3198A, 0x2E000000
// rp_pio2_3t:  pi/2 - (rp_pio2_1+rp_pio2_2+rp_pio2_3)
const rp_pio2_3t = 8.47842766036889956997e-32; // 0x397B839A, 0x252049C1

fn remPio2Medium(ix: u32, x: f64, y: *[2]f64) i32 {
    var w: f64 = undefined;
    var t: f64 = undefined;
    var r: f64 = undefined;
    var @"fn": f64 = undefined;
    var n: i32 = undefined;
    var ex: i32 = undefined;
    var ey: i32 = undefined;
    var ui: u64 = undefined;

    // rint(x/(pi/2))
    @"fn" = x * rp_invpio2 + rp_toint - rp_toint;
    n = @intFromFloat(@"fn");
    r = x - @"fn" * rp_pio2_1;
    w = @"fn" * rp_pio2_1t; // 1st round, good to 85 bits
    // Matters with directed rounding.
    if (r - w < -rp_pio4) {
        n -= 1;
        @"fn" -= 1;
        r = x - @"fn" * rp_pio2_1;
        w = @"fn" * rp_pio2_1t;
    } else if (r - w > rp_pio4) {
        n += 1;
        @"fn" += 1;
        r = x - @"fn" * rp_pio2_1;
        w = @"fn" * rp_pio2_1t;
    }
    y[0] = r - w;
    ui = @bitCast(y[0]);
    ey = @intCast((ui >> 52) & 0x7ff);
    ex = @intCast(ix >> 20);
    if (ex - ey > 16) { // 2nd round, good to 118 bits
        t = r;
        w = @"fn" * rp_pio2_2;
        r = t - w;
        w = @"fn" * rp_pio2_2t - ((t - r) - w);
        y[0] = r - w;
        ui = @bitCast(y[0]);
        ey = @intCast((ui >> 52) & 0x7ff);
        if (ex - ey > 49) { // 3rd round, good to 151 bits, covers all cases
            t = r;
            w = @"fn" * rp_pio2_3;
            r = t - w;
            w = @"fn" * rp_pio2_3t - ((t - r) - w);
            y[0] = r - w;
        }
    }
    y[1] = (r - y[0]) - w;
    return n;
}

// Returns the remainder of x rem pi/2 in y[0]+y[1]
//
// use remPio2Large() for large x
//
// caller must handle the case when reduction is not needed: |x| ~<= pi/4 */
fn remPio2(x: f64, y: *[2]f64) i32 {
    var z: f64 = undefined;
    var tx: [3]f64 = undefined;
    var ty: [2]f64 = undefined;
    var n: i32 = undefined;
    var ix: u32 = undefined;
    var sign: bool = undefined;
    var i: i32 = undefined;
    var ui: u64 = undefined;

    ui = @bitCast(x);
    sign = ui >> 63 != 0;
    ix = @truncate((ui >> 32) & 0x7fffffff);
    if (ix <= 0x400f6a7a) { // |x| ~<= 5pi/4
        if ((ix & 0xfffff) == 0x921fb) { // |x| ~= pi/2 or 2pi/2
            return remPio2Medium(ix, x, y);
        }
        if (ix <= 0x4002d97c) { // |x| ~<= 3pi/4
            if (!sign) {
                z = x - rp_pio2_1; // one round good to 85 bits
                y[0] = z - rp_pio2_1t;
                y[1] = (z - y[0]) - rp_pio2_1t;
                return 1;
            } else {
                z = x + rp_pio2_1;
                y[0] = z + rp_pio2_1t;
                y[1] = (z - y[0]) + rp_pio2_1t;
                return -1;
            }
        } else {
            if (!sign) {
                z = x - 2 * rp_pio2_1;
                y[0] = z - 2 * rp_pio2_1t;
                y[1] = (z - y[0]) - 2 * rp_pio2_1t;
                return 2;
            } else {
                z = x + 2 * rp_pio2_1;
                y[0] = z + 2 * rp_pio2_1t;
                y[1] = (z - y[0]) + 2 * rp_pio2_1t;
                return -2;
            }
        }
    }
    if (ix <= 0x401c463b) { // |x| ~<= 9pi/4
        if (ix <= 0x4015fdbc) { // |x| ~<= 7pi/4
            if (ix == 0x4012d97c) { // |x| ~= 3pi/2
                return remPio2Medium(ix, x, y);
            }
            if (!sign) {
                z = x - 3 * rp_pio2_1;
                y[0] = z - 3 * rp_pio2_1t;
                y[1] = (z - y[0]) - 3 * rp_pio2_1t;
                return 3;
            } else {
                z = x + 3 * rp_pio2_1;
                y[0] = z + 3 * rp_pio2_1t;
                y[1] = (z - y[0]) + 3 * rp_pio2_1t;
                return -3;
            }
        } else {
            if (ix == 0x401921fb) { // |x| ~= 4pi/2 */
                return remPio2Medium(ix, x, y);
            }
            if (!sign) {
                z = x - 4 * rp_pio2_1;
                y[0] = z - 4 * rp_pio2_1t;
                y[1] = (z - y[0]) - 4 * rp_pio2_1t;
                return 4;
            } else {
                z = x + 4 * rp_pio2_1;
                y[0] = z + 4 * rp_pio2_1t;
                y[1] = (z - y[0]) + 4 * rp_pio2_1t;
                return -4;
            }
        }
    }
    if (ix < 0x413921fb) { // |x| ~< 2^20*(pi/2), medium size
        return remPio2Medium(ix, x, y);
    }
    // all other (large) arguments
    if (ix >= 0x7ff00000) { // x is inf or NaN
        y[0] = x - x;
        y[1] = y[0];
        return 0;
    }
    // set z = scalbn(|x|,-ilogb(x)+23)
    ui = @bitCast(x);
    ui &= std.math.maxInt(u64) >> 12;
    ui |= @as(u64, 0x3ff + 23) << 52;
    z = @bitCast(ui);

    i = 0;
    while (i < 2) : (i += 1) {
        tx[@intCast(i)] = @floatFromInt(@as(i32, @intFromFloat(z)));
        z = (z - tx[@intCast(i)]) * 0x1p24;
    }
    tx[@intCast(i)] = z;
    // skip zero terms, first term is non-zero
    while (tx[@intCast(i)] == 0.0) {
        i -= 1;
    }
    n = remPio2Large(tx[0..], ty[0..], @as(i32, @intCast((ix >> 20))) - (0x3ff + 23), i + 1, 1);
    if (sign) {
        y[0] = -ty[0];
        y[1] = -ty[1];
        return -n;
    }
    y[0] = ty[0];
    y[1] = ty[1];
    return n;
}

const rp_init_jk = [_]i32{ 3, 4, 4, 6 }; // initial value for jk

///
/// Table of constants for 2/pi, 396 Hex digits (476 decimal) of 2/pi
///
///              integer array, contains the (24*i)-th to (24*i+23)-th
///              bit of 2/pi after binary point. The corresponding
///              floating value is
///
///                      rp_ipio2[i] * 2^(-24(i+1)).
///
/// NB: This table must have at least (e0-3)/24 + jk terms.
///     For quad precision (e0 <= 16360, jk = 6), this is 686.
const rp_ipio2 = [_]i32{
    0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
    0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
    0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
    0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
    0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
    0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
    0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
    0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
    0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
    0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
    0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,

    0x47C419, 0xC367CD, 0xDCE809, 0x2A8359, 0xC4768B, 0x961CA6,
    0xDDAF44, 0xD15719, 0x053EA5, 0xFF0705, 0x3F7E33, 0xE832C2,
    0xDE4F98, 0x327DBB, 0xC33D26, 0xEF6B1E, 0x5EF89F, 0x3A1F35,
    0xCAF27F, 0x1D87F1, 0x21907C, 0x7C246A, 0xFA6ED5, 0x772D30,
    0x433B15, 0xC614B5, 0x9D19C3, 0xC2C4AD, 0x414D2C, 0x5D000C,
    0x467D86, 0x2D71E3, 0x9AC69B, 0x006233, 0x7CD2B4, 0x97A7B4,
    0xD55537, 0xF63ED7, 0x1810A3, 0xFC764D, 0x2A9D64, 0xABD770,
    0xF87C63, 0x57B07A, 0xE71517, 0x5649C0, 0xD9D63B, 0x3884A7,
    0xCB2324, 0x778AD6, 0x23545A, 0xB91F00, 0x1B0AF1, 0xDFCE19,
    0xFF319F, 0x6A1E66, 0x615799, 0x47FBAC, 0xD87F7E, 0xB76522,
    0x89E832, 0x60BFE6, 0xCDC4EF, 0x09366C, 0xD43F5D, 0xD7DE16,
    0xDE3B58, 0x929BDE, 0x2822D2, 0xE88628, 0x4D58E2, 0x32CAC6,
    0x16E308, 0xCB7DE0, 0x50C017, 0xA71DF3, 0x5BE018, 0x34132E,
    0x621283, 0x014883, 0x5B8EF5, 0x7FB0AD, 0xF2E91E, 0x434A48,
    0xD36710, 0xD8DDAA, 0x425FAE, 0xCE616A, 0xA4280A, 0xB499D3,
    0xF2A606, 0x7F775C, 0x83C2A3, 0x883C61, 0x78738A, 0x5A8CAF,
    0xBDD76F, 0x63A62D, 0xCBBFF4, 0xEF818D, 0x67C126, 0x45CA55,
    0x36D9CA, 0xD2A828, 0x8D61C2, 0x77C912, 0x142604, 0x9B4612,
    0xC459C4, 0x44C5C8, 0x91B24D, 0xF31700, 0xAD43D4, 0xE54929,
    0x10D5FD, 0xFCBE00, 0xCC941E, 0xEECE70, 0xF53E13, 0x80F1EC,
    0xC3E7B3, 0x28F8C7, 0x940593, 0x3E71C1, 0xB3092E, 0xF3450B,
    0x9C1288, 0x7B20AB, 0x9FB52E, 0xC29247, 0x2F327B, 0x6D550C,
    0x90A772, 0x1FE76B, 0x96CB31, 0x4A1679, 0xE27941, 0x89DFF4,
    0x9794E8, 0x84E6E2, 0x973199, 0x6BED88, 0x365F5F, 0x0EFDBB,
    0xB49A48, 0x6CA467, 0x427271, 0x325D8D, 0xB8159F, 0x09E5BC,
    0x25318D, 0x3974F7, 0x1C0530, 0x010C0D, 0x68084B, 0x58EE2C,
    0x90AA47, 0x02E774, 0x24D6BD, 0xA67DF7, 0x72486E, 0xEF169F,
    0xA6948E, 0xF691B4, 0x5153D1, 0xF20ACF, 0x339820, 0x7E4BF5,
    0x6863B2, 0x5F3EDD, 0x035D40, 0x7F8985, 0x295255, 0xC06437,
    0x10D86D, 0x324832, 0x754C5B, 0xD4714E, 0x6E5445, 0xC1090B,
    0x69F52A, 0xD56614, 0x9D0727, 0x50045D, 0xDB3BB4, 0xC576EA,
    0x17F987, 0x7D6B49, 0xBA271D, 0x296996, 0xACCCC6, 0x5414AD,
    0x6AE290, 0x89D988, 0x50722C, 0xBEA404, 0x940777, 0x7030F3,
    0x27FC00, 0xA871EA, 0x49C266, 0x3DE064, 0x83DD97, 0x973FA3,
    0xFD9443, 0x8C860D, 0xDE4131, 0x9D3992, 0x8C70DD, 0xE7B717,
    0x3BDF08, 0x2B3715, 0xA0805C, 0x93805A, 0x921110, 0xD8E80F,
    0xAF806C, 0x4BFFDB, 0x0F9038, 0x761859, 0x15A562, 0xBBCB61,
    0xB989C7, 0xBD4010, 0x04F2D2, 0x277549, 0xF6B6EB, 0xBB22DB,
    0xAA140A, 0x2F2689, 0x768364, 0x333B09, 0x1A940E, 0xAA3A51,
    0xC2A31D, 0xAEEDAF, 0x12265C, 0x4DC26D, 0x9C7A2D, 0x9756C0,
    0x833F03, 0xF6F009, 0x8C402B, 0x99316D, 0x07B439, 0x15200C,
    0x5BC3D8, 0xC492F5, 0x4BADC6, 0xA5CA4E, 0xCD37A7, 0x36A9E6,
    0x9492AB, 0x6842DD, 0xDE6319, 0xEF8C76, 0x528B68, 0x37DBFC,
    0xABA1AE, 0x3115DF, 0xA1AE00, 0xDAFB0C, 0x664D64, 0xB705ED,
    0x306529, 0xBF5657, 0x3AFF47, 0xB9F96A, 0xF3BE75, 0xDF9328,
    0x3080AB, 0xF68C66, 0x15CB04, 0x0622FA, 0x1DE4D9, 0xA4B33D,
    0x8F1B57, 0x09CD36, 0xE9424E, 0xA4BE13, 0xB52333, 0x1AAAF0,
    0xA8654F, 0xA5C1D2, 0x0F3F0B, 0xCD785B, 0x76F923, 0x048B7B,
    0x721789, 0x53A6C6, 0xE26E6F, 0x00EBEF, 0x584A9B, 0xB7DAC4,
    0xBA66AA, 0xCFCF76, 0x1D02D1, 0x2DF1B1, 0xC1998C, 0x77ADC3,
    0xDA4886, 0xA05DF7, 0xF480C6, 0x2FF0AC, 0x9AECDD, 0xBC5C3F,
    0x6DDED0, 0x1FC790, 0xB6DB2A, 0x3A25A3, 0x9AAF00, 0x9353AD,
    0x0457B6, 0xB42D29, 0x7E804B, 0xA707DA, 0x0EAA76, 0xA1597B,
    0x2A1216, 0x2DB7DC, 0xFDE5FA, 0xFEDB89, 0xFDBE89, 0x6C76E4,
    0xFCA906, 0x70803E, 0x156E85, 0xFF87FD, 0x073E28, 0x336761,
    0x86182A, 0xEABD4D, 0xAFE7B3, 0x6E6D8F, 0x396795, 0x5BBF31,
    0x48D784, 0x16DF30, 0x432DC7, 0x356125, 0xCE70C9, 0xB8CB30,
    0xFD6CBF, 0xA200A4, 0xE46C05, 0xA0DD5A, 0x476F21, 0xD21262,
    0x845CB9, 0x496170, 0xE0566B, 0x015299, 0x375550, 0xB7D51E,
    0xC4F133, 0x5F6E13, 0xE4305D, 0xA92E85, 0xC3B21D, 0x3632A1,
    0xA4B708, 0xD4B1EA, 0x21F716, 0xE4698F, 0x77FF27, 0x80030C,
    0x2D408D, 0xA0CD4F, 0x99A520, 0xD3A2B3, 0x0A5D2F, 0x42F9B4,
    0xCBDA11, 0xD0BE7D, 0xC1DB9B, 0xBD17AB, 0x81A2CA, 0x5C6A08,
    0x17552E, 0x550027, 0xF0147F, 0x8607E1, 0x640B14, 0x8D4196,
    0xDEBE87, 0x2AFDDA, 0xB6256B, 0x34897B, 0xFEF305, 0x9EBFB9,
    0x4F6A68, 0xA82A4A, 0x5AC44F, 0xBCF82D, 0x985AD7, 0x95C7F4,
    0x8D4D0D, 0xA63A20, 0x5F57A4, 0xB13F14, 0x953880, 0x0120CC,
    0x86DD71, 0xB6DEC9, 0xF560BF, 0x11654D, 0x6B0701, 0xACB08C,
    0xD0C0B2, 0x485551, 0x0EFB1E, 0xC37295, 0x3B06A3, 0x3540C0,
    0x7BDC06, 0xCC45E0, 0xFA294E, 0xC8CAD6, 0x41F3E8, 0xDE647C,
    0xD8649B, 0x31BED9, 0xC397A4, 0xD45877, 0xC5E369, 0x13DAF0,
    0x3C3ABA, 0x461846, 0x5F7555, 0xF5BDD2, 0xC6926E, 0x5D2EAC,
    0xED440E, 0x423E1C, 0x87C461, 0xE9FD29, 0xF3D6E7, 0xCA7C22,
    0x35916F, 0xC5E008, 0x8DD7FF, 0xE26A6E, 0xC6FDB0, 0xC10893,
    0x745D7C, 0xB2AD6B, 0x9D6ECD, 0x7B723E, 0x6A11C6, 0xA9CFF7,
    0xDF7329, 0xBAC9B5, 0x5100B7, 0x0DB2E2, 0x24BA74, 0x607DE5,
    0x8AD874, 0x2C150D, 0x0C1881, 0x94667E, 0x162901, 0x767A9F,
    0xBEFDFD, 0xEF4556, 0x367ED9, 0x13D9EC, 0xB9BA8B, 0xFC97C4,
    0x27A831, 0xC36EF1, 0x36C594, 0x56A8D8, 0xB5A8B4, 0x0ECCCF,
    0x2D8912, 0x34576F, 0x89562C, 0xE3CE99, 0xB920D6, 0xAA5E6B,
    0x9C2A3E, 0xCC5F11, 0x4A0BFD, 0xFBF4E1, 0x6D3B8E, 0x2C86E2,
    0x84D4E9, 0xA9B4FC, 0xD1EEEF, 0xC9352E, 0x61392F, 0x442138,
    0xC8D91B, 0x0AFC81, 0x6A4AFB, 0xD81C2F, 0x84B453, 0x8C994E,
    0xCC2254, 0xDC552A, 0xD6C6C0, 0x96190B, 0xB8701A, 0x649569,
    0x605A26, 0xEE523F, 0x0F117F, 0x11B5F4, 0xF5CBFC, 0x2DBC34,
    0xEEBC34, 0xCC5DE8, 0x605EDD, 0x9B8E67, 0xEF3392, 0xB817C9,
    0x9B5861, 0xBC57E1, 0xC68351, 0x103ED8, 0x4871DD, 0xDD1C2D,
    0xA118AF, 0x462C21, 0xD7F359, 0x987AD9, 0xC0549E, 0xFA864F,
    0xFC0656, 0xAE79E5, 0x362289, 0x22AD38, 0xDC9367, 0xAAE855,
    0x382682, 0x9BE7CA, 0xA40D51, 0xB13399, 0x0ED7A9, 0x480569,
    0xF0B265, 0xA7887F, 0x974C88, 0x36D1F9, 0xB39221, 0x4A827B,
    0x21CF98, 0xDC9F40, 0x5547DC, 0x3A74E1, 0x42EB67, 0xDF9DFE,
    0x5FD45E, 0xA4677B, 0x7AACBA, 0xA2F655, 0x23882B, 0x55BA41,
    0x086E59, 0x862A21, 0x834739, 0xE6E389, 0xD49EE5, 0x40FB49,
    0xE956FF, 0xCA0F1C, 0x8A59C5, 0x2BFA94, 0xC5C1D3, 0xCFC50F,
    0xAE5ADB, 0x86C547, 0x624385, 0x3B8621, 0x94792C, 0x876110,
    0x7B4C2A, 0x1A2C80, 0x12BF43, 0x902688, 0x893C78, 0xE4C4A8,
    0x7BDBE5, 0xC23AC4, 0xEAF426, 0x8A67F7, 0xBF920D, 0x2BA365,
    0xB1933D, 0x0B7CBD, 0xDC51A4, 0x63DD27, 0xDDE169, 0x19949A,
    0x9529A8, 0x28CE68, 0xB4ED09, 0x209F44, 0xCA984E, 0x638270,
    0x237C7E, 0x32B90F, 0x8EF5A7, 0xE75614, 0x08F121, 0x2A9DB5,
    0x4D7E6F, 0x5119A5, 0xABF9B5, 0xD6DF82, 0x61DD96, 0x023616,
    0x9F3AC4, 0xA1A283, 0x6DED72, 0x7A8D39, 0xA9B882, 0x5C326B,
    0x5B2746, 0xED3400, 0x7700D2, 0x55F4FC, 0x4D5901, 0x8071E0,
};

const rp_PIo2 = [_]f64{
    1.57079625129699707031e+00, // 0x3FF921FB, 0x40000000
    7.54978941586159635335e-08, // 0x3E74442D, 0x00000000
    5.39030252995776476554e-15, // 0x3CF84698, 0x80000000
    3.28200341580791294123e-22, // 0x3B78CC51, 0x60000000
    1.27065575308067607349e-29, // 0x39F01B83, 0x80000000
    1.22933308981111328932e-36, // 0x387A2520, 0x40000000
    2.73370053816464559624e-44, // 0x36E38222, 0x80000000
    2.16741683877804819444e-51, // 0x3569F31D, 0x00000000
};

/// Returns the last three digits of N with y = x - N*pi/2 so that |y| < pi/2.
///
/// The method is to compute the integer (mod 8) and fraction parts of
/// (2/pi)*x without doing the full multiplication. In general we
/// skip the part of the product that are known to be a huge integer (
/// more accurately, = 0 mod 8 ). Thus the number of operations are
/// independent of the exponent of the input.
///
/// (2/pi) is represented by an array of 24-bit integers in rp_ipio2[].
///
/// Input parameters:
///      x[]     The input value (must be positive) is broken into nx
///              pieces of 24-bit integers in double precision format.
///              x[i] will be the i-th 24 bit of x. The scaled exponent
///              of x[0] is given in input parameter e0 (i.e., x[0]*2^e0
///              match x's up to 24 bits.
///
///              Example of breaking a double positive z into x[0]+x[1]+x[2]:
///                      e0 = ilogb(z)-23
///                      z  = scalbn(z,-e0)
///              for i = 0,1,2
///                      x[i] = floor(z)
///                      z    = (z-x[i])*2**24
///
///
///      y[]     output result in an array of double precision numbers.
///              The dimension of y[] is:
///                      24-bit  precision       1
///                      53-bit  precision       2
///                      64-bit  precision       2
///                      113-bit precision       3
///              The actual value is the sum of them. Thus for 113-bit
///              precision, one may have to do something like:
///
///              long double t,w,r_head, r_tail;
///              t = (long double)y[2] + (long double)y[1];
///              w = (long double)y[0];
///              r_head = t+w;
///              r_tail = w - (r_head - t);
///
///      e0      The exponent of x[0]. Must be <= 16360 or you need to
///              expand the rp_ipio2 table.
///
///      nx      dimension of x[]
///
///      prec    an integer indicating the precision:
///                      0       24  bits (single)
///                      1       53  bits (double)
///                      2       64  bits (extended)
///                      3       113 bits (quad)
///
/// Here is the description of some local variables:
///
///      jk      jk+1 is the initial number of terms of rp_ipio2[] needed
///              in the computation. The minimum and recommended value
///              for jk is 3,4,4,6 for single, double, extended, and quad.
///              jk+1 must be 2 larger than you might expect so that our
///              recomputation test works. (Up to 24 bits in the integer
///              part (the 24 bits of it that we compute) and 23 bits in
///              the fraction part may be lost to cancelation before we
///              recompute.)
///
///      jz      local integer variable indicating the number of
///              terms of rp_ipio2[] used.
///
///      jx      nx - 1
///
///      jv      index for pointing to the suitable rp_ipio2[] for the
///              computation. In general, we want
///                      ( 2^e0*x[0] * rp_ipio2[jv-1]*2^(-24jv) )/8
///              is an integer. Thus
///                      e0-3-24*jv >= 0 or (e0-3)/24 >= jv
///              Hence jv = max(0,(e0-3)/24).
///
///      jp      jp+1 is the number of terms in rp_PIo2[] needed, jp = jk.
///
///      q[]     double array with integral value, representing the
///              24-bits chunk of the product of x and 2/pi.
///
///      q0      the corresponding exponent of q[0]. Note that the
///              exponent for q[i] would be q0-24*i.
///
///      rp_PIo2[]  double precision array, obtained by cutting pi/2
///              into 24 bits chunks.
///
///      f[]     rp_ipio2[] in floating point
///
///      iq[]    integer array by breaking up q[] in 24-bits chunk.
///
///      fq[]    final product of x*(2/pi) in fq[0],..,fq[jk]
///
///      ih      integer. If >0 it indicates q[] is >= 0.5, hence
///              it also indicates the *sign* of the result.
///
///
///
/// Constants:
/// The hexadecimal values are the intended ones for the following
/// constants. The decimal values may be used, provided that the
/// compiler will convert from decimal to binary accurately enough
/// to produce the hexadecimal values shown.
///
fn remPio2Large(x: []const f64, y: []f64, e0: i32, nx: i32, prec: usize) i32 {
    var jz: i32 = undefined;
    var jx: i32 = undefined;
    var jv: i32 = undefined;
    var jp: i32 = undefined;
    var jk: i32 = undefined;
    var carry: i32 = undefined;
    var n: i32 = undefined;
    var iq: [20]i32 = undefined;
    var i: i32 = undefined;
    var j: i32 = undefined;
    var k: i32 = undefined;
    var m: i32 = undefined;
    var q0: i32 = undefined;
    var ih: i32 = undefined;

    var z: f64 = undefined;
    var fw: f64 = undefined;
    var f: [20]f64 = undefined;
    var fq: [20]f64 = undefined;
    var q: [20]f64 = undefined;

    // initialize jk
    jk = rp_init_jk[prec];
    jp = jk;

    // determine jx,jv,q0, note that 3>q0
    jx = nx - 1;
    jv = @divFloor(e0 - 3, 24);
    if (jv < 0) jv = 0;
    q0 = e0 - 24 * (jv + 1);

    // set up f[0] to f[jx+jk] where f[jx+jk] = rp_ipio2[jv+jk]
    j = jv - jx;
    m = jx + jk;
    i = 0;
    while (i <= m) : ({
        i += 1;
        j += 1;
    }) {
        f[@intCast(i)] = if (j < 0) 0.0 else @floatFromInt(rp_ipio2[@intCast(j)]);
    }

    // compute q[0],q[1],...q[jk]
    i = 0;
    while (i <= jk) : (i += 1) {
        j = 0;
        fw = 0;
        while (j <= jx) : (j += 1) {
            fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
        }
        q[@intCast(i)] = fw;
    }

    jz = jk;

    // This is to handle a non-trivial goto translation from C.
    // An unconditional return statement is found at the end of this loop.
    recompute: while (true) {
        // distill q[] into iq[] reversingly
        i = 0;
        j = jz;
        z = q[@intCast(jz)];
        while (j > 0) : ({
            i += 1;
            j -= 1;
        }) {
            fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
            iq[@intCast(i)] = @intFromFloat(z - 0x1p24 * fw);
            z = q[@intCast(j - 1)] + fw;
        }

        // compute n
        z = std.math.scalbn(z, q0); // actual value of z
        z -= 8.0 * @floor(z * 0.125); // trim off integer >= 8
        n = @intFromFloat(z);
        z -= @floatFromInt(n);
        ih = 0;
        if (q0 > 0) { // need iq[jz-1] to determine n
            i = iq[@intCast(jz - 1)] >> @intCast(24 - q0);
            n += i;
            iq[@intCast(jz - 1)] -= i << @intCast(24 - q0);
            ih = iq[@intCast(jz - 1)] >> @intCast(23 - q0);
        } else if (q0 == 0) {
            ih = iq[@intCast(jz - 1)] >> 23;
        } else if (z >= 0.5) {
            ih = 2;
        }

        if (ih > 0) { // q > 0.5
            n += 1;
            carry = 0;
            i = 0;
            while (i < jz) : (i += 1) { // compute 1-q
                j = iq[@intCast(i)];
                if (carry == 0) {
                    if (j != 0) {
                        carry = 1;
                        iq[@intCast(i)] = 0x1000000 - j;
                    }
                } else {
                    iq[@intCast(i)] = 0xffffff - j;
                }
            }
            if (q0 > 0) { // rare case: chance is 1 in 12
                @branchHint(.unlikely);
                switch (q0) {
                    1 => iq[@intCast(jz - 1)] &= 0x7fffff,
                    2 => iq[@intCast(jz - 1)] &= 0x3fffff,
                    else => unreachable,
                }
            }
            if (ih == 2) {
                z = 1.0 - z;
                if (carry != 0) {
                    z -= std.math.scalbn(@as(f64, 1.0), q0);
                }
            }
        }

        // check if recomputation is needed
        if (z == 0.0) {
            j = 0;
            i = jz - 1;
            while (i >= jk) : (i -= 1) {
                j |= iq[@intCast(i)];
            }

            if (j == 0) { // need recomputation
                k = 1;
                while (iq[@intCast(jk - k)] == 0) : (k += 1) {
                    // k = no. of terms needed
                }

                i = jz + 1;
                while (i <= jz + k) : (i += 1) { // add q[jz+1] to q[jz+k]
                    f[@intCast(jx + i)] = @floatFromInt(rp_ipio2[@intCast(jv + i)]);
                    j = 0;
                    fw = 0;
                    while (j <= jx) : (j += 1) {
                        fw += x[@intCast(j)] * f[@intCast(jx + i - j)];
                    }
                    q[@intCast(i)] = fw;
                }
                jz += k;
                continue :recompute; // mimic goto recompute
            }
        }

        // chop off zero terms
        if (z == 0.0) {
            jz -= 1;
            q0 -= 24;
            while (iq[@intCast(jz)] == 0) {
                jz -= 1;
                q0 -= 24;
            }
        } else { // break z into 24-bit if necessary
            z = std.math.scalbn(z, -q0);
            if (z >= 0x1p24) {
                fw = @floatFromInt(@as(i32, @intFromFloat(0x1p-24 * z)));
                iq[@intCast(jz)] = @intFromFloat(z - 0x1p24 * fw);
                jz += 1;
                q0 += 24;
                iq[@intCast(jz)] = @intFromFloat(fw);
            } else {
                iq[@intCast(jz)] = @intFromFloat(z);
            }
        }

        // convert integer "bit" chunk to floating-point value
        fw = std.math.scalbn(@as(f64, 1.0), q0);
        i = jz;
        while (i >= 0) : (i -= 1) {
            q[@intCast(i)] = fw * @as(f64, @floatFromInt(iq[@intCast(i)]));
            fw *= 0x1p-24;
        }

        // compute rp_PIo2[0,...,jp]*q[jz,...,0]
        i = jz;
        while (i >= 0) : (i -= 1) {
            fw = 0;
            k = 0;
            while (k <= jp and k <= jz - i) : (k += 1) {
                fw += rp_PIo2[@intCast(k)] * q[@intCast(i + k)];
            }
            fq[@intCast(jz - i)] = fw;
        }

        // compress fq[] into y[]
        switch (prec) {
            0 => {
                fw = 0.0;
                i = jz;
                while (i >= 0) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                y[0] = if (ih == 0) fw else -fw;
            },

            1, 2 => {
                fw = 0.0;
                i = jz;
                while (i >= 0) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                // TODO: drop excess precision here once double_t is used
                fw = fw;
                y[0] = if (ih == 0) fw else -fw;
                fw = fq[0] - fw;
                i = 1;
                while (i <= jz) : (i += 1) {
                    fw += fq[@intCast(i)];
                }
                y[1] = if (ih == 0) fw else -fw;
            },
            3 => { // painful
                i = jz;
                while (i > 0) : (i -= 1) {
                    fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                    fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                    fq[@intCast(i - 1)] = fw;
                }
                i = jz;
                while (i > 1) : (i -= 1) {
                    fw = fq[@intCast(i - 1)] + fq[@intCast(i)];
                    fq[@intCast(i)] += fq[@intCast(i - 1)] - fw;
                    fq[@intCast(i - 1)] = fw;
                }
                fw = 0;
                i = jz;
                while (i >= 2) : (i -= 1) {
                    fw += fq[@intCast(i)];
                }
                if (ih == 0) {
                    y[0] = fq[0];
                    y[1] = fq[1];
                    y[2] = fw;
                } else {
                    y[0] = -fq[0];
                    y[1] = -fq[1];
                    y[2] = -fw;
                }
            },
            else => unreachable,
        }

        return n & 7;
    }
}

/// Sine (musl sin.c).
pub fn sin(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e500000) { // |x| < 2**-26
            return x;
        }
        return ksin(x, 0.0, 0);
    }

    // sin(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => ksin(y[0], y[1], 1),
        1 => kcos(y[0], y[1]),
        2 => -ksin(y[0], y[1], 1),
        else => -kcos(y[0], y[1]),
    };
}

/// Cosine (musl cos.c).
pub fn cos(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e46a09e) { // |x| < 2**-27 * sqrt(2)
            return 1.0;
        }
        return kcos(x, 0);
    }

    // cos(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => kcos(y[0], y[1]),
        1 => -ksin(y[0], y[1], 1),
        2 => -kcos(y[0], y[1]),
        else => ksin(y[0], y[1], 1),
    };
}

/// Tangent (musl tan.c).
pub fn tan(x: f64) f64 {
    var ix = @as(u64, @bitCast(x)) >> 32;
    ix &= 0x7fffffff;

    // |x| ~< pi/4
    if (ix <= 0x3fe921fb) {
        if (ix < 0x3e400000) { // |x| < 2**-27
            return x;
        }
        return ktan(x, 0.0, false);
    }

    // tan(Inf or NaN) is NaN
    if (ix >= 0x7ff00000) {
        return x - x;
    }

    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return ktan(y[0], y[1], n & 1 != 0);
}

// ---------------------------------------------------------------- log10, log2
//
// musl's (FreeBSD's) log10.c and the FreeBSD log2 (e_log2.c), as Zig's
// compiler-rt ports them (lib/compiler_rt/{log10,log2}.zig, Zig 0.17).
// musl 1.2's log2.c is Arm's table-driven one, which rounds differently
// in a few last bits.

/// Base-10 logarithm.
pub fn log10(x_: f64) f64 {
    const ivln10hi: f64 = 4.34294481878168880939e-01;
    const ivln10lo: f64 = 2.50829467116452752298e-11;
    const log10_2hi: f64 = 3.01029995663611771306e-01;
    const log10_2lo: f64 = 3.69423907715893078616e-13;
    const Lg1: f64 = 6.666666666666735130e-01;
    const Lg2: f64 = 3.999999999940941908e-01;
    const Lg3: f64 = 2.857142874366239149e-01;
    const Lg4: f64 = 2.222219843214978396e-01;
    const Lg5: f64 = 1.818357216161805012e-01;
    const Lg6: f64 = 1.531383769920937332e-01;
    const Lg7: f64 = 1.479819860511658591e-01;

    var x = x_;
    var ix: u64 = @bitCast(x);
    var hx: u32 = @intCast(ix >> 32);
    var k: i32 = 0;

    if (hx < 0x00100000 or hx >> 31 != 0) {
        // log(+-0) = -inf
        if (ix << 1 == 0) {
            return -inf;
        }
        // log(-#) = nan
        if (hx >> 31 != 0) {
            return std.math.nan(f64);
        }

        // subnormal, scale x
        k -= 54;
        x *= 0x1.0p54;
        // musl takes the low word of the scaled x too (compiler-rt keeps
        // the subnormal's, a wrong result).
        ix = @bitCast(x);
        hx = @intCast(ix >> 32);
    } else if (hx >= 0x7FF00000) {
        return x;
    } else if (hx == 0x3FF00000 and ix << 32 == 0) {
        return 0;
    }

    // x into [sqrt(2) / 2, sqrt(2)]
    hx += 0x3FF00000 - 0x3FE6A09E;
    k += @as(i32, @intCast(hx >> 20)) - 0x3FF;
    hx = (hx & 0x000FFFFF) + 0x3FE6A09E;
    ix = (@as(u64, hx) << 32) | (ix & 0xFFFFFFFF);
    x = @bitCast(ix);

    const f = x - 1.0;
    const hfsq = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;

    // hi + lo = f - hfsq + s * (hfsq + R) ~ log(1 + f)
    var hi = f - hfsq;
    var hii: u64 = @bitCast(hi);
    hii &= @as(u64, std.math.maxInt(u64)) << 32;
    hi = @bitCast(hii);
    const lo = f - hi - hfsq + s * (hfsq + R);

    // val_hi + val_lo ~ log10(1 + f) + k * log10(2)
    var val_hi = hi * ivln10hi;
    const dk: f64 = @floatFromInt(k);
    const y = dk * log10_2hi;
    var val_lo = dk * log10_2lo + (lo + hi) * ivln10lo + lo * ivln10hi;

    // Extra precision multiplication
    const ww = y + val_hi;
    val_lo += (y - ww) + val_hi;
    val_hi = ww;

    return val_lo + val_hi;
}

/// Base-2 logarithm.
pub fn log2(x_: f64) f64 {
    const ivln2hi: f64 = 1.44269504072144627571e+00;
    const ivln2lo: f64 = 1.67517131648865118353e-10;
    const Lg1: f64 = 6.666666666666735130e-01;
    const Lg2: f64 = 3.999999999940941908e-01;
    const Lg3: f64 = 2.857142874366239149e-01;
    const Lg4: f64 = 2.222219843214978396e-01;
    const Lg5: f64 = 1.818357216161805012e-01;
    const Lg6: f64 = 1.531383769920937332e-01;
    const Lg7: f64 = 1.479819860511658591e-01;

    var x = x_;
    var ix: u64 = @bitCast(x);
    var hx: u32 = @intCast(ix >> 32);
    var k: i32 = 0;

    if (hx < 0x00100000 or hx >> 31 != 0) {
        // log(+-0) = -inf
        if (ix << 1 == 0) {
            return -inf;
        }
        // log(-#) = nan
        if (hx >> 31 != 0) {
            return std.math.nan(f64);
        }

        // subnormal, scale x
        k -= 54;
        x *= 0x1.0p54;
        // As log10.
        ix = @bitCast(x);
        hx = @intCast(ix >> 32);
    } else if (hx >= 0x7FF00000) {
        return x;
    } else if (hx == 0x3FF00000 and ix << 32 == 0) {
        return 0;
    }

    // x into [sqrt(2) / 2, sqrt(2)]
    hx += 0x3FF00000 - 0x3FE6A09E;
    k += @as(i32, @intCast(hx >> 20)) - 0x3FF;
    hx = (hx & 0x000FFFFF) + 0x3FE6A09E;
    ix = (@as(u64, hx) << 32) | (ix & 0xFFFFFFFF);
    x = @bitCast(ix);

    const f = x - 1.0;
    const hfsq = 0.5 * f * f;
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;

    // hi + lo = f - hfsq + s * (hfsq + R) ~ log(1 + f)
    var hi = f - hfsq;
    var hii = @as(u64, @bitCast(hi));
    hii &= @as(u64, std.math.maxInt(u64)) << 32;
    hi = @bitCast(hii);
    const lo = f - hi - hfsq + s * (hfsq + R);

    var val_hi = hi * ivln2hi;
    var val_lo = (lo + hi) * ivln2lo + lo * ivln2hi;

    // spadd(val_hi, val_lo, y)
    const y: f64 = @floatFromInt(k);
    const ww = y + val_hi;
    val_lo += (y - ww) + val_hi;
    val_hi = ww;

    return val_lo + val_hi;
}

// ---------------------------------------------------------------- tests

/// Expected bits, from PostgreSQL 18 on musl (Alpine, aarch64).
fn expectBits(expected: u64, actual: f64) !void {
    try std.testing.expectEqual(expected, @as(u64, @bitCast(actual)));
}

test "libm: exp, log, pow match musl" {
    try expectBits(0x3ffa61298e1e069c, exp(0.5));
    try expectBits(0x0000000000000055, exp(-740)); // subnormal result
    try expectBits(0x40026bb1bbb55516, log(10));
    try expectBits(0x4012fdcf53f3e6f3, pow(2.5, 1.7));
    try expectBits(0xc06e600000000000, pow(-3, 5));
    try std.testing.expect(std.math.isPositiveInf(exp(710)));
    try std.testing.expect(std.math.isNegativeInf(log(0)));
    try std.testing.expect(std.math.isNan(log(-1)));
    try std.testing.expectEqual(@as(f64, 1), pow(std.math.nan(f64), 0));
}

test "libm: hyperbolic functions match musl" {
    try expectBits(0x3ff8b07551d9f550, cosh(1));
    try expectBits(0x3fd37d42af54b926, sinh(0.3));
    try expectBits(0x3fd8511573c242d6, tanh(0.4));
    try expectBits(0x3ffa5b0f0be9dcf6, asinh(2.5));
    try expectBits(0x3feecc2caec5160a, acosh(1.5));
    try expectBits(0x3fd3cf2b50617c96, atanh(0.3));
}

test "libm: tgamma and lgamma match musl" {
    try expectBits(0x7fa4ab7864418638, tgamma(171));
    try expectBits(0x4002e7fb0bcdf4f0, tgamma(-1.5));
    try expectBits(0x40274371e7866c65, tgamma(4.5));
    try expectBits(0x40299a8921a7f7d0, lgamma(10));
    try expectBits(0x3fe250d048e7a1bd, lgamma(0.5));
    try expectBits(0x3feb858151820f85, lgamma(-1.5));
    try expectBits(0x7ed017f38e7a1ab5, lgamma(1e300));
    try std.testing.expect(std.math.isPositiveInf(lgamma(-2)));
}

test "libm: expm1 and log1p" {
    try std.testing.expectEqual(@as(f64, 0), expm1(0));
    try std.testing.expectEqual(@as(f64, -1), expm1(-1000));
    try std.testing.expectEqual(@as(f64, 1e-300), log1p(1e-300));
    try std.testing.expect(std.math.isNegativeInf(log1p(-1)));
}

test "libm: erf" {
    try std.testing.expectEqual(@as(f64, 0.5204998778130465), erf(0.5));
}
