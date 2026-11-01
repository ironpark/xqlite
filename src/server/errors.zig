//! What kind of error a statement failed with, for the wire protocols.
//!
//! Clients tell errors apart by code, not by message: an ORM retries on a
//! serialization failure and turns a unique violation into its own
//! exception, by PostgreSQL's SQLSTATE (23505), MySQL's error number
//! (1062) or SQL Server's (2627). The engine reports an extended result
//! code and a message in the connection's dialect. `classify()` reads them
//! into a `Class`, which carries its SQLSTATE and which each protocol maps
//! to its own numbers.
//!
//! The extended code decides where it is precise (CONSTRAINT_UNIQUE, BUSY,
//! INTERRUPT ...). SQLITE_ERROR covers every SQL error, so for it (and for
//! CHECK constraints, which the dialects use for their type checks) the
//! message decides, by the wording of each dialect: SQLite's "no such
//! table", PostgreSQL's `relation "t" does not exist`, MariaDB's "Table
//! 'db.t' doesn't exist", SQL Server's "Invalid object name", Oracle's
//! "ORA-00942". An error no pattern knows is `.other`.

const std = @import("std");
const xqlite = @import("xqlite");

const Dialect = xqlite.Dialect;
const ResultCode = xqlite.ResultCode;

pub const Class = enum {
    // Class 23: integrity constraint violation.
    unique_violation,
    not_null_violation,
    foreign_key_violation,
    check_violation,
    integrity_constraint_violation,
    // Class 22: data exception.
    string_data_right_truncation,
    numeric_value_out_of_range,
    invalid_text_representation,
    division_by_zero,
    invalid_parameter_value,
    // Class 42: syntax error or access rule violation.
    syntax_error,
    undefined_table,
    undefined_column,
    undefined_function,
    duplicate_object,
    datatype_mismatch,
    insufficient_privilege,
    // Class 25 and 40: transactions.
    invalid_transaction_state,
    in_failed_transaction,
    read_only_transaction,
    transaction_rollback,
    serialization_failure,
    // Resources and the system.
    lock_not_available,
    query_canceled,
    out_of_memory,
    disk_full,
    too_many_connections,
    program_limit_exceeded,
    io_error,
    undefined_file,
    data_corrupted,
    feature_not_supported,
    internal_error,
    /// An SQL error of no known kind.
    other,

    /// The SQLSTATE of the class (PostgreSQL's codes, which follow the
    /// SQL standard's; `.other` is the standard's general error).
    pub fn sqlstate(c: Class) *const [5]u8 {
        return switch (c) {
            .unique_violation => "23505",
            .not_null_violation => "23502",
            .foreign_key_violation => "23503",
            .check_violation => "23514",
            .integrity_constraint_violation => "23000",
            .string_data_right_truncation => "22001",
            .numeric_value_out_of_range => "22003",
            .invalid_text_representation => "22P02",
            .division_by_zero => "22012",
            .invalid_parameter_value => "22023",
            .syntax_error => "42601",
            .undefined_table => "42P01",
            .undefined_column => "42703",
            .undefined_function => "42883",
            .duplicate_object => "42P07",
            .datatype_mismatch => "42804",
            .insufficient_privilege => "42501",
            .invalid_transaction_state => "25000",
            .in_failed_transaction => "25P02",
            .read_only_transaction => "25006",
            .transaction_rollback => "40000",
            .serialization_failure => "40001",
            .lock_not_available => "55P03",
            .query_canceled => "57014",
            .out_of_memory => "53200",
            .disk_full => "53100",
            .too_many_connections => "53300",
            .program_limit_exceeded => "54000",
            .io_error => "58030",
            .undefined_file => "58P01",
            .data_corrupted => "XX001",
            .feature_not_supported => "0A000",
            .internal_error => "XX000",
            .other => "HY000",
        };
    }
};

/// The class of an error the engine reported with `code` and `message`
/// on a connection of `dialect`.
pub fn classify(dialect: Dialect, code: ResultCode, message: []const u8) Class {
    return switch (code) {
        .constraint_unique, .constraint_primarykey, .constraint_rowid => .unique_violation,
        .constraint_notnull => .not_null_violation,
        .constraint_foreignkey => .foreign_key_violation,
        // The dialects check their types with named CHECK constraints
        // (`value too long for type character varying(3)`).
        .constraint_check => byMessage(dialect, checkName(message)) orelse .check_violation,
        .constraint_datatype, .mismatch => .datatype_mismatch,
        .busy_snapshot => .serialization_failure,
        .interrupt => .query_canceled,
        .nomem => .out_of_memory,
        .full => .disk_full,
        .toobig => .program_limit_exceeded,
        .auth => .insufficient_privilege,
        .range => .invalid_parameter_value,
        .misuse, .internal => .internal_error,
        .abort, .abort_rollback => .transaction_rollback,
        else => switch (code.primary()) {
            .constraint => byMessage(dialect, message) orelse .integrity_constraint_violation,
            .busy, .locked => .lock_not_available,
            .readonly => .read_only_transaction,
            .ioerr => .io_error,
            .cantopen => .undefined_file,
            .corrupt, .notadb => .data_corrupted,
            else => byMessage(dialect, message) orelse .other,
        },
    };
}

/// The constraint name of a CHECK failure ("CHECK constraint failed:
/// NAME"), which the dialects' type checks word as their errors.
fn checkName(message: []const u8) []const u8 {
    const prefix = "CHECK constraint failed: ";
    return if (std.mem.startsWith(u8, message, prefix)) message[prefix.len..] else message;
}

const Pattern = struct {
    /// Matched against the start of the message, else anywhere in it
    /// when `anywhere`.
    text: []const u8,
    class: Class,
    anywhere: bool = false,
    /// Text that must be in the message too.
    also: []const u8 = "",
};

fn byMessage(dialect: Dialect, message: []const u8) ?Class {
    // The dialect's own wording first: a dialect may also report an
    // error of the engine in SQLite's words.
    const own: []const Pattern = switch (dialect) {
        .sqlite => &.{},
        .postgres => &postgres,
        .mariadb => &mariadb,
        .mssql => &mssql,
        .oracle => &oracle,
    };
    for ([_][]const Pattern{ own, &sqlite }) |list| {
        for (list) |p| {
            const hit = if (p.anywhere) std.mem.indexOf(u8, message, p.text) != null else std.mem.startsWith(u8, message, p.text);
            if (hit and std.mem.indexOf(u8, message, p.also) != null) return p.class;
        }
    }
    return null;
}

const sqlite = [_]Pattern{
    .{ .text = "no such table", .class = .undefined_table },
    .{ .text = "no such view", .class = .undefined_table },
    .{ .text = "no such column", .class = .undefined_column },
    .{ .text = "no such function", .class = .undefined_function },
    .{ .text = "wrong number of arguments to function", .class = .undefined_function },
    .{ .text = ": syntax error", .class = .syntax_error, .anywhere = true },
    .{ .text = "incomplete input", .class = .syntax_error },
    .{ .text = "unrecognized token", .class = .syntax_error },
    .{ .text = "already exists", .class = .duplicate_object, .anywhere = true },
    .{ .text = "cannot start a transaction within a transaction", .class = .invalid_transaction_state },
    .{ .text = "cannot commit - no transaction is active", .class = .invalid_transaction_state },
    .{ .text = "cannot rollback - no transaction is active", .class = .invalid_transaction_state },
    .{ .text = "no such savepoint", .class = .invalid_transaction_state },
    .{ .text = "attempt to write a readonly database", .class = .read_only_transaction },
    .{ .text = "integer overflow", .class = .numeric_value_out_of_range },
    .{ .text = "string or blob too big", .class = .program_limit_exceeded },
    .{ .text = "xqlite: ", .class = .feature_not_supported },
};

const postgres = [_]Pattern{
    .{ .text = "relation \"", .class = .undefined_table, .also = "does not exist" },
    .{ .text = "column \"", .class = .undefined_column, .also = "does not exist" },
    .{ .text = "function ", .class = .undefined_function, .also = "does not exist" },
    .{ .text = "syntax error at or near", .class = .syntax_error },
    .{ .text = "syntax error at end of input", .class = .syntax_error },
    .{ .text = "value too long for type", .class = .string_data_right_truncation },
    .{ .text = "out of range", .class = .numeric_value_out_of_range, .anywhere = true },
    .{ .text = "invalid input syntax for type", .class = .invalid_text_representation },
    .{ .text = "division by zero", .class = .division_by_zero },
    .{ .text = "permission denied", .class = .insufficient_privilege },
};

const mariadb = [_]Pattern{
    .{ .text = "Table '", .class = .undefined_table, .also = "doesn't exist" },
    .{ .text = "Unknown column", .class = .undefined_column },
    .{ .text = "FUNCTION ", .class = .undefined_function, .also = "does not exist" },
    .{ .text = "You have an error in your SQL syntax", .class = .syntax_error },
    .{ .text = "Data too long for column", .class = .string_data_right_truncation },
    .{ .text = "Out of range value", .class = .numeric_value_out_of_range },
    .{ .text = "Incorrect ", .class = .invalid_text_representation },
    .{ .text = "Truncated incorrect", .class = .invalid_text_representation },
    .{ .text = "Duplicate entry", .class = .unique_violation },
    .{ .text = "cannot be null", .class = .not_null_violation, .anywhere = true },
    .{ .text = "Division by 0", .class = .division_by_zero },
};

const mssql = [_]Pattern{
    .{ .text = "Invalid object name", .class = .undefined_table },
    .{ .text = "Invalid column name", .class = .undefined_column },
    .{ .text = "is not a recognized built-in function name", .class = .undefined_function, .anywhere = true },
    .{ .text = "Incorrect syntax near", .class = .syntax_error },
    .{ .text = "There is already an object named", .class = .duplicate_object },
    .{ .text = "String or binary data would be truncated", .class = .string_data_right_truncation },
    .{ .text = "Arithmetic overflow", .class = .numeric_value_out_of_range },
    .{ .text = "Conversion failed", .class = .invalid_text_representation },
    .{ .text = "Divide by zero error", .class = .division_by_zero },
    .{ .text = "has no corresponding BEGIN TRANSACTION", .class = .invalid_transaction_state, .anywhere = true },
    .{ .text = "Cannot insert duplicate key", .class = .unique_violation },
    .{ .text = "Cannot insert the value NULL", .class = .not_null_violation },
};

const oracle = [_]Pattern{
    .{ .text = "ORA-00942", .class = .undefined_table },
    .{ .text = "ORA-00904", .class = .undefined_column },
    .{ .text = "ORA-00900", .class = .syntax_error },
    .{ .text = "ORA-00933", .class = .syntax_error },
    .{ .text = "ORA-00936", .class = .syntax_error },
    .{ .text = "ORA-00955", .class = .duplicate_object },
    .{ .text = "ORA-00001", .class = .unique_violation },
    .{ .text = "ORA-01400", .class = .not_null_violation },
    .{ .text = "ORA-02291", .class = .foreign_key_violation },
    .{ .text = "ORA-02292", .class = .foreign_key_violation },
    .{ .text = "ORA-02290", .class = .check_violation },
    .{ .text = "ORA-12899", .class = .string_data_right_truncation },
    .{ .text = "ORA-01438", .class = .numeric_value_out_of_range },
    .{ .text = "ORA-01722", .class = .invalid_text_representation },
    .{ .text = "ORA-01476", .class = .division_by_zero },
};

test "classify: codes first, then each dialect's wording" {
    const t = std.testing;
    try t.expectEqual(Class.unique_violation, classify(.postgres, .constraint_unique, "UNIQUE constraint failed: t.id"));
    try t.expectEqual(Class.not_null_violation, classify(.oracle, .constraint_notnull, "ORA-01400: cannot insert NULL"));
    try t.expectEqual(Class.string_data_right_truncation, classify(.postgres, .constraint_check, "CHECK constraint failed: value too long for type character varying(3)"));
    try t.expectEqual(Class.check_violation, classify(.postgres, .constraint_check, "CHECK constraint failed: t_n_check"));
    try t.expectEqual(Class.undefined_table, classify(.postgres, .@"error", "relation \"nope\" does not exist"));
    try t.expectEqual(Class.undefined_table, classify(.mariadb, .@"error", "Table 'main.nope' doesn't exist"));
    try t.expectEqual(Class.undefined_table, classify(.mssql, .@"error", "Invalid object name 'nope'."));
    try t.expectEqual(Class.undefined_table, classify(.oracle, .@"error", "ORA-00942: table or view \"NOPE\" does not exist"));
    try t.expectEqual(Class.undefined_table, classify(.sqlite, .@"error", "no such table: nope"));
    // A dialect's error in SQLite's words.
    try t.expectEqual(Class.undefined_column, classify(.mariadb, .@"error", "no such column: nope"));
    try t.expectEqual(Class.syntax_error, classify(.sqlite, .@"error", "near \"SELEC\": syntax error"));
    try t.expectEqual(Class.syntax_error, classify(.mssql, .@"error", "Incorrect syntax near 'SELEC'."));
    try t.expectEqual(Class.duplicate_object, classify(.postgres, .@"error", "relation \"t\" already exists"));
    try t.expectEqual(Class.invalid_transaction_state, classify(.mssql, .@"error", "The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION."));
    try t.expectEqual(Class.lock_not_available, classify(.postgres, .busy, "database is locked"));
    try t.expectEqual(Class.serialization_failure, classify(.postgres, .busy_snapshot, "database is locked"));
    try t.expectEqual(Class.query_canceled, classify(.mariadb, .interrupt, "interrupted"));
    try t.expectEqual(Class.other, classify(.sqlite, .@"error", "something else"));
    try t.expectEqualStrings("23505", Class.unique_violation.sqlstate());
}
