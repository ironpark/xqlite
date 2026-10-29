//! Rollback-journal crash recovery between xqlite and sqlite3: each
//! engine rolls back the hot journal the other left when it died in the
//! middle of a transaction. (Was tools/interop-hot-journal.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "hot-journal";
pub const about = "each engine rolls back the hot journal the other left";

pub fn register(s: *xqt.Suite) !void {
    try s.add("xqlite leaves a hot journal, sqlite3 rolls it back", xqliteCrashes, .{});
    try s.add("sqlite3 leaves a hot journal, xqlite rolls it back", sqlite3Killed, .{});
}

fn makeDb(c: *Check, db: []const u8) !void {
    _ = try c.sqlite3(db,
        \\PRAGMA page_size=1024; PRAGMA journal_mode=delete; CREATE TABLE t(x);
        \\        WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
        \\        INSERT INTO t SELECT randomblob(200) FROM c;
    );
}

fn dump(c: *Check, db: []const u8) ![]const u8 {
    return c.sqlite3(db, ".dump");
}

/// A journal that exists and is not empty.
fn hasJournal(c: *Check, db: []const u8) !bool {
    const size = try c.fileSize(try std.fmt.allocPrint(c.arena, "{s}-journal", .{db})) orelse return false;
    return size > 0;
}

fn changed(c: *Check, db: []const u8, before: []const u8) !bool {
    const gpa = c.suite.gpa;
    const now = try std.Io.Dir.cwd().readFileAlloc(c.io, try c.path(db), gpa, .unlimited);
    defer gpa.free(now);
    return !std.mem.eql(u8, now, before);
}

fn integrityOk(c: *Check, db: []const u8) !void {
    const ok = try c.sqlite3(db, "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, ok, "\n"), "ok")) return c.abort("integrity_check: {s}", .{ok});
}

/// 1. xqlite crashes mid-commit, sqlite3 rolls the hot journal back.
fn xqliteCrashes(c: *Check) !void {
    const db = "a.db";
    try makeDb(c, db);
    const before = try dump(c, db);
    _ = try c.xq(&.{ "crash-write", db, "0xff" });
    if (!try hasJournal(c, db)) return c.abort("no journal left behind", .{});
    try integrityOk(c, db);
    if (!c.expectSame("content after rollback", "before", before, "after", try dump(c, db))) return;
    if (c.exists(db ++ "-journal")) return c.abort("journal not deleted", .{});
}

/// 2. sqlite3 is killed mid-transaction, xqlite rolls the hot journal back.
fn sqlite3Killed(c: *Check) !void {
    const db = "b.db";
    try makeDb(c, db);
    const before = try dump(c, db);
    const raw_before = try c.readFile(db);

    var sq = try c.spawn(&.{ c.cfg.sqlite3, db }, .{ .output = "sqlite3.out" });
    defer sq.kill();
    // A tiny cache forces sqlite3 to spill modified pages into the
    // database file before the transaction ends.
    try sq.write("PRAGMA cache_size=5; BEGIN; UPDATE t SET x=randomblob(200);\n");
    var i: usize = 0;
    while (!try changed(c, db, raw_before)) {
        i += 1;
        if (i >= 100) return c.abort("sqlite3 never spilled", .{});
        c.sleep(100);
    }
    c.sleep(500);
    sq.kill();

    if (!try hasJournal(c, db)) return c.abort("no journal left behind", .{});
    _ = try c.xq(&.{ "recover", db });
    if (c.exists(db ++ "-journal")) return c.abort("journal not deleted", .{});
    try integrityOk(c, db);
    _ = c.expectSame("content after rollback", "before", before, "after", try dump(c, db));
}
