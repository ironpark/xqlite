//! The error number and SQLSTATE of an ERR packet.
//!
//! The MariaDB dialect records MariaDB's number where it raises an error
//! (Failure.number: 1146, 1062, 1064 ...); an error without one (the
//! engine's, another dialect's, the session's) gets the number of its
//! SQLSTATE. The SQLSTATE sent is MariaDB's for the number (23000 for
//! every constraint, 42S02 for a missing table), not the PostgreSQL
//! code space that Failure.sqlstate is in.

const std = @import("std");
const server = @import("../root.zig");

pub const Err = struct {
    number: u16,
    sqlstate: *const [5]u8,
    /// MariaDB's message, where the engine's would not do (a statement
    /// canceled by KILL QUERY); else the failure's.
    message: ?[]const u8 = null,
};

/// ER_UNKNOWN_ERROR.
pub const unknown = 1105;

pub fn of(f: server.Session.Failure) Err {
    const number: u16 = if (f.number) |n| std.math.cast(u16, n) orelse unknown else ofSqlstate(&f.sqlstate);
    return .{
        .number = number,
        .sqlstate = sqlstateOf(number),
        .message = if (f.number == null and number == 1317) "Query execution was interrupted" else null,
    };
}

/// The MariaDB error of an error known by its SQLSTATE only.
fn ofSqlstate(s: *const [5]u8) u16 {
    const map = std.StaticStringMap(u16).initComptime(.{
        .{ "23505", 1062 }, // ER_DUP_ENTRY
        .{ "23502", 1048 }, // ER_BAD_NULL_ERROR
        .{ "23503", 1452 }, // ER_NO_REFERENCED_ROW_2
        .{ "23514", 4025 }, // ER_CONSTRAINT_FAILED
        .{ "42P01", 1146 }, // ER_NO_SUCH_TABLE
        .{ "42703", 1054 }, // ER_BAD_FIELD_ERROR
        .{ "42601", 1064 }, // ER_PARSE_ERROR
        .{ "42P07", 1050 }, // ER_TABLE_EXISTS_ERROR
        .{ "42701", 1060 }, // ER_DUP_FIELDNAME
        .{ "42702", 1052 }, // ER_NON_UNIQ_ERROR
        .{ "42883", 1305 }, // ER_SP_DOES_NOT_EXIST
        .{ "57014", 1317 }, // ER_QUERY_INTERRUPTED
        .{ "40001", 1213 }, // ER_LOCK_DEADLOCK
        .{ "55P03", 1205 }, // ER_LOCK_WAIT_TIMEOUT
        .{ "25006", 1792 }, // ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION
        .{ "22012", 1365 }, // ER_DIVISION_BY_ZERO
        .{ "22003", 1264 }, // ER_WARN_DATA_OUT_OF_RANGE
        .{ "22001", 1406 }, // ER_DATA_TOO_LONG
        .{ "0A000", 1235 }, // ER_NOT_SUPPORTED_YET
        .{ "21000", 1242 }, // ER_SUBQUERY_NO_1_ROW
        .{ "53300", 1040 }, // ER_CON_COUNT_ERROR
        .{ "3F000", 1049 }, // ER_BAD_DB_ERROR
    });
    return map.get(s) orelse unknown;
}

/// MariaDB's SQLSTATE of error `number` (sql_state.h), HY000 if it has
/// none of its own.
pub fn sqlstateOf(number: u16) *const [5]u8 {
    return switch (number) {
        1040 => "08004",
        1045 => "28000",
        1046 => "3D000",
        1047 => "08S01",
        1048, 1052, 1062, 1216, 1217, 1451, 1452, 4025 => "23000",
        1049, 1061, 1064, 1065, 1067, 1068, 1075, 1091, 1101, 1149, 1171, 1176, 1235, 1305 => "42000",
        1050 => "42S01",
        1051, 1109, 1146 => "42S02",
        1054 => "42S22",
        1060 => "42S21",
        1136 => "21S01",
        1213 => "40001",
        1241, 1242 => "21000",
        1264, 1690 => "22003",
        1292 => "22007",
        1317, 1927 => "70100",
        1365 => "22012",
        1406 => "22001",
        1792 => "25006",
        else => "HY000",
    };
}

test of {
    const F = server.Session.Failure;
    const base: F = .{ .sqlstate = "42P01".*, .number = 1146, .code = .@"error", .message = "", .offset = null, .command = .{ .verb = .select } };
    try std.testing.expectEqual(@as(u16, 1146), of(base).number);
    try std.testing.expectEqualStrings("42S02", of(base).sqlstate);
    var f = base;
    f.number = null;
    f.sqlstate = "23505".*;
    try std.testing.expectEqual(@as(u16, 1062), of(f).number);
    try std.testing.expectEqualStrings("23000", of(f).sqlstate);
    f.sqlstate = "XX000".*;
    try std.testing.expectEqual(@as(u16, unknown), of(f).number);
    try std.testing.expectEqualStrings("HY000", of(f).sqlstate);
}
