//! A generator of random syntax trees (tree.zig) over a small fixed
//! schema, for the render≡lower fuzzer (fuzz.zig): expressions with every
//! semantic node (casts, concatenation, division, collations, LIKE,
//! functions of SQLite, of the engine and of dialects' tables, Coerce,
//! booleans, parameters), queries (joins, subqueries, VALUES, aggregates,
//! windows, compounds, CTEs, ORDER BY with NULLS FIRST/LAST, LIMIT and
//! OFFSET), and tables with CHECK, DEFAULT and generated columns.
//!
//! A tree is a function of a Config (the swarm: which kinds come up and how
//! often) and a seed, so that a frontend can build it again from a few
//! numbers. With `literal_params`, a parameter is generated as the literal
//! of its bound value (the same random choices otherwise): render.zig does
//! not take parameters, the schema has none.
//!
//! Not generated: IdentityDefault, which render.zig writes as
//! nextval('seq') (the exception of the contract: lowering fills identity
//! columns itself, and a sequence advances each time it is read), and
//! functions whose result is not a function of their arguments (random(),
//! the time of day, the session's state).

const std = @import("std");
const tree = @import("tree.zig");
const Dialect = @import("../dialect/dialect.zig").Dialect;
const fuzz = @import("../testing/fuzz.zig");

const Allocator = std.mem.Allocator;
const Expr = tree.Expr;
const Oom = error{OutOfMemory};
const KindTag = std.meta.Tag(tree.Kind);

// ================================================================ schema

/// The tables every tree may read, with rows of edge values.
pub const schema_sql =
    \\CREATE TABLE t1(id INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT, b BLOB, n, c TEXT COLLATE NOCASE);
    \\CREATE INDEX t1_s ON t1(s);
    \\CREATE TABLE t2(id INTEGER PRIMARY KEY, j INTEGER NOT NULL, x REAL, y TEXT NOT NULL, z NUMERIC);
    \\CREATE INDEX t2_j ON t2(j);
    \\INSERT INTO t1 VALUES
    \\  (1, NULL, NULL, NULL, NULL, NULL, NULL),
    \\  (2, 0, -0.0, '', X'', 0, 'abc'),
    \\  (3, 9223372036854775807, 1e308, 'Hello', X'00ff', 'Mixed', 'ABC'),
    \\  (4, -9223372036854775808, -1e308, 'héllo wörld', X'61', 1.5, 'a_c'),
    \\  (5, 1, 0.5, '12abc', X'3132', X'01', 'a%c'),
    \\  (6, -1, 3.0, 'ÄÖÜ äöü', NULL, '-0', ' abc '),
    \\  (7, 42, 2.5, 'a\_b', X'c3a9', 'x', 'abc  '),
    \\  (8, 9007199254740993, 1e-308, '10', X'7f', 9223372036854775807, NULL);
    \\INSERT INTO t2 VALUES
    \\  (1, 1, NULL, 'a', NULL),
    \\  (2, 2, 0.0, 'A', '1e3'),
    \\  (3, 2, -2.5, 'b', 12),
    \\  (4, 0, 1e308, '', 'abc'),
    \\  (5, -1, NULL, 'é', -0.0),
    \\  (6, 9223372036854775807, 4.0, 'Hello', X'00');
;

const Table = struct { name: []const u8, cols: []const []const u8, rows: u64 };

const tables = [_]Table{
    .{ .name = "t1", .cols = &.{ "id", "i", "r", "s", "b", "n", "c" }, .rows = 8 },
    .{ .name = "t2", .cols = &.{ "id", "j", "x", "y", "z" }, .rows = 6 },
};

// ================================================================ values

pub const Value = union(enum) {
    null,
    int: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

const value_pool = [_]Value{
    .null,                              .{ .int = 0 },                        .{ .int = 1 },            .{ .int = -1 },
    .{ .int = 2 },                      .{ .int = 7 },                        .{ .int = 42 },           .{ .int = std.math.maxInt(i64) },
    .{ .int = std.math.minInt(i64) },   .{ .int = 9007199254740993 },         .{ .real = 0.0 },         .{ .real = -0.0 },
    .{ .real = 0.5 },                   .{ .real = 2.5 },                     .{ .real = -2.5 },        .{ .real = 1e308 },
    .{ .real = -1e308 },                .{ .real = 1e-308 },                  .{ .real = 3.0 },         .{ .text = "" },
    .{ .text = "a" },                   .{ .text = "A" },                     .{ .text = "abc" },       .{ .text = "ABC" },
    .{ .text = "Hello" },
    .{ .text = "héllo" },
    .{ .text = "ÄÖÜ" },
    .{ .text = " abc " },               .{ .text = "abc  " },                 .{ .text = "12abc" },     .{ .text = "10" },
    .{ .text = "1e3" },                 .{ .text = "a_c" },                   .{ .text = "a%c" },       .{ .text = "a\\_c" },
    .{ .text = "-0" },                  .{ .text = "true" },                  .{ .text = "yes" },       .{ .text = "2024-01-02" },
    .{ .text = "2024-02-30 10:00:00" }, .{ .text = "{\"a\":1,\"b\":[1,2]}" }, .{ .text = "[1,\"x\"]" }, .{ .blob = "" },
    .{ .blob = "\x00\xff" },            .{ .blob = "a" },                     .{ .blob = "\xc3\xa9" },
};

pub fn randomValue(rand: std.Random) Value {
    return value_pool[rand.uintLessThan(usize, value_pool.len)];
}

// ================================================================ config

/// The kinds of expression node, as the swarm weighs them.
pub const ExprKind = enum {
    literal,
    column,
    param,
    boolean,
    unary,
    binary,
    json_op,
    div,
    compare,
    concat,
    cast,
    func,
    dialect_func,
    case,
    in_list,
    in_select,
    exists,
    subquery,
    between,
    like,
    is_null,
    is_bool,
    row,
    collate,
    coerce,
    aggregate,
    window,
};

pub const BodyKind = enum { core, values, compound, nested };

pub const SourceKind = enum { table, subquery, values, cte };

pub const Config = struct {
    exprs: std.enums.EnumArray(ExprKind, u32),
    bodies: std.enums.EnumArray(BodyKind, u32),
    sources: std.enums.EnumArray(SourceKind, u32),
    /// Depth of expressions and of nested queries.
    expr_depth: u32,
    query_depth: u32,
    /// Out of 256.
    leaf_chance: u8,
    from_chance: u8,
    where_chance: u8,
    group_chance: u8,
    order_chance: u8,
    limit_chance: u8,
    with_chance: u8,
    distinct_chance: u8,
    param_chance: u8,

    pub fn random(rand: std.Random) Config {
        var c: Config = .{
            .exprs = fuzz.randomEnumWeights(rand, ExprKind),
            .bodies = fuzz.randomEnumWeights(rand, BodyKind),
            .sources = fuzz.randomEnumWeights(rand, SourceKind),
            .expr_depth = rand.intRangeAtMost(u32, 1, 4),
            .query_depth = rand.intRangeAtMost(u32, 0, 2),
            .leaf_chance = rand.intRangeAtMost(u8, 30, 160),
            .from_chance = rand.intRangeAtMost(u8, 100, 250),
            .where_chance = rand.int(u8),
            .group_chance = rand.int(u8) / 2,
            .order_chance = rand.int(u8),
            .limit_chance = rand.int(u8) / 2,
            .with_chance = rand.int(u8) / 3,
            .distinct_chance = rand.int(u8) / 3,
            .param_chance = rand.int(u8),
        };
        // A query needs a core to have rows from the tables; a source of
        // FROM a table.
        if (c.bodies.get(.core) == 0) c.bodies.set(.core, rand.intRangeAtMost(u32, 1, 100));
        if (c.sources.get(.table) == 0) c.sources.set(.table, rand.intRangeAtMost(u32, 1, 100));
        return c;
    }
};

// ============================================================= generator

/// A column a name may refer to: `qual.name`, or `name` alone (qual null).
const Col = struct { qual: ?[]const u8, name: []const u8 };

/// The columns of a query level, and those of the queries around it.
const Scope = struct {
    cols: []const Col,
    outer: ?*const Scope,
};

/// What an expression may contain where it is.
const Ctx = struct {
    scope: ?*const Scope = null,
    depth: u32,
    /// Aggregates (a result column, HAVING or ORDER BY of an aggregate
    /// query), window functions (a result column, ORDER BY).
    agg: bool = false,
    win: bool = false,
    /// In the schema (CHECK, DEFAULT, generated columns): no subqueries,
    /// parameters or functions that are not deterministic.
    stored: bool = false,
    /// In a DEFAULT, which SQLite compiles without resolving it: no row
    /// values, which it does not check there ("row value misused"
    /// elsewhere).
    default: bool = false,

    fn child(cx: Ctx) Ctx {
        var c = cx;
        c.depth -|= 1;
        return c;
    }

    /// An operand of an aggregate or a window function.
    fn plain(cx: Ctx) Ctx {
        var c = cx.child();
        c.agg = false;
        c.win = false;
        return c;
    }
};

/// A CTE visible to the queries being generated.
const CteInfo = struct { name: []const u8, cols: []const []const u8, rows: u64 };

pub const Gen = struct {
    a: Allocator,
    rand: std.Random,
    cfg: *const Config,
    /// Parameters become literals of their values (for render).
    literal_params: bool = false,
    /// The values of ?1, ?2 ... (bound by the fuzzer).
    params: std.ArrayList(Value) = .empty,
    names: u32 = 0,
    ctes: std.ArrayList(CteInfo) = .empty,
    /// Whether the last core generated is an aggregate query.
    agg_core: bool = false,
    /// How deep queries may still nest in the query being generated.
    qdepth: u32 = 0,
    /// The rows a query being generated may make (joins are bounded by
    /// it, and a subquery that may run once for each row by what is left),
    /// so that every tree runs fast; the rows of the last one generated.
    budget: u64 = 4096,
    rows: u64 = 0,
    /// Whether the tree has an ORDER BY or GROUP BY (anywhere, windows
    /// too): there a constant is not always what a parameter of its value
    /// is (a column number, folded, a sort of its own).
    sort_keys: bool = false,
    /// The nodes generated, by kind.
    kinds: std.enums.EnumArray(KindTag, u32) = .initFill(0),

    pub fn init(a: Allocator, rand: std.Random, cfg: *const Config, literal_params: bool) Gen {
        return .{ .a = a, .rand = rand, .cfg = cfg, .literal_params = literal_params };
    }

    fn chance(g: *Gen, out_of_256: u8) bool {
        return g.rand.int(u8) < out_of_256;
    }

    fn pick(g: *Gen, comptime T: type, items: []const T) T {
        return items[g.rand.uintLessThan(usize, items.len)];
    }

    fn e(g: *Gen, kind: tree.Kind) Oom!*Expr {
        g.kinds.set(kind, g.kinds.get(kind) + 1);
        return tree.expr(g.a, 0, 0, kind);
    }

    fn list(g: *Gen, items: []const *Expr) Oom![]*Expr {
        return g.a.dupe(*Expr, items);
    }

    fn name(g: *Gen, comptime prefix: []const u8) Oom![]const u8 {
        g.names += 1;
        return std.fmt.allocPrint(g.a, prefix ++ "{d}", .{g.names});
    }

    fn str(g: *Gen, s: []const u8) Oom!*Expr {
        return g.e(.{ .string = s });
    }

    fn int(g: *Gen, v: i64) Oom!*Expr {
        return g.literal(.{ .int = v });
    }

    // ---------------------------------------------------------- literals

    /// The literal of `v`: a negative number is the negation of its
    /// magnitude, as frontends parse it.
    pub fn literal(g: *Gen, v: Value) Oom!*Expr {
        switch (v) {
            .null => return g.e(.null),
            .int => |i| {
                const digits = try std.fmt.allocPrint(g.a, "{d}", .{@abs(i)});
                const x = try g.e(.{ .integer = digits });
                return if (i < 0) g.e(.{ .unary = .{ .op = .neg, .e = x } }) else x;
            },
            .real => |r| {
                const text = try std.fmt.allocPrint(g.a, "{e}", .{@abs(r)});
                const x = try g.e(.{ .float = text });
                return if (std.math.signbit(r)) g.e(.{ .unary = .{ .op = .neg, .e = x } }) else x;
            },
            .text => |s| return g.str(s),
            .blob => |b| {
                const hex = try g.a.alloc(u8, b.len * 2);
                const digits = "0123456789abcdef";
                for (b, 0..) |c, i| {
                    hex[2 * i] = digits[c >> 4];
                    hex[2 * i + 1] = digits[c & 15];
                }
                return g.e(.{ .blob = hex });
            },
        }
    }

    /// Literals as a frontend may spell them (hexadecimal, odd reals).
    fn oddLiteral(g: *Gen) Oom!*Expr {
        const ints = [_][]const u8{ "0x10", "0xffffffffffffffff", "0x7fffffffffffffff", "9223372036854775808", "00012" };
        const reals = [_][]const u8{ ".5", "1.", "1e999", "1.5e10", "0.0", "123456789012345678901234567890" };
        if (g.rand.boolean()) return g.e(.{ .integer = g.pick([]const u8, &ints) });
        return g.e(.{ .float = g.pick([]const u8, &reals) });
    }

    fn param(g: *Gen) Oom!*Expr {
        var v = randomValue(g.rand);
        // -?1 is 0 - ?1, +0.0 for 0.0, where -0.0 (the literal) is -0.0.
        if (v == .real and v.real == 0) v = .{ .real = 0.5 };
        // Mostly a new parameter, sometimes one used before.
        if (g.params.items.len > 0 and g.rand.uintLessThan(u8, 4) == 0) {
            const n = g.rand.uintLessThan(usize, g.params.items.len);
            if (g.literal_params) return g.literal(g.params.items[n]);
            return g.e(.{ .param = @intCast(n + 1) });
        }
        try g.params.append(g.a, v);
        if (g.literal_params) return g.literal(v);
        return g.e(.{ .param = @intCast(g.params.items.len) });
    }

    fn column(g: *Gen, cx: Ctx) Oom!?*Expr {
        var s = cx.scope orelse return null;
        // Mostly this level's columns, sometimes an outer query's.
        while (s.outer) |o| {
            if (s.cols.len > 0 and g.rand.uintLessThan(u8, 4) != 0) break;
            s = o;
        }
        if (s.cols.len == 0) return null;
        const c = g.pick(Col, s.cols);
        const qualified = c.qual != null and g.rand.uintLessThan(u8, 8) != 0;
        const names = try g.a.alloc(tree.Name, if (qualified) 2 else 1);
        if (qualified) {
            names[0] = .{ .text = c.qual.? };
            names[1] = .{ .text = c.name };
        } else names[0] = .{ .text = c.name };
        return g.e(.{ .column = names });
    }

    fn leaf(g: *Gen, cx: Ctx) Oom!*Expr {
        const w = g.cfg.exprs;
        var weights: std.enums.EnumArray(LeafKind, u32) = .initFill(0);
        weights.set(.literal, w.get(.literal));
        weights.set(.column, if (cx.scope != null) w.get(.column) else 0);
        weights.set(.param, if (cx.stored) 0 else w.get(.param) * @as(u32, g.cfg.param_chance) / 256);
        weights.set(.boolean, w.get(.boolean));
        var total: u32 = 0;
        for (weights.values) |x| total += x;
        if (total == 0) weights.set(.literal, 1);
        switch (fuzz.chooseWeighted(g.rand, LeafKind, weights)) {
            .literal => {
                if (g.rand.uintLessThan(u8, 16) == 0) return g.oddLiteral();
                return g.literal(randomValue(g.rand));
            },
            .column => return (try g.column(cx)) orelse g.literal(randomValue(g.rand)),
            .param => return g.param(),
            .boolean => return g.e(.{ .boolean = g.rand.boolean() }),
        }
    }

    const LeafKind = enum { literal, column, param, boolean };

    // ------------------------------------------------------- expressions

    pub fn expr(g: *Gen, cx: Ctx) Oom!*Expr {
        if (cx.depth == 0 or g.chance(g.cfg.leaf_chance)) return g.leaf(cx);
        const kind = fuzz.chooseWeighted(g.rand, ExprKind, g.cfg.exprs);
        const c = cx.child();
        switch (kind) {
            .literal, .column, .param, .boolean => return g.leaf(cx),
            .unary => return g.e(.{ .unary = .{ .op = g.rand.enumValue(tree.UnOp), .e = try g.expr(c) } }),
            .binary => {
                const ops = [_]tree.BinOp{ .add, .sub, .mul, .rem, .@"and", .@"or", .bit_and, .bit_or, .shl, .shr };
                return g.e(.{ .binary = .{ .op = g.pick(tree.BinOp, &ops), .l = try g.expr(c), .r = try g.expr(c) } });
            },
            .json_op => {
                const docs = [_][]const u8{ "{\"a\":1,\"b\":[1,2]}", "[1,\"x\",null]", "{\"a\":{\"b\":\"c\"}}", "3" };
                const paths = [_]Value{ .{ .text = "$.a" }, .{ .text = "$.b[1]" }, .{ .text = "a" }, .{ .int = 1 }, .{ .text = "$" }, .{ .text = "$[0]" } };
                const l = if (g.rand.boolean()) try g.str(g.pick([]const u8, &docs)) else try g.expr(c);
                const r = if (g.rand.boolean()) try g.literal(g.pick(Value, &paths)) else try g.expr(c);
                return g.e(.{ .binary = .{ .op = if (g.rand.boolean()) .json_get else .json_get_text, .l = l, .r = r } });
            },
            .div => {
                const kinds = [_]@FieldType(tree.Div, "kind"){ .sqlite, .real, .int };
                return g.e(.{ .div = .{ .kind = g.pick(@FieldType(tree.Div, "kind"), &kinds), .l = try g.expr(c), .r = try g.expr(c) } });
            },
            .compare => return g.e(.{ .compare = .{
                .op = g.rand.enumValue(tree.CmpOp),
                .l = try g.expr(c),
                .r = try g.expr(c),
                .collation = g.collation(),
            } }),
            .concat => {
                const n = g.rand.intRangeAtMost(usize, 2, 4);
                const args = try g.a.alloc(*Expr, n);
                for (args) |*x| x.* = try g.expr(c);
                return g.e(.{ .concat = .{ .args = args, .null_policy = if (g.rand.boolean()) .propagate else .skip } });
            },
            .cast => return g.cast(c),
            .func => return g.func(c),
            .dialect_func => return g.dialectFunc(c),
            .case => {
                const n = g.rand.intRangeAtMost(usize, 1, 3);
                const whens = try g.a.alloc(*Expr, 2 * n);
                for (whens) |*x| x.* = try g.expr(c);
                return g.e(.{ .case = .{
                    .operand = if (g.rand.boolean()) try g.expr(c) else null,
                    .whens = whens,
                    .@"else" = if (g.rand.boolean()) try g.expr(c) else null,
                } });
            },
            .in_list => {
                const n = g.rand.uintLessThan(usize, 5);
                const items = try g.a.alloc(*Expr, n);
                for (items) |*x| x.* = try g.expr(c);
                return g.e(.{ .in_list = .{ .e = try g.expr(c), .not = g.rand.boolean(), .items = items } });
            },
            .in_select => {
                if (cx.stored or g.qdepth == 0) return g.leaf(cx);
                const lhs = try g.expr(c);
                return g.e(.{ .in_select = .{ .e = lhs, .not = g.rand.boolean(), .sel = try g.subSelect(cx, 1) } });
            },
            .exists => {
                if (cx.stored or g.qdepth == 0) return g.leaf(cx);
                return g.e(.{ .exists = try g.subSelect(cx, g.rand.intRangeAtMost(u32, 1, 3)) });
            },
            .subquery => {
                if (cx.stored or g.qdepth == 0) return g.leaf(cx);
                return g.e(.{ .subquery = try g.subSelect(cx, 1) });
            },
            .between => return g.e(.{ .between = .{ .e = try g.expr(c), .not = g.rand.boolean(), .lo = try g.expr(c), .hi = try g.expr(c) } }),
            .like => return g.like(c),
            .is_null => return g.e(.{ .is_null = .{ .e = try g.expr(c), .not = g.rand.boolean() } }),
            .is_bool => {
                const values = [_]?bool{ true, false, null };
                return g.e(.{ .is_bool = .{ .e = try g.expr(c), .value = g.pick(?bool, &values), .not = g.rand.boolean() } });
            },
            .row => return if (cx.default) g.leaf(cx) else g.rowValue(cx),
            .collate => return g.e(.{ .collate = .{ .e = try g.expr(c), .collation = g.collation() orelse "BINARY" } }),
            .coerce => {
                if (cx.stored) return g.leaf(cx);
                const types = [_][]const u8{ "int(11)", "tinyint", "bigint unsigned", "varchar(3)", "char(2)", "double", "decimal(5,2)", "date", "datetime", "text", "float", "year" };
                return g.e(.{ .coerce = .{
                    .e = try g.expr(c),
                    .decl_type = g.pick([]const u8, &types),
                    .schema = "main",
                    .table = "t",
                    .column = "c",
                    .ignore = g.rand.boolean(),
                    .not_null = g.rand.uintLessThan(u8, 4) == 0,
                } });
            },
            .aggregate => {
                if (!cx.agg) return g.expr(c);
                return g.aggregate(cx);
            },
            .window => {
                if (!cx.win) return g.expr(c);
                return g.window(cx);
            },
        }
    }

    fn collation(g: *Gen) ?[]const u8 {
        const names = [_]?[]const u8{ null, "BINARY", "NOCASE", "RTRIM" };
        return g.pick(?[]const u8, &names);
    }

    fn cast(g: *Gen, c: Ctx) Oom!*Expr {
        const x = try g.expr(c);
        const Mode = std.meta.Tag(tree.CastMode);
        const mode: tree.CastMode = switch (g.rand.enumValue(Mode)) {
            .affinity => .{ .affinity = g.pick([]const u8, &.{ "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", "INT", "FLOAT", "VARCHAR(10)", "DECIMAL(5,2)" }) },
            .func => .{ .func = g.pick([]const u8, &.{ "xq_pg_bool", "date", "datetime", "time", "julianday", "json", "lower", "upper", "abs", "typeof", "hex", "quote", "length", "unicode", "trim" }) },
            .truncate => .{ .truncate = g.pick(i64, &.{ 0, 1, 3, 10, -1 }) },
            .round => .{ .round = g.rand.intRangeAtMost(i64, -2, 4) },
            .typed => .{ .typed = .{ .func = "xq_cast", .type_arg = g.pick([]const u8, &.{ "date", "datetime", "time" }) } },
        };
        return g.e(.{ .cast = .{ .e = x, .target_type = "t", .mode = mode } });
    }

    const Fn = struct { name: []const u8, min: u8, max: u8 };

    /// Deterministic SQLite built-ins and engine functions (no arguments
    /// that may make them allocate without bound).
    const functions = [_]Fn{
        .{ .name = "abs", .min = 1, .max = 1 },          .{ .name = "coalesce", .min = 2, .max = 4 },
        .{ .name = "ifnull", .min = 2, .max = 2 },       .{ .name = "nullif", .min = 2, .max = 2 },
        .{ .name = "iif", .min = 2, .max = 3 },          .{ .name = "length", .min = 1, .max = 1 },
        .{ .name = "lower", .min = 1, .max = 1 },        .{ .name = "upper", .min = 1, .max = 1 },
        .{ .name = "hex", .min = 1, .max = 1 },          .{ .name = "quote", .min = 1, .max = 1 },
        .{ .name = "typeof", .min = 1, .max = 1 },       .{ .name = "substr", .min = 2, .max = 3 },
        .{ .name = "substring", .min = 2, .max = 3 },    .{ .name = "replace", .min = 3, .max = 3 },
        .{ .name = "trim", .min = 1, .max = 2 },         .{ .name = "ltrim", .min = 1, .max = 2 },
        .{ .name = "rtrim", .min = 1, .max = 2 },        .{ .name = "instr", .min = 2, .max = 2 },
        .{ .name = "round", .min = 1, .max = 2 },        .{ .name = "max", .min = 2, .max = 3 },
        .{ .name = "min", .min = 2, .max = 3 },          .{ .name = "char", .min = 1, .max = 3 },
        .{ .name = "unicode", .min = 1, .max = 1 },      .{ .name = "sign", .min = 1, .max = 1 },
        .{ .name = "octet_length", .min = 1, .max = 1 }, .{ .name = "concat", .min = 1, .max = 3 },
        .{ .name = "concat_ws", .min = 2, .max = 4 },    .{ .name = "likely", .min = 1, .max = 1 },
        .{ .name = "unlikely", .min = 1, .max = 1 },     .{ .name = "glob", .min = 2, .max = 2 },
        .{ .name = "like", .min = 2, .max = 3 },         .{ .name = "unhex", .min = 1, .max = 2 },
        .{ .name = "json", .min = 1, .max = 1 },         .{ .name = "json_valid", .min = 1, .max = 1 },
        .{ .name = "json_type", .min = 1, .max = 2 },    .{ .name = "json_extract", .min = 2, .max = 2 },
        .{ .name = "json_array", .min = 0, .max = 3 },   .{ .name = "json_quote", .min = 1, .max = 1 },
        .{ .name = "date", .min = 1, .max = 1 },         .{ .name = "julianday", .min = 1, .max = 1 },
        .{ .name = "strftime", .min = 2, .max = 2 },     .{ .name = "unixepoch", .min = 1, .max = 1 },
        .{ .name = "xq_div", .min = 2, .max = 2 },       .{ .name = "xq_xor", .min = 2, .max = 2 },
        .{ .name = "xq_bitxor", .min = 2, .max = 2 },    .{ .name = "xq_cast", .min = 2, .max = 2 },
        .{ .name = "xq_like", .min = 2, .max = 3 },      .{ .name = "xq_ilike", .min = 2, .max = 3 },
        .{ .name = "xq_pg_bool", .min = 1, .max = 1 },   .{ .name = "printf", .min = 1, .max = 3 },
        .{ .name = "format", .min = 1, .max = 3 },
    };

    fn func(g: *Gen, c: Ctx) Oom!*Expr {
        const f = g.pick(Fn, &functions);
        const n = g.rand.intRangeAtMost(usize, f.min, f.max);
        const args = try g.a.alloc(*Expr, n);
        for (args, 0..) |*x, i| x.* = try g.funcArg(f.name, i, c);
        return g.call(f.name, null, args);
    }

    /// Arguments some functions need to be meaningful.
    fn funcArg(g: *Gen, f: []const u8, i: usize, c: Ctx) Oom!*Expr {
        const eql = std.mem.eql;
        if (i == 1 and eql(u8, f, "xq_cast")) return g.str(g.pick([]const u8, &.{ "date", "datetime", "time" }));
        if (i == 0 and (eql(u8, f, "printf") or eql(u8, f, "format"))) {
            return g.str(g.pick([]const u8, &.{ "%d", "%s|%s", "%.3f", "%x", "%q", "%5s", "%c", "%-4d|", "%g", "%%" }));
        }
        if (i == 0 and eql(u8, f, "strftime")) return g.str(g.pick([]const u8, &.{ "%Y", "%j %H", "%s", "%f" }));
        if (i == 1 and (eql(u8, f, "json_extract") or eql(u8, f, "json_type"))) return g.str(g.pick([]const u8, &.{ "$.a", "$.b[1]", "$", "$[1]" }));
        if (i == 2 and (eql(u8, f, "like") or eql(u8, f, "xq_like") or eql(u8, f, "xq_ilike")) and g.rand.boolean()) {
            return g.str(g.pick([]const u8, &.{ "!", "\\", "" }));
        }
        return g.expr(c);
    }

    fn call(g: *Gen, f: []const u8, owner: ?Dialect, args: []*Expr) Oom!*Expr {
        return g.e(.{ .func = try tree.new(g.a, tree.Func, .{ .name = .{ .text = f }, .dialect = owner, .args = args }) });
    }

    /// Deterministic functions of the dialects' tables (several shadow a
    /// SQLite built-in of the same name).
    const dialect_functions = [_]struct { Dialect, Fn }{
        .{ .postgres, .{ .name = "greatest", .min = 1, .max = 3 } },
        .{ .postgres, .{ .name = "least", .min = 1, .max = 3 } },
        .{ .postgres, .{ .name = "left", .min = 2, .max = 2 } },
        .{ .postgres, .{ .name = "right", .min = 2, .max = 2 } },
        .{ .postgres, .{ .name = "reverse", .min = 1, .max = 1 } },
        .{ .postgres, .{ .name = "split_part", .min = 3, .max = 3 } },
        .{ .postgres, .{ .name = "starts_with", .min = 2, .max = 2 } },
        .{ .postgres, .{ .name = "floor", .min = 1, .max = 1 } },
        .{ .postgres, .{ .name = "ceil", .min = 1, .max = 1 } },
        .{ .postgres, .{ .name = "sqrt", .min = 1, .max = 1 } },
        .{ .postgres, .{ .name = "power", .min = 2, .max = 2 } },
        .{ .postgres, .{ .name = "mod", .min = 2, .max = 2 } },
        .{ .postgres, .{ .name = "trunc", .min = 1, .max = 2 } },
        .{ .postgres, .{ .name = "sign", .min = 1, .max = 1 } },
        .{ .postgres, .{ .name = "log", .min = 1, .max = 2 } },
        .{ .mariadb, .{ .name = "concat", .min = 1, .max = 3 } },
        .{ .mariadb, .{ .name = "floor", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "pow", .min = 2, .max = 2 } },
        .{ .mariadb, .{ .name = "round", .min = 1, .max = 2 } },
        .{ .mariadb, .{ .name = "truncate", .min = 2, .max = 2 } },
        .{ .mariadb, .{ .name = "left", .min = 2, .max = 2 } },
        .{ .mariadb, .{ .name = "reverse", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "hex", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "field", .min = 2, .max = 3 } },
        .{ .mariadb, .{ .name = "elt", .min = 2, .max = 3 } },
        .{ .mariadb, .{ .name = "locate", .min = 3, .max = 3 } },
        .{ .mariadb, .{ .name = "find_in_set", .min = 2, .max = 2 } },
        .{ .mariadb, .{ .name = "year", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "dayofweek", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "ascii", .min = 1, .max = 1 } },
        .{ .mariadb, .{ .name = "json_unquote", .min = 1, .max = 1 } },
    };

    fn dialectFunc(g: *Gen, c: Ctx) Oom!*Expr {
        const df = g.pick(@TypeOf(dialect_functions[0]), &dialect_functions);
        const f = df[1];
        const n = g.rand.intRangeAtMost(usize, f.min, f.max);
        const args = try g.a.alloc(*Expr, n);
        for (args) |*x| x.* = try g.expr(c);
        return g.call(f.name, df[0], args);
    }

    fn like(g: *Gen, c: Ctx) Oom!*Expr {
        const patterns = [_][]const u8{ "a%", "A%", "%c", "a_c", "a\\_c", "a!_c", "%", "_", "", "h%o", "%É%", "%\\%%", "\\", "!" };
        const pat = if (g.rand.boolean()) try g.str(g.pick([]const u8, &patterns)) else try g.expr(c);
        const escape: tree.Escape = switch (g.rand.uintLessThan(u8, 3)) {
            0 => .none,
            1 => .backslash,
            else => .{ .expr = if (g.rand.uintLessThan(u8, 4) != 0) try g.str(g.pick([]const u8, &.{ "!", "\\", "a" })) else try g.expr(c) },
        };
        return g.e(.{ .like = .{ .e = try g.expr(c), .pat = pat, .not = g.rand.boolean(), .case_sensitive = g.rand.boolean(), .escape = escape } });
    }

    /// A comparison of row values, or a row IN a query of as many columns.
    fn rowValue(g: *Gen, cx: Ctx) Oom!*Expr {
        const c = cx.child();
        const n = g.rand.intRangeAtMost(usize, 2, 3);
        const l = try g.a.alloc(*Expr, n);
        for (l) |*x| x.* = try g.expr(c);
        const lhs = try g.e(.{ .row = l });
        if (!cx.stored and g.qdepth > 0 and g.rand.uintLessThan(u8, 3) == 0) {
            return g.e(.{ .in_select = .{ .e = lhs, .not = g.rand.boolean(), .sel = try g.subSelect(cx, @intCast(n)) } });
        }
        const r = try g.a.alloc(*Expr, n);
        for (r) |*x| x.* = try g.expr(c);
        return g.e(.{ .compare = .{ .op = g.rand.enumValue(tree.CmpOp), .l = lhs, .r = try g.e(.{ .row = r }), .collation = if (g.rand.uintLessThan(u8, 8) == 0) g.collation() else null } });
    }

    const aggregates = [_]Fn{
        .{ .name = "count", .min = 0, .max = 1 },            .{ .name = "sum", .min = 1, .max = 1 },
        .{ .name = "total", .min = 1, .max = 1 },            .{ .name = "avg", .min = 1, .max = 1 },
        .{ .name = "min", .min = 1, .max = 1 },              .{ .name = "max", .min = 1, .max = 1 },
        .{ .name = "group_concat", .min = 1, .max = 2 },     .{ .name = "string_agg", .min = 2, .max = 2 },
        .{ .name = "json_group_array", .min = 1, .max = 1 },
    };

    fn aggregate(g: *Gen, cx: Ctx) Oom!*Expr {
        const a = g.pick(Fn, &aggregates);
        const c = cx.plain();
        const n = g.rand.intRangeAtMost(usize, a.min, a.max);
        const args = try g.a.alloc(*Expr, n);
        for (args) |*x| x.* = try g.expr(c);
        const f = try tree.new(g.a, tree.Func, .{ .name = .{ .text = a.name }, .args = args });
        if (n == 0) f.star = true;
        if (n == 1 and g.rand.uintLessThan(u8, 4) == 0) f.distinct = true;
        if (g.rand.uintLessThan(u8, 4) == 0) f.filter = try g.expr(c);
        if (!f.distinct and n > 0 and g.rand.uintLessThan(u8, 4) == 0) f.order_by = try g.sortItems(c, 1, null);
        return g.e(.{ .func = f });
    }

    fn window(g: *Gen, cx: Ctx) Oom!*Expr {
        const c = cx.plain();
        const fns = [_]Fn{
            .{ .name = "row_number", .min = 0, .max = 0 },  .{ .name = "rank", .min = 0, .max = 0 },
            .{ .name = "dense_rank", .min = 0, .max = 0 },  .{ .name = "percent_rank", .min = 0, .max = 0 },
            .{ .name = "cume_dist", .min = 0, .max = 0 },   .{ .name = "ntile", .min = 1, .max = 1 },
            .{ .name = "lag", .min = 1, .max = 2 },         .{ .name = "lead", .min = 1, .max = 2 },
            .{ .name = "first_value", .min = 1, .max = 1 }, .{ .name = "last_value", .min = 1, .max = 1 },
            .{ .name = "sum", .min = 1, .max = 1 },         .{ .name = "count", .min = 1, .max = 1 },
            .{ .name = "max", .min = 1, .max = 1 },         .{ .name = "min", .min = 1, .max = 1 },
        };
        const w = g.pick(Fn, &fns);
        const n = g.rand.intRangeAtMost(usize, w.min, w.max);
        const args = try g.a.alloc(*Expr, n);
        for (args, 0..) |*x, i| x.* = if (i == 1 or std.mem.eql(u8, w.name, "ntile")) try g.int(g.rand.intRangeAtMost(i64, 1, 3)) else try g.expr(c);
        const spec = try tree.new(g.a, tree.WindowSpec, .{});
        if (g.rand.boolean()) spec.partition = try g.list(&.{try g.expr(c)});
        if (g.rand.uintLessThan(u8, 4) != 0) spec.order_by = try g.sortItems(c, g.rand.intRangeAtMost(usize, 1, 2), null);
        if (g.rand.uintLessThan(u8, 3) == 0) {
            const units = [_]@FieldType(tree.Frame, "unit"){ .rows, .range, .groups };
            const starts = [_]tree.Bound{ .{ .kind = .unbounded_preceding }, .{ .kind = .current_row }, .{ .kind = .preceding, .expr = try g.int(1) } };
            const ends = [_]?tree.Bound{ null, .{ .kind = .current_row }, .{ .kind = .unbounded_following }, .{ .kind = .following, .expr = try g.int(2) } };
            spec.frame = .{
                .unit = g.pick(@FieldType(tree.Frame, "unit"), &units),
                .start = g.pick(tree.Bound, &starts),
                .end = g.pick(?tree.Bound, &ends),
                .exclude = g.rand.enumValue(@FieldType(tree.Frame, "exclude")),
            };
        }
        const f = try tree.new(g.a, tree.Func, .{ .name = .{ .text = w.name }, .args = args, .over = spec });
        return g.e(.{ .func = f });
    }

    /// ORDER BY items: expressions of `c`, or (with `positions`) the
    /// number of a result column.
    fn sortItems(g: *Gen, c: Ctx, n: usize, max_pos: ?u32) Oom![]tree.SortItem {
        g.sort_keys = true;
        const items = try g.a.alloc(tree.SortItem, n);
        for (items) |*it| {
            const x = if (max_pos) |np| (if (g.rand.boolean()) try g.int(g.rand.intRangeAtMost(i64, 1, np)) else try g.expr(c)) else try g.expr(c);
            it.* = .{
                .expr = x,
                .dir = g.rand.enumValue(@FieldType(tree.SortItem, "dir")),
                .nulls = g.rand.enumValue(@FieldType(tree.SortItem, "nulls")),
            };
        }
        return items;
    }

    // ----------------------------------------------------------- queries

    /// A top-level query: any number of columns, `*` allowed.
    pub fn query(g: *Gen) Oom!*tree.Select {
        return g.select(null, null, g.cfg.query_depth, true);
    }

    fn subSelect(g: *Gen, cx: Ctx, ncols: u32) Oom!*tree.Select {
        return g.select(cx.scope, ncols, g.qdepth - 1, false);
    }

    /// A query of `ncols` columns (any if null), whose expressions may
    /// refer to the columns of `outer`.
    fn select(g: *Gen, outer: ?*const Scope, ncols: ?u32, qdepth: u32, top: bool) Oom!*tree.Select {
        const n = ncols orelse g.rand.intRangeAtMost(u32, 1, 4);
        const s = try tree.new(g.a, tree.Select, .{ .body = undefined });
        const saved_depth = g.qdepth;
        g.qdepth = qdepth;
        defer g.qdepth = saved_depth;
        const ctes_before = g.ctes.items.len;
        defer g.ctes.shrinkRetainingCapacity(ctes_before);
        if (g.chance(g.cfg.with_chance)) {
            const cte_n = g.rand.intRangeAtMost(u32, 1, 3);
            const cte_name = try g.name("w");
            const cols = try g.a.alloc(tree.Name, cte_n);
            const col_names = try g.a.alloc([]const u8, cte_n);
            for (cols, col_names, 0..) |*cn, *nm, i| {
                nm.* = try std.fmt.allocPrint(g.a, "k{d}", .{i});
                cn.* = .{ .text = nm.* };
            }
            const sel = try g.select(null, cte_n, qdepth -| 1, false);
            const ctes = try g.a.alloc(tree.Cte, 1);
            ctes[0] = .{ .name = .{ .text = cte_name }, .cols = cols, .select = sel, .materialized = g.pick(?bool, &.{ null, true, false }) };
            s.with = try tree.new(g.a, tree.With, .{ .recursive = false, .ctes = ctes });
            try g.ctes.append(g.a, .{ .name = cte_name, .cols = col_names, .rows = g.rows });
        }
        var core_scope: ?*const Scope = null;
        s.body = try g.body(outer, n, ncols == null and top, qdepth, &core_scope);
        const rows = g.rows;
        defer g.rows = rows;
        if (g.chance(g.cfg.order_chance)) {
            const c: Ctx = .{ .scope = core_scope, .depth = g.cfg.expr_depth -| 1, .agg = g.agg_core, .win = core_scope != null };
            // A compound sorts by its result columns only.
            const np: ?u32 = if (n > 0) n else null;
            s.order_by = if (core_scope != null)
                try g.sortItems(c, g.rand.intRangeAtMost(usize, 1, 3), np)
            else
                try g.positions(n);
        }
        if (g.chance(g.cfg.limit_chance)) {
            s.limit = try g.limitValue();
            if (g.rand.boolean()) s.offset = try g.limitValue();
        } else if (g.rand.uintLessThan(u8, 32) == 0) s.offset = try g.limitValue();
        return s;
    }

    fn positions(g: *Gen, n: u32) Oom![]tree.SortItem {
        g.sort_keys = true;
        const k = g.rand.intRangeAtMost(usize, 1, n);
        const items = try g.a.alloc(tree.SortItem, k);
        for (items) |*it| it.* = .{
            .expr = try g.int(g.rand.intRangeAtMost(i64, 1, n)),
            .dir = g.rand.enumValue(@FieldType(tree.SortItem, "dir")),
            .nulls = g.rand.enumValue(@FieldType(tree.SortItem, "nulls")),
        };
        return items;
    }

    fn limitValue(g: *Gen) Oom!*Expr {
        return switch (g.rand.uintLessThan(u8, 8)) {
            0 => g.int(-1),
            1 => g.param(),
            2 => g.e(.{ .binary = .{ .op = .add, .l = try g.int(1), .r = try g.int(1) } }),
            3 => g.literal(.{ .real = 2.0 }),
            else => g.int(g.rand.intRangeAtMost(i64, 0, 4)),
        };
    }

    fn body(g: *Gen, outer: ?*const Scope, n: u32, star_ok: bool, qdepth: u32, core_scope: *?*const Scope) Oom!*tree.Body {
        var w = g.cfg.bodies;
        if (qdepth == 0) {
            w.set(.compound, 0);
            w.set(.nested, 0);
        }
        var total: u32 = 0;
        for (w.values) |x| total += x;
        if (total == 0) w.set(.core, 1);
        const b = try tree.new(g.a, tree.Body, undefined);
        switch (fuzz.chooseWeighted(g.rand, BodyKind, w)) {
            .core => b.* = .{ .core = try g.core(outer, n, star_ok, core_scope) },
            .values => {
                const rows = try g.a.alloc([]*Expr, g.rand.intRangeAtMost(usize, 1, 3));
                const c: Ctx = .{ .scope = outer, .depth = g.cfg.expr_depth -| 1 };
                for (rows) |*row| {
                    row.* = try g.a.alloc(*Expr, n);
                    for (row.*) |*x| x.* = try g.expr(c);
                }
                b.* = .{ .values = rows };
                g.agg_core = false;
                g.rows = rows.len;
            },
            .compound => {
                var ignored: ?*const Scope = null;
                const left = try g.body(outer, n, false, qdepth - 1, &ignored);
                const left_rows = g.rows;
                const right = try g.body(outer, n, false, qdepth - 1, &ignored);
                const op = g.rand.enumValue(tree.SetOp);
                b.* = .{ .compound = .{ .op = op, .all = op == .@"union" and g.rand.boolean(), .left = left, .right = right } };
                g.agg_core = false;
                g.rows += left_rows;
            },
            .nested => {
                b.* = .{ .nested = try g.select(outer, n, qdepth - 1, false) };
                g.agg_core = false;
            },
        }
        return b;
    }

    fn core(g: *Gen, outer: ?*const Scope, n: u32, star_ok: bool, out_scope: *?*const Scope) Oom!*tree.Core {
        const c = try tree.new(g.a, tree.Core, .{ .cols = &.{} });
        var cols: std.ArrayList(Col) = .empty;
        var from: std.ArrayList(tree.FromItem) = .empty;
        // The rows of the join, bounded by the budget (an item that
        // would make more is left out).
        const budget = g.budget;
        defer g.budget = budget;
        var est: u64 = 1;
        if (g.chance(g.cfg.from_chance)) {
            const k = g.rand.intRangeAtMost(usize, 1, 3);
            for (0..k) |i| {
                const n_cols = cols.items.len;
                g.budget = budget / est;
                var item = try g.fromItem(&cols);
                if (est * @max(g.rows, 1) > budget) {
                    cols.shrinkRetainingCapacity(n_cols);
                    break;
                }
                est *= @max(g.rows, 1);
                if (i > 0) {
                    const joins = [_]tree.JoinKind{ .comma, .inner, .left, .right, .full, .cross, .straight };
                    item.join = g.pick(tree.JoinKind, &joins);
                    if (item.join != .comma and item.join != .cross and g.rand.uintLessThan(u8, 4) != 0) {
                        const sc = try tree.new(g.a, Scope, .{ .cols = try g.a.dupe(Col, cols.items), .outer = outer });
                        item.on = try g.expr(.{ .scope = sc, .depth = g.cfg.expr_depth -| 1 });
                    }
                }
                try from.append(g.a, item);
            }
        }
        c.from = from.items;
        // A subquery may run once for each row.
        g.budget = budget / est;
        const scope = try tree.new(g.a, Scope, .{ .cols = cols.items, .outer = outer });
        out_scope.* = scope;
        const plain: Ctx = .{ .scope = scope, .depth = g.cfg.expr_depth };
        if (g.chance(g.cfg.where_chance)) c.where = try g.expr(plain);
        const agg = g.chance(g.cfg.group_chance);
        if (agg) {
            const k = g.rand.uintLessThan(usize, 3);
            const group = try g.a.alloc(*Expr, k);
            for (group) |*x| x.* = (try g.column(plain)) orelse try g.expr(plain);
            c.group_by = group;
            if (k > 0) g.sort_keys = true;
            if (k > 0 and g.rand.uintLessThan(u8, 3) == 0) c.having = try g.expr(.{ .scope = scope, .depth = g.cfg.expr_depth, .agg = true });
        }
        const rc: Ctx = .{ .scope = scope, .depth = g.cfg.expr_depth, .agg = agg, .win = true };
        if (star_ok and from.items.len > 0 and g.rand.uintLessThan(u8, 8) == 0) {
            c.cols = try g.a.dupe(tree.ResultCol, &.{.{ .star = 0 }});
        } else {
            const out = try g.a.alloc(tree.ResultCol, n);
            for (out, 0..) |*x, i| {
                const alias: ?tree.Name = if (g.rand.uintLessThan(u8, 8) != 0) .{ .text = try std.fmt.allocPrint(g.a, "c{d}", .{i}) } else null;
                x.* = .{ .expr = .{ .e = try g.expr(rc), .alias = alias } };
            }
            c.cols = out;
        }
        c.distinct = g.chance(g.cfg.distinct_chance);
        g.agg_core = agg;
        g.rows = est;
        return c;
    }

    /// A FROM item with a new alias, its columns added to `cols`.
    fn fromItem(g: *Gen, cols: *std.ArrayList(Col)) Oom!tree.FromItem {
        var w = g.cfg.sources;
        if (g.ctes.items.len == 0) w.set(.cte, 0);
        if (g.qdepth == 0) w.set(.subquery, 0);
        const alias = try g.name("q");
        switch (fuzz.chooseWeighted(g.rand, SourceKind, w)) {
            .table => {
                const t = g.pick(Table, &tables);
                g.rows = t.rows;
                for (t.cols) |cn| try cols.append(g.a, .{ .qual = alias, .name = cn });
                return .{ .source = .{ .table = .{ .name = .{ .text = t.name } } }, .alias = .{ .name = .{ .text = alias } } };
            },
            .cte => {
                const cte = g.pick(CteInfo, g.ctes.items);
                g.rows = cte.rows;
                for (cte.cols) |cn| try cols.append(g.a, .{ .qual = alias, .name = cn });
                return .{ .source = .{ .table = .{ .name = .{ .text = cte.name } } }, .alias = .{ .name = .{ .text = alias } } };
            },
            .subquery, .values => |kind| {
                const k = g.rand.intRangeAtMost(u32, 1, 3);
                const names = try g.a.alloc(tree.Name, k);
                for (names, 0..) |*nm, i| {
                    nm.* = .{ .text = try std.fmt.allocPrint(g.a, "{s}_{d}", .{ alias, i }) };
                    try cols.append(g.a, .{ .qual = alias, .name = nm.text });
                }
                const sel = if (kind == .subquery) try g.select(null, k, g.qdepth - 1, false) else blk: {
                    const rows = try g.a.alloc([]*Expr, g.rand.intRangeAtMost(usize, 1, 4));
                    for (rows) |*row| {
                        row.* = try g.a.alloc(*Expr, k);
                        for (row.*) |*x| x.* = try g.expr(.{ .depth = 1 });
                    }
                    const b = try tree.new(g.a, tree.Body, .{ .values = rows });
                    g.rows = rows.len;
                    break :blk try tree.new(g.a, tree.Select, .{ .body = b });
                };
                return .{ .source = .{ .subquery = sel }, .alias = .{ .name = .{ .text = alias }, .cols = names } };
            },
        }
    }

    // ------------------------------------------------------------ tables

    /// A table with CHECK, DEFAULT and generated columns, whose stored
    /// expressions the fuzzer checks against lowered queries.
    pub fn table(g: *Gen) Oom!TableSpec {
        const types = [_]?[]const u8{ null, "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC" };
        const n = g.rand.intRangeAtMost(usize, 1, 4);
        const base = try g.a.alloc(BaseCol, n);
        var cols = try g.a.alloc(Col, n);
        for (base, 0..) |*bc, i| {
            const nm = try std.fmt.allocPrint(g.a, "a{d}", .{i});
            cols[i] = .{ .qual = null, .name = nm };
            bc.* = .{ .name = nm, .type = g.pick(?[]const u8, &types) };
        }
        const scope = try tree.new(g.a, Scope, .{ .cols = cols, .outer = null });
        const stored: Ctx = .{ .scope = scope, .depth = g.cfg.expr_depth, .stored = true };
        const constant: Ctx = .{ .depth = g.cfg.expr_depth, .stored = true, .default = true };
        for (base) |*bc| {
            if (g.rand.boolean()) bc.default = try g.expr(constant);
            if (g.rand.uintLessThan(u8, 4) == 0) bc.check = try g.expr(stored);
        }
        const gens = try g.a.alloc(GenCol, g.rand.uintLessThan(usize, 3));
        for (gens, 0..) |*gc, i| gc.* = .{ .name = try std.fmt.allocPrint(g.a, "g{d}", .{i}), .e = try g.expr(stored), .stored = g.rand.boolean() };
        const checks = try g.a.alloc(*Expr, g.rand.uintLessThan(usize, 3));
        for (checks) |*x| x.* = try g.expr(stored);
        return .{ .base = base, .gens = gens, .checks = checks };
    }
};

pub const BaseCol = struct {
    name: []const u8,
    type: ?[]const u8,
    default: ?*Expr = null,
    check: ?*Expr = null,
};

pub const GenCol = struct { name: []const u8, e: *Expr, stored: bool };

pub const TableSpec = struct {
    base: []BaseCol,
    gens: []GenCol,
    checks: []*Expr,

    /// CREATE TABLE `name` of the spec (generated columns have no type,
    /// so that they keep the value of their expression).
    pub fn createTable(t: TableSpec, a: Allocator, name: []const u8) Oom!*tree.CreateTable {
        const cols = try a.alloc(tree.ColumnDef, t.base.len + t.gens.len);
        for (t.base, 0..) |bc, i| {
            var cons: std.ArrayList(tree.ColConstraint) = .empty;
            if (bc.default) |d| try cons.append(a, .{ .kind = .{ .default = d } });
            if (bc.check) |x| try cons.append(a, .{ .kind = .{ .check = x } });
            cols[i] = .{ .name = .{ .text = bc.name }, .type = bc.type, .constraints = cons.items };
        }
        for (t.gens, 0..) |gc, i| {
            const cons = try a.dupe(tree.ColConstraint, &.{.{ .kind = .{ .generated = .{ .e = gc.e, .stored = gc.stored } } }});
            cols[t.base.len + i] = .{ .name = .{ .text = gc.name }, .constraints = cons };
        }
        const tcs = try a.alloc(tree.TableConstraint, t.checks.len);
        for (t.checks, tcs) |x, *tc| tc.* = .{ .kind = .{ .check = x } };
        return tree.new(a, tree.CreateTable, .{ .name = .{ .name = .{ .text = name } }, .columns = cols, .constraints = tcs });
    }

    /// The CHECKs of the table, column ones first.
    pub fn allChecks(t: TableSpec, a: Allocator) Oom![]*Expr {
        var out: std.ArrayList(*Expr) = .empty;
        for (t.base) |bc| if (bc.check) |x| try out.append(a, x);
        try out.appendSlice(a, t.checks);
        return out.items;
    }
};

// ================================================================= tests

test "gen: every node kind comes up" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var counts: std.enums.EnumArray(KindTag, u32) = .initFill(0);
    for (0..200) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const cfg: Config = .random(prng.random());
        var g: Gen = .init(arena.allocator(), prng.random(), &cfg, false);
        _ = try g.query();
        _ = try g.table();
        for (std.enums.values(KindTag)) |k| counts.set(k, counts.get(k) + g.kinds.get(k));
    }
    for (std.enums.values(KindTag)) |k| switch (k) {
        // DEFAULT is the fuzzer's own (INSERT VALUES); IdentityDefault
        // the exception of the contract.
        .default, .identity_default => {},
        else => std.testing.expect(counts.get(k) > 0) catch |err| {
            std.debug.print("never generated: {s}\n", .{@tagName(k)});
            return err;
        },
    };
}

test "gen: the same tree with parameters or their literals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..50) |seed| {
        var kinds: [2]std.enums.EnumArray(KindTag, u32) = undefined;
        var n_params: [2]usize = undefined;
        for (0..2) |i| {
            var prng: std.Random.DefaultPrng = .init(seed);
            const cfg: Config = .random(prng.random());
            var g: Gen = .init(arena.allocator(), prng.random(), &cfg, i == 1);
            _ = try g.query();
            kinds[i] = g.kinds;
            n_params[i] = g.params.items.len;
        }
        try std.testing.expectEqual(n_params[0], n_params[1]);
        try std.testing.expectEqual(@as(u32, 0), kinds[1].get(.param));
        try std.testing.expectEqual(kinds[0].get(.case), kinds[1].get(.case));
        try std.testing.expectEqual(kinds[0].get(.like), kinds[1].get(.like));
    }
}
