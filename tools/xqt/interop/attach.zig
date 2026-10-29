//! ATTACH and multi-database transactions against sqlite3:
//!   1. each engine attaches files the other wrote and changes them; the
//!      rows and integrity_check of every file match
//!   2. the statements of a script over attached databases (pragmas,
//!      sqlite_schema, temp triggers, views, DETACH, errors) print the same
//!   3. a transaction over three files committed by one engine is read
//!      back by the other, in each rollback journal mode
//!   4. xqlite dies at every write of such a commit (XQLITE_TEST_CRASH),
//!      and sqlite3 recovers both files to the old or both to the new rows
//!      and deletes the super-journal
//!   5. sqlite3 dies at every write, truncation or delete of such a commit
//!      (tools/crashshim.c), and xqlite recovers
//! The crash points of each series of 4 and 5 run in parallel, each on
//! files of its own. (Was tools/interop-attach.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const crash = xqt.crash;
const parts = @import("parts.zig");

pub const name = "attach";
pub const about = "ATTACH, transactions over three files, crashes in their commit";

const modes = [_][]const u8{ "delete", "persist", "truncate" };

const Writer = enum { xqlite, sqlite3 };
const Kind = enum { db, journal };

const Series = struct { writer: Writer, kind: Kind, mode: []const u8 };

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    // The crash series first: they take the longest.
    for ([_]Writer{ .sqlite3, .xqlite }) |writer| for (modes) |mode| for ([_]Kind{ .db, .journal }) |kind| {
        const n = try std.fmt.allocPrint(a, "{s} crashes at each {t} write, journal_mode={s}", .{ @tagName(writer), kind, mode });
        try s.add(n, crashSeries, .{Series{ .writer = writer, .kind = kind, .mode = mode }});
    };
    for (modes) |mode| for ([_]Writer{ .xqlite, .sqlite3 }) |writer| {
        const n = try std.fmt.allocPrint(a, "three files, journal_mode={s}, written by {t}", .{ mode, writer });
        try s.add(n, threeFiles, .{ mode, writer });
    };
    try s.add("each other's files, built by sqlite3", attachOne, .{});
    try s.add("each other's files, built by xqlite", attachTwo, .{});
    try s.add("the same output for a script over attached databases", attachScript, .{});
}

const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
    \\CREATE INDEX t_b ON t(b);
    \\WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<500)
    \\INSERT INTO t SELECT n, 'v' || (n % 31) FROM c;
;
const change =
    \\ATTACH 'aux.db' AS aux;
    \\CREATE TABLE IF NOT EXISTS aux.u(x INTEGER PRIMARY KEY, y UNIQUE, z);
    \\INSERT OR REPLACE INTO aux.u(y, z) SELECT b || '-' || a, a * 2 FROM main.t WHERE a % 3 = 0;
    \\DELETE FROM aux.u WHERE x % 7 = 0;
    \\UPDATE main.t SET b = upper(b) WHERE a IN (SELECT z FROM aux.u);
    \\CREATE INDEX IF NOT EXISTS aux.uz ON u(z);
;
const queries =
    \\ATTACH 'aux.db' AS aux;
    \\SELECT count(*), sum(a), min(b), max(b) FROM t;
    \\SELECT count(*), sum(x), min(y), max(z) FROM aux.u;
    \\SELECT count(*) FROM t JOIN aux.u ON u.z = t.a;
    \\SELECT name, type FROM aux.sqlite_schema ORDER BY name;
    \\PRAGMA aux.integrity_check;
    \\PRAGMA integrity_check;
;

/// The statements on main.db by xqlite, then by sqlite3: the same output
/// (standard output and error together), whatever the exit status.
fn same(c: *Check, label: []const u8, sql: []const u8) !void {
    const x = try parts.combined(c, &.{ c.cfg.xq, "sql", "main.db", sql }, .{});
    const s = try parts.combined(c, &.{ c.cfg.sqlite3, "main.db", sql }, .{});
    _ = c.expectSame(label, "xqlite", x, "sqlite3", s);
}

/// 1. Files sqlite3 built, changed by xqlite, then by both.
fn attachOne(c: *Check) !void {
    _ = try c.sqlite3("main.db", schema);
    _ = try c.xqSql("main.db", change);
    try same(c, "xqlite changed sqlite3's files", queries);
    _ = try c.sqlite3("main.db", change);
    _ = try c.xqSql("main.db", change);
    try same(c, "both changed the files", queries);
}

/// 1. Files xqlite built, changed by both.
fn attachTwo(c: *Check) !void {
    _ = try c.xqSql("main.db", schema);
    _ = try c.sqlite3("main.db", change);
    _ = try c.xqSql("main.db", change);
    try same(c, "xqlite's files changed by both", queries);
}

/// 2. A script over attached databases.
fn attachScript(c: *Check) !void {
    _ = try c.sqlite3("main.db", schema);
    _ = try c.sqlite3("aux.db", "CREATE TABLE u(x INTEGER PRIMARY KEY, y); INSERT INTO u VALUES(1, 'a'), (2, 'b');");
    try same(c, "attach script",
        \\ATTACH 'aux.db' AS aux;
        \\ATTACH 'aux.db' AS aux;
        \\ATTACH 'other.db' AS MAIN;
        \\ATTACH 'x.db' AS temp;
        \\ATTACH 'file:aux.db?mode=ro' AS ro;
        \\SELECT * FROM ro.u;
        \\ATTACH ':memory:' AS m;
        \\ATTACH '' AS e;
        \\ATTACH 'file:nope.db?mode=rw' AS n;
        \\ATTACH 'file:aux.db?mode=bogus' AS n;
        \\ATTACH 'nodir/x.db' AS n;
        \\PRAGMA database_list;
        \\SELECT seq, name FROM pragma_database_list;
        \\PRAGMA aux.table_info(u);
        \\SELECT * FROM pragma_table_info('u', 'aux');
        \\PRAGMA aux.user_version = 9;
        \\PRAGMA aux.user_version;
        \\PRAGMA aux.page_count;
        \\PRAGMA aux.journal_mode;
        \\PRAGMA aux.journal_mode = wal;
        \\INSERT INTO aux.u VALUES(3, 'c');
        \\PRAGMA aux.wal_checkpoint;
        \\PRAGMA aux.journal_mode = delete;
        \\SELECT name, sql FROM aux.sqlite_master;
        \\CREATE VIEW aux.v AS SELECT y FROM u;
        \\CREATE VIEW aux.v2 AS SELECT * FROM main.t;
        \\SELECT * FROM aux.v;
        \\CREATE TEMP TRIGGER tr AFTER INSERT ON aux.u BEGIN INSERT INTO m.log VALUES(new.y); END;
        \\CREATE TABLE m.log(y);
        \\INSERT INTO aux.u VALUES(4, 'd');
        \\SELECT * FROM m.log;
        \\CREATE TRIGGER aux.tr2 AFTER INSERT ON u BEGIN INSERT INTO main.t VALUES(1, 2); END;
        \\BEGIN; INSERT INTO aux.u VALUES(5, 'e'); DETACH aux; COMMIT;
        \\DETACH aux;
        \\DETACH aux;
        \\DETACH main;
        \\SELECT name, tbl_name FROM temp.sqlite_schema;
        \\PRAGMA database_list;
    );
}

/// The commit over three files. The journal mode is the connection's: it
/// is set again for the commit.
fn txn(c: *Check, mode: []const u8) ![]const u8 {
    return std.fmt.allocPrint(c.arena,
        \\ATTACH 'a.db' AS a; ATTACH 'b.db' AS b; PRAGMA journal_mode={s};
        \\BEGIN; UPDATE t SET b = 'new'; UPDATE a.t SET b = 'new'; UPDATE b.t SET b = 'new'; COMMIT;
        \\SELECT 'committed';
    , .{mode});
}

const check3 =
    \\ATTACH 'a.db' AS a; ATTACH 'b.db' AS b;
    \\SELECT (SELECT group_concat(DISTINCT b) FROM main.t) || (SELECT group_concat(DISTINCT b) FROM a.t) || (SELECT group_concat(DISTINCT b) FROM b.t);
    \\PRAGMA main.integrity_check; PRAGMA a.integrity_check; PRAGMA b.integrity_check;
;

/// Three files with the same table, made by `shell`.
fn three(c: *Check, shell: Writer, mode: []const u8) !void {
    const sql = try std.fmt.allocPrint(c.arena,
        \\PRAGMA journal_mode={s}; PRAGMA page_size=1024; CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
        \\      WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<300)
        \\      INSERT INTO t SELECT n, 'old' FROM c;
    , .{mode});
    for ([_][]const u8{ "main.db", "a.db", "b.db" }) |f| switch (shell) {
        .sqlite3 => _ = try c.sqlite3(f, sql),
        .xqlite => _ = try c.xqSql(f, sql),
    };
}

/// What `reader` reads back with check3, on one line.
fn readBack(c: *Check, reader: Writer) ![]const u8 {
    const argv: []const []const u8 = switch (reader) {
        .sqlite3 => &.{ c.cfg.sqlite3, "main.db", check3 },
        .xqlite => &.{ c.cfg.xq, "sql", "main.db", check3 },
    };
    return parts.oneLine(c, (try c.run(argv, .{})).stdout);
}

/// Whether a super-journal (a name with "-mj", `ls ./*-mj*`) is in the
/// check's directory.
fn superJournalLeft(c: *Check) !bool {
    var dir = try std.Io.Dir.cwd().openDir(c.io, c.dir, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |e| {
        if (std.mem.indexOf(u8, e.name, "-mj") != null) return true;
    }
    return false;
}

/// Whether some journal (*-journal) names a super-journal.
fn journalNamesSuper(c: *Check) !bool {
    var dir = try std.Io.Dir.cwd().openDir(c.io, c.dir, .{ .iterate = true });
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |e| {
        if (!std.mem.endsWith(u8, e.name, "-journal")) continue;
        const bytes = try c.readFile(e.name);
        if (std.mem.indexOf(u8, bytes, "-mj") != null) return true;
    }
    return false;
}

/// 3. One engine commits over three files, the other reads them.
fn threeFiles(c: *Check, mode: []const u8, writer: Writer) !void {
    const reader: Writer = switch (writer) {
        .xqlite => blk: {
            try three(c, .sqlite3, mode);
            _ = try c.xqSql("main.db", try txn(c, mode));
            break :blk .sqlite3;
        },
        .sqlite3 => blk: {
            try three(c, .xqlite, mode);
            _ = try c.sqlite3("main.db", try txn(c, mode));
            break :blk .xqlite;
        },
    };
    const got = try readBack(c, reader);
    _ = c.expect(std.mem.eql(u8, got, "newnewnew ok ok ok "), "{s}", .{got});
    _ = c.expect(!try superJournalLeft(c), "super-journal left", .{});
}

const old_rows = "oldoldold ok ok ok ";
const new_rows = "newnewnew ok ok ok ";

/// 4 and 5: the writer dies at each write of the commit in turn, until a
/// run gets through it, and the other engine recovers each time.
fn crashSeries(c: *Check, series: Series) !void {
    if (series.writer == .sqlite3) try crash.requireShim(c);
    try parts.crashPoints(c, 200, series, crashAt, .{});
}

/// After a crash at write `at` of the commit, the other engine must find
/// all three files old or all new. Which one the files on disk decide: a
/// journal that names a super-journal that is gone belongs to a committed
/// transaction, so then all must be new; while the super-journal exists,
/// all must be old. (A crash before a journal names the super-journal
/// orphans it, in sqlite3 too, so the transaction rolls back.)
fn crashAt(c: *Check, series: Series, at: u32) !bool {
    try three(c, .sqlite3, series.mode);
    const sql = try txn(c, series.mode);
    const out = switch (series.writer) {
        .xqlite => try parts.combined(c, &.{ c.cfg.xq, "sql", "main.db", sql }, .{
            .env = try crash.xqEnv(c, switch (series.kind) {
                .db => .db,
                .journal => .journal,
            }, at, .{}),
        }),
        .sqlite3 => try parts.combined(c, &.{ c.cfg.sqlite3, "main.db", sql }, .{
            .env = try crash.sqliteEnv(c, switch (series.kind) {
                .db => ".db",
                .journal => "-journal",
            }, at),
        }),
    };

    const super_left = try superJournalLeft(c);
    const names_super = !super_left and try journalNamesSuper(c);
    const either = !super_left and !names_super;
    const want = if (names_super) new_rows else old_rows;
    const got = try readBack(c, switch (series.writer) {
        .xqlite => .sqlite3,
        .sqlite3 => .xqlite,
    });
    const ok = std.mem.eql(u8, got, want) or (either and std.mem.eql(u8, got, new_rows));
    _ = c.expect(ok, "crash at {d}: {s} (want {s})", .{ at, got, want });
    return std.mem.endsWith(u8, parts.trimmed(out), "committed");
}
