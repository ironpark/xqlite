//! The b-tree layer against sqlite3 (`xqlite bt-fill`, `bt-churn`,
//! `bt-vacuum` and `check`):
//!   1. xqlite builds a table and an index from scratch; sqlite3 must find
//!      the file intact and identical in content to the same build in SQL.
//!   2. xqlite deletes, updates and inserts rows in a database built by
//!      sqlite3; the result must match the same statements run by sqlite3.
//!   3. xqlite's integrity check agrees with sqlite3's on a corrupt file.
//!   4. 1 and 2 again on auto-vacuum databases (full and incremental): the
//!      pointer map must check out, and full mode must leave no free pages.
//! (Was tools/interop-btree.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "btree";
pub const about = "bt-fill, bt-churn, bt-vacuum and check against sqlite3";

pub fn register(s: *xqt.Suite) !void {
    try s.add("xqlite writes a table and an index, sqlite3 reads them", fills, .{});
    try s.add("xqlite modifies a database written by sqlite3", churns, .{});
    try s.add("both integrity checks report the same corruption", corruption, .{});
    for ([_]AutoVacuum{ .full, .incremental }) |av| {
        try s.add(try std.fmt.allocPrint(s.arena.allocator(), "auto_vacuum={t}: fill", .{av}), autoVacuumFill, .{av});
        try s.add(try std.fmt.allocPrint(s.arena.allocator(), "auto_vacuum={t}: churn", .{av}), autoVacuumChurn, .{av});
    }
}

const n = "3000";

/// The content `xqlite bt-fill` writes (see src/cli/main.zig), with the
/// auto_vacuum mode `av`. printf('%.*c', 0, x) still prints one
/// character, so no length is 0.
fn fillSql(comptime av: []const u8) []const u8 {
    return "PRAGMA page_size=4096; PRAGMA auto_vacuum=" ++ av ++ ";\n" ++
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
        \\CREATE INDEX t_b ON t(b);
        \\
    ++ "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<" ++ n ++ ")\n" ++
        "INSERT INTO t SELECT i, printf('v-%d', (i*7919)%" ++ n ++ "),\n" ++
        \\  cast(printf('%.*c', CASE WHEN i%50=0 THEN 3000 ELSE i%20+1 END, 'p') AS BLOB) FROM s;
        \\DELETE FROM t WHERE a%7=0;
    ;
}
const fill_sql = fillSql("0");

/// What `xqlite bt-churn` does.
const churn_sql =
    \\DELETE FROM t WHERE a%3=0;
    \\UPDATE t SET c=cast(printf('%.*c', 1500+a, 'u') AS BLOB) WHERE a%3=1 AND a<200;
    \\WITH RECURSIVE s(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM s WHERE k<500)
    \\INSERT INTO t SELECT 100000+k, 'new-'||k,
    \\  cast(printf('%.*c', CASE WHEN k%10=0 THEN 2500 ELSE k%30+1 END, 'n') AS BLOB) FROM s;
;

/// More writes, done by sqlite3 on both files afterwards.
const more_sql =
    \\DELETE FROM t WHERE a%4=1;
    \\WITH RECURSIVE s(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM s WHERE k<800)
    \\INSERT INTO t SELECT 200000+k, printf('more-%d', k*31%800), zeroblob(k%5) FROM s;
;

fn content(c: *Check, db: []const u8) ![]const u8 {
    return c.sqlite3(db,
        \\SELECT a, b, typeof(c), hex(c) FROM t ORDER BY a;
        \\                  SELECT b, a FROM t INDEXED BY t_b WHERE b>'' ORDER BY b;
    );
}

/// Fails with "content differs" and `what` unless `a` and `b` agree.
fn sameContent(c: *Check, a: []const u8, b: []const u8, what: []const u8) !void {
    const ca = try content(c, a);
    const cb = try content(c, b);
    if (!std.mem.eql(u8, ca, cb)) return c.abort("content differs{s}", .{what});
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n");
}

fn freelist(c: *Check, db: []const u8) ![]const u8 {
    return trimmed(try c.sqlite3(db, "PRAGMA freelist_count"));
}

fn intact(c: *Check, db: []const u8) !void {
    if (!std.mem.eql(u8, trimmed(try c.sqlite3(db, "PRAGMA integrity_check")), "ok"))
        return c.abort("sqlite3 integrity_check on {s}", .{db});
    if (!std.mem.eql(u8, trimmed(try c.xq(&.{ "check", db })), "ok"))
        return c.abort("xqlite check on {s}", .{db});
}

/// 1. xqlite writes a table and an index, sqlite3 reads them.
fn fills(c: *Check) !void {
    _ = try c.sqlite3("ref1.db", fill_sql);
    _ = try c.xq(&.{ "bt-fill", "x1.db", n });
    try intact(c, "x1.db");
    try sameContent(c, "x1.db", "ref1.db", "");
}

/// 2. xqlite modifies a database written by sqlite3.
fn churns(c: *Check) !void {
    _ = try c.sqlite3("ref2.db", "PRAGMA page_size=1024; " ++ fill_sql);
    try c.copyFile("ref2.db", "x2.db");
    _ = try c.sqlite3("ref2.db", churn_sql);
    _ = try c.xq(&.{ "bt-churn", "x2.db" });
    try intact(c, "x2.db");
    try sameContent(c, "x2.db", "ref2.db", "");
    // And sqlite3 can keep writing to the result.
    _ = try c.sqlite3("x2.db", more_sql);
    _ = try c.sqlite3("ref2.db", more_sql);
    try intact(c, "x2.db");
    try sameContent(c, "x2.db", "ref2.db", " after sqlite3 writes");
}

/// 3. Both integrity checks report the same corruption.
fn corruption(c: *Check) !void {
    _ = try c.sqlite3("bad.db", fill_sql);
    // Point the first cell of page 3 past the end of the page.
    const data = try c.readFile("bad.db");
    data[2 * 4096 + 8] = 0xff;
    data[2 * 4096 + 9] = 0xff;
    try c.writeFile("bad.db", data);
    // sqlite3 adds a header line and index-versus-table checks, which
    // belong to the SQL layer.
    const r = try c.run(&.{ c.cfg.sqlite3, "bad.db", "PRAGMA integrity_check" }, .{});
    var want: std.Io.Writer.Allocating = .init(c.arena);
    var lines = std.mem.splitScalar(u8, trimmed(r.stdout), '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "*** in database main ***")) continue;
        if (std.mem.startsWith(u8, line, "wrong # of entries")) continue;
        if (std.mem.startsWith(u8, line, "row ") and std.mem.indexOf(u8, line[4..], " missing from index") != null) continue;
        try want.writer.print("{s}\n", .{line});
    }
    const got = try c.xq(&.{ "check", "bad.db" });
    _ = c.expectSame("integrity messages", "sqlite3", trimmed(want.written()), "xqlite", trimmed(got));
}

const AutoVacuum = enum { full, incremental };

fn avSql(av: AutoVacuum) []const u8 {
    return switch (av) {
        .full => comptime fillSql("1"),
        .incremental => comptime fillSql("2"),
    };
}

/// 4. Section 1 on an auto-vacuum database.
fn autoVacuumFill(c: *Check, av: AutoVacuum) !void {
    _ = try c.sqlite3("ref4.db", avSql(av));
    _ = try c.xq(&.{ "bt-fill", "x4.db", n, @tagName(av) });
    const num = if (av == .full) "1" else "2";
    if (!std.mem.eql(u8, trimmed(try c.sqlite3("x4.db", "PRAGMA auto_vacuum")), num))
        return c.abort("auto_vacuum mode of x4.db ({t})", .{av});
    try intact(c, "x4.db");
    try sameContent(c, "x4.db", "ref4.db", try std.fmt.allocPrint(c.arena, " ({t} fill)", .{av}));
    if (av == .full and !std.mem.eql(u8, try freelist(c, "x4.db"), "0"))
        return c.abort("free pages left ({t} fill)", .{av});
}

/// 4. Section 2 on an auto-vacuum database, and bt-vacuum.
fn autoVacuumChurn(c: *Check, av: AutoVacuum) !void {
    _ = try c.sqlite3("ref5.db", try std.mem.concat(c.arena, u8, &.{ "PRAGMA page_size=1024; ", avSql(av) }));
    try c.copyFile("ref5.db", "x5.db");
    _ = try c.sqlite3("ref5.db", churn_sql);
    _ = try c.xq(&.{ "bt-churn", "x5.db" });
    try intact(c, "x5.db");
    try sameContent(c, "x5.db", "ref5.db", try std.fmt.allocPrint(c.arena, " ({t} churn)", .{av}));
    if (av == .incremental) {
        // Commit keeps free pages; vacuuming removes them.
        _ = try c.sqlite3("x5.db", "DELETE FROM t WHERE a>100000");
        _ = try c.sqlite3("ref5.db", "DELETE FROM t WHERE a>100000; PRAGMA incremental_vacuum;");
        const free = try freelist(c, "x5.db");
        const pages = std.fmt.parseInt(i64, free, 10) catch 0;
        if (pages <= 0) return c.abort("expected free pages ({t})", .{av});
        _ = try c.xq(&.{ "bt-vacuum", "x5.db" });
        try intact(c, "x5.db");
        try sameContent(c, "x5.db", "ref5.db", try std.fmt.allocPrint(c.arena, " ({t} vacuum)", .{av}));
    }
    if (!std.mem.eql(u8, try freelist(c, "x5.db"), "0"))
        return c.abort("free pages left ({t} churn)", .{av});
    _ = try c.sqlite3("x5.db", more_sql);
    _ = try c.sqlite3("ref5.db", more_sql);
    try intact(c, "x5.db");
    try sameContent(c, "x5.db", "ref5.db", try std.fmt.allocPrint(c.arena, " after sqlite3 writes ({t})", .{av}));
}
