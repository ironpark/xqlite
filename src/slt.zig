//! A sqllogictest runner: port of sqllogictest.c in verify mode, with the
//! SQLite engine of slt_sqlite.c (sqliteStatement(), sqliteQuery()).
//!
//! Differences from the C program: several script files can be given, each
//! on a fresh database; a failing query counts as one error, not one per
//! wrong value; failures name the engine's error message, and `-v` prints
//! the SQL, so failures can be grouped by cause.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqlite = @import("xqlite");

const sql = xqlite.sql;
const api = sql.api;
const RC = sql.RC;
const Sqlite3 = sql.Sqlite3;

pub const Error = error{ OutOfMemory, WriteFailed };

const SQLITE_NULL = 5;

const usage =
    \\usage: xqlite slt [options] SCRIPT...
    \\
    \\Run sqllogictest scripts, each on a fresh database, and report the
    \\records whose results differ from the expected ones.
    \\
    \\options:
    \\  --db FILE          the database file (deleted first); default in memory
    \\  --halt             stop a script at its first error
    \\  --ht NUM           hash results of more than NUM values, overriding
    \\                     the scripts' hash-threshold records
    \\  --integrity-check  run PRAGMA integrity_check after every statement
    \\  --journal-mode M   run each script with PRAGMA journal_mode=M, on a
    \\                     file (--db, else a fresh one in /tmp per script)
    \\  --wal              the same as --journal-mode wal
    \\  -v, --verbose      print the SQL of each failing record
    \\
;

const Options = struct {
    db_path: ?[]const u8 = null,
    halt: bool = false,
    hash_threshold: ?i32 = null,
    integrity_check: bool = false,
    /// PRAGMA journal_mode for every script; needs a database file.
    journal_mode: ?[]const u8 = null,
    verbose: bool = false,
};

/// The engine name the scripts' skipif/onlyif records test.
const engine_name = "sqlite";

/// DEFAULT_HASH_THRESHOLD.
const default_hash_threshold = 8;

/// The `slt` command. Returns the exit code: 0 if every script passed.
pub fn run(gpa: Allocator, io: Io, args: []const []const u8, out: *Io.Writer, err_out: *Io.Writer) Error!u8 {
    var opts: Options = .{};
    var scripts: std.ArrayList([]const u8) = .empty;
    defer scripts.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--db") and has_value) {
            i += 1;
            opts.db_path = args[i];
        } else if (std.mem.eql(u8, a, "--halt")) {
            opts.halt = true;
        } else if (std.mem.eql(u8, a, "--ht") and has_value) {
            i += 1;
            opts.hash_threshold = std.fmt.parseInt(i32, args[i], 10) catch return usageError(err_out);
        } else if (std.mem.eql(u8, a, "--integrity-check")) {
            opts.integrity_check = true;
        } else if (std.mem.eql(u8, a, "--journal-mode") and has_value) {
            i += 1;
            opts.journal_mode = args[i];
        } else if (std.mem.eql(u8, a, "--wal")) {
            opts.journal_mode = "wal";
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(err_out);
        } else {
            try scripts.append(gpa, a);
        }
    }
    if (scripts.items.len == 0) return usageError(err_out);

    var n_failed: usize = 0;
    for (scripts.items, 0..) |path, n_script| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try err_out.print("{s}: cannot open for reading: {s}\n", .{ path, @errorName(e) });
            try err_out.flush();
            n_failed += 1;
            continue;
        };
        defer gpa.free(text);
        var runner: Runner = .{ .gpa = gpa, .io = io, .opts = opts, .path = path, .out = out, .n_script = n_script };
        const n_err = try runner.runScript(text);
        if (n_err != 0) n_failed += 1;
        try out.flush();
    }
    return if (n_failed == 0) 0 else 1;
}

fn usageError(err_out: *Io.Writer) Error!u8 {
    try err_out.writeAll(usage);
    try err_out.flush();
    return 2;
}

/// Port of the Script object: the scan of a script, a line at a time.
const Script = struct {
    z: []const u8,
    /// Start of the current line.
    i_cur: usize = 0,
    /// The current line, without its \r\n; empty if all spaces.
    line: []const u8 = "",
    /// Start of the next line.
    i_next: usize = 0,
    /// Line number of the current line.
    n_line: u32 = 0,
    /// Line number of the first line of the current record.
    start_line: u32 = 0,
    /// The first four tokens of the record's first line.
    tokens: [4][]const u8 = @splat(""),

    /// Port of nextLine(): advance to the next non-comment line. False at
    /// the end of the script.
    fn nextLine(s: *Script) bool {
        while (true) {
            if (s.i_next >= s.z.len) {
                s.i_cur = s.z.len;
                s.line = "";
                return false;
            }
            s.i_cur = s.i_next;
            s.n_line += 1;
            const end = std.mem.indexOfScalarPos(u8, s.z, s.i_cur, '\n') orelse s.z.len;
            var line = s.z[s.i_cur..end];
            s.i_next = end + 1;
            if (line.len > 0 and line[line.len - 1] == '\r') line.len -= 1;
            if (std.mem.trimEnd(u8, line, &std.ascii.whitespace).len == 0) line = line[0..0];
            s.line = line;
            if (line.len == 0 or line[0] != '#') return true;
        }
    }

    /// Port of nextIsBlank(): whether the next line is blank.
    fn nextIsBlank(s: *const Script) bool {
        var i = s.i_next;
        if (i >= s.z.len) return true;
        while (i < s.z.len and std.ascii.isWhitespace(s.z[i])) : (i += 1) {
            if (s.z[i] == '\n') return true;
        }
        return false;
    }

    /// Port of findStartOfNextRecord(): skip the rest of the current
    /// record and the blank lines after it. False at the end of the script.
    fn findStartOfNextRecord(s: *Script) bool {
        if (s.i_cur > 0) {
            while (s.line.len > 0 and s.i_cur < s.z.len) _ = s.nextLine();
        } else {
            _ = s.nextLine();
        }
        while (s.line.len == 0 and s.i_cur < s.z.len) _ = s.nextLine();
        return s.i_cur < s.z.len;
    }

    /// Port of tokenizeLine().
    fn tokenizeLine(s: *Script) void {
        s.tokens = @splat("");
        s.start_line = s.n_line;
        var it = std.mem.tokenizeAny(u8, s.line, &std.ascii.whitespace);
        for (&s.tokens) |*t| {
            const tok = it.next() orelse break;
            t.* = tok[0..@min(tok.len, 199)];
        }
    }
};

const Runner = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    path: []const u8,
    out: *Io.Writer,
    /// Position of the script on the command line.
    n_script: usize = 0,
    db: *Sqlite3 = undefined,
    n_err: u32 = 0,
    /// Per-record memory: the SQL, the results, messages.
    arena: std.heap.ArenaAllocator = undefined,
    /// The hashes of labeled results (checkValue()), by label.
    labels: std.StringHashMapUnmanaged([32]u8) = .empty,

    fn runScript(r: *Runner, text: []const u8) Error!u32 {
        r.arena = .init(r.gpa);
        defer r.arena.deinit();
        defer {
            var it = r.labels.keyIterator();
            while (it.next()) |k| r.gpa.free(k.*);
            r.labels.deinit(r.gpa);
        }

        var unix = xqlite.UnixVfs.init(r.gpa, r.io);
        // A journal mode needs a file; without --db, one per script and
        // process, so that parallel runs do not collide.
        const db_path: ?[]const u8 = r.opts.db_path orelse if (r.opts.journal_mode != null)
            try std.fmt.allocPrint(r.gpa, "/tmp/xqlite-slt-{d}-{d}.db", .{ std.c.getpid(), r.n_script })
        else
            null;
        defer if (r.opts.db_path == null) if (db_path) |p| {
            r.deleteDbFiles(p);
            r.gpa.free(p);
        };
        const filename = db_path orelse ":memory:";
        if (db_path) |p| r.deleteDbFiles(p);
        if (sql.main.open(unix.interface(), filename, .{}, &r.db) != RC.OK) {
            try r.out.print("{s}: unable to connect to database: {s}\n", .{ r.path, sql.main.errmsg(r.db) });
            _ = sql.main.close(r.db);
            return 1;
        }
        defer _ = sql.main.close(r.db);
        _ = sql.legacy.exec(r.db, "PRAGMA synchronous=OFF", null, null, null);
        if (r.opts.journal_mode) |mode| {
            if (!try r.setJournalMode(mode)) {
                try r.out.print("{s}: cannot set journal_mode={s}: {s}\n", .{ r.path, mode, sql.main.errmsg(r.db) });
                return 1;
            }
        }

        var s: Script = .{ .z = text };
        var hash_threshold: i32 = r.opts.hash_threshold orelse default_hash_threshold;
        var n_cmd: u32 = 0;
        var n_skipped: u32 = 0;
        while ((r.n_err == 0 or !r.opts.halt) and s.findStartOfNextRecord()) {
            _ = r.arena.reset(.retain_capacity);
            s.tokenizeLine();
            var skip = false;
            while (eql(s.tokens[0], "skipif") or eql(s.tokens[0], "onlyif")) {
                const match = std.ascii.eqlIgnoreCase(s.tokens[1], engine_name);
                if (s.tokens[0][0] == 's') {
                    if (match) skip = true;
                } else if (!match) skip = true;
                _ = s.nextLine();
                s.tokenizeLine();
            }
            if (skip) {
                n_skipped += 1;
                try r.checkSkippedLabel(&s);
                continue;
            }

            if (eql(s.tokens[0], "statement")) {
                n_cmd += 1;
                try r.statement(&s);
            } else if (eql(s.tokens[0], "query")) {
                const types = s.tokens[1];
                const bad = for (types) |c| {
                    if (c != 'T' and c != 'I' and c != 'R') break c;
                } else null;
                if (bad) |c| {
                    try r.fail(&s, "unknown type character '{c}' in type string", .{c});
                    continue;
                }
                if (types.len == 0) {
                    try r.fail(&s, "missing type string", .{});
                    break;
                }
                n_cmd += 1;
                try r.query(&s, hash_threshold);
            } else if (eql(s.tokens[0], "hash-threshold")) {
                if (r.opts.hash_threshold == null) hash_threshold = std.fmt.parseInt(i32, s.tokens[1], 10) catch 0;
            } else if (eql(s.tokens[0], "halt")) {
                try r.out.print("{s}:{d}: halt\n", .{ r.path, s.start_line });
                break;
            } else {
                try r.fail(&s, "unknown record type: '{s}'", .{s.tokens[0]});
                break;
            }
        }
        try r.out.print("{d} errors out of {d} tests in {s} - {d} skipped.\n", .{ r.n_err, n_cmd, r.path, n_skipped });
        return r.n_err;
    }

    /// Removes a database file and its journal, WAL and shared memory.
    fn deleteDbFiles(r: *Runner, p: []const u8) void {
        Io.Dir.cwd().deleteFile(r.io, p) catch {};
        for ([_][]const u8{ "-journal", "-wal", "-shm" }) |suffix| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "{s}{s}", .{ p, suffix }) catch continue;
            Io.Dir.cwd().deleteFile(r.io, name) catch {};
        }
    }

    /// PRAGMA journal_mode=MODE; whether the mode took effect.
    fn setJournalMode(r: *Runner, mode: []const u8) Error!bool {
        const text = try std.fmt.allocPrint(r.arena.allocator(), "PRAGMA journal_mode={s}", .{mode});
        var stmt_opt: ?*sql.Stmt = null;
        if (sql.prepare.prepareV2(r.db, text, &stmt_opt, null) != RC.OK) return false;
        const stmt = stmt_opt orelse return false;
        defer _ = api.finalize(stmt);
        if (api.step(stmt) != RC.ROW) return false;
        const z = api.columnText(stmt, 0) orelse return false;
        return std.ascii.eqlIgnoreCase(z, mode);
    }

    /// Report a failure of the current record.
    fn fail(r: *Runner, s: *const Script, comptime fmt: []const u8, args: anytype) Error!void {
        r.n_err += 1;
        try r.out.print("{s}:{d}: " ++ fmt ++ "\n", .{ r.path, s.start_line } ++ args);
    }

    fn printSql(r: *Runner, text: []const u8) Error!void {
        if (!r.opts.verbose) return;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try r.out.print("    {s}\n", .{line});
    }

    /// The text of the record's following lines up to a blank line (for a
    /// statement) or a "----" line (for a query).
    fn recordSql(r: *Runner, s: *Script, is_query: bool) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const a = r.arena.allocator();
        while (if (is_query) !s.nextIsBlank() else true) {
            if (!s.nextLine() or s.line.len == 0) break;
            if (is_query and eql(s.line, "----")) break;
            if (buf.items.len > 0) try buf.append(a, '\n');
            try buf.appendSlice(a, s.line);
        }
        return buf.items;
    }

    /// A "statement ok" or "statement error" record (sqliteStatement()).
    fn statement(r: *Runner, s: *Script) Error!void {
        const text = try r.recordSql(s, false);
        const expect_ok = eql(s.tokens[1], "ok");
        if (!expect_ok and !eql(s.tokens[1], "error")) {
            return r.fail(s, "statement argument should be 'ok' or 'error'", .{});
        }
        var msg: ?[:0]u8 = null;
        var rc = sql.legacy.exec(r.db, text, null, null, &msg);
        defer if (msg) |m| xqlite.malloc.free(m.ptr);
        var check_msg: ?[]const u8 = null;
        if (rc == RC.OK and r.opts.integrity_check) {
            check_msg = try r.integrityCheck();
            if (check_msg != null) rc = RC.ERROR;
        }
        if (expect_ok and rc != RC.OK) {
            if (check_msg) |m| {
                try r.fail(s, "statement error: integrity_check returns: {s}", .{m});
            } else {
                try r.fail(s, "statement error: {s}", .{msg orelse sql.main.errmsg(r.db)});
            }
            try r.printSql(text);
        } else if (!expect_ok and rc == RC.OK) {
            try r.fail(s, "statement error: expected an error", .{});
            try r.printSql(text);
        }
    }

    /// PRAGMA integrity_check after a statement: null if it says "ok",
    /// else what it says.
    fn integrityCheck(r: *Runner) Error!?[]const u8 {
        var stmt_opt: ?*sql.Stmt = null;
        if (sql.prepare.prepareV2(r.db, "PRAGMA integrity_check;", &stmt_opt, null) != RC.OK) return "cannot prepare integrity_check";
        const stmt = stmt_opt.?;
        defer _ = api.finalize(stmt);
        if (api.step(stmt) != RC.ROW) return "cannot run integrity_check";
        const z = api.columnText(stmt, 0) orelse return "NULL";
        if (eql(z, "ok")) return null;
        return try r.arena.allocator().dupe(u8, z);
    }

    /// A "query" record (sqliteQuery() and the result checks of main()).
    fn query(r: *Runner, s: *Script, hash_threshold: i32) Error!void {
        const a = r.arena.allocator();
        const types = s.tokens[1];
        const text = try r.recordSql(s, true);

        // Run the query.
        var values: std.ArrayList([]const u8) = .empty;
        var step_err: ?[]const u8 = null;
        {
            var stmt_opt: ?*sql.Stmt = null;
            if (sql.prepare.prepareV2(r.db, text, &stmt_opt, null) != RC.OK) {
                if (stmt_opt) |st| _ = api.finalize(st);
                try r.fail(s, "query failed: {s}", .{sql.main.errmsg(r.db)});
                return r.printSql(text);
            }
            const stmt = stmt_opt orelse {
                try r.fail(s, "query failed: no statement", .{});
                return r.printSql(text);
            };
            defer _ = api.finalize(stmt);
            if (types.len != api.columnCount(stmt)) {
                try r.fail(s, "wrong number of result columns: expected {d} but got {d}", .{ types.len, api.columnCount(stmt) });
                return r.printSql(text);
            }
            var rc = api.step(stmt);
            while (rc == RC.ROW) : (rc = api.step(stmt)) {
                for (types, 0..) |t, i| try values.append(a, try columnValue(a, stmt, t, i));
            }
            // sqliteQuery() ignores errors while stepping; they only show
            // as wrong results, and as this note.
            if (rc != RC.DONE) step_err = try a.dupe(u8, sql.main.errmsg(r.db));
        }
        const res = values.items;

        // Sort the results.
        const sort = s.tokens[2];
        if (sort.len == 0 or eql(sort, "nosort")) {} else if (eql(sort, "rowsort")) {
            sortRows(a, res, types.len) catch return error.OutOfMemory;
        } else if (eql(sort, "valuesort")) {
            std.mem.sort([]const u8, res, {}, lessThanStr);
        } else {
            try r.fail(s, "unknown sort method: '{s}'", .{sort});
        }

        // Hash the results if there are more than the threshold, or a label.
        const label = s.tokens[3][0..@min(s.tokens[3].len, 20)];
        var hash_line: []const u8 = "";
        const use_hash = hash_threshold > 0 and res.len > hash_threshold;
        if (label.len > 0 or use_hash) {
            const hex = md5Hex(res);
            hash_line = try std.fmt.allocPrint(a, "{d} values hashing to {s}", .{ res.len, &hex });
            if (label.len > 0 and try r.checkValue(label, hex)) {
                try r.fail(s, "labeled result [{s}] does not agree with previous values", .{label});
            }
        }

        // Compare with the expected results.
        if (eql(s.line, "----")) _ = s.nextLine();
        if (!use_hash) {
            var i: usize = 0;
            var mismatch: ?struct { line: u32, expected: []const u8, got: []const u8 } = null;
            while (i < res.len and s.line.len > 0) : ({
                _ = s.nextLine();
                i += 1;
            }) {
                if (mismatch == null and !eql(s.line, res[i])) mismatch = .{ .line = s.n_line, .expected = s.line, .got = res[i] };
            }
            if (mismatch) |m| {
                try r.fail(s, "wrong result - expected [{s}] got [{s}] (line {d})", .{ m.expected, m.got, m.line });
            } else if (i < res.len) {
                try r.fail(s, "too many result rows - expected {d} got {d}", .{ i, res.len });
            } else if (s.line.len > 0) {
                while (s.line.len > 0) {
                    _ = s.nextLine();
                    i += 1;
                }
                try r.fail(s, "too few result rows - expected {d} got {d}", .{ i, res.len });
            } else return;
        } else if (!eql(s.line, hash_line)) {
            try r.fail(s, "wrong result hash - expected [{s}] got [{s}]", .{ s.line, hash_line });
        } else return;
        if (step_err) |m| try r.out.print("    (error while stepping: {s})\n", .{m});
        try r.printSql(text);
    }

    /// A skipped query with a label still has its expected results checked
    /// against those of the label's other queries.
    fn checkSkippedLabel(r: *Runner, s: *Script) Error!void {
        if (!eql(s.tokens[0], "query") or s.tokens[3].len == 0) return;
        while (!s.nextIsBlank() and s.nextLine() and !eql(s.line, "----")) {}
        if (eql(s.line, "----")) _ = s.nextLine();
        if (s.line.len == 0) return;
        var hex: [32]u8 = undefined;
        const prefix = " values hashing to ";
        if (std.mem.indexOf(u8, s.line, prefix)) |at| {
            const h = s.line[at + prefix.len ..];
            if (h.len < 32) return;
            hex = h[0..32].*;
        } else {
            var md5 = std.crypto.hash.Md5.init(.{});
            md5.update(s.line);
            md5.update("\n");
            while (!s.nextIsBlank() and s.nextLine()) {
                md5.update(s.line);
                md5.update("\n");
            }
            hex = std.fmt.bytesToHex(md5.finalResult(), .lower);
        }
        const label = s.tokens[3][0..@min(s.tokens[3].len, 20)];
        if (try r.checkValue(label, hex)) {
            try r.fail(s, "labeled result [{s}] does not agree with previous values", .{label});
        }
    }

    /// Port of checkValue(): remember the hash of `label`'s results the
    /// first time; after that, true if `hex` differs from it.
    fn checkValue(r: *Runner, label: []const u8, hex: [32]u8) Error!bool {
        const gop = try r.labels.getOrPut(r.gpa, label);
        if (gop.found_existing) return !std.mem.eql(u8, &gop.value_ptr.*, &hex);
        gop.key_ptr.* = r.gpa.dupe(u8, label) catch |e| {
            r.labels.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.value_ptr.* = hex;
        return false;
    }
};

/// A result value as sqliteQuery() renders it for type character `t`.
fn columnValue(a: Allocator, stmt: *sql.Stmt, t: u8, i: usize) Error![]const u8 {
    if (api.columnType(stmt, i) == SQLITE_NULL) return "NULL";
    switch (t) {
        'T' => {
            const z = api.columnText(stmt, i) orelse "";
            if (z.len == 0) return "(empty)";
            // Non-printing and control characters become '@'.
            const copy = try a.dupe(u8, z);
            for (copy) |*c| {
                if (c.* < ' ' or c.* > '~') c.* = '@';
            }
            return copy;
        },
        'I' => return std.fmt.allocPrint(a, "{d}", .{@as(i32, @truncate(api.columnInt64(stmt, i)))}),
        'R' => return xqlite.printf.mprintf(a, "%.3f", &.{.{ .double = api.columnDouble(stmt, i) }}) catch error.OutOfMemory,
        else => unreachable,
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Sort the rows of `n_col` values of `res` (rowCompare()).
fn sortRows(a: Allocator, res: [][]const u8, n_col: usize) Allocator.Error!void {
    const n_row = res.len / n_col;
    const rows = try a.alloc([]const []const u8, n_row);
    for (rows, 0..) |*row, i| row.* = try a.dupe([]const u8, res[i * n_col ..][0..n_col]);
    std.mem.sort([]const []const u8, rows, {}, struct {
        fn lt(_: void, x: []const []const u8, y: []const []const u8) bool {
            for (x, y) |u, v| switch (std.mem.order(u8, u, v)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            };
            return false;
        }
    }.lt);
    for (rows, 0..) |row, i| @memcpy(res[i * n_col ..][0..n_col], row);
}

/// The MD5 of the values, each followed by "\n", in lowercase hex.
fn md5Hex(values: []const []const u8) [32]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    for (values) |v| {
        md5.update(v);
        md5.update("\n");
    }
    return std.fmt.bytesToHex(md5.finalResult(), .lower);
}

test "sqllogictest scanner" {
    var s: Script = .{ .z = "# c\nstatement ok\nCREATE TABLE t(a)\n\n  \nquery I rowsort label-1\nSELECT a\n----\n1\n" };
    try std.testing.expect(s.findStartOfNextRecord());
    s.tokenizeLine();
    try std.testing.expectEqualStrings("statement", s.tokens[0]);
    try std.testing.expectEqualStrings("ok", s.tokens[1]);
    try std.testing.expectEqual(2, s.start_line);
    try std.testing.expect(s.nextLine());
    try std.testing.expectEqualStrings("CREATE TABLE t(a)", s.line);
    try std.testing.expect(s.findStartOfNextRecord());
    s.tokenizeLine();
    try std.testing.expectEqualStrings("label-1", s.tokens[3]);
    try std.testing.expectEqual(6, s.start_line);
}

test "sqllogictest hash and sort" {
    const hex = md5Hex(&.{ "1", "2" });
    // printf '1\n2\n' | md5
    try std.testing.expectEqualStrings("6ddb4095eb719e2a9f0a3f95677d24e0", &hex);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var vals = [_][]const u8{ "b", "2", "a", "9", "a", "1" };
    try sortRows(arena.allocator(), &vals, 2);
    try std.testing.expectEqualDeep(&[_][]const u8{ "a", "1", "a", "9", "b", "2" }, &vals);
}
