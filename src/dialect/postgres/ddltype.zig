//! The core's choices by the types of operands (overload.zig), brought
//! back to the tree of a statement whose text the schema keeps: a view, a
//! CHECK, a generated column, an index expression. Such text is SQLite's
//! and read in every dialect (and by sqlite3), so it must say the
//! functions PostgreSQL's operators chose (xq_pg_jsonb_get(), collation
//! xq_pg_jsonb ...), which the core only knows once names are resolved.
//!
//! A probe: the expressions of the statement are lowered (keeping where
//! each Expr comes from: lower.Origins), as a query (a CHECK's over a
//! subquery of NULLs of its table's declared types), and the query is
//! resolved, and so typed, in a Parse of its own that generates no code.
//! What the core changed is then done to the tree: a call another
//! function, an operator a call, an argument wrapped, a comparison's or
//! an ORDER BY's collation. The query of a CTE is resolved as a copy
//! where it is read, so it is probed on its own, as a subquery under the
//! CTEs it sees (a recursive one under itself).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const select_mod = @import("../../sql/select.zig");
const parser = @import("parser.zig");
const Children = @import("jtype.zig").Children;
const operators = @import("operators.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const IrExpr = int.Expr;
const TK = int.TK;

pub fn statement(ps: *Parser, stmt: tree.Stmt) Error!void {
    const p = ps.p orelse return;
    const a = ps.arena;
    switch (stmt) {
        .create_view => |v| try probe(p, ps.src, a, v.select, null),
        .create_table => |ct| {
            if (ct.as_select) |s| try probe(p, ps.src, a, s, null);
            var exprs: std.ArrayList(*Expr) = .empty;
            for (ct.columns) |c| for (c.constraints) |cc| switch (cc.kind) {
                .check => |e| try exprs.append(a, e),
                .generated => |g| try exprs.append(a, g.e),
                else => {},
            };
            for (ct.constraints) |tc| if (tc.kind == .check) try exprs.append(a, tc.kind.check);
            if (exprs.items.len == 0) return;
            // SELECT exprs FROM (SELECT NULL::type AS col ...) AS name.
            const cols = try a.alloc(tree.ResultCol, ct.columns.len);
            for (ct.columns, cols) |c, *rc| {
                const pos = c.name.pos;
                const null_ = try tree.expr(a, pos, pos, .null);
                const v = if (c.decl_type) |d| try tree.expr(a, pos, pos, .{ .cast = .{ .e = null_, .target_type = d, .mode = .{ .affinity = "TEXT" } } }) else null_;
                rc.* = .{ .expr = .{ .e = v, .alias = c.name } };
            }
            const inner = try selectOf(a, cols, &.{});
            const from = try a.alloc(tree.FromItem, 1);
            from[0] = .{ .source = .{ .subquery = inner }, .alias = .{ .name = ct.name.name } };
            try probe(p, ps.src, a, try selectOf(a, try resultCols(a, exprs.items), from), null);
        },
        .create_index => |ci| {
            var exprs: std.ArrayList(*Expr) = .empty;
            for (ci.items) |item| try exprs.append(a, item.expr);
            if (ci.where) |w| try exprs.append(a, w);
            const from = try a.alloc(tree.FromItem, 1);
            from[0] = .{ .source = .{ .table = .{ .schema = ci.name.schema, .name = ci.table } } };
            try probe(p, ps.src, a, try selectOf(a, try resultCols(a, exprs.items), from), null);
        },
        else => {},
    }
}

fn resultCols(a: std.mem.Allocator, exprs: []const *Expr) Error![]tree.ResultCol {
    const cols = try a.alloc(tree.ResultCol, exprs.len);
    for (exprs, cols) |e, *rc| rc.* = .{ .expr = .{ .e = e } };
    return cols;
}

fn selectOf(a: std.mem.Allocator, cols: []tree.ResultCol, from: []tree.FromItem) Error!*tree.Select {
    const c = try tree.new(a, tree.Core, .{ .cols = cols, .from = from });
    return tree.new(a, tree.Select, .{ .body = try tree.new(a, tree.Body, .{ .core = c }) });
}

/// Lower and resolve `s` in a Parse of its own (no code, no error, no
/// authorizer), then bring the choices of the core back to `s`'s tree.
fn probe(outer: *int.Parse, src: [:0]const u8, a: std.mem.Allocator, s: *tree.Select, own_with: ?*tree.With) Error!void {
    const db = outer.db;
    var q: int.Parse = .{ .db = db, .arena = outer.arena, .tail = outer.tail, .outer_parse = outer };
    defer build.releaseTableRefs(&q);
    const saved_auth = db.auth;
    db.auth = null;
    defer db.auth = saved_auth;
    const saved_parse = db.parse;
    db.parse = &q;
    defer db.parse = saved_parse;
    var origins: lower.Origins = .{};
    var l: lower.Lowerer = .init(&q, src);
    l.origins = &origins;
    const x = l.select(s) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed => return,
    };
    select_mod.selectPrep(&q, x, null);
    if (db.malloc_failed) return error.OutOfMemory;
    var b: Back = .{ .o = &origins, .a = a, .p = &q, .own_with = own_with };
    try b.select(s);
    // The query of a CTE is resolved as a copy where it is read: probed
    // on its own, as `WITH (the CTEs it sees) SELECT * FROM (query)`.
    for (b.ctes.items) |c| {
        const star = try a.alloc(tree.ResultCol, 1);
        star[0] = .{ .star = c.select.pos };
        const from = try a.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = c.select }, .alias = .{ .name = .{ .text = "xq_cte", .pos = c.select.pos } } };
        const sel = try selectOf(a, star, from);
        if (c.scope.len > 0) sel.with = try tree.new(a, tree.With, .{ .recursive = c.recursive, .ctes = c.scope });
        try probe(outer, src, a, sel, sel.with);
    }
}

/// Bring the core's choices back to the tree (probe()).
const Back = struct {
    o: *const lower.Origins,
    a: std.mem.Allocator,
    p: *int.Parse,
    /// The WITH of the query probed, whose CTEs are not (CteProbe).
    own_with: ?*tree.With,
    /// The CTEs in scope.
    scope: []tree.Cte = &.{},
    /// The queries of CTEs, to probe on their own.
    ctes: std.ArrayList(CteProbe) = .empty,

    const CteProbe = struct { select: *tree.Select, scope: []tree.Cte, recursive: bool };

    fn of(b: *const Back, e: *const Expr) ?*IrExpr {
        return b.o.exprs.get(e);
    }

    fn select(b: *Back, s: *tree.Select) Error!void {
        const outer = b.scope;
        defer b.scope = outer;
        if (s.with) |w| {
            if (w != b.own_with) for (w.ctes, 0..) |c, i| {
                const n = if (w.recursive) i + 1 else i;
                try b.ctes.append(b.a, .{ .select = c.select, .scope = try std.mem.concat(b.a, tree.Cte, &.{ outer, w.ctes[0..n] }), .recursive = w.recursive });
            };
            b.scope = try std.mem.concat(b.a, tree.Cte, &.{ outer, w.ctes });
        }
        try b.body(s.body);
        try b.sortList(s.order_by);
        if (s.limit) |x| try b.expr(x);
        if (s.offset) |x| try b.expr(x);
    }

    fn body(b: *Back, x: *tree.Body) Error!void {
        switch (x.*) {
            .core => |c| {
                try b.from(c.from);
                for (c.cols) |rc| if (rc == .expr) try b.expr(rc.expr.e);
                if (c.where) |w| try b.expr(w);
                for (c.group_by) |g| try b.expr(g);
                if (c.having) |h| try b.expr(h);
                for (c.windows) |w| try b.window(w.spec);
            },
            .values => |rows| for (rows) |row| for (row) |e| try b.expr(e),
            .compound => |c| {
                try b.body(c.left);
                try b.body(c.right);
            },
            .nested => |n| try b.select(n),
        }
    }

    fn from(b: *Back, items: []tree.FromItem) Error!void {
        for (items) |fi| {
            switch (fi.source) {
                .table => {},
                .subquery => |sub| try b.select(sub),
                .func => |f| for (f.args) |x| try b.expr(x),
                .nested => |inner| try b.from(inner),
            }
            if (fi.on) |on| try b.expr(on);
        }
    }

    fn window(b: *Back, w: *tree.WindowSpec) Error!void {
        for (w.partition) |e| try b.expr(e);
        try b.sortList(w.order_by);
    }

    /// An ORDER BY whose term the core sorts with jsonb's collation.
    fn sortList(b: *Back, items: []tree.SortItem) Error!void {
        for (items) |item| try b.expr(item.expr);
        if (items.len == 0) return;
        const list = b.o.sort_lists.get(items.ptr) orelse return;
        for (items, 0..) |*item, i| {
            if (i >= list.len()) break;
            const x = list.at(i).expr orelse continue;
            if (!isCollate(x) or item.expr.kind == .collate) continue;
            item.expr = try tree.expr(b.a, item.expr.pos, item.expr.end, .{ .collate = .{ .e = item.expr, .collation = collationOf(x) } });
        }
    }

    fn expr(b: *Back, e: *Expr) Error!void {
        switch (e.kind) {
            .func => |f| {
                for (f.args) |x| try b.expr(x);
                if (f.filter) |x| try b.expr(x);
                try b.sortList(f.order_by);
                if (f.over) |w| try b.window(w);
            },
            .in_select => |x| {
                try b.expr(x.e);
                try b.select(x.sel);
            },
            .exists, .subquery => |s| try b.select(s),
            else => {
                var it = Children.of(e);
                while (it.next()) |x| try b.expr(x);
            },
        }
        const x = b.of(e) orelse return;
        switch (e.kind) {
            .concat => |c| if (c.args.len == 2 and calls(x, "xq_pg_jsonb_concat")) {
                e.kind = .{ .func = try b.func(e.pos, x.token(), c.args) };
            },
            // An operator the table made a call (operators.zig, jsonb's
            // `-` of an operand of no type).
            .binary => |*bin| if (operatorCall(x)) {
                e.kind = .{ .func = try b.func(e.pos, x.token(), try b.a.dupe(*Expr, &.{ bin.l, bin.r })) };
            } else {
                try b.literalInput(&bin.l, x.left);
                try b.literalInput(&bin.r, x.right);
            },
            .div => |*d| if (operatorCall(x)) {
                e.kind = .{ .func = try b.func(e.pos, x.token(), try b.a.dupe(*Expr, &.{ d.l, d.r })) };
            } else {
                try b.literalInput(&d.l, x.left);
                try b.literalInput(&d.r, x.right);
            },
            .unary => |u| if (u.op == .neg and operatorCall(x)) {
                e.kind = .{ .func = try b.func(e.pos, x.token(), try b.a.dupe(*Expr, &.{u.e})) };
            },
            .compare => |*c| if (c.collation == null) {
                switch (x.op) {
                    TK.EQ, TK.NE, TK.LT, TK.LE, TK.GT, TK.GE, TK.IS, TK.ISNOT => {},
                    else => return,
                }
                const l = x.left orelse return;
                if (!isCollate(l)) return;
                c.collation = collationOf(l);
                if (!std.mem.eql(u8, c.collation.?, jsonb_collation)) return;
                if (c.l.kind == .string) if (l.left) |w| if (isCall(w)) {
                    c.l = try b.jsonb(c.l);
                };
                if (c.r.kind == .string) if (x.right) |w| if (isCall(w)) {
                    c.r = try b.jsonb(c.r);
                };
            },
            .func => |f| try b.call(f, x),
            else => {},
        }
    }

    /// A string literal operand `t` of an operator the core read as an
    /// integer (`w`: xq_pg_int4('1')): that cast.
    fn literalInput(b: *Back, t: **Expr, w_: ?*IrExpr) Error!void {
        const w = w_ orelse return;
        if (t.*.kind != .string or !isCall(w)) return;
        const name = w.token();
        const list = w.x.list orelse return;
        if (list.len() != 1 or list.at(0).expr != b.of(t.*)) return;
        const types = [_]struct { []const u8, []const u8 }{ .{ "xq_pg_int2", "smallint" }, .{ "xq_pg_int4", "integer" }, .{ "xq_pg_int8", "bigint" } };
        for (types) |ty| if (std.mem.eql(u8, ty[0], name)) {
            t.* = try tree.expr(b.a, t.*.pos, t.*.end, .{ .cast = .{ .e = t.*, .target_type = ty[1], .mode = .{ .func = ty[0] } } });
        };
    }

    /// A call: another function, wrapped arguments, more arguments.
    fn call(b: *Back, f: *tree.Func, x: *IrExpr) Error!void {
        if (!isCall(x)) return;
        const want = lower.functionName(b.p, f.name.text, f.dialect, false) catch return error.OutOfMemory;
        if (!std.ascii.eqlIgnoreCase(want, x.token()) and renames.has(x.token())) {
            f.name.text = x.token();
            f.dialect = null;
        }
        const list = x.x.list orelse return;
        const items = list.slice();
        for (f.args, 0..) |*arg, i| {
            if (i >= items.len) break;
            const w = items[i].expr orelse continue;
            const mine = b.of(arg.*) orelse continue;
            if (w == mine or !isCall(w)) continue;
            const wl = w.x.list orelse continue;
            if (wl.len() == 0 or wl.at(0).expr != mine) continue;
            // Wrapped: name(arg, constants ...).
            const name = w.token();
            if (wl.len() == 1 and (std.mem.eql(u8, name, "xq_pg_json") or std.mem.eql(u8, name, "xq_pg_jsonb"))) {
                arg.* = try tree.expr(b.a, arg.*.pos, arg.*.end, .{ .cast = .{ .e = arg.*, .target_type = name["xq_pg_".len..], .mode = .{ .func = name } } });
                continue;
            }
            var args: std.ArrayList(*Expr) = .empty;
            try args.append(b.a, arg.*);
            for (wl.slice()[1..]) |c| try args.append(b.a, try b.constant(arg.*, c.expr.?) orelse continue);
            arg.* = try tree.expr(b.a, arg.*.pos, arg.*.end, .{ .func = try b.func(arg.*.pos, name, args.items) });
        }
        // Arguments the core added (array_to_json()'s).
        if (items.len > f.args.len and f.args.len > 0 and calls(x, "xq_pg_array_to_json")) {
            var args: std.ArrayList(*Expr) = .empty;
            try args.appendSlice(b.a, f.args);
            for (items[f.args.len..]) |c| try args.append(b.a, try b.constant(f.args[0], c.expr.?) orelse return);
            f.args = args.items;
        }
    }

    /// The tree of an integer constant the core added, null for another
    /// Expr.
    fn constant(b: *Back, at: *const Expr, c: *const IrExpr) Error!?*Expr {
        if (c.op != TK.INTEGER or !c.flags.IntValue) return null;
        return try tree.expr(b.a, at.pos, at.pos, .{ .integer = try std.fmt.allocPrint(b.a, "{d}", .{c.u.value}) });
    }

    fn func(b: *Back, pos: u32, name: []const u8, args: []*Expr) Error!*tree.Func {
        return tree.new(b.a, tree.Func, .{ .name = .{ .text = try b.a.dupe(u8, name), .pos = pos }, .args = args });
    }

    /// `v::jsonb`.
    fn jsonb(b: *Back, v: *Expr) Error!*Expr {
        return tree.expr(b.a, v.pos, v.end, .{ .cast = .{ .e = v, .target_type = "jsonb", .mode = .{ .func = "xq_pg_jsonb" } } });
    }
};

const jsonb_collation = "xq_pg_jsonb";

/// The functions overload.zig calls in the place of another.
const renames = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_jsonb_get"},       .{"xq_pg_jsonb_get_text"}, .{"xq_pg_jsonb_path"},
    .{"xq_pg_jsonb_path_text"}, .{"xq_pg_json_agg_rows"},  .{"xq_pg_array_to_json"},
});

const interval_collation = "xq_pg_interval";

/// Whether `x` is the COLLATE of a type's order overload.zig chose
/// (jsonb's, intervals').
fn isCollate(x: *const IrExpr) bool {
    return x.op == TK.COLLATE and (std.ascii.eqlIgnoreCase(x.token(), jsonb_collation) or std.ascii.eqlIgnoreCase(x.token(), interval_collation));
}

fn collationOf(x: *const IrExpr) []const u8 {
    return if (std.ascii.eqlIgnoreCase(x.token(), interval_collation)) interval_collation else jsonb_collation;
}

fn isCall(x: *const IrExpr) bool {
    return (x.op == TK.FUNCTION or x.op == TK.AGG_FUNCTION) and x.useUToken() and x.useXList();
}

/// Whether `x` is the call of an operator's function (operators.zig).
fn operatorCall(x: *const IrExpr) bool {
    if (!isCall(x)) return false;
    var buf: [64]u8 = undefined;
    const z = x.token();
    if (z.len > buf.len) return false;
    return operators.isFunction(std.ascii.lowerString(&buf, z));
}

fn calls(x: *const IrExpr, name: []const u8) bool {
    return isCall(x) and std.ascii.eqlIgnoreCase(x.token(), name);
}
