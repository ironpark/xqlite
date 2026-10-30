//! The common IR: the dialect-neutral interface through which a frontend
//! (src/dialect/*/frontend.zig) lowers a statement.
//!
//! A frontend other than SQLite's parses into the syntax tree IR
//! (tree.zig), with its dialect's semantics resolved into explicit nodes,
//! and hands it to lower.zig, which builds the parse tree below, and to
//! render.zig, which writes the SQLite text the schema keeps (see those
//! files and docs/architecture.md).
//!
//! The IR is SQLite's own parse tree (Expr, ExprList, IdList, SrcList,
//! Select, With, Window, Upsert, TriggerStep of src/sql/sqlite_int.zig)
//! together with the code generator entry points that SQLite's grammar
//! actions call: building a tree, then handing it to the statement
//! builders (select, insert, CREATE TABLE ...), which generate VDBE code
//! into the Parse as they go. There is no separate logical plan: the
//! SQLite frontend lowering through this file is what keeps the SQLite
//! dialect's bytecode identical to sqlite3's, and another frontend that
//! builds the same tree gets the same plan.
//!
//! Everything here is a thin alias or a helper moved out of parse.y
//! (marked "parse.y"); behaviour is the C function's, named in each doc
//! comment. Conventions, as in C:
//!  - trees live in p.arena and are freed with the statement;
//!  - builders take ownership of the trees passed to them;
//!  - Token values point into text that lives as long as the statement
//!    (the SQL text, p.arena); identifiers are dequoted by the builders
//!    that take a Token (tokenExpr(), nameFromToken() ...);
//!  - errors are left in the Parse (stmt.errorMsg()): a builder that
//!    fails returns normally (or null), and the frontend may keep
//!    lowering; only allocation failures are Zig errors (Oom);
//!  - statement builders (select.run, dml.insert, ddl.endTable ...)
//!    generate code; the statement ends with stmt.finishCoding().
//!
//! SQLite's grammar (src/parse/parser.zig) is the reference for which
//! builder each construct calls with which arguments; see
//! docs/architecture.md for the frontend contract.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const expr_mod = @import("../sql/expr.zig");
const build = @import("../sql/build.zig");
const sel = @import("../sql/select.zig");
const win = @import("../sql/window.zig");
const trig = @import("../sql/trigger.zig");
const upsert_mod = @import("../sql/upsert.zig");
const insert_mod = @import("../sql/insert.zig");
const delete_mod = @import("../sql/delete.zig");
const update_mod = @import("../sql/update.zig");
const pragma_mod = @import("../sql/pragma.zig");
const vacuum_mod = @import("../sql/vacuum.zig");
const attach_mod = @import("../sql/attach.zig");
const analyze_mod = @import("../sql/analyze.zig");
const alter = @import("../sql/alter.zig");
const vtab_mod = @import("../sql/vtab.zig");
const prepare = @import("../sql/prepare.zig");
const ctype = @import("xqlite_base").ctype;

// ================================================================ types

pub const Parse = int.Parse;
pub const Token = int.Token;
pub const Expr = int.Expr;
pub const ExprList = int.ExprList;
pub const IdList = int.IdList;
pub const SrcList = int.SrcList;
pub const Select = int.Select;
pub const Window = int.Window;
pub const With = int.With;
pub const Cte = int.Cte;
pub const Upsert = int.Upsert;
pub const TriggerStep = int.TriggerStep;
pub const OnOrUsing = int.OnOrUsing;
pub const Oom = int.Oom;
/// Token (and Expr.op) codes: TK.INTEGER, TK.EQ, TK.AND ...
pub const TK = int.TK;
/// Expr.flags (EP_*).
pub const EP = int.EP;
/// Select.sel_flags (SF_*): DISTINCT/ALL, VALUES ...
pub const SF = int.SF;
/// Join types (JT_*).
pub const JT = int.JT;
/// Conflict resolution (OE_*): ON CONFLICT, OR REPLACE, FK actions.
pub const OE = int.OE;
/// Table options (TF_*): .Strict, .WithoutRowid ...
pub const TF = int.TF;
/// SortOrder.asc/.desc/.undef, for ORDER BY and NULLS FIRST/LAST.
pub const SortOrder = int.SortOrder;
/// CTE materialization hint (M10d_*).
pub const M10d = int.M10d;

// ============================================================ statements

/// The statement as a whole.
pub const stmt = struct {
    /// sqlite3FinishCoding(): end the statement (OP_Init's target, the
    /// transactions and schema checks of the tables used). Sets p.rc to
    /// DONE. Called once, after the last builder of a statement.
    pub const finishCoding = build.finishCoding;
    /// sqlite3ReadSchema(): read the schema now, if not yet read (most
    /// builders do it themselves).
    pub const readSchema = prepare.readSchema;
    /// sqlite3ErrorMsg(): leave an error in the Parse (Zig format).
    pub const errorMsg = util.errorMsg;
    /// sqlite3ErrorMsg() with %T: the error is about the text at `z`,
    /// whose offset sqlite3_error_offset() reports.
    pub const errorMsgAt = util.errorMsgAt;

    /// parse.y parserSyntaxError(): `near "X": syntax error`.
    pub fn syntaxError(p: *Parse, t: Token) void {
        util.errorMsgAt(p, t.z, "near \"{s}\": syntax error", .{t.slice()});
    }

    /// EXPLAIN (1) or EXPLAIN QUERY PLAN (2) of the statement: set before
    /// the statement builder runs (parse.y's `explain` rule).
    pub fn setExplain(p: *Parse, mode: u8) void {
        p.explain = mode;
    }

    /// The SELECT statement (parse.y "cmd ::= select"): generate the
    /// code that returns the rows of `s`.
    pub fn select(p: *Parse, s: ?*Select) void {
        var dest: sel.SelectDest = .{ .e_dest = sel.SRT.Output };
        if (!p.db.m_db_flags.EncodingFixed) prepare.readSchema(p) catch return;
        if (s) |x| sel.select(p, x, &dest) catch {};
    }

    /// xqlite: lower SQLite text: run SQLite's grammar over `text` (one
    /// statement, without the final finishCoding()) as part of the
    /// statement being compiled, with the connection's semantic hooks.
    /// This is how a frontend should lower anything that is stored in
    /// the schema (CREATE TABLE/INDEX/VIEW/TRIGGER), since sqlite_schema
    /// keeps the text of the statement and sqlite3 must be able to read
    /// it back: render the SQLite equivalent, lower it with this, add
    /// catalog entries (src/catalog) and finish with finishCoding().
    /// `text` must live as long as the statement (allocate it in
    /// p.arena). Errors are left in `p` as usual (their offsets are
    /// relative to `text`).
    pub fn lowerSqliteText(p: *Parse, text: [:0]const u8) Oom!void {
        const tail = p.tail;
        const hold = p.xq_hold_finish;
        p.xq_hold_finish = true;
        defer {
            p.xq_hold_finish = hold;
            p.tail = tail;
        }
        @import("../parse/tokenize.zig").runParser(p, text) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => {},
        };
        // runParser() makes it OK again on its way in.
        if (p.n_err == 0 and p.rc == int.RC.DONE) p.rc = int.RC.OK;
    }
};

// =========================================================== expressions

pub const expr = struct {
    /// sqlite3PExpr(): an operator node `op` (TK.EQ, TK.PLUS, TK.NOT,
    /// TK.UMINUS ...) over `left` and `right`.
    pub const binary = expr_mod.pExpr;
    /// sqlite3ExprAnd(): `left AND right`, folding constants.
    pub const @"and" = expr_mod.exprAnd;
    /// sqlite3Expr(): a leaf node for text `z` (no dequoting).
    pub const leaf = expr_mod.expr;
    /// sqlite3ExprAlloc(): a leaf node for a token, dequoted if asked.
    pub const alloc = expr_mod.exprAlloc;
    /// sqlite3ExprInt32(): an integer literal.
    pub const int32 = expr_mod.exprInt32;
    /// sqlite3ExprAttachSubtrees().
    pub const attachSubtrees = expr_mod.attachSubtrees;
    /// sqlite3PExprAddSelect(): attach a subquery to a TK.SELECT,
    /// TK.EXISTS or TK.IN node.
    pub const addSelect = expr_mod.pExprAddSelect;
    /// exprSetHeight() + flags propagation, after setting Expr.x by hand.
    pub const setHeightAndFlags = expr_mod.setHeightAndFlags;
    /// sqlite3ExprSetErrorOffset().
    pub const setErrorOffset = expr_mod.setErrorOffset;
    /// The offset of a token in the statement text (Expr.w.iOfst).
    pub const tokenOffset = expr_mod.tokenOffset;
    /// sqlite3ExprAddCollateToken(): `e COLLATE name`.
    pub const collate = expr_mod.addCollateToken;
    /// sqlite3ExprFunction(): a call of the function named by the token.
    pub const function = expr_mod.exprFunction;
    /// sqlite3ExprAddFunctionOrderBy(): `f(args ORDER BY ...)`.
    pub const addFunctionOrderBy = expr_mod.addFunctionOrderBy;
    /// sqlite3ExprAssignVarNumber(): number a parameter (?, ?N, :x, $x).
    pub const assignVarNumber = expr_mod.assignVarNumber;
    /// sqlite3ExprIdToTrueFalse(): TRUE/FALSE identifiers to TK.TRUEFALSE.
    pub const idToTrueFalse = expr_mod.idToTrueFalse;
    /// sqlite3ExprIsConstant().
    pub const isConstant = expr_mod.isConstant;
    /// sqlite3ExprUnmapAndDelete().
    pub const unmapAndDelete = expr_mod.unmapAndDelete;
    /// sqlite3DequoteNumber(): a TK.QNUMBER with digit separators.
    pub const dequoteNumber = util.dequoteNumber;

    /// parse.y tokenExpr(): a leaf for one token (TK.ID, TK.STRING,
    /// TK.FLOAT ...), dequoted if quoted (an identifier or a string).
    pub fn token(p: *Parse, op: u8, t: Token) Oom!*Expr {
        const e = try p.arena.create(Expr);
        e.* = .{
            .op = op,
            .flags = .{ .Leaf = true },
            .u = .{ .token = try p.arena.dupeSentinel(u8, t.slice(), 0) },
            .w = .{ .ofst = expr_mod.tokenOffset(p, t) },
            .n_height = 1,
        };
        if (t.n > 0 and ctype.isQuote(e.u.token.?[0])) util.dequoteExpr(e);
        if (p.inRenameObject()) alter.renameTokenMap(p, e, t);
        return e;
    }

    /// parse.y "term ::= INTEGER": an integer literal from its text, a
    /// 32-bit integer node when it fits.
    pub fn integer(p: *Parse, t: Token) Oom!*Expr {
        const e = if (util.getInt32(t.slice())) |v|
            try expr_mod.exprInt32(p.arena, v)
        else
            try expr_mod.exprAlloc(p.arena, TK.INTEGER, t, false);
        e.w = .{ .ofst = expr_mod.tokenOffset(p, t) };
        return e;
    }

    /// xqlite: a call of the function `name` that is not in the text of
    /// the statement (a frontend's rewrite: MariaDB's `a || b` to
    /// concat(a, b), nextval() for an identity column ...).
    pub fn functionCall(p: *Parse, name: []const u8, args: ?*ExprList) Oom!*Expr {
        const e = try expr_mod.exprAlloc(p.arena, TK.FUNCTION, Token.init(name), true);
        e.x = .{ .list = args };
        e.flags.HasFunc = true;
        expr_mod.setHeightAndFlags(p, e);
        return e;
    }

    /// parse.y sqlite3PExprIsNull(): `left ISNULL` (op TK.ISNULL) or
    /// `left NOTNULL` (TK.NOTNULL), folded for a literal operand.
    pub fn isNull(p: *Parse, op: u8, left: *Expr) Oom!*Expr {
        std.debug.assert(op == TK.ISNULL or op == TK.NOTNULL);
        var e = left;
        while (e.op == TK.UPLUS or e.op == TK.UMINUS) e = e.left.?;
        switch (e.op) {
            TK.INTEGER, TK.STRING, TK.FLOAT, TK.BLOB => return expr_mod.exprInt32(p.arena, @intFromBool(op == TK.NOTNULL)),
            else => return expr_mod.pExpr(p, op, left, null),
        }
    }

    /// parse.y sqlite3PExprIs(): `left IS right` (TK.IS) or `IS NOT`
    /// (TK.ISNOT), as ISNULL/NOTNULL against NULL. IS [NOT] DISTINCT
    /// FROM is IS NOT/IS.
    pub fn is(p: *Parse, op: u8, left: *Expr, right: ?*Expr) Oom!*Expr {
        if (right) |r| if (r.op == TK.NULL) {
            return isNull(p, if (op == TK.IS) TK.ISNULL else TK.NOTNULL, left);
        };
        return expr_mod.pExpr(p, op, left, right);
    }

    /// parse.y "expr ::= expr likeop expr [ESCAPE expr]": `lhs LIKE rhs`
    /// as the function the operator token names (LIKE, GLOB, REGEXP,
    /// MATCH), optionally negated.
    pub fn like(p: *Parse, op: Token, not: bool, lhs: ?*Expr, rhs: ?*Expr, escape: ?*Expr) Oom!*Expr {
        var args = try expr_mod.listAppend(p, null, rhs);
        args = try expr_mod.listAppend(p, args, lhs);
        if (escape) |x| args = try expr_mod.listAppend(p, args, x);
        var e = try expr_mod.exprFunction(p, args, op, .{});
        if (not) e = try expr_mod.pExpr(p, TK.NOT, e, null);
        e.flags.InfixFunc = true;
        return e;
    }

    /// parse.y "expr ::= expr between_op expr AND expr".
    pub fn between(p: *Parse, e_arg: ?*Expr, not: bool, low: ?*Expr, high: ?*Expr) Oom!*Expr {
        var bounds = try expr_mod.listAppend(p, null, low);
        bounds = try expr_mod.listAppend(p, bounds, high);
        var e = try expr_mod.pExpr(p, TK.BETWEEN, e_arg, null);
        e.x = .{ .list = bounds };
        expr_mod.setHeightAndFlags(p, e);
        if (not) e = try expr_mod.pExpr(p, TK.NOT, e, null);
        return e;
    }

    /// parse.y "expr ::= LP nexprlist COMMA expr RP": a row value.
    pub fn vector(p: *Parse, items: *ExprList) Oom!*Expr {
        const e = try expr_mod.pExpr(p, TK.VECTOR, null, null);
        e.x = .{ .list = items };
        for (items.slice()) |item| e.flags.set(item.expr.?.flags.only(EP.Propagate));
        return e;
    }

    /// parse.y "expr ::= CASE case_operand case_exprlist case_else END":
    /// `when_then` holds WHEN and THEN expressions in turn.
    pub fn case(p: *Parse, operand: ?*Expr, when_then: ?*ExprList, @"else": ?*Expr) Oom!*Expr {
        const e = try expr_mod.pExpr(p, TK.CASE, operand, null);
        e.x = .{ .list = if (@"else" != null) try expr_mod.listAppend(p, when_then, @"else") else when_then };
        expr_mod.setHeightAndFlags(p, e);
        return e;
    }

    /// parse.y "expr ::= CAST LP expr AS typetoken RP".
    pub fn cast(p: *Parse, e_arg: ?*Expr, type_name: Token) Oom!*Expr {
        const e = try expr_mod.exprAlloc(p.arena, TK.CAST, type_name, true);
        expr_mod.attachSubtrees(e, e_arg, null);
        return e;
    }

    /// parse.y "expr ::= LP select RP" (TK.SELECT) and "EXISTS LP select
    /// RP" (TK.EXISTS).
    pub fn subquery(p: *Parse, op: u8, s: ?*Select) Oom!*Expr {
        const e = try expr_mod.pExpr(p, op, null, null);
        expr_mod.pExprAddSelect(p, e, s);
        return e;
    }

    /// parse.y "expr ::= expr in_op LP select RP".
    pub fn inSelect(p: *Parse, lhs: ?*Expr, not: bool, s: ?*Select) Oom!*Expr {
        var e = try expr_mod.pExpr(p, TK.IN, lhs, null);
        expr_mod.pExprAddSelect(p, e, s);
        if (not) e = try expr_mod.pExpr(p, TK.NOT, e, null);
        return e;
    }

    /// parse.y "expr ::= expr in_op LP exprlist RP": `lhs [NOT] IN
    /// (list)`, with SQLite's rewrites of an empty list and of a single
    /// constant.
    pub fn inList(p: *Parse, lhs: *Expr, not: bool, list_opt: ?*ExprList) Oom!*Expr {
        var lhs_e = lhs;
        const items = list_opt orelse {
            // "x IN ()" is false and "x NOT IN ()" true; but if x contains a
            // function (maybe an aggregate) keep evaluating it.
            const b = try expr_mod.expr(p.arena, TK.STRING, if (not) "true" else "false");
            _ = expr_mod.idToTrueFalse(b);
            if (!lhs_e.flags.HasFunc) {
                expr_mod.unmapAndDelete(p, lhs_e);
                return b;
            }
            return expr_mod.pExpr(p, if (not) TK.OR else TK.AND, b, lhs_e);
        };
        var rhs = items.at(0).expr.?;
        if (items.len() == 1 and expr_mod.isConstant(p, rhs) and rhs.op != TK.COLLATE and lhs_e.op != TK.VECTOR) {
            // "x IN (y)" is "x = +y".
            items.at(0).expr = null;
            rhs = try expr_mod.pExpr(p, TK.UPLUS, rhs, null);
            lhs_e = try expr_mod.pExpr(p, TK.EQ, lhs_e, rhs);
        } else if (items.len() == 1 and rhs.op == TK.SELECT) {
            lhs_e = try expr_mod.pExpr(p, TK.IN, lhs_e, null);
            expr_mod.pExprAddSelect(p, lhs_e, rhs.x.select);
            rhs.x = .{ .select = null };
        } else {
            lhs_e = try expr_mod.pExpr(p, TK.IN, lhs_e, null);
            if (lhs_e.left.?.op == TK.VECTOR) {
                const n = lhs_e.left.?.x.list.?.len();
                if (try expr_mod.listToValues(p, n, items)) |values| {
                    select.doubleLink(p, values);
                    expr_mod.pExprAddSelect(p, lhs_e, values);
                }
            } else {
                lhs_e.x = .{ .list = items };
                expr_mod.setHeightAndFlags(p, lhs_e);
            }
        }
        if (not) lhs_e = try expr_mod.pExpr(p, TK.NOT, lhs_e, null);
        return lhs_e;
    }

    /// parse.y "expr ::= expr in_op nm dbnm paren_exprlist": `lhs IN
    /// table` or `lhs IN table_function(args)`.
    pub fn inTable(p: *Parse, lhs: ?*Expr, not: bool, name: Token, database: Token, args: ?*ExprList) Oom!*Expr {
        const src = try build.srcListAppend(p, null, name, database);
        const s = try sel.selectNew(p, null, src, null, null, null, null, .{}, null);
        if (args) |a| build.srcListFuncArgs(src, a);
        return inSelect(p, lhs, not, s);
    }
};

// ================================================================ lists

/// ExprList (result columns, arguments, ORDER BY ...) and IdList.
pub const list = struct {
    /// sqlite3ExprListAppend().
    pub const append = expr_mod.listAppend;
    /// sqlite3ExprListAppendVector(): `(a, b) = expr` of UPDATE SET.
    pub const appendVector = expr_mod.listAppendVector;
    /// sqlite3ExprListSetName(): the AS name (or SET column) of the last
    /// item.
    pub const setName = expr_mod.listSetName;
    /// sqlite3ExprListSetSpan(): the text of the last item (the name of a
    /// result column without AS).
    pub const setSpan = expr_mod.listSetSpan;
    /// sqlite3ExprListSetSortOrder(): ASC/DESC and NULLS FIRST/LAST of
    /// the last item.
    pub const setSortOrder = expr_mod.listSetSortOrder;
    /// sqlite3ExprListCheckLength().
    pub const checkLength = expr_mod.listCheckLength;
    /// sqlite3ExprListToValues(): `(a,b) IN ((1,2),(3,4))`.
    pub const toValues = expr_mod.listToValues;
    /// sqlite3IdListAppend().
    pub const idAppend = build.idListAppend;

    /// parse.y "selcollist ::= sclp scanpt expr scanpt as": append a
    /// result column, `alias` (empty for none) or the text from `span_start`
    /// to `span_end` naming it.
    pub fn resultColumn(p: *Parse, prior: ?*ExprList, e: ?*Expr, alias: Token, span_start: ?[*]const u8, span_end: ?[*]const u8) Oom!*ExprList {
        const l = try expr_mod.listAppend(p, prior, e);
        if (alias.n > 0) try expr_mod.listSetName(p, l, alias, true);
        try expr_mod.listSetSpan(p, l, span_start, span_end);
        return l;
    }

    /// parse.y "selcollist ::= sclp scanpt STAR": `*`.
    pub fn star(p: *Parse, prior: ?*ExprList, t: Token) Oom!*ExprList {
        const e = try expr_mod.expr(p.arena, TK.ASTERISK, null);
        expr_mod.setErrorOffset(e, expr_mod.tokenOffset(p, t));
        return expr_mod.listAppend(p, prior, e);
    }

    /// parse.y "selcollist ::= sclp scanpt nm DOT STAR": `table.*`.
    pub fn tableStar(p: *Parse, prior: ?*ExprList, table: Token, star_tok: Token) Oom!*ExprList {
        const right = try expr_mod.pExpr(p, TK.ASTERISK, null, null);
        expr_mod.setErrorOffset(right, expr_mod.tokenOffset(p, star_tok));
        const left = try expr.token(p, TK.ID, table);
        const dot = try expr_mod.pExpr(p, TK.DOT, left, right);
        return expr_mod.listAppend(p, prior, dot);
    }

    /// parse.y parserAddExprIdListTerm(): a name in a column list of
    /// CREATE INDEX/VIEW, CTE or UNIQUE, where COLLATE and ASC/DESC are
    /// accepted only while reading the schema.
    pub fn addIdTerm(p: *Parse, prior: ?*ExprList, id: Token, has_collate: bool, sort_order: i32) Oom!*ExprList {
        const l = try expr_mod.listAppend(p, prior, null);
        if ((has_collate or sort_order != SortOrder.undef) and !p.db.init.busy) {
            util.errorMsg(p, "syntax error after column name \"{s}\"", .{id.slice()});
        }
        try expr_mod.listSetName(p, l, id, true);
        return l;
    }
};

// ================================================================= FROM

/// SrcList: FROM clauses and the targets of INSERT/UPDATE/DELETE/DROP.
pub const from = struct {
    /// sqlite3SrcListAppend(): `[database.]table`.
    pub const append = build.srcListAppend;
    /// sqlite3SrcListAppendFromTerm(): a FROM term (table or subquery)
    /// with its alias and ON/USING.
    pub const appendTerm = build.srcListAppendFromTerm;
    /// sqlite3SrcListAppendList().
    pub const appendList = build.srcListAppendList;
    /// sqlite3SrcListIndexedBy(): INDEXED BY / NOT INDEXED (a token with
    /// no text and length 1).
    pub const indexedBy = build.srcListIndexedBy;
    /// sqlite3SrcListFuncArgs(): the arguments of a table-valued function.
    pub const funcArgs = build.srcListFuncArgs;
    /// sqlite3SrcListShiftJoinType(): after the whole FROM is built.
    pub const shiftJoinType = build.srcListShiftJoinType;
    /// sqlite3JoinType(): the JT of up to three join keywords.
    pub const joinType = sel.joinType;
    /// sqlite3NameFromToken(): a dequoted copy of a name.
    pub const nameFromToken = build.nameFromToken;

    /// parse.y "fullname ::= nm [DOT nm]" and xfullname: `[db.]name`
    /// (`name2` empty for none) as a one-item list, with ALTER TABLE
    /// RENAME's token map. `alias` (xfullname's AS) may be empty.
    pub fn fullName(p: *Parse, name1: Token, name2: Token, alias: Token) Oom!?*SrcList {
        const l = (if (name2.n == 0)
            try build.srcListAppend(p, null, name1, null)
        else
            try build.srcListAppend(p, null, name1, name2)) orelse return null;
        if (p.inRenameObject()) {
            alter.renameTokenMap(p, l.at(0).name, if (name2.n == 0) name1 else name2);
        } else if (alias.n > 0) {
            l.at(0).alias = try build.nameFromToken(p.arena, alias);
        }
        return l;
    }

    /// parse.y "seltablist ::= stl_prefix LP seltablist RP as on_using":
    /// a parenthesized FROM clause. A single term is merged into the outer
    /// list; several become a nested subquery.
    pub fn nested(p: *Parse, prefix: ?*SrcList, inner: ?*SrcList, alias: Token, on_using: *OnOrUsing) Oom!?*SrcList {
        if (prefix == null and alias.n == 0 and on_using.on == null and on_using.using == null) {
            return inner;
        } else if (inner != null and inner.?.len() == 1) {
            const result = try build.srcListAppendFromTerm(p, prefix, null, null, alias, null, on_using);
            if (result) |l| {
                const new = l.at(l.len() - 1);
                const old = inner.?.at(0);
                std.debug.assert(!old.fg.fixed_schema);
                new.name = old.name;
                old.name = null;
                if (old.fg.is_subquery) {
                    new.fg.is_subquery = true;
                    new.u4 = .{ .subq = old.u4.subq };
                    old.u4 = .{ .subq = null };
                    old.fg.is_subquery = false;
                    if (new.u4.subq.?.select.sel_flags.NestedFrom) new.fg.is_nested_from = true;
                } else {
                    new.u4 = .{ .database = old.u4.database };
                    old.u4 = .{ .database = null };
                }
                if (old.fg.is_tab_func) {
                    new.u1 = .{ .func_arg = old.u1.func_arg };
                    old.u1 = .{ .func_arg = null };
                    old.fg.is_tab_func = false;
                    new.fg.is_tab_func = true;
                } else if (old.fg.is_indexed_by) {
                    new.u1 = .{ .indexed_by = old.u1.indexed_by };
                    old.u1 = .{ .indexed_by = null };
                    old.fg.is_indexed_by = false;
                    new.fg.is_indexed_by = true;
                }
                new.fg.not_indexed = old.fg.not_indexed;
            }
            return result;
        } else {
            build.srcListShiftJoinType(inner);
            const sub = try sel.selectNew(p, null, inner, null, null, null, null, .{ .NestedFrom = true }, null);
            return build.srcListAppendFromTerm(p, prefix, null, null, alias, sub, on_using);
        }
    }
};

// =============================================================== SELECT

pub const select = struct {
    /// sqlite3SelectNew(): one SELECT core (columns, FROM, WHERE, GROUP
    /// BY, HAVING, ORDER BY, flags, LIMIT). A LIMIT is a TK.LIMIT node
    /// over the limit and the offset.
    pub const new = sel.selectNew;
    /// sqlite3SelectOpName().
    pub const opName = sel.selectOpName;
    /// sqlite3MultiValues(): add a row to a multi-row VALUES.
    pub const multiValues = insert_mod.multiValues;
    /// sqlite3MultiValuesEnd().
    pub const multiValuesEnd = insert_mod.multiValuesEnd;

    /// parse.y parserDoubleLinkSelect(): set the `next` links of a
    /// compound and check its ORDER BY/LIMIT placement and size. Called
    /// on the last SELECT of a compound once it is complete.
    pub fn doubleLink(p: *Parse, s: *Select) void {
        if (s.prior == null) return;
        var next: ?*Select = null;
        var loop: *Select = s;
        var cnt: i32 = 1;
        while (true) {
            loop.next = next;
            loop.sel_flags.Compound = true;
            next = loop;
            loop = loop.prior orelse break;
            cnt += 1;
            if (loop.order_by != null or loop.limit != null) {
                util.errorMsg(p, "{s} clause should come after {s} not before", .{
                    if (loop.order_by != null) "ORDER BY" else "LIMIT",
                    sel.selectOpName(next.?.op),
                });
                break;
            }
        }
        const mx = p.db.limit(.compound_select);
        if (!s.sel_flags.intersects(.{ .MultiValue = true, .Values = true }) and mx > 0 and cnt > mx) {
            util.errorMsg(p, "too many terms in compound SELECT", .{});
        }
    }

    /// parse.y attachWithToSelect(): `WITH ... select`.
    pub fn attachWith(p: *Parse, s_arg: ?*Select, w: ?*With) ?*Select {
        const s = s_arg orelse return null;
        s.with = w;
        doubleLink(p, s);
        return s;
    }

    /// parse.y "selectnowith ::= selectnowith multiselect_op oneselect":
    /// `lhs op rhs` with op TK.UNION, TK.ALL (UNION ALL), TK.EXCEPT or
    /// TK.INTERSECT.
    pub fn compound(p: *Parse, lhs: ?*Select, op: i32, rhs_arg: ?*Select) Oom!?*Select {
        var rhs = rhs_arg;
        if (rhs) |r| if (r.prior != null) {
            doubleLink(p, r);
            const src = try build.srcListAppendFromTerm(p, null, null, null, .{}, r, null);
            rhs = try sel.selectNew(p, null, src, null, null, null, null, .{}, null);
        };
        if (rhs) |r| {
            r.op = @intCast(op);
            r.prior = lhs;
            if (lhs) |l| l.sel_flags.MultiValue = false;
            r.sel_flags.MultiValue = false;
            if (op != TK.ALL) p.has_compound = true;
        }
        return rhs;
    }

    /// parse.y "values ::= VALUES LP nexprlist RP": the first row.
    pub fn values(p: *Parse, row: ?*ExprList) Oom!*Select {
        return sel.selectNew(p, row, null, null, null, null, null, .{ .Values = true }, null);
    }
};

// ======================================================== WITH, windows

pub const with = struct {
    /// sqlite3CteNew().
    pub const cte = build.cteNew;
    /// sqlite3WithAdd().
    pub const add = build.withAdd;
    /// sqlite3WithPush(): a WITH clause of INSERT/UPDATE/DELETE, in scope
    /// for the statement.
    pub const push = sel.withPush;
};

pub const window = struct {
    /// sqlite3WindowAlloc(): a frame (RANGE/ROWS/GROUPS, bounds, EXCLUDE).
    pub const alloc = win.windowAlloc;
    /// sqlite3WindowAssemble(): PARTITION BY, ORDER BY and base window.
    pub const assemble = win.windowAssemble;
    /// sqlite3WindowChain(): `WINDOW w2 AS (w1 ...)`.
    pub const chain = win.windowChain;
    /// sqlite3WindowAttach().
    pub const attach = win.windowAttach;
};

// ================================================================== DML

pub const dml = struct {
    /// sqlite3Insert(): INSERT (`sel` null for DEFAULT VALUES; a VALUES
    /// list is a Select).
    pub const insert = insert_mod.insert;
    /// sqlite3Update().
    pub const update = update_mod.update;
    /// sqlite3DeleteFrom().
    pub const delete = delete_mod.deleteFrom;
    /// sqlite3UpsertNew(): ON CONFLICT [target] DO UPDATE/NOTHING (MariaDB's
    /// ON DUPLICATE KEY UPDATE is one without a target).
    pub const upsertNew = upsert_mod.upsertNew;
    /// sqlite3AddReturning(): RETURNING, before the statement builder.
    pub const addReturning = build.addReturning;

    /// parse.y "cmd ::= with UPDATE orconf xfullname indexed_opt SET
    /// setlist from where_opt_ret": UPDATE with a FROM clause.
    pub fn updateFrom(p: *Parse, target_arg: ?*SrcList, changes: ?*ExprList, from_arg: ?*SrcList, where: ?*Expr, on_error: OE) Oom!void {
        var target = target_arg;
        expr_mod.listCheckLength(p, changes, "set list");
        if (from_arg) |f| {
            var from_clause: ?*SrcList = f;
            if (f.len() > 1) {
                const sub = try sel.selectNew(p, null, f, null, null, null, null, .{ .NestedFrom = true }, null);
                from_clause = try build.srcListAppendFromTerm(p, null, null, null, .{}, sub, null);
            }
            if (target) |t| target = try build.srcListAppendList(p, t, from_clause);
        }
        update_mod.update(p, target, changes, where, on_error, null, null, null);
    }
};

// ================================================================== DDL

pub const ddl = struct {
    /// parse.y disableLookaside(): the start of a CREATE statement
    /// (`createkw ::= CREATE`), before startTable() & co.
    pub fn beginCreate(p: *Parse) void {
        p.disable_lookaside += 1;
        @import("../sql/malloc.zig").disableLookaside(p.db);
        p.is_create = true;
        p.u1 = .{ .cr = .{} };
    }

    // CREATE TABLE: startTable, then addColumn and the column
    // constraints for each column, the table constraints, endTable.

    /// sqlite3StartTable().
    pub const startTable = build.startTable;
    /// sqlite3AddColumn(): name and type token; the type text is stored
    /// as written (STRICT tables need INT, INTEGER, REAL, TEXT, BLOB or
    /// ANY: see strictStorageType()).
    pub const addColumn = build.addColumn;
    /// sqlite3AddNotNull().
    pub const addNotNull = build.addNotNull;
    /// sqlite3AddDefaultValue(): the expression and its text.
    pub const addDefaultValue = build.addDefaultValue;
    /// sqlite3AddPrimaryKey(): of the last column (`list` null) or a table
    /// constraint; `autoinc` for AUTOINCREMENT.
    pub const addPrimaryKey = build.addPrimaryKey;
    /// sqlite3AddCheckConstraint().
    pub const addCheckConstraint = build.addCheckConstraint;
    /// sqlite3AddCollateType(): COLLATE of the last column.
    pub const addCollateType = build.addCollateType;
    /// sqlite3AddGenerated(): GENERATED ALWAYS AS (expr) [STORED|VIRTUAL].
    pub const addGenerated = build.addGenerated;
    /// sqlite3CreateForeignKey().
    pub const createForeignKey = build.createForeignKey;
    /// sqlite3DeferForeignKey().
    pub const deferForeignKey = build.deferForeignKey;
    /// sqlite3EndTable(): the table options (TF: .Strict = true for a
    /// STRICT table, .WithoutRowid) or AS SELECT.
    pub const endTable = build.endTable;
    /// sqlite3CreateIndex(): CREATE INDEX, or a UNIQUE constraint of the
    /// table under construction (`tbl_name` null).
    pub const createIndex = build.createIndex;
    /// sqlite3CreateView().
    pub const createView = build.createView;
    /// sqlite3DropTable() (DROP TABLE and DROP VIEW).
    pub const dropTable = build.dropTable;
    /// sqlite3DropIndex().
    pub const dropIndex = build.dropIndex;

    // Triggers: beginTrigger, the steps, finishTrigger.

    /// sqlite3BeginTrigger().
    pub const beginTrigger = trig.beginTrigger;
    /// sqlite3FinishTrigger().
    pub const finishTrigger = trig.finishTrigger;
    /// sqlite3TriggerSelectStep() & co: the steps of a trigger body,
    /// with the text span of each.
    pub const triggerSelectStep = trig.selectStep;
    pub const triggerInsertStep = trig.insertStep;
    pub const triggerUpdateStep = trig.updateStep;
    pub const triggerDeleteStep = trig.deleteStep;
    /// sqlite3DropTrigger().
    pub const dropTrigger = trig.dropTrigger;

    // ALTER TABLE.

    /// sqlite3AlterRenameTable().
    pub const renameTable = alter.renameTable;
    /// sqlite3AlterBeginAddColumn(), addColumn & co, then
    /// sqlite3AlterFinishAddColumn().
    pub const beginAddColumn = alter.beginAddColumn;
    pub const finishAddColumn = alter.finishAddColumn;
    /// sqlite3AlterDropColumn().
    pub const dropColumn = alter.dropColumn;
    /// sqlite3AlterRenameColumn().
    pub const renameColumn = alter.renameColumn;
    /// sqlite3AlterDropConstraint().
    pub const dropConstraint = alter.dropConstraint;
    /// sqlite3AlterSetNotNull().
    pub const setNotNull = alter.setNotNull;
    /// sqlite3AlterAddConstraint().
    pub const addConstraint = alter.addConstraint;
    /// sqlite3RenameTokenMap()/Remap(): ALTER TABLE RENAME rewrites the
    /// schema text through these maps; only the SQLite frontend parses
    /// schema text, so another frontend can ignore them.
    pub const renameTokenMap = alter.renameTokenMap;
    pub const renameTokenRemap = alter.renameTokenRemap;

    // Virtual tables.

    /// sqlite3VtabBeginParse(), the arguments (argInit, argExtend per
    /// token), sqlite3VtabFinishParse().
    pub const beginVtab = vtab_mod.beginParse;
    pub const vtabArgInit = vtab_mod.argInit;
    pub const vtabArgExtend = vtab_mod.argExtend;
    pub const finishVtab = vtab_mod.finishParse;

    /// xqlite: the type to declare in a STRICT table for a dialect's
    /// declared type, by SQLite's affinity rules (sqlite3AffinityType()):
    /// INTEGER, TEXT, BLOB, REAL, or ANY (NUMERIC affinity, which STRICT
    /// has no name for; keep exactness checks in CHECK constraints). The
    /// declared type itself goes to the catalog (catalog.Key.decl_type).
    pub fn strictStorageType(declared: []const u8) [:0]const u8 {
        if (declared.len == 0) return "ANY";
        return switch (build.affinityType(declared, null)) {
            int.Aff.integer => "INTEGER",
            int.Aff.text => "TEXT",
            int.Aff.blob => "BLOB",
            int.Aff.real => "REAL",
            else => "ANY",
        };
    }
};

// ======================================================= other commands

/// Transactions.
pub const txn = struct {
    /// sqlite3BeginTransaction(): TK.DEFERRED, TK.IMMEDIATE or
    /// TK.EXCLUSIVE.
    pub const begin = build.beginTransaction;
    /// sqlite3EndTransaction(): TK.COMMIT or TK.ROLLBACK.
    pub const end = build.endTransaction;
    /// sqlite3Savepoint(): .BEGIN (SAVEPOINT), .RELEASE, .ROLLBACK (TO).
    pub const savepoint = build.savepoint;
    pub const SavepointOp = build.SAVEPOINT;
};

/// Administrative commands.
pub const admin = struct {
    /// sqlite3Pragma(): `PRAGMA [db.]name [= value]`; `minus` for a
    /// negative number.
    pub const pragma = pragma_mod.pragma;
    /// sqlite3Vacuum().
    pub const vacuum = vacuum_mod.vacuum;
    /// sqlite3Attach() / sqlite3Detach().
    pub const attach = attach_mod.attach;
    pub const detach = attach_mod.detach;
    /// sqlite3Analyze().
    pub const analyze = analyze_mod.analyze;
    /// sqlite3Reindex().
    pub const reindex = build.reindex;
};

/// The catalog of dialect metadata and the sequences (src/catalog).
pub const catalog = @import("../catalog/catalog.zig");

/// The syntax tree IR (tree.zig), its lowering into the parse tree
/// (lower.zig) and its SQLite text (render.zig).
pub const tree = @import("tree.zig");
pub const lower = @import("lower.zig");
pub const render = @import("render.zig");

test {
    _ = @import("test.zig");
    _ = @import("roundtrip_test.zig");
}
