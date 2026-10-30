//! `xqt gen NAME...`: regenerates committed files. The generators named
//! run at once.
//!
//! - fixtures: the databases of src/testdata and pkg/storage/src/testdata,
//!   made by the sqlite3 shell
//!   (was tools/gen-fixtures.sh).
//! - parser: src/parse/grammar.zig from SQLite's grammar: lemon and
//!   mkkeywordhash from ref/sqlite, run on parse.y, and the parser tables,
//!   rule names and keyword list converted by tools/parser/lemon2zig.zig
//!   (was tools/gen-parser.sh).
//! - opcodes: src/vdbe/opcodes.zig: mkopcodeh.tcl and mkopcodec.tcl over
//!   parse.h and vdbe.c, converted by tools/vdbe/opcodes2zig.zig (was
//!   tools/gen-opcodes.sh). Needs tclsh.
//! - superjournal: src/testdata/superjournal, what sqlite3 leaves when it
//!   dies in a multi-database commit (gen/superjournal.zig; it takes its
//!   own arguments, so it runs alone).
//!
//! The C helpers (lemon, mkkeywordhash, tools/parser/keywords.c) are built
//! with `zig cc`, the converters run with `zig run`, and the output is
//! formatted as `zig fmt` does, in-process. $ZIG names the zig binary
//! (default: zig on PATH).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const superjournal = @import("gen/superjournal.zig");

pub const usage =
    \\usage: xqt gen [--fixtures-sqlite3 PATH] NAME...
    \\
    \\  fixtures   pkg/storage/src/testdata/{btree,autovacuum}.db, src/testdata/sql.db with the sqlite3 on
    \\             PATH, or --fixtures-sqlite3 PATH (the committed ones are
    \\             from 3.44.4, whose version they carry in their header)
    \\  parser     src/parse/grammar.zig from ref/sqlite (lemon, mkkeywordhash)
    \\  opcodes    src/vdbe/opcodes.zig from ref/sqlite (lemon, tclsh)
    \\
    \\The C helpers are built with $ZIG cc (default zig on PATH).
    \\
    \\
++ superjournal.usage;

const Name = enum { fixtures, parser, opcodes };

const Job = struct {
    name: Name,
    ctx: *const Ctx,
    /// What to print when it is done (a line), or why it failed.
    message: []const u8 = "",
    ok: bool = false,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const xqt.Config,
    zig: []const u8,
    fixtures_sqlite3: []const u8,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], superjournal.name)) return superjournal.run(gpa, io, cfg, out, args[1..]);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .zig = cfg.environ.get("ZIG") orelse "zig",
        .fixtures_sqlite3 = "sqlite3",
    };
    var jobs: std.ArrayList(Job) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--fixtures-sqlite3") and i + 1 < args.len) {
            i += 1;
            ctx.fixtures_sqlite3 = args[i];
            continue;
        }
        const name = std.meta.stringToEnum(Name, a) orelse return usageError(out);
        if (for (jobs.items) |j| (if (j.name == name) break true) else false) continue;
        try jobs.append(arena, .{ .name = name, .ctx = &ctx });
    }
    if (jobs.items.len == 0) return usageError(out);

    xqt.pool.forEach(jobs.items.len, jobs.items.len, jobs.items, runJob);
    var failed = false;
    for (jobs.items) |j| {
        if (j.ok) {
            try out.print("{s}\n", .{j.message});
        } else {
            failed = true;
            try out.print("xqt gen {t}: {s}\n", .{ j.name, std.mem.trimEnd(u8, j.message, "\n") });
        }
    }
    try out.flush();
    return @intFromBool(failed);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

fn runJob(jobs: []Job, i: usize) void {
    const j = &jobs[i];
    var arena_state: std.heap.ArenaAllocator = .init(j.ctx.gpa);
    defer arena_state.deinit();
    var g: Gen = .{ .ctx = j.ctx, .arena = arena_state.allocator(), .tmp = "" };
    const result = switch (j.name) {
        .fixtures => g.fixtures(),
        .parser => g.parser(),
        .opcodes => g.opcodes(),
    };
    // The message outlives the job's arena.
    const keep = std.heap.page_allocator;
    if (result) |msg| {
        j.ok = true;
        j.message = keep.dupe(u8, msg) catch "";
    } else |err| {
        j.message = keep.dupe(u8, if (err == error.StepFailed) g.failure else @errorName(err)) catch "";
    }
    if (g.tmp.len > 0) Io.Dir.cwd().deleteTree(j.ctx.io, g.tmp) catch {};
    Io.Dir.cwd().deleteDir(j.ctx.io, j.ctx.cfg.tmp) catch {};
}

const Gen = struct {
    ctx: *const Ctx,
    arena: Allocator,
    /// The temporary directory, if one was made.
    tmp: []const u8,
    /// Why a step failed.
    failure: []const u8 = "",

    fn root(g: *Gen, rel: []const u8) ![]const u8 {
        return std.fs.path.join(g.arena, &.{ g.ctx.cfg.root, rel });
    }

    fn makeTmp(g: *Gen, name: []const u8) ![]const u8 {
        g.tmp = try std.fmt.allocPrint(g.arena, "{s}/gen-{s}", .{ g.ctx.cfg.tmp, name });
        Io.Dir.cwd().deleteTree(g.ctx.io, g.tmp) catch {};
        try Io.Dir.cwd().createDirPath(g.ctx.io, g.tmp);
        return g.tmp;
    }

    /// Runs `argv` in `cwd`, which must succeed (set -e); returns its
    /// standard output.
    fn step(g: *Gen, argv: []const []const u8, opts: struct { cwd: ?[]const u8 = null, stdin: ?[]const u8 = null }) ![]const u8 {
        const r = try xqt.proc.run(g.arena, g.ctx.io, argv, .{ .cwd = opts.cwd, .stdin = opts.stdin });
        if (r.ok()) return r.stdout;
        var w: Io.Writer.Allocating = .init(g.arena);
        for (argv, 0..) |a, i| try w.writer.print("{s}{s}", .{ if (i > 0) " " else "", a });
        try w.writer.print(": {f}\n{s}", .{ r, r.stderr });
        g.failure = w.written();
        return error.StepFailed;
    }

    fn cc(g: *Gen, args: []const []const u8) !void {
        _ = try g.step(try std.mem.concat(g.arena, []const u8, &.{ &.{ g.ctx.zig, "cc" }, args }), .{});
    }

    fn write(g: *Gen, path: []const u8, data: []const u8) !void {
        try Io.Dir.cwd().writeFile(g.ctx.io, .{ .sub_path = path, .data = data });
    }

    fn read(g: *Gen, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(g.ctx.io, path, g.arena, .unlimited);
    }

    fn copy(g: *Gen, from: []const u8, to: []const u8) !void {
        try Io.Dir.cwd().copyFile(from, .cwd(), to, g.ctx.io, .{});
    }

    /// The version of ref/sqlite, as $(cat VERSION).
    fn version(g: *Gen, ref: []const u8) ![]const u8 {
        return std.mem.trimEnd(u8, try g.read(try std.fs.path.join(g.arena, &.{ ref, "VERSION" })), "\n");
    }

    /// Runs a converter under tools/ with `zig run` and writes what it
    /// prints, formatted as `zig fmt` would, to `out`.
    fn convert(g: *Gen, converter: []const u8, args: []const []const u8, out: []const u8) !void {
        const argv = try std.mem.concat(g.arena, []const u8, &.{ &.{ g.ctx.zig, "run", try g.root(converter), "--" }, args });
        const zig_src = try g.step(argv, .{});
        try g.write(out, try zigFmt(g.arena, zig_src));
    }

    /// lemon from ref/sqlite, run on parse.y in the temporary directory
    /// (parse.c, parse.h).
    fn lemon(g: *Gen, ref: []const u8, tmp: []const u8) !void {
        try g.copy(try std.fs.path.join(g.arena, &.{ ref, "tool", "lempar.c" }), try std.fs.path.join(g.arena, &.{ tmp, "lempar.c" }));
        try g.copy(try std.fs.path.join(g.arena, &.{ ref, "src", "parse.y" }), try std.fs.path.join(g.arena, &.{ tmp, "parse.y" }));
        const exe = try std.fs.path.join(g.arena, &.{ tmp, "lemon" });
        try g.cc(&.{ "-O2", "-o", exe, try std.fs.path.join(g.arena, &.{ ref, "tool", "lemon.c" }) });
        _ = try g.step(&.{ exe, "-S", "parse.y" }, .{ .cwd = tmp });
    }

    fn parser(g: *Gen) ![]const u8 {
        const ref = try g.root("ref/sqlite");
        const tmp = try g.makeTmp("parser");
        const p = struct {
            fn f(gen: *Gen, dir: []const u8, name: []const u8) ![]const u8 {
                return std.fs.path.join(gen.arena, &.{ dir, name });
            }
        }.f;
        try g.lemon(ref, tmp);
        try g.cc(&.{ "-O2", "-o", try p(g, tmp, "mkkeywordhash"), try p(g, ref, "tool/mkkeywordhash.c") });
        try g.write(try p(g, tmp, "keywordhash.h"), try g.step(&.{try p(g, tmp, "mkkeywordhash")}, .{}));
        try g.cc(&.{ try std.fmt.allocPrint(g.arena, "-I{s}", .{tmp}), "-o", try p(g, tmp, "keywords"), try g.root("tools/parser/keywords.c") });
        try g.write(try p(g, tmp, "keywords.txt"), try g.step(&.{try p(g, tmp, "keywords")}, .{}));
        try g.convert("tools/parser/lemon2zig.zig", &.{ try p(g, tmp, "parse.c"), try p(g, tmp, "parse.h"), try p(g, tmp, "keywords.txt"), try g.version(ref) }, try g.root("src/parse/grammar.zig"));
        return "wrote src/parse/grammar.zig";
    }

    fn opcodes(g: *Gen) ![]const u8 {
        const ref = try g.root("ref/sqlite");
        const tmp = try g.makeTmp("opcodes");
        try g.lemon(ref, tmp);
        const vdbe_c = try std.fs.path.join(g.arena, &.{ ref, "src", "vdbe.c" });
        const input = try std.mem.concat(g.arena, u8, &.{ try g.read(try std.fs.path.join(g.arena, &.{ tmp, "parse.h" })), try g.read(vdbe_c) });
        const opcodes_h = try std.fs.path.join(g.arena, &.{ tmp, "opcodes.h" });
        const opcodes_c = try std.fs.path.join(g.arena, &.{ tmp, "opcodes.c" });
        try g.write(opcodes_h, try g.step(&.{ "tclsh", try std.fs.path.join(g.arena, &.{ ref, "tool", "mkopcodeh.tcl" }) }, .{ .stdin = input }));
        try g.write(opcodes_c, try g.step(&.{ "tclsh", try std.fs.path.join(g.arena, &.{ ref, "tool", "mkopcodec.tcl" }), opcodes_h }, .{}));
        try Io.Dir.cwd().createDirPath(g.ctx.io, try g.root("src/vdbe"));
        try g.convert("tools/vdbe/opcodes2zig.zig", &.{ opcodes_h, opcodes_c, vdbe_c, try g.version(ref) }, try g.root("src/vdbe/opcodes.zig"));
        return "wrote src/vdbe/opcodes.zig";
    }

    /// The databases in pkg/storage/src/testdata (for the b-tree tests) and
    /// src/testdata, made with the sqlite3 shell. The content is
    /// deterministic; tests check it against the same formulas.
    fn fixtures(g: *Gen) ![]const u8 {
        const storage_dir = try g.root("pkg/storage/src/testdata");
        try g.fixture(storage_dir, "btree.db", try btreeSql(g.arena, 0));
        try g.fixture(storage_dir, "autovacuum.db", try btreeSql(g.arena, 1));
        const dir = try g.root("src/testdata");
        // The schema and rows src/sql/sql_test.zig queries.
        const sql_db = try std.fs.path.join(g.arena, &.{ dir, "sql.db" });
        Io.Dir.cwd().deleteFile(g.ctx.io, sql_db) catch {};
        _ = try g.step(&.{ g.ctx.fixtures_sqlite3, "sql.db" }, .{ .cwd = dir, .stdin = sql_fixture });
        return "wrote pkg/storage/src/testdata/btree.db, autovacuum.db, src/testdata/sql.db";
    }

    fn fixture(g: *Gen, dir: []const u8, file: []const u8, sql: []const u8) !void {
        Io.Dir.cwd().deleteFile(g.ctx.io, try std.fs.path.join(g.arena, &.{ dir, file })) catch {};
        _ = try g.step(&.{ g.ctx.fixtures_sqlite3, file }, .{ .cwd = dir, .stdin = sql });
        const ok = try g.step(&.{ g.ctx.fixtures_sqlite3, file, "PRAGMA integrity_check" }, .{ .cwd = dir });
        // grep -qx ok
        var it = std.mem.splitScalar(u8, ok, '\n');
        while (it.next()) |line| if (std.mem.eql(u8, line, "ok")) return;
        g.failure = try std.fmt.allocPrint(g.arena, "{s}: integrity_check: {s}", .{ file, ok });
        return error.StepFailed;
    }
};

/// btree.db and autovacuum.db: `auto_vacuum` is 0 or 1. Some builds
/// (Android's) default to auto_vacuum=1, so it is always set explicitly.
fn btreeSql(arena: Allocator, auto_vacuum: u1) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\PRAGMA page_size=1024;
        \\PRAGMA auto_vacuum={d};
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB, d REAL);
        \\CREATE INDEX t_b ON t(b);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1000)
        \\INSERT INTO t
        \\  SELECT i,
        \\         printf('row-%05d', (i*7919)%1000),
        \\         CASE WHEN i%97=0 THEN cast(printf('%.*c', 2000+i, char(65+i%26)) AS BLOB)
        \\              ELSE cast(i*i AS TEXT) END,
        \\         i*0.5
        \\  FROM n;
        \\DELETE FROM t WHERE a%5=0 OR a BETWEEN 300 AND 420;
        \\
    , .{auto_vacuum});
}

const sql_fixture =
    \\CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c REAL);
    \\INSERT INTO t1 VALUES(1,'one',1.5),(2,'two',2.5),(3,'three',NULL),(4,'four',4.0),(5,'five',-1);
    \\CREATE INDEX t1_b ON t1(b);
    \\CREATE TABLE t2(x, y);
    \\INSERT INTO t2 VALUES(1,'a'),(2,'b'),(2,'c'),(9,'z');
    \\CREATE TABLE wr(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID;
    \\INSERT INTO wr VALUES('b',2),('a',1),('c',3);
    \\
;

/// `source` as `zig fmt` prints it.
fn zigFmt(arena: Allocator, source: []const u8) ![]u8 {
    const src = try arena.dupeSentinel(u8, source, 0);
    var tree = try std.zig.Ast.parse(arena, src, .{ .mode = .zig });
    defer tree.deinit(arena);
    if (tree.errors.len > 0) return error.ParseError;
    return tree.renderAlloc(arena);
}

test zigFmt {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("const a = .{ 1, 2 };\n", try zigFmt(arena.allocator(), "const a = .{1,2};"));
}
