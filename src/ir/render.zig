//! Rendering the syntax tree IR (tree.zig) as SQLite text, for what the
//! schema keeps: CREATE TABLE (CHECK, DEFAULT, generated columns), CREATE
//! INDEX (index expressions), CREATE VIEW (the query), ALTER TABLE.
//! sqlite_schema stores the text, sqlite3 and the SQLite frontend read it
//! back (in whatever dialect the reading connection speaks).
//!
//! The contract with lower.zig: for every tree `t` this file accepts,
//! the SQLite frontend compiling render(t) means what lower(t) means, in
//! the SQLite dialect and in the dialect that built `t`. So a semantic
//! node is spelled as lower.zig lowers it, a node without SQLite syntax
//! as a call of the engine function lowering uses (xq_like(), xq_div(),
//! xq_coerce() ...: dialect.Hooks.engine_functions, visible in every
//! dialect), a function of a dialect's table by its qualified name
//! (xq_postgres_greatest) and a SQLite built-in the connection's dialect
//! shadows as xq_sqlite_<name> (lower.functionName()). The exception is
//! IdentityDefault, written nextval('seq') as PostgreSQL shows a serial
//! column's default: lowering fills identity columns itself.
//!
//! Identifiers are always quoted and operators fully parenthesized, so
//! the text does not depend on SQLite's precedence or keywords.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const ir = @import("ir.zig");
const tree = @import("tree.zig");
const lower = @import("lower.zig");
const Quoted = @import("../dialect/dialect.zig").Quoted;

pub const Error = error{ OutOfMemory, Failed };

/// The text of query `s` (whose positions are offsets of `src`), in
/// the arena of `p`; on error.Failed the error is left in `p`.
pub fn select(p: *int.Parse, src: [:0]const u8, s: *const tree.Select) Error![:0]const u8 {
    var r: Renderer = .{ .p = p, .src = src };
    try r.select(s);
    return r.text();
}

/// The text of expression `e`.
pub fn expr(p: *int.Parse, src: [:0]const u8, e: *const tree.Expr) Error![:0]const u8 {
    var r: Renderer = .{ .p = p, .src = src };
    try r.expr(e);
    return r.text();
}

/// The text of a CREATE TABLE/INDEX/VIEW or ALTER TABLE statement (what
/// lower.zig lowers them as).
pub fn statement(p: *int.Parse, src: [:0]const u8, s: tree.Stmt) Error![:0]const u8 {
    var r: Renderer = .{ .p = p, .src = src };
    return switch (s) {
        .create_table => |x| r.createTable(x),
        .create_index => |x| r.createIndex(x),
        .create_view => |x| r.createView(x),
        .alter_table => |x| r.alterTable(x),
        .select => |x| select(p, src, x),
        else => r.fail(0, "this statement has no SQLite text", .{}),
    };
}

pub const Renderer = struct {
    p: *int.Parse,
    /// The text the positions of the tree are offsets of.
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
        try r.print("{f}", .{Quoted('"'){ .z = name }});
    }

    pub fn string(r: *Renderer, s: []const u8) Error!void {
        try r.print("{f}", .{Quoted('\''){ .z = s }});
    }

    pub fn qname(r: *Renderer, q: tree.QName) Error!void {
        if (q.schema) |s| {
            try r.ident(s.text);
            try r.put(".");
        }
        try r.ident(q.name.text);
    }

    /// A collation name: bare if it is a plain word (BINARY, NOCASE),
    /// else quoted.
    pub fn collation(r: *Renderer, name: []const u8) Error!void {
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return r.ident(name);
        }
        return r.put(name);
    }

    fn functionName(r: *Renderer, name: []const u8, owner: ?@import("../dialect/dialect.zig").Dialect) Error![]const u8 {
        return lower.functionName(r.p, name, owner, true);
    }

    // ====================================================== expressions

    pub fn expr(r: *Renderer, e: *const tree.Expr) Error!void {
        switch (e.kind) {
            .column => |names| {
                for (names, 0..) |n, i| {
                    if (i > 0) try r.put(".");
                    try r.ident(n.text);
                }
            },
            .integer, .float => |t| try r.put(t),
            .string => |s| try r.string(s),
            .blob => |hex| try r.print("X'{s}'", .{hex}),
            .null => try r.put("NULL"),
            .boolean => |b| try r.put(if (b) "TRUE" else "FALSE"),
            .param => return r.fail(e.pos, "parameters are not allowed in the schema", .{}),
            .default => return r.fail(e.pos, "DEFAULT is not allowed in this context", .{}),
            .unary => |u| {
                // A negative number.
                if (u.op == .neg and (u.e.kind == .integer or u.e.kind == .float)) {
                    try r.put("-");
                    return r.expr(u.e);
                }
                try r.put(switch (u.op) {
                    .neg => "(-",
                    .plus => "(+",
                    .not => "(NOT ",
                    .bit_not => "(~",
                });
                // "(- -1)", not a comment.
                const at = r.out.items.len;
                try r.expr(u.e);
                if (r.out.items.len > at and (r.out.items[at] == '-' or r.out.items[at] == '+')) try r.out.insert(r.a(), at, ' ');
                try r.put(")");
            },
            .binary => |b| {
                try r.put("(");
                try r.expr(b.l);
                try r.put(switch (b.op) {
                    .add => " + ",
                    .sub => " - ",
                    .mul => " * ",
                    .rem => " % ",
                    .@"and" => " AND ",
                    .@"or" => " OR ",
                    .bit_and => " & ",
                    .bit_or => " | ",
                    .shl => " << ",
                    .shr => " >> ",
                    .json_get => " -> ",
                    .json_get_text => " ->> ",
                });
                try r.expr(b.r);
                try r.put(")");
            },
            .div => |d| switch (d.kind) {
                .sqlite, .real => {
                    try r.put(if (d.kind == .real) "(CAST(" else "(");
                    try r.expr(d.l);
                    try r.put(if (d.kind == .real) " AS REAL) / " else " / ");
                    try r.expr(d.r);
                    try r.put(")");
                },
                .int => try r.call("xq_div", &.{ d.l, d.r }),
            },
            .compare => |c| {
                try r.put("(");
                if (c.collation) |coll| {
                    try r.put("(");
                    try r.expr(c.l);
                    try r.put(" COLLATE ");
                    try r.collation(coll);
                    try r.put(")");
                } else try r.expr(c.l);
                try r.put(switch (c.op) {
                    .eq => " = ",
                    .ne => " <> ",
                    .lt => " < ",
                    .le => " <= ",
                    .gt => " > ",
                    .ge => " >= ",
                    .is => " IS ",
                    .is_not => " IS NOT ",
                });
                try r.expr(c.r);
                try r.put(")");
            },
            .concat => |c| switch (c.null_policy) {
                .propagate => {
                    try r.put("(");
                    for (c.args, 0..) |x, i| {
                        if (i > 0) try r.put(" || ");
                        try r.expr(x);
                    }
                    try r.put(")");
                },
                .skip => try r.call("concat", c.args),
            },
            .cast => |c| try r.cast(c),
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
            .like => |x| try r.like(x),
            .is_null => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " IS NOT NULL)" else " IS NULL)");
            },
            .is_bool => |x| {
                try r.put("(");
                try r.expr(x.e);
                try r.put(if (x.not) " IS NOT " else " IS ");
                try r.put(if (x.value) |v| (if (v) "TRUE" else "FALSE") else "NULL");
                try r.put(")");
            },
            .row => |items| {
                if (items.len == 1) return r.expr(items[0]);
                try r.put("(");
                try r.exprList(items);
                try r.put(")");
            },
            .collate => |c| {
                try r.put("(");
                try r.expr(c.e);
                try r.put(" COLLATE ");
                try r.collation(c.collation);
                try r.put(")");
            },
            .coerce => |c| {
                const mt = @import("../dialect/mariadb/types.zig");
                var flags: i64 = 0;
                if (c.ignore) flags |= mt.coerce_ignore;
                if (c.not_null) flags |= mt.coerce_not_null;
                if (c.missing) flags |= mt.coerce_missing;
                if (c.multi_row) flags |= mt.coerce_multi_row;
                try r.put("xq_coerce(");
                try r.expr(c.e);
                for ([_][]const u8{ c.decl_type, c.schema, c.table, c.column }) |s| {
                    try r.put(", ");
                    try r.string(s);
                }
                try r.print(", {d}, {d})", .{ flags, c.row });
            },
            .identity_default => |d| {
                try r.put("nextval(");
                try r.string(d.sequence);
                try r.put(")");
            },
        }
    }

    pub fn exprList(r: *Renderer, items: []const *tree.Expr) Error!void {
        for (items, 0..) |x, i| {
            if (i > 0) try r.put(", ");
            try r.expr(x);
        }
    }

    /// name(args): a SQLite built-in or an engine function.
    fn call(r: *Renderer, name: []const u8, args: []const *tree.Expr) Error!void {
        try r.put(try r.functionName(name, null));
        try r.put("(");
        try r.exprList(args);
        try r.put(")");
    }

    fn cast(r: *Renderer, c: tree.Cast) Error!void {
        switch (c.mode) {
            .affinity => |t| {
                try r.put("CAST(");
                try r.expr(c.e);
                try r.print(" AS {s})", .{t});
            },
            .func => |f| try r.call(f, &.{c.e}),
            .truncate => |n| {
                try r.print("{s}(CAST(", .{try r.functionName("substr", null)});
                try r.expr(c.e);
                try r.print(" AS TEXT), 1, {d})", .{n});
            },
            .round => |s| {
                try r.print("CAST({s}(", .{try r.functionName("round", null)});
                try r.expr(c.e);
                try r.print(", {d}) AS NUMERIC)", .{s});
            },
            .typed => |t| {
                try r.print("{s}(", .{try r.functionName(t.func, null)});
                try r.expr(c.e);
                try r.put(", ");
                try r.string(t.type_arg);
                try r.put(")");
            },
        }
    }

    /// As lower.zig lowers it: SQLite's LIKE, or xq_like()/xq_ilike().
    fn like(r: *Renderer, x: tree.Like) Error!void {
        const name: []const u8 = if (x.case_sensitive)
            "xq_like"
        else if (x.escape == .backslash)
            "xq_ilike"
        else
            try r.functionName("like", null);
        if (std.mem.eql(u8, name, "like")) {
            try r.put("(");
            try r.expr(x.e);
            try r.put(if (x.not) " NOT LIKE " else " LIKE ");
            try r.expr(x.pat);
            if (x.escape == .expr) {
                try r.put(" ESCAPE ");
                try r.expr(x.escape.expr);
            }
            return r.put(")");
        }
        try r.put(if (x.not) "(NOT " else "(");
        try r.put(name);
        try r.put("(");
        try r.expr(x.pat);
        try r.put(", ");
        try r.expr(x.e);
        switch (x.escape) {
            .none => if (x.case_sensitive) try r.put(", ''"),
            .backslash => {},
            .expr => |esc| {
                try r.put(", ");
                try r.expr(esc);
            },
        }
        try r.put("))");
    }

    fn func(r: *Renderer, f: *const tree.Func) Error!void {
        try r.put(try r.functionName(f.name.text, f.dialect));
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

    fn window(r: *Renderer, w: *const tree.WindowSpec) Error!void {
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

    fn bound(r: *Renderer, b: tree.Bound) Error!void {
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

    pub fn sortList(r: *Renderer, items: []const tree.SortItem) Error!void {
        for (items, 0..) |it, i| {
            if (i > 0) try r.put(", ");
            try r.expr(it.expr);
            try r.put(switch (it.dir) {
                .default => "",
                .asc => " ASC",
                .desc => " DESC",
            });
            try r.put(switch (it.nulls) {
                .default => "",
                .first => " NULLS FIRST",
                .last => " NULLS LAST",
            });
        }
    }

    // =========================================================== SELECT

    pub fn select(r: *Renderer, s: *const tree.Select) Error!void {
        const saved = r.src;
        defer r.src = saved;
        if (s.src) |t| r.src = t;
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

    pub fn nameList(r: *Renderer, names: []const tree.Name) Error!void {
        try r.put("(");
        for (names, 0..) |n, i| {
            if (i > 0) try r.put(", ");
            try r.ident(n.text);
        }
        try r.put(")");
    }

    fn body(r: *Renderer, b: *const tree.Body) Error!void {
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
    fn operand(r: *Renderer, b: *const tree.Body, right: bool) Error!void {
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

    fn core(r: *Renderer, c: *const tree.Core) Error!void {
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

    pub fn targets(r: *Renderer, cols: []const tree.ResultCol) Error!void {
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
                    } else if (x.name) |n| {
                        try r.put(" AS ");
                        try r.ident(n);
                    }
                },
            }
        }
    }

    fn from(r: *Renderer, items: []const tree.FromItem) Error!void {
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
                        .straight => "CROSS JOIN ",
                        else => "JOIN ",
                    });
                }
            }
            const cols: []const tree.Name = if (item.alias) |al| al.cols else &.{};
            switch (item.source) {
                .table => |q| {
                    if (cols.len > 0) return r.fail(cols[0].pos, "column aliases of a table are not supported", .{});
                    try r.qname(q);
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
            if (item.alias) |al| {
                try r.put(" AS ");
                try r.ident(al.name.text);
            }
            if (item.on) |on| {
                try r.put(" ON ");
                try r.expr(on);
            } else if (item.using.len > 0) {
                try r.put(" USING ");
                try r.nameList(item.using);
            }
        }
    }

    // ============================================================== DDL

    pub fn createTable(r: *Renderer, ct: *const tree.CreateTable) Error![:0]const u8 {
        try r.put(if (ct.temp) "CREATE TEMP TABLE " else "CREATE TABLE ");
        if (ct.if_not_exists) try r.put("IF NOT EXISTS ");
        if (ct.temp) try r.ident(ct.name.name.text) else try r.qname(ct.name);
        if (ct.as_select) |s| {
            try r.put(" AS ");
            try r.select(s);
            return r.text();
        }
        try r.put("(");
        for (ct.columns, 0..) |c, i| {
            if (i > 0) try r.put(", ");
            try r.column(c);
        }
        for (ct.constraints) |tc| {
            try r.put(", ");
            if (tc.name) |n| {
                try r.put("CONSTRAINT ");
                try r.ident(n);
                try r.put(" ");
            }
            switch (tc.kind) {
                .check => |e| {
                    try r.put("CHECK(");
                    try r.expr(e);
                    try r.put(")");
                },
                .unique => |cols| {
                    try r.put("UNIQUE");
                    try r.nameList(cols);
                },
                .primary_key => |cols| {
                    try r.put("PRIMARY KEY");
                    try r.nameList(cols);
                },
                .foreign_key => |fk| {
                    try r.put("FOREIGN KEY");
                    try r.nameList(fk.cols);
                    try r.references(fk.ref);
                },
            }
        }
        try r.put(")");
        if (ct.strict) try r.put(" STRICT");
        if (ct.without_rowid) try r.put(if (ct.strict) ", WITHOUT ROWID" else " WITHOUT ROWID");
        return r.text();
    }

    /// A column definition (CREATE TABLE, ALTER TABLE ADD COLUMN).
    pub fn column(r: *Renderer, c: tree.ColumnDef) Error!void {
        try r.ident(c.name.text);
        if (c.type) |t| try r.print(" {s}", .{t});
        for (c.constraints) |cc| {
            if (cc.name) |n| {
                try r.put(" CONSTRAINT ");
                try r.ident(n);
            }
            switch (cc.kind) {
                .not_null => try r.put(" NOT NULL"),
                .null => {},
                .check => |e| {
                    try r.put(" CHECK(");
                    try r.expr(e);
                    try r.put(")");
                },
                .default => |e| {
                    try r.put(" DEFAULT (");
                    try r.expr(e);
                    try r.put(")");
                },
                .primary_key => |pk| {
                    try r.put(" PRIMARY KEY");
                    if (pk.desc) try r.put(" DESC");
                    if (pk.autoincrement) try r.put(" AUTOINCREMENT");
                },
                .unique => try r.put(" UNIQUE"),
                .references => |ref| try r.references(ref),
                .generated => |g| {
                    try r.put(" GENERATED ALWAYS AS (");
                    try r.expr(g.e);
                    try r.put(if (g.stored) ") STORED" else ") VIRTUAL");
                },
                .collate => |coll| {
                    try r.put(" COLLATE ");
                    try r.collation(coll);
                },
                .identity => |id| {
                    try r.put(" NOT NULL DEFAULT (nextval(");
                    try r.string(id.sequence);
                    try r.put("))");
                },
            }
        }
    }

    fn references(r: *Renderer, ref: tree.Ref) Error!void {
        try r.put(" REFERENCES ");
        try r.ident(ref.table.text);
        if (ref.cols.len > 0) try r.nameList(ref.cols);
        const acts = [_]struct { tree.RefAction, []const u8 }{
            .{ ref.on_delete, " ON DELETE " }, .{ ref.on_update, " ON UPDATE " },
        };
        for (acts) |x| if (x[0] != .none) {
            try r.put(x[1]);
            try r.put(switch (x[0]) {
                .restrict => "RESTRICT",
                .cascade => "CASCADE",
                .set_null => "SET NULL",
                .set_default => "SET DEFAULT",
                .none => unreachable,
            });
        };
        if (ref.deferred) try r.put(" DEFERRABLE INITIALLY DEFERRED");
    }

    pub fn createIndex(r: *Renderer, ci: *const tree.CreateIndex) Error![:0]const u8 {
        try r.put(if (ci.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
        if (ci.if_not_exists) try r.put("IF NOT EXISTS ");
        try r.qname(ci.name);
        try r.put(" ON ");
        try r.ident(ci.table.text);
        try r.put("(");
        for (ci.items, 0..) |it, i| {
            if (i > 0) try r.put(", ");
            if (it.expr.kind == .column and it.expr.kind.column.len == 1) {
                try r.ident(it.expr.kind.column[0].text);
            } else {
                try r.put("(");
                try r.expr(it.expr);
                try r.put(")");
            }
            if (it.collate) |c| {
                try r.put(" COLLATE ");
                try r.collation(c);
            }
            if (it.desc) try r.put(" DESC");
        }
        try r.put(")");
        if (ci.where) |w| {
            try r.put(" WHERE ");
            try r.expr(w);
        }
        return r.text();
    }

    pub fn createView(r: *Renderer, v: *const tree.CreateView) Error![:0]const u8 {
        try r.put(if (v.temp) "CREATE TEMP VIEW " else "CREATE VIEW ");
        if (v.if_not_exists) try r.put("IF NOT EXISTS ");
        if (!v.temp) {
            try r.ident(if (v.name.schema) |s| s.text else "main");
            try r.put(".");
        }
        try r.ident(v.name.name.text);
        if (v.cols.len > 0) try r.nameList(v.cols);
        try r.put(" AS ");
        try r.select(v.select);
        return r.text();
    }

    pub fn alterTable(r: *Renderer, at: *const tree.AlterTable) Error![:0]const u8 {
        try r.put("ALTER TABLE ");
        try r.ident(if (at.name.schema) |s| s.text else "main");
        try r.put(".");
        try r.ident(at.name.name.text);
        switch (at.action) {
            .rename_to => |n| {
                try r.put(" RENAME TO ");
                try r.ident(n.text);
            },
            .rename_column => |rc| {
                try r.put(" RENAME COLUMN ");
                try r.ident(rc.old.text);
                try r.put(" TO ");
                try r.ident(rc.new.text);
            },
            .add_column => |ac| {
                try r.put(" ADD COLUMN ");
                try r.column(ac.def);
            },
            .drop_column => |dc| {
                try r.put(" DROP COLUMN ");
                try r.ident(dc.name.text);
            },
        }
        return r.text();
    }
};
