//! Loading a third-party SQLite extension with the Zig API: sqlite-regex
//! (https://github.com/asg017/sqlite-regex), Rust's regex crate as SQL
//! functions and table-valued functions, then used like any function.
//!
//!     # regex0.dylib (macOS) or regex0.so (Linux) from a release:
//!     # https://github.com/asg017/sqlite-regex/releases
//!     zig build example-sqlite-regex -- ./regex0
//!
//! The argument is the library, with or without its suffix (default
//! "regex0"). docs/load-extension.md has the rest.

const std = @import("std");
const xqlite = @import("xqlite");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path: []const u8 = if (args.len > 1) args[1] else "regex0";

    var db = try xqlite.Db.open(gpa, init.io, ":memory:", .{});
    defer db.close();
    // The entry point, sqlite3_regex_init, is found from the file name.
    db.loadExtension(path, null) catch |err| {
        std.debug.print("cannot load {s}: {s}\n", .{ path, db.lastError().?.message });
        return err;
    };

    const version = (try db.oneAlloc([]const u8, gpa, "SELECT regex_version()", .{})).?;
    defer gpa.free(version);
    std.debug.print("sqlite-regex {s}\n", .{version});

    // Scalar functions, with bound arguments.
    const phone = (try db.oneAlloc([]const u8, gpa, "SELECT regex_find(?, ?)", .{ "[0-9]{3}-[0-9]{3}-[0-9]{4}", "phone: 111-222-3333" })).?;
    defer gpa.free(phone);
    std.debug.print("regex_find: {s}\n", .{phone});
    const name = (try db.oneAlloc([]const u8, gpa, "SELECT regex_replace(?, ?, ?)", .{ "(?P<last>[^,\\s]+),\\s+(?P<first>\\S+)", "Springsteen, Bruce", "$first $last" })).?;
    defer gpa.free(name);
    std.debug.print("regex_replace: {s}\n", .{name});

    // A table-valued function, read into a struct.
    var s = try db.prepare("SELECT start, \"end\", match FROM regex_find_all(?, ?)");
    defer s.finalize();
    try s.bind(.{ "\\b\\w{13}\\b", "Retroactively relinquishing remunerations is reprehensible." });
    var it = s.iterator(struct { start: i64, end: i64, match: []const u8 });
    while (try it.next()) |m| std.debug.print("  {d}..{d} {s}\n", .{ m.start, m.end, m.match });

    // In a schema: a CHECK constraint (REGEXP is the extension's) and an
    // index on an expression. Every connection that writes this table
    // then needs the extension too.
    try db.exec(
        \\CREATE TABLE users(email TEXT CHECK (email REGEXP '^[^@\s]+@[^@\s]+$'));
        \\CREATE INDEX users_domain ON users(regex_find('@.*$', email));
        \\INSERT INTO users VALUES ('ann@example.com'), ('bob@example.org'), ('cy@example.com');
    );
    const n = (try db.one(i64, "SELECT count(*) FROM users WHERE regex_find('@.*$', email) = '@example.com'", .{})).?;
    std.debug.print("users at example.com: {d}\n", .{n});
    if (db.execArgs("INSERT INTO users VALUES (?)", .{"not an email"})) {
        return error.CheckNotEnforced;
    } else |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), db.lastError().?.message });
    }

    // The PostgreSQL dialect: the extension's functions next to the
    // dialect's own ~ operator.
    db.setDialect(.postgres);
    const row = (try db.oneAlloc(struct { r: []const u8, m: bool }, gpa, "SELECT regex_replace_all('[aeiou]', $1, '_') AS r, $1 ~ '^xq' AS m", .{"xqlite speaks postgres"})).?;
    defer gpa.free(row.r);
    std.debug.print("postgres: {s} {}\n", .{ row.r, row.m });
}
