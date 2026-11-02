//! Tests of the syntax tree IR: trees built by hand (the semantic nodes
//! every frontend may use, not only those PostgreSQL's produces) are
//! lowered (lower.zig) and rendered (render.zig), and the two must give
//! the same rows in every dialect: the contract between the backends.

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

/// Building trees in a statement's arena.
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
        const names = try b.a.alloc(tree.Name, 1);
        names[0] = .{ .text = name };
        return b.e(.{ .column = names });
    }

    fn list(b: B, items: []const *Expr) Oom![]*Expr {
        return b.a.dupe(*Expr, items);
    }

    fn call(b: B, name: []const u8, owner: ?dialect.Dialect, args: []const *Expr) Oom!*Expr {
        return b.e(.{ .func = try tree.new(b.a, tree.Func, .{ .name = .{ .text = name }, .dialect = owner, .args = try b.list(args) }) });
    }

    /// SELECT items AS c0, c1 ... [FROM from].
    fn select(b: B, items: []const *Expr, from: []const tree.FromItem) Oom!*tree.Select {
        var cols = try b.a.alloc(tree.ResultCol, items.len);
        for (items, 0..) |x, i| cols[i] = .{ .expr = .{ .e = x, .alias = .{ .text = try std.fmt.allocPrint(b.a, "c{d}", .{i}) } } };
        const core = try tree.new(b.a, tree.Core, .{ .cols = cols, .from = try b.a.dupe(tree.FromItem, from) });
        return tree.new(b.a, tree.Select, .{ .body = try tree.new(b.a, tree.Body, .{ .core = core }) });
    }

    /// (VALUES rows...) AS t(cols...)
    fn values(b: B, rows: []const []const *Expr, name: []const u8, cols: []const []const u8) Oom!tree.FromItem {
        var r = try b.a.alloc([]*Expr, rows.len);
        for (rows, 0..) |row, i| r[i] = try b.list(row);
        var names = try b.a.alloc(tree.Name, cols.len);
        for (cols, 0..) |c, i| names[i] = .{ .text = c };
        const sel = try tree.new(b.a, tree.Select, .{ .body = try tree.new(b.a, tree.Body, .{ .values = r }) });
        return .{ .source = .{ .subquery = sel }, .alias = .{ .name = .{ .text = name }, .cols = names } };
    }
};

fn divisions(b: B) Oom!*tree.Select {
    const seven = try b.int_("7");
    const two = try b.int_("2");
    return b.select(&.{
        try b.e(.{ .div = .{ .kind = .sqlite, .l = seven, .r = two } }),
        try b.e(.{ .div = .{ .kind = .real, .l = seven, .r = two } }),
        try b.e(.{ .div = .{ .kind = .int, .l = seven, .r = two } }),
        try b.e(.{ .binary = .{ .op = .rem, .l = seven, .r = two } }),
        try b.e(.{ .unary = .{ .op = .neg, .e = try b.e(.{ .unary = .{ .op = .neg, .e = seven } }) } }),
    }, &.{});
}

fn strings(b: B) Oom!*tree.Select {
    const args = try b.list(&.{ try b.str("a"), try b.e(.null), try b.int_("1") });
    return b.select(&.{
        try b.e(.{ .concat = .{ .args = args, .null_policy = .skip } }),
        try b.e(.{ .concat = .{ .args = args, .null_policy = .propagate } }),
        try b.e(.{ .concat = .{ .args = try b.list(&.{ try b.str("x"), try b.int_("2") }), .null_policy = .propagate } }),
        try b.e(.{ .compare = .{ .op = .eq, .l = try b.str("a"), .r = try b.str("A"), .collation = "NOCASE" } }),
        try b.e(.{ .compare = .{ .op = .eq, .l = try b.str("a"), .r = try b.str("A"), .collation = "BINARY" } }),
        try b.e(.{ .compare = .{ .op = .is_not, .l = try b.e(.null), .r = try b.int_("1") } }),
        try b.e(.{ .collate = .{ .e = try b.str("b"), .collation = "NOCASE" } }),
    }, &.{});
}

fn likes(b: B) Oom!*tree.Select {
    const s = try b.str("a_C");
    const pat = try b.str("a\\_c");
    return b.select(&.{
        try b.e(.{ .like = .{ .e = s, .pat = try b.str("A%"), .case_sensitive = true, .escape = .backslash } }),
        try b.e(.{ .like = .{ .e = s, .pat = try b.str("A%"), .case_sensitive = false, .escape = .none } }),
        try b.e(.{ .like = .{ .e = s, .pat = pat, .case_sensitive = false, .escape = .backslash } }),
        try b.e(.{ .like = .{ .e = s, .pat = pat, .case_sensitive = true, .escape = .backslash, .not = true } }),
        try b.e(.{ .like = .{ .e = s, .pat = try b.str("a!_C"), .case_sensitive = false, .escape = .{ .expr = try b.str("!") } } }),
        try b.e(.{ .like = .{ .e = s, .pat = pat, .case_sensitive = true, .escape = .none } }),
    }, &.{});
}

fn casts(b: B) Oom!*tree.Select {
    return b.select(&.{
        try b.e(.{ .cast = .{ .e = try b.str("12abc"), .mode = .{ .affinity = "INTEGER" } } }),
        try b.e(.{ .cast = .{ .e = try b.str("yes"), .mode = .{ .func = "xq_pg_bool" } } }),
        try b.e(.{ .cast = .{ .e = try b.str("abcdef"), .mode = .{ .truncate = 3 } } }),
        try b.e(.{ .cast = .{ .e = try b.e(.{ .float = "1.26" }), .mode = .{ .round = 1 } } }),
        try b.e(.{ .cast = .{ .e = try b.str("2024-01-02 10:00:00"), .mode = .{ .typed = .{ .func = "xq_cast", .type_arg = "date" } } } }),
        try b.e(.{ .coerce = .{ .e = try b.str("12"), .decl_type = "int(11)", .schema = "main", .table = "t", .column = "c" } }),
        try b.e(.{ .boolean = true }),
        try b.e(.{ .blob = "0aff" }),
    }, &.{});
}

/// Functions of a dialect's table and SQLite built-ins a dialect
/// shadows: the same function in every dialect.
fn functions(b: B) Oom!*tree.Select {
    return b.select(&.{
        try b.call("greatest", .postgres, &.{ try b.int_("1"), try b.e(.null), try b.int_("3") }),
        try b.call("concat", .mariadb, &.{ try b.str("a"), try b.e(.null) }),
        try b.call("power", .postgres, &.{ try b.int_("2"), try b.int_("10") }),
        try b.call("round", null, &.{try b.e(.{ .float = "2.5" })}),
        try b.call("concat", null, &.{ try b.str("a"), try b.e(.null) }),
    }, &.{});
}

fn predicates(b: B) Oom!*tree.Select {
    const x = try b.col("x");
    const from = try b.values(&.{
        &.{ try b.int_("1"), try b.str("p") },
        &.{ try b.e(.null), try b.str("q") },
        &.{ try b.int_("3"), try b.e(.null) },
    }, "t", &.{ "x", "y" });
    var s = try b.select(&.{
        x,
        try b.e(.{ .is_bool = .{ .e = try b.e(.{ .compare = .{ .op = .gt, .l = x, .r = try b.int_("1") } }), .value = true, .not = false } }),
        try b.e(.{ .is_null = .{ .e = try b.col("y"), .not = true } }),
        try b.e(.{ .between = .{ .e = x, .not = false, .lo = try b.int_("0"), .hi = try b.int_("2") } }),
        try b.e(.{ .in_list = .{ .e = x, .not = true, .items = try b.list(&.{ try b.int_("1"), try b.int_("2") }) } }),
        try b.e(.{ .case = .{ .operand = null, .whens = try b.list(&.{ try b.e(.{ .is_null = .{ .e = x, .not = false } }), try b.str("none") }), .@"else" = try b.str("some") } }),
        try b.e(.{ .compare = .{ .op = .lt, .l = try b.e(.{ .row = try b.list(&.{ x, try b.int_("1") }) }), .r = try b.e(.{ .row = try b.list(&.{ try b.int_("3"), try b.int_("0") }) }) } }),
    }, &.{from});
    // NULLs last ascending, as PostgreSQL sorts.
    s.order_by = try b.a.dupe(tree.SortItem, &.{.{ .expr = x, .nulls = .last }});
    s.limit = try b.int_("5");
    s.offset = try b.int_("0");
    return s;
}

fn queries(b: B) Oom!*tree.Select {
    const from = try b.values(&.{ &.{try b.int_("1")}, &.{try b.int_("2")}, &.{try b.int_("3")} }, "t", &.{"n"});
    const n = try b.col("n");
    const inner = try b.select(&.{n}, &.{from});
    const row_number = try tree.new(b.a, tree.Func, .{
        .name = .{ .text = "row_number" },
        .over = try tree.new(b.a, tree.WindowSpec, .{ .order_by = try b.a.dupe(tree.SortItem, &.{.{ .expr = n, .dir = .desc }}) }),
    });
    const sum = try tree.new(b.a, tree.Func, .{ .name = .{ .text = "sum" }, .args = try b.list(&.{n}), .filter = try b.e(.{ .compare = .{ .op = .gt, .l = n, .r = try b.int_("1") } }) });
    const sub = try b.select(&.{try b.e(.{ .func = sum })}, &.{try b.values(&.{ &.{try b.int_("1")}, &.{try b.int_("2")}, &.{try b.int_("3")} }, "u", &.{"n"})});
    var s = try b.select(&.{
        n,
        try b.e(.{ .func = row_number }),
        try b.e(.{ .in_select = .{ .e = n, .not = false, .sel = inner } }),
        try b.e(.{ .exists = inner }),
        try b.e(.{ .subquery = sub }),
    }, &.{from});
    s.order_by = try b.a.dupe(tree.SortItem, &.{.{ .expr = n, .dir = .asc }});
    // A compound with a CTE: WITH w(k) AS (SELECT 9) SELECT ... UNION ALL SELECT k ... FROM w.
    const w = try b.select(&.{try b.int_("9")}, &.{});
    const ctes = try b.a.dupe(tree.Cte, &.{.{ .name = .{ .text = "w" }, .cols = try b.a.dupe(tree.Name, &.{.{ .text = "k" }}), .select = w }});
    const k = try b.col("k");
    const right = try b.select(&.{ k, k, k, k, k }, &.{.{ .source = .{ .table = .{ .name = .{ .text = "w" } } } }});
    const left = try tree.new(b.a, tree.Body, .{ .nested = s });
    const body = try tree.new(b.a, tree.Body, .{ .compound = .{ .op = .@"union", .all = true, .left = left, .right = right.body } });
    return tree.new(b.a, tree.Select, .{ .with = try tree.new(b.a, tree.With, .{ .recursive = false, .ctes = ctes }), .body = body });
}

const cases = [_]*const fn (B) Oom!*tree.Select{ divisions, strings, likes, casts, functions, predicates, queries };

/// Test frontends: the SQL text is the number of a case, whose tree is
/// lowered (lower.zig), or rendered (render.zig) and compiled by the
/// SQLite frontend, as the schema's text is.
fn runCase(p: *int.Parse, sql: [:0]const u8, comptime rendered: bool) (int.Oom || int.ParseError)!void {
    p.rc = int.RC.OK;
    p.tail = sql[sql.len..];
    const i = std.fmt.parseInt(usize, std.mem.trim(u8, sql, " ;"), 10) catch return error.ParseFailed;
    const s = try cases[i](.{ .a = p.arena });
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

fn rowsOf(c: *Conn, d: dialect.Dialect, f: *const dialect.Frontend, case: usize) ![]u8 {
    main_mod.setDialect(c.db, d);
    main_mod.setFrontend(c.db, f);
    var buf: [8]u8 = undefined;
    return c.query(try std.fmt.bufPrint(&buf, "{d}", .{case}));
}

test "ir: lowering and the rendered text mean the same, in every dialect" {
    // The cases use functions of each dialect (xq_div, ...).
    try dialect.Dialect.requireBuilt(&.{ .postgres, .mariadb, .mssql, .oracle });
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const expected = [cases.len][]const u8{
        "3|3.5|3|1|7\n",
        "a1|NULL|x2|1|0|1|b\n",
        "0|1|1|1|1|0\n",
        "12|1|abc|1.3|2024-01-02|12|1|\n\xff\n",
        "3|NULL|1024.0|3.0|a\n",
        "1|0|1|1|0|some|1\n3|1|0|0|1|some|0\nNULL|0|1|NULL|NULL|none|NULL\n",
        "1|3|1|1|5\n2|2|1|1|5\n3|1|1|1|5\n9|9|9|9|9\n",
    };
    for (0..cases.len) |i| {
        for (std.enums.values(dialect.Dialect)) |d| {
            for ([_]*const dialect.Frontend{ &lower_frontend, &render_frontend }) |f| {
                const got = try rowsOf(&c, d, f, i);
                defer testing.allocator.free(got);
                testing.expectEqualStrings(expected[i], got) catch |err| {
                    std.debug.print("case {d}, {s}, {s}\n", .{ i, d.name(), if (f == &lower_frontend) "lowered" else "rendered" });
                    return err;
                };
            }
        }
    }
}

test "ir: render text" {
    try dialect.Dialect.requireBuilt(&.{ .postgres, .mariadb });
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    main_mod.setDialect(c.db, .postgres);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: int.Parse = .{ .db = c.db, .arena = arena.allocator() };
    const b: B = .{ .a = arena.allocator() };
    const cases_text = [_]struct { *Expr, []const u8 }{
        .{ try b.e(.{ .div = .{ .kind = .real, .l = try b.col("a"), .r = try b.int_("2") } }), "(CAST(\"a\" AS REAL) / 2)" },
        .{ try b.e(.{ .unary = .{ .op = .neg, .e = try b.e(.{ .unary = .{ .op = .neg, .e = try b.int_("1") } }) } }), "(- -1)" },
        .{ try b.call("greatest", .postgres, &.{try b.col("a")}), "xq_postgres_greatest(\"a\")" },
        .{ try b.call("abs", null, &.{try b.col("a")}), "abs(\"a\")" },
        .{ try b.e(.{ .like = .{ .e = try b.col("a"), .pat = try b.str("x%"), .case_sensitive = true, .escape = .backslash } }), "(xq_like('x%', \"a\"))" },
        .{ try b.e(.{ .compare = .{ .op = .eq, .l = try b.col("a"), .r = try b.str("x"), .collation = "NOCASE" } }), "((\"a\" COLLATE NOCASE) = 'x')" },
        .{ try b.e(.{ .identity_default = .{ .sequence = "t_id_seq" } }), "nextval('t_id_seq')" },
    };
    for (cases_text) |x| try testing.expectEqualStrings(x[1], try render.expr(&p, "", x[0]));
    // A SQLite built-in the connection's dialect shadows.
    main_mod.setDialect(c.db, .mariadb);
    try testing.expectEqualStrings("xq_sqlite_concat(\"a\", 1)", try render.expr(&p, "", try b.e(.{ .concat = .{ .args = try b.list(&.{ try b.col("a"), try b.int_("1") }), .null_policy = .skip } })));
    // No parameters in the schema.
    try testing.expectError(error.Failed, render.expr(&p, "", try b.e(.{ .param = 1 })));
}
