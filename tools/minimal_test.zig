//! The engine built with no dialect but SQLite's and no built-in
//! extension (`-Ddialects=none -Dext=none`), which `zig build check`
//! compiles and runs: SQLite's SQL works, and choosing a dialect left out
//! fails with a message that says so.

const std = @import("std");
const xqlite = @import("xqlite");

const testing = std.testing;

fn open() !xqlite.Db {
    return xqlite.Db.open(testing.allocator, testing.io, ":memory:", .{});
}

fn expectError(db: *xqlite.Db, sql: []const u8, message: []const u8) !void {
    if (db.exec(sql)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectEqualStrings(message, db.lastError().?.message);
}

test "minimal build: what is left out" {
    inline for (.{ "postgres", "mariadb", "mssql", "oracle" }) |d| {
        try testing.expect(!@field(xqlite.config, "dialect_" ++ d));
        try testing.expect(!@field(xqlite.Dialect, d).built());
    }
    try testing.expect(xqlite.Dialect.sqlite.built());
    inline for (.{ "carray", "series", "vtablog" }) |e| try testing.expect(!@field(xqlite.config, "ext_" ++ e));
}

test "minimal build: SQLite's SQL" {
    var db = try open();
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t(b) VALUES ('x'), ('y')");
    try testing.expectEqual(@as(?i64, 2), try db.one(i64, "SELECT count(*) FROM t", .{}));
    try testing.expectEqual(@as(?i64, 6), try db.one(i64, "SELECT sum(value) FROM json_each('[1,2,3]')", .{}));
    try expectError(&db, "SELECT * FROM generate_series(1, 3)", "no such table: generate_series");
}

test "minimal build: choosing a dialect left out" {
    var db = try open();
    defer db.close();
    try expectError(&db, "PRAGMA xq_dialect = 'pg'", "dialect not built in: postgres");
    try expectError(&db, "PRAGMA xq_dialect = 'db2'", "unknown dialect: db2");
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT 1", .{}));
    // The Zig API takes the enum: the statements fail.
    db.setDialect(.oracle);
    try expectError(&db, "SELECT 1 FROM dual", "dialect not built in: oracle");
    db.setDialect(.sqlite);
    try testing.expectEqual(@as(?i64, 1), try db.one(i64, "SELECT 1", .{}));
}
