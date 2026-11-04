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
//! an ORDER BY's collation, an Expr wrapped in place (a numeric's
//! xq_dec_key(x) ..., overload.zig's wrapIn()) or a numeric literal read
//! as text. The query of a CTE is resolved as a copy
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
const typing = @import("../../sql/typing.zig");
const util = @import("../../sql/util.zig");
const integer = @import("integer.zig");
const overload = @import("overload.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const IrExpr = int.Expr;
const TK = int.TK;

pub fn statement(ps: *Parser, stmt: tree.Stmt) Error!void {
    const p = ps.p orelse return;
    const a = ps.arena;
    switch (stmt) {
        .create_view => |v| try probe(p, ps.c.sql, a, v.select, null),
        .create_table => |ct| {
            if (ct.as_select) |s| try probe(p, ps.c.sql, a, s, null);
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
                // (Of the column's storage if a BLOB: a uuid's 16 bytes,
                // which overload.zig tells from an older column's text.)
                const aff = if (c.type) |t| (if (std.mem.eql(u8, t, "BLOB")) "BLOB" else "TEXT") else "TEXT";
                const v = if (c.decl_type) |d| try tree.expr(a, pos, pos, .{ .cast = .{ .e = null_, .target_type = d, .mode = .{ .affinity = aff } } }) else null_;
                rc.* = .{ .expr = .{ .e = v, .alias = c.name } };
            }
            const inner = try selectOf(a, cols, &.{});
            const from = try a.alloc(tree.FromItem, 1);
            from[0] = .{ .source = .{ .subquery = inner }, .alias = .{ .name = ct.name.name } };
            try probe(p, ps.c.sql, a, try selectOf(a, try resultCols(a, exprs.items), from), null);
        },
        .create_index => |ci| {
            var exprs: std.ArrayList(*Expr) = .empty;
            for (ci.items) |item| try exprs.append(a, item.expr);
            if (ci.where) |w| try exprs.append(a, w);
            const from = try a.alloc(tree.FromItem, 1);
            from[0] = .{ .source = .{ .table = .{ .schema = ci.name.schema, .name = ci.table } } };
            try probeKeyed(p, ps.c.sql, a, try selectOf(a, try resultCols(a, exprs.items), from), exprs.items[0..ci.items.len]);
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
    return probeWith(outer, src, a, s, own_with, &.{});
}

/// probe() of the expressions of an index (`keyed`, of `s`).
fn probeKeyed(outer: *int.Parse, src: [:0]const u8, a: std.mem.Allocator, s: *tree.Select, keyed: []const *Expr) Error!void {
    return probeWith(outer, src, a, s, null, keyed);
}

fn probeWith(outer: *int.Parse, src: [:0]const u8, a: std.mem.Allocator, s: *tree.Select, own_with: ?*tree.With, keyed: []const *Expr) Error!void {
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
    var b: Back = .{ .o = &origins, .a = a, .p = &q, .outer = outer, .own_with = own_with };
    try b.select(s);
    // A string literal the probe's core could not read as the boolean it
    // met (`coalesce(b, 'maybe')`, `VALUES (true), ('bad')`): the
    // statement's error, at the literal, as PostgreSQL's CREATE VIEW and
    // CHECK fail.
    if (q.n_err > 0 and outer.n_err == 0) if (q.err_msg) |m| if (std.mem.startsWith(u8, m, "invalid input syntax for type boolean")) {
        const at = db.err_byte_offset;
        util.errorMsgState(outer, null, q.err_state, "{s}", .{m});
        db.err_byte_offset = at;
    };
    // The numeric expressions of an index: their keys without a display
    // scale (xq_dec_key()), as a comparison compares them, so that the
    // query's `a + b = 1` is the index's expression.
    for (keyed) |e| {
        const ix = b.of(e) orelse continue;
        if (ix.op == TK.COLUMN or typing.typeOf(db, ix.xq_type).logical != .numeric) continue;
        if (isCall(ix) and std.ascii.eqlIgnoreCase(ix.token(), "xq_dec_key")) continue;
        const inner = try a.create(Expr);
        inner.* = e.*;
        e.kind = .{ .func = try b.func(e.pos, "xq_dec_key", try a.dupe(*Expr, &.{inner})) };
    }
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
    /// The statement's Parse, which a literal no value of its type fails
    /// (boolLiteral()).
    outer: *int.Parse,
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
        try b.sortList(s.order_by, if (s.body.* == .core) s.body.core.cols else &.{});
        if (s.limit) |x| try b.expr(x);
        if (s.offset) |x| try b.expr(x);
    }

    // ------------------------------------------------- interval BLOB
    // overload.zig's choices of intervals: keys, bounds and text.

    /// Whether `e`'s Expr in the probe is an interval.
    fn isInterval(b: *const Back, e: *const Expr) bool {
        const x = b.of(e) orelse return false;
        return typing.typeOf(b.p.db, x.xq_type).logical == .interval;
    }

    /// `name(e)`.
    fn wrap(b: *Back, e: *Expr, name: []const u8) Error!*Expr {
        return tree.expr(b.a, e.pos, e.end, .{ .func = try b.func(e.pos, name, try b.a.dupe(*Expr, &.{e})) });
    }

    /// Operand `t`, which the core wrapped in an interval's key, bound or
    /// text (`w`: xq_pg_iv_key(its Expr)): wrapped the same; whether it
    /// was.
    fn wrapped(b: *Back, t: **Expr, w_: ?*IrExpr) Error!bool {
        const w = w_ orelse return false;
        if (!isCall(w)) return false;
        const names = [_][]const u8{ "xq_pg_iv_key", "xq_pg_iv_high", "xq_pg_iv_text", "xq_pg_iv_out" };
        const name = for (names) |n| {
            if (std.ascii.eqlIgnoreCase(w.token(), n)) break n;
        } else return false;
        const list = w.x.list orelse return false;
        if (list.len() != 1) return false;
        // (+a of x IN (a).)
        var arg = list.at(0).expr orelse return false;
        if (arg.op == TK.UPLUS and arg.left != null and arg != b.of(t.*)) arg = arg.left.?;
        if (arg != b.of(t.*)) return false;
        t.* = try b.wrap(t.*, name);
        return true;
    }

    /// The GROUP BY of `c` by the keys of intervals (typing.groupBy()): a
    /// term that is an interval its key; a DISTINCT of an interval
    /// column a GROUP BY of the columns (only for a list of plain
    /// expressions: one with a call may be an aggregate).
    fn groupKeys(b: *Back, c: *tree.Core) Error!void {
        if (c.group_by.len > 0) {
            for (c.group_by) |*g| if (b.isInterval(g.*)) {
                g.* = try b.wrap(g.*, "xq_pg_iv_key");
            };
            return;
        }
        if (!c.distinct) return;
        var any = false;
        for (c.cols) |rc| {
            if (rc != .expr) return;
            switch (rc.expr.e.kind) {
                .func, .subquery, .exists => return,
                else => {},
            }
            if (b.isInterval(rc.expr.e)) any = true;
        }
        if (!any) return;
        const gb = try b.a.alloc(*Expr, c.cols.len);
        for (c.cols, gb) |rc, *g| g.* = if (b.isInterval(rc.expr.e)) try b.wrap(rc.expr.e, "xq_pg_iv_key") else rc.expr.e;
        c.group_by = gb;
        c.distinct = false;
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
                try b.groupKeys(c);
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
                .subquery => |sub| {
                    try b.select(sub);
                    // `(s) AS x(a, b)` is a CTE (lower.zig's
                    // renameColumns()), resolved as a copy where it is
                    // read: probed on its own, as a CTE's query.
                    if (fi.alias) |al| if (al.cols.len > 0) try b.ctes.append(b.a, .{ .select = sub, .scope = b.scope, .recursive = false });
                },
                .func => |f| for (f.args) |x| try b.expr(x),
                .nested => |inner| try b.from(inner),
            }
            if (fi.on) |on| try b.expr(on);
        }
    }

    fn window(b: *Back, w: *tree.WindowSpec) Error!void {
        for (w.partition) |e| try b.expr(e);
        // An interval partitions by its key (typing.keyList()).
        for (w.partition) |*e| if (b.isInterval(e.*)) {
            e.* = try b.wrap(e.*, "xq_pg_iv_key");
        };
        try b.sortList(w.order_by, &.{});
    }

    /// An ORDER BY whose term the core sorts with its type's collation
    /// or by jsonb's key (`cols`: the result columns of a query, which a
    /// term may name by number or alias).
    fn sortList(b: *Back, items: []tree.SortItem, cols: []const tree.ResultCol) Error!void {
        for (items) |item| try b.expr(item.expr);
        if (items.len == 0) return;
        const list = b.o.sort_lists.get(items.ptr) orelse return;
        for (items, 0..) |*item, i| {
            if (i >= list.len()) break;
            const x = list.at(i).expr orelse continue;
            // jsonb's: by its sort key.
            if (calls(x, jsonb_key)) {
                // A result column by number: the key of its expression (an
                // alias reads as the column in the key's argument too).
                if (item.expr.kind == .integer) {
                    if (resultCol(cols, item.expr)) |e| item.expr = try b.wrap(e, jsonb_key);
                } else if (b.wrappedIn(x, item.expr, jsonb_key) or resultCol(cols, item.expr) != null) {
                    item.expr = try b.wrap(item.expr, jsonb_key);
                }
                continue;
            }
            // An interval's key (typing.keyList()).
            if (try b.wrapped(&item.expr, x)) continue;
            if (!isCollate(x) or item.expr.kind == .collate) continue;
            item.expr = try tree.expr(b.a, item.expr.pos, item.expr.end, .{ .collate = .{ .e = item.expr, .collation = collationOf(x) } });
        }
    }

    fn expr(b: *Back, e: *Expr) Error!void {
        switch (e.kind) {
            .func => |f| {
                for (f.args) |x| try b.expr(x);
                if (f.filter) |x| try b.expr(x);
                try b.sortList(f.order_by, &.{});
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
        const x0 = b.of(e) orelse return;
        // Calls the core wrapped `e` in, in place (outermost first): done
        // to the tree once `e` itself is.
        var wraps: [4]*IrExpr = undefined;
        var n_wraps: usize = 0;
        var x = x0;
        while (n_wraps < wraps.len and b.wrappedInPlace(e, x)) {
            wraps[n_wraps] = x;
            n_wraps += 1;
            x = x.x.list.?.at(0).expr.?;
        }
        defer {
            var k = n_wraps;
            while (k > 0) {
                k -= 1;
                b.wrapTree(e, wraps[k]) catch {};
            }
        }
        // A numeric literal read as its text (xq_dec('1.50')).
        if ((e.kind == .float or e.kind == .integer) and x.op == TK.STRING) e.kind = .{ .string = x.token() };
        if (try b.uuid(e, x)) return;
        switch (e.kind) {
            .concat => |c| if (c.args.len == 2 and calls(x, "xq_pg_jsonb_concat")) {
                e.kind = .{ .func = try b.func(e.pos, x.token(), c.args) };
            } else if (c.args.len == 2 and (calls(x, "xq_pg_array_cat2") or calls(x, "xq_pg_array_append") or calls(x, "xq_pg_array_prepend"))) {
                // || of arrays (an element wrapped as the call's argument).
                const f = try b.func(e.pos, x.token(), c.args);
                try b.call(f, x);
                e.kind = .{ .func = f };
            } else {
                if (c.args.len == 2 and x.op == TK.CONCAT) {
                    // jsonb || text: jsonb's text.
                    if (x.left) |l| if (b.wrappedIn(l, c.args[0], "xq_pg_jsonb_text")) {
                        c.args[0] = try b.wrap(c.args[0], "xq_pg_jsonb_text");
                    };
                    if (x.right) |r| if (b.wrappedIn(r, c.args[1], "xq_pg_jsonb_text")) {
                        c.args[1] = try b.wrap(c.args[1], "xq_pg_jsonb_text");
                    };
                }
                // An interval is its text.
                for (c.args) |*arg| if (b.isInterval(arg.*)) {
                    arg.* = try b.wrap(arg.*, "xq_pg_iv_out");
                };
            },
            .between => |*bt| {
                // jsonb's: the sort keys.
                if (x.left) |l| if (b.wrappedIn(l, bt.e, jsonb_key)) {
                    bt.e = try b.wrap(bt.e, jsonb_key);
                    bt.lo = try b.wrap(bt.lo, jsonb_key);
                    bt.hi = try b.wrap(bt.hi, jsonb_key);
                    return;
                };
                const y = if (x.op == TK.NOT) x.left orelse return else x;
                if (y.op != TK.BETWEEN or !y.useXList()) return;
                const list = y.x.list orelse return;
                if (list.len() != 2) return;
                _ = try b.wrapped(&bt.e, y.left);
                _ = try b.wrapped(&bt.lo, list.at(0).expr);
                _ = try b.wrapped(&bt.hi, list.at(1).expr);
            },
            .in_list => |*il| {
                // jsonb's: the sort keys.
                if (x.left) |l| if (b.wrappedIn(l, il.e, jsonb_key)) {
                    il.e = try b.wrap(il.e, jsonb_key);
                    for (il.items) |*it| it.* = try b.wrap(it.*, jsonb_key);
                    return;
                };
                const y = if (x.op == TK.NOT) x.left orelse return else x;
                if (il.items.len == 1 and (y.op == TK.EQ or y.op == TK.NE)) {
                    // x IN (a) is x = +a.
                    const a = unplus(y.right);
                    if (try b.boolLiteral(&il.items[0], a, y.left) or try b.boolLiteral(&il.e, y.left, a)) return;
                    _ = try b.wrapped(&il.e, y.left);
                    _ = try b.wrapped(&il.items[0], y.right);
                    return;
                }
                if (y.op != TK.IN or !y.useXList()) return;
                const list = y.x.list orelse return;
                if (list.len() != il.items.len) return;
                // A list with a boolean: its string literals read as
                // booleans (overload.zig's boolList()).
                if (b.booleanAmong(y.left, list.slice())) |o| {
                    _ = try b.boolLiteral(&il.e, y.left, o);
                    for (il.items, list.slice()) |*item, w| _ = try b.boolLiteral(item, w.expr, o);
                    return;
                }
                _ = try b.wrapped(&il.e, y.left);
                for (il.items, 0..) |*item, i| _ = try b.wrapped(item, list.at(i).expr);
            },
            // A boolean CASE: its string literals read as booleans
            // (overload.zig's boolCase()).
            .case => |*cs| {
                if (x.op != TK.CASE or !x.useXList()) return;
                const list = x.x.list orelse return;
                const items = list.slice();
                if (items.len != cs.whens.len + @intFromBool(cs.@"else" != null)) return;
                const n = items.len;
                if (cs.operand != null) if (x.left) |base| if (b.isBoolean(base)) {
                    for (cs.whens, 0..) |*w, i| if (!overload.caseResult(n, i)) {
                        _ = try b.boolLiteral(w, items[i].expr, base);
                    };
                };
                const o = for (items, 0..) |item, i| {
                    if (overload.caseResult(n, i) and b.isBoolean(item.expr.?)) break item.expr;
                } else return;
                for (cs.whens, 0..) |*w, i| if (overload.caseResult(n, i)) {
                    _ = try b.boolLiteral(w, items[i].expr, o);
                };
                if (cs.@"else") |*el| _ = try b.boolLiteral(el, items[n - 1].expr, o);
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
                // A string literal met by a boolean, read as one
                // (overload.zig's compare(): b = 't').
                if (try b.boolLiteral(&c.l, x.left, x.right) or try b.boolLiteral(&c.r, x.right, x.left)) return;
                // Intervals: keys, a BLOB column's bounds.
                const wl = try b.wrapped(&c.l, x.left);
                const wr = try b.wrapped(&c.r, x.right);
                if (wl or wr) return;
                const l = x.left orelse return;
                // jsonb's: the sort keys compared.
                if (b.wrappedIn(l, c.l, jsonb_key)) {
                    c.l = try b.wrap(c.l, jsonb_key);
                    c.r = try b.wrap(c.r, jsonb_key);
                    return;
                }
                if (!isCollate(l)) return;
                c.collation = collationOf(l);
                if (isArrayCollation(c.collation.?)) {
                    // A string literal read as the array type.
                    try b.literalArray(&c.l, l.left);
                    try b.literalArray(&c.r, x.right);
                    return;
                }
                if (!std.mem.eql(u8, c.collation.?, jsonb_collation)) return;
                if (c.l.kind == .string) if (l.left) |w| if (isCall(w)) {
                    c.l = try b.jsonb(c.l);
                };
                if (c.r.kind == .string) if (x.right) |w| if (isCall(w)) {
                    c.r = try b.jsonb(c.r);
                };
            },
            .func => |f| if (std.ascii.eqlIgnoreCase(f.name.text, "xq_pg_subscript") and calls(x, "xq_pg_jsonb_path") and f.args.len > 1) {
                // jsonb's subscripts: the path of them.
                const path = try tree.expr(b.a, e.pos, e.end, .{ .func = try b.func(e.pos, "xq_pg_array", f.args[1..]) });
                e.kind = .{ .func = try b.func(e.pos, "xq_pg_jsonb_path", try b.a.dupe(*Expr, &.{ f.args[0], path })) };
            } else try b.call(f, x),
            // jsonb::text: the text of jsonb (a JSONB blob's is not its
            // bytes), CAST(xq_pg_jsonb_text(j) AS TEXT).
            .cast => |*cs| {
                // ::text of an interval.
                if (calls(x, "xq_pg_iv_out") and cs.mode == .affinity) {
                    cs.mode = .{ .func = "xq_pg_iv_out" };
                    return;
                }
                var k = x;
                if (cs.mode == .truncate and isCall(x)) if (x.x.list) |list| if (list.len() > 0) {
                    k = list.at(0).expr orelse return;
                };
                if (k.op != TK.CAST) return;
                const inner = k.left orelse return;
                if (b.wrappedIn(inner, cs.e, "xq_pg_jsonb_text")) cs.e = try b.wrap(cs.e, "xq_pg_jsonb_text");
            },
            else => {},
        }
    }

    /// Whether `x` (the Expr of `e`, or one around it) is a call the core
    /// made of `e` in place (overload.zig's wrapIn(): xq_dec_key(e) ...):
    /// a function that wraps, whose first argument is no Expr of the tree
    /// under `e`. (wrappedIn() is a call made around another Expr, which
    /// wrap() does to the tree.)
    fn wrappedInPlace(b: *Back, e: *const Expr, x: *const IrExpr) bool {
        if (!isCall(x) or !wrappers.has(x.token())) return false;
        const list = x.x.list orelse return false;
        if (list.len() == 0) return false;
        const first = list.at(0).expr orelse return false;
        var it = Children.of(e);
        while (it.next()) |ch| if (b.of(ch) == first) return false;
        return true;
    }

    /// Do to the tree what wrapper `w` did to `e` (wrappedIn()): `e`
    /// becomes the call of its copy and the constants after it; a numeric
    /// literal its text (`1.50` is xq_dec('1.50')).
    fn wrapTree(b: *Back, e: *Expr, w: *const IrExpr) Error!void {
        const list = w.x.list.?;
        const inner = try b.a.create(Expr);
        inner.* = e.*;
        const first = list.at(0).expr.?;
        // A literal read as its text ('1.50', '-2.5').
        if (first.op == TK.STRING and e.kind != .string) inner.kind = .{ .string = first.token() };
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(b.a, inner);
        for (list.slice()[1..]) |c| try args.append(b.a, try b.constant(e, c.expr.?) orelse return);
        e.kind = .{ .func = try b.func(e.pos, w.token(), args.items) };
    }

    /// Whether IR `w` is a call of `name` the core wrapped around the IR
    /// of tree `t`.
    fn wrappedIn(b: *const Back, w: *const IrExpr, t: *const Expr, name: []const u8) bool {
        if (!calls(w, name)) return false;
        const list = w.x.list orelse return false;
        if (list.len() != 1) return false;
        const mine = b.of(t) orelse return false;
        return list.at(0).expr == mine;
    }

    /// A string literal operand `t` of an operator the core read as an
    /// integer (`w`: xq_pg_cast_int4('1')): that cast.
    fn literalInput(b: *Back, t: **Expr, w_: ?*IrExpr) Error!void {
        const w = w_ orelse return;
        if (t.*.kind != .string or !isCall(w)) return;
        const name = w.token();
        const list = w.x.list orelse return;
        if (list.len() != 1 or list.at(0).expr != b.of(t.*)) return;
        const iw = integer.castOf(name) orelse return;
        t.* = try tree.expr(b.a, t.*.pos, t.*.end, .{ .cast = .{ .e = t.*, .target_type = iw.name(), .mode = .{ .func = integer.castName(iw) } } });
    }

    fn isBoolean(b: *const Back, x: *const IrExpr) bool {
        return typing.typeOf(b.p.db, x.xq_type).logical == .boolean;
    }

    /// A boolean among `x` and `items` (of an IN list), if one is.
    fn booleanAmong(b: *const Back, x: ?*IrExpr, items: []const int.ExprListItem) ?*IrExpr {
        if (x) |e| if (b.isBoolean(e)) return e;
        for (items) |item| if (item.expr) |e| if (b.isBoolean(e)) return e;
        return null;
    }

    /// A string literal operand `t` the core read as a boolean (`w`:
    /// xq_pg_bool('t')): that cast; whether it was. One that is no
    /// boolean (`b = 'xyz'`, which the probe's core refused: `w` the
    /// literal, `other` a boolean) fails the statement, as PostgreSQL's
    /// CREATE VIEW and CHECK do.
    fn boolLiteral(b: *Back, t: **Expr, w_: ?*IrExpr, other: ?*IrExpr) Error!bool {
        const w = w_ orelse return false;
        if (t.*.kind != .string) return false;
        if (w.op == TK.STRING and w == b.of(t.*)) {
            const o = other orelse return false;
            if (b.isBoolean(o)) _ = try typing.readLiteralWith(b.outer, "xq_pg_bool", w);
            return false;
        }
        if (!calls(w, "xq_pg_bool")) return false;
        const list = w.x.list orelse return false;
        if (list.len() != 1 or list.at(0).expr != b.of(t.*)) return false;
        t.* = try tree.expr(b.a, t.*.pos, t.*.end, .{ .cast = .{ .e = t.*, .target_type = "boolean", .mode = .{ .func = "xq_pg_bool" } } });
        return true;
    }

    /// A string literal operand `t` the core read as an array (`w`:
    /// xq_pg_array_int4('{1}')): that cast.
    fn literalArray(b: *Back, t: **Expr, w_: ?*IrExpr) Error!void {
        const w = w_ orelse return;
        if (t.*.kind != .string or !isCall(w)) return;
        const list = w.x.list orelse return;
        if (list.len() != 1 or list.at(0).expr != b.of(t.*)) return;
        const name = try b.a.dupe(u8, w.token());
        t.* = try tree.expr(b.a, t.*.pos, t.*.end, .{ .cast = .{ .e = t.*, .target_type = "", .mode = .{ .func = name } } });
    }

    /// A call: another function, wrapped arguments, more arguments.
    fn call(b: *Back, f: *tree.Func, x: *IrExpr) Error!void {
        if (!isCall(x)) return;
        const want = lower.functionName(b.p, f.name.text, f.dialect, false) catch return error.OutOfMemory;
        const kind = overload.kindEngine(x.token()) != null;
        if (!std.ascii.eqlIgnoreCase(want, x.token()) and (renamed(x.token()) or kind)) {
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
        // Arguments the core added (array_to_json()'s, the element type of
        // an array's: array.Code).
        // The type of an argument the value does not tell (overload.zig's
        // kind_calls: xq_pg_to_char(d, t, kind)).
        if (items.len > f.args.len and f.args.len > 0 and (adds_args.has(x.token()) or kind)) {
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

    // ============================================================ uuid

    /// The forms overload.zig gave uuid operands (its uuidUnify(),
    /// uuidCast(), uuidConcat()): a comparison's, IN's and BETWEEN's
    /// operands in xq_pg_uuid() or xq_pg_uuid_text(), a uuid cast to text
    /// xq_pg_uuid_text(), the operands of `||`. Whether it replaced `e`
    /// (the cast): the others go on to expr()'s forms.
    fn uuid(b: *Back, e: *Expr, x: *IrExpr) Error!bool {
        switch (e.kind) {
            .compare => |*c| {
                try b.uuidWrap(&c.l, x.left);
                try b.uuidWrap(&c.r, x.right);
                return false;
            },
            .concat => |c| {
                if (c.args.len != 2 or x.op != TK.CONCAT) return false;
                try b.uuidWrap(&c.args[0], x.left);
                try b.uuidWrap(&c.args[1], x.right);
                return false;
            },
            .cast => |c| {
                if (!calls(x, "xq_pg_uuid_text") or c.mode != .affinity) return false;
                e.kind = .{ .func = try b.func(e.pos, "xq_pg_uuid_text", try b.a.dupe(*Expr, &.{c.e})) };
                return true;
            },
            .in_list => |*l| {
                const in = if (x.op == TK.NOT) x.left orelse return false else x;
                if (in.op != TK.IN or !in.useXList()) return false;
                const list = in.x.list orelse return false;
                if (list.len() != l.items.len) return false;
                try b.uuidWrap(&l.e, in.left);
                for (l.items, list.slice()) |*t, item| try b.uuidWrap(t, item.expr);
                // On to expr()'s: a boolean list's literals, intervals.
                return false;
            },
            .between => |*bt| {
                const in = if (x.op == TK.NOT) x.left orelse return false else x;
                if (in.op != TK.BETWEEN or !in.useXList()) return false;
                const list = in.x.list orelse return false;
                if (list.len() != 2) return false;
                try b.uuidWrap(&bt.e, in.left);
                try b.uuidWrap(&bt.lo, list.at(0).expr);
                try b.uuidWrap(&bt.hi, list.at(1).expr);
                return false;
            },
            else => return false,
        }
    }

    /// Operand `t` in the call `w` overload.zig wrapped it in, if it did.
    fn uuidWrap(b: *Back, t: **Expr, w_: ?*IrExpr) Error!void {
        const w = w_ orelse return;
        if (!calls(w, "xq_pg_uuid") and !calls(w, "xq_pg_uuid_text")) return;
        const list = w.x.list orelse return;
        if (list.len() != 1 or list.at(0).expr != b.of(t.*)) return;
        t.* = try tree.expr(b.a, t.*.pos, t.*.end, .{ .func = try b.func(t.*.pos, w.token(), try b.a.dupe(*Expr, &.{t.*})) });
    }

    /// `v::jsonb`.
    fn jsonb(b: *Back, v: *Expr) Error!*Expr {
        return tree.expr(b.a, v.pos, v.end, .{ .cast = .{ .e = v, .target_type = "jsonb", .mode = .{ .func = "xq_pg_jsonb" } } });
    }
};

const jsonb_collation = "xq_pg_jsonb";
const jsonb_key = @import("repr.zig").jsonb.jsonb_key;

/// The functions overload.zig calls in the place of another.
const renames = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_jsonb_get"},       .{"xq_pg_jsonb_get_text"},   .{"xq_pg_jsonb_path"},
    .{"xq_pg_jsonb_path_text"}, .{"xq_pg_json_agg_rows"},    .{"xq_pg_array_to_json"},
    .{"xq_pg_array_nested"},    .{"xq_pg_array_agg_arrays"}, .{"xq_pg_subscript_k"},
    .{"xq_pg_array_contains"},  .{"xq_pg_iv_sum"},           .{"xq_pg_iv_avg"},
});

/// Whether overload.zig calls `name` in the place of another: renames'
/// or numeric's (numericCall(), decimal_sql.zig's Info.renamed).
fn renamed(name: []const u8) bool {
    if (renames.has(name)) return true;
    const i = decimal_sql.info(name) orelse return false;
    return i.renamed;
}

const decimal_sql = @import("../decimal_sql.zig");

/// The functions overload.zig wraps an Expr in, in place (wrapIn()).
const wrappers = std.StaticStringMap(void).initComptime(.{
    .{"xq_dec"},     .{"xq_dec_key"}, .{"xq_dec_text"}, .{"xq_dec_float8"}, .{"xq_dec_int8"}, .{"xq_dec_number"},
    // A string literal read as the boolean it met (overload.zig's
    // boolLiteral()).
    .{"xq_pg_bool"},
});

/// The functions overload.zig gives more arguments.
const adds_args = std.StaticStringMap(void).initComptime(.{
    .{"xq_pg_array_to_json"}, .{"xq_pg_any"}, .{"xq_pg_subscript_k"}, .{"xq_pg_rows_unnest"},
});

const array = @import("array.zig");

fn isArrayCollation(z: []const u8) bool {
    return std.mem.eql(u8, z, array.collation_text) or std.mem.eql(u8, z, array.collation_number);
}

const interval_collation = "xq_pg_interval";

/// Whether `x` is the COLLATE of a type's order overload.zig chose
/// (jsonb's, intervals').
fn isCollate(x: *const IrExpr) bool {
    if (x.op != TK.COLLATE) return false;
    for ([_][]const u8{ jsonb_collation, interval_collation, array.collation_text, array.collation_number }) |n| {
        if (std.ascii.eqlIgnoreCase(x.token(), n)) return true;
    }
    return false;
}

fn collationOf(x: *const IrExpr) []const u8 {
    for ([_][]const u8{ interval_collation, array.collation_text, array.collation_number }) |n| {
        if (std.ascii.eqlIgnoreCase(x.token(), n)) return n;
    }
    return jsonb_collation;
}

/// The expression of the result column ORDER BY term `t` names (a
/// number, an alias), null if it names none.
fn resultCol(cols: []const tree.ResultCol, t: *const Expr) ?*Expr {
    switch (t.kind) {
        .integer => |z| {
            const n = std.fmt.parseInt(usize, z, 10) catch return null;
            if (n < 1 or n > cols.len or cols[n - 1] != .expr) return null;
            return cols[n - 1].expr.e;
        },
        .column => |names| {
            if (names.len != 1) return null;
            for (cols) |rc| if (rc == .expr) if (rc.expr.alias) |al| if (std.ascii.eqlIgnoreCase(al.text, names[0].text)) return rc.expr.e;
            return null;
        },
        else => return null,
    }
}

/// `x` without the unary + of `a` in `x IN (a)` (`x = +a`).
fn unplus(x: ?*IrExpr) ?*IrExpr {
    const y = x orelse return null;
    return if (y.op == TK.UPLUS) y.left else y;
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
