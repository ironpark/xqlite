//! `xqt gen NAME...`: regenerates committed files. The generators named
//! run at once.
//!
//! - fixtures: the databases of src/testdata and pkg/storage/src/testdata,
//!   made by the sqlite3 shell
//!   (was tools/gen-fixtures.sh).
//! - superjournal: src/testdata/superjournal, what sqlite3 leaves when it
//!   dies in a multi-database commit (gen/superjournal.zig; it takes its
//!   own arguments, so it runs alone).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const superjournal = @import("gen/superjournal.zig");

pub const usage =
    \\usage: xqt gen [--fixtures-sqlite3 PATH] NAME...
    \\
    \\  fixtures   pkg/storage/src/testdata/{btree,autovacuum}.db, src/testdata/sql.db with the sqlite3 on
    \\             PATH, or --fixtures-sqlite3 PATH (the committed ones are
    \\             from 3.44.4, whose version they carry in their header)
    \\
    \\
++ superjournal.usage;

const Name = enum { fixtures };

const Job = struct {
    name: Name,
    ctx: *const Ctx,
    /// What to print when it is done (a line), or why it failed.
    message: []const u8 = "",
    ok: bool = false,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const xqt.Config,
    fixtures_sqlite3: []const u8,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], superjournal.name)) return superjournal.run(gpa, io, cfg, out, args[1..]);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .fixtures_sqlite3 = "sqlite3",
    };
    var jobs: std.ArrayList(Job) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--fixtures-sqlite3") and i + 1 < args.len) {
            i += 1;
            ctx.fixtures_sqlite3 = args[i];
            continue;
        }
        const name = std.meta.stringToEnum(Name, a) orelse return usageError(out);
        if (for (jobs.items) |j| (if (j.name == name) break true) else false) continue;
        try jobs.append(arena, .{ .name = name, .ctx = &ctx });
    }
    if (jobs.items.len == 0) return usageError(out);

    xqt.pool.forEach(jobs.items.len, jobs.items.len, jobs.items, runJob);
    var failed = false;
    for (jobs.items) |j| {
        if (j.ok) {
            try out.print("{s}\n", .{j.message});
        } else {
            failed = true;
            try out.print("xqt gen {t}: {s}\n", .{ j.name, std.mem.trimEnd(u8, j.message, "\n") });
        }
    }
    try out.flush();
    return @intFromBool(failed);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

fn runJob(jobs: []Job, i: usize) void {
    const j = &jobs[i];
    var arena_state: std.heap.ArenaAllocator = .init(j.ctx.gpa);
    defer arena_state.deinit();
    var g: Gen = .{ .ctx = j.ctx, .arena = arena_state.allocator() };
    const result = switch (j.name) {
        .fixtures => g.fixtures(),
    };
    // The message outlives the job's arena.
    const keep = std.heap.page_allocator;
    if (result) |msg| {
        j.ok = true;
        j.message = keep.dupe(u8, msg) catch "";
    } else |err| {
        j.message = keep.dupe(u8, if (err == error.StepFailed) g.failure else @errorName(err)) catch "";
    }
}

const Gen = struct {
    ctx: *const Ctx,
    arena: Allocator,
    /// Why a step failed.
    failure: []const u8 = "",

    fn root(g: *Gen, rel: []const u8) ![]const u8 {
        return std.fs.path.join(g.arena, &.{ g.ctx.cfg.root, rel });
    }

    /// Runs `argv` in `cwd`, which must succeed (set -e); returns its
    /// standard output.
    fn step(g: *Gen, argv: []const []const u8, opts: struct { cwd: ?[]const u8 = null, stdin: ?[]const u8 = null }) ![]const u8 {
        const r = try xqt.proc.run(g.arena, g.ctx.io, argv, .{ .cwd = opts.cwd, .stdin = opts.stdin });
        if (r.ok()) return r.stdout;
        var w: Io.Writer.Allocating = .init(g.arena);
        for (argv, 0..) |a, i| try w.writer.print("{s}{s}", .{ if (i > 0) " " else "", a });
        try w.writer.print(": {f}\n{s}", .{ r, r.stderr });
        g.failure = w.written();
        return error.StepFailed;
    }

    /// The databases in pkg/storage/src/testdata (for the b-tree tests) and
    /// src/testdata, made with the sqlite3 shell. The content is
    /// deterministic; tests check it against the same formulas.
    fn fixtures(g: *Gen) ![]const u8 {
        const storage_dir = try g.root("pkg/storage/src/testdata");
        try g.fixture(storage_dir, "btree.db", try btreeSql(g.arena, 0));
        try g.fixture(storage_dir, "autovacuum.db", try btreeSql(g.arena, 1));
        const dir = try g.root("src/testdata");
        // The schema and rows src/sql/sql_test.zig queries.
        const sql_db = try std.fs.path.join(g.arena, &.{ dir, "sql.db" });
        Io.Dir.cwd().deleteFile(g.ctx.io, sql_db) catch {};
        _ = try g.step(&.{ g.ctx.fixtures_sqlite3, "sql.db" }, .{ .cwd = dir, .stdin = sql_fixture });
        return "wrote pkg/storage/src/testdata/btree.db, autovacuum.db, src/testdata/sql.db";
    }

    fn fixture(g: *Gen, dir: []const u8, file: []const u8, sql: []const u8) !void {
        Io.Dir.cwd().deleteFile(g.ctx.io, try std.fs.path.join(g.arena, &.{ dir, file })) catch {};
        _ = try g.step(&.{ g.ctx.fixtures_sqlite3, file }, .{ .cwd = dir, .stdin = sql });
        const ok = try g.step(&.{ g.ctx.fixtures_sqlite3, file, "PRAGMA integrity_check" }, .{ .cwd = dir });
        // grep -qx ok
        var it = std.mem.splitScalar(u8, ok, '\n');
        while (it.next()) |line| if (std.mem.eql(u8, line, "ok")) return;
        g.failure = try std.fmt.allocPrint(g.arena, "{s}: integrity_check: {s}", .{ file, ok });
        return error.StepFailed;
    }
};

/// btree.db and autovacuum.db: `auto_vacuum` is 0 or 1. Some builds
/// (Android's) default to auto_vacuum=1, so it is always set explicitly.
fn btreeSql(arena: Allocator, auto_vacuum: u1) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\PRAGMA page_size=1024;
        \\PRAGMA auto_vacuum={d};
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB, d REAL);
        \\CREATE INDEX t_b ON t(b);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1000)
        \\INSERT INTO t
        \\  SELECT i,
        \\         printf('row-%05d', (i*7919)%1000),
        \\         CASE WHEN i%97=0 THEN cast(printf('%.*c', 2000+i, char(65+i%26)) AS BLOB)
        \\              ELSE cast(i*i AS TEXT) END,
        \\         i*0.5
        \\  FROM n;
        \\DELETE FROM t WHERE a%5=0 OR a BETWEEN 300 AND 420;
        \\
    , .{auto_vacuum});
}

const sql_fixture =
    \\CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c REAL);
    \\INSERT INTO t1 VALUES(1,'one',1.5),(2,'two',2.5),(3,'three',NULL),(4,'four',4.0),(5,'five',-1);
    \\CREATE INDEX t1_b ON t1(b);
    \\CREATE TABLE t2(x, y);
    \\INSERT INTO t2 VALUES(1,'a'),(2,'b'),(2,'c'),(9,'z');
    \\CREATE TABLE wr(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID;
    \\INSERT INTO wr VALUES('b',2),('a',1),('c',3);
    \\
;
