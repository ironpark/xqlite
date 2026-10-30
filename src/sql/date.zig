//! The date and time SQL functions: julianday(), unixepoch(), date(),
//! time(), datetime(), strftime(), timediff() and current_time() and
//! friends (port of date.c).
//!
//! All times are handled as julian day numbers: days since noon in
//! Greenwich on November 24, 4714 B.C. (proleptic Gregorian calendar).
//! 1970-01-01 00:00:00 is JD 2440587.5. Only years 0000 to 9999 can be
//! rendered. The algorithms follow Jean Meeus, Astronomical Algorithms,
//! 2nd Edition, 1998.

const std = @import("std");
const int = @import("sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const api = @import("../vdbe/api.zig");
const ctype = @import("../util/ctype.zig");
const numeric = @import("numeric.zig");
const printf = @import("printf.zig");
const FUNC = @import("callback.zig").FUNC;

const FuncDef = int.FuncDef;
const Context = vi.Context;
const Mem = vi.Mem;
const RC = int.RC;
const StrAccum = printf.StrAccum;

/// A single date and time (DateTime).
const DateTime = struct {
    /// The julian day number times 86400000.
    i_jd: i64 = 0,
    year: i32 = 0,
    month: i32 = 0,
    day: i32 = 0,
    hour: i32 = 0,
    minute: i32 = 0,
    /// Timezone offset in minutes.
    tz: i32 = 0,
    sec: f64 = 0,
    valid_jd: bool = false,
    valid_ymd: bool = false,
    valid_hms: bool = false,
    /// Days to implement "floor".
    n_floor: i32 = 0,
    /// Raw numeric value stored in sec.
    raw_s: bool = false,
    /// An overflow has occurred.
    is_error: bool = false,
    /// Display subsecond precision.
    use_subsec: bool = false,
    /// Time is known to be UTC.
    is_utc: bool = false,
    /// Time is known to be localtime.
    is_local: bool = false,
};

/// Port of getDigits(): convert the start of `z` into integers as `fmt`
/// says, writing them to `out`. Each spec is 4 characters ABCD (the last
/// one 3): A the number of digits, B the minimum value, C the maximum
/// ('a' 12, 'b' 14, 'c' 24, 'd' 31, 'e' 59, 'f' 14712), D the separator
/// that must follow. Returns the number of successful conversions.
fn getDigits(z_arg: [*:0]const u8, fmt: []const u8, out: []const *i32) usize {
    const a_mx = [_]u16{ 12, 14, 24, 31, 59, 14712 };
    var z = z_arg;
    var f: usize = 0;
    var cnt: usize = 0;
    while (true) {
        var n = fmt[f] - '0';
        const min = fmt[f + 1] - '0';
        std.debug.assert(fmt[f + 2] >= 'a' and fmt[f + 2] <= 'f');
        const max = a_mx[fmt[f + 2] - 'a'];
        const next_c: u8 = if (f + 3 < fmt.len) fmt[f + 3] else 0;
        var val: i32 = 0;
        while (n > 0) : (n -= 1) {
            if (!ctype.isDigit(z[0])) return cnt;
            val = val * 10 + z[0] - '0';
            z += 1;
        }
        if (val < min or val > max or (next_c != 0 and next_c != z[0])) return cnt;
        out[cnt].* = val;
        z += 1;
        cnt += 1;
        f += 4;
        if (next_c == 0) return cnt;
    }
}

/// Port of parseTimezone(): parse a trailing "(+/-)HH:MM" or "Z" into
/// p.tz. A missing timezone is not an error. Returns true on error.
fn parseTimezone(z_arg: [*:0]const u8, p: *DateTime) bool {
    var z = z_arg;
    while (ctype.isSpace(z[0])) z += 1;
    p.tz = 0;
    const c = z[0];
    var sgn: i32 = 0;
    if (c == '-') {
        sgn = -1;
    } else if (c == '+') {
        sgn = 1;
    } else if (c == 'Z' or c == 'z') {
        z += 1;
        p.is_local = false;
        p.is_utc = true;
        while (ctype.isSpace(z[0])) z += 1;
        return z[0] != 0;
    } else {
        return c != 0;
    }
    z += 1;
    var n_hr: i32 = undefined;
    var n_mn: i32 = undefined;
    if (getDigits(z, "20b:20e", &.{ &n_hr, &n_mn }) != 2) return true;
    z += 5;
    p.tz = sgn * (n_mn + n_hr * 60);
    if (p.tz == 0) {
        p.is_local = false;
        p.is_utc = true;
    }
    while (ctype.isSpace(z[0])) z += 1;
    return z[0] != 0;
}

/// Port of parseHhMmSs(): parse HH:MM, HH:MM:SS or HH:MM:SS.FFFF, then an
/// optional timezone. Returns true on error.
fn parseHhMmSs(z_arg: [*:0]const u8, p: *DateTime) bool {
    var z = z_arg;
    var h: i32 = undefined;
    var m: i32 = undefined;
    var s: i32 = undefined;
    var ms: f64 = 0.0;
    if (getDigits(z, "20c:20e", &.{ &h, &m }) != 2) return true;
    z += 5;
    if (z[0] == ':') {
        z += 1;
        if (getDigits(z, "20e", &.{&s}) != 1) return true;
        z += 2;
        if (z[0] == '.' and ctype.isDigit(z[1])) {
            var r_scale: f64 = 1.0;
            z += 1;
            while (ctype.isDigit(z[0])) {
                ms = ms * 10.0 + @as(f64, @floatFromInt(z[0] - '0'));
                r_scale *= 10.0;
                z += 1;
            }
            ms /= r_scale;
            // Truncate to avoid sub-millisecond rounding problems.
            if (ms > 0.999) ms = 0.999;
        }
    } else {
        s = 0;
    }
    if (h == 24 and (m != 0 or s != 0 or ms != 0.0)) return true;
    p.valid_jd = false;
    p.raw_s = false;
    p.valid_hms = true;
    p.hour = h;
    p.minute = m;
    p.sec = @as(f64, @floatFromInt(s)) + ms;
    return parseTimezone(z, p);
}

/// Port of datetimeError(): put `p` into its error state.
fn datetimeError(p: *DateTime) void {
    p.* = .{ .is_error = true };
}

/// Port of computeJD(): YYYY-MM-DD HH:MM:SS (Gregorian) to julian day
/// (Meeus page 61).
fn computeJD(p: *DateTime) void {
    if (p.valid_jd) return;
    var y: i32 = undefined;
    var m: i32 = undefined;
    var d: i32 = undefined;
    if (p.valid_ymd) {
        y = p.year;
        m = p.month;
        d = p.day;
    } else {
        // Without a date, assume 2000-01-01.
        y = 2000;
        m = 1;
        d = 1;
        if (p.valid_hms and p.hour == 24) {
            p.hour = 0;
            d = 2;
        }
    }
    if (y < -4713 or y > 9999 or p.raw_s) {
        datetimeError(p);
        return;
    }
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const a = @divTrunc(y + 4800, 100);
    const b = 38 - a + @divTrunc(a, 4);
    const x1 = @divTrunc(36525 * (y + 4716), 100);
    const x2 = @divTrunc(306001 * (m + 1), 10000);
    p.i_jd = @intFromFloat((@as(f64, @floatFromInt(x1 + x2 + d + b)) - 1524.5) * 86400000);
    p.valid_jd = true;
    if (p.valid_hms) {
        p.i_jd += @as(i64, p.hour) * 3600000 + @as(i64, p.minute) * 60000 +
            @as(i64, @intFromFloat(p.sec * 1000 + 0.5));
        if (p.tz != 0) {
            p.i_jd -= @as(i64, p.tz) * 60000;
            p.valid_ymd = false;
            p.valid_hms = false;
            p.tz = 0;
            p.is_utc = true;
            p.is_local = false;
        }
    }
}

/// Port of daysOfMonth().
fn daysOfMonth(y: i32, m: i32) i32 {
    if ((@as(u32, 1) << @intCast(m)) & 0x15aa != 0) return 31;
    if (m != 2) return 30;
    if (@rem(y, 4) == 0 and (@rem(y, 100) != 0 or @rem(y, 400) == 0)) return 29;
    return 28;
}

/// Port of computeFloor(): set n_floor to the days of day-of-month
/// overflow, which "floor" subtracts.
fn computeFloor(p: *DateTime) void {
    std.debug.assert(p.valid_ymd or p.is_error);
    std.debug.assert(p.day >= 0 and p.day <= 32);
    std.debug.assert(p.month >= 0 and p.month <= 12);
    const mx_d = daysOfMonth(p.year, p.month);
    p.n_floor = if (p.day > mx_d) p.day - mx_d else 0;
}

/// Port of parseYyyyMmDd(): parse YYYY-MM-DD, optionally followed by a
/// time. Returns true if the text is not a well-formed date.
fn parseYyyyMmDd(z_arg: [*:0]const u8, p: *DateTime) bool {
    var z = z_arg;
    var neg = false;
    if (z[0] == '-') {
        z += 1;
        neg = true;
    }
    var y: i32 = undefined;
    var m: i32 = undefined;
    var d: i32 = undefined;
    if (getDigits(z, "40f-21a-21d", &.{ &y, &m, &d }) != 3) return true;
    z += 10;
    while (ctype.isSpace(z[0]) or z[0] == 'T') z += 1;
    if (!parseHhMmSs(z, p)) {
        if (p.hour == 24) {
            const mx_d = daysOfMonth(y, m);
            p.hour = 0;
            d += 1;
            if (d > mx_d) {
                d -= mx_d;
                m += 1;
                if (m > 12) {
                    m = 1;
                    y += 1;
                }
            }
        }
    } else if (z[0] == 0) {
        p.valid_hms = false;
    } else {
        return true;
    }
    p.valid_jd = false;
    p.valid_ymd = true;
    p.year = if (neg) -y else y;
    p.month = m;
    p.day = d;
    computeFloor(p);
    if (p.tz != 0) computeJD(p);
    return false;
}

/// Port of setDateTimeToCurrent(): the statement's current time. Returns
/// true on error.
fn setDateTimeToCurrent(ctx: *Context, p: *DateTime) bool {
    p.i_jd = api.stmtCurrentTime(ctx);
    if (p.i_jd > 0) {
        p.valid_jd = true;
        p.is_utc = true;
        p.is_local = false;
        clearYMD_HMS_TZ(p);
        return false;
    }
    return true;
}

/// Port of setRawDateNumber(): `r` may be a julian day number or unix
/// seconds. Keep it in sec (raw_s) and, if it is in range of a julian day
/// number, install it as one.
fn setRawDateNumber(p: *DateTime, r: f64) void {
    p.sec = r;
    p.raw_s = true;
    if (r >= 0.0 and r < 5373484.5) {
        p.i_jd = @intFromFloat(r * 86400000.0 + 0.5);
        p.valid_jd = true;
    }
}

/// Port of parseDateOrTime(): parse "YYYY-MM-DD HH:MM:SS.FFF +/-HH:MM"
/// (date or time may be omitted), a number, "now" or "subsec". Returns
/// true on error.
fn parseDateOrTime(ctx: *Context, z: [:0]const u8, p: *DateTime) bool {
    const zs = std.mem.span(z.ptr);
    var r: f64 = undefined;
    if (!parseYyyyMmDd(z, p)) return false;
    if (!parseHhMmSs(z, p)) return false;
    if (ctype.eqlNoCase(zs, "now") and api.notPureFunc(ctx)) {
        return setDateTimeToCurrent(ctx, p);
    }
    if (numeric.atoF(z, &r) > 0) {
        setRawDateNumber(p, r);
        return false;
    }
    if ((ctype.eqlNoCase(zs, "subsec") or ctype.eqlNoCase(zs, "subsecond")) and api.notPureFunc(ctx)) {
        p.use_subsec = true;
        return setDateTimeToCurrent(ctx, p);
    }
    return true;
}

/// The largest DateTime.i_jd: 9999-12-31 23:59:59.999.
const max_i_jd: i64 = 464269060799999;

/// Port of validJulianDay().
fn validJulianDay(i_jd: i64) bool {
    return i_jd >= 0 and i_jd <= max_i_jd;
}

/// Port of computeYMD(): year, month and day from the julian day number.
fn computeYMD(p: *DateTime) void {
    if (p.valid_ymd) return;
    if (!p.valid_jd) {
        p.year = 2000;
        p.month = 1;
        p.day = 1;
    } else if (!validJulianDay(p.i_jd)) {
        datetimeError(p);
        return;
    } else {
        const z: i32 = @intCast(@divTrunc(p.i_jd + 43200000, 86400000));
        const zf: f64 = @floatFromInt(z);
        const alpha: i32 = @as(i32, @intFromFloat((zf + 32044.75) / 36524.25)) - 52;
        const a = z + 1 + alpha - @divTrunc(alpha + 100, 4) + 25;
        const b = a + 1524;
        const c: i32 = @intFromFloat((@as(f64, @floatFromInt(b)) - 122.1) / 365.25);
        const d = @divTrunc(36525 * (c & 32767), 100);
        const e: i32 = @intFromFloat(@as(f64, @floatFromInt(b - d)) / 30.6001);
        const x1: i32 = @intFromFloat(30.6001 * @as(f64, @floatFromInt(e)));
        p.day = b - d - x1;
        p.month = if (e < 14) e - 1 else e - 13;
        p.year = if (p.month > 2) c - 4716 else c - 4715;
    }
    p.valid_ymd = true;
}

/// Port of computeHMS(): hour, minute and seconds from the julian day
/// number.
fn computeHMS(p: *DateTime) void {
    if (p.valid_hms) return;
    computeJD(p);
    const day_ms: i32 = @intCast(@rem(p.i_jd + 43200000, 86400000));
    p.sec = @as(f64, @floatFromInt(@rem(day_ms, 60000))) / 1000.0;
    const day_min = @divTrunc(day_ms, 60000);
    p.minute = @rem(day_min, 60);
    p.hour = @divTrunc(day_min, 60);
    p.raw_s = false;
    p.valid_hms = true;
}

/// Port of computeYMD_HMS().
fn computeYMD_HMS(p: *DateTime) void {
    computeYMD(p);
    computeHMS(p);
}

/// Port of clearYMD_HMS_TZ().
fn clearYMD_HMS_TZ(p: *DateTime) void {
    p.valid_ymd = false;
    p.valid_hms = false;
    p.tz = 0;
}

/// struct tm of the C library (POSIX layout with the BSD/glibc extras).
const Tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn localtime_r(t: *const time_t, result: *Tm) ?*Tm;

/// time_t of the C library; without one (wasm32-freestanding), seconds.
const time_t = if (@import("builtin").link_libc) std.c.time_t else i64;

/// Port of osLocaltime(): localtime_r(). Returns true on error.
/// Without a C library there is no time zone: local time is UTC, as
/// wasi-libc's localtime_r() has it too.
fn osLocaltime(t: *const time_t, tm: *Tm) bool {
    const tc = &@import("global.zig").testctrl;
    if (tc.localtime_fault != 0) {
        // SQLITE_TESTCTRL_LOCALTIME_FAULT.
        const alt = tc.alt_localtime orelse return true;
        return alt(t, tm) != 0;
    }
    if (!@import("builtin").link_libc) {
        const secs = std.math.cast(u64, t.*) orelse return true;
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        tm.* = .{
            .tm_sec = ds.getSecondsIntoMinute(),
            .tm_min = ds.getMinutesIntoHour(),
            .tm_hour = ds.getHoursIntoDay(),
            .tm_mday = @as(c_int, md.day_index) + 1,
            .tm_mon = @as(c_int, md.month.numeric()) - 1,
            .tm_year = @as(c_int, yd.year) - 1900,
            .tm_yday = yd.day,
        };
        return false;
    }
    return localtime_r(t, tm) == null;
}

/// The failures of a modifier: not one, or (with an error set on the
/// context) no local time.
const ModifierError = error{ BadModifier, LocaltimeUnavailable };

/// Port of toLocaltime(): move `p`, taken as UTC, to local time. Sets an
/// error on `ctx` and fails (C: SQLITE_ERROR) if local time is
/// unavailable.
fn toLocaltime(p: *DateTime, ctx: *Context) ModifierError!void {
    var s_local: Tm = .{};
    var i_year_diff: i32 = undefined;
    var t: time_t = undefined;
    computeJD(p);
    if (p.i_jd < 2108667600 * @as(i64, 100000) // 1970-01-01
    or p.i_jd > 2130141456 * @as(i64, 100000) // 2038-01-18
    ) {
        // localtime_r() normally only works for years 1970 to 2037; map
        // the year into an equivalent one in that range and back.
        var x = p.*;
        computeYMD_HMS(&x);
        i_year_diff = (2000 + @rem(x.year, 4)) - x.year;
        x.year += i_year_diff;
        x.valid_jd = false;
        computeJD(&x);
        t = @intCast(@divTrunc(x.i_jd, 1000) - 21086676 * @as(i64, 10000));
    } else {
        i_year_diff = 0;
        t = @intCast(@divTrunc(p.i_jd, 1000) - 21086676 * @as(i64, 10000));
    }
    if (osLocaltime(&t, &s_local)) {
        api.resultError(ctx, "local time unavailable");
        return error.LocaltimeUnavailable;
    }
    p.year = s_local.tm_year + 1900 - i_year_diff;
    p.month = s_local.tm_mon + 1;
    p.day = s_local.tm_mday;
    p.hour = s_local.tm_hour;
    p.minute = s_local.tm_min;
    p.sec = @as(f64, @floatFromInt(s_local.tm_sec)) + @as(f64, @floatFromInt(@rem(p.i_jd, 1000))) * 0.001;
    p.valid_ymd = true;
    p.valid_hms = true;
    p.valid_jd = false;
    p.raw_s = false;
    p.tz = 0;
    p.is_error = false;
}

/// The 'NNN days' style transformations (aXformType): unit name, the
/// largest NNN allowed, and seconds per unit.
const XformType = struct { name: []const u8, r_limit: f32, r_xform: f32 };
const xform_types = [_]XformType{
    .{ .name = "second", .r_limit = 4.6427e+14, .r_xform = 1.0 },
    .{ .name = "minute", .r_limit = 7.7379e+12, .r_xform = 60.0 },
    .{ .name = "hour", .r_limit = 1.2897e+11, .r_xform = 3600.0 },
    .{ .name = "day", .r_limit = 5373485.0, .r_xform = 86400.0 },
    .{ .name = "month", .r_limit = 176546.0, .r_xform = 2592000.0 },
    .{ .name = "year", .r_limit = 14713.0, .r_xform = 31536000.0 },
};

/// Port of autoAdjustDate(): a raw number becomes a julian day number or
/// unix seconds, depending on its magnitude.
fn autoAdjustDate(p: *DateTime) void {
    if (!p.raw_s or p.valid_jd) {
        p.raw_s = false;
    } else if (p.sec >= @as(f64, @floatFromInt(-21086676 * @as(i64, 10000))) // -4713-11-24 12:00:00
    and p.sec <= @as(f64, @floatFromInt(25340230 * @as(i64, 10000) + 799)) // 9999-12-31 23:59:59
    ) {
        const r = p.sec * 1000.0 + 210866760000000.0;
        clearYMD_HMS_TZ(p);
        p.i_jd = @intFromFloat(r + 0.5);
        p.valid_jd = true;
        p.raw_s = false;
    }
}

/// sqlite3_strnicmp(z, prefix, prefix.len) == 0.
fn hasPrefixNoCase(z: [*:0]const u8, prefix: []const u8) bool {
    for (prefix, 0..) |c, i| {
        if (ctype.toLower(z[i]) != ctype.toLower(c)) return false;
    }
    return true;
}

/// sqlite3_stricmp(z, s) == 0.
fn eqlZ(z: [*:0]const u8, s: []const u8) bool {
    return ctype.eqlNoCase(std.mem.span(z), s);
}

/// Fails with BadModifier unless `ok`.
fn modifierDone(ok: bool) ModifierError!void {
    if (!ok) return error.BadModifier;
}

/// Port of parseModifier(): apply modifier `z_arg` (argument `idx`) to
/// `p`; fails (C: nonzero) if it is not one or cannot be applied. Only
/// errors in system calls (localtime()) set an error on `ctx`; an
/// unknown modifier does not.
fn parseModifier(ctx: *Context, z_arg: [*:0]const u8, p: *DateTime, idx: usize) ModifierError!void {
    var z = z_arg;
    var ok = false;
    var r: f64 = undefined;
    switch (ctype.toLower(z[0])) {
        'a' => {
            // auto: a raw number is a julian day number or unix seconds,
            // depending on its magnitude.
            if (eqlZ(z, "auto")) {
                if (idx > 1) return error.BadModifier;
                autoAdjustDate(p);
                ok = true;
            }
        },
        'c' => {
            // ceiling: roll day-of-month overflow into the next month (the
            // default; here for symmetry with "floor").
            if (eqlZ(z, "ceiling")) {
                computeJD(p);
                clearYMD_HMS_TZ(p);
                ok = true;
                p.n_floor = 0;
            }
        },
        'e' => {
            // end of day / month / year: the last millisecond of it.
            if (!hasPrefixNoCase(z, "end of ")) return modifierDone(ok);
            if (!p.valid_jd and !p.valid_ymd and !p.valid_hms) return modifierDone(ok);
            z += 7;
            computeYMD(p);
            p.valid_hms = true;
            p.hour = 23;
            p.minute = 59;
            p.sec = 59.999;
            p.raw_s = false;
            p.tz = 0;
            p.valid_jd = false;
            if (eqlZ(z, "month")) {
                p.day = 1;
                p.month += 1;
                if (p.month > 12) {
                    p.year += 1;
                    p.month = 1;
                }
                computeFloor(p);
                computeJD(p);
                p.i_jd -= @as(i64, p.n_floor + 1) * 86400000;
                clearYMD_HMS_TZ(p);
                ok = true;
            } else if (eqlZ(z, "year")) {
                p.month = 12;
                p.day = 31;
                ok = true;
            } else if (eqlZ(z, "day")) {
                ok = true;
            }
        },
        'f' => {
            // floor: roll day-of-month overflow back to the end of the
            // previous month.
            if (eqlZ(z, "floor")) {
                computeJD(p);
                p.i_jd -= @as(i64, p.n_floor) * 86400000;
                clearYMD_HMS_TZ(p);
                ok = true;
            }
        },
        'j' => {
            // julianday: the prior number is a julian day number. Only as
            // the first modifier, and only for an in-range number.
            if (eqlZ(z, "julianday")) {
                if (idx > 1) return error.BadModifier;
                if (p.valid_jd and p.raw_s) {
                    ok = true;
                    p.raw_s = false;
                }
            }
        },
        'l' => {
            // localtime: shift a UTC time to local time.
            if (eqlZ(z, "localtime") and api.notPureFunc(ctx)) {
                const local = if (p.is_local) {} else toLocaltime(p, ctx);
                p.is_utc = false;
                p.is_local = true;
                try local;
                ok = true;
            }
        },
        'u' => {
            if (eqlZ(z, "unixepoch") and p.raw_s) {
                // unixepoch: the raw number is seconds since 1970.
                if (idx > 1) return error.BadModifier;
                r = p.sec * 1000.0 + 210866760000000.0;
                if (r >= 0.0 and r < 464269060800000.0) {
                    clearYMD_HMS_TZ(p);
                    p.i_jd = @intFromFloat(r + 0.5);
                    p.valid_jd = true;
                    p.raw_s = false;
                    ok = true;
                }
            } else if (eqlZ(z, "utc") and api.notPureFunc(ctx)) {
                // utc: shift a local time to UTC, by guessing and
                // correcting with toLocaltime().
                if (!p.is_utc) {
                    var cnt: i32 = 0;
                    computeJD(p);
                    const i_orig_jd = p.i_jd;
                    var i_guess = i_orig_jd;
                    var i_err: i64 = 0;
                    while (true) {
                        var nw: DateTime = .{};
                        i_guess -= i_err;
                        nw.i_jd = i_guess;
                        nw.valid_jd = true;
                        try toLocaltime(&nw, ctx);
                        computeJD(&nw);
                        i_err = nw.i_jd - i_orig_jd;
                        if (i_err == 0) break;
                        const c = cnt;
                        cnt += 1;
                        if (c >= 3) break;
                    }
                    p.* = .{};
                    p.i_jd = i_guess;
                    p.valid_jd = true;
                    p.is_utc = true;
                    p.is_local = false;
                }
                ok = true;
            }
        },
        'w' => {
            // weekday N / weekday -N: move forward (backward for -N) to
            // the next (previous) weekday N, 0 being Sunday; a no-op if
            // already on it.
            if (hasPrefixNoCase(z, "weekday ") and numeric.atoF(z + 8, &r) > 0 and
                r >= -6.0 and r <= 6.0)
            {
                var n: i32 = @intFromFloat(r);
                if (!numeric.realSameAsInt(r, n)) return modifierDone(ok);
                computeYMD_HMS(p);
                p.tz = 0;
                p.valid_jd = false;
                computeJD(p);
                var zd: i64 = @rem(@divTrunc(p.i_jd + 129600000, 86400000), 7);
                if (n < 0) n = -n;
                if (zd != n) {
                    if (zd > n) zd -= 7;
                    p.i_jd += (n - zd) * 86400000;
                    if (std.mem.indexOfScalar(u8, std.mem.span(z + 8), '-') != null) {
                        p.i_jd -= 7 * 86400000;
                    }
                }
                clearYMD_HMS_TZ(p);
                ok = true;
            }
        },
        's' => {
            // start of day / month / year: move back to its beginning.
            // subsec / subsecond: show subsecond precision in datetime(),
            // unixepoch() and strftime('%s').
            if (!hasPrefixNoCase(z, "start of ")) {
                if (eqlZ(z, "subsec") or eqlZ(z, "subsecond")) {
                    p.use_subsec = true;
                    ok = true;
                }
                return modifierDone(ok);
            }
            if (!p.valid_jd and !p.valid_ymd and !p.valid_hms) return modifierDone(ok);
            z += 9;
            computeYMD(p);
            p.valid_hms = true;
            p.hour = 0;
            p.minute = 0;
            p.sec = 0.0;
            p.raw_s = false;
            p.tz = 0;
            p.valid_jd = false;
            if (eqlZ(z, "month")) {
                p.day = 1;
                ok = true;
            } else if (eqlZ(z, "year")) {
                p.month = 1;
                p.day = 1;
                ok = true;
            } else if (eqlZ(z, "day")) {
                ok = true;
            }
        },
        '+', '-', '0'...'9' => return parseShiftModifier(ctx, z, p),
        else => {},
    }
    return modifierDone(ok);
}

/// The numeric cases of parseModifier(): "NNN units", "(+|-)HH:MM:SS.FFF"
/// and "(+|-)YYYY-MM-DD HH:MM:SS.FFF".
fn parseShiftModifier(ctx: *Context, z_arg: [*:0]const u8, p: *DateTime) ModifierError!void {
    var z = z_arg;
    var r: f64 = undefined;
    var y: i32 = undefined;
    var m: i32 = undefined;
    var d: i32 = undefined;
    var h: i32 = undefined;
    var mi: i32 = undefined;
    var z2 = z;
    const z0 = z[0];
    var n: usize = 1;
    while (z[n] != 0) : (n += 1) {
        if (z[n] == ':') break;
        if (ctype.isSpace(z[n])) break;
        if (z[n] == '-') {
            if (n == 5 and getDigits(z + 1, "40f", &.{&y}) == 1) break;
            if (n == 6 and getDigits(z + 1, "50f", &.{&y}) == 1) break;
        }
    }
    {
        // atoF() needs the number NUL-terminated.
        var buf: [64]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const a = if (n < buf.len) fba.allocator() else api.contextDbHandle(ctx).gpa;
        const z_copy = a.dupeSentinel(u8, z[0..n], 0) catch return error.BadModifier;
        defer a.free(z_copy);
        if (numeric.atoF(z_copy, &r) <= 0) return error.BadModifier;
    }
    if (z[n] == '-') {
        // (+|-)YYYY-MM-DD adds or subtracts years, months (0-11) and days
        // (0-30).
        if (z0 != '+' and z0 != '-') return error.BadModifier;
        if (n == 5) {
            if (getDigits(z + 1, "40f-20a-20d", &.{ &y, &m, &d }) != 3) return error.BadModifier;
        } else {
            std.debug.assert(n == 6);
            if (getDigits(z + 1, "50f-20a-20d", &.{ &y, &m, &d }) != 3) return error.BadModifier;
            z += 1;
        }
        if (m >= 12) return error.BadModifier;
        if (d >= 31) return error.BadModifier;
        computeYMD_HMS(p);
        p.valid_jd = false;
        if (z0 == '-') {
            p.year -= y;
            p.month -= m;
            d = -d;
        } else {
            p.year += y;
            p.month += m;
        }
        const x = if (p.month > 0) @divTrunc(p.month - 1, 12) else @divTrunc(p.month - 12, 12);
        p.year += x;
        p.month -= x * 12;
        computeFloor(p);
        computeJD(p);
        p.valid_hms = false;
        p.valid_ymd = false;
        p.i_jd += @as(i64, d) * 86400000;
        if (z[11] == 0) return;
        if (ctype.isSpace(z[11]) and getDigits(z + 12, "20c:20e", &.{ &h, &mi }) == 2) {
            z2 = z + 12;
            n = 2;
        } else {
            return error.BadModifier;
        }
    }
    if (z2[n] == ':') {
        // (+|-)HH:MM:SS.FFF adds or subtracts a time; ":SS.FFF" and ".FFF"
        // are optional.
        if (!ctype.isDigit(z2[0])) z2 += 1;
        var tx: DateTime = .{};
        if (parseHhMmSs(z2, &tx)) return error.BadModifier;
        computeJD(&tx);
        tx.i_jd -= 43200000;
        const day = @divTrunc(tx.i_jd, 86400000);
        tx.i_jd -= day * 86400000;
        if (z0 == '-') tx.i_jd = -tx.i_jd;
        computeJD(p);
        clearYMD_HMS_TZ(p);
        p.i_jd += tx.i_jd;
        return;
    }

    // "+NNN days" and the like.
    z += n;
    while (ctype.isSpace(z[0])) z += 1;
    var unit: []const u8 = std.mem.span(z);
    if (unit.len < 3 or unit.len > 10) return error.BadModifier;
    if (ctype.toLower(unit[unit.len - 1]) == 's') unit = unit[0 .. unit.len - 1];
    computeJD(p);
    var ok = false;
    const r_rounder: f64 = if (r < 0) -0.5 else 0.5;
    p.n_floor = 0;
    for (xform_types, 0..) |xt, i| {
        if (xt.name.len == unit.len and ctype.eqlNoCase(xt.name, unit) and
            r > -xt.r_limit and r < xt.r_limit)
        {
            switch (i) {
                4 => {
                    // Adding months.
                    computeYMD_HMS(p);
                    p.month += @as(i32, @intFromFloat(r));
                    const x = if (p.month > 0) @divTrunc(p.month - 1, 12) else @divTrunc(p.month - 12, 12);
                    p.year += x;
                    p.month -= x * 12;
                    computeFloor(p);
                    p.valid_jd = false;
                    r -= @trunc(r);
                },
                5 => {
                    // Adding years.
                    const yr: i32 = @intFromFloat(r);
                    computeYMD_HMS(p);
                    std.debug.assert(p.month >= 0 and p.month <= 12);
                    p.year += yr;
                    computeFloor(p);
                    p.valid_jd = false;
                    r -= @trunc(r);
                },
                else => {},
            }
            computeJD(p);
            p.i_jd += @as(i64, @intFromFloat(r * 1000.0 * xt.r_xform + r_rounder));
            ok = true;
            break;
        }
    }
    clearYMD_HMS_TZ(p);
    return modifierDone(ok);
}

/// Port of isDate(): argv[0] is a date-time and the rest are modifiers;
/// parse them all into `p`. No arguments means "now". Returns true on
/// error.
fn isDate(ctx: *Context, argv: []const *Mem, p: *DateTime) bool {
    p.* = .{};
    if (argv.len == 0) {
        if (!api.notPureFunc(ctx)) return true;
        return setDateTimeToCurrent(ctx, p);
    }
    const e_type = api.valueType(argv[0]);
    if (e_type == vi.SQLITE_FLOAT or e_type == vi.SQLITE_INTEGER) {
        setRawDateNumber(p, api.valueDouble(argv[0]));
    } else {
        const z = api.valueText(argv[0]) orelse return true;
        if (parseDateOrTime(ctx, z, p)) return true;
    }
    for (argv[1..], 1..) |arg, i| {
        const z = api.valueText(arg) orelse return true;
        parseModifier(ctx, z, p, i) catch return true;
    }
    computeJD(p);
    if (p.is_error or !validJulianDay(p.i_jd)) return true;
    if (argv.len == 1 and p.valid_ymd and p.day > 28) {
        // Normalize YYYY-MM-DD, e.g. 2023-02-31 -> 2023-03-03.
        std.debug.assert(p.valid_jd);
        p.valid_ymd = false;
    }
    return false;
}

// ============================================================== functions

/// Port of juliandayFunc(): julianday(TIMESTRING, MOD, ...).
fn juliandayFunc(ctx: *Context, argv: []*Mem) void {
    var x: DateTime = undefined;
    if (!isDate(ctx, argv, &x)) {
        computeJD(&x);
        api.resultDouble(ctx, @as(f64, @floatFromInt(x.i_jd)) / 86400000.0);
    }
}

/// Port of unixepochFunc(): unixepoch(TIMESTRING, MOD, ...), seconds since
/// 1970-01-01 00:00:00 UTC.
fn unixepochFunc(ctx: *Context, argv: []*Mem) void {
    var x: DateTime = undefined;
    if (!isDate(ctx, argv, &x)) {
        computeJD(&x);
        if (x.use_subsec) {
            api.resultDouble(ctx, @as(f64, @floatFromInt(x.i_jd - 21086676 * @as(i64, 10000000))) / 1000.0);
        } else {
            api.resultInt64(ctx, @divTrunc(x.i_jd, 1000) - 21086676 * @as(i64, 10000));
        }
    }
}

/// '0' + n % 10 for a non-negative n.
fn digit(n: i32) u8 {
    return @intCast('0' + @rem(n, 10));
}

/// Writes HH:MM:SS or HH:MM:SS.SSS to `buf`; returns the length.
fn formatHms(buf: []u8, x: *const DateTime) usize {
    buf[0] = digit(@divTrunc(x.hour, 10));
    buf[1] = digit(x.hour);
    buf[2] = ':';
    buf[3] = digit(@divTrunc(x.minute, 10));
    buf[4] = digit(x.minute);
    buf[5] = ':';
    if (x.use_subsec) {
        const s: i32 = @intFromFloat(1000.0 * x.sec + 0.5);
        buf[6] = digit(@divTrunc(s, 10000));
        buf[7] = digit(@divTrunc(s, 1000));
        buf[8] = '.';
        buf[9] = digit(@divTrunc(s, 100));
        buf[10] = digit(@divTrunc(s, 10));
        buf[11] = digit(s);
        return 12;
    }
    const s: i32 = @intFromFloat(x.sec);
    buf[6] = digit(@divTrunc(s, 10));
    buf[7] = digit(s);
    return 8;
}

/// Writes YYYY-MM-DD (the absolute year) to `buf`.
fn formatYmd(buf: *[10]u8, x: *const DateTime) void {
    const y = if (x.year < 0) -x.year else x.year;
    buf[0] = digit(@divTrunc(y, 1000));
    buf[1] = digit(@divTrunc(y, 100));
    buf[2] = digit(@divTrunc(y, 10));
    buf[3] = digit(y);
    buf[4] = '-';
    buf[5] = digit(@divTrunc(x.month, 10));
    buf[6] = digit(x.month);
    buf[7] = '-';
    buf[8] = digit(@divTrunc(x.day, 10));
    buf[9] = digit(x.day);
}

/// Port of datetimeFunc(): datetime(TIMESTRING, MOD, ...), as
/// YYYY-MM-DD HH:MM:SS.
fn datetimeFunc(ctx: *Context, argv: []*Mem) void {
    var x: DateTime = undefined;
    if (!isDate(ctx, argv, &x)) {
        var buf: [32]u8 = undefined;
        computeYMD_HMS(&x);
        formatYmd(buf[1..11], &x);
        buf[11] = ' ';
        const n = 12 + formatHms(buf[12..], &x);
        if (x.year < 0) {
            buf[0] = '-';
            api.resultText(ctx, buf[0..n], .transient);
        } else {
            api.resultText(ctx, buf[1..n], .transient);
        }
    }
}

/// Port of timeFunc(): time(TIMESTRING, MOD, ...), as HH:MM:SS.
fn timeFunc(ctx: *Context, argv: []*Mem) void {
    var x: DateTime = undefined;
    if (!isDate(ctx, argv, &x)) {
        var buf: [16]u8 = undefined;
        computeHMS(&x);
        const n = formatHms(&buf, &x);
        api.resultText(ctx, buf[0..n], .transient);
    }
}

/// Port of dateFunc(): date(TIMESTRING, MOD, ...), as YYYY-MM-DD.
fn dateFunc(ctx: *Context, argv: []*Mem) void {
    var x: DateTime = undefined;
    if (!isDate(ctx, argv, &x)) {
        var buf: [16]u8 = undefined;
        computeYMD(&x);
        formatYmd(buf[1..11], &x);
        if (x.year < 0) {
            buf[0] = '-';
            api.resultText(ctx, buf[0..11], .transient);
        } else {
            api.resultText(ctx, buf[1..11], .transient);
        }
    }
}

/// Port of daysAfterJan01(): the zero-based day of the year.
fn daysAfterJan01(date: *const DateTime) i32 {
    var jan01 = date.*;
    std.debug.assert(jan01.valid_ymd);
    std.debug.assert(jan01.valid_hms);
    std.debug.assert(date.valid_jd);
    jan01.valid_jd = false;
    jan01.month = 1;
    jan01.day = 1;
    computeJD(&jan01);
    return @intCast(@divTrunc(date.i_jd - jan01.i_jd + 43200000, 86400000));
}

/// Port of daysAfterMonday(): 0 for Monday through 6 for Sunday.
fn daysAfterMonday(date: *const DateTime) i32 {
    std.debug.assert(date.valid_jd);
    return @intCast(@rem(@divTrunc(date.i_jd + 43200000, 86400000), 7));
}

/// Port of daysAfterSunday(): 0 for Sunday through 6 for Saturday.
fn daysAfterSunday(date: *const DateTime) i32 {
    std.debug.assert(date.valid_jd);
    return @intCast(@rem(@divTrunc(date.i_jd + 129600000, 86400000), 7));
}

/// `x` moved to the Thursday of its ISO week, with its date computed.
fn isoThursday(x: *const DateTime) DateTime {
    var y = x.*;
    std.debug.assert(y.valid_jd);
    y.i_jd += @as(i64, 3 - daysAfterMonday(x)) * 86400000;
    y.valid_ymd = false;
    computeYMD(&y);
    return y;
}

/// Port of strftimeFunc(): strftime(FORMAT, TIMESTRING, MOD, ...).
/// Conversions: %d %e %f %F %G %g %H %k %I %j %J %l %m %M %p %P %R %s %S
/// %T %u %w %U %V %W %Y %%. Any other conversion makes the result NULL.
fn strftimeFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 0) return;
    const z_fmt = api.valueText(argv[0]) orelse return;
    var x: DateTime = undefined;
    if (isDate(ctx, argv[1..], &x)) return;
    const db = api.contextDbHandle(ctx);
    // sqlite3_str_new(): sqlite3_malloc() memory.
    var res = StrAccum.init(@import("malloc.zig").allocator, &.{}, @intCast(db.limit(.length)));

    computeJD(&x);
    computeYMD_HMS(&x);
    var i: usize = 0;
    var j: usize = 0;
    while (z_fmt[i] != 0) : (i += 1) {
        if (z_fmt[i] != '%') continue;
        if (j < i) res.append(z_fmt[j..i]);
        i += 1;
        j = i + 1;
        const cf = z_fmt[i];
        switch (cf) {
            'd', 'e' => res.appendf(if (cf == 'd') "%02d" else "%2d", &.{.{ .int = x.day }}),
            'f' => {
                // Fractional seconds (non-standard).
                var s = x.sec;
                if (s > 59.999) s = 59.999;
                res.appendf("%06.3f", &.{.{ .double = s }});
            },
            'F' => res.appendf("%04d-%02d-%02d", &.{ .{ .int = x.year }, .{ .int = x.month }, .{ .int = x.day } }),
            'G', 'g' => {
                const y = isoThursday(&x);
                if (cf == 'g') {
                    res.appendf("%02d", &.{.{ .int = @rem(y.year, 100) }});
                } else {
                    res.appendf("%04d", &.{.{ .int = y.year }});
                }
            },
            'H', 'k' => res.appendf(if (cf == 'H') "%02d" else "%2d", &.{.{ .int = x.hour }}),
            'I', 'l' => {
                var h = x.hour;
                if (h > 12) h -= 12;
                if (h == 0) h = 12;
                res.appendf(if (cf == 'I') "%02d" else "%2d", &.{.{ .int = h }});
            },
            // Day of year, Jan01 being 1.
            'j' => res.appendf("%03d", &.{.{ .int = daysAfterJan01(&x) + 1 }}),
            // Julian day number (non-standard).
            'J' => res.appendf("%.16g", &.{.{ .double = @as(f64, @floatFromInt(x.i_jd)) / 86400000.0 }}),
            'm' => res.appendf("%02d", &.{.{ .int = x.month }}),
            'M' => res.appendf("%02d", &.{.{ .int = x.minute }}),
            'p', 'P' => {
                if (x.hour >= 12) {
                    res.append(if (cf == 'p') "PM" else "pm");
                } else {
                    res.append(if (cf == 'p') "AM" else "am");
                }
            },
            'R' => res.appendf("%02d:%02d", &.{ .{ .int = x.hour }, .{ .int = x.minute } }),
            's' => {
                if (x.use_subsec) {
                    res.appendf("%.3f", &.{.{ .double = @as(f64, @floatFromInt(x.i_jd - 21086676 * @as(i64, 10000000))) / 1000.0 }});
                } else {
                    const i_s = @divTrunc(x.i_jd, 1000) - 21086676 * @as(i64, 10000);
                    res.appendf("%lld", &.{.{ .int = i_s }});
                }
            },
            'S' => res.appendf("%02d", &.{.{ .int = @as(i32, @intFromFloat(x.sec)) }}),
            'T' => res.appendf("%02d:%02d:%02d", &.{
                .{ .int = x.hour }, .{ .int = x.minute }, .{ .int = @as(i32, @intFromFloat(x.sec)) },
            }),
            'u', 'w' => {
                // Day of week: %u 1-7 from Monday, %w 0-6 from Sunday.
                var c: u8 = @intCast(daysAfterSunday(&x) + '0');
                if (c == '0' and cf == 'u') c = '7';
                res.appendChar(1, c);
            },
            // Week 00-53; the first Sunday of the year starts week 01.
            'U' => res.appendf("%02d", &.{.{ .int = @divTrunc(daysAfterJan01(&x) - daysAfterSunday(&x) + 7, 7) }}),
            'V' => {
                // Week 01-53; the first week with a Thursday is week 01.
                const y = isoThursday(&x);
                res.appendf("%02d", &.{.{ .int = @divTrunc(daysAfterJan01(&y), 7) + 1 }});
            },
            // Week 00-53; the first Monday of the year starts week 01.
            'W' => res.appendf("%02d", &.{.{ .int = @divTrunc(daysAfterJan01(&x) - daysAfterMonday(&x) + 7, 7) }}),
            'Y' => res.appendf("%04d", &.{.{ .int = x.year }}),
            '%' => res.appendChar(1, '%'),
            else => {
                res.reset();
                return;
            },
        }
    }
    if (j < i) res.append(z_fmt[j..i]);
    api.resultStr(ctx, &res, .xfer);
    res.reset();
}

/// Port of ctimeFunc(): current_time(), the same as time('now').
fn ctimeFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    timeFunc(ctx, &.{});
}

/// Port of cdateFunc(): current_date(), the same as date('now').
fn cdateFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    dateFunc(ctx, &.{});
}

/// Port of timediffFunc(): timediff(DATE1, DATE2), the time to add to
/// DATE2 to reach DATE1, as (+|-)YYYY-MM-DD HH:MM:SS.SSS, so that
/// datetime(A) == datetime(B, timediff(A, B)).
fn timediffFunc(ctx: *Context, argv: []*Mem) void {
    var d1: DateTime = undefined;
    var d2: DateTime = undefined;
    if (isDate(ctx, argv[0..1], &d1)) return;
    if (isDate(ctx, argv[1..2], &d2)) return;
    computeYMD_HMS(&d1);
    computeYMD_HMS(&d2);
    var sign: u8 = undefined;
    var y: i32 = undefined;
    var m: i32 = undefined;
    if (d1.i_jd >= d2.i_jd) {
        sign = '+';
        y = d1.year - d2.year;
        if (y != 0) {
            d2.year = d1.year;
            d2.valid_jd = false;
            computeJD(&d2);
        }
        m = d1.month - d2.month;
        if (m < 0) {
            y -= 1;
            m += 12;
        }
        if (m != 0) {
            d2.month = d1.month;
            d2.valid_jd = false;
            computeJD(&d2);
        }
        while (d1.i_jd < d2.i_jd) {
            m -= 1;
            if (m < 0) {
                m = 11;
                y -= 1;
            }
            d2.month -= 1;
            if (d2.month < 1) {
                d2.month = 12;
                d2.year -= 1;
            }
            d2.valid_jd = false;
            computeJD(&d2);
        }
        d1.i_jd -= d2.i_jd;
        d1.i_jd += 1486995408 * @as(i64, 100000);
    } else {
        sign = '-';
        y = d2.year - d1.year;
        if (y != 0) {
            d2.year = d1.year;
            d2.valid_jd = false;
            computeJD(&d2);
        }
        m = d2.month - d1.month;
        if (m < 0) {
            y -= 1;
            m += 12;
        }
        if (m != 0) {
            d2.month = d1.month;
            d2.valid_jd = false;
            computeJD(&d2);
        }
        while (d1.i_jd > d2.i_jd) {
            m -= 1;
            if (m < 0) {
                m = 11;
                y -= 1;
            }
            d2.month += 1;
            if (d2.month > 12) {
                d2.month = 1;
                d2.year += 1;
            }
            d2.valid_jd = false;
            computeJD(&d2);
        }
        d1.i_jd = d2.i_jd - d1.i_jd;
        d1.i_jd += 1486995408 * @as(i64, 100000);
    }
    clearYMD_HMS_TZ(&d1);
    computeYMD_HMS(&d1);
    var res = StrAccum.init(@import("malloc.zig").allocator, &.{}, 100);
    res.appendf("%c%04d-%02d-%02d %02d:%02d:%06.3f", &.{
        .{ .int = sign },       .{ .int = y },       .{ .int = m },
        .{ .int = d1.day - 1 }, .{ .int = d1.hour }, .{ .int = d1.minute },
        .{ .double = d1.sec },
    });
    api.resultStr(ctx, &res, .xfer);
}

/// Port of ctimestampFunc(): current_timestamp(), the same as
/// datetime('now').
fn ctimestampFunc(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    datetimeFunc(ctx, &.{});
}

/// PURE_DATE(): deterministic unless "now" or a time zone conversion is
/// involved. (C sets pUserData to &sqlite3Config, which nothing reads.)
fn pureDate(name: [:0]const u8, n_arg: i16, x_func: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{ .enc = vi.ENC.UTF8, .BUILTIN = true, .SLOCHNG = true, .CONSTANT = true },
        .x_sfunc = x_func,
        .name = name,
    };
}

/// DFUNCTION(): may change between statements, not within one.
const dFunction = @import("func.zig").dfunction;

/// The date and time functions (aDateTimeFuncs of
/// sqlite3RegisterDateTimeFunctions()), for sqlite3InsertBuiltinFuncs().
/// The registry copies them, as it links entries through FuncDef.next.
pub const funcs = [_]FuncDef{
    pureDate("julianday", -1, juliandayFunc),
    pureDate("unixepoch", -1, unixepochFunc),
    pureDate("date", -1, dateFunc),
    pureDate("time", -1, timeFunc),
    pureDate("datetime", -1, datetimeFunc),
    pureDate("strftime", -1, strftimeFunc),
    pureDate("timediff", 2, timediffFunc),
    dFunction("current_time", 0, ctimeFunc),
    dFunction("current_timestamp", 0, ctimestampFunc),
    dFunction("current_date", 0, cdateFunc),
};

// ================================================================== tests

const mem = @import("../vdbe/mem.zig");

/// One SQL value given to a test call.
const TestArg = union(enum) { text: []const u8, int: i64, real: f64, null };

/// Calls the function named `name` with `args` and returns its result
/// rendered as text ("NULL" for NULL), in `buf`.
fn callFunc(buf: []u8, name: []const u8, args: []const TestArg) ![]const u8 {
    var db: int.Sqlite3 = .{ .gpa = undefined };
    db.gpa = @import("malloc.zig").dbAllocator(&db);
    var def: FuncDef = for (funcs) |f| {
        if (std.mem.eql(u8, f.name, name)) break f;
    } else unreachable;
    var cells: [8]Mem = @splat(.{});
    var argv: [8]*Mem = undefined;
    for (args, 0..) |a, i| {
        cells[i] = .{ .db = &db };
        argv[i] = &cells[i];
        switch (a) {
            .text => |t| try mem.setStr(&cells[i], t, vi.ENC.UTF8, .static),
            .int => |v| mem.setInt64(&cells[i], v),
            .real => |v| mem.setDouble(&cells[i], v),
            .null => {},
        }
    }
    defer for (cells[0..args.len]) |*c| mem.release(c);
    var out: Mem = .{ .db = &db };
    defer mem.release(&out);
    var ctx: Context = .{ .out = &out, .func = &def, .argv = &.{} };
    def.x_sfunc.?(&ctx, argv[0..args.len]);
    try std.testing.expectEqual(@as(i32, 0), ctx.is_error);
    return switch (api.valueType(&out)) {
        vi.SQLITE_NULL => "NULL",
        vi.SQLITE_INTEGER => std.fmt.bufPrint(buf, "{d}", .{api.valueInt64(&out)}),
        vi.SQLITE_FLOAT => printf.formatDouble(buf[0..64], api.valueDouble(&out), 17),
        else => blk: {
            const t = api.valueText(&out).?;
            @memcpy(buf[0..t.len], t);
            break :blk buf[0..t.len];
        },
    };
}

fn expectCall(want: []const u8, name: []const u8, args: []const TestArg) !void {
    var buf: [128]u8 = undefined;
    const got = try callFunc(&buf, name, args);
    std.testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("{s}({any})\n", .{ name, args });
        return err;
    };
}

// Expected values come from the sqlite3 3.54.1 shell.

test "date: julianday, unixepoch and the basic formats" {
    try expectCall("2451544.5", "julianday", &.{.{ .text = "2000-01-01" }});
    try expectCall("2451545.0", "julianday", &.{.{ .text = "12:00" }});
    try expectCall("1704067200", "unixepoch", &.{.{ .text = "2024-01-01 00:00:00" }});
    try expectCall("1704067200.25", "unixepoch", &.{ .{ .text = "2024-01-01 00:00:00.250" }, .{ .text = "subsec" } });
    try expectCall("1970-01-01 00:00:00", "datetime", &.{ .{ .int = 0 }, .{ .text = "unixepoch" } });
    try expectCall("2023-02-25 00:00:00", "datetime", &.{.{ .real = 2460000.5 }});
    try expectCall("2023-02-25 00:00:00", "datetime", &.{ .{ .real = 2460000.5 }, .{ .text = "julianday" } });
    try expectCall("2023-11-14 22:13:20", "datetime", &.{ .{ .int = 1700000000 }, .{ .text = "auto" } });
    try expectCall("2024-01-01 12:34:56.789", "datetime", &.{ .{ .text = "2024-01-01 12:34:56.789" }, .{ .text = "subsec" } });
    try expectCall("12:34:56.789", "time", &.{ .{ .text = "12:34:56.789" }, .{ .text = "subsec" } });
    try expectCall("2024-06-15 08:00:00", "datetime", &.{.{ .text = "2024-06-15T10:00:00+02:00" }});
    try expectCall("2024-06-15 10:00:00", "datetime", &.{.{ .text = "2024-06-15 10:00Z" }});
    try expectCall("2023-03-03", "date", &.{.{ .text = "2023-02-31" }});
    try expectCall("2025-01-01 00:00:00", "datetime", &.{.{ .text = "2024-12-31 24:00" }});
    try expectCall("-0044-03-15", "date", &.{.{ .text = "-0044-03-15" }});
}

test "date: modifiers" {
    try expectCall("2025-03-01", "date", &.{ .{ .text = "2024-02-29" }, .{ .text = "+1 year" } });
    try expectCall("13:30:00", "time", &.{ .{ .text = "12:00" }, .{ .text = "+90 minutes" } });
    try expectCall("2024-03-02", "date", &.{ .{ .text = "2024-03-31" }, .{ .text = "-1 month" } });
    try expectCall("2024-02-29", "date", &.{ .{ .text = "2024-03-31" }, .{ .text = "-1 month" }, .{ .text = "floor" } });
    try expectCall("2024-03-02", "date", &.{ .{ .text = "2024-01-31" }, .{ .text = "+1 month" }, .{ .text = "ceiling" } });
    try expectCall("2024-05-01", "date", &.{ .{ .text = "2024-05-17" }, .{ .text = "start of month" } });
    try expectCall("2024-01-01", "date", &.{ .{ .text = "2024-06-15" }, .{ .text = "start of year" } });
    try expectCall("2024-06-15 00:00:00", "datetime", &.{ .{ .text = "2024-06-15 13:14:15" }, .{ .text = "start of day" } });
    try expectCall("2024-05-19", "date", &.{ .{ .text = "2024-05-17" }, .{ .text = "weekday 0" } });
    try expectCall("2024-06-10", "date", &.{ .{ .text = "2024-06-15" }, .{ .text = "weekday -1" } });
    try expectCall("2024-01-31 23:59:59", "datetime", &.{ .{ .text = "2024-01-31" }, .{ .text = "end of month" } });
    try expectCall("2024-12-31 23:59:59", "datetime", &.{ .{ .text = "2024-03-05" }, .{ .text = "end of year" } });
    try expectCall("2024-02-10 23:59:59", "datetime", &.{ .{ .text = "2024-02-10 05:06:07" }, .{ .text = "end of day" } });
    try expectCall("2024-03-02 10:00:00", "datetime", &.{ .{ .text = "2024-01-31 10:00:00" }, .{ .text = "+1 month" } });
    try expectCall("2025-03-03 01:02:03", "datetime", &.{ .{ .text = "2024-01-31" }, .{ .text = "+0001-01-00 01:02:03" } });
    try expectCall("2024-04-12", "date", &.{ .{ .text = "2024-06-15" }, .{ .text = "-0000-02-03" } });
    try expectCall("2024-06-16 20:30:00", "datetime", &.{ .{ .text = "2024-06-15 10:00" }, .{ .text = "+0000-00-01 10:30" } });
    try expectCall("2024-01-31 10:30:00", "datetime", &.{ .{ .text = "2024-01-31 12:00" }, .{ .text = "-01:30" } });
    try expectCall("2017-07-15 14:40:00", "datetime", &.{ .{ .real = 1.5e9 }, .{ .text = "unixepoch" }, .{ .text = "+1.5 days" } });
    try expectCall("2025-07-02 12:00:00", "datetime", &.{ .{ .text = "2024-01-01" }, .{ .text = "+1.5 years" } });
}

test "date: strftime" {
    try expectCall("2013-10-07 08:23:19.120 280 40 1381134199", "strftime", &.{
        .{ .text = "%Y-%m-%d %H:%M:%f %j %W %s" }, .{ .text = "2013-10-07 08:23:19.120" },
    });
    try expectCall("01 53 2020 20 7 0  3 15  3 03 PM pm 15 04 05 2021 01 03 % 2459218.127843495 2021-01-03 15:04 15:04:05", "strftime", &.{
        .{ .text = "%U %V %G %g %u %w %e %k %l %I %p %P %H %M %S %Y %m %d %% %J %F %R %T" },
        .{ .text = "2021-01-03 15:04:05.678" },
    });
    try expectCall(" 3| 0|12|12|AM|am", "strftime", &.{ .{ .text = "%e|%k|%l|%I|%p|%P" }, .{ .text = "2021-01-03 00:04:05" } });
    try expectCall("1704067200.250", "strftime", &.{ .{ .text = "%s" }, .{ .text = "2024-01-01 00:00:00.250" }, .{ .text = "subsec" } });
    try expectCall("NULL", "strftime", &.{ .{ .text = "%Q" }, .{ .text = "2024-01-01" } });
    try expectCall("NULL", "strftime", &.{.{ .text = "abc%" }});
}

test "date: timediff" {
    try expectCall("+0000-01-15 00:00:00.000", "timediff", &.{ .{ .text = "2024-03-01" }, .{ .text = "2024-01-15" } });
    try expectCall("-0000-01-17 00:00:00.000", "timediff", &.{ .{ .text = "2024-01-15" }, .{ .text = "2024-03-01" } });
}

test "date: invalid input is NULL" {
    try expectCall("NULL", "date", &.{.{ .text = "garbage" }});
    try expectCall("NULL", "date", &.{ .{ .text = "2024-01-01" }, .{ .text = "bogus" } });
    try expectCall("NULL", "date", &.{.null});
    try expectCall("NULL", "datetime", &.{.{ .real = 5373484.5 }});
    try expectCall("NULL", "datetime", &.{ .{ .real = 1.5e9 }, .{ .text = "julianday" } });
    try expectCall("NULL", "datetime", &.{ .{ .text = "2024-01-01" }, .{ .text = "unixepoch" } });
    try expectCall("NULL", "datetime", &.{ .{ .text = "2024-01-01" }, .{ .text = "+1 fortnight" } });
    try expectCall("NULL", "date", &.{ .{ .text = "2024-01-01" }, .{ .null = {} } });
}

test "date: now and localtime round trip" {
    var buf: [128]u8 = undefined;
    const now = try callFunc(&buf, "current_timestamp", &.{});
    try std.testing.expectEqual(@as(usize, 19), now.len);
    try std.testing.expectEqual(@as(usize, 10), (try callFunc(&buf, "current_date", &.{})).len);
    try std.testing.expectEqual(@as(usize, 8), (try callFunc(&buf, "current_time", &.{})).len);
    try std.testing.expectEqual(@as(usize, 10), (try callFunc(&buf, "date", &.{.{ .text = "now" }})).len);
    try expectCall("2024-06-15 10:00:00", "datetime", &.{ .{ .text = "2024-06-15 10:00:00" }, .{ .text = "localtime" }, .{ .text = "utc" } });
}
