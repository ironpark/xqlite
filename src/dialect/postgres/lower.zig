//! Lowering the PostgreSQL syntax tree (ast.zig) into the common IR
//! (src/ir/ir.zig): queries, DML and transaction control. The builders
//! are called as SQLite's grammar calls them (src/parse/parser.zig), so
//! that the same query gets SQLite's own plan; the differences are
//! PostgreSQL's semantics:
//!
//!  - names are folded already; `public.t` is `main.t`, `pg_temp.t` is
//!    `temp.t`; information_schema and pg_catalog views are replaced by
//!    the queries of catalog_views.zig;
//!  - ORDER BY without NULLS FIRST/LAST puts NULLs last for ASC and
//!    first for DESC (SQLite does the opposite), except on a column
//!    that cannot be NULL (so that an index still gives the order);
//!  - result columns are named as PostgreSQL names them ("?column?",
//!    the function name ...);
//!  - LIKE/ILIKE call the engine functions xq_like()/xq_ilike(); casts follow
//!    types.castPlan(); $n is ?n;
//!  - INSERT fills an omitted INTEGER PRIMARY KEY that has an identity
//!    sequence (SQLite would otherwise ignore its DEFAULT nextval());
//!    DEFAULT in VALUES and SET is the column's default; DELETE USING
//!    becomes a rowid IN (subquery).

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const expr_mod = @import("../../sql/expr.zig");
const ctype = @import("../../util/ctype.zig");
const catalog = @import("../../catalog/catalog.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");
const views = @import("catalog_views.zig");

const Parse = int.Parse;
const Token = int.Token;
const IrExpr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const IrSelect = int.Select;
const TK = int.TK;
const SO = int.SortOrder;

pub const Error = error{ OutOfMemory, Failed };

pub const Lowerer = struct {
    p: *Parse,
    /// The text the tree was parsed from (positions are offsets in it).
    src: [:0]const u8,
    /// In a RETURNING list: the name (alias or table) whose qualified
    /// columns are the target's, which SQLite wants unqualified.
    returning_qualifier: ?[]const u8 = null,

    fn arena(l: *const Lowerer) std.mem.Allocator {
        return l.p.arena;
    }

    /// Leave an error about the text at `pos` and fail.
    pub fn fail(l: *Lowerer, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        const z: ?[*]const u8 = if (pos < l.src.len) l.src.ptr + pos else null;
        ir.stmt.errorMsgAt(l.p, z, fmt, args);
        return error.Failed;
    }

    /// Fail if a builder left an error.
    fn check(l: *Lowerer) Error!void {
        if (l.p.n_err > 0) return error.Failed;
    }

    // ------------------------------------------------------------ tokens

    /// A token for a name: in the text when it is spelled there as is
    /// (for error offsets), else a copy; quoted if it starts with a quote
    /// character, as the builders dequote such tokens.
    pub fn nameTok(l: *Lowerer, n: ast.Name) Error!Token {
        const t = n.text;
        if (t.len > 0 and ctype.isQuote(t[0])) {
            var out: std.ArrayList(u8) = .empty;
            try out.append(l.arena(), '"');
            for (t) |c| {
                if (c == '"') try out.append(l.arena(), '"');
                try out.append(l.arena(), c);
            }
            try out.append(l.arena(), '"');
            return Token.init(out.items);
        }
        if (n.pos + t.len <= l.src.len and std.mem.eql(u8, l.src[n.pos..][0..t.len], t)) {
            return .{ .z = l.src.ptr + n.pos, .n = @intCast(t.len) };
        }
        return Token.init(t);
    }

    fn tokAt(l: *Lowerer, pos: u32, len: u32) Token {
        if (pos + len <= l.src.len) return .{ .z = l.src.ptr + pos, .n = len };
        return .{};
    }

    /// parse.y tokenExpr() without the dequoting: the names and strings
    /// of the tree are decoded already.
    fn leaf(l: *Lowerer, op: u8, text: []const u8, pos: u32) Error!*IrExpr {
        const p = l.p;
        const e = try p.arena.create(IrExpr);
        e.* = .{
            .op = op,
            .flags = .{ .Leaf = true },
            .u = .{ .token = try p.arena.dupeSentinel(u8, text, 0) },
            .w = .{ .ofst = expr_mod.tokenOffset(p, l.tokAt(pos, 0)) },
            .n_height = 1,
        };
        return e;
    }

    // ======================================================= statements

    pub fn statement(l: *Lowerer, s: ast.Stmt) Error!void {
        const p = l.p;
        switch (s) {
            // Lowering looks at the schema (catalog views, identity
            // columns, NOT NULL columns): read it first.
            .select, .insert, .update, .delete, .truncate, .explain => ir.stmt.readSchema(p) catch return error.Failed,
            else => {},
        }
        switch (s) {
            .select => |sel| ir.stmt.select(p, try l.select(sel)),
            .insert => |x| try l.insert(x),
            .update => |x| try l.update(x),
            .delete => |x| try l.delete(x),
            .begin => ir.txn.begin(p, TK.DEFERRED),
            .commit => ir.txn.end(p, TK.COMMIT),
            .rollback => ir.txn.end(p, TK.ROLLBACK),
            .savepoint => |n| ir.txn.savepoint(p, .BEGIN, try l.nameTok(n)),
            .release => |n| ir.txn.savepoint(p, .RELEASE, try l.nameTok(n)),
            .rollback_to => |n| ir.txn.savepoint(p, .ROLLBACK, try l.nameTok(n)),
            .truncate => |t| try l.truncate(t),
            .explain => |inner| {
                ir.stmt.setExplain(p, 2);
                try l.statement(inner.*);
            },
            else => unreachable, // DDL: ddl.zig
        }
        try l.check();
    }

    // ====================================================== expressions

    pub fn expr(l: *Lowerer, e: *const ast.Expr) Error!*IrExpr {
        const p = l.p;
        switch (e.kind) {
            .column => |names| return l.column(names),
            .integer => |t| {
                const x = try ir.expr.integer(p, Token.init(t));
                x.w = .{ .ofst = expr_mod.tokenOffset(p, l.tokAt(e.pos, 0)) };
                return x;
            },
            .float => |t| return l.leaf(TK.FLOAT, t, e.pos),
            .string => |t| return l.leaf(TK.STRING, t, e.pos),
            .blob => |hex| return l.leaf(TK.BLOB, try std.fmt.allocPrint(l.arena(), "x'{s}'", .{hex}), e.pos),
            .null => return l.leaf(TK.NULL, "NULL", e.pos),
            .boolean => |b| return l.boolean(b),
            .param => |n| {
                const x = try l.leaf(TK.VARIABLE, try std.fmt.allocPrint(l.arena(), "?{d}", .{n}), e.pos);
                try ir.expr.assignVarNumber(p, x, @intCast(x.token().len));
                try l.check();
                return x;
            },
            .default => return l.fail(e.pos, "DEFAULT is not allowed in this context", .{}),
            .unary => |u| {
                const x = try l.expr(u.e);
                switch (u.op) {
                    .not => return ir.expr.binary(p, TK.NOT, x, null),
                    .bit_not => return ir.expr.binary(p, TK.BITNOT, x, null),
                    .neg, .plus => {
                        const op: u8 = if (u.op == .neg) TK.UMINUS else TK.UPLUS;
                        if (x.op == TK.UPLUS) {
                            x.op = op;
                            return x;
                        }
                        return ir.expr.binary(p, op, x, null);
                    },
                }
            },
            .binary => |b| return l.binaryExpr(b),
            .cast => |c| return l.cast(e, c),
            .func => |f| return l.func(f),
            .case => |c| {
                const operand = if (c.operand) |o| try l.expr(o) else null;
                var list: ?*ExprList = null;
                for (c.whens) |w| list = try ir.list.append(p, list, try l.expr(w));
                const else_ = if (c.@"else") |x| try l.expr(x) else null;
                return ir.expr.case(p, operand, list, else_);
            },
            .in_list => |x| {
                const lhs = try l.expr(x.e);
                return ir.expr.inList(p, lhs, x.not, try l.exprList(x.items));
            },
            .in_select => |x| {
                const lhs = try l.expr(x.e);
                return ir.expr.inSelect(p, lhs, x.not, try l.select(x.sel));
            },
            .exists => |s| return ir.expr.subquery(p, TK.EXISTS, try l.select(s)),
            .subquery => |s| return ir.expr.subquery(p, TK.SELECT, try l.select(s)),
            .between => |x| {
                const v = try l.expr(x.e);
                const lo = try l.expr(x.lo);
                const hi = try l.expr(x.hi);
                return ir.expr.between(p, v, x.not, lo, hi);
            },
            .like => |x| {
                const lhs = try l.expr(x.e);
                const rhs = try l.expr(x.pat);
                const esc = if (x.escape) |z| try l.expr(z) else null;
                return ir.expr.like(p, Token.init(if (x.ilike) "xq_ilike" else "xq_like"), x.not, lhs, rhs, esc);
            },
            .is_null => |x| return ir.expr.isNull(p, if (x.not) TK.NOTNULL else TK.ISNULL, try l.expr(x.e)),
            .is_distinct => |x| {
                const lhs = try l.expr(x.l);
                const rhs = try l.expr(x.r);
                return ir.expr.is(p, if (x.not) TK.IS else TK.ISNOT, lhs, rhs);
            },
            .is_bool => |x| {
                const lhs = try l.expr(x.e);
                const v = x.value orelse return ir.expr.isNull(p, if (x.not) TK.NOTNULL else TK.ISNULL, lhs);
                return ir.expr.is(p, if (x.not) TK.ISNOT else TK.IS, lhs, try l.boolean(v));
            },
            .row => |items| {
                if (items.len == 1) return l.expr(items[0]);
                return ir.expr.vector(p, (try l.exprList(items)).?);
            },
            .collate => |c| {
                const x = try l.expr(c.e);
                return ir.expr.collate(p, x, try l.collationTok(c.name), true);
            },
        }
    }

    fn boolean(l: *Lowerer, b: bool) Error!*IrExpr {
        const x = try expr_mod.expr(l.arena(), TK.STRING, if (b) "true" else "false");
        _ = ir.expr.idToTrueFalse(x);
        return x;
    }

    /// The collation a PostgreSQL collation name maps to: "C" and
    /// "POSIX" are BINARY; SQLite's own names pass through.
    fn collationTok(l: *Lowerer, n: ast.Name) Error!Token {
        if (isBinaryCollation(n.text)) return Token.init("BINARY");
        return l.nameTok(n);
    }

    pub fn exprList(l: *Lowerer, items: []const *ast.Expr) Error!?*ExprList {
        var list: ?*ExprList = null;
        for (items) |x| list = try ir.list.append(l.p, list, try l.expr(x));
        return list;
    }

    fn column(l: *Lowerer, names: []const ast.Name) Error!*IrExpr {
        const p = l.p;
        switch (names.len) {
            1 => return l.leaf(TK.ID, names[0].text, names[0].pos),
            2 => {
                if (l.returning_qualifier) |q| if (std.mem.eql(u8, q, names[0].text)) {
                    return l.leaf(TK.ID, names[1].text, names[1].pos);
                };
                const t = try l.leaf(TK.ID, names[0].text, names[0].pos);
                const c = try l.leaf(TK.ID, names[1].text, names[1].pos);
                return ir.expr.binary(p, TK.DOT, t, c);
            },
            else => {
                const db = try l.schemaName(names[0]);
                const s = try l.leaf(TK.ID, db, names[0].pos);
                const t = try l.leaf(TK.ID, names[1].text, names[1].pos);
                const c = try l.leaf(TK.ID, names[2].text, names[2].pos);
                return ir.expr.binary(p, TK.DOT, s, try ir.expr.binary(p, TK.DOT, t, c));
            },
        }
    }

    /// The SQLite database of a PostgreSQL schema.
    fn schemaName(l: *Lowerer, n: ast.Name) Error![]const u8 {
        if (std.mem.eql(u8, n.text, "public")) return "main";
        if (std.mem.eql(u8, n.text, "pg_temp")) return "temp";
        if (build.findDbName(l.p.db, n.text) != null) return n.text;
        return l.fail(n.pos, "schema \"{s}\" does not exist", .{n.text});
    }

    fn binaryExpr(l: *Lowerer, b: ast.Binary) Error!*IrExpr {
        const p = l.p;
        const lhs = try l.expr(b.l);
        const rhs = try l.expr(b.r);
        const op: u8 = switch (b.op) {
            .@"and" => return (try ir.expr.@"and"(p, lhs, rhs)).?,
            .pow => {
                var args = try ir.list.append(p, null, lhs);
                args = try ir.list.append(p, args, rhs);
                return ir.expr.functionCall(p, "power", args);
            },
            .json_get, .json_get_text => {
                var args = try ir.list.append(p, null, lhs);
                args = try ir.list.append(p, args, rhs);
                return ir.expr.function(p, args, Token.init(if (b.op == .json_get) "->" else "->>"), .{});
            },
            .add => TK.PLUS,
            .sub => TK.MINUS,
            .mul => TK.STAR,
            .div => TK.SLASH,
            .mod => TK.REM,
            .concat => TK.CONCAT,
            .eq => TK.EQ,
            .ne => TK.NE,
            .lt => TK.LT,
            .le => TK.LE,
            .gt => TK.GT,
            .ge => TK.GE,
            .@"or" => TK.OR,
            .bit_and => TK.BITAND,
            .bit_or => TK.BITOR,
            .shl => TK.LSHIFT,
            .shr => TK.RSHIFT,
        };
        return ir.expr.binary(p, op, lhs, rhs);
    }

    fn cast(l: *Lowerer, e: *const ast.Expr, c: ast.Cast) Error!*IrExpr {
        const p = l.p;
        // '\x0102'::bytea is a blob constant.
        if (byteaHex(c)) |b| switch (b) {
            .hex => |hex| return l.leaf(TK.BLOB, try std.fmt.allocPrint(l.arena(), "x'{s}'", .{hex}), e.pos),
            .bad_digit => |ch| return l.fail(e.pos, ByteaHex.bad_digit_msg, .{ch}),
            .odd_length => return l.fail(e.pos, ByteaHex.odd_length_msg, .{}),
        };
        const plan = types.castPlan(c.ty) catch |err| return l.typeError(c.ty, err);
        const x = try l.expr(c.e);
        switch (plan) {
            .sqlite => |t| return ir.expr.cast(p, x, Token.init(t)),
            .func => |f| return ir.expr.functionCall(p, f, try ir.list.append(p, null, x)),
            .truncate => |n| {
                var args = try ir.list.append(p, null, try ir.expr.cast(p, x, Token.init("TEXT")));
                args = try ir.list.append(p, args, try l.intConst(1));
                args = try ir.list.append(p, args, try l.intConst(n));
                return ir.expr.functionCall(p, "substr", args);
            },
            .round => |s| {
                var args = try ir.list.append(p, null, x);
                args = try ir.list.append(p, args, try l.intConst(s));
                return ir.expr.cast(p, try ir.expr.functionCall(p, "round", args), Token.init("NUMERIC"));
            },
        }
    }

    pub fn typeError(l: *Lowerer, ty: ast.TypeName, err: types.Error) Error {
        return switch (err) {
            error.Array => l.fail(ty.pos, "arrays are not supported", .{}),
            error.UnknownType => l.fail(ty.pos, "type \"{s}\" does not exist", .{ty.name}),
        };
    }

    fn intConst(l: *Lowerer, v: i64) Error!*IrExpr {
        if (std.math.cast(i32, v)) |x| return expr_mod.exprInt32(l.arena(), x);
        return expr_mod.expr(l.arena(), TK.INTEGER, try std.fmt.allocPrint(l.arena(), "{d}", .{v}));
    }

    fn strConst(l: *Lowerer, s: []const u8) Error!*IrExpr {
        return expr_mod.expr(l.arena(), TK.STRING, s);
    }

    /// Function calls, with PostgreSQL's names mapped to SQLite's and
    /// the rewrites of the special syntax.
    fn func(l: *Lowerer, f: *const ast.Func) Error!*IrExpr {
        const p = l.p;
        const n = f.name.text;
        // Calls that become something else.
        if (specialCall(f)) |sc| switch (sc) {
            .now => {
                if (f.args.len != 0) return l.fail(f.name.pos, "function {s} does not exist", .{n});
                return l.now();
            },
            .localtime => return ir.expr.functionCall(p, "current_time", null),
            .current_user => return ir.expr.functionCall(p, "current_user", null),
            .current_database => return ir.expr.functionCall(p, "current_database", null),
            .date_part => return l.datePart(f),
        };
        const mapped = funcName(n);
        const name_tok = if (mapped.ptr == n.ptr) try l.nameTok(f.name) else Token.init(mapped);
        const sf: int.SF = if (f.distinct) .{ .Distinct = true } else .{};
        const args = if (f.star) null else try l.exprList(f.args);
        const e = try ir.expr.function(p, args, name_tok, sf);
        if (f.order_by.len > 0) {
            if (try l.sortList(f.order_by, &.{})) |ob| try ir.expr.addFunctionOrderBy(p, e, ob);
        }
        if (f.over) |spec| {
            const w = try l.window(spec);
            if (f.filter) |flt| w.filter = try l.expr(flt);
            ir.window.attach(p, e, w);
        } else if (f.filter) |flt| {
            const w = try p.arena.create(int.Window);
            w.* = .{ .e_frm_type = TK.FILTER, .filter = try l.expr(flt) };
            ir.window.attach(p, e, w);
        }
        try l.check();
        return e;
    }

    /// now(): the statement's time as 'YYYY-MM-DD HH:MM:SS.SSS' (UTC,
    /// no zone), which SQLite's date functions read back.
    fn now(l: *Lowerer) Error!*IrExpr {
        const p = l.p;
        var args = try ir.list.append(p, null, try l.strConst("%Y-%m-%d %H:%M:%f"));
        args = try ir.list.append(p, args, try l.strConst("now"));
        return ir.expr.functionCall(p, "strftime", args);
    }

    /// date_part('field', x) (and EXTRACT(field FROM x)) with strftime().
    fn datePart(l: *Lowerer, f: *const ast.Func) Error!*IrExpr {
        const p = l.p;
        if (f.args.len != 2 or f.args[0].kind != .string) return l.fail(f.name.pos, "function date_part with these arguments is not supported", .{});
        const plan = datePartPlan(f.args[0].kind.string) orelse
            return l.fail(f.args[0].pos, "unit \"{s}\" not recognized for type timestamp", .{f.args[0].kind.string});
        const x = try l.expr(f.args[1]);
        if (plan.func) |fname| return ir.expr.functionCall(p, fname, try ir.list.append(p, null, x));
        var args = try ir.list.append(p, null, try l.strConst(plan.fmt));
        args = try ir.list.append(p, args, x);
        const s = try ir.expr.functionCall(p, "strftime", args);
        var v = try ir.expr.cast(p, s, Token.init(plan.cast));
        if (plan.quarter) {
            v = try ir.expr.binary(p, TK.PLUS, v, try l.intConst(2));
            v = try ir.expr.binary(p, TK.SLASH, v, try l.intConst(3));
        }
        return v;
    }

    // ========================================================== windows

    fn window(l: *Lowerer, spec: *const ast.WindowSpec) Error!*int.Window {
        const p = l.p;
        if (spec.name_only) {
            const w = try p.arena.create(int.Window);
            w.* = .{ .name = try p.arena.dupeSentinel(u8, spec.base.?.text, 0) };
            return w;
        }
        var frame: ?*int.Window = null;
        if (spec.frame) |fr| {
            const unit: i32 = switch (fr.unit) {
                .rows => TK.ROWS,
                .range => TK.RANGE,
                .groups => TK.GROUPS,
            };
            const s = try l.bound(fr.start);
            const e = if (fr.end) |b| try l.bound(b) else BoundIr{ .t = TK.CURRENT, .e = null };
            const excl: u8 = switch (fr.exclude) {
                .none => 0,
                .no_others => TK.NO,
                .current_row => TK.CURRENT,
                .group => TK.GROUP,
                .ties => TK.TIES,
            };
            frame = try ir.window.alloc(p, unit, s.t, s.e, e.t, e.e, excl);
        } else {
            frame = try ir.window.alloc(p, 0, TK.UNBOUNDED, null, TK.CURRENT, null, 0);
        }
        const partition = try l.exprList(spec.partition);
        const order = try l.sortList(spec.order_by, &.{});
        const base: ?Token = if (spec.base) |b| try l.nameTok(b) else null;
        const w = try ir.window.assemble(p, frame, partition, order, base);
        try l.check();
        return w orelse error.Failed;
    }

    const BoundIr = struct { t: i32, e: ?*IrExpr };

    fn bound(l: *Lowerer, b: ast.Bound) Error!BoundIr {
        return switch (b.kind) {
            .unbounded_preceding, .unbounded_following => .{ .t = TK.UNBOUNDED, .e = null },
            .current_row => .{ .t = TK.CURRENT, .e = null },
            .preceding => .{ .t = TK.PRECEDING, .e = try l.expr(b.expr.?) },
            .following => .{ .t = TK.FOLLOWING, .e = try l.expr(b.expr.?) },
        };
    }

    // ======================================================== ORDER BY

    /// ORDER BY items; `from` (the FROM of the query, if it is one
    /// SELECT) tells which columns cannot be NULL.
    fn sortList(l: *Lowerer, items: []const ast.SortItem, from_items: []const ast.FromItem) Error!?*ExprList {
        const p = l.p;
        var list: ?*ExprList = null;
        for (items) |it| {
            list = try ir.list.append(p, list, try l.expr(it.expr));
            const desc = it.dir == .desc;
            const nulls: i32 = switch (it.nulls) {
                .first => SO.asc,
                .last => SO.desc,
                // PostgreSQL: NULLs sort as if larger than any value.
                .default => if (desc) SO.asc else if (l.neverNull(it.expr, from_items)) SO.undef else SO.desc,
            };
            ir.list.setSortOrder(list, if (desc) SO.desc else if (it.dir == .asc) SO.asc else SO.undef, nulls);
        }
        return list;
    }

    /// Whether an ORDER BY name may be a result column (an alias) rather
    /// than a column of the FROM tables.
    fn aliasShadows(c: *const ast.Core, order_by: []const ast.SortItem) bool {
        for (order_by) |it| {
            if (it.expr.kind != .column or it.expr.kind.column.len != 1) continue;
            const name = it.expr.kind.column[0].text;
            for (c.cols) |rc| switch (rc) {
                .expr => |x| if (x.alias) |a| if (std.mem.eql(u8, a.text, name)) return true,
                else => {},
            };
        }
        return false;
    }

    /// Whether `e` is a column that cannot be NULL in the rows of `from`:
    /// NOT NULL or the INTEGER PRIMARY KEY of a table not on the
    /// nullable side of an outer join.
    fn neverNull(l: *Lowerer, e: *const ast.Expr, items: []const ast.FromItem) bool {
        if (e.kind != .column or items.len == 0) return false;
        const names = e.kind.column;
        if (names.len > 2) return false;
        var outer_after = false;
        var found = false;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            const item = items[i];
            const nullable = outer_after or item.join == .left or item.join == .full;
            if (item.join == .right or item.join == .full) outer_after = true;
            if (item.source != .table) {
                if (names.len == 1) return false;
                continue;
            }
            const q = item.source.table;
            if (names.len == 2) {
                const label = if (item.alias) |a| a.name.text else q.name.text;
                if (!std.mem.eql(u8, label, names[0].text)) continue;
            }
            const db: ?[]const u8 = if (q.schema) |s| (if (std.mem.eql(u8, s.text, "public")) "main" else s.text) else null;
            const t = build.findTable(l.p.db, q.name.text, db) orelse return false;
            const col_name = names[names.len - 1].text;
            for (t.cols, 0..) |*c, ci| {
                if (!std.ascii.eqlIgnoreCase(c.name(), col_name)) continue;
                if (found) return false;
                found = true;
                if (nullable) return false;
                if (c.not_null == .None and t.i_pkey != @as(i16, @intCast(ci))) return false;
            }
            if (names.len == 2) return found;
        }
        return found;
    }

    // =========================================================== SELECT

    pub fn select(l: *Lowerer, s: *const ast.Select) Error!*IrSelect {
        const p = l.p;
        var x = try l.body(s.body);
        if (s.order_by.len > 0 or s.limit != null or s.offset != null) {
            // SQLite takes no ORDER BY/LIMIT after VALUES.
            if (x.order_by != null or x.limit != null or s.body.* == .values) x = try l.wrap(x);
            const items: []const ast.FromItem = if (s.body.* == .core and !aliasShadows(s.body.core, s.order_by)) s.body.core.from else &.{};
            x.order_by = try l.sortList(s.order_by, items);
            x.limit = try l.limit(s.limit, s.offset);
        }
        if (s.with) |w| {
            const w_ir = try l.with(w);
            x = ir.select.attachWith(p, x, w_ir) orelse return error.Failed;
        } else {
            ir.select.doubleLink(p, x);
        }
        try l.check();
        return x;
    }

    fn limit(l: *Lowerer, lim: ?*ast.Expr, off: ?*ast.Expr) Error!?*IrExpr {
        const p = l.p;
        if (lim == null and off == null) return null;
        // OFFSET alone: LIMIT -1 OFFSET n.
        const n = if (lim) |x| try l.expr(x) else try ir.expr.binary(p, TK.UMINUS, try l.intConst(1), null);
        const o = if (off) |x| try l.expr(x) else null;
        return ir.expr.binary(p, TK.LIMIT, n, o);
    }

    /// `SELECT * FROM (s)`: a query that can take its own ORDER BY,
    /// LIMIT or WITH, or be an operand of a compound.
    fn wrap(l: *Lowerer, s: *IrSelect) Error!*IrSelect {
        const p = l.p;
        ir.select.doubleLink(p, s);
        const src = try ir.from.appendTerm(p, null, null, null, .{}, s, null);
        return ir.select.new(p, null, src, null, null, null, null, .{}, null);
    }

    /// The query of a body: one SELECT, or the last of a compound.
    fn body(l: *Lowerer, b: *const ast.Body) Error!*IrSelect {
        const p = l.p;
        switch (b.*) {
            .core => |c| return l.core(c),
            .values => |rows| {
                var s = try ir.select.values(p, try l.exprList(rows[0]));
                if (rows.len == 1) return s;
                for (rows[1..]) |row| s = try ir.select.multiValues(p, s, try l.exprList(row));
                ir.select.multiValuesEnd(p, s);
                return s;
            },
            .nested => |inner| return l.select(inner),
            .compound => |c| {
                if (c.all and c.op != .@"union") {
                    return l.fail(0, "{s} ALL is not supported", .{if (c.op == .except) "EXCEPT" else "INTERSECT"});
                }
                var lhs = try l.body(c.left);
                if (c.left.* == .nested and (lhs.order_by != null or lhs.limit != null or lhs.with != null)) lhs = try l.wrap(lhs);
                var rhs = try l.body(c.right);
                if (c.right.* == .nested and (rhs.order_by != null or rhs.limit != null or rhs.with != null)) rhs = try l.wrap(rhs);
                const op: i32 = switch (c.op) {
                    .@"union" => if (c.all) TK.ALL else TK.UNION,
                    .except => TK.EXCEPT,
                    .intersect => TK.INTERSECT,
                };
                const r = try ir.select.compound(p, lhs, op, rhs);
                try l.check();
                return r orelse error.Failed;
            },
        }
    }

    fn core(l: *Lowerer, c: *const ast.Core) Error!*IrSelect {
        const p = l.p;
        const cols = try l.targets(c.cols);
        const src = try l.fromClause(c.from);
        const where = if (c.where) |w| try l.expr(w) else null;
        const group = try l.exprList(c.group_by);
        const having = if (c.having) |h| try l.expr(h) else null;
        const sf: int.SF = if (c.distinct) .{ .Distinct = true } else .{};
        const s = try ir.select.new(p, cols, src, where, group, having, null, sf, null);
        if (c.windows.len > 0) {
            var list: ?*int.Window = null;
            for (c.windows) |nw| {
                const w = try l.window(nw.spec);
                w.name = try p.arena.dupeSentinel(u8, nw.name.text, 0);
                try ir.window.chain(p, w, list);
                w.next_win = list;
                list = w;
            }
            s.win_defn = list;
        }
        try l.check();
        return s;
    }

    /// Result columns (and RETURNING lists).
    pub fn targets(l: *Lowerer, cols: []const ast.ResultCol) Error!?*ExprList {
        const p = l.p;
        var list: ?*ExprList = null;
        for (cols) |rc| switch (rc) {
            .star => |pos| list = try ir.list.star(p, list, l.tokAt(pos, 1)),
            .table_star => |ts| {
                const t = ts.names[ts.names.len - 1];
                if (l.returning_qualifier) |q| if (std.mem.eql(u8, q, t.text)) {
                    list = try ir.list.star(p, list, l.tokAt(ts.star_pos, 1));
                    continue;
                };
                list = try ir.list.tableStar(p, list, try l.nameTok(t), l.tokAt(ts.star_pos, 1));
            },
            .expr => |x| {
                list = try ir.list.append(p, list, try l.expr(x.e));
                if (x.alias) |a| {
                    try ir.list.setName(p, list, try l.nameTok(a), true);
                } else if (ast.columnName(x.e)) |name| {
                    try ir.list.setSpan(p, list, name.ptr, name.ptr + name.len);
                }
            },
        };
        return list;
    }

    fn with(l: *Lowerer, w: *const ast.With) Error!*int.With {
        const p = l.p;
        var out: ?*int.With = null;
        for (w.ctes) |cte| {
            p.has_with = true;
            var cols: ?*ExprList = null;
            for (cte.cols) |c| cols = try ir.list.addIdTerm(p, cols, try l.nameTok(c), false, SO.undef);
            const sel = try l.select(cte.select);
            const m: int.M10d = if (cte.materialized) |m| (if (m) .yes else .no) else .any;
            const x = try ir.with.cte(p, try l.nameTok(cte.name), cols, sel, m);
            out = try ir.with.add(p, out, x);
        }
        try l.check();
        return out orelse error.Failed;
    }

    // ============================================================= FROM

    /// The FROM clause, join types shifted to SQLite's convention.
    pub fn fromClause(l: *Lowerer, items: []const ast.FromItem) Error!?*SrcList {
        if (items.len == 0) return null;
        const list = try l.fromItems(items);
        ir.from.shiftJoinType(list);
        return list;
    }

    fn joinType(l: *Lowerer, item: ast.FromItem) int.JT {
        const p = l.p;
        var words: [2]Token = undefined;
        var n: usize = 0;
        if (item.natural) {
            words[n] = Token.init("natural");
            n += 1;
        }
        switch (item.join) {
            .none, .comma, .inner, .cross => {
                if (n == 0) return .{ .INNER = true };
            },
            .left => {
                words[n] = Token.init("left");
                n += 1;
            },
            .right => {
                words[n] = Token.init("right");
                n += 1;
            },
            .full => {
                words[n] = Token.init("full");
                n += 1;
            },
        }
        return ir.from.joinType(p, words[0], if (n > 1) words[1] else null, null);
    }

    fn fromItems(l: *Lowerer, items: []const ast.FromItem) Error!?*SrcList {
        const p = l.p;
        var list: ?*SrcList = null;
        for (items, 0..) |item, i| {
            if (i > 0) if (list) |sl| if (sl.len() > 0) {
                sl.at(sl.len() - 1).fg.jointype = l.joinType(item);
            };
            var ou: int.OnOrUsing = .{};
            if (item.on) |on| ou.on = try l.expr(on);
            for (item.using) |u| ou.using = try ir.list.idAppend(p, ou.using, try l.nameTok(u));
            const alias: Token = if (item.alias) |a| try l.nameTok(a.name) else .{};
            const alias_cols: []const ast.Name = if (item.alias) |a| a.cols else &.{};
            switch (item.source) {
                .table => |q| {
                    if (try l.catalogView(q)) |sel| {
                        const name_tok = if (item.alias == null) Token.init(q.name.text) else alias;
                        list = try ir.from.appendTerm(p, list, null, null, name_tok, sel, &ou);
                    } else {
                        if (alias_cols.len > 0) return l.fail(alias_cols[0].pos, "column aliases of a table are not supported", .{});
                        if (q.schema) |s| {
                            const db = try l.schemaName(s);
                            list = try ir.from.appendTerm(p, list, Token.init(db), try l.nameTok(q.name), alias, null, &ou);
                        } else {
                            list = try ir.from.appendTerm(p, list, try l.nameTok(q.name), null, alias, null, &ou);
                        }
                    }
                },
                .subquery => |s| {
                    var sel = try l.select(s);
                    if (alias_cols.len > 0) sel = try l.renameColumns(sel, alias_cols);
                    list = try ir.from.appendTerm(p, list, null, null, alias, sel, &ou);
                },
                .func => |f| {
                    if (std.mem.eql(u8, f.name.text, "generate_series")) {
                        // Its column is named after the function or the
                        // alias, as in PostgreSQL (SQLite's is "value").
                        if (alias_cols.len > 1) return l.fail(alias_cols[1].pos, "too many column aliases for generate_series", .{});
                        const col: []const u8 = if (alias_cols.len == 1) alias_cols[0].text else if (item.alias) |a| a.name.text else "generate_series";
                        const inner = try ir.from.appendTerm(p, null, Token.init("generate_series"), null, .{}, null, null);
                        ir.from.funcArgs(inner, try l.exprList(f.args));
                        const cols = try ir.list.append(p, null, try l.leaf(TK.ID, "value", f.name.pos));
                        try ir.list.setName(p, cols, Token.init(col), false);
                        const sub = try ir.select.new(p, cols, inner, null, null, null, null, .{}, null);
                        const label = if (item.alias == null) Token.init("generate_series") else alias;
                        list = try ir.from.appendTerm(p, list, null, null, label, sub, &ou);
                        try l.check();
                        continue;
                    }
                    if (alias_cols.len > 0) return l.fail(alias_cols[0].pos, "column aliases of a function are not supported", .{});
                    const args = try l.exprList(f.args);
                    list = try ir.from.appendTerm(p, list, try l.nameTok(f.name), null, alias, null, &ou);
                    ir.from.funcArgs(list, args);
                },
                .nested => |inner| {
                    const inner_list = try l.fromItems(inner);
                    list = try ir.from.nested(p, list, inner_list, alias, &ou);
                },
            }
            try l.check();
        }
        return list;
    }

    /// `(s) AS x(a, b)`: (WITH xq_alias(a, b) AS (s) SELECT * FROM
    /// xq_alias).
    fn renameColumns(l: *Lowerer, s: *IrSelect, cols: []const ast.Name) Error!*IrSelect {
        const p = l.p;
        var names: ?*ExprList = null;
        for (cols) |c| names = try ir.list.addIdTerm(p, names, try l.nameTok(c), false, SO.undef);
        p.has_with = true;
        const cte = try ir.with.cte(p, Token.init("xq_alias"), names, s, .any);
        const w = try ir.with.add(p, null, cte);
        const src = try ir.from.appendTerm(p, null, Token.init("xq_alias"), null, .{}, null, null);
        const outer = try ir.select.new(p, null, src, null, null, null, null, .{}, null);
        return ir.select.attachWith(p, outer, w) orelse error.Failed;
    }

    /// The query standing for an information_schema or pg_catalog view.
    fn catalogView(l: *Lowerer, q: ast.QName) Error!?*IrSelect {
        const p = l.p;
        const schema: ?[]const u8 = if (q.schema) |s| s.text else null;
        if (schema == null and build.findTable(p.db, q.name.text, null) != null) return null;
        const text = (try views.definition(p, schema, q.name.text)) orelse {
            if (schema) |s| if (std.mem.eql(u8, s, "information_schema") or std.mem.eql(u8, s, "pg_catalog")) {
                return l.fail(q.name.pos, "relation \"{s}.{s}\" does not exist", .{ s, q.name.text });
            };
            return null;
        };
        const parser = @import("parser.zig");
        var ps = parser.Parser.init(p.arena, text, 0, null) catch return l.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text});
        const tree = ps.select() catch return l.fail(q.name.pos, "internal error in the definition of {s}: {s}", .{ q.name.text, ps.err_msg });
        if (ps.toks[ps.i].kind != .eof) return l.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text});
        var sub: Lowerer = .{ .p = p, .src = text };
        return try sub.select(tree);
    }

    // ============================================================== DML

    /// The target of INSERT/UPDATE/DELETE.
    fn target(l: *Lowerer, q: ast.QName, alias: ?ast.Name) Error!?*SrcList {
        const a: Token = if (alias) |x| try l.nameTok(x) else .{};
        if (q.schema) |s| {
            const db = try l.schemaName(s);
            return ir.from.fullName(l.p, Token.init(db), try l.nameTok(q.name), a);
        }
        return ir.from.fullName(l.p, try l.nameTok(q.name), .{}, a);
    }

    /// The table named by `q`, if it exists (the schema is read first).
    fn findTable(l: *Lowerer, q: ast.QName) Error!?*int.Table {
        ir.stmt.readSchema(l.p) catch return error.Failed;
        const db: ?[]const u8 = if (q.schema) |s| try l.schemaName(s) else null;
        return build.findTable(l.p.db, q.name.text, db);
    }

    /// The sequence of an identity column: the argument of a DEFAULT
    /// nextval('seq').
    fn identitySequence(t: *int.Table, c: *const int.Column) ?[]const u8 {
        var d = build.columnExpr(t, c) orelse return null;
        // DEFAULT (expr) is a TK_SPAN over the expression.
        while (d.op == TK.SPAN) d = d.left orelse return null;
        if (d.op != TK.FUNCTION or !std.ascii.eqlIgnoreCase(d.token(), "nextval")) return null;
        const args = d.x.list orelse return null;
        if (args.len() != 1) return null;
        const a = args.at(0).expr.?;
        if (a.op != TK.STRING) return null;
        return a.token();
    }

    /// Fail on a value for a GENERATED ALWAYS identity column.
    fn checkAlways(l: *Lowerer, t: *int.Table, c: *const int.Column, pos: u32, is_update: bool) Error!void {
        if (identitySequence(t, c) == null) return;
        const db = l.p.db;
        const schema = catalog.schemaName(db, t);
        const kind = catalog.get(db, l.arena(), schema, t.name, c.name(), catalog.Key.identity_kind) catch null;
        if (kind) |k| if (std.mem.eql(u8, k, "always")) {
            if (is_update) return l.fail(pos, "column \"{s}\" can only be updated to DEFAULT", .{c.name()});
            return l.fail(pos, "cannot insert a non-DEFAULT value into column \"{s}\"", .{c.name()});
        };
    }

    fn columnIndex(t: *int.Table, name: []const u8) ?usize {
        for (t.cols, 0..) |*c, i| if (std.ascii.eqlIgnoreCase(c.name(), name)) return i;
        return null;
    }

    /// The default of column `c` (a copy), or NULL; nextval() of its
    /// sequence for an identity column.
    fn defaultOf(l: *Lowerer, t: *int.Table, c: *const int.Column) Error!*IrExpr {
        if (identitySequence(t, c)) |seq| return catalog.sequence.nextvalExpr(l.p, seq);
        if (build.columnExpr(t, c)) |d| {
            if (!c.col_flags.intersects(int.COLFLAG.GENERATED)) {
                if (try expr_mod.exprDup(l.arena(), d)) |x| return x;
            }
        }
        return expr_mod.expr(l.arena(), TK.NULL, null);
    }

    /// A string constant assigned to a numeric column (ANY in a STRICT
    /// table): the number it spells, as PostgreSQL reads '1.5' for a
    /// numeric; null if it is not one.
    fn numericLiteral(l: *Lowerer, t: *int.Table, c: *const int.Column, e: *const ast.Expr) Error!?*IrExpr {
        if (e.kind != .string or !t.tab_flags.Strict) return null;
        if (!std.ascii.eqlIgnoreCase(build.columnType(c, ""), "ANY")) return null;
        const s = std.mem.trim(u8, e.kind.string, " ");
        if (s.len == 0) return null;
        if (std.fmt.parseInt(i64, s, 10)) |_| {
            return ir.expr.integer(l.p, Token.init(s));
        } else |_| {}
        for (s) |ch| if (!(std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E')) return null;
        _ = std.fmt.parseFloat(f64, s) catch return null;
        return l.leaf(TK.FLOAT, s, e.pos);
    }

    /// The number of values of the rows of a VALUES or SELECT source,
    /// if the tree tells (no `*`).
    fn valuesWidth(s: *const ast.Select) ?usize {
        var b = s.body;
        while (true) switch (b.*) {
            .values => |rows| return rows[0].len,
            .core => |c| {
                for (c.cols) |rc| if (rc != .expr) return null;
                return c.cols.len;
            },
            .compound => |x| b = x.left,
            .nested => |n| b = n.body,
        };
    }

    /// An identity column an INSERT leaves out, and its sequence.
    const Fill = struct { col: *int.Column, seq: []const u8 };

    /// The columns an INSERT assigns, in order.
    fn insertColumns(l: *Lowerer, t: *int.Table, names: []const ast.Name) Error![]?*int.Column {
        var out: std.ArrayList(?*int.Column) = .empty;
        if (names.len > 0) {
            for (names) |c| try out.append(l.arena(), if (columnIndex(t, c.text)) |i| &t.cols[i] else null);
        } else {
            for (t.cols) |*c| if (!c.col_flags.intersects(int.COLFLAG.NOINSERT)) try out.append(l.arena(), c);
        }
        return out.items;
    }

    fn insert(l: *Lowerer, ins: *const ast.Insert) Error!void {
        const p = l.p;
        if (ins.with) |w| _ = ir.with.push(p, try l.with(w));
        const tab = try l.findTable(ins.table);
        var cols: ?*int.IdList = null;
        // PostgreSQL fills the leading columns with fewer values than
        // columns (the others get their defaults); SQLite wants a list.
        var names: []const ast.Name = ins.cols;
        if (names.len == 0) if (tab) |t| if (ins.source) |src| if (valuesWidth(src)) |n| {
            var all: std.ArrayList(ast.Name) = .empty;
            for (t.cols) |*c| if (!c.col_flags.intersects(int.COLFLAG.NOINSERT)) try all.append(l.arena(), .{ .text = c.name(), .pos = ins.pos });
            if (n < all.items.len) names = all.items[0..n];
        };
        for (names) |c| cols = try ir.list.idAppend(p, cols, try l.nameTok(c));

        // The identity columns the INSERT leaves out get nextval() here:
        // SQLite ignores the DEFAULT of an INTEGER PRIMARY KEY, and with
        // trusted_schema off a DEFAULT (nextval()) is an unsafe use.
        var fills: std.ArrayList(Fill) = .empty;
        if (tab) |t| if (names.len > 0 or ins.source == null) {
            for (t.cols) |*c| {
                if (c.col_flags.intersects(int.COLFLAG.NOINSERT)) continue;
                const seq = identitySequence(t, c) orelse continue;
                var given = false;
                for (names) |n| {
                    if (std.ascii.eqlIgnoreCase(n.text, c.name())) given = true;
                }
                if (!given) try fills.append(l.arena(), .{ .col = c, .seq = seq });
            }
        };

        var sel: ?*IrSelect = null;
        if (ins.source) |src| {
            const assigned: []?*int.Column = if (tab) |t| try l.insertColumns(t, names) else &.{};
            if (src.body.* == .values and src.with == null and src.order_by.len == 0 and src.limit == null and src.offset == null) {
                // VALUES: DEFAULT items, identity checks, the added columns.
                const rows = src.body.values;
                var s: ?*IrSelect = null;
                for (rows, 0..) |row, ri| {
                    var list: ?*ExprList = null;
                    for (row, 0..) |item, ci| {
                        const col: ?*int.Column = if (ci < assigned.len) assigned[ci] else null;
                        const v = if (item.kind == .default) blk: {
                            const t = tab orelse break :blk try l.expr(item);
                            const c = col orelse break :blk try expr_mod.expr(l.arena(), TK.NULL, null);
                            break :blk try l.defaultOf(t, c);
                        } else blk: {
                            if (!ins.overriding and ri == 0) if (tab) |t| if (col) |c| try l.checkAlways(t, c, item.pos, false);
                            if (col) |c| if (try l.numericLiteral(tab.?, c, item)) |x| break :blk x;
                            break :blk try l.expr(item);
                        };
                        list = try ir.list.append(p, list, v);
                    }
                    for (fills.items) |fl| list = try ir.list.append(p, list, try catalog.sequence.nextvalExpr(p, fl.seq));
                    s = if (s) |prev| try ir.select.multiValues(p, prev, list) else try ir.select.values(p, list);
                }
                if (rows.len > 1) ir.select.multiValuesEnd(p, s);
                ir.select.doubleLink(p, s.?);
                sel = s;
            } else {
                if (!ins.overriding) if (tab) |t| for (assigned) |col| if (col) |c| try l.checkAlways(t, c, src.pos, false);
                sel = try l.select(src);
                if (fills.items.len > 0) {
                    // SELECT *, nextval('seq') ... FROM (source)
                    const from_src = try ir.from.appendTerm(p, null, null, null, .{}, sel, null);
                    var list = try ir.list.star(p, null, .{});
                    for (fills.items) |fl| list = try ir.list.append(p, list, try catalog.sequence.nextvalExpr(p, fl.seq));
                    sel = try ir.select.new(p, list, from_src, null, null, null, null, .{}, null);
                }
            }
        } else if (fills.items.len > 0) {
            // DEFAULT VALUES: VALUES (nextval('seq') ...) for the identity
            // columns, the others keep their defaults.
            var list: ?*ExprList = null;
            for (fills.items) |fl| list = try ir.list.append(p, list, try catalog.sequence.nextvalExpr(p, fl.seq));
            sel = try ir.select.values(p, list);
        }
        for (fills.items) |fl| cols = try ir.list.idAppend(p, cols, Token.init(fl.col.name()));

        var upsert: ?*int.Upsert = null;
        if (ins.on_conflict) |oc| {
            var tgt: ?*ExprList = null;
            for (oc.target) |it| {
                tgt = try ir.list.append(p, tgt, try l.expr(it.expr));
                ir.list.setSortOrder(tgt, SO.undef, SO.undef);
            }
            const tw = if (oc.target_where) |w| try l.expr(w) else null;
            var set: ?*ExprList = null;
            var where: ?*IrExpr = null;
            if (oc.update) |items| {
                set = try l.setList(items, tab, false);
                if (oc.where) |w| where = try l.expr(w);
            }
            upsert = try ir.dml.upsertNew(p, tgt, tw, set, where, null);
        }
        if (ins.returning.len > 0) ir.dml.addReturning(p, try l.returning(ins.returning, ins.table, ins.alias));
        try l.check();
        const tgt = try l.target(ins.table, ins.alias);
        ir.dml.insert(p, tgt, sel, cols, .Default, upsert);
    }

    /// A RETURNING list: columns qualified with the target's alias (or
    /// name) are the target's.
    fn returning(l: *Lowerer, cols: []const ast.ResultCol, q: ast.QName, alias: ?ast.Name) Error!?*ExprList {
        const saved = l.returning_qualifier;
        defer l.returning_qualifier = saved;
        l.returning_qualifier = if (alias) |a| a.text else q.name.text;
        return l.targets(cols);
    }

    /// SET items of UPDATE and ON CONFLICT DO UPDATE.
    fn setList(l: *Lowerer, items: []const ast.SetItem, tab: ?*int.Table, check_identity: bool) Error!?*ExprList {
        const p = l.p;
        var list: ?*ExprList = null;
        for (items) |it| {
            if (it.multi) {
                var ids: ?*int.IdList = null;
                for (it.cols) |c| ids = try ir.list.idAppend(p, ids, try l.nameTok(c));
                const v = try l.expr(it.value);
                list = try ir.list.appendVector(p, list, ids, v);
                continue;
            }
            const name = it.cols[0];
            const col: ?*int.Column = if (tab) |t| (if (columnIndex(t, name.text)) |i| &t.cols[i] else null) else null;
            const v = if (it.value.kind == .default) blk: {
                if (tab != null and col != null) break :blk try l.defaultOf(tab.?, col.?);
                break :blk try expr_mod.expr(l.arena(), TK.NULL, null);
            } else blk: {
                if (check_identity) if (tab) |t| if (col) |c| try l.checkAlways(t, c, it.value.pos, true);
                break :blk try l.expr(it.value);
            };
            list = try ir.list.append(p, list, v);
            try ir.list.setName(p, list, try l.nameTok(name), true);
        }
        return list;
    }

    fn update(l: *Lowerer, u: *const ast.Update) Error!void {
        const p = l.p;
        if (u.with) |w| _ = ir.with.push(p, try l.with(w));
        const tab = try l.findTable(u.table);
        const changes = try l.setList(u.sets, tab, true);
        const src = try l.fromClause(u.from);
        const where = if (u.where) |w| try l.expr(w) else null;
        if (u.returning.len > 0) ir.dml.addReturning(p, try l.returning(u.returning, u.table, u.alias));
        try l.check();
        const tgt = try l.target(u.table, u.alias);
        try ir.dml.updateFrom(p, tgt, changes, src, where, .Default);
    }

    fn delete(l: *Lowerer, d: *const ast.Delete) Error!void {
        const p = l.p;
        if (d.with) |w| _ = ir.with.push(p, try l.with(w));
        var where = if (d.where) |w| try l.expr(w) else null;
        if (d.using.len > 0) {
            // DELETE FROM t USING u WHERE c: rowid IN (SELECT t.rowid FROM t, u WHERE c)
            const label: ast.Name = if (d.alias) |a| a else d.table.name;
            var items: std.ArrayList(ast.FromItem) = .empty;
            try items.append(l.arena(), .{ .source = .{ .table = d.table }, .alias = if (d.alias) |a| .{ .name = a } else null });
            for (d.using, 0..) |item, i| {
                var x = item;
                if (i == 0) x.join = .comma;
                try items.append(l.arena(), x);
            }
            const src = try l.fromClause(items.items);
            const rowid = try ir.expr.binary(p, TK.DOT, try l.leaf(TK.ID, label.text, label.pos), try l.leaf(TK.ID, "rowid", d.pos));
            const inner = try ir.select.new(p, try ir.list.append(p, null, rowid), src, where, null, null, null, .{}, null);
            ir.select.doubleLink(p, inner);
            where = try ir.expr.inSelect(p, try l.leaf(TK.ID, "rowid", d.pos), false, inner);
        }
        if (d.returning.len > 0) ir.dml.addReturning(p, try l.returning(d.returning, d.table, d.alias));
        try l.check();
        const tgt = try l.target(d.table, d.alias);
        ir.dml.delete(p, tgt, where, null, null);
    }

    fn truncate(l: *Lowerer, t: *const ast.Truncate) Error!void {
        const p = l.p;
        if (t.tables.len != 1) return l.fail(t.tables[1].name.pos, "TRUNCATE of several tables is not supported", .{});
        const q = t.tables[0];
        const tab = try l.findTable(q) orelse return l.fail(q.name.pos, "relation \"{s}\" does not exist", .{q.name.text});
        ir.dml.delete(p, try l.target(q, null), null, null, null);
        try l.check();
        if (t.restart_identity) {
            const schema = catalog.schemaName(p.db, tab);
            if (catalog.exists(p.db, schema) and catalog.sequence.exists(p.db, schema)) {
                catalog.codeExecFmt(p, schema, "UPDATE %Q.xq_sequence SET last_value=start_value,is_called=0 WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND key=%Q)", &.{
                    .{ .str = schema }, .{ .str = schema }, .{ .str = tab.name }, .{ .str = catalog.Key.identity },
                });
            }
        }
    }
};

/// Whether PostgreSQL collation `name` is SQLite's BINARY.
pub fn isBinaryCollation(name: []const u8) bool {
    return std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX") or
        std.ascii.eqlIgnoreCase(name, "default") or std.ascii.eqlIgnoreCase(name, "ucs_basic");
}

/// The calls (without OVER, FILTER or ORDER BY) that lowering and
/// rendering rewrite: now() and its synonyms (no arguments), localtime,
/// current_role/session_user (current_user()), current_catalog
/// (current_database()), date_part().
pub const SpecialCall = enum { now, localtime, current_user, current_database, date_part };

pub fn specialCall(f: *const ast.Func) ?SpecialCall {
    if (f.over != null or f.filter != null or f.order_by.len > 0) return null;
    const map = std.StaticStringMap(SpecialCall).initComptime(.{
        .{ "now", .now },                   .{ "current_timestamp", .now },
        .{ "localtimestamp", .now },        .{ "transaction_timestamp", .now },
        .{ "statement_timestamp", .now },   .{ "clock_timestamp", .now },
        .{ "localtime", .localtime },       .{ "current_role", .current_user },
        .{ "session_user", .current_user }, .{ "current_catalog", .current_database },
        .{ "date_part", .date_part },
    });
    return map.get(f.name.text);
}

/// A '\x0102'::bytea cast of a string: its hex digits (a blob constant),
/// or what is wrong with them.
pub const ByteaHex = union(enum) {
    hex: []const u8,
    bad_digit: u8,
    odd_length,

    pub const bad_digit_msg = "invalid hexadecimal digit: \"{c}\"";
    pub const odd_length_msg = "invalid hexadecimal data: odd number of digits";
};

/// The bytea literal of cast `c`, null if it is not one.
pub fn byteaHex(c: ast.Cast) ?ByteaHex {
    if (!std.mem.eql(u8, c.ty.name, "bytea") or c.ty.array or c.e.kind != .string) return null;
    const s = c.e.kind.string;
    if (!std.mem.startsWith(u8, s, "\\x")) return null;
    const hex = s[2..];
    for (hex) |ch| if (!std.ascii.isHex(ch)) return .{ .bad_digit = ch };
    if (hex.len % 2 != 0) return .odd_length;
    return .{ .hex = hex };
}

/// The SQLite name of a PostgreSQL function, if it differs (else `n`).
pub fn funcName(n: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "substring", "substr" },   .{ "strpos", "instr" },            .{ "btrim", "trim" },
        .{ "char_length", "length" }, .{ "character_length", "length" }, .{ "bool_and", "min" },
        .{ "bool_or", "max" },        .{ "every", "min" },               .{ "ascii", "unicode" },
        .{ "chr", "char" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], n)) return m[1];
    return n;
}

/// How date_part() (EXTRACT) reads a field with strftime().
pub const DatePart = struct {
    fmt: []const u8 = "",
    cast: []const u8 = "INTEGER",
    quarter: bool = false,
    /// A function of the value instead (epoch: unixepoch()).
    func: ?[]const u8 = null,
};

pub fn datePartPlan(field_arg: []const u8) ?DatePart {
    var buf: [16]u8 = undefined;
    if (field_arg.len > buf.len) return null;
    const field = std.ascii.lowerString(&buf, field_arg);
    const map = [_]struct { []const u8, DatePart }{
        .{ "year", .{ .fmt = "%Y" } },          .{ "month", .{ .fmt = "%m" } },
        .{ "day", .{ .fmt = "%d" } },           .{ "hour", .{ .fmt = "%H" } },
        .{ "minute", .{ .fmt = "%M" } },        .{ "second", .{ .fmt = "%f", .cast = "REAL" } },
        .{ "dow", .{ .fmt = "%w" } },           .{ "doy", .{ .fmt = "%j" } },
        .{ "isodow", .{ .fmt = "%u" } },        .{ "week", .{ .fmt = "%V" } },
        .{ "isoyear", .{ .fmt = "%G" } },       .{ "quarter", .{ .fmt = "%m", .quarter = true } },
        .{ "epoch", .{ .func = "unixepoch" } },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], field)) return m[1];
    return null;
}
