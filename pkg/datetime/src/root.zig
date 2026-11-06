//! Dates and intervals the dialects share, with no dependency but std.

/// The proleptic Gregorian calendar: days since 1970-01-01, month lengths.
pub const calendar = @import("calendar.zig");
/// PostgreSQL's interval (months, days, microseconds), its arithmetic and
/// the order-preserving BLOB a column stores one as.
pub const interval = @import("interval.zig");
/// PostgreSQL's date, time, timestamp and interval text and arithmetic.
pub const pg = @import("pg.zig");

test {
    _ = calendar;
    _ = interval;
    _ = pg;
}
