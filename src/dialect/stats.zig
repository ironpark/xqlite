//! Statistical, ordered-set and hypothetical-set aggregates as PostgreSQL
//! computes them, for any dialect (outside the dialect directories, as
//! variance.zig's; PostgreSQL's dialect lowers its functions to them):
//!
//!   xq_float_var_pop(x), xq_float_var_samp(x), xq_float_stddev_pop(x),
//!   xq_float_stddev_samp(x)    var_pop() ... of doubles: float8_accum()'s
//!                              Youngs-Cramer sums (not variance.zig's
//!                              Welford), so that the digits are
//!                              PostgreSQL's; NULL with no rows (the
//!                              sample ones with one)
//!   xq_corr(y, x), xq_covar_pop(y, x), xq_covar_samp(y, x),
//!   xq_regr_avgx/avgy/sxx/syy/sxy/slope/intercept/r2(y, x)
//!                              float8_regr_accum()'s sums and finals
//!   xq_regr_count(y, x)        the rows where neither is NULL (a bigint)
//!   xq_any_value(x)            the first value that is not NULL
//!   xq_percentile_cont(f, x)   percentile_cont(f) WITHIN GROUP (ORDER BY
//!                              x): the rows come sorted (the aggregate's
//!                              ORDER BY); x a double, interpolated
//!   xq_percentile_disc(f, x)   the first value whose position in the
//!                              sorted rows reaches the fraction f
//!   xq_mode(x)                 the most frequent value of the sorted rows
//!                              (the first of equals)
//!   xq_hypo_rank(flags, h1, x1, lt1, gt1, ...), xq_hypo_dense_rank,
//!   xq_hypo_percent_rank, xq_hypo_cume_dist
//!                              rank(h1 ...) WITHIN GROUP (ORDER BY x1
//!                              ...) of the hypothetical row h: per
//!                              column its value, the row's value and
//!                              whether x < h and x > h (the frontend's
//!                              comparisons, of its types); flags: bit 2i
//!                              column i descending, bit 2i+1 its NULLs
//!                              first
//!
//! The sums are PostgreSQL's as its builds for arm64 compute them (and
//! those of the reference server the tests record): GCC fuses `a * b +
//! c` into one rounding there (-ffp-contract=fast), as @mulAdd does here,
//! on every platform alike.
//!
//! The float aggregates have no inverse (PostgreSQL computes a moving
//! frame anew, as these do: window.zig scans a frame whose start moves for
//! an aggregate without xInverse). NULL arguments are skipped (the
//! transition functions are strict). Their meaning is part of the file
//! format (abi.zig): it never changes.

const std = @import("std");
const api = @import("../vdbe/api.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const int = @import("../sql/sqlite_int.zig");
const dfunc = @import("func.zig");
const serial = @import("../vdbe/serial.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const isNull = dfunc.isNull;

const det: dfunc.Options = .{ .deterministic = true };

/// Hooks.engine_functions of no dialect: dialect.zig adds them.
pub const engine_functions = [_]int.FuncDef{
    noInverse("xq_float_var_pop", 1, varStep, varFinal(.var_pop)),
    noInverse("xq_float_var_samp", 1, varStep, varFinal(.var_samp)),
    noInverse("xq_float_stddev_pop", 1, varStep, varFinal(.stddev_pop)),
    noInverse("xq_float_stddev_samp", 1, varStep, varFinal(.stddev_samp)),
    noInverse("xq_corr", 2, regrStep, regrFinal(.corr)),
    noInverse("xq_covar_pop", 2, regrStep, regrFinal(.covar_pop)),
    noInverse("xq_covar_samp", 2, regrStep, regrFinal(.covar_samp)),
    noInverse("xq_regr_avgx", 2, regrStep, regrFinal(.avgx)),
    noInverse("xq_regr_avgy", 2, regrStep, regrFinal(.avgy)),
    noInverse("xq_regr_count", 2, regrStep, regrFinal(.count)),
    noInverse("xq_regr_intercept", 2, regrStep, regrFinal(.intercept)),
    noInverse("xq_regr_r2", 2, regrStep, regrFinal(.r2)),
    noInverse("xq_regr_slope", 2, regrStep, regrFinal(.slope)),
    noInverse("xq_regr_sxx", 2, regrStep, regrFinal(.sxx)),
    noInverse("xq_regr_sxy", 2, regrStep, regrFinal(.sxy)),
    noInverse("xq_regr_syy", 2, regrStep, regrFinal(.syy)),
    withValue("xq_any_value", 1, anyStep, anyFinal, anyValue),
    dfunc.aggregate("xq_percentile_cont", 2, det, contStep, contFinal),
    dfunc.aggregate("xq_percentile_disc", 2, det, discStep, discFinal),
    dfunc.aggregate("xq_mode", 1, det, modeStep, modeFinal),
    dfunc.aggregate("xq_hypo_rank", -1, det, hypoStep(false), hypoFinal(.rank)),
    dfunc.aggregate("xq_hypo_dense_rank", -1, det, hypoStep(true), hypoFinal(.dense_rank)),
    dfunc.aggregate("xq_hypo_percent_rank", -1, det, hypoStep(false), hypoFinal(.percent_rank)),
    dfunc.aggregate("xq_hypo_cume_dist", -1, det, hypoStep(false), hypoFinal(.cume_dist)),
};

/// An aggregate that is a window function too, without xInverse: its
/// xValue is its xFinal, which leaves the state as it is (the state holds
/// no memory of its own).
fn noInverse(name: [:0]const u8, n_arg: i16, step: dfunc.StepFn, final: dfunc.FinalFn) int.FuncDef {
    return withValue(name, n_arg, step, final, final);
}

fn withValue(name: [:0]const u8, n_arg: i16, step: dfunc.StepFn, final: dfunc.FinalFn, value: dfunc.FinalFn) int.FuncDef {
    var f = dfunc.aggregate(name, n_arg, det, step, final);
    f.x_value = value;
    return f;
}

fn overflow(ctx: *Context) void {
    api.resultErrorState(ctx, .of("22003"), "value out of range: overflow");
}

fn isInf(x: f64) bool {
    return std.math.isInf(x);
}

// ============================================================ variance

/// float8_accum()'s transition values: N, Sx, Sxx.
const Moments = struct { n: f64 = 0, sx: f64 = 0, sxx: f64 = 0 };

fn varStep(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return;
    const m = dfunc.aggState(Moments, ctx, true) orelse return api.resultErrorNomem(ctx);
    const x = api.valueDouble(argv[0]);
    const n0 = m.n;
    const sx0 = m.sx;
    m.n += 1;
    m.sx += x;
    if (n0 > 0) {
        const tmp = @mulAdd(f64, x, m.n, -m.sx);
        m.sxx += tmp * tmp / (m.n * n0);
        // Overflow, unless an input was infinite.
        if (isInf(m.sx) or isInf(m.sxx)) {
            if (!isInf(sx0) and !isInf(x)) return overflow(ctx);
            m.sxx = std.math.nan(f64);
        }
    } else if (std.math.isNan(x) or isInf(x)) {
        // A first input of NaN or infinity: not a variance of 0.
        m.sxx = std.math.nan(f64);
    }
}

const VarKind = enum { var_pop, var_samp, stddev_pop, stddev_samp };

fn varFinal(comptime k: VarKind) dfunc.FinalFn {
    return struct {
        fn f(ctx: *Context) void {
            const m = dfunc.aggState(Moments, ctx, false) orelse return api.resultNull(ctx);
            const sample = k == .var_samp or k == .stddev_samp;
            if (m.n == 0 or (sample and m.n <= 1)) return api.resultNull(ctx);
            const v = m.sxx / (if (sample) m.n - 1 else m.n);
            api.resultDouble(ctx, if (k == .stddev_pop or k == .stddev_samp) @sqrt(v) else v);
        }
    }.f;
}

// ======================================================== regressions

/// float8_regr_accum()'s transition values: N, Sx, Sxx, Sy, Syy, Sxy.
const Regr = struct { n: f64 = 0, sx: f64 = 0, sxx: f64 = 0, sy: f64 = 0, syy: f64 = 0, sxy: f64 = 0 };

/// (y, x), as PostgreSQL's regression aggregates take them.
fn regrStep(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0]) or isNull(argv[1])) return;
    const s = dfunc.aggState(Regr, ctx, true) orelse return api.resultErrorNomem(ctx);
    const y = api.valueDouble(argv[0]);
    const x = api.valueDouble(argv[1]);
    const n0 = s.n;
    const sx0 = s.sx;
    const sy0 = s.sy;
    s.n += 1;
    s.sx += x;
    s.sy += y;
    if (n0 > 0) {
        const tx = @mulAdd(f64, x, s.n, -s.sx);
        const ty = @mulAdd(f64, y, s.n, -s.sy);
        const scale = 1.0 / (s.n * n0);
        s.sxx = @mulAdd(f64, tx * tx, scale, s.sxx);
        s.syy = @mulAdd(f64, ty * ty, scale, s.syy);
        s.sxy = @mulAdd(f64, tx * ty, scale, s.sxy);
        if (isInf(s.sx) or isInf(s.sxx) or isInf(s.sy) or isInf(s.syy) or isInf(s.sxy)) {
            if (((isInf(s.sx) or isInf(s.sxx)) and !isInf(sx0) and !isInf(x)) or
                ((isInf(s.sy) or isInf(s.syy)) and !isInf(sy0) and !isInf(y)) or
                (isInf(s.sxy) and !isInf(sx0) and !isInf(x) and !isInf(sy0) and !isInf(y)))
                return overflow(ctx);
            if (isInf(s.sxx)) s.sxx = std.math.nan(f64);
            if (isInf(s.syy)) s.syy = std.math.nan(f64);
            if (isInf(s.sxy)) s.sxy = std.math.nan(f64);
        }
    } else {
        if (std.math.isNan(x) or isInf(x)) {
            s.sxx = std.math.nan(f64);
            s.sxy = std.math.nan(f64);
        }
        if (std.math.isNan(y) or isInf(y)) {
            s.syy = std.math.nan(f64);
            s.sxy = std.math.nan(f64);
        }
    }
}

const RegrKind = enum { corr, covar_pop, covar_samp, avgx, avgy, count, intercept, r2, slope, sxx, sxy, syy };

fn regrFinal(comptime k: RegrKind) dfunc.FinalFn {
    return struct {
        fn f(ctx: *Context) void {
            const s = dfunc.aggState(Regr, ctx, false) orelse
                return if (k == .count) api.resultInt64(ctx, 0) else api.resultNull(ctx);
            if (k == .count) return api.resultInt64(ctx, @intFromFloat(s.n));
            if (s.n < 1 or (k == .covar_samp and s.n < 2)) return api.resultNull(ctx);
            const r: f64 = switch (k) {
                .count => unreachable,
                .sxx => s.sxx,
                .syy => s.syy,
                .sxy => s.sxy,
                .avgx => s.sx / s.n,
                .avgy => s.sy / s.n,
                .covar_pop => s.sxy / s.n,
                .covar_samp => s.sxy / (s.n - 1),
                .corr => blk: {
                    if (s.sxx == 0 or s.syy == 0) return api.resultNull(ctx);
                    // sqrt(Sxx) * sqrt(Syy) where the product underflows
                    // or overflows; clamped to [-1, 1].
                    const product = s.sxx * s.syy;
                    const root = if (product == 0 or isInf(product)) @sqrt(s.sxx) * @sqrt(s.syy) else @sqrt(product);
                    break :blk std.math.clamp(s.sxy / root, -1, 1);
                },
                .r2 => blk: {
                    if (s.sxx == 0) return api.resultNull(ctx);
                    if (s.syy == 0) break :blk 1.0;
                    break :blk (s.sxy * s.sxy) / (s.sxx * s.syy);
                },
                .slope => blk: {
                    if (s.sxx == 0) return api.resultNull(ctx);
                    break :blk s.sxy / s.sxx;
                },
                .intercept => blk: {
                    if (s.sxx == 0) return api.resultNull(ctx);
                    break :blk (s.sy - s.sx * s.sxy / s.sxx) / s.n;
                },
            };
            api.resultDouble(ctx, r);
        }
    }.f;
}

// ============================================================ any_value

/// The value kept (a copy, freed with the state's Mem: anyFree()).
const Kept = struct { v: ?*Mem = null };

fn anyStep(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return;
    const st = dfunc.aggState(Kept, ctx, true) orelse return api.resultErrorNomem(ctx);
    if (st.v != null) return;
    st.v = api.valueDup(argv[0]) orelse return api.resultErrorNomem(ctx);
}

/// xValue: the value, kept (the frame of a window may still grow).
fn anyValue(ctx: *Context) void {
    const st = dfunc.aggState(Kept, ctx, false) orelse return api.resultNull(ctx);
    const v = st.v orelse return api.resultNull(ctx);
    api.resultValue(ctx, v);
}

fn anyFinal(ctx: *Context) void {
    const st = dfunc.aggState(Kept, ctx, false) orelse return api.resultNull(ctx);
    const v = st.v orelse return api.resultNull(ctx);
    api.resultValue(ctx, v);
    api.valueFree(v);
    st.v = null;
}

// ===================================================== sorted rows

/// Values kept by an aggregate, as copies (Mems of sqlite3_value_dup()),
/// in the order of the rows.
pub const Values = struct {
    items: ?[*]*Mem = null,
    len: usize = 0,
    cap: usize = 0,

    pub fn slice(s: *const Values) []*Mem {
        return if (s.items) |p| p[0..s.len] else &.{};
    }

    pub fn append(s: *Values, ctx: *Context, m: *Mem) bool {
        const gpa = dfunc.gpa(ctx);
        if (s.len == s.cap) {
            const n = @max(16, s.cap * 2);
            const grown = gpa.alloc(*Mem, n) catch return false;
            if (s.items) |p| {
                @memcpy(grown[0..s.len], p[0..s.len]);
                gpa.free(p[0..s.cap]);
            }
            s.items = grown.ptr;
            s.cap = n;
        }
        const v = api.valueDup(m) orelse return false;
        s.items.?[s.len] = v;
        s.len += 1;
        return true;
    }

    pub fn free(s: *Values, ctx: *Context) void {
        for (s.slice()) |v| api.valueFree(v);
        if (s.items) |p| dfunc.gpa(ctx).free(p[0..s.cap]);
        s.* = .{};
    }
};

/// The state of percentile_cont() and percentile_disc(): the fraction
/// (of the first row: a direct argument, the same for every row of the
/// group) and the values that are not NULL.
const Ordered = struct {
    fraction: ?*Mem = null,
    seen: bool = false,
    values: Values = .{},
    doubles: ?[*]f64 = null,
    n: usize = 0,
    cap: usize = 0,

    fn free(st: *Ordered, ctx: *Context) void {
        if (st.fraction) |f| api.valueFree(f);
        st.values.free(ctx);
        if (st.doubles) |p| dfunc.gpa(ctx).free(p[0..st.cap]);
        st.* = .{};
    }

    fn appendDouble(st: *Ordered, ctx: *Context, x: f64) bool {
        const gpa = dfunc.gpa(ctx);
        if (st.n == st.cap) {
            const n = @max(16, st.cap * 2);
            const grown = gpa.alloc(f64, n) catch return false;
            if (st.doubles) |p| {
                @memcpy(grown[0..st.n], p[0..st.n]);
                gpa.free(p[0..st.cap]);
            }
            st.doubles = grown.ptr;
            st.cap = n;
        }
        st.doubles.?[st.n] = x;
        st.n += 1;
        return true;
    }

    fn doubleSlice(st: *const Ordered) []f64 {
        return if (st.doubles) |p| p[0..st.n] else &.{};
    }
};

/// The step of the ordered-set aggregates (f, x): `doubles` keeps x as a
/// double (percentile_cont()), else a copy of the value.
fn orderedStep(ctx: *Context, argv: []*Mem, comptime doubles: bool) void {
    const st = dfunc.aggState(Ordered, ctx, true) orelse return api.resultErrorNomem(ctx);
    if (!st.seen) {
        st.seen = true;
        st.fraction = api.valueDup(argv[0]) orelse return api.resultErrorNomem(ctx);
    }
    if (isNull(argv[1])) return;
    const ok = if (doubles) st.appendDouble(ctx, api.valueDouble(argv[1])) else st.values.append(ctx, argv[1]);
    if (!ok) api.resultErrorNomem(ctx);
}

/// percentile_cont()'s step (`doubles`), also of the PostgreSQL arrays
/// of fractions (ordered.zig's).
pub fn contStep(ctx: *Context, argv: []*Mem) void {
    orderedStep(ctx, argv, true);
}

/// percentile_disc()'s step, also of the PostgreSQL arrays of fractions.
pub fn discStep(ctx: *Context, argv: []*Mem) void {
    orderedStep(ctx, argv, false);
}

/// The state of the ordered-set aggregates of a call, after its last row:
/// null if there were no rows that are not NULL (after the result is set
/// to NULL), else the state (freed by the caller) and its fraction.
pub const Group = struct {
    st: *Ordered,

    pub fn fraction(g: Group) ?*Mem {
        const f = g.st.fraction orelse return null;
        return if (isNull(f)) null else f;
    }

    pub fn doubles(g: Group) []f64 {
        return g.st.doubleSlice();
    }

    pub fn values(g: Group) []*Mem {
        return g.st.values.slice();
    }

    pub fn deinit(g: Group, ctx: *Context) void {
        g.st.free(ctx);
    }
};

/// The state of an ordered-set aggregate at its final call; null (and the
/// result NULL) if no row had a value.
pub fn finalGroup(ctx: *Context) ?Group {
    const st = dfunc.aggState(Ordered, ctx, false) orelse {
        api.resultNull(ctx);
        return null;
    };
    if (st.n == 0 and st.values.len == 0) {
        st.free(ctx);
        api.resultNull(ctx);
        return null;
    }
    return .{ .st = st };
}

/// PostgreSQL's check of a fraction: "percentile value 1.5 is not between
/// 0 and 1"; false after making it the error.
pub fn checkFraction(ctx: *Context, p: f64) bool {
    if (p >= 0 and p <= 1) return true;
    var buf: [96]u8 = undefined;
    var gb: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "percentile value {s} is not between 0 and 1", .{formatG(&gb, p)}) catch "percentile value is not between 0 and 1";
    api.resultErrorState(ctx, .of("22003"), msg);
    return false;
}

/// percentile_cont() of fraction `p` (checked) of the sorted doubles `xs`
/// (not empty): the value at p * (n - 1), interpolated (float8_lerp()).
pub fn contOf(xs: []const f64, p: f64) f64 {
    const pos = p * @as(f64, @floatFromInt(xs.len - 1));
    const first = @floor(pos);
    const second = @ceil(pos);
    const lo = xs[@intFromFloat(first)];
    if (first == second) return lo;
    const hi = xs[@intFromFloat(second)];
    const prop = pos - first;
    return lo + (hi - lo) * prop;
}

/// percentile_disc()'s row of fraction `p` (checked) of `n` (> 0) sorted
/// rows: the first whose position reaches p, 0-based.
pub fn discIndex(n: usize, p: f64) usize {
    const k: f64 = @ceil(p * @as(f64, @floatFromInt(n)));
    const r: usize = if (k > 1) @intFromFloat(k) else 1;
    return @min(r, n) - 1;
}

fn contFinal(ctx: *Context) void {
    const g = finalGroup(ctx) orelse return;
    defer g.deinit(ctx);
    const f = g.fraction() orelse return api.resultNull(ctx);
    const p = api.valueDouble(f);
    if (!checkFraction(ctx, p)) return;
    const xs = g.doubles();
    api.resultDouble(ctx, contOf(xs, p));
}

fn discFinal(ctx: *Context) void {
    const g = finalGroup(ctx) orelse return;
    defer g.deinit(ctx);
    const f = g.fraction() orelse return api.resultNull(ctx);
    const p = api.valueDouble(f);
    if (!checkFraction(ctx, p)) return;
    const vs = g.values();
    api.resultValue(ctx, vs[discIndex(vs.len, p)]);
}

/// C's "%g": 6 significant digits, trailing zeros dropped, in exponent
/// form below 1e-4 or from 1e6.
pub fn formatG(buf: *[32]u8, v: f64) []const u8 {
    if (std.math.isNan(v)) return "nan";
    if (std.math.isInf(v)) return if (v > 0) "inf" else "-inf";
    if (v == 0) return if (std.math.signbit(v)) "-0" else "0";
    var sci: [40]u8 = undefined;
    const z = std.fmt.bufPrint(&sci, "{e:.5}", .{v}) catch return "0";
    const e_at = std.mem.indexOfScalar(u8, z, 'e') orelse return "0";
    const exp = std.fmt.parseInt(i32, z[e_at + 1 ..], 10) catch 0;
    const neg = z[0] == '-';
    var digits: [8]u8 = undefined;
    var n: usize = 0;
    for (z[@intFromBool(neg)..e_at]) |c| {
        if (c == '.') continue;
        if (n < digits.len) {
            digits[n] = c;
            n += 1;
        }
    }
    while (n > 1 and digits[n - 1] == '0') n -= 1;
    var w: std.Io.Writer = .fixed(buf);
    if (neg) w.writeByte('-') catch {};
    if (exp < -4 or exp >= 6) {
        w.writeByte(digits[0]) catch {};
        if (n > 1) {
            w.writeByte('.') catch {};
            w.writeAll(digits[1..n]) catch {};
        }
        w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch {};
    } else if (exp < 0) {
        w.writeAll("0.") catch {};
        for (0..@intCast(-exp - 1)) |_| w.writeByte('0') catch {};
        w.writeAll(digits[0..n]) catch {};
    } else {
        const whole: usize = @intCast(exp + 1);
        for (0..whole) |i| w.writeByte(if (i < n) digits[i] else '0') catch {};
        if (n > whole) {
            w.writeByte('.') catch {};
            w.writeAll(digits[whole..n]) catch {};
        }
    }
    return w.buffered();
}

// ================================================================ mode

/// mode()'s state: the run of equal values so far and the most frequent
/// value before it.
const Mode = struct {
    cur: ?*Mem = null,
    run: u64 = 0,
    best: ?*Mem = null,
    best_n: u64 = 0,

    /// The run ends: it is the mode if longer than the best so far (the
    /// first of equal lengths stays).
    fn close(m: *Mode) void {
        const c = m.cur orelse return;
        if (m.run > m.best_n) {
            if (m.best) |b| api.valueFree(b);
            m.best = c;
            m.best_n = m.run;
        } else api.valueFree(c);
        m.cur = null;
        m.run = 0;
    }
};

fn modeStep(ctx: *Context, argv: []*Mem) void {
    if (isNull(argv[0])) return;
    const m = dfunc.aggState(Mode, ctx, true) orelse return api.resultErrorNomem(ctx);
    if (m.cur) |c| if (serial.memCompare(c, argv[0], null) == 0) {
        m.run += 1;
        return;
    };
    m.close();
    m.cur = api.valueDup(argv[0]) orelse return api.resultErrorNomem(ctx);
    m.run = 1;
}

fn modeFinal(ctx: *Context) void {
    const m = dfunc.aggState(Mode, ctx, false) orelse return api.resultNull(ctx);
    m.close();
    const b = m.best orelse return api.resultNull(ctx);
    api.resultValue(ctx, b);
    api.valueFree(b);
    m.* = .{};
}

// ======================================================= hypothetical

/// The state of the hypothetical-set aggregates: the rows, those before
/// the hypothetical row, those before or its peers; dense_rank()'s keeps
/// the values of the rows before it (to count them without duplicates).
const Hypo = struct {
    rows: i64 = 0,
    before: i64 = 0,
    not_after: i64 = 0,
    keys: Values = .{},
    width: usize = 0,
};

/// -1 if the row sorts before the hypothetical row, 0 if it is a peer, 1
/// after it (the order of the WITHIN GROUP's ORDER BY).
fn hypoCompare(argv: []*Mem) i32 {
    const flags = api.valueInt64(argv[0]);
    const cols = (argv.len - 1) / 4;
    for (0..cols) |i| {
        const h = argv[1 + 4 * i];
        const x = argv[2 + 4 * i];
        const desc = (flags >> @intCast(2 * i)) & 1 != 0;
        const nulls_first = (flags >> @intCast(2 * i + 1)) & 1 != 0;
        const hn = isNull(h);
        const xn = isNull(x);
        var c: i32 = 0;
        if (hn and xn) {
            c = 0;
        } else if (xn) {
            c = if (nulls_first) -1 else 1;
        } else if (hn) {
            c = if (nulls_first) 1 else -1;
        } else {
            const lt = argv[3 + 4 * i];
            const gt = argv[4 + 4 * i];
            if (!isNull(lt) and api.valueInt64(lt) != 0) {
                c = -1;
            } else if (!isNull(gt) and api.valueInt64(gt) != 0) {
                c = 1;
            }
            if (desc) c = -c;
        }
        if (c != 0) return c;
    }
    return 0;
}

fn hypoStep(comptime dense: bool) dfunc.StepFn {
    return struct {
        fn f(ctx: *Context, argv: []*Mem) void {
            hypoAdd(ctx, argv, dense);
        }
    }.f;
}

fn hypoAdd(ctx: *Context, argv: []*Mem, dense: bool) void {
    const st = dfunc.aggState(Hypo, ctx, true) orelse return api.resultErrorNomem(ctx);
    st.rows += 1;
    if (argv.len < 5 or (argv.len - 1) % 4 != 0) return api.resultError(ctx, "wrong number of arguments to xq_hypo_rank()");
    const c = hypoCompare(argv);
    if (c < 0) st.before += 1;
    if (c <= 0) st.not_after += 1;
    // dense_rank(): the row's values, if before.
    if (c < 0 and dense) {
        const cols = (argv.len - 1) / 4;
        st.width = cols;
        for (0..cols) |i| if (!st.keys.append(ctx, argv[2 + 4 * i])) return api.resultErrorNomem(ctx);
    }
}

const HypoKind = enum { rank, dense_rank, percent_rank, cume_dist };

fn hypoFinal(comptime k: HypoKind) dfunc.FinalFn {
    return struct {
        fn f(ctx: *Context) void {
            const st_opt = dfunc.aggState(Hypo, ctx, false);
            const st: Hypo = if (st_opt) |s| s.* else .{};
            defer if (st_opt) |s| {
                s.keys.free(ctx);
                s.* = .{};
            };
            switch (k) {
                .rank => api.resultInt64(ctx, st.before + 1),
                .percent_rank => api.resultDouble(ctx, if (st.rows == 0) 0 else @as(f64, @floatFromInt(st.before)) / @as(f64, @floatFromInt(st.rows))),
                .cume_dist => api.resultDouble(ctx, @as(f64, @floatFromInt(st.not_after + 1)) / @as(f64, @floatFromInt(st.rows + 1))),
                .dense_rank => {
                    const keys = st.keys.slice();
                    const w = st.width;
                    if (w == 0 or keys.len == 0) return api.resultInt64(ctx, 1);
                    // The distinct tuples of the rows before: sorted, then
                    // counted.
                    const n = keys.len / w;
                    const order = dfunc.gpa(ctx).alloc(usize, n) catch return api.resultErrorNomem(ctx);
                    defer dfunc.gpa(ctx).free(order);
                    for (order, 0..) |*o, i| o.* = i;
                    const Cmp = struct {
                        keys: []*Mem,
                        w: usize,
                        fn cmp(c: @This(), a: usize, b: usize) i32 {
                            for (0..c.w) |j| {
                                const r = serial.memCompare(c.keys[a * c.w + j], c.keys[b * c.w + j], null);
                                if (r != 0) return r;
                            }
                            return 0;
                        }
                        fn less(c: @This(), a: usize, b: usize) bool {
                            return c.cmp(a, b) < 0;
                        }
                    };
                    const cx: Cmp = .{ .keys = keys, .w = w };
                    std.sort.pdq(usize, order, cx, Cmp.less);
                    var distinct: i64 = 1;
                    for (order[1..], 0..) |o, i| {
                        if (cx.cmp(order[i], o) != 0) distinct += 1;
                    }
                    api.resultInt64(ctx, distinct + 1);
                },
            }
        }
    }.f;
}

test "stats: %g" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", formatG(&b, 1.5));
    try std.testing.expectEqualStrings("2", formatG(&b, 2));
    try std.testing.expectEqualStrings("-0.1", formatG(&b, -0.1));
    try std.testing.expectEqualStrings("1e+06", formatG(&b, 1e6));
    try std.testing.expectEqualStrings("1.23457e-05", formatG(&b, 1.234567e-5));
    try std.testing.expectEqualStrings("123457", formatG(&b, 123456.7));
}
