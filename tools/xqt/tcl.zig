//! `xqt tcl [options] [PATH...]`: SQLite's own TCL test suite
//! (ref/sqlite/test) with the test fixture of `zig build testfixture`,
//! once on libxqlite3 and once on SQLite 3.54.1 built the same way
//! (tools/tcl/README.md). Every test file runs in its own directory, one
//! process per file and fixture, in parallel, with a time limit. The
//! outcome of each test case (do_test and the procs built on it) is
//! compared between the two: passes on both, fails on both (the harness
//! cannot pass it), or fails only on xqlite (an incompatibility), and the
//! last are grouped by cause.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt tcl [options] [PATH...]   (PATH: a .test file or a directory;
    \\                                      default: the set below in ref/sqlite/test)
    \\
    \\  --set NAME     all (default): every test/*.test but the scripts that run
    \\                 other files; veryquick, quick: as test/permutations.test
    \\                 defines them
    \\  --timeout S    seconds per test file and fixture (default 300)
    \\  --fixture P    testfixture on libxqlite3 (default zig-out/bin/testfixture-xqlite)
    \\  --ref P        testfixture on SQLite (default zig-out/bin/testfixture-sqlite)
    \\  --no-ref       run xqlite only (no classification)
    \\  --faultsim     let tester.tcl install its OOM-injecting malloc wrapper
    \\                 (XQTCL_FAULTSIM=1; off, the OOM tests fail on both)
    \\  --tcl-library D  Tcl's script library (default ref/tcl/lib/tcl8.6)
    \\  --log FILE     write every file's outcome and every failing test to FILE
    \\  --top N        causes to list (default 40)
    \\
    \\Build first: zig build testfixture (needs xqt fetch sqlite, xqt fetch tcl).
    \\
;

const Engine = enum { xqlite, sqlite };

const Status = enum {
    /// Ran to finish_test, no failures.
    ok,
    /// Ran to finish_test with failures.
    fail,
    /// The script stopped with a Tcl error before finish_test.
    @"error",
    /// Killed by a signal.
    crash,
    timeout,
    /// Did not run (--no-ref).
    none,

    /// Whether the file stopped before finish_test.
    fn stopped(st: Status) bool {
        return st == .@"error" or st == .crash or st == .timeout;
    }
};

const Failure = struct {
    name: []const u8,
    /// "Error: ..." (the test's script raised it), or empty.
    err: []const u8 = "",
    expected: []const u8 = "",
    got: []const u8 = "",
};

const Run = struct {
    status: Status = .none,
    /// "N errors out of M tests": M (test cases run).
    total: u64 = 0,
    passed: []const []const u8 = &.{},
    failed: []const Failure = &.{},
    /// Why the script stopped (error, crash), its first line.
    reason: []const u8 = "",
    /// "Unfreed memory: ..." at the end.
    leak: []const u8 = "",
    ms: i64 = 0,
};

const FileResult = struct {
    path: []const u8,
    runs: std.EnumArray(Engine, Run) = .initFill(.{}),
};

const Ctx = struct {
    timeout_ms: i64,
    fixtures: std.EnumArray(Engine, ?[]const u8),
    env: *const std.process.Environ.Map,
    n_jobs: usize,
    done: std.atomic.Value(usize) = .init(0),
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    var set: []const u8 = "all";
    var timeout_s: i64 = 300;
    var fixture: []const u8 = try std.fs.path.join(arena, &.{ cfg.root, "zig-out", "bin", "testfixture-xqlite" });
    var ref: ?[]const u8 = try std.fs.path.join(arena, &.{ cfg.root, "zig-out", "bin", "testfixture-sqlite" });
    var faultsim = false;
    var tcl_library: []const u8 = try std.fs.path.join(arena, &.{ cfg.root, "ref", "tcl", "lib", "tcl8.6" });
    var log_path: ?[]const u8 = null;
    var top: usize = 40;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--set") and has_value) {
            i += 1;
            set = args[i];
        } else if (std.mem.eql(u8, a, "--timeout") and has_value) {
            i += 1;
            timeout_s = std.fmt.parseInt(i64, args[i], 10) catch return usageError(out);
        } else if (std.mem.eql(u8, a, "--fixture") and has_value) {
            i += 1;
            fixture = try xqt.Config.absolute(arena, io, args[i]);
        } else if (std.mem.eql(u8, a, "--ref") and has_value) {
            i += 1;
            ref = try xqt.Config.absolute(arena, io, args[i]);
        } else if (std.mem.eql(u8, a, "--no-ref")) {
            ref = null;
        } else if (std.mem.eql(u8, a, "--faultsim")) {
            faultsim = true;
        } else if (std.mem.eql(u8, a, "--tcl-library") and has_value) {
            i += 1;
            tcl_library = try xqt.Config.absolute(arena, io, args[i]);
        } else if (std.mem.eql(u8, a, "--log") and has_value) {
            i += 1;
            log_path = args[i];
        } else if (std.mem.eql(u8, a, "--top") and has_value) {
            i += 1;
            top = std.fmt.parseUnsigned(usize, args[i], 10) catch return usageError(out);
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(out);
        } else {
            try paths.append(arena, try xqt.Config.absolute(arena, io, a));
        }
    }
    for ([_]?[]const u8{ fixture, ref, tcl_library }) |p| {
        const path = p orelse continue;
        if (!xqt.Config.exists(io, path)) {
            try out.print("xqt tcl: no {s} (zig build testfixture; xqt fetch tcl)\n", .{path});
            try out.flush();
            return 2;
        }
    }

    var files: std.ArrayList([]const u8) = .empty;
    if (paths.items.len == 0) {
        const dir = try std.fs.path.join(arena, &.{ cfg.root, "ref", "sqlite", "test" });
        const filter: Filter = if (std.mem.eql(u8, set, "all"))
            .all
        else if (std.mem.eql(u8, set, "quick"))
            .quick
        else if (std.mem.eql(u8, set, "veryquick"))
            .veryquick
        else
            return usageError(out);
        try testFiles(arena, io, dir, &files, filter);
    } else {
        for (paths.items) |p| try testFiles(arena, io, p, &files, .none);
    }
    if (files.items.len == 0) {
        try out.writeAll("xqt tcl: no test files\n");
        try out.flush();
        return 2;
    }

    const env = try arena.create(std.process.Environ.Map);
    env.* = try cfg.environ.clone(arena);
    try env.put("TCL_LIBRARY", tcl_library);
    try env.put("XQTCL_FAULTSIM", if (faultsim) "1" else "0");

    const results = try arena.alloc(FileResult, files.items.len);
    for (results, files.items) |*r, f| r.* = .{ .path = f };
    var ctx: Ctx = .{
        .timeout_ms = timeout_s * std.time.ms_per_s,
        .fixtures = .init(.{ .xqlite = fixture, .sqlite = ref }),
        .env = env,
        .n_jobs = files.items.len * @as(usize, if (ref != null) 2 else 1),
    };
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "tcl", .show = .none });
    defer suite.deinit();
    for (results) |*r| {
        for ([_]Engine{ .xqlite, .sqlite }) |e| {
            if (ctx.fixtures.get(e) == null) continue;
            try suite.add(r.path, runFile, .{ &ctx, e, r });
        }
    }
    suite.run();

    var log: ?Io.File = null;
    var log_buffer: [4096]u8 = undefined;
    var log_writer: Io.File.Writer = undefined;
    if (log_path) |p| {
        log = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
        log_writer = log.?.writer(io, &log_buffer);
    }
    defer if (log) |f| f.close(io);
    const lw: ?*Io.Writer = if (log != null) &log_writer.interface else null;
    const code = try summarize(arena, out, lw, results, ref != null, top, suite.elapsed_ms);
    if (lw) |w| try w.flush();
    try out.flush();
    return code;
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    try out.flush();
    return 2;
}

// ---------------------------------------------------------------- test files

const Filter = enum { none, all, quick, veryquick };

/// Scripts that run other test files, or are not tests (permutations.test
/// `alltests` -exclude).
const not_tests = [_][]const u8{
    "all.test",          "quick.test", "veryquick.test",  "memleak.test",
    "permutations.test", "soak.test",  "fts3.test",       "mallocAll.test",
    "rtree.test",        "full.test",  "extraquick.test", "session.test",
    "rbu.test",
};

/// permutations.test: `allquicktests`, the slow files left out of quick.
const not_quick = [_][]const u8{
    "backup_ioerr.test", "corrupt.test",     "corruptC.test",         "crash.test",
    "crash2.test",       "crash3.test",      "crash4.test",           "crash5.test",
    "crash6.test",       "crash7.test",      "crash9.test",           "delete3.test",
    "e_fts3.test",       "fts3rnd.test",     "fkey_malloc.test",      "fuzz.test",
    "fuzz3.test",        "fuzz_malloc.test", "in2.test",              "loadext.test",
    "misc7.test",        "mutex2.test",      "onefile.test",          "pagerfault2.test",
    "savepoint4.test",   "savepoint6.test",  "select9.test",          "speed1.test",
    "speed1p.test",      "speed2.test",      "speed3.test",           "speed4.test",
    "speed4p.test",      "sqllimits1.test",  "tkt2686.test",          "thread001.test",
    "thread002.test",    "thread003.test",   "thread004.test",        "thread005.test",
    "trans2.test",       "vacuum3.test",     "incrvacuum_ioerr.test", "autovacuum_crash.test",
    "btree8.test",       "shared_err.test",  "vtab_err.test",         "walslow.test",
    "walcrash.test",     "walcrash3.test",   "walthread.test",        "rtree3.test",
    "indexfault.test",   "securedel2.test",  "sort3.test",            "sort4.test",
    "fts4growth.test",   "fts4growth2.test", "bigsort.test",          "walprotocol.test",
    "mmap4.test",        "fuzzer2.test",     "walcrash2.test",        "e_fkey.test",
    "backup.test",       "fts4merge.test",   "fts4merge2.test",       "fts4merge4.test",
    "fts4check.test",    "fts4merge5.test",  "fts3cov.test",          "fts3snippet.test",
    "fts3corrupt2.test", "fts3an.test",      "fts3defer.test",        "fts4langid.test",
    "fts3sort.test",     "fts5unicode.test", "recovercorrupt.test",   "rtree4.test",
    "sessionbig.test",   "sessionbig2.test", "writecrash.test",       "view3.test",
    "fts5dlidx.test",    "fts5ac.test",      "fts4merge3.test",       "fts5prefix.test",
    "fts5bigtok2.test",  "fts5secure7.test", "sessionB.test",
};

/// permutations.test: veryquick is quick without these patterns.
const not_veryquick = [_][]const u8{ "malloc", "ioerr", "fault", "bigfile", "_err", "fts5corrupt", "fts5big", "fts5aj", "rbucrash" };

fn wanted(name: []const u8, filter: Filter) bool {
    if (!std.mem.endsWith(u8, name, ".test")) return false;
    if (filter == .none) return true;
    for (not_tests) |n| if (std.mem.eql(u8, n, name)) return false;
    if (filter == .all) return true;
    for (not_quick) |n| if (std.mem.eql(u8, n, name)) return false;
    if (filter == .quick) return true;
    for (not_veryquick) |p| if (std.mem.indexOf(u8, name, p) != null) return false;
    return true;
}

/// A .test file, or the .test files in a directory (not below), sorted.
fn testFiles(arena: Allocator, io: Io, path: []const u8, files: *std.ArrayList([]const u8), filter: Filter) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return files.append(arena, path),
        else => |e| return e,
    };
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and wanted(e.name, filter))
            try found.append(arena, try std.fs.path.join(arena, &.{ path, e.name }));
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f);
    try files.appendSlice(arena, found.items);
}

// ---------------------------------------------------------------- running

fn runFile(c: *Check, ctx: *Ctx, engine: Engine, res: *FileResult) !void {
    const fixture = ctx.fixtures.get(engine).?;
    const start = Io.Clock.awake.now(c.io);
    const r = c.run(&.{ fixture, res.path }, .{ .env = ctx.env, .timeout_ms = ctx.timeout_ms }) catch |err| {
        // Not the fixture's outcome (too many processes, no memory):
        // counted as a file that stopped, with the reason.
        res.runs.set(engine, .{ .status = .@"error", .reason = try std.fmt.allocPrint(c.keep, "xqt could not run the fixture: {t}", .{err}) });
        c.printNow("{t} {s}: xqt could not run the fixture: {t}", .{ engine, std.fs.path.basename(res.path), err });
        return;
    };
    var parsed = try parse(c.keep, r);
    parsed.ms = start.durationTo(Io.Clock.awake.now(c.io)).toMilliseconds();
    res.runs.set(engine, parsed);
    const n = ctx.done.fetchAdd(1, .monotonic) + 1;
    if (parsed.status != .ok or n % 100 == 0)
        c.printNow("[{d}/{d}] {t} {s} {s} ({d} failed of {d}, {d} ms){s}{s}", .{
            n,                 ctx.n_jobs,   engine,    upper(parsed.status),                    std.fs.path.basename(res.path),
            parsed.failed.len, parsed.total, parsed.ms, if (parsed.reason.len > 0) ": " else "", firstLine(parsed.reason, 100),
        });
}

fn upper(s: Status) []const u8 {
    return switch (s) {
        .ok => "OK",
        .fail => "FAIL",
        .@"error" => "ERROR",
        .crash => "CRASH",
        .timeout => "TIMEOUT",
        .none => "-",
    };
}

fn firstLine(s: []const u8, max: usize) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, max)];
}

/// The output of tester.tcl at --verbose=1 (its default):
///
///     NAME... Ok
///     NAME...
///     ! NAME expected: [E]
///     ! NAME got:      [G]
///     NAME...
///     Error: MESSAGE
///     N errors out of M tests on HOST ...
///     Unfreed memory: N bytes in K allocations
///
/// A Tcl error that ends the script is on standard error as
/// "FIXTURE: MESSAGE" with the stack after it.
fn parse(keep: Allocator, r: xqt.proc.Result) !Run {
    var res: Run = .{};
    var passed: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(Failure) = .empty;
    var current: []const u8 = "";
    var finished = false;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "! ")) {
            // "! NAME expected: [E]" / "! NAME got:      [G]"
            const rest = line[2..];
            if (std.mem.indexOf(u8, rest, " expected: ")) |k| {
                try failed.append(keep, .{
                    .name = try keep.dupe(u8, rest[0..k]),
                    .expected = try keep.dupe(u8, bracketed(rest[k + " expected: ".len ..])),
                });
            } else if (std.mem.indexOf(u8, rest, " got: ")) |k| {
                if (failed.items.len > 0 and std.mem.eql(u8, failed.items[failed.items.len - 1].name, rest[0..k]))
                    failed.items[failed.items.len - 1].got = try keep.dupe(u8, bracketed(std.mem.trimStart(u8, rest[k + " got: ".len ..], " ")));
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "Error: ") and current.len > 0) {
            try failed.append(keep, .{ .name = try keep.dupe(u8, current), .err = try keep.dupe(u8, line["Error: ".len..]) });
            current = "";
            continue;
        }
        if (parseSummary(line)) |total| {
            res.total = total;
            finished = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Unfreed memory: ")) {
            res.leak = try keep.dupe(u8, line);
            continue;
        }
        // "NAME... Ok", or "NAME..." and what the test printed.
        if (std.mem.indexOf(u8, line, "...")) |k| {
            if (k > 0 and std.mem.indexOfAny(u8, line[0..k], " \t") == null) {
                const after = line[k + 3 ..];
                if (std.mem.endsWith(u8, after, " Ok")) {
                    try passed.append(keep, try keep.dupe(u8, line[0..k]));
                    current = "";
                } else if (std.mem.eql(u8, after, " Omitted")) {
                    current = "";
                } else {
                    current = line[0..k];
                }
                continue;
            }
        }
        if (std.mem.endsWith(u8, line, " Ok") and current.len > 0) {
            // The test printed something between "NAME..." and " Ok".
            try passed.append(keep, try keep.dupe(u8, current));
            current = "";
        }
    }
    res.passed = passed.items;
    res.failed = failed.items;
    if (r.timedOut()) {
        res.status = .timeout;
        if (current.len > 0) res.reason = try std.fmt.allocPrint(keep, "during {s}", .{current});
    } else if (r.exitCode() == null) {
        res.status = .crash;
        res.reason = if (panicAt(keep, r.stderr)) |p|
            try std.fmt.allocPrint(keep, "panic: {s} at {s}{s}{s}", .{ p[0], p[1], if (current.len > 0) " during " else "", current })
        else
            try std.fmt.allocPrint(keep, "{f}{s}{s}{s}{s}", .{
                r,
                if (current.len > 0) " during " else "",
                current,
                if (std.mem.trim(u8, r.stderr, " \t\r\n").len > 0) ": " else "",
                firstLine(std.mem.trim(u8, r.stderr, " \t\r\n"), 120),
            });
    } else if (!finished) {
        res.status = .@"error";
        res.reason = try keep.dupe(u8, scriptError(r.stderr, r.stdout));
    } else {
        res.status = if (failed.items.len > 0) .fail else .ok;
    }
    return res;
}

/// A Zig panic of the ReleaseSafe libxqlite3 on standard error:
///
///     thread 123 panic: index out of bounds: index 1, len 1
///     /path/src/sql/insert.zig:711:16: 0x10491111b in insertImpl (xqlite3)
///
/// -> {"index out of bounds: index N, len N", "insertImpl (insert.zig:711)"}.
fn panicAt(a: Allocator, stderr: []const u8) ?[2][]const u8 {
    const k = std.mem.indexOf(u8, stderr, "panic: ") orelse return null;
    const msg = firstLine(stderr[k + "panic: ".len ..], 200);
    var it = std.mem.splitScalar(u8, stderr[k..], '\n');
    _ = it.next();
    while (it.next()) |line| {
        // The first frame in the engine's sources.
        const in = std.mem.indexOf(u8, line, " in ") orelse continue;
        const src = std.mem.indexOf(u8, line, "/src/") orelse std.mem.indexOf(u8, line, "/pkg/") orelse continue;
        if (src > in) continue;
        const loc = line[src + 1 .. std.mem.indexOfScalarPos(u8, line, src, ':') orelse continue];
        const func_end = std.mem.indexOfScalarPos(u8, line, in + 4, ' ') orelse line.len;
        const after_loc = line[src + 1 + loc.len + 1 ..];
        const lineno = after_loc[0 .. std.mem.indexOfScalar(u8, after_loc, ':') orelse after_loc.len];
        const where = std.fmt.allocPrint(a, "{s} ({s}:{s})", .{ line[in + 4 .. func_end], std.fs.path.basename(loc), lineno }) catch return null;
        return .{ msg, where };
    }
    return .{ msg, "?" };
}

/// "[TEXT]" -> "TEXT"
fn bracketed(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') return s[1 .. s.len - 1];
    return s;
}

/// "N errors out of M tests on ..." -> M
fn parseSummary(line: []const u8) ?u64 {
    const k = std.mem.indexOf(u8, line, " errors out of ") orelse return null;
    for (line[0..k]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const rest = line[k + " errors out of ".len ..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    if (!std.mem.startsWith(u8, rest[sp..], " tests")) return null;
    return std.fmt.parseUnsigned(u64, rest[0..sp], 10) catch null;
}

/// The message of the Tcl error that ended a script: testfixture prints
/// "ARGV0: MESSAGE" and the stack on standard error. Else the last
/// line of standard output.
fn scriptError(stderr: []const u8, stdout: []const u8) []const u8 {
    const err = std.mem.trim(u8, stderr, " \t\r\n");
    if (err.len > 0) {
        var line = firstLine(err, err.len);
        // "/path/testfixture-xqlite: message"
        if (std.mem.indexOf(u8, line, "testfixture-")) |k| {
            if (std.mem.indexOfPos(u8, line, k, ": ")) |colon| line = line[colon + 2 ..];
        }
        return line;
    }
    const o = std.mem.trimEnd(u8, stdout, " \t\r\n");
    const nl = std.mem.lastIndexOfScalar(u8, o, '\n');
    return if (nl) |n| o[n + 1 ..] else o;
}

// ---------------------------------------------------------------- results

const Class = enum { pass_both, fail_both, xqlite_only, sqlite_only, sqlite_ran_only, xqlite_ran_only };

/// A cause: how many tests (or files), in how many test files, and one example.
const Cause = struct { n: usize = 0, files: usize = 0, last_file: []const u8 = "", example: []const u8 = "" };

fn summarize(arena: Allocator, out: *Io.Writer, log: ?*Io.Writer, results: []FileResult, with_ref: bool, top: usize, ms: i64) !u8 {
    var by_status: std.EnumArray(Engine, std.EnumArray(Status, usize)) = .initFill(.initFill(0));
    var passed: std.EnumArray(Engine, u64) = .initFill(0);
    var failed: std.EnumArray(Engine, u64) = .initFill(0);
    var leaks: std.EnumArray(Engine, usize) = .initFill(0);
    var classes: std.EnumArray(Class, u64) = .initFill(0);
    var causes: std.StringArrayHashMapUnmanaged(Cause) = .empty;
    var stops: std.StringArrayHashMapUnmanaged(Cause) = .empty;
    var files_xq_only: usize = 0;
    var by_file: std.StringArrayHashMapUnmanaged(Cause) = .empty;

    for (results) |*f| {
        const name = std.fs.path.basename(f.path);
        for ([_]Engine{ .xqlite, .sqlite }) |e| {
            const r = f.runs.get(e);
            if (r.status == .none) continue;
            by_status.getPtr(e).getPtr(r.status).* += 1;
            passed.getPtr(e).* += r.passed.len;
            failed.getPtr(e).* += r.failed.len;
            if (r.leak.len > 0) leaks.getPtr(e).* += 1;
        }
        const xq = f.runs.get(.xqlite);
        const sq = f.runs.get(.sqlite);
        if (log) |w| {
            try w.print("{s}: xqlite {s} ({d}/{d} failed, {d} ms){s}{s}", .{ name, upper(xq.status), xq.failed.len, xq.total, xq.ms, if (xq.reason.len > 0) ": " else "", firstLine(xq.reason, 200) });
            if (with_ref) try w.print("; sqlite {s} ({d}/{d} failed, {d} ms){s}{s}", .{ upper(sq.status), sq.failed.len, sq.total, sq.ms, if (sq.reason.len > 0) ": " else "", firstLine(sq.reason, 200) });
            try w.writeAll("\n");
            if (xq.leak.len > 0) try w.print("  xqlite: {s}\n", .{xq.leak});
            if (sq.leak.len > 0) try w.print("  sqlite: {s}\n", .{sq.leak});
        }
        if (!with_ref) {
            for (xq.failed) |fl| {
                try count(arena, &causes, try cause(arena, fl), try example(arena, name, fl), name);
                if (log) |w| try logFailure(w, "FAIL", fl);
            }
            if (xq.status.stopped())
                try count(arena, &stops, try stopCause(arena, xq), name, name);
            continue;
        }

        // Test names: a name that fails anywhere in a file counts as failed.
        var sq_names: std.StringHashMapUnmanaged(bool) = .empty; // name -> failed
        for (sq.passed) |n| try sq_names.put(arena, n, (sq_names.get(n) orelse false));
        for (sq.failed) |fl| try sq_names.put(arena, fl.name, true);
        var xq_names: std.StringArrayHashMapUnmanaged(?Failure) = .empty; // name -> first failure
        for (xq.passed) |n| {
            const gop = try xq_names.getOrPut(arena, n);
            if (!gop.found_existing) gop.value_ptr.* = null;
        }
        for (xq.failed) |fl| {
            const gop = try xq_names.getOrPut(arena, fl.name);
            if (!gop.found_existing or gop.value_ptr.* == null) gop.value_ptr.* = fl;
        }
        var it = xq_names.iterator();
        while (it.next()) |kv| {
            const xq_failed = kv.value_ptr.* != null;
            const class: Class = if (sq_names.get(kv.key_ptr.*)) |sq_failed|
                (if (xq_failed and sq_failed) .fail_both else if (xq_failed) .xqlite_only else if (sq_failed) .sqlite_only else .pass_both)
            else
                .xqlite_ran_only;
            classes.getPtr(class).* += 1;
            if (class == .xqlite_only or (class == .xqlite_ran_only and xq_failed)) {
                const fl = kv.value_ptr.*.?;
                try count(arena, &causes, try cause(arena, fl), try example(arena, name, fl), name);
                try count(arena, &by_file, name, fl.name, name);
                if (log) |w| try logFailure(w, if (class == .xqlite_only) "XQLITE-ONLY" else "XQLITE-ONLY (not run on sqlite)", fl);
            } else if (class == .fail_both) {
                if (log) |w| try w.print("  BOTH {s}\n", .{kv.key_ptr.*});
            } else if (class == .sqlite_only) {
                if (log) |w| try w.print("  SQLITE-ONLY {s}\n", .{kv.key_ptr.*});
            }
        }
        var sit = sq_names.iterator();
        while (sit.next()) |kv| {
            if (!xq_names.contains(kv.key_ptr.*)) classes.getPtr(.sqlite_ran_only).* += 1;
        }
        // The file stopped early on xqlite only.
        const xq_stopped = xq.status.stopped();
        const sq_stopped = sq.status.stopped();
        if (xq_stopped and !sq_stopped) {
            files_xq_only += 1;
            try count(arena, &stops, try stopCause(arena, xq), name, name);
            if (log) |w| try w.print("  XQLITE STOPPED: {s}\n", .{firstLine(xq.reason, 300)});
        }
    }

    try out.print("\n{d} test files, {d} ms\n", .{ results.len, ms });
    try out.writeAll("                 xqlite   sqlite\n");
    for (std.enums.values(Status)) |s| {
        if (s == .none) continue;
        try out.print("  {s:<13}{d:>8} {d:>8}\n", .{ @tagName(s), by_status.get(.xqlite).get(s), by_status.get(.sqlite).get(s) });
    }
    try out.print("  {s:<13}{d:>8} {d:>8}\n", .{ "unfreed mem", leaks.get(.xqlite), leaks.get(.sqlite) });
    try out.writeAll("test cases (lines of the output; a name can run more than once)\n");
    try out.print("  passed        {d:>8} {d:>8}\n", .{ passed.get(.xqlite), passed.get(.sqlite) });
    try out.print("  failed        {d:>8} {d:>8}\n", .{ failed.get(.xqlite), failed.get(.sqlite) });
    if (with_ref) {
        try out.print(
            \\test names (a name failing anywhere in its file counts as failed):
            \\  pass on both              {d}
            \\  fail on both (harness)    {d}
            \\  fail on xqlite only       {d}
            \\  fail on sqlite only       {d}
            \\  run on sqlite only        {d}  (xqlite stopped before them)
            \\  run on xqlite only        {d}
            \\files that stop early on xqlite only: {d}
            \\
        , .{
            classes.get(.pass_both),   classes.get(.fail_both),       classes.get(.xqlite_only),
            classes.get(.sqlite_only), classes.get(.sqlite_ran_only), classes.get(.xqlite_ran_only),
            files_xq_only,
        });
    }
    try listCauses(arena, out, if (with_ref) "\nxqlite-only failures by cause:\n" else "\nfailures by cause:\n", &causes, top);
    if (with_ref) try listCauses(arena, out, "\nxqlite-only failures by test file:\n", &by_file, top);
    try listCauses(arena, out, if (with_ref) "\nfiles that stop early on xqlite only, by cause:\n" else "\nfiles that stop early, by cause:\n", &stops, top);
    return @intFromBool(causes.count() > 0 or stops.count() > 0);
}

fn logFailure(w: *Io.Writer, label: []const u8, fl: Failure) !void {
    if (fl.err.len > 0) {
        try w.print("  {s} {s}: Error: {s}\n", .{ label, fl.name, fl.err });
    } else {
        try w.print("  {s} {s}\n    expected: [{s}]\n    got:      [{s}]\n", .{ label, fl.name, fl.expected, fl.got });
    }
}

fn listCauses(arena: Allocator, out: *Io.Writer, title: []const u8, causes: *std.StringArrayHashMapUnmanaged(Cause), top: usize) !void {
    if (causes.count() == 0) return;
    const order = try arena.alloc(usize, causes.count());
    for (order, 0..) |*o, k| o.* = k;
    const values = causes.values();
    std.mem.sort(usize, order, values, struct {
        fn f(v: @TypeOf(values), a: usize, b: usize) bool {
            return v[a].n > v[b].n or (v[a].n == v[b].n and a < b);
        }
    }.f);
    try out.writeAll(title);
    for (order[0..@min(top, order.len)]) |k| {
        try out.print("{d:8} {s:>9}  {s}\n          e.g. {s}\n", .{ values[k].n, if (values[k].files <= 1 or values[k].files == values[k].n) "" else try std.fmt.allocPrint(arena, "({d} files)", .{values[k].files}), causes.keys()[k], values[k].example });
    }
    if (order.len > top) try out.print("          ({d} more causes)\n", .{order.len - top});
}

fn count(arena: Allocator, causes: *std.StringArrayHashMapUnmanaged(Cause), key: []const u8, ex: []const u8, file: []const u8) !void {
    const gop = try causes.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{ .example = ex };
    gop.value_ptr.n += 1;
    if (!std.mem.eql(u8, gop.value_ptr.last_file, file)) {
        gop.value_ptr.files += 1;
        gop.value_ptr.last_file = file;
    }
}

fn example(arena: Allocator, file: []const u8, fl: Failure) ![]const u8 {
    if (fl.err.len > 0) return std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ file, fl.name, firstLine(fl.err, 160) });
    return std.fmt.allocPrint(arena, "{s} {s}: expected [{s}] got [{s}]", .{ file, fl.name, firstLine(fl.expected, 120), firstLine(fl.got, 120) });
}

fn stopCause(arena: Allocator, r: Run) ![]const u8 {
    return switch (r.status) {
        .timeout => "TIMEOUT",
        .crash => std.fmt.allocPrint(arena, "CRASH: {s}", .{try normalize(arena, firstLine(r.reason, 160))}),
        else => std.fmt.allocPrint(arena, "ERROR: {s}", .{try normalize(arena, firstLine(r.reason, 120))}),
    };
}

/// What a failure is about, its specifics taken out, to group by.
///   - the test raised an error: "error: MESSAGE"
///   - catchsql-style results "1 {MESSAGE}" / "0 {ROWS}": an error where
///     none was expected, a missing error, a different message
///   - otherwise "wrong result"
fn cause(arena: Allocator, fl: Failure) ![]const u8 {
    if (fl.err.len > 0) return std.fmt.allocPrint(arena, "error: {s}", .{try normalize(arena, firstLine(fl.err, 120))});
    const e_err = catchError(fl.expected);
    const g_err = catchError(fl.got);
    if (g_err != null and e_err == null) return std.fmt.allocPrint(arena, "unexpected error: {s}", .{try normalize(arena, g_err.?)});
    if (e_err != null and g_err == null) return std.fmt.allocPrint(arena, "missing error: {s}", .{try normalize(arena, e_err.?)});
    if (e_err != null and g_err != null) return std.fmt.allocPrint(arena, "other error: {s} (want {s})", .{ try normalize(arena, g_err.?), try normalize(arena, e_err.?) });
    // An error text without catchsql's "1 {...}".
    for ([_][]const u8{ "no such ", "syntax error", "not authorized", "constraint failed", "malformed", "unable to", "cannot ", "misuse", "SQLITE_" }) |p| {
        if (std.mem.indexOf(u8, fl.got, p) != null and std.mem.indexOf(u8, fl.expected, p) == null)
            return std.fmt.allocPrint(arena, "unexpected error text: {s}", .{try normalize(arena, firstLine(fl.got, 80))});
    }
    return "wrong result";
}

/// "1 {MESSAGE}" -> MESSAGE (catchsql's error result).
fn catchError(s: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, "1 {") and std.mem.endsWith(u8, s, "}")) return s[3 .. s.len - 1];
    // "1 MESSAGE" for a one-word message, not "1 2" (two values).
    if (std.mem.startsWith(u8, s, "1 ") and s.len > 2 and std.mem.indexOfScalar(u8, s[2..], ' ') == null) {
        if (std.fmt.parseFloat(f64, s[2..])) |_| return null else |_| return s[2..];
    }
    return null;
}

/// Digits to N, quoted names and the text after "near" to X, so that
/// messages that differ only there group together.
fn normalize(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '"' or ch == '\'') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, ch)) |close| {
                try out.appendSlice(arena, if (ch == '"') "\"X\"" else "'X'");
                i = close + 1;
                continue;
            }
        }
        if (std.ascii.isDigit(ch) and (i == 0 or !isWord(s[i - 1]))) {
            var j = i;
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
            if (j == s.len or !isWord(s[j])) {
                try out.append(arena, 'N');
                i = j;
                continue;
            }
        }
        try out.append(arena, ch);
        i += 1;
    }
    // "no such table: main.t1" and the like: the name after the colon.
    const text = out.items;
    for ([_][]const u8{ "no such table: ", "no such column: ", "no such function: ", "no such index: ", "no such view: ", "no such module: ", "no such collation sequence: ", "no such trigger: ", "no such savepoint: ", "unknown database " }) |p| {
        if (std.mem.indexOf(u8, text, p)) |k| {
            const start = k + p.len;
            var end = start;
            while (end < text.len and text[end] != ' ' and text[end] != ',' and text[end] != ')') end += 1;
            return std.mem.concat(arena, u8, &.{ text[0..start], "X", text[end..] });
        }
    }
    return text;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

test parse {
    const out =
        \\a-1.1... Ok
        \\a-1.2...
        \\! a-1.2 expected: [1 2]
        \\! a-1.2 got:      [1 3]
        \\a-1.3...
        \\Error: no such table: t9
        \\some output... Ok
        \\a-1.4...hello Ok
        \\0 errors out of 4 tests on host Darwin 64-bit
        \\Unfreed memory: 144 bytes in 3 allocations
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), .{ .term = .{ .exited = 1 }, .stdout = @constCast(out), .stderr = @constCast("") });
    try std.testing.expectEqual(Status.fail, r.status);
    try std.testing.expectEqual(4, r.total);
    try std.testing.expectEqual(2, r.failed.len);
    try std.testing.expectEqualStrings("a-1.2", r.failed[0].name);
    try std.testing.expectEqualStrings("1 2", r.failed[0].expected);
    try std.testing.expectEqualStrings("1 3", r.failed[0].got);
    try std.testing.expectEqualStrings("no such table: t9", r.failed[1].err);
    try std.testing.expectEqual(2, r.passed.len);
    try std.testing.expectEqualStrings("a-1.4", r.passed[1]);
    try std.testing.expect(r.leak.len > 0);
}

test cause {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("error: no such table: X", try cause(a, .{ .name = "x", .err = "no such table: t9" }));
    try std.testing.expectEqualStrings("unexpected error: no such function: X", try cause(a, .{ .name = "x", .expected = "0 {1 2}", .got = "1 {no such function: sin}" }));
    try std.testing.expectEqualStrings("missing error: near \"X\": syntax error", try cause(a, .{ .name = "x", .expected = "1 {near \"x\": syntax error}", .got = "0 {}" }));
    try std.testing.expectEqualStrings("wrong result", try cause(a, .{ .name = "x", .expected = "1 2 3", .got = "1 2" }));
}

test wanted {
    try std.testing.expect(wanted("select1.test", .veryquick));
    try std.testing.expect(!wanted("malloc3.test", .veryquick));
    try std.testing.expect(wanted("malloc3.test", .quick));
    try std.testing.expect(!wanted("crash.test", .quick));
    try std.testing.expect(wanted("crash.test", .all));
    try std.testing.expect(!wanted("all.test", .all));
}
