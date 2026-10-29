//! `xqt planner [FILE...] [-k KINDS] [--known FILE]`: xqlite against
//! sqlite3 3.54.1 on query results, EXPLAIN QUERY PLAN and EXPLAIN
//! bytecode. (Was tools/planner/diff.py; tools/planner/README.md.)
//!
//! A case file has blocks separated by lines "----". In each block, lines
//! before a line "==" are setup SQL, run once by the reference shell; each
//! later non-empty line is one query. A setup line ".each SQL" runs SQL
//! before each query of the block on the same connection (e.g. an ATTACH).
//! Both engines run in a directory of the block's own, so relative file
//! names in the SQL land there.
//!
//! The setups of every block run first, in parallel; then the queries, in
//! chunks of a few per check, each chunk on its own copy of the block's
//! directory as the setup left it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt planner [FILE...] [-k KINDS] [--known FILE]
    \\
    \\  FILE          case files (default: tools/planner/*.txt but vtablog.txt)
    \\  -k KINDS      res,eqp,code (default: all)
    \\  --known FILE  failures to expect (tools/planner/known-failures.list)
    \\  -v            print what differs
    \\
    \\The reference is --sq ($SQ, default sqlite3 on PATH): 3.54.1 built
    \\without SQLITE_ENABLE_EXPLAIN_COMMENTS. SQOPT=MASK runs it with
    \\".testctrl optimizations MASK".
    \\
;

const Kind = enum {
    code,
    eqp,
    res,
};

/// Queries per check.
const chunk_size = 8;
/// Seconds an engine gets per query (then the output is "TIMEOUT").
const timeout_ms = 60_000;

const Block = struct {
    index: usize,
    /// Arguments for the reference shell after the database; null if the
    /// block has no setup.
    setup: ?[]const []const u8,
    each: []const []const u8,
    queries: []const []const u8,
    /// Where the setup builds main.db: CFG.tmp/planner/FILE-BLOCK.
    dir: []const u8,
};

const CaseFile = struct {
    path: []const u8,
    blocks: []Block,
};

const Failure = struct {
    /// The query's index in its block.
    query: usize,
    kind: Kind,
    order_only: bool,
    /// What differs (-v).
    detail: []const u8,
};

const Chunk = struct {
    file: *const CaseFile,
    block: *const Block,
    start: usize,
    end: usize,
    failures: []Failure = &.{},
};

const Ctx = struct {
    cfg: *const xqt.Config,
    kinds: std.EnumSet(Kind),
    /// SQOPT as the reference's first argument, or null.
    sqpre: ?[]const u8,
};

const Known = struct {
    file: []const u8,
    kind: Kind,
    query: []const u8,
    seen: bool = false,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    var kinds: std.EnumSet(Kind) = .full;
    var known_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-k") and i + 1 < args.len) {
            i += 1;
            kinds = .empty;
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |k| kinds.insert(std.meta.stringToEnum(Kind, k) orelse return usageError(out));
        } else if (std.mem.eql(u8, a, "--known") and i + 1 < args.len) {
            i += 1;
            known_path = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            return usageError(out);
        } else {
            try paths.append(arena, a);
        }
    }
    if (paths.items.len == 0) try defaultFiles(arena, io, cfg, &paths);

    var known: []Known = &.{};
    if (known_path) |p| known = try readKnown(arena, io, p);

    const sqopt = cfg.environ.get("SQOPT") orelse "";
    const ctx: Ctx = .{
        .cfg = cfg,
        .kinds = kinds,
        .sqpre = if (sqopt.len > 0) try std.fmt.allocPrint(arena, ".testctrl optimizations {s}", .{sqopt}) else null,
    };

    // Read and split every file.
    const files = try arena.alloc(CaseFile, paths.items.len);
    for (files, paths.items, 0..) |*f, p, fi| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .unlimited) catch |err| {
            try out.print("xqt planner: cannot read {s}: {t}\n", .{ p, err });
            return 2;
        };
        f.* = .{ .path = relative(cfg.root, p), .blocks = try parse(arena, cfg, fi, text) };
    }

    // 1. The setups.
    var setups: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "planner-setup", .show = .failures });
    defer setups.deinit();
    for (files) |*f| for (f.blocks) |*b| {
        try setups.add(try std.fmt.allocPrint(arena, "{s} block {d} setup", .{ f.path, b.index }), setupBlock, .{ &ctx, b });
    };
    setups.run();

    // 2. The queries.
    var chunks: std.ArrayList(Chunk) = .empty;
    // Where each file's chunks start in `chunks`, and end.
    const file_chunks = try arena.alloc([2]usize, files.len);
    for (files, file_chunks) |*f, *range| {
        range[0] = chunks.items.len;
        for (f.blocks) |*b| {
            var start: usize = 0;
            while (start < b.queries.len) : (start += chunk_size) {
                try chunks.append(arena, .{ .file = f, .block = b, .start = start, .end = @min(b.queries.len, start + chunk_size) });
            }
        }
        range[1] = chunks.items.len;
    }
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "planner", .show = .failures });
    defer suite.deinit();
    // The first chunk of every file, then the second ...: a slow query
    // (vtab.txt has one that both engines run to the 60 s timeout) then
    // starts early wherever its file is, instead of last.
    var rank: usize = 0;
    var added: usize = 0;
    while (added < chunks.items.len) : (rank += 1) {
        for (file_chunks) |range| {
            if (range[0] + rank >= range[1]) continue;
            const ch = &chunks.items[range[0] + rank];
            try suite.add(try std.fmt.allocPrint(arena, "{s} block {d} queries {d}..{d}", .{
                ch.file.path, ch.block.index, ch.start, ch.end - 1,
            }), runChunk, .{ &ctx, ch });
            added += 1;
        }
    }
    suite.run();
    if (!cfg.keep or (setups.failed() == 0 and suite.failed() == 0))
        Io.Dir.cwd().deleteTree(io, try std.fs.path.join(arena, &.{ cfg.tmp, "planner-blocks" })) catch {};
    Io.Dir.cwd().deleteDir(io, cfg.tmp) catch {};

    // The report, in the order of the files: what diff.py printed.
    var failed = setups.failed() > 0 or suite.failed() > 0;
    var n_known: usize = 0;
    var next_chunk: usize = 0;
    for (files) |*f| {
        try out.print("== {s}\n", .{f.path});
        var counts: std.EnumArray(Kind, usize) = .initFill(0);
        var n_queries: usize = 0;
        for (f.blocks) |b| n_queries += b.queries.len;
        while (next_chunk < chunks.items.len and chunks.items[next_chunk].file == f) : (next_chunk += 1) {
            const ch = &chunks.items[next_chunk];
            for (ch.failures) |fl| {
                const q = ch.block.queries[fl.query];
                counts.getPtr(fl.kind).* += 1;
                const is_known = markKnown(known, f.path, fl.kind, q);
                if (is_known) n_known += 1 else failed = true;
                try out.print("{s}[{t}{s}] block {d}: {s}\n", .{
                    if (is_known) "KNOWN" else "FAIL",
                    fl.kind,
                    if (fl.order_only) ":order-only" else "",
                    ch.block.index,
                    q,
                });
                if (cfg.verbose) try out.writeAll(fl.detail);
            }
        }
        try out.print("{d} queries; failures: ", .{n_queries});
        var first = true;
        for (std.enums.values(Kind)) |k| {
            if (!kinds.contains(k)) continue;
            try out.print("{s}{t}={d}", .{ if (first) "" else ", ", k, counts.get(k) });
            first = false;
        }
        try out.writeAll("\n");
    }
    // A known failure that no longer fails: take it off the list.
    for (known) |k| {
        if (k.seen or !kinds.contains(k.kind)) continue;
        for (files) |f| {
            if (!std.mem.eql(u8, std.fs.path.basename(f.path), k.file)) continue;
            try out.print("FIXED[{t}] {s}: {s} (remove it from {s})\n", .{ k.kind, k.file, k.query, known_path.? });
            failed = true;
        }
    }
    if (known_path) |p| if (n_known > 0) try out.print("{d} known failures ({s})\n", .{ n_known, p });
    try out.flush();
    return @intFromBool(failed);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

/// tools/planner/*.txt but vtablog.txt, which needs a reference shell with
/// vtablog.c (tools/planner/README.md).
fn defaultFiles(arena: Allocator, io: Io, cfg: *const xqt.Config, paths: *std.ArrayList([]const u8)) !void {
    const dir_path = try std.fs.path.join(arena, &.{ cfg.root, "tools", "planner" });
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".txt")) continue;
        if (std.mem.eql(u8, e.name, "vtablog.txt")) continue;
        try paths.append(arena, try std.fs.path.join(arena, &.{ "tools", "planner", e.name }));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    // Relative to the root, wherever xqt runs.
    for (paths.items) |*p| p.* = try std.fs.path.join(arena, &.{ cfg.root, p.* });
}

/// The default files as "tools/planner/NAME.txt".
fn relative(root: []const u8, p: []const u8) []const u8 {
    if (p.len > root.len and std.mem.startsWith(u8, p, root) and p[root.len] == '/') return p[root.len + 1 ..];
    return p;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Lines "CASEFILE KIND QUERY" (CASEFILE without its directory); "#"
/// starts a comment line.
fn readKnown(arena: Allocator, io: Io, path: []const u8) ![]Known {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var list: std.ArrayList(Known) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        const file = parts.next().?;
        const kind = std.meta.stringToEnum(Kind, parts.next() orelse return error.BadKnownLine) orelse return error.BadKnownLine;
        try list.append(arena, .{ .file = file, .kind = kind, .query = parts.rest() });
    }
    return list.toOwnedSlice(arena);
}

fn markKnown(known: []Known, path: []const u8, kind: Kind, query: []const u8) bool {
    for (known) |*k| {
        // Each line excuses one failure: the same query twice needs two.
        if (!k.seen and k.kind == kind and std.mem.eql(u8, k.query, query) and std.mem.eql(u8, k.file, std.fs.path.basename(path))) {
            k.seen = true;
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- the case file

/// Splits a case file into blocks, as diff.py did (Python's str.split,
/// splitlines and strip).
fn parse(arena: Allocator, cfg: *const xqt.Config, file_index: usize, raw: []const u8) ![]Block {
    // open() in text mode: universal newlines.
    const text = try universalNewlines(arena, raw);
    var blocks: std.ArrayList(Block) = .empty;
    var it = std.mem.splitSequence(u8, text, "\n----\n");
    var bi: usize = 0;
    while (it.next()) |block| : (bi += 1) {
        var setup_text: []const u8 = "";
        var qs = block;
        if (std.mem.indexOf(u8, block, "\n==\n")) |at| {
            setup_text = block[0..at];
            qs = block[at + 4 ..];
        }
        var setup_lines: std.ArrayList([]const u8) = .empty;
        var each: std.ArrayList([]const u8) = .empty;
        var lines = splitLines(setup_text);
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "#")) continue;
            if (std.mem.startsWith(u8, l, ".each ")) {
                try each.append(arena, l[".each ".len..]);
            } else {
                try setup_lines.append(arena, l);
            }
        }
        // setup.strip(): any non-blank character.
        var has_setup = false;
        for (setup_lines.items) |l| if (!isBlank(l)) {
            has_setup = true;
        };
        var setup: ?[]const []const u8 = null;
        if (has_setup) {
            // Dot-commands (".dbconfig defensive off") go as arguments of
            // their own, between the SQL of the lines around them.
            var args: std.ArrayList([]const u8) = .empty;
            var sql: std.ArrayList([]const u8) = .empty;
            for (setup_lines.items) |l| {
                if (std.mem.startsWith(u8, l, ".")) {
                    if (sql.items.len > 0) {
                        try args.append(arena, try std.mem.join(arena, "\n", sql.items));
                        sql.clearRetainingCapacity();
                    }
                    try args.append(arena, l);
                } else {
                    try sql.append(arena, l);
                }
            }
            if (sql.items.len > 0) try args.append(arena, try std.mem.join(arena, "\n", sql.items));
            setup = args.items;
        }
        var queries: std.ArrayList([]const u8) = .empty;
        lines = splitLines(qs);
        while (lines.next()) |l| {
            if (isBlank(l) or std.mem.startsWith(u8, l, "#")) continue;
            try queries.append(arena, l);
        }
        try blocks.append(arena, .{
            .index = bi,
            .setup = setup,
            .each = each.items,
            .queries = queries.items,
            .dir = try std.fmt.allocPrint(arena, "{s}/planner-blocks/{d}-{d}", .{ cfg.tmp, file_index, bi }),
        });
    }
    return blocks.items;
}

/// Python's str.splitlines(): the line breaks are \n, \r\n, \r, \v, \f,
/// \x1c..\x1e, U+0085, U+2028 and U+2029; no empty line after a final one.
const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(it: *LineIterator) ?[]const u8 {
        const t = it.text;
        if (it.pos >= t.len) return null;
        const start = it.pos;
        var i = start;
        while (i < t.len) : (i += 1) {
            const n: usize = switch (t[i]) {
                '\n', 0x0b, 0x0c, 0x1c, 0x1d, 0x1e => 1,
                '\r' => if (i + 1 < t.len and t[i + 1] == '\n') 2 else 1,
                0xc2 => if (i + 1 < t.len and t[i + 1] == 0x85) 2 else 0,
                0xe2 => if (i + 2 < t.len and t[i + 1] == 0x80 and (t[i + 2] == 0xa8 or t[i + 2] == 0xa9)) 3 else 0,
                else => 0,
            };
            if (n > 0) {
                it.pos = i + n;
                return t[start..i];
            }
        }
        it.pos = t.len;
        return t[start..];
    }
};

fn splitLines(text: []const u8) LineIterator {
    return .{ .text = text };
}

/// Python's str.isspace() for every character (and true for "").
fn isBlank(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const n = spaceLen(s[i..]);
        if (n == 0) return false;
        i += n;
    }
    return true;
}

/// The length of the white space character at the start of `s`, 0 if
/// there is none (Python's definition, for \s and str.strip()).
fn spaceLen(s: []const u8) usize {
    switch (s[0]) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x1c, 0x1d, 0x1e, 0x1f => return 1,
        0x80...0xff => {
            const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
            if (n > s.len) return 0;
            const cp = std.unicode.utf8Decode(s[0..n]) catch return 0;
            return switch (cp) {
                0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => n,
                else => 0,
            };
        },
        else => return 0,
    }
}

/// \r\n and \r to \n, as Python's text mode reads.
fn universalNewlines(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
        } else out.appendAssumeCapacity(s[i]);
    }
    return out.items;
}

/// `re.match(r'\s*(SELECT|VALUES)\b', q, re.I)`: a plain query.
fn isPlainQuery(q: []const u8) bool {
    var i: usize = 0;
    while (i < q.len) {
        const n = spaceLen(q[i..]);
        if (n == 0) break;
        i += n;
    }
    const rest = q[i..];
    for ([_][]const u8{ "select", "values" }) |word| {
        if (rest.len < word.len or !std.ascii.eqlIgnoreCase(rest[0..word.len], word)) continue;
        if (rest.len == word.len) return true;
        const ch = rest[word.len];
        // A word character ends the match (anything past ASCII counts as one).
        return !(std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80);
    }
    return false;
}

// ---------------------------------------------------------------- the checks

fn setupBlock(c: *Check, ctx: *const Ctx, b: *const Block) !void {
    try Io.Dir.cwd().createDirPath(c.io, b.dir);
    const args = b.setup orelse return;
    // Build the database once with the reference so both read the same file.
    const argv = try c.arena.alloc([]const u8, args.len + 2);
    argv[0] = ctx.cfg.sq;
    argv[1] = try std.fs.path.join(c.arena, &.{ b.dir, "main.db" });
    @memcpy(argv[2..], args);
    _ = try c.run(argv, .{ .cwd = b.dir });
}

const Engine = enum { xq, sq };

fn runChunk(c: *Check, ctx: *const Ctx, ch: *Chunk) !void {
    const dir = try c.path("b");
    try Check.copyTree(c.io, c.arena, ch.block.dir, dir);
    const db = try std.fs.path.join(c.arena, &.{ dir, "main.db" });
    var failures: std.ArrayList(Failure) = .empty;
    for (ch.block.queries[ch.start..ch.end], ch.start..) |q, qi| {
        // Anything but a plain query may change the database: it runs
        // on a copy (the statements after the first of an EXPLAIN run
        // too), and the result includes the dump.
        const writes = !isPlainQuery(q) or std.mem.indexOfScalar(u8, q, ';') != null;
        for (std.enums.values(Kind)) |kind| {
            if (!ctx.kinds.contains(kind)) continue;
            if (try compare(c, ctx, ch.block, db, q, kind, writes)) |f| {
                var copy = f;
                copy.query = qi;
                try failures.append(c.keep, copy);
            }
        }
    }
    ch.failures = failures.items;
}

/// One comparison; a failure if the engines disagree.
fn compare(c: *Check, ctx: *const Ctx, b: *const Block, db: []const u8, q: []const u8, kind: Kind, writes: bool) !?Failure {
    var detail: Io.Writer.Allocating = .init(c.keep);
    const w = &detail.writer;
    switch (kind) {
        .res => {
            const post: []const []const u8 = if (writes) &.{ ".dump", "PRAGMA integrity_check" } else &.{};
            const a = try runEngine(c, ctx, .xq, db, q, b.each, &.{}, post, writes);
            const s = try runEngine(c, ctx, .sq, db, q, b.each, &.{}, post, writes);
            if (std.mem.eql(u8, a, s)) return null;
            if (ctx.cfg.verbose) try showBoth(w, s, a);
            return .{ .query = 0, .kind = kind, .order_only = try sameLines(c.arena, a, s), .detail = detail.written() };
        },
        .eqp => {
            const text = try std.fmt.allocPrint(c.arena, "EXPLAIN QUERY PLAN {s}", .{q});
            const a = try eqpTree(c.arena, try runEngine(c, ctx, .xq, db, text, b.each, &.{".explain off"}, &.{}, writes));
            const s = try eqpTree(c.arena, try runEngine(c, ctx, .sq, db, text, b.each, &.{".explain off"}, &.{}, writes));
            if (std.mem.eql(u8, a, s)) return null;
            if (ctx.cfg.verbose) try showBoth(w, s, a);
            return .{ .query = 0, .kind = kind, .order_only = false, .detail = detail.written() };
        },
        .code => {
            const text = try std.fmt.allocPrint(c.arena, "EXPLAIN {s}", .{q});
            const a = try codeNorm(c.arena, try runEngine(c, ctx, .xq, db, text, b.each, &.{".explain off"}, &.{}, writes));
            const s = try codeNorm(c.arena, try runEngine(c, ctx, .sq, db, text, b.each, &.{".explain off"}, &.{}, writes));
            if (a.len == s.len) {
                for (a, s) |x, y| {
                    if (!std.mem.eql(u8, x, y)) break;
                } else return null;
            }
            if (ctx.cfg.verbose) {
                var d: Io.Writer.Allocating = .init(c.arena);
                try xqt.diff.writeLines(&d.writer, c.arena, "sqlite3", "xqlite", s, a, .{ .context = 2, .max_lines = std.math.maxInt(usize) });
                try indent(w, d.written(), "    ");
            }
            return .{ .query = 0, .kind = kind, .order_only = false, .detail = detail.written() };
        },
    }
}

/// diff.py -v for results and plans: each side indented.
fn showBoth(w: *Io.Writer, sq: []const u8, xq: []const u8) !void {
    try w.writeAll("  --- sqlite3\n");
    try indentLines(w, sq);
    try w.writeAll("  --- xqlite\n");
    try indentLines(w, xq);
}

/// print('\n'.join('    ' + l for l in text.splitlines())).
fn indentLines(w: *Io.Writer, text: []const u8) !void {
    var it = splitLines(text);
    var first = true;
    while (it.next()) |l| {
        if (!first) try w.writeByte('\n');
        try w.print("    {s}", .{l});
        first = false;
    }
    try w.writeByte('\n');
}

fn indent(w: *Io.Writer, text: []const u8, prefix: []const u8) !void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    if (text.len == 0) return;
    while (it.next()) |l| try w.print("{s}{s}\n", .{ prefix, l });
}

/// sorted(a.splitlines()) == sorted(b.splitlines()).
fn sameLines(arena: Allocator, a: []const u8, b: []const u8) !bool {
    const la = try collectLines(arena, a);
    const lb = try collectLines(arena, b);
    if (la.len != lb.len) return false;
    std.mem.sort([]const u8, la, {}, lessThan);
    std.mem.sort([]const u8, lb, {}, lessThan);
    for (la, lb) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn collectLines(arena: Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = splitLines(text);
    while (it.next()) |l| try list.append(arena, l);
    return list.items;
}

/// Runs one engine on `q`: standard output, then "ERR:" and standard error
/// if there is any. A statement that writes runs on a fresh copy of the
/// block's directory, so the next one sees the databases as set up.
fn runEngine(
    c: *Check,
    ctx: *const Ctx,
    engine: Engine,
    db_in: []const u8,
    q: []const u8,
    each: []const []const u8,
    extra_pre: []const []const u8,
    post: []const []const u8,
    writes: bool,
) ![]const u8 {
    var db = db_in;
    if (writes) {
        const from = std.fs.path.dirname(db_in).?;
        const work = try std.fmt.allocPrint(c.arena, "{s}.work", .{from});
        try Io.Dir.cwd().deleteTree(c.io, work);
        try Check.copyTree(c.io, c.arena, from, work);
        db = try std.fs.path.join(c.arena, &.{ work, std.fs.path.basename(db_in) });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    const sqpre = if (engine == .sq) ctx.sqpre else null;
    switch (engine) {
        .xq => try argv.appendSlice(c.arena, &.{ ctx.cfg.xq, "sql" }),
        .sq => try argv.append(c.arena, ctx.cfg.sq),
    }
    try argv.append(c.arena, db);
    if (sqpre) |p| try argv.append(c.arena, p);
    try argv.appendSlice(c.arena, each);
    try argv.appendSlice(c.arena, extra_pre);
    try argv.append(c.arena, q);
    try argv.appendSlice(c.arena, post);

    const r = try c.run(argv.items, .{ .cwd = std.fs.path.dirname(db).?, .timeout_ms = timeout_ms });
    if (r.timedOut()) return "TIMEOUT";
    var out = try universalNewlines(c.arena, r.stdout);
    var err = try universalNewlines(c.arena, r.stderr);
    if (ctx.sqpre != null) {
        // SQOPT shifts the argument numbers in sqlite3's error messages.
        err = try normalizeArgNumbers(c.arena, err);
        // The .testctrl status line.
        if (sqpre != null) out = if (std.mem.indexOfScalar(u8, out, '\n')) |nl| out[nl + 1 ..] else "";
    }
    const all = if (err.len > 0) try std.mem.concat(c.arena, u8, &.{ out, "ERR:", err }) else out;
    // P4 of virtual table opcodes is the address of the sqlite3_vtab.
    return maskVtab(c.arena, all);
}

/// re.sub(r'in \d+(st|nd|rd|th) command line argument', 'in Nth command line argument', s)
fn normalizeArgNumbers(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "in ")) {
            var j = i + 3;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j > i + 3 and j + 2 <= s.len) {
                const suffix = s[j .. j + 2];
                const ordinal = for ([_][]const u8{ "st", "nd", "rd", "th" }) |o| {
                    if (std.mem.eql(u8, suffix, o)) break true;
                } else false;
                if (ordinal and std.mem.startsWith(u8, s[j + 2 ..], " command line argument")) {
                    try out.appendSlice(arena, "in Nth command line argument");
                    i = j + 2 + " command line argument".len;
                    continue;
                }
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// re.sub(r'vtab:[0-9A-Fa-f]+', 'vtab:PTR', s)
fn maskVtab(arena: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "vtab:") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "vtab:")) {
            var j = i + 5;
            while (j < s.len and std.ascii.isHex(s[j])) j += 1;
            if (j > i + 5) {
                try out.appendSlice(arena, "vtab:PTR");
                i = j;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// The EXPLAIN QUERY PLAN rows (id|parent|notused|detail) as an indented
/// tree; other lines (errors) after it.
fn eqpTree(arena: Allocator, out: []const u8) ![]const u8 {
    const Row = struct { id: ?i64, parent: ?i64, text: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    var it = splitLines(out);
    while (it.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '|');
        const p0 = parts.next().?;
        const p1 = parts.next();
        const p2 = parts.next();
        const rest = parts.rest();
        const is_row = p1 != null and p2 != null and parts.index != null and isIntText(p0);
        if (is_row) {
            const id = std.fmt.parseInt(i64, p0, 10) catch null;
            const parent = std.fmt.parseInt(i64, std.mem.trim(u8, p1.?, " \t"), 10) catch null;
            if (id != null and parent != null) {
                try rows.append(arena, .{ .id = id, .parent = parent, .text = rest });
                continue;
            }
        }
        try rows.append(arena, .{ .id = null, .parent = null, .text = line });
    }
    var lines: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    try walk(arena, rows.items, 0, 0, &lines, &n);
    for (rows.items) |r| if (r.id == null) try appendLine(arena, &lines, &n, 0, r.text);
    return lines.items;
}

/// parts[0].lstrip('-').isdigit()
fn isIntText(s: []const u8) bool {
    const t = std.mem.trimStart(u8, s, "-");
    if (t.len == 0) return false;
    for (t) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn walk(arena: Allocator, rows: anytype, parent: i64, depth: usize, lines: *std.ArrayList(u8), n: *usize) !void {
    // Python stops at its recursion limit; so does this, on a cycle.
    if (depth > 900) return error.PlanCycle;
    for (rows) |r| {
        if (r.parent == null or r.parent.? != parent) continue;
        try appendLine(arena, lines, n, depth, r.text);
        try walk(arena, rows, r.id.?, depth + 1, lines, n);
    }
}

fn appendLine(arena: Allocator, lines: *std.ArrayList(u8), n: *usize, depth: usize, text: []const u8) !void {
    if (n.* > 0) try lines.append(arena, '\n');
    try lines.appendNTimes(arena, ' ', 2 * depth);
    try lines.appendSlice(arena, text);
    n.* += 1;
}

/// The main program of an EXPLAIN as "addr|opcode|p1|p2|p3|p4|p5" lines:
/// xqlite's EXPLAIN does not list trigger sub-programs after it, as
/// sqlite3's does, and the comment column goes.
fn codeNorm(arena: Allocator, out: []const u8) ![]const []const u8 {
    var res: std.ArrayList([]const u8) = .empty;
    var it = splitLines(out);
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        if (res.items.len > 0 and std.mem.eql(u8, fields.first(), "0")) break;
        var count: usize = 1;
        var end: usize = line.len;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] != '|') continue;
            count += 1;
            if (count == 8) end = i;
        }
        if (count < 7) {
            try res.append(arena, line);
            continue;
        }
        try res.append(arena, line[0..end]);
    }
    return res.items;
}

test splitLines {
    var it = splitLines("a\r\nb\rc\n\nd\xc2\x85e\n");
    for ([_][]const u8{ "a", "b", "c", "", "d", "e" }) |want| try std.testing.expectEqualStrings(want, it.next().?);
    try std.testing.expect(it.next() == null);
}

test isPlainQuery {
    try std.testing.expect(isPlainQuery("  select 1"));
    try std.testing.expect(isPlainQuery("VALUES(1)"));
    try std.testing.expect(!isPlainQuery("SELECTX"));
    try std.testing.expect(!isPlainQuery("INSERT INTO t VALUES(1)"));
}

test eqpTree {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try eqpTree(arena.allocator(), ""));
    try std.testing.expectEqualStrings(
        "SCAN t\n  USE TEMP B-TREE\nSEARCH u\nQUERY PLAN\nERR:x",
        try eqpTree(arena.allocator(), "QUERY PLAN\n2|0|0|SCAN t\n5|2|0|USE TEMP B-TREE\n7|0|0|SEARCH u\nERR:x"),
    );
}

test codeNorm {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The comment goes; a trigger program (its address 0 again) ends it.
    const got = try codeNorm(arena.allocator(), "0|Init|0|1|0||0|comment\n1|Halt|0|0|0||0\nERR:x\n0|Init|0|0|0||0\n");
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqualStrings("0|Init|0|1|0||0", got[0]);
    try std.testing.expectEqualStrings("ERR:x", got[2]);
}
