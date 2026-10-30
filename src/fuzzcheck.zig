//! A port of SQLite's fuzzcheck (test/fuzzcheck.c): run the fuzz corpora
//! of the SQLite source tree (test/fuzzdata*.db) and report what must never
//! happen, whatever the input: a crash or failed assertion, a memory leak,
//! a connection that does not close. Query results are not checked.
//!
//! Each corpus file holds SQL scripts (table xsql) and database images
//! (table db). Every script runs against every image, each case on a fresh
//! in-memory file system, or against an empty database if the file has no
//! images. A script that is a dbsqlfuzz case carries its own database, as a
//! hex dump before the SQL.
//!
//! Not ported: the query-invariant checks of runDbSql(), the dbconfig and
//! optimization flags of dbsqlfuzz cases, the recovery extension, OOM
//! injection, and the authorizer that blocks ATTACH of real files (every
//! file here lives in memory). The progress-handler timeout becomes a
//! watchdog thread that interrupts the connection.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const xqlite = @import("xqlite");

const sql = xqlite.sql;
const api = sql.api;
const RC = sql.RC;
const Sqlite3 = sql.Sqlite3;

pub const Error = error{ OutOfMemory, WriteFailed };

const usage =
    \\usage: xqlite fuzzcheck [options] DATABASE...
    \\
    \\Run the SQL fuzz cases of each DATABASE (a test/fuzzdata*.db file of
    \\the SQLite source tree) and report crashes, memory leaks and
    \\connections that fail to close. A crash names the case it happened in.
    \\
    \\options:
    \\  --sqlid N       run only the script with this id
    \\  --dbid N        run only against the database image with this id
    \\  --start N       skip the first N cases of each DATABASE (to go on
    \\                  past a crash, which names the case's number)
    \\  --timeout MS    interrupt a case after MS milliseconds (default 10000)
    \\  -v, --verbose   print the name of each case before running it
    \\
;

const Options = struct {
    sqlid: ?i64 = null,
    dbid: ?i64 = null,
    start: u32 = 0,
    timeout_ms: i64 = 10_000,
    verbose: bool = false,
};

/// MX_FILE_SZ: the largest database a dbsqlfuzz case may decode to.
const max_file_size = 10_000_000;

/// The memory a case may use before allocations fail (heapLimit).
const heap_limit = 100_000_000;

/// The case being run, for `panic` to name. The one process-wide variable
/// of the command (tools/globals_test.zig lists it): a panic handler has no
/// other way to reach it.
var current: struct { buf: [64]u8 = undefined, len: usize = 0 } = .{};

/// The executable's panic handler: name the fuzz case, if one is running,
/// then panic as usual.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (current.len > 0) std.debug.print("\nfuzzcheck: crashed in {s}\n", .{current.buf[0..current.len]});
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// The `fuzzcheck` command. Returns the exit code: 0 if every case passed.
pub fn run(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer, err_out: *Io.Writer) Error!u8 {
    var opts: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--sqlid") and has_value) {
            i += 1;
            opts.sqlid = std.fmt.parseInt(i64, args[i], 10) catch return usageError(err_out);
        } else if (std.mem.eql(u8, a, "--dbid") and has_value) {
            i += 1;
            opts.dbid = std.fmt.parseInt(i64, args[i], 10) catch return usageError(err_out);
        } else if (std.mem.eql(u8, a, "--start") and has_value) {
            i += 1;
            opts.start = std.fmt.parseInt(u32, args[i], 10) catch return usageError(err_out);
        } else if (std.mem.eql(u8, a, "--timeout") and has_value) {
            i += 1;
            opts.timeout_ms = std.fmt.parseInt(i64, args[i], 10) catch return usageError(err_out);
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(err_out);
        } else {
            try files.append(gpa, a);
        }
    }
    if (files.items.len == 0) return usageError(err_out);

    // Count the library's memory, to find leaks and to bound each case.
    const saved_malloc = xqlite.malloc.configGetMalloc();
    var counter: Counter = .{ .backing = saved_malloc };
    xqlite.malloc.configMalloc(counter.allocator());
    defer xqlite.malloc.configMalloc(saved_malloc);

    var watchdog: Watchdog = .{ .io = io };
    // Single-threaded builds (WebAssembly) run without a watchdog.
    const thread: ?std.Thread = if (@import("builtin").single_threaded) null else std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch {
        try err_out.print("fuzzcheck: cannot start the watchdog thread\n", .{});
        try err_out.flush();
        return 1;
    };
    defer if (thread) |t| {
        watchdog.mutex.lockUncancelable(io);
        watchdog.stop = true;
        watchdog.mutex.unlock(io);
        t.join();
    };

    var r: Runner = .{ .gpa = gpa, .io = io, .opts = opts, .out = out, .counter = &counter, .watchdog = &watchdog };
    var failed = false;
    for (files.items) |path| {
        if (!try r.runFile(path)) failed = true;
        try out.flush();
    }
    return @intFromBool(failed);
}

fn usageError(err_out: *Io.Writer) Error!u8 {
    try err_out.writeAll(usage);
    try err_out.flush();
    return 2;
}

/// A blob of a corpus file: a script or a database image.
const Blob = struct { id: i64, bytes: []const u8 };

const Runner = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    out: *Io.Writer,
    counter: *Counter,
    watchdog: *Watchdog,
    /// Results of the current file. `n_seen` counts the skipped cases too.
    n_seen: u32 = 0,
    n_case: u32 = 0,
    n_fail: u32 = 0,
    n_timeout: u32 = 0,

    /// Run every case of the corpus at `path`. Returns false if one failed.
    fn runFile(r: *Runner, path: []const u8) Error!bool {
        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        r.n_seen = 0;
        r.n_case = 0;
        r.n_fail = 0;
        r.n_timeout = 0;

        var scripts: std.ArrayList(Blob) = .empty;
        var images: std.ArrayList(Blob) = .empty;
        loadCorpus(arena, r.io, path, &scripts, &images) catch |err| {
            try r.out.print("{s}: cannot read: {s}\n", .{ path, @errorName(err) });
            return false;
        };
        // No images: the scripts run against an empty database.
        if (images.items.len == 0) try images.append(arena, .{ .id = 1, .bytes = "" });

        const start = Io.Clock.awake.now(r.io).toMilliseconds();
        for (scripts.items) |script| {
            if (r.opts.sqlid) |id| if (id != script.id) continue;
            if (isDbSql(script.bytes)) {
                if (r.opts.dbid != null) continue;
                try r.runCase(arena, script.id, null, script.bytes);
                continue;
            }
            for (images.items) |image| {
                if (r.opts.dbid) |id| if (id != image.id) continue;
                try r.runCase(arena, script.id, image, script.bytes);
            }
        }
        const elapsed: u64 = @intCast(Io.Clock.awake.now(r.io).toMilliseconds() - start);
        try r.out.print("{s}: {d} cases, {d} failed, {d} timed out, {d}.{d:0>3}s\n", .{
            path, r.n_case, r.n_fail, r.n_timeout, elapsed / 1000, elapsed % 1000,
        });
        return r.n_fail == 0;
    }

    /// Run one case: `script` against `image`, or a dbsqlfuzz case
    /// (`image` null) against the database it carries.
    fn runCase(r: *Runner, arena: Allocator, sqlid: i64, image: ?Blob, script: []const u8) Error!void {
        const index = r.n_seen;
        r.n_seen += 1;
        if (index < r.opts.start) return;
        var name_buf: [64]u8 = undefined;
        const name = if (image) |img|
            std.fmt.bufPrint(&name_buf, "case {d} (sqlid={d},dbid={d})", .{ index, sqlid, img.id }) catch unreachable
        else
            std.fmt.bufPrint(&name_buf, "case {d} (sqlid={d})", .{ index, sqlid }) catch unreachable;
        @memcpy(current.buf[0..name.len], name);
        current.len = name.len;
        defer current.len = 0;
        if (r.opts.verbose) {
            try r.out.print("{s}\n", .{name});
            try r.out.flush();
        }
        r.n_case += 1;

        // C strings: a script ends at its first NUL.
        var text = script[0 .. std.mem.indexOfScalar(u8, script, 0) orelse script.len];
        var db_bytes: []const u8 = if (image) |img| img.bytes else "";
        if (image == null) {
            const decoded = decodeDatabase(arena, script) orelse return;
            db_bytes = decoded.db;
            text = decoded.sql[0 .. std.mem.indexOfScalar(u8, decoded.sql, 0) orelse decoded.sql.len];
        }

        const used_before = r.counter.used;
        // After mem.deinit() below: the files' memory counts too.
        defer r.checkLeak(name, used_before);
        // The files are the library's memory, under the heap limit, as
        // fuzzcheck.c's memdb takes its pages from sqlite3_malloc().
        var mem = xqlite.MemVfs.init(r.counter.allocator(), r.io);
        defer mem.deinit();
        if (db_bytes.len > 0) {
            const f = mem.interface().open("main.db", .{ .create = true }) catch return error.OutOfMemory;
            defer f.close();
            f.write(db_bytes, 0) catch return error.OutOfMemory;
        }
        r.counter.limit = used_before + heap_limit;
        defer r.counter.limit = std.math.maxInt(usize);

        var opened: ?*Sqlite3 = null;
        _ = sql.main.open(mem.interface(), "main.db", .{}, &opened);
        const db = opened orelse return;
        if (image == null) {
            _ = sql.main.limit(db, .length, 1_000_000);
            _ = sql.main.limit(db, .expr_depth, 500);
            _ = sql.main.limit(db, .vdbe_op, 25_000);
            _ = sql.main.limit(db, .like_pattern_length, 100);
        } else {
            _ = sql.main.limit(db, .length, 100_000_000);
            _ = sql.main.limit(db, .like_pattern_length, 50);
        }

        r.watchdog.arm(db, r.opts.timeout_ms);
        if (image == null) runStatements(db, text, r.watchdog) else runScript(db, text, r.watchdog);
        const timed_out = r.watchdog.disarm();
        if (timed_out) r.n_timeout += 1;

        const close_rc = sql.main.close(db);
        if (close_rc != RC.OK) {
            r.n_fail += 1;
            try r.out.print("{s}: close() returned {d}\n", .{ name, close_rc });
        }
    }

    fn checkLeak(r: *Runner, name: []const u8, used_before: usize) void {
        if (r.counter.used == used_before) return;
        r.n_fail += 1;
        r.out.print("{s}: memory leak: {d} bytes\n", .{ name, @as(i64, @intCast(r.counter.used)) - @as(i64, @intCast(used_before)) }) catch {};
    }
};

/// Read the scripts and database images of a corpus file.
fn loadCorpus(arena: Allocator, io: Io, path: []const u8, scripts: *std.ArrayList(Blob), images: *std.ArrayList(Blob)) !void {
    var unix = xqlite.OsVfs.init(arena, io);
    var opened: ?*Sqlite3 = null;
    const rc = sql.main.open(unix.interface(), path, .{ .read_only = true, .create = false }, &opened);
    const db = opened orelse return error.OutOfMemory;
    defer _ = sql.main.close(db);
    if (rc != RC.OK) return error.CannotOpen;
    try loadBlobs(arena, db, "SELECT sqlid, sqltext FROM xsql ORDER BY sqlid", scripts);
    try loadBlobs(arena, db, "SELECT dbid, dbcontent FROM db ORDER BY dbid", images);
}

fn loadBlobs(arena: Allocator, db: *Sqlite3, query: []const u8, list: *std.ArrayList(Blob)) !void {
    var stmt_opt: ?*sql.Stmt = null;
    if (sql.prepare.prepareV2(db, query, &stmt_opt, null) != RC.OK) return error.NotACorpus;
    const stmt = stmt_opt.?;
    defer _ = api.finalize(stmt);
    var rc = api.step(stmt);
    while (rc == RC.ROW) : (rc = api.step(stmt)) {
        const bytes = api.columnBlob(stmt, 1) orelse "";
        try list.append(arena, .{ .id = api.columnInt64(stmt, 0), .bytes = try arena.dupe(u8, bytes) });
    }
    if (rc != RC.DONE) return error.NotACorpus;
}

/// Port of runSql(): run every statement of `text`, ignoring errors.
fn runScript(db: *Sqlite3, text: []const u8, watchdog: *const Watchdog) void {
    var rest = text;
    while (rest.len > 0 and !watchdog.timed_out.load(.monotonic)) {
        var stmt: ?*sql.Stmt = null;
        var tail = rest;
        _ = sql.prepare.prepareV2(db, rest, &stmt, &tail);
        if (tail.ptr == rest.ptr) break;
        rest = tail;
        if (stmt) |s| runStatement(s);
    }
}

/// The SQL loop of runCombinedDbSqlInput(): split the script into complete
/// statements and run each (runDbSql()).
fn runStatements(db: *Sqlite3, text: []const u8, watchdog: *const Watchdog) void {
    var j: usize = 0;
    for (text, 0..) |c, i| {
        if (c != ';') continue;
        if (sql.complete.complete(text[j .. i + 1])) {
            runOne(db, text[j .. i + 1]);
            j = i + 1;
        }
        if (watchdog.timed_out.load(.monotonic)) return;
    }
    if (j < text.len) runOne(db, text[j..]);
}

/// Port of runDbSql() without its invariant checks: run the first
/// statement of `text`.
fn runOne(db: *Sqlite3, text: []const u8) void {
    const trimmed = std.mem.trimStart(u8, text, " \t\n\r\x0b\x0c");
    if (trimmed.len == 0) return;
    var stmt: ?*sql.Stmt = null;
    if (sql.prepare.prepareV2(db, trimmed, &stmt, null) != RC.OK) {
        if (stmt) |s| _ = api.finalize(s);
        return;
    }
    if (stmt) |s| runStatement(s);
}

fn runStatement(stmt: *sql.Stmt) void {
    while (api.step(stmt) == RC.ROW) {}
    _ = api.finalize(stmt);
}

// ================================================================= dbsqlfuzz

/// Port of isDbSql(): whether a script starts with a database description,
/// as a dbsqlfuzz case does.
fn isDbSql(a_arg: []const u8) bool {
    if (a_arg.len > 4 and std.mem.eql(u8, a_arg[0..4], "\n--\n")) return true;
    var a = std.mem.trimStart(u8, a_arg, " \t\n\r\x0b\x0c");
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    while (a.len > 0 and n < 8) : (a = a[1..]) {
        if (std.ascii.isHex(a[0])) {
            buf[n] = std.ascii.toLower(a[0]);
            n += 1;
        }
    }
    return n == 8 and std.mem.eql(u8, &buf, "53514c69");
}

/// Port of decodeDatabase(): the database image a dbsqlfuzz case encodes
/// as hex digits, with "[offset]" jumps, up to a "\n--\n" line, and the
/// SQL after it. Null if the image is missing or too large.
fn decodeDatabase(arena: Allocator, in: []const u8) ?struct { db: []u8, sql: []const u8 } {
    if (in.len < 4) return null;
    var a: std.ArrayList(u8) = .empty;
    var size: usize = 0;
    var k: usize = 0;
    var b: u8 = 0;
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        const c = in[i];
        if (std.ascii.isHex(c)) {
            k += 1;
            const nibble = std.fmt.charToDigit(c, 16) catch unreachable;
            if (k & 1 != 0) {
                b = nibble * 16;
                continue;
            }
            b += nibble;
            const j = k / 2 - 1;
            if (j >= max_file_size) return null;
            if (j >= a.items.len) {
                const old = a.items.len;
                a.resize(arena, (j + 4096) & ~@as(usize, 4095)) catch return null;
                @memset(a.items[old..], 0);
            }
            if (j >= size) size = @min((j + 4095) & ~@as(usize, 4095), max_file_size);
            a.items[j] = b;
        } else if (c == '[' and i + 3 < in.len) {
            if (parseOffset(in[i..])) |o| {
                k = 2 * @as(usize, o.offset);
                i += o.end;
            }
        } else if (c == '\n' and i + 4 < in.len and std.mem.eql(u8, in[i..][0..4], "\n--\n")) {
            i += 4;
            break;
        }
    }
    const db = a.items[0..@min(size, a.items.len)];
    // A WAL-mode image cannot be opened from memory alone.
    if (db.len >= 20 and db[18] == 2 and db[19] == 2) {
        db[18] = 1;
        db[19] = 1;
    }
    return .{ .db = db, .sql = in[@min(i, in.len)..] };
}

/// Port of isOffset(): `in` starts with "[hex]", which moves the output to
/// that byte offset; `end` is the index of the "]". The value wraps at 32
/// bits, as the C unsigned int does.
fn parseOffset(in: []const u8) ?struct { offset: u32, end: usize } {
    var v: u32 = 0;
    for (in[1..], 1..) |c, i| {
        if (c == ']') return .{ .offset = v, .end = i };
        const d = std.fmt.charToDigit(c, 16) catch return null;
        v = v *% 16 +% d;
    }
    return null;
}

// ============================================================ infrastructure

/// The library's allocator during the run: counts the bytes in use, so a
/// case can be checked for leaks, and fails allocations past `limit`, like
/// the hard heap limit of fuzzcheck.c.
const Counter = struct {
    backing: Allocator,
    used: usize = 0,
    limit: usize = std.math.maxInt(usize),

    fn allocator(c: *Counter) Allocator {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn of(ptr: *anyopaque) *Counter {
        return @ptrCast(@alignCast(ptr));
    }

    fn fits(c: *const Counter, old_len: usize, new_len: usize) bool {
        return new_len <= old_len or c.used + (new_len - old_len) <= c.limit;
    }

    fn alloc(ptr: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const c = of(ptr);
        if (!c.fits(0, len)) return null;
        const p = c.backing.rawAlloc(len, a, ra) orelse return null;
        c.used += len;
        return p;
    }

    fn resize(ptr: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const c = of(ptr);
        if (!c.fits(memory.len, new_len) or !c.backing.rawResize(memory, a, new_len, ra)) return false;
        c.used = c.used - memory.len + new_len;
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c = of(ptr);
        if (!c.fits(memory.len, new_len)) return null;
        const p = c.backing.rawRemap(memory, a, new_len, ra) orelse return null;
        c.used = c.used - memory.len + new_len;
        return p;
    }

    fn free(ptr: *anyopaque, memory: []u8, a: Alignment, ra: usize) void {
        const c = of(ptr);
        c.backing.rawFree(memory, a, ra);
        c.used -= memory.len;
    }
};

/// Interrupts the connection of a case that runs past its deadline (the
/// progress handler of fuzzcheck.c). The mutex keeps the connection from
/// closing while the thread interrupts it.
const Watchdog = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    db: ?*Sqlite3 = null,
    deadline_ms: i64 = 0,
    stop: bool = false,
    /// The case of `db` was interrupted.
    timed_out: std.atomic.Value(bool) = .init(false),

    fn arm(w: *Watchdog, db: *Sqlite3, timeout_ms: i64) void {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        w.db = db;
        w.deadline_ms = Io.Clock.awake.now(w.io).toMilliseconds() + timeout_ms;
        w.timed_out.store(false, .monotonic);
    }

    /// Stop watching the connection. Returns whether it timed out.
    fn disarm(w: *Watchdog) bool {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        w.db = null;
        return w.timed_out.load(.monotonic);
    }

    fn run(w: *Watchdog) void {
        while (true) {
            w.io.sleep(.fromMilliseconds(20), .awake) catch {};
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            if (w.stop) return;
            const db = w.db orelse continue;
            if (Io.Clock.awake.now(w.io).toMilliseconds() < w.deadline_ms) continue;
            w.timed_out.store(true, .monotonic);
            // Keep interrupting: a statement that starts later resets the flag.
            db.is_interrupted.store(true, .monotonic);
        }
    }
};

test "isDbSql and decodeDatabase" {
    try std.testing.expect(isDbSql("\n--\nSELECT 1;"));
    try std.testing.expect(isDbSql("  53 51 4c 69 74 65"));
    try std.testing.expect(!isDbSql("SELECT 1;"));

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const d = decodeDatabase(arena_state.allocator(), "53514c69[10]ff\n--\nSELECT 1;").?;
    try std.testing.expectEqual(@as(usize, 4096), d.db.len);
    try std.testing.expectEqualSlices(u8, "SQLi", d.db[0..4]);
    try std.testing.expectEqual(@as(u8, 0xff), d.db[0x10]);
    try std.testing.expectEqualStrings("SELECT 1;", d.sql);
}
