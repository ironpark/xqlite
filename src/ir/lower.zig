//! Lowering the syntax tree IR (tree.zig) into SQLite's parse tree with
//! the builders of ir.zig: queries, DML, transaction control and DDL. The
//! builders are called as SQLite's grammar (src/parse/parser.zig) calls
//! them, so a tree without dialect-specific nodes gets SQLite's own plan
//! and bytecode. DDL is rendered as SQLite text (render.zig) and lowered
//! with ir.stmt.lowerSqliteText(), the dialect metadata recorded in the
//! same statement.
//!
//! Shared semantics every frontend gets from here:
//!
//!  - DML defaults: DEFAULT (tree.Kind.default) as a value of INSERT
//!    VALUES or UPDATE SET, also inside the Coerce of that value, is the
//!    column's default: nextval() of its identity sequence, else a copy of
//!    its DEFAULT expression, else NULL (so an INTEGER PRIMARY KEY without
//!    an identity, MariaDB's AUTO_INCREMENT, gets the next rowid);
//!  - identity columns, as the catalog records them (catalog.Key.identity
//!    and identity_kind of xq_catalog, not the DEFAULT text): an INSERT
//!    that lists its columns, or DEFAULT VALUES, gets nextval() for the
//!    identity columns it leaves out (SQLite ignores the DEFAULT of an
//!    INTEGER PRIMARY KEY, and with trusted_schema off a DEFAULT calling
//!    nextval() is an unsafe use); a value for a GENERATED ALWAYS column
//!    fails without Insert.overriding. CREATE TABLE creates the sequences
//!    of tree.Identity columns and records them; DROP TABLE drops them,
//!    TRUNCATE ... RESTART IDENTITY restarts them;
//!  - ORDER BY ... NULLS LAST on a column that cannot be NULL (NOT NULL,
//!    the INTEGER PRIMARY KEY, not on the nullable side of an outer join)
//!    is lowered without the NULLS clause, so that an index still gives
//!    the order;
//!  - DELETE ... USING and UPDATE/DELETE ... ORDER BY ... LIMIT become a
//!    rowid IN (subquery); a derived column list (`(s) AS x(a, b)`) a CTE;
//!  - a function is called by the name that means it in the connection's
//!    dialect (functionName()).

const std = @import("std");
const ir = @import("ir.zig");
const tree = @import("tree.zig");
const render = @import("render.zig");
const int = @import("../sql/sqlite_int.zig");
const build = @import("../sql/build.zig");
const expr_mod = @import("../sql/expr.zig");
const ctype = @import("../util/ctype.zig");
const catalog = @import("../catalog/catalog.zig");
const dialect = @import("../dialect/dialect.zig");

const sequence = catalog.sequence;
const Parse = int.Parse;
const Token = int.Token;
const IrExpr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const IrSelect = int.Select;
const TK = int.TK;
const SO = int.SortOrder;

pub const Error = error{ OutOfMemory, Failed };

/// The name that calls function `name` in the connection's dialect: with
/// `owner` (a function of that dialect's table), the name itself in that
/// dialect, else xq_<owner>_<name>; without, the name itself, unless the
/// connection's dialect shadows it (xq_sqlite_<name>, SQLite's built-in).
/// `schema`: for text the schema keeps, which any dialect may read: a
/// function of a dialect's table is always qualified.
pub fn functionName(p: *Parse, name: []const u8, owner: ?dialect.Dialect, schema: bool) Error![]const u8 {
    if (owner) |d| {
        if (!schema and p.db.xq.lang.dialect == d) return name;
        return dialect.qualifiedFunctionName(p.arena, d, name);
    }
    if (dialect.functionSearch(p.db, name).len > 0) return std.fmt.allocPrint(p.arena, "xq_sqlite_{s}", .{name});
    return name;
}

pub const Lowerer = struct {
    p: *Parse,
    /// The text the positions of the tree are offsets of.
    src: [:0]const u8,
    /// In a RETURNING list: the name (alias or table) whose qualified
    /// columns are the target's, which SQLite wants unqualified.
    returning_qualifier: ?[]const u8 = null,
    /// The column a value of INSERT VALUES or UPDATE SET is assigned to,
    /// while it is lowered (what DEFAULT stands for).
    value_target: ?ValueTarget = null,
    /// The identity columns of the last table asked for.
    identity_cache: ?struct { tab: *int.Table, cols: []Identity } = null,

    const ValueTarget = struct { tab: ?*int.Table, col: ?*int.Column };

    pub fn init(p: *Parse, src: [:0]const u8) Lowerer {
        return .{ .p = p, .src = src };
    }

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

    fn readSchema(l: *Lowerer) Error!void {
        ir.stmt.readSchema(l.p) catch return error.Failed;
    }

    // ------------------------------------------------------------ tokens

    /// A token for a name: in the text when it is spelled there as is
    /// (for error offsets), else a copy; quoted if it starts with a quote
    /// character, as the builders dequote such tokens.
    pub fn nameTok(l: *Lowerer, n: tree.Name) Error!Token {
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

    fn intConst(l: *Lowerer, v: i64) Error!*IrExpr {
        if (std.math.cast(i32, v)) |x| return expr_mod.exprInt32(l.arena(), x);
        return expr_mod.expr(l.arena(), TK.INTEGER, try std.fmt.allocPrint(l.arena(), "{d}", .{v}));
    }

    fn strConst(l: *Lowerer, s: []const u8) Error!*IrExpr {
        return expr_mod.expr(l.arena(), TK.STRING, s);
    }

    fn nullConst(l: *Lowerer) Error!*IrExpr {
        return expr_mod.expr(l.arena(), TK.NULL, null);
    }

    /// A call of `name` (a SQLite built-in or an engine function), not in
    /// the text.
    fn call(l: *Lowerer, name: []const u8, args: []const *IrExpr) Error!*IrExpr {
        const p = l.p;
        var list: ?*ExprList = null;
        for (args) |x| list = try ir.list.append(p, list, x);
        return ir.expr.functionCall(p, try functionName(p, name, null, false), list);
    }

    // ======================================================= statements

    /// Lower statement `s` (the caller finishes it with
    /// ir.stmt.finishCoding()).
    pub fn statement(l: *Lowerer, s: tree.Stmt) Error!void {
        const p = l.p;
        switch (s) {
            // Lowering looks at the schema (identity and NOT NULL
            // columns): read it first.
            .select, .insert, .update, .delete, .truncate, .explain => try l.readSchema(),
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
            .create_table => |x| try l.createTable(x),
            .create_index => |x| try l.createIndex(x),
            .create_view => |x| try l.createView(x),
            .create_sequence => |x| l.createSequence(x),
            .alter_table => |x| try l.alterTable(x),
            .drop => |x| try l.drop(x),
        }
        try l.check();
    }

    // ====================================================== expressions

    pub fn expr(l: *Lowerer, e: *const tree.Expr) Error!*IrExpr {
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
                const text = if (n) |i| try std.fmt.allocPrint(l.arena(), "?{d}", .{i}) else "?";
                const x = try l.leaf(TK.VARIABLE, text, e.pos);
                try ir.expr.assignVarNumber(p, x, @intCast(x.token().len));
                try l.check();
                return x;
            },
            .default => {
                const vt = l.value_target orelse return l.fail(e.pos, "DEFAULT is not allowed in this context", .{});
                const t = vt.tab orelse return l.nullConst();
                const c = vt.col orelse return l.nullConst();
                return l.defaultOf(t, c);
            },
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
            .div => |d| {
                const lhs = try l.expr(d.l);
                const rhs = try l.expr(d.r);
                return switch (d.kind) {
                    .sqlite => ir.expr.binary(p, TK.SLASH, lhs, rhs),
                    .real => ir.expr.binary(p, TK.SLASH, try ir.expr.cast(p, lhs, Token.init("REAL")), rhs),
                    .int => l.call("xq_div", &.{ lhs, rhs }),
                };
            },
            .compare => |c| {
                var lhs = try l.expr(c.l);
                const rhs = try l.expr(c.r);
                // The left operand's COLLATE decides the comparison's.
                if (c.collation) |coll| lhs = try ir.expr.collate(p, lhs, Token.init(coll), false);
                return switch (c.op) {
                    .is => ir.expr.is(p, TK.IS, lhs, rhs),
                    .is_not => ir.expr.is(p, TK.ISNOT, lhs, rhs),
                    else => ir.expr.binary(p, switch (c.op) {
                        .eq => TK.EQ,
                        .ne => TK.NE,
                        .lt => TK.LT,
                        .le => TK.LE,
                        .gt => TK.GT,
                        .ge => TK.GE,
                        .is, .is_not => unreachable,
                    }, lhs, rhs),
                };
            },
            .concat => |c| {
                switch (c.null_policy) {
                    .propagate => {
                        var x = try l.expr(c.args[0]);
                        for (c.args[1..]) |a| x = try ir.expr.binary(p, TK.CONCAT, x, try l.expr(a));
                        return x;
                    },
                    .skip => return ir.expr.functionCall(p, try functionName(p, "concat", null, false), try l.exprList(c.args)),
                }
            },
            .cast => |c| return l.cast(c),
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
            .like => |x| return l.like(x),
            .is_null => |x| return ir.expr.isNull(p, if (x.not) TK.NOTNULL else TK.ISNULL, try l.expr(x.e)),
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
                return ir.expr.collate(p, x, Token.init(c.collation), false);
            },
            .coerce => |c| return l.coerce(c),
            .identity_default => |d| return sequence.nextvalExpr(p, d.sequence),
            .named_param => |name| {
                const x = try l.leaf(TK.VARIABLE, name, e.pos);
                try ir.expr.assignVarNumber(p, x, @intCast(x.token().len));
                try l.check();
                return x;
            },
        }
    }

    fn boolean(l: *Lowerer, b: bool) Error!*IrExpr {
        const x = try expr_mod.expr(l.arena(), TK.STRING, if (b) "true" else "false");
        _ = ir.expr.idToTrueFalse(x);
        return x;
    }

    pub fn exprList(l: *Lowerer, items: []const *tree.Expr) Error!?*ExprList {
        var list: ?*ExprList = null;
        for (items) |x| list = try ir.list.append(l.p, list, try l.expr(x));
        return list;
    }

    fn column(l: *Lowerer, names: []const tree.Name) Error!*IrExpr {
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
                const s = try l.leaf(TK.ID, names[0].text, names[0].pos);
                const t = try l.leaf(TK.ID, names[1].text, names[1].pos);
                const c = try l.leaf(TK.ID, names[2].text, names[2].pos);
                return ir.expr.binary(p, TK.DOT, s, try ir.expr.binary(p, TK.DOT, t, c));
            },
        }
    }

    fn binaryExpr(l: *Lowerer, b: tree.Binary) Error!*IrExpr {
        const p = l.p;
        const lhs = try l.expr(b.l);
        const rhs = try l.expr(b.r);
        const op: u8 = switch (b.op) {
            .@"and" => {
                // ir.expr.and() folds `x AND 0` to 0, as SQLite's parser does,
                // but not `x AND FALSE` in the text: FALSE is a name until
                // resolved (in ORDER BY the 0 would be a column number).
                const truth: int.EP = .{ .IsTrue = true, .IsFalse = true };
                const saved = .{ lhs.flags, rhs.flags };
                if (b.l.kind == .boolean) lhs.flags.clear(truth);
                if (b.r.kind == .boolean) rhs.flags.clear(truth);
                const x = (try ir.expr.@"and"(p, lhs, rhs)).?;
                lhs.flags = saved[0];
                rhs.flags = saved[1];
                return x;
            },
            .json_get, .json_get_text => {
                var args = try ir.list.append(p, null, lhs);
                args = try ir.list.append(p, args, rhs);
                return ir.expr.function(p, args, Token.init(if (b.op == .json_get) "->" else "->>"), .{});
            },
            .add => TK.PLUS,
            .sub => TK.MINUS,
            .mul => TK.STAR,
            .rem => TK.REM,
            .@"or" => TK.OR,
            .bit_and => TK.BITAND,
            .bit_or => TK.BITOR,
            .shl => TK.LSHIFT,
            .shr => TK.RSHIFT,
        };
        return ir.expr.binary(p, op, lhs, rhs);
    }

    fn cast(l: *Lowerer, c: tree.Cast) Error!*IrExpr {
        const p = l.p;
        const x = try l.expr(c.e);
        switch (c.mode) {
            .affinity => |t| return ir.expr.cast(p, x, Token.init(t)),
            .func => |f| return l.call(f, &.{x}),
            .truncate => |n| return l.call("substr", &.{ try ir.expr.cast(p, x, Token.init("TEXT")), try l.intConst(1), try l.intConst(n) }),
            .round => |s| return ir.expr.cast(p, try l.call("round", &.{ x, try l.intConst(s) }), Token.init("NUMERIC")),
            .typed => |t| return l.call(t.func, &.{ x, try l.strConst(t.type_arg) }),
        }
    }

    /// LIKE: SQLite's operator when it means the same (ASCII letters
    /// folded, the escape SQLite's), else the engine functions xq_like()
    /// (case-sensitive) and xq_ilike() (folding), whose default escape is
    /// `\` ('' for none).
    fn like(l: *Lowerer, x: tree.Like) Error!*IrExpr {
        const p = l.p;
        const lhs = try l.expr(x.e);
        const rhs = try l.expr(x.pat);
        const esc: ?*IrExpr = switch (x.escape) {
            .none => if (x.case_sensitive) try l.strConst("") else null,
            .backslash => null,
            .expr => |z| try l.expr(z),
        };
        const name: []const u8 = if (x.case_sensitive)
            "xq_like"
        else if (x.escape == .backslash)
            "xq_ilike"
        else
            try functionName(p, "like", null, false);
        return ir.expr.like(p, Token.init(name), x.not, lhs, rhs, esc);
    }

    /// xq_coerce(value, type, schema, table, column, flags, row).
    fn coerce(l: *Lowerer, c: tree.Coerce) Error!*IrExpr {
        const mt = @import("../dialect/mariadb/types.zig");
        var flags: i64 = 0;
        if (c.ignore) flags |= mt.coerce_ignore;
        if (c.not_null) flags |= mt.coerce_not_null;
        if (c.missing) flags |= mt.coerce_missing;
        if (c.multi_row) flags |= mt.coerce_multi_row;
        const x = try l.call("xq_coerce", &.{
            try l.expr(c.e),
            try l.strConst(c.decl_type),
            try l.strConst(c.schema),
            try l.strConst(c.table),
            try l.strConst(c.column),
            try l.intConst(flags),
            try l.intConst(c.row),
        });
        // The conversion may fail the statement.
        @import("../sql/main.zig").mayAbort(l.p);
        return x;
    }

    fn func(l: *Lowerer, f: *const tree.Func) Error!*IrExpr {
        const p = l.p;
        const name = try functionName(p, f.name.text, f.dialect, false);
        const name_tok = if (name.ptr == f.name.text.ptr) try l.nameTok(f.name) else Token.init(name);
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

    // ========================================================== windows

    fn window(l: *Lowerer, spec: *const tree.WindowSpec) Error!*int.Window {
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

    fn bound(l: *Lowerer, b: tree.Bound) Error!BoundIr {
        return switch (b.kind) {
            .unbounded_preceding, .unbounded_following => .{ .t = TK.UNBOUNDED, .e = null },
            .current_row => .{ .t = TK.CURRENT, .e = null },
            .preceding => .{ .t = TK.PRECEDING, .e = try l.expr(b.expr.?) },
            .following => .{ .t = TK.FOLLOWING, .e = try l.expr(b.expr.?) },
        };
    }

    // ======================================================== ORDER BY

    /// ORDER BY items; `from_items` (the FROM of the query, if it is one
    /// SELECT) tells which columns cannot be NULL.
    fn sortList(l: *Lowerer, items: []const tree.SortItem, from_items: []const tree.FromItem) Error!?*ExprList {
        const p = l.p;
        var list: ?*ExprList = null;
        for (items) |it| {
            list = try ir.list.append(p, list, try l.expr(it.expr));
            const nulls: i32 = switch (it.nulls) {
                .default => SO.undef,
                .first => SO.asc,
                .last => if (l.neverNull(it.expr, from_items)) SO.undef else SO.desc,
            };
            const dir: i32 = switch (it.dir) {
                .default => SO.undef,
                .asc => SO.asc,
                .desc => SO.desc,
            };
            ir.list.setSortOrder(list, dir, nulls);
        }
        return list;
    }

    /// Whether an ORDER BY name may be a result column (an alias) rather
    /// than a column of the FROM tables.
    fn aliasShadows(c: *const tree.Core, order_by: []const tree.SortItem) bool {
        for (order_by) |it| {
            if (it.expr.kind != .column or it.expr.kind.column.len != 1) continue;
            const name = it.expr.kind.column[0].text;
            for (c.cols) |rc| switch (rc) {
                .expr => |x| if (x.alias) |a| if (ctype.eqlNoCase(a.text, name)) return true,
                else => {},
            };
        }
        return false;
    }

    /// Whether `e` is a column that cannot be NULL in the rows of `items`:
    /// NOT NULL or the INTEGER PRIMARY KEY of a table not on the nullable
    /// side of an outer join.
    fn neverNull(l: *Lowerer, e: *const tree.Expr, items: []const tree.FromItem) bool {
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
                if (!ctype.eqlNoCase(label, names[0].text)) continue;
            }
            const db: ?[]const u8 = if (q.schema) |s| s.text else null;
            const t = build.findTable(l.p.db, q.name.text, db) orelse return false;
            const col_name = names[names.len - 1].text;
            for (t.cols, 0..) |*c, ci| {
                if (!ctype.eqlNoCase(c.name(), col_name)) continue;
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

    pub fn select(l: *Lowerer, s: *const tree.Select) Error!*IrSelect {
        const p = l.p;
        const saved_src = l.src;
        const saved_target = l.value_target;
        defer {
            l.src = saved_src;
            l.value_target = saved_target;
        }
        if (s.src) |text| l.src = text;
        l.value_target = null;
        var x = try l.body(s.body);
        // A query takes one WITH: a nested query's is kept in a subquery.
        if (s.with != null and x.with != null) x = try l.wrap(x);
        if (s.order_by.len > 0 or s.limit != null or s.offset != null) {
            // SQLite takes no ORDER BY/LIMIT after VALUES: wrapped where
            // render.zig wraps, so that the text is the same query (the
            // subquery may sort, and LIMIT pick rows, otherwise).
            if (x.order_by != null or x.limit != null or render.Renderer.tail(s.body) != .plain) x = try l.wrap(x);
            const items: []const tree.FromItem = if (s.body.* == .core and !aliasShadows(s.body.core, s.order_by)) s.body.core.from else &.{};
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

    fn limit(l: *Lowerer, lim: ?*tree.Expr, off: ?*tree.Expr) Error!?*IrExpr {
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
    fn body(l: *Lowerer, b: *const tree.Body) Error!*IrSelect {
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

    fn core(l: *Lowerer, c: *const tree.Core) Error!*IrSelect {
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
    pub fn targets(l: *Lowerer, cols: []const tree.ResultCol) Error!?*ExprList {
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
                } else if (x.name) |name| {
                    try ir.list.setSpan(p, list, name.ptr, name.ptr + name.len);
                }
            },
        };
        return list;
    }

    fn with(l: *Lowerer, w: *const tree.With) Error!*int.With {
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
    pub fn fromClause(l: *Lowerer, items: []const tree.FromItem) Error!?*SrcList {
        if (items.len == 0) return null;
        const list = try l.fromItems(items);
        ir.from.shiftJoinType(list);
        return list;
    }

    fn joinType(l: *Lowerer, item: tree.FromItem) int.JT {
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
            .straight => {
                if (n == 0) return .{ .INNER = true, .CROSS = true };
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

    fn fromItems(l: *Lowerer, items: []const tree.FromItem) Error!?*SrcList {
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
            const alias_cols: []const tree.Name = if (item.alias) |a| a.cols else &.{};
            switch (item.source) {
                .table => |q| {
                    if (alias_cols.len > 0) return l.fail(alias_cols[0].pos, "column aliases of a table are not supported", .{});
                    if (q.schema) |s| {
                        list = try ir.from.appendTerm(p, list, try l.nameTok(s), try l.nameTok(q.name), alias, null, &ou);
                    } else {
                        list = try ir.from.appendTerm(p, list, try l.nameTok(q.name), null, alias, null, &ou);
                    }
                },
                .subquery => |s| {
                    var sel = try l.select(s);
                    if (alias_cols.len > 0) sel = try l.renameColumns(sel, alias_cols);
                    list = try ir.from.appendTerm(p, list, null, null, alias, sel, &ou);
                },
                .func => |f| {
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
    fn renameColumns(l: *Lowerer, s: *IrSelect, cols: []const tree.Name) Error!*IrSelect {
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

    // ====================================================== DML defaults

    /// An identity column (catalog.Key.identity) and its sequence.
    pub const Identity = struct { col: *int.Column, sequence: []const u8, always: bool };

    /// The identity columns of `t`, as its catalog records them.
    pub fn identityColumns(l: *Lowerer, t: *int.Table) Error![]Identity {
        if (l.identity_cache) |c| if (c.tab == t) return c.cols;
        const db = l.p.db;
        const schema = catalog.schemaName(db, t);
        var out: std.ArrayList(Identity) = .empty;
        if (catalog.exists(db, schema)) {
            const entries = catalog.entries(db, l.arena(), schema, t.name) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => &.{},
            };
            for (entries) |en| {
                if (!std.mem.eql(u8, en.key, catalog.Key.identity)) continue;
                const i = columnIndex(t, en.col) orelse continue;
                var always = false;
                for (entries) |k| {
                    if (std.mem.eql(u8, k.key, catalog.Key.identity_kind) and ctype.eqlNoCase(k.col, en.col)) always = std.mem.eql(u8, k.value, "always");
                }
                try out.append(l.arena(), .{ .col = &t.cols[i], .sequence = en.value, .always = always });
            }
        }
        l.identity_cache = .{ .tab = t, .cols = out.items };
        return out.items;
    }

    fn identityOf(l: *Lowerer, t: *int.Table, c: *const int.Column) Error!?Identity {
        for (try l.identityColumns(t)) |id| if (id.col == c) return id;
        return null;
    }

    /// Fail on a value for a GENERATED ALWAYS identity column.
    fn checkAlways(l: *Lowerer, t: *int.Table, c: *const int.Column, pos: u32, is_update: bool) Error!void {
        const id = (try l.identityOf(t, c)) orelse return;
        if (!id.always) return;
        if (is_update) return l.fail(pos, "column \"{s}\" can only be updated to DEFAULT", .{c.name()});
        return l.fail(pos, "cannot insert a non-DEFAULT value into column \"{s}\"", .{c.name()});
    }

    fn columnIndex(t: *int.Table, name: []const u8) ?usize {
        for (t.cols, 0..) |*c, i| if (ctype.eqlNoCase(c.name(), name)) return i;
        return null;
    }

    /// The default of column `c` (a copy): nextval() of its identity
    /// sequence, its DEFAULT expression, or NULL.
    pub fn defaultOf(l: *Lowerer, t: *int.Table, c: *const int.Column) Error!*IrExpr {
        if (try l.identityOf(t, c)) |id| return sequence.nextvalExpr(l.p, id.sequence);
        if (build.columnExpr(t, c)) |d| {
            if (!c.col_flags.intersects(int.COLFLAG.GENERATED)) {
                if (try expr_mod.exprDup(l.arena(), d)) |x| return x;
            }
        }
        return l.nullConst();
    }

    /// Lower `e`, the value assigned to column `col` of `tab`.
    fn value(l: *Lowerer, e: *const tree.Expr, tab: ?*int.Table, col: ?*int.Column) Error!*IrExpr {
        const saved = l.value_target;
        defer l.value_target = saved;
        l.value_target = .{ .tab = tab, .col = col };
        return l.expr(e);
    }

    // ============================================================== DML

    /// The target of INSERT/UPDATE/DELETE.
    fn target(l: *Lowerer, q: tree.QName, alias: ?tree.Name) Error!?*SrcList {
        const a: Token = if (alias) |x| try l.nameTok(x) else .{};
        if (q.schema) |s| return ir.from.fullName(l.p, try l.nameTok(s), try l.nameTok(q.name), a);
        return ir.from.fullName(l.p, try l.nameTok(q.name), .{}, a);
    }

    /// The table named by `q`, if it exists (the schema is read first).
    pub fn findTable(l: *Lowerer, q: tree.QName) Error!?*int.Table {
        try l.readSchema();
        return build.findTable(l.p.db, q.name.text, if (q.schema) |s| s.text else null);
    }

    /// The columns an INSERT assigns, in order (null: not a column).
    fn insertColumns(l: *Lowerer, t: *int.Table, names: []const tree.Name) Error![]?*int.Column {
        var out: std.ArrayList(?*int.Column) = .empty;
        if (names.len > 0) {
            for (names) |c| try out.append(l.arena(), if (columnIndex(t, c.text)) |i| &t.cols[i] else null);
        } else {
            for (t.cols) |*c| if (!c.col_flags.intersects(int.COLFLAG.NOINSERT)) try out.append(l.arena(), c);
        }
        return out.items;
    }

    fn onError(oe: tree.OnError) int.OE {
        return switch (oe) {
            .default => .Default,
            .rollback => .Rollback,
            .abort => .Abort,
            .fail => .Fail,
            .ignore => .Ignore,
            .replace => .Replace,
        };
    }

    fn insert(l: *Lowerer, ins: *const tree.Insert) Error!void {
        const p = l.p;
        if (ins.with) |w| _ = ir.with.push(p, try l.with(w));
        const tab = try l.findTable(ins.table);
        var cols: ?*int.IdList = null;
        const names = ins.cols;
        for (names) |c| cols = try ir.list.idAppend(p, cols, try l.nameTok(c));

        // The identity columns the INSERT leaves out.
        var fills: std.ArrayList(Identity) = .empty;
        if (tab) |t| if (names.len > 0 or ins.source == null) {
            for (try l.identityColumns(t)) |id| {
                if (id.col.col_flags.intersects(int.COLFLAG.NOINSERT)) continue;
                for (names) |n| {
                    if (ctype.eqlNoCase(n.text, id.col.name())) break;
                } else try fills.append(l.arena(), id);
            }
        };

        var sel: ?*IrSelect = null;
        if (ins.source) |src| {
            const assigned: []?*int.Column = if (tab) |t| try l.insertColumns(t, names) else &.{};
            if (src.body.* == .values and src.with == null and src.order_by.len == 0 and src.limit == null and src.offset == null) {
                // VALUES: DEFAULT items, identity checks, the added columns.
                const saved_src = l.src;
                defer l.src = saved_src;
                if (src.src) |text| l.src = text;
                const rows = src.body.values;
                var s: ?*IrSelect = null;
                for (rows, 0..) |row, ri| {
                    var list: ?*ExprList = null;
                    for (row, 0..) |item, ci| {
                        const col: ?*int.Column = if (ci < assigned.len) assigned[ci] else null;
                        if (item.kind != .default and !ins.overriding and ri == 0) if (tab) |t| if (col) |c| try l.checkAlways(t, c, item.pos, false);
                        list = try ir.list.append(p, list, try l.value(item, tab, col));
                    }
                    for (fills.items) |fl| list = try ir.list.append(p, list, try sequence.nextvalExpr(p, fl.sequence));
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
                    for (fills.items) |fl| list = try ir.list.append(p, list, try sequence.nextvalExpr(p, fl.sequence));
                    sel = try ir.select.new(p, list, from_src, null, null, null, null, .{}, null);
                }
            }
        } else if (fills.items.len > 0) {
            // DEFAULT VALUES: VALUES (nextval('seq') ...) for the identity
            // columns, the others keep their defaults.
            var list: ?*ExprList = null;
            for (fills.items) |fl| list = try ir.list.append(p, list, try sequence.nextvalExpr(p, fl.sequence));
            sel = try ir.select.values(p, list);
        }
        for (fills.items) |fl| cols = try ir.list.idAppend(p, cols, Token.init(fl.col.name()));

        var upsert: ?*int.Upsert = null;
        if (ins.on_conflict) |oc| {
            var tgt: ?*ExprList = null;
            for (oc.target) |e| {
                tgt = try ir.list.append(p, tgt, try l.expr(e));
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
        ir.dml.insert(p, tgt, sel, cols, onError(ins.on_error), upsert);
    }

    /// A RETURNING list: columns qualified with the target's alias (or
    /// name) are the target's.
    fn returning(l: *Lowerer, cols: []const tree.ResultCol, q: tree.QName, alias: ?tree.Name) Error!?*ExprList {
        const saved = l.returning_qualifier;
        defer l.returning_qualifier = saved;
        l.returning_qualifier = if (alias) |a| a.text else q.name.text;
        return l.targets(cols);
    }

    /// SET items of UPDATE and ON CONFLICT DO UPDATE.
    fn setList(l: *Lowerer, items: []const tree.SetItem, tab: ?*int.Table, check_identity: bool) Error!?*ExprList {
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
            if (check_identity and it.value.kind != .default) if (tab) |t| if (col) |c| try l.checkAlways(t, c, it.value.pos, true);
            list = try ir.list.append(p, list, try l.value(it.value, tab, col));
            try ir.list.setName(p, list, try l.nameTok(name), true);
        }
        return list;
    }

    /// The WHERE of an UPDATE/DELETE with ORDER BY ... LIMIT: rowid IN
    /// (SELECT rowid FROM t WHERE w ORDER BY o LIMIT n); without a LIMIT,
    /// `where` (an ORDER BY alone changes nothing).
    fn limitedWhere(l: *Lowerer, q: tree.QName, alias: ?tree.Name, where: ?*IrExpr, order_by: []const tree.SortItem, lim: ?*tree.Expr, pos: u32) Error!?*IrExpr {
        const p = l.p;
        const n = lim orelse return where;
        const src = try l.target(q, alias);
        const cols = try ir.list.append(p, null, try l.leaf(TK.ID, "rowid", pos));
        const order = try l.sortList(order_by, &.{});
        const inner = try ir.select.new(p, cols, src, where, null, null, order, .{}, try ir.expr.binary(p, TK.LIMIT, try l.expr(n), null));
        ir.select.doubleLink(p, inner);
        return ir.expr.inSelect(p, try l.leaf(TK.ID, "rowid", pos), false, inner);
    }

    fn update(l: *Lowerer, u: *const tree.Update) Error!void {
        const p = l.p;
        if (u.with) |w| _ = ir.with.push(p, try l.with(w));
        const tab = try l.findTable(u.table);
        const changes = try l.setList(u.sets, tab, true);
        const src = try l.fromClause(u.from);
        var where = if (u.where) |w| try l.expr(w) else null;
        where = try l.limitedWhere(u.table, u.alias, where, u.order_by, u.limit, u.pos);
        if (u.returning.len > 0) ir.dml.addReturning(p, try l.returning(u.returning, u.table, u.alias));
        try l.check();
        const tgt = try l.target(u.table, u.alias);
        try ir.dml.updateFrom(p, tgt, changes, src, where, onError(u.on_error));
    }

    fn delete(l: *Lowerer, d: *const tree.Delete) Error!void {
        const p = l.p;
        if (d.with) |w| _ = ir.with.push(p, try l.with(w));
        var where = if (d.where) |w| try l.expr(w) else null;
        if (d.using.len > 0) {
            // DELETE FROM t USING u WHERE c: rowid IN (SELECT t.rowid FROM t, u WHERE c)
            const label: tree.Name = if (d.alias) |a| a else d.table.name;
            var items: std.ArrayList(tree.FromItem) = .empty;
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
        where = try l.limitedWhere(d.table, d.alias, where, d.order_by, d.limit, d.pos);
        if (d.returning.len > 0) ir.dml.addReturning(p, try l.returning(d.returning, d.table, d.alias));
        try l.check();
        const tgt = try l.target(d.table, d.alias);
        ir.dml.delete(p, tgt, where, null, null);
    }

    fn truncate(l: *Lowerer, t: *const tree.Truncate) Error!void {
        const p = l.p;
        const tab = try l.findTable(t.table) orelse return l.fail(t.table.name.pos, "no such table: {s}", .{t.table.name.text});
        ir.dml.delete(p, try l.target(t.table, null), null, null, null);
        try l.check();
        if (t.restart_identity) {
            const schema = catalog.schemaName(p.db, tab);
            if (catalog.exists(p.db, schema) and sequence.exists(p.db, catalog.main_schema)) {
                catalog.codeExecFmt(p, schema, "UPDATE main.xq_sequence SET last_value=start_value,is_called=0 WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND key=%Q)", &.{
                    .{ .str = schema }, .{ .str = tab.name }, .{ .str = catalog.Key.identity },
                });
            }
        }
    }

    // ============================================================== DDL

    fn lowerText(l: *Lowerer, text: [:0]const u8) Error!void {
        try ir.stmt.lowerSqliteText(l.p, text);
        try l.check();
    }

    fn renderer(l: *Lowerer) render.Renderer {
        return .{ .p = l.p, .src = l.src };
    }

    /// The name the catalog records as the dialect of what a statement
    /// creates.
    fn dialectName(l: *Lowerer) []const u8 {
        return l.p.db.xq.lang.dialect.name();
    }

    /// CREATE TABLE, and in the same statement its catalog entries (the
    /// dialect, each column's declared type, the identity columns) and
    /// the sequences of its identity columns. Nothing is recorded when
    /// IF NOT EXISTS finds the table.
    pub fn createTable(l: *Lowerer, ct: *const tree.CreateTable) Error!void {
        const p = l.p;
        try l.readSchema();
        const schema: []const u8 = if (ct.temp) "temp" else if (ct.name.schema) |s| s.text else catalog.main_schema;
        const table = ct.name.name.text;
        const exists = build.findTable(p.db, table, schema) != null;
        var r = l.renderer();
        try l.lowerText(try r.createTable(ct));
        if (ct.if_not_exists and exists) return;
        catalog.codeDeleteTable(p, schema, table);
        catalog.codeSet(p, schema, table, "", catalog.Key.dialect, l.dialectName());
        for (ct.columns) |c| try l.recordColumn(schema, table, c, true);
    }

    /// The catalog entries of column `c` of a new table (`create`: and
    /// the sequence of an identity column).
    fn recordColumn(l: *Lowerer, schema: []const u8, table: []const u8, c: tree.ColumnDef, create: bool) Error!void {
        const p = l.p;
        if (c.decl_type) |t| catalog.codeSet(p, schema, table, c.name.text, catalog.Key.decl_type, t);
        for (c.constraints) |cc| if (cc.kind == .identity) {
            if (!create) return l.fail(c.name.pos, "adding an identity or serial column is not supported", .{});
            const id = cc.kind.identity;
            catalog.codeSet(p, schema, table, c.name.text, catalog.Key.identity, id.sequence);
            if (id.always) |a| catalog.codeSet(p, schema, table, c.name.text, catalog.Key.identity_kind, if (a) "always" else "by default");
            sequence.codeCreate(p, catalog.main_schema, id.sequence, seqOptions(id.opts), false);
        };
    }

    pub fn seqOptions(o: tree.SeqOpts) sequence.Options {
        return .{ .start = o.start, .increment = o.increment orelse 1, .min = o.min, .max = o.max, .cycle = o.cycle orelse false };
    }

    pub fn createIndex(l: *Lowerer, ci: *const tree.CreateIndex) Error!void {
        try l.readSchema();
        var r = l.renderer();
        try l.lowerText(try r.createIndex(ci));
    }

    /// CREATE [OR REPLACE] VIEW, and its catalog entry (the dialect).
    pub fn createView(l: *Lowerer, v: *const tree.CreateView) Error!void {
        const p = l.p;
        try l.readSchema();
        const schema: []const u8 = if (v.temp) "temp" else if (v.name.schema) |s| s.text else catalog.main_schema;
        const name = v.name.name.text;
        const exists = build.findTable(p.db, name, schema) != null;
        const replace = v.or_replace and exists;
        if (replace) {
            var drop_text = l.renderer();
            try drop_text.put("DROP VIEW ");
            try drop_text.ident(schema);
            try drop_text.put(".");
            try drop_text.ident(name);
            try l.lowerText(try drop_text.text());
        }
        var r = l.renderer();
        const text = try r.createView(v);
        if (replace) {
            // The old view is still in the schema while this compiles: the
            // new one is created when the statement runs, after the DROP.
            const i_db = catalog.schemaIndex(p, schema) orelse return error.Failed;
            catalog.codeExec(p, i_db, text);
        } else {
            try l.lowerText(text);
        }
        if (v.if_not_exists and exists) return;
        catalog.codeDeleteTable(p, schema, name);
        catalog.codeSet(p, schema, name, "", catalog.Key.dialect, l.dialectName());
    }

    /// CREATE SEQUENCE (in main, as the sequence functions look there).
    pub fn createSequence(l: *Lowerer, s: *const tree.CreateSequence) void {
        sequence.codeCreate(l.p, catalog.main_schema, s.name.name.text, seqOptions(s.opts), s.if_not_exists);
    }

    /// ALTER TABLE, with the catalog following it (renames, a new
    /// column's declared type, a dropped column's entries and identity
    /// sequence).
    pub fn alterTable(l: *Lowerer, a: *const tree.AlterTable) Error!void {
        const p = l.p;
        const tab = try l.findTable(a.name) orelse {
            if (a.if_exists) return;
            return l.fail(a.name.name.pos, "no such table: {s}", .{a.name.name.text});
        };
        const db_name = catalog.schemaName(p.db, tab);
        const table = tab.name;
        switch (a.action) {
            .add_column => |ac| {
                if (ac.if_not_exists and columnIndex(tab, ac.def.name.text) != null) return;
                for (ac.def.constraints) |cc| if (cc.kind == .identity) {
                    return l.fail(ac.def.name.pos, "adding an identity or serial column is not supported", .{});
                };
            },
            .drop_column => |dc| if (dc.if_exists and columnIndex(tab, dc.name.text) == null) return,
            else => {},
        }
        var at = a.*;
        at.name = .{ .schema = .{ .text = db_name }, .name = .{ .text = table, .pos = a.name.name.pos } };
        var r = l.renderer();
        try l.lowerText(try r.alterTable(&at));
        switch (a.action) {
            .rename_to => |n| catalog.codeRenameTable(p, db_name, table, n.text),
            .rename_column => |rc| catalog.codeRenameColumn(p, db_name, table, rc.old.text, rc.new.text),
            .add_column => |ac| try l.recordColumn(db_name, table, ac.def, false),
            .drop_column => |dc| {
                const n = dc.name;
                if (catalog.exists(p.db, db_name) and sequence.exists(p.db, catalog.main_schema)) {
                    catalog.codeExecFmt(p, db_name, "DELETE FROM main.xq_sequence WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q AND key=%Q)", &.{
                        .{ .str = db_name }, .{ .str = table }, .{ .str = n.text }, .{ .str = catalog.Key.identity },
                    });
                }
                catalog.codeDeleteColumn(p, db_name, table, n.text);
            },
        }
    }

    /// DROP TABLE/VIEW (with its catalog entries and identity sequences),
    /// INDEX or SEQUENCE.
    pub fn drop(l: *Lowerer, d: *const tree.Drop) Error!void {
        const p = l.p;
        try l.readSchema();
        const q = d.name;
        const name = q.name.text;
        const db: ?[]const u8 = if (q.schema) |s| s.text else null;
        switch (d.kind) {
            .table, .view => {
                const tab = build.findTable(p.db, name, db);
                ir.ddl.dropTable(p, try l.target(q, null), d.kind == .view, d.if_exists);
                try l.check();
                const t = tab orelse return;
                const db_name = catalog.schemaName(p.db, t);
                if (!catalog.exists(p.db, db_name)) return;
                if (d.kind == .table and sequence.exists(p.db, catalog.main_schema)) {
                    catalog.codeExecFmt(p, db_name, "DELETE FROM main.xq_sequence WHERE name IN (SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND key=%Q)", &.{
                        .{ .str = db_name }, .{ .str = name }, .{ .str = catalog.Key.identity },
                    });
                }
                catalog.codeDeleteTable(p, db_name, name);
            },
            .index => ir.ddl.dropIndex(p, try l.target(q, null), d.if_exists),
            .sequence => sequence.codeDrop(p, catalog.main_schema, name),
        }
    }
};
