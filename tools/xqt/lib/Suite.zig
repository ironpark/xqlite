//! A list of checks run on a work pool. Each check reports ok, FAIL (with
//! its log) or skip as it finishes, in one piece; `summary` then lists the
//! failures in the order the checks were added and counts them.
//!
//!     var suite: Suite = .init(gpa, io, &cfg, out, .{ .name = "interop" });
//!     defer suite.deinit();
//!     try suite.add("sql: written by xqlite", writtenByXqlite, .{});
//!     try suite.add("planner: block 3", runBlock, .{ &file, 3 });
//!     suite.run();
//!     try suite.summary();
//!     if (suite.failed() > 0) ...
//!
//! A check is a function `fn (c: *Check, args...) !void` (see Check.zig);
//! `add` copies `args`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const Check = @import("Check.zig");
const pool = @import("pool.zig");

const Suite = @This();

gpa: Allocator,
io: Io,
cfg: *const Config,
opts: Options,
/// Standard output, shared by every check; hold `out_mutex` to write.
out: *Io.Writer,
out_mutex: Io.Mutex = .init,
/// Names and arguments of the checks.
arena: std.heap.ArenaAllocator,
entries: std.ArrayList(Entry) = .empty,
/// Put before the name of each check `add` adds ("sql: ").
prefix: []const u8 = "",
elapsed_ms: i64 = 0,

pub const Options = struct {
    /// Names the directory of this suite's checks under `Config.tmp`;
    /// unique among the suites of one run.
    name: []const u8,
    /// What to print as each check finishes: every check, only the failed
    /// ones, or nothing (the command reports by itself).
    show: enum { all, failures, none } = .all,
};

pub const Status = enum { ok, failed, skipped };

pub const Outcome = struct {
    status: Status = .ok,
    ms: i64 = 0,
    /// The check's log; for a skip, the reason.
    log: []const u8 = "",
    /// The temporary directory, if --keep kept it.
    kept: ?[]const u8 = null,
};

const Entry = struct {
    name: []const u8,
    call: *const fn (*Check, *const anyopaque) anyerror!void,
    args: *const anyopaque,
    /// `Check.keep`: lives until `deinit`.
    keep: std.heap.ArenaAllocator,
    outcome: Outcome = .{},
};

pub fn init(gpa: Allocator, io: Io, cfg: *const Config, out: *Io.Writer, opts: Options) Suite {
    return .{ .gpa = gpa, .io = io, .cfg = cfg, .opts = opts, .out = out, .arena = .init(gpa) };
}

pub fn deinit(s: *Suite) void {
    for (s.entries.items) |*e| e.keep.deinit();
    s.entries.deinit(s.gpa);
    s.arena.deinit();
}

/// Adds the check `func(c, args...)` named `name`. Checks start in the
/// order they were added; add the long ones first.
pub fn add(s: *Suite, name: []const u8, comptime func: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Wrap = struct {
        fn call(c: *Check, p: *const anyopaque) anyerror!void {
            const a: *const Args = @ptrCast(@alignCast(p));
            return @call(.auto, func, .{c} ++ a.*);
        }
    };
    const arena = s.arena.allocator();
    const copy = try arena.create(Args);
    copy.* = args;
    try s.entries.append(s.gpa, .{
        .name = try std.mem.concat(arena, u8, &.{ s.prefix, name }),
        .call = Wrap.call,
        .args = copy,
        .keep = .init(s.gpa),
    });
}

pub fn len(s: *const Suite) usize {
    return s.entries.items.len;
}

/// The outcome of the i-th check added, after `run`.
pub fn outcome(s: *const Suite, i: usize) Outcome {
    return s.entries.items[i].outcome;
}

pub fn failed(s: *const Suite) usize {
    var n: usize = 0;
    for (s.entries.items) |e| n += @intFromBool(e.outcome.status == .failed);
    return n;
}

/// Runs every check, `Config.jobs` at a time.
pub fn run(s: *Suite) void {
    const start = Io.Clock.awake.now(s.io);
    pool.forEach(s.cfg.jobs, s.entries.items.len, s, runOne);
    s.elapsed_ms = start.durationTo(Io.Clock.awake.now(s.io)).toMilliseconds();
    // The suite's directory, unless --keep left something in it.
    const dir = std.fs.path.join(s.gpa, &.{ s.cfg.tmp, s.opts.name }) catch return;
    defer s.gpa.free(dir);
    Io.Dir.cwd().deleteDir(s.io, dir) catch {};
    Io.Dir.cwd().deleteDir(s.io, s.cfg.tmp) catch {};
}

fn runOne(s: *Suite, i: usize) void {
    const e = &s.entries.items[i];
    const keep = e.keep.allocator();
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    var log: Io.Writer.Allocating = .init(s.gpa);
    defer log.deinit();

    const dir = checkDir(s, scratch.allocator(), i) catch |err| {
        e.outcome = .{ .status = .failed, .log = std.fmt.allocPrint(keep, "cannot make a temporary directory: {t}\n", .{err}) catch "" };
        s.report(e);
        return;
    };
    var c: Check = .{
        .suite = s,
        .name = e.name,
        .io = s.io,
        .cfg = s.cfg,
        .arena = scratch.allocator(),
        .keep = keep,
        .dir = dir,
        .log = &log.writer,
    };
    const start = Io.Clock.awake.now(s.io);
    var status: Status = .ok;
    if (e.call(&c, e.args)) |_| {
        if (c.failures > 0) status = .failed;
    } else |err| switch (err) {
        error.CheckFailed => status = .failed,
        error.Skipped => status = .skipped,
        else => {
            c.fail("error: {t}", .{err});
            status = .failed;
        },
    }
    if (c.failures > 0) status = .failed;
    const ms = start.durationTo(Io.Clock.awake.now(s.io)).toMilliseconds();

    var kept: ?[]const u8 = null;
    if (status == .failed and s.cfg.keep) {
        kept = keep.dupe(u8, dir) catch null;
    } else {
        Io.Dir.cwd().deleteTree(s.io, dir) catch {};
    }
    e.outcome = .{
        .status = status,
        .ms = ms,
        .log = if (status == .skipped) c.skip_reason orelse "" else keep.dupe(u8, log.written()) catch "",
        .kept = kept,
    };
    s.report(e);
}

/// CFG.tmp/SUITE/INDEX-NAME, made new.
fn checkDir(s: *Suite, arena: Allocator, i: usize) ![]const u8 {
    const e = &s.entries.items[i];
    var name: [40]u8 = undefined;
    const n = @min(name.len, e.name.len);
    for (e.name[0..n], name[0..n]) |ch, *d| d.* = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.') ch else '_';
    const dir = try std.fmt.allocPrint(arena, "{s}/{s}/{d}-{s}", .{ s.cfg.tmp, s.opts.name, i, name[0..n] });
    Io.Dir.cwd().deleteTree(s.io, dir) catch {};
    try Io.Dir.cwd().createDirPath(s.io, dir);
    return dir;
}

fn report(s: *Suite, e: *const Entry) void {
    const o = e.outcome;
    const show = switch (s.opts.show) {
        .all => true,
        .failures => o.status == .failed,
        .none => false,
    };
    if (!show) return;
    s.out_mutex.lockUncancelable(s.io);
    defer s.out_mutex.unlock(s.io);
    const w = s.out;
    switch (o.status) {
        .ok => w.print("ok   {s} ({f})\n", .{ e.name, msDuration(o.ms) }) catch {},
        .failed => w.print("FAIL {s} ({f})\n", .{ e.name, msDuration(o.ms) }) catch {},
        .skipped => w.print("skip {s}: {s}\n", .{ e.name, o.log }) catch {},
    }
    if (o.status == .failed or (o.status == .ok and s.cfg.verbose)) writeIndented(w, o.log) catch {};
    if (o.kept) |dir| w.print("     kept {s}\n", .{dir}) catch {};
    w.flush() catch {};
}

fn msDuration(ms: i64) Io.Duration {
    return .fromMilliseconds(ms);
}

fn writeIndented(w: *Io.Writer, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    if (text.len == 0) return;
    while (it.next()) |line| try w.print("     {s}\n", .{line});
}

/// Writes `text` to standard output at once, between the reports of
/// checks. For a check's progress line (`Check.printNow`).
pub fn printNow(s: *Suite, comptime fmt: []const u8, args: anytype) void {
    s.out_mutex.lockUncancelable(s.io);
    defer s.out_mutex.unlock(s.io);
    s.out.print(fmt, args) catch {};
    s.out.flush() catch {};
}

/// The failed checks in the order they were added, then the counts:
/// "N checks: A ok, B failed, C skipped (T)".
pub fn summary(s: *Suite) !void {
    s.out_mutex.lockUncancelable(s.io);
    defer s.out_mutex.unlock(s.io);
    const w = s.out;
    var n: [3]usize = @splat(0);
    for (s.entries.items) |e| n[@backingInt(e.outcome.status)] += 1;
    if (n[@backingInt(Status.failed)] > 0) {
        try w.writeAll("\nfailed:\n");
        for (s.entries.items) |e| {
            if (e.outcome.status != .failed) continue;
            try w.print("  {s}\n", .{e.name});
            if (e.outcome.kept) |dir| try w.print("    kept {s}\n", .{dir});
        }
    }
    try w.print("{d} checks: {d} ok, {d} failed, {d} skipped ({f})\n", .{
        s.entries.items.len,
        n[@backingInt(Status.ok)],
        n[@backingInt(Status.failed)],
        n[@backingInt(Status.skipped)],
        msDuration(s.elapsed_ms),
    });
    try w.flush();
}
