//! A LATERAL subquery in a view's query, which SQLite has no syntax for:
//! the tree of the query rewritten in forms SQLite has, before
//! render.zig writes it into the schema. The arguments of a table-valued
//! function may name the FROM items before it (in SQLite and in sqlite3
//! with the extension), so
//!
//!     SELECT a.id, b.n FROM e a, LATERAL (SELECT a.s + 1 AS n) b
//!
//! is
//!
//!     SELECT "a"."id", xq_lateral_col("b"."value", 0, 'integer') AS "n"
//!     FROM "e" AS "a", "json_each"((SELECT xq_lateral_rows(
//!         "xq_lateral"."xq_c1") FROM (WITH "xq_alias"("xq_c1") AS
//!         (SELECT ("a"."s" + 1) AS "n") SELECT * FROM "xq_alias") AS
//!         "xq_lateral")) AS "b"
//!
//! (dialect/lateral.zig): the subquery's rows packed into one value per
//! row of the items before it, json_each() giving them back, each column
//! read out of its row with its type and bytes, typed for the core by
//! the type spelled after it. LEFT JOIN LATERAL ... ON keeps its meaning:
//! SQLite puts the arguments of a table-valued function on the right of
//! a LEFT JOIN into its ON.
//!
//! What a column reference means is known only once names are resolved,
//! so the query is lowered and resolved in a Parse of its own (as
//! ddltype.zig's probe): a reference to a column of the subquery becomes
//! the read of its row; an unqualified reference to a column of another
//! FROM item is qualified with that item's name, so that json_each()'s
//! own columns (key, value, type, id ...), now next to it, take none of
//! them; `*` and `b.*` are the columns they stand for.
//!
//! What is not done (the subquery of a CTE or of a subquery with column
//! aliases, resolved as a copy where it is read; `*` over USING or
//! NATURAL joins) leaves the LATERAL as it is, and render.zig fails on
//! it as before.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const desugar = @import("../../ir/desugar.zig");
const int = @import("../../sql/sqlite_int.zig");
const typing = @import("../../sql/typing.zig");
const util = @import("../../sql/util.zig");
const ddltype = @import("ddltype.zig");

const Expr = tree.Expr;
const Name = tree.Name;
const TK = int.TK;
const Error = @import("parser.zig").Error;

/// The forms of a query (or of a query in it) its SQLite text does not
/// keep.
pub const Forms = struct {
    /// A LATERAL item after the first of its FROM.
    lateral: bool = false,
    /// What desugar.zig rewrites (DISTINCT ON, GROUPING SETS, WITH TIES,
    /// INTERSECT ALL, EXCEPT ALL).
    desugared: bool = false,
};

pub fn forms(s: *tree.Select) Forms {
    var f: Finder = .{};
    walk(&f, s) catch unreachable;
    return f.f;
}

const Finder = struct {
    f: Forms = .{},

    fn query(x: *Finder, s: *tree.Select) Error!void {
        if (desugar.needs(s)) x.f.desugared = true;
    }

    fn enter(x: *Finder, c: *tree.Core) Error!void {
        if (hasLaterItem(c.from)) x.f.lateral = true;
    }

    fn leave(_: *Finder, _: *tree.Core) Error!void {}
};

/// Whether `items` (or a nested item's list) has a LATERAL item after
/// its first.
fn hasLaterItem(items: []const tree.FromItem) bool {
    for (items, 0..) |it, i| {
        if (it.lateral and i > 0) return true;
        if (it.source == .nested and hasLaterItem(it.source.nested)) return true;
    }
    return false;
}

/// Walk query `s` and the queries in it (of its CTEs, its FROM items,
/// its expressions): v.query() of each query, v.enter() and v.leave() of
/// each core before and after the queries in it.
fn walk(v: anytype, s: *tree.Select) Error!void {
    try v.query(s);
    if (s.with) |w| for (w.ctes) |c| try walk(v, c.select);
    try walkBody(v, s.body);
    for (s.order_by) |o| try walkExpr(v, o.expr);
}

fn walkBody(v: anytype, b: *tree.Body) Error!void {
    switch (b.*) {
        .core => |c| {
            try v.enter(c);
            try walkFrom(v, c.from);
            for (c.cols) |rc| if (rc == .expr) try walkExpr(v, rc.expr.e);
            if (c.where) |w| try walkExpr(v, w);
            for (c.group_by) |g| try walkExpr(v, g);
            if (c.having) |h| try walkExpr(v, h);
            try walkOn(v, c.from);
            try v.leave(c);
        },
        .values => |rows| for (rows) |row| for (row) |e| try walkExpr(v, e),
        .compound => |c| {
            try walkBody(v, c.left);
            try walkBody(v, c.right);
        },
        .nested => |n| try walk(v, n),
    }
}

/// The queries of the items of a FROM (flatten()'s order).
fn walkFrom(v: anytype, items: []tree.FromItem) Error!void {
    for (items) |*fi| switch (fi.source) {
        .subquery => |sub| try walk(v, sub),
        .func => |f| for (f.args) |x| try walkExpr(v, x),
        .nested => |n| try walkFrom(v, n),
        else => {},
    };
}

/// The queries of the ON of the items flatten() gives.
fn walkOn(v: anytype, items: []tree.FromItem) Error!void {
    for (items) |*fi| switch (fi.source) {
        .nested => |n| try walkOn(v, n),
        else => if (fi.on) |on| try walkExpr(v, on),
    };
}

fn walkExpr(v: anytype, e: *Expr) Error!void {
    switch (e.kind) {
        .subquery, .exists => |s| try walk(v, s),
        .in_select => |x| {
            try walkExpr(v, x.e);
            try walk(v, x.sel);
        },
        else => {
            var it = tree.Children.of(e);
            while (it.next()) |x| try walkExpr(v, x);
        },
    }
}

/// Rewrite the LATERAL items of view query `s` (offsets of `src`) as
/// above, in place, with the arena `a`. An error is left in `outer`.
pub fn rewrite(outer: *int.Parse, src: [:0]const u8, a: std.mem.Allocator, s: *tree.Select) Error!void {
    var r: Rewriter = .{ .a = a, .outer = outer, .src = src, .s = s };
    r.o.want_from_items = true;
    return ddltype.resolveApart(outer, src, s, &r.o, &r, Rewriter.run);
}

const Item = struct {
    /// The name its columns are qualified with; null if it has none.
    name: ?[]const u8,
    lateral: ?*Lateral = null,
};

const Lateral = struct {
    alias: []const u8,
    names: []const []const u8,
    types: []const ?[]const u8,
};

const Rewriter = struct {
    a: std.mem.Allocator,
    outer: *int.Parse,
    src: [:0]const u8,
    s: *tree.Select,
    /// The Parse `s` is resolved in, and where its nodes went.
    q: *int.Parse = undefined,
    o: lower.Origins = .{},
    /// The walk's: the FROM items by cursor, or the items rewritten.
    stage: enum { collect, items } = .collect,
    items: std.AutoHashMapUnmanaged(i32, Item) = .empty,
    /// The cores whose LATERAL items are rewritten.
    cores: std.AutoHashMapUnmanaged(*const tree.Core, void) = .empty,
    laterals: usize = 0,

    fn run(r: *Rewriter, q: *int.Parse) Error!void {
        if (q.n_err > 0) return;
        r.q = q;
        // The FROM items by cursor, then the references, then the items.
        try walk(r, r.s);
        if (r.laterals == 0) return;
        try r.select(r.s, false);
        r.stage = .items;
        try walk(r, r.s);
    }

    fn query(_: *Rewriter, _: *tree.Select) Error!void {}

    fn enter(r: *Rewriter, c: *tree.Core) Error!void {
        if (r.stage == .collect) try r.collectCore(c);
    }

    fn leave(r: *Rewriter, c: *tree.Core) Error!void {
        if (r.stage == .items) try r.rewriteCore(c);
    }

    fn fail(r: *Rewriter, pos: u32) Error {
        const z: ?[*]const u8 = if (pos < r.src.len) r.src.ptr + pos else null;
        util.errorMsgState(r.outer, z, .of("0A000"), "LATERAL in the query of a view is not supported", .{});
        return error.ParseFailed;
    }

    fn srcItem(r: *const Rewriter, fi: *const tree.FromItem) ?*int.SrcItem {
        const t = r.o.from_items.get(fi) orelse return null;
        if (t.i >= t.list.len()) return null;
        const it = t.list.at(t.i);
        if (it.i_cursor < 0) return null;
        return it;
    }

    // ------------------------------------------------------- collect

    /// The items of core `c` (the queries in it are walked after).
    fn collectCore(r: *Rewriter, c: *tree.Core) Error!void {
        var leaves: std.ArrayList(*tree.FromItem) = .empty;
        try flatten(r.a, c.from, &leaves);
        // A core whose LATERAL items can all be rewritten: each item's
        // term known, a subquery's columns known.
        var any = false;
        var ok = true;
        for (leaves.items) |fi| if (fi.lateral and isLaterRef(c.from, fi)) {
            any = true;
            if (fi.natural or fi.using.len > 0) ok = false;
        };
        for (leaves.items) |fi| {
            const it = r.srcItem(fi) orelse {
                ok = false;
                continue;
            };
            var item: Item = .{ .name = if (it.alias) |al| al else it.name };
            if (fi.lateral and isLaterRef(c.from, fi)) {
                const sub = it.subquery() orelse {
                    ok = false;
                    continue;
                };
                const tab = it.s_tab orelse {
                    ok = false;
                    continue;
                };
                const n = tab.cols.len;
                const names = try r.a.alloc([]const u8, n);
                const types = try r.a.alloc(?[]const u8, n);
                for (tab.cols, names, types, 0..) |col, *nm, *ty, j| {
                    nm.* = try r.a.dupe(u8, col.name());
                    const id = try typing.columnOf(r.q, sub, j);
                    ty.* = if (typing.spelling(r.q.db, id)) |z| try r.a.dupe(u8, z) else null;
                }
                const alias: []const u8 = if (fi.alias) |al| al.name.text else try std.fmt.allocPrint(r.a, "xq_lateral_{d}", .{r.laterals + 1});
                const lat = try tree.new(r.a, Lateral, .{ .alias = alias, .names = names, .types = types });
                item = .{ .name = alias, .lateral = lat };
                r.laterals += 1;
            }
            try r.items.put(r.a, it.i_cursor, item);
        }
        if (any and ok) try r.cores.put(r.a, c, {});
        if (any and !ok) {
            // Leave this core's LATERAL items (render.zig fails on them).
            for (leaves.items) |fi| if (r.srcItem(fi)) |it| if (r.items.getPtr(it.i_cursor)) |p| if (p.lateral != null) {
                p.lateral = null;
                r.laterals -= 1;
            };
        }
    }

    // ---------------------------------------------------- references

    /// The references of `s`; `inside`: in a core being rewritten (or a
    /// query in one), where a reference not resolved cannot be told
    /// from one json_each() would take.
    fn select(r: *Rewriter, s: *tree.Select, inside: bool) Error!void {
        if (s.with) |w| for (w.ctes) |c| try r.select(c.select, inside);
        try r.body(s.body, inside);
        for (s.order_by) |o| try r.ref(o.expr, inside, true);
        if (s.limit) |x| try r.ref(x, inside, false);
        if (s.offset) |x| try r.ref(x, inside, false);
    }

    fn body(r: *Rewriter, b: *tree.Body, inside: bool) Error!void {
        switch (b.*) {
            .core => |c| {
                const in = inside or r.cores.contains(c);
                var leaves: std.ArrayList(*tree.FromItem) = .empty;
                try flatten(r.a, c.from, &leaves);
                for (leaves.items) |fi| {
                    switch (fi.source) {
                        .subquery => |sub| try r.select(sub, in),
                        .func => |f| for (f.args) |x| try r.ref(x, in, false),
                        else => {},
                    }
                    if (fi.on) |on| try r.ref(on, in, false);
                }
                for (c.cols) |*rc| if (rc.* == .expr) {
                    const was_col = rc.expr.e.kind == .column;
                    const last: ?[]const u8 = if (was_col) rc.expr.e.kind.column[rc.expr.e.kind.column.len - 1].text else null;
                    try r.ref(rc.expr.e, in, false);
                    // A column read out of its row keeps its name.
                    if (was_col and rc.expr.e.kind != .column and rc.expr.alias == null and rc.expr.name == null) rc.expr.name = last;
                };
                if (c.where) |w| try r.ref(w, in, false);
                for (c.distinct_on) |g| try r.ref(g, in, true);
                for (c.group_by) |g| try r.ref(g, in, true);
                if (c.having) |h| try r.ref(h, in, false);
                for (c.windows) |w| try r.window(w.spec, in);
            },
            .values => |rows| for (rows) |row| for (row) |e| try r.ref(e, inside, false),
            .compound => |c| {
                try r.body(c.left, inside);
                try r.body(c.right, inside);
            },
            .nested => |n| try r.select(n, inside),
        }
    }

    fn window(r: *Rewriter, w: *tree.WindowSpec, inside: bool) Error!void {
        for (w.partition) |e| try r.ref(e, inside, false);
        for (w.order_by) |o| try r.ref(o.expr, inside, false);
    }

    /// The references of expression `e`; `sort`: a term of ORDER BY or
    /// GROUP BY, which may name a result column.
    fn ref(r: *Rewriter, e: *Expr, inside: bool, sort: bool) Error!void {
        switch (e.kind) {
            .column => |names| return r.column(e, names, inside, sort),
            .subquery, .exists => |s| return r.select(s, inside),
            .in_select => |x| {
                try r.ref(x.e, inside, false);
                return r.select(x.sel, inside);
            },
            .func => |f| {
                for (f.order_by) |o| try r.ref(o.expr, inside, false);
                if (f.over) |w| try r.window(w, inside);
            },
            else => {},
        }
        var it = tree.Children.of(e);
        while (it.next()) |x| try r.ref(x, inside, false);
    }

    fn column(r: *Rewriter, e: *Expr, names: []const Name, inside: bool, sort: bool) Error!void {
        const x = r.o.exprs.get(e) orelse {
            if (inside) return r.fail(e.pos);
            return;
        };
        if (x.op != TK.COLUMN) {
            // A result column an ORDER BY or GROUP BY term names (the
            // core put a copy of it there): its name stays.
            if (sort and x.op != TK.ID and x.op != TK.DOT) return;
            if (inside and (x.op == TK.ID or x.op == TK.DOT)) return r.fail(e.pos);
            return;
        }
        const item = r.items.get(x.i_table) orelse return;
        if (item.lateral) |lat| {
            const j: usize = @intCast(x.i_column);
            if (j >= lat.names.len) return r.fail(e.pos);
            e.kind = .{ .func = try r.readCall(e.pos, lat, j) };
            return;
        }
        if (names.len != 1) return;
        const q = item.name orelse return;
        const two = try r.a.alloc(Name, 2);
        two[0] = .{ .text = q, .pos = names[0].pos };
        two[1] = names[0];
        e.kind = .{ .column = two };
    }

    /// xq_lateral_col("alias"."value", j, 'type').
    fn readCall(r: *Rewriter, pos: u32, lat: *const Lateral, j: usize) Error!*tree.Func {
        const col = try r.a.alloc(Name, 2);
        col[0] = .{ .text = lat.alias, .pos = pos };
        col[1] = .{ .text = "value", .pos = pos };
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(r.a, try tree.expr(r.a, pos, pos, .{ .column = col }));
        try args.append(r.a, try tree.intConst(r.a, pos, @intCast(j)));
        if (lat.types[j]) |t| try args.append(r.a, try tree.expr(r.a, pos, pos, .{ .string = t }));
        return tree.new(r.a, tree.Func, .{ .name = .{ .text = "xq_lateral_col", .pos = pos }, .args = args.items });
    }

    // ------------------------------------------------------- items

    /// The items of core `c` (the queries in it are walked before: their
    /// own LATERAL items first).
    fn rewriteCore(r: *Rewriter, c: *tree.Core) Error!void {
        if (!r.cores.contains(c)) return;
        var leaves: std.ArrayList(*tree.FromItem) = .empty;
        try flatten(r.a, c.from, &leaves);
        try r.expandStars(c, leaves.items);
        for (leaves.items) |fi| if (r.lateralOf(fi)) |lat| try r.rowsItem(fi, lat);
    }

    /// `*` and `b.*` of a core being rewritten: the columns of its items
    /// (json_each()'s would be in them).
    fn expandStars(r: *Rewriter, c: *tree.Core, leaves: []const *tree.FromItem) Error!void {
        var has = false;
        for (c.cols) |rc| switch (rc) {
            .star => has = true,
            .table_star => |ts| {
                for (leaves) |fi| if (r.lateralOf(fi)) |lat| if (std.ascii.eqlIgnoreCase(lat.alias, ts.names[ts.names.len - 1].text)) {
                    has = true;
                };
            },
            else => {},
        };
        if (!has) return;
        var out: std.ArrayList(tree.ResultCol) = .empty;
        for (c.cols) |rc| switch (rc) {
            .star => |pos| {
                for (leaves) |fi| {
                    if (fi.natural or fi.using.len > 0) return r.fail(pos);
                    if (r.lateralOf(fi)) |lat| {
                        try r.lateralCols(&out, lat, pos);
                        continue;
                    }
                    const it = r.srcItem(fi) orelse return r.fail(pos);
                    const item = r.items.get(it.i_cursor) orelse return r.fail(pos);
                    const name = item.name orelse return r.fail(pos);
                    const names = try r.a.alloc(Name, 1);
                    names[0] = .{ .text = name, .pos = pos };
                    try out.append(r.a, .{ .table_star = .{ .names = names, .star_pos = pos } });
                }
            },
            .table_star => |ts| {
                const lat = for (leaves) |fi| {
                    if (r.lateralOf(fi)) |l| if (std.ascii.eqlIgnoreCase(l.alias, ts.names[ts.names.len - 1].text)) break l;
                } else null;
                if (lat) |l| try r.lateralCols(&out, l, ts.star_pos) else try out.append(r.a, rc);
            },
            .expr => try out.append(r.a, rc),
        };
        c.cols = out.items;
    }

    fn lateralOf(r: *const Rewriter, fi: *const tree.FromItem) ?*Lateral {
        const it = r.srcItem(fi) orelse return null;
        const item = r.items.get(it.i_cursor) orelse return null;
        return item.lateral;
    }

    fn lateralCols(r: *Rewriter, out: *std.ArrayList(tree.ResultCol), lat: *const Lateral, pos: u32) Error!void {
        for (lat.names, 0..) |n, j| {
            const e = try tree.expr(r.a, pos, pos, .{ .func = try r.readCall(pos, lat, j) });
            try out.append(r.a, .{ .expr = .{ .e = e, .name = n } });
        }
    }

    /// LATERAL (s) AS b: json_each((SELECT xq_lateral_rows(...) FROM
    /// (s) AS xq_lateral(xq_c1 ...))) AS b.
    fn rowsItem(r: *Rewriter, fi: *tree.FromItem, lat: *const Lateral) Error!void {
        const sub = fi.source.subquery;
        const pos = sub.pos;
        const k = lat.names.len;
        const cols = try r.a.alloc(Name, k);
        var args: std.ArrayList(*Expr) = .empty;
        for (cols, 0..) |*cn, j| {
            cn.* = .{ .text = try std.fmt.allocPrint(r.a, "xq_c{d}", .{j + 1}), .pos = pos };
            const ref_names = try r.a.alloc(Name, 2);
            ref_names[0] = .{ .text = "xq_lateral", .pos = pos };
            ref_names[1] = cn.*;
            try args.append(r.a, try tree.expr(r.a, pos, pos, .{ .column = ref_names }));
        }
        const call = try tree.new(r.a, tree.Func, .{ .name = .{ .text = "xq_lateral_rows", .pos = pos }, .args = args.items });
        const rc = try r.a.alloc(tree.ResultCol, 1);
        rc[0] = .{ .expr = .{ .e = try tree.expr(r.a, pos, pos, .{ .func = call }) } };
        const from = try r.a.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = sub }, .alias = .{ .name = .{ .text = "xq_lateral", .pos = pos }, .cols = cols } };
        const core = try tree.new(r.a, tree.Core, .{ .cols = rc, .from = from, .pos = pos });
        const packed_sel = try tree.new(r.a, tree.Select, .{ .body = try tree.new(r.a, tree.Body, .{ .core = core }), .pos = pos });
        const fargs = try r.a.alloc(*Expr, 1);
        fargs[0] = try tree.expr(r.a, pos, pos, .{ .subquery = packed_sel });
        const f = try tree.new(r.a, tree.Func, .{ .name = .{ .text = "json_each", .pos = pos }, .args = fargs });
        fi.source = .{ .func = f };
        fi.lateral = false;
        fi.alias = .{ .name = .{ .text = lat.alias, .pos = if (fi.alias) |al| al.name.pos else pos } };
    }
};

/// Whether `fi` is a LATERAL item of `items` after the first (or inside
/// a nested item, after the first of its list).
fn isLaterRef(items: []tree.FromItem, fi: *const tree.FromItem) bool {
    for (items, 0..) |*x, i| {
        if (x == fi) return i > 0;
        if (x.source == .nested) if (isLaterRef(x.source.nested, fi)) return true;
    }
    return false;
}

/// The items of a FROM, nested ones' items in their place.
fn flatten(a: std.mem.Allocator, items: []tree.FromItem, out: *std.ArrayList(*tree.FromItem)) error{OutOfMemory}!void {
    for (items) |*fi| {
        if (fi.source == .nested) {
            try flatten(a, fi.source.nested, out);
        } else try out.append(a, fi);
    }
}
