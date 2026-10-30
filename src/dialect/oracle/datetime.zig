//! Oracle dates as the dialect stores them: text in SQLite's format,
//! 'YYYY-MM-DD HH:MM:SS' for DATE (which has a time of day) and
//! 'YYYY-MM-DD HH:MM:SS.ffffff' for TIMESTAMP, so that SQLite's date
//! functions read them and they sort as text. This file parses and
//! writes them, does the calendar arithmetic of ADD_MONTHS and friends,
//! and reads and writes Oracle's datetime format models (TO_CHAR,
//! TO_DATE): YYYY YYY YY Y RRRR RR SYYYY Q MM MON MONTH RM WW IW W DDD DD D
//! DAY DY J HH HH12 HH24 MI SS SSSSS FF[1-9] AM PM A.M. P.M. FM, "text"
//! and punctuation, in English (NLS_DATE_LANGUAGE AMERICAN).

const std = @import("std");
const calendar = @import("../calendar.zig");

pub const DateTime = struct {
    year: i32 = 1,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// Nanoseconds.
    nanos: u32 = 0,

    /// Days since 1970-01-01.
    pub fn days(d: DateTime) i64 {
        return daysFromCivil(d.year, d.month, d.day);
    }

    pub fn secondsOfDay(d: DateTime) i64 {
        return @as(i64, d.hour) * 3600 + @as(i64, d.minute) * 60 + d.second;
    }

    pub fn withDays(d: DateTime, n: i64) DateTime {
        var r = d;
        const c = civilFromDays(n);
        r.year = c.year;
        r.month = c.month;
        r.day = c.day;
        return r;
    }

    /// Julian day number (as TO_CHAR's J).
    pub fn julian(d: DateTime) i64 {
        return d.days() + 2440588;
    }

    /// 0 Sunday .. 6 Saturday.
    pub fn weekday(d: DateTime) u8 {
        return @intCast(@mod(d.days() + 4, 7));
    }

    pub fn dayOfYear(d: DateTime) u16 {
        return @intCast(d.days() - daysFromCivil(d.year, 1, 1) + 1);
    }

    /// Seconds since 1970 as a float, with the fraction.
    pub fn epochSeconds(d: DateTime) f64 {
        return @as(f64, @floatFromInt(d.days() * 86400 + d.secondsOfDay())) + @as(f64, @floatFromInt(d.nanos)) / 1e9;
    }

    pub fn fromEpochSeconds(s: f64) DateTime {
        const whole = @floor(s);
        var ns: i64 = @intFromFloat(@round((s - whole) * 1e9));
        var secs: i64 = @intFromFloat(whole);
        if (ns >= 1_000_000_000) {
            secs += 1;
            ns -= 1_000_000_000;
        }
        const day = @divFloor(secs, 86400);
        const sod = @mod(secs, 86400);
        var d = (DateTime{}).withDays(day);
        d.hour = @intCast(@divTrunc(sod, 3600));
        d.minute = @intCast(@divTrunc(@mod(sod, 3600), 60));
        d.second = @intCast(@mod(sod, 60));
        d.nanos = @intCast(ns);
        return d;
    }
};

pub fn isLeap(y: i32) bool {
    return calendar.isLeap(y);
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return @intCast(calendar.daysInMonth(y, m));
}

pub fn daysFromCivil(y: i32, m: u8, d: u8) i64 {
    return calendar.daysFromCivil(y, m, d);
}

pub fn civilFromDays(z: i64) struct { year: i32, month: u8, day: u8 } {
    const y, const m, const d = calendar.civilFromDays(z);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

// ============================================================ ISO text

fn digitsAt(s: []const u8, i: usize, n: usize) ?u32 {
    if (i + n > s.len) return null;
    var v: u32 = 0;
    for (s[i .. i + n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// 'YYYY-MM-DD[( |T)HH:MM[:SS[.f...]]]' with an optional trailing zone
/// (Z, +HH:MM, a name), which is ignored; null if `s` is not one.
pub fn parseIso(s_arg: []const u8) ?DateTime {
    const s = std.mem.trim(u8, s_arg, " ");
    var d: DateTime = .{};
    var i: usize = 0;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        i = 1;
    }
    const y = digitsAt(s, i, 4) orelse return null;
    i += 4;
    d.year = @intCast(y);
    if (neg) d.year = -d.year;
    if (i >= s.len or s[i] != '-') return null;
    d.month = @intCast(digitsAt(s, i + 1, 2) orelse return null);
    if (i + 3 >= s.len or s[i + 3] != '-') return null;
    d.day = @intCast(digitsAt(s, i + 4, 2) orelse return null);
    i += 6;
    if (d.month < 1 or d.month > 12 or d.day < 1 or d.day > daysInMonth(d.year, d.month)) return null;
    if (i == s.len) return d;
    if (s[i] != ' ' and s[i] != 'T') return null;
    i += 1;
    while (i < s.len and s[i] == ' ') i += 1;
    d.hour = @intCast(digitsAt(s, i, 2) orelse return null);
    if (i + 2 >= s.len or s[i + 2] != ':') return null;
    d.minute = @intCast(digitsAt(s, i + 3, 2) orelse return null);
    i += 5;
    if (i < s.len and s[i] == ':') {
        d.second = @intCast(digitsAt(s, i + 1, 2) orelse return null);
        i += 3;
        if (i < s.len and s[i] == '.') {
            i += 1;
            var scale: u32 = 100_000_000;
            const start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                d.nanos += (s[i] - '0') * scale;
                scale /= 10;
            }
            if (i == start) return null;
        }
    }
    if (d.hour > 23 or d.minute > 59 or d.second > 59) return null;
    // A zone, ignored.
    const rest = std.mem.trim(u8, s[i..], " ");
    if (rest.len > 0 and !(rest[0] == 'Z' or rest[0] == '+' or rest[0] == '-' or std.ascii.isAlphabetic(rest[0]))) return null;
    return d;
}

/// The text of a DATE: 'YYYY-MM-DD HH:MM:SS'.
pub fn writeDate(buf: []u8, d: DateTime) []const u8 {
    return writeTimestamp(buf, d, 0);
}

/// 'YYYY-MM-DD HH:MM:SS[.f]' with `digits` fractional digits.
pub fn writeTimestamp(buf: []u8, d: DateTime, digits: u32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (d.year < 0) w.print("-{d:0>4}", .{@abs(d.year)}) catch {} else w.print("{d:0>4}", .{@as(u32, @intCast(d.year))}) catch {};
    w.print("-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ d.month, d.day, d.hour, d.minute, d.second }) catch {};
    if (digits > 0) {
        var frac: [9]u8 = undefined;
        _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{d.nanos}) catch {};
        w.print(".{s}", .{frac[0..digits]}) catch {};
    }
    return w.buffered();
}

// ========================================================== arithmetic

/// ADD_MONTHS: the same day `n` months later; the last day of the month
/// if `d` is the last day of its month or the result's month is shorter.
pub fn addMonths(d: DateTime, n: i64) DateTime {
    const total = @as(i64, d.year) * 12 + (d.month - 1) + n;
    var r = d;
    r.year = @intCast(@divFloor(total, 12));
    r.month = @intCast(@mod(total, 12) + 1);
    const last = daysInMonth(r.year, r.month);
    if (d.day == daysInMonth(d.year, d.month) or d.day > last) r.day = last;
    return r;
}

/// MONTHS_BETWEEN(a, b): whole months when the days of the month are the
/// same or both are the last of their month, else a fraction of a 31-day
/// month that counts the time of day.
pub fn monthsBetween(a: DateTime, b: DateTime) f64 {
    const months: f64 = @floatFromInt((@as(i64, a.year) - b.year) * 12 + (@as(i64, a.month) - b.month));
    const a_last = a.day == daysInMonth(a.year, a.month);
    const b_last = b.day == daysInMonth(b.year, b.month);
    if (a.day == b.day or (a_last and b_last)) return months;
    const day_diff: f64 = @as(f64, @floatFromInt(@as(i64, a.day) - b.day)) + @as(f64, @floatFromInt(a.secondsOfDay() - b.secondsOfDay())) / 86400.0;
    return months + day_diff / 31.0;
}

pub fn lastDay(d: DateTime) DateTime {
    var r = d;
    r.day = daysInMonth(d.year, d.month);
    return r;
}

/// TRUNC(date, unit) / ROUND(date, unit); null for an unknown unit.
pub fn truncate(d: DateTime, unit_arg: []const u8, round: bool) ?DateTime {
    var buf: [16]u8 = undefined;
    if (unit_arg.len > buf.len) return null;
    const unit = std.ascii.upperString(&buf, std.mem.trim(u8, unit_arg, " "));
    const eq = std.mem.eql;
    const day0: DateTime = .{ .year = d.year, .month = d.month, .day = d.day };
    if (eq(u8, unit, "DD") or eq(u8, unit, "DDD") or eq(u8, unit, "J")) {
        if (round and d.hour >= 12) return day0.withDays(day0.days() + 1);
        return day0;
    }
    if (eq(u8, unit, "MM") or eq(u8, unit, "MON") or eq(u8, unit, "MONTH") or eq(u8, unit, "RM")) {
        const first: DateTime = .{ .year = d.year, .month = d.month, .day = 1 };
        if (round and d.day >= 16) return addMonths(first, 1);
        return first;
    }
    if (eq(u8, unit, "YYYY") or eq(u8, unit, "SYYYY") or eq(u8, unit, "YEAR") or eq(u8, unit, "SYEAR") or eq(u8, unit, "YYY") or eq(u8, unit, "YY") or eq(u8, unit, "Y") or eq(u8, unit, "RRRR") or eq(u8, unit, "RR")) {
        const first: DateTime = .{ .year = d.year, .month = 1, .day = 1 };
        if (round and d.month >= 7) return .{ .year = d.year + 1, .month = 1, .day = 1 };
        return first;
    }
    if (eq(u8, unit, "Q")) {
        const qm: u8 = (d.month - 1) / 3 * 3 + 1;
        const first: DateTime = .{ .year = d.year, .month = qm, .day = 1 };
        if (round and (d.month - qm > 1 or (d.month - qm == 1 and d.day >= 16))) return addMonths(first, 3);
        return first;
    }
    if (eq(u8, unit, "CC") or eq(u8, unit, "SCC")) {
        const c = @divFloor(d.year - 1, 100) * 100 + 1;
        const first: DateTime = .{ .year = c, .month = 1, .day = 1 };
        if (round and d.year - c >= 50) return .{ .year = c + 100, .month = 1, .day = 1 };
        return first;
    }
    if (eq(u8, unit, "DAY") or eq(u8, unit, "DY") or eq(u8, unit, "D")) {
        const start = day0.days() - d.weekday();
        if (round and (d.weekday() > 3 or (d.weekday() == 3 and d.hour >= 12))) return day0.withDays(start + 7);
        return day0.withDays(start);
    }
    if (eq(u8, unit, "IW")) {
        const wd: i64 = @mod(@as(i64, d.weekday()) + 6, 7);
        return day0.withDays(day0.days() - wd);
    }
    if (eq(u8, unit, "WW")) {
        const jan1 = daysFromCivil(d.year, 1, 1);
        return day0.withDays(day0.days() - @mod(day0.days() - jan1, 7));
    }
    if (eq(u8, unit, "HH") or eq(u8, unit, "HH12") or eq(u8, unit, "HH24")) {
        var r = day0;
        r.hour = d.hour;
        if (round and d.minute >= 30) return DateTime.fromEpochSeconds(r.epochSeconds() + 3600);
        return r;
    }
    if (eq(u8, unit, "MI")) {
        var r = day0;
        r.hour = d.hour;
        r.minute = d.minute;
        if (round and d.second >= 30) return DateTime.fromEpochSeconds(r.epochSeconds() + 60);
        return r;
    }
    return null;
}

// ======================================================= format models

pub const month_names = [_][]const u8{ "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" };
pub const day_names = [_][]const u8{ "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" };
const roman = [_][]const u8{ "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII" };

const Elem = enum {
    syyyy,
    yyyy,
    yyy,
    yy,
    y,
    rrrr,
    rr,
    q,
    mm,
    month,
    mon,
    rm,
    ww,
    iw,
    w,
    ddd,
    dd,
    d,
    day,
    dy,
    j,
    hh24,
    hh12,
    hh,
    mi,
    sssss,
    ss,
    ff,
    am,
    pm,
    a_m,
    p_m,
    fm,
};

/// The elements, longest spellings first.
const elems = [_]struct { []const u8, Elem }{
    .{ "SYYYY", .syyyy }, .{ "YYYY", .yyyy }, .{ "YYY", .yyy },     .{ "RRRR", .rrrr }, .{ "RR", .rr },
    .{ "YY", .yy },       .{ "Y", .y },       .{ "MONTH", .month }, .{ "MON", .mon },   .{ "MM", .mm },
    .{ "RM", .rm },       .{ "WW", .ww },     .{ "IW", .iw },       .{ "W", .w },       .{ "DDD", .ddd },
    .{ "DAY", .day },     .{ "DD", .dd },     .{ "DY", .dy },       .{ "D", .d },       .{ "J", .j },
    .{ "HH24", .hh24 },   .{ "HH12", .hh12 }, .{ "HH", .hh },       .{ "MI", .mi },     .{ "SSSSS", .sssss },
    .{ "SS", .ss },       .{ "FF", .ff },     .{ "A.M.", .a_m },    .{ "P.M.", .p_m },  .{ "AM", .am },
    .{ "PM", .pm },       .{ "FM", .fm },     .{ "Q", .q },
};

const Piece = union(enum) {
    elem: struct { e: Elem, text: []const u8, ff_digits: u32 = 0 },
    literal: []const u8,
};

/// The next piece of a format model at `i`; null at the end, error for
/// an unknown element.
fn nextPiece(fmt: []const u8, i: *usize) error{BadFormat}!?Piece {
    if (i.* >= fmt.len) return null;
    const c = fmt[i.*];
    if (c == '"') {
        const end = std.mem.indexOfScalarPos(u8, fmt, i.* + 1, '"') orelse return error.BadFormat;
        const lit = fmt[i.* + 1 .. end];
        i.* = end + 1;
        return .{ .literal = lit };
    }
    if (std.mem.indexOfScalar(u8, " -/,.;:", c) != null) {
        // A.M./P.M. start with a letter, so a dot here is punctuation.
        i.* += 1;
        return .{ .literal = fmt[i.* - 1 .. i.*] };
    }
    for (elems) |e| {
        if (i.* + e[0].len <= fmt.len and std.ascii.eqlIgnoreCase(fmt[i.* .. i.* + e[0].len], e[0])) {
            const text = fmt[i.* .. i.* + e[0].len];
            i.* += e[0].len;
            var digits: u32 = 0;
            if (e[1] == .ff) {
                digits = 6;
                if (i.* < fmt.len and fmt[i.*] >= '1' and fmt[i.*] <= '9') {
                    digits = fmt[i.*] - '0';
                    i.* += 1;
                }
            }
            return .{ .elem = .{ .e = e[1], .text = text, .ff_digits = digits } };
        }
    }
    // TH, SP suffixes and other elements are not supported.
    return error.BadFormat;
}

/// How a name element is cased: MONTH, Month or month after the case of
/// its first two letters, as Oracle does.
fn caseName(w: *std.Io.Writer, name: []const u8, spelled: []const u8, pad: usize) !void {
    const first_upper = std.ascii.isUpper(spelled[0]);
    const second_upper = spelled.len > 1 and std.ascii.isUpper(spelled[1]);
    for (name, 0..) |ch, k| {
        const out = if (first_upper and (second_upper or k == 0)) ch else std.ascii.toLower(ch);
        try w.writeByte(out);
    }
    var n = name.len;
    while (n < pad) : (n += 1) try w.writeByte(' ');
}

fn num(w: *std.Io.Writer, v: i64, width: usize, fm: bool) !void {
    if (fm) return w.print("{d}", .{v});
    if (v < 0) return w.print("-{d:0>[1]}", .{ @abs(v), width });
    try w.print("{d:0>[1]}", .{ @as(u64, @intCast(v)), width });
}

pub const FormatError = error{ BadFormat, WriteFailed };

/// TO_CHAR(datetime, fmt) into `w`.
pub fn format(w: *std.Io.Writer, d: DateTime, fmt: []const u8) FormatError!void {
    var i: usize = 0;
    var fm = false;
    while (try nextPiece(fmt, &i)) |piece| switch (piece) {
        .literal => |l| try w.writeAll(l),
        .elem => |el| switch (el.e) {
            .fm => fm = !fm,
            .syyyy, .yyyy, .rrrr => try num(w, d.year, 4, fm),
            .yyy => try num(w, @mod(d.year, 1000), 3, fm),
            .yy, .rr => try num(w, @mod(d.year, 100), 2, fm),
            .y => try num(w, @mod(d.year, 10), 1, fm),
            .q => try num(w, (d.month - 1) / 3 + 1, 1, fm),
            .mm => try num(w, d.month, 2, fm),
            .month => try caseName(w, month_names[d.month - 1], el.text, if (fm) 0 else 9),
            .mon => try caseName(w, month_names[d.month - 1][0..3], el.text, 0),
            .rm => try caseName(w, roman[d.month - 1], el.text, if (fm) 0 else 4),
            .ww => try num(w, (d.dayOfYear() - 1) / 7 + 1, 2, fm),
            .iw => try num(w, isoWeek(d), 2, fm),
            .w => try num(w, (d.day - 1) / 7 + 1, 1, fm),
            .ddd => try num(w, d.dayOfYear(), 3, fm),
            .dd => try num(w, d.day, 2, fm),
            .d => try num(w, @as(i64, d.weekday()) + 1, 1, fm),
            .day => try caseName(w, day_names[d.weekday()], el.text, if (fm) 0 else 9),
            .dy => try caseName(w, day_names[d.weekday()][0..3], el.text, 0),
            .j => try num(w, d.julian(), 7, fm),
            .hh24 => try num(w, d.hour, 2, fm),
            .hh, .hh12 => try num(w, if (d.hour % 12 == 0) 12 else d.hour % 12, 2, fm),
            .mi => try num(w, d.minute, 2, fm),
            .ss => try num(w, d.second, 2, fm),
            .sssss => try num(w, d.secondsOfDay(), 5, fm),
            .ff => {
                var frac: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&frac, "{d:0>9}", .{d.nanos}) catch {};
                try w.writeAll(frac[0..el.ff_digits]);
            },
            .am, .pm, .a_m, .p_m => {
                const pm = d.hour >= 12;
                const dotted = el.e == .a_m or el.e == .p_m;
                const s: []const u8 = if (dotted) (if (pm) "P.M." else "A.M.") else (if (pm) "PM" else "AM");
                try caseName(w, s, el.text, 0);
            },
        },
    };
}

/// The ISO week of `d` (IW).
pub fn isoWeek(d: DateTime) i64 {
    const wd: i64 = @mod(@as(i64, d.weekday()) + 6, 7); // Monday 0
    const thursday = d.days() - wd + 3;
    const ty = civilFromDays(thursday).year;
    const jan1 = daysFromCivil(ty, 1, 1);
    return @divTrunc(thursday - jan1, 7) + 1;
}

pub const ParseError = error{ BadFormat, NoMatch, BadMonth, BadDay, BadHour, BadHour12, BadMinute, BadSecond };

/// TO_DATE(text, fmt): `now` gives the year and month a format without
/// them leaves out (Oracle uses the first day of the current month).
pub fn parse(s: []const u8, fmt: []const u8, now: DateTime) ParseError!DateTime {
    var d: DateTime = .{ .year = now.year, .month = now.month, .day = 1 };
    var pm: ?bool = null;
    var i: usize = 0;
    var j: usize = 0;
    var day_of_year: ?u32 = null;
    var hour12 = false;
    while (try nextPiece(fmt, &i)) |piece| {
        // Oracle is lenient with blanks and punctuation.
        switch (piece) {
            .literal => |l| {
                if (j < s.len and std.mem.startsWith(u8, s[j..], l)) {
                    j += l.len;
                } else {
                    while (j < s.len and !std.ascii.isAlphanumeric(s[j])) j += 1;
                }
                continue;
            },
            .elem => {},
        }
        const el = piece.elem;
        if (el.e != .fm) {
            while (j < s.len and (s[j] == ' ' or std.mem.indexOfScalar(u8, "/,.;:", s[j]) != null or (s[j] == '-' and el.e != .syyyy))) j += 1;
        }
        switch (el.e) {
            .fm => {},
            .syyyy, .yyyy, .rrrr, .yyy, .yy, .y, .rr => {
                const max: usize = switch (el.e) {
                    .yyy => 3,
                    .yy, .rr => 2,
                    .y => 1,
                    else => 4,
                };
                var neg = false;
                if (el.e == .syyyy and j < s.len and s[j] == '-') {
                    neg = true;
                    j += 1;
                }
                const start = j;
                const v = readNum(s, &j, if (el.e == .rrrr or el.e == .rr) 4 else max) orelse return error.NoMatch;
                const n_digits = j - start;
                var y: i32 = @intCast(v);
                if ((el.e == .rr or el.e == .rrrr) and n_digits <= 2) {
                    const cur = @mod(now.year, 100);
                    const century = now.year - cur;
                    y = if (y < 50) (if (cur < 50) century + y else century + 100 + y) else (if (cur < 50) century - 100 + y else century + y);
                } else if (n_digits < 4 and el.e != .syyyy and el.e != .yyyy) {
                    const m = std.math.pow(i32, 10, @intCast(n_digits));
                    y = now.year - @mod(now.year, m) + y;
                }
                d.year = if (neg) -y else y;
            },
            .mm => d.month = @intCast(readNum(s, &j, 2) orelse return error.NoMatch),
            .month, .mon => {
                var found = false;
                for (month_names, 0..) |name, k| {
                    for ([_][]const u8{ name, name[0..3] }) |cand| {
                        if (j + cand.len <= s.len and std.ascii.eqlIgnoreCase(s[j .. j + cand.len], cand)) {
                            d.month = @intCast(k + 1);
                            j += cand.len;
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                }
                if (!found) return error.NoMatch;
            },
            .rm => {
                var best: ?usize = null;
                var best_len: usize = 0;
                for (roman, 0..) |r, k| {
                    if (j + r.len <= s.len and std.ascii.eqlIgnoreCase(s[j .. j + r.len], r) and r.len > best_len) {
                        best = k;
                        best_len = r.len;
                    }
                }
                d.month = @intCast((best orelse return error.NoMatch) + 1);
                j += best_len;
            },
            .dd => d.day = @intCast(readNum(s, &j, 2) orelse return error.NoMatch),
            .ddd => day_of_year = @intCast(readNum(s, &j, 3) orelse return error.NoMatch),
            .day, .dy => {
                for (day_names) |name| {
                    if (j + name.len <= s.len and std.ascii.eqlIgnoreCase(s[j .. j + name.len], name)) {
                        j += name.len;
                        break;
                    }
                    if (j + 3 <= s.len and std.ascii.eqlIgnoreCase(s[j .. j + 3], name[0..3])) {
                        j += 3;
                        break;
                    }
                } else return error.NoMatch;
            },
            .d, .w, .ww, .iw, .q => _ = readNum(s, &j, 2) orelse return error.NoMatch,
            .j => {
                const v = readNum(s, &j, 7) orelse return error.NoMatch;
                const t = d;
                d = t.withDays(@as(i64, v) - 2440588);
            },
            .hh24 => d.hour = @intCast(readNum(s, &j, 2) orelse return error.NoMatch),
            .hh, .hh12 => {
                d.hour = @intCast(readNum(s, &j, 2) orelse return error.NoMatch);
                hour12 = true;
            },
            .mi => d.minute = @intCast(readNum(s, &j, 2) orelse return error.NoMatch),
            .ss => d.second = @intCast(readNum(s, &j, 2) orelse return error.NoMatch),
            .sssss => {
                const v = readNum(s, &j, 5) orelse return error.NoMatch;
                d.hour = @intCast(v / 3600);
                d.minute = @intCast(v % 3600 / 60);
                d.second = @intCast(v % 60);
            },
            .ff => {
                var scale: u32 = 100_000_000;
                const start = j;
                while (j < s.len and std.ascii.isDigit(s[j]) and j - start < 9) : (j += 1) {
                    d.nanos += (s[j] - '0') * scale;
                    scale /= 10;
                }
                if (j == start) return error.NoMatch;
            },
            .am, .pm, .a_m, .p_m => {
                for ([_][]const u8{ "A.M.", "P.M.", "AM", "PM" }) |cand| {
                    if (j + cand.len <= s.len and std.ascii.eqlIgnoreCase(s[j .. j + cand.len], cand)) {
                        pm = cand[0] == 'P' or cand[0] == 'p';
                        j += cand.len;
                        break;
                    }
                } else return error.NoMatch;
                hour12 = true;
            },
        }
    }
    while (j < s.len and s[j] == ' ') j += 1;
    if (j != s.len) return error.NoMatch;
    if (hour12) {
        if (d.hour < 1 or d.hour > 12) return error.BadHour12;
        if (pm orelse false) {
            if (d.hour != 12) d.hour += 12;
        } else if (d.hour == 12) d.hour = 0;
    }
    if (day_of_year) |n| {
        const jan1 = daysFromCivil(d.year, 1, 1);
        const t = d;
        d = t.withDays(jan1 + n - 1);
    }
    if (d.month < 1 or d.month > 12) return error.BadMonth;
    if (d.day < 1 or d.day > daysInMonth(d.year, d.month)) return error.BadDay;
    if (d.hour > 23) return error.BadHour;
    if (d.minute > 59) return error.BadMinute;
    if (d.second > 59) return error.BadSecond;
    return d;
}

fn readNum(s: []const u8, j: *usize, max: usize) ?u32 {
    const start = j.*;
    var v: u32 = 0;
    while (j.* < s.len and std.ascii.isDigit(s[j.*]) and j.* - start < max) : (j.* += 1) v = v * 10 + (s[j.*] - '0');
    if (j.* == start) return null;
    return v;
}

/// A date given as text: ISO, else Oracle's default format DD-MON-RR
/// (also DD-MON-YYYY).
pub fn parseDefault(s: []const u8, now: DateTime) ?DateTime {
    if (parseIso(s)) |d| return d;
    return parse(s, "DD-MON-RR HH24:MI:SS", now) catch parse(s, "DD-MON-RR", now) catch null;
}

// ================================================================= tests

const testing = std.testing;

fn expectFormat(d: DateTime, fmt: []const u8, want: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(&w, d, fmt);
    try testing.expectEqualStrings(want, w.buffered());
}

test "oracle dates: calendar" {
    const d = parseIso("2024-01-31 10:20:30").?;
    try testing.expectEqual(@as(i64, 19753), d.days());
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2024-02-29 10:20:30", writeDate(&buf, addMonths(d, 1)));
    try testing.expectEqualStrings("2023-11-30 10:20:30", writeDate(&buf, addMonths(d, -2)));
    try testing.expectEqualStrings("2024-01-31 10:20:30.000000", writeTimestamp(&buf, d, 6));
    try testing.expectEqual(@as(u8, 3), d.weekday()); // Wednesday
    try testing.expectEqualStrings("2024-01-29 00:00:00", writeDate(&buf, truncate(d, "IW", false).?));
    try testing.expectEqualStrings("2024-01-01 00:00:00", writeDate(&buf, truncate(d, "YYYY", false).?));
    try testing.expectEqualStrings("2024-02-01 00:00:00", writeDate(&buf, truncate(d, "MM", true).?));
    try testing.expect(parseIso("2024-02-30") == null);
    try testing.expectApproxEqAbs(@as(f64, 2.4516129), monthsBetween(parseIso("2024-03-15").?, parseIso("2024-01-01").?), 1e-6);
}

test "oracle dates: format models" {
    const d = parseIso("2024-03-05 14:07:09.123456").?;
    try expectFormat(d, "DD-MON-YYYY Day", "05-MAR-2024 Tuesday  ");
    try expectFormat(d, "fmMonth dd, yyyy", "March 5, 2024");
    try expectFormat(d, "YYYY-MM-DD HH24:MI:SS.FF3 AM", "2024-03-05 14:07:09.123 PM");
    try expectFormat(d, "\"Q\"Q DDD J", "Q1 065 2460375");
    const p = try parse("05-MAR-24 2:07 pm", "DD-MON-RR HH:MI AM", d);
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2024-03-05 14:07:00", writeDate(&buf, p));
    try testing.expectEqualStrings("2024-03-01 10:30:00", writeDate(&buf, try parse("10:30", "HH24:MI", d)));
    try testing.expectError(error.BadMonth, parse("2024-13-01", "YYYY-MM-DD", d));
}
