//! The MariaDB parser: hand-written recursive descent over lexer.zig's
//! tokens producing the syntax tree IR (src/ir/tree.zig) with MariaDB's
//! semantics resolved, which src/ir/lower.zig lowers and src/ir/render.zig
//! renders for the schema (so a query, a CHECK, a DEFAULT, a generated
//! column and a view mean the same).
//!
//! This file has the parser core, expressions, SELECT and the metadata of
//! a DML target; functions.zig has function calls, dml.zig the DML, ddl.zig
//! the DDL and session.zig the session and introspection statements.
//!
//! Expressions follow MariaDB's precedence (lowest first): OR / || ,
//! XOR, AND / &&, NOT, comparisons (= <=> <> != < <= > >= IS LIKE
//! REGEXP IN BETWEEN), |, &, << >>, + -, * / DIV % MOD, ^, || under
//! PIPES_AS_CONCAT, unary (- + ~ ! BINARY), COLLATE. Where MariaDB and
//! SQLite disagree the tree says what MariaDB means:
//!  - `a / b` is a Div .real (CAST(a AS REAL) / b: 7/2 is 3.5), `a DIV b`
//!    a Div .int (xq_div());
//!  - `a XOR b` and `a ^ b` call the engine functions xq_xor() and
//!    xq_bitxor();
//!  - `a || b` is OR, or a Concat (NULL if an operand is) under
//!    PIPES_AS_CONCAT; `a <=> b` is `a IS b`; CONCAT() of 2 or more
//!    arguments is a Concat;
//!  - LIKE folds ASCII letters and has the escape character \ (also
//!    under NO_BACKSLASH_ESCAPES): SQLite's LIKE ... ESCAPE '\';
//!  - function names MariaDB spells differently are renamed, and a
//!    function of the dialect's table (runtime.zig) is a Func of
//!    .mariadb (functions.zig);
//!  - a string is decoded as sql_mode says (lexer.zig), '' is NULL under
//!    EMPTY_STRING_IS_NULL.
//!
//! What the schema keeps (DEFAULT, CHECK, generated columns, views) is
//! parsed with `stored` set: variables and parameters are refused there,
//! as MariaDB does.

const std = @import("std");
const ctype = @import("../../util/ctype.zig");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const json_table = @import("json_table.zig");
const functions = @import("functions.zig");
const dialect = @import("../dialect.zig");
const lexer = @import("lexer.zig");
const state = @import("state.zig");

const Parse = int.Parse;
const Expr = tree.Expr;
const Name = tree.Name;
const QName = tree.QName;

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

/// Whether `name` is a function of the dialect's table (runtime.zig):
/// a call of it is a Func of .mariadb, which the schema keeps as
/// xq_mariadb_<name>.
pub fn isDialectFunction(name: []const u8) bool {
    return dialect.spec(.mariadb).function_map.get(name) != null;
}

/// What the parser is reading for the schema (Parser.stored).
pub const Stored = struct {
    /// The clause (CHECK, DEFAULT, GENERATED ALWAYS AS), "" for a view.
    clause: []const u8 = "",
    /// The column or constraint.
    name: []const u8 = "",
};

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
    /// stands for the column's default (tree.Kind.default).
    allow_default: bool = false,
    /// Parsing what the schema keeps.
    stored: ?Stored = null,
    /// The JSON_TABLEs of the FROM clauses being parsed, and the column
    /// references that are values of JSON functions (json_table.zig).
    json_tables: std.ArrayList(json_table.JsonTable) = .empty,
    json_args: std.ArrayList(*Expr) = .empty,

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
        for (s.lx.sql[0..s.posOf(t)]) |c| {
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

    // --------------------------------------------------------- positions

    /// The offset of `ptr` (in the statement's text).
    pub fn offset(s: *const Parser, ptr: [*]const u8) u32 {
        return @intCast(@intFromPtr(ptr) - @intFromPtr(s.lx.sql.ptr));
    }

    pub fn posOf(s: *const Parser, t: Token) u32 {
        return s.offset(t.text.ptr);
    }

    /// The offset of the current token.
    pub fn here(s: *const Parser) u32 {
        return s.posOf(s.tok);
    }

    /// The offset after the last token consumed.
    pub fn endPos(s: *const Parser) u32 {
        return s.offset(s.prev_end);
    }

    /// An expression node from `pos` to the last token consumed.
    pub fn mk(s: *Parser, pos: u32, kind: tree.Kind) Error!*Expr {
        return tree.expr(s.a, pos, @max(pos, s.endPos()), kind);
    }

    pub fn new(s: *Parser, comptime T: type, v: T) Error!*T {
        return tree.new(s.a, T, v);
    }

    // ============================================================ lowering

    /// A Lowerer of the statement (positions are offsets of its text).
    pub fn lowerer(s: *Parser) lower.Lowerer {
        return .init(s.p, s.lx.sql);
    }

    /// Lower statement `st` with the IR.
    pub fn lowerStmt(s: *Parser, st: tree.Stmt) Error!void {
        var l = s.lowerer();
        l.statement(st) catch |err| return lowered(err);
    }

    // =============================================================== names

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

    /// The name a name token stands for.
    pub fn nameText(s: *Parser, t: Token) Error![]const u8 {
        return lexer.identValue(s.a, t);
    }

    /// The tree name of a name token.
    pub fn nameOf(s: *Parser, t: Token) Error!Name {
        return .{ .text = try lexer.identValue(s.a, t), .pos = s.posOf(t) };
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

    /// `[schema.]name`; a MariaDB database is a SQLite schema.
    pub fn qualifiedName(s: *Parser) Error!QName {
        const first = try s.nameOf(try s.anyName());
        if (s.eatOp(".")) {
            const second = try s.nameOf(try s.anyName());
            return .{ .schema = first, .name = second };
        }
        return .{ .name = first };
    }

    // ======================================================== expressions

    pub fn expr(s: *Parser) Error!*Expr {
        return s.orExpr();
    }

    fn bin(s: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return tree.expr(s.a, l.pos, r.end, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    fn orExpr(s: *Parser) Error!*Expr {
        var l = try s.xorExpr();
        while (s.isKw("OR") or (s.isOp("||") and !s.mode.has(.PIPES_AS_CONCAT))) {
            s.advance();
            l = try s.bin(.@"or", l, try s.xorExpr());
        }
        return l;
    }

    fn xorExpr(s: *Parser) Error!*Expr {
        var l = try s.andExpr();
        while (s.eatKw("XOR")) {
            const r = try s.andExpr();
            l = try s.func(l.pos, "xq_xor", &.{ l, r });
        }
        return l;
    }

    fn andExpr(s: *Parser) Error!*Expr {
        var l = try s.notExpr();
        while (s.isKw("AND") or s.isOp("&&")) {
            s.advance();
            l = try s.bin(.@"and", l, try s.notExpr());
        }
        return l;
    }

    fn notExpr(s: *Parser) Error!*Expr {
        const pos = s.here();
        if (s.eatKw("NOT")) {
            const e = try s.notExpr();
            return s.mk(pos, .{ .unary = .{ .op = .not, .e = e } });
        }
        return s.predicate();
    }

    fn compareOp(t: Token) ?tree.CmpOp {
        if (t.kind != .op) return null;
        const ops = [_]struct { []const u8, tree.CmpOp }{
            .{ "=", .eq },  .{ "<>", .ne }, .{ "!=", .ne }, .{ "<", .lt },
            .{ "<=", .le }, .{ ">", .gt },  .{ ">=", .ge }, .{ "<=>", .is },
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
                l = try s.mk(l.pos, .{ .compare = .{ .op = op, .l = try functions.jsonCompared(s, l), .r = try functions.jsonCompared(s, r) } });
                continue;
            }
            if (s.isKw("IS")) {
                s.advance();
                const not = s.eatKw("NOT");
                if (s.eatKw("NULL") or s.eatKw("UNKNOWN")) {
                    l = try s.mk(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                } else if (s.isKw("TRUE") or s.isKw("FALSE")) {
                    const v = s.isKw("TRUE");
                    s.advance();
                    l = try s.mk(l.pos, .{ .is_bool = .{ .e = l, .value = v, .not = not } });
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
                const op_pos = s.here();
                s.advance();
                const r = try s.bitOr();
                // The escape character is \ unless ESCAPE says.
                const esc = if (s.eatKw("ESCAPE")) try s.primaryWithCollate() else try s.mk(op_pos, .{ .string = "\\" });
                l = try s.mk(l.pos, .{ .like = .{ .e = l, .pat = r, .not = not, .case_sensitive = false, .escape = .{ .expr = esc } } });
                continue;
            }
            if (s.isKw("REGEXP") or s.isKw("RLIKE")) {
                const op_pos = s.here();
                s.advance();
                const r = try s.bitOr();
                const f = try s.new(tree.Func, .{ .name = .{ .text = "regexp", .pos = op_pos }, .args = try s.a.dupe(*Expr, &.{ r, l }) });
                l = try s.mk(l.pos, .{ .func = f });
                if (not) l = try s.mk(l.pos, .{ .unary = .{ .op = .not, .e = l } });
                continue;
            }
            if (s.eatKw("IN")) {
                try s.expectOp("(");
                if (s.isSelectStart()) {
                    const sub = try s.selectStmt();
                    try s.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = sub } });
                } else {
                    const items = try s.exprList();
                    try s.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_list = .{ .e = try functions.jsonCompared(s, l), .not = not, .items = items } });
                }
                continue;
            }
            if (s.eatKw("BETWEEN")) {
                const lo = try s.bitOr();
                try s.expectKw("AND");
                const hi = try s.bitOr();
                l = try s.mk(l.pos, .{ .between = .{ .e = l, .not = not, .lo = lo, .hi = hi } });
                continue;
            }
            if (s.isKw("SOUNDS")) return s.fail("xqlite: SOUNDS LIKE is not supported", .{});
            break;
        }
        return l;
    }

    pub fn bitOr(s: *Parser) Error!*Expr {
        var l = try s.bitAnd();
        while (s.eatOp("|")) l = try s.bin(.bit_or, l, try s.bitAnd());
        return l;
    }

    fn bitAnd(s: *Parser) Error!*Expr {
        var l = try s.shift();
        while (s.eatOp("&")) l = try s.bin(.bit_and, l, try s.shift());
        return l;
    }

    fn shift(s: *Parser) Error!*Expr {
        var l = try s.additive();
        while (s.isOp("<<") or s.isOp(">>")) {
            const op: tree.BinOp = if (s.isOp("<<")) .shl else .shr;
            s.advance();
            l = try s.bin(op, l, try s.additive());
        }
        return l;
    }

    fn additive(s: *Parser) Error!*Expr {
        var l = if (s.isKw("INTERVAL") and !s.peek().is("(")) blk: {
            // INTERVAL n unit + date
            const pos = s.here();
            const iv = try s.interval();
            try s.expectOp("+");
            const d = try s.multiplicative();
            break :blk try s.dateAdd(pos, d, iv.n, iv.unit, false);
        } else try s.multiplicative();
        while (s.isOp("+") or s.isOp("-")) {
            const minus = s.isOp("-");
            s.advance();
            if (s.isKw("INTERVAL")) {
                const iv = try s.interval();
                l = try s.dateAdd(l.pos, l, iv.n, iv.unit, minus);
                continue;
            }
            l = try s.bin(if (minus) .sub else .add, l, try s.multiplicative());
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
    pub fn dateAdd(s: *Parser, pos: u32, d: *Expr, n: *Expr, unit: []const u8, negate: bool) Error!*Expr {
        const amount = if (negate) try s.mk(n.pos, .{ .unary = .{ .op = .neg, .e = n } }) else n;
        const u = try std.ascii.allocUpperString(s.a, unit);
        return s.func(pos, "xq_date_add", &.{ d, amount, try s.str(pos, u) });
    }

    fn multiplicative(s: *Parser) Error!*Expr {
        var l = try s.bitXor();
        while (true) {
            if (s.eatOp("*")) {
                l = try s.bin(.mul, l, try s.bitXor());
            } else if (s.eatOp("/")) {
                const r = try s.bitXor();
                l = try s.mk(l.pos, .{ .div = .{ .kind = .real, .l = l, .r = r } });
            } else if (s.eatOp("%") or s.eatKw("MOD")) {
                l = try s.bin(.rem, l, try s.bitXor());
            } else if (s.eatKw("DIV")) {
                const r = try s.bitXor();
                l = try s.mk(l.pos, .{ .div = .{ .kind = .int, .l = l, .r = r } });
            } else break;
        }
        return l;
    }

    fn bitXor(s: *Parser) Error!*Expr {
        var l = try s.concat();
        while (s.eatOp("^")) {
            const r = try s.concat();
            l = try s.func(l.pos, "xq_bitxor", &.{ l, r });
        }
        return l;
    }

    fn concat(s: *Parser) Error!*Expr {
        const l = try s.unary();
        if (!(s.mode.has(.PIPES_AS_CONCAT) and s.isOp("||"))) return l;
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(s.a, l);
        while (s.mode.has(.PIPES_AS_CONCAT) and s.eatOp("||")) try args.append(s.a, try s.unary());
        return s.mk(l.pos, .{ .concat = .{ .args = args.items, .null_policy = .propagate } });
    }

    fn unary(s: *Parser) Error!*Expr {
        const pos = s.here();
        if (s.isOp("-") or s.isOp("+")) {
            const minus = s.isOp("-");
            s.advance();
            const e = try s.unary();
            if (!minus) return e;
            return s.mk(pos, .{ .unary = .{ .op = .neg, .e = e } });
        }
        if (s.eatOp("~")) return s.mk(pos, .{ .unary = .{ .op = .bit_not, .e = try s.unary() } });
        if (s.eatOp("!")) return s.mk(pos, .{ .unary = .{ .op = .not, .e = try s.unary() } });
        if (s.isKw("BINARY") and !s.peek().is("(")) {
            s.advance();
            return s.mk(pos, .{ .collate = .{ .e = try s.unary(), .collation = "BINARY" } });
        }
        return s.primaryWithCollate();
    }

    fn primaryWithCollate(s: *Parser) Error!*Expr {
        var e = try s.primary();
        // col->'path', col->>'path' (MySQL's; MariaDB has neither).
        while (s.isOp("->") or s.isOp("->>")) {
            const text = s.isOp("->>");
            const pos = s.here();
            s.advance();
            const path = try s.mk(s.here(), .{ .string = try s.stringLiteral() });
            e = try s.func(pos, "json_extract", &.{ e, path });
            if (text) e = try s.func(pos, "json_unquote", &.{e});
        }
        while (s.eatKw("COLLATE")) {
            const coll = try s.collationName();
            e = try s.mk(e.pos, .{ .collate = .{ .e = e, .collation = coll } });
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

    /// A string constant at `pos`.
    pub fn str(s: *Parser, pos: u32, z: []const u8) Error!*Expr {
        return tree.expr(s.a, pos, pos, .{ .string = z });
    }

    /// An integer constant at `pos`.
    pub fn int_(s: *Parser, pos: u32, v: i64) Error!*Expr {
        if (v < 0) {
            const x = try tree.expr(s.a, pos, pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{-v}) });
            return tree.expr(s.a, pos, pos, .{ .unary = .{ .op = .neg, .e = x } });
        }
        return tree.expr(s.a, pos, pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{v}) });
    }

    /// A call of `fname` (a function the frontend chose): of the
    /// dialect's table if it has one of that name (isDialectFunction()),
    /// else a SQLite built-in or an engine function.
    pub fn func(s: *Parser, pos: u32, fname: []const u8, args: []const *Expr) Error!*Expr {
        return s.funcNode(pos, .{ .name = .{ .text = fname, .pos = pos }, .args = try s.a.dupe(*Expr, args) });
    }

    /// A Func node (its `dialect` set as func() says).
    pub fn funcNode(s: *Parser, pos: u32, f: tree.Func) Error!*Expr {
        var x = f;
        x.dialect = if (isDialectFunction(f.name.text)) .mariadb else null;
        return s.mk(pos, .{ .func = try s.new(tree.Func, x) });
    }

    pub fn isSelectStart(s: *Parser) bool {
        return s.isKw("SELECT") or s.isKw("WITH") or (s.isOp("(") and isSelectish(s.peek())) or s.isKw("VALUES");
    }

    fn isSelectish(t: Token) bool {
        return t.isKw("SELECT") or t.isKw("WITH") or t.is("(");
    }

    /// Refuse what the schema may not keep (variables, parameters):
    /// `what` is its text.
    fn refuseStored(s: *Parser, what: []const u8) Error!void {
        const st = s.stored orelse return;
        if (st.clause.len == 0) return s.fail("View's SELECT contains a variable or parameter", .{});
        return s.fail("Function or expression '{s}' cannot be used in the {s} clause of `{s}`", .{ what, st.clause, st.name });
    }

    fn primary(s: *Parser) Error!*Expr {
        const t = s.tok;
        const pos = s.posOf(t);
        switch (t.kind) {
            .string => {
                const v = try s.stringLiteral();
                if (v.len == 0 and s.mode.has(.EMPTY_STRING_IS_NULL)) return s.mk(pos, .null);
                return s.mk(pos, .{ .string = v });
            },
            .integer => {
                s.advance();
                return s.mk(pos, .{ .integer = t.text });
            },
            .float => {
                s.advance();
                return s.mk(pos, .{ .float = t.text });
            },
            .hex => {
                s.advance();
                const digits = (try lexer.hexDigits(s.a, t)) orelse return s.syntaxErrorAt(t);
                return s.mk(pos, .{ .blob = digits });
            },
            .bit => {
                s.advance();
                const v = lexer.bitValue(t) orelse return s.fail("bit literal out of range", .{});
                if (v < 0) return s.int_(pos, v);
                return s.mk(pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{v}) });
            },
            .param => {
                try s.refuseStored(t.text);
                s.advance();
                return s.mk(pos, .{ .param = null });
            },
            .sys_var => {
                try s.refuseStored(t.text);
                s.advance();
                const name_ = try sysVarName(s, t);
                return s.func(pos, "xq_sysvar", &.{try s.str(pos, name_)});
            },
            .user_var => {
                try s.refuseStored(t.text);
                s.advance();
                const name_ = try userVarName(s, t);
                if (s.eatOp(":=")) {
                    const v = try s.expr();
                    return s.func(pos, "xq_set_uservar", &.{ try s.str(pos, name_), v });
                }
                return s.func(pos, "xq_uservar", &.{try s.str(pos, name_)});
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
        const pos = s.here();
        try s.expectOp("(");
        if (s.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
            const sub = try s.selectStmt();
            try s.expectOp(")");
            return s.mk(pos, .{ .subquery = sub });
        }
        const first = try s.expr();
        if (s.eatOp(")")) return first;
        var items: std.ArrayList(*Expr) = .empty;
        try items.append(s.a, first);
        while (s.eatOp(",")) try items.append(s.a, try s.expr());
        try s.expectOp(")");
        return s.mk(pos, .{ .row = items.items });
    }

    fn columnRef(s: *Parser) Error!*Expr {
        const pos = s.here();
        var names: std.ArrayList(Name) = .empty;
        try names.append(s.a, try s.nameOf(try s.anyName()));
        while (names.items.len < 3 and s.eatOp(".")) try names.append(s.a, try s.nameOf(try s.anyName()));
        return s.mk(pos, .{ .column = names.items });
    }

    /// An expression starting with a word: a keyword form, a function
    /// call or a column reference.
    fn wordExpr(s: *Parser) Error!*Expr {
        const t = s.tok;
        const pos = s.posOf(t);
        const next = s.peek();
        if (t.isKw("NULL") or t.isKw("UNKNOWN")) {
            s.advance();
            return s.mk(pos, .null);
        }
        if (t.isKw("TRUE") or t.isKw("FALSE")) {
            s.advance();
            return s.mk(pos, .{ .boolean = t.isKw("TRUE") });
        }
        if (t.isKw("CASE")) return s.caseExpr();
        if (t.isKw("EXISTS")) {
            s.advance();
            try s.expectOp("(");
            const sub = try s.selectStmt();
            try s.expectOp(")");
            return s.mk(pos, .{ .exists = sub });
        }
        if (t.isKw("DEFAULT") and s.allow_default and !next.is("(")) {
            s.advance();
            return s.mk(pos, .default);
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
            return s.func(pos, "nextval", &.{try s.str(s.posOf(seq), try s.nameText(seq))});
        }
        if ((t.isKw("PREVIOUS") or t.isKw("LASTVAL")) and next.isKw("VALUE")) {
            s.advance();
            s.advance();
            try s.expectKw("FOR");
            const seq = try s.anyName();
            return s.func(pos, "lastval", &.{try s.str(s.posOf(seq), try s.nameText(seq))});
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
            return @import("functions.zig").byName(s, n[1], &.{}, pos);
        };
        if (isReserved(t)) return s.syntaxError();
        return s.columnRef();
    }

    fn caseExpr(s: *Parser) Error!*Expr {
        const pos = s.here();
        try s.expectKw("CASE");
        const operand: ?*Expr = if (s.isKw("WHEN")) null else try s.expr();
        var whens: std.ArrayList(*Expr) = .empty;
        while (s.eatKw("WHEN")) {
            try whens.append(s.a, try s.expr());
            try s.expectKw("THEN");
            try whens.append(s.a, try s.expr());
        }
        if (whens.items.len == 0) return s.syntaxError();
        const else_: ?*Expr = if (s.eatKw("ELSE")) try s.expr() else null;
        try s.expectKw("END");
        return s.mk(pos, .{ .case = .{ .operand = operand, .whens = whens.items, .@"else" = else_ } });
    }

    pub fn exprList(s: *Parser) Error![]*Expr {
        var l: std.ArrayList(*Expr) = .empty;
        try l.append(s.a, try s.expr());
        while (s.eatOp(",")) try l.append(s.a, try s.expr());
        return l.items;
    }

    // ============================================================= SELECT

    /// `[WITH ...] select_body [ORDER BY ...] [LIMIT ...] [locking]`.
    pub fn selectStmt(s: *Parser) Error!*tree.Select {
        const pos = s.here();
        const jm = json_table.mark(s);
        var w: ?*tree.With = null;
        if (s.isKw("WITH")) w = try s.withClause();
        const body = try s.selectBody();
        const sel = try s.new(tree.Select, .{ .with = w, .body = body, .pos = pos });
        try s.orderLimit(sel);
        try s.lockingClause();
        try json_table.endSelect(s, jm, sel);
        return sel;
    }

    /// The ORDER BY and LIMIT of a whole SELECT.
    fn orderLimit(s: *Parser, sel: *tree.Select) Error!void {
        if (s.isKw("ORDER") and s.peek().isKw("BY")) {
            s.advance();
            s.advance();
            sel.order_by = try s.sortList();
        }
        if (s.isKw("LIMIT")) {
            const l = try s.limitClause();
            sel.limit = l.limit;
            sel.offset = l.offset;
        } else if (s.eatKw("OFFSET")) {
            // OFFSET n ROWS FETCH {FIRST|NEXT} m ROWS ONLY (MariaDB 10.6).
            sel.offset = try s.expr();
            _ = s.eatKw("ROWS") or s.eatKw("ROW");
            if (s.eatKw("FETCH")) sel.limit = try s.fetchFirst();
        } else if (s.eatKw("FETCH")) {
            sel.limit = try s.fetchFirst();
        }
    }

    fn fetchFirst(s: *Parser) Error!*Expr {
        if (!(s.eatKw("FIRST") or s.eatKw("NEXT"))) return s.syntaxError();
        const n = if (s.isKw("ROW") or s.isKw("ROWS")) try s.int_(s.here(), 1) else try s.expr();
        if (!(s.eatKw("ROWS") or s.eatKw("ROW"))) return s.syntaxError();
        if (s.isKw("WITH")) return s.fail("xqlite: FETCH ... WITH TIES is not supported", .{});
        try s.expectKw("ONLY");
        return n;
    }

    pub const Limit = struct { limit: *Expr, offset: ?*Expr = null };

    /// `LIMIT n`, `LIMIT off, n`, `LIMIT n OFFSET m`.
    pub fn limitClause(s: *Parser) Error!Limit {
        try s.expectKw("LIMIT");
        const first = try s.limitValue();
        if (s.eatOp(",")) return .{ .limit = try s.limitValue(), .offset = first };
        if (s.eatKw("OFFSET")) return .{ .limit = first, .offset = try s.limitValue() };
        if (s.isKw("ROWS")) return s.fail("xqlite: LIMIT ROWS EXAMINED is not supported", .{});
        return .{ .limit = first };
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

    /// A parenthesized list of names.
    pub fn nameList(s: *Parser) Error![]Name {
        try s.expectOp("(");
        var out: std.ArrayList(Name) = .empty;
        while (true) {
            try out.append(s.a, try s.nameOf(try s.anyName()));
            if (!s.eatOp(",")) break;
        }
        try s.expectOp(")");
        return out.items;
    }

    fn withClause(s: *Parser) Error!*tree.With {
        try s.expectKw("WITH");
        const recursive = s.eatKw("RECURSIVE");
        var ctes: std.ArrayList(tree.Cte) = .empty;
        while (true) {
            const n = try s.nameOf(try s.name());
            var cols: []Name = &.{};
            if (s.isOp("(")) cols = try s.nameList();
            try s.expectKw("AS");
            try s.expectOp("(");
            const q = try s.selectStmt();
            try s.expectOp(")");
            try ctes.append(s.a, .{ .name = n, .cols = cols, .select = q });
            if (!s.eatOp(",")) break;
        }
        return s.new(tree.With, .{ .recursive = recursive, .ctes = ctes.items });
    }

    /// Terms joined by UNION/EXCEPT/INTERSECT.
    fn selectBody(s: *Parser) Error!*tree.Body {
        var lhs = try s.selectTerm();
        while (true) {
            var op: tree.SetOp = undefined;
            var all = false;
            if (s.eatKw("UNION")) {
                op = .@"union";
                all = s.eatKw("ALL");
                if (!all) _ = s.eatKw("DISTINCT");
            } else if (s.eatKw("EXCEPT") or s.eatKw("MINUS")) {
                if (s.eatKw("ALL")) return s.fail("xqlite: EXCEPT ALL is not supported", .{});
                _ = s.eatKw("DISTINCT");
                op = .except;
            } else if (s.eatKw("INTERSECT")) {
                if (s.eatKw("ALL")) return s.fail("xqlite: INTERSECT ALL is not supported", .{});
                _ = s.eatKw("DISTINCT");
                op = .intersect;
            } else break;
            const rhs = try s.selectTerm();
            lhs = try s.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = lhs, .right = rhs } });
        }
        return lhs;
    }

    fn selectTerm(s: *Parser) Error!*tree.Body {
        if (s.eatOp("(")) {
            const inner = try s.selectStmt();
            try s.expectOp(")");
            return s.new(tree.Body, .{ .nested = inner });
        }
        if (s.isKw("VALUES")) return s.new(tree.Body, .{ .values = try s.valuesRows() });
        return s.new(tree.Body, .{ .core = try s.selectCore() });
    }

    /// `VALUES (row), (row) ...` (an empty row is allowed).
    pub fn valuesRows(s: *Parser) Error![][]*Expr {
        if (!(s.eatKw("VALUES") or s.eatKw("VALUE"))) return s.syntaxError();
        var rows: std.ArrayList([]*Expr) = .empty;
        while (true) {
            try s.expectOp("(");
            const row: []*Expr = if (s.isOp(")")) &.{} else try s.exprList();
            try s.expectOp(")");
            try rows.append(s.a, row);
            if (!s.eatOp(",")) break;
        }
        return rows.items;
    }

    fn selectCore(s: *Parser) Error!*tree.Core {
        const pos = s.here();
        const jm = json_table.mark(s);
        try s.expectKw("SELECT");
        var distinct = false;
        var straight = false;
        while (true) {
            if (s.eatKw("DISTINCT") or s.eatKw("DISTINCTROW")) {
                distinct = true;
            } else if (s.eatKw("ALL")) {
                distinct = false;
            } else if (s.eatKw("STRAIGHT_JOIN")) {
                straight = true;
            } else if (s.eatKw("HIGH_PRIORITY") or s.eatKw("SQL_SMALL_RESULT") or s.eatKw("SQL_BIG_RESULT") or
                s.eatKw("SQL_BUFFER_RESULT") or s.eatKw("SQL_CACHE") or s.eatKw("SQL_NO_CACHE") or
                s.eatKw("SQL_CALC_FOUND_ROWS"))
            {} else break;
        }
        const cols = try s.resultColumns();
        if (s.isKw("INTO")) return s.fail("xqlite: SELECT ... INTO is not supported", .{});
        var from: []tree.FromItem = &.{};
        if (s.eatKw("FROM")) {
            if (s.isKw("DUAL")) {
                s.advance();
            } else {
                from = try s.tableRefs();
                // SELECT STRAIGHT_JOIN: the tables are joined in order.
                if (straight) for (from[1..]) |*item| switch (item.join) {
                    .comma, .inner, .cross => item.join = .straight,
                    else => {},
                };
            }
        }
        const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
        var group: std.ArrayList(*Expr) = .empty;
        if (s.isKw("GROUP")) {
            s.advance();
            try s.expectKw("BY");
            while (true) {
                try group.append(s.a, try s.expr());
                _ = s.eatKw("ASC") or s.eatKw("DESC");
                if (!s.eatOp(",")) break;
            }
            if (s.isKw("WITH") and s.peek().isKw("ROLLUP")) return s.fail("xqlite: GROUP BY ... WITH ROLLUP is not supported", .{});
        }
        const having: ?*Expr = if (s.eatKw("HAVING")) try s.expr() else null;
        var windows: []tree.NamedWindow = &.{};
        if (s.eatKw("WINDOW")) windows = try s.windowDefs();
        const core = try s.new(tree.Core, .{
            .distinct = distinct,
            .cols = cols,
            .from = from,
            .where = where,
            .group_by = group.items,
            .having = having,
            .windows = windows,
            .pos = pos,
        });
        try json_table.endCore(s, jm, core);
        return core;
    }

    fn resultColumns(s: *Parser) Error![]tree.ResultCol {
        var l: std.ArrayList(tree.ResultCol) = .empty;
        while (true) {
            if (s.isOp("*")) {
                try l.append(s.a, .{ .star = s.here() });
                s.advance();
            } else if ((s.tok.kind == .ident or s.tok.kind == .quoted_ident) and s.peek().is(".") and s.peek2().is("*")) {
                const tbl = try s.nameOf(s.tok);
                s.advance();
                s.advance();
                const star = s.here();
                s.advance();
                try l.append(s.a, .{ .table_star = .{ .names = try s.a.dupe(Name, &.{tbl}), .star_pos = star } });
            } else {
                const start = s.here();
                const e = try s.expr();
                const end = s.endPos();
                const al = try s.alias(true);
                // MariaDB names a column by the expression as written, a
                // string by its value.
                const text: ?[]const u8 = switch (e.kind) {
                    .column => null,
                    .string => |v| v,
                    else => s.lx.sql[start..end],
                };
                try l.append(s.a, .{ .expr = .{ .e = e, .alias = al, .name = if (al == null) text else null } });
            }
            if (!s.eatOp(",")) break;
        }
        return l.items;
    }

    /// `[AS] name` (or a string, for a column alias).
    pub fn alias(s: *Parser, string_ok: bool) Error!?Name {
        if (s.eatKw("AS")) {
            if (string_ok and s.tok.kind == .string) return try s.stringAlias();
            return try s.nameOf(try s.anyName());
        }
        if (s.isName()) {
            const t = s.tok;
            s.advance();
            return try s.nameOf(t);
        }
        if (string_ok and s.tok.kind == .string) return try s.stringAlias();
        return null;
    }

    /// A string as a name.
    fn stringAlias(s: *Parser) Error!Name {
        const pos = s.here();
        return .{ .text = try s.stringLiteral(), .pos = pos };
    }

    pub fn sortList(s: *Parser) Error![]tree.SortItem {
        var l: std.ArrayList(tree.SortItem) = .empty;
        while (true) {
            const e = try s.expr();
            var item: tree.SortItem = .{ .expr = e };
            if (s.eatKw("ASC")) {
                item.dir = .asc;
            } else if (s.eatKw("DESC")) item.dir = .desc;
            try l.append(s.a, item);
            if (!s.eatOp(",")) break;
        }
        return l.items;
    }

    // ----------------------------------------------------------- windows

    fn windowDefs(s: *Parser) Error![]tree.NamedWindow {
        var list: std.ArrayList(tree.NamedWindow) = .empty;
        while (true) {
            const n = try s.nameOf(try s.name());
            try s.expectKw("AS");
            try s.expectOp("(");
            const w = try s.windowSpec();
            try s.expectOp(")");
            try list.append(s.a, .{ .name = n, .spec = w });
            if (!s.eatOp(",")) break;
        }
        return list.items;
    }

    /// The inside of OVER ( ... ) or WINDOW w AS ( ... ).
    fn windowSpec(s: *Parser) Error!*tree.WindowSpec {
        var w: tree.WindowSpec = .{};
        if (s.isName() and !s.isKw("PARTITION") and !s.isKw("ORDER") and !s.isKw("ROWS") and !s.isKw("RANGE")) {
            w.base = try s.nameOf(try s.name());
        }
        if (s.eatKw("PARTITION")) {
            try s.expectKw("BY");
            w.partition = try s.exprList();
        }
        if (s.isKw("ORDER")) {
            s.advance();
            try s.expectKw("BY");
            w.order_by = try s.sortList();
        }
        w.frame = try s.frame();
        return s.new(tree.WindowSpec, w);
    }

    fn frame(s: *Parser) Error!?tree.Frame {
        var f: tree.Frame = undefined;
        if (s.eatKw("ROWS")) {
            f.unit = .rows;
        } else if (s.eatKw("RANGE")) {
            f.unit = .range;
        } else return null;
        f.end = null;
        if (s.eatKw("BETWEEN")) {
            f.start = try s.frameBound();
            try s.expectKw("AND");
            f.end = try s.frameBound();
        } else f.start = try s.frameBound();
        f.exclude = .none;
        if (s.eatKw("EXCLUDE")) {
            if (s.eatKw("CURRENT")) {
                try s.expectKw("ROW");
                f.exclude = .current_row;
            } else if (s.eatKw("GROUP")) {
                f.exclude = .group;
            } else if (s.eatKw("TIES")) {
                f.exclude = .ties;
            } else if (s.eatKw("NO")) {
                try s.expectKw("OTHERS");
                f.exclude = .no_others;
            } else return s.syntaxError();
        }
        return f;
    }

    fn frameBound(s: *Parser) Error!tree.Bound {
        if (s.eatKw("UNBOUNDED")) {
            if (s.eatKw("PRECEDING")) return .{ .kind = .unbounded_preceding };
            if (s.eatKw("FOLLOWING")) return .{ .kind = .unbounded_following };
            return s.syntaxError();
        }
        if (s.eatKw("CURRENT")) {
            try s.expectKw("ROW");
            return .{ .kind = .current_row };
        }
        const e = try s.additive();
        if (s.eatKw("PRECEDING")) return .{ .kind = .preceding, .expr = e };
        if (s.eatKw("FOLLOWING")) return .{ .kind = .following, .expr = e };
        return s.syntaxError();
    }

    /// `OVER (spec)` or `OVER name` after a function call.
    pub fn overClause(s: *Parser) Error!?*tree.WindowSpec {
        if (!s.eatKw("OVER")) return null;
        if (s.eatOp("(")) {
            const w = try s.windowSpec();
            try s.expectOp(")");
            return w;
        }
        const n = try s.nameOf(try s.name());
        return s.new(tree.WindowSpec, .{ .base = n, .name_only = true });
    }

    // -------------------------------------------------------------- FROM

    /// Table references joined by commas and JOINs.
    fn tableRefs(s: *Parser) Error![]tree.FromItem {
        var list: std.ArrayList(tree.FromItem) = .empty;
        try list.append(s.a, try s.tableFactor());
        while (true) {
            const j = (try s.joinOp()) orelse break;
            var item = try s.tableFactor();
            item.join = j.join;
            item.natural = j.natural;
            try list.append(s.a, item);
        }
        return list.items;
    }

    const Join = struct { join: tree.JoinKind, natural: bool = false };

    fn joinOp(s: *Parser) Error!?Join {
        if (s.eatOp(",")) return .{ .join = .comma };
        if (s.eatKw("JOIN")) return .{ .join = .inner };
        if (s.eatKw("STRAIGHT_JOIN")) return .{ .join = .straight };
        if (s.eatKw("INNER")) {
            try s.expectKw("JOIN");
            return .{ .join = .inner };
        }
        if (s.eatKw("CROSS")) {
            try s.expectKw("JOIN");
            return .{ .join = .cross };
        }
        const natural = s.eatKw("NATURAL");
        var j: Join = .{ .join = .inner, .natural = natural };
        if (s.isKw("LEFT") or s.isKw("RIGHT")) {
            j.join = if (s.isKw("LEFT")) .left else .right;
            s.advance();
            _ = s.eatKw("OUTER");
        } else if (natural) {
            _ = s.eatKw("INNER");
        } else return null;
        try s.expectKw("JOIN");
        return j;
    }

    fn onUsing(s: *Parser, item: *tree.FromItem) Error!void {
        if (s.eatKw("ON")) {
            item.on = try s.expr();
        } else if (s.eatKw("USING")) {
            try s.expectOp("(");
            var ids: std.ArrayList(Name) = .empty;
            while (true) {
                try ids.append(s.a, try s.nameOf(try s.name()));
                if (!s.eatOp(",")) break;
            }
            try s.expectOp(")");
            item.using = ids.items;
        }
    }

    fn aliasOf(s: *Parser) Error!?tree.Alias {
        const n = (try s.alias(false)) orelse return null;
        return .{ .name = n };
    }

    fn tableFactor(s: *Parser) Error!tree.FromItem {
        var item: tree.FromItem = .{ .source = undefined };
        if (s.isOp("(")) {
            const n = s.peek();
            if (n.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
                s.advance();
                const sub = try s.selectStmt();
                try s.expectOp(")");
                item.source = .{ .subquery = sub };
                item.alias = try s.aliasOf();
                try s.onUsing(&item);
                return item;
            }
            s.advance();
            const inner = try s.tableRefs();
            try s.expectOp(")");
            item.source = .{ .nested = inner };
            item.alias = try s.aliasOf();
            try s.onUsing(&item);
            return item;
        }
        const q = try s.qualifiedName();
        if (q.schema == null and s.isOp("(") and std.ascii.eqlIgnoreCase(q.name.text, "json_table")) {
            item = try json_table.fromItem(s, q.name.pos);
            try s.onUsing(&item);
            return item;
        }
        if (s.isKw("PARTITION")) return s.fail("xqlite: PARTITION is not supported", .{});
        if (q.schema) |sch| if (std.ascii.eqlIgnoreCase(sch.text, "information_schema")) {
            const sub = (try @import("infoschema.zig").select(s, q.name.text)) orelse
                return s.fail("Unknown table '{s}' in information_schema", .{q.name.text});
            item.source = .{ .subquery = sub };
            item.alias = (try s.aliasOf()) orelse .{ .name = q.name };
            try s.onUsing(&item);
            return item;
        };
        if (s.eatOp("(")) {
            // A table-valued function (SQLite's json_each(), pragma_*()).
            const args: []*Expr = if (s.isOp(")")) &.{} else try s.exprList();
            try s.expectOp(")");
            item.source = .{ .func = try s.new(tree.Func, .{ .name = q.name, .args = args }) };
        } else item.source = .{ .table = q };
        item.alias = try s.aliasOf();
        try s.indexHints();
        try s.onUsing(&item);
        return item;
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
    pub fn target(s: *Parser, q: QName) Error!Target {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const schema_name: ?[]const u8 = if (q.schema) |x| x.text else null;
        var tab = build.findTable(s.p.db, q.name.text, schema_name) orelse return .{ .tab = null, .schema = "main", .cols = &.{} };
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

    /// How a value is stored (wrapValue()).
    pub const Wrap = struct {
        row: u32 = 1,
        ignore: bool = false,
        /// The NULL for a NOT NULL column without a DEFAULT that the
        /// INSERT leaves out.
        missing: bool = false,
        multi_row: bool = false,
        /// Whether AUTO_INCREMENT's 0 means the next value (INSERT).
        insert: bool = true,
    };

    /// The value `e` stored into column `c`: MariaDB's conversion (a
    /// Coerce, types.coerceFunc) if the column has a MariaDB type, and
    /// NULLIF(v, 0) for an AUTO_INCREMENT column of an INSERT (0
    /// generates the next value unless NO_AUTO_VALUE_ON_ZERO). A DEFAULT
    /// in `e` is the column's default (lower.zig).
    pub fn wrapValue(s: *Parser, t: *const Target, c: *const ColMeta, e: *Expr, w: Wrap) Error!*Expr {
        var x = e;
        const autoinc = c.autoinc and w.insert;
        if (c.decl_type) |ty| {
            x = try tree.expr(s.a, e.pos, e.end, .{ .coerce = .{
                .e = x,
                .decl_type = ty,
                .schema = t.schema,
                .table = t.name,
                .column = c.name,
                .ignore = w.ignore,
                .not_null = (c.not_null and !autoinc) or w.missing,
                .missing = w.missing,
                .multi_row = w.multi_row,
                .row = w.row,
            } });
        }
        if (autoinc and !s.mode.has(.NO_AUTO_VALUE_ON_ZERO)) x = try s.func(e.pos, "nullif", &.{ x, try s.int_(e.pos, 0) });
        return x;
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

/// A lowering failure as the frontend's error (the message is in Parse).
pub fn lowered(err: lower.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.ParseFailed,
    };
}

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
    const lname = try std.ascii.allocLowerString(s.a, z);
    if (!@import("session.zig").isSysVar(lname)) return s.fail("Unknown system variable '{s}'", .{z});
    return lname;
}

/// The name of @name (case-insensitive: lower case).
fn userVarName(s: *Parser, t: Token) Error![]const u8 {
    var z = t.text[1..];
    if (z.len > 0 and (z[0] == '`' or z[0] == '\'' or z[0] == '"')) {
        z = if (z[0] == '`') try lexer.identValue(s.a, .{ .kind = .quoted_ident, .text = z }) else try lexer.stringValue(s.a, .{ .kind = .string, .text = z }, false);
    }
    return std.ascii.allocLowerString(s.a, z);
}
