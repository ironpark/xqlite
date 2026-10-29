//! What a check gets: its own temporary directory, a log, allocators and
//! helpers to run the engines and compare what they print.
//!
//! A check is `fn (c: *Check, args...) !void`. It reports by calling
//! `fail` (go on) or `abort` (stop); returning an error also fails it,
//! except `error.Skipped` from `skip`. Its directory is removed when it
//! passes (and, without --keep, when it fails). Relative paths given to
//! the helpers, and the working directory of the programs it runs, are in
//! that directory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const Config = @import("Config.zig");
const Suite = @import("Suite.zig");
const proc = @import("proc.zig");
const diff = @import("diff.zig");

const Check = @This();

suite: *Suite,
name: []const u8,
io: Io,
cfg: *const Config,
/// Freed when the check ends: process output, paths, scratch.
arena: Allocator,
/// Freed with the suite: results the command reads after `Suite.run`.
keep: Allocator,
/// The check's temporary directory, absolute.
dir: []const u8,
/// Printed with the result if the check fails (or with -v).
log: *Io.Writer,
failures: usize = 0,
skip_reason: ?[]const u8 = null,

pub const Error = error{ CheckFailed, Skipped };

// ---------------------------------------------------------------- reporting

/// Adds a line to the log.
pub fn print(c: *Check, comptime fmt: []const u8, args: anytype) void {
    c.log.print(fmt ++ "\n", args) catch {};
}

/// Records a failure and goes on.
pub fn fail(c: *Check, comptime fmt: []const u8, args: anytype) void {
    c.failures += 1;
    c.print(fmt, args);
}

/// Records a failure; `return c.abort(...)` ends the check.
pub fn abort(c: *Check, comptime fmt: []const u8, args: anytype) error{CheckFailed} {
    c.fail(fmt, args);
    return error.CheckFailed;
}

/// `return c.skip(...)` ends the check as skipped, with the reason.
pub fn skip(c: *Check, comptime fmt: []const u8, args: anytype) error{Skipped} {
    c.skip_reason = std.fmt.allocPrint(c.keep, fmt, args) catch "?";
    return error.Skipped;
}

/// Fails unless `ok`. Returns `ok`.
pub fn expect(c: *Check, ok: bool, comptime fmt: []const u8, args: anytype) bool {
    if (!ok) c.fail(fmt, args);
    return ok;
}

/// Fails unless `got` equals `want`, logging "WHAT differs" and a short
/// unified diff (--- want_name, +++ got_name). Returns whether they agree.
pub fn expectSame(c: *Check, what: []const u8, want_name: []const u8, want: []const u8, got_name: []const u8, got: []const u8) bool {
    if (std.mem.eql(u8, want, got)) return true;
    c.fail("{s} differs", .{what});
    c.writeDiff(want_name, want, got_name, got);
    return false;
}

/// Logs a short unified diff of two texts.
pub fn writeDiff(c: *Check, a_name: []const u8, a: []const u8, b_name: []const u8, b: []const u8) void {
    diff.write(c.log, c.arena, a_name, b_name, a, b, .{}) catch {};
}

/// Prints a line on standard output now, between the reports of checks
/// (progress of a long check).
pub fn printNow(c: *Check, comptime fmt: []const u8, args: anytype) void {
    c.suite.printNow(fmt ++ "\n", args);
}

// ---------------------------------------------------------------- programs

pub const RunOptions = struct {
    /// The working directory; null is the check's directory.
    cwd: ?[]const u8 = null,
    /// The environment (see `env`); null passes on xqt's own.
    env: ?*const Environ.Map = null,
    /// Written to the standard input; null gives it /dev/null.
    stdin: ?[]const u8 = null,
    /// Kill the program after this many milliseconds (`Result.timedOut`).
    timeout_ms: ?i64 = null,
};

/// Runs `argv` to its end. The output lives until the check ends.
pub fn run(c: *Check, argv: []const []const u8, opts: RunOptions) !proc.Result {
    return proc.run(c.arena, c.io, argv, .{
        .cwd = opts.cwd orelse c.dir,
        .env = opts.env,
        .stdin = opts.stdin,
        .timeout_ms = opts.timeout_ms,
    });
}

/// Runs `argv`, which must exit with status 0 (as under `set -e`), and
/// returns its standard output. Otherwise the check fails, logging the
/// command and its standard error, and this returns error.CheckFailed.
pub fn runOk(c: *Check, argv: []const []const u8, opts: RunOptions) ![]const u8 {
    const r = try c.run(argv, opts);
    if (r.ok()) return r.stdout;
    c.fail("{f}: {f}", .{ fmtArgv(argv), r });
    if (r.stderr.len > 0) c.print("{s}", .{std.mem.trimEnd(u8, r.stderr, "\n")});
    return error.CheckFailed;
}

/// `sqlite3 DB SQL` with the reference shell; must succeed. Returns the
/// standard output.
pub fn sqlite3(c: *Check, db: []const u8, sql: []const u8) ![]const u8 {
    return c.runOk(&.{ c.cfg.sqlite3, db, sql }, .{});
}

/// `sqlite3 ARGS...`; must succeed.
pub fn sqlite3Args(c: *Check, args: []const []const u8) ![]const u8 {
    return c.runOk(try c.command(c.cfg.sqlite3, args), .{});
}

/// `xqlite sql DB SQL`; must succeed. Returns the standard output.
pub fn xqSql(c: *Check, db: []const u8, sql: []const u8) ![]const u8 {
    return c.runOk(&.{ c.cfg.xq, "sql", db, sql }, .{});
}

/// `xqlite ARGS...` (a command and its arguments); must succeed.
pub fn xq(c: *Check, args: []const []const u8) ![]const u8 {
    return c.runOk(try c.command(c.cfg.xq, args), .{});
}

/// PROGRAM followed by ARGS, for `run`.
pub fn command(c: *Check, program: []const u8, args: []const []const u8) ![]const []const u8 {
    const v = try c.arena.alloc([]const u8, args.len + 1);
    v[0] = program;
    @memcpy(v[1..], args);
    return v;
}

/// Starts `argv` with a pipe on its standard input, to write to while it
/// runs; standard output and error go to the file `output` (relative to
/// the check's directory) or nowhere. `kill` it before the check ends.
pub fn spawn(c: *Check, argv: []const []const u8, opts: struct {
    cwd: ?[]const u8 = null,
    env: ?*const Environ.Map = null,
    output: ?[]const u8 = null,
}) !proc.Child {
    return proc.spawn(c.io, argv, .{
        .cwd = opts.cwd orelse c.dir,
        .env = opts.env,
        .output = if (opts.output) |o| try c.path(o) else null,
    });
}

/// xqt's environment with `vars` ({name, value} pairs) set, for
/// `RunOptions.env`.
pub fn env(c: *Check, vars: []const [2][]const u8) !*Environ.Map {
    const m = try c.arena.create(Environ.Map);
    m.* = try c.cfg.environ.clone(c.arena);
    for (vars) |v| try m.put(v[0], v[1]);
    return m;
}

fn fmtArgv(args: []const []const u8) std.fmt.Alt([]const []const u8, writeArgv) {
    return .{ .data = args };
}

/// The command, each argument cut to one line of 60 bytes.
fn writeArgv(args: []const []const u8, w: *Io.Writer) Io.Writer.Error!void {
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeByte(' ');
        const shown = if (i == 0) std.fs.path.basename(a) else a;
        const line = shown[0 .. std.mem.indexOfScalar(u8, shown, '\n') orelse shown.len];
        const cut = line[0..@min(line.len, 60)];
        const quote = cut.len != shown.len or std.mem.indexOfAny(u8, cut, " '\"") != null or cut.len == 0;
        if (quote) try w.writeByte('\'');
        try w.writeAll(cut);
        if (cut.len != shown.len) try w.writeAll("...");
        if (quote) try w.writeByte('\'');
    }
}

// ---------------------------------------------------------------- files

/// NAME in the check's directory (an absolute path stays).
pub fn path(c: *Check, name: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(name)) return name;
    return std.fs.path.join(c.arena, &.{ c.dir, name });
}

pub fn exists(c: *Check, name: []const u8) bool {
    const p = c.path(name) catch return false;
    return Config.exists(c.io, p);
}

/// The size of the file, null if there is none.
pub fn fileSize(c: *Check, name: []const u8) !?u64 {
    const p = try c.path(name);
    const st = Io.Dir.cwd().statFile(c.io, p, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return st.size;
}

pub fn readFile(c: *Check, name: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, try c.path(name), c.arena, .unlimited);
}

pub fn writeFile(c: *Check, name: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try c.path(name), .data = data });
}

pub fn copyFile(c: *Check, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().copyFile(try c.path(from), .cwd(), try c.path(to), c.io, .{});
}

/// Copies the directory `from` to `to` (made new) with what it contains.
pub fn copyDir(c: *Check, from: []const u8, to: []const u8) !void {
    try copyTree(c.io, c.arena, try c.path(from), try c.path(to));
}

/// Removes a file or a directory tree; nothing if there is none.
pub fn remove(c: *Check, name: []const u8) !void {
    try Io.Dir.cwd().deleteTree(c.io, try c.path(name));
}

pub fn makeDir(c: *Check, name: []const u8) !void {
    try Io.Dir.cwd().createDirPath(c.io, try c.path(name));
}

pub fn sleep(c: *Check, ms: i64) void {
    c.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// Copies the tree at `from` to `to`, which must not exist.
pub fn copyTree(io: Io, gpa: Allocator, from: []const u8, to: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, to);
    var src = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    var dst = try Io.Dir.cwd().openDir(io, to, .{});
    defer dst.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| switch (entry.kind) {
        .directory => {
            const a = try std.fs.path.join(gpa, &.{ from, entry.name });
            defer gpa.free(a);
            const b = try std.fs.path.join(gpa, &.{ to, entry.name });
            defer gpa.free(b);
            try copyTree(io, gpa, a, b);
        },
        else => try src.copyFile(entry.name, dst, entry.name, io, .{}),
    };
}
