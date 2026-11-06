//! PostgreSQL 18's interval input and the functions of intervals that
//! read fields (src/backend/utils/adt/datetime.c, timestamp.c):
//!
//!  - decode(): interval_in() — ParseDateTime() splits the text into
//!    fields, DecodeInterval() reads them right to left (a unit before its
//!    number, a number without one by the field of the type modifier:
//!    `interval '1' year`, after an hour or a time a day), then
//!    DecodeISO8601Interval() if that was no interval ('P1Y2M',
//!    'P0001-02-03T04:05:06'); the fields gathered as years, months,
//!    days and microseconds that may each overflow ("interval field value
//!    out of range"), then made one interval ("interval out of range");
//!  - adjust(): AdjustIntervalForTypmod() — the fields after the last
//!    one of the type modifier zeroed (`interval day to hour`), the
//!    fraction of a second rounded to its precision (`interval(2)`,
//!    `second(3)`);
//!  - the type modifier is PostgreSQL's (INTERVAL_TYPMOD(): the range
//!    mask in the high 16 bits, the precision in the low ones; -1 none),
//!    what pg_attribute.atttypmod shows;
//!  - extract(): interval_part_common() — EXTRACT (numeric) and
//!    date_part() (double precision) of an interval.
//!
//! The engine functions (their names are part of the ABI:
//! docs/extension.md):
//!   xq_pg_iv_in(x, typmod)       x (text or an interval's BLOB) as an interval
//!                                BLOB of type modifier typmod (-1: none)
//!   xq_pg_iv_in(x, typmod, 1)    the same, a leading '-' read as IntervalStyle
//!                                sql_standard reads it (a cast compiled in
//!                                such a session)
//!   xq_pg_iv_extract(field, x)   EXTRACT(field FROM x): a numeric key
//!   xq_pg_iv_date_part(field, x) date_part(field, x): a double
//! The dialect's make_interval(years, months, weeks, days, hours, mins,
//! secs) takes all seven arguments (the parser fills in the defaults of
//! those not given, by name or by position).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const ivl = @import("datetime").interval;
const decimal = @import("decimal");

const Interval = ivl.Interval;
const Context = dfunc.Context;
const Mem = dfunc.Mem;

const usecs_per_sec = ivl.usecs_per_sec;
const usecs_per_minute = ivl.usecs_per_minute;
const usecs_per_hour = ivl.usecs_per_hour;
const usecs_per_day = ivl.usecs_per_day;

pub const Error = error{
    /// Not an interval's text ("invalid input syntax for type interval").
    Syntax,
    /// A field out of its range ("interval field value out of range").
    FieldOverflow,
    /// The result out of range ("interval out of range").
    IntervalRange,
};

// ------------------------------------------------------- type modifier

/// The bits of the fields of a type modifier's range (INTERVAL_MASK()).
pub const month: i32 = 1 << 1;
pub const year: i32 = 1 << 2;
pub const day: i32 = 1 << 3;
pub const hour: i32 = 1 << 10;
pub const minute: i32 = 1 << 11;
pub const second: i32 = 1 << 12;
pub const full_range: i32 = 0x7FFF;
pub const full_precision: i32 = 0xFFFF;
pub const max_precision: i32 = 6;

/// INTERVAL_TYPMOD(precision, range).
pub fn typmod(range: i32, precision: i32) i32 {
    return ((range & 0x7FFF) << 16) | (precision & 0xFFFF);
}

fn rangeOf(tm: i32) i32 {
    return if (tm < 0) full_range else (tm >> 16) & 0x7FFF;
}

fn precisionOf(tm: i32) i32 {
    return if (tm < 0) full_precision else tm & 0xFFFF;
}

/// The ranges of fields PostgreSQL's grammar (opt_interval) takes, by
/// their text: rangeOfFields() reads one, typmodText() writes it.
const range_names = [_]struct { i32, []const u8 }{
    .{ year, "year" },                                  .{ month, "month" },                  .{ day, "day" },
    .{ hour, "hour" },                                  .{ minute, "minute" },                .{ second, "second" },
    .{ year | month, "year to month" },                 .{ day | hour, "day to hour" },       .{ day | hour | minute, "day to minute" },
    .{ day | hour | minute | second, "day to second" }, .{ hour | minute, "hour to minute" }, .{ hour | minute | second, "hour to second" },
    .{ minute | second, "minute to second" },
};

/// The range of the fields written `a TO b` or `a` (b empty), as
/// PostgreSQL's grammar (opt_interval) takes them; null for another.
pub fn rangeOfFields(a: []const u8, b: []const u8) ?i32 {
    for (range_names) |r| {
        const n = r[1];
        const match = if (b.len == 0)
            std.mem.eql(u8, n, a)
        else
            n.len == a.len + " to ".len + b.len and std.mem.startsWith(u8, n, a) and
                std.mem.eql(u8, n[a.len..][0..4], " to ") and std.mem.endsWith(u8, n, b);
        if (match) return r[0];
    }
    return null;
}

/// The range of fields written as text `fields` (lower case: "year",
/// "day to second"; full_range for ""), null for another text.
pub fn rangeOfText(fields: []const u8) ?i32 {
    var it = std.mem.tokenizeScalar(u8, fields, ' ');
    const a = it.next() orelse return full_range;
    const to = it.next() orelse return rangeOfFields(a, "");
    if (!std.mem.eql(u8, to, "to")) return null;
    const b = it.next() orelse return null;
    if (it.next() != null) return null;
    return rangeOfFields(a, b);
}

/// The type modifier of fields `range` (full_range: none given) and
/// declared precision `precision` (null: none), -1 for neither: the
/// precision clamped to 0 ... 6 as intervaltypmodin() does ("interval(7)
/// precision reduced to maximum allowed, 6"). What the cast, a column's
/// store and pg_attribute.atttypmod all take.
pub fn typmodOf(range: i32, precision: ?i64) i32 {
    const p: i32 = if (precision) |v| @intCast(std.math.clamp(v, 0, max_precision)) else full_precision;
    if (range == full_range and p == full_precision) return -1;
    return typmod(range, p);
}

/// The type modifier of a declared type's text ("interval", "interval
/// year to month", "interval(2)", "interval day to second(3)"), -1 for
/// none or another type.
pub fn typmodOfDecl(decl_arg: []const u8) i32 {
    const decl = std.mem.trim(u8, decl_arg, " ");
    if (decl.len < 8 or !std.ascii.eqlIgnoreCase(decl[0..8], "interval")) return -1;
    var rest = std.mem.trim(u8, decl[8..], " ");
    var precision: ?i64 = null;
    if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse return -1;
        precision = std.fmt.parseInt(i64, std.mem.trim(u8, rest[open + 1 .. close], " "), 10) catch return -1;
        rest = std.mem.trim(u8, rest[0..open], " ");
    }
    var buf: [32]u8 = undefined;
    if (rest.len > buf.len) return -1;
    const range = rangeOfText(std.ascii.lowerString(&buf, rest)) orelse return -1;
    return typmodOf(range, precision);
}

/// intervaltypmodout(): what format_type() puts after "interval" for
/// type modifier `tm` (" year to month", "(2)", " day to second(3)").
pub fn typmodText(buf: *[48]u8, tm: i32) []const u8 {
    if (tm < 0) return "";
    const range = rangeOf(tm);
    const fields = for (range_names) |n| {
        if (n[0] == range) break n[1];
    } else "";
    const sep = if (fields.len > 0) " " else "";
    const p = precisionOf(tm);
    if (p == full_precision) return std.fmt.bufPrint(buf, "{s}{s}", .{ sep, fields }) catch "";
    return std.fmt.bufPrint(buf, "{s}{s}({d})", .{ sep, fields, p }) catch "";
}

// ---------------------------------------------------------------- input

/// The fields of an interval as its text gives them (pg_itm_in).
const Itm = struct {
    usec: i64 = 0,
    mday: i32 = 0,
    mon: i32 = 0,
    year: i32 = 0,

    /// itmin2interval().
    fn interval(t: Itm) Error!Interval {
        const months = @as(i64, t.year) * 12 + t.mon;
        return .{
            .months = std.math.cast(i32, months) orelse return error.IntervalRange,
            .days = t.mday,
            .time = t.usec,
        };
    }
};

fn mulAdd64(val: i64, mul: i64, sum: *i64) bool {
    const p = std.math.mul(i64, val, mul) catch return false;
    sum.* = std.math.add(i64, sum.*, p) catch return false;
    return true;
}

fn mulAdd32(val: i64, mul: i32, sum: *i32) bool {
    const v = std.math.cast(i32, val) orelse return false;
    const p = std.math.mul(i32, v, mul) catch return false;
    sum.* = std.math.add(i32, sum.*, p) catch return false;
    return true;
}

fn adjustFractMicroseconds(frac_arg: f64, scale: i64, t: *Itm) bool {
    if (frac_arg == 0) return true;
    var frac = frac_arg * @as(f64, @floatFromInt(scale));
    if (!(frac >= -0x1p63 and frac < 0x1p63)) return false;
    var usec: i64 = @intFromFloat(frac);
    frac -= @floatFromInt(usec);
    if (frac > 0.5) usec += 1 else if (frac < -0.5) usec -= 1;
    t.usec = std.math.add(i64, t.usec, usec) catch return false;
    return true;
}

fn adjustFractDays(frac_arg: f64, scale: i32, t: *Itm) bool {
    if (frac_arg == 0) return true;
    var frac = frac_arg * @as(f64, @floatFromInt(scale));
    if (!(frac >= -2147483648.0 and frac < 2147483648.0)) return false;
    const extra: i32 = @intFromFloat(frac);
    t.mday = std.math.add(i32, t.mday, extra) catch return false;
    frac -= @floatFromInt(extra);
    return adjustFractMicroseconds(frac, usecs_per_day, t);
}

fn adjustFractYears(frac: f64, scale: i32, t: *Itm) bool {
    const m = ivl.rint(frac * @as(f64, @floatFromInt(scale)) * 12);
    if (!(m >= -2147483648.0 and m < 2147483648.0)) return false;
    t.mon = std.math.add(i32, t.mon, @as(i32, @intFromFloat(m))) catch return false;
    return true;
}

fn adjustMicroseconds(val: i64, fval: f64, scale: i64, t: *Itm) bool {
    if (!mulAdd64(val, scale, &t.usec)) return false;
    return adjustFractMicroseconds(fval, scale, t);
}

fn adjustDays(val: i64, scale: i32, t: *Itm) bool {
    return mulAdd32(val, scale, &t.mday);
}

fn adjustMonths(val: i64, t: *Itm) bool {
    return mulAdd32(val, 1, &t.mon);
}

fn adjustYears(val: i64, scale: i32, t: *Itm) bool {
    return mulAdd32(val, scale, &t.year);
}

/// strtol(): leading spaces, a sign, digits; `end` after them (at the
/// start when there are none). Overflow is FieldOverflow.
fn strtoi64(z: []const u8, end: *usize) Error!i64 {
    var i: usize = 0;
    while (i < z.len and (z[i] == ' ' or z[i] == '\t')) i += 1;
    var neg = false;
    if (i < z.len and (z[i] == '-' or z[i] == '+')) {
        neg = z[i] == '-';
        i += 1;
    }
    const ds = i;
    var v: i64 = 0;
    var over = false;
    while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) {
        const d: i64 = z[i] - '0';
        v = std.math.mul(i64, v, 10) catch blk: {
            over = true;
            break :blk 0;
        };
        v = (if (neg) std.math.sub(i64, v, d) else std.math.add(i64, v, d)) catch blk: {
            over = true;
            break :blk 0;
        };
    }
    if (i == ds) {
        end.* = 0;
        return 0;
    }
    end.* = i;
    if (over) return error.FieldOverflow;
    return v;
}

fn strtoint(z: []const u8, end: *usize) Error!i32 {
    const v = try strtoi64(z, end);
    return std.math.cast(i32, v) orelse error.FieldOverflow;
}

/// ParseFraction(): `z` starts at the point; digits only after it.
fn parseFraction(z: []const u8) Error!f64 {
    if (z.len == 1) return 0;
    for (z[1..]) |c| if (!std.ascii.isDigit(c)) return error.Syntax;
    return std.fmt.parseFloat(f64, z) catch error.Syntax;
}

const FType = enum { number, time, date, tz, string, special };
const Field = struct { t: FType, z: []const u8 };
const max_fields = 25;

/// ParseDateTime(): the fields of `z` (lower case, in `buf`).
fn split(z: []const u8, buf: *[256]u8, fields: *[max_fields]Field) Error![]Field {
    var n: usize = 0;
    var o: usize = 0;
    var i: usize = 0;
    const Ap = struct {
        fn put(b: *[256]u8, at: *usize, c: u8) Error!void {
            if (at.* >= b.len - 1) return error.Syntax;
            b[at.*] = std.ascii.toLower(c);
            at.* += 1;
        }
    };
    while (i < z.len) {
        const c = z[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (n >= max_fields) return error.Syntax;
        const start = o;
        var t: FType = undefined;
        if (std.ascii.isDigit(c)) {
            while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) try Ap.put(buf, &o, z[i]);
            if (i < z.len and z[i] == ':') {
                t = .time;
                while (i < z.len and (std.ascii.isDigit(z[i]) or z[i] == ':' or z[i] == '.')) : (i += 1) try Ap.put(buf, &o, z[i]);
            } else if (i < z.len and (z[i] == '-' or z[i] == '/' or z[i] == '.')) {
                const delim = z[i];
                try Ap.put(buf, &o, z[i]);
                i += 1;
                if (i < z.len and std.ascii.isDigit(z[i])) {
                    t = if (delim == '.') .number else .date;
                    while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) try Ap.put(buf, &o, z[i]);
                    if (i < z.len and z[i] == delim) {
                        t = .date;
                        while (i < z.len and (std.ascii.isDigit(z[i]) or z[i] == delim)) : (i += 1) try Ap.put(buf, &o, z[i]);
                    }
                } else {
                    t = .date;
                    while (i < z.len and (std.ascii.isAlphanumeric(z[i]) or z[i] == delim)) : (i += 1) try Ap.put(buf, &o, z[i]);
                }
            } else t = .number;
        } else if (c == '.') {
            try Ap.put(buf, &o, c);
            i += 1;
            while (i < z.len and std.ascii.isDigit(z[i])) : (i += 1) try Ap.put(buf, &o, z[i]);
            t = .number;
        } else if (std.ascii.isAlphabetic(c)) {
            t = .string;
            while (i < z.len and std.ascii.isAlphabetic(z[i])) : (i += 1) try Ap.put(buf, &o, z[i]);
            var is_date = false;
            if (i < z.len and (z[i] == '-' or z[i] == '/' or z[i] == '.')) {
                is_date = true;
            } else if (i < z.len and (z[i] == '+' or std.ascii.isDigit(z[i]))) {
                is_date = !isDateToken(buf[start..o]);
            }
            if (is_date) {
                t = .date;
                while (true) {
                    try Ap.put(buf, &o, z[i]);
                    i += 1;
                    if (!(i < z.len and (std.mem.indexOfScalar(u8, "+-/_.:", z[i]) != null or std.ascii.isAlphanumeric(z[i])))) break;
                }
            }
        } else if (c == '+' or c == '-') {
            try Ap.put(buf, &o, c);
            i += 1;
            while (i < z.len and std.ascii.isWhitespace(z[i])) i += 1;
            if (i < z.len and std.ascii.isDigit(z[i])) {
                t = .tz;
                try Ap.put(buf, &o, z[i]);
                i += 1;
                while (i < z.len and (std.ascii.isDigit(z[i]) or z[i] == ':' or z[i] == '.' or z[i] == '-')) : (i += 1) try Ap.put(buf, &o, z[i]);
            } else if (i < z.len and std.ascii.isAlphabetic(z[i])) {
                t = .special;
                while (i < z.len and std.ascii.isAlphabetic(z[i])) : (i += 1) try Ap.put(buf, &o, z[i]);
            } else return error.Syntax;
        } else if (std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c)) {
            i += 1;
            continue;
        } else return error.Syntax;
        // The field's terminating NUL takes a byte of the buffer too.
        if (o >= buf.len - 1) return error.Syntax;
        o += 1;
        fields[n] = .{ .t = t, .z = buf[start .. o - 1] };
        n += 1;
    }
    return fields[0..n];
}

/// Whether `w` is a word of datetktbl (it does not start a time zone
/// name): the words that matter before a digit or `+` here.
fn isDateToken(w: []const u8) bool {
    const words = [_][]const u8{
        "ad",       "allballs", "am",        "apr",      "april", "aug",      "august", "bc",       "d",        "dec",     "december", "dow",       "doy",
        "dst",      "epoch",    "feb",       "february", "fri",   "friday",   "h",      "infinity", "isodow",   "isoyear", "j",        "jan",       "january",
        "jd",       "jul",      "july",      "jun",      "june",  "m",        "mar",    "march",    "may",      "mm",      "mon",      "monday",    "nov",
        "november", "now",      "oct",       "october",  "on",    "pm",       "s",      "sat",      "saturday", "sep",     "sept",     "september", "sun",
        "sunday",   "t",        "thu",       "thur",     "thurs", "thursday", "today",  "tomorrow", "tue",      "tues",    "tuesday",  "wed",       "wednesday",
        "weds",     "y",        "yesterday", "z",        "zulu",
    };
    for (words) |x| if (std.mem.eql(u8, x, w)) return true;
    return false;
}

/// The units of deltatktbl (compared on their first 10 characters, as
/// PostgreSQL's TOKMAXLEN).
pub const Unit = enum { microsecond, millisecond, second, minute, hour, day, week, month, quarter, year, decade, century, millennium, tz, tz_hour, tz_minute, dow, doy, isodow, isoyear, julian, ago };

const unit_words = [_]struct { []const u8, Unit }{
    .{ "ago", .ago },              .{ "c", .century },             .{ "cent", .century },           .{ "centuries", .century },
    .{ "century", .century },      .{ "d", .day },                 .{ "day", .day },                .{ "days", .day },
    .{ "dec", .decade },           .{ "decade", .decade },         .{ "decades", .decade },         .{ "decs", .decade },
    .{ "h", .hour },               .{ "hour", .hour },             .{ "hours", .hour },             .{ "hr", .hour },
    .{ "hrs", .hour },             .{ "m", .minute },              .{ "microsecon", .microsecond }, .{ "mil", .millennium },
    .{ "millennia", .millennium }, .{ "millennium", .millennium }, .{ "millisecon", .millisecond }, .{ "mils", .millennium },
    .{ "min", .minute },           .{ "mins", .minute },           .{ "minute", .minute },          .{ "minutes", .minute },
    .{ "mon", .month },            .{ "mons", .month },            .{ "month", .month },            .{ "months", .month },
    .{ "ms", .millisecond },       .{ "msec", .millisecond },      .{ "msecond", .millisecond },    .{ "mseconds", .millisecond },
    .{ "msecs", .millisecond },    .{ "qtr", .quarter },           .{ "quarter", .quarter },        .{ "s", .second },
    .{ "sec", .second },           .{ "second", .second },         .{ "seconds", .second },         .{ "secs", .second },
    .{ "timezone", .tz },          .{ "timezone_h", .tz_hour },    .{ "timezone_m", .tz_minute },   .{ "us", .microsecond },
    .{ "usec", .microsecond },     .{ "usecond", .microsecond },   .{ "useconds", .microsecond },   .{ "usecs", .microsecond },
    .{ "w", .week },               .{ "week", .week },             .{ "weeks", .week },             .{ "y", .year },
    .{ "year", .year },            .{ "years", .year },            .{ "yr", .year },                .{ "yrs", .year },
    .{ "dow", .dow },              .{ "doy", .doy },               .{ "isodow", .isodow },          .{ "isoyear", .isoyear },
    .{ "j", .julian },             .{ "jd", .julian },             .{ "julian", .julian },
};

/// DecodeUnits(): the unit word `w` (lower case) names, null for none.
pub fn unitOf(w: []const u8) ?Unit {
    const k = w[0..@min(w.len, 10)];
    for (unit_words) |u| if (std.mem.eql(u8, u[0], k)) return u[1];
    return null;
}

/// The bits of fmask/tmask (DTK_M()).
const M = struct {
    const year: u32 = 1 << 0;
    const month: u32 = 1 << 1;
    const day: u32 = 1 << 2;
    const week: u32 = 1 << 3;
    const decade: u32 = 1 << 4;
    const century: u32 = 1 << 5;
    const millennium: u32 = 1 << 6;
    const hour: u32 = 1 << 7;
    const minute: u32 = 1 << 8;
    const second: u32 = 1 << 9;
    const millisecond: u32 = 1 << 10;
    const microsecond: u32 = 1 << 11;
    const date = M.year | M.month | M.day;
    const time = M.hour | M.minute | M.second | M.millisecond | M.microsecond;
    const all_secs = M.second | M.millisecond | M.microsecond;
};

/// What a field without a unit is (DecodeInterval()'s `type`).
const Type = enum { ignore, unit_0, microsecond, millisecond, second, minute, hour, day, week, month, year, decade, century, millennium, other };

fn typeOfUnit(u: Unit) Type {
    return switch (u) {
        .microsecond => .microsecond,
        .millisecond => .millisecond,
        .second => .second,
        .minute => .minute,
        .hour => .hour,
        .day => .day,
        .week => .week,
        .month => .month,
        .year => .year,
        .decade => .decade,
        .century => .century,
        .millennium => .millennium,
        else => .other,
    };
}

/// DecodeTimeForInterval(): `z` (h:m[:s[.f]] or m:s.f) into t.usec.
fn decodeTime(z: []const u8, range: i32, t: *Itm) Error!void {
    var end: usize = 0;
    var h = try strtoi64(z, &end);
    if (end == 0 or end >= z.len or z[end] != ':') return error.Syntax;
    var rest = z[end + 1 ..];
    var m: i64 = try strtoint(rest, &end);
    rest = rest[end..];
    var s: i64 = 0;
    var fsec: f64 = 0;
    if (rest.len == 0) {
        if (range == minute | second) {
            if (std.math.cast(i32, h) == null) return error.FieldOverflow;
            s = m;
            m = h;
            h = 0;
        }
    } else if (rest[0] == '.') {
        fsec = ivl.rint(try parseFraction(rest) * 1e6);
        if (std.math.cast(i32, h) == null) return error.FieldOverflow;
        s = m;
        m = h;
        h = 0;
    } else if (rest[0] == ':') {
        rest = rest[1..];
        s = try strtoint(rest, &end);
        rest = rest[end..];
        if (rest.len > 0) {
            if (rest[0] != '.') return error.Syntax;
            fsec = ivl.rint(try parseFraction(rest) * 1e6);
        }
    } else return error.Syntax;
    if (h < 0 or m < 0 or m > 59 or s < 0 or s > 60 or fsec < 0 or fsec > 1e6) return error.FieldOverflow;
    t.usec = @intFromFloat(fsec);
    if (!mulAdd64(h, usecs_per_hour, &t.usec) or !mulAdd64(m, usecs_per_minute, &t.usec) or !mulAdd64(s, usecs_per_sec, &t.usec)) return error.FieldOverflow;
}

const Decoded = union(enum) { fields: Itm, late, early };

/// DecodeInterval(). `sql_standard` (IntervalStyle sql_standard): a
/// leading '-' and no other sign makes every field negative ('-1
/// 2:03:04' is -1 days -02:03:04).
fn decodeFields(fields: []Field, range: i32, sql_standard: bool) Error!Decoded {
    var force_negative = false;
    if (sql_standard) {
        // ParseDateTime() makes no field of '@'.
        var first: ?usize = null;
        for (fields, 0..) |f, k| if (!std.mem.eql(u8, f.z, "@")) {
            first = k;
            break;
        };
        if (first) |k0| if (fields[k0].z.len > 0 and fields[k0].z[0] == '-') {
            force_negative = for (fields[k0 + 1 ..]) |f| {
                if (f.z.len > 0 and (f.z[0] == '-' or f.z[0] == '+')) break false;
            } else true;
        };
    }
    var t: Itm = .{};
    var fmask: u32 = 0;
    var typ: Type = .ignore;
    var is_before = false;
    var parsing_unit = false;
    var special: ?Decoded = null;
    var i = fields.len;
    while (i > 0) {
        i -= 1;
        const f = fields[i];
        var tmask: u32 = 0;
        number: {
            switch (f.t) {
                .time => {
                    try decodeTime(f.z, range, &t);
                    if (force_negative and t.usec > 0) t.usec = -t.usec;
                    tmask = M.time;
                    typ = .day;
                    parsing_unit = false;
                    break :number;
                },
                .tz => if (std.mem.indexOfScalar(u8, f.z[1..], ':') != null) {
                    var tt = t;
                    if (decodeTime(f.z[1..], range, &tt)) {
                        t = tt;
                        if (f.z[0] == '-') {
                            if (t.usec == std.math.minInt(i64)) return error.FieldOverflow;
                            t.usec = -t.usec;
                        }
                        tmask = M.time;
                        typ = .day;
                        parsing_unit = false;
                        break :number;
                    } else |_| {}
                },
                .string, .special => {
                    if (parsing_unit) return error.Syntax;
                    if (unitOf(f.z)) |u| {
                        if (u == .ago) {
                            if (i != fields.len - 1) return error.Syntax;
                            is_before = true;
                            typ = .unit_0;
                        } else {
                            typ = typeOfUnit(u);
                            parsing_unit = true;
                        }
                    } else if (std.mem.eql(u8, f.z, "@")) {
                        continue;
                    } else if (std.mem.eql(u8, f.z, "infinity") or std.mem.eql(u8, f.z, "+infinity") or std.mem.eql(u8, f.z, "-infinity")) {
                        tmask = M.date | M.time;
                        special = if (f.z[0] == '-') .early else .late;
                    } else return error.Syntax;
                    if (tmask & fmask != 0) return error.Syntax;
                    fmask |= tmask;
                    continue;
                },
                else => {},
            }
            // A number (DTK_NUMBER, DTK_DATE, DTK_TZ without a time).
            if (typ == .ignore) typ = switch (range) {
                year => .year,
                month, year | month => .month,
                day => .day,
                hour, day | hour => .hour,
                minute, hour | minute, day | hour | minute => .minute,
                else => .second,
            };
            var end: usize = 0;
            var val = try strtoi64(f.z, &end);
            var fval: f64 = 0;
            const rest = f.z[end..];
            if (rest.len > 0 and rest[0] == '-') {
                // SQL's years-months.
                var e2: usize = 0;
                var val2: i64 = try strtoint(rest[1..], &e2);
                if (val2 < 0 or val2 >= 12) return error.FieldOverflow;
                if (1 + e2 != rest.len) return error.Syntax;
                typ = .month;
                if (f.z[0] == '-') val2 = -val2;
                val = std.math.mul(i64, val, 12) catch return error.FieldOverflow;
                val = std.math.add(i64, val, val2) catch return error.FieldOverflow;
            } else if (rest.len > 0 and rest[0] == '.') {
                fval = try parseFraction(rest);
                if (f.z[0] == '-') fval = -fval;
            } else if (rest.len != 0) return error.Syntax;
            if (force_negative) {
                if (val > 0) val = -val;
                if (fval > 0) fval = -fval;
            }
            const ov = error.FieldOverflow;
            switch (typ) {
                .microsecond => {
                    if (!adjustMicroseconds(val, fval, 1, &t)) return ov;
                    tmask = M.microsecond;
                },
                .millisecond => {
                    if (!adjustMicroseconds(val, fval, 1000, &t)) return ov;
                    tmask = M.millisecond;
                },
                .second => {
                    if (!adjustMicroseconds(val, fval, usecs_per_sec, &t)) return ov;
                    tmask = if (fval == 0) M.second else M.all_secs;
                },
                .minute => {
                    if (!adjustMicroseconds(val, fval, usecs_per_minute, &t)) return ov;
                    tmask = M.minute;
                },
                .hour => {
                    if (!adjustMicroseconds(val, fval, usecs_per_hour, &t)) return ov;
                    tmask = M.hour;
                    typ = .day;
                },
                .day => {
                    if (!adjustDays(val, 1, &t) or !adjustFractMicroseconds(fval, usecs_per_day, &t)) return ov;
                    tmask = M.day;
                },
                .week => {
                    if (!adjustDays(val, 7, &t) or !adjustFractDays(fval, 7, &t)) return ov;
                    tmask = M.week;
                },
                .month => {
                    if (!adjustMonths(val, &t) or !adjustFractDays(fval, 30, &t)) return ov;
                    tmask = M.month;
                },
                .year => {
                    if (!adjustYears(val, 1, &t) or !adjustFractYears(fval, 1, &t)) return ov;
                    tmask = M.year;
                },
                .decade => {
                    if (!adjustYears(val, 10, &t) or !adjustFractYears(fval, 10, &t)) return ov;
                    tmask = M.decade;
                },
                .century => {
                    if (!adjustYears(val, 100, &t) or !adjustFractYears(fval, 100, &t)) return ov;
                    tmask = M.century;
                },
                .millennium => {
                    if (!adjustYears(val, 1000, &t) or !adjustFractYears(fval, 1000, &t)) return ov;
                    tmask = M.millennium;
                },
                else => return error.Syntax,
            }
            parsing_unit = false;
        }
        if (tmask & fmask != 0) return error.Syntax;
        fmask |= tmask;
    }
    if (fmask == 0 or parsing_unit) return error.Syntax;
    // An infinity stands alone ('infinity ago' is no interval).
    if (special) |s| return if (fields.len == 1) s else error.Syntax;
    if (is_before) {
        if (t.usec == std.math.minInt(i64) or t.mday == std.math.minInt(i32) or t.mon == std.math.minInt(i32) or t.year == std.math.minInt(i32)) return error.FieldOverflow;
        t = .{ .usec = -t.usec, .mday = -t.mday, .mon = -t.mon, .year = -t.year };
    }
    return .{ .fields = t };
}

/// ParseISO8601Number(): a number as strtod() reads it, its whole part
/// and fraction.
fn isoNumber(z: []const u8, i: *usize, ipart: *i64, fpart: *f64) Error!void {
    const s = i.*;
    if (s >= z.len or !(std.ascii.isDigit(z[s]) or z[s] == '-' or z[s] == '.')) return error.Syntax;
    var e = s;
    if (z[e] == '-' or z[e] == '+') e += 1;
    const ds = e;
    while (e < z.len and std.ascii.isDigit(z[e])) e += 1;
    var digits = e > ds;
    if (e < z.len and z[e] == '.') {
        e += 1;
        const fs = e;
        while (e < z.len and std.ascii.isDigit(z[e])) e += 1;
        digits = digits or e > fs;
    }
    if (!digits) return error.Syntax;
    if (e < z.len and (z[e] == 'e' or z[e] == 'E')) {
        var x = e + 1;
        if (x < z.len and (z[x] == '-' or z[x] == '+')) x += 1;
        const xs = x;
        while (x < z.len and std.ascii.isDigit(z[x])) x += 1;
        if (x > xs) e = x;
    }
    const v = std.fmt.parseFloat(f64, z[s..e]) catch return error.Syntax;
    if (std.math.isNan(v) or v < -1.0e15 or v > 1.0e15) return error.FieldOverflow;
    const w: i64 = @intFromFloat(@trunc(v));
    ipart.* = w;
    fpart.* = v - @as(f64, @floatFromInt(w));
    i.* = e;
}

fn isoIntWidth(z: []const u8, at: usize) usize {
    var i = at;
    if (i < z.len and z[i] == '-') i += 1;
    const s = i;
    while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
    return i - s;
}

/// DecodeISO8601Interval().
fn decodeIso(z: []const u8) Error!Itm {
    var t: Itm = .{};
    if (z.len < 2 or z[0] != 'P') return error.Syntax;
    var i: usize = 1;
    var datepart = true;
    var havefield = false;
    const ov = error.FieldOverflow;
    while (i < z.len) {
        if (z[i] == 'T') {
            datepart = false;
            havefield = false;
            i += 1;
            continue;
        }
        const fieldstart = i;
        var val: i64 = 0;
        var fval: f64 = 0;
        try isoNumber(z, &i, &val, &fval);
        const unit: u8 = if (i < z.len) z[i] else 0;
        i += 1;
        if (datepart) {
            switch (unit) {
                'Y' => if (!adjustYears(val, 1, &t) or !adjustFractYears(fval, 1, &t)) return ov,
                'M' => if (!adjustMonths(val, &t) or !adjustFractDays(fval, 30, &t)) return ov,
                'W' => if (!adjustDays(val, 7, &t) or !adjustFractDays(fval, 7, &t)) return ov,
                'D' => if (!adjustDays(val, 1, &t) or !adjustFractMicroseconds(fval, usecs_per_day, &t)) return ov,
                'T', 0, '-' => {
                    if (unit != '-' and isoIntWidth(z, fieldstart) == 8 and !havefield) {
                        if (!adjustYears(@divTrunc(val, 10000), 1, &t) or !adjustMonths(@rem(@divTrunc(val, 100), 100), &t) or
                            !adjustDays(@rem(val, 100), 1, &t) or !adjustFractMicroseconds(fval, usecs_per_day, &t)) return ov;
                        if (unit == 0) return t;
                        datepart = false;
                        havefield = false;
                        continue;
                    }
                    if (havefield) return error.Syntax;
                    if (!adjustYears(val, 1, &t) or !adjustFractYears(fval, 1, &t)) return ov;
                    if (unit == 0) return t;
                    if (unit == 'T') {
                        datepart = false;
                        havefield = false;
                        continue;
                    }
                    try isoNumber(z, &i, &val, &fval);
                    if (!adjustMonths(val, &t) or !adjustFractDays(fval, 30, &t)) return ov;
                    if (i >= z.len) return t;
                    if (z[i] == 'T') {
                        datepart = false;
                        havefield = false;
                        i += 1;
                        continue;
                    }
                    if (z[i] != '-') return error.Syntax;
                    i += 1;
                    try isoNumber(z, &i, &val, &fval);
                    if (!adjustDays(val, 1, &t) or !adjustFractMicroseconds(fval, usecs_per_day, &t)) return ov;
                    if (i >= z.len) return t;
                    if (z[i] == 'T') {
                        datepart = false;
                        havefield = false;
                        i += 1;
                        continue;
                    }
                    return error.Syntax;
                },
                else => return error.Syntax,
            }
        } else {
            switch (unit) {
                'H' => if (!adjustMicroseconds(val, fval, usecs_per_hour, &t)) return ov,
                'M' => if (!adjustMicroseconds(val, fval, usecs_per_minute, &t)) return ov,
                'S' => if (!adjustMicroseconds(val, fval, usecs_per_sec, &t)) return ov,
                0, ':' => {
                    if (unit == 0 and isoIntWidth(z, fieldstart) == 6 and !havefield) {
                        if (!adjustMicroseconds(@divTrunc(val, 10000), 0, usecs_per_hour, &t) or
                            !adjustMicroseconds(@rem(@divTrunc(val, 100), 100), 0, usecs_per_minute, &t) or
                            !adjustMicroseconds(@rem(val, 100), 0, usecs_per_sec, &t) or
                            !adjustFractMicroseconds(fval, 1, &t)) return ov;
                        return t;
                    }
                    if (havefield) return error.Syntax;
                    if (!adjustMicroseconds(val, fval, usecs_per_hour, &t)) return ov;
                    if (unit == 0) return t;
                    try isoNumber(z, &i, &val, &fval);
                    if (!adjustMicroseconds(val, fval, usecs_per_minute, &t)) return ov;
                    if (i >= z.len) return t;
                    if (z[i] != ':') return error.Syntax;
                    i += 1;
                    try isoNumber(z, &i, &val, &fval);
                    if (!adjustMicroseconds(val, fval, usecs_per_sec, &t)) return ov;
                    if (i >= z.len) return t;
                    return error.Syntax;
                },
                else => return error.Syntax,
            }
        }
        havefield = true;
    }
    return t;
}

/// interval_in(): the interval text `z` is, read by the range of type
/// modifier `tm` (-1 none), then adjusted to it.
pub fn decode(z: []const u8, tm: i32) Error!Interval {
    return decodeIn(z, tm, false);
}

/// decode() as IntervalStyle sql_standard reads it (`sql_standard`):
/// a leading '-' and no other sign makes every field negative.
pub fn decodeIn(z: []const u8, tm: i32, sql_standard: bool) Error!Interval {
    const range = rangeOf(tm);
    var buf: [256]u8 = undefined;
    var fields: [max_fields]Field = undefined;
    var iv: Interval = undefined;
    const d: Error!Decoded = if (split(z, &buf, &fields)) |fs| decodeFields(fs, range, sql_standard) else |err| err;
    if (d) |r| {
        iv = switch (r) {
            .fields => |t| try t.interval(),
            .late => Interval.infinity,
            .early => Interval.neg_infinity,
        };
    } else |err| {
        if (err != error.Syntax) return err;
        iv = try (try decodeIso(z)).interval();
    }
    return adjust(iv, tm);
}

/// AdjustIntervalForTypmod().
pub fn adjust(iv_arg: Interval, tm: i32) Error!Interval {
    var iv = iv_arg;
    if (tm < 0 or !iv.isFinite()) return iv;
    const range = rangeOf(tm);
    const precision = precisionOf(tm);
    const trunc = struct {
        fn f(t: i64, unit: i64) i64 {
            return @divTrunc(t, unit) * unit;
        }
    }.f;
    switch (range) {
        year => {
            iv.months = @divTrunc(iv.months, 12) * 12;
            iv.days = 0;
            iv.time = 0;
        },
        month, year | month => {
            iv.days = 0;
            iv.time = 0;
        },
        day => iv.time = 0,
        hour, day | hour => iv.time = trunc(iv.time, usecs_per_hour),
        minute, day | hour | minute, hour | minute => iv.time = trunc(iv.time, usecs_per_minute),
        else => {},
    }
    if (precision != full_precision) {
        if (precision < 0 or precision > max_precision) return error.Syntax;
        const scales = [_]i64{ 1000000, 100000, 10000, 1000, 100, 10, 1 };
        const offsets = [_]i64{ 500000, 50000, 5000, 500, 50, 5, 0 };
        const p: usize = @intCast(precision);
        if (iv.time >= 0) {
            iv.time = std.math.add(i64, iv.time, offsets[p]) catch return error.IntervalRange;
        } else {
            iv.time = std.math.sub(i64, iv.time, offsets[p]) catch return error.IntervalRange;
        }
        iv.time -= @rem(iv.time, scales[p]);
    }
    return iv;
}

// ------------------------------------------------------------- functions

const det: dfunc.Options = .{ .deterministic = true };

/// xq_pg_iv_in(x, typmod): an interval's input with its type modifier
/// (repr/interval.zig's cast and store).
pub const in_def = dfunc.scalar("xq_pg_iv_in", 2, det, inFunc);
/// xq_pg_iv_in(x, typmod, 1): IntervalStyle sql_standard's input (its
/// sign), what a cast compiled in such a session calls (a constant of
/// its own: the session does not change it later).
pub const in_sql_def = dfunc.scalar("xq_pg_iv_in", 3, det, inFunc);

/// xq_pg_iv_in()'s constant arguments after x for type modifier `tm`,
/// in `buf`: (tm), and where `db`'s session reads intervals in
/// IntervalStyle sql_standard (tm, 1), its reading of a sign. A
/// statement keeps them as compiled, as PostgreSQL reads a constant then
/// (session.zig compiles the statements again when sql_standard comes or
/// goes); null `db`: the default style's.
pub fn inArgs(db: ?*const int.Sqlite3, tm: i64, buf: *[2]i64) []const i64 {
    buf.* = .{ tm, 1 };
    const sql = if (db) |d| sqlStandard(d) else false;
    return buf[0 .. @as(usize, 1) + @intFromBool(sql)];
}

/// Whether `db`'s session reads intervals in IntervalStyle sql_standard.
pub fn sqlStandard(db: *const int.Sqlite3) bool {
    return db.xq.postgres.sqlStandard();
}

/// What a value stored into an interval column goes through
/// (typing.Rules.store, with the typmod): xq_pg_iv_in(), in the
/// session's IntervalStyle (a string with a leading '-' in sql_standard).
/// Called by code generation, not by name: not an engine function.
pub const store_def = dfunc.scalar("xq_pg_iv_store", 2, .{}, storeFunc);

fn storeFunc(ctx: *Context, argv: []*Mem) void {
    inRead(ctx, argv, sqlStandard(api.contextDbHandle(ctx)));
}

pub const engine_functions = [_]int.FuncDef{
    in_def,
    in_sql_def,
    dfunc.scalar("xq_pg_iv_extract", 2, det, dfunc.bind(partFunc, .{true})),
    dfunc.scalar("xq_pg_iv_date_part", 2, det, dfunc.bind(partFunc, .{false})),
};

pub const functions = [_]int.FuncDef{
    dfunc.scalar("make_interval", 7, det, makeFunc),
    dfunc.scalar("xq_pg_part", 4, det, choosePartFunc),
};

/// xq_pg_part(field, x, timestamp's part, extract): what the parser
/// makes of EXTRACT and date_part(), which overload.zig makes the part
/// of an interval or of a timestamp by the type of x. Where it was not
/// (a value of no known type), by the value: an interval's BLOB the
/// interval's part, else the timestamp's.
fn choosePartFunc(ctx: *Context, argv: []*Mem) void {
    if (api.valueType(argv[1]) == vi.SQLITE_BLOB and ivl.valid(api.valueBlob(argv[1]) orelse &.{})) {
        if (api.valueInt64(argv[3]) == 1) return partFunc(ctx, argv[0..2], true);
        return partFunc(ctx, argv[0..2], false);
    }
    api.resultValue(ctx, argv[2]);
}

/// Interval `iv` the result: its BLOB.
pub fn resultInterval(ctx: *Context, iv: Interval) void {
    const b = iv.encode();
    api.resultBlob(ctx, &b, .transient);
}

/// The error of input `raw`.
pub fn fail(ctx: *Context, err: Error, raw: []const u8) void {
    var buf: [512]u8 = undefined;
    const shown = raw[0..@min(raw.len, 400)];
    switch (err) {
        error.Syntax => {
            const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type interval: \"{s}\"", .{shown}) catch "invalid input syntax";
            api.resultErrorState(ctx, .of("22007"), msg);
        },
        error.FieldOverflow => {
            const msg = std.fmt.bufPrint(&buf, "interval field value out of range: \"{s}\"", .{shown}) catch "interval field value out of range";
            api.resultErrorState(ctx, .of("22015"), msg);
        },
        error.IntervalRange => api.resultErrorState(ctx, .of("22008"), "interval out of range"),
    }
}

/// xq_pg_iv_in(x, typmod [, sql_standard]).
fn inFunc(ctx: *Context, argv: []*Mem) void {
    const sql = argv.len > 2 and !dfunc.isNull(argv[2]) and api.valueInt64(argv[2]) != 0;
    inRead(ctx, argv[0..2], sql);
}

fn inRead(ctx: *Context, argv: []*Mem, sql_standard: bool) void {
    const m = argv[0];
    if (dfunc.isNull(m)) return api.resultNull(ctx);
    const tm: i32 = if (dfunc.isNull(argv[1])) -1 else std.math.cast(i32, api.valueInt64(argv[1])) orelse -1;
    if (tm >= 0) {
        const p = precisionOf(tm);
        if (p != full_precision and (p < 0 or p > max_precision)) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "interval({d}) precision must be between 0 and 6", .{p}) catch "interval precision out of range";
            return api.resultErrorState(ctx, .of("22023"), msg);
        }
    }
    if (api.valueType(m) == vi.SQLITE_BLOB) {
        const iv = ivl.decode(api.valueBlob(m) orelse &.{}) orelse
            return api.resultErrorState(ctx, .of("22P03"), "invalid interval value");
        const r = adjust(iv, tm) catch |err| return fail(ctx, err, "");
        return resultInterval(ctx, r);
    }
    const raw = dfunc.text(ctx, m) orelse return;
    const iv = decodeIn(raw, tm, sql_standard) catch |err| return fail(ctx, err, raw);
    resultInterval(ctx, iv);
}

/// The interval argument `m` is, an interval's BLOB or its text (an
/// older database's TEXT column, a string) read by decode(): its
/// months, days and microseconds; null after making the error
/// (PostgreSQL's input messages) the result. For every function that
/// takes an interval (the operators' xq_pg_iv_*(), uuidv7(interval),
/// EXTRACT ...). `m` is not NULL.
pub fn intervalArg(ctx: *Context, m: *Mem) ?Interval {
    if (api.valueType(m) == vi.SQLITE_BLOB) {
        return ivl.decode(api.valueBlob(m) orelse &.{}) orelse {
            api.resultErrorState(ctx, .of("22P03"), "invalid interval value");
            return null;
        };
    }
    const raw = dfunc.text(ctx, m) orelse return null;
    return decode(raw, -1) catch |err| {
        fail(ctx, err, raw);
        return null;
    };
}

/// What EXTRACT and date_part() give: an integer, a number of
/// microseconds shown with `scale` digits after the point, or an
/// infinity.
const Part = union(enum) { int: i64, scaled: struct { v: i128, scale: u8 }, inf: bool, none };

/// interval_part_common().
fn part(ctx: *Context, unit_z: []const u8, iv: Interval) ?Part {
    var lbuf: [64]u8 = undefined;
    const low = std.ascii.lowerString(lbuf[0..@min(unit_z.len, lbuf.len)], unit_z[0..@min(unit_z.len, lbuf.len)]);
    const epoch = std.mem.eql(u8, low, "epoch");
    const u = unitOf(low);
    var mbuf: [160]u8 = undefined;
    if (u == null and !epoch) {
        const msg = std.fmt.bufPrint(&mbuf, "unit \"{s}\" not recognized for type interval", .{low}) catch "unit not recognized";
        api.resultErrorState(ctx, .of("22023"), msg);
        return null;
    }
    const unsupported = struct {
        fn f(c: *Context, l: []const u8, b: *[160]u8) ?Part {
            const msg = std.fmt.bufPrint(b, "unit \"{s}\" not supported for type interval", .{l}) catch "unit not supported";
            api.resultErrorState(c, .of("0A000"), msg);
            return null;
        }
    }.f;
    if (!iv.isFinite()) {
        if (epoch) return .{ .inf = iv.isNegInf() };
        return switch (u.?) {
            .microsecond, .millisecond, .second, .minute, .week, .month, .quarter => .none,
            .hour, .day, .year, .decade, .century, .millennium => .{ .inf = iv.isNegInf() },
            else => unsupported(ctx, low, &mbuf),
        };
    }
    if (epoch) {
        const secs_dm: i128 = (@as(i128, 1461) * @divTrunc(iv.months, 12) + @as(i128, 120) * @rem(iv.months, 12) + @as(i128, 4) * iv.days) * (86400 / 4);
        return .{ .scaled = .{ .v = secs_dm * 1_000_000 + iv.time, .scale = 6 } };
    }
    const tm_year = @divTrunc(iv.months, 12);
    const tm_mon = @rem(iv.months, 12);
    var time = iv.time;
    const tm_hour = @divTrunc(time, usecs_per_hour);
    time -= tm_hour * usecs_per_hour;
    const tm_min = @divTrunc(time, usecs_per_minute);
    time -= tm_min * usecs_per_minute;
    const us = time; // seconds and microseconds
    return switch (u.?) {
        .microsecond => .{ .int = us },
        .millisecond => .{ .scaled = .{ .v = us, .scale = 3 } },
        .second => .{ .scaled = .{ .v = us, .scale = 6 } },
        .minute => .{ .int = tm_min },
        .hour => .{ .int = tm_hour },
        .day => .{ .int = iv.days },
        .week => .{ .int = @divTrunc(iv.days, 7) },
        .month => .{ .int = tm_mon },
        .quarter => .{ .int = if (iv.months >= 0) @divTrunc(tm_mon, 3) + 1 else -(@divTrunc(@rem(-@as(i64, iv.months), 12), 3) + 1) },
        .year => .{ .int = tm_year },
        .decade => .{ .int = @divTrunc(tm_year, 10) },
        .century => .{ .int = @divTrunc(tm_year, 100) },
        .millennium => .{ .int = @divTrunc(tm_year, 1000) },
        else => unsupported(ctx, low, &mbuf),
    };
}

/// xq_pg_iv_extract(field, x) (numeric) and xq_pg_iv_date_part(field,
/// x) (double precision).
fn partFunc(ctx: *Context, argv: []*Mem, comptime numeric: bool) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const unit_z = dfunc.text(ctx, argv[0]) orelse return;
    const iv = intervalArg(ctx, argv[1]) orelse return;
    const p = part(ctx, unit_z, iv) orelse return;
    if (!numeric and iv.isFinite() and std.ascii.eqlIgnoreCase(unit_z, "epoch")) {
        // In double precision, as PostgreSQL computes it.
        const m: f64 = @floatFromInt(@divTrunc(iv.months, 12));
        const r: f64 = @floatFromInt(@rem(iv.months, 12));
        const t: f64 = @floatFromInt(iv.time);
        return api.resultDouble(ctx, t / 1e6 + 365.25 * 86400.0 * m + 30.0 * 86400.0 * r + 86400.0 * @as(f64, @floatFromInt(iv.days)));
    }
    if (!numeric) {
        return switch (p) {
            .none => api.resultNull(ctx),
            .inf => |neg| api.resultDouble(ctx, if (neg) -std.math.inf(f64) else std.math.inf(f64)),
            .int => |v| api.resultDouble(ctx, @floatFromInt(v)),
            // As PostgreSQL computes it (whole seconds plus the fraction).
            .scaled => |s| api.resultDouble(ctx, if (s.scale == 3)
                @as(f64, @floatFromInt(@divTrunc(s.v, 1_000_000))) * 1000.0 + @as(f64, @floatFromInt(@rem(s.v, 1_000_000))) / 1000.0
            else
                @as(f64, @floatFromInt(@divTrunc(s.v, 1_000_000))) + @as(f64, @floatFromInt(@rem(s.v, 1_000_000))) / 1e6),
        };
    }
    var tbuf: [64]u8 = undefined;
    const text: []const u8 = switch (p) {
        .none => return api.resultNull(ctx),
        .inf => |neg| if (neg) "-Infinity" else "Infinity",
        .int => |v| std.fmt.bufPrint(&tbuf, "{d}", .{v}) catch unreachable,
        .scaled => |s| scaledText(&tbuf, s.v, s.scale),
    };
    var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const d = decimal.parse(a, text) catch return api.resultErrorNomem(ctx);
    const k = decimal.key(a, d, true) catch return api.resultErrorNomem(ctx);
    api.resultBlob(ctx, k, .transient);
}

/// `v` microseconds as seconds (scale 6) or milliseconds (scale 3).
fn scaledText(buf: *[64]u8, v: i128, scale: u8) []const u8 {
    const neg = v < 0;
    const a: u128 = @abs(v);
    const div: u128 = if (scale == 6) 1_000_000 else 1000;
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>[3]}", .{ if (neg) "-" else "", a / div, a % div, @as(usize, scale) }) catch unreachable;
}

/// make_interval(years, months, weeks, days, hours, mins, secs).
fn makeFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    var ints: [6]i32 = undefined;
    for (argv[0..6], &ints) |m, *o| {
        const v: i64 = switch (api.valueType(m)) {
            vi.SQLITE_FLOAT => blk: {
                const r = ivl.rint(api.valueDouble(m));
                if (!(r >= -2147483648.0 and r <= 2147483647.0)) return api.resultErrorState(ctx, .of("22003"), "integer out of range");
                break :blk @intFromFloat(r);
            },
            else => api.valueInt64(m),
        };
        o.* = std.math.cast(i32, v) orelse return api.resultErrorState(ctx, .of("22003"), "integer out of range");
    }
    var secs: f64 = switch (api.valueType(argv[6])) {
        vi.SQLITE_INTEGER, vi.SQLITE_FLOAT => api.valueDouble(argv[6]),
        else => blk: {
            const z = std.mem.trim(u8, dfunc.text(ctx, argv[6]) orelse return, " \t\r\n");
            break :blk parseFloat8(z) orelse {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type double precision: \"{s}\"", .{z[0..@min(z.len, 64)]}) catch "invalid input syntax";
                return api.resultErrorState(ctx, .of("22P02"), msg);
            };
        },
    };
    const range = error.IntervalRange;
    const r = blk: {
        if (std.math.isInf(secs) or std.math.isNan(secs)) break :blk range;
        const months = std.math.add(i32, std.math.mul(i32, ints[0], 12) catch break :blk range, ints[1]) catch break :blk range;
        const days = std.math.add(i32, std.math.mul(i32, ints[2], 7) catch break :blk range, ints[3]) catch break :blk range;
        var time: i64 = @as(i64, ints[4]) * usecs_per_hour + @as(i64, ints[5]) * usecs_per_minute;
        const us = secs * 1e6;
        if (std.math.isInf(us)) return api.resultErrorState(ctx, .of("22003"), "value out of range: overflow");
        secs = ivl.rint(us);
        if (!(secs >= -0x1p63 and secs < 0x1p63)) break :blk range;
        time = std.math.add(i64, time, @as(i64, @intFromFloat(secs))) catch break :blk range;
        const iv: Interval = .{ .months = months, .days = days, .time = time };
        if (!iv.isFinite()) break :blk range;
        break :blk iv;
    };
    const iv = r catch return api.resultErrorState(ctx, .of("22008"), "interval out of range");
    resultInterval(ctx, iv);
}

/// float8in(): a number, 'Infinity', '-inf', 'NaN' ...
fn parseFloat8(z: []const u8) ?f64 {
    const words = [_]struct { []const u8, f64 }{
        .{ "infinity", std.math.inf(f64) }, .{ "+infinity", std.math.inf(f64) }, .{ "-infinity", -std.math.inf(f64) },
        .{ "inf", std.math.inf(f64) },      .{ "+inf", std.math.inf(f64) },      .{ "-inf", -std.math.inf(f64) },
        .{ "nan", std.math.nan(f64) },
    };
    for (words) |w| if (std.ascii.eqlIgnoreCase(z, w[0])) return w[1];
    if (z.len == 0) return null;
    for (z) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '-' or c == '+')) return null;
    return std.fmt.parseFloat(f64, z) catch null;
}

// ================================================================= tests

const testing = std.testing;

fn expectIv(z: []const u8, tm: i32, want: Interval) !void {
    const got = decode(z, tm) catch |err| {
        std.debug.print("{s}: {t}\n", .{ z, err });
        return err;
    };
    testing.expectEqual(want, got) catch |err| {
        std.debug.print("{s}: got {d} {d} {d}\n", .{ z, got.months, got.days, got.time });
        return err;
    };
}

test "pg interval input: DecodeInterval" {
    const h = usecs_per_hour;
    try expectIv("1 day 2 hours ago", -1, .{ .days = -1, .time = -2 * h });
    try expectIv("@ 1 minute ago", -1, .{ .time = -usecs_per_minute });
    try expectIv("1-2", -1, .{ .months = 14 });
    try expectIv("-1-2", -1, .{ .months = -14 });
    try expectIv("+1 -1:00:00", -1, .{ .days = 1, .time = -h });
    try expectIv("-1 +02:03", -1, .{ .days = -1, .time = 2 * h + 3 * usecs_per_minute });
    try expectIv("02:00 1.5 days", -1, .{ .days = 1, .time = 2 * h });
    try expectIv("1:2:60", -1, .{ .time = h + 3 * usecs_per_minute });
    try expectIv("4 millenniums", -1, .{ .months = 48000 });
    try expectIv("1 millisecondsxyz", -1, .{ .time = 1000 });
    try expectIv(".5", -1, .{ .time = 500000 });
    try expectIv("1.5 weeks", -1, .{ .days = 10, .time = 12 * h });
    try expectIv("infinity", -1, Interval.infinity);
    try expectIv("-2147483648 months -2147483648 days -9223372036854775808 us", -1, Interval.neg_infinity);
    for ([_][]const u8{ "1 2 days", "5 ago", "1 day ago 2", "1 hour 02:00", "1,5 days", "1 qtr", "@ 30 eons ago", "", "123 11", "infinity ago" }) |z|
        try testing.expectError(error.Syntax, decode(z, -1));
    try testing.expectError(error.FieldOverflow, decode("2147483648 days", -1));
    try testing.expectError(error.IntervalRange, decode("2147483647 years", -1));
    try testing.expectError(error.FieldOverflow, decode("-2147483648 months ago", -1));
}

test "pg interval input: IntervalStyle sql_standard's leading sign" {
    const h = usecs_per_hour;
    const m = usecs_per_minute;
    const cases = [_]struct { []const u8, Interval, Interval }{
        // input, as postgres reads it, as sql_standard does
        .{ "-1 2:03:04", .{ .days = -1, .time = 2 * h + 3 * m + 4 * usecs_per_sec }, .{ .days = -1, .time = -(2 * h + 3 * m + 4 * usecs_per_sec) } },
        .{ "-1 day 2 hours", .{ .days = -1, .time = 2 * h }, .{ .days = -1, .time = -2 * h } },
        .{ "-1-2 3", .{ .months = -14, .time = 3 * usecs_per_sec }, .{ .months = -14, .time = -3 * usecs_per_sec } },
        .{ "-1.5 2:03", .{ .days = -1, .time = -12 * h + 2 * h + 3 * m }, .{ .days = -1, .time = -12 * h - 2 * h - 3 * m } },
        .{ "-1 2:03:04 ago", .{ .days = 1, .time = -(2 * h + 3 * m + 4 * usecs_per_sec) }, .{ .days = 1, .time = 2 * h + 3 * m + 4 * usecs_per_sec } },
        .{ "@ -1 day 2 hours", .{ .days = -1, .time = 2 * h }, .{ .days = -1, .time = -2 * h } },
        // Another sign: as written.
        .{ "-1 +2:03:04", .{ .days = -1, .time = 2 * h + 3 * m + 4 * usecs_per_sec }, .{ .days = -1, .time = 2 * h + 3 * m + 4 * usecs_per_sec } },
        .{ "1 -2:00", .{ .days = 1, .time = -2 * h }, .{ .days = 1, .time = -2 * h } },
        // ISO 8601: no such rule.
        .{ "P-1DT2H", .{ .days = -1, .time = 2 * h }, .{ .days = -1, .time = 2 * h } },
    };
    for (cases) |cs| {
        try testing.expectEqual(cs[1], try decodeIn(cs[0], -1, false));
        try testing.expectEqual(cs[2], try decodeIn(cs[0], -1, true));
    }
}

test "pg interval input: ISO 8601" {
    const h = usecs_per_hour;
    try expectIv("P1Y2M3DT4H5M6.5S", -1, .{ .months = 14, .days = 3, .time = 4 * h + 5 * usecs_per_minute + 6_500_000 });
    try expectIv("P0002-10-15T10:30:20", -1, .{ .months = 34, .days = 15, .time = 10 * h + 30 * usecs_per_minute + 20 * usecs_per_sec });
    try expectIv("P00021015T103020", -1, .{ .months = 34, .days = 15, .time = 10 * h + 30 * usecs_per_minute + 20 * usecs_per_sec });
    try expectIv("PT10:30", -1, .{ .time = 10 * h + 30 * usecs_per_minute });
    try expectIv("P1.5Y", -1, .{ .months = 18 });
    try testing.expectError(error.Syntax, decode("p1y", -1));
    try testing.expectError(error.FieldOverflow, decode("P2147483648", -1));
}

test "pg interval input: type modifiers" {
    const h = usecs_per_hour;
    const m = usecs_per_minute;
    try expectIv("1", typmod(year | month, full_precision), .{ .months = 1 });
    try expectIv("999", typmod(month, full_precision), .{ .months = 999 });
    try expectIv("1 2", typmod(day | hour, full_precision), .{ .days = 1, .time = 2 * h });
    try expectIv("1 2:03", typmod(day | hour, full_precision), .{ .days = 1, .time = 2 * h });
    try expectIv("1 2:03", typmod(minute | second, full_precision), .{ .days = 1, .time = 2 * m + 3 * usecs_per_sec });
    try expectIv("1 -2:03", typmod(minute | second, full_precision), .{ .days = 1, .time = -(2 * m + 3 * usecs_per_sec) });
    try expectIv("1 day 01:23:45.6789", typmod(full_range, 2), .{ .days = 1, .time = h + 23 * m + 45_680_000 });
    try expectIv("12:34.5678", typmod(minute | second, 2), .{ .time = 12 * m + 34_570_000 });
    try testing.expectError(error.Syntax, decode("1 2", typmod(day | hour | minute, full_precision)));
    try testing.expectError(error.Syntax, decode("123 11", typmod(day, full_precision)));
    try testing.expectError(error.IntervalRange, decode("2562047788:00:54.775807", typmod(second, 2)));
    try testing.expectEqual(typmod(year | month, full_precision), typmodOfDecl("interval year to month"));
    try testing.expectEqual(typmod(day | hour | minute | second, 3), typmodOfDecl("INTERVAL DAY TO SECOND(3)"));
    try testing.expectEqual(typmod(full_range, 2), typmodOfDecl("interval(2)"));
    try testing.expectEqual(@as(i32, -1), typmodOfDecl("interval"));
    // Clamped as the column's type and a cast are (types.intervalTypmod()).
    try testing.expectEqual(typmod(full_range, 6), typmodOfDecl("interval(7)"));
    var buf: [48]u8 = undefined;
    for (range_names) |r| {
        try testing.expectEqual(r[0], rangeOfText(r[1]).?);
        try testing.expectEqualStrings(r[1], typmodText(&buf, typmod(r[0], full_precision))[1..]);
    }
    try testing.expectEqualStrings(" day to second(3)", typmodText(&buf, typmod(day | hour | minute | second, 3)));
    try testing.expectEqualStrings("(2)", typmodText(&buf, typmod(full_range, 2)));
}
