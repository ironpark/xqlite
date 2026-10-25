//! Preparing statements and reading the schema (port of prepare.c).

const int = @import("sqlite_int.zig");

const Parse = int.Parse;

/// Port of sqlite3ReadSchema(): make sure the schema is loaded.
pub fn readSchema(p: *Parse) i32 {
    _ = p;
    return int.RC.OK;
}

/// Port of sqlite3InitOne(): read the schema of database `i_db`. On error
/// returns the code and sets `err_msg`. Not ported yet.
pub fn initOne(db: *int.Sqlite3, i_db: usize, err_msg: *?[:0]u8, flags: u32) i32 {
    _ = .{ db, i_db, err_msg, flags };
    return int.RC.ERROR;
}

/// The second half of OP_ParseSchema: add the schema rows matching
/// `where` (an SQL expression) to the in-memory schema. Not ported yet.
pub fn parseSchemaWhere(db: *int.Sqlite3, i_db: usize, where: [:0]const u8, err_msg: *?[:0]u8) i32 {
    _ = .{ db, i_db, where, err_msg };
    return int.RC.ERROR;
}
