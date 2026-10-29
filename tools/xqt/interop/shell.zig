//! The `xqlite sql` shell against the sqlite3 command-line shell: the
//! same scripts (every output mode, headers, nullvalue, separators,
//! .tables/.schema/.indexes/.dump, errors) must give the same standard
//! output, standard error and exit code, and the .dump output of xqlite
//! must rebuild the database in sqlite3. Older shells than 3.54.1 format
//! some output differently. (Was tools/interop-shell.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "shell";
pub const about = "the xqlite sql shell against the sqlite3 shell: output, errors, exit codes";

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    for ([_]Writer{ .sqlite3, .xqlite }) |w| {
        const db = if (w == .sqlite3) "a.db" else "b.db";
        try s.add(try std.fmt.allocPrint(a, "modes ({s})", .{db}), script, .{ w, modes, "" });
        try s.add(try std.fmt.allocPrint(a, "dot-commands ({s})", .{db}), script, .{ w, dot, "" });
        try s.add(try std.fmt.allocPrint(a, "dump ({s})", .{db}), script, .{ w, dump, "" });
    }
    try s.add("arguments 1", arguments, .{&[_][]const u8{ "CREATE TABLE a(x); INSERT INTO a VALUES(1),(2)", ".mode csv", "SELECT x, 'p,q' FROM a" }});
    try s.add("arguments 2", arguments, .{&[_][]const u8{ "SELECT 1; SELEC 2", "SELECT 3" }});
    try s.add("arguments 3", arguments, .{&[_][]const u8{ ".bogus", "SELECT 3" }});
    try s.add("arguments 4", arguments, .{&[_][]const u8{ ".mode box", "SELECT 1 AS one, NULL AS two" }});
    // Reading files, nested errors, .bail, .exit and .quit.
    try s.add("read", script, .{ Writer.sqlite3, ".read inc.sql\nSELECT 42;\n.bail on\n.read inc.sql\nSELECT 43;\n", "SELECT 41;\nSELEC oops;\n.print in-file\n.read missing.sql\n" });
    try s.add("exit", script, .{ Writer.sqlite3, "SELECT 1;\n.exit 3\nSELECT 2;\n", "" });
    try s.add("quit", script, .{ Writer.sqlite3, "SELECT 1;\n.quit\nSELECT 2;\n", "" });
    try s.add("incomplete input", script, .{ Writer.sqlite3, "SELECT (1\n", "" });
    try s.add("dump round trip", roundTrip, .{});
}

const Writer = enum { sqlite3, xqlite };

const schema = "CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL, d BLOB);\n" ++
    \\INSERT INTO t VALUES(1,'hello',1.5,x'00ff10');
    \\INSERT INTO t VALUES(2,NULL,0.1,NULL);
    \\INSERT INTO t VALUES(3,'it''s, "quoted"',1e100,'');
    \\INSERT INTO t VALUES(4,'line1
    \\line2',-2.5e-7,x'');
    \\
++ "INSERT INTO t VALUES(5,'tab\there',123456789012345678,'x');\n" ++
    \\INSERT INTO t VALUES(6,'ünï ☃ wide 漢字',3.0,'ctl' || char(1) || 'z');
    \\INSERT INTO t VALUES(7,'a long value that has to be wrapped in narrow columns',-0.0,42);
    \\CREATE INDEX t_b ON t(b);
    \\CREATE TABLE "odd name"("a b" TEXT, "select" INT);
    \\INSERT INTO "odd name" VALUES('x y', 7);
    \\CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
    \\INSERT INTO s(v) VALUES('one'),('two');
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
    \\INSERT INTO w VALUES('a',1),('b',2.25),('c',NULL);
    \\CREATE VIEW vt AS SELECT a, b FROM t WHERE a < 3;
    \\CREATE UNIQUE INDEX s_v ON s(v);
    \\CREATE INDEX w_v ON w(v) WHERE v IS NOT NULL;
    \\
;

/// Every output mode, with and without headers.
const modes = blk: {
    var text: []const u8 = "";
    for ([_][]const u8{
        "list",    "csv",  "tabs", "line",  "column", "quote", "insert", "box",   "table", "markdown", "json",
        "jobject", "html", "tcl",  "ascii", "psql",   "qbox",  "split",  "count", "off",
    }) |m| {
        text = text ++ ".print == " ++ m ++ "\n.mode " ++ m ++ "\nSELECT * FROM t ORDER BY a;\n" ++
            ".headers on\nSELECT * FROM t WHERE a<3 ORDER BY a;\nSELECT 1 WHERE 0;\n" ++
            ".headers off\nSELECT k, v FROM w ORDER BY k;\n";
    }
    break :blk text;
};

const dot =
    \\.tables
    \\.tables %e%
    \\.indexes
    \\.indexes s
    \\.schema
    \\.schema s
    \\.schema --nosys
    \\.schema sqlite_schema
    \\.schema odd%
    \\.schema "odd name"
    \\.mode
    \\.headers on
    \\.separator ; "\n--\n"
    \\SELECT * FROM w ORDER BY k;
    \\.separator , \r\n
    \\SELECT * FROM w ORDER BY k;
    \\.separator |
    \\.nullvalue <null>
    \\SELECT b FROM t WHERE a=2;
    \\.mode insert foo
    \\.mode
    \\SELECT * FROM "odd name";
    \\.mode quote
    \\SELECT * FROM w ORDER BY k;
    \\.mode csv
    \\.mode
    \\.mode column
    \\SELECT * FROM t WHERE 0;
    \\.headers off
    \\.mode column
    \\SELECT * FROM t WHERE 0;
    \\SELECT a, b FROM t ORDER BY a;
    \\.mode line
    \\SELECT a AS longername, b FROM t WHERE a < 3 ORDER BY a;
    \\.mode list
    \\.changes on
    \\INSERT INTO w VALUES('d', 3);
    \\UPDATE w SET v = v + 1 WHERE v > 1;
    \\.changes off
    \\.echo on
    \\SELECT 1;
    \\.echo off
    \\.print hello   world 'x y' "tab\there"
    \\.show
    \\SELECT 1; SELECT 2,
    \\  3;
    \\SELECT 'a;b'; -- trailing
    \\SELECT
    \\  4
    \\;
    \\-- comment only
    \\/* block */
    \\SELECT 5; SELEC 6; SELECT 7;
    \\SELECT * FROM nosuch;
    \\INSERT INTO s(v) VALUES('one');
    \\SELECT abs(-9223372036854775807-1);
    \\SELECT 12345678901234567890123456789012345678901234567890, 1 +;
    \\.bogus
    \\.headers maybe
    \\.bail
    \\.mode nosuch
    \\.mode box --wrap
    \\.mode box --wrap 10
    \\SELECT b, a FROM t ORDER BY a;
    \\.mode table --border off
    \\SELECT 1 AS a, 'xyz' AS b;
    \\.mode box --limits 2,12,4
    \\SELECT b AS longtitle, d FROM t ORDER BY a;
    \\.mode line --limits 2,10
    \\SELECT * FROM t WHERE a=4;
    \\.mode qbox --sw 50
    \\SELECT * FROM t ORDER BY a;
    \\.mode list --quote relaxed
    \\SELECT 'a', '1', 1, '', NULL;
    \\.mode -v
    \\.mode tty
    \\.mode
    \\.mode batch
    \\.headers always
    \\SELECT 1 WHERE 0;
    \\.mode insert --multiinsert 60
    \\SELECT * FROM t ORDER BY a;
    \\.mode list
    \\.bail on
    \\SELECT 8;
    \\SELECT bad syntax here;
    \\SELECT 9;
    \\
;

const dump =
    \\.dump
    \\.dump t
    \\.dump --data-only w
    \\.dump --nosys
    \\.dump s%
    \\.mode tty
    \\.dump w
    \\.dump --bogus
    \\
;

/// The sample database written by `w`, named `db`.
fn build(c: *Check, w: Writer, db: []const u8) !void {
    switch (w) {
        .sqlite3 => _ = try c.runOk(&.{ c.cfg.sqlite3, db }, .{ .stdin = schema }),
        .xqlite => _ = try c.runOk(&.{ c.cfg.xq, "sql", db }, .{ .stdin = schema }),
    }
}

/// What a shell printed: standard output followed by "exit N", and
/// standard error.
const Output = struct { out: []const u8, err: []const u8 };

fn shellOutput(c: *Check, r: xqt.proc.Result) !Output {
    const code: u32 = if (r.term) |t| switch (t) {
        .exited => |n| n,
        .signal => |sig| 128 + @as(u32, @backingInt(sig)),
        else => 255,
    } else 255;
    return .{ .out = try std.fmt.allocPrint(c.arena, "{s}exit {d}\n", .{ r.stdout, code }), .err = r.stderr };
}

fn same(c: *Check, label: []const u8, x: Output, s: Output) void {
    for ([_][3][]const u8{ .{ "stdout", x.out, s.out }, .{ "stderr", x.err, s.err } }) |f| {
        if (std.mem.eql(u8, f[1], f[2])) continue;
        c.fail("{s}: {s} differs (- xqlite, + sqlite3)", .{ label, f[0] });
        c.writeDiff("xqlite", f[1], "sqlite3", f[2]);
    }
}

/// Runs `input` through both shells on copies of the database `w` wrote,
/// in directories x and s where both are named db (and hold `inc`, if
/// not empty, as inc.sql).
fn script(c: *Check, w: Writer, input: []const u8, inc: []const u8) !void {
    try build(c, w, "sample.db");
    var got: [2]Output = undefined;
    for ([_][]const u8{ "x", "s" }, 0..) |d, i| {
        try c.makeDir(d);
        try c.copyFile("sample.db", try std.fs.path.join(c.arena, &.{ d, "db" }));
        if (inc.len > 0) try c.writeFile(try std.fs.path.join(c.arena, &.{ d, "inc.sql" }), inc);
        const argv: []const []const u8 = if (i == 0) &.{ c.cfg.xq, "sql", "db" } else &.{ c.cfg.sqlite3, "db" };
        got[i] = try shellOutput(c, try c.run(argv, .{ .cwd = try c.path(d), .stdin = input }));
    }
    same(c, c.name, got[0], got[1]);
}

/// SQL and dot-commands as command-line arguments.
fn arguments(c: *Check, args: []const []const u8) !void {
    var got: [2]Output = undefined;
    for ([_][]const u8{ "x", "s" }, 0..) |d, i| {
        try c.makeDir(d);
        const pre: []const []const u8 = if (i == 0) &.{ c.cfg.xq, "sql", "c.db" } else &.{ c.cfg.sqlite3, "c.db" };
        const argv = try std.mem.concat(c.arena, []const u8, &.{ pre, args });
        got[i] = try shellOutput(c, try c.run(argv, .{ .cwd = try c.path(d) }));
    }
    var label: std.Io.Writer.Allocating = .init(c.arena);
    try label.writer.writeAll("arguments");
    for (args) |a| try label.writer.print(" {s}", .{a});
    same(c, label.written(), got[0], got[1]);
}

/// The .dump of xqlite rebuilds the database in sqlite3, which dumps it
/// back the same.
fn roundTrip(c: *Check) !void {
    try build(c, .xqlite, "b.db");
    const xd = try c.xqSql("b.db", ".dump");
    _ = try c.runOk(&.{ c.cfg.sqlite3, "r.db" }, .{ .stdin = xd });
    const ok = try c.sqlite3("r.db", "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, ok, "\n"), "ok")) c.fail("dump round trip: integrity_check: {s}", .{ok});
    const sd = try c.sqlite3("r.db", ".dump");
    if (!std.mem.eql(u8, xd, sd)) {
        c.fail("dump round trip differs", .{});
        c.writeDiff("xqlite", xd, "sqlite3", sd);
    }
}
