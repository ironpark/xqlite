//! `xqt bench [WORKLOAD...]`: times the same workloads in xqlite and
//! sqlite3 and prints both, with the ratio. Each workload runs RUNS times
//! (default 3) and the fastest run counts. Build xqlite first with
//! `zig build -Doptimize=ReleaseFast`. (Was tools/bench.sh.)
//!
//! The workloads run one after the other, never in parallel, so that they
//! do not slow each other down. A run is timed from the start of the
//! program to its end, as the script did (without the script's own
//! overhead of starting python3 around it).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");

pub const usage =
    \\usage: xqt bench [--runs N] [--rows N] [WORKLOAD...]   (default: all)
    \\
    \\Times each workload in xqlite (--xq, $XQ) and sqlite3 (--sqlite3,
    \\$SQLITE3) and prints the fastest of N runs (--runs or $RUNS, default 3)
    \\in seconds, and their ratio. --rows or $ROWS sets the table size
    \\(default 1000000). Build xqlite with -Doptimize=ReleaseFast first.
    \\
;

const Needs = enum {
    /// An empty file.
    empty,
    /// The filled table t.
    filled,
    /// The column-heavy tables w and o.
    wide,
};

const Workload = struct {
    name: []const u8,
    needs: Needs,
    sql: []const u8,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runs: u64 = try envNumber(cfg, "RUNS", 3);
    var rows: u64 = try envNumber(cfg, "ROWS", 1000000);
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if ((std.mem.eql(u8, a, "--runs") or std.mem.eql(u8, a, "--rows")) and i + 1 < args.len) {
            i += 1;
            const v = std.fmt.parseUnsigned(u64, args[i], 10) catch return usageError(out);
            if (a[4] == 'n') runs = v else rows = v;
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(out);
        } else {
            try names.append(arena, a);
        }
    }

    const fill = try std.fmt.allocPrint(arena, "CREATE TABLE t(a INTEGER PRIMARY KEY, b INT, c TEXT); BEGIN; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<{d}) INSERT INTO t SELECT i, i*7%1000, 'row'||i FROM r; COMMIT;", .{rows});
    // Column-heavy tables: w has 20 columns, the rows of o spill onto
    // overflow pages (b is larger than a page, c comes after it).
    var wcols: Io.Writer.Allocating = .init(arena);
    var wvals: Io.Writer.Allocating = .init(arena);
    for (1..21) |k| {
        const sep = if (k > 1) ", " else "";
        try wcols.writer.print("{s}c{d} INT", .{ sep, k });
        try wvals.writer.print("{s}i*{d}%1000", .{ sep, k });
    }
    const fill2 = try std.fmt.allocPrint(arena, "CREATE TABLE w({s}); CREATE TABLE o(a INTEGER PRIMARY KEY, b BLOB, c INT); BEGIN; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<{d}) INSERT INTO w SELECT {s} FROM r; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<{d}) INSERT INTO o SELECT i, zeroblob(6000), i FROM r; COMMIT;", .{ wcols.written(), rows / 2, wvals.written(), rows / 100 });

    const workloads = [_]Workload{
        .{ .name = "insert", .needs = .empty, .sql = fill },
        .{ .name = "index", .needs = .filled, .sql = "CREATE INDEX tb ON t(b);" },
        .{ .name = "scan", .needs = .filled, .sql = "SELECT count(*), sum(b), max(length(c)) FROM t;" },
        .{ .name = "groupby", .needs = .filled, .sql = "SELECT b, count(*) FROM t GROUP BY b ORDER BY 2 DESC LIMIT 3;" },
        .{ .name = "sort", .needs = .filled, .sql = "SELECT sum(x) FROM (SELECT a+b AS x FROM t ORDER BY c LIMIT 100000);" },
        .{ .name = "pklookup", .needs = .filled, .sql = "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<200000) SELECT sum((SELECT c FROM t WHERE a=i*3) IS NOT NULL) FROM r;" },
        .{ .name = "update", .needs = .filled, .sql = "CREATE INDEX tb ON t(b); UPDATE t SET b=b+1 WHERE a%3=0;" },
        .{ .name = "delete", .needs = .filled, .sql = "DELETE FROM t WHERE a%5=0;" },
        .{ .name = "cte", .needs = .empty, .sql = "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<5000000) SELECT sum(i*2+1), max(i%7) FROM r;" },
        .{ .name = "printf", .needs = .filled, .sql = "SELECT sum(length(printf('%d-%s', a, c))) FROM t;" },
        .{ .name = "json", .needs = .filled, .sql = "SELECT sum(length(json_object('a',a,'b',c))) FROM t;" },
        .{ .name = "window", .needs = .filled, .sql = "SELECT sum(r) FROM (SELECT row_number() OVER (PARTITION BY b ORDER BY a) r FROM t);" },
        .{ .name = "wide", .needs = .wide, .sql = "SELECT sum(c20), sum(c19) FROM w;" },
        .{ .name = "overflow", .needs = .wide, .sql = "SELECT sum(length(b)), sum(c) FROM o;" },
    };

    const dir = try std.fmt.allocPrint(arena, "{s}/bench", .{cfg.tmp});
    try Io.Dir.cwd().createDirPath(io, dir);
    defer {
        Io.Dir.cwd().deleteTree(io, dir) catch {};
        Io.Dir.cwd().deleteDir(io, cfg.tmp) catch {};
    }
    var b: Bench = .{ .gpa = gpa, .arena = arena, .io = io, .cfg = cfg, .out = out, .dir = dir, .runs = runs };

    // The two starting databases, built by sqlite3 at once.
    var setups = [_]Setup{ .{ .b = &b, .db = "base.db", .sql = fill }, .{ .b = &b, .db = "base2.db", .sql = fill2 } };
    xqt.pool.forEach(2, setups.len, &setups, Setup.run);
    for (setups) |s| if (s.err) |e| {
        try out.print("xqt bench: {s}: {s}\n", .{ s.db, e });
        return 1;
    };

    try out.print("{s:<10} {s:>8} {s:>8} {s:>6}\n", .{ "workload", "xqlite", "sqlite3", "ratio" });
    try out.flush();
    for (workloads) |w| {
        if (names.items.len > 0 and !contains(names.items, w.name)) continue;
        const x = b.best(&.{ cfg.xq, "sql" }, w) catch |err| return b.failed(w, "xqlite", err);
        const s = b.best(&.{cfg.sqlite3}, w) catch |err| return b.failed(w, "sqlite3", err);
        const xs = try std.fmt.allocPrint(arena, "{d:.3}", .{x});
        const ss = try std.fmt.allocPrint(arena, "{d:.3}", .{s});
        const ratio = if (s == 0) try arena.dupe(u8, "-") else try std.fmt.allocPrint(arena, "{d:.2}", .{x / s});
        try out.print("{s:<10} {s:>8} {s:>8} {s:>6}\n", .{ w.name, xs, ss, ratio });
        try out.flush();
    }
    return 0;
}

const Setup = struct {
    b: *Bench,
    db: []const u8,
    sql: []const u8,
    err: ?[]const u8 = null,

    fn run(setups: *[2]Setup, i: usize) void {
        const s = &setups[i];
        s.err = s.b.sqlite3(s.db, s.sql) catch |err| @errorName(err);
    }
};

const Bench = struct {
    gpa: Allocator,
    /// Used by one thread at a time (the setups use `gpa`).
    arena: Allocator,
    io: Io,
    cfg: *const xqt.Config,
    out: *Io.Writer,
    dir: []const u8,
    runs: u64,
    /// The standard error of the last run that failed.
    stderr: []const u8 = "",

    /// Builds `db` with sqlite3; the error text if it fails.
    fn sqlite3(b: *Bench, db: []const u8, sql: []const u8) !?[]const u8 {
        const path = try std.fs.path.join(b.gpa, &.{ b.dir, db });
        defer b.gpa.free(path);
        const r = try xqt.proc.run(b.gpa, b.io, &.{ b.cfg.sqlite3, path, sql }, .{ .cwd = b.dir });
        defer b.gpa.free(r.stdout);
        if (r.ok()) {
            b.gpa.free(r.stderr);
            return null;
        }
        return r.stderr;
    }

    /// The fastest of `runs` runs of `engine W.db SQL`, in seconds, each
    /// on a fresh copy of the database it needs. As the script, the best
    /// so far is kept rounded to milliseconds and compared unrounded.
    fn best(b: *Bench, engine: []const []const u8, w: Workload) !f64 {
        const db = try std.fs.path.join(b.arena, &.{ b.dir, "w.db" });
        var kept: ?f64 = null;
        for (0..b.runs) |_| {
            for ([_][]const u8{ "", "-journal", "-wal", "-shm" }) |suffix| {
                const p = try std.mem.concat(b.arena, u8, &.{ db, suffix });
                Io.Dir.cwd().deleteFile(b.io, p) catch {};
            }
            const from: ?[]const u8 = switch (w.needs) {
                .empty => null,
                .filled => "base.db",
                .wide => "base2.db",
            };
            if (from) |f| {
                const src = try std.fs.path.join(b.arena, &.{ b.dir, f });
                try Io.Dir.cwd().copyFile(src, .cwd(), db, b.io, .{});
            }
            const argv = try std.mem.concat(b.arena, []const u8, &.{ engine, &.{ db, w.sql } });
            const start = Io.Clock.awake.now(b.io);
            const r = try xqt.proc.run(b.arena, b.io, argv, .{ .cwd = b.dir });
            const ns = start.durationTo(Io.Clock.awake.now(b.io)).toNanoseconds();
            if (!r.ok()) {
                b.stderr = r.stderr;
                return error.RunFailed;
            }
            const t = @as(f64, @floatFromInt(ns)) / 1e9;
            if (kept == null or t < kept.?) kept = round3(t);
        }
        return kept orelse 0;
    }

    fn failed(b: *Bench, w: Workload, engine: []const u8, err: anyerror) !u8 {
        try b.out.print("xqt bench: {s} failed in {s}: {t}\n{s}", .{ w.name, engine, err, b.stderr });
        try b.out.flush();
        return 1;
    }
};

/// `t` as f'{t:.3f}' prints it, read back.
fn round3(t: f64) f64 {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.3}", .{t}) catch return t;
    return std.fmt.parseFloat(f64, s) catch t;
}

fn envNumber(cfg: *const xqt.Config, name: []const u8, default: u64) !u64 {
    const v = cfg.environ.get(name) orelse return default;
    return std.fmt.parseUnsigned(u64, v, 10) catch error.Usage;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}
