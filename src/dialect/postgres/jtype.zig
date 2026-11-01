//! The json/jsonb typing of a parsed statement: what PostgreSQL decides
//! from the types of operands, which the parser alone does not know (a
//! column's type is in the catalog, and the select list comes before
//! FROM). A pass over the tree, after parsing, with the scopes of FROM:
//!
//!  - `a || b` with a jsonb operand is xq_pg_jsonb_concat(); `a - b` with
//!    a jsonb left operand xq_pg_jsonb_delete[_keys]();
//!  - `->`, `#>` ... of a jsonb operand call jsonb's functions (their
//!    results are normalized), of json json's (the text as written);
//!  - a comparison with a jsonb operand compares in jsonb's order
//!    (collation xq_pg_jsonb), a string constant read as jsonb; ORDER
//!    BY a jsonb value too;
//!  - an argument of a function that builds JSON (to_json(),
//!    json_build_object(), json_agg() ...) that is json/jsonb (a column)
//!    is wrapped in xq_pg_json()/xq_pg_jsonb() so that it has the JSON
//!    subtype, a boolean in xq_pg_json_bool(), an array literal in
//!    xq_pg_array_to_json(), a row (`t` naming a FROM item) spelled out
//!    as xq_pg_row_json('a', t.a, ...);
//!  - a reference to a column of a JSON set-returning function of FROM
//!    (parser.zig's json_each() items) is replaced by its expression,
//!    `*` spelled out where such an item is;
//!  - a value stored into a jsonb column (INSERT, UPDATE) is normalized
//!    (xq_pg_jsonb()), into a json column checked (xq_pg_json()).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;

pub const JT = enum { other, unknown, json, jsonb, boolean, text_array, num_array, row };

const Col = struct {
    name: []const u8,
    jt: JT,
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

const T = struct {
    p: *Parser,
    jts: std.AutoHashMapUnmanaged(*const Expr, JT) = .empty,

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
            .create_table => |ct| try t.createTable(ct),
            .create_index => |ci| {
                const q: tree.QName = .{ .schema = ci.name.schema, .name = ci.table };
                const sc = try t.tableScope(q, ci.table.text, null);
                for (ci.items) |*item| _ = try t.expr(item.expr, sc);
                if (ci.where) |w| _ = try t.expr(w, sc);
            },
            .explain => |inner| try t.stmt(inner.*),
            else => {},
        }
    }

    // ============================================================ scopes

    /// The columns of table `q` (its catalog types), null if unknown.
    fn tableCols(t: *T, q: tree.QName) Error!?[]const Col {
        const ps = t.p.p orelse return null;
        t.p.readSchema() catch return null;
        const tbl = build.findTable(ps.db, q.name.text, if (q.schema) |s| s.text else null) orelse return null;
        const schema = catalog.schemaName(ps.db, tbl);
        const entries = catalog.entries(ps.db, t.arena(), schema, tbl.name) catch &.{};
        var cols: std.ArrayList(Col) = .empty;
        for (tbl.cols) |*c| {
            var jt: JT = .other;
            for (entries) |en| if (std.mem.eql(u8, en.key, catalog.Key.decl_type) and std.ascii.eqlIgnoreCase(en.col, c.name())) {
                jt = declType(en.value);
            };
            try cols.append(t.arena(), .{ .name = c.name(), .jt = jt, .insertable = !c.col_flags.intersects(int.COLFLAG.NOINSERT) });
        }
        return cols.items;
    }

    fn tableScope(t: *T, q: tree.QName, name: []const u8, parent: ?*const Scope) Error!*const Scope {
        const items = try t.arena().alloc(Item, 1);
        items[0] = .{ .name = name, .cols = try t.tableCols(q) };
        return tree.new(t.arena(), Scope, .{ .parent = parent, .items = items });
    }

    /// The items of FROM, appended to `items` (ON conditions typed as
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
                        for (srf.cols, cs) |sc_, *c| c.* = .{ .name = sc_.name, .jt = if (sc_.cast) |ty| typeNameType(ty) else .other, .srf = sc_ };
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

    /// Type a query; its result columns.
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
            var jt: JT = .other;
            if (item.expr.kind == .integer) {
                const k = std.fmt.parseInt(usize, item.expr.kind.integer, 10) catch 0;
                if (k >= 1 and k <= cols.len) jt = cols[k - 1].jt;
            } else if (item.expr.kind == .column and item.expr.kind.column.len == 1 and resultCol(cols, item.expr.kind.column[0].text) != null) {
                const rc = resultCol(cols, item.expr.kind.column[0].text).?;
                jt = rc.jt;
                // A name that is not an alias is the column (qualified
                // next to json_each()).
                if (!rc.aliased) _ = try t.expr(item.expr, core_scope orelse sc);
            } else jt = try t.expr(item.expr, core_scope orelse sc);
            if (jt == .jsonb) item.expr = try tree.expr(t.arena(), item.expr.pos, item.expr.end, .{ .collate = .{ .e = item.expr, .collation = "xq_pg_jsonb" } });
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
                    const jt = try t.expr(e, sc);
                    if (r == 0) try cols.append(t.arena(), .{ .name = try std.fmt.allocPrint(t.arena(), "column{d}", .{i + 1}), .jt = jt });
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
                const jt = try t.expr(x.e, sc);
                const name = if (x.alias) |a| a.text else if (x.name) |n| n else if (was) |w| w else "?column?";
                // A json_each() column a reference became keeps the
                // reference's name (SQLite would name it after json_each's
                // column or the expression).
                if (x.alias == null and (x.e.kind != .column and was != null or x.e.kind == .column and t.p.srf_refs.contains(x.e))) x.alias = .{ .text = name, .pos = x.e.pos };
                try cols.append(t.arena(), .{ .name = name, .jt = jt, .aliased = aliased });
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
                    if (col.jt != .other) try t.jts.put(t.arena(), e, col.jt);
                    try out.append(t.arena(), .{ .expr = .{ .e = e, .alias = .{ .text = col.name, .pos = pos } } });
                }
            }
            if (!expanded) return;
        }
        c.cols = out.items;
    }

    fn window(t: *T, w: *tree.WindowSpec, sc: *const Scope) Error!void {
        for (w.partition) |e| _ = try t.expr(e, sc);
        for (w.order_by) |*item| {
            if (try t.expr(item.expr, sc) == .jsonb) item.expr = try tree.expr(t.arena(), item.expr.pos, item.expr.end, .{ .collate = .{ .e = item.expr, .collation = "xq_pg_jsonb" } });
        }
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
        if (ins.source) |src| try t.coerceInsert(ins, src, cols);
        const tsc = try t.tableScope(ins.table, target_name, null);
        if (ins.on_conflict) |oc| {
            const items = try t.arena().alloc(Item, 2);
            items[0] = tsc.items[0];
            items[1] = .{ .name = "excluded", .cols = cols };
            const csc = try tree.new(t.arena(), Scope, .{ .items = items });
            for (oc.target) |e| _ = try t.expr(e, csc);
            if (oc.target_where) |w| _ = try t.expr(w, csc);
            if (oc.update) |items_| try t.sets(items_, cols, csc);
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
            try t.sets(u.sets, cs, sc);
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

    fn sets(t: *T, items: []tree.SetItem, cols: []const Col, sc: *const Scope) Error!void {
        for (items) |*s| {
            const jt = try t.expr(s.value, sc);
            if (s.multi) continue;
            const col = findCol(cols, s.cols[0].text) orelse continue;
            s.value = try t.stored(s.value, jt, col.jt);
        }
    }

    /// `v` (of type `jt`) as stored into a column of type `col`.
    fn stored(t: *T, v: *Expr, jt: JT, col: JT) Error!*Expr {
        if (v.kind == .default or v.kind == .null) return v;
        switch (col) {
            .jsonb => {
                if (jt == .jsonb and v.kind == .func) return v;
                return t.cast(v, "jsonb");
            },
            .json => {
                if ((jt == .json or jt == .jsonb) and v.kind == .func) return v;
                return t.cast(v, "json");
            },
            else => return v,
        }
    }

    /// The values of an INSERT into json/jsonb columns: VALUES items in
    /// place, a query's result columns, else the query wrapped as
    /// SELECT stored(c1) ... FROM (query) AS xq_src(c1, ...).
    fn coerceInsert(t: *T, ins: *tree.Insert, src: *tree.Select, cols: []const Col) Error!void {
        var targets: std.ArrayList(?Col) = .empty;
        if (ins.cols.len > 0) {
            for (ins.cols) |n| try targets.append(t.arena(), findCol(cols, n.text));
        } else for (cols) |c| if (c.insertable) try targets.append(t.arena(), c);
        var any = false;
        for (targets.items) |c| if (c != null and (c.?.jt == .json or c.?.jt == .jsonb)) {
            any = true;
        };
        if (!any) return;
        const colType = struct {
            fn f(ts: []const ?Col, i: usize) JT {
                if (i >= ts.len) return .other;
                return if (ts[i]) |c| c.jt else .other;
            }
        }.f;
        if (src.body.* == .values and src.with == null and src.order_by.len == 0 and src.limit == null) {
            for (src.body.values) |row| for (row, 0..) |*item, i| {
                item.* = try t.stored(item.*, t.jts.get(item.*) orelse .other, colType(targets.items, i));
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
                for (c.cols, 0..) |*rc, i| rc.expr.e = try t.stored(rc.expr.e, t.jts.get(rc.expr.e) orelse .other, colType(targets.items, i));
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
            rc.* = .{ .expr = .{ .e = try t.stored(col, .other, colType(targets.items, i)) } };
        }
        var from = try t.arena().alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = src }, .alias = .{ .name = .{ .text = "xq_src", .pos = src.pos }, .cols = names } };
        const c = try tree.new(t.arena(), tree.Core, .{ .cols = rcs, .from = from, .pos = src.pos });
        ins.source = try tree.new(t.arena(), tree.Select, .{ .body = try tree.new(t.arena(), tree.Body, .{ .core = c }), .pos = src.pos });
    }

    fn createTable(t: *T, ct: *tree.CreateTable) Error!void {
        if (ct.as_select) |s| _ = try t.select(s, null);
        var cols: std.ArrayList(Col) = .empty;
        for (ct.columns) |c| try cols.append(t.arena(), .{ .name = c.name.text, .jt = if (c.decl_type) |d| declType(d) else .other });
        const items = try t.arena().alloc(Item, 1);
        items[0] = .{ .name = ct.name.name.text, .cols = cols.items };
        const sc = try tree.new(t.arena(), Scope, .{ .items = items });
        for (ct.columns) |c| for (c.constraints) |cc| switch (cc.kind) {
            .check => |e| _ = try t.expr(e, sc),
            .generated => |g| _ = try t.expr(g.e, sc),
            else => {},
        };
        for (ct.constraints) |tc| if (tc.kind == .check) {
            _ = try t.expr(tc.kind.check, sc);
        };
    }

    // ======================================================= expressions

    fn expr(t: *T, e: *Expr, sc: ?*const Scope) Error!JT {
        const jt = try t.exprInner(e, sc);
        if (jt != .other) try t.jts.put(t.arena(), e, jt);
        return jt;
    }

    fn exprInner(t: *T, e: *Expr, sc: ?*const Scope) Error!JT {
        switch (e.kind) {
            .column => |names| return t.column(e, names, sc),
            .string, .null, .param, .named_param => return .unknown,
            .boolean => return .boolean,
            .integer, .float, .blob, .default, .identity_default => return .other,
            .cast => |c| {
                _ = try t.expr(c.e, sc);
                return castType(c.target_type);
            },
            .func => |f| return t.func(e, f, sc),
            .concat => |c| {
                var jts: [2]JT = .{ .other, .other };
                for (c.args, 0..) |a, i| {
                    const jt = try t.expr(a, sc);
                    if (i < 2) jts[i] = jt;
                }
                if (c.args.len == 2 and c.null_policy == .propagate) {
                    const l = jts[0];
                    const r = jts[1];
                    if (l == .json and r == .json) return t.p.failState(e.pos, .of("42883"), "operator does not exist: json || json", .{});
                    if ((l == .jsonb and (r == .jsonb or r == .unknown)) or (r == .jsonb and l == .unknown)) {
                        e.kind = .{ .func = try t.newFunc(e.pos, "xq_pg_jsonb_concat", c.args) };
                        return .jsonb;
                    }
                }
                return .other;
            },
            .binary => |b| {
                const l = try t.expr(b.l, sc);
                const r = try t.expr(b.r, sc);
                if (b.op == .sub and l == .jsonb) {
                    const name = if (r == .text_array or r == .num_array) "xq_pg_jsonb_delete_keys" else "xq_pg_jsonb_delete";
                    e.kind = .{ .func = try t.newFunc(e.pos, name, try t.list(&.{ b.l, b.r })) };
                    return .jsonb;
                }
                return if (b.op == .@"and" or b.op == .@"or") .boolean else .other;
            },
            .compare => |*c| {
                const l = try t.expr(c.l, sc);
                const r = try t.expr(c.r, sc);
                if (l == .json and r == .json and c.op != .is and c.op != .is_not) return t.p.failState(e.pos, .of("42883"), "operator does not exist: json {s} json", .{cmpText(c.op)});
                if ((l == .jsonb and (r == .jsonb or r == .unknown)) or (r == .jsonb and l == .unknown)) {
                    if (l == .unknown and c.l.kind == .string) c.l = try t.cast(c.l, "jsonb");
                    if (r == .unknown and c.r.kind == .string) c.r = try t.cast(c.r, "jsonb");
                    c.collation = "xq_pg_jsonb";
                }
                return .boolean;
            },
            .unary => |u| {
                _ = try t.expr(u.e, sc);
                return if (u.op == .not) .boolean else .other;
            },
            .div => |d| {
                _ = try t.expr(d.l, sc);
                _ = try t.expr(d.r, sc);
                return .other;
            },
            .case => |c| {
                if (c.operand) |o| _ = try t.expr(o, sc);
                var jt: JT = .unknown;
                for (c.whens, 0..) |w, i| {
                    const x = try t.expr(w, sc);
                    if (i % 2 == 1 and jt == .unknown) jt = x;
                }
                if (c.@"else") |x| {
                    const y = try t.expr(x, sc);
                    if (jt == .unknown) jt = y;
                }
                return if (jt == .row) .other else jt;
            },
            .in_list => |x| {
                _ = try t.expr(x.e, sc);
                for (x.items) |i| _ = try t.expr(i, sc);
                return .boolean;
            },
            .in_select => |x| {
                _ = try t.expr(x.e, sc);
                _ = try t.select(x.sel, sc);
                return .boolean;
            },
            .exists => |s| {
                _ = try t.select(s, sc);
                return .boolean;
            },
            .subquery => |s| {
                const cols = try t.select(s, sc);
                return if (cols.len > 0) cols[0].jt else .other;
            },
            .between => |x| {
                _ = try t.expr(x.e, sc);
                _ = try t.expr(x.lo, sc);
                _ = try t.expr(x.hi, sc);
                return .boolean;
            },
            .like => |x| {
                _ = try t.expr(x.e, sc);
                _ = try t.expr(x.pat, sc);
                if (x.escape == .expr) _ = try t.expr(x.escape.expr, sc);
                return .boolean;
            },
            .is_null => |x| {
                _ = try t.expr(x.e, sc);
                return .boolean;
            },
            .is_bool => |x| {
                _ = try t.expr(x.e, sc);
                return .boolean;
            },
            .row => |items| {
                for (items) |i| _ = try t.expr(i, sc);
                return .other;
            },
            .collate => |x| return t.expr(x.e, sc),
            .coerce => |x| {
                _ = try t.expr(x.e, sc);
                return .other;
            },
        }
    }

    /// A column reference: its type; a column of a JSON set-returning
    /// function becomes its expression; `t` naming a FROM item is a row.
    fn column(t: *T, e: *Expr, names: []const Name, sc_opt: ?*const Scope) Error!JT {
        const sc = sc_opt orelse return .other;
        if (t.p.srf_refs.contains(e)) return .other;
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
                return col.jt;
            }
        }
        // A FROM item as a value: its row.
        if (names.len == 1 and findItem(sc, col_name) != null) return .row;
        return .other;
    }

    fn func(t: *T, e: *Expr, f: *tree.Func, sc: ?*const Scope) Error!JT {
        const n = f.name.text;
        const builder = builderArgs(n);
        for (f.args, 0..) |*a, i| {
            const jt = try t.expr(a.*, sc);
            if (builder.takes(i, f.args.len)) a.* = try t.wrapArg(a.*, jt, sc);
        }
        if (f.filter) |x| _ = try t.expr(x, sc);
        for (f.order_by) |*item| {
            if (try t.expr(item.expr, sc) == .jsonb) item.expr = try tree.expr(t.arena(), item.expr.pos, item.expr.end, .{ .collate = .{ .e = item.expr, .collation = "xq_pg_jsonb" } });
        }
        if (f.over) |w| if (sc) |s| try t.window(w, s);
        const eq = std.mem.eql;
        // Operators of jsonb operands.
        const variants = [_]struct { []const u8, []const u8 }{
            .{ "xq_pg_json_get", "xq_pg_jsonb_get" },   .{ "xq_pg_json_get_text", "xq_pg_jsonb_get_text" },
            .{ "xq_pg_json_path", "xq_pg_jsonb_path" }, .{ "xq_pg_json_path_text", "xq_pg_jsonb_path_text" },
        };
        for (variants) |v| if (eq(u8, n, v[0])) {
            const left = t.jts.get(f.args[0]) orelse .other;
            if (left == .jsonb) f.name.text = v[1];
            if (std.mem.endsWith(u8, n, "_text")) return .other;
            return if (left == .jsonb) .jsonb else .json;
        };
        if (eq(u8, n, "row_to_json") and f.args.len == 1 and f.args[0].kind == .func and eq(u8, f.args[0].kind.func.name.text, "xq_pg_row_json")) {
            e.kind = f.args[0].kind;
            return .json;
        }
        if ((eq(u8, n, "json_agg") or eq(u8, n, "json_arrayagg")) and f.args.len == 1 and f.args[0].kind == .func and
            (eq(u8, f.args[0].kind.func.name.text, "xq_pg_row_json") or eq(u8, f.args[0].kind.func.name.text, "xq_pg_array_to_json")))
        {
            // json_agg() of rows or arrays: a line break between them.
            if (eq(u8, n, "json_agg")) {
                f.name.text = "xq_pg_json_agg_rows";
                f.dialect = null;
            }
            return .json;
        }
        if (eq(u8, n, "array_to_json") and f.args.len >= 1) {
            const jt = t.jts.get(f.args[0]) orelse .other;
            if (jt == .text_array or jt == .num_array) {
                const pretty = if (f.args.len > 1) f.args[1] else try tree.expr(t.arena(), e.pos, e.pos, .{ .integer = "0" });
                const num = try tree.expr(t.arena(), e.pos, e.pos, .{ .integer = if (jt == .num_array) "1" else "0" });
                f.name.text = "xq_pg_array_to_json";
                f.dialect = null;
                f.args = try t.list(&.{ f.args[0], pretty, num });
            }
            return .json;
        }
        if (eq(u8, n, "xq_pg_array")) {
            for (f.args) |a| {
                const k = numeric(a);
                if (!k) return .text_array;
            }
            return if (f.args.len > 0) .num_array else .text_array;
        }
        if (eq(u8, n, "xq_pg_json_ctor_object") or eq(u8, n, "xq_pg_json_ctor_array") or eq(u8, n, "xq_pg_json_arrayagg") or eq(u8, n, "xq_pg_json_objectagg")) {
            const flags = f.args[if (eq(u8, n, "xq_pg_json_arrayagg")) 1 else if (eq(u8, n, "xq_pg_json_objectagg")) 2 else 0];
            if (flags.kind == .integer and (std.fmt.parseInt(i64, flags.kind.integer, 10) catch 0) & 1 != 0) return .jsonb;
            return .json;
        }
        if (eq(u8, n, "coalesce") or eq(u8, n, "nullif") or eq(u8, n, "greatest") or eq(u8, n, "least") or eq(u8, n, "ifnull")) {
            for (f.args) |a| {
                const jt = t.jts.get(a) orelse .other;
                if (jt != .unknown) return jt;
            }
            return .other;
        }
        return funcType(n);
    }

    /// An argument of a function that builds JSON, so that the function
    /// sees what it is (jfuncs.zig).
    fn wrapArg(t: *T, a: *Expr, jt: JT, sc: ?*const Scope) Error!*Expr {
        switch (jt) {
            .json, .jsonb => {
                if (a.kind == .func and funcType(a.kind.func.name.text) != .other) return a;
                if (a.kind == .cast and castType(a.kind.cast.target_type) == jt) return a;
                return t.cast(a, if (jt == .jsonb) "jsonb" else "json");
            },
            .boolean => return t.call(a, "xq_pg_json_bool", &.{a}),
            .text_array, .num_array => {
                const zero = try tree.expr(t.arena(), a.pos, a.pos, .{ .integer = "0" });
                const num = try tree.expr(t.arena(), a.pos, a.pos, .{ .integer = if (jt == .num_array) "1" else "0" });
                return t.call(a, "xq_pg_array_to_json", &.{ a, zero, num });
            },
            .row => return t.rowJson(a, sc.?),
            else => return a,
        }
    }

    /// xq_pg_row_json('a', t.a, ...) of FROM item `t`.
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
            try args.append(t.arena(), try t.wrapArg(v, col.jt, sc));
        }
        return t.call(a, "xq_pg_row_json", args.items);
    }

    // ========================================================== builders

    fn list(t: *T, items: []const *Expr) Error![]*Expr {
        return t.arena().dupe(*Expr, items);
    }

    fn newFunc(t: *T, pos: u32, name: []const u8, args: []*Expr) Error!*tree.Func {
        return tree.new(t.arena(), tree.Func, .{ .name = .{ .text = name, .pos = pos }, .args = args });
    }

    fn call(t: *T, at: *const Expr, name: []const u8, args: []const *Expr) Error!*Expr {
        const f = try t.newFunc(at.pos, name, try t.list(args));
        return tree.expr(t.arena(), at.pos, at.end, .{ .func = f });
    }

    /// `v::json` / `v::jsonb`.
    fn cast(t: *T, v: *Expr, ty: []const u8) Error!*Expr {
        const f: []const u8 = if (std.mem.eql(u8, ty, "jsonb")) "xq_pg_jsonb" else "xq_pg_json";
        const x = try tree.expr(t.arena(), v.pos, v.end, .{ .cast = .{ .e = v, .target_type = ty, .mode = .{ .func = f } } });
        try t.jts.put(t.arena(), x, castType(ty));
        return x;
    }
};

// ================================================================ tables

fn findCol(cols: []const Col, name: []const u8) ?Col {
    for (cols) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

fn resultCol(cols: []const Col, name: []const u8) ?Col {
    return findCol(cols, name);
}

fn findItem(sc: *const Scope, name: []const u8) ?Item {
    var s: ?*const Scope = sc;
    while (s) |x| : (s = x.parent) {
        for (x.items) |it| if (std.ascii.eqlIgnoreCase(it.name, name)) return it;
    }
    return null;
}

/// The type of a declared (catalog) type.
fn declType(d: []const u8) JT {
    if (std.mem.eql(u8, d, "jsonb")) return .jsonb;
    if (std.mem.eql(u8, d, "json")) return .json;
    if (std.mem.eql(u8, d, "boolean")) return .boolean;
    return .other;
}

fn castType(target: []const u8) JT {
    if (std.mem.eql(u8, target, "jsonb")) return .jsonb;
    if (std.mem.eql(u8, target, "json")) return .json;
    if (std.mem.eql(u8, target, "boolean")) return .boolean;
    if (std.mem.endsWith(u8, target, "[]")) return if (types.isNumeric(target[0 .. target.len - 2])) .num_array else .text_array;
    return .other;
}

fn typeNameType(ty: types.TypeName) JT {
    if (ty.array) return if (types.isNumeric(ty.name)) .num_array else .text_array;
    return castType(ty.name);
}

fn cmpText(op: tree.CmpOp) []const u8 {
    return switch (op) {
        .eq => "=",
        .ne => "<>",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        else => "=",
    };
}

fn numeric(e: *const Expr) bool {
    return switch (e.kind) {
        .integer, .float => true,
        .unary => |u| (u.op == .neg or u.op == .plus) and numeric(u.e),
        else => false,
    };
}

/// The result type of a function by its name.
fn funcType(n: []const u8) JT {
    const map = std.StaticStringMap(JT).initComptime(.{
        .{ "to_jsonb", .jsonb },                    .{ "jsonb_build_object", .jsonb },       .{ "jsonb_build_array", .jsonb },
        .{ "jsonb_object", .jsonb },                .{ "jsonb_agg", .jsonb },                .{ "jsonb_object_agg", .jsonb },
        .{ "jsonb_set", .jsonb },                   .{ "jsonb_set_lax", .jsonb },            .{ "jsonb_insert", .jsonb },
        .{ "jsonb_strip_nulls", .jsonb },           .{ "jsonb_extract_path", .jsonb },       .{ "jsonb_path_query_array", .jsonb },
        .{ "jsonb_path_query_first", .jsonb },      .{ "xq_pg_jsonb", .jsonb },              .{ "xq_pg_jsonb_get", .jsonb },
        .{ "xq_pg_jsonb_path", .jsonb },            .{ "xq_pg_jsonb_concat", .jsonb },       .{ "xq_pg_jsonb_delete", .jsonb },
        .{ "xq_pg_jsonb_delete_keys", .jsonb },     .{ "xq_pg_jsonb_delete_path", .jsonb },  .{ "to_json", .json },
        .{ "json_build_object", .json },            .{ "json_build_array", .json },          .{ "json_object", .json },
        .{ "json_agg", .json },                     .{ "json_object_agg", .json },           .{ "json_strip_nulls", .json },
        .{ "json_extract_path", .json },            .{ "row_to_json", .json },               .{ "array_to_json", .json },
        .{ "xq_pg_json", .json },                   .{ "xq_pg_json_get", .json },            .{ "xq_pg_json_path", .json },
        .{ "xq_pg_row_json", .json },               .{ "xq_pg_array_to_json", .json },       .{ "xq_pg_json_agg_rows", .json },
        .{ "xq_pg_json_bool", .json },              .{ "xq_pg_jsonb_contains", .boolean },   .{ "xq_pg_jsonb_exists", .boolean },
        .{ "xq_pg_jsonb_exists_any", .boolean },    .{ "xq_pg_jsonb_exists_all", .boolean }, .{ "xq_pg_jsonb_path_exists_op", .boolean },
        .{ "xq_pg_jsonb_path_match_op", .boolean }, .{ "jsonb_path_exists", .boolean },      .{ "jsonb_path_match", .boolean },
        .{ "xq_pg_is_json", .boolean },             .{ "xq_pg_bool", .boolean },             .{ "xq_like", .boolean },
        .{ "xq_ilike", .boolean },                  .{ "starts_with", .boolean },            .{ "xq_pg_text_array", .text_array },
    });
    return map.get(n) orelse .other;
}

/// Which arguments of a function are values it makes JSON of.
const Builder = enum {
    none,
    first,
    all,
    after_first,
    first_two,

    fn takes(b: Builder, i: usize, n: usize) bool {
        _ = n;
        return switch (b) {
            .none => false,
            .first => i == 0,
            .all => true,
            .after_first => i > 0,
            .first_two => i < 2,
        };
    }
};

fn builderArgs(n: []const u8) Builder {
    const map = std.StaticStringMap(Builder).initComptime(.{
        .{ "to_json", .first },                     .{ "to_jsonb", .first },            .{ "json_agg", .first },
        .{ "jsonb_agg", .first },                   .{ "xq_pg_json_agg_rows", .first }, .{ "row_to_json", .first },
        .{ "xq_pg_json_arrayagg", .first },         .{ "json_build_object", .all },     .{ "jsonb_build_object", .all },
        .{ "json_build_array", .all },              .{ "jsonb_build_array", .all },     .{ "xq_pg_json_ctor_object", .after_first },
        .{ "xq_pg_json_ctor_array", .after_first }, .{ "json_object_agg", .first_two }, .{ "jsonb_object_agg", .first_two },
        .{ "xq_pg_json_objectagg", .first_two },
    });
    return map.get(n) orelse .none;
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
