//! Scalar functions that MariaDB and SQL Server define alike: the math
//! functions (NULL where the result is not a finite number; FLOOR,
//! CEILING and ROUND an integer when it fits) and LEFT, RIGHT, REVERSE,
//! REPEAT/REPLICATE, SPACE and ASCII, by characters of UTF-8 text.
//! Here, outside the dialect directories, so that a build with one of
//! the two dialects only (-Ddialects=) has them.

const std = @import("std");
const api = @import("../vdbe/api.zig");
const dfunc = @import("func.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;

const isNull = dfunc.isNull;
const anyNull = dfunc.anyNull;
const isIntegral = dfunc.isIntegral;
const text = dfunc.text;
const charCount = dfunc.charCount;
const charOffset = dfunc.charOffset;

// ================================================================ math

/// Whether the integral float `r` is an i64.
fn fitsI64(r: f64) bool {
    return r >= -9.2233720368547758e18 and r < 9.2233720368547758e18;
}

fn mathFunc(comptime f: fn (f64) f64) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            const r = f(api.valueDouble(argv[0]));
            if (std.math.isNan(r) or std.math.isInf(r)) return api.resultNull(ctx);
            api.resultDouble(ctx, r);
        }
    }.call;
}

fn sqrt(x: f64) f64 {
    return if (x < 0) std.math.nan(f64) else @sqrt(x);
}
fn exp(x: f64) f64 {
    return @exp(x);
}
fn ln(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log(x);
}
fn log2(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log2(x);
}
fn log10(x: f64) f64 {
    return if (x <= 0) std.math.nan(f64) else @log10(x);
}
fn sin(x: f64) f64 {
    return @sin(x);
}
fn cos(x: f64) f64 {
    return @cos(x);
}
fn tan(x: f64) f64 {
    return @tan(x);
}
fn asin(x: f64) f64 {
    return std.math.asin(x);
}
fn acos(x: f64) f64 {
    return std.math.acos(x);
}
fn atan(x: f64) f64 {
    return std.math.atan(x);
}
fn degrees(x: f64) f64 {
    return x * 180.0 / std.math.pi;
}
fn radians(x: f64) f64 {
    return x * std.math.pi / 180.0;
}

pub const sqrtFunc = mathFunc(sqrt);
pub const expFunc = mathFunc(exp);
pub const lnFunc = mathFunc(ln);
pub const log2Func = mathFunc(log2);
pub const log10Func = mathFunc(log10);
pub const sinFunc = mathFunc(sin);
pub const cosFunc = mathFunc(cos);
pub const tanFunc = mathFunc(tan);
pub const asinFunc = mathFunc(asin);
pub const acosFunc = mathFunc(acos);
pub const atanFunc = mathFunc(atan);
pub const degreesFunc = mathFunc(degrees);
pub const radiansFunc = mathFunc(radians);

/// LOG(x) is ln(x); LOG(b, x) is log base b.
pub fn logFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 1) return lnFunc(ctx, argv);
    if (anyNull(argv)) return api.resultNull(ctx);
    const b = api.valueDouble(argv[0]);
    const x = api.valueDouble(argv[1]);
    if (b <= 0 or b == 1 or x <= 0) return api.resultNull(ctx);
    api.resultDouble(ctx, @log(x) / @log(b));
}

pub fn piFunc(ctx: *Context, _: []*Mem) void {
    api.resultDouble(ctx, std.math.pi);
}

/// FLOOR/CEIL: an integer for an integer or a float that fits.
fn roundingFunc(comptime up: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (isNull(argv[0])) return api.resultNull(ctx);
            if (isIntegral(argv[0])) return api.resultInt64(ctx, api.valueInt64(argv[0]));
            const x = api.valueDouble(argv[0]);
            const r = if (up) @ceil(x) else @floor(x);
            if (fitsI64(r)) return api.resultInt64(ctx, @intFromFloat(r));
            api.resultDouble(ctx, r);
        }
    }.call;
}

pub const floorFunc = roundingFunc(false);
pub const ceilFunc = roundingFunc(true);

/// TRUNCATE(x, d): x truncated to d decimals.
pub fn truncateFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const d = api.valueInt64(argv[1]);
    if (isIntegral(argv[0]) and d >= 0) return api.resultInt64(ctx, api.valueInt64(argv[0]));
    const x = api.valueDouble(argv[0]);
    const p = std.math.pow(f64, 10, @floatFromInt(std.math.clamp(d, -30, 30)));
    const r = @trunc(x * p) / p;
    if (d <= 0 and fitsI64(r)) return api.resultInt64(ctx, @intFromFloat(r));
    api.resultDouble(ctx, r);
}

/// ROUND(x[, d]): half away from zero; an integer for an integer or
/// when d <= 0 (MariaDB's exact result for ROUND(2.5) is 3).
pub fn roundFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const d: i64 = if (argv.len > 1) std.math.clamp(api.valueInt64(argv[1]), -30, 30) else 0;
    if (isIntegral(argv[0]) and d >= 0) return api.resultInt64(ctx, api.valueInt64(argv[0]));
    const x = api.valueDouble(argv[0]);
    const p = std.math.pow(f64, 10, @floatFromInt(d));
    const r = @round(x * p) / p;
    if (d <= 0 and fitsI64(r)) return api.resultInt64(ctx, @intFromFloat(r));
    api.resultDouble(ctx, r);
}

// ============================================================== strings

/// LEFT(s, n), RIGHT(s, n).
fn sideFunc(comptime right: bool) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            if (anyNull(argv)) return api.resultNull(ctx);
            const z = text(ctx, argv[0]) orelse return;
            const n_i = api.valueInt64(argv[1]);
            const n: usize = if (n_i < 0) 0 else @intCast(n_i);
            const len = charCount(z);
            if (n >= len) return api.resultText(ctx, z, .transient);
            if (right) return api.resultText(ctx, z[charOffset(z, len - n)..], .transient);
            api.resultText(ctx, z[0..charOffset(z, n)], .transient);
        }
    }.call;
}

pub const leftFunc = sideFunc(false);
pub const rightFunc = sideFunc(true);

/// REPEAT(s, n).
pub fn repeatFunc(ctx: *Context, argv: []*Mem) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const gpa = dfunc.gpa(ctx);
    const z = text(ctx, argv[0]) orelse return;
    const n = api.valueInt64(argv[1]);
    if (n <= 0 or z.len == 0) return api.resultText(ctx, "", .static);
    if (@as(u64, @intCast(n)) * z.len > 1 << 30) return api.resultErrorTooBig(ctx);
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacityPrecise(gpa, @as(usize, @intCast(n)) * z.len) catch return api.resultErrorNomem(ctx);
    for (0..@intCast(n)) |_| out.appendSliceAssumeCapacity(z);
    dfunc.resultOwned(ctx, &out);
}

/// SPACE(n).
pub fn spaceFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const gpa = dfunc.gpa(ctx);
    const n = api.valueInt64(argv[0]);
    if (n <= 0) return api.resultText(ctx, "", .static);
    if (n > 1 << 30) return api.resultErrorTooBig(ctx);
    var out: std.ArrayList(u8) = .empty;
    out.appendNTimes(gpa, ' ', @intCast(n)) catch return api.resultErrorNomem(ctx);
    dfunc.resultOwned(ctx, &out);
}

/// REVERSE(s), by characters.
pub fn reverseFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const gpa = dfunc.gpa(ctx);
    const z = text(ctx, argv[0]) orelse return;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, z.len) catch return api.resultErrorNomem(ctx);
    var end = z.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and z[start] & 0xc0 == 0x80) start -= 1;
        out.appendSliceAssumeCapacity(z[start..end]);
        end = start;
    }
    dfunc.resultOwned(ctx, &out);
}

/// ASCII(s): the first byte, 0 for ''.
pub fn asciiFunc(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return api.resultNull(ctx);
    const z = text(ctx, argv[0]) orelse return;
    api.resultInt64(ctx, if (z.len == 0) 0 else z[0]);
}
