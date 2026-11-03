//! Db.loadExtension(): the Zig API loading an extension built against
//! sqlite3ext.h (tools/capi/ext_test.c, whose path is the argument), which
//! calls back through the C ABI the load compiles in. `zig build
//! test-capi` runs it.

const std = @import("std");
const xqlite = @import("xqlite");

fn expectText(gpa: std.mem.Allocator, db: *xqlite.Db, want: []const u8, sql: []const u8) !void {
    const got = (try db.oneAlloc([]const u8, gpa, sql, .{})).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = args[1];

    // Load, call a scalar function and an aggregate, in two dialects.
    for ([_]xqlite.Db.Dialect{ .sqlite, .postgres }) |d| {
        if (!d.built()) continue;
        var db = try xqlite.Db.open(gpa, init.io, ":memory:", .{ .dialect = d });
        defer db.close();
        try db.loadExtension(path, null);
        try expectText(gpa, &db, "hello world", "SELECT xq_ext_hello('world')");
        try db.exec("CREATE TABLE t(x int); INSERT INTO t VALUES (1), (2), (39)");
        try std.testing.expectEqual(@as(?i64, 42), try db.one(i64, "SELECT xq_ext_sum(x) FROM t", .{}));
        try std.testing.expectEqual(@as(?i64, 3054001), try db.one(i64, "SELECT xq_ext_libversion()", .{}));
        // Loading the same library again is allowed (sqlite3 too).
        try db.loadExtension(path, "sqlite3_xqexttest_init");
    }

    // Failures: error.Sql with the loader's message; the connection
    // stays usable and closes cleanly.
    var db = try xqlite.Db.open(gpa, init.io, ":memory:", .{});
    defer db.close();
    try std.testing.expectError(error.Sql, db.loadExtension("/nonexistent/libnothing", null));
    try std.testing.expect(db.lastError().?.message.len > 0);
    try std.testing.expectError(error.Sql, db.loadExtension(path, "no_such_entry"));
    // (The dynamic loader's message, if it has one: dlsym() names the symbol.)
    try std.testing.expect(std.mem.indexOf(u8, db.lastError().?.message, "no_such_entry") != null);
    try std.testing.expectError(error.Sql, db.loadExtension(path, "xq_ext_fail"));
    try std.testing.expectEqualStrings("error during initialization: boom 42", db.lastError().?.message);
    try std.testing.expectError(error.Sql, db.exec("SELECT xq_ext_hello('x')"));
    try db.loadExtension(path, null);
    try expectText(gpa, &db, "hello again", "SELECT xq_ext_hello('again')");
    // The SQL function stays off: loading from SQL is not authorized.
    try std.testing.expectError(error.Sql, db.exec("SELECT load_extension('x')"));
    try std.testing.expectEqualStrings("not authorized", db.lastError().?.message);
}
