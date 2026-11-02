//! An interval of months, days and microseconds (PostgreSQL's interval,
//! the fields Oracle's INTERVAL types can share), its arithmetic, and the
//! BLOB a column stores one as. Outside the dialect directories, so that
//! the display layer (api/display.zig) and the wire servers have it with
//! any set of dialects (-Ddialects).
//!
//! The BLOB (`len` bytes) is an order-preserving key followed by the
//! fields:
//!
//! | bytes  | what                                                        |
//! |--------|-------------------------------------------------------------|
//! | 0..16  | cmpValue(): months * 30 + days as days of 24 hours, plus the |
//! |        | time, in microseconds (PostgreSQL's interval_cmp_value()), a |
//! |        | 128-bit integer, big-endian, its sign bit flipped            |
//! | 16..20 | months, a 32-bit integer, big-endian, sign bit flipped       |
//! | 20..24 | days, the same                                               |
//! | 24..32 | microseconds, 64 bits, the same                              |
//!
//! So memcmp() orders two values as PostgreSQL orders intervals, by the
//! length they stand for ('1 day' > '23:00:00', '1 mon' < '31 days'),
//! and values of the same length by their fields: SQLite's BINARY
//! comparison sorts, indexes and range-scans them. Values of the same
//! length but other fields ('1 mon' and '30 days') are equal to
//! PostgreSQL but not the same bytes: they compute differently (a
//! timestamp plus '1 mon' is not that plus '30 days'), so the fields are
//! kept and equality compares the key, keyOf() (its first `key_len`
//! bytes). A key alone (16 bytes) sorts before every value of its
//! length, and a key followed by a byte 0xFF after every one: bounds of
//! a range of values of one length (lowBound(), highBound()).
//!
//! The encoding is part of the file format (docs/extension.md): it never
//! changes.
//!
//! The arithmetic is PostgreSQL 18's (interval_pl(), interval_mul() ...,
//! with its infinite intervals: all three fields at their maximum, or
//! minimum); `legacy` is that of the dialect's first, text intervals
//! (no infinity, halves rounded away from zero), whose functions keep
//! their meaning.

const std = @import("std");

pub const usecs_per_sec: i64 = 1_000_000;
pub const usecs_per_hour: i64 = 3600 * usecs_per_sec;
pub const usecs_per_day: i64 = 24 * usecs_per_hour;
pub const days_per_month: i32 = 30;

pub const Error = error{
    /// A result out of the range of a field ("interval out of range").
    IntervalRange,
    DivisionByZero,
};

pub const Interval = struct {
    months: i32 = 0,
    days: i32 = 0,
    /// Microseconds.
    time: i64 = 0,

    /// +infinity (PostgreSQL's INTERVAL_NOEND).
    pub const infinity: Interval = .{ .months = std.math.maxInt(i32), .days = std.math.maxInt(i32), .time = std.math.maxInt(i64) };
    /// -infinity (INTERVAL_NOBEGIN).
    pub const neg_infinity: Interval = .{ .months = std.math.minInt(i32), .days = std.math.minInt(i32), .time = std.math.minInt(i64) };

    pub fn isPosInf(a: Interval) bool {
        return std.meta.eql(a, infinity);
    }

    pub fn isNegInf(a: Interval) bool {
        return std.meta.eql(a, neg_infinity);
    }

    pub fn isFinite(a: Interval) bool {
        return !a.isPosInf() and !a.isNegInf();
    }

    /// The length the interval stands for, in microseconds of days of 24
    /// hours and months of 30 days: what PostgreSQL compares
    /// (interval_cmp_value()).
    pub fn cmpValue(a: Interval) i128 {
        const days: i128 = @as(i128, a.months) * days_per_month + a.days;
        return days * usecs_per_day + a.time;
    }

    pub fn order(a: Interval, b: Interval) std.math.Order {
        return std.math.order(a.cmpValue(), b.cmpValue());
    }

    /// The sign of its length (interval_sign()).
    pub fn sign(a: Interval) i2 {
        const v = a.cmpValue();
        return if (v > 0) 1 else if (v < 0) -1 else 0;
    }

    // ------------------------------------------------------- arithmetic

    /// A result that is finite, as the operators make (an overflow that
    /// lands on infinity's fields is out of range).
    fn finite(r: Interval) Error!Interval {
        if (!r.isFinite()) return error.IntervalRange;
        return r;
    }

    fn addFinite(a: Interval, b: Interval) Error!Interval {
        return .{
            .months = std.math.add(i32, a.months, b.months) catch return error.IntervalRange,
            .days = std.math.add(i32, a.days, b.days) catch return error.IntervalRange,
            .time = std.math.add(i64, a.time, b.time) catch return error.IntervalRange,
        };
    }

    fn subFinite(a: Interval, b: Interval) Error!Interval {
        return .{
            .months = std.math.sub(i32, a.months, b.months) catch return error.IntervalRange,
            .days = std.math.sub(i32, a.days, b.days) catch return error.IntervalRange,
            .time = std.math.sub(i64, a.time, b.time) catch return error.IntervalRange,
        };
    }

    /// Field by field (the text intervals' operator).
    pub fn addLegacy(a: Interval, b: Interval) Error!Interval {
        return addFinite(a, b);
    }

    pub fn negLegacy(a: Interval) Error!Interval {
        return .{
            .months = std.math.negate(a.months) catch return error.IntervalRange,
            .days = std.math.negate(a.days) catch return error.IntervalRange,
            .time = std.math.negate(a.time) catch return error.IntervalRange,
        };
    }

    pub fn subLegacy(a: Interval, b: Interval) Error!Interval {
        return a.addLegacy(try b.negLegacy());
    }

    /// interval_pl(): infinity plus a finite interval or the same
    /// infinity is that infinity, plus the other one out of range.
    pub fn add(a: Interval, b: Interval) Error!Interval {
        if (a.isNegInf()) return if (b.isPosInf()) error.IntervalRange else neg_infinity;
        if (a.isPosInf()) return if (b.isNegInf()) error.IntervalRange else infinity;
        if (!b.isFinite()) return b;
        return finite(try addFinite(a, b));
    }

    /// interval_mi().
    pub fn sub(a: Interval, b: Interval) Error!Interval {
        if (a.isNegInf()) return if (b.isNegInf()) error.IntervalRange else neg_infinity;
        if (a.isPosInf()) return if (b.isPosInf()) error.IntervalRange else infinity;
        if (b.isNegInf()) return infinity;
        if (b.isPosInf()) return neg_infinity;
        return finite(try subFinite(a, b));
    }

    /// interval_um().
    pub fn neg(a: Interval) Error!Interval {
        if (a.isNegInf()) return infinity;
        if (a.isPosInf()) return neg_infinity;
        return finite(try a.negLegacy());
    }

    pub const Rounding = enum {
        /// PostgreSQL's rint(): halves to even; infinite intervals and
        /// factors as interval_mul() and interval_div() take them.
        pg,
        /// The text intervals' first functions: halves away from zero, no
        /// infinity.
        legacy,
    };

    /// interval_mul(): the fraction of the months becomes days of 30,
    /// the fraction of the days time.
    pub fn mul(a: Interval, factor: f64, r: Rounding) Error!Interval {
        if (r == .pg) {
            if (std.math.isNan(factor)) return error.IntervalRange;
            if (!a.isFinite()) {
                if (factor == 0) return error.IntervalRange;
                return if (factor < 0) a.neg() else a;
            }
            if (std.math.isInf(factor)) {
                const s = a.sign();
                if (s == 0) return error.IntervalRange;
                return if ((factor < 0) != (s < 0)) neg_infinity else infinity;
            }
        }
        return a.scale(factor, false, r);
    }

    /// interval_div().
    pub fn div(a: Interval, factor: f64, r: Rounding) Error!Interval {
        if (factor == 0) return error.DivisionByZero;
        if (r == .pg) {
            if (std.math.isNan(factor)) return error.IntervalRange;
            if (!a.isFinite()) {
                if (std.math.isInf(factor)) return error.IntervalRange;
                return if (factor < 0) a.neg() else a;
            }
            if (std.math.isInf(factor)) return .{};
        }
        return a.scale(factor, true, r);
    }

    fn scale(a: Interval, factor: f64, divide: bool, r: Rounding) Error!Interval {
        const round = if (r == .pg) &rint else &roundAway;
        const m: f64 = @floatFromInt(a.months);
        const d: f64 = @floatFromInt(a.days);
        const t: f64 = @floatFromInt(a.time);
        const mf = if (divide) m / factor else m * factor;
        const df = if (divide) d / factor else d * factor;
        const tf = if (divide) t / factor else t * factor;
        var res: Interval = .{
            .months = try toI32(mf),
            .days = try toI32(df),
        };
        const month_days = tsRound((mf - @as(f64, @floatFromInt(res.months))) * days_per_month, round);
        var sec = tsRound((df - @as(f64, @floatFromInt(res.days)) + month_days - @trunc(month_days)) * 86400, round);
        if (@abs(sec) >= 86400) {
            const whole = @trunc(sec / 86400);
            res.days = std.math.add(i32, res.days, try toI32(whole)) catch return error.IntervalRange;
            sec -= whole * 86400;
        }
        res.days = std.math.add(i32, res.days, try toI32(@trunc(month_days))) catch return error.IntervalRange;
        const time = round(tf + sec * 1e6);
        if (!(time >= -0x1p63 and time < 0x1p63)) return error.IntervalRange;
        res.time = @intFromFloat(time);
        return if (r == .pg) finite(res) else res;
    }

    /// justify_hours(): whole days of the time are days, the time of the
    /// sign of the days.
    pub fn justifyHours(a: Interval) Error!Interval {
        if (!a.isFinite()) return a;
        var res = a;
        const whole = @divTrunc(res.time, usecs_per_day);
        res.time -= whole * usecs_per_day;
        res.days = std.math.add(i32, res.days, std.math.cast(i32, whole) orelse return error.IntervalRange) catch return error.IntervalRange;
        if (res.days > 0 and res.time < 0) {
            res.time += usecs_per_day;
            res.days -= 1;
        } else if (res.days < 0 and res.time > 0) {
            res.time -= usecs_per_day;
            res.days += 1;
        }
        return res;
    }

    /// justify_days(): whole months of 30 of the days are months, the days
    /// of the sign of the months.
    pub fn justifyDays(a: Interval) Error!Interval {
        if (!a.isFinite()) return a;
        var res = a;
        const whole = @divTrunc(res.days, days_per_month);
        res.days -= whole * days_per_month;
        res.months = std.math.add(i32, res.months, whole) catch return error.IntervalRange;
        if (res.months > 0 and res.days < 0) {
            res.days += days_per_month;
            res.months -= 1;
        } else if (res.months < 0 and res.days > 0) {
            res.days -= days_per_month;
            res.months += 1;
        }
        return res;
    }

    /// justify_interval(): justify_hours() then justify_days(), the signs
    /// of all fields made the same.
    pub fn justifyInterval(a: Interval) Error!Interval {
        if (!a.isFinite()) return a;
        var res = a;
        if ((res.days > 0 and res.time > 0) or (res.days < 0 and res.time < 0)) {
            const wm = @divTrunc(res.days, days_per_month);
            res.days -= wm * days_per_month;
            res.months = std.math.add(i32, res.months, wm) catch return error.IntervalRange;
        }
        const whole = @divTrunc(res.time, usecs_per_day);
        res.time -= whole * usecs_per_day;
        res.days += @intCast(whole);
        const wm = @divTrunc(res.days, days_per_month);
        res.days -= wm * days_per_month;
        res.months = std.math.add(i32, res.months, wm) catch return error.IntervalRange;
        if (res.months > 0 and (res.days < 0 or (res.days == 0 and res.time < 0))) {
            res.days += days_per_month;
            res.months -= 1;
        } else if (res.months < 0 and (res.days > 0 or (res.days == 0 and res.time > 0))) {
            res.days -= days_per_month;
            res.months += 1;
        }
        if (res.days > 0 and res.time < 0) {
            res.time += usecs_per_day;
            res.days -= 1;
        } else if (res.days < 0 and res.time > 0) {
            res.time -= usecs_per_day;
            res.days += 1;
        }
        return res;
    }

    // --------------------------------------------------------- encoding

    /// The BLOB of the interval (the file's comment).
    pub fn encode(a: Interval) [len]u8 {
        var out: [len]u8 = undefined;
        out[0..key_len].* = a.key();
        std.mem.writeInt(u32, out[16..20], @as(u32, @bitCast(a.months)) ^ 0x8000_0000, .big);
        std.mem.writeInt(u32, out[20..24], @as(u32, @bitCast(a.days)) ^ 0x8000_0000, .big);
        std.mem.writeInt(u64, out[24..32], @as(u64, @bitCast(a.time)) ^ (1 << 63), .big);
        return out;
    }

    /// The key of the interval: the first `key_len` bytes of its BLOB.
    pub fn key(a: Interval) [key_len]u8 {
        var out: [key_len]u8 = undefined;
        std.mem.writeInt(u128, &out, @as(u128, @bitCast(a.cmpValue())) ^ (1 << 127), .big);
        return out;
    }
};

/// The bytes of an interval's BLOB.
pub const len = 32;
/// The bytes of its key.
pub const key_len = 16;

/// The interval BLOB `b` is, null if it is none: not `len` bytes, or a
/// key that is not its fields' (valid()).
pub fn decode(b: []const u8) ?Interval {
    if (b.len != len) return null;
    const a: Interval = .{
        .months = @bitCast(std.mem.readInt(u32, b[16..20], .big) ^ 0x8000_0000),
        .days = @bitCast(std.mem.readInt(u32, b[20..24], .big) ^ 0x8000_0000),
        .time = @bitCast(std.mem.readInt(u64, b[24..32], .big) ^ (1 << 63)),
    };
    if (!std.mem.eql(u8, &a.key(), b[0..key_len])) return null;
    return a;
}

/// Whether `b` is an interval's BLOB.
pub fn valid(b: []const u8) bool {
    return decode(b) != null;
}

/// The key of interval BLOB `b` (valid()).
pub fn keyOf(b: []const u8) *const [key_len]u8 {
    return b[0..key_len];
}

/// The smallest bytes that sort after every interval of the length of
/// `a`: its key and a byte 0xFF, longer than a BLOB. With the key itself
/// (before every interval of that length), the bounds of the values a
/// PostgreSQL comparison with `a` takes in.
pub fn highBound(a: Interval) [len + 1]u8 {
    var out: [len + 1]u8 = @splat(0xFF);
    out[0..key_len].* = a.key();
    return out;
}

fn toI32(v: f64) Error!i32 {
    const t = @trunc(v);
    if (!(t >= -2147483648.0 and t <= 2147483647.0)) return error.IntervalRange;
    return @intFromFloat(t);
}

/// C's rint() in the default rounding mode: halves to even.
pub fn rint(v: f64) f64 {
    const r = @round(v);
    if (@abs(v - @trunc(v)) == 0.5) return 2 * @round(v / 2);
    return r;
}

fn roundAway(v: f64) f64 {
    return @round(v);
}

/// Rounded to microseconds (PostgreSQL's TSROUND()).
fn tsRound(v: f64, round: *const fn (f64) f64) f64 {
    return round(v * 1e6) / 1e6;
}

// ================================================================ tests

const testing = std.testing;

test "interval BLOBs sort as PostgreSQL orders intervals" {
    const day: Interval = .{ .days = 1 };
    const mon: Interval = .{ .months = 1 };
    const d30: Interval = .{ .days = 30 };
    const h23: Interval = .{ .time = 23 * usecs_per_hour };
    const neg: Interval = .{ .days = -1 };
    const vals = [_]Interval{ Interval.neg_infinity, .{ .months = std.math.minInt(i32) }, neg, .{}, .{ .time = 1 }, h23, day, d30, mon, .{ .days = 31 }, .{ .months = std.math.maxInt(i32), .days = std.math.maxInt(i32) }, Interval.infinity };
    for (vals, 0..) |a, i| for (vals, 0..) |b, j| {
        const ea = a.encode();
        const eb = b.encode();
        const o = std.mem.order(u8, &ea, &eb);
        const want = a.order(b);
        if (want != .eq) try testing.expectEqual(want, o);
        if (i == j) try testing.expectEqual(std.math.Order.eq, o);
        try testing.expectEqual(want, std.mem.order(u8, keyOf(&ea), keyOf(&eb)));
        try testing.expectEqual(a, decode(&ea).?);
        // The bounds of b's length.
        const kb = b.key();
        const hb = highBound(b);
        try testing.expectEqual(want == .lt, std.mem.order(u8, &ea, &kb) == .lt);
        try testing.expectEqual(want == .gt, std.mem.order(u8, &ea, &hb) == .gt);
    };
    // '1 mon' and '30 days' are the same length, other bytes.
    try testing.expectEqual(std.math.Order.eq, mon.order(d30));
    try testing.expect(!std.mem.eql(u8, &mon.encode(), &d30.encode()));
    try testing.expectEqualSlices(u8, &mon.key(), &d30.key());
    // Not an interval.
    var bad = day.encode();
    bad[31] ^= 1;
    try testing.expectEqual(@as(?Interval, null), decode(&bad));
    try testing.expectEqual(@as(?Interval, null), decode(bad[0..31]));
}

test "interval arithmetic of PostgreSQL 18" {
    const inf = Interval.infinity;
    const ninf = Interval.neg_infinity;
    const day: Interval = .{ .days = 1 };
    try testing.expectEqual(inf, try inf.add(day));
    try testing.expectError(error.IntervalRange, inf.add(ninf));
    try testing.expectEqual(ninf, try day.sub(inf));
    try testing.expectError(error.IntervalRange, inf.sub(inf));
    try testing.expectEqual(ninf, try inf.neg());
    try testing.expectError(error.IntervalRange, (Interval{ .months = std.math.minInt(i32) }).neg());
    try testing.expectEqual(ninf, try inf.mul(-2, .pg));
    try testing.expectError(error.IntervalRange, inf.mul(0, .pg));
    try testing.expectEqual(inf, try day.mul(std.math.inf(f64), .pg));
    try testing.expectEqual(Interval{}, try day.div(std.math.inf(f64), .pg));
    try testing.expectError(error.DivisionByZero, day.div(0, .pg));
    try testing.expectEqual(Interval{ .days = 15 }, try (Interval{ .months = 1 }).div(2, .pg));
    try testing.expectEqual(Interval{ .months = 1, .days = 15 }, try (Interval{ .months = 1 }).mul(1.5, .pg));
    try testing.expectEqual(Interval{ .months = 6, .days = 5, .time = 4 * usecs_per_hour + 3 * 60 * usecs_per_sec + 2 * usecs_per_sec }, try (Interval{ .months = 6, .days = 3, .time = 52 * usecs_per_hour + 3 * 60 * usecs_per_sec + 2 * usecs_per_sec }).justifyHours());
    try testing.expectEqual(Interval{ .months = 7, .days = 6 }, try (Interval{ .months = 6, .days = 36 }).justifyDays());
    try testing.expectEqual(Interval{ .days = 29, .time = 23 * usecs_per_hour }, try (Interval{ .months = 1, .time = -usecs_per_hour }).justifyInterval());
    try testing.expectError(error.IntervalRange, (Interval{ .months = std.math.maxInt(i32), .days = 30 }).justifyDays());
    try testing.expectEqual(@as(f64, 2), rint(2.5));
    try testing.expectEqual(@as(f64, -4), rint(-3.5));
    try testing.expectEqual(@as(f64, 3), rint(2.6));
}
