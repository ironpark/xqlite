//! VACUUM, VACUUM INTO and the backup API against sqlite3:
//!   1. both engines VACUUM copies of the same database (rollback journal,
//!      auto-vacuum, WAL; built by either engine) with page_size and
//!      auto_vacuum changes, and the files are byte for byte the same;
//!      each engine passes integrity_check on the other's
//!   2. the same for VACUUM INTO, with a URI reserve=N
//!   3. .backup, .save and .restore (the backup API) of the shells write
//!      the same bytes, across page sizes, and each reads the other's copy
//!   4. xqlite dies at every write of a VACUUM (XQLITE_TEST_CRASH) and
//!      sqlite3 recovers the file to the bytes before or after the VACUUM
//!      (or, in WAL mode, the same rows)
//!   5. sqlite3 dies at every change of the file or journal in a VACUUM
//!      (tools/crashshim.c) and xqlite recovers
//! One check per database (1-3) or crash series (4, 5); its cases or
//! crash points run in parallel on copies. (Was tools/interop-vacuum.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const crash = xqt.crash;
const parts = @import("parts.zig");

pub const name = "vacuum";
pub const about = "VACUUM, VACUUM INTO, .backup/.restore: the same bytes; crashes in a VACUUM";

const Engine = enum { xqlite, sqlite3 };

/// A database of 1-3: the engine that builds it and the pragmas first.
const Base = struct { dir: []const u8, engine: Engine, pragmas: []const u8 };

const bases = [_]Base{
    .{ .dir = "sq-plain", .engine = .sqlite3, .pragmas = "" },
    .{ .dir = "sq-auto", .engine = .sqlite3, .pragmas = "PRAGMA auto_vacuum=FULL; PRAGMA page_size=2048;" },
    .{ .dir = "sq-incr", .engine = .sqlite3, .pragmas = "PRAGMA auto_vacuum=INCREMENTAL; PRAGMA page_size=16384;" },
    .{ .dir = "sq-wal", .engine = .sqlite3, .pragmas = "PRAGMA journal_mode=wal;" },
    .{ .dir = "xq-plain", .engine = .xqlite, .pragmas = "" },
    .{ .dir = "xq-auto", .engine = .xqlite, .pragmas = "PRAGMA auto_vacuum=FULL; PRAGMA page_size=1024;" },
    .{ .dir = "xq-wal", .engine = .xqlite, .pragmas = "PRAGMA journal_mode=wal;" },
};

fn base(comptime dir: []const u8) Base {
    for (bases) |b| if (std.mem.eql(u8, b.dir, dir)) return b;
    unreachable;
}

const JournalMode = enum { delete, persist, wal };
const FileKind = enum { db, journal, wal };
const Series = struct { writer: Engine, kind: FileKind, mode: JournalMode };

const crash_series = [_]Series{
    // 5. sqlite3 dies.
    .{ .writer = .sqlite3, .kind = .db, .mode = .delete },
    .{ .writer = .sqlite3, .kind = .journal, .mode = .delete },
    .{ .writer = .sqlite3, .kind = .db, .mode = .persist },
    .{ .writer = .sqlite3, .kind = .journal, .mode = .persist },
    .{ .writer = .sqlite3, .kind = .wal, .mode = .wal },
    // 4. xqlite dies.
    .{ .writer = .xqlite, .kind = .db, .mode = .delete },
    .{ .writer = .xqlite, .kind = .journal, .mode = .delete },
    .{ .writer = .xqlite, .kind = .db, .mode = .persist },
    .{ .writer = .xqlite, .kind = .journal, .mode = .persist },
    .{ .writer = .xqlite, .kind = .wal, .mode = .wal },
    .{ .writer = .xqlite, .kind = .db, .mode = .wal },
};

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    // The crash series first: they take the longest.
    for (crash_series) |cs| {
        const n = try std.fmt.allocPrint(a, "{t} crashes at each {t} write of a VACUUM, journal_mode={t}", .{ cs.writer, cs.kind, cs.mode });
        try s.add(n, crashSeries, .{cs});
    }
    for (bases) |b| try s.add(try std.fmt.allocPrint(a, "VACUUM writes the same bytes, {s}", .{b.dir}), vacuums, .{b});
    for ([_]Base{ base("sq-plain"), base("sq-auto"), base("sq-wal"), base("xq-plain") }) |b|
        try s.add(try std.fmt.allocPrint(a, "VACUUM INTO writes the same bytes, {s}", .{b.dir}), vacuumInto, .{b});
    for ([_]Base{ base("sq-plain"), base("sq-auto"), base("xq-plain"), base("xq-wal") }) |b|
        try s.add(try std.fmt.allocPrint(a, ".backup, .save and .restore, {s}", .{b.dir}), backups, .{b});
    try s.add(".backup DB FILE", backupDbFile, .{});
}

// Tables with holes, indexes (one UNIQUE over a blob), overflow pages in
// a table and a WITHOUT ROWID table, AUTOINCREMENT, sqlite_stat1, a view
// and a trigger, and header fields VACUUM keeps.
const content =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
    \\CREATE INDEX tb ON t(b);
    \\CREATE UNIQUE INDEX tc ON t(c, a);
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<400)
    \\INSERT INTO t SELECT i * 7, printf('%.*c', i % 150, 'v'), zeroblob(i % 11 * 700) FROM n;
    \\DELETE FROM t WHERE a % 3 = 0;
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB) WITHOUT ROWID;
    \\INSERT INTO w SELECT b || a, zeroblob(a % 5000) FROM t;
    \\DELETE FROM w WHERE length(k) % 4 = 0;
    \\CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, x);
    \\INSERT INTO s(x) SELECT a FROM t WHERE a < 200;
    \\CREATE TABLE r(x, y);
    \\INSERT INTO r SELECT b, a FROM t WHERE a % 5 = 1;
    \\CREATE VIEW tv AS SELECT a, b FROM t WHERE a > 10;
    \\CREATE TRIGGER ttr AFTER DELETE ON t BEGIN INSERT INTO s(x) VALUES(old.a); END;
    \\ANALYZE;
    \\PRAGMA user_version = 42;
    \\PRAGMA application_id = 1234;
;
// The rows, to compare without the file layout.
const rows =
    \\SELECT count(*), sum(a), sum(length(b)), sum(length(c)) FROM t;
    \\SELECT count(*), sum(length(v)) FROM w;
    \\SELECT count(*), sum(x) FROM s;
    \\SELECT count(*) FROM r;
    \\SELECT * FROM sqlite_sequence;
    \\PRAGMA user_version;
;

/// `ENGINE ARGS...`: `xqlite sql ARGS...` or `sqlite3 ARGS...`.
fn argv(c: *Check, e: Engine, args: []const []const u8) ![]const []const u8 {
    return switch (e) {
        .sqlite3 => c.command(c.cfg.sqlite3, args),
        .xqlite => blk: {
            const v = try c.arena.alloc([]const u8, args.len + 2);
            v[0] = c.cfg.xq;
            v[1] = "sql";
            @memcpy(v[2..], args);
            break :blk v;
        },
    };
}

/// The database main.db in the new directory `b.dir` of the check.
fn build(c: *Check, b: Base) ![]const u8 {
    try c.makeDir(b.dir);
    _ = try c.runOk(try argv(c, b.engine, &.{ "main.db", b.pragmas, content }), .{ .cwd = try c.path(b.dir) });
    return c.path(b.dir);
}

/// A case of `same_file`: SQL run on a copy of `src` by each engine; the
/// output and the file `file` must be the same.
const Case = struct {
    label: []const u8,
    /// An absolute directory.
    src: []const u8,
    sql: []const u8,
    file: []const u8,
    /// freelist_count after it: 0 after a VACUUM (a backup copies the
    /// source's).
    free: []const u8 = "0",
};

/// The integrity check of `file` by both engines, and its freelist.
fn checkBoth(c: *Check, label: []const u8, file: []const u8, free: []const u8) !void {
    const sql = try std.fmt.allocPrint(c.arena, "PRAGMA integrity_check; SELECT freelist_count = {s} FROM pragma_freelist_count;", .{free});
    for ([_]Engine{ .xqlite, .sqlite3 }) |e| {
        const got = try parts.oneLine(c, try parts.combined(c, try argv(c, e, &.{ file, sql }), .{}));
        _ = c.expect(std.mem.eql(u8, got, "ok 1 "), "{s}: {t} on {s}: {s}", .{ label, e, file, got });
    }
}

/// Run SQL on a copy of the source with each engine; the files must be
/// the same.
fn sameFile(c: *Check, k: Case) !void {
    try c.remove("x");
    try c.remove("s");
    try c.copyDir(k.src, "x");
    try c.copyDir(k.src, "s");
    const x = try parts.combined(c, try argv(c, .xqlite, &.{ "main.db", k.sql }), .{ .cwd = "x" });
    const s = try parts.combined(c, try argv(c, .sqlite3, &.{ "main.db", k.sql }), .{ .cwd = "s" });
    _ = c.expectSame(try std.fmt.allocPrint(c.arena, "{s}: output", .{k.label}), "xqlite", x, "sqlite3", s);
    const xf = try std.fmt.allocPrint(c.arena, "x/{s}", .{k.file});
    const sf = try std.fmt.allocPrint(c.arena, "s/{s}", .{k.file});
    const same = c.exists(xf) and c.exists(sf) and std.mem.eql(u8, try c.readFile(xf), try c.readFile(sf));
    _ = c.expect(same, "{s}: {s} differs", .{ k.label, k.file });
    try checkBoth(c, k.label, xf, k.free);
}

fn runCases(part: *Check, cases: []const Case, i: usize) !void {
    try sameFile(part, cases[i]);
}

const vacuum_sql = [_][]const u8{
    "VACUUM",
    "VACUUM main",
    "PRAGMA page_size=1024; VACUUM",
    "PRAGMA page_size=512; VACUUM",
    "PRAGMA page_size=65536; VACUUM",
    "PRAGMA auto_vacuum=FULL; VACUUM",
    "PRAGMA auto_vacuum=INCREMENTAL; PRAGMA page_size=2048; VACUUM",
    "PRAGMA auto_vacuum=NONE; VACUUM",
    "VACUUM; VACUUM",
    "PRAGMA journal_mode=persist; VACUUM",
    "PRAGMA journal_mode=truncate; PRAGMA page_size=8192; VACUUM",
    "DELETE FROM t WHERE a > 1000; VACUUM",
};

/// 1. VACUUM writes the same bytes; on sq-plain also an attached database.
fn vacuums(c: *Check, b: Base) !void {
    const src = try build(c, b);
    var cases: std.ArrayList(Case) = .empty;
    for (vacuum_sql) |v| try cases.append(c.arena, .{
        .label = try std.fmt.allocPrint(c.arena, "{s}: {s}", .{ b.dir, v }),
        .src = src,
        .sql = v,
        .file = "main.db",
    });
    if (std.mem.eql(u8, b.dir, "sq-plain"))
        try cases.append(c.arena, .{ .label = "attached", .src = src, .sql = "ATTACH 'main.db' AS m2; VACUUM m2", .file = "main.db" });
    try parts.forEach(c, cases.items.len, @as([]const Case, cases.items), runCases);
}

/// 2. VACUUM INTO writes the same bytes.
fn vacuumInto(c: *Check, b: Base) !void {
    const src = try build(c, b);
    const into = [_][2][]const u8{
        .{ "INTO", "VACUUM INTO 'out.db'" },
        .{ "INTO, page_size", "PRAGMA page_size=4096; PRAGMA auto_vacuum=2; VACUUM INTO 'out.db'" },
        .{ "INTO, reserve", "VACUUM INTO 'file:out.db?reserve=24'" },
        .{ "INTO, then VACUUM", "VACUUM INTO 'file:out.db?reserve=16'; ATTACH 'out.db' AS o; VACUUM o" },
        .{ "INTO, errors", "VACUUM INTO 'out.db'; VACUUM INTO 'out.db'; VACUUM INTO 1; VACUUM INTO NULL; VACUUM nosuch; VACUUM temp; BEGIN; VACUUM" },
    };
    var cases: [into.len]Case = undefined;
    for (into, &cases) |v, *k| k.* = .{
        .label = try std.fmt.allocPrint(c.arena, "{s} {s}", .{ b.dir, v[0] }),
        .src = src,
        .sql = v[1],
        .file = "out.db",
    };
    try parts.forEach(c, cases.len, @as([]const Case, &cases), runCases);
}

const Backup = struct { b: Base, src: []const u8, free: []const u8 };

fn freelist(c: *Check, db: []const u8) ![]const u8 {
    return parts.trimmed(try c.sqlite3(db, "PRAGMA freelist_count"));
}

/// 3. .backup, .save and .restore write the same bytes.
fn backups(c: *Check, b: Base) !void {
    const src = try build(c, b);
    const ctx: Backup = .{ .b = b, .src = src, .free = try freelist(c, try std.fmt.allocPrint(c.arena, "{s}/main.db", .{src})) };
    try parts.forEach(c, 5, &ctx, backupCase);
}

fn backupCase(c: *Check, ctx: *const Backup, i: usize) !void {
    const d = ctx.b.dir;
    switch (i) {
        0 => try sameFile(c, .{ .label = try std.fmt.allocPrint(c.arena, "{s} .backup", .{d}), .src = ctx.src, .sql = ".backup copy.db", .file = "copy.db", .free = ctx.free }),
        1 => try sameFile(c, .{ .label = try std.fmt.allocPrint(c.arena, "{s} .save", .{d}), .src = ctx.src, .sql = ".save --async copy.db", .file = "copy.db", .free = ctx.free }),
        else => {
            const sizes = [_][]const u8{ "512", "4096", "65536" };
            const sz = sizes[i - 2];
            // Into a database of another page size, over content to drop.
            try c.makeDir("r");
            try c.copyFile(try std.fmt.allocPrint(c.arena, "{s}/main.db", .{ctx.src}), "r/src.db");
            _ = try c.sqlite3("r/main.db", try std.fmt.allocPrint(c.arena, "PRAGMA page_size={s}; CREATE TABLE junk(x); INSERT INTO junk VALUES(zeroblob(200000));", .{sz}));
            try sameFile(c, .{
                .label = try std.fmt.allocPrint(c.arena, "{s} .restore over page_size {s}", .{ d, sz }),
                .src = try c.path("r"),
                .sql = ".restore src.db",
                .file = "main.db",
                .free = ctx.free,
            });
            // Each engine reads the other's backup.
            const r = try c.path("r");
            _ = try c.runOk(try argv(c, .xqlite, &.{ "src.db", ".backup x.db" }), .{ .cwd = r });
            _ = try c.runOk(try argv(c, .sqlite3, &.{ "src.db", ".backup s.db" }), .{ .cwd = r });
            const want = (try c.run(try argv(c, .xqlite, &.{ "r/src.db", rows }), .{})).stdout;
            for ([_][]const u8{ "x.db", "s.db" }) |f| {
                const got = (try c.run(try argv(c, .sqlite3, &.{ try std.fmt.allocPrint(c.arena, "r/{s}", .{f}), rows }), .{})).stdout;
                _ = c.expect(std.mem.eql(u8, got, want), "{s}: rows of {s} (.restore over page_size {s})", .{ d, f, sz });
            }
        },
    }
}

/// 3. `.backup main FILE` of sq-plain.
fn backupDbFile(c: *Check) !void {
    const src = try build(c, base("sq-plain"));
    const free = try freelist(c, "sq-plain/main.db");
    try sameFile(c, .{ .label = ".backup DB FILE", .src = src, .sql = ".backup main copy.db", .file = "copy.db", .free = free });
}

// Crash tests on a smaller database, with a journal sync point to hit.
const small =
    \\PRAGMA page_size=1024;
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
    \\CREATE INDEX tb ON t(b);
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<150)
    \\INSERT INTO t SELECT i, printf('%.*c', i % 90, 'v'), zeroblob(i % 4 * 400) FROM n;
    \\DELETE FROM t WHERE a % 2 = 0;
;
const crash_vacuum = "PRAGMA page_size=2048; VACUUM; SELECT 'vacuumed';";
const rows_small = "SELECT count(*), sum(a), sum(length(b)), sum(length(c)) FROM t;";

/// What every crash point of a series compares with.
const Crash = struct {
    series: Series,
    /// The directory of the database before the VACUUM.
    base: []const u8,
    /// The file before the VACUUM, and after it (the same for both
    /// engines, see 1).
    before: []const u8,
    after: []const u8,
    /// rows_small before the VACUUM, for WAL mode.
    rows: []const u8,
};

/// 4 and 5: the writer dies at each write of a VACUUM in turn, until a
/// run gets through it, and the other engine recovers each time.
fn crashSeries(c: *Check, series: Series) !void {
    if (series.writer == .sqlite3) try crash.requireShim(c);
    try c.makeDir("base");
    _ = try c.sqlite3Args(&.{ "base/main.db", try std.fmt.allocPrint(c.arena, "PRAGMA journal_mode={t};", .{series.mode}), small });
    try c.copyDir("base", "after");
    _ = try c.sqlite3("after/main.db", crash_vacuum);
    const ctx: Crash = .{
        .series = series,
        .base = try c.path("base"),
        .before = try c.readFile("base/main.db"),
        .after = try c.readFile("after/main.db"),
        .rows = (try c.run(&.{ c.cfg.sqlite3, "base/main.db", rows_small }, .{})).stdout,
    };
    // In WAL mode xqlite's first write of the database is the checkpoint
    // as it closes, after the VACUUM printed: the first run gets through.
    try parts.crashPoints(c, 400, &ctx, crashAt, .{ .may_not_crash = series.mode == .wal and series.kind == .db });
}

/// After a crash, the reader finds the file as it was before the VACUUM
/// or as after it: the bytes in rollback mode (after the commit, the file
/// may not be truncated yet), the rows in WAL mode.
fn crashAt(c: *Check, ctx: *const Crash, at: u32) !bool {
    const s = ctx.series;
    try c.copyDir(ctx.base, "crash");
    const out = switch (s.writer) {
        .xqlite => try parts.combined(c, &.{ c.cfg.xq, "sql", "main.db", crash_vacuum }, .{
            .cwd = "crash",
            .env = try crash.xqEnv(c, switch (s.kind) {
                .db => .db,
                .journal => .journal,
                .wal => .wal,
            }, at, .{}),
        }),
        .sqlite3 => try parts.combined(c, &.{ c.cfg.sqlite3, "main.db", crash_vacuum }, .{
            .cwd = "crash",
            .env = try crash.sqliteEnv(c, switch (s.kind) {
                .db => "main.db",
                .journal => "main.db-journal",
                .wal => "main.db-wal",
            }, at),
        }),
    };
    const reader: Engine = switch (s.writer) {
        .xqlite => .sqlite3,
        .sqlite3 => .xqlite,
    };
    const through = std.mem.endsWith(u8, parts.trimmed(out), "vacuumed");
    const ok = try parts.oneLine(c, try parts.combined(c, try argv(c, reader, &.{ "crash/main.db", "PRAGMA integrity_check;" }), .{}));
    if (!std.mem.eql(u8, ok, "ok ")) {
        c.fail("crash at {d}: {s}", .{ at, ok });
        return through;
    }
    if (s.mode == .wal) {
        const got = (try c.run(try argv(c, reader, &.{ "crash/main.db", rows_small }), .{})).stdout;
        _ = c.expect(std.mem.eql(u8, parts.trimmed(got), parts.trimmed(ctx.rows)), "crash at {d}: rows", .{at});
    } else {
        const now = try c.readFile("crash/main.db");
        const old = std.mem.eql(u8, now, ctx.before);
        const new = now.len >= ctx.after.len and std.mem.eql(u8, now[0..ctx.after.len], ctx.after);
        _ = c.expect(old or new, "crash at {d}: neither the old nor the vacuumed file", .{at});
    }
    return through;
}
