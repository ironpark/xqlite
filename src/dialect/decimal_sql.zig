//! The engine functions of exact numbers (pkg/decimal): what a dialect's
//! `numeric` lowers to and what the schema may call, in every dialect
//! (outside the dialect directories, as like.zig's) and in sqlite3 with
//! the extension. Their meaning, and the key, are part of the file format
//! (abi.zig): they never change; a change is a new name.
//!
//! A value of these functions is a key (pkg/decimal: a BLOB in the order
//! of the numbers), with its display scale after it if that is known. An argument
//! may be a key, an integer, a double (its 15 significant digits, as
//! PostgreSQL's float8_numeric()), or text (numeric_in()); NULL gives
//! NULL. The semantics are PostgreSQL's: half away from zero, NaN and
//! +-Infinity, the scale of a quotient by select_div_scale(), its errors
//! and their SQLSTATEs.
//!
//!   xq_dec(x [, p, s])        x as a key with its display scale ('1.50'
//!                             keeps 2); with p and s numeric(p, s):
//!                             rounded to s, "numeric field overflow"
//!                             beyond p - s digits (22003)
//!   xq_dec_key(x [, p, s])    the same without the display scale: what a
//!                             column stores and comparisons compare
//!   xq_dec_valid(k [, p, s])  1 if k is a key without a display scale
//!                             (of numeric(p, s) as is), else 0: a
//!                             column's CHECK
//!   xq_dec_text(x [, s])      the text (numeric_out()), with at least s
//!                             digits after the point if s >= 0
//!   xq_dec_add/sub/mul/div/mod(x, y), xq_dec_neg(x), xq_dec_abs(x)
//!   xq_dec_div_trunc(x, y)    div(): the quotient truncated
//!   xq_dec_round(x [, s]), xq_dec_trunc(x [, s]), xq_dec_ceil(x),
//!   xq_dec_floor(x), xq_dec_sign(x)
//!   xq_dec_scale(x), xq_dec_min_scale(x) (integers), xq_dec_trim_scale(x)
//!   xq_dec_sqrt(x), xq_dec_exp(x), xq_dec_ln(x), xq_dec_log(x) (base
//!   10), xq_dec_log(b, x), xq_dec_power(x, y)   pkg/decimal/src/math.zig: the
//!                             digits and scale of PostgreSQL's
//!   xq_dec_factorial(n)       n! of an integer n
//!   xq_dec_width_bucket(x, b1, b2, n)   width_bucket() (an integer)
//!   xq_dec_int2/int4/int8(x)  the integer, rounded half away from zero
//!   xq_dec_float4/float8(x)   the nearest float (a double is itself)
//!   xq_dec_number(x)          a SQLite number: what an older numeric
//!                             column (stored as numbers) keeps
//!   xq_dec_sum(x), xq_dec_avg(x)   aggregates (and window functions)

const std = @import("std");
const api = @import("../vdbe/api.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const int = @import("../sql/sqlite_int.zig");
const dfunc = @import("func.zig");
const dec = @import("decimal");
const math = @import("decimal").math;

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Dec = dec.Dec;
const Allocator = std.mem.Allocator;

const det: dfunc.Options = .{ .deterministic = true, .exact = true };

/// Hooks.engine_functions of no dialect: dialect.zig adds them.
pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_dec", 1, det, wrap(decFunc)),
    dfunc.scalar("xq_dec", 3, det, wrap(decFunc)),
    dfunc.scalar("xq_dec_key", 1, det, wrap(keyFunc)),
    dfunc.scalar("xq_dec_key", 3, det, wrap(keyFunc)),
    dfunc.scalar("xq_dec_valid", 1, det, validFunc),
    dfunc.scalar("xq_dec_valid", 3, det, validFunc),
    dfunc.scalar("xq_dec_text", 1, det, wrap(textFunc)),
    dfunc.scalar("xq_dec_text", 2, det, wrap(textFunc)),
    dfunc.scalar("xq_dec_add", 2, det, wrap(binary(.add))),
    dfunc.scalar("xq_dec_sub", 2, det, wrap(binary(.sub))),
    dfunc.scalar("xq_dec_mul", 2, det, wrap(binary(.mul))),
    dfunc.scalar("xq_dec_div", 2, det, wrap(binary(.div))),
    dfunc.scalar("xq_dec_mod", 2, det, wrap(binary(.mod))),
    dfunc.scalar("xq_dec_div_trunc", 2, det, wrap(binary(.div_trunc))),
    dfunc.scalar("xq_dec_neg", 1, det, wrap(unary(.neg))),
    dfunc.scalar("xq_dec_abs", 1, det, wrap(unary(.abs))),
    dfunc.scalar("xq_dec_ceil", 1, det, wrap(unary(.ceil))),
    dfunc.scalar("xq_dec_floor", 1, det, wrap(unary(.floor))),
    dfunc.scalar("xq_dec_sign", 1, det, wrap(unary(.sign))),
    dfunc.scalar("xq_dec_trim_scale", 1, det, wrap(unary(.trim_scale))),
    dfunc.scalar("xq_dec_round", 1, det, wrap(roundFunc(true))),
    dfunc.scalar("xq_dec_round", 2, det, wrap(roundFunc(true))),
    dfunc.scalar("xq_dec_trunc", 1, det, wrap(roundFunc(false))),
    dfunc.scalar("xq_dec_trunc", 2, det, wrap(roundFunc(false))),
    dfunc.scalar("xq_dec_scale", 1, det, wrap(scaleFunc(false))),
    dfunc.scalar("xq_dec_min_scale", 1, det, wrap(scaleFunc(true))),
    dfunc.scalar("xq_dec_sqrt", 1, det, wrap(mathFunc(.sqrt))),
    dfunc.scalar("xq_dec_exp", 1, det, wrap(mathFunc(.exp))),
    dfunc.scalar("xq_dec_ln", 1, det, wrap(mathFunc(.ln))),
    dfunc.scalar("xq_dec_log", 1, det, wrap(mathFunc(.log10))),
    dfunc.scalar("xq_dec_log", 2, det, wrap(mathFunc(.log))),
    dfunc.scalar("xq_dec_power", 2, det, wrap(mathFunc(.power))),
    dfunc.scalar("xq_dec_factorial", 1, det, wrap(factorialFunc)),
    dfunc.scalar("xq_dec_width_bucket", 4, det, wrap(widthBucketFunc)),
    dfunc.scalar("xq_dec_int2", 1, det, wrap(intFunc(.smallint))),
    dfunc.scalar("xq_dec_int4", 1, det, wrap(intFunc(.integer))),
    dfunc.scalar("xq_dec_int8", 1, det, wrap(intFunc(.bigint))),
    dfunc.scalar("xq_dec_float4", 1, det, wrap(floatFunc(true))),
    dfunc.scalar("xq_dec_float8", 1, det, wrap(floatFunc(false))),
    dfunc.scalar("xq_dec_number", 1, det, wrap(numberFunc)),
    window("xq_dec_sum", sumStep, sumFinal(.sum, true), sumFinal(.sum, false), sumInverse),
    window("xq_dec_avg", sumStep, sumFinal(.avg, true), sumFinal(.avg, false), sumInverse),
};

/// The function `name` of `n_arg` arguments of the table.
pub fn def(comptime name: []const u8, comptime n_arg: i16) *const int.FuncDef {
    inline for (&engine_functions) |*f| {
        if (comptime std.mem.eql(u8, f.name, name) and f.n_arg == n_arg) return f;
    }
    @compileError("decimal_sql.zig: no function " ++ name);
}

/// What a dialect knows of a function of the table (PostgreSQL's: its
/// overload.zig calls these in the place of its functions, ddltype.zig
/// keeps such calls, deparse.zig gives them back).
pub const Info = struct {
    name: []const u8,
    /// The PostgreSQL function it is (`div` of xq_dec_div_trunc), null
    /// for an operator, a cast or none of PostgreSQL's.
    pg: ?[]const u8 = null,
    /// Its result is a key (else an integer, a double or text).
    key: bool = true,
    /// How many of the first arguments are numerics (keys).
    numerics: u8 = 1,
    /// Whether PostgreSQL's dialect calls it in the place of `pg` (or of
    /// a cast to an integer).
    renamed: bool = false,
};

const infos = [_]Info{
    .{ .name = "xq_dec" },
    .{ .name = "xq_dec_key" },
    .{ .name = "xq_dec_valid", .key = false },
    .{ .name = "xq_dec_text", .key = false },
    .{ .name = "xq_dec_add", .numerics = 2 },
    .{ .name = "xq_dec_sub", .numerics = 2 },
    .{ .name = "xq_dec_mul", .numerics = 2 },
    .{ .name = "xq_dec_div", .numerics = 2 },
    .{ .name = "xq_dec_neg" },
    .{ .name = "xq_dec_mod", .pg = "mod", .numerics = 2, .renamed = true },
    .{ .name = "xq_dec_div_trunc", .pg = "div", .numerics = 2, .renamed = true },
    .{ .name = "xq_dec_abs", .pg = "abs", .renamed = true },
    .{ .name = "xq_dec_ceil", .pg = "ceil", .renamed = true },
    .{ .name = "xq_dec_floor", .pg = "floor", .renamed = true },
    .{ .name = "xq_dec_sign", .pg = "sign", .renamed = true },
    .{ .name = "xq_dec_trim_scale", .pg = "trim_scale", .renamed = true },
    .{ .name = "xq_dec_round", .pg = "round", .renamed = true },
    .{ .name = "xq_dec_trunc", .pg = "trunc", .renamed = true },
    .{ .name = "xq_dec_scale", .pg = "scale", .key = false, .renamed = true },
    .{ .name = "xq_dec_min_scale", .pg = "min_scale", .key = false, .renamed = true },
    .{ .name = "xq_dec_sqrt", .pg = "sqrt", .renamed = true },
    .{ .name = "xq_dec_exp", .pg = "exp", .renamed = true },
    .{ .name = "xq_dec_ln", .pg = "ln", .renamed = true },
    .{ .name = "xq_dec_log", .pg = "log", .numerics = 2, .renamed = true },
    .{ .name = "xq_dec_power", .pg = "power", .numerics = 2, .renamed = true },
    // factorial(bigint): PostgreSQL's dialect calls it by that name.
    .{ .name = "xq_dec_factorial", .pg = "factorial", .numerics = 0 },
    .{ .name = "xq_dec_width_bucket", .pg = "width_bucket", .key = false, .numerics = 3, .renamed = true },
    .{ .name = "xq_dec_int2", .key = false, .renamed = true },
    .{ .name = "xq_dec_int4", .key = false, .renamed = true },
    .{ .name = "xq_dec_int8", .key = false, .renamed = true },
    .{ .name = "xq_dec_float4", .key = false },
    .{ .name = "xq_dec_float8", .key = false },
    .{ .name = "xq_dec_number", .key = false },
    .{ .name = "xq_dec_sum", .pg = "sum", .renamed = true },
    .{ .name = "xq_dec_avg", .pg = "avg", .renamed = true },
};

const info_map = blk: {
    @setEvalBranchQuota(100_000);
    var kvs: [infos.len]struct { []const u8, Info } = undefined;
    for (infos, &kvs) |i, *kv| {
        for (engine_functions) |f| {
            if (std.mem.eql(u8, f.name, i.name)) break;
        } else @compileError("decimal_sql.zig: no function " ++ i.name);
        kv.* = .{ i.name, i };
    }
    break :blk std.StaticStringMap(Info).initComptime(kvs);
};

/// What is known of the function `name` of the table, null if it is not one.
pub fn info(name: []const u8) ?Info {
    return info_map.get(name);
}

fn window(name: [:0]const u8, step: dfunc.StepFn, final: dfunc.FinalFn, value_fn: dfunc.FinalFn, inverse: dfunc.StepFn) int.FuncDef {
    var f = dfunc.aggregate(name, 1, det, step, final);
    f.x_value = value_fn;
    f.x_inverse = inverse;
    return f;
}

/// What a call may fail with: Reported when the error is the call's
/// result already.
const Fail = error{ Reported, OutOfMemory, Invalid, Overflow, DivisionByZero };

/// A call: an arena of the connection's allocator.
const Call = struct {
    ctx: *Context,
    arena: std.heap.ArenaAllocator,

    fn a(c: *Call) Allocator {
        return c.arena.allocator();
    }
};

fn wrap(comptime f: fn (*Call, []*Mem) Fail!void) dfunc.StepFn {
    return struct {
        fn call(ctx: *Context, argv: []*Mem) void {
            var c: Call = .{ .ctx = ctx, .arena = .init(dfunc.gpa(ctx)) };
            defer c.arena.deinit();
            f(&c, argv) catch |err| report(ctx, err);
        }
    }.call;
}

fn report(ctx: *Context, err: Fail) void {
    switch (err) {
        error.Reported => {},
        error.OutOfMemory => api.resultErrorNomem(ctx),
        error.Overflow => api.resultErrorState(ctx, .of("22003"), "value overflows numeric format"),
        error.DivisionByZero => api.resultErrorState(ctx, .of("22012"), "division by zero"),
        error.Invalid => api.resultErrorState(ctx, .of("22P02"), "invalid input syntax for type numeric"),
    }
}

/// The number of argument `m`, null for NULL.
fn value(c: *Call, m: *Mem) Fail!?Dec {
    return valueIn(c.ctx, c.a(), m);
}

fn valueIn(ctx: *Context, a: Allocator, m: *Mem) Fail!?Dec {
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return null,
        vi.SQLITE_INTEGER => return try dec.fromInt(a, api.valueInt64(m)),
        vi.SQLITE_FLOAT => return try dec.fromFloat(a, api.valueDouble(m)),
        vi.SQLITE_BLOB => {
            const b = api.valueBlob(m) orelse "";
            const r = dec.decodeKey(a, b) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const msg = std.fmt.allocPrint(a, "invalid input syntax for type numeric: \"\\x{x}\"", .{b[0..@min(b.len, 64)]}) catch return error.OutOfMemory;
                    api.resultErrorState(ctx, .of("22P02"), msg);
                    return error.Reported;
                },
            };
            return r.dec;
        },
        else => {
            const z = api.valueText(m) orelse return error.OutOfMemory;
            return dec.parse(a, z) catch |err| switch (err) {
                error.Invalid => {
                    const msg = std.fmt.allocPrint(a, "invalid input syntax for type numeric: \"{s}\"", .{z}) catch return error.OutOfMemory;
                    api.resultErrorState(ctx, .of("22P02"), msg);
                    return error.Reported;
                },
                else => |e| return e,
            };
        },
    }
}

/// value() for other functions: the number of argument `m` (in `a`);
/// null once the result is set (NULL for NULL, or the error).
pub fn numArg(ctx: *Context, a: Allocator, m: *Mem) ?Dec {
    const d = valueIn(ctx, a, m) catch |err| {
        report(ctx, err);
        return null;
    };
    return d orelse {
        api.resultNull(ctx);
        return null;
    };
}

/// An integer argument, null for NULL.
fn intArg(m: *Mem) ?i64 {
    if (dfunc.isNull(m)) return null;
    return api.valueInt64(m);
}

/// `d` as the call's key (with its display scale if `with_scale`).
fn result(c: *Call, d: Dec, with_scale: bool) Fail!void {
    try dec.check(d);
    const k = try dec.key(c.a(), d, with_scale);
    api.resultBlob(c.ctx, k, .transient);
}

/// numeric(p, s) of `d`, from the arguments p and s (argv[1], argv[2]).
fn typmod(c: *Call, d: Dec, argv: []*Mem) Fail!Dec {
    const p = intArg(argv[1]) orelse return d;
    const s = intArg(argv[2]) orelse return d;
    if (p < 1 or p > dec.max_precision) {
        api.resultErrorState(c.ctx, .of("22023"), "NUMERIC precision must be between 1 and 1000");
        return error.Reported;
    }
    if (s < -dec.max_precision or s > dec.max_precision) {
        api.resultErrorState(c.ctx, .of("22023"), "NUMERIC scale must be between -1000 and 1000");
        return error.Reported;
    }
    return dec.applyTypmod(c.a(), d, @intCast(p), @intCast(s)) catch |err| switch (err) {
        error.Overflow => {
            // PostgreSQL's DETAIL.
            var dbuf: [160]u8 = undefined;
            api.resultErrorFields(c.ctx, .of("22003"), .{ .message = "numeric field overflow", .detail = dec.overflowDetail(&dbuf, d, p, s) });
            return error.Reported;
        },
        else => |e| return e,
    };
}

fn decFunc(c: *Call, argv: []*Mem) Fail!void {
    var d = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
    if (argv.len == 3) d = try typmod(c, d, argv);
    try result(c, d, true);
}

fn keyFunc(c: *Call, argv: []*Mem) Fail!void {
    var d = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
    if (argv.len == 3) d = try typmod(c, d, argv);
    try result(c, d, false);
}

fn validFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    switch (api.valueType(m)) {
        vi.SQLITE_NULL => return api.resultNull(ctx),
        vi.SQLITE_BLOB => {},
        else => return api.resultInt64(ctx, 0),
    }
    const b = api.valueBlob(m) orelse "";
    if (!dec.isPureKey(b)) return api.resultInt64(ctx, 0);
    if (argv.len == 3) {
        const p = intArg(argv[1]) orelse return api.resultInt64(ctx, 1);
        const s = intArg(argv[2]) orelse return api.resultInt64(ctx, 1);
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
        defer arena.deinit();
        const a = if (b.len * 2 + 16 <= buf.len) fba.allocator() else arena.allocator();
        const d = (dec.decodeKey(a, b) catch return api.resultInt64(ctx, 0)).dec;
        const ok = dec.fitsTypmod(d, @intCast(std.math.clamp(p, -10000, 10000)), @intCast(std.math.clamp(s, -10000, 10000)));
        return api.resultInt64(ctx, @intFromBool(ok));
    }
    api.resultInt64(ctx, 1);
}

fn textFunc(c: *Call, argv: []*Mem) Fail!void {
    var d = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
    if (argv.len == 2) if (intArg(argv[1])) |s| if (s >= 0) {
        d.dscale = @max(@as(u32, @intCast(@min(s, dec.max_dscale))), d.fracDigits());
    };
    const z = try dec.toText(c.a(), d);
    api.resultText(c.ctx, z, .transient);
}

const Binary = enum { add, sub, mul, div, mod, div_trunc };

fn binary(comptime op: Binary) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            const y = try value(c, argv[1]) orelse return api.resultNull(c.ctx);
            const a = c.a();
            const r = switch (op) {
                .add => try dec.add(a, x, y),
                .sub => try dec.sub(a, x, y),
                .mul => try dec.mul(a, x, y),
                .div => try dec.div(a, x, y),
                .mod => try dec.mod(a, x, y),
                .div_trunc => try dec.divTrunc(a, x, y),
            };
            try result(c, r, true);
        }
    }.f;
}

const Unary = enum { neg, abs, ceil, floor, sign, trim_scale };

fn unary(comptime op: Unary) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            const a = c.a();
            const r: Dec = switch (op) {
                .neg => x.negate(),
                .abs => x.abs(),
                .ceil => try dec.ceil(a, x),
                .floor => try dec.floor(a, x),
                .sign => switch (x.kind) {
                    .nan => Dec.nan,
                    else => try dec.fromInt(a, x.sign()),
                },
                .trim_scale => x.withScale(0),
            };
            try result(c, r, true);
        }
    }.f;
}

fn roundFunc(comptime rnd: bool) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            var s: i64 = 0;
            if (argv.len == 2) s = intArg(argv[1]) orelse return api.resultNull(c.ctx);
            // PostgreSQL's bounds: every digit before the point, the
            // largest display scale.
            s = std.math.clamp(s, -dec.max_point - 1, dec.max_dscale);
            const r = if (rnd) try dec.round(c.a(), x, s) else try dec.trunc(c.a(), x, s);
            try result(c, r, true);
        }
    }.f;
}

fn scaleFunc(comptime min: bool) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            if (x.kind != .finite) return api.resultNull(c.ctx);
            api.resultInt64(c.ctx, if (min) x.fracDigits() else x.dscale);
        }
    }.f;
}

const Math = enum { sqrt, exp, ln, log10, log, power };

fn mathFunc(comptime op: Math) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            const y: Dec = if (argv.len == 2) try value(c, argv[1]) orelse return api.resultNull(c.ctx) else .zero;
            const a = c.a();
            const r = switch (op) {
                .sqrt => math.sqrt(a, x),
                .exp => math.exp(a, x),
                .ln => math.ln(a, x),
                .log10 => math.log10(a, x),
                .log => math.log(a, x, y),
                .power => math.power(a, x, y),
            } catch |err| return mathError(c, err);
            try result(c, r, true);
        }
    }.f;
}

fn factorialFunc(c: *Call, argv: []*Mem) Fail!void {
    const n: i64 = switch (api.valueType(argv[0])) {
        vi.SQLITE_NULL => return api.resultNull(c.ctx),
        vi.SQLITE_INTEGER => api.valueInt64(argv[0]),
        else => blk: {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            break :blk dec.toInt(c.a(), x) catch |err| switch (err) {
                error.Overflow, error.Invalid => {
                    api.resultErrorState(c.ctx, .of("22003"), "bigint out of range");
                    return error.Reported;
                },
                else => |e| return e,
            };
        },
    };
    const r = math.factorial(c.a(), n) catch |err| return mathError(c, err);
    try result(c, r, true);
}

fn widthBucketFunc(c: *Call, argv: []*Mem) Fail!void {
    const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
    const b1 = try value(c, argv[1]) orelse return api.resultNull(c.ctx);
    const b2 = try value(c, argv[2]) orelse return api.resultNull(c.ctx);
    const n = intArg(argv[3]) orelse return api.resultNull(c.ctx);
    const r = math.widthBucket(c.a(), x, b1, b2, n) catch |err| return mathError(c, err);
    api.resultInt64(c.ctx, r);
}

/// The errors of pkg/decimal/src/math.zig, PostgreSQL's.
fn mathError(c: *Call, err: math.Error) Fail {
    const state, const msg = math.errorInfo(err) orelse return error.OutOfMemory;
    api.resultErrorState(c.ctx, .{ .sqlstate = state }, msg);
    return error.Reported;
}

const IntType = enum {
    smallint,
    integer,
    bigint,

    fn range(t: IntType) [2]i64 {
        return switch (t) {
            .smallint => .{ std.math.minInt(i16), std.math.maxInt(i16) },
            .integer => .{ std.math.minInt(i32), std.math.maxInt(i32) },
            .bigint => .{ std.math.minInt(i64), std.math.maxInt(i64) },
        };
    }
};

fn intFunc(comptime t: IntType) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            const name = @tagName(t);
            switch (x.kind) {
                .nan => {
                    api.resultErrorState(c.ctx, .of("0A000"), "cannot convert NaN to " ++ name);
                    return error.Reported;
                },
                .pinf, .ninf => {
                    api.resultErrorState(c.ctx, .of("0A000"), "cannot convert infinity to " ++ name);
                    return error.Reported;
                },
                .finite => {},
            }
            const v = dec.toInt(c.a(), x) catch |err| switch (err) {
                error.Overflow => null,
                else => |e| return e,
            };
            const r = t.range();
            if (v == null or v.? < r[0] or v.? > r[1]) {
                api.resultErrorState(c.ctx, .of("22003"), name ++ " out of range");
                return error.Reported;
            }
            api.resultInt64(c.ctx, v.?);
        }
    }.f;
}

fn floatFunc(comptime real: bool) fn (*Call, []*Mem) Fail!void {
    return struct {
        fn f(c: *Call, argv: []*Mem) Fail!void {
            // A double is itself, an integer the double nearest.
            switch (api.valueType(argv[0])) {
                vi.SQLITE_FLOAT, vi.SQLITE_INTEGER => {
                    const v = api.valueDouble(argv[0]);
                    return api.resultDouble(c.ctx, if (real) @as(f32, @floatCast(v)) else v);
                },
                else => {},
            }
            const x = try value(c, argv[0]) orelse return api.resultNull(c.ctx);
            const v = dec.toFloat(c.a(), x) catch |err| switch (err) {
                error.Overflow => {
                    const z = try dec.toText(c.a(), x);
                    const msg = try std.fmt.allocPrint(c.a(), "\"{s}\" is out of range for type {s}", .{ z, if (real) "real" else "double precision" });
                    api.resultErrorState(c.ctx, .of("22003"), msg);
                    return error.Reported;
                },
                else => |e| return e,
            };
            if (real) {
                const r: f32 = @floatCast(v);
                if (std.math.isInf(r) and !std.math.isInf(v)) {
                    const z = try dec.toText(c.a(), x);
                    const msg = try std.fmt.allocPrint(c.a(), "\"{s}\" is out of range for type real", .{z});
                    api.resultErrorState(c.ctx, .of("22003"), msg);
                    return error.Reported;
                }
                return api.resultDouble(c.ctx, r);
            }
            api.resultDouble(c.ctx, v);
        }
    }.f;
}

/// The SQLite number of a numeric, for a column that stores numbers (a
/// numeric column of a table made before numerics were keys): an
/// integer or a double as it is; text as numeric_in() reads it, an
/// integer if it is written as one (`3`), else the double (`1.50` is
/// 1.5, as such a column always stored it); a key its integer if it has
/// no digits after the point and fits, else the nearest double. NaN has
/// no SQLite number: invalid input.
fn numberFunc(c: *Call, argv: []*Mem) Fail!void {
    const m = argv[0];
    switch (api.valueType(m)) {
        vi.SQLITE_NULL, vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return api.resultValue(c.ctx, m),
        vi.SQLITE_TEXT => {
            const raw = api.valueText(m) orelse return error.OutOfMemory;
            const x = try value(c, m) orelse return api.resultNull(c.ctx);
            const s = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
            if (x.kind == .finite and std.mem.indexOfAny(u8, s, ".eExXoObB_") == null) {
                if (std.fmt.parseInt(i64, s, 10)) |v| return api.resultInt64(c.ctx, v) else |_| {}
            }
            return number(c, x, raw, false);
        },
        else => {
            const x = try value(c, m) orelse return api.resultNull(c.ctx);
            return number(c, x, "NaN", true);
        },
    }
}

fn number(c: *Call, x: Dec, raw: []const u8, integral: bool) Fail!void {
    if (x.kind == .nan) {
        const msg = try std.fmt.allocPrint(c.a(), "invalid input syntax for type numeric: \"{s}\"", .{raw});
        api.resultErrorState(c.ctx, .of("22P02"), msg);
        return error.Reported;
    }
    if (integral and x.kind == .finite and x.dscale == 0 and x.digits.len <= 19) {
        if (dec.toInt(c.a(), x)) |v| return api.resultInt64(c.ctx, v) else |_| {}
    }
    const v = dec.toFloat(c.a(), x) catch |err| switch (err) {
        error.Overflow => if (x.neg) -std.math.inf(f64) else std.math.inf(f64),
        else => |e| return e,
    };
    api.resultDouble(c.ctx, v);
}

// ============================================================= sum, avg

/// The state of xq_dec_sum() and xq_dec_avg() in the aggregate context:
/// the sum of the numbers, how many there were, the NaNs and infinities,
/// and how many had each display scale (so that the largest is known when
/// a window's frame drops one, as PostgreSQL's maxScale).
const SumState = struct {
    n: i64 = 0,
    /// The numbers of no known display scale (a stored key, a double).
    unknown_scale: i64 = 0,
    nan: i64 = 0,
    pinf: i64 = 0,
    ninf: i64 = 0,
    /// The sum's key (decimal.key()), owned by the connection's allocator;
    /// null for 0.
    sum: ?[*]u8 = null,
    sum_len: usize = 0,
    /// scales[s]: how many numbers have display scale s.
    scales: ?[*]u64 = null,
    scales_len: usize = 0,
};

fn sumStep(ctx: *Context, argv: []*Mem) void {
    accumulate(ctx, argv, false);
}

fn sumInverse(ctx: *Context, argv: []*Mem) void {
    accumulate(ctx, argv, true);
}

fn accumulate(ctx: *Context, argv: []*Mem, remove: bool) void {
    var c: Call = .{ .ctx = ctx, .arena = .init(dfunc.gpa(ctx)) };
    defer c.arena.deinit();
    accumulateImpl(&c, argv[0], remove) catch |err| report(ctx, err);
}

fn accumulateImpl(c: *Call, m: *Mem, remove: bool) Fail!void {
    const x = try value(c, m) orelse return;
    const st = dfunc.aggState(SumState, c.ctx, true) orelse return error.Reported;
    const gpa = dfunc.gpa(c.ctx);
    const d: i64 = if (remove) -1 else 1;
    st.n += d;
    switch (x.kind) {
        .nan => st.nan += d,
        .pinf => st.pinf += d,
        .ninf => st.ninf += d,
        .finite => {
            if (!x.scale_known) st.unknown_scale += d;
            const cur = try current(c, st);
            const next = if (remove) try dec.sub(c.a(), cur, x) else try dec.add(c.a(), cur, x);
            const k = try dec.key(gpa, next.withScale(0), false);
            if (st.sum) |old| gpa.free(old[0..st.sum_len]);
            st.sum = k.ptr;
            st.sum_len = k.len;
            // The count of the scale.
            const s: usize = x.dscale;
            if (s >= st.scales_len) {
                const n = @max(s + 1, st.scales_len * 2, 4);
                const grown = try gpa.alloc(u64, n);
                @memset(grown, 0);
                if (st.scales) |old| {
                    @memcpy(grown[0..st.scales_len], old[0..st.scales_len]);
                    gpa.free(old[0..st.scales_len]);
                }
                st.scales = grown.ptr;
                st.scales_len = n;
            }
            const counts = st.scales.?[0..st.scales_len];
            if (remove) counts[s] -|= 1 else counts[s] += 1;
        },
    }
}

/// The sum so far.
fn current(c: *Call, st: *const SumState) Fail!Dec {
    const k = st.sum orelse return .zero;
    return (try dec.decodeKey(c.a(), k[0..st.sum_len])).dec;
}

fn maxScale(st: *const SumState) u32 {
    const counts = (st.scales orelse return 0)[0..st.scales_len];
    var i = counts.len;
    while (i > 0) {
        i -= 1;
        if (counts[i] > 0) return @intCast(i);
    }
    return 0;
}

const Agg = enum { sum, avg };

fn sumFinal(comptime which: Agg, comptime final: bool) dfunc.FinalFn {
    return struct {
        fn f(ctx: *Context) void {
            const st = dfunc.aggState(SumState, ctx, false) orelse return api.resultNull(ctx);
            defer if (final) {
                const gpa = dfunc.gpa(ctx);
                if (st.sum) |k| gpa.free(k[0..st.sum_len]);
                if (st.scales) |s| gpa.free(s[0..st.scales_len]);
                st.* = .{};
            };
            var c: Call = .{ .ctx = ctx, .arena = .init(dfunc.gpa(ctx)) };
            defer c.arena.deinit();
            finish(&c, st, which) catch |err| report(ctx, err);
        }
    }.f;
}

fn finish(c: *Call, st: *const SumState, which: Agg) Fail!void {
    if (st.n <= 0) return api.resultNull(c.ctx);
    const r: Dec = if (st.nan > 0 or (st.pinf > 0 and st.ninf > 0))
        .nan
    else if (st.pinf > 0)
        .pinf
    else if (st.ninf > 0)
        .ninf
    else blk: {
        var s = (try current(c, st)).withScale(maxScale(st));
        s.scale_known = st.unknown_scale <= 0;
        if (which == .sum) break :blk s;
        break :blk try dec.div(c.a(), s, try dec.fromInt(c.a(), st.n));
    };
    try result(c, r, true);
}
