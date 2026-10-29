//! Printing the PostgreSQL syntax tree as SQLite text, for what the
//! schema stores (CHECK and DEFAULT expressions, index expressions, view
//! queries, CREATE TABLE AS): sqlite_schema keeps the text and sqlite3
//! reads it back. The semantics are those of lower.zig (casts, function
//! names, NULLS ordering, column names), spelled in SQLite's syntax;
//! identifiers are always quoted, operators fully parenthesized.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");
const lower = @import("lower.zig");
const views = @import("catalog_views.zig");

pub const Error = error{ OutOfMemory, Failed };

pub const Renderer = struct {
    p: *int.Parse,
    src: [:0]const u8,
    out: std.ArrayList(u8) = .empty,

    fn a(r: *Renderer) std.mem.Allocator {
        return r.p.arena;
    }

    pub fn fail(r: *Renderer, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        const z: ?[*]const u8 = if (pos < r.src.len) r.src.ptr + pos else null;
        ir.stmt.errorMsgAt(r.p, z, fmt, args);
        return error.Failed;
    }

    pub fn put(r: *Renderer, s: []const u8) Error!void {
        try r.out.appendSlice(r.a(), s);
    }

    pub fn print(r: *Renderer, comptime fmt: []const u8, args: anytype) Error!void {
        try r.out.print(r.a(), fmt, args);
    }

    /// The text so far, NUL-terminated, in the arena.
    pub fn text(r: *Renderer) Error![:0]const u8 {
        return r.a().dupeSentinel(u8, r.out.items, 0);
    }

    pub fn ident(r: *Renderer, name: []const u8) Error!void {
        try r.put("\"");
        for (name) |c| {
            if (c == '"') try r.put("\"");
            try r.out.append(r.a(), c);
        }
        try r.put("\"");
    }

    pub fn string(r: *Renderer, s: []const u8) Error!void {
        try r.put("'");
        for (s) |c| {
            if (c == '\'') try r.put("'");
            try r.out.append(r.a(), c);
        }
        try r.put("'");
    }

    fn schema(r: *Renderer, n: ast.Name) Error!void {
        if (std.mem.eql(u8, n.text, "public")) return r.ident("main");
        if (std.mem.eql(u8, n.text, "pg_temp")) return r.ident("temp");
        return r.fail(n.pos, "schema \"{s}\" does not exist", .{n.text});
    }

    pub fn qname(r: *Renderer, q: ast.QName) Error!void {
        if (q.schema) |s| {
            try r.schema(s);
            try r.put(".");
        }
        try r.ident(q.name.text);
    }

    // ====================================================== expressions

    pub fn expr(r: *Renderer, e: *const ast.Expr) Error!void {
        switch (e.kind) {
            .column => |names| {
                for (names, 0..) |n, i| {
                    if (i > 0) try r.put(".");
                    if (i == 0 and names.len == 3) try r.schema(n) else try r.ident(n.text);
                }
            },
            .integer, .float => |t| try r.put(t),
            .string => |s| try r.string(s),
            .blob => |hex| try r.print("X'{s}'", .{hex}),
            .null => try r.put("NULL"),
            .boolean => |b| try r.put(if (b) "TRUE" else "FALSE"),
            .param => |n| return r.fail(e.pos, "there is no parameter ${d}", .{n}),
            .default => return r.fail(e.pos, "DEFAULT is not allowed in this context", .{}),
            .unary => |u| {
                try r.put(switch (u.op) {
                    .neg => "(-",
                    .plus => "(+",
                    .not => "(NOT ",
                    .bit_not => "(~",
                });
                try r.expr(u.e);
                try r.put(")");
            },
            .binary => |b| {
                if (b.op == .pow) {
                    try r.put("power(");
                    try r.expr(b.l);
                    try r.put(", ");
                    try r.expr(b.r);
                    return r.put(")");
                }
                try r.put("(");
                try r.expr(b.l);
                try r.put(switch (b.op) {
                    .add => " + ",
                    .sub => " - ",
                    .mul => " * ",
                    .div => " / ",
                    .mod => " % ",
                    .concat => " || ",
                    .eq => " = ",
                    .ne => " <> ",
                    .lt => " < ",
                    .le => " <= ",
                    .gt => " > ",
                    .ge => " >= ",
                    .@"and" => " AND ",
                    .@"or" => " OR ",
                    .bit_and => " & ",
                    .bit_or => " | ",
                    .shl => " << ",
                    .shr => " >> ",
                    .json_get => " -> ",
                    .json_get_text => " ->> ",
                    .pow => unreachable,
                });
                try r.expr(b.r);
                try r.put(")");
            },
            .cast => |c| try r.cast(e, c),
            .func => |f| try r.func(f),
            .case => |c| {
                try r.put("CASE");
                if (c.operand) |o| {
                    try r.put(" ");
                    try r.expr(o);
                }
                var i: usize = 0;
                while (i + 1 < c.whens.len) : (i += 2) {
                    try r.put(" WHEN ");
                    try r.expr(c.whens[i]);
                    try r.put(" THEN ");
                    try r.expr(c.whens[i + 1]);
                }
                if (c.@"else") |x| {
                    try r.put(" ELSE ");
                    try r.expr(x);
                }
                try r.put(" END");
            },
            .in_list => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " NOT IN (" else " IN (");
                try r.exprList(x.items);
                try r.put("))");
            },
            .in_select => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " NOT IN (" else " IN (");
                try r.select(x.sel);
                try r.put("))");
            },
            .exists => |s| {
                try r.put("(EXISTS (");
                try r.select(s);
                try r.put("))");
            },
            .subquery => |s| {
                try r.put("(");
                try r.select(s);
                try r.put(")");
            },
            .between => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " NOT BETWEEN " else " BETWEEN ");
                try r.expr(x.lo);
                try r.put(" AND ");
                try r.expr(x.hi);
                try r.put(")");
            },
            .like => |x| {
                // LIKE calls like(); ILIKE is the dialect's ilike().
                try r.put(if (x.not) "(NOT " else "(");
                try r.put(if (x.ilike) "ilike(" else "like(");
                try r.expr(x.pat);
                try r.put(", ");
                try r.expr(x.e);
                if (x.escape) |esc| {
                    try r.put(", ");
                    try r.expr(esc);
                }
                try r.put("))");
            },
            .is_null => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " IS NOT NULL)" else " IS NULL)");
            },
            .is_distinct => |x| {
                try r.put("(");
                try r.expr(x.l);
                try r.put(if (x.not) " IS " else " IS NOT ");
                try r.expr(x.r);
                try r.put(")");
            },
            .is_bool => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " IS NOT " else " IS ");
                try r.put(if (x.value) |v| (if (v) "TRUE" else "FALSE") else "NULL");
                try r.put(")");
            },
            .row => |items| {
                try r.put("(");
                try r.exprList(items);
                try r.put(")");
            },
            .collate => |c| {
                try r.put("(");
                try r.expr(c.e);
                try r.put(" COLLATE ");
                try r.collation(c.name);
                try r.put(")");
            },
        }
    }

    pub fn collation(r: *Renderer, n: ast.Name) Error!void {
        if (std.mem.eql(u8, n.text, "C") or std.mem.eql(u8, n.text, "POSIX") or std.ascii.eqlIgnoreCase(n.text, "default") or std.ascii.eqlIgnoreCase(n.text, "ucs_basic")) {
            return r.put("BINARY");
        }
        return r.ident(n.text);
    }

    pub fn exprList(r: *Renderer, items: []const *ast.Expr) Error!void {
        for (items, 0..) |x, i| {
            if (i > 0) try r.put(", ");
            try r.expr(x);
        }
    }

    fn cast(r: *Renderer, e: *const ast.Expr, c: ast.Cast) Error!void {
        if (std.mem.eql(u8, c.ty.name, "bytea") and !c.ty.array and c.e.kind == .string) {
            const s = c.e.kind.string;
            if (std.mem.startsWith(u8, s, "\\x")) {
                for (s[2..]) |ch| if (!std.ascii.isHex(ch)) return r.fail(e.pos, "invalid hexadecimal digit: \"{c}\"", .{ch});
                return r.print("X'{s}'", .{s[2..]});
            }
        }
        const plan = types.castPlan(c.ty) catch |err| return switch (err) {
            error.Array => r.fail(c.ty.pos, "arrays are not supported", .{}),
            error.UnknownType => r.fail(c.ty.pos, "type \"{s}\" does not exist", .{c.ty.name}),
        };
        switch (plan) {
            .sqlite => |t| {
                try r.put("CAST(");
                try r.expr(c.e);
                try r.print(" AS {s})", .{t});
            },
            .func => |f| {
                try r.print("{s}(", .{f});
                try r.expr(c.e);
                try r.put(")");
            },
            .truncate => |n| {
                try r.put("substr(CAST(");
                try r.expr(c.e);
                try r.print(" AS TEXT), 1, {d})", .{n});
            },
            .round => |s| {
                try r.put("CAST(round(");
                try r.expr(c.e);
                try r.print(", {d}) AS NUMERIC)", .{s});
            },
        }
    }

    fn func(r: *Renderer, f: *const ast.Func) Error!void {
        const n = f.name.text;
        const eql = std.mem.eql;
        if (f.over == null and f.filter == null and f.order_by.len == 0) {
            if (eql(u8, n, "now") or eql(u8, n, "current_timestamp") or eql(u8, n, "localtimestamp") or
                eql(u8, n, "transaction_timestamp") or eql(u8, n, "statement_timestamp") or eql(u8, n, "clock_timestamp"))
            {
                return r.put("strftime('%Y-%m-%d %H:%M:%f', 'now')");
            }
            if (eql(u8, n, "localtime")) return r.put("current_time");
            if (eql(u8, n, "current_date") or eql(u8, n, "current_time")) return r.put(n);
            if (eql(u8, n, "current_role") or eql(u8, n, "session_user")) return r.put("current_user()");
            if (eql(u8, n, "current_catalog")) return r.put("current_database()");
            if (eql(u8, n, "date_part")) {
                if (f.args.len != 2 or f.args[0].kind != .string) return r.fail(f.name.pos, "function date_part with these arguments is not supported", .{});
                const plan = lower.datePartPlan(f.args[0].kind.string) orelse
                    return r.fail(f.args[0].pos, "unit \"{s}\" not recognized for type timestamp", .{f.args[0].kind.string});
                if (plan.func) |fname| {
                    try r.print("{s}(", .{fname});
                    try r.expr(f.args[1]);
                    return r.put(")");
                }
                if (plan.quarter) try r.put("((");
                try r.print("CAST(strftime('{s}', ", .{plan.fmt});
                try r.expr(f.args[1]);
                try r.print(") AS {s})", .{plan.cast});
                if (plan.quarter) try r.put(" + 2) / 3)");
                return;
            }
        }
        try r.put(lower.funcName(n));
        try r.put("(");
        if (f.star) {
            try r.put("*");
        } else {
            if (f.distinct) try r.put("DISTINCT ");
            try r.exprList(f.args);
            if (f.order_by.len > 0) {
                try r.put(" ORDER BY ");
                try r.sortList(f.order_by);
            }
        }
        try r.put(")");
        if (f.filter) |flt| {
            try r.put(" FILTER (WHERE ");
            try r.expr(flt);
            try r.put(")");
        }
        if (f.over) |w| {
            try r.put(" OVER ");
            if (w.name_only) return r.ident(w.base.?.text);
            try r.put("(");
            try r.window(w);
            try r.put(")");
        }
    }

    fn window(r: *Renderer, w: *const ast.WindowSpec) Error!void {
        var sep = false;
        if (w.base) |b| {
            try r.ident(b.text);
            sep = true;
        }
        if (w.partition.len > 0) {
            if (sep) try r.put(" ");
            try r.put("PARTITION BY ");
            try r.exprList(w.partition);
            sep = true;
        }
        if (w.order_by.len > 0) {
            if (sep) try r.put(" ");
            try r.put("ORDER BY ");
            try r.sortList(w.order_by);
            sep = true;
        }
        if (w.frame) |fr| {
            if (sep) try r.put(" ");
            try r.put(switch (fr.unit) {
                .rows => "ROWS ",
                .range => "RANGE ",
                .groups => "GROUPS ",
            });
            if (fr.end) |e| {
                try r.put("BETWEEN ");
                try r.bound(fr.start);
                try r.put(" AND ");
                try r.bound(e);
            } else try r.bound(fr.start);
            try r.put(switch (fr.exclude) {
                .none => "",
                .no_others => " EXCLUDE NO OTHERS",
                .current_row => " EXCLUDE CURRENT ROW",
                .group => " EXCLUDE GROUP",
                .ties => " EXCLUDE TIES",
            });
        }
    }

    fn bound(r: *Renderer, b: ast.Bound) Error!void {
        switch (b.kind) {
            .unbounded_preceding => try r.put("UNBOUNDED PRECEDING"),
            .unbounded_following => try r.put("UNBOUNDED FOLLOWING"),
            .current_row => try r.put("CURRENT ROW"),
            .preceding, .following => {
                try r.expr(b.expr.?);
                try r.put(if (b.kind == .preceding) " PRECEDING" else " FOLLOWING");
            },
        }
    }

    pub fn sortList(r: *Renderer, items: []const ast.SortItem) Error!void {
        for (items, 0..) |it, i| {
            if (i > 0) try r.put(", ");
            try r.expr(it.expr);
            const desc = it.dir == .desc;
            if (desc) try r.put(" DESC");
            try r.put(switch (it.nulls) {
                .first => " NULLS FIRST",
                .last => " NULLS LAST",
                .default => if (desc) " NULLS FIRST" else " NULLS LAST",
            });
        }
    }

    // =========================================================== SELECT

    pub fn select(r: *Renderer, s: *const ast.Select) Error!void {
        if (s.with) |w| {
            try r.put("WITH ");
            if (w.recursive) try r.put("RECURSIVE ");
            for (w.ctes, 0..) |cte, i| {
                if (i > 0) try r.put(", ");
                try r.ident(cte.name.text);
                if (cte.cols.len > 0) try r.nameList(cte.cols);
                try r.put(" AS ");
                if (cte.materialized) |m| try r.put(if (m) "MATERIALIZED " else "NOT MATERIALIZED ");
                try r.put("(");
                try r.select(cte.select);
                try r.put(")");
            }
            try r.put(" ");
        }
        const ordered = s.order_by.len > 0 or s.limit != null or s.offset != null;
        const needs_wrap = ordered and switch (s.body.*) {
            .nested => |n| n.order_by.len > 0 or n.limit != null or n.offset != null,
            // SQLite takes no ORDER BY/LIMIT after VALUES.
            .values => true,
            else => false,
        };
        if (needs_wrap) {
            try r.put("SELECT * FROM (");
            try r.body(s.body);
            try r.put(")");
        } else try r.body(s.body);
        if (s.order_by.len > 0) {
            try r.put(" ORDER BY ");
            try r.sortList(s.order_by);
        }
        if (s.limit != null or s.offset != null) {
            try r.put(" LIMIT ");
            if (s.limit) |x| try r.expr(x) else try r.put("-1");
            if (s.offset) |x| {
                try r.put(" OFFSET ");
                try r.expr(x);
            }
        }
    }

    fn nameList(r: *Renderer, names: []const ast.Name) Error!void {
        try r.put("(");
        for (names, 0..) |n, i| {
            if (i > 0) try r.put(", ");
            try r.ident(n.text);
        }
        try r.put(")");
    }

    fn body(r: *Renderer, b: *const ast.Body) Error!void {
        switch (b.*) {
            .core => |c| try r.core(c),
            .values => |rows| {
                try r.put("VALUES ");
                for (rows, 0..) |row, i| {
                    if (i > 0) try r.put(", ");
                    try r.put("(");
                    try r.exprList(row);
                    try r.put(")");
                }
            },
            .nested => |s| try r.select(s),
            .compound => |c| {
                if (c.all and c.op != .@"union") return r.fail(0, "{s} ALL is not supported", .{if (c.op == .except) "EXCEPT" else "INTERSECT"});
                try r.operand(c.left, false);
                try r.put(switch (c.op) {
                    .@"union" => if (c.all) " UNION ALL " else " UNION ",
                    .except => " EXCEPT ",
                    .intersect => " INTERSECT ",
                });
                try r.operand(c.right, true);
            },
        }
    }

    /// An operand of a compound: SQLite has no parentheses there, so a
    /// query with its own ORDER BY/LIMIT/WITH (or a compound on the
    /// right) is a subquery.
    fn operand(r: *Renderer, b: *const ast.Body, right: bool) Error!void {
        const wrap = switch (b.*) {
            .nested => |s| s.order_by.len > 0 or s.limit != null or s.offset != null or s.with != null or (right and s.body.* == .compound),
            .compound => right,
            else => false,
        };
        if (wrap) {
            try r.put("SELECT * FROM (");
            try r.body(b);
            try r.put(")");
        } else try r.body(b);
    }

    fn core(r: *Renderer, c: *const ast.Core) Error!void {
        try r.put(if (c.distinct) "SELECT DISTINCT " else "SELECT ");
        try r.targets(c.cols);
        if (c.from.len > 0) {
            try r.put(" FROM ");
            try r.from(c.from);
        }
        if (c.where) |w| {
            try r.put(" WHERE ");
            try r.expr(w);
        }
        if (c.group_by.len > 0) {
            try r.put(" GROUP BY ");
            try r.exprList(c.group_by);
        }
        if (c.having) |h| {
            try r.put(" HAVING ");
            try r.expr(h);
        }
        if (c.windows.len > 0) {
            try r.put(" WINDOW ");
            for (c.windows, 0..) |w, i| {
                if (i > 0) try r.put(", ");
                try r.ident(w.name.text);
                try r.put(" AS (");
                try r.window(w.spec);
                try r.put(")");
            }
        }
    }

    pub fn targets(r: *Renderer, cols: []const ast.ResultCol) Error!void {
        for (cols, 0..) |rc, i| {
            if (i > 0) try r.put(", ");
            switch (rc) {
                .star => try r.put("*"),
                .table_star => |ts| {
                    try r.ident(ts.names[ts.names.len - 1].text);
                    try r.put(".*");
                },
                .expr => |x| {
                    try r.expr(x.e);
                    if (x.alias) |al| {
                        try r.put(" AS ");
                        try r.ident(al.text);
                    } else if (ast.columnName(x.e)) |n| {
                        try r.put(" AS ");
                        try r.ident(n);
                    }
                },
            }
        }
    }

    fn from(r: *Renderer, items: []const ast.FromItem) Error!void {
        for (items, 0..) |item, i| {
            if (i > 0) {
                if (item.join == .comma) {
                    try r.put(", ");
                } else {
                    try r.put(" ");
                    if (item.natural) try r.put("NATURAL ");
                    try r.put(switch (item.join) {
                        .left => "LEFT JOIN ",
                        .right => "RIGHT JOIN ",
                        .full => "FULL JOIN ",
                        else => "JOIN ",
                    });
                }
            }
            const cols: []const ast.Name = if (item.alias) |al| al.cols else &.{};
            switch (item.source) {
                .table => |q| {
                    const schema_name: ?[]const u8 = if (q.schema) |s| s.text else null;
                    const def = if (schema_name == null and @import("../../sql/build.zig").findTable(r.p.db, q.name.text, null) != null)
                        null
                    else
                        try views.definition(r.p, schema_name, q.name.text);
                    if (def) |text_| {
                        const parser = @import("parser.zig");
                        var ps = parser.Parser.init(r.a(), text_, 0) catch return r.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text});
                        const tree = ps.select() catch return r.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text});
                        var sub: Renderer = .{ .p = r.p, .src = text_, .out = r.out };
                        try sub.put("(");
                        try sub.select(tree);
                        try sub.put(")");
                        r.out = sub.out;
                        try r.put(" AS ");
                        try r.ident(if (item.alias) |al| al.name.text else q.name.text);
                    } else {
                        if (cols.len > 0) return r.fail(cols[0].pos, "column aliases of a table are not supported", .{});
                        try r.qname(q);
                        if (item.alias) |al| {
                            try r.put(" AS ");
                            try r.ident(al.name.text);
                        }
                    }
                },
                .subquery => |s| {
                    try r.put("(");
                    if (cols.len > 0) {
                        try r.put("WITH \"xq_alias\"");
                        try r.nameList(cols);
                        try r.put(" AS (");
                        try r.select(s);
                        try r.put(") SELECT * FROM \"xq_alias\"");
                    } else try r.select(s);
                    try r.put(")");
                },
                .func => |f| {
                    if (cols.len > 0) return r.fail(cols[0].pos, "column aliases of a function are not supported", .{});
                    try r.ident(f.name.text);
                    try r.put("(");
                    try r.exprList(f.args);
                    try r.put(")");
                },
                .nested => |inner| {
                    try r.put("(");
                    try r.from(inner);
                    try r.put(")");
                },
            }
            if (item.alias) |al| if (item.source != .table) {
                try r.put(" AS ");
                try r.ident(al.name.text);
            };
            if (item.on) |on| {
                try r.put(" ON ");
                try r.expr(on);
            } else if (item.using.len > 0) {
                try r.put(" USING ");
                try r.nameList(item.using);
            }
        }
    }
};
