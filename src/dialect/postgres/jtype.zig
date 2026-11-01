//! What the JSON of a parsed statement needs from the structure of FROM
//! and the names it binds, which the parser alone does not know (the
//! select list comes before FROM): a pass over the tree, after parsing,
//! with the scopes of FROM (the names of their columns only):
//!
//!  - a FROM item named as a value (`row_to_json(t)`, `json_agg(t)`, an
//!    argument of another function that builds JSON) is its row, spelled
//!    out as xq_pg_row_json('a', t.a, ...);
//!  - a reference to a column of a JSON set-returning function of FROM
//!    (parser.zig's json_each() items) is replaced by its expression,
//!    `*` spelled out where such an item is;
//!  - a value stored into a jsonb column (INSERT, UPDATE) is normalized
//!    (xq_pg_jsonb()), into a json column checked (xq_pg_json()): the
//!    column's type is the catalog's.
//!
//! What depends on the types of operands (jsonb's `||` and `-`, the
//! json/jsonb functions of `->`, jsonb's comparison and ORDER BY, the
//! arguments of the functions that build JSON) is chosen in the core,
//! once names are resolved and operands typed: overload.zig, which also
//! drops the normalization of a stored value that is jsonb already. For
//! the text the schema keeps (a view, a CHECK, an index expression),
//! ddltype.zig brings the core's choices back to the tree.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const overload = @import("overload.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;

const Col = struct {
    name: []const u8,
    /// A column of a JSON set-returning function.
    srf: ?parser.SrfCol = null,
    insertable: bool = true,
    /// A result column with AS.
    aliased: bool = false,
};

const Item = struct {
    name: []const u8,
    /// A table-valued function (json_each() ...), whose own columns
    /// (key, value, id ...) unqualified names must not meet.
    vtab: bool = false,
    /// Null when not known (a table-valued function of SQLite's).
    cols: ?[]const Col,
};

const Cte = struct { name: []const u8, cols: []const Col };

const Scope = struct {
    parent: ?*const Scope = null,
    items: []const Item = &.{},
    ctes: []const Cte = &.{},

    fn cte(sc: *const Scope, name: []const u8) ?[]const Col {
        var s: ?*const Scope = sc;
        while (s) |x| : (s = x.parent) {
            for (x.ctes) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c.cols;
        }
        return null;
    }
};

pub fn statement(p: *Parser, stmt: tree.Stmt) Error!void {
    var t: T = .{ .p = p };
    try t.stmt(stmt);
}

/// What a column stores a value as (its declared type, in the catalog).
const Store = enum { as_is, json, jsonb };

const T = struct {
    p: *Parser,

    fn arena(t: *T) std.mem.Allocator {
        return t.p.arena;
    }

    fn stmt(t: *T, s: tree.Stmt) Error!void {
        switch (s) {
            .select => |x| _ = try t.select(x, null),
            .insert => |x| try t.insert(x),
            .update => |x| try t.update(x),
            .delete => |x| try t.delete(x),
            .create_view => |v| _ = try t.select(v.select, null),
            .create_table => |ct| if (ct.as_select) |x| {
                _ = try t.select(x, null);
            },
            .explain => |inner| try t.stmt(inner.*),
            else => {},
        }
    }

    // ============================================================ scopes

    /// The columns of table `q`, null if unknown.
    fn tableCols(t: *T, q: tree.QName) Error!?[]const Col {
        const ps = t.p.p orelse return null;
        t.p.readSchema() catch return null;
        const tbl = build.findTable(ps.db, q.name.text, if (q.schema) |s| s.text else null) orelse return null;
        var cols: std.ArrayList(Col) = .empty;
        for (tbl.cols) |*c| try cols.append(t.arena(), .{ .name = c.name(), .insertable = !c.col_flags.intersects(int.COLFLAG.NOINSERT) });
        return cols.items;
    }

    /// How the columns of table `q` store values (by the order of
    /// tableCols()), null if no column is json or jsonb.
    fn storeTypes(t: *T, q: tree.QName) Error!?[]const Store {
        const ps = t.p.p orelse return null;
        t.p.readSchema() catch return null;
        const tbl = build.findTable(ps.db, q.name.text, if (q.schema) |s| s.text else null) orelse return null;
        const m = (catalog.metaOf(ps.db, tbl) catch null) orelse return null;
        const out = try t.arena().alloc(Store, tbl.cols.len);
        var any = false;
        for (tbl.cols, out) |*c, *st| {
            const d = m.declType(c.name()) orelse "";
            st.* = if (std.mem.eql(u8, d, "jsonb")) .jsonb else if (std.mem.eql(u8, d, "json")) .json else .as_is;
            if (st.* != .as_is) any = true;
        }
        return if (any) out else null;
    }

    fn tableScope(t: *T, q: tree.QName, name: []const u8, parent: ?*const Scope) Error!*const Scope {
        const items = try t.arena().alloc(Item, 1);
        items[0] = .{ .name = name, .cols = try t.tableCols(q) };
        return tree.new(t.arena(), Scope, .{ .parent = parent, .items = items });
    }

    /// The items of FROM, appended to `items` (ON conditions walked as
    /// they come).
    fn fromItems(t: *T, from: []tree.FromItem, items: *std.ArrayList(Item), parent: ?*const Scope) Error!void {
        for (from) |*fi| {
            var cols: ?[]const Col = null;
            var name: []const u8 = "";
            switch (fi.source) {
                .table => |q| {
                    name = q.name.text;
                    const cte = if (q.schema == null and parent != null) parent.?.cte(q.name.text) else null;
                    cols = cte orelse try t.tableCols(q);
                },
                .subquery => |sub| {
                    cols = try t.select(sub, parent);
                },
                .func => |f| {
                    name = f.name.text;
                    const sc = try tree.new(t.arena(), Scope, .{ .parent = parent, .items = try t.arena().dupe(Item, items.items) });
                    for (f.args) |a| _ = try t.expr(a, sc);
                    if (t.p.srfs.get(f)) |srf| {
                        const cs = try t.arena().alloc(Col, srf.cols.len);
                        for (srf.cols, cs) |sc_, *c| c.* = .{ .name = sc_.name, .srf = sc_ };
                        cols = cs;
                    }
                },
                .nested => |inner| {
                    try t.fromItems(inner, items, parent);
                    continue;
                },
            }
            if (fi.alias) |a| {
                name = a.name.text;
                if (cols) |cs| if (a.cols.len > 0) {
                    const renamed = try t.arena().dupe(Col, cs);
                    for (a.cols, 0..) |n, i| if (i < renamed.len) {
                        renamed[i].name = n.text;
                    };
                    cols = renamed;
                };
            }
            try items.append(t.arena(), .{ .name = name, .cols = cols, .vtab = fi.source == .func });
            if (fi.on) |on| {
                const sc = try tree.new(t.arena(), Scope, .{ .parent = parent, .items = try t.arena().dupe(Item, items.items) });
                _ = try t.expr(on, sc);
            }
        }
    }

    // =========================================================== queries

    /// Walk a query; its result columns.
    fn select(t: *T, s: *tree.Select, parent: ?*const Scope) Error![]const Col {
        var sc: *const Scope = try tree.new(t.arena(), Scope, .{ .parent = parent });
        if (s.with) |w| {
            var ctes: std.ArrayList(Cte) = .empty;
            for (w.ctes) |*c| {
                const inner = try tree.new(t.arena(), Scope, .{ .parent = parent, .ctes = try t.arena().dupe(Cte, ctes.items) });
                var cols = try t.arena().dupe(Col, try t.select(c.select, inner));
                for (c.cols, 0..) |n, i| if (i < cols.len) {
                    cols[i].name = n.text;
                };
                try ctes.append(t.arena(), .{ .name = c.name.text, .cols = cols });
            }
            sc = try tree.new(t.arena(), Scope, .{ .parent = parent, .ctes = ctes.items });
        }
        var core_scope: ?*const Scope = null;
        const cols = try t.body(s.body, sc, &core_scope);
        for (s.order_by) |*item| {
            if (item.expr.kind == .integer) continue;
            if (item.expr.kind == .column and item.expr.kind.column.len == 1) if (findCol(cols, item.expr.kind.column[0].text)) |rc| {
                // A name that is not an alias is the column (qualified
                // next to json_each()).
                if (!rc.aliased) _ = try t.expr(item.expr, core_scope orelse sc);
                continue;
            };
            _ = try t.expr(item.expr, core_scope orelse sc);
        }
        if (s.limit) |x| _ = try t.expr(x, sc);
        if (s.offset) |x| _ = try t.expr(x, sc);
        return cols;
    }

    fn body(t: *T, b: *tree.Body, sc: *const Scope, core_scope: *?*const Scope) Error![]const Col {
        switch (b.*) {
            .core => |c| return t.core(c, sc, core_scope),
            .values => |rows| {
                var cols: std.ArrayList(Col) = .empty;
                for (rows, 0..) |row, r| for (row, 0..) |e, i| {
                    _ = try t.expr(e, sc);
                    if (r == 0) try cols.append(t.arena(), .{ .name = try std.fmt.allocPrint(t.arena(), "column{d}", .{i + 1}) });
                };
                return cols.items;
            },
            .compound => |c| {
                var ignore: ?*const Scope = null;
                const l = try t.body(c.left, sc, &ignore);
                _ = try t.body(c.right, sc, &ignore);
                return l;
            },
            .nested => |n| return t.select(n, sc),
        }
    }

    fn core(t: *T, c: *tree.Core, parent: *const Scope, out_scope: *?*const Scope) Error![]const Col {
        var items: std.ArrayList(Item) = .empty;
        try t.fromItems(c.from, &items, parent);
        const sc = try tree.new(t.arena(), Scope, .{ .parent = parent, .items = items.items });
        out_scope.* = sc;
        try t.expandStars(c, sc);
        var cols: std.ArrayList(Col) = .empty;
        for (c.cols) |*rc| switch (rc.*) {
            .expr => |*x| {
                const aliased = x.alias != null;
                const was: ?[]const u8 = if (x.e.kind == .column) x.e.kind.column[x.e.kind.column.len - 1].text else null;
                _ = try t.expr(x.e, sc);
                const name = if (x.alias) |a| a.text else if (x.name) |n| n else if (was) |w| w else "?column?";
                // A json_each() column a reference became keeps the
                // reference's name (SQLite would name it after json_each's
                // column or the expression).
                if (x.alias == null and (x.e.kind != .column and was != null or x.e.kind == .column and t.p.srf_refs.contains(x.e))) x.alias = .{ .text = name, .pos = x.e.pos };
                try cols.append(t.arena(), .{ .name = name, .aliased = aliased });
            },
            .star => for (sc.items) |it| if (it.cols) |cs| try cols.appendSlice(t.arena(), cs),
            .table_star => |ts| if (findItem(sc, ts.names[ts.names.len - 1].text)) |it| if (it.cols) |cs| try cols.appendSlice(t.arena(), cs),
        };
        if (c.where) |w| _ = try t.expr(w, sc);
        for (c.group_by) |g| _ = try t.expr(g, sc);
        if (c.having) |h| _ = try t.expr(h, sc);
        for (c.windows) |w| try t.window(w.spec, sc);
        return cols.items;
    }

    /// `*` and `t.*` spelled out when FROM has a JSON set-returning
    /// function (whose json_each() columns are not its own).
    fn expandStars(t: *T, c: *tree.Core, sc: *const Scope) Error!void {
        var any = false;
        for (sc.items) |it| if (it.cols) |cs| {
            for (cs) |col| if (col.srf != null) {
                any = true;
            };
        };
        if (!any) return;
        var out: std.ArrayList(tree.ResultCol) = .empty;
        for (c.cols) |rc| {
            const pos: u32 = switch (rc) {
                .star => |at| at,
                .table_star => |ts| ts.star_pos,
                .expr => {
                    try out.append(t.arena(), rc);
                    continue;
                },
            };
            var expanded = true;
            for (sc.items) |it| {
                if (rc == .table_star and !std.ascii.eqlIgnoreCase(it.name, rc.table_star.names[rc.table_star.names.len - 1].text)) continue;
                const cs = it.cols orelse {
                    expanded = false;
                    break;
                };
                for (cs) |col| {
                    const e = if (col.srf) |srf| try t.p.srfColumn(it.name, srf, pos) else blk: {
                        const names = try t.arena().alloc(Name, 2);
                        names[0] = .{ .text = it.name, .pos = pos };
                        names[1] = .{ .text = col.name, .pos = pos };
                        break :blk try tree.expr(t.arena(), pos, pos, .{ .column = names });
                    };
                    try out.append(t.arena(), .{ .expr = .{ .e = e, .alias = .{ .text = col.name, .pos = pos } } });
                }
            }
            if (!expanded) return;
        }
        c.cols = out.items;
    }

    fn window(t: *T, w: *tree.WindowSpec, sc: *const Scope) Error!void {
        for (w.partition) |e| _ = try t.expr(e, sc);
        for (w.order_by) |*item| _ = try t.expr(item.expr, sc);
    }

    // ============================================================== DML

    fn insert(t: *T, ins: *tree.Insert) Error!void {
        var sc: *const Scope = try tree.new(t.arena(), Scope, .{});
        if (ins.with) |w| {
            var ctes: std.ArrayList(Cte) = .empty;
            for (w.ctes) |*c| {
                const inner = try tree.new(t.arena(), Scope, .{ .ctes = try t.arena().dupe(Cte, ctes.items) });
                try ctes.append(t.arena(), .{ .name = c.name.text, .cols = try t.select(c.select, inner) });
            }
            sc = try tree.new(t.arena(), Scope, .{ .ctes = ctes.items });
        }
        if (ins.source) |src| _ = try t.select(src, sc);
        const target_name = if (ins.alias) |a| a.text else ins.table.name.text;
        const cols = (try t.tableCols(ins.table)) orelse return;
        const stores = try t.storeTypes(ins.table);
        if (ins.source) |src| if (stores) |st| try t.coerceInsert(ins, src, cols, st);
        const tsc = try t.tableScope(ins.table, target_name, null);
        if (ins.on_conflict) |oc| {
            const items = try t.arena().alloc(Item, 2);
            items[0] = tsc.items[0];
            items[1] = .{ .name = "excluded", .cols = cols };
            const csc = try tree.new(t.arena(), Scope, .{ .items = items });
            for (oc.target) |e| _ = try t.expr(e, csc);
            if (oc.target_where) |w| _ = try t.expr(w, csc);
            if (oc.update) |items_| try t.sets(items_, cols, stores, csc);
            if (oc.where) |w| _ = try t.expr(w, csc);
        }
        try t.returning(ins.returning, tsc);
    }

    fn update(t: *T, u: *tree.Update) Error!void {
        const name = if (u.alias) |a| a.text else u.table.name.text;
        const cols = try t.tableCols(u.table);
        var items: std.ArrayList(Item) = .empty;
        try items.append(t.arena(), .{ .name = name, .cols = cols });
        try t.fromItems(u.from, &items, null);
        const sc = try tree.new(t.arena(), Scope, .{ .items = items.items });
        if (cols) |cs| {
            try t.sets(u.sets, cs, try t.storeTypes(u.table), sc);
        } else for (u.sets) |s| {
            _ = try t.expr(s.value, sc);
        }
        if (u.where) |w| _ = try t.expr(w, sc);
        try t.returning(u.returning, sc);
    }

    fn delete(t: *T, d: *tree.Delete) Error!void {
        const name = if (d.alias) |a| a.text else d.table.name.text;
        var items: std.ArrayList(Item) = .empty;
        try items.append(t.arena(), .{ .name = name, .cols = try t.tableCols(d.table) });
        try t.fromItems(d.using, &items, null);
        const sc = try tree.new(t.arena(), Scope, .{ .items = items.items });
        if (d.where) |w| _ = try t.expr(w, sc);
        try t.returning(d.returning, sc);
    }

    fn returning(t: *T, cols: []tree.ResultCol, sc: *const Scope) Error!void {
        for (cols) |*rc| if (rc.* == .expr) {
            _ = try t.expr(rc.expr.e, sc);
        };
    }

    fn sets(t: *T, items: []tree.SetItem, cols: []const Col, stores: ?[]const Store, sc: *const Scope) Error!void {
        for (items) |*s| {
            _ = try t.expr(s.value, sc);
            if (s.multi) continue;
            const st = stores orelse continue;
            const i = colIndex(cols, s.cols[0].text) orelse continue;
            s.value = try t.stored(s.value, st[i]);
        }
    }

    /// `v` as stored into a column that stores `st`: normalized for
    /// jsonb, checked for json, by a call no frontend types (which
    /// overload.zig drops if `v` is a call of that type already).
    fn stored(t: *T, v: *Expr, st: Store) Error!*Expr {
        if (v.kind == .default or v.kind == .null) return v;
        const f: []const u8 = switch (st) {
            .jsonb => "xq_pg_jsonb",
            .json => "xq_pg_json",
            .as_is => return v,
        };
        return tree.expr(t.arena(), v.pos, v.end, .{ .cast = .{ .e = v, .mode = .{ .func = f } } });
    }

    /// The values of an INSERT into json/jsonb columns: VALUES items in
    /// place, a query's result columns, else the query wrapped as
    /// SELECT stored(c1) ... FROM (query) AS xq_src(c1, ...).
    fn coerceInsert(t: *T, ins: *tree.Insert, src: *tree.Select, cols: []const Col, stores: []const Store) Error!void {
        var targets: std.ArrayList(Store) = .empty;
        if (ins.cols.len > 0) {
            for (ins.cols) |n| try targets.append(t.arena(), if (colIndex(cols, n.text)) |i| stores[i] else .as_is);
        } else for (cols, stores) |c, st| if (c.insertable) try targets.append(t.arena(), st);
        var any = false;
        for (targets.items) |st| if (st != .as_is) {
            any = true;
        };
        if (!any) return;
        const colStore = struct {
            fn f(ts: []const Store, i: usize) Store {
                return if (i < ts.len) ts[i] else .as_is;
            }
        }.f;
        if (src.body.* == .values and src.with == null and src.order_by.len == 0 and src.limit == null) {
            for (src.body.values) |row| for (row, 0..) |*item, i| {
                item.* = try t.stored(item.*, colStore(targets.items, i));
            };
            return;
        }
        if (src.body.* == .core and src.order_by.len == 0 and src.limit == null and src.offset == null) {
            const c = src.body.core;
            var plain = true;
            for (c.cols) |rc| if (rc != .expr) {
                plain = false;
            };
            if (plain) {
                for (c.cols, 0..) |*rc, i| rc.expr.e = try t.stored(rc.expr.e, colStore(targets.items, i));
                return;
            }
        }
        const n = targets.items.len;
        const names = try t.arena().alloc(Name, n);
        const rcs = try t.arena().alloc(tree.ResultCol, n);
        for (names, rcs, 0..) |*nm, *rc, i| {
            nm.* = .{ .text = try std.fmt.allocPrint(t.arena(), "xq_{d}", .{i + 1}), .pos = src.pos };
            const one = try t.arena().alloc(Name, 1);
            one[0] = nm.*;
            const col = try tree.expr(t.arena(), src.pos, src.pos, .{ .column = one });
            rc.* = .{ .expr = .{ .e = try t.stored(col, colStore(targets.items, i)) } };
        }
        var from = try t.arena().alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = src }, .alias = .{ .name = .{ .text = "xq_src", .pos = src.pos }, .cols = names } };
        const c = try tree.new(t.arena(), tree.Core, .{ .cols = rcs, .from = from, .pos = src.pos });
        ins.source = try tree.new(t.arena(), tree.Select, .{ .body = try tree.new(t.arena(), tree.Body, .{ .core = c }), .pos = src.pos });
    }

    // ======================================================= expressions

    /// Walk expression `e`; whether it is a FROM item named as a value
    /// (a row).
    fn expr(t: *T, e: *Expr, sc: ?*const Scope) Error!bool {
        switch (e.kind) {
            .column => |names| return t.column(e, names, sc),
            .func => |f| try t.func(e, f, sc),
            .in_select => |x| {
                _ = try t.expr(x.e, sc);
                _ = try t.select(x.sel, sc);
            },
            .exists, .subquery => |s| _ = try t.select(s, sc),
            else => {
                var it = Children.of(e);
                while (it.next()) |x| _ = try t.expr(x, sc);
            },
        }
        return false;
    }

    /// A column reference: a column of a JSON set-returning function
    /// becomes its expression; whether it is a FROM item (`t` naming
    /// one), a row.
    fn column(t: *T, e: *Expr, names: []const Name, sc_opt: ?*const Scope) Error!bool {
        const sc = sc_opt orelse return false;
        if (t.p.srf_refs.contains(e)) return false;
        const col_name = names[names.len - 1].text;
        const item_name: ?[]const u8 = if (names.len >= 2) names[names.len - 2].text else null;
        var s: ?*const Scope = sc;
        while (s) |x| : (s = x.parent) {
            for (x.items) |it| {
                if (item_name) |n| if (!std.ascii.eqlIgnoreCase(it.name, n)) continue;
                const cs = it.cols orelse continue;
                const col = findCol(cs, col_name) orelse continue;
                if (col.srf) |srf| {
                    const v = try t.p.srfColumn(it.name, srf, e.pos);
                    e.kind = v.kind;
                    if (e.kind == .column) try t.p.srf_refs.put(t.arena(), e, {});
                } else if (names.len == 1 and it.name.len > 0) {
                    // Next to a json_each() item, `id` would be its column.
                    var vtab = false;
                    for (x.items) |o| if (o.vtab) {
                        vtab = true;
                    };
                    if (vtab) {
                        const q = try t.arena().alloc(Name, 2);
                        q[0] = .{ .text = it.name, .pos = names[0].pos };
                        q[1] = names[0];
                        e.kind = .{ .column = q };
                    }
                }
                return false;
            }
        }
        // A FROM item as a value: its row.
        return names.len == 1 and findItem(sc, col_name) != null;
    }

    fn func(t: *T, e: *Expr, f: *tree.Func, sc: ?*const Scope) Error!void {
        const n = f.name.text;
        const builder = overload.builderArgs(n);
        for (f.args, 0..) |*a, i| {
            const row = try t.expr(a.*, sc);
            if (row and builder.takes(i)) a.* = try t.rowJson(a.*, sc.?);
        }
        if (f.filter) |x| _ = try t.expr(x, sc);
        for (f.order_by) |*item| _ = try t.expr(item.expr, sc);
        if (f.over) |w| if (sc) |s| try t.window(w, s);
        if (std.mem.eql(u8, n, "row_to_json") and f.args.len == 1 and f.args[0].kind == .func and std.mem.eql(u8, f.args[0].kind.func.name.text, "xq_pg_row_json")) {
            e.kind = f.args[0].kind;
        }
    }

    /// xq_pg_row_json('a', t.a, ...) of FROM item `t` (its values made
    /// JSON by their types in the core: overload.zig).
    fn rowJson(t: *T, a: *Expr, sc: *const Scope) Error!*Expr {
        const it = findItem(sc, a.kind.column[0].text).?;
        const cs = it.cols orelse return a;
        var args: std.ArrayList(*Expr) = .empty;
        for (cs) |col| {
            try args.append(t.arena(), try tree.expr(t.arena(), a.pos, a.end, .{ .string = col.name }));
            const v = if (col.srf) |srf| try t.p.srfColumn(it.name, srf, a.pos) else blk: {
                const names = try t.arena().alloc(Name, 2);
                names[0] = .{ .text = it.name, .pos = a.pos };
                names[1] = .{ .text = col.name, .pos = a.pos };
                break :blk try tree.expr(t.arena(), a.pos, a.end, .{ .column = names });
            };
            try args.append(t.arena(), v);
        }
        const f = try tree.new(t.arena(), tree.Func, .{ .name = .{ .text = "xq_pg_row_json", .pos = a.pos }, .args = try t.arena().dupe(*Expr, args.items) });
        return tree.expr(t.arena(), a.pos, a.end, .{ .func = f });
    }
};

// ================================================================ tables

fn findCol(cols: []const Col, name: []const u8) ?Col {
    for (cols) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

fn colIndex(cols: []const Col, name: []const u8) ?usize {
    for (cols, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
    return null;
}

fn findItem(sc: *const Scope, name: []const u8) ?Item {
    var s: ?*const Scope = sc;
    while (s) |x| : (s = x.parent) {
        for (x.items) |it| if (std.ascii.eqlIgnoreCase(it.name, name)) return it;
    }
    return null;
}

// =========================================================== tree walking

/// The direct subexpressions of an expression (not of subqueries).
pub const Children = struct {
    buf: [4]*Expr = undefined,
    extra: []const *Expr = &.{},
    n: usize = 0,
    i: usize = 0,
    j: usize = 0,

    pub fn of(e: *const Expr) Children {
        var c: Children = .{};
        switch (e.kind) {
            .unary => |u| c.add(u.e),
            .binary => |b| {
                c.add(b.l);
                c.add(b.r);
            },
            .div => |d| {
                c.add(d.l);
                c.add(d.r);
            },
            .compare => |x| {
                c.add(x.l);
                c.add(x.r);
            },
            .concat => |x| c.extra = x.args,
            .cast => |x| c.add(x.e),
            .func => |f| {
                c.extra = f.args;
                if (f.filter) |x| c.add(x);
            },
            .case => |x| {
                if (x.operand) |o| c.add(o);
                if (x.@"else") |o| c.add(o);
                c.extra = x.whens;
            },
            .in_list => |x| {
                c.add(x.e);
                c.extra = x.items;
            },
            .in_select => |x| c.add(x.e),
            .between => |x| {
                c.add(x.e);
                c.add(x.lo);
                c.add(x.hi);
            },
            .like => |x| {
                c.add(x.e);
                c.add(x.pat);
                if (x.escape == .expr) c.add(x.escape.expr);
            },
            .is_null => |x| c.add(x.e),
            .is_bool => |x| c.add(x.e),
            .row => |items| c.extra = items,
            .collate => |x| c.add(x.e),
            .coerce => |x| c.add(x.e),
            else => {},
        }
        return c;
    }

    fn add(c: *Children, e: *Expr) void {
        c.buf[c.n] = e;
        c.n += 1;
    }

    pub fn next(c: *Children) ?*Expr {
        if (c.i < c.n) {
            c.i += 1;
            return c.buf[c.i - 1];
        }
        if (c.j < c.extra.len) {
            c.j += 1;
            return c.extra[c.j - 1];
        }
        return null;
    }
};
