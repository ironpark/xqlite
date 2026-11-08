//! PostgreSQL's functions of double precision beyond funcs.zig's (float.c),
//! with its errors, and its pseudo-random numbers (pseudorandomfuncs.c):
//!
//!  - sin, cos, tan, cot, asin, acos, atan, atan2; sind, cosd, tand,
//!    cotd, asind, acosd, atand, atan2d (exact at the special angles:
//!    sind(30) is 0.5), sinh, cosh, tanh, asinh, acosh, atanh, cbrt,
//!    degrees, radians, erf, erfc, gamma, lgamma: "input is out of
//!    range", "value out of range: overflow" / "underflow" (22003) as
//!    PostgreSQL;
//!  - round(x) of a double: rint(), half to even;
//!  - random(), random(min, max) of integers and of numerics,
//!    random_normal([mean [, stddev]]), setseed(s): PostgreSQL's PRNG
//!    (xoroshiro128**, pg_prng.c) per session (state.zig's prng), seeded
//!    from the connection's randomness until setseed() seeds it, so that
//!    a seed gives PostgreSQL's numbers.
//!
//! The functions of exp(), log() and pow(), erf() and erfc() are
//! ../libm.zig's ports of musl's (PostgreSQL's alpine builds call musl's:
//! the same digits on every platform); the trigonometric ones Zig's
//! (musl's FreeBSD code);
//! PostgreSQL's own arithmetic is fused where GCC fuses it on arm64
//! (stats.zig).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const dec = @import("decimal");
const decimal_sql = @import("../decimal_sql.zig");
const stats = @import("../stats.zig");
const libm = @import("../libm.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;
const math = std.math;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    unary("sin", sinF),
    unary("cos", cosF),
    unary("tan", tanF),
    unary("cot", cotF),
    unary("asin", asinF),
    unary("acos", acosF),
    unary("atan", atanF),
    binary("atan2", atan2F),
    unary("sind", sindF),
    unary("cosd", cosdF),
    unary("tand", tandF),
    unary("cotd", cotdF),
    unary("asind", asindF),
    unary("acosd", acosdF),
    unary("atand", atandF),
    binary("atan2d", atan2dF),
    unary("sinh", sinhF),
    unary("cosh", coshF),
    unary("tanh", tanhF),
    unary("asinh", asinhF),
    unary("acosh", acoshF),
    unary("atanh", atanhF),
    unary("cbrt", cbrtF),
    unary("degrees", degreesF),
    unary("radians", radiansF),
    unary("erf", erfF),
    unary("erfc", erfcF),
    unary("gamma", gammaF),
    unary("lgamma", lgammaF),
    dfunc.scalar("round", 1, det, roundFunc),
    // round(x, n): numeric's (an integer or a double made a numeric).
    dfunc.scalar("round", 2, det, round2Func),
    dfunc.scalar("random_normal", 0, .{}, randomNormalFunc),
    dfunc.scalar("random_normal", 1, .{}, randomNormalFunc),
    dfunc.scalar("random_normal", 2, .{}, randomNormalFunc),
    dfunc.scalar("setseed", 1, .{}, setseedFunc),
};

/// The math error of a function of doubles.
const Fail = error{ OutOfRange, Overflow, Underflow };

fn report(ctx: *Context, err: Fail) void {
    api.resultErrorState(ctx, .of("22003"), switch (err) {
        error.OutOfRange => "input is out of range",
        error.Overflow => "value out of range: overflow",
        error.Underflow => "value out of range: underflow",
    });
}

pub fn unary(comptime name: [:0]const u8, comptime f: fn (f64) Fail!f64) int.FuncDef {
    return dfunc.scalar(name, 1, det, struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            const r = f(api.valueDouble(argv[0])) catch |err| return report(ctx, err);
            api.resultDouble(ctx, r);
        }
    }.call);
}

fn binary(comptime name: [:0]const u8, comptime f: fn (f64, f64) Fail!f64) int.FuncDef {
    return dfunc.scalar(name, 2, det, struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (anyNull(argv)) return api.resultNull(ctx);
            const r = f(api.valueDouble(argv[0]), api.valueDouble(argv[1])) catch |err| return report(ctx, err);
            api.resultDouble(ctx, r);
        }
    }.call);
}

const nan = math.nan(f64);
const isNan = math.isNan;
const isInf = math.isInf;

fn noInf(r: f64) Fail!f64 {
    if (isInf(r)) return error.Overflow;
    return r;
}

/// dexp(): musl's exp() (../libm.zig), its overflow and underflow
/// errors (funcs.zig registers it).
pub fn expF(x: f64) Fail!f64 {
    if (isInf(x)) return if (x > 0) x else 0;
    const r = libm.exp(x);
    if (isInf(r)) return error.Overflow;
    if (r == 0) return error.Underflow;
    return r;
}

// ======================================================== trigonometry

fn sinF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (isInf(x)) return error.OutOfRange;
    return noInf(@sin(x));
}

fn cosF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (isInf(x)) return error.OutOfRange;
    return noInf(@cos(x));
}

fn tanF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (isInf(x)) return error.OutOfRange;
    return @tan(x);
}

fn cotF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (isInf(x)) return error.OutOfRange;
    return 1.0 / @tan(x);
}

fn asinF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (x < -1.0 or x > 1.0) return error.OutOfRange;
    return noInf(math.asin(x));
}

fn acosF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    if (x < -1.0 or x > 1.0) return error.OutOfRange;
    return noInf(math.acos(x));
}

fn atanF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    return noInf(math.atan(x));
}

fn atan2F(y: f64, x: f64) Fail!f64 {
    if (isNan(y) or isNan(x)) return nan;
    return noInf(math.atan2(y, x));
}

// ============================================================= degrees

const radians_per_degree: f64 = 0.0174532925199432957692;

/// A constant read at run time, so that the degree constants are
/// computed by the functions at run time as PostgreSQL's are (not folded
/// by the compiler with other digits).
fn rt(comptime v: f64) f64 {
    var x: f64 = v;
    return @as(*volatile f64, &x).*;
}

/// init_degree_constants().
const Consts = struct {
    sin_30: f64,
    one_minus_cos_60: f64,
    asin_0_5: f64,
    acos_0_5: f64,
    atan_1_0: f64,
};

fn consts() Consts {
    return .{
        .sin_30 = @sin(rt(30.0) * radians_per_degree),
        .one_minus_cos_60 = 1.0 - @cos(rt(60.0) * radians_per_degree),
        .asin_0_5 = math.asin(rt(0.5)),
        .acos_0_5 = math.acos(rt(0.5)),
        .atan_1_0 = math.atan(rt(1.0)),
    };
}

fn tan45(k: Consts) f64 {
    return sindQ1(k, rt(45.0)) / cosdQ1(k, rt(45.0));
}

fn cot45(k: Consts) f64 {
    return cosdQ1(k, rt(45.0)) / sindQ1(k, rt(45.0));
}

fn asindQ1(k: Consts, x: f64) f64 {
    if (x <= 0.5) return (math.asin(x) / k.asin_0_5) * 30.0;
    return @mulAdd(f64, -(math.acos(x) / k.acos_0_5), 60.0, 90.0);
}

fn acosdQ1(k: Consts, x: f64) f64 {
    if (x <= 0.5) return @mulAdd(f64, -(math.asin(x) / k.asin_0_5), 30.0, 90.0);
    return (math.acos(x) / k.acos_0_5) * 60.0;
}

fn sind0To30(k: Consts, x: f64) f64 {
    const s = @sin(x * radians_per_degree);
    return (s / k.sin_30) / 2.0;
}

fn cosd0To60(k: Consts, x: f64) f64 {
    const one_minus = 1.0 - @cos(x * radians_per_degree);
    return 1.0 - (one_minus / k.one_minus_cos_60) / 2.0;
}

fn sindQ1(k: Consts, x: f64) f64 {
    if (x <= 30.0) return sind0To30(k, x);
    return cosd0To60(k, 90.0 - x);
}

fn cosdQ1(k: Consts, x: f64) f64 {
    if (x <= 60.0) return cosd0To60(k, x);
    return sind0To30(k, 90.0 - x);
}

fn acosdF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    const k = consts();
    if (x < -1.0 or x > 1.0) return error.OutOfRange;
    return noInf(if (x >= 0.0) acosdQ1(k, x) else 90.0 + asindQ1(k, -x));
}

fn asindF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    const k = consts();
    if (x < -1.0 or x > 1.0) return error.OutOfRange;
    return noInf(if (x >= 0.0) asindQ1(k, x) else -asindQ1(k, -x));
}

fn atandF(x: f64) Fail!f64 {
    if (isNan(x)) return nan;
    const k = consts();
    return noInf((math.atan(x) / k.atan_1_0) * 45.0);
}

fn atan2dF(y: f64, x: f64) Fail!f64 {
    if (isNan(y) or isNan(x)) return nan;
    const k = consts();
    return noInf((math.atan2(y, x) / k.atan_1_0) * 45.0);
}

/// The angle reduced to [0, 90] and the sign of the function there, as
/// dsind() ... reduce it (`flip`: the sign changes past 90 degrees, as
/// for cos, tan and cot).
fn reduce(x0: f64, comptime neg_flips: bool, comptime flip90: bool) struct { f64, f64 } {
    var x = @rem(x0, 360.0);
    var sign: f64 = 1;
    if (x < 0.0) {
        x = -x;
        if (neg_flips) sign = -sign;
    }
    if (x > 180.0) {
        x = 360.0 - x;
        if (neg_flips) sign = -sign;
    }
    if (x > 90.0) {
        x = 180.0 - x;
        if (flip90) sign = -sign;
    }
    return .{ x, sign };
}

fn sindF(x0: f64) Fail!f64 {
    if (isNan(x0)) return nan;
    if (isInf(x0)) return error.OutOfRange;
    const k = consts();
    const x, const sign = reduce(x0, true, false);
    return noInf(sign * sindQ1(k, x));
}

fn cosdF(x0: f64) Fail!f64 {
    if (isNan(x0)) return nan;
    if (isInf(x0)) return error.OutOfRange;
    const k = consts();
    const x, const sign = reduce(x0, false, true);
    return noInf(sign * cosdQ1(k, x));
}

fn tandF(x0: f64) Fail!f64 {
    if (isNan(x0)) return nan;
    if (isInf(x0)) return error.OutOfRange;
    const k = consts();
    const x, const sign = reduce(x0, true, true);
    const t = sindQ1(k, x) / cosdQ1(k, x);
    const r = sign * (t / tan45(k));
    return if (r == 0.0) 0.0 else r;
}

fn cotdF(x0: f64) Fail!f64 {
    if (isNan(x0)) return nan;
    if (isInf(x0)) return error.OutOfRange;
    const k = consts();
    const x, const sign = reduce(x0, true, true);
    const t = cosdQ1(k, x) / sindQ1(k, x);
    const r = sign * (t / cot45(k));
    return if (r == 0.0) 0.0 else r;
}

fn degreesF(x: f64) Fail!f64 {
    const r = x / radians_per_degree;
    if (isInf(r) and !isInf(x)) return error.Overflow;
    if (r == 0.0 and x != 0.0) return error.Underflow;
    return r;
}

fn radiansF(x: f64) Fail!f64 {
    const r = x * radians_per_degree;
    if (isInf(r) and !isInf(x)) return error.Overflow;
    if (r == 0.0 and x != 0.0) return error.Underflow;
    return r;
}

// ========================================================== hyperbolic

fn sinhF(x: f64) Fail!f64 {
    return libm.sinh(x);
}

fn coshF(x: f64) Fail!f64 {
    const r = libm.cosh(x);
    if (r == 0.0) return error.Underflow;
    return r;
}

fn tanhF(x: f64) Fail!f64 {
    return noInf(libm.tanh(x));
}

fn asinhF(x: f64) Fail!f64 {
    return libm.asinh(x);
}

fn acoshF(x: f64) Fail!f64 {
    if (x < 1.0) return error.OutOfRange;
    return libm.acosh(x);
}

fn atanhF(x: f64) Fail!f64 {
    if (x < -1.0 or x > 1.0) return error.OutOfRange;
    if (x == -1.0) return -math.inf(f64);
    if (x == 1.0) return math.inf(f64);
    return libm.atanh(x);
}

// =============================================================== other

fn cbrtF(x: f64) Fail!f64 {
    const r = math.cbrt(x);
    if (isInf(r) and !isInf(x)) return error.Overflow;
    if (r == 0.0 and x != 0.0) return error.Underflow;
    return r;
}

fn erfF(x: f64) Fail!f64 {
    return noInf(libm.erf(x));
}

fn erfcF(x: f64) Fail!f64 {
    return noInf(libm.erfc(x));
}

fn gammaF(x: f64) Fail!f64 {
    if (isNan(x)) return x;
    if (isInf(x)) {
        if (x < 0) return error.Overflow;
        return x;
    }
    const r = libm.tgamma(x);
    if (isInf(r) or isNan(r)) return if (r != 0.0) error.Overflow else error.Underflow;
    if (r == 0.0) return error.Underflow;
    return r;
}

fn lgammaF(x: f64) Fail!f64 {
    const r = libm.lgamma(x);
    if (isInf(r) and !isInf(x)) return error.Overflow;
    return r;
}

/// round(x) of a double: rint(), half to even (round(2.5) is 2); an
/// integer as it is (numerics: decimal_sql.zig's xq_dec_round()).
fn roundFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_INTEGER) return api.resultDouble(ctx, @floatFromInt(api.valueInt64(argv[0])));
    api.resultDouble(ctx, @import("datetime").interval.rint(api.valueDouble(argv[0])));
}

/// round(x, n): numeric's of an integer (numerics are xq_dec_round()'s
/// already); PostgreSQL has none of a double.
fn round2Func(ctx: *Context, argv: []*Mem) void {
    if (api.valueType(argv[0]) == vi.SQLITE_FLOAT) {
        return api.resultErrorFields(ctx, .of("42883"), .{ .message = "function round(double precision, integer) does not exist", .hint = @import("frontend.zig").function_hint });
    }
    decimal_sql.def("xq_dec_round", 2).x_sfunc.?(ctx, argv);
}

// ================================================================ PRNG

/// pg_prng.c's xoroshiro128**.
const Prng = struct {
    s: *[2]u64,

    fn next(r: Prng) u64 {
        const s0 = r.s[0];
        const sx = r.s[1] ^ s0;
        const val = math.rotl(u64, s0 *% 5, 7) *% 9;
        r.s[0] = math.rotl(u64, s0, 24) ^ sx ^ (sx << 16);
        r.s[1] = math.rotl(u64, sx, 37);
        return val;
    }

    /// pg_prng_uint64_range().
    pub fn range(r: Prng, lo: u64, hi: u64) u64 {
        if (hi <= lo) return lo;
        const span = hi - lo;
        const rshift: u6 = @intCast(@clz(span));
        while (true) {
            const v = r.next() >> rshift;
            if (v <= span) return lo + v;
        }
    }

    /// pg_prng_int64_range().
    fn int64Range(r: Prng, lo: i64, hi: i64) i64 {
        if (hi <= lo) return lo;
        const u = @as(u64, @bitCast(lo)) +% r.range(0, @as(u64, @bitCast(hi)) -% @as(u64, @bitCast(lo)));
        return @bitCast(u);
    }

    /// pg_prng_double(): 52 bits.
    fn double(r: Prng) f64 {
        const v = r.next();
        return math.ldexp(@as(f64, @floatFromInt(v >> 12)), -52);
    }
};

fn seed(s: *[2]u64, seed0: u64) void {
    var x: std.Random.SplitMix64 = .init(seed0);
    s[0] = x.next();
    s[1] = x.next();
    if (s[0] == 0 and s[1] == 0) s.* = .{ 0x5851F42D4C957F2D, 0x14057B7EF767814F };
}

/// The session's PRNG, seeded from the connection's randomness the first
/// time.
fn prng(ctx: *Context) Prng {
    const db = api.contextDbHandle(ctx);
    const st = &db.xq.postgres;
    if (st.prng == null) {
        var buf: [8]u8 = undefined;
        @import("../../sql/func/func.zig").randomness(db, &buf);
        var s: [2]u64 = undefined;
        seed(&s, std.mem.readInt(u64, &buf, .little));
        st.prng = s;
    }
    return .{ .s = &st.prng.? };
}

/// random(): [0, 1).
pub fn randomFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 2) return randomRange(ctx, argv);
    api.resultDouble(ctx, prng(ctx).double());
}

fn boundsError(ctx: *Context) void {
    api.resultErrorState(ctx, .of("22023"), "lower bound must be less than or equal to upper bound");
}

/// random(min, max): of integers an integer, else a numeric (random_var()).
fn randomRange(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_INTEGER and api.valueType(argv[1]) == vi.SQLITE_INTEGER) {
        const lo = api.valueInt64(argv[0]);
        const hi = api.valueInt64(argv[1]);
        if (lo > hi) return boundsError(ctx);
        return api.resultInt64(ctx, prng(ctx).int64Range(lo, hi));
    }
    var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const lo = decimal_sql.numArg(ctx, a, argv[0]) orelse return;
    const hi = decimal_sql.numArg(ctx, a, argv[1]) orelse return;
    const bad: ?[]const u8 = if (lo.kind == .nan)
        "lower bound cannot be NaN"
    else if (lo.kind != .finite)
        "lower bound cannot be infinity"
    else if (hi.kind == .nan)
        "upper bound cannot be NaN"
    else if (hi.kind != .finite)
        "upper bound cannot be infinity"
    else
        null;
    if (bad) |m| return api.resultErrorState(ctx, .of("22023"), m);
    const r = dec.math.random(a, lo, hi, prng(ctx)) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Invalid => return boundsError(ctx),
        else => return api.resultErrorState(ctx, .of("22003"), "value overflows numeric format"),
    };
    const k = dec.key(a, r, true) catch return api.resultErrorNomem(ctx);
    api.resultBlob(ctx, k, .transient);
}

/// random_normal([mean [, stddev]]): Box-Muller (pg_prng_double_normal()).
fn randomNormalFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const mean: f64 = if (argv.len > 0) api.valueDouble(argv[0]) else 0;
    const sd: f64 = if (argv.len > 1) api.valueDouble(argv[1]) else 1;
    const r = prng(ctx);
    const u_1 = 1.0 - r.double();
    const u_2 = 1.0 - r.double();
    const z = @sqrt(-2.0 * libm.log(u_1)) * @sin(2.0 * math.pi * u_2);
    api.resultDouble(ctx, @mulAdd(f64, sd, z, mean));
}

/// setseed(s): pg_prng_fseed(); NULL (PostgreSQL's void).
fn setseedFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const s = api.valueDouble(argv[0]);
    if (s < -1 or s > 1 or isNan(s)) {
        var buf: [96]u8 = undefined;
        var gb: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "setseed parameter {s} is out of allowed range [-1,1]", .{stats.formatG(&gb, s)}) catch "setseed parameter is out of allowed range [-1,1]";
        return api.resultErrorState(ctx, .of("22023"), msg);
    }
    const db = api.contextDbHandle(ctx);
    const iseed: i64 = @intFromFloat(@as(f64, @floatFromInt((@as(u64, 1) << 52) - 1)) * s);
    var st: [2]u64 = undefined;
    seed(&st, @bitCast(iseed));
    db.xq.postgres.prng = st;
    api.resultNull(ctx);
}
