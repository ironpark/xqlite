//! The T-SQL parser: hand-written recursive descent over lexer.zig's
//! tokens producing the syntax tree IR (src/ir/tree.zig) with SQL
//! Server's semantics resolved, which src/ir/lower.zig lowers and
//! src/ir/render.zig renders for the schema.
//!
//! This file has the parser core, names, expressions and SELECT;
//! functions.zig has function calls, dml.zig the DML (MERGE too), ddl.zig
//! the DDL and session.zig the session statements (SET, DECLARE,
//! transactions).
//!
//! Precedence (lowest first): OR, AND, NOT, comparisons and predicates
//! (= <> != < <= > >= !< !> IS LIKE IN BETWEEN), + - & ^ |, * / %,
//! unary - + ~, COLLATE. Where SQL Server and SQLite disagree the tree
//! says what SQL Server means:
//!  - `+` of two strings is a Concat (NULL if an operand is), of numbers
//!    an addition. Which one is decided from the operands' types where
//!    the parser knows them (literals, casts, functions, variables),
//!    else when the statement runs by the engine function xq_tsql_add(),
//!    from the values' storage classes (TEXT and TEXT concatenate), which
//!    in the dialect's STRICT tables are those of the declared types;
//!  - `^` is a bitwise XOR ((a | b) & ~(a & b));
//!  - LIKE folds case (the default collation is case-insensitive) and
//!    has no escape character; a pattern with [...] classes, or one that
//!    is not a constant, is the engine function xq_tsql_like();
//!  - names compare case-insensitively (as SQLite's), the schema dbo is
//!    SQLite's main, a #temp table lives in temp, a table t of a schema s
//!    of CREATE SCHEMA is main's "s.t" (catalog/schema.zig), aliased t.
//!
//! What the schema keeps (DEFAULT, CHECK, computed columns, views) is
//! parsed with `stored` set: variables and parameters are refused there.

const std = @import("std");
const ctype = @import("../../util/ctype.zig");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const dialect = @import("../dialect.zig");
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const json_sql = @import("json_sql.zig");
const nsp = catalog.schemas;

const Parse = int.Parse;
const Expr = tree.Expr;
const Name = tree.Name;
const QName = tree.QName;

pub const Token = lexer.Token;
pub const Error = int.Oom || int.ParseError;

/// SQL Server's reserved words and the words that cannot be an alias
/// where one is optional.
const reserved = blk: {
    @setEvalBranchQuota(20_000);
    const words = [_][]const u8{
        "ADD",          "ALL",          "ALTER",             "AND",          "ANY",      "APPLY",   "AS",     "ASC",
        "BEGIN",        "BETWEEN",      "BREAK",             "BY",           "CASCADE",  "CASE",    "CHECK",  "CLUSTERED",
        "COLLATE",      "COLUMN",       "COMMIT",            "CONSTRAINT",   "CONTINUE", "CREATE",  "CROSS",  "CURRENT",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DECLARE",  "DEFAULT", "DELETE", "DENY",
        "DESC",         "DISTINCT",     "DROP",              "ELSE",         "END",      "ESCAPE",  "EXCEPT", "EXEC",
        "EXECUTE",      "EXISTS",       "FETCH",             "FOR",          "FOREIGN",  "FROM",    "FULL",   "FUNCTION",
        "GOTO",         "GRANT",        "GROUP",             "HAVING",       "IDENTITY", "IF",      "IN",     "INDEX",
        "INNER",        "INSERT",       "INTERSECT",         "INTO",         "IS",       "JOIN",    "KEY",    "LEFT",
        "LIKE",         "MERGE",        "NONCLUSTERED",      "NOT",          "NULL",     "OFFSET",  "ON",     "OPTION",
        "OR",           "ORDER",        "OUTER",             "OUTPUT",       "OVER",     "PERCENT", "PIVOT",  "PRIMARY",
        "PRINT",        "PROC",         "PROCEDURE",         "REFERENCES",   "RETURN",   "REVOKE",  "RIGHT",  "ROLLBACK",
        "SAVE",         "SELECT",       "SET",               "SOME",         "TABLE",    "THEN",    "TO",     "TOP",
        "TRAN",         "TRANSACTION",  "TRUNCATE",          "UNION",        "UNIQUE",   "UNPIVOT", "UPDATE", "USE",
        "USING",        "VALUES",       "VIEW",              "WHEN",         "WHERE",    "WHILE",   "WINDOW", "WITH",
        "WITHIN",
    };
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    break :blk std.StaticStringMapWithEql(void, ctype.eqlNoCase).initComptime(kvs);
};

pub fn isReserved(t: Token) bool {
    return t.kind == .ident and reserved.has(t.text);
}

/// The words that start a statement: one ends the statement before it
/// (T-SQL needs no semicolons).
pub fn startsStatement(t: Token) bool {
    return t.kind == .go or t.isAnyKw(&.{
        "SELECT",  "INSERT", "UPDATE",   "DELETE", "MERGE", "CREATE",  "DROP",  "ALTER", "TRUNCATE",
        "BEGIN",   "COMMIT", "ROLLBACK", "SAVE",   "SET",   "DECLARE", "PRINT", "USE",   "EXEC",
        "EXECUTE", "IF",     "WHILE",    "RETURN", "GRANT", "REVOKE",  "DENY",
    });
}

/// Whether `name` is a function of the dialect's table (frontend.zig):
/// a call of it is a Func of .mssql, which the schema keeps as
/// xq_mssql_<name>.
pub fn isDialectFunction(name: []const u8) bool {
    return dialect.spec(.mssql).function_map.get(name) != null;
}

/// The static type class of an expression (Parser.classOf()).
pub const Class = enum { string, number, unknown };

/// The statement an OUTPUT clause belongs to.
pub const Output = enum { insert, update, delete };

/// What TOP said of a SELECT.
pub const Top = struct { n: *Expr, percent: bool = false };

/// `@name = expr` of SELECT @a = x, @b = y FROM ...
pub const Assign = struct { name: []const u8, value: *Expr };

pub const Parser = struct {
    p: *Parse,
    a: std.mem.Allocator,
    lx: lexer.Lexer,
    tok: Token,
    prev_end: [*]const u8,
    /// Parsing the VALUES rows or SET list of INSERT/UPDATE: DEFAULT
    /// stands for the column's default (tree.Kind.default).
    allow_default: bool = false,
    /// Parsing what the schema keeps: no variables or parameters.
    stored: bool = false,
    /// Nesting of queries: the statement's own is depth 1.
    depth: u32 = 0,
    /// Classes of the nodes whose class classOf() cannot see (variables).
    classes: std.AutoHashMapUnmanaged(*const Expr, Class) = .empty,
    /// TOP of the SELECT cores parsed.
    tops: std.AutoHashMapUnmanaged(*const tree.Core, Top) = .empty,
    /// SELECT @a = ...: the assignments of the statement's query.
    assigns: ?[]Assign = null,
    /// SELECT ... INTO t: the new table.
    into: ?QName = null,
    /// The xq_tsql_add() calls made (resolvePlus() has work).
    n_plus: u32 = 0,
    /// Parsing the OUTPUT clause of this statement: INSERTED.c and
    /// DELETED.c are the target's columns (RETURNING), where allowed.
    output: ?Output = null,
    /// JSON value kinds known once the FROM clause is (json_sql.zig).
    json_fixes: std.ArrayList(json_sql.Fix) = .empty,
    /// The columns of the OPENJSON calls parsed (json_sql.openJson()).
    openjson_cols: std.AutoHashMapUnmanaged(*const tree.Func, []const json_sql.Col) = .empty,
    /// The schemas of CREATE SCHEMA (registered()), read once.
    schemas: ?[]const nsp.Info = null,
    /// The names of the WITH queries parsed: an unqualified name that is
    /// one stays as written (unqualified()).
    cte_names: std.ArrayList([]const u8) = .empty,
    /// Compiling an element of CREATE SCHEMA s (CREATE TABLE ...): s,
    /// where unqualified names are created and first looked up.
    element_schema: ?[]const u8 = null,

    pub fn init(p: *Parse, sql: [:0]const u8) Parser {
        var s: Parser = .{
            .p = p,
            .a = p.arena,
            .lx = .init(sql),
            .tok = undefined,
            .prev_end = sql.ptr,
        };
        s.tok = s.lx.next();
        return s;
    }

    pub fn advance(s: *Parser) void {
        s.prev_end = s.tok.end();
        s.tok = s.lx.next();
    }

    pub fn peek(s: *Parser) Token {
        var copy = s.lx;
        return copy.next();
    }

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

    pub fn isAnyKw(s: *Parser, comptime kws: []const []const u8) bool {
        return s.tok.isAnyKw(kws);
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

    /// IF EXISTS
    pub fn ifExists(s: *Parser) Error!bool {
        if (!s.isKw("IF")) return false;
        if (!s.peek().isKw("EXISTS")) return false;
        s.advance();
        s.advance();
        return true;
    }

    /// The end of the statement: `;`, GO, the end of the text, or a word
    /// that starts another statement.
    pub fn atStmtEnd(s: *Parser) bool {
        return s.tok.kind == .eof or s.tok.is(";") or startsStatement(s.tok);
    }

    /// SQL Server's syntax error at the current token.
    pub fn syntaxError(s: *Parser) Error {
        return s.syntaxErrorAt(s.tok);
    }

    pub fn syntaxErrorAt(s: *Parser, t: Token) Error {
        if (s.p.n_err > 0) return error.ParseFailed;
        if (t.kind == .illegal and t.text.len > 0 and (t.text[0] == '\'' or t.text[0] == 'N' or t.text[0] == 'n')) {
            ir.stmt.errorMsgAt(s.p, t.text.ptr, "Unclosed quotation mark after the character string '{s}'.", .{t.text[@min(t.text.len, @as(usize, if (t.text[0] == '\'') 1 else 2))..]});
            return error.ParseFailed;
        }
        // At the end: the token before it.
        const near: []const u8 = if (t.kind == .eof) blk: {
            const start = @intFromPtr(s.lx.sql.ptr);
            var i = @intFromPtr(s.prev_end) - start;
            var j = i;
            while (j > 0 and !std.ascii.isWhitespace(s.lx.sql[j - 1])) j -= 1;
            if (j == i) i = j;
            break :blk s.lx.sql[j..i];
        } else t.text;
        ir.stmt.errorMsgAt(s.p, t.text.ptr, "Incorrect syntax near '{s}'.", .{near[0..@min(near.len, 80)]});
        return error.ParseFailed;
    }

    /// An error with a message.
    pub fn fail(s: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (s.p.n_err == 0) ir.stmt.errorMsg(s.p, fmt, args);
        return error.ParseFailed;
    }

    pub fn check(s: *Parser) Error!void {
        if (s.p.n_err > 0) return error.ParseFailed;
    }

    // --------------------------------------------------------- positions

    pub fn offset(s: *const Parser, ptr: [*]const u8) u32 {
        return @intCast(@intFromPtr(ptr) - @intFromPtr(s.lx.sql.ptr));
    }

    pub fn posOf(s: *const Parser, t: Token) u32 {
        return s.offset(t.text.ptr);
    }

    pub fn here(s: *const Parser) u32 {
        return s.posOf(s.tok);
    }

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

    pub fn lowerer(s: *Parser) lower.Lowerer {
        return .init(s.p, s.lx.sql);
    }

    /// Lower statement `st` with the IR.
    pub fn lowerStmt(s: *Parser, st: tree.Stmt) Error!void {
        var l = s.lowerer();
        l.statement(st) catch |err| return lowered(err);
    }

    // =============================================================== names

    /// A name: a word that is not reserved, or a delimited identifier.
    pub fn name(s: *Parser) Error!Token {
        if (s.isName()) {
            const t = s.tok;
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

    pub fn nameText(s: *Parser, t: Token) Error![]const u8 {
        return lexer.identValue(s.a, t);
    }

    pub fn nameOf(s: *Parser, t: Token) Error!Name {
        return .{ .text = try lexer.identValue(s.a, t), .pos = s.posOf(t) };
    }

    /// A string literal's value.
    pub fn stringLiteral(s: *Parser) Error![]const u8 {
        if (s.tok.kind != .string) return s.syntaxError();
        const v = try lexer.stringValue(s.a, s.tok);
        s.advance();
        return v;
    }

    /// The SQLite database a T-SQL schema name stands for: dbo (and
    /// main) is main, temp/tempdb temp, an attached database itself; a
    /// schema of CREATE SCHEMA is not one (resolveParts() maps it).
    pub fn mapSchema(s: *Parser, n: Name) Error!Name {
        return (try s.sqliteDb(n.text, n.pos)) orelse s.noSchema(n.text);
    }

    /// The SQLite database `t` names (dbo, main, temp, tempdb, an attached
    /// database), null if none.
    pub fn sqliteDb(s: *Parser, t: []const u8, pos: u32) Error!?Name {
        if (std.ascii.eqlIgnoreCase(t, "dbo") or std.ascii.eqlIgnoreCase(t, "main") or t.len == 0) return .{ .text = "main", .pos = pos };
        if (std.ascii.eqlIgnoreCase(t, "tempdb") or std.ascii.eqlIgnoreCase(t, "temp")) return .{ .text = "temp", .pos = pos };
        if (build.findDbName(s.p.db, t) != null) return .{ .text = t, .pos = pos };
        return null;
    }

    /// The schemas of CREATE SCHEMA (catalog/schema.zig), read once per
    /// parser.
    pub fn registered(s: *Parser) Error![]const nsp.Info {
        if (s.schemas) |l| return l;
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const l = nsp.list(s.p.db, s.a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
        };
        s.schemas = l;
        return l;
    }

    /// The registered schema called `n`, null if none (dbo, sys ... are
    /// not registered).
    pub fn findSchema(s: *Parser, n: []const u8) Error!?nsp.Info {
        return nsp.find(try s.registered(), n);
    }

    /// The name within its schema of a SQLite name: "t" of a mangled
    /// "s.t" whose s is a schema of CREATE SCHEMA, else the name itself.
    pub fn bareName(s: *Parser, z: []const u8) Error![]const u8 {
        const sp = nsp.split(z) orelse return z;
        return if (try s.findSchema(sp.schema) != null) sp.name else z;
    }

    /// The alias a FROM item or DML target naming `q` takes: the name
    /// within its schema when `q` is mangled (so that t.col finds s.t),
    /// else null.
    pub fn autoAlias(s: *Parser, q: QName) Error!?Name {
        if (q.schema != null) return null;
        const sp = nsp.split(q.name.text) orelse return null;
        if (try s.findSchema(sp.schema) == null) return null;
        return .{ .text = sp.name, .pos = q.name.pos };
    }

    /// What a name is read for: an object to look up, or one to create
    /// (its schema must exist).
    pub const NameUse = enum { lookup, create };

    /// `[db.][schema.]name`: dbo is main (SQLite's database), a #name is
    /// a temporary table, `db..name` skips the schema. A schema of CREATE
    /// SCHEMA is main with the mangled name "schema.name", written
    /// without a database. An unqualified name is the session's default
    /// schema's (ALTER USER ... WITH DEFAULT_SCHEMA) if it has one of that
    /// name, else dbo's. A schema that does not exist fails a `create`;
    /// a `lookup` gets a name that is no table, which fails as SQL
    /// Server's "Invalid object name 's.t'".
    pub fn qualifiedName(s: *Parser) Error!QName {
        return s.qualifiedNameFor(.lookup);
    }

    pub fn qualifiedNameFor(s: *Parser, use: NameUse) Error!QName {
        var parts: std.ArrayList(Name) = .empty;
        try parts.append(s.a, try s.nameOf(try s.anyName()));
        while (s.isOp(".") and parts.items.len < 3) {
            s.advance();
            if (s.isOp(".")) {
                // db..name: the default schema.
                try parts.append(s.a, .{ .text = "", .pos = s.here() });
                continue;
            }
            try parts.append(s.a, try s.nameOf(try s.anyName()));
        }
        return s.resolveParts(parts.items, use);
    }

    /// The parts of a name (1 to 3) resolved as qualifiedName() does.
    pub fn resolveParts(s: *Parser, ps: []const Name, use: NameUse) Error!QName {
        const last = ps[ps.len - 1];
        if (ps.len == 1) return s.unqualified(last, use);
        // db.schema.name: the database decides; dbo (or nothing) is its
        // default schema, another one a schema of CREATE SCHEMA in main.
        if (ps.len == 3) {
            const db = (try s.sqliteDb(ps[0].text, ps[0].pos)) orelse return s.noSchema(ps[0].text);
            if (ps[1].text.len == 0 or std.ascii.eqlIgnoreCase(ps[1].text, "dbo")) return .{ .schema = db, .name = last };
            if (std.mem.eql(u8, db.text, "main")) return s.inSchema(ps[1], last, use);
            if (use == .create) return s.noSchema(ps[1].text);
            return .{ .schema = db, .name = .{ .text = try nsp.mangle(s.a, ps[1].text, last.text), .pos = last.pos } };
        }
        if (try s.sqliteDb(ps[0].text, ps[0].pos)) |db| return .{ .schema = db, .name = last };
        return s.inSchema(ps[0], last, use);
    }

    /// `sch.n` where sch is no SQLite database: a schema of CREATE SCHEMA.
    fn inSchema(s: *Parser, sch: Name, n: Name, use: NameUse) Error!QName {
        if (try s.findSchema(sch.text)) |i| return .{ .name = .{ .text = try nsp.mangle(s.a, i.name, n.text), .pos = n.pos } };
        if (use == .create) return s.noSchema(sch.text);
        return .{ .name = .{ .text = try nsp.mangle(s.a, sch.text, n.text), .pos = n.pos } };
    }

    /// SQL Server's error 2760.
    pub fn noSchema(s: *Parser, sch: []const u8) Error {
        return s.fail("The specified schema name \"{s}\" either does not exist or you do not have permission to use it.", .{sch});
    }

    /// An unqualified name: the session's default schema's object of that
    /// name (or, to create, the default schema's), else dbo's.
    fn unqualified(s: *Parser, n: Name, use: NameUse) Error!QName {
        if (n.text.len > 0 and n.text[0] == '#') return .{ .name = n };
        const sch = s.element_schema orelse s.p.db.xq.mssql.default_schema orelse return .{ .name = n };
        const info = (try s.findSchema(sch)) orelse return .{ .name = n };
        const m: Name = .{ .text = try nsp.mangle(s.a, info.name, n.text), .pos = n.pos };
        if (use == .create) return .{ .name = m };
        for (s.cte_names.items) |c| if (std.ascii.eqlIgnoreCase(c, n.text)) return .{ .name = n };
        if (build.findTable(s.p.db, m.text, "main") != null) return .{ .name = m };
        if (try s.sequenceExists(m.text)) return .{ .name = m };
        return .{ .name = n };
    }

    /// Whether main has sequence `name` (now).
    pub fn sequenceExists(s: *Parser, seq: []const u8) Error!bool {
        if (!catalog.sequence.exists(s.p.db, catalog.main_schema)) return false;
        var q = catalog.Query.initFmt(s.p.db, "SELECT 1 FROM main.xq_sequence WHERE name=%Q COLLATE NOCASE", &.{.{ .str = seq }}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
        };
        defer q.deinit();
        return q.step() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
        };
    }

    // ======================================================== expressions

    pub fn expr(s: *Parser) Error!*Expr {
        return s.orExpr();
    }

    pub fn bin(s: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return tree.expr(s.a, l.pos, r.end, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    fn orExpr(s: *Parser) Error!*Expr {
        var l = try s.andExpr();
        while (s.eatKw("OR")) l = try s.bin(.@"or", l, try s.andExpr());
        return l;
    }

    fn andExpr(s: *Parser) Error!*Expr {
        var l = try s.notExpr();
        while (s.eatKw("AND")) l = try s.bin(.@"and", l, try s.notExpr());
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
            .{ "=", .eq }, .{ "<>", .ne }, .{ "!=", .ne }, .{ "<", .lt },  .{ "<=", .le },
            .{ ">", .gt }, .{ ">=", .ge }, .{ "!<", .ge }, .{ "!>", .le },
        };
        for (ops) |o| if (std.mem.eql(u8, t.text, o[0])) return o[1];
        return null;
    }

    fn predicate(s: *Parser) Error!*Expr {
        var l = try s.additive();
        while (true) {
            if (compareOp(s.tok)) |op| {
                s.advance();
                if (s.isAnyKw(&.{ "ANY", "SOME", "ALL" })) {
                    return s.fail("xqlite: comparisons with ANY/SOME/ALL subqueries are not supported", .{});
                }
                const r = try s.additive();
                l = try s.mk(l.pos, .{ .compare = .{ .op = op, .l = l, .r = r } });
                continue;
            }
            if (s.isKw("IS")) {
                s.advance();
                const not = s.eatKw("NOT");
                try s.expectKw("NULL");
                l = try s.mk(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                continue;
            }
            var not = false;
            if (s.isKw("NOT")) {
                const n = s.peek();
                if (!n.isAnyKw(&.{ "LIKE", "IN", "BETWEEN" })) break;
                s.advance();
                not = true;
            }
            if (s.eatKw("LIKE")) {
                const r = try s.additive();
                const esc: ?*Expr = if (s.eatKw("ESCAPE")) try s.additive() else null;
                l = try s.like(l, r, esc, not);
                continue;
            }
            if (s.eatKw("IN")) {
                try s.expectOp("(");
                if (s.isSelectStart()) {
                    const sub = try s.subSelect();
                    try s.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = sub } });
                } else {
                    const items = try s.exprList();
                    try s.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_list = .{ .e = l, .not = not, .items = items } });
                }
                continue;
            }
            if (s.eatKw("BETWEEN")) {
                const lo = try s.additive();
                try s.expectKw("AND");
                const hi = try s.additive();
                l = try s.mk(l.pos, .{ .between = .{ .e = l, .not = not, .lo = lo, .hi = hi } });
                continue;
            }
            if (not) return s.syntaxError();
            break;
        }
        return l;
    }

    /// `e [NOT] LIKE pat [ESCAPE esc]`: SQLite's LIKE (case-insensitive,
    /// no escape character unless ESCAPE says) for a constant pattern
    /// without [...] classes, else xq_tsql_like().
    fn like(s: *Parser, e: *Expr, pat: *Expr, esc: ?*Expr, not: bool) Error!*Expr {
        const plain = pat.kind == .string and std.mem.indexOfScalar(u8, pat.kind.string, '[') == null;
        if (plain) {
            const escape: tree.Escape = if (esc) |x| .{ .expr = x } else .none;
            return s.mk(e.pos, .{ .like = .{ .e = e, .pat = pat, .not = not, .case_sensitive = false, .escape = escape } });
        }
        var args: std.ArrayList(*Expr) = .empty;
        try args.appendSlice(s.a, &.{ e, pat });
        if (esc) |x| try args.append(s.a, x);
        const call = try s.func(e.pos, "xq_tsql_like", args.items);
        if (!not) return call;
        return s.mk(e.pos, .{ .unary = .{ .op = .not, .e = call } });
    }

    fn additive(s: *Parser) Error!*Expr {
        var l = try s.multiplicative();
        while (true) {
            if (s.eatOp("+")) {
                l = try s.plus(l, try s.multiplicative());
            } else if (s.eatOp("-")) {
                l = try s.bin(.sub, l, try s.multiplicative());
            } else if (s.eatOp("&")) {
                l = try s.bin(.bit_and, l, try s.multiplicative());
            } else if (s.eatOp("|")) {
                l = try s.bin(.bit_or, l, try s.multiplicative());
            } else if (s.eatOp("^")) {
                l = try s.xor(l, try s.multiplicative());
            } else break;
        }
        return l;
    }

    /// a ^ b: (a | b) & ~(a & b).
    pub fn xor(s: *Parser, l: *Expr, r: *Expr) Error!*Expr {
        const both = try s.bin(.bit_and, l, r);
        const either = try s.bin(.bit_or, l, r);
        const not_both = try tree.expr(s.a, l.pos, r.end, .{ .unary = .{ .op = .bit_not, .e = both } });
        return s.bin(.bit_and, either, not_both);
    }

    /// `l + r`: concatenation or addition, as the operands' types say
    /// (see the file's comment).
    pub fn plus(s: *Parser, l: *Expr, r: *Expr) Error!*Expr {
        const cl = s.classOf(l);
        const cr = s.classOf(r);
        if (cl == .string and cr == .string) return s.concatOf(l, r);
        if (cl == .number or cr == .number) return s.bin(.add, l, r);
        // A string constant that is no number cannot be added: SQL
        // Server could only fail.
        if ((cl == .string and nonNumericString(l)) or (cr == .string and nonNumericString(r))) return s.concatOf(l, r);
        const x = try s.func(l.pos, "xq_tsql_add", &.{ l, r });
        x.end = r.end;
        s.n_plus += 1;
        return x;
    }

    fn nonNumericString(e: *const Expr) bool {
        if (e.kind != .string) return false;
        const z = std.mem.trim(u8, e.kind.string, " \t\r\n");
        _ = std.fmt.parseFloat(f64, z) catch return true;
        return false;
    }

    fn concatOf(s: *Parser, l: *Expr, r: *Expr) Error!*Expr {
        var args: std.ArrayList(*Expr) = .empty;
        for ([_]*Expr{ l, r }) |x| {
            if (x.kind == .concat and x.kind.concat.null_policy == .propagate) {
                try args.appendSlice(s.a, x.kind.concat.args);
            } else try args.append(s.a, x);
        }
        return tree.expr(s.a, l.pos, r.end, .{ .concat = .{ .args = args.items, .null_policy = .propagate } });
    }

    /// The type class the parser knows of `e`.
    pub fn classOf(s: *Parser, e: *const Expr) Class {
        if (s.classes.get(e)) |c| return c;
        return switch (e.kind) {
            .string => .string,
            .integer, .float => .number,
            .concat => .string,
            .binary => |b| switch (b.op) {
                .add, .sub, .mul, .rem, .bit_and, .bit_or, .shl, .shr => .number,
                else => .unknown,
            },
            .div => .number,
            .unary => |u| if (u.op == .not) .unknown else .number,
            .cast => |c| castClass(c),
            .func => |f| funcClass(f),
            .collate => |c| s.classOf(c.e),
            .case => |c| blk: {
                var cls: ?Class = null;
                var i: usize = 1;
                while (i < c.whens.len) : (i += 2) {
                    const k = s.classOf(c.whens[i]);
                    if (cls != null and cls.? != k) break :blk .unknown;
                    cls = k;
                }
                if (c.@"else") |x| {
                    const k = s.classOf(x);
                    if (cls != null and cls.? != k) break :blk .unknown;
                    cls = k;
                }
                break :blk cls orelse .unknown;
            },
            else => .unknown,
        };
    }

    fn castClass(c: tree.Cast) Class {
        return switch (c.mode) {
            .truncate => .string,
            .affinity => |t| if (std.mem.eql(u8, t, "TEXT")) .string else if (std.mem.eql(u8, t, "BLOB")) .unknown else .number,
            .func => .string,
            .typed => |t| typeClass(types.parseText(t.type_arg)),
            .round => .number,
        };
    }

    pub fn typeClass(t: ?types.Type) Class {
        const ty = t orelse return .unknown;
        if (ty.isNumber()) return .number;
        if (ty.isChar() or ty.isTemporal() or ty.base == .uniqueidentifier) return .string;
        return .unknown;
    }

    fn funcClass(f: *const tree.Func) Class {
        const strings = [_][]const u8{
            "upper",               "lower",              "substr",    "ltrim",    "rtrim",              "trim",               "replace",             "left",
            "right",               "concat",             "concat_ws", "char",     "reverse",            "repeat",             "space",               "insert",
            "group_concat",        "quote",              "datename",  "strftime", "date",               "time",               "datetime",            "xq_tsql_newid",
            "quotename",           "format",             "hex",       "upper",    "xq_tsql_json_value", "xq_tsql_json_query", "xq_tsql_json_modify", "xq_tsql_json_escape",
            "xq_tsql_json_object", "xq_tsql_json_array",
        };
        const numbers = [_][]const u8{
            "length",                   "octet_length", "instr",       "charindex", "abs",            "count",         "round",             "floor",
            "ceil",                     "ceiling",      "datediff",    "datepart",  "unicode",        "ascii",         "sign",              "power",
            "sum",                      "avg",          "xq_tsql_avg", "min",       "max",            "total",         "changes",           "row_number",
            "rank",                     "dense_rank",   "ntile",       "isnumeric", "isdate",         "sqrt",          "exp",               "log",
            "log10",                    "pi",           "random",      "rand",      "scope_identity", "ident_current", "last_insert_rowid", "xq_tsql_isjson",
            "xq_tsql_json_path_exists",
        };
        for (strings) |n| if (std.ascii.eqlIgnoreCase(f.name.text, n)) return .string;
        for (numbers) |n| if (std.ascii.eqlIgnoreCase(f.name.text, n)) return .number;
        return .unknown;
    }

    fn multiplicative(s: *Parser) Error!*Expr {
        var l = try s.unary();
        while (true) {
            if (s.eatOp("*")) {
                l = try s.bin(.mul, l, try s.unary());
            } else if (s.eatOp("/")) {
                const r = try s.unary();
                l = try s.mk(l.pos, .{ .div = .{ .kind = .sqlite, .l = l, .r = r } });
            } else if (s.eatOp("%")) {
                l = try s.bin(.rem, l, try s.unary());
            } else break;
        }
        return l;
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
        return s.primaryWithCollate();
    }

    fn primaryWithCollate(s: *Parser) Error!*Expr {
        var e = try s.primary();
        while (s.eatKw("COLLATE")) {
            const coll = try s.collationName();
            e = try s.mk(e.pos, .{ .collate = .{ .e = e, .collation = coll } });
        }
        return e;
    }

    /// The SQLite collation of the SQL Server collation at the current
    /// token: case-sensitive (_CS_) and binary (_BIN, _BIN2) ones are
    /// BINARY, the others (_CI_) NOCASE.
    pub fn collationName(s: *Parser) Error![:0]const u8 {
        const t = s.tok;
        if (t.kind != .ident and t.kind != .quoted_ident) return s.syntaxError();
        const n = try s.nameText(t);
        s.advance();
        return mapCollation(n) orelse s.fail("Invalid collation '{s}'.", .{n});
    }

    pub fn str(s: *Parser, pos: u32, z: []const u8) Error!*Expr {
        return tree.expr(s.a, pos, pos, .{ .string = z });
    }

    pub fn int_(s: *Parser, pos: u32, v: i64) Error!*Expr {
        if (v < 0) {
            const x = try tree.expr(s.a, pos, pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{-%v}) });
            return tree.expr(s.a, pos, pos, .{ .unary = .{ .op = .neg, .e = x } });
        }
        return tree.expr(s.a, pos, pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{v}) });
    }

    /// A call of `fname`: of the dialect's table if it has one of that
    /// name, else a SQLite built-in or an engine function.
    pub fn func(s: *Parser, pos: u32, fname: []const u8, args: []const *Expr) Error!*Expr {
        return s.funcNode(pos, .{ .name = .{ .text = fname, .pos = pos }, .args = try s.a.dupe(*Expr, args) });
    }

    pub fn funcNode(s: *Parser, pos: u32, f: tree.Func) Error!*Expr {
        var x = f;
        x.dialect = if (isDialectFunction(f.name.text)) .mssql else null;
        return s.mk(pos, .{ .func = try s.new(tree.Func, x) });
    }

    pub fn isSelectStart(s: *Parser) bool {
        return s.isKw("SELECT") or s.isKw("WITH") or (s.isOp("(") and isSelectish(s.peek()));
    }

    fn isSelectish(t: Token) bool {
        return t.isKw("SELECT") or t.isKw("WITH") or t.is("(");
    }

    fn refuseStored(s: *Parser, what: []const u8) Error!void {
        if (!s.stored) return;
        return s.fail("Variables are not allowed in this context: '{s}'.", .{what});
    }

    fn primary(s: *Parser) Error!*Expr {
        const t = s.tok;
        const pos = s.posOf(t);
        switch (t.kind) {
            .string => return s.mk(pos, .{ .string = try s.stringLiteral() }),
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
                return s.mk(pos, .{ .blob = try lexer.hexDigits(s.a, t) });
            },
            .param => {
                try s.refuseStored(t.text);
                s.advance();
                return s.mk(pos, .{ .param = null });
            },
            .variable => {
                try s.refuseStored(t.text);
                s.advance();
                return s.variableRef(t, pos);
            },
            .sys_var => {
                try s.refuseStored(t.text);
                s.advance();
                return @import("functions.zig").systemFunction(s, t, pos);
            },
            .op => {
                if (t.is("(")) return s.parenthesized();
                return s.syntaxError();
            },
            .quoted_ident => return s.columnRef(),
            .ident => return s.wordExpr(),
            else => return s.syntaxError(),
        }
    }

    /// @name: the variable's value (it must be declared).
    pub fn variableRef(s: *Parser, t: Token, pos: u32) Error!*Expr {
        const vname = try varName(s.a, t.text);
        const v = s.p.db.xq.mssql.get(vname) orelse return s.fail("Must declare the scalar variable \"{s}\".", .{t.text});
        const x = try s.func(pos, "xq_tsql_getvar", &.{try s.str(pos, vname)});
        try s.classes.put(s.a, x, typeClass(types.parseText(v.type)));
        return x;
    }

    fn parenthesized(s: *Parser) Error!*Expr {
        const pos = s.here();
        try s.expectOp("(");
        if (s.isAnyKw(&.{ "SELECT", "WITH" })) {
            const sub = try s.subSelect();
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

    /// [[db.]schema.]table.column, table.column or column.
    pub fn columnRef(s: *Parser) Error!*Expr {
        const pos = s.here();
        var names: std.ArrayList(Name) = .empty;
        try names.append(s.a, try s.nameOf(try s.anyName()));
        while (names.items.len < 4 and s.isOp(".") and !s.peek().is("*")) {
            s.advance();
            try names.append(s.a, try s.nameOf(try s.anyName()));
        }
        var ns = names.items;
        if (s.output) |o| if (ns.len == 2) {
            const ins = std.ascii.eqlIgnoreCase(ns[0].text, "inserted");
            const del = std.ascii.eqlIgnoreCase(ns[0].text, "deleted");
            if (ins or del) {
                if ((ins and o == .delete) or (del and o == .insert)) {
                    return s.fail("The multi-part identifier \"{s}.{s}\" could not be bound.", .{ ns[0].text, ns[1].text });
                }
                if (del and o == .update) return s.fail("xqlite: OUTPUT DELETED in UPDATE is not supported (RETURNING sees the new row)", .{});
                return s.mk(pos, .{ .column = ns[1..] });
            }
        };
        if (ns.len == 4) {
            // db.schema.table.column: a schema of CREATE SCHEMA is main's.
            if (!std.ascii.eqlIgnoreCase(ns[1].text, "dbo") and ns[1].text.len > 0 and try s.findSchema(ns[1].text) != null) {
                if (try s.sqliteDb(ns[0].text, ns[0].pos)) |d| if (std.mem.eql(u8, d.text, "main")) return s.mk(pos, .{ .column = ns[2..] });
            }
            ns = ns[1..];
        }
        if (ns.len == 3) {
            // schema.table.column: a table of a schema of CREATE SCHEMA is
            // aliased to its name (autoAlias()).
            if (try s.sqliteDb(ns[0].text, ns[0].pos)) |d| {
                ns[0] = d;
            } else if (try s.findSchema(ns[0].text) != null) {
                ns = ns[1..];
            }
        }
        return s.mk(pos, .{ .column = ns });
    }

    /// An expression starting with a word: a keyword form, a function
    /// call or a column reference.
    fn wordExpr(s: *Parser) Error!*Expr {
        const t = s.tok;
        const pos = s.posOf(t);
        const next = s.peek();
        if (t.isKw("NULL")) {
            s.advance();
            return s.mk(pos, .null);
        }
        if (t.isKw("CASE")) return s.caseExpr();
        if (t.isKw("EXISTS")) {
            s.advance();
            try s.expectOp("(");
            const sub = try s.subSelect();
            try s.expectOp(")");
            return s.mk(pos, .{ .exists = sub });
        }
        if (t.isKw("DEFAULT") and s.allow_default) {
            s.advance();
            return s.mk(pos, .default);
        }
        if (t.isKw("NEXT") and next.isKw("VALUE")) {
            s.advance();
            s.advance();
            try s.expectKw("FOR");
            const q = try s.qualifiedName();
            return s.func(pos, "xq_tsql_next_value", &.{try s.str(q.name.pos, q.name.text)});
        }
        if (next.is("(") and t.kind == .ident) return @import("functions.zig").call(s);
        const niladic = [_][]const u8{ "CURRENT_TIMESTAMP", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER", "CURRENT_DATE" };
        for (niladic) |n| if (t.isKw(n)) {
            s.advance();
            return @import("functions.zig").byName(s, n, &.{}, pos);
        };
        if (isReserved(t)) return s.syntaxError();
        // schema.function(...)
        if (next.is(".") and s.peek2().kind == .ident) {
            var copy = s.lx;
            _ = copy.next();
            _ = copy.next();
            if (copy.next().is("(")) {
                s.advance();
                s.advance();
                return @import("functions.zig").call(s);
            }
        }
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

    /// A query inside another statement (a subquery, a CTE, INSERT ...
    /// SELECT): no variable assignments, no INTO.
    pub fn subSelect(s: *Parser) Error!*tree.Select {
        s.depth += 1;
        defer s.depth -= 1;
        const saved_assigns = s.assigns;
        const saved_into = s.into;
        defer {
            s.assigns = saved_assigns;
            s.into = saved_into;
        }
        s.assigns = null;
        s.into = null;
        const sel = try s.selectInner();
        if (s.assigns != null) return s.fail("xqlite: a SELECT that assigns variables cannot be a subquery", .{});
        if (s.into != null) return s.syntaxError();
        return sel;
    }

    /// The query of a SELECT statement (variable assignments and INTO
    /// are left in s.assigns and s.into).
    pub fn selectStmt(s: *Parser) Error!*tree.Select {
        s.depth += 1;
        defer s.depth -= 1;
        return s.selectInner();
    }

    fn selectInner(s: *Parser) Error!*tree.Select {
        const pos = s.here();
        var w: ?*tree.With = null;
        if (s.isKw("WITH")) w = try s.withClause();
        const body = try s.selectBody();
        const sel = try s.new(tree.Select, .{ .with = w, .body = body, .pos = pos });
        // TOP of a lone SELECT: after its ORDER BY.
        var top: ?Top = null;
        if (body.* == .core) top = s.tops.get(body.core);
        if (s.isKw("ORDER") and s.peek().isKw("BY")) {
            s.advance();
            s.advance();
            sel.order_by = try s.sortList();
        }
        if (s.eatKw("OFFSET")) {
            if (top != null) return s.fail("A TOP can not be used in the same query or sub-query as a OFFSET.", .{});
            if (sel.order_by.len == 0) return s.syntaxError();
            sel.offset = try s.expr();
            if (!(s.eatKw("ROWS") or s.eatKw("ROW"))) return s.syntaxError();
            if (s.eatKw("FETCH")) {
                if (!(s.eatKw("FIRST") or s.eatKw("NEXT"))) return s.syntaxError();
                sel.limit = try s.expr();
                if (!(s.eatKw("ROWS") or s.eatKw("ROW"))) return s.syntaxError();
                try s.expectKw("ONLY");
            }
        }
        if (top) |tp| try s.applyTop(sel, tp);
        if (s.isKw("OPTION") and s.peek().is("(")) {
            // Query hints: ignored.
            s.advance();
            try s.skipParens();
        }
        if (s.isKw("FOR") and s.peek().isKw("JSON")) return json_sql.forJson(s, sel);
        if (s.isKw("FOR") and s.peek().isAnyKw(&.{ "XML", "BROWSE" })) return s.fail("xqlite: FOR {s} is not supported", .{s.peek().text});
        return sel;
    }

    /// Skip a parenthesized group at the current token.
    pub fn skipParens(s: *Parser) Error!void {
        try s.expectOp("(");
        var depth: usize = 1;
        while (depth > 0) {
            if (s.tok.kind == .eof) return s.syntaxError();
            if (s.isOp("(")) depth += 1;
            if (s.isOp(")")) depth -= 1;
            s.advance();
        }
    }

    /// Make TOP n [PERCENT] the LIMIT of `sel`: PERCENT is the ceiling of
    /// n percent of the query's rows (counted by the same query in a
    /// subquery).
    fn applyTop(s: *Parser, sel: *tree.Select, top: Top) Error!void {
        if (!top.percent) {
            sel.limit = top.n;
            return;
        }
        const pos = top.n.pos;
        // (SELECT count(*) FROM (SELECT ... without ORDER BY/LIMIT))
        const inner = try s.new(tree.Select, .{ .with = sel.with, .body = sel.body, .pos = pos });
        const from = try s.a.dupe(tree.FromItem, &.{.{ .source = .{ .subquery = inner } }});
        const cnt = try s.funcNode(pos, .{ .name = .{ .text = "count", .pos = pos }, .star = true });
        const core = try s.new(tree.Core, .{ .cols = try s.a.dupe(tree.ResultCol, &.{.{ .expr = .{ .e = cnt } }}), .from = from, .pos = pos });
        const count = try s.mk(pos, .{ .subquery = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .core = core }), .pos = pos }) });
        // v = count * n / 100.0; ceil(v) = CAST(v AS INTEGER) + (v > CAST(v AS INTEGER))
        const v = try s.mk(pos, .{ .div = .{ .kind = .sqlite, .l = try s.bin(.mul, count, top.n), .r = try tree.expr(s.a, pos, pos, .{ .float = "100.0" }) } });
        const trunc = try s.mk(pos, .{ .cast = .{ .e = v, .target_type = "int", .mode = .{ .affinity = "INTEGER" } } });
        const frac = try s.mk(pos, .{ .compare = .{ .op = .gt, .l = v, .r = trunc } });
        sel.limit = try s.bin(.add, trunc, frac);
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

    /// WITH name [(cols)] AS (query), ...: SQL Server's CTEs are recursive
    /// when they name themselves, without a RECURSIVE keyword.
    pub fn withClause(s: *Parser) Error!*tree.With {
        try s.expectKw("WITH");
        var ctes: std.ArrayList(tree.Cte) = .empty;
        while (true) {
            const n = try s.nameOf(try s.name());
            try s.cte_names.append(s.a, n.text);
            var cols: []Name = &.{};
            if (s.isOp("(")) cols = try s.nameList();
            try s.expectKw("AS");
            try s.expectOp("(");
            const q = try s.subSelect();
            try s.expectOp(")");
            try ctes.append(s.a, .{ .name = n, .cols = cols, .select = q });
            if (!s.eatOp(",")) break;
        }
        return s.new(tree.With, .{ .recursive = true, .ctes = ctes.items });
    }

    /// Terms joined by UNION/EXCEPT, which bind less than INTERSECT.
    fn selectBody(s: *Parser) Error!*tree.Body {
        var lhs = try s.intersectTerm();
        while (true) {
            var op: tree.SetOp = undefined;
            var all = false;
            if (s.eatKw("UNION")) {
                op = .@"union";
                all = s.eatKw("ALL");
            } else if (s.eatKw("EXCEPT")) {
                op = .except;
            } else break;
            const rhs = try s.intersectTerm();
            lhs = try s.compound(op, all, lhs, rhs);
        }
        return lhs;
    }

    fn intersectTerm(s: *Parser) Error!*tree.Body {
        var lhs = try s.selectTerm();
        while (s.eatKw("INTERSECT")) {
            const rhs = try s.selectTerm();
            lhs = try s.compound(.intersect, false, lhs, rhs);
        }
        return lhs;
    }

    /// A compound; an operand with TOP is a query of its own.
    fn compound(s: *Parser, op: tree.SetOp, all: bool, l: *tree.Body, r: *tree.Body) Error!*tree.Body {
        return s.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = try s.topOperand(l), .right = try s.topOperand(r) } });
    }

    fn topOperand(s: *Parser, b: *tree.Body) Error!*tree.Body {
        if (b.* != .core) return b;
        const top = s.tops.get(b.core) orelse return b;
        const sel = try s.new(tree.Select, .{ .body = b, .pos = b.core.pos });
        try s.applyTop(sel, top);
        return s.new(tree.Body, .{ .nested = sel });
    }

    fn selectTerm(s: *Parser) Error!*tree.Body {
        if (s.eatOp("(")) {
            const inner = try s.subSelect();
            try s.expectOp(")");
            return s.new(tree.Body, .{ .nested = inner });
        }
        return s.new(tree.Body, .{ .core = try s.selectCore() });
    }

    /// `VALUES (row), (row) ...`.
    pub fn valuesRows(s: *Parser) Error![][]*Expr {
        try s.expectKw("VALUES");
        var rows: std.ArrayList([]*Expr) = .empty;
        while (true) {
            try s.expectOp("(");
            const row = try s.exprList();
            try s.expectOp(")");
            try rows.append(s.a, row);
            if (!s.eatOp(",")) break;
        }
        return rows.items;
    }

    fn selectCore(s: *Parser) Error!*tree.Core {
        const pos = s.here();
        const json_mark = s.json_fixes.items.len;
        try s.expectKw("SELECT");
        var distinct = false;
        if (s.eatKw("DISTINCT")) {
            distinct = true;
        } else _ = s.eatKw("ALL");
        var top: ?Top = null;
        if (s.eatKw("TOP")) {
            const n = if (s.eatOp("(")) blk: {
                const x = try s.expr();
                try s.expectOp(")");
                break :blk x;
            } else try s.primary();
            top = .{ .n = n, .percent = s.eatKw("PERCENT") };
            if (s.isKw("WITH") and s.peek().isKw("TIES")) return s.fail("xqlite: TOP ... WITH TIES is not supported", .{});
        }
        const cols = try s.resultColumns();
        if (s.eatKw("INTO")) {
            if (s.depth != 1 or s.into != null) return s.syntaxError();
            s.into = try s.qualifiedNameFor(.create);
        }
        var from: []tree.FromItem = &.{};
        if (s.eatKw("FROM")) from = try s.tableRefs();
        const where: ?*Expr = if (s.eatKw("WHERE")) try s.expr() else null;
        var group: std.ArrayList(*Expr) = .empty;
        if (s.isKw("GROUP")) {
            s.advance();
            try s.expectKw("BY");
            if (s.isAnyKw(&.{ "ROLLUP", "CUBE", "GROUPING" })) return s.fail("xqlite: GROUP BY {s} is not supported", .{s.tok.text});
            while (true) {
                try group.append(s.a, try s.expr());
                if (!s.eatOp(",")) break;
            }
            if (s.isKw("WITH") and s.peek().isAnyKw(&.{ "ROLLUP", "CUBE" })) return s.fail("xqlite: GROUP BY ... WITH {s} is not supported", .{s.peek().text});
        }
        const having: ?*Expr = if (s.eatKw("HAVING")) try s.expr() else null;
        const core = try s.new(tree.Core, .{
            .distinct = distinct,
            .cols = cols,
            .from = from,
            .where = where,
            .group_by = group.items,
            .having = having,
            .pos = pos,
        });
        if (top) |tp| try s.tops.put(s.a, core, tp);
        try json_sql.resolveKinds(s, json_mark, core.from);
        if (s.n_plus > 0) {
            const scope = try s.fromScope(core.from);
            for (core.cols) |rc| if (rc == .expr) s.resolvePlus(rc.expr.e, scope);
            for (core.from) |it| if (it.on) |on| s.resolvePlus(on, scope);
            if (core.where) |w| s.resolvePlus(w, scope);
            for (core.group_by) |g| s.resolvePlus(g, scope);
            if (core.having) |h| s.resolvePlus(h, scope);
        }
        return core;
    }

    // ------------------------------------------------------ `+` by types

    /// The columns of a table in scope and their type classes.
    pub const ScopeTable = struct { label: []const u8, cols: []const ColClass };
    pub const ColClass = struct { name: []const u8, class: Class };

    /// The tables of a FROM clause (those that exist; not subqueries).
    pub fn fromScope(s: *Parser, items: []const tree.FromItem) Error![]ScopeTable {
        var out: std.ArrayList(ScopeTable) = .empty;
        for (items) |it| switch (it.source) {
            .table => |q| {
                const label = if (it.alias) |a| a.name.text else q.name.text;
                if (try s.tableClasses(q)) |cols| try out.append(s.a, .{ .label = label, .cols = cols });
            },
            .nested => |inner| try out.appendSlice(s.a, try s.fromScope(inner)),
            else => {},
        };
        return out.items;
    }

    /// The classes of the columns of table `q`, by their affinity (a
    /// T-SQL table's storage types are its declared types'), null if it
    /// does not exist.
    pub fn tableClasses(s: *Parser, q: QName) Error!?[]ColClass {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse return null;
        const cols = try s.a.alloc(ColClass, tab.cols.len);
        for (tab.cols, 0..) |*c, i| {
            cols[i] = .{ .name = try s.a.dupe(u8, c.name()), .class = switch (c.affinity) {
                int.Aff.text => .string,
                int.Aff.integer, int.Aff.real, int.Aff.numeric => .number,
                else => .unknown,
            } };
        }
        return cols;
    }

    /// The class of `e` with the columns of `scope` known.
    fn scopedClass(s: *Parser, e: *const Expr, scope: []const ScopeTable) Class {
        if (e.kind != .column) return s.classOf(e);
        const names = e.kind.column;
        const col = names[names.len - 1].text;
        const label: ?[]const u8 = if (names.len >= 2) names[names.len - 2].text else null;
        var found: ?Class = null;
        for (scope) |t| {
            if (label) |l| if (!std.ascii.eqlIgnoreCase(l, t.label)) continue;
            for (t.cols) |c| if (std.ascii.eqlIgnoreCase(c.name, col)) {
                if (found != null) return .unknown;
                found = c.class;
            };
        }
        return found orelse .unknown;
    }

    /// Make the xq_tsql_add() calls in `e` whose operands' classes the
    /// scope tells concatenations or additions (innermost first).
    pub fn resolvePlus(s: *Parser, e: *Expr, scope: []const ScopeTable) void {
        switch (e.kind) {
            .unary => |u| s.resolvePlus(u.e, scope),
            .binary => |b| {
                s.resolvePlus(b.l, scope);
                s.resolvePlus(b.r, scope);
            },
            .div => |d| {
                s.resolvePlus(d.l, scope);
                s.resolvePlus(d.r, scope);
            },
            .compare => |c| {
                s.resolvePlus(c.l, scope);
                s.resolvePlus(c.r, scope);
            },
            .concat => |c| for (c.args) |x| s.resolvePlus(x, scope),
            .cast => |c| s.resolvePlus(c.e, scope),
            .collate => |c| s.resolvePlus(c.e, scope),
            .case => |c| {
                if (c.operand) |o| s.resolvePlus(o, scope);
                for (c.whens) |x| s.resolvePlus(x, scope);
                if (c.@"else") |x| s.resolvePlus(x, scope);
            },
            .in_list => |x| {
                s.resolvePlus(x.e, scope);
                for (x.items) |y| s.resolvePlus(y, scope);
            },
            .in_select => |x| s.resolvePlus(x.e, scope),
            .between => |x| {
                s.resolvePlus(x.e, scope);
                s.resolvePlus(x.lo, scope);
                s.resolvePlus(x.hi, scope);
            },
            .like => |x| {
                s.resolvePlus(x.e, scope);
                s.resolvePlus(x.pat, scope);
            },
            .is_null => |x| s.resolvePlus(x.e, scope),
            .is_bool => |x| s.resolvePlus(x.e, scope),
            .row => |items| for (items) |x| s.resolvePlus(x, scope),
            .func => |f| {
                for (f.args) |x| s.resolvePlus(x, scope);
                if (!std.mem.eql(u8, f.name.text, "xq_tsql_add") or f.args.len != 2) return;
                const l = f.args[0];
                const r = f.args[1];
                const cl = s.scopedClass(l, scope);
                const cr = s.scopedClass(r, scope);
                if (cl == .string and cr == .string) {
                    var args: std.ArrayList(*Expr) = .empty;
                    for ([_]*Expr{ l, r }) |x| {
                        if (x.kind == .concat and x.kind.concat.null_policy == .propagate) {
                            args.appendSlice(s.a, x.kind.concat.args) catch return;
                        } else args.append(s.a, x) catch return;
                    }
                    e.kind = .{ .concat = .{ .args = args.items, .null_policy = .propagate } };
                } else if (cl == .number or cr == .number) {
                    e.kind = .{ .binary = .{ .op = .add, .l = l, .r = r } };
                }
            },
            else => {},
        }
    }

    /// Whether the tokens are `name . name . *`.
    fn qualifiedStar(s: *Parser) bool {
        var copy = s.lx;
        _ = copy.next(); // .
        const t = copy.next();
        if (t.kind != .ident and t.kind != .quoted_ident) return false;
        if (!copy.next().is(".")) return false;
        return copy.next().is("*");
    }

    fn resultColumns(s: *Parser) Error![]tree.ResultCol {
        var l: std.ArrayList(tree.ResultCol) = .empty;
        var assigns: std.ArrayList(Assign) = .empty;
        while (true) {
            if (s.isOp("*")) {
                try l.append(s.a, .{ .star = s.here() });
                s.advance();
            } else if ((s.tok.kind == .ident or s.tok.kind == .quoted_ident) and s.peek().is(".") and s.peek2().kind != .op and s.qualifiedStar()) {
                // schema.table.*: the table (aliased to its name).
                s.advance();
                s.advance();
                const tbl = try s.nameOf(s.tok);
                s.advance();
                s.advance();
                const star = s.here();
                s.advance();
                try l.append(s.a, .{ .table_star = .{ .names = try s.a.dupe(Name, &.{tbl}), .star_pos = star } });
            } else if ((s.tok.kind == .ident or s.tok.kind == .quoted_ident) and s.peek().is(".") and s.peek2().is("*")) {
                const tbl = try s.nameOf(s.tok);
                s.advance();
                s.advance();
                const star = s.here();
                s.advance();
                try l.append(s.a, .{ .table_star = .{ .names = try s.a.dupe(Name, &.{tbl}), .star_pos = star } });
            } else if (s.tok.kind == .variable and isAssignOp(s.peek())) {
                // @x = expr, @x += expr
                const vt = s.tok;
                const vpos = s.here();
                s.advance();
                const op = s.tok.text;
                s.advance();
                var e = try s.expr();
                if (op.len == 2) e = try s.compoundAssign(op[0], try s.variableRef(vt, vpos), e);
                try assigns.append(s.a, .{ .name = try varName(s.a, vt.text), .value = e });
                try l.append(s.a, .{ .expr = .{ .e = e } });
            } else if ((s.tok.kind == .ident or s.tok.kind == .quoted_ident or s.tok.kind == .string) and !isReserved(s.tok) and s.peek().is("=")) {
                // alias = expr
                const al: Name = if (s.tok.kind == .string) .{ .text = try lexer.stringValue(s.a, s.tok), .pos = s.here() } else try s.nameOf(s.tok);
                s.advance();
                s.advance();
                const e = try s.expr();
                try l.append(s.a, .{ .expr = .{ .e = e, .alias = al } });
            } else {
                const e = try s.expr();
                const al = try s.alias(true);
                // SQL Server names a column by its name, anything else not
                // at all.
                const nm: ?[]const u8 = if (al != null or e.kind == .column or s.depth != 1) null else "";
                try l.append(s.a, .{ .expr = .{ .e = e, .alias = al, .name = nm } });
            }
            if (!s.eatOp(",")) break;
        }
        if (assigns.items.len > 0) {
            if (assigns.items.len != l.items.len or s.depth != 1) {
                return s.fail("A SELECT statement that assigns a value to a variable must not be combined with data-retrieval operations.", .{});
            }
            s.assigns = assigns.items;
        }
        return l.items;
    }

    /// `x op= e`: x op e.
    pub fn compoundAssign(s: *Parser, op: u8, x: *Expr, e: *Expr) Error!*Expr {
        return switch (op) {
            '+' => s.plus(x, e),
            '-' => s.bin(.sub, x, e),
            '*' => s.bin(.mul, x, e),
            '/' => s.mk(x.pos, .{ .div = .{ .kind = .sqlite, .l = x, .r = e } }),
            '%' => s.bin(.rem, x, e),
            '&' => s.bin(.bit_and, x, e),
            '|' => s.bin(.bit_or, x, e),
            '^' => s.xor(x, e),
            else => s.syntaxError(),
        };
    }

    /// `[AS] name` (or a string, for a column alias).
    fn alias(s: *Parser, string_ok: bool) Error!?Name {
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

    fn stringAlias(s: *Parser) Error!Name {
        const pos = s.here();
        return .{ .text = try s.stringLiteral(), .pos = pos };
    }

    // ----------------------------------------------------------- windows

    /// The inside of OVER ( ... ).
    fn windowSpec(s: *Parser) Error!*tree.WindowSpec {
        var w: tree.WindowSpec = .{};
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

    /// `OVER (spec)` after a function call.
    pub fn overClause(s: *Parser) Error!?*tree.WindowSpec {
        if (!s.eatKw("OVER")) return null;
        try s.expectOp("(");
        const w = try s.windowSpec();
        try s.expectOp(")");
        return w;
    }

    // -------------------------------------------------------------- FROM

    /// Table sources joined by commas and JOINs.
    pub fn tableRefs(s: *Parser) Error![]tree.FromItem {
        var list: std.ArrayList(tree.FromItem) = .empty;
        try list.append(s.a, try s.tableSource());
        while (true) {
            if ((s.isKw("CROSS") or s.isKw("OUTER")) and s.peek().isKw("APPLY")) {
                // CROSS/OUTER APPLY of a table-valued function (OPENJSON):
                // a join, whose arguments may name the tables before it.
                const outer = s.isKw("OUTER");
                s.advance();
                s.advance();
                var item = try s.tableSource();
                if (item.source != .func) return s.fail("xqlite: {s} APPLY is supported only with OPENJSON and table-valued functions", .{if (outer) "OUTER" else "CROSS"});
                item.join = if (outer) .left else .inner;
                try list.append(s.a, item);
                continue;
            }
            const j = (try s.joinOp()) orelse break;
            var item = try s.tableSource();
            item.join = j;
            if (j != .comma and j != .cross) {
                try s.expectKw("ON");
                item.on = try s.expr();
            }
            try list.append(s.a, item);
        }
        return list.items;
    }

    fn joinOp(s: *Parser) Error!?tree.JoinKind {
        if (s.eatOp(",")) return .comma;
        if (s.eatKw("CROSS")) {
            try s.expectKw("JOIN");
            return .cross;
        }
        var j: tree.JoinKind = .inner;
        if (s.eatKw("INNER")) {} else if (s.eatKw("LEFT")) {
            j = .left;
            _ = s.eatKw("OUTER");
        } else if (s.eatKw("RIGHT")) {
            j = .right;
            _ = s.eatKw("OUTER");
        } else if (s.eatKw("FULL")) {
            j = .full;
            _ = s.eatKw("OUTER");
        } else if (!s.isKw("JOIN")) return null;
        // Join hints.
        _ = s.eatKw("LOOP") or s.eatKw("HASH") or s.eatKw("MERGE") or s.eatKw("REMOTE");
        try s.expectKw("JOIN");
        return j;
    }

    /// `[AS] alias`, with a column list `(a, b)` if `cols` (a derived
    /// table).
    fn aliasOf(s: *Parser, cols: bool) Error!?tree.Alias {
        const n = (try s.alias(false)) orelse return null;
        var al: tree.Alias = .{ .name = n };
        if (cols and s.isOp("(")) al.cols = try s.nameList();
        return al;
    }

    fn isHint(t: Token) bool {
        return t.isAnyKw(&.{ "NOLOCK", "READUNCOMMITTED", "UPDLOCK", "HOLDLOCK", "ROWLOCK", "TABLOCK", "TABLOCKX", "PAGLOCK", "READPAST", "XLOCK", "NOWAIT", "SERIALIZABLE", "REPEATABLEREAD", "READCOMMITTED", "INDEX", "FORCESEEK", "FORCESCAN" });
    }

    /// WITH (NOLOCK, ...) and the old (NOLOCK): ignored.
    pub fn tableHints(s: *Parser) Error!void {
        if ((s.isKw("WITH") and s.peek().is("(")) or (s.isOp("(") and isHint(s.peek()))) {
            if (s.isKw("WITH")) s.advance();
            try s.skipParens();
        }
    }

    pub fn tableSource(s: *Parser) Error!tree.FromItem {
        var item: tree.FromItem = .{ .source = undefined };
        if (s.isOp("(")) {
            const n = s.peek();
            if (n.isAnyKw(&.{ "SELECT", "WITH", "VALUES" }) or n.is("(")) {
                s.advance();
                if (s.isKw("VALUES")) {
                    const pos = s.here();
                    const rows = try s.valuesRows();
                    item.source = .{ .subquery = try s.new(tree.Select, .{ .body = try s.new(tree.Body, .{ .values = rows }), .pos = pos }) };
                } else {
                    item.source = .{ .subquery = try s.subSelect() };
                }
                try s.expectOp(")");
                item.alias = try s.aliasOf(true);
                return item;
            }
            s.advance();
            const inner = try s.tableRefs();
            try s.expectOp(")");
            item.source = .{ .nested = inner };
            item.alias = try s.aliasOf(false);
            return item;
        }
        if (s.tok.kind == .variable) return s.fail("xqlite: table variables are not supported", .{});
        if (s.tok.kind == .ident and s.tok.isKw("OPENJSON") and s.peek().is("(")) {
            item.source = .{ .func = try json_sql.openJson(s) };
            item.alias = try s.aliasOf(false);
            return item;
        }
        const q = try s.qualifiedNameRaw();
        if (q.special) |sp| {
            const sub = (try @import("catalog_views.zig").select(s, sp, q.q.name.text)) orelse
                return s.fail("Invalid object name '{s}.{s}'.", .{ sp, q.q.name.text });
            item.source = .{ .subquery = sub };
            item.alias = (try s.aliasOf(false)) orelse .{ .name = q.q.name };
            return item;
        }
        if (s.isOp("(") and !isHint(s.peek())) {
            s.advance();
            // A table-valued function (SQLite's json_each(), pragma_*()).
            const args: []*Expr = if (s.isOp(")")) &.{} else try s.exprList();
            try s.expectOp(")");
            item.source = .{ .func = try s.new(tree.Func, .{ .name = q.q.name, .args = args }) };
        } else item.source = .{ .table = q.q };
        try s.tableHints();
        item.alias = try s.aliasOf(false);
        try s.tableHints();
        if (item.alias == null and item.source == .table) {
            if (try s.autoAlias(q.q)) |a| item.alias = .{ .name = a };
        }
        return item;
    }

    pub const RawName = struct { q: QName, special: ?[]const u8 = null };

    /// qualifiedName(), and whether the schema is INFORMATION_SCHEMA or
    /// sys (catalog views).
    pub fn qualifiedNameRaw(s: *Parser) Error!RawName {
        const t = s.tok;
        if ((t.kind == .ident or t.kind == .quoted_ident) and s.peek().is(".")) {
            const first = try s.nameText(t);
            const specials = [_][]const u8{ "INFORMATION_SCHEMA", "sys" };
            for (specials) |sp| if (std.ascii.eqlIgnoreCase(first, sp)) {
                s.advance();
                s.advance();
                const n = try s.nameOf(try s.anyName());
                return .{ .q = .{ .name = n }, .special = sp };
            };
        }
        return .{ .q = try s.qualifiedName() };
    }

    // ================================================================ DML

    /// What the dialect knows of a target table: its name as stored and
    /// the declared type of each column (none for a table another
    /// dialect created), its identity column.
    pub const Target = struct {
        tab: ?*int.Table,
        schema: []const u8,
        name: []const u8 = "",
        /// The name within its schema (SQL Server's messages).
        bare: []const u8 = "",
        cols: []ColMeta,

        pub fn findCol(t: *const Target, n: []const u8) ?*ColMeta {
            for (t.cols) |*c| if (std.ascii.eqlIgnoreCase(c.name, n)) return c;
            return null;
        }

        pub fn identity(t: *const Target) ?*ColMeta {
            for (t.cols) |*c| if (c.identity != null) return c;
            return null;
        }
    };

    pub const ColMeta = struct {
        name: []const u8,
        decl_type: ?[]const u8 = null,
        /// The type argument of xq_tsql_store(): the declared type, the
        /// table (as SQL Server names it in messages) and the column.
        store_arg: []const u8 = "",
        /// The identity sequence.
        identity: ?[]const u8 = null,
        generated: bool = false,
        hidden: bool = false,
    };

    /// Look up the target table and its catalog entries (now, at compile
    /// time).
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
            tab = build.findTable(s.p.db, stored, schema) orelse return .{ .tab = null, .schema = schema, .cols = &.{} };
        }
        var is_mssql = false;
        for (entries) |en| {
            if (en.col.len == 0 and std.mem.eql(u8, en.key, catalog.Key.dialect) and std.mem.eql(u8, en.value, "mssql")) is_mssql = true;
        }
        const cols = try s.a.alloc(ColMeta, tab.cols.len);
        for (tab.cols, 0..) |*c, i| {
            cols[i] = .{
                .name = try s.a.dupe(u8, c.name()),
                .generated = c.col_flags.intersects(int.COLFLAG.GENERATED),
                .hidden = c.col_flags.HIDDEN,
            };
            for (entries) |en| {
                if (!std.ascii.eqlIgnoreCase(en.col, cols[i].name)) continue;
                if (std.mem.eql(u8, en.key, catalog.Key.decl_type) and is_mssql) {
                    cols[i].decl_type = en.value;
                    cols[i].store_arg = try std.fmt.allocPrint(s.a, "{s}|{s}.{s}{s}|{s}", .{ en.value, schema, if (try s.autoAlias(.{ .name = .{ .text = stored } }) != null) "" else "dbo.", stored, cols[i].name });
                }
                if (std.mem.eql(u8, en.key, catalog.Key.identity)) cols[i].identity = en.value;
            }
        }
        return .{ .tab = tab, .schema = schema, .name = stored, .bare = try s.bareName(stored), .cols = cols };
    }
};

fn isAssignOp(t: Token) bool {
    if (t.kind != .op) return false;
    const ops = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=" };
    for (ops) |o| if (std.mem.eql(u8, t.text, o)) return true;
    return false;
}

/// The name of variable @name: lower case, without the @.
pub fn varName(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return std.ascii.allocLowerString(a, text[1..]);
}

/// A lowering failure as the frontend's error (the message is in Parse).
pub fn lowered(err: lower.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.ParseFailed,
    };
}

/// The SQLite collation of a SQL Server collation name: case-sensitive
/// (_CS) and binary (_BIN, _BIN2) ones BINARY, case-insensitive (_CI)
/// ones NOCASE (which folds ASCII letters only).
pub fn mapCollation(n: []const u8) ?[:0]const u8 {
    var b: [128]u8 = undefined;
    if (n.len > b.len) return null;
    const l = std.ascii.lowerString(&b, n);
    if (std.mem.indexOf(u8, l, "_bin") != null or std.mem.indexOf(u8, l, "_cs") != null) return "BINARY";
    if (std.mem.indexOf(u8, l, "_ci") != null) return "NOCASE";
    if (std.mem.eql(u8, l, "binary")) return "BINARY";
    if (std.mem.eql(u8, l, "nocase")) return "NOCASE";
    if (std.mem.eql(u8, l, "rtrim")) return "RTRIM";
    return null;
}
