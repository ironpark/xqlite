//! What Oracle's errors are (int.ErrorState). An Oracle message starts
//! with its number, "ORA-00942: table or view does not exist", so the
//! number is read from the message the dialect writes, wherever it is
//! raised: at compile time (translateError() of the frontend), at run
//! time (resultError()), and for the CHECK constraints named after an
//! error (check_errors). The SQLSTATE is that of the number, in
//! PostgreSQL's code space.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const api = @import("../../vdbe/api.zig");
const dialect = @import("../dialect.zig");

/// The SQLSTATE of each number this dialect raises.
const sqlstates = [_]struct { u32, *const [5]u8 }{
    .{ 1, "23505" }, // unique constraint violated
    .{ 900, "42601" }, // invalid SQL statement
    .{ 901, "42601" }, // invalid CREATE command
    .{ 902, "42704" }, // invalid datatype
    .{ 904, "42703" }, // invalid identifier
    .{ 905, "42601" }, // missing keyword
    .{ 906, "42601" }, // missing left parenthesis
    .{ 907, "42601" }, // missing right parenthesis
    .{ 908, "42601" }, // missing NULL keyword
    .{ 909, "42883" }, // invalid number of arguments
    .{ 911, "42601" }, // invalid character
    .{ 913, "42601" }, // too many values
    .{ 917, "42601" }, // missing comma
    .{ 918, "42702" }, // column ambiguously defined
    .{ 921, "42601" }, // unexpected end of SQL command
    .{ 922, "42601" }, // missing or invalid option
    .{ 923, "42601" }, // FROM keyword not found where expected
    .{ 926, "42601" }, // missing VALUES keyword
    .{ 927, "42601" }, // missing equal sign
    .{ 928, "42601" }, // missing SELECT keyword
    .{ 932, "42804" }, // inconsistent datatypes
    .{ 933, "42601" }, // SQL command not properly ended
    .{ 934, "42803" }, // group function is not allowed here
    .{ 936, "42601" }, // missing expression
    .{ 942, "42P01" }, // table or view does not exist
    .{ 947, "42601" }, // not enough values
    .{ 955, "42P07" }, // name is already used by an existing object
    .{ 957, "42701" }, // duplicate column name
    .{ 1031, "42501" }, // insufficient privileges
    .{ 1036, "42P02" }, // illegal variable name/number
    .{ 1400, "23502" }, // cannot insert NULL
    .{ 1407, "23502" }, // cannot update to NULL
    .{ 1418, "42704" }, // specified index does not exist
    .{ 1426, "22003" }, // numeric overflow
    .{ 1428, "22003" }, // argument is out of range
    .{ 1430, "42701" }, // column being added already exists in table
    .{ 1435, "42704" }, // user does not exist
    .{ 1438, "22003" }, // value larger than specified precision
    .{ 1465, "22P02" }, // invalid hex number
    .{ 1468, "42601" }, // a predicate may reference only one outer-joined table
    .{ 1476, "22012" }, // divisor is equal to zero
    .{ 1481, "22007" }, // invalid number format model
    .{ 1722, "22P02" }, // invalid number
    .{ 1735, "42601" }, // invalid ALTER TABLE option
    .{ 1740, "42601" }, // missing double quote in identifier
    .{ 1741, "42601" }, // illegal zero-length identifier
    .{ 1742, "42601" }, // comment not properly terminated
    .{ 1756, "42601" }, // quoted string not properly terminated
    .{ 1821, "22007" }, // date format not recognized
    .{ 1830, "22007" }, // date format picture ends before converting
    .{ 1840, "22007" }, // input value not long enough for date format
    .{ 1841, "22008" }, // (full) year must be between -4713 and +9999
    .{ 1843, "22008" }, // not a valid month
    .{ 1846, "22007" }, // not a valid day of the week
    .{ 1847, "22008" }, // day of month must be between 1 and last day
    .{ 1849, "22008" }, // hour must be between 1 and 12
    .{ 1850, "22008" }, // hour must be between 0 and 23
    .{ 1851, "22008" }, // minutes must be between 0 and 59
    .{ 1852, "22008" }, // seconds must be between 0 and 59
    .{ 1858, "22007" }, // a non-numeric character was found
    .{ 1861, "22007" }, // literal does not match format string
    .{ 1898, "22007" }, // too many precision specifiers
    .{ 1917, "42704" }, // user or role does not exist
    .{ 1918, "42704" }, // user does not exist
    .{ 1920, "42710" }, // user name conflicts with another user or role name
    .{ 1922, "2BP01" }, // CASCADE must be specified to drop
    .{ 1940, "55006" }, // cannot drop a user that is currently connected
    .{ 2003, "22023" }, // invalid USERENV parameter
    .{ 2248, "22023" }, // invalid option for ALTER SESSION
    .{ 2289, "42P01" }, // sequence does not exist
    .{ 2290, "23514" }, // check constraint violated
    .{ 2291, "23503" }, // integrity constraint violated - parent key not found
    .{ 2292, "23503" }, // integrity constraint violated - child record found
    .{ 2421, "42601" }, // missing or invalid schema authorization identifier
    .{ 2422, "42601" }, // missing or invalid schema element
    .{ 12899, "22001" }, // value too large for column
    .{ 25137, "22003" }, // data value out of range
    .{ 25156, "42601" }, // old style outer join (+) cannot be used with ANSI joins
    .{ 30001, "22027" }, // trim set should have only one character
    .{ 30483, "42P20" }, // window functions are not allowed here
    .{ 30675, "42P16" }, // identity column must be a numeric type
    .{ 32795, "428C9" }, // cannot insert into a generated always identity column
    .{ 32796, "428C9" }, // cannot update a generated always identity column
    .{ 38104, "42601" }, // columns referenced in the ON clause cannot be updated
    .{ 40417, "42601" }, // JSON path expression has an invalid key name
    .{ 40441, "22032" }, // JSON syntax error
    .{ 40442, "42601" }, // JSON path expression syntax error
    .{ 40444, "22030" }, // JSON processing error
    .{ 40449, "42804" }, // invalid data type for return value
    .{ 40450, "42601" }, // invalid ON ERROR clause
    .{ 40451, "42601" }, // invalid default value
    .{ 40456, "2203F" }, // JSON path evaluated to non-scalar value
    .{ 40462, "22035" }, // JSON path evaluated to no value
    .{ 40470, "22034" }, // JSON path evaluated to multiple values
    .{ 40473, "22037" }, // duplicate key names in JSON object
    .{ 40478, "22001" }, // output value too large
    .{ 40480, "22034" }, // JSON array wrapper needed
    .{ 40597, "42601" }, // JSON path expression syntax error
    .{ 40629, "22032" }, // patch specification is not valid JSON
    .{ 40762, "22035" }, // missing value in JSON_TRANSFORM
    .{ 40763, "22030" }, // value already exists in JSON_TRANSFORM
    .{ 61723, "22001" }, // value selected by JSON path exceeds maximum
    .{ 61763, "0A000" }, // JSON modifier check on IS JSON is only supported on JSON type
    .{ 61800, "22P02" }, // invalid boolean value
};

/// The ErrorState of `msg`, if it is an Oracle error ("ORA-NNNNN: ...").
pub fn stateOf(msg: []const u8) ?int.ErrorState {
    if (!std.mem.startsWith(u8, msg, "ORA-") or msg.len < 9) return null;
    const n = std.fmt.parseInt(u32, msg[4..9], 10) catch return null;
    for (sqlstates) |e| if (e[0] == n) return .{ .sqlstate = e[1].*, .number = n };
    // A number without a known SQLSTATE: the general error.
    return .{ .sqlstate = "HY000".*, .number = n };
}

/// The ErrorState of the errors raised with the message format `fmt`:
/// its Oracle number, else xqlite's conventions (int.ErrorState.ofFormat()).
pub fn formatState(comptime fmt: []const u8) ?int.ErrorState {
    @setEvalBranchQuota(sqlstates.len * 100);
    return stateOf(fmt) orelse int.ErrorState.ofFormat(fmt);
}

/// api.resultError() that records what the error is, for the messages
/// that are Oracle errors.
pub fn resultError(ctx: *@import("../func.zig").Context, msg: []const u8) void {
    if (stateOf(msg)) |st| api.resultErrorState(ctx, st, msg) else api.resultError(ctx, msg);
}

/// Hooks.check_errors: the CHECK constraints named after an Oracle error
/// ("ORA-01722: invalid number").
pub const check_errors = blk: {
    @setEvalBranchQuota(sqlstates.len * 1000);
    var list: [sqlstates.len]dialect.CheckError = undefined;
    for (&list, sqlstates) |*c, e| c.* = .{
        .prefix = std.fmt.comptimePrint("ORA-{d:0>5}", .{e[0]}),
        .state = .{ .sqlstate = e[1].*, .number = e[0] },
    };
    break :blk list;
};

test stateOf {
    const st = stateOf("ORA-00942: table or view \"T\" does not exist").?;
    try std.testing.expectEqualStrings("42P01", &st.sqlstate);
    try std.testing.expectEqual(@as(u32, 942), st.number);
    try std.testing.expectEqual(@as(?int.ErrorState, null), stateOf("no such table: t"));
    try std.testing.expectEqualStrings("HY000", &stateOf("ORA-99999: x").?.sqlstate);
}
