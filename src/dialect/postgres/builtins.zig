//! PostgreSQL's functions of numbers, booleans and hashes beyond
//! funcs.zig's:
//!
//!  - gcd(a, b), lcm(a, b): of integers (int4gcd() ... with their
//!    overflow errors) and of numerics (numeric_gcd(): NaN if one is NaN
//!    or infinite, the larger display scale). overload.zig calls the
//!    engine functions xq_pg_gcd(a, b, bits) and xq_pg_lcm(a, b, bits)
//!    with the width of the arguments' type (32: integer, smallint; 64:
//!    bigint; 0: numeric); gcd() and lcm() of untyped values take an
//!    integer as a bigint, anything else as a numeric;
//!  - float8(x), float4(x): the casts written as calls (an integer, a
//!    numeric, a double, or text read as float8in() and float4in() do); a
//!    real is kept a double, as the dialect's `::real` keeps one;
//!  - booleq(a, b), boolne(a, b): `a = b` and `a <> b` of booleans;
//!  - interval_hash(i): a hash of the interval's key, equal for intervals
//!    that are equal ('30 days' and '1 mon'). Not PostgreSQL's numbers.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const dec = @import("decimal");
const ivl = @import("datetime").interval;
const decimal_sql = @import("../decimal_sql.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Dec = dec.Dec;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("gcd", 2, det, dfunc.bind(gcdFunc, .{false})),
    dfunc.scalar("lcm", 2, det, dfunc.bind(gcdFunc, .{true})),
    dfunc.scalar("float8", 1, det, dfunc.bind(floatFunc, .{false})),
    dfunc.scalar("float4", 1, det, dfunc.bind(floatFunc, .{true})),
    dfunc.scalar("booleq", 2, det, dfunc.bind(boolCmpFunc, .{true})),
    dfunc.scalar("boolne", 2, det, dfunc.bind(boolCmpFunc, .{false})),
    dfunc.scalar("interval_hash", 1, det, intervalHashFunc),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_gcd", 3, det, dfunc.bind(gcdFunc, .{false})),
    dfunc.scalar("xq_pg_lcm", 3, det, dfunc.bind(gcdFunc, .{true})),
};

// ============================================================= gcd, lcm

fn gcdFunc(ctx: *Context, argv: []*Mem, comptime lcm: bool) void {
    if (dfunc.anyNull(argv[0..2])) return api.resultNull(ctx);
    const bits: i64 = if (argv.len > 2) api.valueInt64(argv[2]) else 0;
    const ints = api.valueType(argv[0]) == vi.SQLITE_INTEGER and api.valueType(argv[1]) == vi.SQLITE_INTEGER;
    if (bits == 16 or bits == 32 or bits == 64 or (bits == 0 and argv.len == 2 and ints)) {
        const wide = bits == 64 or bits == 0;
        const x = api.valueInt64(argv[0]);
        const y = api.valueInt64(argv[1]);
        const r = (if (lcm) intLcm(x, y, wide) else intGcd(x, y, wide)) catch
            return api.resultErrorState(ctx, .of("22003"), if (wide) "bigint out of range" else "integer out of range");
        return api.resultInt64(ctx, r);
    }
    var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const x = decimal_sql.numArg(ctx, a, argv[0]) orelse return;
    const y = decimal_sql.numArg(ctx, a, argv[1]) orelse return;
    const r = numGcd(a, x, y, lcm) catch |err| return decError(ctx, err);
    dec.check(r) catch |err| return decError(ctx, err);
    const k = dec.key(a, r, true) catch return api.resultErrorNomem(ctx);
    api.resultBlob(ctx, k, .transient);
}

fn decError(ctx: *Context, err: dec.Error) void {
    switch (err) {
        error.OutOfMemory => api.resultErrorNomem(ctx),
        error.DivisionByZero => api.resultErrorState(ctx, .of("22012"), "division by zero"),
        else => api.resultErrorState(ctx, .of("22003"), "value overflows numeric format"),
    }
}

/// int4gcd_internal() and int8gcd_internal() (`wide`).
fn intGcd(x_in: i64, y_in: i64, wide: bool) error{Overflow}!i64 {
    const min: i64 = if (wide) std.math.minInt(i64) else std.math.minInt(i32);
    var x = x_in;
    var y = y_in;
    // The larger absolute value first (compared in negative space).
    const ax = if (x < 0) x else -x;
    const ay = if (y < 0) y else -y;
    if (ax > ay) std.mem.swap(i64, &x, &y);
    if (x == min) {
        if (y == 0 or y == min) return error.Overflow;
        if (y == -1) return 1;
    }
    while (y != 0) {
        const t = y;
        y = @rem(x, y);
        x = t;
    }
    if (x < 0) x = -x;
    return x;
}

/// int4lcm() and int8lcm() (`wide`).
fn intLcm(x_in: i64, y: i64, wide: bool) error{Overflow}!i64 {
    if (x_in == 0 or y == 0) return 0;
    const g = try intGcd(x_in, y, wide);
    const x = @divTrunc(x_in, g);
    var r = std.math.mul(i64, x, y) catch return error.Overflow;
    const min: i64 = if (wide) std.math.minInt(i64) else std.math.minInt(i32);
    const max: i64 = if (wide) std.math.maxInt(i64) else std.math.maxInt(i32);
    if (r < min or r > max or r == min) return error.Overflow;
    if (r < 0) r = -r;
    return r;
}

/// numeric_gcd() and numeric_lcm(): gcd_var(), the larger display scale.
fn numGcd(a: std.mem.Allocator, x: Dec, y: Dec, lcm: bool) dec.Error!Dec {
    if (x.kind != .finite or y.kind != .finite) return Dec.nan;
    const scale = @max(x.dscale, y.dscale);
    if (lcm) {
        if (x.isZero() or y.isZero()) {
            var z = Dec.zero;
            z.dscale = scale;
            return z;
        }
        const g = try gcdVar(a, x, y);
        // x / gcd (exact), times y.
        const q = try dec.divTrunc(a, x, g);
        var r = (try dec.mul(a, q, y)).abs();
        r.dscale = scale;
        r.scale_known = true;
        return r;
    }
    var g = try gcdVar(a, x, y);
    g.dscale = scale;
    g.scale_known = true;
    return g;
}

fn gcdVar(a: std.mem.Allocator, x_in: Dec, y_in: Dec) dec.Error!Dec {
    var x = x_in.abs();
    var y = y_in.abs();
    if (dec.order(x, y) == .lt) std.mem.swap(Dec, &x, &y);
    if (dec.order(x, y) == .eq or y.isZero()) return x;
    while (true) {
        const m = try dec.mod(a, x, y);
        if (m.isZero()) break;
        x = y;
        y = m;
    }
    return y;
}

// ============================================================ float casts

fn floatFunc(ctx: *Context, argv: []*Mem, comptime real: bool) void {
    const m = argv[0];
    const v: f64 = switch (api.valueType(m)) {
        vi.SQLITE_NULL => return api.resultNull(ctx),
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => api.valueDouble(m),
        vi.SQLITE_BLOB => blk: {
            var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
            defer arena.deinit();
            const d = decimal_sql.numArg(ctx, arena.allocator(), m) orelse return;
            break :blk switch (d.kind) {
                .nan => std.math.nan(f64),
                .pinf => std.math.inf(f64),
                .ninf => -std.math.inf(f64),
                .finite => dec.toFloat(arena.allocator(), d) catch return api.resultErrorState(ctx, .of("22003"), "value out of range: overflow"),
            };
        },
        else => {
            const raw = dfunc.text(ctx, m) orelse return;
            var buf: [1024]u8 = undefined;
            switch (floatInput(raw, real, &buf)) {
                // Kept a double, as the dialect's casts to real keep one.
                .value => |v| return api.resultDouble(ctx, v),
                .failed => |e| return api.resultErrorState(ctx, e.state, e.msg),
            }
        },
    };
    if (real) {
        // Kept a double, as the dialect's casts to real keep one.
        const f: f32 = @floatCast(v);
        if (std.math.isInf(f) and !std.math.isInf(v)) return api.resultErrorState(ctx, .of("22003"), "value out of range: overflow");
    }
    api.resultDouble(ctx, v);
}

/// What float8in() (float4in() if `real`) makes of text `raw`: the
/// number, or its error (in `buf`).
pub const FloatInput = union(enum) {
    value: f64,
    failed: struct { msg: []const u8, state: int.ErrorState },
};

pub fn floatInput(raw: []const u8, real: bool, buf: []u8) FloatInput {
    const type_name = if (real) "real" else "double precision";
    const shown = raw[0..@min(raw.len, 900)];
    const v = parseFloat(raw) catch |err| return .{ .failed = switch (err) {
        error.Overflow => .{ .state = .of("22003"), .msg = std.fmt.bufPrint(buf, "\"{s}\" is out of range for type {s}", .{ shown, type_name }) catch "value out of range" },
        error.Invalid => .{ .state = .of("22P02"), .msg = std.fmt.bufPrint(buf, "invalid input syntax for type {s}: \"{s}\"", .{ type_name, shown }) catch "invalid input syntax" },
    } };
    if (real) {
        const f: f32 = @floatCast(v);
        if (std.math.isInf(f) and !std.math.isInf(v)) return .{ .failed = .{ .state = .of("22003"), .msg = std.fmt.bufPrint(buf, "\"{s}\" is out of range for type real", .{shown}) catch "value out of range" } };
    }
    return .{ .value = v };
}

/// float8in()'s reading of text: spaces around a number, NaN,
/// [+-]Infinity, [+-]inf; error.Overflow out of range.
pub fn parseFloat(raw: []const u8) error{ Invalid, Overflow }!f64 {
    const s = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    if (s.len == 0) return error.Invalid;
    const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
    const neg = s[0] == '-';
    if (std.ascii.eqlIgnoreCase(body, "nan")) {
        if (body.len != s.len) return error.Invalid;
        return std.math.nan(f64);
    }
    if (std.ascii.eqlIgnoreCase(body, "infinity") or std.ascii.eqlIgnoreCase(body, "inf")) return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    for (body) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '-' or c == '+')) return error.Invalid;
    const v = std.fmt.parseFloat(f64, s) catch return error.Invalid;
    if (std.math.isInf(v)) return error.Overflow;
    return v;
}

// ============================================================== booleans

fn boolCmpFunc(ctx: *Context, argv: []*Mem, comptime eq: bool) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const x = api.valueInt64(argv[0]) != 0;
    const y = api.valueInt64(argv[1]) != 0;
    api.resultInt64(ctx, @intFromBool((x == y) == eq));
}

// ================================================================= hashes

fn intervalHashFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    const datetime = @import("datetime.zig");
    const iv = datetime.intervalArg(ctx, m) orelse return;
    const k = iv.key();
    const h = std.hash.Wyhash.hash(0, &k);
    api.resultInt64(ctx, @as(i32, @truncate(@as(i64, @bitCast(h)))));
}

test "builtins: gcd and lcm of integers" {
    try std.testing.expectEqual(@as(i64, 1466), try intGcd(61866666, 6410818, false));
    try std.testing.expectEqual(@as(i64, 1466), try intGcd(-61866666, 6410818, false));
    try std.testing.expectError(error.Overflow, intGcd(-2147483648, 0, false));
    try std.testing.expectEqual(@as(i64, 2147483648), try intGcd(-2147483648, 0, true));
    try std.testing.expectError(error.Overflow, intLcm(2147483647, 2147483646, false));
    try std.testing.expectError(error.Overflow, intLcm(-2147483648, 1, false));
}
