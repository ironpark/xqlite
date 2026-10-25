//! sqlite3_exec() (port of legacy.c). Not ported yet.

const int = @import("sqlite_int.zig");

/// Port of sqlite3_exec() without a callback: run every statement of
/// `sql`. On error returns the code and sets `err_msg`.
pub fn execNoCallback(db: *int.Sqlite3, sql: [:0]const u8, err_msg: *?[:0]u8) i32 {
    _ = .{ db, sql, err_msg };
    return int.RC.ERROR;
}
