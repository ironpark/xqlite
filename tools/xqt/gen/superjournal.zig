//! `xqt gen superjournal [DIR]`: regenerates src/testdata/superjournal (or
//! DIR): what sqlite3 leaves on disk when it dies during the commit of a
//! transaction over three databases (main, a and b) in
//! journal_mode=DELETE, at four points:
//!
//!   pending      the last change before the super-journal is deleted:
//!                the super-journal and every journal exist, b's journal
//!                does not name the super-journal yet (must roll back)
//!   committed-0  the super-journal is deleted, every journal is left
//!   committed-1  main's journal is deleted too
//!   committed-2  a's journal is deleted too (all three must be committed)
//!
//! sqlite3 (cfg.sqlite3) is killed with tools/crashshim.c (xqt.crash). The
//! files are made in /tmp/xqsj, so the super-journal name inside the
//! journals is /private/tmp/xqsj/main.db-mj... on macOS. Each state
//! directory also holds the super-journal, if any, as "super". The states
//! must hold the files src/sql/attach_test.zig expects (fixtureExists).
//! (Was tools/gen-superjournal-fixtures.sh.)

const std = @import("std");
const Io = std.Io;
const xqt = @import("xqt");
const Check = xqt.Check;
const crash = xqt.crash;

pub const name = "superjournal";
pub const usage =
    \\  superjournal [DIR]   src/testdata/superjournal (or DIR) from sqlite3 dying in a
    \\                       commit over three files (needs the crash shim)
    \\
;

const work = "/tmp/xqsj";

const files = [_][]const u8{ "main.db", "a.db", "b.db", "main.db-journal", "a.db-journal", "b.db-journal" };

/// The files of each state, as src/sql/attach_test.zig expects them.
const states = [_]struct { []const u8, []const u8 }{
    .{ "pending", "main.db a.db b.db main.db-journal a.db-journal b.db-journal super" },
    .{ "committed-0", "main.db a.db b.db main.db-journal a.db-journal b.db-journal" },
    .{ "committed-1", "main.db a.db b.db a.db-journal b.db-journal" },
    .{ "committed-2", "main.db a.db b.db b.db-journal" },
};

const Job = struct { out_dir: []const u8 };

pub fn run(gpa: std.mem.Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    if (args.len > 1 or (args.len == 1 and args[0].len > 0 and args[0][0] == '-')) {
        try out.writeAll("usage: xqt gen\n" ++ usage);
        return 2;
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out_dir = if (args.len == 1) blk: {
        if (std.fs.path.isAbsolute(args[0])) break :blk args[0];
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &buf);
        break :blk try std.fs.path.resolveAlloc(arena, &.{ buf[0..n], args[0] });
    } else try std.fs.path.join(arena, &.{ cfg.root, "src", "testdata", "superjournal" });

    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "gen", .show = .failures });
    defer suite.deinit();
    const job: Job = .{ .out_dir = out_dir };
    try suite.add("gen superjournal", generate, .{&job});
    suite.run();
    const o = suite.outcome(0);
    switch (o.status) {
        .ok => {
            try out.print("{s}:\n{s}", .{ out_dir, o.log });
            return 0;
        },
        .skipped => {
            try out.print("xqt gen superjournal: {s}\n", .{o.log});
            return 1;
        },
        .failed => return 1,
    }
}

fn generate(c: *Check, job: *const Job) !void {
    try crash.requireShim(c);
    // The first crash point that leaves no super-journal is the unlink of
    // main's journal: the super-journal was deleted just before.
    var i: u32 = 1;
    while (true) : (i += 1) {
        if (i > 100) return c.abort("no crash point found", .{});
        try crashAt(c, i);
        if (try superJournal(c) == null and std.mem.indexOf(u8, try readWork(c, "main.db-journal") orelse "", "-mj") != null) break;
    }
    try save(c, job, "committed-0");
    try crashAt(c, i - 1);
    try save(c, job, "pending");
    try crashAt(c, i + 1);
    try save(c, job, "committed-1");
    try crashAt(c, i + 2);
    try save(c, job, "committed-2");
    try Io.Dir.cwd().deleteTree(c.io, work);
    c.print("crash points {d} (pending) to {d} of a journal", .{ i - 1, i + 2 });
    for (states) |st| {
        const got = try listState(c, job, st[0]);
        c.print("  {s}: {s}", .{ st[0], got });
        if (!std.mem.eql(u8, got, st[1])) c.fail("{s} holds {s}, not {s} (see src/sql/attach_test.zig)", .{ st[0], got, st[1] });
    }
}

/// Crash sqlite3 at change `at` of a journal; leaves the files in `work`.
fn crashAt(c: *Check, at: u32) !void {
    try Io.Dir.cwd().deleteTree(c.io, work);
    try Io.Dir.cwd().createDirPath(c.io, work);
    for ([_][]const u8{ "main.db", "a.db", "b.db" }) |f| {
        _ = try c.runOk(&.{ c.cfg.sqlite3, f, "PRAGMA page_size=512; CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t VALUES(1, 'old'), (2, 'old');" }, .{ .cwd = work });
    }
    _ = try c.run(&.{
        c.cfg.sqlite3, "main.db",
        \\ATTACH 'a.db' AS a; ATTACH 'b.db' AS b;
        \\    BEGIN; UPDATE t SET b = 'new'; UPDATE a.t SET b = 'new'; UPDATE b.t SET b = 'new'; COMMIT;
    }, .{ .cwd = work, .env = try crash.sqliteEnv(c, "-journal", at) });
}

fn readWork(c: *Check, f: []const u8) !?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.arena, &.{ work, f }), c.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

/// The name of the super-journal (main.db-mj*) in `work`, if any.
fn superJournal(c: *Check) !?[]const u8 {
    var dir = try Io.Dir.cwd().openDir(c.io, work, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |e| {
        if (std.mem.startsWith(u8, e.name, "main.db-mj")) return try c.arena.dupe(u8, e.name);
    }
    return null;
}

/// Copies the files of `work` into the state directory `state`, made new.
fn save(c: *Check, job: *const Job, state: []const u8) !void {
    const dir = try std.fs.path.join(c.arena, &.{ job.out_dir, state });
    try Io.Dir.cwd().deleteTree(c.io, dir);
    try Io.Dir.cwd().createDirPath(c.io, dir);
    for (files) |f| {
        const bytes = try readWork(c, f) orelse continue;
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fs.path.join(c.arena, &.{ dir, f }), .data = bytes });
    }
    if (try superJournal(c)) |s| {
        const bytes = (try readWork(c, s)).?;
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fs.path.join(c.arena, &.{ dir, "super" }), .data = bytes });
    }
}

/// The files of a saved state, in the order of `files`, then "super".
fn listState(c: *Check, job: *const Job, state: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (files ++ [_][]const u8{"super"}) |f| {
        const p = try std.fs.path.join(c.arena, &.{ job.out_dir, state, f });
        if (!xqt.Config.exists(c.io, p)) continue;
        if (list.items.len > 0) try list.append(c.arena, ' ');
        try list.appendSlice(c.arena, f);
    }
    return list.items;
}
