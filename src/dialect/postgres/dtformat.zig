//! PostgreSQL 18's datetime template patterns (formatting.c, its DCH_*
//! part): to_char() of a timestamp, timestamptz, date or interval, and
//! to_timestamp() and to_date() of text. The template is parsed as
//! parse_format() does (keywords with their FM/TM prefixes and TH/th/SP
//! suffixes, "quoted literal text", a backslash before a double quote),
//! formatted as DCH_to_char() does and read as DCH_from_char() and
//! do_to_timestamp() do, with PostgreSQL's error messages and SQLSTATEs
//! (their DETAIL and HINT left out).
//!
//! Not supported, or different:
//!  - Only the C locale: TM writes and reads the English names (it only
//!    drops the padding of MONTH, DAY ..., as PostgreSQL's TM does);
//!  - the session time zone is always UTC: a timestamptz formats with
//!    offset 0 and TZ "UTC", a timestamp with TZ empty; to_timestamp()
//!    without a zone in its input takes it as UTC;
//!  - a zone abbreviation that to_timestamp() reads (TZ) has the offset
//!    of PostgreSQL's default abbreviation set (pg_timezone_abbrevs);
//!    those that PostgreSQL resolves through a zone (MSK, ...) always
//!    have their present offset, whatever the date;
//!  - not the SQL/JSON datetime mode (`std`) of parse_datetime();
//!  - SP is accepted and ignored, as PostgreSQL does.
//!
//! The functions are pure: the caller checks for an empty template or an
//! infinite value (to_char() is NULL for those).

const std = @import("std");
const calendar = @import("datetime").calendar;
const ivl = @import("datetime").interval;
const numformat = @import("numformat.zig");

/// The error of a failed call: PostgreSQL's SQLSTATE and message.
pub const Diag = numformat.Diag;

/// Failed: `diag` holds the message (allocated with the allocator given).
pub const Error = numformat.Error;

const Allocator = std.mem.Allocator;

const invalid_datetime_format = "22007";
const datetime_out_of_range = "22008";
const invalid_tz_displacement = "22009";

const usecs_per_sec: i64 = 1_000_000;
const usecs_per_minute: i64 = 60 * usecs_per_sec;
const usecs_per_hour: i64 = 3600 * usecs_per_sec;
const usecs_per_day: i64 = 24 * usecs_per_hour;

/// Julian day of 2000-01-01 (PostgreSQL's epoch) and of 1970-01-01.
const postgres_epoch_jdate: i64 = 2451545;
const unix_epoch_jdate: i64 = 2440588;
/// Microseconds from 1970-01-01 to 2000-01-01.
const epoch_shift: i64 = (postgres_epoch_jdate - unix_epoch_jdate) * usecs_per_day;
/// PostgreSQL's MIN_TIMESTAMP and END_TIMESTAMP (since 2000).
const min_timestamp: i64 = -211813488000000000;
const end_timestamp: i64 = 9223371331200000000;
/// DATE_END_JULIAN.
const date_end_julian: i64 = 2147483494;
const max_tzdisp_hour = 15;

// ============================================================ keywords

const Mode = enum(u2) { none, gregorian, isoweek };

/// DCH_poz: what a keyword formats or reads. The lower-case keywords
/// that behave as their upper-case ones share their id.
const Id = enum {
    A_D,
    A_M,
    AD,
    AM,
    B_C,
    BC,
    CC,
    DAY,
    DDD,
    DD,
    DY,
    Day,
    Dy,
    D,
    FF1,
    FF2,
    FF3,
    FF4,
    FF5,
    FF6,
    FX,
    HH24,
    HH12,
    HH,
    IDDD,
    ID,
    IW,
    IYYY,
    IYY,
    IY,
    I,
    J,
    MI,
    MM,
    MONTH,
    MON,
    MS,
    Month,
    Mon,
    OF,
    P_M,
    PM,
    Q,
    RM,
    SSSS,
    SS,
    TZH,
    TZM,
    TZ,
    US,
    WW,
    W,
    Y_YYY,
    YYYY,
    YYY,
    YY,
    Y,
    a_d,
    a_m,
    ad,
    am,
    b_c,
    bc,
    day,
    dy,
    month,
    mon,
    p_m,
    pm,
    rm,
    tz,
};

const Keyword = struct { name: []const u8, id: Id, digit: bool, mode: Mode };

fn k(name: []const u8, id: Id, digit: bool, mode: Mode) Keyword {
    return .{ .name = name, .id = id, .digit = digit, .mode = mode };
}

/// DCH_keywords, in its order: of the keywords that start with the same
/// letter, the first that the template starts with is taken ("HH24"
/// before "HH").
const keywords = [_]Keyword{
    k("A.D.", .A_D, false, .none),
    k("A.M.", .A_M, false, .none),
    k("AD", .AD, false, .none),
    k("AM", .AM, false, .none),
    k("B.C.", .B_C, false, .none),
    k("BC", .BC, false, .none),
    k("CC", .CC, true, .none),
    k("DAY", .DAY, false, .none),
    k("DDD", .DDD, true, .gregorian),
    k("DD", .DD, true, .gregorian),
    k("DY", .DY, false, .none),
    k("Day", .Day, false, .none),
    k("Dy", .Dy, false, .none),
    k("D", .D, true, .gregorian),
    k("FF1", .FF1, true, .none),
    k("FF2", .FF2, true, .none),
    k("FF3", .FF3, true, .none),
    k("FF4", .FF4, true, .none),
    k("FF5", .FF5, true, .none),
    k("FF6", .FF6, true, .none),
    k("FX", .FX, false, .none),
    k("HH24", .HH24, true, .none),
    k("HH12", .HH12, true, .none),
    k("HH", .HH, true, .none),
    k("IDDD", .IDDD, true, .isoweek),
    k("ID", .ID, true, .isoweek),
    k("IW", .IW, true, .isoweek),
    k("IYYY", .IYYY, true, .isoweek),
    k("IYY", .IYY, true, .isoweek),
    k("IY", .IY, true, .isoweek),
    k("I", .I, true, .isoweek),
    k("J", .J, true, .none),
    k("MI", .MI, true, .none),
    k("MM", .MM, true, .gregorian),
    k("MONTH", .MONTH, false, .gregorian),
    k("MON", .MON, false, .gregorian),
    k("MS", .MS, true, .none),
    k("Month", .Month, false, .gregorian),
    k("Mon", .Mon, false, .gregorian),
    k("OF", .OF, false, .none),
    k("P.M.", .P_M, false, .none),
    k("PM", .PM, false, .none),
    k("Q", .Q, true, .none),
    k("RM", .RM, false, .gregorian),
    k("SSSSS", .SSSS, true, .none),
    k("SSSS", .SSSS, true, .none),
    k("SS", .SS, true, .none),
    k("TZH", .TZH, false, .none),
    k("TZM", .TZM, true, .none),
    k("TZ", .TZ, false, .none),
    k("US", .US, true, .none),
    k("WW", .WW, true, .gregorian),
    k("W", .W, true, .gregorian),
    k("Y,YYY", .Y_YYY, true, .gregorian),
    k("YYYY", .YYYY, true, .gregorian),
    k("YYY", .YYY, true, .gregorian),
    k("YY", .YY, true, .gregorian),
    k("Y", .Y, true, .gregorian),
    k("a.d.", .a_d, false, .none),
    k("a.m.", .a_m, false, .none),
    k("ad", .ad, false, .none),
    k("am", .am, false, .none),
    k("b.c.", .b_c, false, .none),
    k("bc", .bc, false, .none),
    k("cc", .CC, true, .none),
    k("day", .day, false, .none),
    k("ddd", .DDD, true, .gregorian),
    k("dd", .DD, true, .gregorian),
    k("dy", .dy, false, .none),
    k("d", .D, true, .gregorian),
    k("ff1", .FF1, true, .none),
    k("ff2", .FF2, true, .none),
    k("ff3", .FF3, true, .none),
    k("ff4", .FF4, true, .none),
    k("ff5", .FF5, true, .none),
    k("ff6", .FF6, true, .none),
    k("fx", .FX, false, .none),
    k("hh24", .HH24, true, .none),
    k("hh12", .HH12, true, .none),
    k("hh", .HH, true, .none),
    k("iddd", .IDDD, true, .isoweek),
    k("id", .ID, true, .isoweek),
    k("iw", .IW, true, .isoweek),
    k("iyyy", .IYYY, true, .isoweek),
    k("iyy", .IYY, true, .isoweek),
    k("iy", .IY, true, .isoweek),
    k("i", .I, true, .isoweek),
    k("j", .J, true, .none),
    k("mi", .MI, true, .none),
    k("mm", .MM, true, .gregorian),
    k("month", .month, false, .gregorian),
    k("mon", .mon, false, .gregorian),
    k("ms", .MS, true, .none),
    k("of", .OF, false, .none),
    k("p.m.", .p_m, false, .none),
    k("pm", .pm, false, .none),
    k("q", .Q, true, .none),
    k("rm", .rm, false, .gregorian),
    k("sssss", .SSSS, true, .none),
    k("ssss", .SSSS, true, .none),
    k("ss", .SS, true, .none),
    k("tzh", .TZH, false, .none),
    k("tzm", .TZM, true, .none),
    k("tz", .tz, false, .none),
    k("us", .US, true, .none),
    k("ww", .WW, true, .gregorian),
    k("w", .W, true, .gregorian),
    k("y,yyy", .Y_YYY, true, .gregorian),
    k("yyyy", .YYYY, true, .gregorian),
    k("yyy", .YYY, true, .gregorian),
    k("yy", .YY, true, .gregorian),
    k("y", .Y, true, .gregorian),
};

// Suffixes (a node's `suffix` is an OR of these).
const s_fm: u8 = 0x01;
const s_TH: u8 = 0x02;
const s_th: u8 = 0x04;
const s_sp: u8 = 0x08;
const s_tm: u8 = 0x10;

const Suffix = struct { name: []const u8, id: u8, prefix: bool };

/// DCH_suff.
const suffixes = [_]Suffix{
    .{ .name = "FM", .id = s_fm, .prefix = true },
    .{ .name = "fm", .id = s_fm, .prefix = true },
    .{ .name = "TM", .id = s_tm, .prefix = true },
    .{ .name = "tm", .id = s_tm, .prefix = true },
    .{ .name = "TH", .id = s_TH, .prefix = false },
    .{ .name = "th", .id = s_th, .prefix = false },
    .{ .name = "SP", .id = s_sp, .prefix = false },
};

const months_full = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const months_short = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const days_full = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const days_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
/// AD at even indexes, BC at odd ones; AM and PM the same.
const adbc = [_][]const u8{ "ad", "bc", "AD", "BC" };
const adbc_long = [_][]const u8{ "a.d.", "b.c.", "A.D.", "B.C." };
const ampm = [_][]const u8{ "am", "pm", "AM", "PM" };
const ampm_long = [_][]const u8{ "a.m.", "p.m.", "A.M.", "P.M." };
/// December first, so that "VIII" is tried before "V".
const rm_upper = [_][]const u8{ "XII", "XI", "X", "IX", "VIII", "VII", "VI", "V", "IV", "III", "II", "I" };
const rm_lower = [_][]const u8{ "xii", "xi", "x", "ix", "viii", "vii", "vi", "v", "iv", "iii", "ii", "i" };

// ============================================================ the template

const Node = struct {
    kind: enum { action, char, separator, space },
    /// The character of a char, separator or space node.
    text: []const u8 = "",
    key: *const Keyword = undefined,
    suffix: u8 = 0,
};

const charLen = numformat.charLen;

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// An ASCII printable character, not a letter or a digit.
fn isSeparatorChar(c: u8) bool {
    return c > 0x20 and c < 0x7f and !std.ascii.isAlphanumeric(c);
}

/// The keywords of each first character: keywords[lo..hi] (DCH_index).
const keyword_index = blk: {
    var index: [128]struct { lo: u16, hi: u16 } = @splat(.{ .lo = 0, .hi = 0 });
    for (keywords, 0..) |kw, i| {
        const c = kw.name[0];
        if (index[c].hi == 0) {
            index[c] = .{ .lo = i, .hi = i + 1 };
        } else if (index[c].hi == i) {
            index[c].hi = i + 1;
        } else @compileError("the keywords of a first character are together");
    }
    break :blk index;
};

fn findKeyword(s: []const u8) ?*const Keyword {
    if (s[0] >= keyword_index.len) return null;
    const r = keyword_index[s[0]];
    for (keywords[r.lo..r.hi]) |*kw| {
        if (std.mem.startsWith(u8, s, kw.name)) return kw;
    }
    return null;
}

fn findSuffix(s: []const u8, prefix: bool) ?*const Suffix {
    for (&suffixes) |*sf| {
        if (sf.prefix == prefix and std.mem.startsWith(u8, s, sf.name)) return sf;
    }
    return null;
}

/// A parsed template; its nodes refer to the template's text.
pub const Template = struct {
    nodes: []const Node,

    pub fn deinit(t: Template, a: Allocator) void {
        a.free(t.nodes);
    }
};

/// parse_format() of a DCH template.
pub fn parse(a: Allocator, fmt: []const u8) Allocator.Error!Template {
    return .{ .nodes = try parseFormat(a, fmt) };
}

fn parseFormat(a: Allocator, fmt: []const u8) Allocator.Error![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(a);
    var i: usize = 0;
    while (i < fmt.len) {
        var suffix: u8 = 0;
        if (findSuffix(fmt[i..], true)) |sf| {
            suffix |= sf.id;
            i += sf.name.len;
        }
        if (i < fmt.len) {
            if (findKeyword(fmt[i..])) |kw| {
                i += kw.name.len;
                var n: Node = .{ .kind = .action, .key = kw, .suffix = suffix };
                if (i < fmt.len) {
                    if (findSuffix(fmt[i..], false)) |sf| {
                        n.suffix |= sf.id;
                        i += sf.name.len;
                    }
                }
                try nodes.append(a, n);
                continue;
            }
        }
        if (i >= fmt.len) break;
        if (fmt[i] == '"') {
            // A quoted literal; a backslash quotes the next character.
            i += 1;
            while (i < fmt.len) {
                if (fmt[i] == '"') {
                    i += 1;
                    break;
                }
                if (fmt[i] == '\\' and i + 1 < fmt.len) i += 1;
                const l = charLen(fmt, i);
                try nodes.append(a, .{ .kind = .char, .text = fmt[i .. i + l] });
                i += l;
            }
        } else {
            // Outside quotes a backslash only escapes a double quote.
            if (fmt[i] == '\\' and i + 1 < fmt.len and fmt[i + 1] == '"') i += 1;
            const l = charLen(fmt, i);
            const c = fmt[i];
            try nodes.append(a, .{
                .kind = if (isSeparatorChar(c)) .separator else if (isSpace(c)) .space else .char,
                .text = fmt[i .. i + l],
            });
            i += l;
        }
    }
    return nodes.toOwnedSlice(a);
}

fn fail(a: Allocator, diag: *Diag, state: *const [5]u8, comptime fmt: []const u8, args: anytype) Error {
    return failFields(a, diag, state, null, null, fmt, args);
}

/// fail() with PostgreSQL's DETAIL and HINT.
fn failFields(a: Allocator, diag: *Diag, state: *const [5]u8, detail: ?[]const u8, hint: ?[]const u8, comptime fmt: []const u8, args: anytype) Error {
    diag.state = state.*;
    diag.fields = .{ .message = try std.fmt.allocPrint(a, fmt, args), .detail = detail, .hint = hint };
    return error.Failed;
}

/// The HINT of a field of a fixed width the input does not fill.
const fm_hint = "If your source string is not fixed-width, try using the \"FM\" modifier.";

// ============================================================ calendar

/// date2j(): the Julian day of a date (astronomical years), as
/// PostgreSQL computes it (also for the fields of an interval).
fn date2j(year_in: i64, month_in: i64, day: i64) i64 {
    var year = year_in;
    var month = month_in;
    if (month > 2) {
        month += 1;
        year += 4800;
    } else {
        month += 13;
        year += 4799;
    }
    const century = @divTrunc(year, 100);
    var julian = year * 365 - 32167;
    julian += @divTrunc(year, 4) - century + @divTrunc(century, 4);
    julian += @divTrunc(7834 * month, 256) + day;
    return julian;
}

const Ymd = struct { year: i32, mon: i32, mday: i32 };

/// j2date(), with its unsigned arithmetic.
fn j2date(jd: i64) Ymd {
    const jd32: i32 = @truncate(jd);
    var julian: u32 = @bitCast(jd32);
    julian +%= 32044;
    var quad: u32 = julian / 146097;
    const extra: u32 = (julian -% quad *% 146097) *% 4 +% 3;
    julian +%= 60 +% quad *% 3 +% extra / 146097;
    quad = julian / 1461;
    julian -%= quad *% 1461;
    var y: i32 = @intCast(julian * 4 / 1461);
    julian = (if (y != 0) (julian + 305) % 365 else (julian + 306) % 366) + 123;
    y = @bitCast(@as(u32, @bitCast(y)) +% quad *% 4);
    quad = julian * 2141 / 65536;
    return .{
        .year = y -% 4800,
        .mon = @intCast((quad + 10) % 12 + 1),
        .mday = @intCast(julian - 7834 * quad / 256),
    };
}

/// j2day(): 0 is Sunday.
fn j2day(j: i64) i64 {
    return @mod(j + 1, 7);
}

fn isoweek2j(year: i64, week: i64) i64 {
    const day4 = date2j(year, 1, 4);
    const day0 = j2day(day4 - 1);
    return (week - 1) * 7 + (day4 - day0);
}

fn date2isoweek(year: i64, mon: i64, mday: i64) i64 {
    const dayn = date2j(year, mon, mday);
    var day4 = date2j(year, 1, 4);
    var day0 = j2day(day4 - 1);
    if (dayn < day4 - day0) {
        day4 = date2j(year - 1, 1, 4);
        day0 = j2day(day4 - 1);
    }
    var result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    if (result >= 52) {
        day4 = date2j(year + 1, 1, 4);
        day0 = j2day(day4 - 1);
        if (dayn >= day4 - day0) result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    }
    return result;
}

/// The ISO 8601 year (year 0 exists).
fn date2isoyear(year_in: i64, mon: i64, mday: i64) i64 {
    var year = year_in;
    const dayn = date2j(year, mon, mday);
    var day4 = date2j(year, 1, 4);
    var day0 = j2day(day4 - 1);
    if (dayn < day4 - day0) {
        day4 = date2j(year - 1, 1, 4);
        day0 = j2day(day4 - 1);
        year -= 1;
    }
    const result = @divTrunc(dayn - (day4 - day0), 7) + 1;
    if (result >= 52) {
        day4 = date2j(year + 1, 1, 4);
        day0 = j2day(day4 - 1);
        if (dayn >= day4 - day0) year += 1;
    }
    return year;
}

fn date2isoyearday(year: i64, mon: i64, mday: i64) i64 {
    return date2j(year, mon, mday) - isoweek2j(date2isoyear(year, mon, mday), 1) + 1;
}

/// IS_VALID_JULIAN().
fn validJulian(y: i64, m: i64) bool {
    return (y > -4713 or (y == -4713 and m >= 11)) and (y < 5874898 or (y == 5874898 and m < 6));
}

// ============================================================ to_char

const Tm = struct {
    sec: i32 = 0,
    min: i32 = 0,
    hour: i64 = 0,
    mday: i32 = 1,
    mon: i32 = 1,
    year: i32 = 0,
    wday: i32 = 0,
    yday: i64 = 0,
    gmtoff: i64 = 0,
};

const ToChar = struct { tm: Tm = .{}, fsec: i64 = 0, tzn: ?[]const u8 = null };

/// to_char(timestamp/timestamptz/date, fmt). `us`: microseconds since
/// 1970-01-01 00:00 UTC (a date is midnight). tz: whether timestamptz.
/// An empty `fmt` gives "" (PostgreSQL's NULL is the caller's).
pub fn timestampToChar(a: Allocator, us: i64, tz: bool, fmt: Template, diag: *Diag) Error![]u8 {
    // timestamp2tm()
    const dt = std.math.sub(i64, us, epoch_shift) catch
        return fail(a, diag, datetime_out_of_range, "timestamp out of range", .{});
    var date = @divTrunc(dt, usecs_per_day);
    var time = dt - date * usecs_per_day;
    if (time < 0) {
        time += usecs_per_day;
        date -= 1;
    }
    date += postgres_epoch_jdate;
    if (date < 0 or date > std.math.maxInt(i32))
        return fail(a, diag, datetime_out_of_range, "timestamp out of range", .{});
    const ymd = j2date(date);
    var in: ToChar = .{};
    in.tm.year = ymd.year;
    in.tm.mon = ymd.mon;
    in.tm.mday = ymd.mday;
    in.tm.hour = @divTrunc(time, usecs_per_hour);
    time -= in.tm.hour * usecs_per_hour;
    in.tm.min = @intCast(@divTrunc(time, usecs_per_minute));
    time -= @as(i64, in.tm.min) * usecs_per_minute;
    in.tm.sec = @intCast(@divTrunc(time, usecs_per_sec));
    in.fsec = time - @as(i64, in.tm.sec) * usecs_per_sec;
    const thisdate = date2j(ymd.year, ymd.mon, ymd.mday);
    in.tm.wday = @intCast(@rem(thisdate + 1, 7));
    in.tm.yday = thisdate - date2j(ymd.year, 1, 1) + 1;
    if (tz) in.tzn = "UTC";
    return format(a, fmt, false, &in, diag);
}

/// to_char(interval, fmt), as interval_to_char(): years and months from
/// the months, the days, and hours that may exceed 24. Not for infinite
/// intervals. An empty `fmt` gives "".
pub fn intervalToChar(a: Allocator, iv: ivl.Interval, fmt: Template, diag: *Diag) Error![]u8 {
    var in: ToChar = .{};
    // interval2itm()
    in.tm.year = @divTrunc(iv.months, 12);
    in.tm.mon = @rem(iv.months, 12);
    in.tm.mday = iv.days;
    var time = iv.time;
    in.tm.hour = @divTrunc(time, usecs_per_hour);
    time -= in.tm.hour * usecs_per_hour;
    in.tm.min = @intCast(@divTrunc(time, usecs_per_minute));
    time -= @as(i64, in.tm.min) * usecs_per_minute;
    in.tm.sec = @intCast(@divTrunc(time, usecs_per_sec));
    in.fsec = time - @as(i64, in.tm.sec) * usecs_per_sec;
    // wday is meaningless, yday approximates the span in days.
    in.tm.yday = (@as(i64, in.tm.year) * 12 + in.tm.mon) * 30 + in.tm.mday;
    return format(a, fmt, true, &in, diag);
}

fn format(a: Allocator, fmt: Template, is_interval: bool, in: *const ToChar, diag: *Diag) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (fmt.nodes) |*n| {
        if (n.kind != .action) {
            try out.appendSlice(a, n.text);
            continue;
        }
        try toChar(a, &out, n, is_interval, in, diag);
    }
    return out.toOwnedSlice(a);
}

/// C's "%0*d": zero-padded to `width` characters, the sign among them.
fn cInt(buf: []u8, v: i64, width: usize) []const u8 {
    var digits: [24]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{@abs(v)}) catch unreachable;
    var n: usize = 0;
    if (v < 0) {
        buf[0] = '-';
        n = 1;
    }
    if (width > n + d.len) {
        @memset(buf[n .. width - d.len], '0');
        n = width - d.len;
    }
    @memcpy(buf[n .. n + d.len], d);
    return buf[0 .. n + d.len];
}

/// ADJUST_YEAR(): there is no year 0 for a timestamp (1 BC is year 1).
fn adjustYear(year: i64, is_interval: bool) i64 {
    return if (is_interval) year else if (year <= 0) -(year - 1) else year;
}

const Case = enum { upper, initcap, lower };

fn toChar(a: Allocator, out: *std.ArrayList(u8), n: *const Node, is_interval: bool, in: *const ToChar, diag: *Diag) Error!void {
    const tm = &in.tm;
    const fm = n.suffix & s_fm != 0;
    const tm_mode = n.suffix & s_tm != 0;
    const id = n.key.id;
    const pm = @rem(tm.hour, 24) >= 12;
    switch (id) {
        .tz, .TZ, .TZH, .TZM, .OF, .A_D, .B_C, .AD, .BC, .a_d, .b_c, .ad, .bc, .MONTH, .Month, .month, .MON, .Mon, .mon, .DAY, .Day, .day, .DY, .Dy, .dy, .D, .ID => if (is_interval)
            return fail(a, diag, invalid_datetime_format, "invalid format specification for an interval value", .{}),
        else => {},
    }
    const W = struct {
        out: *std.ArrayList(u8),
        a: Allocator,
        suffix: u8,
        fn str(w: @This(), s: []const u8) Allocator.Error!void {
            try w.out.appendSlice(w.a, s);
        }
        /// A number, then its TH/th suffix if asked for.
        fn num(w: @This(), v: i64, width: usize) Allocator.Error!void {
            var buf: [32]u8 = undefined;
            const s = cInt(&buf, v, width);
            try w.out.appendSlice(w.a, s);
            if (w.suffix & (s_TH | s_th) != 0) try w.out.appendSlice(w.a, numformat.ordinal(s, w.suffix & s_TH != 0));
        }
        /// "%*s": left-justified in `width` columns.
        fn padded(w: @This(), s: []const u8, width: usize) Allocator.Error!void {
            try w.out.appendSlice(w.a, s);
            if (s.len < width) try w.out.appendNTimes(w.a, ' ', width - s.len);
        }
        fn cased(w: @This(), s: []const u8, case: Case) Allocator.Error!void {
            for (s, 0..) |c, i| try w.out.append(w.a, switch (case) {
                .upper => std.ascii.toUpper(c),
                .lower => std.ascii.toLower(c),
                .initcap => if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c),
            });
        }
        /// A month or day name: cased, padded to 9 unless FM or TM.
        fn name(w: @This(), s: []const u8, case: Case, pad: bool) Allocator.Error!void {
            const start = w.out.items.len;
            try w.cased(s, case);
            const l = w.out.items.len - start;
            if (pad and l < 9) try w.out.appendNTimes(w.a, ' ', 9 - l);
        }
    };
    const w: W = .{ .out = out, .a = a, .suffix = n.suffix };
    const fw = struct {
        fn width(f: bool, nonneg: bool, wpos: usize) usize {
            return if (f) 0 else if (nonneg) wpos else wpos + 1;
        }
    }.width;
    const gmt_abs: i64 = @intCast(@abs(tm.gmtoff));
    const pad = !fm and !tm_mode;
    switch (id) {
        .A_M, .P_M => try w.str(if (pm) "P.M." else "A.M."),
        .AM, .PM => try w.str(if (pm) "PM" else "AM"),
        .a_m, .p_m => try w.str(if (pm) "p.m." else "a.m."),
        .am, .pm => try w.str(if (pm) "pm" else "am"),
        .HH, .HH12 => {
            const h = @rem(tm.hour, 12);
            try w.num(if (h == 0) 12 else h, fw(fm, tm.hour >= 0, 2));
        },
        .HH24 => try w.num(tm.hour, fw(fm, tm.hour >= 0, 2)),
        .MI => try w.num(tm.min, fw(fm, tm.min >= 0, 2)),
        .SS => try w.num(tm.sec, fw(fm, tm.sec >= 0, 2)),
        .FF1 => try w.num(@divTrunc(in.fsec, 100000), 1),
        .FF2 => try w.num(@divTrunc(in.fsec, 10000), 2),
        .FF3, .MS => try w.num(@divTrunc(in.fsec, 1000), 3),
        .FF4 => try w.num(@divTrunc(in.fsec, 100), 4),
        .FF5 => try w.num(@divTrunc(in.fsec, 10), 5),
        .FF6, .US => try w.num(in.fsec, 6),
        .SSSS => try w.num(tm.hour * 3600 + @as(i64, tm.min) * 60 + tm.sec, 0),
        .tz => if (in.tzn) |z| try w.cased(z, .lower),
        .TZ => if (in.tzn) |z| try w.str(z),
        .TZH => {
            try w.str(if (tm.gmtoff >= 0) "+" else "-");
            var buf: [32]u8 = undefined;
            try w.str(cInt(&buf, @divTrunc(gmt_abs, 3600), 2));
        },
        .TZM => {
            var buf: [32]u8 = undefined;
            try w.str(cInt(&buf, @divTrunc(@rem(gmt_abs, 3600), 60), 2));
        },
        .OF => {
            try w.str(if (tm.gmtoff >= 0) "+" else "-");
            var buf: [32]u8 = undefined;
            try w.str(cInt(&buf, @divTrunc(gmt_abs, 3600), if (fm) 0 else 2));
            if (@rem(gmt_abs, 3600) != 0) {
                try w.str(":");
                try w.str(cInt(&buf, @divTrunc(@rem(gmt_abs, 3600), 60), 2));
            }
        },
        .A_D, .B_C => try w.str(if (tm.year <= 0) "B.C." else "A.D."),
        .AD, .BC => try w.str(if (tm.year <= 0) "BC" else "AD"),
        .a_d, .b_c => try w.str(if (tm.year <= 0) "b.c." else "a.d."),
        .ad, .bc => try w.str(if (tm.year <= 0) "bc" else "ad"),
        .MONTH, .Month, .month => if (tm.mon >= 1 and tm.mon <= 12) {
            const s = months_full[@intCast(tm.mon - 1)];
            try w.name(s, if (id == .MONTH) .upper else if (id == .Month) .initcap else .lower, pad);
        },
        .MON, .Mon, .mon => if (tm.mon >= 1 and tm.mon <= 12) {
            const s = months_short[@intCast(tm.mon - 1)];
            try w.name(s, if (id == .MON) .upper else if (id == .Mon) .initcap else .lower, false);
        },
        .MM => try w.num(tm.mon, fw(fm, tm.mon >= 0, 2)),
        .DAY, .Day, .day => {
            const s = days_full[@intCast(tm.wday)];
            try w.name(s, if (id == .DAY) .upper else if (id == .Day) .initcap else .lower, pad);
        },
        .DY, .Dy, .dy => {
            const s = days_short[@intCast(tm.wday)];
            try w.name(s, if (id == .DY) .upper else if (id == .Dy) .initcap else .lower, false);
        },
        .DDD => try w.num(tm.yday, if (fm) 0 else 3),
        .IDDD => try w.num(date2isoyearday(tm.year, tm.mon, tm.mday), if (fm) 0 else 3),
        .DD => try w.num(tm.mday, if (fm) 0 else 2),
        .D => try w.num(tm.wday + 1, 0),
        .ID => try w.num(if (tm.wday == 0) 7 else tm.wday, 0),
        .WW => try w.num(@divTrunc(tm.yday - 1, 7) + 1, if (fm) 0 else 2),
        .IW => try w.num(date2isoweek(tm.year, tm.mon, tm.mday), if (fm) 0 else 2),
        .Q => if (tm.mon != 0) try w.num(@divTrunc(tm.mon - 1, 3) + 1, 0),
        .CC => {
            const i: i64 = if (is_interval)
                @divTrunc(tm.year, 100)
            else if (tm.year > 0)
                @divTrunc(tm.year - 1, 100) + 1 // century 20 is 1901-2000
            else
                @divTrunc(tm.year, 100) - 1; // century 6 BC is 600-501 BC
            try w.num(i, if (i <= 99 and i >= -99) fw(fm, i >= 0, 2) else 0);
        },
        .Y_YYY => {
            const y = adjustYear(tm.year, is_interval);
            const i = @divTrunc(y, 1000);
            var buf: [32]u8 = undefined;
            try w.str(cInt(&buf, i, 0));
            try w.str(",");
            try w.num(y - i * 1000, 3);
        },
        .YYYY, .IYYY, .YYY, .IYY, .YY, .IY, .Y, .I => {
            const y = adjustYear(tm.year, is_interval);
            const v = switch (id) {
                .IYYY, .IYY, .IY, .I => adjustYear(date2isoyear(tm.year, tm.mon, tm.mday), is_interval),
                else => y,
            };
            switch (id) {
                .YYYY, .IYYY => try w.num(v, fw(fm, y >= 0, 4)),
                .YYY, .IYY => try w.num(@rem(v, 1000), fw(fm, y >= 0, 3)),
                .YY, .IY => try w.num(@rem(v, 100), fw(fm, y >= 0, 2)),
                else => try w.num(@rem(v, 10), 1),
            }
        },
        .RM, .rm => if (tm.mon != 0 or tm.year != 0) {
            // The table is reversed, December first. A whole number of
            // interval years is month 0.
            const mon: i64 = if (tm.mon == 0)
                (if (tm.year >= 0) 0 else 11)
            else if (tm.mon < 0)
                -(@as(i64, tm.mon) + 1)
            else
                12 - @as(i64, tm.mon);
            const months = if (id == .RM) &rm_upper else &rm_lower;
            if (mon >= 0 and mon < 12) try w.padded(months[@intCast(mon)], if (fm) 0 else 4);
        },
        .W => try w.num(@divTrunc(tm.mday - 1, 7) + 1, 0),
        .J => try w.num(date2j(tm.year, tm.mon, tm.mday), 0),
        .FX => {},
    }
}

// ============================================================ to_timestamp

/// TmFromChar: the fields read; 0 is "not given".
const FromChar = struct {
    mode: Mode = .none,
    hh: i32 = 0,
    pm: i32 = 0,
    mi: i32 = 0,
    ss: i32 = 0,
    ssss: i32 = 0,
    /// 1-7, Sunday is 1.
    d: i32 = 0,
    dd: i32 = 0,
    ddd: i32 = 0,
    mm: i32 = 0,
    ms: i32 = 0,
    year: i32 = 0,
    bc: i32 = 0,
    ww: i32 = 0,
    w: i32 = 0,
    cc: i32 = 0,
    j: i32 = 0,
    us: i32 = 0,
    yysz: i32 = 0,
    clock12: bool = false,
    /// +1, -1, or 0 without TZH/TZM.
    tzsign: i32 = 0,
    tzh: i32 = 0,
    tzm: i32 = 0,
    ff: i32 = 0,
    has_tz: bool = false,
    /// Of a TZ abbreviation, seconds east of UTC.
    gmtoffset: i32 = 0,
};

/// PostgreSQL's default time zone abbreviations (pg_timezone_abbrevs),
/// lower case and sorted, with their offsets in seconds east of UTC.
const zone_abbrevs = std.StaticStringMap(i32).initComptime(.{
    .{ "acdt", 37800 },  .{ "acsst", 37800 },  .{ "acst", 34200 },  .{ "act", -18000 },
    .{ "acwst", 31500 }, .{ "adt", -10800 },   .{ "aedt", 39600 },  .{ "aesst", 39600 },
    .{ "aest", 36000 },  .{ "aft", 16200 },    .{ "akdt", -28800 }, .{ "akst", -32400 },
    .{ "almst", 25200 }, .{ "almt", 21600 },   .{ "amst", 14400 },  .{ "amt", -14400 },
    .{ "anast", 43200 }, .{ "anat", 43200 },   .{ "arst", -10800 }, .{ "art", -10800 },
    .{ "ast", -14400 },  .{ "awsst", 32400 },  .{ "awst", 28800 },  .{ "azost", 0 },
    .{ "azot", -3600 },  .{ "azst", 14400 },   .{ "azt", 14400 },   .{ "bdst", 7200 },
    .{ "bdt", 21600 },   .{ "bnt", 28800 },    .{ "bort", 28800 },  .{ "bot", -14400 },
    .{ "bra", -10800 },  .{ "brst", -7200 },   .{ "brt", -10800 },  .{ "bst", 3600 },
    .{ "btt", 21600 },   .{ "cadt", 37800 },   .{ "cast", 34200 },  .{ "cct", 28800 },
    .{ "cdt", -18000 },  .{ "cest", 7200 },    .{ "cet", 3600 },    .{ "cetdst", 7200 },
    .{ "chadt", 49500 }, .{ "chast", 45900 },  .{ "chut", 36000 },  .{ "ckt", -36000 },
    .{ "clst", -10800 }, .{ "clt", -10800 },   .{ "cot", -18000 },  .{ "cst", -21600 },
    .{ "cxt", 25200 },   .{ "davt", 25200 },   .{ "ddut", 36000 },  .{ "easst", -18000 },
    .{ "east", -18000 }, .{ "eat", 10800 },    .{ "edt", -14400 },  .{ "eest", 10800 },
    .{ "eet", 7200 },    .{ "eetdst", 10800 }, .{ "egst", 0 },      .{ "egt", -3600 },
    .{ "est", -18000 },  .{ "fet", 10800 },    .{ "fjst", 46800 },  .{ "fjt", 43200 },
    .{ "fkst", -10800 }, .{ "fkt", -10800 },   .{ "fnst", -3600 },  .{ "fnt", -7200 },
    .{ "galt", -21600 }, .{ "gamt", -32400 },  .{ "gest", 14400 },  .{ "get", 14400 },
    .{ "gft", -10800 },  .{ "gilt", 43200 },   .{ "gmt", 0 },       .{ "gyt", -14400 },
    .{ "hkt", 28800 },   .{ "hst", -36000 },   .{ "ict", 25200 },   .{ "idt", 10800 },
    .{ "iot", 21600 },   .{ "irkst", 28800 },  .{ "irkt", 28800 },  .{ "irt", 12600 },
    .{ "ist", 7200 },    .{ "jayt", 32400 },   .{ "jst", 32400 },   .{ "kdt", 36000 },
    .{ "kgst", 21600 },  .{ "kgt", 21600 },    .{ "kost", 39600 },  .{ "krast", 25200 },
    .{ "krat", 25200 },  .{ "kst", 32400 },    .{ "lhdt", 39600 },  .{ "lhst", 37800 },
    .{ "ligt", 36000 },  .{ "lint", 50400 },   .{ "lkt", 19800 },   .{ "magst", 39600 },
    .{ "magt", 39600 },  .{ "mart", -34200 },  .{ "mawt", 18000 },  .{ "mdt", -21600 },
    .{ "mest", 7200 },   .{ "mesz", 7200 },    .{ "met", 3600 },    .{ "metdst", 7200 },
    .{ "mez", 3600 },    .{ "mht", 43200 },    .{ "mmt", 23400 },   .{ "mpt", 36000 },
    .{ "msd", 14400 },   .{ "msk", 10800 },    .{ "mst", -25200 },  .{ "must", 18000 },
    .{ "mut", 14400 },   .{ "mvt", 18000 },    .{ "myt", 28800 },   .{ "ndt", -9000 },
    .{ "nft", -12600 },  .{ "novst", 25200 },  .{ "novt", 25200 },  .{ "npt", 20700 },
    .{ "nst", -12600 },  .{ "nut", -39600 },   .{ "nzdt", 46800 },  .{ "nzst", 43200 },
    .{ "nzt", 43200 },   .{ "omsst", 21600 },  .{ "omst", 21600 },  .{ "pdt", -25200 },
    .{ "pet", -18000 },  .{ "petst", 43200 },  .{ "pett", 43200 },  .{ "pgt", 36000 },
    .{ "pht", 28800 },   .{ "pkst", 21600 },   .{ "pkt", 18000 },   .{ "pmdt", -7200 },
    .{ "pmst", -10800 }, .{ "pont", 39600 },   .{ "pst", -28800 },  .{ "pwt", 32400 },
    .{ "pyst", -10800 }, .{ "pyt", -10800 },   .{ "ret", 14400 },   .{ "sadt", 37800 },
    .{ "sast", 7200 },   .{ "sct", 14400 },    .{ "sgt", 28800 },   .{ "taht", -36000 },
    .{ "tft", 18000 },   .{ "tjt", 18000 },    .{ "tkt", 46800 },   .{ "tmt", 18000 },
    .{ "tot", 46800 },   .{ "trut", 36000 },   .{ "tvt", 43200 },   .{ "uct", 0 },
    .{ "ulast", 32400 }, .{ "ulat", 28800 },   .{ "ut", 0 },        .{ "utc", 0 },
    .{ "uyst", -7200 },  .{ "uyt", -10800 },   .{ "uzst", 21600 },  .{ "uzt", 18000 },
    .{ "vet", -14400 },  .{ "vlast", 36000 },  .{ "vlat", 36000 },  .{ "volt", 10800 },
    .{ "vut", 39600 },   .{ "wadt", 28800 },   .{ "wakt", 43200 },  .{ "wast", 25200 },
    .{ "wat", 3600 },    .{ "wdt", 32400 },    .{ "wet", 0 },       .{ "wetdst", 3600 },
    .{ "wft", 43200 },   .{ "wgst", -7200 },   .{ "wgt", -10800 },  .{ "xjt", 21600 },
    .{ "yakst", 32400 }, .{ "yakt", 32400 },   .{ "yapt", 36000 },  .{ "yekst", 21600 },
    .{ "yekt", 18000 },  .{ "z", 0 },          .{ "zulu", 0 },
});

/// The offset (seconds east of UTC) of zone abbreviation `name` (in any
/// case), null if it is none.
pub fn zoneAbbrev(name: []const u8) ?i32 {
    var low: [zone_abbrevs.max_len]u8 = undefined;
    if (name.len > low.len) return null;
    return zone_abbrevs.get(std.ascii.lowerString(&low, name));
}

/// DecodeTimezoneAbbrevPrefix(): the longest zone abbreviation that `s`
/// starts with (of its first letters, at most 10), and its offset.
fn zoneAbbrevPrefix(s: []const u8) ?struct { len: usize, offset: i32 } {
    var low: [10]u8 = undefined;
    var len: usize = 0;
    while (len < low.len and len < s.len and std.ascii.isAlphabetic(s[len])) : (len += 1) low[len] = std.ascii.toLower(s[len]);
    while (len > 0) : (len -= 1) {
        if (zone_abbrevs.get(low[0..len])) |offset| return .{ .len = len, .offset = offset };
    }
    return null;
}

/// The parse of DCH_from_char(): the input and the position in it.
const Parser = struct {
    a: Allocator,
    diag: *Diag,
    in: []const u8,
    s: usize = 0,
    nodes: []const Node,
    out: FromChar = .{},

    fn at(p: *const Parser, i: usize) u8 {
        return if (i < p.in.len) p.in[i] else 0;
    }

    fn advance(p: *Parser, n: usize) void {
        p.s = @min(p.s + n, p.in.len);
    }

    fn skipSpaces(p: *Parser) usize {
        var n: usize = 0;
        while (p.s < p.in.len and isSpace(p.in[p.s])) : (p.s += 1) n += 1;
        return n;
    }

    /// SKIP_THth: two characters after a field with TH or th.
    fn skipTh(p: *Parser, suffix: u8) void {
        if (suffix & (s_TH | s_th) != 0) {
            p.advance(charLen(p.in, p.s));
            p.advance(charLen(p.in, p.s));
        }
    }

    fn setMode(p: *Parser, mode: Mode) Error!void {
        if (mode == .none) return;
        if (p.out.mode == .none) {
            p.out.mode = mode;
        } else if (p.out.mode != mode) {
            return failFields(p.a, p.diag, invalid_datetime_format, null, "Do not mix Gregorian and ISO week date conventions in a formatting template.", "invalid combination of date conventions", .{});
        }
    }

    /// from_char_set_int(): a field may only be given once (or again
    /// with the same value).
    fn setInt(p: *Parser, dest: *i32, value: i32, n: *const Node) Error!void {
        if (dest.* != 0 and dest.* != value)
            return failFields(p.a, p.diag, invalid_datetime_format, "This value contradicts a previous setting for the same field type.", null, "conflicting values for \"{s}\" field in formatting string", .{n.key.name});
        dest.* = value;
    }

    /// is_next_separator(): whether the field ends at a non-digit.
    fn nextIsSeparator(p: *const Parser, ni: usize) bool {
        const n = &p.nodes[ni];
        if (n.suffix & (s_TH | s_th) != 0) return true;
        if (ni + 1 >= p.nodes.len) return true;
        const next = &p.nodes[ni + 1];
        if (next.kind == .action) return !next.key.digit;
        if (next.text.len == 1 and std.ascii.isDigit(next.text[0])) return false;
        return true;
    }

    /// from_char_parse_int_len(): an integer of `len` characters (after
    /// spaces), or as long as it goes with FM or a separator after it.
    /// Returns the characters used, the spaces among them.
    fn parseIntLen(p: *Parser, dest: ?*i32, len: usize, ni: usize) Error!usize {
        const n = &p.nodes[ni];
        const init = p.s;
        _ = p.skipSpaces();
        const copy = p.in[p.s..@min(p.s + len, p.in.len)];
        var value: Strtol = undefined;
        if (n.suffix & s_fm != 0 or p.nextIsSeparator(ni)) {
            value = strtol(p.in[init..]);
            p.s = init + value.used;
        } else {
            if (copy.len < len) {
                const detail = try std.fmt.allocPrint(p.a, "Field requires {d} characters, but only {d} remain.", .{ len, copy.len });
                return failFields(p.a, p.diag, invalid_datetime_format, detail, fm_hint, "source string too short for \"{s}\" formatting field", .{n.key.name});
            }
            value = strtol(copy);
            if (value.used > 0 and value.used < len) {
                const detail = try std.fmt.allocPrint(p.a, "Field requires {d} characters, but only {d} could be parsed.", .{ len, value.used });
                return failFields(p.a, p.diag, invalid_datetime_format, detail, fm_hint, "invalid value \"{s}\" for \"{s}\"", .{ copy, n.key.name });
            }
            p.s += value.used;
        }
        if (p.s == init)
            return failFields(p.a, p.diag, invalid_datetime_format, "Value must be an integer.", null, "invalid value \"{s}\" for \"{s}\"", .{ copy, n.key.name });
        if (value.overflow or value.v < std.math.minInt(i32) or value.v > std.math.maxInt(i32))
            return failFields(p.a, p.diag, datetime_out_of_range, "Value must be in the range -2147483648 to 2147483647.", null, "value for \"{s}\" in source string is out of range", .{n.key.name});
        if (dest) |d| try p.setInt(d, @intCast(value.v), n);
        return p.s - init;
    }

    fn parseInt(p: *Parser, dest: ?*i32, ni: usize) Error!usize {
        return p.parseIntLen(dest, p.nodes[ni].key.name.len, ni);
    }

    /// from_char_seq_search(): the index in `array` of the word the
    /// input starts with, in any case.
    fn seqSearch(p: *Parser, array: []const []const u8, n: *const Node) Error!i32 {
        const rest = p.in[p.s..];
        for (array, 0..) |word, i| {
            if (rest.len >= word.len and std.ascii.eqlIgnoreCase(rest[0..word.len], word)) {
                p.s += word.len;
                return @intCast(i);
            }
        }
        var end: usize = 0;
        while (end < rest.len and !isSpace(rest[end])) end += 1;
        return failFields(p.a, p.diag, invalid_datetime_format, "The given value did not match any of the allowed values for this field.", null, "invalid value \"{s}\" for \"{s}\"", .{ rest[0..end], n.key.name });
    }

    /// The sign of TZH and OF: a sign, or a space, or a minus taken
    /// for a separator before the field.
    fn tzSign(p: *Parser, extra_skip: i32) void {
        const c = p.at(p.s);
        if (c == '+' or c == '-' or c == ' ') {
            p.out.tzsign = if (c == '-') -1 else 1;
            p.s += 1;
        } else {
            p.out.tzsign = if (extra_skip > 0 and p.s > 0 and p.in[p.s - 1] == '-') -1 else 1;
        }
    }

    /// DCH_from_char().
    fn run(p: *Parser) Error!void {
        var fx = false;
        // Characters skipped beyond those the template has.
        var extra_skip: i32 = 0;
        var ni: usize = 0;
        while (ni < p.nodes.len and p.s < p.in.len) : (ni += 1) {
            const n = &p.nodes[ni];
            // Spaces at the start and before fields are skipped unless FX.
            if (!fx and !(n.kind == .action and n.key.id == .FX) and (n.kind == .action or ni == 0))
                extra_skip += @intCast(p.skipSpaces());

            switch (n.kind) {
                .space, .separator => {
                    // A space or separator matches one, or none; with FX
                    // one character, whatever it is.
                    if (!fx) {
                        extra_skip -= 1;
                        const c = p.at(p.s);
                        if (isSpace(c) or isSeparatorChar(c)) {
                            p.s += 1;
                            extra_skip += 1;
                        }
                    } else p.advance(charLen(p.in, p.s));
                    continue;
                },
                .char => {
                    // Text: one character, whatever it is (unless more
                    // were skipped before, which may be of a field).
                    if (!fx and extra_skip > 0) extra_skip -= 1 else p.advance(charLen(p.in, p.s));
                    continue;
                },
                .action => {},
            }

            try p.setMode(n.key.mode);
            const o = &p.out;
            switch (n.key.id) {
                .FX => fx = true,
                .A_M, .P_M, .a_m, .p_m => {
                    const v = try p.seqSearch(&ampm_long, n);
                    try p.setInt(&o.pm, @rem(v, 2), n);
                    o.clock12 = true;
                },
                .AM, .PM, .am, .pm => {
                    const v = try p.seqSearch(&ampm, n);
                    try p.setInt(&o.pm, @rem(v, 2), n);
                    o.clock12 = true;
                },
                .HH, .HH12 => {
                    _ = try p.parseIntLen(&o.hh, 2, ni);
                    o.clock12 = true;
                    p.skipTh(n.suffix);
                },
                .HH24 => {
                    _ = try p.parseIntLen(&o.hh, 2, ni);
                    p.skipTh(n.suffix);
                },
                .MI => {
                    _ = try p.parseInt(&o.mi, ni);
                    p.skipTh(n.suffix);
                },
                .SS => {
                    _ = try p.parseInt(&o.ss, ni);
                    p.skipTh(n.suffix);
                },
                .MS => {
                    // 25 is 0.25 and 250 is 0.25 too; 025 is 0.025.
                    const len = try p.parseIntLen(&o.ms, 3, ni);
                    o.ms *%= if (len == 1) 100 else if (len == 2) 10 else 1;
                    p.skipTh(n.suffix);
                },
                .FF1, .FF2, .FF3, .FF4, .FF5, .FF6, .US => {
                    if (n.key.id != .US) o.ff = @as(i32, @backingInt(n.key.id)) - @backingInt(Id.FF1) + 1;
                    const len = try p.parseIntLen(&o.us, if (n.key.id == .US) 6 else @intCast(o.ff), ni);
                    const scale: i32 = switch (len) {
                        1 => 100000,
                        2 => 10000,
                        3 => 1000,
                        4 => 100,
                        5 => 10,
                        else => 1,
                    };
                    o.us *%= scale;
                    p.skipTh(n.suffix);
                },
                .SSSS => {
                    _ = try p.parseInt(&o.ssss, ni);
                    p.skipTh(n.suffix);
                },
                .tz, .TZ, .OF => zone: {
                    if (n.key.id != .OF) {
                        if (zoneAbbrevPrefix(p.in[p.s..])) |z| {
                            o.has_tz = true;
                            o.gmtoffset = z.offset;
                            o.tzsign = 0; // drops an earlier TZH/TZM
                            p.s += z.len;
                            break :zone;
                        } else if (std.ascii.isAlphabetic(p.at(p.s))) {
                            return fail(p.a, p.diag, invalid_datetime_format, "invalid value \"{s}\" for \"{s}\"", .{ p.in[p.s..], n.key.name });
                        }
                        // Otherwise read as OF.
                    }
                    // OF is TZH or TZH:TZM.
                    p.tzSign(extra_skip);
                    _ = try p.parseIntLen(&o.tzh, 2, ni);
                    if (p.at(p.s) == ':') {
                        p.s += 1;
                        _ = try p.parseIntLen(&o.tzm, 2, ni);
                    }
                },
                .TZH => {
                    // A minus before TZH may have been skipped as a
                    // separator.
                    p.tzSign(extra_skip);
                    _ = try p.parseIntLen(&o.tzh, 2, ni);
                },
                .TZM => {
                    if (o.tzsign == 0) o.tzsign = 1;
                    _ = try p.parseIntLen(&o.tzm, 2, ni);
                },
                .A_D, .B_C, .a_d, .b_c => {
                    const v = try p.seqSearch(&adbc_long, n);
                    try p.setInt(&o.bc, @rem(v, 2), n);
                },
                .AD, .BC, .ad, .bc => {
                    const v = try p.seqSearch(&adbc, n);
                    try p.setInt(&o.bc, @rem(v, 2), n);
                },
                .MONTH, .Month, .month => try p.setInt(&o.mm, try p.seqSearch(&months_full, n) + 1, n),
                .MON, .Mon, .mon => try p.setInt(&o.mm, try p.seqSearch(&months_short, n) + 1, n),
                .MM => {
                    _ = try p.parseInt(&o.mm, ni);
                    p.skipTh(n.suffix);
                },
                .DAY, .Day, .day => {
                    try p.setInt(&o.d, try p.seqSearch(&days_full, n), n);
                    o.d += 1;
                },
                .DY, .Dy, .dy => {
                    try p.setInt(&o.d, try p.seqSearch(&days_short, n), n);
                    o.d += 1;
                },
                .DDD => {
                    _ = try p.parseInt(&o.ddd, ni);
                    p.skipTh(n.suffix);
                },
                .IDDD => {
                    _ = try p.parseIntLen(&o.ddd, 3, ni);
                    p.skipTh(n.suffix);
                },
                .DD => {
                    _ = try p.parseInt(&o.dd, ni);
                    p.skipTh(n.suffix);
                },
                .D => {
                    _ = try p.parseInt(&o.d, ni);
                    p.skipTh(n.suffix);
                },
                .ID => {
                    _ = try p.parseIntLen(&o.d, 1, ni);
                    // Sunday is 1, as in D.
                    o.d +%= 1;
                    if (o.d > 7) o.d = 1;
                    p.skipTh(n.suffix);
                },
                .WW, .IW => {
                    _ = try p.parseInt(&o.ww, ni);
                    p.skipTh(n.suffix);
                },
                .Q => {
                    // Read, but not used for the date.
                    _ = try p.parseInt(null, ni);
                    p.skipTh(n.suffix);
                },
                .CC => {
                    _ = try p.parseInt(&o.cc, ni);
                    p.skipTh(n.suffix);
                },
                .Y_YYY => {
                    // sscanf(s, "%d,%03d%n")
                    const rest = p.in[p.s..];
                    const m = scanInt(rest, 0, null);
                    var years: ?Strtol = null;
                    if (m.used > 0 and m.used < rest.len and rest[m.used] == ',') {
                        const y = scanInt(rest, m.used + 1, 3);
                        if (y.used > 0) years = y;
                    }
                    const y = years orelse
                        return fail(p.a, p.diag, invalid_datetime_format, "invalid value \"{s}\" for \"{s}\"", .{ rest, "Y,YYY" });
                    const millennia = std.math.cast(i32, m.v) orelse
                        return fail(p.a, p.diag, datetime_out_of_range, "value for \"{s}\" in source string is out of range", .{"Y,YYY"});
                    const total = blk: {
                        const t = std.math.mul(i32, millennia, 1000) catch break :blk null;
                        break :blk std.math.add(i32, @intCast(y.v), t) catch null;
                    } orelse return fail(p.a, p.diag, datetime_out_of_range, "value for \"{s}\" in source string is out of range", .{"Y,YYY"});
                    try p.setInt(&o.year, total, n);
                    o.yysz = 4;
                    p.s += y.used;
                    p.skipTh(n.suffix);
                },
                .YYYY, .IYYY => {
                    _ = try p.parseInt(&o.year, ni);
                    o.yysz = 4;
                    p.skipTh(n.suffix);
                },
                .YYY, .IYY, .YY, .IY, .Y, .I => {
                    const len = try p.parseInt(&o.year, ni);
                    if (len < 4) o.year = adjustPartialYear(o.year);
                    o.yysz = switch (n.key.id) {
                        .YYY, .IYY => 3,
                        .YY, .IY => 2,
                        else => 1,
                    };
                    p.skipTh(n.suffix);
                },
                .RM, .rm => try p.setInt(&o.mm, 12 - try p.seqSearch(&rm_lower, n), n),
                .W => {
                    _ = try p.parseInt(&o.w, ni);
                    p.skipTh(n.suffix);
                },
                .J => {
                    _ = try p.parseInt(&o.j, ni);
                    p.skipTh(n.suffix);
                },
            }

            // Spaces after a field are skipped unless FX.
            if (!fx) extra_skip = @intCast(p.skipSpaces());
        }
    }
};

const Strtol = struct { v: i64, used: usize, overflow: bool = false };

/// strtol(s, &end, 10): spaces, a sign and digits; `used` is 0 without
/// digits.
fn strtol(s: []const u8) Strtol {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    return scanDigits(s, i, null);
}

/// scanf's %d (or %Nd, `width` characters after the spaces) from `start`.
/// `used` counts from 0, not from `start`; 0 without digits.
fn scanInt(s: []const u8, start: usize, width: ?usize) Strtol {
    var i = start;
    while (i < s.len and isSpace(s[i])) i += 1;
    return scanDigits(s, i, width);
}

fn scanDigits(s: []const u8, start: usize, width: ?usize) Strtol {
    const end = if (width) |w| @min(s.len, start + w) else s.len;
    var i = start;
    var neg = false;
    if (i < end and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const digits = i;
    var v: i64 = 0;
    var overflow = false;
    while (i < end and std.ascii.isDigit(s[i])) : (i += 1) {
        const d: i64 = s[i] - '0';
        const m = @mulWithOverflow(v, 10);
        const r = @subWithOverflow(m[0], d);
        if (m[1] != 0 or r[1] != 0) overflow = true else v = r[0];
    }
    if (i == digits) return .{ .v = 0, .used = 0 };
    if (!neg) {
        if (v == std.math.minInt(i64)) overflow = true else v = -v;
    }
    return .{ .v = v, .used = i, .overflow = overflow };
}

/// adjust_partial_year_to_2020(): '70' is 1970 and '69' 2069.
fn adjustPartialYear(year: i32) i32 {
    if (year < 70) return year + 2000;
    if (year < 100) return year + 1900;
    if (year < 520) return year + 2000;
    if (year < 1000) return year + 1000;
    return year;
}

/// The result of do_to_timestamp().
const Parsed = struct {
    year: i32 = 0,
    mon: i32 = 1,
    mday: i32 = 1,
    hour: i32 = 0,
    min: i32 = 0,
    sec: i32 = 0,
    fsec: i32 = 0,
    /// Seconds west of UTC (PostgreSQL's sign), if the input had a zone.
    tz: ?i32 = null,
    /// FF1-FF6's precision, or 0.
    fprec: i32 = 0,
};

fn fieldOverflow(a: Allocator, diag: *Diag, input: []const u8) Error {
    return fail(a, diag, datetime_out_of_range, "date/time field value out of range: \"{s}\"", .{input});
}

/// do_to_timestamp(): the input read with the template, into a date, a
/// time and a zone.
fn doToTimestamp(a: Allocator, input: []const u8, fmt: Template, diag: *Diag) Error!Parsed {
    var p: Parser = .{ .a = a, .diag = diag, .in = input, .nodes = fmt.nodes };
    try p.run();
    var f = p.out;
    var tm: Parsed = .{};

    if (f.ssss != 0) {
        var x = f.ssss;
        tm.hour = @divTrunc(x, 3600);
        x = @rem(x, 3600);
        tm.min = @divTrunc(x, 60);
        tm.sec = @rem(x, 60);
    }
    if (f.ss != 0) tm.sec = f.ss;
    if (f.mi != 0) tm.min = f.mi;
    if (f.hh != 0) tm.hour = f.hh;

    if (f.clock12) {
        if (tm.hour < 1 or tm.hour > 12)
            return failFields(a, diag, invalid_datetime_format, null, "Use the 24-hour clock, or give an hour between 1 and 12.", "hour \"{d}\" is invalid for the 12-hour clock", .{tm.hour});
        if (f.pm != 0 and tm.hour < 12) {
            tm.hour += 12;
        } else if (f.pm == 0 and tm.hour == 12) tm.hour = 0;
    }

    var has_year = false;
    const ovf = std.math.mul;
    const add = std.math.add;
    if (f.year != 0) {
        if (f.cc != 0 and f.yysz <= 2) {
            // CC and YY (or Y): YY are the last two digits of a year of
            // the century; the 21st century is 2001-2100, the 6th BC
            // 600-501 BC.
            if (f.bc != 0) f.cc = -f.cc;
            tm.year = @rem(f.year, 100);
            if (tm.year != 0) {
                if (f.cc >= 0) {
                    const t = ovf(i32, f.cc - 1, 100) catch return fieldOverflow(a, diag, input);
                    tm.year = add(i32, tm.year, t) catch return fieldOverflow(a, diag, input);
                } else {
                    const t = ovf(i32, f.cc + 1, 100) catch return fieldOverflow(a, diag, input);
                    const u = std.math.sub(i32, t, tm.year) catch return fieldOverflow(a, diag, input);
                    tm.year = add(i32, u, 1) catch return fieldOverflow(a, diag, input);
                }
            } else {
                // A year ending in 00.
                tm.year = f.cc *% 100 +% @as(i32, if (f.cc >= 0) 0 else 1);
            }
        } else {
            // A year of 4 digits; CC is ignored.
            tm.year = f.year;
            if (f.bc != 0) tm.year = -%tm.year;
            if (tm.year < 0) tm.year += 1; // 1 BC is year 0
        }
        has_year = true;
    } else if (f.cc != 0) {
        // The first year of the century.
        if (f.bc != 0) f.cc = -f.cc;
        if (f.cc >= 0) {
            const t = ovf(i32, f.cc - 1, 100) catch return fieldOverflow(a, diag, input);
            tm.year = add(i32, t, 1) catch return fieldOverflow(a, diag, input);
        } else {
            const t = ovf(i32, f.cc, 100) catch return fieldOverflow(a, diag, input);
            tm.year = add(i32, t, 1) catch return fieldOverflow(a, diag, input);
        }
        has_year = true;
    }
    var has_month = false;
    var has_day = false;

    if (f.j != 0) {
        const d = j2date(f.j);
        tm.year = d.year;
        tm.mon = d.mon;
        tm.mday = d.mday;
        has_year = true;
        has_month = true;
        has_day = true;
    }

    if (f.ww != 0) {
        if (f.mode == .isoweek) {
            // Without a day, the Monday of the ISO week.
            var jday = isoweek2j(tm.year, f.ww);
            if (f.d != 0) {
                jday += if (f.d > 1) f.d - 2 else 6;
            }
            const d = j2date(jday);
            tm.year = d.year;
            tm.mon = d.mon;
            tm.mday = d.mday;
            has_year = true;
            has_month = true;
            has_day = true;
        } else {
            const t = std.math.sub(i32, f.ww, 1) catch return fieldOverflow(a, diag, input);
            const u = ovf(i32, t, 7) catch return fieldOverflow(a, diag, input);
            f.ddd = add(i32, u, 1) catch return fieldOverflow(a, diag, input);
        }
    }
    if (f.w != 0) {
        const t = std.math.sub(i32, f.w, 1) catch return fieldOverflow(a, diag, input);
        const u = ovf(i32, t, 7) catch return fieldOverflow(a, diag, input);
        f.dd = add(i32, u, 1) catch return fieldOverflow(a, diag, input);
    }
    if (f.dd != 0) {
        tm.mday = f.dd;
        has_day = true;
    }
    if (f.mm != 0) {
        tm.mon = f.mm;
        has_month = true;
    }

    if (f.ddd != 0 and (tm.mon <= 1 or tm.mday <= 1)) {
        // The day of the year, Gregorian or ISO, makes the month and day.
        if (tm.year == 0 and f.bc == 0)
            return fail(a, diag, invalid_datetime_format, "cannot calculate day of year without year information", .{});
        if (f.mode == .isoweek) {
            const j0 = isoweek2j(tm.year, 1) - 1;
            const d = j2date(j0 + f.ddd);
            tm.year = d.year;
            tm.mon = d.mon;
            tm.mday = d.mday;
            has_year = true;
            has_month = true;
            has_day = true;
        } else {
            const ysum = [2][13]i32{
                .{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
                .{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
            };
            const y = &ysum[@intFromBool(calendar.isLeap(tm.year))];
            var i: usize = 1;
            while (i <= 12) : (i += 1) {
                if (f.ddd <= y[i]) break;
            }
            if (tm.mon <= 1) tm.mon = @intCast(i);
            if (tm.mday <= 1) tm.mday = f.ddd - y[i - 1];
            has_month = true;
            has_day = true;
        }
    }

    if (f.ms != 0) {
        const t = ovf(i32, f.ms, 1000) catch return fieldOverflow(a, diag, input);
        tm.fsec = add(i32, tm.fsec, t) catch return fieldOverflow(a, diag, input);
    }
    if (f.us != 0) tm.fsec +%= f.us;
    tm.fprec = f.ff;

    // ValidateDate()
    if (has_month and (tm.mon < 1 or tm.mon > 12)) return fieldOverflow(a, diag, input);
    if (has_day and (tm.mday < 1 or tm.mday > 31)) return fieldOverflow(a, diag, input);
    if (has_year and has_month and has_day and tm.mday > calendar.daysInMonth(tm.year, @intCast(tm.mon)))
        return fieldOverflow(a, diag, input);

    if (tm.hour < 0 or tm.hour >= 24 or tm.min < 0 or tm.min >= 60 or
        tm.sec < 0 or tm.sec >= 60 or tm.fsec < 0 or tm.fsec >= usecs_per_sec)
        return fieldOverflow(a, diag, input);

    if (f.tzsign != 0) {
        if (f.tzh < 0 or f.tzh > max_tzdisp_hour or f.tzm < 0 or f.tzm >= 60)
            return fail(a, diag, invalid_tz_displacement, "time zone displacement out of range: \"{s}\"", .{input});
        const off = (f.tzh * 60 + f.tzm) * 60;
        tm.tz = if (f.tzsign > 0) -off else off;
    } else if (f.has_tz) {
        tm.tz = -f.gmtoffset;
    }
    return tm;
}

/// to_timestamp(text, fmt): microseconds since 1970-01-01 00:00 UTC.
/// Without a zone in the input, the time is UTC.
pub fn toTimestamp(a: Allocator, input: []const u8, fmt: Template, diag: *Diag) Error!i64 {
    const tm = try doToTimestamp(a, input, fmt, diag);
    const range = struct {
        fn err(al: Allocator, d: *Diag) Error {
            return fail(al, d, datetime_out_of_range, "timestamp out of range", .{});
        }
    }.err;
    // tm2timestamp()
    if (!validJulian(tm.year, tm.mon)) return range(a, diag);
    const date = date2j(tm.year, tm.mon, tm.mday) - postgres_epoch_jdate;
    const time = ((@as(i64, tm.hour) * 60 + tm.min) * 60 + tm.sec) * usecs_per_sec + tm.fsec;
    var result = std.math.mul(i64, date, usecs_per_day) catch return range(a, diag);
    result = std.math.add(i64, result, time) catch return range(a, diag);
    result -= -@as(i64, tm.tz orelse 0) * usecs_per_sec;
    if (result < min_timestamp or result >= end_timestamp) return range(a, diag);
    // AdjustTimestampForTypmod(): round to the precision of FFn.
    if (tm.fprec > 0 and tm.fprec < 6) {
        const scales = [_]i64{ 1000000, 100000, 10000, 1000, 100, 10, 1 };
        const offsets = [_]i64{ 500000, 50000, 5000, 500, 50, 5, 0 };
        const i: usize = @intCast(tm.fprec);
        result = if (result >= 0)
            @divTrunc(result + offsets[i], scales[i]) * scales[i]
        else
            -(@divTrunc(-result + offsets[i], scales[i]) * scales[i]);
    }
    // Microseconds since 1970 in 64 bits end in 294247, before
    // PostgreSQL's last year (294276).
    return std.math.add(i64, result, epoch_shift) catch range(a, diag);
}

/// to_date(text, fmt): days since 1970-01-01.
pub fn toDate(a: Allocator, input: []const u8, fmt: Template, diag: *Diag) Error!i64 {
    const tm = try doToTimestamp(a, input, fmt, diag);
    if (!validJulian(tm.year, tm.mon))
        return fail(a, diag, datetime_out_of_range, "date out of range: \"{s}\"", .{input});
    const result = date2j(tm.year, tm.mon, tm.mday) - postgres_epoch_jdate;
    if (result < -postgres_epoch_jdate or result >= date_end_julian - postgres_epoch_jdate)
        return fail(a, diag, datetime_out_of_range, "date out of range: \"{s}\"", .{input});
    return result + (postgres_epoch_jdate - unix_epoch_jdate);
}

// ============================================================ tests

const testing = std.testing;

/// Microseconds since 1970 of a civil date and time (astronomical year).
fn ts(y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, us: i64) i64 {
    return ((calendar.daysFromCivil(y, mo, d) * 24 + h) * 60 + mi) * 60 * usecs_per_sec + s * usecs_per_sec + us;
}

fn expectChar(us: i64, tz: bool, fmt: []const u8, want: []const u8) !void {
    var diag: Diag = .{};
    const t = try parse(testing.allocator, fmt);
    defer t.deinit(testing.allocator);
    const got = timestampToChar(testing.allocator, us, tz, t, &diag) catch |e| {
        std.debug.print("to_char({s}): {s}\n", .{ fmt, diag.fields.message });
        testing.allocator.free(diag.fields.message);
        return e;
    };
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectIv(iv: ivl.Interval, fmt: []const u8, want: []const u8) !void {
    var diag: Diag = .{};
    const t = try parse(testing.allocator, fmt);
    defer t.deinit(testing.allocator);
    const got = intervalToChar(testing.allocator, iv, t, &diag) catch |e| {
        std.debug.print("to_char({s}): {s}\n", .{ fmt, diag.fields.message });
        testing.allocator.free(diag.fields.message);
        return e;
    };
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectTs(input: []const u8, fmt: []const u8, want: i64) !void {
    var diag: Diag = .{};
    const t = try parse(testing.allocator, fmt);
    defer t.deinit(testing.allocator);
    const got = toTimestamp(testing.allocator, input, t, &diag) catch |e| {
        std.debug.print("to_timestamp({s}, {s}): {s}\n", .{ input, fmt, diag.fields.message });
        testing.allocator.free(diag.fields.message);
        return e;
    };
    try testing.expectEqual(want, got);
}

fn expectDate(input: []const u8, fmt: []const u8, y: i64, m: i64, d: i64) !void {
    var diag: Diag = .{};
    const t = try parse(testing.allocator, fmt);
    defer t.deinit(testing.allocator);
    const got = toDate(testing.allocator, input, t, &diag) catch |e| {
        std.debug.print("to_date({s}, {s}): {s}\n", .{ input, fmt, diag.fields.message });
        testing.allocator.free(diag.fields.message);
        return e;
    };
    try testing.expectEqual(calendar.daysFromCivil(y, m, d), got);
}

const Fn = enum { ts, date, char, iv };

fn expectFail(f: Fn, input: []const u8, fmt: []const u8, state: *const [5]u8, msg: []const u8) !void {
    var diag: Diag = .{};
    const t = try parse(testing.allocator, fmt);
    defer t.deinit(testing.allocator);
    // The message, its DETAIL and HINT, in the call's memory.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r: Error!void = switch (f) {
        .ts => if (toTimestamp(a, input, t, &diag)) |_| {} else |e| e,
        .date => if (toDate(a, input, t, &diag)) |_| {} else |e| e,
        .char => if (timestampToChar(a, 0, false, t, &diag)) |_| {} else |e| e,
        .iv => if (intervalToChar(a, .{ .months = 1 }, t, &diag)) |_| {} else |e| e,
    };
    try testing.expectError(error.Failed, r);
    try testing.expectEqualStrings(msg, diag.fields.message);
    try testing.expectEqualStrings(state, &diag.state);
}

test "to_char of a timestamp" {
    const t = ts(2001, 2, 16, 20, 38, 40, 123456);
    try expectChar(t, false, "YYYY-MM-DD HH24:MI:SS.US Day Mon DDD IW J DDTH ddth", "2001-02-16 20:38:40.123456 Friday    Feb 047 07 2451957 16TH 16th");
    try expectChar(t, false, "HH HH12 AM am A.M. p.m. PM", "08 08 PM pm P.M. p.m. PM");
    try expectChar(t, false, "MS FF1 FF2 FF3 FF4 FF5 FF6 SSSS SSSSS", "123 1 12 123 1234 12345 123456 74320 74320");
    try expectChar(t, false, "DAY Day day DY Dy dy D ID", "FRIDAY    Friday    friday    FRI Fri fri 6 5");
    try expectChar(t, false, "MONTH Month month MON Mon mon MM RM rm", "FEBRUARY  February  february  FEB Feb feb 02 II   ii  ");
    try expectChar(t, false, "FMMonth FMDay FMDD FMHH24 FMRM|", "February Friday 16 20 II|");
    try expectChar(t, false, "TMMonth|TMDay|TMMON|TMdy", "February|Friday|FEB|fri");
    try expectChar(t, false, "Q CC Y,YYY YYYY YYY YY Y IYYY IYY IY I IDDD WW W", "1 21 2,001 2001 001 01 1 2001 001 01 1 047 07 3");
    try expectChar(t, false, "AD ad A.D. a.d. BC bc B.C. b.c.", "AD ad A.D. a.d. AD ad A.D. a.d.");
    try expectChar(t, false, "TZ|tz|OF|TZH|TZM|", "||+00|+00|00|");
    try expectChar(t, true, "TZ|tz|OF|TZH|TZM|FMOF", "UTC|utc|+00|+00|00|+0");
    try expectChar(t, false, "\"YYYY\" \"a\\\"b\" \\\"MM\\\" \\HH", "YYYY a\"b \"02\" \\08");
    try expectChar(t, false, "FMDDth DDst HH24TH SSth Dth IDth Qth CCth MMth", "16th 16st 20TH 40th 6th 5th 1st 21st 02nd");
    try expectChar(t, false, "DDSP FX FMx Mi", "16  x M1");
    try expectChar(ts(2001, 5, 16, 0, 5, 9, 0), false, "HH:MI:SS AM HH24 FMHH12 TMMonth| Month|", "12:05:09 AM 00 12 May| May      |");
    try expectChar(ts(2001, 5, 16, 12, 0, 0, 0), false, "HH12 PM", "12 PM");
    try expectChar(ts(2001, 5, 16, 0, 0, 0, 0), false, "", "");
}

test "to_char of ordinals, ISO weeks and BC dates" {
    try expectChar(ts(2011, 1, 1, 0, 0, 0, 0), false, "DDth DDD IW IYYY IDDD ID WW", "01st 001 52 2010 363 6 01");
    try expectChar(ts(2008, 12, 29, 0, 0, 0, 0), false, "IYYY-IW-ID IDDD", "2009-01-1 001");
    try expectChar(ts(2002, 11, 11, 0, 0, 0, 0), false, "DDth DDTH", "11th 11TH");
    try expectChar(ts(2002, 11, 22, 0, 0, 0, 0), false, "DDth", "22nd");
    try expectChar(ts(2002, 11, 23, 0, 0, 0, 0), false, "DDth", "23rd");
    try expectChar(ts(2002, 11, 13, 0, 0, 0, 0), false, "DDth", "13th");
    try expectChar(ts(2002, 3, 31, 0, 0, 0, 0), false, "DDDth", "090th");
    // 1 BC (year 0), and 0001-01-01 BC minus a day.
    try expectChar(ts(0, 12, 31, 0, 0, 0, 0), false, "YYYY BC B.C. ad CC Y,YYY IYYY J", "0001 BC B.C. bc -01 0,001 0001 1721425");
    try expectChar(ts(-100, 3, 1, 0, 0, 0, 0), false, "YYYY AD CC YY", "0101 BC -02 01");
    try expectChar(ts(-4713, 11, 24, 0, 0, 0, 0), false, "YYYY-MM-DD BC J", "4714-11-24 BC 0");
    try expectChar(ts(12345, 1, 1, 0, 0, 0, 0), false, "YYYY CC Y,YYY", "12345 124 12,345");
    try expectChar(ts(1900, 1, 1, 0, 0, 0, 0), false, "CC YYYY", "19 1900");
    try expectChar(ts(2000, 1, 1, 0, 0, 0, 0), false, "CC", "20");
}

test "to_char of an interval" {
    try expectIv(.{ .months = 14, .days = 3, .time = ((4 * 60 + 5) * 60 + 6) * usecs_per_sec + 789000 }, "YYYY MM DD HH24 MI SS MS", "0001 02 03 04 05 06 789");
    try expectIv(.{ .months = -14, .days = -3, .time = -(((4 * 60 + 5) * 60 + 6) * usecs_per_sec + 789000) }, "YYYY MM DD HH24 HH MI SS MS US SSSS DDD WW IW IYYY CC Y,YYY Q RM", "-0001 -02 -3 -04 -04 -05 -06 -789 -789000 -14706 -423 -59 39 -0002 00 0,-01 0 XI  ");
    try expectIv(.{ .time = 100 * usecs_per_hour }, "HH24 HH12 FMHH24 SSSS AM", "100 04 100 360000 AM");
    try expectIv(.{ .months = 24 }, "YYYY MM RM Q", "0002 00 XII  ");
    try expectIv(.{ .months = 3 }, "YYYY MM RM Q", "0000 03 III  1");
}

test "to_char errors" {
    try expectFail(.iv, "", "Mon", "22007", "invalid format specification for an interval value");
    try expectFail(.iv, "", "TZ", "22007", "invalid format specification for an interval value");
    try expectFail(.iv, "", "BC", "22007", "invalid format specification for an interval value");
}

test "to_timestamp" {
    try expectTs("2011-12-18 11:38 PM", "YYYY-MM-DD HH12:MI PM", ts(2011, 12, 18, 23, 38, 0, 0));
    try expectTs("05 Dec 2000", "DD Mon YYYY", ts(2000, 12, 5, 0, 0, 0, 0));
    try expectTs("2011-12-18 11:38 +05:30", "YYYY-MM-DD HH12:MI TZH:TZM", ts(2011, 12, 18, 6, 8, 0, 0));
    try expectTs("2011-12-18 11:38 -05", "YYYY-MM-DD HH12:MI TZH", ts(2011, 12, 18, 16, 38, 0, 0));
    try expectTs("2011-12-18 11:38 EST", "YYYY-MM-DD HH12:MI TZ", ts(2011, 12, 18, 16, 38, 0, 0));
    try expectTs("2011-12-18 11:38 +05:30", "YYYY-MM-DD HH12:MI OF", ts(2011, 12, 18, 6, 8, 0, 0));
    try expectTs("2011-12-18 11:38 -01:30", "YYYY-MM-DD HH12:MI TZ", ts(2011, 12, 18, 13, 8, 0, 0));
    try expectTs("2011-12-18 11:38 PST", "YYYY-MM-DD HH12:MI TZ", ts(2011, 12, 18, 19, 38, 0, 0));
    try expectTs("2011-12-18 11:38 utcx", "YYYY-MM-DD HH12:MI TZ", ts(2011, 12, 18, 11, 38, 0, 0));
    try expectTs("2011-12-18 -05", "YYYY-MM-DD TZH", ts(2011, 12, 18, 5, 0, 0, 0));
    try expectTs("2011-12-18-05", "YYYY-MM-DDTZH", ts(2011, 12, 18, 5, 0, 0, 0));
    try expectTs("2011-12-18  -05", "YYYY-MM-DD TZH", ts(2011, 12, 18, 5, 0, 0, 0));
    try expectTs("2000-01-01 12:34:56.999999", "YYYY-MM-DD HH24:MI:SS.FF5", ts(2000, 1, 1, 12, 34, 57, 0));
    // Rounded as PostgreSQL rounds, from 2000-01-01.
    try expectTs("1999-12-31 23:59:59.55", "YYYY-MM-DD HH24:MI:SS.FF1", ts(1999, 12, 31, 23, 59, 59, 500000));
    try expectTs("1997 AD 07 12", "YYYY BC MM DD", ts(1997, 7, 12, 0, 0, 0, 0));
    try expectTs("1997 BC 07 12", "YYYY BC MM DD", ts(-1996, 7, 12, 0, 0, 0, 0));
    try expectTs("2000-01-01 12:34:56.789", "YYYY-MM-DD HH24:MI:SS.MS", ts(2000, 1, 1, 12, 34, 56, 789000));
    try expectTs("2000-01-01 12:34:56.12", "YYYY-MM-DD HH24:MI:SS.MS", ts(2000, 1, 1, 12, 34, 56, 120000));
    try expectTs("2000-01-01 12:34:56.123456", "YYYY-MM-DD HH24:MI:SS.US", ts(2000, 1, 1, 12, 34, 56, 123456));
    try expectTs("2000-01-01 12:34:56.123456", "YYYY-MM-DD HH24:MI:SS.FF6", ts(2000, 1, 1, 12, 34, 56, 123456));
    try expectTs("2000-01-01 12:34:56.15", "YYYY-MM-DD HH24:MI:SS.FF2", ts(2000, 1, 1, 12, 34, 56, 150000));
    try expectTs("10:30", "HH24:MI", ts(0, 1, 1, 10, 30, 0, 0));
    try expectTs("  2000    Jan   3", "YYYY Mon DD", ts(2000, 1, 3, 0, 0, 0, 0));
    try expectTs("2000JUN", "YYYYMON", ts(2000, 6, 1, 0, 0, 0, 0));
    try expectTs("2000 november", "YYYY Month", ts(2000, 11, 1, 0, 0, 0, 0));
    try expectTs("2000 xii 3", "YYYY RM DD", ts(2000, 12, 3, 0, 0, 0, 0));
    try expectTs("44287", "SSSS", ts(0, 1, 1, 12, 18, 7, 0));
    try expectTs("2451545", "J", ts(2000, 1, 1, 0, 0, 0, 0));
    try expectTs("2005-W2-3", "IYYY-\"W\"IW-ID", ts(2005, 1, 12, 0, 0, 0, 0));
    try expectTs("2005 2", "IYYY IW", ts(2005, 1, 10, 0, 0, 0, 0));
    try expectTs("19 05", "CC YY", ts(1805, 1, 1, 0, 0, 0, 0));
    try expectTs("21", "CC", ts(2001, 1, 1, 0, 0, 0, 0));
    try expectTs("1,234", "Y,YYY", ts(1234, 1, 1, 0, 0, 0, 0));
    try expectTs("2010 3", "YYYY WW", ts(2010, 1, 15, 0, 0, 0, 0));
    try expectTs("2010 3 3", "YYYY MM W", ts(2010, 3, 15, 0, 0, 0, 0));
    try expectTs("Mon 2010 3 1", "Dy YYYY MM DD", ts(2010, 3, 1, 0, 0, 0, 0));
    try expectTs("2000 1 2", "FXYYYY MM DD", ts(2000, 1, 2, 0, 0, 0, 0));
    try expectTs("12:00 am", "HH:MI am", ts(0, 1, 1, 0, 0, 0, 0));
    try expectTs("1:2:3 p.m.", "HH:MI:SS a.m.", ts(0, 1, 1, 13, 2, 3, 0));
    try expectTs("2020-01-01 00:00:00.123456", "YYYY-MM-DD HH24:MI:SS.FF2", ts(2020, 1, 1, 0, 0, 0, 120000));
}

test "to_date" {
    try expectDate("20100309", "YYYYMMDD", 2010, 3, 9);
    try expectDate("2016-366", "YYYY-DDD", 2016, 12, 31);
    try expectDate("2015-365", "YYYY-DDD", 2015, 12, 31);
    try expectDate("2016-12", "YYYY-MM", 2016, 12, 1);
    try expectDate("2016", "YYYYMMDD", 2016, 1, 1);
    try expectDate("16-03-09", "YY-MM-DD", 2016, 3, 9);
    try expectDate("75-03-09", "YY-MM-DD", 1975, 3, 9);
    try expectDate("475-03-09", "YYY-MM-DD", 2475, 3, 9);
    try expectDate("2016 2016", "YYYY YYYY", 2016, 1, 1);
    try expectDate("2016-W2-1", "IYYY-\"W\"IW-ID", 2016, 1, 11);
    try expectDate("2016 362", "IYYY IDDD", 2016, 12, 30);
    try expectDate("2010 Monday 2", "IYYY Day IW", 2010, 1, 11);
    try expectDate(" 2010", "YYYY", 2010, 1, 1);
    try expectDate("2010 0", "YYYY  MM", 2010, 1, 1);
    try expectDate("2010   5", "YYYY MM", 2010, 5, 1);
    try expectDate("x2010", "xYYYY", 2010, 1, 1);
    try expectDate("2010-05", "YYYYxMM", 2010, 5, 1);
    try expectDate("9 BC", "Y BC", -2008, 1, 1);
    try expectDate("-44-03-15", "YYYY-MM-DD", -43, 3, 15);
    try expectDate("2011 12  18", "YYYY MM DD", 2011, 12, 18);
    try expectDate("2011 12 18", "FXYYYY  MM DD", 2011, 2, 18);
    try expectDate("20 12", "CC YY", 1912, 1, 1);
    try expectDate("6 50 BC", "CC YY BC", -549, 1, 1);
    try expectDate("3 BC", "CC BC", -299, 1, 1);
    try expectDate("5 Jan 2016", "FMDD Mon YYYY", 2016, 1, 5);
    try expectDate("2016/3/9", "YYYY/MM/DD", 2016, 3, 9);
    try expectDate("2016 3 9th", "YYYY MM DDth", 2016, 3, 9);
    try expectDate("1 BC", "YYYY BC", 0, 1, 1);
    try expectDate("4714-11-24 BC", "YYYY-MM-DD BC", -4713, 11, 24);
}

test "to_timestamp and to_date errors" {
    try expectFail(.date, "2016-13-01", "YYYY-MM-DD", "22008", "date/time field value out of range: \"2016-13-01\"");
    try expectFail(.date, "2015-02-29", "YYYY-MM-DD", "22008", "date/time field value out of range: \"2015-02-29\"");
    try expectFail(.ts, "2011-12-18 13:38 PM", "YYYY-MM-DD HH12:MI PM", "22007", "hour \"13\" is invalid for the 12-hour clock");
    try expectFail(.ts, "2011-12-18 11:38 +16", "YYYY-MM-DD HH12:MI TZH", "22009", "time zone displacement out of range: \"2011-12-18 11:38 +16\"");
    try expectFail(.ts, "2011-12-18 11:38 FOO", "YYYY-MM-DD HH12:MI TZ", "22007", "invalid value \"FOO\" for \"TZ\"");
    try expectFail(.date, "2016-366", "YYYY-IDDD", "22007", "invalid combination of date conventions");
    try expectFail(.date, "366", "DDD", "22007", "cannot calculate day of year without year information");
    try expectFail(.date, "2016 2017", "YYYY YYYY", "22007", "conflicting values for \"YYYY\" field in formatting string");
    try expectFail(.date, "20161", "YYYYMMDD", "22007", "source string too short for \"MM\" formatting field");
    try expectFail(.date, "2016-x", "YYYY-MM", "22007", "invalid value \"x\" for \"MM\"");
    try expectFail(.date, "2016-1x", "YYYY-MMDD", "22007", "invalid value \"1x\" for \"MM\"");
    try expectFail(.date, "99999999999-01-01", "FMYYYY-MM-DD", "22008", "value for \"YYYY\" in source string is out of range");
    try expectFail(.date, "5874898-01-01", "YYYY-MM-DD", "22008", "date out of range: \"5874898-01-01\"");
    try expectFail(.ts, "294277-01-01", "YYYY-MM-DD", "22008", "timestamp out of range");
    // Valid for PostgreSQL, but past 64-bit microseconds since 1970.
    try expectFail(.ts, "294276-12-31", "YYYY-MM-DD", "22008", "timestamp out of range");
    try expectFail(.date, "4714-11-23 BC", "YYYY-MM-DD BC", "22008", "date out of range: \"4714-11-23 BC\"");
    try expectFail(.ts, "2010 XIII 3", "YYYY RM DD", "22007", "invalid value \"I \" for \"DD\"");
    try expectFail(.ts, "Foo bar", "Mon", "22007", "invalid value \"Foo\" for \"Mon\"");
    try expectFail(.ts, "Foo", "mon", "22007", "invalid value \"Foo\" for \"mon\"");
    try expectFail(.ts, "x,123", "Y,YYY", "22007", "invalid value \"x,123\" for \"Y,YYY\"");
    try expectFail(.ts, "2011-12-18 11:38 -0130", "YYYY-MM-DD HH12:MI TZ", "22009", "time zone displacement out of range: \"2011-12-18 11:38 -0130\"");
    try expectFail(.date, "2016 13", "YYYY HH", "22007", "hour \"13\" is invalid for the 12-hour clock");
    try expectFail(.ts, "0", "HH", "22007", "hour \"0\" is invalid for the 12-hour clock");
    try expectFail(.ts, "25:00", "HH24:MI", "22008", "date/time field value out of range: \"25:00\"");
}
