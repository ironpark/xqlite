//! Regression tests of what the render≡lower fuzzer (fuzz.zig) found:
//! trees whose lowering and rendered text did not mean the same, and
//! crashes of functions it called.

const std = @import("std");
const testing = std.testing;
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");
const dialect = @import("../dialect/dialect.zig");
const ir = @import("ir.zig");
const tree = @import("tree.zig");
const lower = @import("lower.zig");
const render = @import("render.zig");
const Conn = @import("../sql/sql_test.zig").Conn;

const Expr = tree.Expr;
const Oom = error{OutOfMemory};

const B = struct {
    a: std.mem.Allocator,

    fn e(b: B, kind: tree.Kind) Oom!*Expr {
        return tree.expr(b.a, 0, 0, kind);
    }

    fn int_(b: B, digits: []const u8) Oom!*Expr {
        return b.e(.{ .integer = digits });
    }

    fn str(b: B, s: []const u8) Oom!*Expr {
        return b.e(.{ .string = s });
    }

    fn col(b: B, name: []const u8) Oom!*Expr {
        return b.e(.{ .column = try b.a.dupe(tree.Name, &.{.{ .text = name }}) });
    }

    fn body(b: B, x: tree.Body) Oom!*tree.Body {
        return tree.new(b.a, tree.Body, x);
    }

    /// VALUES of one-column rows.
    fn values(b: B, items: []const *Expr) Oom!*tree.Body {
        const rows = try b.a.alloc([]*Expr, items.len);
        for (items, rows) |x, *r| r.* = try b.a.dupe(*Expr, &.{x});
        return b.body(.{ .values = rows });
    }

    fn core(b: B, items: []const *Expr, from: []const tree.FromItem) Oom!*tree.Body {
        const cols = try b.a.alloc(tree.ResultCol, items.len);
        for (items, cols) |x, *c| c.* = .{ .expr = .{ .e = x } };
        return b.body(.{ .core = try tree.new(b.a, tree.Core, .{ .cols = cols, .from = try b.a.dupe(tree.FromItem, from) }) });
    }

    fn sel(b: B, s: tree.Select) Oom!*tree.Select {
        return tree.new(b.a, tree.Select, s);
    }

    fn by(b: B, items: []const *Expr) Oom![]tree.SortItem {
        const out = try b.a.alloc(tree.SortItem, items.len);
        for (items, out) |x, *it| it.* = .{ .expr = x };
        return out;
    }

    fn cte(b: B, name: []const u8, column: []const u8, s: *tree.Select) Oom!*tree.With {
        const ctes = try b.a.dupe(tree.Cte, &.{.{ .name = .{ .text = name }, .cols = try b.a.dupe(tree.Name, &.{.{ .text = column }}), .select = s }});
        return tree.new(b.a, tree.With, .{ .recursive = false, .ctes = ctes });
    }

    fn table(name: []const u8) tree.FromItem {
        return .{ .source = .{ .table = .{ .name = .{ .text = name } } } };
    }
};

/// (VALUES (3), (1), (2)) ORDER BY 1: lowering set the ORDER BY on the
/// VALUES, which ignores it.
fn nestedValuesOrdered(b: B) Oom!*tree.Select {
    const inner = try b.sel(.{ .body = try b.values(&.{ try b.int_("3"), try b.int_("1"), try b.int_("2") }) });
    return b.sel(.{ .body = try b.body(.{ .nested = inner }), .order_by = try b.by(&.{try b.int_("1")}) });
}

/// SELECT 3 UNION ALL VALUES (1), (2) ORDER BY 1 LIMIT 2: rendered as
/// such, a syntax error (no ORDER BY/LIMIT after VALUES).
fn compoundEndingInValues(b: B) Oom!*tree.Select {
    const right = try b.values(&.{ try b.int_("1"), try b.int_("2") });
    const body = try b.body(.{ .compound = .{ .op = .@"union", .all = true, .left = try b.core(&.{try b.int_("3")}, &.{}), .right = right } });
    return b.sel(.{ .body = body, .order_by = try b.by(&.{try b.int_("1")}), .limit = try b.int_("2") });
}

/// WITH a(x) AS (SELECT 1) (WITH c(y) AS (SELECT 2) SELECT x, y FROM a,
/// c): rendered WITH ... WITH (a syntax error); lowering dropped the
/// inner WITH (no such table: c).
fn withAroundWith(b: B) Oom!*tree.Select {
    const inner = try b.sel(.{
        .with = try b.cte("c", "y", try b.sel(.{ .body = try b.core(&.{try b.int_("2")}, &.{}) })),
        .body = try b.core(&.{ try b.col("x"), try b.col("y") }, &.{ B.table("a"), B.table("c") }),
    });
    return b.sel(.{
        .with = try b.cte("a", "x", try b.sel(.{ .body = try b.core(&.{try b.int_("1")}, &.{}) })),
        .body = try b.body(.{ .nested = inner }),
    });
}

/// SELECT n FROM (VALUES (2), (1)) AS t(n) ORDER BY (FALSE AND TRUE), n:
/// lowering folded the AND to 0, a column number (out of range).
fn andFalseOrdered(b: B) Oom!*tree.Select {
    const from: tree.FromItem = .{
        .source = .{ .subquery = try b.sel(.{ .body = try b.values(&.{ try b.int_("2"), try b.int_("1") }) }) },
        .alias = .{ .name = .{ .text = "t" }, .cols = try b.a.dupe(tree.Name, &.{.{ .text = "n" }}) },
    };
    const and_ = try b.e(.{ .binary = .{ .op = .@"and", .l = try b.e(.{ .boolean = false }), .r = try b.e(.{ .boolean = true }) } });
    return b.sel(.{ .body = try b.core(&.{try b.col("n")}, &.{from}), .order_by = try b.by(&.{ and_, try b.col("n") }) });
}

/// The same ORDER BY (TRUE AND 0): `x AND 0` the parser does fold, so the
/// text fails (out of range), and the lowering must too.
fn andZeroOrdered(b: B) Oom!*tree.Select {
    const s = try andFalseOrdered(b);
    s.order_by[0].expr.kind.binary.r = try b.int_("0");
    return s;
}

/// (VALUES ('2024-02-30'), (FALSE) UNION ALL VALUES ('12abc') LIMIT 2.0)
/// ORDER BY 1:
/// lowering put the LIMIT on the compound, the text on a subquery of it
/// (as it must), which keeps other rows.
fn limitOfCompoundEndingInValues(b: B) Oom!*tree.Select {
    const left = try b.values(&.{ try b.str("2024-02-30"), try b.e(.{ .boolean = false }) });
    const compound = try b.body(.{ .compound = .{ .op = .@"union", .all = true, .left = left, .right = try b.values(&.{try b.str("12abc")}) } });
    const inner = try b.sel(.{ .body = compound, .limit = try b.e(.{ .float = "2e0" }) });
    return b.sel(.{ .body = try b.body(.{ .nested = inner }), .order_by = try b.by(&.{try b.int_("1")}) });
}

const cases = [_]struct { build: *const fn (B) Oom!*tree.Select, rows: []const u8, err: ?[]const u8 = null }{
    .{ .build = nestedValuesOrdered, .rows = "1\n2\n3\n" },
    .{ .build = compoundEndingInValues, .rows = "1\n2\n" },
    .{ .build = withAroundWith, .rows = "1|2\n" },
    .{ .build = andFalseOrdered, .rows = "1\n2\n" },
    .{ .build = andZeroOrdered, .rows = "", .err = "1st ORDER BY term out of range - should be between 1 and 1" },
    // What sqlite3 gives for the text.
    .{ .build = limitOfCompoundEndingInValues, .rows = "0\n12abc\n" },
};

/// Test frontends: the SQL text is the number of a case, lowered, or
/// rendered and compiled by the SQLite frontend.
fn runCase(p: *int.Parse, sql: [:0]const u8, comptime rendered: bool) (int.Oom || int.ParseError)!void {
    p.rc = int.RC.OK;
    p.tail = sql[sql.len..];
    const i = std.fmt.parseInt(usize, std.mem.trim(u8, sql, " ;"), 10) catch return error.ParseFailed;
    const s = try cases[i].build(.{ .a = p.arena });
    if (rendered) {
        const text = render.select(p, "", s) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Failed => return error.ParseFailed,
        };
        try ir.stmt.lowerSqliteText(p, text);
    } else {
        var l: lower.Lowerer = .init(p, "");
        l.statement(.{ .select = s }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Failed => return error.ParseFailed,
        };
    }
    if (p.n_err > 0) return error.ParseFailed;
    ir.stmt.finishCoding(p);
}

fn lowerRun(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return runCase(p, sql, false);
}

fn renderRun(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return runCase(p, sql, true);
}

const lower_frontend: dialect.Frontend = .{ .run = lowerRun };
const render_frontend: dialect.Frontend = .{ .run = renderRun };

test "ir roundtrip: queries the fuzzer found lowered and rendered differently" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    var failed = false;
    for (cases, 0..) |case, i| {
        for ([_]*const dialect.Frontend{ &lower_frontend, &render_frontend }) |f| {
            main_mod.setFrontend(c.db, f);
            var buf: [8]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "{d}", .{i});
            if (case.err) |msg| {
                c.expectError(sql, msg) catch {
                    std.debug.print("case {d}, {s}: no error\n", .{ i, if (f == &lower_frontend) "lowered" else "rendered" });
                    failed = true;
                };
                continue;
            }
            const got = c.query(sql) catch "(error)";
            defer if (got.ptr != "(error)".ptr) testing.allocator.free(got);
            if (!std.mem.eql(u8, case.rows, got)) {
                std.debug.print("case {d}, {s}: {s}\n", .{ i, if (f == &lower_frontend) "lowered" else "rendered", got });
                failed = true;
            }
        }
    }
    try testing.expect(!failed);
}

test "ir roundtrip: IS TRUE in a DEFAULT, which SQLite does not resolve" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b: B = .{ .a = arena.allocator() };
    // 2 IS TRUE, 'a' IS NOT FALSE, 'a' IS (1 IN ()): 1, 0, 1 (as SELECT
    // gives them); SQLite compiles the DEFAULT text `2 IS TRUE` as
    // `2 IS 1`.
    const is_true = try b.e(.{ .is_bool = .{ .e = try b.int_("2"), .value = true, .not = false } });
    const is_not_false = try b.e(.{ .compare = .{ .op = .is_not, .l = try b.str("a"), .r = try b.e(.{ .boolean = false }) } });
    const in_empty = try b.e(.{ .in_list = .{ .e = try b.int_("1"), .not = false, .items = &.{} } });
    const is_empty_in = try b.e(.{ .compare = .{ .op = .is, .l = try b.str("a"), .r = in_empty } });
    const cols = try b.a.dupe(tree.ColumnDef, &.{
        .{ .name = .{ .text = "x" }, .constraints = try b.a.dupe(tree.ColConstraint, &.{.{ .kind = .{ .default = is_true } }}) },
        .{ .name = .{ .text = "y" }, .constraints = try b.a.dupe(tree.ColConstraint, &.{.{ .kind = .{ .default = is_not_false } }}) },
        .{ .name = .{ .text = "w" }, .constraints = try b.a.dupe(tree.ColConstraint, &.{.{ .kind = .{ .default = is_empty_in } }}) },
        .{ .name = .{ .text = "z" } },
    });
    const ct = try tree.new(b.a, tree.CreateTable, .{ .name = .{ .name = .{ .text = "t" } }, .columns = cols });
    var p: int.Parse = .{ .db = c.db, .arena = b.a };
    try c.exec(try render.statement(&p, "", .{ .create_table = ct }));
    try c.exec("INSERT INTO t(z) VALUES (0)");
    try c.expectRows("SELECT x, y, w, 2 IS TRUE, 'a' IS NOT FALSE, 'a' IS (1 IN ()) FROM t", "1|0|1|1|0|1\n");
}

test "ir roundtrip: dialect functions on edge values" {
    try dialect.Dialect.requireBuilt(&.{ .postgres, .mariadb });
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // right(s, n) with n the smallest integer: overflowed negating it.
    try c.expectRows("SELECT xq_postgres_right('abc', -9223372036854775808), xq_postgres_right('abc', -1)", "|bc\n");
    // An empty CONCAT(): its buffer was freed twice.
    try c.expectRows("SELECT xq_mariadb_concat('', ''), xq_mariadb_concat('a', '')", "|a\n");
}
