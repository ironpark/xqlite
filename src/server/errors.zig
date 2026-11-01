//! The SQLSTATE of an error, for the wire protocols.
//!
//! Clients tell errors apart by code, not by message: an ORM retries on a
//! serialization failure and turns a unique violation into its own
//! exception, by PostgreSQL's SQLSTATE (23505), MySQL's error number
//! (1062) or SQL Server's (2627). The engine and the dialects record what
//! an error is where they raise it (ErrorInfo.sqlstate, and the dialect's
//! number in ErrorInfo.dialect_number): `no such table` is 42P01 in every
//! dialect, and 1146 in MariaDB's. The errors raised without one are told
//! apart by their extended result code (CONSTRAINT_UNIQUE, BUSY,
//! INTERRUPT ...), which sqlstate() maps; the rest are the general error.

const std = @import("std");
const xqlite = @import("xqlite");

const ResultCode = xqlite.ResultCode;

/// The SQLSTATE of an error of extended result code `code`: `recorded`,
/// the one the engine or the dialect gave it, else that of the code.
pub fn sqlstate(code: ResultCode, recorded: ?[5]u8) [5]u8 {
    if (recorded) |s| return s;
    return (ofCode(code) orelse general).*;
}

/// The SQL standard's general error (no more specific code).
pub const general = "HY000";
/// The SQLSTATEs the session itself raises.
pub const in_failed_transaction = "25P02";
pub const too_many_connections = "53300";

/// The SQLSTATE an extended result code stands for, where it tells the
/// error apart.
fn ofCode(code: ResultCode) ?*const [5]u8 {
    return switch (code) {
        .constraint_unique, .constraint_primarykey, .constraint_rowid => "23505",
        .constraint_notnull => "23502",
        .constraint_foreignkey => "23503",
        .constraint_check => "23514",
        .constraint_datatype, .mismatch => "42804",
        .busy_snapshot => "40001",
        .interrupt => "57014",
        .nomem => "53200",
        .full => "53100",
        .toobig => "54000",
        .auth => "42501",
        .range => "22023",
        .misuse, .internal => "XX000",
        .abort, .abort_rollback => "40000",
        else => switch (code.primary()) {
            .constraint => "23000",
            .busy, .locked => "55P03",
            .readonly => "25006",
            .ioerr => "58030",
            .cantopen => "58P01",
            .corrupt, .notadb => "XX001",
            else => null,
        },
    };
}

test "sqlstate: the recorded one, else the extended code's" {
    const t = std.testing;
    try t.expectEqualStrings("42P01", &sqlstate(.@"error", "42P01".*));
    try t.expectEqualStrings("23505", &sqlstate(.constraint_unique, null));
    try t.expectEqualStrings("22001", &sqlstate(.constraint_check, "22001".*));
    try t.expectEqualStrings("23514", &sqlstate(.constraint_check, null));
    try t.expectEqualStrings("55P03", &sqlstate(.busy, null));
    try t.expectEqualStrings("40001", &sqlstate(.busy_snapshot, null));
    try t.expectEqualStrings("57014", &sqlstate(.interrupt, null));
    try t.expectEqualStrings(general, &sqlstate(.@"error", null));
}
