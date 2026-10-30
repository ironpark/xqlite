//! The proleptic Gregorian calendar the dialects' date functions share
//! (Howard Hinnant's days_from_civil and civil_from_days): days since
//! 1970-01-01, and month lengths.

const std = @import("std");

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

/// The days of month `m` (1-12) of year `y`; 0 for another month.
pub fn daysInMonth(y: i64, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

/// Days since 1970-01-01 of a civil date.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The civil date (year, month, day) of a day since 1970-01-01.
pub fn civilFromDays(z_in: i64) struct { i64, u32, u32 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ if (m <= 2) y + 1 else y, m, d };
}

test "civil dates round-trip, across eras and before 1970" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    try std.testing.expectEqual(@as(i64, -719162), daysFromCivil(1, 1, 1));
    var z: i64 = daysFromCivil(-4800, 1, 1);
    const end = daysFromCivil(10000, 12, 31);
    while (z <= end) : (z += 37) {
        const y, const m, const d = civilFromDays(z);
        try std.testing.expect(m >= 1 and m <= 12 and d >= 1 and d <= daysInMonth(y, m));
        try std.testing.expectEqual(z, daysFromCivil(y, m, d));
    }
    try std.testing.expectEqual(@as(u32, 29), daysInMonth(2000, 2));
    try std.testing.expectEqual(@as(u32, 28), daysInMonth(1900, 2));
}
