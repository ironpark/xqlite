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
const sqlparse = @import("sql/parse");
const pratt = sqlparse.pratt;
const syntax = @import("../syntax.zig");
const ctype = @import("xqlite_base").ctype;
const sqllex = @import("sql/lexer");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
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

/// What the parser is reading for the schema (Parser.stored).
pub const Stored = struct {
    /// The clause (CHECK, DEFAULT, GENERATED ALWAYS AS), "" for a view.
    clause: []const u8 = "",
    /// The column or constraint.
    name: []const u8 = "",
};

/// The tokens of a statement, read as the parser goes (where a statement
/// ends is the parser's business), and its error (pkg/sql/parse).
pub const Cursor = sqlparse.Cursor(sqlparse.Streaming(lexer.Lexer), int.ErrorState, struct {
    pub const syntaxErrorAt = mariadbSyntaxError;
});

/// MariaDB's syntax error at token `t`.
fn mariadbSyntaxError(c: anytype, t: Token) Error {
    const near = std.mem.sliceTo(c.sql[t.start..@min(c.sql.len, t.start + 80)], 0);
    const line = sqllex.lineOf(c.sql, t.start);
    return c.failState(t.start, .numbered("42601", 1064), "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '{s}' at line {d}", .{ near, line });
}

pub const Parser = struct {
    p: *Parse,
    a: std.mem.Allocator,
    /// The tokens, the text they are in and the error the parser found
    /// (frontend.zig records it in `p`, unless lowering recorded one).
    c: Cursor,
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
    /// The databases of CREATE DATABASE (catalog/schema.zig), read once.
    schemas: ?[]const nsp.Info = null,
    /// The names of the WITH queries: an unqualified one is not a table
    /// of the current database.
    cte_names: std.ArrayList([]const u8) = .empty,
    /// Names are SQLite's as written (information_schema's text).
    raw_names: bool = false,
    /// The table CREATE TABLE creates (its REFERENCES may name it).
    creating: ?Rel = null,
    /// The precedence parser's state (expr()).
    pratt: pratt.State = .{},

    pub fn init(p: *Parse, sql: [:0]const u8, mode: state.SqlMode) Parser {
        return .{
            .p = p,
            .a = p.arena,
            .c = .{ .arena = p.arena, .sql = sql, .src = .init(lexer.init(sql, 0, mode)) },
            .mode = mode,
        };
    }

    /// The end of the statement: `;` or the end of the text.
    pub fn atStmtEnd(s: *Parser) bool {
        return s.c.atEof() or s.c.isOp(";");
    }

    /// Fail with the error a statement run while compiling this one left
    /// in the connection `db`, as it is (its ErrorState too).
    pub fn failFrom(s: *Parser, db: *int.Sqlite3) Error {
        return s.c.failState(null, db.err_state, "{s}", .{@import("../../sql/main.zig").errmsg(db)});
    }

    /// Fail if a builder left an error.
    pub fn check(s: *Parser) Error!void {
        if (s.p.n_err > 0) return error.ParseFailed;
    }

    /// An expression node from `pos` to the last token consumed.
    pub fn mk(s: *Parser, pos: u32, kind: tree.Kind) Error!*Expr {
        return tree.expr(s.a, pos, @max(pos, s.c.lastEnd()), kind);
    }

    pub fn new(s: *Parser, comptime T: type, v: T) Error!*T {
        return tree.new(s.a, T, v);
    }

    // ============================================================ lowering

    /// A Lowerer of the statement (positions are offsets of its text).
    pub fn lowerer(s: *Parser) lower.Lowerer {
        return .init(s.p, s.c.sql);
    }

    /// Lower statement `st` with the IR.
    pub fn lowerStmt(s: *Parser, st: tree.Stmt) Error!void {
        var l = s.lowerer();
        l.statement(st) catch |err| return lowered(err);
    }

    // =============================================================== names

    /// A name: a word that is not reserved, or a quoted identifier.
    pub fn name(s: *Parser) Error!Token {
        const t = s.c.peek();
        if (t.kind == .quoted_ident or (t.kind == .word and !t.isReserved())) {
            s.c.skip();
            return t;
        }
        return s.c.syntaxError();
    }

    /// A name, also a reserved word (after a dot, or where only a name
    /// can come).
    pub fn anyName(s: *Parser) Error!Token {
        const t = s.c.peek();
        if (t.kind == .quoted_ident or t.kind == .word) {
            s.c.skip();
            return t;
        }
        return s.c.syntaxError();
    }

    pub fn isName(s: *Parser) bool {
        return s.c.peek().kind == .quoted_ident or (s.c.peek().kind == .word and !s.c.peek().isReserved());
    }

    /// The name a name token stands for.
    pub fn nameText(s: *Parser, t: Token) Error![]const u8 {
        return lexer.identValue(s.a, s.c.sql, t);
    }

    /// The tree name of a name token.
    pub fn nameOf(s: *Parser, t: Token) Error!Name {
        return .{ .text = try lexer.identValue(s.a, s.c.sql, t), .pos = t.start };
    }

    /// A string literal's value (after `_charset` introducers and with
    /// adjacent literals concatenated, as MariaDB does).
    pub fn stringLiteral(s: *Parser) Error![]const u8 {
        if (s.c.peek().kind == .word and s.c.text(s.c.peek())[0] == '_' and lexer.isString(s.c.peekAt(1))) s.c.skip();
        if (!lexer.isString(s.c.peek())) return s.c.syntaxError();
        var v = try lexer.stringValue(s.a, s.c.sql, s.c.peek(), !s.mode.has(.NO_BACKSLASH_ESCAPES));
        s.c.skip();
        while (lexer.isString(s.c.peek())) {
            const more = try lexer.stringValue(s.a, s.c.sql, s.c.peek(), !s.mode.has(.NO_BACKSLASH_ESCAPES));
            v = try std.mem.concat(s.a, u8, &.{ v, more });
            s.c.skip();
        }
        return v;
    }

    /// `[database.]name`, as written (relation() resolves it).
    pub fn qualifiedName(s: *Parser) Error!QName {
        const first = try s.nameOf(try s.anyName());
        if (s.c.eatOp(".")) {
            const second = try s.nameOf(try s.anyName());
            return .{ .schema = first, .name = second };
        }
        return .{ .name = first };
    }

    // =========================================================== databases
    //
    // A MariaDB database is a SQLite database (main, the default; temp;
    // an attached one) or a database of CREATE DATABASE (databases.zig),
    // whose objects are main objects named "<db>.<name>"
    // (catalog/schema.zig). Unqualified names are in the current
    // database (USE, state.zig). A mangled name is written without its
    // SQLite database (main) and a FROM item or DML target naming it
    // takes the bare name as its alias, so `t.col` finds it.

    /// A MariaDB database as SQLite has it.
    pub const Db = struct {
        /// The SQLite database: main, temp or an attached one.
        sqlite: []const u8,
        /// A database of CREATE DATABASE (as registered): its objects
        /// are main objects with mangled names.
        named: ?[]const u8 = null,
        /// The name MariaDB shows ('db.t' in messages).
        shown: []const u8,

        /// The SQLite name of object `name` of the database.
        pub fn objectName(d: Db, a: std.mem.Allocator, obj: []const u8) Error![]const u8 {
            const n = d.named orelse return obj;
            return nsp.mangle(a, n, obj);
        }
    };

    /// The databases of CREATE DATABASE (read once per statement).
    pub fn registered(s: *Parser) Error![]const nsp.Info {
        if (s.schemas) |l| return l;
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const l = nsp.list(s.p.db, s.a) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return s.failFrom(s.p.db),
        };
        s.schemas = l;
        return l;
    }

    /// Database `name`, null if there is none.
    pub fn database(s: *Parser, db_name: []const u8) Error!?Db {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        if (build.findDbName(s.p.db, db_name)) |i| {
            const n = s.p.db.dbs.items[i].name;
            return .{ .sqlite = n, .shown = n };
        }
        if (nsp.find(try s.registered(), db_name)) |info| return .{ .sqlite = catalog.main_schema, .named = info.name, .shown = info.name };
        return null;
    }

    /// The current database (USE); "No database selected" if none is.
    pub fn currentDb(s: *Parser) Error!Db {
        const cur = s.p.db.xq.mariadb.currentDatabase() orelse return s.c.failState(null, .numbered("3D000", 1046), "No database selected", .{});
        if (build.findDbName(s.p.db, cur)) |i| {
            const n = s.p.db.dbs.items[i].name;
            return .{ .sqlite = n, .shown = n };
        }
        // A database of CREATE DATABASE (USE checked it; if another
        // connection dropped it since, its tables are not found).
        return .{ .sqlite = catalog.main_schema, .named = cur, .shown = cur };
    }

    /// A table (view) name resolved.
    pub const Rel = struct {
        /// The SQLite name. Its database is null where SQLite's lookup
        /// finds the object (an unqualified name in main, a temporary
        /// table) and for a mangled name (main).
        q: QName,
        /// The alias a FROM item or DML target naming a mangled name
        /// takes: the bare name.
        alias: ?Name = null,
        db: Db,
        /// The name within the database.
        bare: []const u8,

        /// The SQLite database to look the name up in (null: SQLite's
        /// order, temp first).
        pub fn sqliteDb(r: Rel) ?[]const u8 {
            if (r.q.schema) |x| return x.text;
            return if (r.db.named != null) catalog.main_schema else null;
        }

        /// 'db.name' as MariaDB's messages show it.
        pub fn shown(r: Rel, a: std.mem.Allocator) Error![]const u8 {
            return std.fmt.allocPrint(a, "{s}.{s}", .{ r.db.shown, r.bare });
        }

        /// The table or view, if it exists.
        pub fn find(r: Rel, db: *int.Sqlite3) ?*int.Table {
            return build.findTable(db, r.q.name.text, r.sqliteDb());
        }
    };

    /// The object `q` names in a query, a DML statement, SHOW ...: in
    /// its database (a missing one: "Table 'x.t' doesn't exist", as
    /// MariaDB says), else in the current one (a WITH query and a
    /// temporary table first).
    pub fn relation(s: *Parser, q: QName) Error!Rel {
        if (q.schema) |x| {
            if (s.raw_names) return .{ .q = q, .db = .{ .sqlite = x.text, .shown = x.text }, .bare = q.name.text };
            const d = (try s.database(x.text)) orelse return s.c.failState(null, .numbered("42P01", 1146), "Table '{s}.{s}' doesn't exist", .{ x.text, q.name.text });
            return s.inDb(d, q.name, true);
        }
        const keep: Rel = .{ .q = q, .db = .{ .sqlite = catalog.main_schema, .shown = catalog.main_schema }, .bare = q.name.text };
        if (s.raw_names) return keep;
        for (s.cte_names.items) |c| if (std.ascii.eqlIgnoreCase(c, q.name.text)) return keep;
        const d = try s.currentDb();
        // SQLite looks in temp first.
        if (!std.mem.eql(u8, d.sqlite, catalog.main_schema) or d.named != null) {
            ir.stmt.readSchema(s.p) catch return error.ParseFailed;
            if (build.findTable(s.p.db, q.name.text, "temp") != null) return .{ .q = q, .db = .{ .sqlite = "temp", .shown = d.shown }, .bare = q.name.text };
        }
        return s.inDb(d, q.name, false);
    }

    /// Object `n` of database `d`; `qualify`: name its SQLite database
    /// (else main's unqualified name stays so).
    fn inDb(s: *Parser, d: Db, n: Name, qualify: bool) Error!Rel {
        if (d.named) |_| {
            const m = try d.objectName(s.a, n.text);
            return .{ .q = .{ .name = .{ .text = m, .pos = n.pos } }, .alias = n, .db = d, .bare = n.text };
        }
        const unq = !qualify and std.mem.eql(u8, d.sqlite, catalog.main_schema);
        return .{
            .q = .{ .schema = if (unq) null else .{ .text = d.sqlite, .pos = n.pos }, .name = n },
            .db = d,
            .bare = n.text,
        };
    }

    /// Where CREATE puts object `q`: its database ("Unknown database"
    /// if there is none), temp for a temporary one, else the current
    /// database. The SQLite name always has its database.
    pub fn createTarget(s: *Parser, q: QName, temp: bool) Error!Rel {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        if (temp) {
            const shown = if (q.schema) |x| x.text else (s.p.db.xq.mariadb.currentDatabase() orelse catalog.main_schema);
            return .{ .q = .{ .schema = .{ .text = "temp", .pos = q.name.pos }, .name = q.name }, .db = .{ .sqlite = "temp", .shown = shown }, .bare = q.name.text };
        }
        const d = if (q.schema) |x|
            (try s.database(x.text)) orelse return s.c.failState(null, .numbered("3D000", 1049), "Unknown database '{s}'", .{x.text})
        else
            try s.currentDb();
        var r = try s.inDb(d, q.name, true);
        if (r.q.schema == null) r.q.schema = .{ .text = d.sqlite, .pos = q.name.pos };
        r.alias = null;
        return r;
    }

    /// The xq_sequence name of sequence `q` (sequences are in main; one
    /// of a database of CREATE DATABASE is mangled).
    pub fn sequenceName(s: *Parser, q: QName) Error![]const u8 {
        if (s.raw_names) return q.name.text;
        const d = if (q.schema) |x|
            (try s.database(x.text)) orelse return s.c.failState(null, .numbered("3D000", 1049), "Unknown database '{s}'", .{x.text})
        else
            try s.currentDb();
        return d.objectName(s.a, q.name.text);
    }

    // ======================================================== expressions

    /// An expression: one table of sqlparse.pratt (ops()) says where the
    /// operators stand, prefix(), infix() and postfix() what they mean.
    pub fn expr(s: *Parser) Error!*Expr {
        return s.exprAt(0);
    }

    fn bin(s: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return tree.expr(s.a, l.pos, r.end, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    const ExprOp = enum {
        @"or",
        xor,
        @"and",
        not,
        compare,
        is,
        like,
        not_like,
        regexp,
        not_regexp,
        in,
        not_in,
        between,
        not_between,
        sounds,
        bit_or,
        bit_and,
        shl,
        shr,
        add,
        sub,
        interval,
        mul,
        div,
        rem,
        int_div,
        bit_xor,
        concat,
        neg,
        plus,
        bit_not,
        bang,
        binary,
        json,
        json_text,
        collate,
    };

    /// Binding powers: conditions, the predicates, bit expressions
    /// (| & << >> + -), terms (* / ^ ||), unary operators, COLLATE, ->.
    const pred_bp = 40;
    const bit_bp = 50;
    const add_bp = 80;
    const mul_bp = 90;
    const unary_bp = 120;
    const collate_bp = 130;
    const json_bp = 140;

    /// MariaDB's operators. What no tighter operator follows is capped:
    /// `x IS NULL + 1`, `x IN (1) * 2`, `x - INTERVAL 1 DAY * 2` and
    /// `x COLLATE c -> '$'` are syntax errors. NOT starts a condition only
    /// (`1 + NOT x` is a syntax error at NOT), - + ~ ! BINARY a term only
    /// (after ESCAPE a primary follows), and `INTERVAL n unit + x` starts
    /// a bit expression; elsewhere `INTERVAL ...` is an operand of its own
    /// (wordExpr()). `||` is OR, or a term's Concat under PIPES_AS_CONCAT.
    fn ops(comptime pipes: bool) []const pratt.Op(ExprOp) {
        const T = ExprOp;
        const no_paren: pratt.Tok = .{ .kind = "lparen" };
        var o: []const pratt.Op(T) = &.{pratt.left(T, .@"or", 10, .{ .kw = "OR" })};
        if (!pipes) o = o ++ .{pratt.left(T, .@"or", 10, .{ .op = "||" })};
        o = o ++ .{
            pratt.left(T, .xor, 20, .{ .kw = "XOR" }),
            pratt.left(T, .@"and", 30, .{ .kw = "AND" }),
            pratt.left(T, .@"and", 30, .{ .op = "&&" }),
            pratt.prefixAt(T, .not, pred_bp, pred_bp, .{ .kw = "NOT" }),
            pratt.postfix(T, .is, pred_bp, .{ .kw = "IS", .cap = pred_bp }),
            pratt.left(T, .not_like, pred_bp, .{ .kw = "NOT", .then = "LIKE" }),
            pratt.left(T, .not_in, pred_bp, .{ .kw = "NOT", .then = "IN", .cap = pred_bp }),
            pratt.left(T, .not_between, pred_bp, .{ .kw = "NOT", .then = "BETWEEN" }),
            pratt.left(T, .not_regexp, pred_bp, .{ .kw = "NOT", .then = "REGEXP" }),
            pratt.left(T, .not_regexp, pred_bp, .{ .kw = "NOT", .then = "RLIKE" }),
            pratt.left(T, .like, pred_bp, .{ .kw = "LIKE" }),
            pratt.left(T, .regexp, pred_bp, .{ .kw = "REGEXP" }),
            pratt.left(T, .regexp, pred_bp, .{ .kw = "RLIKE" }),
            pratt.left(T, .in, pred_bp, .{ .kw = "IN", .cap = pred_bp }),
            pratt.left(T, .between, pred_bp, .{ .kw = "BETWEEN" }),
            pratt.left(T, .sounds, pred_bp, .{ .kw = "SOUNDS" }),
        };
        for (compare_ops) |c| o = o ++ .{pratt.left(T, .compare, pred_bp, .{ .op = c[0] })};
        o = o ++ .{
            pratt.left(T, .bit_or, bit_bp, .{ .op = "|" }),
            pratt.left(T, .bit_and, 60, .{ .op = "&" }),
            pratt.left(T, .shl, 70, .{ .op = "<<" }),
            pratt.left(T, .shr, 70, .{ .op = ">>" }),
            pratt.left(T, .add, add_bp, .{ .op = "+" }),
            pratt.left(T, .sub, add_bp, .{ .op = "-" }),
            pratt.prefixAt(T, .interval, add_bp, mul_bp, .{ .kw = "INTERVAL", .unless = no_paren }),
            pratt.left(T, .mul, mul_bp, .{ .op = "*" }),
            pratt.left(T, .div, mul_bp, .{ .op = "/" }),
            pratt.left(T, .rem, mul_bp, .{ .op = "%" }),
            pratt.left(T, .rem, mul_bp, .{ .kw = "MOD" }),
            pratt.left(T, .int_div, mul_bp, .{ .kw = "DIV" }),
            pratt.left(T, .bit_xor, 100, .{ .op = "^" }),
        };
        if (pipes) o = o ++ .{pratt.left(T, .concat, 110, .{ .op = "||" })};
        return o ++ .{
            pratt.prefixAt(T, .neg, unary_bp, unary_bp, .{ .op = "-" }),
            pratt.prefixAt(T, .plus, unary_bp, unary_bp, .{ .op = "+" }),
            pratt.prefixAt(T, .bit_not, unary_bp, unary_bp, .{ .op = "~" }),
            pratt.prefixAt(T, .bang, unary_bp, unary_bp, .{ .op = "!" }),
            pratt.prefixAt(T, .binary, unary_bp, unary_bp, .{ .kw = "BINARY", .unless = no_paren }),
            pratt.postfix(T, .collate, collate_bp, .{ .kw = "COLLATE", .cap = collate_bp }),
            pratt.postfix(T, .json, json_bp, .{ .op = "->" }),
            pratt.postfix(T, .json_text, json_bp, .{ .op = "->>" }),
        };
    }

    fn Ops(comptime pipes: bool) type {
        return pratt.Pratt(Parser, *Expr, ExprOp, comptime ops(pipes));
    }

    /// An expression whose operators bind at least `min`.
    fn exprAt(s: *Parser, min: u8) Error!*Expr {
        if (s.mode.has(.PIPES_AS_CONCAT)) return Ops(true).expr(s, min);
        return Ops(false).expr(s, min);
    }

    /// The comparison operators; <=> is IS.
    const compare_ops = [_]struct { []const u8, tree.CmpOp }{
        .{ "=", .eq },  .{ "<>", .ne }, .{ "!=", .ne }, .{ "<", .lt },
        .{ "<=", .le }, .{ ">", .gt },  .{ ">=", .ge }, .{ "<=>", .is },
    };

    fn compareOp(s: *const Parser, t: Token) tree.CmpOp {
        for (compare_ops) |o| if (std.mem.eql(u8, s.c.text(t), o[0])) return o[1];
        unreachable;
    }

    /// A bit expression: an operand of the predicates.
    pub fn bitOr(s: *Parser) Error!*Expr {
        return s.exprAt(bit_bp);
    }

    /// `a + b - ...` (and INTERVAL forms): a LIMIT value, and an operand
    /// starting with INTERVAL.
    fn additive(s: *Parser) Error!*Expr {
        return s.exprAt(add_bp);
    }

    pub fn operand(s: *Parser) Error!*Expr {
        return s.primary();
    }

    /// NOT, `INTERVAL n unit + x` (xq_date_add()), - + ~ !, BINARY.
    pub fn prefix(s: *Parser, tag: ExprOp, m: anytype, rbp: u8) Error!*Expr {
        const pos = m.first.start;
        if (tag == .interval) {
            const iv = try s.intervalRest();
            try s.c.expectOp("+");
            const d = try s.exprAt(rbp);
            return s.dateAdd(pos, d, iv.n, iv.unit, false);
        }
        const e = try s.exprAt(rbp);
        return switch (tag) {
            .not, .bang => s.mk(pos, .{ .unary = .{ .op = .not, .e = e } }),
            .neg => s.mk(pos, .{ .unary = .{ .op = .neg, .e = e } }),
            .plus => e,
            .bit_not => s.mk(pos, .{ .unary = .{ .op = .bit_not, .e = e } }),
            .binary => s.mk(pos, .{ .collate = .{ .e = e, .collation = "BINARY" } }),
            else => unreachable,
        };
    }

    /// The binary operators, the predicates (whose operands are bit
    /// expressions), `x ± INTERVAL n unit`, and `||` as a Concat of all
    /// the operands in a row.
    pub fn infix(s: *Parser, tag: ExprOp, l: *Expr, m: anytype, rbp: u8) Error!*Expr {
        const not = switch (tag) {
            .not_like, .not_regexp, .not_in, .not_between => true,
            else => false,
        };
        switch (tag) {
            .compare => {
                if (s.c.isAnyKw(&.{ "ANY", "SOME", "ALL" })) {
                    return s.c.fail(null, "xqlite: comparisons with ANY/SOME/ALL subqueries are not supported", .{});
                }
                const r = try s.bitOr();
                return s.mk(l.pos, .{ .compare = .{ .op = s.compareOp(m.first), .l = try functions.jsonCompared(s, l), .r = try functions.jsonCompared(s, r) } });
            },
            .like, .not_like => {
                const r = try s.bitOr();
                // The escape character is \ unless ESCAPE says (then a
                // primary, after which no tighter operator follows).
                const esc = if (s.c.eatKw("ESCAPE")) blk: {
                    const e = try s.exprAt(collate_bp);
                    s.pratt.cap(pred_bp);
                    break :blk e;
                } else try s.mk(m.last.start, .{ .string = "\\" });
                return s.mk(l.pos, .{ .like = .{ .e = l, .pat = r, .not = not, .case_sensitive = false, .escape = .{ .expr = esc } } });
            },
            .regexp, .not_regexp => {
                const r = try s.bitOr();
                const f = try s.new(tree.Func, .{ .name = .{ .text = "regexp", .pos = m.last.start }, .args = try s.a.dupe(*Expr, &.{ r, l }) });
                const e = try s.mk(l.pos, .{ .func = f });
                if (!not) return e;
                return s.mk(e.pos, .{ .unary = .{ .op = .not, .e = e } });
            },
            .in, .not_in => {
                try s.c.expectOp("(");
                if (s.isSelectStart()) {
                    const sub = try s.selectStmt();
                    try s.c.expectOp(")");
                    return s.mk(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = sub } });
                }
                const items = try s.exprList();
                try s.c.expectOp(")");
                return s.mk(l.pos, .{ .in_list = .{ .e = try functions.jsonCompared(s, l), .not = not, .items = items } });
            },
            .between, .not_between => {
                const lo = try s.bitOr();
                try s.c.expectKw("AND");
                const hi = try s.bitOr();
                return s.mk(l.pos, .{ .between = .{ .e = l, .not = not, .lo = lo, .hi = hi } });
            },
            .sounds => return s.c.fail(null, "xqlite: SOUNDS LIKE is not supported", .{}),
            .add, .sub => if (s.c.isKw("INTERVAL")) {
                const iv = try s.interval();
                s.pratt.cap(add_bp);
                return s.dateAdd(l.pos, l, iv.n, iv.unit, tag == .sub);
            },
            .concat => {
                var args: std.ArrayList(*Expr) = .empty;
                try args.append(s.a, l);
                try args.append(s.a, try s.exprAt(rbp));
                while (s.c.eatOp("||")) try args.append(s.a, try s.exprAt(rbp));
                return s.mk(l.pos, .{ .concat = .{ .args = args.items, .null_policy = .propagate } });
            },
            else => {},
        }
        const r = try s.exprAt(rbp);
        return switch (tag) {
            .@"or" => s.bin(.@"or", l, r),
            .@"and" => s.bin(.@"and", l, r),
            .xor => s.func(l.pos, "xq_xor", &.{ l, r }),
            .bit_or => s.bin(.bit_or, l, r),
            .bit_and => s.bin(.bit_and, l, r),
            .shl => s.bin(.shl, l, r),
            .shr => s.bin(.shr, l, r),
            .add => s.bin(.add, l, r),
            .sub => s.bin(.sub, l, r),
            .mul => s.bin(.mul, l, r),
            .div => s.mk(l.pos, .{ .div = .{ .kind = .real, .l = l, .r = r } }),
            .rem => s.bin(.rem, l, r),
            .int_div => s.mk(l.pos, .{ .div = .{ .kind = .int, .l = l, .r = r } }),
            .bit_xor => s.func(l.pos, "xq_bitxor", &.{ l, r }),
            else => unreachable,
        };
    }

    /// IS [NOT] {NULL | UNKNOWN | TRUE | FALSE}; COLLATE name;
    /// col->'path', col->>'path' (MySQL's; MariaDB has neither).
    pub fn postfix(s: *Parser, tag: ExprOp, l: *Expr, m: anytype) Error!*Expr {
        switch (tag) {
            .is => {
                const not = s.c.eatKw("NOT");
                if (s.c.eatKw("NULL") or s.c.eatKw("UNKNOWN")) {
                    return s.mk(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                } else if (s.c.isKw("TRUE") or s.c.isKw("FALSE")) {
                    const v = s.c.isKw("TRUE");
                    s.c.skip();
                    return s.mk(l.pos, .{ .is_bool = .{ .e = l, .value = v, .not = not } });
                }
                return s.c.syntaxError();
            },
            .collate => {
                const coll = try s.collationName();
                return s.mk(l.pos, .{ .collate = .{ .e = l, .collation = coll } });
            },
            .json, .json_text => {
                const pos = m.first.start;
                const path = try s.mk(s.c.here(), .{ .string = try s.stringLiteral() });
                const e = try s.func(pos, "json_extract", &.{ l, path });
                if (tag == .json) return e;
                return s.func(pos, "json_unquote", &.{e});
            },
            else => unreachable,
        }
    }

    const Interval = struct { n: *Expr, unit: []const u8 };

    /// `INTERVAL expr unit`.
    fn interval(s: *Parser) Error!Interval {
        try s.c.expectKw("INTERVAL");
        return s.intervalRest();
    }

    /// `expr unit`, after INTERVAL.
    fn intervalRest(s: *Parser) Error!Interval {
        const n = try s.expr();
        if (s.c.peek().kind != .word) return s.c.syntaxError();
        const unit = s.c.text(s.c.peek());
        s.c.skip();
        return .{ .n = n, .unit = unit };
    }

    /// xq_date_add(d, [-]n, 'UNIT').
    pub fn dateAdd(s: *Parser, pos: u32, d: *Expr, n: *Expr, unit: []const u8, negate: bool) Error!*Expr {
        const amount = if (negate) try s.mk(n.pos, .{ .unary = .{ .op = .neg, .e = n } }) else n;
        const u = try std.ascii.allocUpperString(s.a, unit);
        return s.func(pos, "xq_date_add", &.{ d, amount, try s.str(pos, u) });
    }

    /// The SQLite collation for a MariaDB collation name (after COLLATE).
    pub fn collationName(s: *Parser) Error![:0]const u8 {
        const t = s.c.peek();
        if (t.kind != .word and t.kind != .quoted_ident and !lexer.isString(t)) return s.c.syntaxError();
        const n = if (lexer.isString(t)) try lexer.stringValue(s.a, s.c.sql, t, false) else try s.nameText(t);
        s.c.skip();
        return mapCollation(n) orelse s.c.failState(null, .numbered("42704", 1273), "Unknown collation: '{s}'", .{n});
    }

    /// A string constant at `pos`.
    pub fn str(s: *Parser, pos: u32, z: []const u8) Error!*Expr {
        return tree.expr(s.a, pos, pos, .{ .string = z });
    }

    /// An integer constant at `pos`.
    pub fn int_(s: *Parser, pos: u32, v: i64) Error!*Expr {
        return tree.intConst(s.a, pos, v);
    }

    /// A call of `fname` (a function the frontend chose): of the
    /// dialect's table if it has one of that name (Dialect.hasFunction()),
    /// else a SQLite built-in or an engine function.
    pub fn func(s: *Parser, pos: u32, fname: []const u8, args: []const *Expr) Error!*Expr {
        return s.funcNode(pos, .{ .name = .{ .text = fname, .pos = pos }, .args = try s.a.dupe(*Expr, args) });
    }

    /// A Func node (its `dialect` set as func() says).
    pub fn funcNode(s: *Parser, pos: u32, f: tree.Func) Error!*Expr {
        var x = f;
        x.dialect = if (dialect.Dialect.mariadb.hasFunction(f.name.text)) .mariadb else null;
        return s.mk(pos, .{ .func = try s.new(tree.Func, x) });
    }

    pub fn isSelectStart(s: *Parser) bool {
        return s.c.isKw("SELECT") or s.c.isKw("WITH") or (s.c.isOp("(") and isSelectish(s.c.peekAt(1))) or s.c.isKw("VALUES");
    }

    fn isSelectish(t: Token) bool {
        return t.isKw("SELECT") or t.isKw("WITH") or t.kind == .lparen;
    }

    /// Refuse what the schema may not keep (variables, parameters):
    /// `what` is its text.
    fn refuseStored(s: *Parser, what: []const u8) Error!void {
        const st = s.stored orelse return;
        if (st.clause.len == 0) return s.c.failState(null, .numbered("0A000", 1351), "View's SELECT contains a variable or parameter", .{});
        return s.c.failState(null, .numbered("42P17", 1901), "Function or expression '{s}' cannot be used in the {s} clause of `{s}`", .{ what, st.clause, st.name });
    }

    fn primary(s: *Parser) Error!*Expr {
        const t = s.c.peek();
        const pos = t.start;
        if (lexer.isHex(t)) {
            s.c.skip();
            const digits = (try lexer.hexDigits(s.a, s.c.sql, t)) orelse return s.c.syntaxErrorAt(t);
            return s.mk(pos, .{ .blob = digits });
        }
        if (lexer.isBits(t)) {
            s.c.skip();
            const v = lexer.bitValue(s.c.sql, t) orelse return s.c.failState(null, .of("22003"), "bit literal out of range", .{});
            if (v < 0) return s.int_(pos, v);
            return s.mk(pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{v}) });
        }
        switch (t.kind) {
            .string => {
                const v = try s.stringLiteral();
                if (v.len == 0 and s.mode.has(.EMPTY_STRING_IS_NULL)) return s.mk(pos, .null);
                return s.mk(pos, .{ .string = v });
            },
            .integer => {
                s.c.skip();
                return s.mk(pos, .{ .integer = s.c.text(t) });
            },
            .float => {
                s.c.skip();
                return s.mk(pos, .{ .float = s.c.text(t) });
            },
            .param => {
                try s.refuseStored(s.c.text(t));
                s.c.skip();
                return s.mk(pos, .{ .param = null });
            },
            .variable => {
                try s.refuseStored(s.c.text(t));
                s.c.skip();
                if (t.sub == .system) {
                    const name_ = try sysVarName(s, t);
                    return s.func(pos, "xq_sysvar", &.{try s.str(pos, name_)});
                }
                const name_ = try userVarName(s, t);
                if (s.c.eatOp(":=")) {
                    const v = try s.expr();
                    return s.func(pos, "xq_set_uservar", &.{ try s.str(pos, name_), v });
                }
                return s.func(pos, "xq_uservar", &.{try s.str(pos, name_)});
            },
            .lparen => return s.parenthesized(),
            .op => {
                if (s.c.isOpTok(t, "{")) {
                    // ODBC escapes: {d '...'}, {ts '...'}, {fn f()}.
                    s.c.skip();
                    _ = try s.anyName();
                    const e = try s.expr();
                    try s.c.expectOp("}");
                    return e;
                }
                return s.c.syntaxError();
            },
            .quoted_ident => return s.columnRef(),
            .word => return s.wordExpr(),
            else => return s.c.syntaxError(),
        }
    }

    /// `( ... )`: a subquery, a row value or a parenthesized expression.
    fn parenthesized(s: *Parser) Error!*Expr {
        const pos = s.c.here();
        try s.c.expectOp("(");
        if (s.c.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
            const sub = try s.selectStmt();
            try s.c.expectOp(")");
            return s.mk(pos, .{ .subquery = sub });
        }
        const first = try s.expr();
        if (s.c.eatOp(")")) return first;
        var items: std.ArrayList(*Expr) = .empty;
        try items.append(s.a, first);
        while (s.c.eatOp(",")) try items.append(s.a, try s.expr());
        try s.c.expectOp(")");
        return s.mk(pos, .{ .row = items.items });
    }

    fn columnRef(s: *Parser) Error!*Expr {
        const pos = s.c.here();
        var names: std.ArrayList(Name) = .empty;
        try names.append(s.a, try s.nameOf(try s.anyName()));
        while (names.items.len < 3 and s.c.eatOp(".")) try names.append(s.a, try s.nameOf(try s.anyName()));
        // db.t.col of a database of CREATE DATABASE: the table's alias is t.
        if (names.items.len == 3 and !s.raw_names) {
            if (try s.database(names.items[0].text)) |d| if (d.named != null) return s.mk(pos, .{ .column = names.items[1..] });
        }
        return s.mk(pos, .{ .column = names.items });
    }

    /// An expression starting with a word: a keyword form, a function
    /// call or a column reference.
    fn wordExpr(s: *Parser) Error!*Expr {
        const t = s.c.peek();
        const pos = t.start;
        const next = s.c.peekAt(1);
        if (t.isKw("NULL") or t.isKw("UNKNOWN")) {
            s.c.skip();
            return s.mk(pos, .null);
        }
        if (t.isKw("TRUE") or t.isKw("FALSE")) {
            s.c.skip();
            return s.mk(pos, .{ .boolean = t.isKw("TRUE") });
        }
        if (t.isKw("CASE")) return s.caseExpr();
        if (t.isKw("EXISTS")) {
            s.c.skip();
            try s.c.expectOp("(");
            const sub = try s.selectStmt();
            try s.c.expectOp(")");
            return s.mk(pos, .{ .exists = sub });
        }
        if (t.isKw("DEFAULT") and s.allow_default and next.kind != .lparen) {
            s.c.skip();
            return s.mk(pos, .default);
        }
        if (t.isAnyKw(&.{ "DATE", "TIME", "TIMESTAMP" }) and lexer.isString(next)) {
            // DATE '2024-01-01' and the like: the string.
            s.c.skip();
            return s.primary();
        }
        if (s.c.text(t)[0] == '_' and (lexer.isString(next) or lexer.isHex(next) or lexer.isBits(next))) {
            // A character set introducer: _latin1 'x' is the string (and
            // _binary X'41', _binary 0b1 the constant).
            s.c.skip();
            return s.primary();
        }
        if (t.isKw("INTERVAL") and next.kind != .lparen) {
            // INTERVAL n unit + date
            return s.additive();
        }
        if (t.isKw("NEXT") and next.isKw("VALUE")) {
            s.c.skip();
            s.c.skip();
            try s.c.expectKw("FOR");
            const seq = try s.qualifiedName();
            return s.func(pos, "nextval", &.{try s.str(seq.name.pos, try s.sequenceName(seq))});
        }
        if ((t.isKw("PREVIOUS") or t.isKw("LASTVAL")) and next.isKw("VALUE")) {
            s.c.skip();
            s.c.skip();
            try s.c.expectKw("FOR");
            const seq = try s.qualifiedName();
            return s.func(pos, "lastval", &.{try s.str(seq.name.pos, try s.sequenceName(seq))});
        }
        if (next.kind == .lparen) return @import("functions.zig").call(s);
        // Niladic functions.
        const niladic = [_]struct { []const u8, []const u8 }{
            .{ "CURRENT_TIMESTAMP", "now" }, .{ "LOCALTIME", "now" },        .{ "LOCALTIMESTAMP", "now" },
            .{ "CURRENT_DATE", "curdate" },  .{ "CURRENT_TIME", "curtime" }, .{ "UTC_TIMESTAMP", "now" },
            .{ "UTC_DATE", "curdate" },      .{ "UTC_TIME", "curtime" },     .{ "CURRENT_USER", "current_user" },
        };
        inline for (niladic) |n| if (t.isKw(n[0])) {
            s.c.skip();
            return @import("functions.zig").byName(s, n[1], &.{}, pos);
        };
        if (t.isReserved()) return s.c.syntaxError();
        return s.columnRef();
    }

    fn caseExpr(s: *Parser) Error!*Expr {
        return syntax.caseExpr(s, expr);
    }

    pub fn exprList(s: *Parser) Error![]*Expr {
        return s.c.list(*Expr, s, expr);
    }

    // ============================================================= SELECT

    /// `[WITH ...] select_body [ORDER BY ...] [LIMIT ...] [locking]`.
    pub fn selectStmt(s: *Parser) Error!*tree.Select {
        const pos = s.c.here();
        const jm = json_table.mark(s);
        var w: ?*tree.With = null;
        if (s.c.isKw("WITH")) w = try s.withClause();
        const body = try s.selectBody();
        const sel = try s.new(tree.Select, .{ .with = w, .body = body, .pos = pos });
        try s.orderLimit(sel);
        try s.lockingClause();
        try json_table.endSelect(s, jm, sel);
        return sel;
    }

    /// The ORDER BY and LIMIT of a whole SELECT.
    fn orderLimit(s: *Parser, sel: *tree.Select) Error!void {
        if (s.c.eatKws(&.{ "ORDER", "BY" })) {
            sel.order_by = try s.sortList();
        }
        if (s.c.isKw("LIMIT")) {
            const l = try s.limitClause();
            sel.limit = l.limit;
            sel.offset = l.offset;
        } else if (s.c.eatKw("OFFSET")) {
            // OFFSET n ROWS FETCH {FIRST|NEXT} m ROWS ONLY (MariaDB 10.6).
            sel.offset = try s.expr();
            _ = s.c.eatKw("ROWS") or s.c.eatKw("ROW");
            if (s.c.eatKw("FETCH")) sel.limit = try s.fetchFirst();
        } else if (s.c.eatKw("FETCH")) {
            sel.limit = try s.fetchFirst();
        }
    }

    fn fetchFirst(s: *Parser) Error!*Expr {
        if (!(s.c.eatKw("FIRST") or s.c.eatKw("NEXT"))) return s.c.syntaxError();
        const n = if (s.c.isKw("ROW") or s.c.isKw("ROWS")) try s.int_(s.c.here(), 1) else try s.expr();
        if (!(s.c.eatKw("ROWS") or s.c.eatKw("ROW"))) return s.c.syntaxError();
        if (s.c.isKw("WITH")) return s.c.fail(null, "xqlite: FETCH ... WITH TIES is not supported", .{});
        try s.c.expectKw("ONLY");
        return n;
    }

    pub const Limit = struct { limit: *Expr, offset: ?*Expr = null };

    /// `LIMIT n`, `LIMIT off, n`, `LIMIT n OFFSET m`.
    pub fn limitClause(s: *Parser) Error!Limit {
        try s.c.expectKw("LIMIT");
        const first = try s.limitValue();
        if (s.c.eatOp(",")) return .{ .limit = try s.limitValue(), .offset = first };
        if (s.c.eatKw("OFFSET")) return .{ .limit = first, .offset = try s.limitValue() };
        if (s.c.isKw("ROWS")) return s.c.fail(null, "xqlite: LIMIT ROWS EXAMINED is not supported", .{});
        return .{ .limit = first };
    }

    /// A LIMIT value: a number, a parameter or (an xqlite extension) an
    /// expression.
    fn limitValue(s: *Parser) Error!*Expr {
        return s.additive();
    }

    fn lockingClause(s: *Parser) Error!void {
        if (s.c.eatKws(&.{ "FOR", "UPDATE" })) {
            if (s.c.eatKw("WAIT")) {
                _ = try s.expr();
            } else _ = s.c.eatKw("NOWAIT") or (s.c.eatKw("SKIP") and s.c.eatKw("LOCKED"));
        } else if (s.c.eatKws(&.{ "LOCK", "IN" })) {
            try s.c.expectKw("SHARE");
            try s.c.expectKw("MODE");
        }
    }

    /// A parenthesized list of names.
    pub fn nameList(s: *Parser) Error![]Name {
        try s.c.expectOp("(");
        var out: std.ArrayList(Name) = .empty;
        while (true) {
            try out.append(s.a, try s.nameOf(try s.anyName()));
            if (!s.c.eatOp(",")) break;
        }
        try s.c.expectOp(")");
        return out.items;
    }

    fn withClause(s: *Parser) Error!*tree.With {
        try s.c.expectKw("WITH");
        const recursive = s.c.eatKw("RECURSIVE");
        var ctes: std.ArrayList(tree.Cte) = .empty;
        while (true) {
            const n = try s.nameOf(try s.name());
            try s.cte_names.append(s.a, n.text);
            var cols: []Name = &.{};
            if (s.c.isOp("(")) cols = try s.nameList();
            try s.c.expectKw("AS");
            try s.c.expectOp("(");
            const q = try s.selectStmt();
            try s.c.expectOp(")");
            try ctes.append(s.a, .{ .name = n, .cols = cols, .select = q });
            if (!s.c.eatOp(",")) break;
        }
        return s.new(tree.With, .{ .recursive = recursive, .ctes = ctes.items });
    }

    /// Terms joined by UNION/EXCEPT/INTERSECT.
    fn selectBody(s: *Parser) Error!*tree.Body {
        var lhs = try s.selectTerm();
        while (true) {
            var op: tree.SetOp = undefined;
            var all = false;
            if (s.c.eatKw("UNION")) {
                op = .@"union";
                all = s.c.eatKw("ALL");
                if (!all) _ = s.c.eatKw("DISTINCT");
            } else if (s.c.eatKw("EXCEPT") or s.c.eatKw("MINUS")) {
                if (s.c.eatKw("ALL")) return s.c.fail(null, "xqlite: EXCEPT ALL is not supported", .{});
                _ = s.c.eatKw("DISTINCT");
                op = .except;
            } else if (s.c.eatKw("INTERSECT")) {
                if (s.c.eatKw("ALL")) return s.c.fail(null, "xqlite: INTERSECT ALL is not supported", .{});
                _ = s.c.eatKw("DISTINCT");
                op = .intersect;
            } else break;
            const rhs = try s.selectTerm();
            lhs = try s.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = lhs, .right = rhs } });
        }
        return lhs;
    }

    fn selectTerm(s: *Parser) Error!*tree.Body {
        if (s.c.eatOp("(")) {
            const inner = try s.selectStmt();
            try s.c.expectOp(")");
            return s.new(tree.Body, .{ .nested = inner });
        }
        if (s.c.isKw("VALUES")) return s.new(tree.Body, .{ .values = try s.valuesRows() });
        return s.new(tree.Body, .{ .core = try s.selectCore() });
    }

    /// `VALUES (row), (row) ...` (an empty row is allowed).
    pub fn valuesRows(s: *Parser) Error![][]*Expr {
        if (!(s.c.eatKw("VALUES") or s.c.eatKw("VALUE"))) return s.c.syntaxError();
        var rows: std.ArrayList([]*Expr) = .empty;
        while (true) {
            try s.c.expectOp("(");
            const row: []*Expr = if (s.c.isOp(")")) &.{} else try s.exprList();
            try s.c.expectOp(")");
            try rows.append(s.a, row);
            if (!s.c.eatOp(",")) break;
        }
        return rows.items;
    }

    fn selectCore(s: *Parser) Error!*tree.Core {
        const pos = s.c.here();
        const jm = json_table.mark(s);
        try s.c.expectKw("SELECT");
        var distinct = false;
        var straight = false;
        while (true) {
            if (s.c.eatKw("DISTINCT") or s.c.eatKw("DISTINCTROW")) {
                distinct = true;
            } else if (s.c.eatKw("ALL")) {
                distinct = false;
            } else if (s.c.eatKw("STRAIGHT_JOIN")) {
                straight = true;
            } else if (s.c.eatKw("HIGH_PRIORITY") or s.c.eatKw("SQL_SMALL_RESULT") or s.c.eatKw("SQL_BIG_RESULT") or
                s.c.eatKw("SQL_BUFFER_RESULT") or s.c.eatKw("SQL_CACHE") or s.c.eatKw("SQL_NO_CACHE") or
                s.c.eatKw("SQL_CALC_FOUND_ROWS"))
            {} else break;
        }
        const cols = try s.resultColumns();
        if (s.c.isKw("INTO")) return s.c.fail(null, "xqlite: SELECT ... INTO is not supported", .{});
        var from: []tree.FromItem = &.{};
        if (s.c.eatKw("FROM")) {
            if (s.c.isKw("DUAL")) {
                s.c.skip();
            } else {
                from = try s.tableRefs();
                // SELECT STRAIGHT_JOIN: the tables are joined in order.
                if (straight) for (from[1..]) |*item| switch (item.join) {
                    .comma, .inner, .cross => item.join = .straight,
                    else => {},
                };
            }
        }
        const where: ?*Expr = if (s.c.eatKw("WHERE")) try s.expr() else null;
        var group: std.ArrayList(*Expr) = .empty;
        if (try s.c.optKws(&.{ "GROUP", "BY" })) {
            while (true) {
                try group.append(s.a, try s.expr());
                _ = s.c.eatKw("ASC") or s.c.eatKw("DESC");
                if (!s.c.eatOp(",")) break;
            }
            if (s.c.isKw("WITH") and s.c.peekAt(1).isKw("ROLLUP")) return s.c.fail(null, "xqlite: GROUP BY ... WITH ROLLUP is not supported", .{});
        }
        const having: ?*Expr = if (s.c.eatKw("HAVING")) try s.expr() else null;
        var windows: []tree.NamedWindow = &.{};
        if (s.c.eatKw("WINDOW")) windows = try s.windowDefs();
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
            if (s.c.isOp("*")) {
                try l.append(s.a, .{ .star = s.c.here() });
                s.c.skip();
            } else if ((s.c.peek().kind == .word or s.c.peek().kind == .quoted_ident) and s.c.peekAt(1).kind == .dot and s.c.peekAt(2).isOp(s.c.sql, "*")) {
                const tbl = try s.nameOf(s.c.peek());
                s.c.skip();
                s.c.skip();
                const star = s.c.here();
                s.c.skip();
                try l.append(s.a, .{ .table_star = .{ .names = try s.a.dupe(Name, &.{tbl}), .star_pos = star } });
            } else {
                const start = s.c.here();
                const e = try s.expr();
                const end = s.c.lastEnd();
                const al = try s.alias(true);
                // MariaDB names a column by the expression as written, a
                // string by its value.
                const text: ?[]const u8 = switch (e.kind) {
                    .column => null,
                    // DATABASE() is a string too.
                    .string => |v| if (std.mem.endsWith(u8, s.c.sql[start..end], ")")) s.c.sql[start..end] else v,
                    else => s.c.sql[start..end],
                };
                try l.append(s.a, .{ .expr = .{ .e = e, .alias = al, .name = if (al == null) text else null } });
            }
            if (!s.c.eatOp(",")) break;
        }
        return l.items;
    }

    /// `[AS] name` (or a string, for a column alias).
    pub fn alias(s: *Parser, string_ok: bool) Error!?Name {
        if (s.c.eatKw("AS")) {
            if (string_ok and lexer.isString(s.c.peek())) return try s.stringAlias();
            return try s.nameOf(try s.anyName());
        }
        if (s.isName()) {
            const t = s.c.peek();
            s.c.skip();
            return try s.nameOf(t);
        }
        if (string_ok and lexer.isString(s.c.peek())) return try s.stringAlias();
        return null;
    }

    /// A string as a name.
    fn stringAlias(s: *Parser) Error!Name {
        const pos = s.c.here();
        return .{ .text = try s.stringLiteral(), .pos = pos };
    }

    pub fn sortList(s: *Parser) Error![]tree.SortItem {
        return syntax.sortList(s, expr, .{});
    }

    // ----------------------------------------------------------- windows

    fn windowDefs(s: *Parser) Error![]tree.NamedWindow {
        var list: std.ArrayList(tree.NamedWindow) = .empty;
        while (true) {
            const n = try s.nameOf(try s.name());
            try s.c.expectKw("AS");
            try s.c.expectOp("(");
            const w = try s.windowSpec();
            try s.c.expectOp(")");
            try list.append(s.a, .{ .name = n, .spec = w });
            if (!s.c.eatOp(",")) break;
        }
        return list.items;
    }

    /// The inside of OVER ( ... ) or WINDOW w AS ( ... ).
    fn windowSpec(s: *Parser) Error!*tree.WindowSpec {
        var w: tree.WindowSpec = .{};
        if (s.isName() and !s.c.isKw("PARTITION") and !s.c.isKw("ORDER") and !s.c.isKw("ROWS") and !s.c.isKw("RANGE")) {
            w.base = try s.nameOf(try s.name());
        }
        try syntax.windowClauses(s, &w, additive, .{});
        return s.new(tree.WindowSpec, w);
    }

    /// `OVER (spec)` or `OVER name` after a function call.
    pub fn overClause(s: *Parser) Error!?*tree.WindowSpec {
        if (!s.c.eatKw("OVER")) return null;
        if (s.c.eatOp("(")) {
            const w = try s.windowSpec();
            try s.c.expectOp(")");
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
        if (s.c.eatOp(",")) return .{ .join = .comma };
        if (s.c.eatKw("JOIN")) return .{ .join = .inner };
        if (s.c.eatKw("STRAIGHT_JOIN")) return .{ .join = .straight };
        if (try s.c.optKws(&.{ "INNER", "JOIN" })) {
            return .{ .join = .inner };
        }
        if (try s.c.optKws(&.{ "CROSS", "JOIN" })) {
            return .{ .join = .cross };
        }
        const natural = s.c.eatKw("NATURAL");
        var j: Join = .{ .join = .inner, .natural = natural };
        if (s.c.isKw("LEFT") or s.c.isKw("RIGHT")) {
            j.join = if (s.c.isKw("LEFT")) .left else .right;
            s.c.skip();
            _ = s.c.eatKw("OUTER");
        } else if (natural) {
            _ = s.c.eatKw("INNER");
        } else return null;
        try s.c.expectKw("JOIN");
        return j;
    }

    fn onUsing(s: *Parser, item: *tree.FromItem) Error!void {
        if (s.c.eatKw("ON")) {
            item.on = try s.expr();
        } else if (s.c.eatKw("USING")) {
            try s.c.expectOp("(");
            var ids: std.ArrayList(Name) = .empty;
            while (true) {
                try ids.append(s.a, try s.nameOf(try s.name()));
                if (!s.c.eatOp(",")) break;
            }
            try s.c.expectOp(")");
            item.using = ids.items;
        }
    }

    fn aliasOf(s: *Parser) Error!?tree.Alias {
        const n = (try s.alias(false)) orelse return null;
        return .{ .name = n };
    }

    fn tableFactor(s: *Parser) Error!tree.FromItem {
        var item: tree.FromItem = .{ .source = undefined };
        if (s.c.isOp("(")) {
            const n = s.c.peekAt(1);
            if (n.isAnyKw(&.{ "SELECT", "WITH", "VALUES" })) {
                s.c.skip();
                const sub = try s.selectStmt();
                try s.c.expectOp(")");
                item.source = .{ .subquery = sub };
                item.alias = try s.aliasOf();
                try s.onUsing(&item);
                return item;
            }
            s.c.skip();
            const inner = try s.tableRefs();
            try s.c.expectOp(")");
            item.source = .{ .nested = inner };
            item.alias = try s.aliasOf();
            try s.onUsing(&item);
            return item;
        }
        const q = try s.qualifiedName();
        if (q.schema == null and s.c.isOp("(") and std.ascii.eqlIgnoreCase(q.name.text, "json_table")) {
            item = try json_table.fromItem(s, q.name.pos);
            try s.onUsing(&item);
            return item;
        }
        if (s.c.isKw("PARTITION")) return s.c.fail(null, "xqlite: PARTITION is not supported", .{});
        if (q.schema) |sch| if (std.ascii.eqlIgnoreCase(sch.text, "information_schema")) {
            const sub = (try @import("infoschema.zig").select(s, q.name.text)) orelse
                return s.c.failState(null, .numbered("42P01", 1109), "Unknown table '{s}' in information_schema", .{q.name.text});
            item.source = .{ .subquery = sub };
            item.alias = (try s.aliasOf()) orelse .{ .name = q.name };
            try s.onUsing(&item);
            return item;
        };
        if (s.c.eatOp("(")) {
            // A table-valued function (SQLite's json_each(), pragma_*()).
            const args: []*Expr = if (s.c.isOp(")")) &.{} else try s.exprList();
            try s.c.expectOp(")");
            item.source = .{ .func = try s.new(tree.Func, .{ .name = q.name, .args = args }) };
            item.alias = try s.aliasOf();
        } else {
            const r = try s.relation(q);
            item.source = .{ .table = r.q };
            item.alias = (try s.aliasOf()) orelse if (r.alias) |a| tree.Alias{ .name = a } else null;
        }
        try s.indexHints();
        try s.onUsing(&item);
        return item;
    }

    /// USE/IGNORE/FORCE {INDEX|KEY} [FOR ...] (names): accepted, ignored.
    fn indexHints(s: *Parser) Error!void {
        while (s.c.isAnyKw(&.{ "USE", "IGNORE", "FORCE" })) {
            const n = s.c.peekAt(1);
            if (!(n.isKw("INDEX") or n.isKw("KEY"))) return;
            s.c.skip();
            s.c.skip();
            if (s.c.eatKw("FOR")) {
                if (s.c.eatKw("JOIN")) {} else if (s.c.eatKw("ORDER") or s.c.eatKw("GROUP")) {
                    try s.c.expectKw("BY");
                } else return s.c.syntaxError();
            }
            try s.c.expectOp("(");
            while (!s.c.isOp(")")) {
                _ = try s.anyName();
                if (!s.c.eatOp(",")) break;
            }
            try s.c.expectOp(")");
        }
    }

    // ================================================================ DML

    /// The MariaDB metadata of a target table: its name as stored, the
    /// MariaDB type of each column (from xq_catalog; none for a table
    /// another dialect created), the AUTO_INCREMENT column.
    pub const Target = struct {
        tab: ?*int.Table,
        /// The SQLite name to write, and the alias a mangled one takes.
        q: QName = .{ .name = .{ .text = "" } },
        alias: ?Name = null,
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
    pub fn target(s: *Parser, q_in: QName) Error!Target {
        ir.stmt.readSchema(s.p) catch return error.ParseFailed;
        const r = try s.relation(q_in);
        const q = r.q;
        var tab = r.find(s.p.db) orelse return .{ .tab = null, .q = q, .alias = r.alias, .schema = "main", .cols = &.{} };
        const schema = catalog.schemaName(s.p.db, tab);
        const stored = try s.a.dupe(u8, tab.name);
        var m: ?*const catalog.TableMeta = null;
        if (catalog.exists(s.p.db, schema)) {
            m = catalog.meta(s.p.db, schema, stored) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return s.failFrom(s.p.db),
            };
            // Reading the catalog may have reloaded the schema.
            tab = build.findTable(s.p.db, stored, schema) orelse return .{ .tab = null, .q = q, .alias = r.alias, .schema = schema, .cols = &.{} };
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
            if (m) |x| {
                // Copied: a statement run while parsing may drop the
                // catalog in memory.
                if (x.declType(cols[i].name)) |t| cols[i].decl_type = try s.a.dupe(u8, t);
                cols[i].on_update = x.value(cols[i].name, "mariadb.on_update") != null;
            }
        }
        return .{ .tab = tab, .q = q, .alias = r.alias, .schema = schema, .name = stored, .cols = cols };
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
    var z = s.c.text(t)[2..];
    if (z.len > 0 and z[0] == '`') z = try lexer.quotedName(s.a, z);
    for ([_][]const u8{ "global.", "session.", "local." }) |scope| {
        if (z.len > scope.len and std.ascii.startsWithIgnoreCase(z, scope)) z = z[scope.len..];
    }
    const lname = try std.ascii.allocLowerString(s.a, z);
    if (!@import("session.zig").isSysVar(lname)) return s.c.failState(null, .numbered("42704", 1193), "Unknown system variable '{s}'", .{z});
    return lname;
}

/// The name of @name (case-insensitive: lower case).
fn userVarName(s: *Parser, t: Token) Error![]const u8 {
    var z = s.c.text(t)[1..];
    if (z.len > 0 and (z[0] == '`' or z[0] == '\'' or z[0] == '"')) {
        z = if (z[0] == '`') try lexer.quotedName(s.a, z) else try lexer.stringText(s.a, z, false);
    }
    return std.ascii.allocLowerString(s.a, z);
}
