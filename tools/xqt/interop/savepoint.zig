//! Savepoints and statement transactions against sqlite3: the same
//! script of SAVEPOINT / RELEASE / ROLLBACK TO and statements that fail
//! midway inside a transaction, run by `xqlite sql` and by sqlite3 in each
//! journal mode and with a cache small enough to spill, must print the
//! same results and leave a database that passes the integrity check.
//! (Was tools/interop-savepoint.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "savepoint";
pub const about = "SAVEPOINT, ROLLBACK TO and failed statements in each journal mode";

pub fn register(s: *xqt.Suite) !void {
    for ([_][]const u8{ "delete", "persist", "truncate", "off" }) |mode| {
        for ([_][]const u8{ "5", "2000" }) |cache| {
            try s.add(try std.fmt.allocPrint(s.arena.allocator(), "journal_mode={s} cache_size={s}", .{ mode, cache }), byMode, .{ mode, cache });
        }
    }
}

// randomblob() lengths are compared, not contents.
const body =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b, c UNIQUE);
    \\CREATE INDEX tb ON t(b);
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3000)
    \\  INSERT INTO t SELECT i, randomblob(100+i%400), i FROM n;
    \\BEGIN;
    \\UPDATE t SET b = randomblob(300) WHERE a % 2 = 0;
    \\SAVEPOINT s1;
    \\DELETE FROM t WHERE a % 3 = 0;
    \\SAVEPOINT s2;
    \\INSERT INTO t SELECT a+10000, randomblob(700), c+10000 FROM t WHERE a < 1500;
    \\UPDATE t SET c = c + 1 WHERE a > 2900;
    \\SELECT 'mid', count(*), sum(length(b)) FROM t;
    \\ROLLBACK TO s2;
    \\SELECT 'rb2', count(*), sum(length(b)) FROM t;
    \\INSERT INTO t SELECT a+20000, randomblob(50), c+20000 FROM t WHERE a < 100;
    \\ROLLBACK TO s1;
    \\SELECT 'rb1', count(*), sum(length(b)) FROM t;
    \\INSERT INTO t SELECT a+30000, b, c FROM t WHERE a < 10;
    \\SELECT 'after-fail', count(*) FROM t;
    \\RELEASE s1;
    \\COMMIT;
    \\SAVEPOINT outer1;
    \\INSERT INTO t VALUES(50000, 'x', 50000);
    \\SAVEPOINT inner1;
    \\DELETE FROM t WHERE a < 1000;
    \\RELEASE outer1;
    \\SELECT 'end', count(*), sum(length(b)) FROM t;
    \\RELEASE nosuch;
    \\PRAGMA integrity_check;
;

fn byMode(c: *Check, mode: []const u8, cache: []const u8) !void {
    // The shells turn on defensive mode, which refuses journal_mode=OFF.
    const input = try std.fmt.allocPrint(c.arena, ".dbconfig defensive off\nPRAGMA journal_mode={s};\nPRAGMA cache_size={s};\n{s}\n", .{ mode, cache, body });
    // The two engines run at once, each on its own file.
    var xp = try start(c, &.{ c.cfg.xq, "sql", "x.db" }, input, "xq.out");
    defer xp.kill();
    var sp = try start(c, &.{ c.cfg.sqlite3, "s.db" }, input, "sq.out");
    defer sp.kill();
    _ = try xp.close();
    _ = try sp.close();
    const x = try normalize(c, try c.readFile("xq.out"));
    const s = try normalize(c, try c.readFile("sq.out"));
    _ = c.expectSame("output", "sqlite3", s, "xqlite", x);
    const ok = try c.sqlite3("x.db", "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, ok, "\n"), "ok")) c.fail("integrity_check: {s}", .{ok});
}

/// Starts `argv < input > out 2>&1`: standard output and standard error
/// into one file, as the program interleaves them. `close` waits for it.
fn start(c: *Check, argv: []const []const u8, input: []const u8, out: []const u8) !xqt.proc.Child {
    var p = try c.spawn(argv, .{ .output = out });
    errdefer p.kill();
    p.write(input) catch |err| switch (err) {
        error.BrokenPipe => {},
        else => |e| return e,
    };
    return p;
}

/// Without the lines `.dbconfig` prints (`grep -v '^ *defensive'`), and
/// with the first "line N" of each line made "line N"
/// (`sed 's/line \([0-9]*\)/line N/'`).
fn normalize(c: *Check, text: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(c.arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // The piece after the last newline (empty if the text ends with one).
        if (lines.peek() == null and line.len == 0) break;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "defensive")) continue;
        if (std.mem.indexOf(u8, line, "line ")) |i| {
            var j = i + "line ".len;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            try w.writer.print("{s}line N{s}\n", .{ line[0..i], line[j..] });
        } else {
            try w.writer.print("{s}\n", .{line});
        }
    }
    return w.written();
}
