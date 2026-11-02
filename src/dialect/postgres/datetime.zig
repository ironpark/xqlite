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

const std = @import("std");
const calendar = @import("../calendar.zig");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");

pub const usecs_per_sec: i64 = 1_000_000;
pub const usecs_per_hour: i64 = 3600 * usecs_per_sec;
pub const usecs_per_day: i64 = 24 * usecs_per_hour;

pub const Error = error{
    /// Not the text of a value of the type.
    Syntax,
    /// A field out of its range (February 30, 25:00).
    FieldRange,
    DateRange,
    TimestampRange,
    IntervalRange,
    DivisionByZero,
    /// A time plus or minus an infinite interval.
    AddInfiniteToTime,
    SubInfiniteFromTime,
};

/// PostgreSQL's range of dates: 4713-01-01 BC (year -4712 counting a
/// year 0) to 5874897-12-31.
const min_date = calendar.daysFromCivil(-4712, 1, 1);
const max_date = calendar.daysFromCivil(5874897, 12, 31);
/// Of timestamps: from 4713-11-24 BC to 294276-12-31 in PostgreSQL;
/// here to 294246-12-31 (microseconds since 1970 in 64 bits).
const min_ts = calendar.daysFromCivil(-4713, 11, 24) * usecs_per_day;
const max_ts = (calendar.daysFromCivil(294246, 12, 31) + 1) * usecs_per_day - 1;

pub fn checkDate(d: i64) Error!i64 {
    if (d < min_date or d > max_date) return error.DateRange;
    return d;
}

pub fn checkTimestamp(t: i64) Error!i64 {
    if (t < min_ts or t > max_ts) return error.TimestampRange;
    return t;
}

/// An interval's months, days and microseconds, its arithmetic and its
/// BLOB (src/dialect/interval.zig).
pub const ivl = @import("../interval.zig");
pub const Interval = ivl.Interval;

// ============================================================ arithmetic

/// Timestamp `t` (microseconds since 1970-01-01) plus interval `iv`: its
/// months (the day clamped to the month's last), then its days, then its
/// time.
pub fn addInterval(t: i64, iv: Interval) Error!i64 {
    var x = t;
    if (iv.months != 0) {
        const days = @divFloor(x, usecs_per_day);
        const tod = x - days * usecs_per_day;
        const y, const m, const d = calendar.civilFromDays(days);
        const mon: i64 = @as(i64, m) - 1 + iv.months;
        const ny = y + @divFloor(mon, 12);
        const nm: u32 = @intCast(@mod(mon, 12) + 1);
        if (ny < -4713 or ny > 294247) return error.TimestampRange;
        const nd = @min(d, calendar.daysInMonth(ny, nm));
        x = calendar.daysFromCivil(ny, nm, nd) * usecs_per_day + tod;
    }
    if (iv.days != 0) x = std.math.add(i64, x, @as(i64, iv.days) * usecs_per_day) catch return error.TimestampRange;
    x = std.math.add(i64, x, iv.time) catch return error.TimestampRange;
    return checkTimestamp(x);
}

/// The difference of two timestamps: an interval of days and time.
pub fn diff(a: i64, b: i64) Error!Interval {
    const t = std.math.sub(i64, a, b) catch return error.IntervalRange;
    return (Interval{ .time = t }).justifyHours();
}

/// Time of day `t` plus `us` microseconds, around midnight.
pub fn addTime(t: i64, us: i64) i64 {
    return @mod(t +% @rem(us, usecs_per_day), usecs_per_day);
}

// ============================================================== parsing

const Scanner = struct {
    z: []const u8,
    i: usize = 0,

    fn peek(s: *const Scanner) u8 {
        return if (s.i < s.z.len) s.z[s.i] else 0;
    }

    fn eat(s: *Scanner, c: u8) bool {
        if (s.peek() != c) return false;
        s.i += 1;
        return true;
    }

    fn spaces(s: *Scanner) void {
        while (s.i < s.z.len and std.ascii.isWhitespace(s.z[s.i])) s.i += 1;
    }

    fn atEnd(s: *const Scanner) bool {
        return s.i >= s.z.len;
    }

    /// An unsigned number of 1 to `max` digits.
    fn digits(s: *Scanner, max: usize) ?i64 {
        const start = s.i;
        var v: i64 = 0;
        while (s.i < s.z.len and std.ascii.isDigit(s.z[s.i])) : (s.i += 1) {
            if (s.i - start >= max) return null;
            v = v * 10 + (s.z[s.i] - '0');
        }
        if (s.i == start) return null;
        return v;
    }

    /// A word of letters, lower case into `buf`.
    fn word(s: *Scanner, buf: []u8) []const u8 {
        var n: usize = 0;
        while (s.i < s.z.len and std.ascii.isAlphabetic(s.z[s.i])) : (s.i += 1) {
            if (n < buf.len) buf[n] = std.ascii.toLower(s.z[s.i]);
            n += 1;
        }
        return buf[0..@min(n, buf.len)];
    }

    /// The microseconds of a fraction after its point: up to 6 digits,
    /// rounded by the 7th (more are ignored).
    fn fraction(s: *Scanner) i64 {
        var v: i64 = 0;
        var n: usize = 0;
        var round_up = false;
        while (s.i < s.z.len and std.ascii.isDigit(s.z[s.i])) : (s.i += 1) {
            const dgt = s.z[s.i] - '0';
            if (n < 6) {
                v = v * 10 + dgt;
            } else if (n == 6) {
                round_up = dgt >= 5;
            }
            n += 1;
        }
        while (n < 6) : (n += 1) v *= 10;
        return v + @intFromBool(round_up);
    }

    fn ci(s: *Scanner, w: []const u8) bool {
        if (s.z.len - s.i < w.len or !std.ascii.eqlIgnoreCase(s.z[s.i..][0..w.len], w)) return false;
        if (s.i + w.len < s.z.len and std.ascii.isAlphabetic(s.z[s.i + w.len])) return false;
        s.i += w.len;
        return true;
    }
};

/// A time of day HH:MM[:SS[.ffffff]]: its microseconds.
fn timeOfDay(s: *Scanner) Error!i64 {
    const h = s.digits(2) orelse return error.Syntax;
    if (!s.eat(':')) return error.Syntax;
    const m = s.digits(2) orelse return error.Syntax;
    var sec: i64 = 0;
    var frac: i64 = 0;
    if (s.eat(':')) {
        sec = s.digits(2) orelse return error.Syntax;
        if (s.eat('.')) frac = s.fraction();
    } else if (s.eat('.')) {
        return error.Syntax;
    }
    if (m > 59 or sec > 60 or h > 24) return error.FieldRange;
    const t = ((h * 60 + m) * 60 + sec) * usecs_per_sec + frac;
    if (t > usecs_per_day) return error.FieldRange;
    return t;
}

/// A UTC offset: Z, +HH, +HH:MM, +HHMM, +HH:MM:SS; its seconds east.
fn offset(s: *Scanner) Error!?i64 {
    if (s.eat('Z') or s.eat('z')) return 0;
    const c = s.peek();
    if (c != '+' and c != '-') return null;
    s.i += 1;
    const start = s.i;
    var h = s.digits(4) orelse return error.Syntax;
    var m: i64 = 0;
    var sec: i64 = 0;
    if (s.i - start > 2) {
        // +HHMM
        m = @mod(h, 100);
        h = @divTrunc(h, 100);
    } else if (s.eat(':')) {
        m = s.digits(2) orelse return error.Syntax;
        if (s.eat(':')) sec = s.digits(2) orelse return error.Syntax;
    }
    if (h > 15 or m > 59 or sec > 59) return error.FieldRange;
    const v = (h * 60 + m) * 60 + sec;
    return if (c == '-') -v else v;
}

pub const DateTime = struct {
    /// The date written: days since 1970-01-01.
    days: i64,
    /// The time of day written, microseconds.
    tod: i64 = 0,
    /// The offset written (seconds east of UTC), if any.
    offset: ?i64 = null,

    /// Microseconds since 1970-01-01 00:00 of the local time written.
    pub fn local(d: DateTime) Error!i64 {
        const x = std.math.mul(i64, d.days, usecs_per_day) catch return error.TimestampRange;
        return std.math.add(i64, x, d.tod) catch error.TimestampRange;
    }

    /// As a timestamptz: in UTC.
    pub fn utc(d: DateTime) Error!i64 {
        return std.math.sub(i64, try d.local(), (d.offset orelse 0) * usecs_per_sec) catch error.TimestampRange;
    }
};

/// The text of a date or a timestamp: YYYY-MM-DD, then optionally a time
/// (after a space or a T) and an offset, and BC.
pub fn parseDateTime(z_in: []const u8) Error!DateTime {
    var s: Scanner = .{ .z = std.mem.trim(u8, z_in, " \t\r\n") };
    const y = s.digits(9) orelse return error.Syntax;
    if (!s.eat('-')) return error.Syntax;
    const m = s.digits(2) orelse return error.Syntax;
    if (!s.eat('-')) return error.Syntax;
    const d = s.digits(2) orelse return error.Syntax;
    var tod: i64 = 0;
    var off: ?i64 = null;
    var bc = false;
    if (s.eat('T') or s.eat('t')) {
        tod = try timeOfDay(&s);
    } else {
        const save = s.i;
        s.spaces();
        if (std.ascii.isDigit(s.peek())) {
            tod = try timeOfDay(&s);
        } else {
            s.i = save;
        }
    }
    s.spaces();
    if (s.ci("bc")) {
        bc = true;
        s.spaces();
    }
    off = try offset(&s);
    s.spaces();
    if (!bc and s.ci("bc")) {
        bc = true;
        s.spaces();
    }
    if (!s.atEnd()) return error.Syntax;
    if (y == 0 or m < 1 or m > 12) return error.FieldRange;
    const year = if (bc) 1 - y else y;
    if (d < 1 or d > calendar.daysInMonth(year, @intCast(m))) return error.FieldRange;
    return .{ .days = calendar.daysFromCivil(year, m, d), .tod = tod, .offset = off };
}

/// The text of a date: its days since 1970-01-01 (a timestamp's date).
pub fn parseDate(z: []const u8) Error!i64 {
    const dt = try parseDateTime(z);
    return checkDate(dt.days);
}

/// The text of a timestamp (`tz`: with time zone, in UTC).
pub fn parseTimestamp(z: []const u8, tz: bool) Error!i64 {
    const dt = try parseDateTime(z);
    return checkTimestamp(if (tz) try dt.utc() else try dt.local());
}

/// The text of a time: HH:MM[:SS[.f]] (an offset is ignored), or a
/// timestamp's time of day.
pub fn parseTime(z_in: []const u8) Error!i64 {
    const z = std.mem.trim(u8, z_in, " \t\r\n");
    var s: Scanner = .{ .z = z };
    if (timeOfDay(&s)) |t| {
        s.spaces();
        _ = offset(&s) catch return error.Syntax;
        s.spaces();
        if (s.atEnd()) return t;
    } else |err| if (err == error.FieldRange) return err;
    const dt = try parseDateTime(z);
    return dt.tod;
}

/// The fields of an interval as its text gives them, before they are an
/// Interval.
const Fields = struct {
    months: i64 = 0,
    days: i64 = 0,
    time: i64 = 0,

    /// The fraction `frac` (of the sign of its number) of a unit of
    /// `per_day` days: whole days, then time (AdjustFractDays()).
    fn fractDays(f: *Fields, frac: f64, per: f64) Error!void {
        if (frac == 0) return;
        const x = frac * per;
        const whole = @trunc(x);
        f.days = std.math.add(i64, f.days, try toI64(whole)) catch return error.IntervalRange;
        try f.fractTime(x - whole, usecs_per_day);
    }

    fn fractTime(f: *Fields, frac: f64, per: i64) Error!void {
        if (frac == 0) return;
        const x = frac * @as(f64, @floatFromInt(per));
        f.time = std.math.add(i64, f.time, try toI64(@round(x))) catch return error.IntervalRange;
    }
};

/// A float's integer, out of range beyond 64 bits.
fn toI64(v: f64) Error!i64 {
    if (!(v >= -0x1p63 and v < 0x1p63)) return error.IntervalRange;
    return @intFromFloat(v);
}

/// A number of an interval's text: its sign, whole part and fraction.
const Num = struct {
    neg: bool,
    whole: i64,
    frac: f64,
    /// Whether a point was written (1.5, 1.).
    point: bool,

    fn signedWhole(n: Num) i64 {
        return if (n.neg) -n.whole else n.whole;
    }

    fn signedFrac(n: Num) f64 {
        return if (n.neg) -n.frac else n.frac;
    }
};

fn number(s: *Scanner) Error!?Num {
    const save = s.i;
    var neg = false;
    if (s.eat('-')) {
        neg = true;
    } else _ = s.eat('+');
    const start = s.i;
    var whole: i64 = 0;
    while (s.i < s.z.len and std.ascii.isDigit(s.z[s.i])) : (s.i += 1) {
        whole = std.math.mul(i64, whole, 10) catch return error.IntervalRange;
        whole = std.math.add(i64, whole, s.z[s.i] - '0') catch return error.IntervalRange;
    }
    const had_digits = s.i > start;
    var frac: f64 = 0;
    var point = false;
    if (s.peek() == '.' and (had_digits or (s.i + 1 < s.z.len and std.ascii.isDigit(s.z[s.i + 1])))) {
        point = true;
        s.i += 1;
        var scale: f64 = 0.1;
        while (s.i < s.z.len and std.ascii.isDigit(s.z[s.i])) : (s.i += 1) {
            frac += @as(f64, @floatFromInt(s.z[s.i] - '0')) * scale;
            scale /= 10;
        }
    } else if (!had_digits) {
        s.i = save;
        return null;
    }
    return .{ .neg = neg, .whole = whole, .frac = frac, .point = point };
}

const Unit = enum { microsecond, millisecond, second, minute, hour, day, week, month, year, decade, century, millennium };

const units = std.StaticStringMap(Unit).initComptime(.{
    .{ "microsecond", .microsecond }, .{ "microseconds", .microsecond }, .{ "usec", .microsecond },         .{ "usecs", .microsecond },
    .{ "us", .microsecond },          .{ "millisecond", .millisecond },  .{ "milliseconds", .millisecond }, .{ "msec", .millisecond },
    .{ "msecs", .millisecond },       .{ "ms", .millisecond },           .{ "second", .second },            .{ "seconds", .second },
    .{ "sec", .second },              .{ "secs", .second },              .{ "s", .second },                 .{ "minute", .minute },
    .{ "minutes", .minute },          .{ "min", .minute },               .{ "mins", .minute },              .{ "m", .minute },
    .{ "hour", .hour },               .{ "hours", .hour },               .{ "hr", .hour },                  .{ "hrs", .hour },
    .{ "h", .hour },                  .{ "day", .day },                  .{ "days", .day },                 .{ "d", .day },
    .{ "week", .week },               .{ "weeks", .week },               .{ "w", .week },                   .{ "month", .month },
    .{ "months", .month },            .{ "mon", .month },                .{ "mons", .month },               .{ "year", .year },
    .{ "years", .year },              .{ "yr", .year },                  .{ "yrs", .year },                 .{ "y", .year },
    .{ "decade", .decade },           .{ "decades", .decade },           .{ "dec", .decade },               .{ "decs", .decade },
    .{ "century", .century },         .{ "centuries", .century },        .{ "cent", .century },             .{ "c", .century },
    .{ "millennium", .millennium },   .{ "millennia", .millennium },     .{ "mil", .millennium },           .{ "mils", .millennium },
});

fn apply(f: *Fields, u: Unit, n: Num) Error!void {
    const w = n.signedWhole();
    const fr = n.signedFrac();
    const ov = error.IntervalRange;
    switch (u) {
        .microsecond, .millisecond, .second, .minute, .hour => {
            const per: i64 = switch (u) {
                .microsecond => 1,
                .millisecond => 1000,
                .second => usecs_per_sec,
                .minute => 60 * usecs_per_sec,
                else => usecs_per_hour,
            };
            f.time = std.math.add(i64, f.time, std.math.mul(i64, w, per) catch return ov) catch return ov;
            try f.fractTime(fr, per);
        },
        .day => {
            f.days = std.math.add(i64, f.days, w) catch return ov;
            try f.fractTime(fr, usecs_per_day);
        },
        .week => {
            f.days = std.math.add(i64, f.days, std.math.mul(i64, w, 7) catch return ov) catch return ov;
            try f.fractDays(fr, 7);
        },
        .month => {
            f.months = std.math.add(i64, f.months, w) catch return ov;
            try f.fractDays(fr, 30);
        },
        .year, .decade, .century, .millennium => {
            const per: i64 = switch (u) {
                .year => 12,
                .decade => 120,
                .century => 1200,
                else => 12000,
            };
            f.months = std.math.add(i64, f.months, std.math.mul(i64, w, per) catch return ov) catch return ov;
            f.months = std.math.add(i64, f.months, try toI64(@round(fr * @as(f64, @floatFromInt(per))))) catch return ov;
        },
    }
}

/// How an interval's text is read.
pub const ParseOptions = struct {
    /// PostgreSQL 18's input (the interval BLOBs' functions): 'infinity'
    /// and '-infinity'; a number without a unit before a time is days
    /// ('-1 +02:03'); a unit given twice is an error ('1 sec 2 secs').
    /// Off: the text intervals' first functions, which keep their
    /// meaning.
    pg: bool = false,
};

/// The text of an interval: PostgreSQL's verbose input ('1 year 2 mons
/// 3 days 04:05:06', '@ 1 day ago', '1.5 hours', a bare number of
/// seconds) or ISO 8601's ('P1Y2M3DT4H5M6S').
pub fn parseInterval(z_in: []const u8) Error!Interval {
    return parseIntervalOpts(z_in, .{});
}

pub fn parseIntervalOpts(z_in: []const u8, opts: ParseOptions) Error!Interval {
    const z = std.mem.trim(u8, z_in, " \t\r\n");
    if (opts.pg) {
        if (std.ascii.eqlIgnoreCase(z, "infinity") or std.ascii.eqlIgnoreCase(z, "+infinity")) return Interval.infinity;
        if (std.ascii.eqlIgnoreCase(z, "-infinity")) return Interval.neg_infinity;
    }
    var s: Scanner = .{ .z = z };
    var f: Fields = .{};
    if (s.peek() == 'P' or s.peek() == 'p') {
        s.i += 1;
        try iso8601(&s, &f);
        return finish(f, false, opts);
    }
    _ = s.eat('@');
    var any = false;
    var ago = false;
    // The units given (opts.pg), by Unit, a time all of its units.
    var seen: u16 = 0;
    const time_mask: u16 = 1 << @backingInt(Unit.microsecond) | 1 << @backingInt(Unit.millisecond) | 1 << @backingInt(Unit.second) | 1 << @backingInt(Unit.minute) | 1 << @backingInt(Unit.hour);
    while (true) {
        s.spaces();
        if (s.atEnd()) break;
        if (s.ci("ago")) {
            s.spaces();
            if (!s.atEnd()) return error.Syntax;
            ago = true;
            break;
        }
        const n = try number(&s) orelse return error.Syntax;
        if (s.peek() == ':') {
            // A time: [-]H:MM[:SS[.f]] (hours may be more than 24).
            if (n.point) return error.Syntax;
            if (opts.pg) {
                if (seen & time_mask != 0) return error.Syntax;
                seen |= time_mask;
            }
            s.i += 1;
            const m = s.digits(2) orelse return error.Syntax;
            var sec: i64 = 0;
            var frac: i64 = 0;
            if (s.eat(':')) {
                sec = s.digits(2) orelse return error.Syntax;
                if (s.eat('.')) frac = s.fraction();
            } else if (s.eat('.')) {
                // MM:SS.f
                sec = m;
                frac = s.fraction();
                const ov = error.IntervalRange;
                const t0 = std.math.add(i64, std.math.mul(i64, n.whole, 60) catch return ov, sec) catch return ov;
                const t = std.math.add(i64, std.math.mul(i64, t0, usecs_per_sec) catch return ov, frac) catch return ov;
                f.time = std.math.add(i64, f.time, if (n.neg) -t else t) catch return ov;
                any = true;
                continue;
            }
            if (m > 59 or sec > 59) return error.FieldRange;
            const h = std.math.mul(i64, n.whole, usecs_per_hour) catch return error.IntervalRange;
            const t = std.math.add(i64, h, (m * 60 + sec) * usecs_per_sec + frac) catch return error.IntervalRange;
            f.time = std.math.add(i64, f.time, if (n.neg) -t else t) catch return error.IntervalRange;
            any = true;
            continue;
        }
        s.spaces();
        var buf: [16]u8 = undefined;
        const w = s.word(&buf);
        const u: Unit = if (w.len == 0) blk: {
            // A bare number: seconds, days before a time.
            if (opts.pg and timeNext(s)) break :blk .day;
            break :blk .second;
        } else units.get(w) orelse return error.Syntax;
        if (opts.pg) {
            const bit = @as(u16, 1) << @backingInt(u);
            if (seen & bit != 0) return error.Syntax;
            seen |= bit;
        }
        try apply(&f, u, n);
        any = true;
    }
    if (!any) return error.Syntax;
    return finish(f, ago, opts);
}

/// Whether a time ([-+]H:MM) follows at `s`.
fn timeNext(s_in: Scanner) bool {
    var s = s_in;
    s.spaces();
    if (s.peek() == '-' or s.peek() == '+') s.i += 1;
    if (s.digits(18) == null) return false;
    return s.peek() == ':';
}

fn iso8601(s: *Scanner, f: *Fields) Error!void {
    var time = false;
    var any = false;
    while (!s.atEnd()) {
        if (s.eat('T') or s.eat('t')) {
            time = true;
            continue;
        }
        const n = try number(s) orelse return error.Syntax;
        const c = std.ascii.toUpper(s.peek());
        s.i += 1;
        const u: Unit = if (time) switch (c) {
            'H' => .hour,
            'M' => .minute,
            'S' => .second,
            else => return error.Syntax,
        } else switch (c) {
            'Y' => .year,
            'M' => .month,
            'W' => .week,
            'D' => .day,
            else => return error.Syntax,
        };
        try apply(f, u, n);
        any = true;
    }
    if (!any) return error.Syntax;
}

fn finish(f: Fields, ago: bool, opts: ParseOptions) Error!Interval {
    const iv: Interval = .{
        .months = std.math.cast(i32, f.months) orelse return error.IntervalRange,
        .days = std.math.cast(i32, f.days) orelse return error.IntervalRange,
        .time = f.time,
    };
    const r = if (ago) try iv.negLegacy() else iv;
    // The fields of an infinity are not a finite interval's.
    if (opts.pg and !r.isFinite()) return error.IntervalRange;
    return r;
}

// ============================================================ formatting

/// Room for the text of any value.
pub const Buf = [96]u8;

const Out = struct {
    buf: []u8,
    n: usize = 0,

    fn print(o: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(o.buf[o.n..], fmt, args) catch unreachable;
        o.n += s.len;
    }

    fn slice(o: *const Out) []const u8 {
        return o.buf[0..o.n];
    }
};

fn putDate(o: *Out, days: i64) bool {
    const y, const m, const d = calendar.civilFromDays(days);
    const bc = y <= 0;
    const year: u64 = @intCast(if (bc) 1 - y else y);
    o.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ year, m, d });
    return bc;
}

/// Seconds and their fraction without trailing zeros (AppendSeconds()).
fn putSeconds(o: *Out, us: u64) void {
    const sec = us / 1_000_000;
    const frac = us % 1_000_000;
    o.print("{d:0>2}", .{sec});
    if (frac == 0) return;
    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch unreachable;
    var n: usize = 6;
    while (n > 0 and digits[n - 1] == '0') n -= 1;
    o.print(".{s}", .{digits[0..n]});
}

fn putTime(o: *Out, us: u64) void {
    const h = us / @as(u64, usecs_per_hour);
    const m = us / 60_000_000 % 60;
    o.print("{d:0>2}:{d:0>2}:", .{ h, m });
    putSeconds(o, us % 60_000_000);
}

pub fn formatDate(days: i64, buf: *Buf) []const u8 {
    var o: Out = .{ .buf = buf };
    if (putDate(&o, days)) o.print(" BC", .{});
    return o.slice();
}

/// A timestamp's text (a timestamptz's in UTC, without an offset).
pub fn formatTimestamp(t: i64, buf: *Buf) []const u8 {
    var o: Out = .{ .buf = buf };
    const days = @divFloor(t, usecs_per_day);
    const bc = putDate(&o, days);
    o.print(" ", .{});
    putTime(&o, @intCast(t - days * usecs_per_day));
    if (bc) o.print(" BC", .{});
    return o.slice();
}

pub fn formatTime(t: i64, buf: *Buf) []const u8 {
    var o: Out = .{ .buf = buf };
    putTime(&o, @intCast(@mod(t, usecs_per_day)));
    return o.slice();
}

/// An interval's text in PostgreSQL's default style (IntervalStyle
/// postgres): its years, months and days ("1 year", "2 mons", "-1 days"),
/// a field after a negative one with its sign ("-1 days +02:00:00"), then
/// the time if it is not zero or nothing else is.
pub fn formatInterval(iv: Interval, buf: *Buf) []const u8 {
    var o: Out = .{ .buf = buf };
    var zero = true;
    var before = false;
    const fields = [_]struct { i64, []const u8 }{
        .{ @divTrunc(iv.months, 12), "year" },
        .{ @rem(iv.months, 12), "mon" },
        .{ iv.days, "day" },
    };
    for (fields) |fd| {
        const v = fd[0];
        if (v == 0) continue;
        o.print("{s}{s}{d} {s}{s}", .{ if (zero) "" else " ", if (before and v > 0) "+" else "", v, fd[1], if (v != 1) "s" else "" });
        before = v < 0;
        zero = false;
    }
    if (zero or iv.time != 0) {
        const minus = iv.time < 0;
        o.print("{s}{s}", .{ if (zero) "" else " ", if (minus) "-" else if (before) "+" else "" });
        putTime(&o, @abs(iv.time));
    }
    return o.slice();
}

/// An interval's text as PostgreSQL 18 writes it: formatInterval()'s,
/// 'infinity' and '-infinity' for the infinities.
pub fn formatIntervalPg(iv: Interval, buf: *Buf) []const u8 {
    if (iv.isPosInf()) return "infinity";
    if (iv.isNegInf()) return "-infinity";
    return formatInterval(iv, buf);
}

/// The collation xq_pg_interval: intervals in PostgreSQL's order, a
/// month 30 days and a day 24 hours ('1 mon' is '30 days',
/// interval_cmp()); text that is no interval in byte order.
pub fn collateInterval(_: ?*anyopaque, x: []const u8, y: []const u8) std.math.Order {
    if (std.mem.eql(u8, x, y)) return .eq;
    const a = parseInterval(x) catch return std.mem.order(u8, x, y);
    const b = parseInterval(y) catch return std.mem.order(u8, x, y);
    return std.math.order(span(a), span(b));
}

fn span(iv: Interval) i128 {
    return (@as(i128, iv.months) * 30 + iv.days) * usecs_per_day + iv.time;
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

/// The casts (castFunc()), also what a value stored into a column of
/// the type goes through (typing.Rules.store): of an interval column
/// stored as TEXT (an older database's) the text, of a BLOB one
/// (cast_iv) the BLOB.
pub const cast_interval = &engine_functions[0];
pub const cast_date = &engine_functions[1];
pub const cast_time = &engine_functions[2];
pub const cast_timestamp = &engine_functions[3];
pub const cast_timestamptz = &engine_functions[4];
pub const cast_iv = &engine_functions[5];

/// The functions of interval BLOBs besides the operators' (their names
/// are part of the ABI: docs/extension.md):
///   xq_pg_iv(x)          x (an interval's text or BLOB) as a BLOB: the cast,
///                        a value stored into a BLOB column
///   xq_pg_iv_text(x)     its text, in PostgreSQL's default output style
///   xq_pg_iv_key(x)      its key (16 bytes): what = < ... GROUP BY compare
///   xq_pg_iv_high(x)     its key and 0xFF: above every interval of its length
///   xq_pg_iv_valid(x)    whether x is an interval's BLOB (a column's CHECK)
///   xq_pg_iv_sum(x)      sum() of intervals, also a window function
///   xq_pg_iv_avg(x)      avg()
pub const engine_functions = blk: {
    const ops = std.enums.values(Op);
    const fixed = [_]int.FuncDef{
        dfunc.scalar("xq_pg_interval", 1, det, dfunc.bind(castFunc, .{ Kind.interval, false })),
        dfunc.scalar("xq_pg_date", 1, det, dfunc.bind(castFunc, .{ Kind.date, false })),
        dfunc.scalar("xq_pg_time", 1, det, dfunc.bind(castFunc, .{ Kind.time, false })),
        dfunc.scalar("xq_pg_timestamp", 1, det, dfunc.bind(castFunc, .{ Kind.timestamp, false })),
        dfunc.scalar("xq_pg_timestamptz", 1, det, dfunc.bind(castFunc, .{ Kind.timestamptz, false })),
        dfunc.scalar("xq_pg_iv", 1, det, dfunc.bind(castFunc, .{ Kind.interval, true })),
        dfunc.scalar("xq_pg_iv_text", 1, det, dfunc.bind(ivFunc, .{IvFn.text})),
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
            const iv = ivl.decode(b) orelse {
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
        .interval => .{ .iv = parseIntervalOpts(raw, .{ .pg = pg }) catch |err| return failed(ctx, err, k, raw, pg) },
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

/// The interval argument `m` is, an interval's BLOB or its text (an
/// older database's TEXT column, a string): its months, days and
/// microseconds; null after making the error (PostgreSQL's input
/// messages) the result. For the functions that take an interval
/// (uuidv7(interval) ...). `m` is not NULL.
pub fn intervalArg(ctx: *Context, m: *Mem) ?Interval {
    return (arg(ctx, m, .interval, true) orelse return null).iv;
}

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
        .date => formatDate(checkDate(r.i) catch |err| return result(ctx, err), &buf),
        .timestamp, .timestamptz => formatTimestamp(r.i, &buf),
        .time => formatTime(r.i, &buf),
        .interval => if (pg) return resultInterval(ctx, r.iv) else formatInterval(r.iv, &buf),
        .float => unreachable,
    };
    api.resultText(ctx, z, .transient);
}

fn resultInterval(ctx: *Context, iv: Interval) void {
    const b = iv.encode();
    api.resultBlob(ctx, &b, .transient);
}

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
        .timestamp_mi, .timestamptz_mi => .{ .iv = try diff(a.i, b.i) },
        .time_pl_interval => .{ .i = addTime(a.i, (try finiteForTime(b.iv, pg, error.AddInfiniteToTime)).time) },
        .interval_pl_time => .{ .i = addTime(b.i, (try finiteForTime(a.iv, pg, error.AddInfiniteToTime)).time) },
        .time_mi_interval => .{ .i = addTime(a.i, -%(try finiteForTime(b.iv, pg, error.SubInfiniteFromTime)).time) },
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

const IvFn = enum { text, key, high, justify_hours, justify_days, justify_interval };

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
        .key => {
            const k = iv.key();
            api.resultBlob(ctx, &k, .transient);
        },
        .high => {
            const h = ivl.highBound(iv);
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
    api.resultInt64(ctx, @intFromBool(ivl.valid(api.valueBlob(m) orelse &.{})));
}

/// isfinite(x): false for an infinite interval (a BLOB) and for the
/// text 'infinity' or '-infinity' (as an interval, a date or a
/// timestamp), true for any other value; NULL for NULL.
fn isfiniteFunc(ctx: *Context, argv: []*Mem) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    if (api.valueType(m) == vi.SQLITE_BLOB) {
        if (ivl.decode(api.valueBlob(m) orelse &.{})) |iv| return api.resultInt64(ctx, @intFromBool(iv.isFinite()));
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

// ================================================================ tests

const testing = std.testing;

fn expectInterval(input: []const u8, want: []const u8) !void {
    var buf: Buf = undefined;
    const iv = parseInterval(input) catch |err| {
        std.debug.print("{s}: {t}\n", .{ input, err });
        return err;
    };
    try testing.expectEqualStrings(want, formatInterval(iv, &buf));
}

test "intervals read and written as PostgreSQL does" {
    try expectInterval("1 day", "1 day");
    try expectInterval("2 days", "2 days");
    try expectInterval("1 day 2 hours", "1 day 02:00:00");
    try expectInterval("-1 month", "-1 mons");
    try expectInterval("38 months", "3 years 2 mons");
    try expectInterval("1 year 2 months 3 days 04:05:06.5", "1 year 2 mons 3 days 04:05:06.5");
    try expectInterval("-1 day +1 hour", "-1 days +01:00:00");
    try expectInterval("1 day -1 hour", "1 day -01:00:00");
    try expectInterval("0", "00:00:00");
    try expectInterval("10", "00:00:10");
    try expectInterval("90 minutes", "01:30:00");
    try expectInterval("1.5 days", "1 day 12:00:00");
    try expectInterval("1.5 months", "1 mon 15 days");
    try expectInterval("1.5 years", "1 year 6 mons");
    try expectInterval("2 weeks", "14 days");
    try expectInterval("@ 1 day ago", "-1 days");
    try expectInterval("1 day ago", "-1 days");
    try expectInterval("25:00:00", "25:00:00");
    try expectInterval("-01:30", "-01:30:00");
    try expectInterval("1 Day 1 MIN", "1 day 00:01:00");
    try expectInterval("3 mons", "3 mons");
    try expectInterval("1 mon", "1 mon");
    try expectInterval("1ms", "00:00:00.001");
    try expectInterval("P1Y2M3DT4H5M6S", "1 year 2 mons 3 days 04:05:06");
    try expectInterval("-1 years -2 mons", "-1 years -2 mons");
    try expectInterval("-1 years 2 mons", "-10 mons");
    try expectInterval("-1 mons 2 days", "-1 mons +2 days");
    try testing.expectError(error.Syntax, parseInterval("abc"));
    try testing.expectError(error.Syntax, parseInterval(""));
    try testing.expectError(error.Syntax, parseInterval("1 fortnight"));
}

test "interval arithmetic" {
    var buf: Buf = undefined;
    const day = try parseInterval("1 day");
    try testing.expectEqualStrings("2 days", formatInterval(try day.mul(2, .legacy), &buf));
    try testing.expectEqualStrings("08:00:00", formatInterval(try day.div(3, .legacy), &buf));
    try testing.expectEqualStrings("15 days", formatInterval(try (try parseInterval("1 month")).div(2, .legacy), &buf));
    try testing.expectEqualStrings("01:30:00", formatInterval(try (try parseInterval("1 hour")).mul(1.5, .legacy), &buf));
    try testing.expectEqualStrings("1 mon 15 days", formatInterval(try (try parseInterval("1 month")).mul(1.5, .legacy), &buf));
    try testing.expectEqualStrings("1 day -02:00:00", formatInterval(try day.subLegacy(try parseInterval("2 hours")), &buf));
    try testing.expectEqualStrings("-1 days", formatInterval(try day.negLegacy(), &buf));
    try testing.expectError(error.DivisionByZero, day.div(0, .legacy));
    try testing.expectEqual(std.math.Order.eq, collateInterval(null, "1 mon", "30 days"));
    try testing.expectEqual(std.math.Order.gt, collateInterval(null, "1 day", "02:00:00"));
    try testing.expectEqual(std.math.Order.lt, collateInterval(null, "-1 days", "00:00:00"));
}

fn ts(z: []const u8) !i64 {
    return parseTimestamp(z, false);
}

test "timestamps and dates" {
    var buf: Buf = undefined;
    try testing.expectEqualStrings("2024-02-29 00:00:00", formatTimestamp(try addInterval(try ts("2024-01-31"), try parseInterval("1 month")), &buf));
    try testing.expectEqualStrings("2023-02-28 00:00:00", formatTimestamp(try addInterval(try ts("2023-01-31"), try parseInterval("1 month")), &buf));
    try testing.expectEqualStrings("2024-03-01 10:00:00", formatTimestamp(try addInterval(try ts("2024-01-31 10:00"), try parseInterval("1 month 1 day")), &buf));
    try testing.expectEqualStrings("2023-12-31 23:00:00", formatTimestamp(try addInterval(try ts("2024-01-01"), try parseInterval("-1 hour")), &buf));
    try testing.expectEqualStrings("2024-02-29 00:00:00", formatTimestamp(try addInterval(try ts("2024-05-31"), try parseInterval("-3 mons")), &buf));
    try testing.expectEqualStrings("2024-01-01 10:00:00.25", formatTimestamp(try ts("2024-01-01T10:00:00.250Z"), &buf));
    try testing.expectEqualStrings("1 day 02:00:00", formatInterval(try diff(try ts("2024-01-02 02:00"), try ts("2024-01-01")), &buf));
    try testing.expectEqualStrings("-1 days -02:00:00", formatInterval(try diff(try ts("2024-01-01"), try ts("2024-01-02 02:00")), &buf));
    try testing.expectEqualStrings("23:00:00", formatInterval(try diff(try ts("2024-01-02 00:00"), try ts("2024-01-01 01:00")), &buf));
    // A timestamptz in UTC.
    try testing.expectEqualStrings("2024-01-01 08:00:00", formatTimestamp(try parseTimestamp("2024-01-01 10:00:00+02", true), &buf));
    try testing.expectEqualStrings("2024-01-01 15:30:00", formatTimestamp(try parseTimestamp("2024-01-01 10:00:00-05:30", true), &buf));
    try testing.expectEqualStrings("2024-01-01 10:00:00", formatTimestamp(try parseTimestamp("2024-01-01 10:00:00+02", false), &buf));
    try testing.expectEqualStrings("0044-03-15 BC", formatDate(try parseDate("0044-03-15 BC"), &buf));
    try testing.expectEqualStrings("2024-01-02", formatDate(try parseDate("2024-01-02 10:00:00"), &buf));
    try testing.expectError(error.FieldRange, parseDate("2023-02-29"));
    try testing.expectError(error.Syntax, parseDate("yesterday"));
    try testing.expectError(error.DateRange, checkDate(max_date + 1));
    try testing.expectEqualStrings("01:00:00", formatTime(addTime(try parseTime("23:00"), 2 * usecs_per_hour), &buf));
    try testing.expectEqualStrings("10:11:12", formatTime(try parseTime("2024-01-01 10:11:12"), &buf));
}
