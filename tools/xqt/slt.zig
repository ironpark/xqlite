//! `xqt slt [options] PATH... [-- ARGS]`: sqllogictest scripts with
//! `xqlite slt`, one process per script in parallel, the failures grouped
//! by cause. (Was tools/slt/run.py; tools/slt/README.md.)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt slt [options] PATH... [-- ARGS]   (PATH: a .test file or a directory)
    \\
    \\  --timeout S  seconds per script (default 600)
    \\  --ref BIN    also run the C reference runner (sqllogictest built against
    \\               sqlite3 3.54.1, see tools/slt/README.md) on failing scripts,
    \\               and mark failures it shares
    \\  --log FILE   write every failure line to FILE
    \\  --top N      causes to list (default 40)
    \\  -- ARGS      extra arguments for `xqlite slt`, e.g. -- --integrity-check
    \\
;

const Status = enum { crash, fail, ok, timeout };

const Failure = struct { line: u32, msg: []const u8 };

const Result = struct {
    status: Status = .ok,
    total: u64 = 0,
    n_err: u64 = 0,
    fails: []const Failure = &.{},
    /// The first lines of the standard error.
    tail: []const u8 = "",
    /// Lines the reference runner fails too (--ref).
    shared: []const u32 = &.{},
};

const Ctx = struct {
    cfg: *const xqt.Config,
    timeout_ms: i64,
    extra: []const []const u8,
    ref: ?[]const u8,
    n_scripts: usize,
    done: std.atomic.Value(usize) = .init(0),
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    var extra: []const []const u8 = &.{};
    var timeout_s: i64 = 600;
    var ref: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var top: usize = 40;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            extra = args[i + 1 ..];
            break;
        }
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--timeout") and has_value) {
            i += 1;
            timeout_s = std.fmt.parseInt(i64, args[i], 10) catch return usageError(out);
        } else if (std.mem.eql(u8, a, "--ref") and has_value) {
            i += 1;
            ref = try absolute(arena, io, args[i]);
        } else if (std.mem.eql(u8, a, "--log") and has_value) {
            i += 1;
            log_path = args[i];
        } else if (std.mem.eql(u8, a, "--top") and has_value) {
            i += 1;
            top = std.fmt.parseUnsigned(usize, args[i], 10) catch return usageError(out);
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(out);
        } else {
            try paths.append(arena, a);
        }
    }
    if (paths.items.len == 0) return usageError(out);

    var files: std.ArrayList([]const u8) = .empty;
    for (paths.items) |p| try scripts(arena, io, p, &files);
    const results = try arena.alloc(Result, files.items.len);
    @memset(results, .{});

    var ctx: Ctx = .{
        .cfg = cfg,
        .timeout_ms = timeout_s * std.time.ms_per_s,
        .extra = extra,
        .ref = ref,
        .n_scripts = files.items.len,
    };
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "slt", .show = .failures });
    defer suite.deinit();
    for (files.items, results) |f, *r| try suite.add(f, runScript, .{ &ctx, f, r });
    suite.run();

    if (ref != null) {
        var refs: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "slt-ref", .show = .failures });
        defer refs.deinit();
        for (files.items, results) |f, *r| {
            if (r.status == .fail) try refs.add(f, runRef, .{ &ctx, f, r });
        }
        refs.run();
    }

    // Causes, in the order of the scripts, then by count.
    var causes: std.StringArrayHashMapUnmanaged(struct { n: usize, example: []const u8 }) = .empty;
    var log: ?Io.File = null;
    var log_buffer: [4096]u8 = undefined;
    var log_writer: Io.File.Writer = undefined;
    if (log_path) |p| {
        log = try Io.Dir.cwd().createFile(io, p, .{ .truncate = true });
        log_writer = log.?.writer(io, &log_buffer);
    }
    defer if (log) |f| f.close(io);
    var n_tests: u64 = 0;
    var n_fail: u64 = 0;
    var n_shared: u64 = 0;
    for (files.items, results) |path, r| {
        n_tests += r.total;
        switch (r.status) {
            .crash => {
                const first = if (r.tail.len > 0) r.tail[0 .. std.mem.indexOfScalar(u8, r.tail, '\n') orelse r.tail.len] else "?";
                try count(arena, &causes, try std.fmt.allocPrint(arena, "CRASH: {s}", .{first}), path);
            },
            .timeout => try count(arena, &causes, "TIMEOUT", path),
            else => {},
        }
        for (r.fails) |f| {
            if (std.mem.indexOfScalar(u32, r.shared, f.line) != null) {
                n_shared += 1;
                continue;
            }
            n_fail += 1;
            try count(arena, &causes, try cause(arena, f.msg), try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, f.line }));
            if (log != null) try log_writer.interface.print("{s}:{d}: {s}\n", .{ path, f.line, f.msg });
        }
    }
    if (log != null) try log_writer.interface.flush();

    var by_status: std.EnumArray(Status, usize) = .initFill(0);
    for (results) |r| by_status.getPtr(r.status).* += 1;
    try out.print("\n{d} scripts: ", .{files.items.len});
    var first = true;
    for (std.enums.values(Status)) |s| {
        if (by_status.get(s) == 0) continue;
        try out.print("{s}{t}={d}", .{ if (first) "" else ", ", s, by_status.get(s) });
        first = false;
    }
    try out.print("\n{d} tests, {d} failures", .{ n_tests, n_fail });
    if (ref != null) try out.print(" (+{d} the reference shares)", .{n_shared});
    try out.writeAll("\n");
    if (causes.count() > 0) {
        // Counter.most_common(): by count, ties in order of appearance.
        const order = try arena.alloc(usize, causes.count());
        for (order, 0..) |*o, k| o.* = k;
        const values = causes.values();
        std.mem.sort(usize, order, values, struct {
            fn f(v: @TypeOf(values), a: usize, b: usize) bool {
                return v[a].n > v[b].n or (v[a].n == v[b].n and a < b);
            }
        }.f);
        try out.writeAll("\ncauses:\n");
        for (order[0..@min(top, order.len)]) |k| {
            try out.print("{d:8}  {s}\n          e.g. {s}\n", .{ values[k].n, causes.keys()[k], values[k].example });
        }
    }
    try out.flush();
    return @intFromBool(causes.count() > 0);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

fn count(arena: Allocator, causes: anytype, key: []const u8, example: []const u8) !void {
    const gop = try causes.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = .{ .n = 0, .example = example };
    gop.value_ptr.n += 1;
}

fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return std.fs.path.resolveAlloc(arena, &.{ buf[0..n], path });
}

/// A .test file, or the .test files under a directory in sorted order.
fn scripts(arena: Allocator, io: Io, path: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return files.append(arena, path),
        else => |e| return e,
    };
    defer dir.close(io);
    var found: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".test"))
            try found.append(arena, try std.fs.path.join(arena, &.{ path, e.path }));
    }
    // os.walk sorted: by directory, then by name within it.
    std.mem.sort([]const u8, found.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            const da = std.fs.path.dirname(a) orelse "";
            const db = std.fs.path.dirname(b) orelse "";
            if (!std.mem.eql(u8, da, db)) return std.mem.lessThan(u8, da, db);
            return std.mem.lessThan(u8, a, b);
        }
    }.f);
    try files.appendSlice(arena, found.items);
}

fn runScript(c: *Check, ctx: *Ctx, path: []const u8, res: *Result) !void {
    const argv = try c.arena.alloc([]const u8, ctx.extra.len + 3);
    argv[0] = ctx.cfg.xq;
    argv[1] = "slt";
    @memcpy(argv[2 .. argv.len - 1], ctx.extra);
    argv[argv.len - 1] = path;
    // The paths are relative to where xqt runs.
    const r = try c.run(argv, .{ .cwd = ".", .timeout_ms = ctx.timeout_ms });
    res.* = if (r.timedOut()) .{ .status = .timeout } else try parse(c.keep, path, r);
    const n = ctx.done.fetchAdd(1, .monotonic) + 1;
    if (res.status != .ok)
        c.printNow("[{d}/{d}] {s} {s} ({d}/{d})", .{ n, ctx.n_scripts, upper(res.status), path, res.n_err, res.total });
}

fn upper(s: Status) []const u8 {
    return switch (s) {
        .crash => "CRASH",
        .fail => "FAIL",
        .ok => "OK",
        .timeout => "TIMEOUT",
    };
}

/// The summary line "E errors out of T tests in PATH - S skipped." and
/// the failure lines "PATH:LINE: MESSAGE" of `xqlite slt`.
fn parse(keep: Allocator, path: []const u8, r: xqt.proc.Result) !Result {
    var res: Result = .{};
    var fails: std.ArrayList(Failure) = .empty;
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break; // after the final newline
        last = line;
        if (parseSummary(line)) |s| {
            res.n_err = s[0];
            res.total = s[1];
            continue;
        }
        if (parseFailure(line)) |f| {
            if (std.mem.eql(u8, f.path, path)) try fails.append(keep, .{ .line = f.line, .msg = try keep.dupe(u8, f.msg) });
        }
    }
    res.fails = fails.items;
    const code = r.exitCode();
    if (code == null or code.? > 1 or parseSummary(last) == null) {
        res.status = .crash;
    } else if (res.n_err > 0) {
        res.status = .fail;
    }
    // The first three lines of the stripped standard error.
    const err = std.mem.trim(u8, r.stderr, " \t\r\n");
    var end: usize = 0;
    var n: usize = 0;
    while (n < 3 and end < err.len) : (n += 1) {
        end = if (std.mem.indexOfScalarPos(u8, err, end, '\n')) |nl| nl + 1 else err.len;
    }
    res.tail = try keep.dupe(u8, std.mem.trimEnd(u8, err[0..end], "\n"));
    return res;
}

/// `^(\d+) errors out of (\d+) tests in (.*) - (\d+) skipped\.$`
fn parseSummary(line: []const u8) ?[2]u64 {
    var rest = line;
    const e = takeNumber(&rest) orelse return null;
    if (!std.mem.startsWith(u8, rest, " errors out of ")) return null;
    rest = rest[" errors out of ".len..];
    const t = takeNumber(&rest) orelse return null;
    if (!std.mem.startsWith(u8, rest, " tests in ")) return null;
    rest = rest[" tests in ".len..];
    if (!std.mem.endsWith(u8, rest, " skipped.")) return null;
    rest = rest[0 .. rest.len - " skipped.".len];
    // (.*) - (\d+): the last " - " followed by digits only.
    const dash = std.mem.lastIndexOf(u8, rest, " - ") orelse return null;
    const digits = rest[dash + 3 ..];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return .{ e, t };
}

fn takeNumber(s: *[]const u8) ?u64 {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s.*[n])) n += 1;
    if (n == 0) return null;
    const v = std.fmt.parseUnsigned(u64, s.*[0..n], 10) catch return null;
    s.* = s.*[n..];
    return v;
}

/// `^(.*?):(\d+): (.*)$`: the first ":DIGITS: " in the line.
fn parseFailure(line: []const u8) ?struct { path: []const u8, line: u32, msg: []const u8 } {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, ':')) |colon| : (i = colon + 1) {
        var j = colon + 1;
        while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
        if (j == colon + 1 or !std.mem.startsWith(u8, line[j..], ": ")) continue;
        const n = std.fmt.parseUnsigned(u32, line[colon + 1 .. j], 10) catch continue;
        return .{ .path = line[0..colon], .line = n, .msg = line[j + 2 ..] };
    }
    return null;
}

/// The line numbers the C reference runner reports as failing.
fn runRef(c: *Check, ctx: *Ctx, path: []const u8, res: *Result) !void {
    const abs = try absolute(c.arena, c.io, path);
    const r = try c.run(&.{ ctx.ref.?, "-verify", abs }, .{ .cwd = "/tmp", .timeout_ms = ctx.timeout_ms });
    if (r.timedOut()) return;
    var lines: std.ArrayList(u32) = .empty;
    for ([_][]const u8{ r.stdout, r.stderr }) |text| {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| if (parseFailure(line)) |f| try lines.append(c.keep, f.line);
    }
    res.shared = lines.items;
}

/// The failure message with its specifics taken out, to group by.
fn cause(arena: Allocator, msg: []const u8) ![]const u8 {
    for ([_][]const u8{ "wrong result", "too many result rows", "too few result rows" }) |p| {
        if (std.mem.startsWith(u8, msg, p))
            return msg[0 .. std.mem.indexOf(u8, msg, " - ") orelse msg.len];
    }
    if (std.mem.startsWith(u8, msg, "labeled result")) return "labeled result does not agree";
    for ([_][]const u8{ "statement error: ", "query failed: " }) |p| {
        if (std.mem.startsWith(u8, msg, p)) {
            const detail = try numbersToN(arena, try nearX(arena, msg[p.len..]));
            return std.mem.concat(arena, u8, &.{ p, detail });
        }
    }
    return numbersToN(arena, msg);
}

/// re.sub(r'near "[^"]*"', 'near "X"', s)
fn nearX(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "near \"")) {
            if (std.mem.indexOfScalarPos(u8, s, i + 6, '"')) |close| {
                try out.appendSlice(arena, "near \"X\"");
                i = close + 1;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// re.sub(r'\b\d+\b', 'N', s): runs of digits between non-word characters.
fn numbersToN(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.ascii.isDigit(s[i]) and (i == 0 or !isWord(s[i - 1]))) {
            var j = i;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j == s.len or !isWord(s[j])) {
                try out.append(arena, 'N');
                i = j;
                continue;
            }
            try out.appendSlice(arena, s[i..j]);
            i = j;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// A regex word character (anything past ASCII counts as one).
fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

test cause {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("wrong result", try cause(a, "wrong result - 3 values"));
    try std.testing.expectEqualStrings(
        "statement error: near \"X\": syntax error at N",
        try cause(a, "statement error: near \"FOO\": syntax error at 12"),
    );
    try std.testing.expectEqualStrings("query failed: no such table: t1", try cause(a, "query failed: no such table: t1"));
    try std.testing.expectEqualStrings("x N y2 7_ (N)", try cause(a, "x 5 y2 7_ (12)"));
}

test parseSummary {
    try std.testing.expectEqual([2]u64{ 2, 100 }, parseSummary("2 errors out of 100 tests in a - b.test - 0 skipped.").?);
    try std.testing.expect(parseSummary("2 errors out of 100 tests in x - skipped.") == null);
}

test parseFailure {
    const f = parseFailure("a/b.test:12: wrong result: x:3: y").?;
    try std.testing.expectEqualStrings("a/b.test", f.path);
    try std.testing.expectEqual(12, f.line);
    try std.testing.expectEqualStrings("wrong result: x:3: y", f.msg);
}
