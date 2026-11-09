//! Desugaring: query forms of the syntax tree IR that SQLite has no
//! syntax for, rewritten as trees of forms it has. lower.zig and
//! render.zig both desugar a query before they consume it, so that
//! render ≡ lower holds by construction.
//!
//!  - DISTINCT ON (exprs) ... ORDER BY: the rows numbered by
//!    row_number() OVER (PARTITION BY exprs ORDER BY ...) in a subquery,
//!    the first of each partition kept;
//!  - FETCH FIRST n ROWS WITH TIES: rank() OVER (ORDER BY ...) <= n
//!    (OFFSET o: row_number() > o AND rank() <= o + n);
//!  - GROUPING SETS (ROLLUP, CUBE, as the frontend expanded them): a
//!    UNION ALL of one grouped query per set, the expressions of the
//!    other sets NULL and GROUPING() a constant in each; with window
//!    functions, DISTINCT ON or WITH TIES, that union a derived table
//!    whose columns are the grouped expressions the outer query's window
//!    functions, DISTINCT ON and ORDER BY read;
//!  - INTERSECT ALL / EXCEPT ALL: INTERSECT / EXCEPT of the operands'
//!    rows numbered within their duplicates (row_number() OVER
//!    (PARTITION BY every column)).
//!
//! The ORDER BY of the query is then over the subquery: its expressions
//! are columns xq_o<n> of the subquery, after the query's own columns
//! xq_c<n>, which the outer query renames back. With `*` in the result,
//! whose columns are not known before names are resolved, the query's
//! columns are kept as they are and the extra ones hidden from the outer
//! `*` (tree.Core.hidden), which only lowering can say: render.zig
//! fails there.

const std = @import("std");
const tree = @import("tree.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const callback = @import("../sql/callback.zig");
const lower = @import("lower.zig");

pub const Error = error{ OutOfMemory, Failed };

const Expr = tree.Expr;
const Name = tree.Name;

/// The position of what desugaring adds (in no text).
const nowhere: u32 = std.math.maxInt(u32) >> 1;

pub const Mode = enum { lower, render };

/// Whether `s` (not the queries it contains) has something to desugar.
pub fn needs(s: *const tree.Select) bool {
    return s.with_ties or needsBody(s.body);
}

fn needsBody(b: *const tree.Body) bool {
    return switch (b.*) {
        .core => |c| c.distinct_on.len > 0 or c.grouping_sets != null,
        .compound => |c| (c.all and c.op != .@"union") or needsBody(c.left) or needsBody(c.right),
        else => false,
    };
}

pub const Desugar = struct {
    p: *int.Parse,
    /// The text the positions of the tree are offsets of.
    src: [:0]const u8,
    mode: Mode,

    fn a(d: *const Desugar) std.mem.Allocator {
        return d.p.arena;
    }

    fn fail(d: *Desugar, pos: u32, state: ?int.ErrorState, comptime fmt: []const u8, args: anytype) Error {
        const z: ?[*]const u8 = if (pos < d.src.len) d.src.ptr + pos else null;
        util.errorMsgState(d.p, z, state, fmt, args);
        return error.Failed;
    }

    fn unsupported(d: *Desugar, pos: u32, what: []const u8) Error {
        return d.fail(pos, .of("0A000"), "{s} is not supported", .{what});
    }

    /// `s` desugared (`s` itself if there is nothing to do).
    pub fn select(d: *Desugar, s: *const tree.Select) Error!*const tree.Select {
        if (!needs(s)) return s;
        if (s.src) |t| d.src = t;
        var x = s.*;
        x.body = try d.body(s.body, true);
        if (x.body.* == .core) {
            const c = x.body.core;
            if (c.grouping_sets != null) {
                if (x.with_ties or c.distinct_on.len > 0 or d.hasWindow(&x, c)) return d.groupedWindows(&x, c);
                return d.groupingSets(&x, c);
            }
            if (c.distinct_on.len > 0) {
                if (x.with_ties) return d.unsupported(c.pos, "DISTINCT ON with FETCH ... WITH TIES");
                return d.distinctOn(&x, c);
            }
        }
        if (x.with_ties) return d.withTies(&x);
        return tree.new(d.a(), tree.Select, x);
    }

    /// `b` desugared; `top`: the body of the query (whose ORDER BY a
    /// core's DISTINCT ON and GROUPING SETS are desugared with), else an
    /// operand of a compound.
    fn body(d: *Desugar, b: *tree.Body, top: bool) Error!*tree.Body {
        switch (b.*) {
            .core => |c| {
                if (top or (c.distinct_on.len == 0 and c.grouping_sets == null)) return b;
                const s = try tree.new(d.a(), tree.Select, .{ .body = b, .pos = c.pos });
                return tree.new(d.a(), tree.Body, .{ .nested = @constCast(try d.select(s)) });
            },
            .compound => |c| {
                var x = c;
                x.left = try d.body(c.left, false);
                x.right = try d.body(c.right, false);
                if (x.all and x.op != .@"union") return d.setAll(x);
                return tree.new(d.a(), tree.Body, .{ .compound = x });
            },
            else => return b,
        }
    }

    // ============================================================ helpers

    fn colRef(d: *Desugar, name: []const u8) Error!*Expr {
        const names = try d.a().alloc(Name, 1);
        names[0] = .{ .text = name, .pos = nowhere };
        return tree.expr(d.a(), nowhere, nowhere, .{ .column = names });
    }

    fn label(d: *Desugar, comptime prefix: []const u8, i: usize) Error![]const u8 {
        return std.fmt.allocPrint(d.a(), prefix ++ "{d}", .{i});
    }

    fn call(d: *Desugar, name: []const u8, args: []*Expr, over: ?*tree.WindowSpec) Error!*Expr {
        const f = try tree.new(d.a(), tree.Func, .{ .name = .{ .text = name, .pos = nowhere }, .args = args, .over = over });
        return tree.expr(d.a(), nowhere, nowhere, .{ .func = f });
    }

    fn intConst(d: *Desugar, v: i64) Error!*Expr {
        return tree.intConst(d.a(), nowhere, v);
    }

    fn compare(d: *Desugar, op: tree.CmpOp, l: *Expr, r: *Expr) Error!*Expr {
        return tree.expr(d.a(), nowhere, nowhere, .{ .compare = .{ .op = op, .l = l, .r = r } });
    }

    fn andExpr(d: *Desugar, l: ?*Expr, r: *Expr) Error!*Expr {
        const x = l orelse return r;
        return tree.expr(d.a(), nowhere, nowhere, .{ .binary = .{ .op = .@"and", .l = x, .r = r } });
    }

    fn subqueryItem(d: *Desugar, s: *tree.Select, alias: []const u8, cols: []Name) Error![]tree.FromItem {
        const from = try d.a().alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = s }, .alias = .{ .name = .{ .text = alias, .pos = nowhere }, .cols = cols } };
        return from;
    }

    fn selectOf(d: *Desugar, b: *tree.Body, pos: u32) Error!*tree.Select {
        return tree.new(d.a(), tree.Select, .{ .body = b, .pos = pos });
    }

    fn coreBody(d: *Desugar, c: tree.Core) Error!*tree.Body {
        return tree.new(d.a(), tree.Body, .{ .core = try tree.new(d.a(), tree.Core, c) });
    }

    /// The name of result column `rc` (null: `*`, or an expression the
    /// frontend did not name).
    fn outName(rc: tree.ResultCol) ?[]const u8 {
        return switch (rc) {
            .expr => |x| if (x.alias) |al| al.text else if (x.name) |n| n else switch (x.e.kind) {
                .column => |names| names[names.len - 1].text,
                else => null,
            },
            else => null,
        };
    }

    /// Whether the result columns of `cols` are known by name.
    fn named(cols: []const tree.ResultCol) bool {
        for (cols) |rc| if (outName(rc) == null) return false;
        return cols.len > 0;
    }

    /// The result columns of `c` with `*` and `t.*` spelled out as
    /// columns of the tables and subqueries of FROM, if they are known.
    fn expandStars(d: *Desugar, c: *const tree.Core) Error!?[]tree.ResultCol {
        @import("ir.zig").stmt.readSchema(d.p) catch return null;
        var out: std.ArrayList(tree.ResultCol) = .empty;
        for (c.cols) |rc| switch (rc) {
            .expr => try out.append(d.a(), rc),
            .star => for (c.from) |*item| {
                if (!try d.itemCols(item, null, &out)) return null;
            },
            .table_star => |ts| {
                var found = false;
                for (c.from) |*item| if (try d.itemCols(item, ts.names[ts.names.len - 1].text, &out)) {
                    found = true;
                };
                if (!found) return null;
            },
        };
        return out.items;
    }

    /// The columns of FROM item `item` (with `only`, if it is the item of
    /// that name), appended to `out`; false if not known.
    fn itemCols(d: *Desugar, item: *const tree.FromItem, only: ?[]const u8, out: *std.ArrayList(tree.ResultCol)) Error!bool {
        if (item.natural or item.using.len > 0) return false;
        const ar = d.a();
        switch (item.source) {
            .nested => |inner| {
                if (only != null) {
                    var found = false;
                    for (inner) |*x| if (try d.itemCols(x, only, out)) {
                        found = true;
                    };
                    return found;
                }
                for (inner) |*x| if (!try d.itemCols(x, null, out)) return false;
                return true;
            },
            .func => return false,
            .table => |q| {
                const lab: []const u8 = if (item.alias) |al| al.name.text else q.name.text;
                if (only) |o| if (!std.ascii.eqlIgnoreCase(o, lab)) return false;
                const t = @import("../sql/build.zig").findTable(d.p.db, q.name.text, if (q.schema) |s| s.text else null) orelse return false;
                for (t.cols) |*col| {
                    if (col.col_flags.HIDDEN) continue;
                    try out.append(ar, .{ .expr = .{ .e = try d.qualified(lab, col.name()) } });
                }
                return true;
            },
            .subquery => |s| {
                const al = item.alias orelse return false;
                if (only) |o| if (!std.ascii.eqlIgnoreCase(o, al.name.text)) return false;
                const names: []const []const u8 = if (al.cols.len > 0) blk: {
                    const ns = try ar.alloc([]const u8, al.cols.len);
                    for (al.cols, ns) |n, *x| x.* = n.text;
                    break :blk ns;
                } else try d.bodyNames(s.body) orelse return false;
                for (names) |n| try out.append(ar, .{ .expr = .{ .e = try d.qualified(al.name.text, n) } });
                return true;
            },
        }
    }

    fn qualified(d: *Desugar, table: []const u8, col: []const u8) Error!*Expr {
        const names = try d.a().alloc(Name, 2);
        names[0] = .{ .text = table, .pos = nowhere };
        names[1] = .{ .text = col, .pos = nowhere };
        return tree.expr(d.a(), nowhere, nowhere, .{ .column = names });
    }

    /// `(s) AS x(cols)` as SELECT xq_a.c1 AS col1 ... FROM (s) AS xq_a
    /// (the columns past `cols` keep their names), if the names of the
    /// columns of `s` are known.
    pub fn renamed(d: *Desugar, s: *tree.Select, cols: []const Name) Error!?*tree.Select {
        if (s.body.* == .values) {
            // VALUES (a), (b) AS x(c): SELECT a AS c UNION ALL SELECT b.
            const rows = s.body.values;
            if (cols.len > rows[0].len) return null;
            var all: ?*tree.Body = null;
            for (rows, 0..) |row, r| {
                const out = try d.a().alloc(tree.ResultCol, row.len);
                for (row, out, 0..) |e, *o, i| {
                    o.* = .{ .expr = .{ .e = e, .alias = if (r > 0) null else if (i < cols.len) cols[i] else .{ .text = try d.label("column", i + 1), .pos = nowhere } } };
                }
                const b = try d.coreBody(.{ .cols = out, .pos = s.pos });
                all = if (all) |prev| try tree.new(d.a(), tree.Body, .{ .compound = .{ .op = .@"union", .all = true, .left = prev, .right = b } }) else b;
            }
            var x = s.*;
            x.body = all.?;
            return tree.new(d.a(), tree.Select, x);
        }
        const names = try d.bodyNames(s.body) orelse return null;
        if (cols.len > names.len) return null;
        const out = try d.a().alloc(tree.ResultCol, names.len);
        for (names, out, 0..) |n, *o, i| {
            o.* = .{ .expr = .{ .e = try d.qualified("xq_a", n), .alias = if (i < cols.len) cols[i] else .{ .text = n, .pos = nowhere } } };
        }
        return d.selectOf(try d.coreBody(.{ .cols = out, .from = try d.subqueryItem(s, "xq_a", &.{}), .pos = s.pos }), s.pos);
    }

    /// The names of the columns of `b`, if known.
    fn bodyNames(d: *Desugar, b: *const tree.Body) Error!?[]const []const u8 {
        switch (b.*) {
            .core => |c| {
                if (!named(c.cols)) return null;
                const out = try d.a().alloc([]const u8, c.cols.len);
                for (c.cols, out) |rc, *n| n.* = outName(rc).?;
                return out;
            },
            .values => |rows| {
                const out = try d.a().alloc([]const u8, rows[0].len);
                for (out, 0..) |*n, i| n.* = try d.label("column", i + 1);
                return out;
            },
            .nested => |s| return d.bodyNames(s.body),
            .compound => |c| return d.bodyNames(c.left),
        }
    }

    /// An ORDER BY, DISTINCT ON or GROUP BY item that names a result
    /// column of `c` (by position, or by alias with `by_alias`): that
    /// column's expression; else the item.
    fn resultRef(d: *Desugar, c: *const tree.Core, e: *Expr, clause: []const u8, by_alias: bool) Error!*Expr {
        switch (e.kind) {
            .integer => |digits| {
                const k = std.fmt.parseInt(usize, digits, 10) catch 0;
                var i: usize = 0;
                for (c.cols) |rc| switch (rc) {
                    .expr => |x| {
                        i += 1;
                        if (i == k) return x.e;
                    },
                    else => if (k > i) return d.unsupported(e.pos, "a position after * in this clause"),
                };
                return d.fail(e.pos, .of("42P10"), "{s} position {s} is not in select list", .{ clause, digits });
            },
            .column => |names| if (by_alias and names.len == 1) {
                for (c.cols) |rc| if (rc == .expr) if (rc.expr.alias) |al| if (std.mem.eql(u8, al.text, names[0].text)) return rc.expr.e;
            },
            else => {},
        }
        return e;
    }

    fn isAggregate(d: *Desugar, f: *const tree.Func) bool {
        return aggregateCall(d.p, f);
    }

    /// Whether `f` is an aggregate call (not a window function).
    pub fn aggregateCall(p: *int.Parse, f: *const tree.Func) bool {
        if (f.over != null) return false;
        if (f.distinct or f.filter != null or f.order_by.len > 0 or f.star) return true;
        const name = lower.functionName(p, f.name.text, f.dialect, false) catch return false;
        const def = callback.findFunction(p.db, name, @intCast(f.args.len), p.db.enc, false) orelse return false;
        return def.x_finalize != null;
    }

    fn isGrouping(f: *const tree.Func) bool {
        return f.dialect == null and f.over == null and std.ascii.eqlIgnoreCase(f.name.text, "grouping");
    }

    fn hasCall(d: *Desugar, e: *const Expr, comptime pred: fn (*Desugar, *const tree.Func) bool) bool {
        return callIn(d, e, pred);
    }

    /// Whether `e` has a call that `pred` (given `ctx`) says yes to (not
    /// looking into subqueries).
    pub fn callIn(ctx: anytype, e: *const Expr, comptime pred: fn (@TypeOf(ctx), *const tree.Func) bool) bool {
        if (e.kind == .func and pred(ctx, e.kind.func)) return true;
        var it = tree.Children.of(e);
        while (it.next()) |x| if (callIn(ctx, x, pred)) return true;
        return false;
    }

    fn isWindow(d: *Desugar, f: *const tree.Func) bool {
        return windowCall(d.p, f);
    }

    /// Whether `f` is a window function call.
    pub fn windowCall(_: *int.Parse, f: *const tree.Func) bool {
        return f.over != null;
    }

    // ======================================================= DISTINCT ON

    fn distinctOn(d: *Desugar, s: *const tree.Select, c: *tree.Core) Error!*tree.Select {
        const ar = d.a();
        const on = try ar.alloc(*Expr, c.distinct_on.len);
        for (c.distinct_on, on) |e, *o| o.* = try d.resultRef(c, e, "DISTINCT ON", true);
        const order = try ar.alloc(tree.SortItem, s.order_by.len);
        for (s.order_by, order) |it, *o| {
            o.* = it;
            o.expr = try d.resultRef(c, it.expr, "ORDER BY", true);
        }
        // PostgreSQL's rule (transformDistinctOnClause()): the ORDER BY
        // starts with the DISTINCT ON expressions (in any order); those
        // it leaves out come after it.
        var skipped = false;
        for (order) |it| {
            const k = indexOf(on, it.expr) orelse {
                skipped = true;
                continue;
            };
            if (skipped) return d.fail(c.distinct_on[k].pos, .of("42P10"), "SELECT DISTINCT ON expressions must match initial ORDER BY expressions", .{});
        }
        var w_order: std.ArrayList(tree.SortItem) = .empty;
        try w_order.appendSlice(ar, order);
        for (on, 0..) |e, k| {
            for (order) |it| {
                if (sameExpr(it.expr, e)) break;
            } else {
                if (skipped) return d.fail(c.distinct_on[k].pos, .of("42P10"), "SELECT DISTINCT ON expressions must match initial ORDER BY expressions", .{});
                // (Ascending, NULLs last: PostgreSQL's default order.)
                try w_order.append(ar, .{ .expr = e, .nulls = .last });
            }
        }
        const spec = try tree.new(ar, tree.WindowSpec, .{ .partition = on, .order_by = w_order.items });
        const wins = [_]Win{.{ .label = "xq_rn", .e = try d.call("row_number", &.{}, spec) }};
        const where = try d.compare(.eq, try d.colRef("xq_rn"), try d.intConst(1));
        // Without an ORDER BY, the rows come in the order of the DISTINCT
        // ON expressions, as PostgreSQL sorts them.
        return d.wrap(s, c, if (order.len > 0) order else w_order.items, &wins, where, s.limit, s.offset);
    }

    const Win = struct { label: []const u8, e: *Expr };

    /// SELECT cols FROM (SELECT cols AS xq_c<n>, sort keys AS xq_o<n>,
    /// wins FROM ...) WHERE `where` ORDER BY xq_o<n> LIMIT `lim` OFFSET
    /// `off`: query `s` of core `c` sorted by `order`.
    fn wrap(d: *Desugar, s: *const tree.Select, c: *tree.Core, order: []const tree.SortItem, wins: []const Win, where: *Expr, lim: ?*Expr, off: ?*Expr) Error!*tree.Select {
        var c_ = c;
        if (!named(c.cols) and d.mode == .render) {
            const ar = d.a();
            // The text spells `*` out (as PostgreSQL's view keeps its
            // columns).
            const cols = try d.expandStars(c) orelse return d.unsupported(c.pos, "* in the query of a view with DISTINCT ON or WITH TIES");
            c_ = try tree.new(ar, tree.Core, c.*);
            c_.cols = cols;
        }
        return d.wrapNamed(s, c_, order, wins, where, lim, off);
    }

    fn wrapNamed(d: *Desugar, s: *const tree.Select, c: *tree.Core, order: []const tree.SortItem, wins: []const Win, where: *Expr, lim: ?*Expr, off: ?*Expr) Error!*tree.Select {
        const ar = d.a();
        const by_name = named(c.cols);
        var cols: std.ArrayList(tree.ResultCol) = .empty;
        var outer: std.ArrayList(tree.ResultCol) = .empty;
        if (by_name) {
            for (c.cols, 0..) |rc, i| {
                const lab = try d.label("xq_c", i);
                try cols.append(ar, .{ .expr = .{ .e = rc.expr.e, .alias = .{ .text = lab, .pos = nowhere } } });
                try outer.append(ar, .{ .expr = .{ .e = try d.colRef(lab), .alias = .{ .text = outName(rc).?, .pos = nowhere } } });
            }
        } else {
            try cols.appendSlice(ar, c.cols);
            try outer.append(ar, .{ .star = nowhere });
        }
        const outer_order = try ar.alloc(tree.SortItem, order.len);
        for (order, outer_order, 0..) |it, *o, j| {
            const lab = try d.label("xq_o", j);
            try cols.append(ar, .{ .expr = .{ .e = it.expr, .alias = .{ .text = lab, .pos = nowhere } } });
            o.* = it;
            o.expr = try d.colRef(lab);
        }
        for (wins) |w| try cols.append(ar, .{ .expr = .{ .e = w.e, .alias = .{ .text = w.label, .pos = nowhere } } });
        var inner = c.*;
        inner.cols = cols.items;
        inner.distinct_on = &.{};
        inner.hidden = if (by_name) 0 else @intCast(order.len + wins.len);
        const sub = try tree.new(ar, tree.Select, .{ .body = try d.coreBody(inner), .pos = c.pos, .src = s.src });
        const body_ = try d.coreBody(.{ .cols = outer.items, .from = try d.subqueryItem(sub, "xq_q", &.{}), .where = where, .pos = c.pos });
        return tree.new(ar, tree.Select, .{ .with = s.with, .body = body_, .order_by = outer_order, .limit = lim, .offset = off, .pos = s.pos, .src = s.src });
    }

    // ===================================================== WITH TIES

    fn withTies(d: *Desugar, s: *const tree.Select) Error!*tree.Select {
        const ar = d.a();
        if (s.body.* != .core) return d.unsupported(s.pos, "FETCH ... WITH TIES of a compound query");
        const c = s.body.core;
        // (The window functions would count the rows before DISTINCT.)
        if (c.distinct) return d.unsupported(c.pos, "SELECT DISTINCT with FETCH ... WITH TIES");
        const order = try ar.alloc(tree.SortItem, s.order_by.len);
        for (s.order_by, order) |it, *o| {
            o.* = it;
            o.expr = try d.resultRef(c, it.expr, "ORDER BY", true);
        }
        const n = s.limit.?;
        const rank = try d.call("rank", &.{}, try tree.new(ar, tree.WindowSpec, .{ .order_by = order }));
        if (s.offset) |off| {
            // The rows after the first `off` (in row order), up to the
            // `off + n`th and those that tie with it.
            const rn = try d.call("row_number", &.{}, try tree.new(ar, tree.WindowSpec, .{ .order_by = order }));
            const wins = [_]Win{ .{ .label = "xq_rk", .e = rank }, .{ .label = "xq_rn", .e = rn } };
            const upto = try tree.expr(ar, nowhere, nowhere, .{ .binary = .{ .op = .add, .l = off, .r = n } });
            const where = try d.andExpr(try d.compare(.gt, try d.colRef("xq_rn"), off), try d.compare(.le, try d.colRef("xq_rk"), upto));
            return d.wrap(s, c, order, &wins, where, null, null);
        }
        const wins = [_]Win{.{ .label = "xq_rk", .e = rank }};
        return d.wrap(s, c, order, &wins, try d.compare(.le, try d.colRef("xq_rk"), n), null, null);
    }

    // ===================================================== GROUPING SETS

    fn groupingSets(d: *Desugar, s: *const tree.Select, c: *tree.Core) Error!*tree.Select {
        const ar = d.a();
        if (!named(c.cols)) return d.unsupported(c.pos, "* with GROUPING SETS");
        const groups = try ar.alloc(*Expr, c.group_by.len);
        for (c.group_by, groups) |g, *x| x.* = try d.resultRef(c, g, "GROUP BY", false);
        const order = try ar.alloc(tree.SortItem, s.order_by.len);
        for (s.order_by, order) |it, *o| {
            o.* = it;
            o.expr = try d.resultRef(c, it.expr, "ORDER BY", true);
        }
        // The result columns xq_c<n> (whether the set's query is an
        // aggregate by them), the sort keys xq_o<n>.
        const cols = try ar.alloc(tree.ResultCol, c.cols.len + order.len);
        for (c.cols, 0..) |rc, i| cols[i] = .{ .expr = .{ .e = rc.expr.e, .alias = .{ .text = try d.label("xq_c", i), .pos = nowhere } } };
        for (order, 0..) |it, j| cols[c.cols.len + j] = .{ .expr = .{ .e = it.expr, .alias = .{ .text = try d.label("xq_o", j), .pos = nowhere } } };
        const all = try d.setsUnion(c.*, groups, cols, c.cols.len, !c.distinct);
        const outer = try ar.alloc(tree.ResultCol, c.cols.len);
        for (c.cols, outer, 0..) |rc, *o, i| {
            o.* = .{ .expr = .{ .e = try d.colRef(try d.label("xq_c", i)), .alias = .{ .text = outName(rc).?, .pos = nowhere } } };
        }
        const outer_order = try ar.alloc(tree.SortItem, order.len);
        for (order, outer_order, 0..) |it, *o, j| {
            o.* = it;
            o.expr = try d.colRef(try d.label("xq_o", j));
        }
        const sub = try d.selectOf(all, c.pos);
        const body_ = try d.coreBody(.{ .cols = outer, .from = try d.subqueryItem(sub, "xq_g", &.{}), .pos = c.pos });
        return tree.new(ar, tree.Select, .{ .with = s.with, .body = body_, .order_by = outer_order, .limit = s.limit, .offset = s.offset, .pos = s.pos, .src = s.src });
    }

    /// The UNION [ALL] of the queries of `base`'s grouping sets: each
    /// `base` grouped by its set, result columns `cols` and HAVING as
    /// Subst makes them. The empty set is one group of all rows, even of
    /// none: unless one of the first `n_agg` columns or HAVING calls an
    /// aggregate, its query is made one (CASE WHEN count(*) >= 0 THEN col
    /// END).
    fn setsUnion(d: *Desugar, base: tree.Core, groups: []const *Expr, cols: []const tree.ResultCol, n_agg: usize, all: bool) Error!*tree.Body {
        const ar = d.a();
        var out: ?*tree.Body = null;
        for (base.grouping_sets.?) |set| {
            const in_set = try ar.alloc(bool, groups.len);
            @memset(in_set, false);
            for (set) |i| in_set[i] = true;
            var sub: Subst = .{ .d = d, .groups = groups, .in_set = in_set };
            const set_cols = try ar.dupe(tree.ResultCol, cols);
            var has_agg = false;
            for (cols, set_cols, 0..) |rc, *o, i| {
                o.expr.e = try sub.expr(rc.expr.e);
                if (i < n_agg and d.hasCall(rc.expr.e, isAggregate)) has_agg = true;
            }
            const gb = try ar.alloc(*Expr, set.len);
            for (set, gb) |i, *g| g.* = groups[i];
            const having: ?*Expr = if (base.having) |h| try sub.expr(h) else null;
            if (having) |h| if (d.hasCall(h, isAggregate)) {
                has_agg = true;
            };
            if (set.len == 0 and !has_agg) {
                const whens = try ar.alloc(*Expr, 2);
                whens[0] = try d.compare(.ge, try d.countStar(), try d.intConst(0));
                whens[1] = set_cols[0].expr.e;
                set_cols[0].expr.e = try tree.expr(ar, nowhere, nowhere, .{ .case = .{ .operand = null, .whens = whens, .@"else" = null } });
            }
            var branch = base;
            branch.distinct = false;
            branch.cols = set_cols;
            branch.group_by = gb;
            branch.grouping_sets = null;
            branch.having = having;
            const b = try d.coreBody(branch);
            out = if (out) |prev| try tree.new(ar, tree.Body, .{ .compound = .{ .op = .@"union", .all = all, .left = prev, .right = b } }) else b;
        }
        return out.?;
    }

    /// count(*).
    fn countStar(d: *Desugar) Error!*Expr {
        const ar = d.a();
        const count = try tree.new(ar, tree.Func, .{ .name = .{ .text = "count", .pos = nowhere }, .star = true });
        return tree.expr(ar, nowhere, nowhere, .{ .func = count });
    }

    /// Whether the result columns or the ORDER BY of `c` call a window
    /// function.
    fn hasWindow(d: *Desugar, s: *const tree.Select, c: *const tree.Core) bool {
        for (c.cols) |rc| if (rc == .expr and d.hasCall(rc.expr.e, isWindow)) return true;
        for (s.order_by) |it| if (d.hasCall(it.expr, isWindow)) return true;
        return false;
    }

    /// GROUPING SETS with window functions, DISTINCT ON or WITH TIES:
    /// SELECT cols FROM (the UNION ALL of the sets' queries) AS xq_g ...,
    /// the grouped query's expressions that are not in a window function
    /// call (the operands of the calls, the result columns and sort keys
    /// without one) columns xq_v<n> of the union (HAVING applied there);
    /// the window functions, DISTINCT [ON], ORDER BY and LIMIT those of
    /// the outer query, desugared as such.
    fn groupedWindows(d: *Desugar, s: *const tree.Select, c: *tree.Core) Error!*tree.Select {
        const ar = d.a();
        if (!named(c.cols)) return d.unsupported(c.pos, "* with GROUPING SETS");
        const groups = try ar.alloc(*Expr, c.group_by.len);
        for (c.group_by, groups) |g, *x| x.* = try d.resultRef(c, g, "GROUP BY", false);
        var lift: Lift = .{ .d = d };
        const cols = try ar.alloc(tree.ResultCol, c.cols.len);
        for (c.cols, cols) |rc, *o| {
            o.* = .{ .expr = .{ .e = try lift.expr(rc.expr.e), .alias = .{ .text = outName(rc).?, .pos = nowhere } } };
        }
        // A position or a result column's name stays one (of the outer
        // query's same result columns).
        const order = try ar.alloc(tree.SortItem, s.order_by.len);
        for (s.order_by, order) |it, *o| {
            o.* = it;
            if (try d.resultRef(c, it.expr, "ORDER BY", true) == it.expr) o.expr = try lift.expr(it.expr);
        }
        const on = try ar.alloc(*Expr, c.distinct_on.len);
        for (c.distinct_on, on) |e, *o| {
            o.* = if (try d.resultRef(c, e, "DISTINCT ON", true) == e) try lift.expr(e) else e;
        }
        const windows = try ar.alloc(tree.NamedWindow, c.windows.len);
        for (c.windows, windows) |w, *o| {
            var spec = w.spec.*;
            spec.partition = try ar.dupe(*Expr, spec.partition);
            for (spec.partition) |*e| e.* = try lift.expr(e.*);
            spec.order_by = try ar.dupe(tree.SortItem, spec.order_by);
            for (spec.order_by) |*it| it.expr = try lift.expr(it.expr);
            o.* = .{ .name = w.name, .spec = try tree.new(ar, tree.WindowSpec, spec) };
        }
        // A union of no columns has one: count(*), an aggregate for the
        // empty set too.
        if (lift.items.items.len == 0) try lift.items.append(ar, try d.countStar());
        const items = lift.items.items;
        const inner = try ar.alloc(tree.ResultCol, items.len);
        for (items, inner, 0..) |e, *o, j| o.* = .{ .expr = .{ .e = e, .alias = .{ .text = try d.label("xq_v", j), .pos = nowhere } } };
        var base = c.*;
        base.distinct_on = &.{};
        base.windows = &.{};
        const all = try d.setsUnion(base, groups, inner, inner.len, true);
        const sub = try d.selectOf(all, c.pos);
        const body_ = try d.coreBody(.{ .distinct = c.distinct, .distinct_on = on, .cols = cols, .from = try d.subqueryItem(sub, "xq_g", &.{}), .windows = windows, .pos = c.pos });
        const outer = try tree.new(ar, tree.Select, .{ .with = s.with, .body = body_, .order_by = order, .limit = s.limit, .offset = s.offset, .with_ties = s.with_ties, .pos = s.pos, .src = s.src });
        return @constCast(try d.select(outer));
    }

    /// The expressions of a grouped query as the outer query's of
    /// groupedWindows(): each operand without a window function call a
    /// column xq_v<n> of the grouped query, `items` (once each).
    const Lift = struct {
        d: *Desugar,
        items: std.ArrayList(*Expr) = .empty,

        fn expr(x: *Lift, e: *Expr) Error!*Expr {
            if (x.d.hasCall(e, isWindow)) return mapChildren(x.d.a(), e, x, Lift.expr);
            const j = indexOf(x.items.items, e) orelse blk: {
                try x.items.append(x.d.a(), e);
                break :blk x.items.items.len - 1;
            };
            return x.d.colRef(try x.d.label("xq_v", j));
        }
    };

    /// The expressions of a query of one grouping set: those of the other
    /// sets NULL (but in aggregates' arguments), GROUPING() its value.
    const Subst = struct {
        d: *Desugar,
        groups: []const *Expr,
        in_set: []const bool,

        fn expr(x: *Subst, e: *Expr) Error!*Expr {
            for (x.groups, 0..) |g, i| if (sameExpr(g, e)) {
                if (x.in_set[i]) return e;
                return tree.expr(x.d.a(), e.pos, e.end, .null);
            };
            switch (e.kind) {
                .func => |f| {
                    if (isGrouping(f)) return x.grouping(e, f);
                    if (x.d.isAggregate(f)) return e;
                },
                .subquery, .exists => return e,
                else => {},
            }
            return mapChildren(x.d.a(), e, x, Subst.expr);
        }

        fn grouping(x: *Subst, e: *Expr, f: *const tree.Func) Error!*Expr {
            if (f.args.len == 0 or f.args.len > 31) return x.d.fail(e.pos, .of("54023"), "GROUPING must have fewer than 32 arguments", .{});
            var v: i64 = 0;
            for (f.args) |arg| {
                const i = indexOf(x.groups, arg) orelse return x.d.fail(arg.pos, .of("42803"), "arguments to GROUPING must be grouping expressions of the associated query level", .{});
                v = v * 2 + @intFromBool(!x.in_set[i]);
            }
            return tree.intConst(x.d.a(), e.pos, v);
        }
    };

    // ========================================== INTERSECT/EXCEPT ALL

    /// `l INTERSECT ALL r` as (SELECT c1 AS name1 ... FROM (l' INTERSECT
    /// r')), each operand's rows numbered within their duplicates.
    fn setAll(d: *Desugar, c: tree.Compound) Error!*tree.Body {
        const ar = d.a();
        const what: []const u8 = if (c.op == .intersect) "INTERSECT" else "EXCEPT";
        const names = try d.bodyNames(c.left) orelse return d.unsupported(0, try std.fmt.allocPrint(ar, "{s} ALL of a query with *", .{what}));
        if (try d.bodyNames(c.right)) |r| if (r.len != names.len) {
            return d.fail(0, .of("42601"), "each {s} query must have the same number of columns", .{what});
        };
        const cols = try ar.alloc(Name, names.len);
        for (cols, 0..) |*n, i| n.* = .{ .text = try d.label("xq_", i + 1), .pos = nowhere };
        const left = try d.numbered(c.left, cols);
        const right = try d.numbered(c.right, cols);
        const both = try tree.new(ar, tree.Body, .{ .compound = .{ .op = c.op, .all = false, .left = left, .right = right } });
        const outer = try ar.alloc(tree.ResultCol, names.len);
        for (outer, names, cols) |*o, n, cn| o.* = .{ .expr = .{ .e = try d.colRef(cn.text), .alias = .{ .text = n, .pos = nowhere } } };
        const sel = try d.selectOf(try d.coreBody(.{ .cols = outer, .from = try d.subqueryItem(try d.selectOf(both, 0), "xq_s", &.{}) }), 0);
        return tree.new(ar, tree.Body, .{ .nested = sel });
    }

    /// SELECT xq_1 ... xq_n, row_number() OVER (PARTITION BY xq_1 ...
    /// xq_n) FROM (b) AS xq_a(xq_1 ... xq_n).
    fn numbered(d: *Desugar, b: *tree.Body, names: []Name) Error!*tree.Body {
        const ar = d.a();
        const refs = try ar.alloc(*Expr, names.len);
        const cols = try ar.alloc(tree.ResultCol, names.len + 1);
        for (names, refs, 0..) |n, *r, i| {
            r.* = try d.colRef(n.text);
            cols[i] = .{ .expr = .{ .e = r.* } };
        }
        const rn = try d.call("row_number", &.{}, try tree.new(ar, tree.WindowSpec, .{ .partition = refs }));
        cols[names.len] = .{ .expr = .{ .e = rn, .alias = .{ .text = "xq_k", .pos = nowhere } } };
        return d.coreBody(.{ .cols = cols, .from = try d.subqueryItem(try d.selectOf(b, 0), "xq_a", names) });
    }
};

// ============================================================ expressions

fn indexOf(list: []const *Expr, e: *const Expr) ?usize {
    for (list, 0..) |x, i| if (sameExpr(x, e)) return i;
    return null;
}

/// Whether `x` and `y` are the same expression (positions aside; a
/// column qualified in one and not in the other the same column).
pub fn sameExpr(x: *const Expr, y: *const Expr) bool {
    if (x == y) return true;
    if (x.kind == .column and y.kind == .column) {
        const p = x.kind.column;
        const q = y.kind.column;
        if (!std.ascii.eqlIgnoreCase(p[p.len - 1].text, q[q.len - 1].text)) return false;
        if (p.len == 1 or q.len == 1) return true;
        return std.ascii.eqlIgnoreCase(p[p.len - 2].text, q[q.len - 2].text);
    }
    return deepEql(tree.Kind, x.kind, y.kind);
}

fn deepEql(comptime T: type, x: T, y: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (T == Name) return std.mem.eql(u8, x.text, y.text);
            if (T == Expr) return sameExpr(&x, &y);
            inline for (info.field_names, info.field_types) |name, F| {
                if (comptime (std.mem.eql(u8, name, "pos") or std.mem.eql(u8, name, "end") or std.mem.eql(u8, name, "src"))) continue;
                if (!deepEql(F, @field(x, name), @field(y, name))) return false;
            }
            return true;
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            if (@as(Tag, x) != @as(Tag, y)) return false;
            switch (x) {
                inline else => |v, tag| return deepEql(@TypeOf(v), v, @field(y, @tagName(tag))),
            }
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => return x == y or deepEql(ptr.child, x.*, y.*),
            .slice => {
                if (x.len != y.len) return false;
                for (x, y) |xi, yi| if (!deepEql(ptr.child, xi, yi)) return false;
                return true;
            },
            else => return x == y,
        },
        .optional => |o| {
            if (x == null or y == null) return x == null and y == null;
            return deepEql(o.child, x.?, y.?);
        },
        .void => return true,
        else => return x == y,
    }
}

/// `e` with each operand `x` replaced by `f(ctx, x)` (a copy if one
/// changed; the queries in it as they are).
fn mapChildren(ar: std.mem.Allocator, e: *Expr, ctx: anytype, comptime f: anytype) Error!*Expr {
    var changed = false;
    const M = struct {
        fn one(c: anytype, x: *Expr, ch: *bool) Error!*Expr {
            const y = try f(c, x);
            if (y != x) ch.* = true;
            return y;
        }
        fn list(al: std.mem.Allocator, c: anytype, xs: []*Expr, ch: *bool) Error![]*Expr {
            const out = try al.alloc(*Expr, xs.len);
            for (xs, out) |x, *o| o.* = try one(c, x, ch);
            return out;
        }
        fn opt(c: anytype, x: ?*Expr, ch: *bool) Error!?*Expr {
            return if (x) |y| try one(c, y, ch) else null;
        }
    };
    var k = e.kind;
    switch (k) {
        .unary => |*u| u.e = try M.one(ctx, u.e, &changed),
        .binary => |*b| {
            b.l = try M.one(ctx, b.l, &changed);
            b.r = try M.one(ctx, b.r, &changed);
        },
        .div => |*b| {
            b.l = try M.one(ctx, b.l, &changed);
            b.r = try M.one(ctx, b.r, &changed);
        },
        .compare => |*b| {
            b.l = try M.one(ctx, b.l, &changed);
            b.r = try M.one(ctx, b.r, &changed);
        },
        .concat => |*x| x.args = try M.list(ar, ctx, x.args, &changed),
        .cast => |*x| x.e = try M.one(ctx, x.e, &changed),
        .func => |*fp| {
            var nf = fp.*.*;
            nf.args = try M.list(ar, ctx, nf.args, &changed);
            nf.filter = try M.opt(ctx, nf.filter, &changed);
            if (nf.order_by.len > 0) {
                const aob = try ar.dupe(tree.SortItem, nf.order_by);
                for (aob) |*it| it.expr = try M.one(ctx, it.expr, &changed);
                nf.order_by = aob;
            }
            if (nf.over) |w| {
                var nw = w.*;
                nw.partition = try M.list(ar, ctx, nw.partition, &changed);
                const ob = try ar.dupe(tree.SortItem, nw.order_by);
                for (ob) |*it| it.expr = try M.one(ctx, it.expr, &changed);
                nw.order_by = ob;
                nf.over = try tree.new(ar, tree.WindowSpec, nw);
            }
            fp.* = try tree.new(ar, tree.Func, nf);
        },
        .case => |*x| {
            x.operand = try M.opt(ctx, x.operand, &changed);
            x.whens = try M.list(ar, ctx, x.whens, &changed);
            x.@"else" = try M.opt(ctx, x.@"else", &changed);
        },
        .in_list => |*x| {
            x.e = try M.one(ctx, x.e, &changed);
            x.items = try M.list(ar, ctx, x.items, &changed);
        },
        .in_select => |*x| x.e = try M.one(ctx, x.e, &changed),
        .between => |*x| {
            x.e = try M.one(ctx, x.e, &changed);
            x.lo = try M.one(ctx, x.lo, &changed);
            x.hi = try M.one(ctx, x.hi, &changed);
        },
        .like => |*x| {
            x.e = try M.one(ctx, x.e, &changed);
            x.pat = try M.one(ctx, x.pat, &changed);
            if (x.escape == .expr) x.escape = .{ .expr = try M.one(ctx, x.escape.expr, &changed) };
        },
        .is_null => |*x| x.e = try M.one(ctx, x.e, &changed),
        .is_bool => |*x| x.e = try M.one(ctx, x.e, &changed),
        .row => |*items| items.* = try M.list(ar, ctx, items.*, &changed),
        .collate => |*x| x.e = try M.one(ctx, x.e, &changed),
        .coerce => |*x| x.e = try M.one(ctx, x.e, &changed),
        else => return e,
    }
    if (!changed) return e;
    return tree.expr(ar, e.pos, e.end, k);
}

test "sameExpr" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const n1 = try ar.alloc(Name, 2);
    n1[0] = .{ .text = "t", .pos = 1 };
    n1[1] = .{ .text = "a", .pos = 3 };
    const n2 = try ar.alloc(Name, 1);
    n2[0] = .{ .text = "a", .pos = 9 };
    const x = try tree.expr(ar, 0, 3, .{ .column = n1 });
    const y = try tree.expr(ar, 9, 10, .{ .column = n2 });
    try std.testing.expect(sameExpr(x, y));
    const one = try tree.intConst(ar, 4, 1);
    const sx = try tree.expr(ar, 0, 5, .{ .binary = .{ .op = .add, .l = x, .r = one } });
    const sy = try tree.expr(ar, 7, 9, .{ .binary = .{ .op = .add, .l = y, .r = try tree.intConst(ar, 8, 1) } });
    try std.testing.expect(sameExpr(sx, sy));
    const sz = try tree.expr(ar, 7, 9, .{ .binary = .{ .op = .sub, .l = y, .r = one } });
    try std.testing.expect(!sameExpr(sx, sz));
}
