//! PostgreSQL's date, time, timestamp and interval values as the dialect
//! keeps them, and the arithmetic of their operators (the rows of
//! operators.zig that are engine functions).
//!
//! A value is stored as TEXT that sqlite3's date functions read (a date
//! '2024-01-02', a timestamp '2024-01-02 03:04:05', a timestamptz the
//! same in UTC without an offset, as now() is); an interval is
//! PostgreSQL's text of it in its default output style (IntervalStyle
//! postgres: '1 day', '1 day 02:00:00', '-1 mons', '3 years 2 mons'). The
//! functions read their arguments' text as PostgreSQL's input functions
//! do (an ISO date, a time, an offset; an interval's units, a time, ISO
//! 8601's P1DT2H) and write PostgreSQL's output:
//!  - a date plus or minus days is a date, the difference of two dates
//!    an integer;
//!  - a timestamp (a date as one at midnight) plus or minus an interval
//!    adds its months (clamped to the end of the month: Jan 31 plus a
//!    month is Feb 29), then its days, then its time; the difference of
//!    two timestamps is an interval of days and time (justify_hours());
//!  - a timestamptz is computed in UTC, the session's time zone (SET
//!    TIME ZONE is shown, not applied);
//!  - a time plus or minus an interval wraps around midnight;
//!  - intervals add field by field; an interval times or divided by a
//!    number cascades the fraction of months into days (of 30) and of
//!    days into time, as interval_mul() and interval_div() do.
//!
//! The text and the arithmetic are pkg/datetime's `pg`; this file is
//! their SQL functions.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const ivinput = @import("ivinput.zig");
const pgdt = @import("datetime").pg;

// What the dialect's other files use of pkg/datetime's pg.
pub const Buf = pgdt.Buf;
pub const Error = pgdt.Error;
pub const Interval = pgdt.Interval;
pub const IntervalStyle = pgdt.IntervalStyle;
pub const addInterval = pgdt.addInterval;
pub const checkTimestamp = pgdt.checkTimestamp;
pub const collateInterval = pgdt.collateInterval;
pub const formatDate = pgdt.formatDate;
pub const formatInterval = pgdt.formatInterval;
pub const formatIntervalPg = pgdt.formatIntervalPg;
pub const formatIntervalStyle = pgdt.formatIntervalStyle;
pub const formatTime = pgdt.formatTime;
pub const formatTimestamp = pgdt.formatTimestamp;
pub const parseDate = pgdt.parseDate;
pub const parseInterval = pgdt.parseInterval;
pub const parseTime = pgdt.parseTime;
pub const parseTimestamp = pgdt.parseTimestamp;
pub const usecs_per_day = pgdt.usecs_per_day;
pub const usecs_per_sec = pgdt.usecs_per_sec;

/// An interval's text in the session's IntervalStyle (`db`'s).
pub fn formatIntervalSession(db: *const int.Sqlite3, iv: Interval, buf: *Buf) []const u8 {
    return formatIntervalStyle(iv, @import("../valuetext.zig").Settings.of(db).interval, buf);
}

// ===================================================== the SQL functions

/// The operators' functions (operators.zig names them): PostgreSQL's
/// names of their implementations (date_pli, timestamp_pl_interval ...).
pub const Op = enum {
    date_pli,
    integer_pl_date,
    date_mii,
    date_mi,
    date_pl_interval,
    interval_pl_date,
    date_mi_interval,
    datetime_pl,
    timedate_pl,
    timestamp_pl_interval,
    interval_pl_timestamp,
    timestamp_mi_interval,
    timestamp_mi,
    timestamptz_pl_interval,
    interval_pl_timestamptz,
    timestamptz_mi_interval,
    timestamptz_mi,
    time_pl_interval,
    interval_pl_time,
    time_mi_interval,
    time_mi_time,
    interval_pl,
    interval_mi,
    interval_um,
    interval_mul,
    mul_d_interval,
    interval_div,

    /// The engine function's name: xq_pg_<op>; of an operator with an
    /// interval operand or result, the interval BLOBs' xq_pg_iv_<op>
    /// (legacyName() is the text intervals' xq_pg_<op>, which the
    /// schemas of older databases call).
    pub fn name(comptime o: Op) [:0]const u8 {
        return if (comptime o.ofInterval()) "xq_pg_iv_" ++ @tagName(o) else legacyName(o);
    }

    pub fn legacyName(comptime o: Op) [:0]const u8 {
        return "xq_pg_" ++ @tagName(o);
    }

    /// Whether an operand or the result is an interval.
    pub fn ofInterval(o: Op) bool {
        const ka, const kb, const kr = signature(o);
        return ka == .interval or kb == .interval or kr == .interval;
    }
};

const det: dfunc.Options = .{ .deterministic = true };

/// The casts (castFunc()), by name; date's ... also what a value stored
/// into a column of the type goes through (typing.Rules.store).
/// xq_pg_interval() is the cast of an interval stored as TEXT (an older
/// database's), xq_pg_iv() of a BLOB one.
const casts = struct {
    const interval = dfunc.scalar("xq_pg_interval", 1, det, dfunc.bind(castFunc, .{ Kind.interval, false }));
    const date = dfunc.scalar("xq_pg_date", 1, det, dfunc.bind(castFunc, .{ Kind.date, false }));
    const time = dfunc.scalar("xq_pg_time", 1, det, dfunc.bind(castFunc, .{ Kind.time, false }));
    const timestamp = dfunc.scalar("xq_pg_timestamp", 1, det, dfunc.bind(castFunc, .{ Kind.timestamp, false }));
    const timestamptz = dfunc.scalar("xq_pg_timestamptz", 1, det, dfunc.bind(castFunc, .{ Kind.timestamptz, false }));
    const iv = dfunc.scalar("xq_pg_iv", 1, det, dfunc.bind(castFunc, .{ Kind.interval, true }));
};
pub const cast_date = &casts.date;
/// xq_pg_iv_out(x): what an interval made text is (::text, ||, JSON ...).
pub const out_name = "xq_pg_iv_out";
pub const cast_time = &casts.time;
pub const cast_timestamp = &casts.timestamp;
pub const cast_timestamptz = &casts.timestamptz;

/// The functions of interval BLOBs besides the operators' (their names
/// are part of the ABI: docs/extension.md):
///   xq_pg_iv(x)          x (an interval's text or BLOB) as a BLOB: the cast,
///                        a value stored into a BLOB column
///   xq_pg_iv_text(x)     its text, in PostgreSQL's default output style
///   xq_pg_iv_out(x)      its text in the session's IntervalStyle (postgres
///                        outside an xqlite session: the extension's);
///                        stable: not deterministic (no index or generated
///                        column), the text of a constant made once a
///                        statement
///   xq_pg_iv_key(x)      its key (16 bytes): what = < ... GROUP BY compare
///   xq_pg_iv_high(x)     its key and 0xFF: above every interval of its length
///   xq_pg_iv_valid(x)    whether x is an interval's BLOB (a column's CHECK)
///   xq_pg_iv_sum(x)      sum() of intervals, also a window function
///   xq_pg_iv_avg(x)      avg()
pub const engine_functions = blk: {
    const ops = std.enums.values(Op);
    const fixed = [_]int.FuncDef{
        casts.interval,
        casts.date,
        casts.time,
        casts.timestamp,
        casts.timestamptz,
        casts.iv,
        dfunc.scalar("xq_pg_iv_text", 1, det, dfunc.bind(ivFunc, .{IvFn.text})),
        // Of the session (IntervalStyle): stable, as PostgreSQL's
        // interval_out() (a constant's text made once a statement).
        dfunc.scalar(out_name, 1, .{ .stable = true }, dfunc.bind(ivFunc, .{IvFn.out})),
        dfunc.scalar("xq_pg_iv_key", 1, det, dfunc.bind(ivFunc, .{IvFn.key})),
        dfunc.scalar("xq_pg_iv_high", 1, det, dfunc.bind(ivFunc, .{IvFn.high})),
        dfunc.scalar("xq_pg_iv_valid", 1, det, validFunc),
        windowAgg("xq_pg_iv_sum", sumStep, sumFinal, sumInverse),
        windowAgg("xq_pg_iv_avg", sumStep, avgFinal, sumInverse),
    };
    var n_iv: usize = 0;
    for (ops) |o| n_iv += @intFromBool(o.ofInterval());
    var defs: [fixed.len + ops.len + n_iv]int.FuncDef = undefined;
    for (fixed, 0..) |f, i| defs[i] = f;
    var i = fixed.len;
    for (ops) |o| {
        const n: i16 = if (o == .interval_um) 1 else 2;
        defs[i] = dfunc.scalar(o.legacyName(), n, det, dfunc.bind(opFunc, .{ o, false }));
        i += 1;
        if (o.ofInterval()) {
            defs[i] = dfunc.scalar(o.name(), n, det, dfunc.bind(opFunc, .{ o, true }));
            i += 1;
        }
    }
    break :blk defs;
};

/// The dialect's functions of intervals (Hooks.functions): their results
/// are BLOBs.
pub const functions = [_]int.FuncDef{
    dfunc.scalar("justify_hours", 1, det, dfunc.bind(ivFunc, .{IvFn.justify_hours})),
    dfunc.scalar("justify_days", 1, det, dfunc.bind(ivFunc, .{IvFn.justify_days})),
    dfunc.scalar("justify_interval", 1, det, dfunc.bind(ivFunc, .{IvFn.justify_interval})),
    dfunc.scalar("isfinite", 1, det, isfiniteFunc),
};

/// What a value stored into an older database's interval column (TEXT)
/// goes through (typing.Rules.store): an interval's text or BLOB as its
/// text; an infinity is out of range, as the text intervals' functions
/// and the collation xq_pg_interval do not read it. Called by code
/// generation, not by name: not an engine function.
pub const store_interval_text = dfunc.scalar("xq_pg_iv_store_text", 1, det, storeTextFunc);

fn storeTextFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    const iv = (arg(ctx, m, .interval, true) orelse return).iv;
    if (!iv.isFinite()) return result(ctx, error.IntervalRange);
    var buf: Buf = undefined;
    api.resultText(ctx, formatInterval(iv, &buf), .transient);
}

fn windowAgg(name: [:0]const u8, step: dfunc.StepFn, final: dfunc.FinalFn, inverse: dfunc.StepFn) int.FuncDef {
    var d = dfunc.aggregate(name, 1, det, step, final);
    d.x_value = final;
    d.x_inverse = inverse;
    return d;
}

const Context = dfunc.Context;
const Mem = dfunc.Mem;

/// What an argument is read as.
const Kind = enum {
    date,
    time,
    timestamp,
    timestamptz,
    interval,
    integer,
    float,

    fn typeName(k: Kind) []const u8 {
        return switch (k) {
            .date => "date",
            .time => "time",
            .timestamp => "timestamp",
            .timestamptz => "timestamp with time zone",
            .interval => "interval",
            .integer => "integer",
            .float => "double precision",
        };
    }
};

/// The value of an argument read as `k`.
const Value = union { i: i64, f: f64, iv: Interval };

/// The error of input `raw` read as `k` (`pg`: as the interval BLOBs'
/// functions read it, PostgreSQL 18's messages).
fn fail(ctx: *Context, err: Error, k: Kind, raw: []const u8, pg: bool) void {
    var buf: [160]u8 = undefined;
    const shown = raw[0..@min(raw.len, 64)];
    switch (err) {
        error.Syntax => {
            const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type {s}: \"{s}\"", .{ k.typeName(), shown }) catch "invalid input syntax";
            api.resultErrorState(ctx, if (k == .integer or k == .float) .of("22P02") else .of("22007"), msg);
        },
        error.FieldRange => {
            const msg = std.fmt.bufPrint(&buf, "date/time field value out of range: \"{s}\"", .{shown}) catch "date/time field value out of range";
            api.resultErrorState(ctx, .of("22008"), msg);
        },
        error.IntervalRange => if (pg and k == .interval) {
            const msg = std.fmt.bufPrint(&buf, "interval field value out of range: \"{s}\"", .{shown}) catch "interval field value out of range";
            api.resultErrorState(ctx, .of("22015"), msg);
        } else result(ctx, err),
        else => result(ctx, err),
    }
}

/// The error of a result out of range.
fn result(ctx: *Context, err: Error) void {
    switch (err) {
        error.DateRange => api.resultErrorState(ctx, .of("22008"), "date out of range"),
        error.TimestampRange => api.resultErrorState(ctx, .of("22008"), "timestamp out of range"),
        error.IntervalRange => api.resultErrorState(ctx, .of("22008"), "interval out of range"),
        error.DivisionByZero => api.resultErrorState(ctx, .of("22012"), "division by zero"),
        error.AddInfiniteToTime => api.resultErrorState(ctx, .of("22008"), "cannot add infinite interval to time"),
        error.SubInfiniteFromTime => api.resultErrorState(ctx, .of("22008"), "cannot subtract infinite interval from time"),
        error.Syntax, error.FieldRange => api.resultErrorState(ctx, .of("22007"), "invalid input syntax"),
    }
}

/// Argument `m` read as `k`; null after making the error the result.
/// With `pg` an interval is a BLOB or text (PostgreSQL 18's input), else
/// text only.
fn arg(ctx: *Context, m: *Mem, k: Kind, comptime pg: bool) ?Value {
    switch (k) {
        .integer => switch (api.valueType(m)) {
            vi.SQLITE_INTEGER => return .{ .i = api.valueInt64(m) },
            vi.SQLITE_FLOAT => {
                const r = @round(api.valueDouble(m));
                if (!(r >= -2147483648.0 and r <= 2147483647.0)) {
                    api.resultErrorState(ctx, .of("22003"), "integer out of range");
                    return null;
                }
                return .{ .i = @intFromFloat(r) };
            },
            else => {},
        },
        .float => switch (api.valueType(m)) {
            vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => return .{ .f = api.valueDouble(m) },
            else => {},
        },
        .interval => if (pg and api.valueType(m) == vi.SQLITE_BLOB) {
            const b = api.valueBlob(m) orelse &.{};
            const iv = pgdt.ivl.decode(b) orelse {
                api.resultErrorState(ctx, .of("22P03"), "invalid interval value");
                return null;
            };
            return .{ .iv = iv };
        },
        else => {},
    }
    const raw = dfunc.text(ctx, m) orelse return null;
    const v: Value = switch (k) {
        .date => .{ .i = parseDate(raw) catch |err| return failed(ctx, err, k, raw, pg) },
        .time => .{ .i = parseTime(raw) catch |err| return failed(ctx, err, k, raw, pg) },
        .timestamp => .{ .i = parseTimestamp(raw, false) catch |err| return failed(ctx, err, k, raw, pg) },
        .timestamptz => .{ .i = parseTimestamp(raw, true) catch |err| return failed(ctx, err, k, raw, pg) },
        .interval => .{ .iv = pgdt.parseIntervalOpts(raw, .{ .pg = pg }) catch |err| return failed(ctx, err, k, raw, pg) },
        .integer => blk: {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            const n = std.fmt.parseInt(i32, s, 10) catch |err| switch (err) {
                error.Overflow => {
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "value \"{s}\" is out of range for type integer", .{s[0..@min(s.len, 64)]}) catch "integer out of range";
                    api.resultErrorState(ctx, .of("22003"), msg);
                    return null;
                },
                error.InvalidCharacter => return failed(ctx, error.Syntax, k, raw, pg),
            };
            break :blk .{ .i = n };
        },
        .float => .{ .f = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r\n")) catch return failed(ctx, error.Syntax, k, raw, pg) },
    };
    return v;
}

/// The interval argument of the functions that take one (uuidv7(interval),
/// to_char() ...): PostgreSQL 18's input (ivinput.zig). Not the
/// operators' engine functions (arg()), which keep their meaning for the
/// schemas that call them.
pub const intervalArg = ivinput.intervalArg;

fn failed(ctx: *Context, err: Error, k: Kind, raw: []const u8, pg: bool) ?Value {
    fail(ctx, err, k, raw, pg);
    return null;
}

/// The kinds of the arguments of `o` and of its result.
fn signature(o: Op) struct { Kind, ?Kind, Kind } {
    return switch (o) {
        .date_pli, .date_mii => .{ .date, .integer, .date },
        .integer_pl_date => .{ .integer, .date, .date },
        .date_mi => .{ .date, .date, .integer },
        .date_pl_interval, .date_mi_interval => .{ .date, .interval, .timestamp },
        .interval_pl_date => .{ .interval, .date, .timestamp },
        .datetime_pl => .{ .date, .time, .timestamp },
        .timedate_pl => .{ .time, .date, .timestamp },
        .timestamp_pl_interval, .timestamp_mi_interval => .{ .timestamp, .interval, .timestamp },
        .interval_pl_timestamp => .{ .interval, .timestamp, .timestamp },
        .timestamp_mi => .{ .timestamp, .timestamp, .interval },
        .timestamptz_pl_interval, .timestamptz_mi_interval => .{ .timestamptz, .interval, .timestamptz },
        .interval_pl_timestamptz => .{ .interval, .timestamptz, .timestamptz },
        .timestamptz_mi => .{ .timestamptz, .timestamptz, .interval },
        .time_pl_interval, .time_mi_interval => .{ .time, .interval, .time },
        .interval_pl_time => .{ .interval, .time, .time },
        .time_mi_time => .{ .time, .time, .interval },
        .interval_pl, .interval_mi => .{ .interval, .interval, .interval },
        .interval_um => .{ .interval, null, .interval },
        .interval_mul, .interval_div => .{ .interval, .float, .interval },
        .mul_d_interval => .{ .float, .interval, .interval },
    };
}

/// Operator `o`: xq_pg_<op>() (text intervals) or, with `pg`,
/// xq_pg_iv_<op>() (BLOBs, PostgreSQL 18's arithmetic).
fn opFunc(ctx: *Context, argv: []*Mem, comptime o: Op, comptime pg: bool) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const ka, const kb, const kr = comptime signature(o);
    const a = arg(ctx, argv[0], ka, pg) orelse return;
    const b: Value = if (kb) |k| (arg(ctx, argv[1], k, pg) orelse return) else .{ .i = 0 };
    const r = compute(o, a, b, pg) catch |err| return result(ctx, err);
    var buf: Buf = undefined;
    const z = switch (kr) {
        .integer => return api.resultInt64(ctx, r.i),
        .date => formatDate(pgdt.checkDate(r.i) catch |err| return result(ctx, err), &buf),
        .timestamp, .timestamptz => formatTimestamp(r.i, &buf),
        .time => formatTime(r.i, &buf),
        .interval => if (pg) return resultInterval(ctx, r.iv) else formatInterval(r.iv, &buf),
        .float => unreachable,
    };
    api.resultText(ctx, z, .transient);
}

const resultInterval = ivinput.resultInterval;

fn compute(comptime o: Op, a: Value, b: Value, comptime pg: bool) Error!Value {
    const day = usecs_per_day;
    const rounding: Interval.Rounding = if (pg) .pg else .legacy;
    const neg = if (pg) Interval.neg else Interval.negLegacy;
    return switch (o) {
        .date_pli, .integer_pl_date => .{ .i = std.math.add(i64, a.i, b.i) catch return error.DateRange },
        .date_mii => .{ .i = std.math.sub(i64, a.i, b.i) catch return error.DateRange },
        .date_mi => .{ .i = a.i - b.i },
        .date_pl_interval => .{ .i = try addInterval(a.i * day, b.iv) },
        .interval_pl_date => .{ .i = try addInterval(b.i * day, a.iv) },
        .date_mi_interval => .{ .i = try addInterval(a.i * day, try neg(b.iv)) },
        .datetime_pl => .{ .i = try checkTimestamp(a.i * day + b.i) },
        .timedate_pl => .{ .i = try checkTimestamp(b.i * day + a.i) },
        .timestamp_pl_interval, .timestamptz_pl_interval => .{ .i = try addInterval(a.i, b.iv) },
        .interval_pl_timestamp, .interval_pl_timestamptz => .{ .i = try addInterval(b.i, a.iv) },
        .timestamp_mi_interval, .timestamptz_mi_interval => .{ .i = try addInterval(a.i, try neg(b.iv)) },
        .timestamp_mi, .timestamptz_mi => .{ .iv = try pgdt.diff(a.i, b.i) },
        .time_pl_interval => .{ .i = pgdt.addTime(a.i, (try finiteForTime(b.iv, pg, error.AddInfiniteToTime)).time) },
        .interval_pl_time => .{ .i = pgdt.addTime(b.i, (try finiteForTime(a.iv, pg, error.AddInfiniteToTime)).time) },
        .time_mi_interval => .{ .i = pgdt.addTime(a.i, -%(try finiteForTime(b.iv, pg, error.SubInfiniteFromTime)).time) },
        .time_mi_time => .{ .iv = .{ .time = a.i - b.i } },
        .interval_pl => .{ .iv = try if (pg) a.iv.add(b.iv) else a.iv.addLegacy(b.iv) },
        .interval_mi => .{ .iv = try if (pg) a.iv.sub(b.iv) else a.iv.subLegacy(b.iv) },
        .interval_um => .{ .iv = try neg(a.iv) },
        .interval_mul => .{ .iv = try a.iv.mul(b.f, rounding) },
        .mul_d_interval => .{ .iv = try b.iv.mul(a.f, rounding) },
        .interval_div => .{ .iv = try a.iv.div(b.f, rounding) },
    };
}

/// An interval a time is moved by: PostgreSQL 18's error for an infinite
/// one.
fn finiteForTime(iv: Interval, comptime pg: bool, err: Error) Error!Interval {
    if (pg and !iv.isFinite()) return err;
    return iv;
}

/// The casts to interval, date, time, timestamp and timestamptz
/// (xq_pg_interval(x) ...): the text of the value PostgreSQL's input
/// function reads, in its output style ('90 minutes' is '01:30:00',
/// '2024-01-02 03:04:05.50' is '2024-01-02 03:04:05.5', a timestamptz
/// in UTC); 'now', 'today', 'tomorrow', 'yesterday' and 'epoch' are the
/// statement's time, its day, ... With `pg` (xq_pg_iv(x)), an interval's
/// BLOB.
fn castFunc(ctx: *Context, argv: []*Mem, comptime k: Kind, comptime pg: bool) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    var buf: Buf = undefined;
    if (k != .interval) {
        const raw = dfunc.text(ctx, m) orelse return;
        if (special(ctx, raw)) |t| {
            const z = switch (k) {
                .date => formatDate(@divFloor(t, usecs_per_day), &buf),
                .time => formatTime(t, &buf),
                else => formatTimestamp(t, &buf),
            };
            return api.resultText(ctx, z, .transient);
        }
    }
    const v = arg(ctx, m, k, pg) orelse return;
    const z = switch (k) {
        .interval => if (pg) return resultInterval(ctx, v.iv) else formatInterval(v.iv, &buf),
        .date => formatDate(v.i, &buf),
        .time => formatTime(v.i, &buf),
        .timestamp, .timestamptz => formatTimestamp(v.i, &buf),
        else => unreachable,
    };
    api.resultText(ctx, z, .transient);
}

const IvFn = enum { text, out, key, high, justify_hours, justify_days, justify_interval };

/// A function of one interval (its text or BLOB): its text, its key ...
fn ivFunc(ctx: *Context, argv: []*Mem, comptime f: IvFn) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    const iv = (arg(ctx, m, .interval, true) orelse return).iv;
    switch (f) {
        .text => {
            var buf: Buf = undefined;
            api.resultText(ctx, formatIntervalPg(iv, &buf), .transient);
        },
        .out => {
            var buf: Buf = undefined;
            api.resultText(ctx, formatIntervalSession(api.contextDbHandle(ctx), iv, &buf), .transient);
        },
        .key => {
            const k = iv.key();
            api.resultBlob(ctx, &k, .transient);
        },
        .high => {
            const h = pgdt.ivl.highBound(iv);
            api.resultBlob(ctx, &h, .transient);
        },
        .justify_hours, .justify_days, .justify_interval => {
            const r = switch (f) {
                .justify_hours => iv.justifyHours(),
                .justify_days => iv.justifyDays(),
                else => iv.justifyInterval(),
            } catch |err| return result(ctx, err);
            resultInterval(ctx, r);
        },
    }
}

/// xq_pg_iv_valid(x): whether x is an interval's BLOB (NULL for NULL).
fn validFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    if (api.valueType(m) != vi.SQLITE_BLOB) return api.resultInt64(ctx, 0);
    api.resultInt64(ctx, @intFromBool(pgdt.ivl.valid(api.valueBlob(m) orelse &.{})));
}

/// isfinite(x): false for an infinite interval (a BLOB) and for the
/// text 'infinity' or '-infinity' (as an interval, a date or a
/// timestamp), true for any other value; NULL for NULL.
fn isfiniteFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    if (api.valueType(m) == vi.SQLITE_BLOB) {
        if (pgdt.ivl.decode(api.valueBlob(m) orelse &.{})) |iv| return api.resultInt64(ctx, @intFromBool(iv.isFinite()));
        return api.resultInt64(ctx, 1);
    }
    const raw = std.mem.trim(u8, dfunc.text(ctx, m) orelse return, " \t\r\n");
    const inf = std.ascii.eqlIgnoreCase(raw, "infinity") or std.ascii.eqlIgnoreCase(raw, "+infinity") or std.ascii.eqlIgnoreCase(raw, "-infinity");
    api.resultInt64(ctx, @intFromBool(!inf));
}

/// The state of sum() and avg() of intervals (PostgreSQL's
/// IntervalAggState): the sum of the finite values, how many there are,
/// how many infinities of each sign.
const SumState = struct {
    n: i64 = 0,
    sum: Interval = .{},
    pos_inf: i64 = 0,
    neg_inf: i64 = 0,
};

fn sumStep(ctx: *Context, argv: []*Mem) void {
    sumAccum(ctx, argv, false);
}

/// A row leaves the window frame: its value off the sum.
fn sumInverse(ctx: *Context, argv: []*Mem) void {
    sumAccum(ctx, argv, true);
}

fn sumAccum(ctx: *Context, argv: []*Mem, comptime inverse: bool) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return;
    const iv = (arg(ctx, m, .interval, true) orelse return).iv;
    const st = dfunc.aggState(SumState, ctx, true) orelse return api.resultErrorNomem(ctx);
    const d: i64 = if (inverse) -1 else 1;
    if (iv.isPosInf()) {
        st.pos_inf += d;
    } else if (iv.isNegInf()) {
        st.neg_inf += d;
    } else {
        st.sum = (if (inverse) st.sum.sub(iv) else st.sum.add(iv)) catch |err| return result(ctx, err);
        st.n += d;
    }
}

/// The sum so far (PostgreSQL's interval_sum()): NULL of no value, an
/// infinity of infinities of one sign, out of range of both.
fn sumOf(ctx: *Context) ?Interval {
    const st = dfunc.aggState(SumState, ctx, false) orelse {
        api.resultNull(ctx);
        return null;
    };
    if (st.n + st.pos_inf + st.neg_inf == 0) {
        api.resultNull(ctx);
        return null;
    }
    if (st.pos_inf > 0 and st.neg_inf > 0) {
        result(ctx, error.IntervalRange);
        return null;
    }
    if (st.pos_inf > 0) return Interval.infinity;
    if (st.neg_inf > 0) return Interval.neg_infinity;
    return st.sum;
}

fn sumFinal(ctx: *Context) void {
    resultInterval(ctx, sumOf(ctx) orelse return);
}

/// interval_avg(): the sum divided by the count of finite values.
fn avgFinal(ctx: *Context) void {
    const s = sumOf(ctx) orelse return;
    if (!s.isFinite()) return resultInterval(ctx, s);
    const st = dfunc.aggState(SumState, ctx, false).?;
    const r = s.div(@floatFromInt(st.n), .pg) catch |err| return result(ctx, err);
    resultInterval(ctx, r);
}

/// The time (microseconds since 1970, UTC) a special input word means.
fn special(ctx: *Context, raw: []const u8) ?i64 {
    const z = std.mem.trim(u8, raw, " \t\r\n");
    const words = [_][]const u8{ "now", "today", "tomorrow", "yesterday", "epoch" };
    const i = for (words, 0..) |w, i| {
        if (std.ascii.eqlIgnoreCase(z, w)) break i;
    } else return null;
    if (i == 4) return 0;
    // Julian day milliseconds to microseconds since 1970.
    const now = (api.stmtCurrentTime(ctx) - 210866760000000) * 1000;
    if (i == 0) return now;
    const day = @divFloor(now, usecs_per_day) * usecs_per_day;
    return switch (i) {
        1 => day,
        2 => day + usecs_per_day,
        else => day - usecs_per_day,
    };
}
