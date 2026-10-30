//! The render≡lower fuzzer (`ir_roundtrip`, src/fuzz_tests.zig): random
//! trees of gen.zig checked against the contract of tree.zig, that the
//! SQLite frontend compiling render(t) means what lower(t) means.
//!
//! A query event builds a query `t` and, in a fresh in-memory database
//! with gen.schema_sql, for every dialect d:
//!
//!   A   lower(t) run in d, parameters bound (and lower(t') with t' the
//!       tree whose parameters are literals of their values: the same);
//!   B   render(t') rendered in d, compiled by the SQLite frontend in every
//!       dialect e: the rows of A in e;
//!   C   CREATE VIEW from the tree in d (render.zig writes its query),
//!       then SELECT * FROM it in every dialect e: the rows of A in e;
//!
//! and render is stable (rendering the same tree twice gives the same
//! text). A table event builds a table with CHECK, DEFAULT and generated
//! columns (gen.TableSpec), creates it from the tree in d, and inserts
//! rows into it both with a lowered INSERT (DEFAULT items, left-out
//! columns) and with SQLite text, in every dialect e; the stored rows and
//! the CHECK outcomes must be what lowered queries compute from the same
//! values (a staging table of the same column types, no constraints).
//!
//! Results compare exactly: value types, integers, text and blobs bytes,
//! reals bit for bit (NaN equals NaN); rows of a query without ORDER BY as
//! multisets. Two errors are the same when their primary result codes are.
//!
//! The trees reach the lowering through a test frontend (tree_frontend)
//! whose SQL text names a job: what to build and the seeds to build it
//! from, so there is no state to share (and a schema change that compiles
//! a statement again builds the same tree).

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");
const legacy = @import("../sql/legacy.zig");
const prepare = @import("../sql/prepare.zig");
const malloc = @import("../sql/malloc.zig");
const api = @import("../vdbe/api.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const dialect = @import("../dialect/dialect.zig");
const ir = @import("ir.zig");
const tree = @import("tree.zig");
const lower = @import("lower.zig");
const render = @import("render.zig");
const gen = @import("gen.zig");

const Allocator = std.mem.Allocator;
const Dialect = dialect.Dialect;
const RC = int.RC;
const Oom = error{OutOfMemory};

/// The dialects whose frontends the fuzzer reads views and stored text
/// in. A dialect joins once its frontend parses `SELECT * FROM v`.
const dialects = [_]Dialect{ .sqlite, .postgres, .mariadb };

/// Events that share a swarm configuration.
const events_per_config = 64;
/// Rows inserted into the table of a table event.
const rows_per_table = 4;

// ================================================================== jobs

/// What the test frontend builds: `kind cfg_seed seed [arg]`.
const Job = struct {
    kind: Kind,
    cfg_seed: u64,
    seed: u64,
    arg: u64 = 0,

    const Kind = enum(u8) {
        /// The query, with parameters.
        query = 'q',
        /// The query, its parameters literals.
        literal = 'l',
        /// CREATE VIEW v<arg> AS the query (literals).
        view = 'v',
        /// SELECT * FROM (the query (literals)): what reading the view
        /// means. A query that is a subquery may give other values than
        /// the query: SQLite gives its columns an affinity (that of a
        /// compound's arms, of a column).
        wrapped = 'w',
        /// CREATE TABLE t (gen.TableSpec).
        table = 't',
        /// INSERT INTO t row <arg>, as a lowered INSERT.
        insert = 'i',
        /// INSERT INTO s row <arg>: every column, the defaults' trees for
        /// those the row leaves out.
        staging = 's',
        /// SELECT the columns of s, the generated columns' expressions and
        /// (check IS FALSE) for each CHECK, FROM s.
        expected = 'e',
    };

    fn text(j: Job, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{c} {d} {d} {d}", .{ @backingInt(j.kind), j.cfg_seed, j.seed, j.arg }, 0) catch unreachable;
    }

    fn parse(sql: []const u8) ?Job {
        var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, sql, " ;"), ' ');
        const k = it.next() orelse return null;
        if (k.len != 1) return null;
        const kind = std.enums.fromInt(Kind, k[0]) orelse return null;
        var nums: [3]u64 = undefined;
        for (&nums) |*n| n.* = std.fmt.parseUnsigned(u64, it.next() orelse return null, 10) catch return null;
        return .{ .kind = kind, .cfg_seed = nums[0], .seed = nums[1], .arg = nums[2] };
    }

    fn config(j: Job) gen.Config {
        var prng: std.Random.DefaultPrng = .init(j.cfg_seed);
        return .random(prng.random());
    }

    /// The statement of the job, in `a`.
    fn statement(j: Job, a: Allocator) Oom!tree.Stmt {
        const cfg = try a.create(gen.Config);
        cfg.* = j.config();
        var prng: std.Random.DefaultPrng = .init(j.seed);
        var g: gen.Gen = .init(a, prng.random(), cfg, j.kind != .query);
        switch (j.kind) {
            .query, .literal => return .{ .select = try g.query() },
            .view => {
                const name = try std.fmt.allocPrint(a, "v{d}", .{j.arg});
                return .{ .create_view = try tree.new(a, tree.CreateView, .{ .name = .{ .name = .{ .text = name } }, .select = try g.query() }) };
            },
            .wrapped => {
                const from = try a.dupe(tree.FromItem, &.{.{ .source = .{ .subquery = try g.query() }, .alias = .{ .name = .{ .text = "v" } } }});
                const core = try tree.new(a, tree.Core, .{ .cols = try a.dupe(tree.ResultCol, &.{.{ .star = 0 }}), .from = from });
                return .{ .select = try tree.new(a, tree.Select, .{ .body = try tree.new(a, tree.Body, .{ .core = core }) }) };
            },
            .table => return .{ .create_table = try (try g.table()).createTable(a, "t") },
            .insert, .staging => {
                const spec = try g.table();
                const row = try Row.of(a, spec, j.seed, j.arg);
                return .{ .insert = try row.insert(a, spec, j.kind == .staging) };
            },
            .expected => return .{ .select = try expectedQuery(a, try g.table()) },
        }
    }
};

fn treeRun(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    p.rc = RC.OK;
    p.tail = sql[sql.len..];
    const job = Job.parse(sql) orelse return error.ParseFailed;
    const s = try job.statement(p.arena);
    var l: lower.Lowerer = .init(p, "");
    l.statement(s) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed => return error.ParseFailed,
    };
    if (p.n_err > 0) return error.ParseFailed;
    ir.stmt.finishCoding(p);
}

const tree_frontend: dialect.Frontend = .{ .run = treeRun };

// ================================================================= tables

/// The values of a row of a table event: per base column a value, or
/// none (the column's default), given as DEFAULT in the INSERT or left
/// out.
const Row = struct {
    values: []?gen.Value,
    as_default: []bool,

    fn of(a: Allocator, spec: gen.TableSpec, seed: u64, i: u64) Oom!Row {
        var prng: std.Random.DefaultPrng = .init(seed ^ (i +% 1) *% 0x9e3779b97f4a7c15);
        const rand = prng.random();
        const r: Row = .{ .values = try a.alloc(?gen.Value, spec.base.len), .as_default = try a.alloc(bool, spec.base.len) };
        for (r.values, r.as_default) |*v, *d| {
            v.* = if (rand.uintLessThan(u8, 3) == 0) null else gen.randomValue(rand);
            d.* = rand.boolean();
        }
        return r;
    }

    /// INSERT INTO t (lowered) or s (`staging`: every column, the default
    /// expressions written out).
    fn insert(r: Row, a: Allocator, spec: gen.TableSpec, staging: bool) Oom!*tree.Insert {
        var g: gen.Gen = .init(a, undefined, undefined, true);
        var cols: std.ArrayList(tree.Name) = .empty;
        var items: std.ArrayList(*tree.Expr) = .empty;
        for (spec.base, r.values, r.as_default) |bc, v, as_default| {
            const x: *tree.Expr = if (v) |val| try g.literal(val) else if (staging)
                bc.default orelse try g.literal(.null)
            else if (as_default)
                try tree.expr(a, 0, 0, .default)
            else
                continue;
            try cols.append(a, .{ .text = bc.name });
            try items.append(a, x);
        }
        const target: tree.QName = .{ .name = .{ .text = if (staging) "s" else "t" } };
        if (items.items.len == 0) return tree.new(a, tree.Insert, .{ .table = target, .source = null });
        const rows = try a.dupe([]*tree.Expr, &.{items.items});
        const body = try tree.new(a, tree.Body, .{ .values = rows });
        return tree.new(a, tree.Insert, .{ .table = target, .cols = cols.items, .source = try tree.new(a, tree.Select, .{ .body = body }) });
    }

    /// The same INSERT INTO t as SQLite text (columns left out for
    /// DEFAULT), in `p`'s arena.
    fn text(r: Row, p: *int.Parse, spec: gen.TableSpec) ![:0]const u8 {
        var g: gen.Gen = .init(p.arena, undefined, undefined, true);
        var cols: std.ArrayList(u8) = .empty;
        var vals: std.ArrayList(u8) = .empty;
        for (spec.base, r.values) |bc, v| {
            const val = v orelse continue;
            if (cols.items.len > 0) {
                try cols.appendSlice(p.arena, ", ");
                try vals.appendSlice(p.arena, ", ");
            }
            try cols.print(p.arena, "\"{s}\"", .{bc.name});
            try vals.appendSlice(p.arena, try render.expr(p, "", try g.literal(val)));
        }
        if (cols.items.len == 0) return p.arena.dupeSentinel(u8, "INSERT INTO t DEFAULT VALUES", 0);
        return std.fmt.allocPrintSentinel(p.arena, "INSERT INTO t({s}) VALUES ({s})", .{ cols.items, vals.items }, 0);
    }
};

/// SELECT a0 ..., g0 expression ..., (check IS FALSE) ... FROM s.
fn expectedQuery(a: Allocator, spec: gen.TableSpec) Oom!*tree.Select {
    var cols: std.ArrayList(tree.ResultCol) = .empty;
    for (spec.base) |bc| {
        const names = try a.dupe(tree.Name, &.{.{ .text = bc.name }});
        try cols.append(a, .{ .expr = .{ .e = try tree.expr(a, 0, 0, .{ .column = names }) } });
    }
    for (spec.gens) |gc| try cols.append(a, .{ .expr = .{ .e = gc.e } });
    // CASE WHEN NOT chk THEN 1 ELSE 0 END: whether the CHECK fails,
    // computed as SQLite tests a CHECK (the WHEN jumps as the CHECK does,
    // so that `a OR b` does not compute b when a is true, where its value
    // would).
    for (try spec.allChecks(a)) |x| {
        const not = try tree.expr(a, 0, 0, .{ .unary = .{ .op = .not, .e = x } });
        const zero = try tree.expr(a, 0, 0, .{ .integer = "0" });
        const one = try tree.expr(a, 0, 0, .{ .integer = "1" });
        const whens = try a.dupe(*tree.Expr, &.{ not, one });
        try cols.append(a, .{ .expr = .{ .e = try tree.expr(a, 0, 0, .{ .case = .{ .operand = null, .whens = whens, .@"else" = zero } }) } });
    }
    const from = try a.dupe(tree.FromItem, &.{.{ .source = .{ .table = .{ .name = .{ .text = "s" } } } }});
    const core = try tree.new(a, tree.Core, .{ .cols = cols.items, .from = from });
    return tree.new(a, tree.Select, .{ .body = try tree.new(a, tree.Body, .{ .core = core }) });
}

/// CREATE TABLE s of the base columns of the spec, their types, nothing
/// else.
fn stagingText(a: Allocator, spec: gen.TableSpec) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "CREATE TABLE s(");
    for (spec.base, 0..) |bc, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "\"{s}\" {s}", .{ bc.name, bc.type orelse "" });
    }
    try out.appendSlice(a, ")");
    return out.items;
}

// ============================================================== database

/// A connection to a private in-memory database.
const Db = struct {
    mem: MemVfs,
    db: *int.Sqlite3,

    fn open(gpa: Allocator, io: std.Io) !*Db {
        const d = try gpa.create(Db);
        errdefer gpa.destroy(d);
        d.mem = .init(gpa, io);
        errdefer d.mem.deinit();
        var db: ?*int.Sqlite3 = null;
        const rc = main_mod.open(d.mem.interface(), ":memory:", .{}, &db);
        d.db = db orelse return error.OutOfMemory;
        if (rc != RC.OK) {
            _ = main_mod.close(d.db);
            return error.OpenFailed;
        }
        return d;
    }

    fn close(d: *Db, gpa: Allocator) void {
        std.debug.assert(main_mod.close(d.db) == RC.OK);
        d.mem.deinit();
        gpa.destroy(d);
    }

    /// Compile with the test frontend in the hooks of `d`.
    fn useTree(db: *Db, d: Dialect) void {
        main_mod.setDialect(db.db, d);
        main_mod.setFrontend(db.db, &tree_frontend);
    }

    /// Compile with the SQLite frontend in the hooks of `d`.
    fn useText(db: *Db, d: Dialect) void {
        main_mod.setDialect(db.db, d);
        main_mod.setFrontend(db.db, dialect.spec(.sqlite).frontend);
    }

    fn exec(d: *Db, sql: []const u8) !void {
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(d.db, sql, null, null, &msg);
        defer if (msg) |m| malloc.free(m.ptr);
        if (rc != RC.OK) {
            std.debug.print("ir fuzz: {s}\n  -> {s}\n", .{ sql, msg orelse "?" });
            return error.ExecFailed;
        }
    }

    /// Run `sql` (one statement) with `binds` for ?1, ?2 ...
    fn run(d: *Db, a: Allocator, sql: []const u8, binds: []const gen.Value) Oom!Outcome {
        var stmt: ?*vi.Vdbe = null;
        var rc = prepare.prepareV2(d.db, sql, &stmt, null);
        if (rc != RC.OK) return d.failure(a, rc, false);
        const v = stmt orelse return .{ .rows = &.{} };
        defer _ = api.finalize(v);
        for (binds, 1..) |b, i| {
            if (i > api.bindParameterCount(v)) break;
            _ = switch (b) {
                .null => api.bindNull(v, i),
                .int => |x| api.bindInt64(v, i, x),
                .real => |x| api.bindDouble(v, i, x),
                .text => |x| api.bindText(v, i, x),
                .blob => |x| api.bindBlob(v, i, x),
            };
        }
        var rows: std.ArrayList([]Val) = .empty;
        while (true) {
            rc = api.step(v);
            if (rc == RC.DONE) break;
            if (rc != RC.ROW) return d.failure(a, rc, true);
            const row = try a.alloc(Val, api.columnCount(v));
            for (row, 0..) |*x, i| x.* = switch (api.columnType(v, i)) {
                vi.SQLITE_INTEGER => .{ .int = api.columnInt64(v, i) },
                vi.SQLITE_FLOAT => .{ .real = @bitCast(api.columnDouble(v, i)) },
                vi.SQLITE_TEXT => .{ .text = try a.dupe(u8, api.columnText(v, i) orelse "") },
                vi.SQLITE_BLOB => .{ .blob = try a.dupe(u8, api.columnBlob(v, i) orelse "") },
                else => .null,
            };
            try rows.append(a, row);
        }
        return .{ .rows = rows.items };
    }

    fn failure(d: *Db, a: Allocator, rc: i32, step: bool) Oom!Outcome {
        return .{ .err = .{ .rc = rc & 0xff, .msg = try a.dupe(u8, main_mod.errmsg(d.db)), .step = step } };
    }
};

// ============================================================== outcomes

const Val = union(enum) {
    null,
    int: i64,
    /// The bits of the real.
    real: u64,
    text: []const u8,
    blob: []const u8,

    fn eql(x: Val, y: Val) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .null => true,
            .int => |i| i == y.int,
            .real => |r| r == y.real or (std.math.isNan(@as(f64, @bitCast(r))) and std.math.isNan(@as(f64, @bitCast(y.real)))),
            .text => |s| std.mem.eql(u8, s, y.text),
            .blob => |s| std.mem.eql(u8, s, y.blob),
        };
    }

    fn order(x: Val, y: Val) std.math.Order {
        const tx = @backingInt(std.meta.activeTag(x));
        const ty = @backingInt(std.meta.activeTag(y));
        if (tx != ty) return std.math.order(tx, ty);
        return switch (x) {
            .null => .eq,
            .int => |i| std.math.order(i, y.int),
            .real => |r| std.math.order(r, y.real),
            .text => |s| std.mem.order(u8, s, y.text),
            .blob => |s| std.mem.order(u8, s, y.blob),
        };
    }

    pub fn format(x: Val, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (x) {
            .null => try w.writeAll("NULL"),
            .int => |i| try w.print("{d}", .{i}),
            .real => |r| try w.print("{e}r", .{@as(f64, @bitCast(r))}),
            .text => |s| try w.print("'{s}'", .{s}),
            .blob => |s| try w.print("X'{x}'", .{s}),
        }
    }
};

const Outcome = union(enum) {
    rows: []const []const Val,
    err: struct { rc: i32, msg: []const u8, step: bool = false },

    fn rowLess(_: void, x: []const Val, y: []const Val) bool {
        for (x, y) |a, b| switch (a.order(b)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        };
        return x.len < y.len;
    }

    /// Whether `o` is `want`: the same rows (in order if `ordered`), or
    /// an error of the same class.
    fn same(o: Outcome, want: Outcome, a: Allocator, ordered: bool) Oom!bool {
        switch (want) {
            .err => |e| return o == .err and o.err.rc == e.rc,
            .rows => |w| {
                if (o != .rows) return false;
                const x = o.rows;
                if (x.len != w.len) return false;
                const xs = try a.dupe([]const Val, x);
                const ws = try a.dupe([]const Val, w);
                if (!ordered) {
                    std.mem.sort([]const Val, xs, {}, rowLess);
                    std.mem.sort([]const Val, ws, {}, rowLess);
                }
                for (xs, ws) |rx, rw| {
                    if (rx.len != rw.len) return false;
                    for (rx, rw) |vx, vw| if (!vx.eql(vw)) return false;
                }
                return true;
            },
        }
    }

    fn print(o: Outcome) void {
        switch (o) {
            .err => |e| std.debug.print("    error {d}: {s}\n", .{ e.rc, e.msg }),
            .rows => |rows| {
                std.debug.print("    {d} rows\n", .{rows.len});
                for (rows[0..@min(rows.len, 8)]) |row| {
                    std.debug.print("     ", .{});
                    for (row) |v| std.debug.print(" {f}", .{v});
                    std.debug.print("\n", .{});
                }
            },
        }
    }
};

// ================================================================ fuzzer

const Stats = struct {
    queries: u32 = 0,
    tables: u32 = 0,
    /// Queries whose lowering failed, in the SQLite dialect.
    query_errors: u32 = 0,
    /// Tables that could not be created.
    table_errors: u32 = 0,
    rows_checked: u32 = 0,
    /// Queries run with parameters bound (in each dialect).
    params_checked: u32 = 0,
    /// Rows a CHECK refused.
    check_failures: u32 = 0,
    /// Reads in a third dialect left out (Fuzz.readable()).
    cross_skipped: u32 = 0,
    /// Views that failed while running where the subquery did not, or
    /// the other way around.
    view_step_errors: u32 = 0,
    /// Rows whose expected values failed while the table took them.
    row_step_errors: u32 = 0,
};

const Fuzz = struct {
    gpa: Allocator,
    io: std.Io,
    seed: u64,
    event: u32,
    cfg_seed: u64,
    tree_seed: u64,
    stats: Stats = .{},

    fn mismatch(f: *Fuzz, comptime what: []const u8, args: anytype, text: ?[]const u8, got: Outcome, want: Outcome) error{Mismatch} {
        std.debug.print("\nir_roundtrip: mismatch: " ++ what, args);
        std.debug.print("\n  seed={d} event={d} (cfg_seed={d} tree_seed={d})\n", .{ f.seed, f.event, f.cfg_seed, f.tree_seed });
        if (text) |t| std.debug.print("  text: {s}\n", .{t});
        std.debug.print("  got:\n", .{});
        got.print();
        std.debug.print("  want:\n", .{});
        want.print();
        std.debug.print("  repro: zig build fuzz -- ir_roundtrip {d} --events {d}\n", .{ f.seed, f.event + 1 });
        return error.Mismatch;
    }

    fn job(f: *const Fuzz, kind: Job.Kind, arg: u64, buf: []u8) [:0]const u8 {
        return (Job{ .kind = kind, .cfg_seed = f.cfg_seed, .seed = f.tree_seed, .arg = arg }).text(buf);
    }

    // ------------------------------------------------------------- query

    fn queryEvent(f: *Fuzz, a: Allocator) !void {
        f.stats.queries += 1;
        const db = try Db.open(f.gpa, f.io);
        defer db.close(f.gpa);
        db.useText(.sqlite);
        try db.exec(gen.schema_sql);

        // The values of the parameters, and whether the order is known.
        const cfg = (Job{ .kind = .query, .cfg_seed = f.cfg_seed, .seed = f.tree_seed }).config();
        var prng: std.Random.DefaultPrng = .init(f.tree_seed);
        var g: gen.Gen = .init(a, prng.random(), &cfg, false);
        const shape = try g.query();
        const binds = g.params.items;
        const ordered = shape.order_by.len > 0;

        var buf: [96]u8 = undefined;
        var want: [dialects.len]Outcome = undefined;
        var want_view: [dialects.len]Outcome = undefined;
        for (dialects, &want, &want_view) |d, *w, *wv| {
            db.useTree(d);
            // The tree that is rendered: parameters as literals.
            w.* = try db.run(a, f.job(.literal, 0, &buf), &.{});
            wv.* = try db.run(a, f.job(.wrapped, 0, &buf), &.{});
            // The same with the parameters bound, where a constant means
            // what a parameter of its value means.
            if (binds.len == 0 or g.sort_keys) continue;
            const bound = try db.run(a, f.job(.query, 0, &buf), binds);
            // SQLite folds constants (`'a' IS NOT NULL OR f(x)` is 1, f
            // not called): an error with one only is not a difference.
            if ((bound == .err) != (w.* == .err)) continue;
            if (!try bound.same(w.*, a, ordered)) {
                db.useText(d);
                return f.mismatch("bound parameters, lowered in {s}", .{@tagName(d)}, try f.renderQuery(a, db), bound, w.*);
            }
            f.stats.params_checked += 1;
        }
        if (want[0] == .err) f.stats.query_errors += 1;

        var texts: [dialects.len]?[:0]const u8 = undefined;
        for (dialects, &texts) |d, *t| {
            db.useText(d);
            t.* = try f.renderQuery(a, db);
        }
        for (dialects, 0..) |d, di| {
            // B: the text rendered in d, compiled in every dialect.
            const text = texts[di] orelse continue;
            for (dialects, want, texts) |e, w, text_e| {
                if (!f.readable(text, d, e, text_e)) continue;
                db.useText(e);
                const got = try db.run(a, text, &.{});
                if (!try got.same(w, a, ordered)) return f.mismatch("rendered in {s}, compiled in {s}", .{ @tagName(d), @tagName(e) }, text, got, w);
            }
            // C: a view created from the tree in d, read in every dialect.
            db.useTree(d);
            const created = try db.run(a, f.job(.view, di, &buf), &.{});
            if (created == .err) {
                if (want_view[di] == .rows) return f.mismatch("CREATE VIEW in {s}", .{@tagName(d)}, text, created, want_view[di]);
                continue;
            }
            const sel = try std.fmt.allocPrint(a, "SELECT * FROM v{d}", .{di});
            for (dialects, want_view, texts) |e, w, text_e| {
                if (!f.readable(text, d, e, text_e)) continue;
                main_mod.setDialect(db.db, e);
                const got = try db.run(a, sel, &.{});
                if (try got.same(w, a, ordered)) continue;
                // A view is not always run as the same query in a
                // subquery is (sqlite3 too): an expression that fails
                // (OFFSET X'', integer overflow) may not be computed, or
                // another one first.
                const got_step = got == .err and got.err.step;
                const want_step = w == .err and w.err.step;
                const step_error = (got_step and w == .rows) or (want_step and got == .rows) or (got_step and want_step);
                if (step_error) {
                    f.stats.view_step_errors += 1;
                    continue;
                }
                return f.mismatch("view created in {s}, read in {s}", .{ @tagName(d), @tagName(e) }, text, got, w);
            }
        }
    }

    /// Whether text rendered in `d` is to mean in `e` what lowering means
    /// there. The contract (tree.zig) covers the SQLite dialect and `d`.
    /// In a third dialect a SQLite built-in that `e`'s table shadows but
    /// `d`'s does not (concat(), round(), hex() ...) is written by its
    /// name, which means `e`'s function there: checked only when the text
    /// rendered in `e` is the same (no such name).
    fn readable(f: *Fuzz, text: []const u8, d: Dialect, e: Dialect, text_e: ?[]const u8) bool {
        if (e == .sqlite or e == d) return true;
        if (text_e) |t| if (std.mem.eql(u8, t, text)) return true;
        f.stats.cross_skipped += 1;
        return false;
    }

    /// render(t') in the connection's dialect, checked to be stable; null
    /// if render does not take the tree.
    fn renderQuery(f: *Fuzz, a: Allocator, db: *Db) !?[:0]const u8 {
        var texts: [2][:0]const u8 = undefined;
        for (&texts) |*t| {
            var p: int.Parse = .{ .db = db.db, .arena = a };
            const stmt = try (Job{ .kind = .literal, .cfg_seed = f.cfg_seed, .seed = f.tree_seed }).statement(a);
            t.* = render.select(&p, "", stmt.select) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Failed => return null,
            };
        }
        if (!std.mem.eql(u8, texts[0], texts[1])) {
            std.debug.print("ir_roundtrip: render is not stable (seed={d} event={d}):\n  {s}\n  {s}\n", .{ f.seed, f.event, texts[0], texts[1] });
            return error.Mismatch;
        }
        return texts[0];
    }

    // ------------------------------------------------------------- table

    fn tableEvent(f: *Fuzz, a: Allocator) !void {
        f.stats.tables += 1;
        const cfg = (Job{ .kind = .table, .cfg_seed = f.cfg_seed, .seed = f.tree_seed }).config();
        var prng: std.Random.DefaultPrng = .init(f.tree_seed);
        var g: gen.Gen = .init(a, prng.random(), &cfg, true);
        const spec = try g.table();
        var buf: [96]u8 = undefined;

        // The text of the table in each dialect.
        var ddls: [dialects.len]?[]const u8 = undefined;
        {
            const db = try Db.open(f.gpa, f.io);
            defer db.close(f.gpa);
            for (dialects, &ddls) |d, *t| {
                db.useText(d);
                var p: int.Parse = .{ .db = db.db, .arena = a };
                t.* = render.statement(&p, "", .{ .create_table = try spec.createTable(a, "t") }) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.Failed => null,
                };
            }
        }

        for (dialects, ddls) |d, ddl_d| {
            const ddl = ddl_d orelse continue;
            const db = try Db.open(f.gpa, f.io);
            defer db.close(f.gpa);
            db.useTree(d);
            const created = try db.run(a, f.job(.table, 0, &buf), &.{});
            if (created == .err) {
                f.stats.table_errors += 1;
                continue;
            }
            db.useText(.sqlite);
            try db.exec(try stagingText(a, spec));

            for (0..rows_per_table) |ri| {
                const row = try Row.of(a, spec, f.tree_seed, ri);
                for (dialects, ddls) |e, ddl_e| {
                    if (!f.readable(ddl, d, e, ddl_e)) continue;
                    db.useText(e);
                    try db.exec("DELETE FROM s");
                    db.useTree(e);
                    const staged = try db.run(a, f.job(.staging, ri, &buf), &.{});
                    const expected = if (staged == .err) staged else try db.run(a, f.job(.expected, 0, &buf), &.{});
                    // Lowered, then as SQLite text.
                    for (0..2) |how| {
                        var p: int.Parse = .{ .db = db.db, .arena = a };
                        const text: [:0]const u8 = if (how == 0) f.job(.insert, ri, &buf) else try row.text(&p, spec);
                        if (how == 0) db.useTree(e) else db.useText(e);
                        const inserted = try db.run(a, text, &.{});
                        db.useText(e);
                        const stored = if (inserted == .err) inserted else try db.run(a, try storedQuery(a, spec), &.{});
                        try db.exec("DELETE FROM t");
                        try f.checkRow(a, spec, expected, inserted, stored, .{ @tagName(d), @tagName(e), if (how == 0) "lowered" else "text", ri }, ddl);
                        f.stats.rows_checked += 1;
                    }
                }
            }
        }
    }

    /// The outcome of inserting a row into t (and reading it back), given
    /// what the lowered queries over s expect.
    fn checkRow(f: *Fuzz, a: Allocator, spec: gen.TableSpec, expected: Outcome, inserted: Outcome, stored: Outcome, args: anytype, ddl: []const u8) !void {
        const what = "table created in {s}, row inserted in {s} ({s}), row {d}";
        // An expression that fails: the INSERT or the reading fails (with
        // which error depends on what is computed first), unless SQLite
        // did not compute it there: it may compute a constant ahead in a
        // query (a CASE branch not taken) and not in a DEFAULT.
        if (expected == .err) {
            if (stored != .err) {
                if (!expected.err.step) return f.mismatch(what, args, ddl, stored, expected);
                f.stats.row_step_errors += 1;
            }
            return;
        }
        if (expected.rows.len != 1) return f.mismatch(what, args, ddl, stored, expected);
        const want = expected.rows[0];
        const n_cols = spec.base.len + spec.gens.len;
        var check_fails = false;
        for (want[n_cols..]) |v| {
            if (v == .int and v.int == 1) check_fails = true;
        }
        if (check_fails) {
            if (inserted != .err or inserted.err.rc != RC.CONSTRAINT) {
                return f.mismatch(what ++ " (a CHECK fails)", args, ddl, inserted, .{ .err = .{ .rc = RC.CONSTRAINT, .msg = "CHECK constraint failed" } });
            }
            f.stats.check_failures += 1;
            return;
        }
        const rows = try a.dupe([]const Val, &.{want[0..n_cols]});
        if (!try stored.same(.{ .rows = rows }, a, true)) return f.mismatch(what, args, ddl, stored, .{ .rows = rows });
    }
};

/// SELECT the base and generated columns FROM t.
fn storedQuery(a: Allocator, spec: gen.TableSpec) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "SELECT ");
    for (spec.base, 0..) |bc, i| try out.print(a, "{s}\"{s}\"", .{ if (i > 0) ", " else "", bc.name });
    for (spec.gens) |gc| try out.print(a, ", \"{s}\"", .{gc.name});
    try out.appendSlice(a, " FROM t");
    return out.items;
}

/// The `ir_roundtrip` fuzzer: `events_max` events, a query or a table
/// each, the swarm configuration drawn again every events_per_config.
pub fn roundtrip(gpa: Allocator, io: std.Io, seed: u64, events_max: u32) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var f: Fuzz = .{ .gpa = gpa, .io = io, .seed = seed, .event = 0, .cfg_seed = 0, .tree_seed = 0 };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..events_max) |i| {
        if (i % events_per_config == 0) f.cfg_seed = rand.int(u64);
        f.event = @intCast(i);
        f.tree_seed = rand.int(u64);
        _ = arena.reset(.retain_capacity);
        if (rand.uintLessThan(u8, 5) == 0) try f.tableEvent(arena.allocator()) else try f.queryEvent(arena.allocator());
    }
    const s = f.stats;
    if (!@import("builtin").is_test) std.debug.print(
        "ir_roundtrip: {d} queries ({d} failing, {d} with parameters bound), {d} tables ({d} not created), {d} rows checked ({d} refused by a CHECK); skipped: {d} third-dialect reads, {d} view errors, {d} row errors\n",
        .{ s.queries, s.query_errors, s.params_checked, s.tables, s.table_errors, s.rows_checked, s.check_failures, s.cross_skipped, s.view_step_errors, s.row_step_errors },
    );
}

test {
    _ = gen;
}
