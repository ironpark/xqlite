//! Running programs: `run` waits for a program and captures its output,
//! `spawn` starts one to talk to while it runs (a shell kept open on a
//! pipe, a process to kill mid-transaction).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Options = struct {
    /// The working directory; null keeps the caller's. `Check.run` passes
    /// the check's temporary directory.
    cwd: ?[]const u8 = null,
    /// The whole environment of the program; null passes on the caller's.
    /// `Check.env` builds one with variables added.
    env: ?*const Environ.Map = null,
    /// Written to the standard input, which is then closed; null gives the
    /// program /dev/null.
    stdin: ?[]const u8 = null,
    /// Kill the program (SIGKILL) after this many milliseconds; the result
    /// is then `timed_out` with the output read so far.
    timeout_ms: ?i64 = null,
};

pub const Result = struct {
    /// How the program ended; null if it timed out.
    term: ?std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    /// It exited with status 0.
    pub fn ok(r: Result) bool {
        return r.exitCode() == 0;
    }

    /// The exit status, null if a signal ended it or it timed out.
    pub fn exitCode(r: Result) ?u8 {
        const t = r.term orelse return null;
        return switch (t) {
            .exited => |code| code,
            else => null,
        };
    }

    pub fn timedOut(r: Result) bool {
        return r.term == null;
    }

    /// "exited with code 1", "terminated with signal SEGV", "timed out".
    pub fn format(r: Result, w: *Io.Writer) Io.Writer.Error!void {
        if (r.term) |t| return t.format(w);
        try w.writeAll("timed out");
    }
};

/// Runs `argv` to its end and returns its exit status and output, which
/// `gpa` allocates. argv[0] is looked up in PATH if it has no slash.
pub fn run(gpa: Allocator, io: Io, argv: []const []const u8, opts: Options) !Result {
    // A thread feeds the standard input, so that a program that writes
    // much before it reads all of it cannot block on a full pipe. It is
    // joined after the program has ended (the defer below runs first).
    var feeder: ?std.Thread = null;
    defer if (feeder) |t| t.join();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = opts.env,
        .stdin = if (opts.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.id != null) kill(io, &child);

    if (opts.stdin) |input| {
        const file = child.stdin.?;
        child.stdin = null;
        feeder = std.Thread.spawn(.{}, feed, .{ io, file, input }) catch |err| {
            file.close(io);
            return err;
        };
    }

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    const timeout: Io.Timeout = if (opts.timeout_ms) |ms|
        (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }).toDeadline(io)
    else
        .none;
    var timed_out = false;
    while (reader.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }
    var term: ?std.process.Child.Term = null;
    if (timed_out) kill(io, &child) else {
        try reader.checkAnyError();
        term = try child.wait(io);
    }
    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn feed(io: Io, file: Io.File, input: []const u8) void {
    defer file.close(io);
    // A program that exits without reading it all closes the pipe.
    file.writeStreamingAll(io, input) catch {};
}

/// Ends `child` at once with SIGKILL, as a power loss would, and reaps it.
pub fn kill(io: Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(pid, .KILL) catch {};
    _ = child.wait(io) catch {};
}

pub const SpawnOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?*const Environ.Map = null,
    /// Standard output and standard error go to this file (created or
    /// truncated); null sends them to /dev/null.
    output: ?[]const u8 = null,
};

/// A program that runs alongside the check: write to its standard input
/// with `write`, end it with `close` (EOF, then wait) or `kill`.
pub const Child = struct {
    io: Io,
    child: std.process.Child,

    pub fn write(c: *Child, bytes: []const u8) !void {
        try c.child.stdin.?.writeStreamingAll(c.io, bytes);
    }

    /// Closes the standard input and waits for the program to end.
    pub fn close(c: *Child) !std.process.Child.Term {
        if (c.child.stdin) |f| {
            f.close(c.io);
            c.child.stdin = null;
        }
        return c.child.wait(c.io);
    }

    /// SIGKILL, then reap it. Safe to call after `close`.
    pub fn kill(c: *Child) void {
        if (c.child.id == null) return;
        if (c.child.stdin) |f| {
            f.close(c.io);
            c.child.stdin = null;
        }
        kill_(c.io, &c.child);
    }
};

const kill_ = kill;

/// Starts `argv` with a pipe on its standard input.
pub fn spawn(io: Io, argv: []const []const u8, opts: SpawnOptions) !Child {
    var out: ?Io.File = null;
    if (opts.output) |path| out = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer if (out) |f| f.close(io);
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = opts.env,
        .stdin = .pipe,
        .stdout = if (out) |f| .{ .file = f } else .ignore,
        .stderr = if (out) |f| .{ .file = f } else .ignore,
    });
    return .{ .io = io, .child = child };
}
