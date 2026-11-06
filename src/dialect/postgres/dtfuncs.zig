//! PostgreSQL's date_trunc(), date_bin() and timezone() (`x AT TIME
//! ZONE z`) on the dialect's values (datetime.zig: a timestamp is its
//! text, a timestamptz the same in UTC, an interval a BLOB):
//!
//!  - date_trunc(unit, x): a timestamp or timestamptz (a date as one at
//!    midnight) truncated as timestamp_trunc() does (the session's time
//!    zone is UTC), an interval as interval_trunc() does (its infinities
//!    as they are; `week` is not supported, months having fractional
//!    weeks); units by PostgreSQL's names and abbreviations (ivinput.zig's
//!    DecodeUnits());
//!  - date_bin(stride, source, origin): timestamp_bin();
//!  - timezone(zone, x): of a timestamp the timestamptz of that local time
//!    in `zone`, of a timestamptz its local time there. A zone is an
//!    interval (a fixed offset east of UTC), an abbreviation of
//!    PostgreSQL's default set (UTC, EST, PDT, CET ...: dtformat.zig) or
//!    a POSIX offset ('+05' is
//!    five hours west); a name of the tz database is not known
//!    ("time zone "x" not recognized"). overload.zig calls
//!    xq_pg_timezone(zone, x, kind), `kind` saying which type `x` is
//!    (formatting.Kind); `x AT TIME ZONE zone` is the same function as
//!    xq_pg_at_time_zone(zone, x[, kind]), so that a definition shows
//!    the syntax it was written in.

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const int = @import("../../sql/sqlite_int.zig");
const calendar = @import("datetime").calendar;
const datetime = @import("datetime.zig");
const formatting = @import("formatting.zig");
const dtformat = @import("dtformat.zig");
const ivinput = @import("ivinput.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Interval = datetime.Interval;
const usecs_per_day = datetime.usecs_per_day;
const usecs_per_sec = datetime.usecs_per_sec;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("date_trunc", 2, det, truncFunc),
    dfunc.scalar("date_bin", 3, det, binFunc),
    dfunc.scalar("timezone", 2, det, timezoneFunc),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_timezone", 3, det, timezoneFunc),
    // `x AT TIME ZONE z`: timezone(z, x) by the name of its syntax, which
    // the definitions show as written (deparse.zig); of an `x` of no type
    // told, two arguments.
    dfunc.scalar("xq_pg_at_time_zone", 2, det, timezoneFunc),
    dfunc.scalar("xq_pg_at_time_zone", 3, det, timezoneFunc),
};

// ============================================================ date_trunc

/// A unit of date_trunc(): of DecodeUnits(), microsecond to millennium
/// (in that order).
const Unit = ivinput.Unit;

/// The unit `lower` names, for type `type_name`; null after making the
/// error the result (a unit of no truncation: not supported; `week` of
/// an interval).
fn truncUnit(ctx: *Context, lower: []const u8, type_name: []const u8) ?Unit {
    const u = ivinput.unitOf(lower) orelse {
        unitError(ctx, lower, type_name, false);
        return null;
    };
    switch (u) {
        .ago => unitError(ctx, lower, type_name, false),
        .tz, .tz_hour, .tz_minute, .dow, .doy, .isodow, .isoyear, .julian => unitError(ctx, lower, type_name, true),
        // PostgreSQL's DETAIL (interval_trunc()).
        .week => if (std.mem.eql(u8, type_name, "interval")) api.resultErrorFields(ctx, .of("0A000"), .{
            .message = "unit \"week\" not supported for type interval",
            .detail = "Months usually have fractional weeks.",
        }) else return u,
        else => return u,
    }
    return null;
}

fn unitError(ctx: *Context, lower: []const u8, type_name: []const u8, known: bool) void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unit \"{s}\" not {s} for type {s}", .{ lower[0..@min(lower.len, 64)], if (known) "supported" else "recognized", type_name }) catch "unit not recognized";
    api.resultErrorState(ctx, if (known) .of("0A000") else .of("22023"), msg);
}

fn truncFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const raw_unit = dfunc.text(ctx, argv[0]) orelse return;
    var ubuf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&ubuf, raw_unit[0..@min(raw_unit.len, ubuf.len)]);
    const m = argv[1];
    // An interval: its key, or its text (an older database's interval
    // column).
    const iv: Interval = if (api.valueType(m) == vi.SQLITE_BLOB)
        datetime.intervalArg(ctx, m) orelse return
    else blk: {
        const raw = dfunc.text(ctx, m) orelse return;
        const t = datetime.parseTimestamp(raw, false) catch
            break :blk datetime.parseInterval(raw) catch return badTimestamp(ctx, raw);
        const u = truncUnit(ctx, lower, "timestamp without time zone") orelse return;
        var buf: datetime.Buf = undefined;
        return api.resultText(ctx, datetime.formatTimestamp(truncTimestamp(t, u), &buf), .transient);
    };
    const u = truncUnit(ctx, lower, "interval") orelse return;
    resultInterval(ctx, if (iv.isFinite()) truncInterval(iv, u) else iv);
}

fn badTimestamp(ctx: *Context, raw: []const u8) void {
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid input syntax for type timestamp: \"{s}\"", .{raw[0..@min(raw.len, 64)]}) catch "invalid input syntax for type timestamp";
    api.resultErrorState(ctx, .of("22007"), msg);
}

fn resultInterval(ctx: *Context, iv: Interval) void {
    const b = iv.encode();
    api.resultBlob(ctx, &b, .transient);
}

/// timestamp_trunc() of `t` (microseconds since 1970, astronomical
/// years).
fn truncTimestamp(t: i64, u: Unit) i64 {
    const days = @divFloor(t, usecs_per_day);
    var tod = t - days * usecs_per_day;
    var y, var mon, var mday = calendar.civilFromDays(days);
    if (u == .week) {
        // The Monday of the ISO week.
        const dow = @mod(days + 3, 7); // 0 Monday
        return (days - dow) * usecs_per_day;
    }
    switch (u) {
        .millennium => y = if (y > 0) @divTrunc(y + 999, 1000) * 1000 - 999 else -@divTrunc(999 - (y - 1), 1000) * 1000 + 1,
        .century => y = if (y > 0) @divTrunc(y + 99, 100) * 100 - 99 else -@divTrunc(99 - (y - 1), 100) * 100 + 1,
        .decade => y = if (y > 0) @divTrunc(y, 10) * 10 else -@divTrunc(8 - (y - 1), 10) * 10,
        else => {},
    }
    if (@backingInt(u) >= @backingInt(Unit.year)) mon = 1;
    if (u == .quarter) mon = 3 * ((mon - 1) / 3) + 1;
    if (@backingInt(u) >= @backingInt(Unit.month)) mday = 1;
    const hour_us: i64 = 3600 * usecs_per_sec;
    const min_us: i64 = 60 * usecs_per_sec;
    tod = switch (u) {
        .microsecond => tod,
        .millisecond => @divFloor(tod, 1000) * 1000,
        .second => @divFloor(tod, usecs_per_sec) * usecs_per_sec,
        .minute => @divFloor(tod, min_us) * min_us,
        .hour => @divFloor(tod, hour_us) * hour_us,
        else => 0,
    };
    return calendar.daysFromCivil(y, mon, mday) * usecs_per_day + tod;
}

/// interval_trunc(): the fields below `u` zero.
fn truncInterval(iv: Interval, u: Unit) Interval {
    var years: i64 = @divTrunc(iv.months, 12);
    var mons: i64 = @rem(iv.months, 12);
    var days: i64 = iv.days;
    var time: i64 = iv.time;
    const hour_us: i64 = 3600 * usecs_per_sec;
    const min_us: i64 = 60 * usecs_per_sec;
    switch (u) {
        .millennium => years = @divTrunc(years, 1000) * 1000,
        .century => years = @divTrunc(years, 100) * 100,
        .decade => years = @divTrunc(years, 10) * 10,
        else => {},
    }
    if (@backingInt(u) >= @backingInt(Unit.year)) mons = 0;
    if (u == .quarter) mons = 3 * @divTrunc(mons, 3);
    if (@backingInt(u) >= @backingInt(Unit.month)) days = 0;
    time = switch (u) {
        .microsecond => time,
        .millisecond => @divTrunc(time, 1000) * 1000,
        .second => @divTrunc(time, usecs_per_sec) * usecs_per_sec,
        .minute => @divTrunc(time, min_us) * min_us,
        .hour => @divTrunc(time, hour_us) * hour_us,
        else => 0,
    };
    return .{ .months = @intCast(years * 12 + mons), .days = @intCast(days), .time = time };
}

// ============================================================== date_bin

fn binFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    const stride = datetime.intervalArg(ctx, argv[0]) orelse return;
    const ts_raw = dfunc.text(ctx, argv[1]) orelse return;
    const t = datetime.parseTimestamp(ts_raw, false) catch return badTimestamp(ctx, ts_raw);
    const or_raw = dfunc.text(ctx, argv[2]) orelse return;
    const origin = datetime.parseTimestamp(or_raw, false) catch return badTimestamp(ctx, or_raw);
    if (!stride.isFinite()) return api.resultErrorState(ctx, .of("22008"), "timestamps cannot be binned into infinite intervals");
    if (stride.months != 0) return api.resultErrorState(ctx, .of("0A000"), "timestamps cannot be binned into intervals containing months or years");
    const s = std.math.add(i64, std.math.mul(i64, stride.days, usecs_per_day) catch return rangeErr(ctx), stride.time) catch return rangeErr(ctx);
    if (s <= 0) return api.resultErrorState(ctx, .of("22008"), "stride must be greater than zero");
    const diff = std.math.sub(i64, t, origin) catch return rangeErr(ctx);
    const modulo = @rem(diff, s);
    var r = origin + (diff - modulo);
    if (modulo < 0) {
        r = std.math.sub(i64, r, s) catch return api.resultErrorState(ctx, .of("22008"), "timestamp out of range");
        _ = datetime.checkTimestamp(r) catch return api.resultErrorState(ctx, .of("22008"), "timestamp out of range");
    }
    var buf: datetime.Buf = undefined;
    api.resultText(ctx, datetime.formatTimestamp(r, &buf), .transient);
}

fn rangeErr(ctx: *Context) void {
    api.resultErrorState(ctx, .of("22008"), "interval out of range");
}

// ============================================================== timezone

/// The offset (seconds east of UTC) of zone name `z`, null if unknown.
fn zoneOffset(z_in: []const u8) ?i64 {
    const z = std.mem.trim(u8, z_in, " ");
    if (z.len == 0) return null;
    if (dtformat.zoneAbbrev(z)) |o| return o;
    // POSIX: [+-]hh[:mm[:ss]], west of UTC positive.
    var i: usize = 0;
    var sign: i64 = 1;
    if (z[0] == '+' or z[0] == '-') {
        sign = if (z[0] == '-') -1 else 1;
        i = 1;
    }
    var parts: [3]i64 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, z[i..], ':');
    while (it.next()) |p| {
        if (n == 3 or p.len == 0 or p.len > 2) return null;
        parts[n] = std.fmt.parseInt(i64, p, 10) catch return null;
        n += 1;
    }
    if (n == 0 or parts[0] > 15 * 24) return null;
    return -sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
}

fn timezoneFunc(ctx: *Context, argv: []*Mem) void {
    if (dfunc.anyNull(argv[0..2])) return api.resultNull(ctx);
    const kind = formatting.Kind.fromArg(argv, 2);
    var offset_us: i64 = 0;
    if (api.valueType(argv[0]) == vi.SQLITE_BLOB) {
        const iv = datetime.intervalArg(ctx, argv[0]) orelse return;
        var buf: datetime.Buf = undefined;
        var mbuf: [200]u8 = undefined;
        if (!iv.isFinite()) {
            const msg = std.fmt.bufPrint(&mbuf, "interval time zone \"{s}\" must be finite", .{datetime.formatIntervalPg(iv, &buf)}) catch "interval time zone must be finite";
            return api.resultErrorState(ctx, .of("22023"), msg);
        }
        if (iv.months != 0 or iv.days != 0) {
            const msg = std.fmt.bufPrint(&mbuf, "interval time zone \"{s}\" must not include months or days", .{datetime.formatIntervalPg(iv, &buf)}) catch "interval time zone must not include months or days";
            return api.resultErrorState(ctx, .of("22023"), msg);
        }
        offset_us = iv.time;
    } else {
        const z = dfunc.text(ctx, argv[0]) orelse return;
        const off = zoneOffset(z) orelse {
            var mbuf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&mbuf, "time zone \"{s}\" not recognized", .{z[0..@min(z.len, 64)]}) catch "time zone not recognized";
            return api.resultErrorState(ctx, .of("22023"), msg);
        };
        offset_us = off * usecs_per_sec;
    }
    if (kind == .time or kind == .timetz) return api.resultErrorState(ctx, .of("0A000"), "xqlite: AT TIME ZONE of a time is not supported");
    const raw = dfunc.text(ctx, argv[1]) orelse return;
    const local = kind == .timestamp;
    const t = datetime.parseTimestamp(raw, !local) catch return badTimestamp(ctx, raw);
    // A timestamp is local time in the zone: its UTC; a timestamptz (a
    // date as one) is UTC: its local time there.
    const r = (if (local) std.math.sub(i64, t, offset_us) else std.math.add(i64, t, offset_us)) catch
        return api.resultErrorState(ctx, .of("22008"), "timestamp out of range");
    _ = datetime.checkTimestamp(r) catch return api.resultErrorState(ctx, .of("22008"), "timestamp out of range");
    var buf: datetime.Buf = undefined;
    api.resultText(ctx, datetime.formatTimestamp(r, &buf), .transient);
}

test "dtfuncs: truncation and zones" {
    const ts = calendar.daysFromCivil(2001, 2, 16) * usecs_per_day + (20 * 3600 + 38 * 60 + 40) * usecs_per_sec;
    try std.testing.expectEqual(calendar.daysFromCivil(2001, 2, 16) * usecs_per_day + 20 * 3600 * usecs_per_sec, truncTimestamp(ts, .hour));
    try std.testing.expectEqual(calendar.daysFromCivil(2001, 2, 12) * usecs_per_day, truncTimestamp(ts, .week));
    try std.testing.expectEqual(calendar.daysFromCivil(2001, 1, 1) * usecs_per_day, truncTimestamp(ts, .century));
    try std.testing.expectEqual(calendar.daysFromCivil(2001, 1, 1) * usecs_per_day, truncTimestamp(ts, .millennium));
    try std.testing.expectEqual(calendar.daysFromCivil(2000, 1, 1) * usecs_per_day, truncTimestamp(ts, .decade));
    try std.testing.expectEqual(@as(?i64, -5 * 3600), zoneOffset("+05"));
    try std.testing.expectEqual(@as(?i64, -5 * 3600), zoneOffset("EST"));
    try std.testing.expectEqual(@as(?i64, null), zoneOffset("America/New_York"));
}
