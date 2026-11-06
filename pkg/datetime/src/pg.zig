//! PostgreSQL's date, time, timestamp and interval text: the input
//! functions' syntax (an ISO date, a time, an offset; an interval's
//! units, a time, ISO 8601's P1DT2H), the output styles, and the
//! arithmetic of the values (a timestamp plus an interval adds months,
//! clamped to the end of the month, then days, then time). Days count
//! from 1970-01-01 and a timestamp is microseconds from its midnight, as
//! calendar.zig counts; an interval is interval.zig's.
//!
//! The PostgreSQL dialect's SQL functions of these values are
//! src/dialect/postgres/datetime.zig.

const std = @import("std");
const calendar = @import("calendar.zig");

pub const usecs_per_sec = ivl.usecs_per_sec;
pub const usecs_per_minute = ivl.usecs_per_minute;
pub const usecs_per_hour = ivl.usecs_per_hour;
pub const usecs_per_day = ivl.usecs_per_day;

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
/// BLOB (pkg/datetime/src/interval.zig).
pub const ivl = @import("interval.zig");
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
                .minute => usecs_per_minute,
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

/// AppendSeconds(): seconds `sec` (two digits with `fill`), their
/// fraction `fsec` (microseconds) without its trailing zeros.
fn putSeconds(o: *Out, sec: u64, fsec: u64, fill: bool) void {
    if (fill) o.print("{d:0>2}", .{sec}) else o.print("{d}", .{sec});
    if (fsec == 0) return;
    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{fsec}) catch unreachable;
    var n: usize = 6;
    while (n > 0 and digits[n - 1] == '0') n -= 1;
    o.print(".{s}", .{digits[0..n]});
}

fn putTime(o: *Out, us: u64) void {
    const h = us / @as(u64, usecs_per_hour);
    const m = us / 60_000_000 % 60;
    o.print("{d:0>2}:{d:0>2}:", .{ h, m });
    putSeconds(o, us / 1_000_000 % 60, us % 1_000_000, true);
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
    return formatIntervalStyle(iv, .postgres, buf);
}

pub const IntervalStyle = ivl.Style;

/// An interval's text in IntervalStyle `style` (interval_out():
/// EncodeInterval()), 'infinity' and '-infinity' for the infinities.
pub fn formatIntervalStyle(iv: Interval, style: IntervalStyle, buf: *Buf) []const u8 {
    if (iv.isPosInf()) return "infinity";
    if (iv.isNegInf()) return "-infinity";
    // interval2itm(): the fields, each of the sign of its value.
    const year: i64 = @divTrunc(iv.months, 12);
    const mon: i64 = @rem(iv.months, 12);
    const mday: i64 = iv.days;
    var t = iv.time;
    const hour: i64 = @divTrunc(t, usecs_per_hour);
    t -= hour * usecs_per_hour;
    const min: i64 = @divTrunc(t, ivl.usecs_per_minute);
    t -= min * ivl.usecs_per_minute;
    const sec: i64 = @divTrunc(t, ivl.usecs_per_sec);
    const fsec: i64 = t - sec * ivl.usecs_per_sec;
    var o: Out = .{ .buf = buf };
    switch (style) {
        .postgres => return formatInterval(iv, buf),
        .sql_standard => {
            const neg = year < 0 or mon < 0 or mday < 0 or hour < 0 or min < 0 or sec < 0 or fsec < 0;
            const pos = year > 0 or mon > 0 or mday > 0 or hour > 0 or min > 0 or sec > 0 or fsec > 0;
            const has_ym = year != 0 or mon != 0;
            const has_dt = mday != 0 or hour != 0 or min != 0 or sec != 0 or fsec != 0;
            // One sign before the whole value, if its fields allow it.
            const standard = !(neg and pos) and !(has_ym and has_dt);
            if (!neg and !pos) {
                o.print("0", .{});
            } else if (!standard) {
                // Every sign written: the fields' are mixed.
                const ys: u8 = if (year < 0 or mon < 0) '-' else '+';
                const ds: u8 = if (mday < 0) '-' else '+';
                const tsg: u8 = if (hour < 0 or min < 0 or sec < 0 or fsec < 0) '-' else '+';
                o.print("{c}{d}-{d} {c}{d} {c}{d}:{d:0>2}:", .{ ys, @abs(year), @abs(mon), ds, @abs(mday), tsg, @abs(hour), @abs(min) });
                putSeconds(&o, @abs(sec), @abs(fsec), true);
            } else {
                if (neg) o.print("-", .{});
                if (has_ym) {
                    o.print("{d}-{d}", .{ @abs(year), @abs(mon) });
                } else {
                    if (mday != 0) o.print("{d} ", .{@abs(mday)});
                    o.print("{d}:{d:0>2}:", .{ @abs(hour), @abs(min) });
                    putSeconds(&o, @abs(sec), @abs(fsec), true);
                }
            }
        },
        .iso_8601 => {
            if (year == 0 and mon == 0 and mday == 0 and iv.time == 0) return "PT0S";
            o.print("P", .{});
            isoPart(&o, year, 'Y');
            isoPart(&o, mon, 'M');
            isoPart(&o, mday, 'D');
            if (iv.time != 0) o.print("T", .{});
            isoPart(&o, hour, 'H');
            isoPart(&o, min, 'M');
            if (sec != 0 or fsec != 0) {
                if (sec < 0 or fsec < 0) o.print("-", .{});
                putSeconds(&o, @abs(sec), @abs(fsec), false);
                o.print("S", .{});
            }
        },
        .postgres_verbose => {
            o.print("@", .{});
            var zero = true;
            var before = false;
            const parts = [_]struct { i64, []const u8 }{ .{ year, "year" }, .{ mon, "mon" }, .{ mday, "day" }, .{ hour, "hour" }, .{ min, "min" } };
            // AddVerboseIntPart(): the first value's sign is "ago", the
            // later ones' relative to it.
            for (parts) |pt| {
                var v = pt[0];
                if (v == 0) continue;
                if (zero) {
                    before = v < 0;
                    if (v < 0) v = -v;
                } else if (before) v = -v;
                o.print(" {d} {s}{s}", .{ v, pt[1], if (v == 1) "" else "s" });
                zero = false;
            }
            if (sec != 0 or fsec != 0) {
                o.print(" ", .{});
                if (sec < 0 or (sec == 0 and fsec < 0)) {
                    if (zero) before = true else if (!before) o.print("-", .{});
                } else if (before) o.print("-", .{});
                putSeconds(&o, @abs(sec), @abs(fsec), false);
                o.print(" sec{s}", .{if (@abs(sec) != 1 or fsec != 0) "s" else ""});
                zero = false;
            }
            if (zero) o.print(" 0", .{});
            if (before) o.print(" ago", .{});
        },
    }
    return o.slice();
}

/// AddISO8601IntPart().
fn isoPart(o: *Out, v: i64, unit: u8) void {
    if (v != 0) o.print("{d}{c}", .{ v, unit });
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

test "intervals in each IntervalStyle (EncodeInterval())" {
    const cases = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        // input, postgres_verbose, sql_standard, iso_8601
        .{ "0", "@ 0", "0", "PT0S" },
        .{ "1 day 2 hours", "@ 1 day 2 hours", "1 2:00:00", "P1DT2H" },
        .{ "-1 day", "@ 1 day ago", "-1 0:00:00", "P-1D" },
        .{ "1 year 2 mons", "@ 1 year 2 mons", "1-2", "P1Y2M" },
        .{ "-1 years -2 mons", "@ 1 year 2 mons ago", "-1-2", "P-1Y-2M" },
        .{ "1 year 2 mons -3 days 4:05:06", "@ 1 year 2 mons -3 days 4 hours 5 mins 6 secs", "+1-2 -3 +4:05:06", "P1Y2M-3DT4H5M6S" },
        .{ "-1 years -2 mons +3 days -04:05:06", "@ 1 year 2 mons -3 days 4 hours 5 mins 6 secs ago", "-1-2 +3 -4:05:06", "P-1Y-2M3DT-4H-5M-6S" },
        .{ "-2:03:04.5", "@ 2 hours 3 mins 4.5 secs ago", "-2:03:04.5", "PT-2H-3M-4.5S" },
        .{ "1 day -1 sec", "@ 1 day -1 sec", "+0-0 +1 -0:00:01", "P1DT-1S" },
        .{ "-1 day 1 sec", "@ 1 day -1 sec ago", "+0-0 -1 +0:00:01", "P-1DT1S" },
        .{ "-0.5 sec", "@ 0.5 secs ago", "-0:00:00.5", "PT-0.5S" },
        .{ "1 sec", "@ 1 sec", "0:00:01", "PT1S" },
        .{ "1.5 sec", "@ 1.5 secs", "0:00:01.5", "PT1.5S" },
    };
    var buf: Buf = undefined;
    for (cases) |cs| {
        const iv = try parseInterval(cs[0]);
        try testing.expectEqualStrings(cs[1], formatIntervalStyle(iv, .postgres_verbose, &buf));
        try testing.expectEqualStrings(cs[2], formatIntervalStyle(iv, .sql_standard, &buf));
        try testing.expectEqualStrings(cs[3], formatIntervalStyle(iv, .iso_8601, &buf));
        try testing.expectEqualStrings(formatInterval(iv, &buf), formatIntervalStyle(iv, .postgres, &buf));
    }
    // The longest text fits the buffer.
    const most: Interval = .{ .months = std.math.maxInt(i32) - 1, .days = std.math.minInt(i32), .time = std.math.minInt(i64) + 1 };
    for (std.enums.values(IntervalStyle)) |st| _ = formatIntervalStyle(most, st, &buf);
    try testing.expectEqualStrings("infinity", formatIntervalStyle(Interval.infinity, .iso_8601, &buf));
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
