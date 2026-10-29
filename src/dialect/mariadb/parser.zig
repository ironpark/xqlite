//! The MariaDB parser: hand-written recursive descent over lexer.zig's
//! tokens that lowers each construct into the IR (src/ir/ir.zig) as it
//! goes, the way SQLite's grammar actions do (src/parse/parser.zig is
//! the model for which builder gets which arguments).
//!
//! This file has the parser core, expressions, SELECT and DML; DDL is in
//! ddl.zig and the session/introspection statements in session.zig.
//!
//! Expressions follow MariaDB's precedence (lowest first): OR / || ,
//! XOR, AND / &&, NOT, comparisons (= <=> <> != < <= > >= IS LIKE
//! REGEXP IN BETWEEN), |, &, << >>, + -, * / DIV % MOD, ^, || under
//! PIPES_AS_CONCAT, unary (- + ~ ! BINARY), COLLATE. Where MariaDB and
//! SQLite disagree the lowering rewrites:
//!  - `a / b` divides as reals (CAST(a AS REAL) / b): 7/2 is 3.5;
//!  - `a DIV b`, `a XOR b`, `a ^ b` call the dialect's xq_div(),
//!    xq_xor() and xq_bitxor();
//!  - `a || b` is OR, or SQLite's || (NULL if an operand is) under
//!    PIPES_AS_CONCAT; `a <=> b` is `a IS b`;
//!  - LIKE has the escape character \ (also under NO_BACKSLASH_ESCAPES);
//!  - function names MariaDB spells differently are renamed
//!    (functionCall()).

const std = @import("std");
const ctype = @import("../../util/ctype.zig");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const expr_mod = @import("../../sql/expr.zig");
const catalog = @import("../../catalog/catalog.zig");
const lexer = @import("lexer.zig");
const state = @import("state.zig");
const types = @import("types.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const With = int.With;
const Window = int.Window;
const TK = int.TK;
const OE = int.OE;
const SF = int.SF;
const JT = int.JT;
const SO = int.SortOrder;

pub const Token = lexer.Token;
pub const Error = int.Oom || int.ParseError;

/// Words that are not names where a name is optional (aliases) or
/// where they would make no sense as one (a column reference).
const reserved = blk: {
    @setEvalBranchQuota(10_000);
    const words = [_][]const u8{
        "ALL",      "AND",           "AS",         "ASC",     "BETWEEN",   "BINARY",  "BY",     "CASE",
        "CHECK",    "COLLATE",       "CONSTRAINT", "CREATE",  "CROSS",     "DEFAULT", "DELETE", "DESC",
        "DISTINCT", "DISTINCTROW",   "DIV",        "DROP",    "DUAL",      "ELSE",    "ESCAPE", "EXCEPT",
        "EXISTS",   "FALSE",         "FETCH",      "FOR",     "FORCE",     "FOREIGN", "FROM",   "GROUP",
        "HAVING",   "HIGH_PRIORITY", "IGNORE",     "IN",      "INDEX",     "INNER",   "INSERT", "INTERSECT",
        "INTERVAL", "INTO",          "IS",         "JOIN",    "KEY",       "LEFT",    "LIKE",   "LIMIT",
        "LOCK",     "LOW_PRIORITY",  "MOD",        "NATURAL", "NOT",       "NULL",    "OFFSET", "ON",
        "OR",       "ORDER",         "OUTER",      "OVER",    "PARTITION", "PRIMARY", "RANGE",  "REFERENCES",
        "REGEXP",   "REPLACE",       "RETURNING",  "RIGHT",   "RLIKE",     "ROWS",    "SELECT", "SEPARATOR",
        "SET",      "STRAIGHT_JOIN", "THEN",       "TRUE",    "UNION",     "UNIQUE",  "UPDATE", "USE",
        "USING",    "VALUES",        "WHEN",       "WHERE",   "WINDOW",    "WITH",    "XOR",
    };
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    break :blk std.StaticStringMapWithEql(void, ctype.eqlNoCase).initComptime(kvs);
};

pub fn isReserved(t: Token) bool {
    return t.kind == .ident and reserved.has(t.text);
}

pub fn irTok(t: Token) int.Token {
    return .{ .z = t.text.ptr, .n = @intCast(t.text.len) };
}

pub const Parser = struct {
    p: *Parse,
    a: std.mem.Allocator,
    lx: lexer.Lexer,
    tok: Token,
    prev_end: [*]const u8,
    mode: state.SqlMode,
    /// Parsing ON DUPLICATE KEY UPDATE: VALUES(col) is the value the
    /// INSERT would have stored (excluded.col).
    in_odku: bool = false,
    /// Parsing the VALUES rows or SET list of INSERT/UPDATE: DEFAULT
    /// stands for the column's default (a TK.DEFAULT marker node).
    allow_default: bool = false,

    pub fn init(p: *Parse, sql: [:0]const u8, mode: state.SqlMode) Parser {
        var s: Parser = .{
            .p = p,
            .a = p.arena,
            .lx = .init(sql, mode),
            .tok = undefined,
            .prev_end = sql.ptr,
            .mode = mode,
        };
        s.tok = s.lx.next();
        return s;
    }

    pub fn advance(s: *Parser) void {
        s.prev_end = s.tok.end();
        s.tok = s.lx.next();
    }

    /// The token after the current one.
    pub fn peek(s: *Parser) Token {
        var copy = s.lx;
        return copy.next();
    }

    /// The token two after the current one.
    pub fn peek2(s: *Parser) Token {
        var copy = s.lx;
        _ = copy.next();
        return copy.next();
    }

    pub fn isKw(s: *Parser, kw: []const u8) bool {
        return s.tok.isKw(kw);
    }

    pub fn eatKw(s: *Parser, kw: []const u8) bool {
        if (!s.tok.isKw(kw)) return false;
        s.advance();
        return true;
    }

    pub fn expectKw(s: *Parser, kw: []const u8) Error!void {
        if (!s.eatKw(kw)) return s.syntaxError();
    }

    /// Whether the current token is one of the keywords `kws`.
    pub fn isAnyKw(s: *Parser, comptime kws: []const []const u8) bool {
        return s.tok.isAnyKw(kws);
    }

    /// An optional IF EXISTS: whether it is there.
    pub fn ifExists(s: *Parser) Error!bool {
        if (!s.eatKw("IF")) return false;
        try s.expectKw("EXISTS");
        return true;
    }

    /// An optional IF NOT EXISTS: whether it is there.
    pub fn ifNotExists(s: *Parser) Error!bool {
        if (!s.eatKw("IF")) return false;
        try s.expectKw("NOT");
        try s.expectKw("EXISTS");
        return true;
    }

    pub fn isOp(s: *Parser, op: []const u8) bool {
        return s.tok.is(op);
    }

    pub fn eatOp(s: *Parser, op: []const u8) bool {
        if (!s.tok.is(op)) return false;
        s.advance();
        return true;
    }

    pub fn expectOp(s: *Parser, op: []const u8) Error!void {
        if (!s.eatOp(op)) return s.syntaxError();
    }

    /// The end of the statement: `;` or the end of the text.
    pub fn atStmtEnd(s: *Parser) bool {
        return s.tok.kind == .eof or s.tok.is(";");
    }

    /// MariaDB's syntax error at the current token.
    pub fn syntaxError(s: *Parser) Error {
        return s.syntaxErrorAt(s.tok);
    }

    pub fn syntaxErrorAt(s: *Parser, t: Token) Error {
        if (s.p.n_err > 0) return error.ParseFailed;
        const rest = std.mem.sliceTo(t.text.ptr, 0);
        const near = rest[0..@min(rest.len, 80)];
        var line: usize = 1;
        for (s.lx.sql[0 .. @intFromPtr(t.text.ptr) - @intFromPtr(s.lx.sql.ptr)]) |c| {
            if (c == '\n') line += 1;
        }
        ir.stmt.errorMsgAt(s.p, t.text.ptr, "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '{s}' at line {d}", .{ near, line });
        return error.ParseFailed;
    }

    /// An error with a message.
    pub fn fail(s: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (s.p.n_err == 0) ir.stmt.errorMsg(s.p, fmt, args);
        return error.ParseFailed;
    }

    /// Fail if a builder left an error.
    pub fn check(s: *Parser) Error!void {
        if (s.p.n_err > 0) return error.ParseFailed;
    }

    /// A name: a word that is not reserved, or a quoted identifier.
    pub fn name(s: *Parser) Error!Token {
        const t = s.tok;
        if (t.kind == .quoted_ident or (t.kind == .ident and !isReserved(t))) {
            s.advance();
            return t;
        }
        return s.syntaxError();
    }

    /// A name, also a reserved word (after a dot, or where only a name
    /// can come).
    pub fn anyName(s: *Parser) Error!Token {
        const t = s.tok;
        if (t.kind == .quoted_ident or t.kind == .ident) {
            s.advance();
            return t;
        }
        return s.syntaxError();
    }

    pub fn isName(s: *Parser) bool {
        return s.tok.kind == .quoted_ident or (s.tok.kind == .ident and !isReserved(s.tok));
    }

    /// The name an IR token of a name stands for (dequoted).
    pub fn tokName(s: *Parser, t: int.Token) Error![]const u8 {
        const z = t.slice();
        const quoted = z.len > 0 and (z[0] == '`' or z[0] == '"');
        return lexer.identValue(s.a, .{ .kind = if (quoted) .quoted_ident else .ident, .text = z });
    }

    /// The name a name token stands for.
    pub fn nameText(s: *Parser, t: Token) Error![]const u8 {
        return lexer.identValue(s.a, t);
    }

    /// A string literal's value (after `_charset` introducers and with
    /// adjacent literals concatenated, as MariaDB does).
    pub fn stringLiteral(s: *Parser) Error![]const u8 {
        if (s.tok.kind == .ident and s.tok.text[0] == '_' and s.peek().kind == .string) s.advance();
        if (s.tok.kind != .string) return s.syntaxError();
        var v = try lexer.stringValue(s.a, s.tok, !s.mode.has(.NO_BACKSLASH_ESCAPES));
        s.advance();
        while (s.tok.kind == .string) {
            const more = try lexer.stringValue(s.a, s.tok, !s.mode.has(.NO_BACKSLASH_ESCAPES));
            v = try std.mem.concat(s.a, u8, &.{ v, more });
            s.advance();
        }
        return v;
    }

    /// `[schema.]name`: (name, schema) as IR tokens in the order of
    /// SQLite's `nm dbnm` (first, second).
    pub fn qualifiedName(s: *Parser) Error!struct { int.Token, int.Token } {
        const first = try s.anyName();
        if (s.isOp(".")) {
            s.advance();
            const second = try s.anyName();
            return .{ irTok(first), irTok(second) };
        }
        return .{ irTok(first), .{} };
    }

    // ====================================================== expressions

    pub fn expr(s: *Parser) Error!*Expr {
        return s.orExpr();
    }

    fn orExpr(s: *Parser) Error!*Expr {
        var l = try s.xorExpr();
        while (s.isKw("OR") or (s.isOp("||") and !s.mode.has(.PIPES_AS_CONCAT))) {
            s.advance();
            const r = try s.xorExpr();
            l = try ir.expr.binary(s.p, TK.OR, l, r);
        }
        return l;
    }

    fn xorExpr(s: *Parser) Error!*Expr {
        var l = try s.andExpr();
        while (s.eatKw("XOR")) {
            const r = try s.andExpr();
            l = try s.call("xq_xor", &.{ l, r });
        }
        return l;
    }

    fn andExpr(s: *Parser) Error!*Expr {
        var l = try s.notExpr();
        while (s.isKw("AND") or s.isOp("&&")) {
            s.advance();
            const r = try s.notExpr();
            l = (try ir.expr.@"and"(s.p, l, r)).?;
        }
        return l;
    }

    fn notExpr(s: *Parser) Error!*Expr {
        if (s.eatKw("NOT")) {
            const e = try s.notExpr();
            return ir.expr.binary(s.p, TK.NOT, e, null);
        }
        return s.predicate();
    }

    fn compareOp(t: Token) ?u8 {
        if (t.kind != .op) return null;
        const ops = [_]struct { []const u8, u8 }{
            .{ "=", TK.EQ },  .{ "<>", TK.NE }, .{ "!=", TK.NE }, .{ "<", TK.LT },
            .{ "<=", TK.LE }, .{ ">", TK.GT },  .{ ">=", TK.GE }, .{ "<=>", TK.IS },
        };
        for (ops) |o| if (std.mem.eql(u8, t.text, o[0])) return o[1];
        return null;
    }

    fn predicate(s: *Parser) Error!*Expr {
        var l = try s.bitOr();
        while (true) {
            if (compareOp(s.tok)) |op| {
                s.advance();
                if (s.isAnyKw(&.{ "ANY", "SOME", "ALL" })) {
                    return s.fail("xqlite: comparisons with ANY/SOME/ALL subqueries are not supported", .{});
                }
                const r = try s.bitOr();
                l = if (op == TK.IS) try ir.expr.is(s.p, TK.IS, l, r) else try ir.expr.binary(s.p, op, l, r);
                continue;
            }
            if (s.isKw("IS")) {
                s.advance();
                const not = s.eatKw("NOT");
                if (s.eatKw("NULL") or s.eatKw("UNKNOWN")) {
                    l = try ir.expr.isNull(s.p, if (not) TK.NOTNULL else TK.ISNULL, l);
                } else if (s.isKw("TRUE") or s.isKw("FALSE")) {
                    const b = try ir.expr.token(s.p, TK.ID, irTok(s.tok));
                    s.advance();
                    _ = ir.expr.idToTrueFalse(b);
                    l = try ir.expr.is(s.p, if (not) TK.ISNOT else TK.IS, l, b);
                } else return s.syntaxError();
                continue;
            }
            var not = false;
            if (s.isKw("NOT")) {
                const n = s.peek();
                if (!n.isAnyKw(&.{ "LIKE", "IN", "BETWEEN", "REGEXP", "RLIKE" })) break;
                s.advance();
                not = true;
            }
            if (s.isKw("LIKE")) {
                const op = s.tok;
                s.advance();
                const r = try s.bitOr();
                var esc: ?*Expr = null;
                if (s.eatKw("ESCAPE")) {
                    esc = try s.primaryWithCollate();
                } else {
                    esc = try s.stringExpr("\\");
                }
                l = try ir.expr.like(s.p, irTok(op), not, l, r, esc);
                continue;
            }
            if (s.isKw("REGEXP") or s.isKw("RLIKE")) {
                s.advance();
                const r = try s.bitOr();
                l = try ir.expr.like(s.p, int.Token.init("regexp"), not, l, r, null);
                continue;
            }
            if (s.eatKw("IN")) {
                try s.expectOp("(");
                if (s.isSelectStart()) {
                    const sub = try s.selectStmt();
                    try s.expectOp(")");
                    l = try ir.expr.inSelect(s.p, l, not, sub);
                } else {
                    const items = try s.exprList();
                    try s.expectOp(")");
                    l = try ir.expr.inList(s.p, l, not, items);
                }
                continue;
            }
            if (s.eatKw("BETWEEN")) {
                const lo = try s.bitOr();
                try s.expectKw("AND");
                const hi = try s.bitOr();
                l = try ir.expr.between(s.p, l, not, lo, hi);
                continue;
            }
            if (s.isKw("SOUNDS")) return s.fail("xqlite: SOUNDS LIKE is not supported", .{});
            break;
        }
        return l;
    }

    pub fn bitOr(s: *Parser) Error!*Expr {
        var l = try s.bitAnd();
        while (s.isOp("|")) {
            s.advance();
            l = try ir.expr.binary(s.p, TK.BITOR, l, try s.bitAnd());
        }
        return l;
    }

    fn bitAnd(s: *Parser) Error!*Expr {
        var l = try s.shift();
        while (s.isOp("&")) {
            s.advance();
            l = try ir.expr.binary(s.p, TK.BITAND, l, try s.shift());
        }
        return l;
    }

    fn shift(s: *Parser) Error!*Expr {
        var l = try s.additive();
        while (s.isOp("<<") or s.isOp(">>")) {
            const op: u8 = if (s.isOp("<<")) TK.LSHIFT else TK.RSHIFT;
            s.advance();
            l = try ir.expr.binary(s.p, op, l, try s.additive());
        }
        return l;
    }

    fn additive(s: *Parser) Error!*Expr {
        var l = if (s.isKw("INTERVAL") and !s.peek().is("(")) blk: {
            // INTERVAL n unit + date
            const iv = try s.interval();
            try s.expectOp("+");
            const d = try s.multiplicative();
            break :blk try s.dateAdd(d, iv.n, iv.unit, false);
        } else try s.multiplicative();
        while (s.isOp("+") or s.isOp("-")) {
            const minus = s.isOp("-");
            s.advance();
            if (s.isKw("INTERVAL")) {
                const iv = try s.interval();
                l = try s.dateAdd(l, iv.n, iv.unit, minus);
                continue;
            }
            l = try ir.expr.binary(s.p, if (minus) TK.MINUS else TK.PLUS, l, try s.multiplicative());
        }
        return l;
    }

    const Interval = struct { n: *Expr, unit: []const u8 };

    /// `INTERVAL expr unit`.
    fn interval(s: *Parser) Error!Interval {
        try s.expectKw("INTERVAL");
        const n = try s.expr();
        if (s.tok.kind != .ident) return s.syntaxError();
        const unit = s.tok.text;
        s.advance();
        return .{ .n = n, .unit = unit };
    }

    /// xq_date_add(d, [-]n, 'UNIT').
    pub fn dateAdd(s: *Parser, d: *Expr, n: *Expr, unit: []const u8, negate: bool) Error!*Expr {
        const amount = if (negate) try ir.expr.binary(s.p, TK.UMINUS, n, null) else n;
        const u = try std.ascii.allocUpperString(s.a, unit);
        return s.call("xq_date_add", &.{ d, amount, try s.stringExpr(u) });
    }

    fn multiplicative(s: *Parser) Error!*Expr {
        var l = try s.bitXor();
        while (true) {
            if (s.isOp("*")) {
                s.advance();
                l = try ir.expr.binary(s.p, TK.STAR, l, try s.bitXor());
            } else if (s.isOp("/")) {
                s.advance();
                const r = try s.bitXor();
                const real = try ir.expr.cast(s.p, l, int.Token.init("REAL"));
                l = try ir.expr.binary(s.p, TK.SLASH, real, r);
            } else if (s.isOp("%") or s.isKw("MOD")) {
                s.advance();
                l = try ir.expr.binary(s.p, TK.REM, l, try s.bitXor());
            } else if (s.isKw("DIV")) {
                s.advance();
                l = try s.call("xq_div", &.{ l, try s.bitXor() });
            } else break;
        }
        return l;
    }

    fn bitXor(s: *Parser) Error!*Expr {
        var l = try s.concat();
        while (s.isOp("^")) {
            s.advance();
            l = try s.call("xq_bitxor", &.{ l, try s.concat() });
        }
        return l;
    }

    fn concat(s: *Parser) Error!*Expr {
        var l = try s.unary();
        while (s.mode.has(.PIPES_AS_CONCAT) and s.isOp("||")) {
            s.advance();
            l = try ir.expr.binary(s.p, TK.CONCAT, l, try s.unary());
        }
        return l;
    }

    fn unary(s: *Parser) Error!*Expr {
        if (s.isOp("-") or s.isOp("+")) {
            const minus = s.isOp("-");
            s.advance();
            const e = try s.unary();
            if (!minus) return e;
            return ir.expr.binary(s.p, TK.UMINUS, e, null);
        }
        if (s.isOp("~")) {
            s.advance();
            return ir.expr.binary(s.p, TK.BITNOT, try s.unary(), null);
        }
        if (s.isOp("!")) {
            s.advance();
            return ir.expr.binary(s.p, TK.NOT, try s.unary(), null);
        }
        if (s.isKw("BINARY") and !s.peek().is("(")) {
            s.advance();
            return ir.expr.collate(s.p, try s.unary(), int.Token.init("BINARY"), false);
        }
        return s.primaryWithCollate();
    }

    fn primaryWithCollate(s: *Parser) Error!*Expr {
        var e = try s.primary();
        while (s.eatKw("COLLATE")) {
            const coll = try s.collationName();
            e = try ir.expr.collate(s.p, e, int.Token.init(coll), false);
        }
        return e;
    }

    /// The SQLite collation for a MariaDB collation name (after COLLATE).
    pub fn collationName(s: *Parser) Error![:0]const u8 {
        const t = s.tok;
        if (t.kind != .ident and t.kind != .quoted_ident and t.kind != .string) return s.syntaxError();
        const n = if (t.kind == .string) try lexer.stringValue(s.a, t, false) else try s.nameText(t);
        s.advance();
        return mapCollation(n) orelse s.fail("Unknown collation: '{s}'", .{n});
    }

    pub fn stringExpr(s: *Parser, z: []const u8) Error!*Expr {
        return ir.expr.leaf(s.a, TK.STRING, z);
    }

    pub fn intExpr(s: *Parser, v: i32) Error!*Expr {
        return ir.expr.int32(s.a, v);
    }

    /// A call of `name` (a function the frontend chose) with `args`.
    pub fn call(s: *Parser, name_: []const u8, args: []const *Expr) Error!*Expr {
        var l: ?*ExprList = null;
        for (args) |x| l = try ir.list.append(s.p, l, x);
        return ir.expr.functionCall(s.p, name_, l);
    }

    pub fn isSelectStart(s: *Parser) bool {
        return s.isKw("SELECT") or s.isKw("WITH") or (s.isOp("(") and isSelectish(s.peek())) or s.isKw("VALUES");
    }

    fn isSelectish(t: Token) bool {
        return t.isKw("SELECT") or t.isKw("WITH") or t.is("(");
    }

    fn primary(s: *Parser) Error!*Expr {
        const t = s.tok;
        switch (t.kind) {
            .string => {
                const v = try s.stringLiteral();
                if (v.len == 0 and s.mode.has(.EMPTY_STRING_IS_NULL)) return ir.expr.leaf(s.a, TK.NULL, null);
                const e = try ir.expr.leaf(s.a, TK.STRING, v);
                e.w = .{ .ofst = ir.expr.tokenOffset(s.p, irTok(t)) };
                return e;
            },
            .integer => {
                s.advance();
                return ir.expr.integer(s.p, irTok(t));
            },
            .float => {
                s.advance();
                return ir.expr.token(s.p, TK.FLOAT, irTok(t));
            },
            .hex => {
                s.advance();
                const digits = (try lexer.hexDigits(s.a, t)) orelse return s.syntaxErrorAt(t);
                const z = try std.fmt.allocPrint(s.a, "x'{s}'", .{digits});
                return ir.expr.leaf(s.a, TK.BLOB, z);
            },
            .bit => {
                s.advance();
                const v = lexer.bitValue(t) orelse return s.fail("bit literal out of range", .{});
                const z = try std.fmt.allocPrint(s.a, "{d}", .{v});
                return ir.expr.integer(s.p, int.Token.init(z));
            },
            .param => {
                s.advance();
                const e = try ir.expr.token(s.p, TK.VARIABLE, irTok(t));
                try ir.expr.assignVarNumber(s.p, e, 1);
                return e;
            },
            .sys_var => {
                s.advance();
                const name_ = try sysVarName(s, t);
                return s.call("xq_sysvar", &.{try s.stringExpr(name_)});
            },
            .user_var => {
                s.advance();
                const name_ = try userVarName(s, t);
                if (s.eatOp(":=")) {
                    const v = try s.expr();
                    return s.call("xq_set_uservar", &.{ try s.stringExpr(name_), v });
                }
                return s.call("xq_uservar", &.{try s.stringExpr(name_)});
            },
            .op => {
                if (t.is("(")) return s.parenthesized();
                if (t.is("{")) {
                    // ODBC escapes: {d '...'}, {ts '...'}, {fn f()}.
                    s.advance();
                    _ = try s.anyName();
                    const e = try s.expr();
                    try s.expectOp("}");
                    return e;
                }
                return s.syntaxError();
            },
            .quoted_ident => return s.columnRef(),
            .ident => return s.wordExpr(),
            else => return s.syntaxError(),
        }
    }

    /// `( ... )`: a subquery, a row value or a parenthesized expression.
    fn parenthesized(s: *Parser) Error!*Expr {
        try s.expectOp("(");
        if (s.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
            const sub = try s.selectStmt();
            try s.expectOp(")");
            return ir.expr.subquery(s.p, TK.SELECT, sub);
        }
        const first = try s.expr();
        if (s.eatOp(")")) return first;
        var items = try ir.list.append(s.p, null, first);
        while (s.eatOp(",")) items = try ir.list.append(s.p, items, try s.expr());
        try s.expectOp(")");
        return ir.expr.vector(s.p, items);
    }

    fn columnRef(s: *Parser) Error!*Expr {
        const t1 = try s.anyName();
        if (!s.isOp(".")) return s.idExpr(t1);
        s.advance();
        const t2 = try s.anyName();
        if (!s.isOp(".")) return ir.expr.binary(s.p, TK.DOT, try s.idExpr(t1), try s.idExpr(t2));
        s.advance();
        const t3 = try s.anyName();
        const right = try ir.expr.binary(s.p, TK.DOT, try s.idExpr(t2), try s.idExpr(t3));
        return ir.expr.binary(s.p, TK.DOT, try s.idExpr(t1), right);
    }

    /// A TK.ID node for a name token (dequoted; never the string that
    /// SQLite makes of an unknown "x").
    pub fn idExpr(s: *Parser, t: Token) Error!*Expr {
        const e = try ir.expr.token(s.p, TK.ID, irTok(t));
        e.flags.DblQuoted = false;
        return e;
    }

    /// An expression starting with a word: a keyword form, a function
    /// call or a column reference.
    fn wordExpr(s: *Parser) Error!*Expr {
        const t = s.tok;
        const next = s.peek();
        if (t.isKw("NULL") or t.isKw("UNKNOWN")) {
            s.advance();
            return ir.expr.token(s.p, TK.NULL, irTok(t));
        }
        if (t.isKw("TRUE") or t.isKw("FALSE")) {
            s.advance();
            return s.intExpr(@intFromBool(t.isKw("TRUE")));
        }
        if (t.isKw("CASE")) return s.caseExpr();
        if (t.isKw("EXISTS")) {
            s.advance();
            try s.expectOp("(");
            const sub = try s.selectStmt();
            try s.expectOp(")");
            return ir.expr.subquery(s.p, TK.EXISTS, sub);
        }
        if (t.isKw("DEFAULT") and s.allow_default and !next.is("(")) {
            s.advance();
            return ir.expr.binary(s.p, TK.DEFAULT, null, null);
        }
        if (t.isAnyKw(&.{ "DATE", "TIME", "TIMESTAMP" }) and next.kind == .string) {
            // DATE '2024-01-01' and the like: the string.
            s.advance();
            return s.primary();
        }
        if (t.text[0] == '_' and next.kind == .string) return s.primary();
        if (t.isKw("INTERVAL") and !next.is("(")) {
            // INTERVAL n unit + date
            return s.additive();
        }
        if (t.isKw("NEXT") and next.isKw("VALUE")) {
            s.advance();
            s.advance();
            try s.expectKw("FOR");
            const seq = try s.anyName();
            return s.call("nextval", &.{try s.stringExpr(try s.nameText(seq))});
        }
        if ((t.isKw("PREVIOUS") or t.isKw("LASTVAL")) and next.isKw("VALUE")) {
            s.advance();
            s.advance();
            try s.expectKw("FOR");
            const seq = try s.anyName();
            return s.call("lastval", &.{try s.stringExpr(try s.nameText(seq))});
        }
        if (next.is("(")) return @import("functions.zig").call(s);
        // Niladic functions.
        const niladic = [_]struct { []const u8, []const u8 }{
            .{ "CURRENT_TIMESTAMP", "now" }, .{ "LOCALTIME", "now" },        .{ "LOCALTIMESTAMP", "now" },
            .{ "CURRENT_DATE", "curdate" },  .{ "CURRENT_TIME", "curtime" }, .{ "UTC_TIMESTAMP", "now" },
            .{ "UTC_DATE", "curdate" },      .{ "UTC_TIME", "curtime" },     .{ "CURRENT_USER", "current_user" },
        };
        for (niladic) |n| if (t.isKw(n[0])) {
            s.advance();
            return @import("functions.zig").byName(s, n[1], null, t);
        };
        if (isReserved(t)) return s.syntaxError();
        return s.columnRef();
    }

    fn caseExpr(s: *Parser) Error!*Expr {
        try s.expectKw("CASE");
        const operand: ?*Expr = if (s.isKw("WHEN")) null else try s.expr();
        var list: ?*ExprList = null;
        while (s.eatKw("WHEN")) {
            list = try ir.list.append(s.p, list, try s.expr());
            try s.expectKw("THEN");
            list = try ir.list.append(s.p, list, try s.expr());
        }
        if (list == null) return s.syntaxError();
        const else_: ?*Expr = if (s.eatKw("ELSE")) try s.expr() else null;
        try s.expectKw("END");
        return ir.expr.case(s.p, operand, list, else_);
    }

    pub fn exprList(s: *Parser) Error!*ExprList {
        var l = try ir.list.append(s.p, null, try s.expr());
        while (s.eatOp(",")) l = try ir.list.append(s.p, l, try s.expr());
        return l;
    }

    // ============================================================ SELECT

    /// `[WITH ...] select_body [ORDER BY ...] [LIMIT ...] [locking]`.
    pub fn selectStmt(s: *Parser) Error!*Select {
        var w: ?*With = null;
        if (s.isKw("WITH")) w = try s.withClause();
        var sel = try s.selectBody();
        try s.orderLimit(sel);
        try s.lockingClause();
        if (w != null) {
            sel = ir.select.attachWith(s.p, sel, w) orelse return s.syntaxError();
        } else ir.select.doubleLink(s.p, sel);
        try s.check();
        return sel;
    }

    /// The ORDER BY and LIMIT of a whole SELECT (the last core of a
    /// compound carries them in SQLite's tree).
    fn orderLimit(s: *Parser, sel: *Select) Error!void {
        if (s.isKw("ORDER") and s.peek().isKw("BY")) {
            if (sel.order_by != null or sel.limit != null) return s.syntaxError();
            s.advance();
            s.advance();
            sel.order_by = try s.sortList();
        }
        if (s.isKw("LIMIT")) {
            if (sel.limit != null) return s.syntaxError();
            sel.limit = try s.limitClause();
        } else if (s.isKw("OFFSET")) {
            // OFFSET n ROWS FETCH {FIRST|NEXT} m ROWS ONLY (MariaDB 10.6).
            s.advance();
            const off = try s.expr();
            _ = s.eatKw("ROWS") or s.eatKw("ROW");
            var lim: ?*Expr = null;
            if (s.eatKw("FETCH")) lim = try s.fetchFirst();
            sel.limit = try ir.expr.binary(s.p, TK.LIMIT, lim orelse try ir.expr.int32(s.a, -1), off);
        } else if (s.eatKw("FETCH")) {
            sel.limit = try ir.expr.binary(s.p, TK.LIMIT, try s.fetchFirst(), null);
        }
    }

    fn fetchFirst(s: *Parser) Error!*Expr {
        if (!(s.eatKw("FIRST") or s.eatKw("NEXT"))) return s.syntaxError();
        const n = if (s.isKw("ROW") or s.isKw("ROWS")) try ir.expr.int32(s.a, 1) else try s.expr();
        if (!(s.eatKw("ROWS") or s.eatKw("ROW"))) return s.syntaxError();
        if (s.isKw("WITH")) return s.fail("xqlite: FETCH ... WITH TIES is not supported", .{});
        try s.expectKw("ONLY");
        return n;
    }

    /// `LIMIT n`, `LIMIT off, n`, `LIMIT n OFFSET m`: a TK.LIMIT node.
    pub fn limitClause(s: *Parser) Error!*Expr {
        try s.expectKw("LIMIT");
        const first = try s.limitValue();
        if (s.eatOp(",")) {
            const n = try s.limitValue();
            return ir.expr.binary(s.p, TK.LIMIT, n, first);
        }
        if (s.eatKw("OFFSET")) {
            const off = try s.limitValue();
            return ir.expr.binary(s.p, TK.LIMIT, first, off);
        }
        if (s.isKw("ROWS")) return s.fail("xqlite: LIMIT ROWS EXAMINED is not supported", .{});
        return ir.expr.binary(s.p, TK.LIMIT, first, null);
    }

    /// A LIMIT value: a number, a parameter or (an xqlite extension) an
    /// expression.
    fn limitValue(s: *Parser) Error!*Expr {
        return s.additive();
    }

    fn lockingClause(s: *Parser) Error!void {
        if (s.isKw("FOR") and s.peek().isKw("UPDATE")) {
            s.advance();
            s.advance();
            if (s.eatKw("WAIT")) {
                _ = try s.expr();
            } else _ = s.eatKw("NOWAIT") or (s.eatKw("SKIP") and s.eatKw("LOCKED"));
        } else if (s.isKw("LOCK") and s.peek().isKw("IN")) {
            s.advance();
            s.advance();
            try s.expectKw("SHARE");
            try s.expectKw("MODE");
        }
    }

    fn withClause(s: *Parser) Error!*With {
        try s.expectKw("WITH");
        _ = s.eatKw("RECURSIVE");
        var w: ?*With = null;
        while (true) {
            const n = try s.name();
            s.p.has_with = true;
            var cols: ?*ExprList = null;
            if (s.eatOp("(")) {
                while (true) {
                    const c = try s.name();
                    cols = try ir.list.addIdTerm(s.p, cols, irTok(c), false, SO.undef);
                    if (!s.eatOp(",")) break;
                }
                try s.expectOp(")");
            }
            try s.expectKw("AS");
            try s.expectOp("(");
            const q = try s.selectStmt();
            try s.expectOp(")");
            const cte = try ir.with.cte(s.p, irTok(n), cols, q, .any);
            w = try ir.with.add(s.p, w, cte);
            if (!s.eatOp(",")) break;
        }
        return w.?;
    }

    /// Cores joined by UNION/EXCEPT/INTERSECT.
    fn selectBody(s: *Parser) Error!*Select {
        var lhs = try s.selectTerm();
        while (true) {
            var op: i32 = undefined;
            if (s.eatKw("UNION")) {
                op = if (s.eatKw("ALL")) TK.ALL else blk: {
                    _ = s.eatKw("DISTINCT");
                    break :blk TK.UNION;
                };
            } else if (s.eatKw("EXCEPT") or s.eatKw("MINUS")) {
                if (s.eatKw("ALL")) return s.fail("xqlite: EXCEPT ALL is not supported", .{});
                _ = s.eatKw("DISTINCT");
                op = TK.EXCEPT;
            } else if (s.eatKw("INTERSECT")) {
                if (s.eatKw("ALL")) return s.fail("xqlite: INTERSECT ALL is not supported", .{});
                _ = s.eatKw("DISTINCT");
                op = TK.INTERSECT;
            } else break;
            if (lhs.order_by != null or lhs.limit != null) lhs = try s.wrapSubquery(lhs);
            var rhs = try s.selectTerm();
            if (rhs.order_by != null or rhs.limit != null) rhs = try s.wrapSubquery(rhs);
            lhs = (try ir.select.compound(s.p, lhs, op, rhs)) orelse return s.syntaxError();
        }
        return lhs;
    }

    /// `SELECT * FROM (sel)`.
    pub fn wrapSubquery(s: *Parser, sel: *Select) Error!*Select {
        const src = try ir.from.appendTerm(s.p, null, null, null, .{}, sel, null);
        return ir.select.new(s.p, null, src, null, null, null, null, .{}, null);
    }

    fn selectTerm(s: *Parser) Error!*Select {
        if (s.eatOp("(")) {
            const inner = try s.selectStmt();
            try s.expectOp(")");
            return inner;
        }
        if (s.isKw("VALUES")) return s.valuesRows(null);
        return s.selectCore();
    }

    /// `VALUES (row), (row) ...` as a Select (each row through `wrap` if
    /// given: INSERT's coercion).
    pub fn valuesRows(s: *Parser, wrap: ?*const RowWrap) Error!*Select {
        if (!(s.eatKw("VALUES") or s.eatKw("VALUE"))) return s.syntaxError();
        var sel: ?*Select = null;
        var n: usize = 0;
        while (true) {
            try s.expectOp("(");
            var row: ?*ExprList = null;
            if (!s.isOp(")")) row = try s.exprList();
            try s.expectOp(")");
            n += 1;
            if (wrap) |w| row = try w.apply(s, row, n);
            sel = if (sel) |prev| try ir.select.multiValues(s.p, prev, row) else try ir.select.values(s.p, row);
            if (!s.eatOp(",")) break;
        }
        if (n > 1) {
            ir.select.multiValuesEnd(s.p, sel.?);
            if (wrap != null) markMultiRow(sel.?);
        }
        ir.select.doubleLink(s.p, sel.?);
        try s.check();
        return sel.?;
    }

    fn selectCore(s: *Parser) Error!*Select {
        try s.expectKw("SELECT");
        var flags: SF = .{};
        var straight = false;
        while (true) {
            if (s.eatKw("DISTINCT") or s.eatKw("DISTINCTROW")) {
                flags = .{ .Distinct = true };
            } else if (s.eatKw("ALL")) {
                flags = .{ .All = true };
            } else if (s.eatKw("STRAIGHT_JOIN")) {
                straight = true;
            } else if (s.eatKw("HIGH_PRIORITY") or s.eatKw("SQL_SMALL_RESULT") or s.eatKw("SQL_BIG_RESULT") or
                s.eatKw("SQL_BUFFER_RESULT") or s.eatKw("SQL_CACHE") or s.eatKw("SQL_NO_CACHE") or
                s.eatKw("SQL_CALC_FOUND_ROWS"))
            {} else break;
        }
        const cols = try s.resultColumns();
        if (s.isKw("INTO")) return s.fail("xqlite: SELECT ... INTO is not supported", .{});
        var src: ?*SrcList = null;
        if (s.eatKw("FROM")) {
            if (s.isKw("DUAL")) {
                s.advance();
            } else {
                src = try s.tableRefs();
                ir.from.shiftJoinType(src);
                if (straight) if (src) |l| for (l.slice()[1..]) |*item| {
                    item.fg.jointype.CROSS = true;
                };
            }
        }
        const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
        var group: ?*ExprList = null;
        if (s.isKw("GROUP")) {
            s.advance();
            try s.expectKw("BY");
            while (true) {
                group = try ir.list.append(s.p, group, try s.expr());
                _ = s.eatKw("ASC") or s.eatKw("DESC");
                if (!s.eatOp(",")) break;
            }
            if (s.isKw("WITH") and s.peek().isKw("ROLLUP")) return s.fail("xqlite: GROUP BY ... WITH ROLLUP is not supported", .{});
        }
        const having: ?*Expr = if (s.eatKw("HAVING")) try s.expr() else null;
        var windows: ?*Window = null;
        if (s.eatKw("WINDOW")) windows = try s.windowDefs();
        const sel = try ir.select.new(s.p, cols, src, where, group, having, null, flags, null);
        sel.win_defn = windows;
        return sel;
    }

    fn resultColumns(s: *Parser) Error!*ExprList {
        var l: ?*ExprList = null;
        while (true) {
            if (s.isOp("*")) {
                l = try ir.list.star(s.p, l, irTok(s.tok));
                s.advance();
            } else if ((s.tok.kind == .ident or s.tok.kind == .quoted_ident) and s.peek().is(".") and s.peek2().is("*")) {
                const tbl = s.tok;
                s.advance();
                s.advance();
                const star = s.tok;
                s.advance();
                l = try ir.list.tableStar(s.p, l, irTok(tbl), irTok(star));
            } else {
                const start = s.tok.text.ptr;
                const e = try s.expr();
                const end = s.prev_end;
                const al = try s.alias(true);
                l = try ir.list.resultColumn(s.p, l, e, al, start, end);
            }
            if (!s.eatOp(",")) break;
        }
        return l.?;
    }

    /// `[AS] name` (or a string, for a column alias); an empty token if
    /// there is none.
    fn alias(s: *Parser, string_ok: bool) Error!int.Token {
        if (s.eatKw("AS")) {
            if (string_ok and s.tok.kind == .string) return s.stringAlias();
            return irTok(try s.anyName());
        }
        if (s.isName()) {
            const t = s.tok;
            s.advance();
            return irTok(t);
        }
        if (string_ok and s.tok.kind == .string) return s.stringAlias();
        return .{};
    }

    /// A string as a name: its value, quoted for the IR's dequoting.
    fn stringAlias(s: *Parser) Error!int.Token {
        const v = try s.stringLiteral();
        var out: std.ArrayList(u8) = .empty;
        try out.append(s.a, '"');
        for (v) |c| {
            if (c == '"') try out.append(s.a, '"');
            try out.append(s.a, c);
        }
        try out.append(s.a, '"');
        return int.Token.init(out.items);
    }

    pub fn sortList(s: *Parser) Error!*ExprList {
        var l: ?*ExprList = null;
        while (true) {
            l = try ir.list.append(s.p, l, try s.expr());
            var order: i32 = SO.undef;
            if (s.eatKw("ASC")) {
                order = SO.asc;
            } else if (s.eatKw("DESC")) order = SO.desc;
            ir.list.setSortOrder(l, order, SO.undef);
            if (!s.eatOp(",")) break;
        }
        return l.?;
    }

    // ---------------------------------------------------------- windows

    fn windowDefs(s: *Parser) Error!*Window {
        var list: ?*Window = null;
        while (true) {
            const n = try s.name();
            try s.expectKw("AS");
            try s.expectOp("(");
            const w = try s.windowSpec();
            try s.expectOp(")");
            w.name = try s.a.dupeSentinel(u8, try s.nameText(n), 0);
            if (list) |prev| {
                try ir.window.chain(s.p, w, prev);
                w.next_win = prev;
            }
            list = w;
            if (!s.eatOp(",")) break;
        }
        return list.?;
    }

    /// The inside of OVER ( ... ) or WINDOW w AS ( ... ).
    fn windowSpec(s: *Parser) Error!*Window {
        var base: ?int.Token = null;
        if (s.isName() and !s.isKw("PARTITION") and !s.isKw("ORDER") and !s.isKw("ROWS") and !s.isKw("RANGE")) {
            base = irTok(try s.name());
        }
        var partition: ?*ExprList = null;
        if (s.eatKw("PARTITION")) {
            try s.expectKw("BY");
            partition = try s.exprList();
        }
        var order: ?*ExprList = null;
        if (s.isKw("ORDER")) {
            s.advance();
            try s.expectKw("BY");
            order = try s.sortList();
        }
        const fr = try s.frame();
        return (try ir.window.assemble(s.p, fr, partition, order, base)) orelse s.syntaxError();
    }

    fn frame(s: *Parser) Error!?*Window {
        var kind: i32 = 0;
        if (s.eatKw("ROWS")) {
            kind = TK.ROWS;
        } else if (s.eatKw("RANGE")) {
            kind = TK.RANGE;
        } else return ir.window.alloc(s.p, 0, TK.UNBOUNDED, null, TK.CURRENT, null, 0);
        var start: Bound = undefined;
        var end: Bound = .{ .e_type = TK.CURRENT, .e = null };
        if (s.eatKw("BETWEEN")) {
            start = try s.frameBound();
            try s.expectKw("AND");
            end = try s.frameBound();
        } else start = try s.frameBound();
        var exclude: u8 = 0;
        if (s.eatKw("EXCLUDE")) {
            if (s.eatKw("CURRENT")) {
                try s.expectKw("ROW");
                exclude = TK.CURRENT;
            } else if (s.eatKw("GROUP")) {
                exclude = TK.GROUP;
            } else if (s.eatKw("TIES")) {
                exclude = TK.TIES;
            } else if (s.eatKw("NO")) {
                try s.expectKw("OTHERS");
                exclude = TK.NO;
            } else return s.syntaxError();
        }
        return ir.window.alloc(s.p, kind, start.e_type, start.e, end.e_type, end.e, exclude);
    }

    const Bound = struct { e_type: i32, e: ?*Expr };

    fn frameBound(s: *Parser) Error!Bound {
        if (s.eatKw("UNBOUNDED")) {
            if (!(s.eatKw("PRECEDING") or s.eatKw("FOLLOWING"))) return s.syntaxError();
            return .{ .e_type = TK.UNBOUNDED, .e = null };
        }
        if (s.eatKw("CURRENT")) {
            try s.expectKw("ROW");
            return .{ .e_type = TK.CURRENT, .e = null };
        }
        const e = try s.additive();
        if (s.eatKw("PRECEDING")) return .{ .e_type = TK.PRECEDING, .e = e };
        if (s.eatKw("FOLLOWING")) return .{ .e_type = TK.FOLLOWING, .e = e };
        return s.syntaxError();
    }

    /// `OVER (spec)` or `OVER name` after a function call, attached to it.
    pub fn overClause(s: *Parser, e: *Expr) Error!void {
        if (!s.eatKw("OVER")) return;
        if (s.eatOp("(")) {
            const w = try s.windowSpec();
            try s.expectOp(")");
            ir.window.attach(s.p, e, w);
        } else {
            const n = try s.name();
            const w = try s.a.create(Window);
            w.* = .{ .name = try s.a.dupeSentinel(u8, try s.nameText(n), 0) };
            ir.window.attach(s.p, e, w);
        }
    }

    // ------------------------------------------------------------- FROM

    /// Table references joined by commas and JOINs.
    fn tableRefs(s: *Parser) Error!?*SrcList {
        var list = try s.tableFactor(null, false);
        while (true) {
            const jt = (try s.joinOp()) orelse break;
            if (list) |l| if (l.len() > 0) {
                l.at(l.len() - 1).fg.jointype = jt;
            };
            list = try s.tableFactor(list, true);
        }
        return list;
    }

    fn joinOp(s: *Parser) Error!?JT {
        if (s.eatOp(",")) return .{ .INNER = true };
        if (s.eatKw("JOIN")) return .{ .INNER = true };
        if (s.eatKw("STRAIGHT_JOIN")) return .{ .INNER = true, .CROSS = true };
        if (s.isKw("INNER") or s.isKw("CROSS")) {
            s.advance();
            try s.expectKw("JOIN");
            return .{ .INNER = true };
        }
        var words: [3]int.Token = .{ .{}, .{}, .{} };
        var n: usize = 0;
        if (s.isKw("NATURAL")) {
            words[n] = irTok(s.tok);
            n += 1;
            s.advance();
        }
        if (s.isKw("LEFT") or s.isKw("RIGHT")) {
            words[n] = irTok(s.tok);
            n += 1;
            s.advance();
            if (s.isKw("OUTER")) {
                words[n] = irTok(s.tok);
                n += 1;
                s.advance();
            }
        } else if (n == 1 and (s.isKw("INNER") or s.isKw("OUTER"))) {
            words[n] = irTok(s.tok);
            n += 1;
            s.advance();
        }
        if (n == 0) return null;
        try s.expectKw("JOIN");
        return ir.from.joinType(s.p, words[0], if (n > 1) words[1] else null, if (n > 2) words[2] else null);
    }

    fn onUsing(s: *Parser) Error!int.OnOrUsing {
        if (s.eatKw("ON")) return .{ .on = try s.expr() };
        if (s.eatKw("USING")) {
            try s.expectOp("(");
            var ids: ?*IdList = null;
            while (true) {
                ids = try ir.list.idAppend(s.p, ids, irTok(try s.name()));
                if (!s.eatOp(",")) break;
            }
            try s.expectOp(")");
            return .{ .using = ids };
        }
        return .{};
    }

    fn tableFactor(s: *Parser, prefix: ?*SrcList, joined: bool) Error!?*SrcList {
        _ = joined;
        if (s.isOp("(")) {
            const n = s.peek();
            if (n.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
                s.advance();
                const sub = try s.selectStmt();
                try s.expectOp(")");
                const al = try s.alias(false);
                var ou = try s.onUsing();
                return ir.from.appendTerm(s.p, prefix, null, null, al, sub, &ou);
            }
            s.advance();
            const inner = try s.tableRefs();
            try s.expectOp(")");
            const al = try s.alias(false);
            var ou = try s.onUsing();
            return ir.from.nested(s.p, prefix, inner, al, &ou);
        }
        const n1, const n2 = try s.qualifiedName();
        if (s.isKw("PARTITION")) return s.fail("xqlite: PARTITION is not supported", .{});
        if (n2.n != 0 and std.ascii.eqlIgnoreCase(try s.tokName(n1), "information_schema")) {
            const view = try s.tokName(n2);
            const sub = (try @import("infoschema.zig").select(s, view)) orelse
                return s.fail("Unknown table '{s}' in information_schema", .{view});
            var al = try s.alias(false);
            if (al.n == 0) al = n2;
            var ou = try s.onUsing();
            return ir.from.appendTerm(s.p, prefix, null, null, al, sub, &ou);
        }
        // A table-valued function (SQLite's json_each(), pragma_*()).
        var args: ?*ExprList = null;
        const is_func = s.isOp("(");
        if (is_func) {
            s.advance();
            if (!s.isOp(")")) args = try s.exprList();
            try s.expectOp(")");
        }
        const al = try s.alias(false);
        try s.indexHints();
        var ou = try s.onUsing();
        const l = try ir.from.appendTerm(s.p, prefix, n1, if (n2.n == 0) null else n2, al, null, &ou);
        if (is_func) ir.from.funcArgs(l, args);
        return l;
    }

    /// USE/IGNORE/FORCE {INDEX|KEY} [FOR ...] (names): accepted, ignored.
    fn indexHints(s: *Parser) Error!void {
        while (s.isAnyKw(&.{ "USE", "IGNORE", "FORCE" })) {
            const n = s.peek();
            if (!(n.isKw("INDEX") or n.isKw("KEY"))) return;
            s.advance();
            s.advance();
            if (s.eatKw("FOR")) {
                if (s.eatKw("JOIN")) {} else if (s.eatKw("ORDER") or s.eatKw("GROUP")) {
                    try s.expectKw("BY");
                } else return s.syntaxError();
            }
            try s.expectOp("(");
            while (!s.isOp(")")) {
                _ = try s.anyName();
                if (!s.eatOp(",")) break;
            }
            try s.expectOp(")");
        }
    }

    // ================================================================ DML

    /// The MariaDB metadata of a target table: its name as stored, the
    /// MariaDB type of each column (from xq_catalog; none for a table
    /// another dialect created), the AUTO_INCREMENT column.
    pub const Target = struct {
        tab: ?*int.Table,
        schema: []const u8,
        /// The table name as stored.
        name: []const u8 = "",
        cols: []ColMeta,
    };

    pub const ColMeta = struct {
        name: []const u8,
        decl_type: ?[]const u8 = null,
        on_update: bool = false,
        not_null: bool = false,
        autoinc: bool = false,
        generated: bool = false,
        hidden: bool = false,
        has_default: bool = false,
    };

    /// Look up the target table and its catalog entries (the catalog is
    /// read now, at compile time).
    pub fn target(s: *Parser, n1: int.Token, n2: int.Token) Error!Target {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const tbl_name = try s.tokName(if (n2.n != 0) n2 else n1);
        const schema_name: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
        var tab = build.findTable(s.p.db, tbl_name, schema_name) orelse return .{ .tab = null, .schema = "main", .cols = &.{} };
        const schema = catalog.schemaName(s.p.db, tab);
        const stored = try s.a.dupe(u8, tab.name);
        var entries: []const catalog.Entry = &.{};
        if (catalog.exists(s.p.db, schema)) {
            entries = catalog.entries(s.p.db, s.a, schema, stored) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
            };
            // The query may have reloaded the schema.
            tab = build.findTable(s.p.db, stored, schema) orelse return .{ .tab = null, .schema = schema, .cols = &.{} };
        }
        const cols = try s.a.alloc(ColMeta, tab.cols.len);
        for (tab.cols, 0..) |*c, i| {
            cols[i] = .{
                .name = try s.a.dupe(u8, c.name()),
                .not_null = c.not_null != .None,
                .autoinc = tab.tab_flags.Autoincrement and tab.i_pkey == i,
                .generated = c.col_flags.intersects(int.COLFLAG.GENERATED),
                .hidden = c.col_flags.HIDDEN,
                .has_default = c.i_dflt != 0,
            };
            for (entries) |en| {
                if (!std.ascii.eqlIgnoreCase(en.col, cols[i].name)) continue;
                if (std.mem.eql(u8, en.key, catalog.Key.decl_type)) cols[i].decl_type = en.value;
                if (std.mem.eql(u8, en.key, "mariadb.on_update")) cols[i].on_update = true;
            }
        }
        return .{ .tab = tab, .schema = schema, .name = stored, .cols = cols };
    }

    /// The column called `n` of the target, or null.
    pub fn findCol(t: *const Target, n: []const u8) ?*ColMeta {
        for (t.cols) |*c| if (std.ascii.eqlIgnoreCase(c.name, n)) return c;
        return null;
    }

    /// Wrap a value stored into column `c`: MariaDB's conversion
    /// (types.coerceFunc) if the column has a MariaDB type, and NULLIF(v,
    /// 0) for an AUTO_INCREMENT column (0 generates the next value unless
    /// NO_AUTO_VALUE_ON_ZERO). A DEFAULT marker becomes the column's
    /// default.
    pub fn wrapValue(s: *Parser, t: *const Target, c: *const ColMeta, e_in: *Expr, row: usize, ignore: bool) Error!*Expr {
        return s.wrapValueX(t, c, e_in, row, ignore, false);
    }

    /// wrapValue(); `missing`: the NULL for a NOT NULL column without a
    /// DEFAULT that the INSERT leaves out.
    pub fn wrapValueX(s: *Parser, t: *const Target, c: *const ColMeta, e_in: *Expr, row: usize, ignore: bool, missing: bool) Error!*Expr {
        var e = e_in;
        if (e.op == TK.DEFAULT) e = try s.columnDefault(t, c.name);
        if (c.decl_type) |ty| {
            var flags: i32 = 0;
            if (ignore) flags |= types.coerce_ignore;
            if (c.not_null and !c.autoinc) flags |= types.coerce_not_null;
            if (missing) flags |= types.coerce_missing | types.coerce_not_null;
            e = try s.call("xq_coerce", &.{
                e,
                try s.stringExpr(ty),
                try s.stringExpr(t.schema),
                try s.stringExpr(t.name),
                try s.stringExpr(c.name),
                try s.intExpr(flags),
                try s.intExpr(@intCast(@min(row, std.math.maxInt(i32)))),
            });
            @import("../../sql/main.zig").mayAbort(s.p);
        }
        if (c.autoinc and !s.mode.has(.NO_AUTO_VALUE_ON_ZERO)) e = try s.call("nullif", &.{ e, try s.intExpr(0) });
        return e;
    }

    /// A copy of the DEFAULT expression of column `n`, NULL if none.
    fn columnDefault(s: *Parser, t: *const Target, n: []const u8) Error!*Expr {
        const tab = t.tab orelse return ir.expr.leaf(s.a, TK.NULL, null);
        for (tab.cols, 0..) |*c, i| {
            if (!std.ascii.eqlIgnoreCase(c.name(), n)) continue;
            if (c.i_dflt == 0 or c.col_flags.intersects(int.COLFLAG.GENERATED) or tab.i_pkey == i) break;
            const dl = tab.u.tab.dflt_list orelse break;
            const d = dl.at(c.i_dflt - 1).expr orelse break;
            return (try expr_mod.exprDup(s.a, d)).?;
        }
        return ir.expr.leaf(s.a, TK.NULL, null);
    }

    /// The NOT NULL columns without a DEFAULT of a MariaDB table that an
    /// INSERT into `cols` leaves out.
    pub fn missingColumns(s: *Parser, t: *const Target, cols: []const *ColMeta) Error![]*ColMeta {
        var out: std.ArrayList(*ColMeta) = .empty;
        for (t.cols) |*c| {
            if (!c.not_null or c.has_default or c.autoinc or c.generated or c.hidden or c.decl_type == null) continue;
            for (cols) |x| {
                if (x == c) break;
            } else try out.append(s.a, c);
        }
        return out.items;
    }

    /// The columns an INSERT without a column list fills.
    pub fn insertColumns(s: *Parser, t: *const Target) Error![]*ColMeta {
        var out: std.ArrayList(*ColMeta) = .empty;
        for (t.cols) |*c| if (!c.generated and !c.hidden) try out.append(s.a, c);
        return out.items;
    }
};

/// Set coerce_multi_row in the xq_coerce() calls of a multi-row VALUES.
fn markMultiRow(last: *Select) void {
    var sel: ?*Select = last;
    while (sel) |x| : (sel = x.prior) {
        const l = x.e_list orelse continue;
        for (l.slice()) |item| {
            var e = item.expr orelse continue;
            // nullif(xq_coerce(...), 0) for AUTO_INCREMENT.
            if (e.op == TK.FUNCTION and std.ascii.eqlIgnoreCase(e.token(), "nullif")) e = e.x.list.?.at(0).expr.?;
            if (e.op != TK.FUNCTION or !std.ascii.eqlIgnoreCase(e.token(), "xq_coerce")) continue;
            const f = e.x.list.?.at(types.coerce_flags_arg).expr.?;
            f.u = .{ .value = f.u.value | types.coerce_multi_row };
        }
    }
}

/// The per-row wrapping of INSERT's VALUES.
pub const RowWrap = struct {
    target: *const Parser.Target,
    cols: []const *Parser.ColMeta,
    ignore: bool,
    needed: bool,
    /// NOT NULL columns without a DEFAULT the INSERT leaves out: a NULL
    /// for each is added to each row (and to the column list).
    missing: []const *Parser.ColMeta = &.{},

    pub fn apply(w: *const RowWrap, s: *Parser, row: ?*ExprList, n: usize) Error!?*ExprList {
        var l = row orelse return row;
        for (w.missing) |c| {
            const e = try s.wrapValueX(w.target, c, try ir.expr.leaf(s.a, TK.NULL, null), n, w.ignore, true);
            l = try ir.list.append(s.p, l, e);
        }
        if (l.len() != w.cols.len + w.missing.len and w.cols.len > 0) {
            return s.fail("Column count doesn't match value count at row {d}", .{n});
        }
        for (l.slice(), 0..) |*item, i| {
            const e = item.expr orelse continue;
            if (i >= w.cols.len) {
                // No column metadata (an unknown table or column, which
                // the builder reports): DEFAULT is NULL.
                if (e.op == TK.DEFAULT) item.expr = try ir.expr.leaf(s.a, TK.NULL, null);
                continue;
            }
            if (w.needed or e.op == TK.DEFAULT) item.expr = try s.wrapValue(w.target, w.cols[i], e, n, w.ignore);
        }
        return l;
    }
};

/// The SQLite collation of a MariaDB collation or character set name:
/// *_bin, binary and *_cs are BINARY, *_ci (and a character set's
/// default collation) NOCASE. NOCASE folds ASCII letters only.
pub fn mapCollation(n: []const u8) ?[:0]const u8 {
    const lower_buf = blk: {
        var b: [64]u8 = undefined;
        if (n.len > b.len) return null;
        break :blk std.ascii.lowerString(&b, n);
    };
    const l = lower_buf;
    if (std.mem.eql(u8, l, "binary") or std.mem.endsWith(u8, l, "_bin") or std.mem.endsWith(u8, l, "_cs")) return "BINARY";
    if (std.mem.endsWith(u8, l, "_ci")) return "NOCASE";
    // SQLite's own names.
    if (std.mem.eql(u8, l, "nocase")) return "NOCASE";
    if (std.mem.eql(u8, l, "rtrim")) return "RTRIM";
    return null;
}

/// The default collation of a character set, null if unknown.
pub fn charsetCollation(n: []const u8) ?[:0]const u8 {
    const known = [_][]const u8{ "utf8mb4", "utf8mb3", "utf8", "latin1", "ascii", "utf16", "utf32", "ucs2" };
    if (std.ascii.eqlIgnoreCase(n, "binary")) return "BINARY";
    for (known) |k| if (std.ascii.eqlIgnoreCase(n, k)) return "NOCASE";
    return null;
}

/// The name of @@[scope.]name, lower case, checked against the system
/// variables xqlite knows (session.zig).
fn sysVarName(s: *Parser, t: Token) Error![]const u8 {
    var z = t.text[2..];
    if (z.len > 0 and z[0] == '`') z = try lexer.identValue(s.a, .{ .kind = .quoted_ident, .text = z });
    for ([_][]const u8{ "global.", "session.", "local." }) |scope| {
        if (z.len > scope.len and std.ascii.startsWithIgnoreCase(z, scope)) z = z[scope.len..];
    }
    const lower = try std.ascii.allocLowerString(s.a, z);
    if (!@import("session.zig").isSysVar(lower)) return s.fail("Unknown system variable '{s}'", .{z});
    return lower;
}

/// The name of @name (case-insensitive: lower case).
fn userVarName(s: *Parser, t: Token) Error![]const u8 {
    var z = t.text[1..];
    if (z.len > 0 and (z[0] == '`' or z[0] == '\'' or z[0] == '"')) {
        z = if (z[0] == '`') try lexer.identValue(s.a, .{ .kind = .quoted_ident, .text = z }) else try lexer.stringValue(s.a, .{ .kind = .string, .text = z }, false);
    }
    return std.ascii.allocLowerString(s.a, z);
}
