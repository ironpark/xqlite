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
const syntax = @import("../syntax.zig");
const words = sqlparse.words;
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

/// Words that are not names where a name is optional (aliases) or
/// where they would make no sense as one (a column reference).
const reserved = words.noCase(&.{
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
});

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

    pub fn init(p: *Parse, sql: [:0]const u8, mode: state.SqlMode) Parser {
        return .{
            .p = p,
            .a = p.arena,
            .c = .{ .arena = p.arena, .sql = sql, .src = .init(.init(sql, mode)) },
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
        if (t.kind == .quoted_ident or (t.kind == .ident and !isReserved(t))) {
            s.c.skip();
            return t;
        }
        return s.c.syntaxError();
    }

    /// A name, also a reserved word (after a dot, or where only a name
    /// can come).
    pub fn anyName(s: *Parser) Error!Token {
        const t = s.c.peek();
        if (t.kind == .quoted_ident or t.kind == .ident) {
            s.c.skip();
            return t;
        }
        return s.c.syntaxError();
    }

    pub fn isName(s: *Parser) bool {
        return s.c.peek().kind == .quoted_ident or (s.c.peek().kind == .ident and !isReserved(s.c.peek()));
    }

    /// The name a name token stands for.
    pub fn nameText(s: *Parser, t: Token) Error![]const u8 {
        return lexer.identValue(s.a, t);
    }

    /// The tree name of a name token.
    pub fn nameOf(s: *Parser, t: Token) Error!Name {
        return .{ .text = try lexer.identValue(s.a, t), .pos = t.start };
    }

    /// A string literal's value (after `_charset` introducers and with
    /// adjacent literals concatenated, as MariaDB does).
    pub fn stringLiteral(s: *Parser) Error![]const u8 {
        if (s.c.peek().kind == .ident and s.c.peek().text[0] == '_' and s.c.peekAt(1).kind == .string) s.c.skip();
        if (s.c.peek().kind != .string) return s.c.syntaxError();
        var v = try lexer.stringValue(s.a, s.c.peek(), !s.mode.has(.NO_BACKSLASH_ESCAPES));
        s.c.skip();
        while (s.c.peek().kind == .string) {
            const more = try lexer.stringValue(s.a, s.c.peek(), !s.mode.has(.NO_BACKSLASH_ESCAPES));
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

    pub fn expr(s: *Parser) Error!*Expr {
        return s.orExpr();
    }

    fn bin(s: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return tree.expr(s.a, l.pos, r.end, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    fn orExpr(s: *Parser) Error!*Expr {
        var l = try s.xorExpr();
        while (s.c.isKw("OR") or (s.c.isOp("||") and !s.mode.has(.PIPES_AS_CONCAT))) {
            s.c.skip();
            l = try s.bin(.@"or", l, try s.xorExpr());
        }
        return l;
    }

    fn xorExpr(s: *Parser) Error!*Expr {
        var l = try s.andExpr();
        while (s.c.eatKw("XOR")) {
            const r = try s.andExpr();
            l = try s.func(l.pos, "xq_xor", &.{ l, r });
        }
        return l;
    }

    fn andExpr(s: *Parser) Error!*Expr {
        var l = try s.notExpr();
        while (s.c.isKw("AND") or s.c.isOp("&&")) {
            s.c.skip();
            l = try s.bin(.@"and", l, try s.notExpr());
        }
        return l;
    }

    fn notExpr(s: *Parser) Error!*Expr {
        const pos = s.c.here();
        if (s.c.eatKw("NOT")) {
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
            if (compareOp(s.c.peek())) |op| {
                s.c.skip();
                if (s.c.isAnyKw(&.{ "ANY", "SOME", "ALL" })) {
                    return s.c.fail(null, "xqlite: comparisons with ANY/SOME/ALL subqueries are not supported", .{});
                }
                const r = try s.bitOr();
                l = try s.mk(l.pos, .{ .compare = .{ .op = op, .l = try functions.jsonCompared(s, l), .r = try functions.jsonCompared(s, r) } });
                continue;
            }
            if (s.c.isKw("IS")) {
                s.c.skip();
                const not = s.c.eatKw("NOT");
                if (s.c.eatKw("NULL") or s.c.eatKw("UNKNOWN")) {
                    l = try s.mk(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                } else if (s.c.isKw("TRUE") or s.c.isKw("FALSE")) {
                    const v = s.c.isKw("TRUE");
                    s.c.skip();
                    l = try s.mk(l.pos, .{ .is_bool = .{ .e = l, .value = v, .not = not } });
                } else return s.c.syntaxError();
                continue;
            }
            var not = false;
            if (s.c.isKw("NOT")) {
                const n = s.c.peekAt(1);
                if (!n.isAnyKw(&.{ "LIKE", "IN", "BETWEEN", "REGEXP", "RLIKE" })) break;
                s.c.skip();
                not = true;
            }
            if (s.c.isKw("LIKE")) {
                const op_pos = s.c.here();
                s.c.skip();
                const r = try s.bitOr();
                // The escape character is \ unless ESCAPE says.
                const esc = if (s.c.eatKw("ESCAPE")) try s.primaryWithCollate() else try s.mk(op_pos, .{ .string = "\\" });
                l = try s.mk(l.pos, .{ .like = .{ .e = l, .pat = r, .not = not, .case_sensitive = false, .escape = .{ .expr = esc } } });
                continue;
            }
            if (s.c.isKw("REGEXP") or s.c.isKw("RLIKE")) {
                const op_pos = s.c.here();
                s.c.skip();
                const r = try s.bitOr();
                const f = try s.new(tree.Func, .{ .name = .{ .text = "regexp", .pos = op_pos }, .args = try s.a.dupe(*Expr, &.{ r, l }) });
                l = try s.mk(l.pos, .{ .func = f });
                if (not) l = try s.mk(l.pos, .{ .unary = .{ .op = .not, .e = l } });
                continue;
            }
            if (s.c.eatKw("IN")) {
                try s.c.expectOp("(");
                if (s.isSelectStart()) {
                    const sub = try s.selectStmt();
                    try s.c.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = sub } });
                } else {
                    const items = try s.exprList();
                    try s.c.expectOp(")");
                    l = try s.mk(l.pos, .{ .in_list = .{ .e = try functions.jsonCompared(s, l), .not = not, .items = items } });
                }
                continue;
            }
            if (s.c.eatKw("BETWEEN")) {
                const lo = try s.bitOr();
                try s.c.expectKw("AND");
                const hi = try s.bitOr();
                l = try s.mk(l.pos, .{ .between = .{ .e = l, .not = not, .lo = lo, .hi = hi } });
                continue;
            }
            if (s.c.isKw("SOUNDS")) return s.c.fail(null, "xqlite: SOUNDS LIKE is not supported", .{});
            break;
        }
        return l;
    }

    pub fn bitOr(s: *Parser) Error!*Expr {
        var l = try s.bitAnd();
        while (s.c.eatOp("|")) l = try s.bin(.bit_or, l, try s.bitAnd());
        return l;
    }

    fn bitAnd(s: *Parser) Error!*Expr {
        var l = try s.shift();
        while (s.c.eatOp("&")) l = try s.bin(.bit_and, l, try s.shift());
        return l;
    }

    fn shift(s: *Parser) Error!*Expr {
        var l = try s.additive();
        while (s.c.isOp("<<") or s.c.isOp(">>")) {
            const op: tree.BinOp = if (s.c.isOp("<<")) .shl else .shr;
            s.c.skip();
            l = try s.bin(op, l, try s.additive());
        }
        return l;
    }

    fn additive(s: *Parser) Error!*Expr {
        var l = if (s.c.isKw("INTERVAL") and !s.c.peekAt(1).is("(")) blk: {
            // INTERVAL n unit + date
            const pos = s.c.here();
            const iv = try s.interval();
            try s.c.expectOp("+");
            const d = try s.multiplicative();
            break :blk try s.dateAdd(pos, d, iv.n, iv.unit, false);
        } else try s.multiplicative();
        while (s.c.isOp("+") or s.c.isOp("-")) {
            const minus = s.c.isOp("-");
            s.c.skip();
            if (s.c.isKw("INTERVAL")) {
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
        try s.c.expectKw("INTERVAL");
        const n = try s.expr();
        if (s.c.peek().kind != .ident) return s.c.syntaxError();
        const unit = s.c.peek().text;
        s.c.skip();
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
            if (s.c.eatOp("*")) {
                l = try s.bin(.mul, l, try s.bitXor());
            } else if (s.c.eatOp("/")) {
                const r = try s.bitXor();
                l = try s.mk(l.pos, .{ .div = .{ .kind = .real, .l = l, .r = r } });
            } else if (s.c.eatOp("%") or s.c.eatKw("MOD")) {
                l = try s.bin(.rem, l, try s.bitXor());
            } else if (s.c.eatKw("DIV")) {
                const r = try s.bitXor();
                l = try s.mk(l.pos, .{ .div = .{ .kind = .int, .l = l, .r = r } });
            } else break;
        }
        return l;
    }

    fn bitXor(s: *Parser) Error!*Expr {
        var l = try s.concat();
        while (s.c.eatOp("^")) {
            const r = try s.concat();
            l = try s.func(l.pos, "xq_bitxor", &.{ l, r });
        }
        return l;
    }

    fn concat(s: *Parser) Error!*Expr {
        const l = try s.unary();
        if (!(s.mode.has(.PIPES_AS_CONCAT) and s.c.isOp("||"))) return l;
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(s.a, l);
        while (s.mode.has(.PIPES_AS_CONCAT) and s.c.eatOp("||")) try args.append(s.a, try s.unary());
        return s.mk(l.pos, .{ .concat = .{ .args = args.items, .null_policy = .propagate } });
    }

    fn unary(s: *Parser) Error!*Expr {
        const pos = s.c.here();
        if (s.c.isOp("-") or s.c.isOp("+")) {
            const minus = s.c.isOp("-");
            s.c.skip();
            const e = try s.unary();
            if (!minus) return e;
            return s.mk(pos, .{ .unary = .{ .op = .neg, .e = e } });
        }
        if (s.c.eatOp("~")) return s.mk(pos, .{ .unary = .{ .op = .bit_not, .e = try s.unary() } });
        if (s.c.eatOp("!")) return s.mk(pos, .{ .unary = .{ .op = .not, .e = try s.unary() } });
        if (s.c.isKw("BINARY") and !s.c.peekAt(1).is("(")) {
            s.c.skip();
            return s.mk(pos, .{ .collate = .{ .e = try s.unary(), .collation = "BINARY" } });
        }
        return s.primaryWithCollate();
    }

    fn primaryWithCollate(s: *Parser) Error!*Expr {
        var e = try s.primary();
        // col->'path', col->>'path' (MySQL's; MariaDB has neither).
        while (s.c.isOp("->") or s.c.isOp("->>")) {
            const text = s.c.isOp("->>");
            const pos = s.c.here();
            s.c.skip();
            const path = try s.mk(s.c.here(), .{ .string = try s.stringLiteral() });
            e = try s.func(pos, "json_extract", &.{ e, path });
            if (text) e = try s.func(pos, "json_unquote", &.{e});
        }
        while (s.c.eatKw("COLLATE")) {
            const coll = try s.collationName();
            e = try s.mk(e.pos, .{ .collate = .{ .e = e, .collation = coll } });
        }
        return e;
    }

    /// The SQLite collation for a MariaDB collation name (after COLLATE).
    pub fn collationName(s: *Parser) Error![:0]const u8 {
        const t = s.c.peek();
        if (t.kind != .ident and t.kind != .quoted_ident and t.kind != .string) return s.c.syntaxError();
        const n = if (t.kind == .string) try lexer.stringValue(s.a, t, false) else try s.nameText(t);
        s.c.skip();
        return mapCollation(n) orelse s.c.failState(null, .numbered("42704", 1273), "Unknown collation: '{s}'", .{n});
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
        return s.c.isKw("SELECT") or s.c.isKw("WITH") or (s.c.isOp("(") and isSelectish(s.c.peekAt(1))) or s.c.isKw("VALUES");
    }

    fn isSelectish(t: Token) bool {
        return t.isKw("SELECT") or t.isKw("WITH") or t.is("(");
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
        switch (t.kind) {
            .string => {
                const v = try s.stringLiteral();
                if (v.len == 0 and s.mode.has(.EMPTY_STRING_IS_NULL)) return s.mk(pos, .null);
                return s.mk(pos, .{ .string = v });
            },
            .integer => {
                s.c.skip();
                return s.mk(pos, .{ .integer = t.text });
            },
            .float => {
                s.c.skip();
                return s.mk(pos, .{ .float = t.text });
            },
            .hex => {
                s.c.skip();
                const digits = (try lexer.hexDigits(s.a, t)) orelse return s.c.syntaxErrorAt(t);
                return s.mk(pos, .{ .blob = digits });
            },
            .bit => {
                s.c.skip();
                const v = lexer.bitValue(t) orelse return s.c.failState(null, .of("22003"), "bit literal out of range", .{});
                if (v < 0) return s.int_(pos, v);
                return s.mk(pos, .{ .integer = try std.fmt.allocPrint(s.a, "{d}", .{v}) });
            },
            .param => {
                try s.refuseStored(t.text);
                s.c.skip();
                return s.mk(pos, .{ .param = null });
            },
            .sys_var => {
                try s.refuseStored(t.text);
                s.c.skip();
                const name_ = try sysVarName(s, t);
                return s.func(pos, "xq_sysvar", &.{try s.str(pos, name_)});
            },
            .user_var => {
                try s.refuseStored(t.text);
                s.c.skip();
                const name_ = try userVarName(s, t);
                if (s.c.eatOp(":=")) {
                    const v = try s.expr();
                    return s.func(pos, "xq_set_uservar", &.{ try s.str(pos, name_), v });
                }
                return s.func(pos, "xq_uservar", &.{try s.str(pos, name_)});
            },
            .op => {
                if (t.is("(")) return s.parenthesized();
                if (t.is("{")) {
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
            .ident => return s.wordExpr(),
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
        if (t.isKw("DEFAULT") and s.allow_default and !next.is("(")) {
            s.c.skip();
            return s.mk(pos, .default);
        }
        if (t.isAnyKw(&.{ "DATE", "TIME", "TIMESTAMP" }) and next.kind == .string) {
            // DATE '2024-01-01' and the like: the string.
            s.c.skip();
            return s.primary();
        }
        if (t.text[0] == '_' and next.kind == .string) return s.primary();
        if (t.isKw("INTERVAL") and !next.is("(")) {
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
        if (next.is("(")) return @import("functions.zig").call(s);
        // Niladic functions.
        const niladic = [_]struct { []const u8, []const u8 }{
            .{ "CURRENT_TIMESTAMP", "now" }, .{ "LOCALTIME", "now" },        .{ "LOCALTIMESTAMP", "now" },
            .{ "CURRENT_DATE", "curdate" },  .{ "CURRENT_TIME", "curtime" }, .{ "UTC_TIMESTAMP", "now" },
            .{ "UTC_DATE", "curdate" },      .{ "UTC_TIME", "curtime" },     .{ "CURRENT_USER", "current_user" },
        };
        for (niladic) |n| if (t.isKw(n[0])) {
            s.c.skip();
            return @import("functions.zig").byName(s, n[1], &.{}, pos);
        };
        if (isReserved(t)) return s.c.syntaxError();
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
            } else if ((s.c.peek().kind == .ident or s.c.peek().kind == .quoted_ident) and s.c.peekAt(1).is(".") and s.c.peekAt(2).is("*")) {
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
            if (string_ok and s.c.peek().kind == .string) return try s.stringAlias();
            return try s.nameOf(try s.anyName());
        }
        if (s.isName()) {
            const t = s.c.peek();
            s.c.skip();
            return try s.nameOf(t);
        }
        if (string_ok and s.c.peek().kind == .string) return try s.stringAlias();
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
    var z = t.text[2..];
    if (z.len > 0 and z[0] == '`') z = try lexer.identValue(s.a, .{ .kind = .quoted_ident, .text = z });
    for ([_][]const u8{ "global.", "session.", "local." }) |scope| {
        if (z.len > scope.len and std.ascii.startsWithIgnoreCase(z, scope)) z = z[scope.len..];
    }
    const lname = try std.ascii.allocLowerString(s.a, z);
    if (!@import("session.zig").isSysVar(lname)) return s.c.failState(null, .numbered("42704", 1193), "Unknown system variable '{s}'", .{z});
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
