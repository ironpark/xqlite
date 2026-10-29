//! Parts of one check run in parallel, for the modules whose checks are
//! made of many independent runs (a statement on a copy of a database, a
//! crash at each write of a commit): the check prints one line, and its
//! log lists the parts that failed, in order. Not a module itself.
//!
//!     try parts.forEach(c, cases.len, &ctx, runCase);    // fn (*Check, Ctx, usize) !void
//!     try parts.crashPoints(c, 200, &ctx, crashAt, .{}); // fn (*Check, Ctx, u32) !bool
//!
//! Each part is a Check of its own (the same helpers), in the directory
//! c.dir/N: removed if the part passes, left for --keep if it fails.

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

/// How many parts of one check run at a time: an eighth of -j, as other
/// checks run alongside (and -j 1 runs everything one after the other).
/// Every process start allocates from xqt's allocator (the debug
/// allocator in a Debug xqt), whose lock spins: with a quarter of -j,
/// attach, vacuum and analyze together took 56s instead of 16s.
pub fn width(c: *const Check) usize {
    return @max(1, (c.cfg.jobs + 7) / 8);
}

/// What the parts allocate with, to keep off that lock.
const allocator = std.heap.smp_allocator;

const Status = enum { not_run, ok, failed, skipped };

const Result = struct {
    status: Status = .not_run,
    /// The part's log (on `allocator`).
    log: []const u8 = "",
};

/// Calls `func(part, ctx, i)` for every i in 0..n, `width(c)` at a time,
/// each with a Check of its own in c.dir/I. A part that fails fails `c`,
/// and its log goes to c's log (in the order of i, after every part has
/// ended); a part that skips (error.Skipped) counts as not run.
pub fn forEach(c: *Check, n: usize, ctx: anytype, comptime func: fn (*Check, @TypeOf(ctx), usize) anyerror!void) !void {
    const results = try runAll(c, n, ctx, func);
    defer free(results);
    report(c, results);
}

/// The parts, run; `free` the result.
fn runAll(c: *Check, n: usize, ctx: anytype, comptime func: fn (*Check, @TypeOf(ctx), usize) anyerror!void) ![]Result {
    const results = try allocator.alloc(Result, n);
    @memset(results, .{});
    const Shared = struct {
        parent: *Check,
        ctx: @TypeOf(ctx),
        results: []Result,

        fn one(sh: *const @This(), i: usize) void {
            sh.results[i] = runPart(sh.parent, i, sh.ctx, func);
        }
    };
    const shared: Shared = .{ .parent = c, .ctx = ctx, .results = results };
    xqt.pool.forEach(width(c), n, &shared, Shared.one);
    return results;
}

fn free(results: []Result) void {
    for (results) |r| allocator.free(r.log);
    allocator.free(results);
}

/// Fails `c` with the log of each part that failed.
fn report(c: *Check, results: []const Result) void {
    for (results) |r| {
        if (r.status != .failed) continue;
        c.failures += 1;
        c.log.writeAll(r.log) catch {};
    }
}

fn runPart(parent: *Check, i: usize, ctx: anytype, comptime func: anytype) Result {
    const gpa = allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    const dir = std.fmt.allocPrint(arena.allocator(), "{s}/{d}", .{ parent.dir, i }) catch
        return .{ .status = .failed, .log = gpa.dupe(u8, "out of memory\n") catch "" };
    std.Io.Dir.cwd().createDirPath(parent.io, dir) catch |err|
        return .{ .status = .failed, .log = std.fmt.allocPrint(gpa, "cannot make {s}: {t}\n", .{ dir, err }) catch "" };
    var part: Check = .{
        .suite = parent.suite,
        .name = parent.name,
        .io = parent.io,
        .cfg = parent.cfg,
        .arena = arena.allocator(),
        .keep = arena.allocator(),
        .dir = dir,
        .log = &log.writer,
    };
    var status: Status = .ok;
    if (func(&part, ctx, i)) |_| {} else |err| switch (err) {
        error.CheckFailed => status = .failed,
        error.Skipped => status = .skipped,
        else => {
            part.fail("error: {t}", .{err});
            status = .failed;
        },
    }
    if (part.failures > 0) status = .failed;
    if (status != .failed) std.Io.Dir.cwd().deleteTree(parent.io, dir) catch {};
    return .{
        .status = status,
        .log = if (status == .failed) gpa.dupe(u8, log.written()) catch "" else "",
    };
}

/// Crash tests: `point(part, ctx, at)` crashes a writer at its at-th write
/// (from 1) and checks what the other engine recovers; it returns true
/// when the run got through, with nothing left to crash. The points run
/// in parallel, in order, up to the first that gets through (as the old
/// loop `while not through: crash at i; i++`), or `max`. Fails `c` if no
/// run got through, or if the first did (nothing crashed) unless
/// `may_not_crash` (a series with no write of that kind). Logs the count.
pub fn crashPoints(c: *Check, max: u32, ctx: anytype, comptime point: fn (*Check, @TypeOf(ctx), u32) anyerror!bool, opts: struct {
    may_not_crash: bool = false,
}) !void {
    const Shared = struct {
        ctx: @TypeOf(ctx),
        /// The first point that got through.
        through: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),

        fn one(part: *Check, sh: *@This(), i: usize) !void {
            const at: u32 = @intCast(i + 1);
            // Past a run that got through: the old loop stopped there.
            if (at > sh.through.load(.monotonic)) return error.Skipped;
            if (try point(part, sh.ctx, at)) _ = sh.through.fetchMin(at, .monotonic);
        }
    };
    var shared: Shared = .{ .ctx = ctx };
    const results = try runAll(c, max, &shared, Shared.one);
    defer free(results);
    const through = shared.through.load(.monotonic);
    if (through == std.math.maxInt(u32)) {
        report(c, results);
        return c.abort("no run got through in {d}", .{max});
    }
    // The points past the first that got through ran only because they
    // started before it ended; the old loop never ran them.
    report(c, results[0..through]);
    for (through..max) |i| c.remove(try std.fmt.allocPrint(c.arena, "{d}", .{i})) catch {};
    if (through == 1 and !opts.may_not_crash) return c.abort("the run at 1 got through: nothing crashed", .{});
    c.print("{d} crashes, then the run at {d} got through", .{ through - 1, through });
}

/// Runs `argv` (in `cwd`, a directory of the check's) with standard
/// output and standard error in one stream, as `cmd 2>&1` would, and
/// returns what it printed; whatever its exit status.
pub fn combined(c: *Check, argv: []const []const u8, opts: struct {
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
}) ![]const u8 {
    const out = "combined.out";
    var child = try c.spawn(argv, .{
        .cwd = if (opts.cwd) |d| try c.path(d) else null,
        .env = opts.env,
        .output = out,
    });
    defer child.kill();
    _ = try child.close();
    const text = try c.readFile(out);
    try c.remove(out);
    return text;
}

/// `text` with each newline a space, as `| tr '\n' ' '`.
pub fn oneLine(c: *Check, text: []const u8) ![]const u8 {
    const s = try c.arena.dupe(u8, text);
    std.mem.replaceScalar(u8, s, '\n', ' ');
    return s;
}

/// `text` without its final newlines, as `$(...)`.
pub fn trimmed(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\n");
}
