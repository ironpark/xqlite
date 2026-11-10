//! The math functions of SQLITE_ENABLE_MATH_FUNCTIONS (port of func.c):
//! ceil(), ceiling(), floor(), trunc(), ln(), log(), log10(), log2(),
//! exp(), pow(), power(), mod(), the trigonometric and hyperbolic
//! functions and their inverses, sqrt(), radians(), degrees() and pi().
//! func.zig registers them where func.c does, in its table.
//!
//! They are the SQLite dialect's only (FUNC.XQ_SQLITE_ONLY): the other
//! dialects have functions of these names with their own meaning, or
//! none, and keep them.
//!
//! SQLite calls the C library's libm, whose last bit differs from one
//! platform to the next. These call one libm on every platform, in every
//! build mode and in WebAssembly: musl's (../../dialect/libm.zig, the
//! port the postgres dialect uses; Zig's std.math for asin, acos, atan
//! and atan2, also musl's code), so a value stored by an expression index
//! or a generated column is the same wherever xqlite computes it. That is
//! SQLite on musl (Alpine), but for log2(), which is FreeBSD's where musl
//! 1.2 has Arm's; exp(), ln() and pow() are Arm's code, which glibc has
//! too. Against other libms (macOS's) the transcendental functions differ
//! in the last bit or so for some arguments, as two sqlite3 builds do.
//! ceil(), floor(), trunc(), sqrt() and mod() (fmod()) are exact in every
//! libm.
//!
//! The C library is not called: the Zig builtins (@exp, @sin ...) call it
//! in a release build that links one, and compiler-rt's code in a debug
//! build or without one, and an `extern` declaration of exp() binds to
//! compiler-rt's too in a debug build.

const std = @import("std");
const vi = @import("../../vdbe/vdbe_int.zig");
const api = @import("../../vdbe/api.zig");
const musl = @import("../../dialect/libm.zig");
const StepFn = @import("../sqlite_int.zig").FuncDef.StepFn;
const ptrToInt = @import("func.zig").ptrToInt;

const Context = vi.Context;
const Mem = vi.Mem;

const SQLITE_INTEGER = vi.SQLITE_INTEGER;
const SQLITE_FLOAT = vi.SQLITE_FLOAT;

// ============================================================== libm

/// The libm functions of this file (see the top of the file).
pub const m = struct {
    pub fn ceil(x: f64) f64 {
        return @ceil(x);
    }
    pub fn floor(x: f64) f64 {
        return @floor(x);
    }
    pub fn trunc(x: f64) f64 {
        return @trunc(x);
    }
    pub fn sqrt(x: f64) f64 {
        return @sqrt(x);
    }
    /// fmod(): exact; NaN for an infinite x or a zero y, x for an
    /// infinite y.
    pub fn fmod(x: f64, y: f64) f64 {
        if (std.math.isNan(x) or std.math.isNan(y) or std.math.isInf(x) or y == 0) return std.math.nan(f64);
        if (std.math.isInf(y)) return x;
        return @rem(x, y);
    }
    pub const exp = musl.exp;
    pub const log = musl.log;
    pub const log10 = musl.log10;
    pub const log2 = musl.log2;
    pub const pow = musl.pow;
    pub const sin = musl.sin;
    pub const cos = musl.cos;
    pub const tan = musl.tan;
    pub fn acos(x: f64) f64 {
        return std.math.acos(x);
    }
    pub fn asin(x: f64) f64 {
        return std.math.asin(x);
    }
    pub fn atan(x: f64) f64 {
        return std.math.atan(x);
    }
    pub fn atan2(y: f64, x: f64) f64 {
        return std.math.atan2(y, x);
    }
    pub const cosh = musl.cosh;
    pub const sinh = musl.sinh;
    pub const tanh = musl.tanh;
    pub const acosh = musl.acosh;
    pub const asinh = musl.asinh;
    pub const atanh = musl.atanh;
};

/// M_PI.
const pi: f64 = 3.141592653589793238462643383279502884;

/// degToRad(): x*(M_PI/180.0), the quotient a double as in C.
fn degToRad(x: f64) f64 {
    const k: f64 = pi / @as(f64, 180.0);
    return x * k;
}

/// radToDeg(): x*(180.0/M_PI).
fn radToDeg(x: f64) f64 {
    const k: f64 = @as(f64, 180.0) / pi;
    return x * k;
}

// ========================================================= functions

/// ceilingFunc(): ceil(X), ceiling(X), floor(X), trunc(X): an integer
/// stays the same integer, a real goes through `f`, anything else is
/// NULL.
pub fn ceilingFunc(comptime f: fn (f64) f64) StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            std.debug.assert(argv.len == 1);
            switch (api.valueNumericType(argv[0])) {
                SQLITE_INTEGER => api.resultInt64(ctx, api.valueInt64(argv[0])),
                SQLITE_FLOAT => api.resultDouble(ctx, f(api.valueDouble(argv[0]))),
                else => {},
            }
        }
    }.call;
}

/// logFunc(): ln(X) (user data 0), log(X) and log10(X) (1), log2(X)
/// (2), and log(B,X) (0). NULL for an argument that is not a number or
/// not positive. As in func.c, log(B,X) checks the type of B twice and
/// not that of X, whose value is taken as sqlite3_value_double() gives
/// it.
pub fn logFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 1 or argv.len == 2);
    var x: f64 = undefined;
    switch (api.valueNumericType(argv[0])) {
        SQLITE_INTEGER, SQLITE_FLOAT => {
            x = api.valueDouble(argv[0]);
            if (x <= 0.0) return;
        },
        else => return,
    }
    var ans: f64 = undefined;
    if (argv.len == 2) {
        switch (api.valueNumericType(argv[0])) {
            SQLITE_INTEGER, SQLITE_FLOAT => {},
            else => return,
        }
        const b = m.log(x);
        if (b <= 0.0) return;
        x = api.valueDouble(argv[1]);
        if (x <= 0.0) return;
        ans = m.log(x) / b;
    } else {
        ans = switch (ptrToInt(api.userData(ctx))) {
            1 => m.log10(x),
            2 => m.log2(x),
            else => m.log(x),
        };
    }
    api.resultDouble(ctx, ans);
}

/// math1Func(): a function of one number: NULL if X is not a number.
pub fn math1Func(comptime f: fn (f64) f64) StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            std.debug.assert(argv.len == 1);
            const type0 = api.valueNumericType(argv[0]);
            if (type0 != SQLITE_INTEGER and type0 != SQLITE_FLOAT) return;
            api.resultDouble(ctx, f(api.valueDouble(argv[0])));
        }
    }.call;
}

/// math2Func(): a function of two numbers: NULL if either is not a
/// number.
pub fn math2Func(comptime f: fn (f64, f64) f64) StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            std.debug.assert(argv.len == 2);
            const type0 = api.valueNumericType(argv[0]);
            if (type0 != SQLITE_INTEGER and type0 != SQLITE_FLOAT) return;
            const type1 = api.valueNumericType(argv[1]);
            if (type1 != SQLITE_INTEGER and type1 != SQLITE_FLOAT) return;
            const v0 = api.valueDouble(argv[0]);
            const v1 = api.valueDouble(argv[1]);
            api.resultDouble(ctx, f(v0, v1));
        }
    }.call;
}

/// piFunc(): pi().
pub fn piFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 0);
    api.resultDouble(ctx, pi);
}

pub const radians = degToRad;
pub const degrees = radToDeg;
