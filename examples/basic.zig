//! A tour of the basic Zig API: open, DDL, inserts with bound arguments,
//! typed queries, transactions and error details.
//!
//!     zig build example-basic                # in-memory database
//!     zig build example-basic -- notes.db    # a file

const std = @import("std");
const xqlite = @import("xqlite");

const Priority = enum { low, normal, high };

const Note = struct {
    id: i64,
    title: []const u8,
    body: ?[]const u8,
    priority: Priority,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path: []const u8 = if (args.len > 1) args[1] else ":memory:";

    var diag: xqlite.Diagnostics = .{};
    var db = xqlite.Db.open(gpa, init.io, path, .{ .diagnostics = &diag, .busy_timeout_ms = 1000 }) catch |err| {
        std.debug.print("cannot open {s}: {s} ({s})\n", .{ path, @errorName(err), diag.message() });
        return err;
    };
    defer db.close();

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS notes(
        \\  id       INTEGER PRIMARY KEY,
        \\  title    TEXT NOT NULL UNIQUE,
        \\  body     TEXT,
        \\  priority TEXT NOT NULL DEFAULT 'normal'
        \\);
        \\DELETE FROM notes;
    );

    // Positional arguments from a tuple; optionals bind NULL, enums their
    // tag name.
    try db.execArgs("INSERT INTO notes(title, body, priority) VALUES(?, ?, ?)", .{ "groceries", "eggs, milk", Priority.normal });
    std.debug.print("inserted note {d}\n", .{db.lastInsertRowid()});

    // Named arguments from a struct, in one transaction with a reused
    // statement.
    try db.transaction(.immediate, insertMany, .{&db});
    std.debug.print("{d} notes\n", .{(try db.one(i64, "SELECT count(*) FROM notes", .{})).?});

    // Iterate rows as structs; the strings are borrowed until the next row.
    var stmt = try db.prepare("SELECT id, title, body, priority FROM notes WHERE priority <> ? ORDER BY id");
    defer stmt.finalize();
    try stmt.bind(.{Priority.low});
    var it = stmt.iterator(Note);
    while (try it.next()) |n| {
        std.debug.print("  #{d} [{t}] {s}: {s}\n", .{ n.id, n.priority, n.title, n.body orelse "(empty)" });
    }

    // Copies that outlive the statement come from an allocator.
    const titles = try db.all([]const u8, gpa, "SELECT title FROM notes ORDER BY title", .{});
    defer {
        for (titles) |t| gpa.free(t);
        gpa.free(titles);
    }
    std.debug.print("titles:", .{});
    for (titles) |t| std.debug.print(" \"{s}\"", .{t});
    std.debug.print("\n", .{});

    // Errors are a Zig error set; the details stay on the connection.
    db.execArgs("INSERT INTO notes(title) VALUES(?)", .{"groceries"}) catch |err| {
        const info = db.lastError().?;
        std.debug.print("{s}: {s} (extended code {t} = {d})\n", .{ @errorName(err), info.message, info.code, @backingInt(info.code) });
    };

    // A failing transaction is rolled back.
    db.transaction(.deferred, struct {
        fn f(d: *xqlite.Db) !void {
            try d.exec("UPDATE notes SET priority = 'high'");
            try d.execArgs("INSERT INTO notes(title) VALUES(?)", .{"groceries"});
        }
    }.f, .{&db}) catch |err| std.debug.print("transaction rolled back: {s}: {s}\n", .{ @errorName(err), diag.message() });
    std.debug.print("high-priority notes after rollback: {d}\n", .{(try db.one(i64, "SELECT count(*) FROM notes WHERE priority = 'high'", .{})).?});
}

fn insertMany(db: *xqlite.Db) !void {
    var s = try db.prepare("INSERT INTO notes(title, body, priority) VALUES(:title, :body, :priority)");
    defer s.finalize();
    const items = [_]struct { title: []const u8, body: ?[]const u8, priority: Priority }{
        .{ .title = "call mom", .body = null, .priority = .high },
        .{ .title = "zig 0.17 notes", .body = "Io everywhere", .priority = .low },
        .{ .title = "taxes", .body = "due in April", .priority = .high },
    };
    for (items) |item| try s.exec(item);
}
