//! A recursive descent parser for the Oracle statements the dialect
//! supports (see docs/oracle.md), producing the syntax tree IR
//! (src/ir/tree.zig) with Oracle's semantics resolved:
//!
//!  - names: unquoted identifiers folded to upper case (lexer.zig);
//!    schemas are users: MAIN (and SYS) is main, an attached database
//!    itself, a user of CREATE USER main with the mangled name "U.T" of
//!    catalog/schema.zig (aliased T); unqualified names resolve in the
//!    current schema (ALTER SESSION SET CURRENT_SCHEMA, session.zig);
//!    DUAL is no table; the data dictionary views (USER_TABLES ...) are
//!    the queries of catalog_views.zig;
//!  - the empty string is NULL: a '' literal is NULL, `||` and CONCAT
//!    skip NULLs and are NULL when the result is '' (concat{skip} in
//!    nullif(..., '')), the dialect's string functions return NULL for
//!    '' (funcs.zig), and values stored into columns go through
//!    xq_ora_coerce() (dml.zig);
//!  - `/` divides as reals; LIKE is case-sensitive without an escape;
//!    NVL, NVL2, DECODE are COALESCE and CASEs; functions map to the
//!    dialect's (funcs.zig) or SQLite's; SYSDATE/SYSTIMESTAMP are the
//!    statement's time as text; date + n and date - date are julianday()
//!    arithmetic where the parser knows an operand is a date (dates.zig);
//!  - ROWNUM in WHERE is a LIMIT, elsewhere row_number() OVER (); the
//!    (+) outer join marks become LEFT (or RIGHT) JOINs; s.NEXTVAL and
//!    s.CURRVAL are nextval('S') and currval('S');
//!  - ORDER BY without NULLS FIRST/LAST puts NULLs last ascending and
//!    first descending, as Oracle does;
//!  - result columns without an alias are named as Oracle names them: a
//!    column after the column, else the expression's text in upper case
//!    without blanks;
//!  - DDL: types mapped to STRICT storage with the checks of types.zig,
//!    GENERATED ... AS IDENTITY to tree.Identity columns.
//!
//! Operator precedence is Oracle's (lowest first): OR, AND, NOT,
//! comparison and IS/LIKE/BETWEEN/IN, + - ||, * /, unary + -.
//!
//! A statement is lexed up to its terminating semicolon (or `/` line)
//! first, so lookahead never fails; `end` is the offset after it.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const ir = @import("../../ir/ir.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const Dialect = @import("../dialect.zig").Dialect;
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const views = @import("catalog_views.zig");
const datetime = @import("datetime.zig");
const jsonsql = @import("jsonsql.zig");
const ora_state = @import("state.zig");
const nsp = catalog.schemas;

const Token = lexer.Token;
const Name = tree.Name;
const Expr = tree.Expr;
const Allocator = std.mem.Allocator;

pub const Error = error{ ParseFailed, OutOfMemory };

/// A set of (upper-case) words.
fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(20_000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

/// Oracle's reserved words (V$RESERVED_WORDS), which cannot name a
/// column or table unquoted.
const reserved = wordSet(&.{
    "ACCESS",     "ADD",      "ALL",        "ALTER",    "AND",        "ANY",        "AS",        "ASC",
    "AUDIT",      "BETWEEN",  "BY",         "CHAR",     "CHECK",      "CLUSTER",    "COLUMN",    "COMMENT",
    "COMPRESS",   "CONNECT",  "CREATE",     "CURRENT",  "DATE",       "DECIMAL",    "DEFAULT",   "DELETE",
    "DESC",       "DISTINCT", "DROP",       "ELSE",     "EXCLUSIVE",  "EXISTS",     "FILE",      "FLOAT",
    "FOR",        "FROM",     "GRANT",      "GROUP",    "HAVING",     "IDENTIFIED", "IMMEDIATE", "IN",
    "INCREMENT",  "INDEX",    "INITIAL",    "INSERT",   "INTEGER",    "INTERSECT",  "INTO",      "IS",
    "LEVEL",      "LIKE",     "LOCK",       "LONG",     "MAXEXTENTS", "MINUS",      "MLSLABEL",  "MODE",
    "MODIFY",     "NOAUDIT",  "NOCOMPRESS", "NOT",      "NOWAIT",     "NULL",       "NUMBER",    "OF",
    "OFFLINE",    "ON",       "ONLINE",     "OPTION",   "OR",         "ORDER",      "PCTFREE",   "PRIOR",
    "PUBLIC",     "RAW",      "RENAME",     "RESOURCE", "REVOKE",     "ROW",        "ROWID",     "ROWNUM",
    "ROWS",       "SELECT",   "SESSION",    "SET",      "SHARE",      "SIZE",       "SMALLINT",  "START",
    "SUCCESSFUL", "SYNONYM",  "SYSDATE",    "TABLE",    "THEN",       "TO",         "TRIGGER",   "UID",
    "UNION",      "UNIQUE",   "UPDATE",     "USER",     "VALIDATE",   "VALUES",     "VARCHAR",   "VARCHAR2",
    "VIEW",       "WHENEVER", "WHERE",      "WITH",
});

/// Words that may not be a bare alias (reserved words and the keywords
/// that may follow a FROM item or a result column).
const not_alias = wordSet(&.{
    "JOIN",  "INNER",   "LEFT",      "RIGHT",  "FULL",  "OUTER",     "CROSS", "NATURAL", "USING",
    "FETCH", "OFFSET",  "RETURNING", "RETURN", "CASE",  "WHEN",      "END",   "WINDOW",  "EXCEPT",
    "PIVOT", "UNPIVOT", "MODEL",     "SAMPLE", "LIMIT", "PARTITION", "LOG",   "KEEP",    "APPLY",
});

pub fn isReserved(word: []const u8) bool {
    return reserved.has(word);
}

fn noAlias(word: []const u8) bool {
    return reserved.has(word) or not_alias.has(word);
}

/// The error of a statement that does not lex (Parser.init()).
pub const LexError = struct {
    msg: []const u8 = "",
    pos: usize = 0,
};

/// `[schema.]name` as written.
pub const QName = struct {
    schema: ?Name = null,
    name: Name,
};

/// A function call as written, before it is resolved (callExpr()).
const Call = struct {
    name: Name,
    args: []*Expr = &.{},
    star: bool = false,
    distinct: bool = false,
    order_by: []tree.SortItem = &.{},
    filter: ?*Expr = null,
    over: ?*tree.WindowSpec = null,
};

/// A statement as the frontend lowers it: a tree statement, or one
/// lowered as several (MERGE, INSERT ALL), or one with nothing to run.
pub const Statement = union(enum) {
    tree: tree.Stmt,
    /// Statements run in turn as one (MERGE, INSERT ALL, ALTER TABLE ...
    /// ADD (a, b)).
    multi: []tree.Stmt,
    /// DDL statements run in turn as one, each checked (CREATE SCHEMA).
    ddl: []tree.Stmt,
    /// COMMENT ON: a catalog entry.
    comment: struct { table: tree.QName, column: ?Name, text: ?[]const u8 },
    /// Accepted and ignored (SET TRANSACTION, ALTER SESSION, LOCK TABLE).
    noop,
};

pub const Kind = enum { none, date, timestamp };

pub const Parser = struct {
    arena: Allocator,
    src: [:0]const u8,
    toks: []Token,
    i: usize = 0,
    err_msg: []const u8 = "",
    err_pos: usize = 0,
    /// Offset after the statement (and its terminator).
    end: usize,
    /// The statement being compiled, for what depends on the schema.
    p: ?*int.Parse = null,
    /// The error is in `p` already (the schema could not be read).
    err_in_parse: bool = false,
    schema_read: bool = false,
    /// The registered schemas (catalog/schema.zig), read once.
    schemas: ?[]const nsp.Info = null,
    /// The names of the WITH queries of the statement: an unqualified
    /// relation with one of these names is not looked up in the current
    /// schema.
    cte_names: std.ArrayList([]const u8) = .empty,
    /// The table CREATE TABLE creates (its REFERENCES may name it).
    creating: ?nsp.Target = null,
    /// Unqualified names stay as written (the text of a data dictionary
    /// view).
    no_schema: bool = false,
    /// The statement is an element of CREATE SCHEMA: CREATE and GRANT end
    /// a CREATE TABLE.
    schema_element: bool = false,
    /// Column references marked (+).
    outer_marks: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    /// The LIMIT a WHERE ROWNUM <= n puts on its query.
    rownum_limits: std.AutoHashMapUnmanaged(*const tree.Core, *Expr) = .empty,
    /// The query whose FROM is parsed selects `*`: DUAL is a row then.
    dual_star: bool = false,
    /// The nullif(concat(...), '') nodes of `||` and CONCAT.
    concat_nodes: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    /// The row_number() OVER () nodes of ROWNUM.
    rownum_nodes: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    /// The names of result columns that are pseudo-columns (s.NEXTVAL is
    /// NEXTVAL).
    pseudo_names: std.AutoHashMapUnmanaged(*const Expr, []const u8) = .empty,
    /// The sequences whose NEXTVAL the current row (select list, VALUES
    /// row, SET list) has used: a second NEXTVAL is the same value
    /// (currval()), as Oracle increments a sequence once per row.
    nextval_seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Expressions the parser made that are dates or timestamps.
    date_nodes: std.AutoHashMapUnmanaged(*const Expr, Kind) = .empty,
    /// The declared types of the tables looked at (dates.zig).
    decl_types: std.StringHashMapUnmanaged([]const catalog.Entry) = .empty,
    /// JSON (jsonsql.zig): the values given to JSON constructors, the
    /// JSON_VALUE calls, dot notation placeholders, JSON_OBJECT(*) calls,
    /// the JSON_TABLEs of FROM and the queries whose references to them
    /// are rewritten.
    json_values: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    json_text_nodes: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    dot_nodes: std.AutoHashMapUnmanaged(*const Expr, jsonsql.Dot) = .empty,
    json_object_star: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    jt_items: std.AutoHashMapUnmanaged(*const tree.Func, *jsonsql.Table) = .empty,
    jt_done: std.AutoHashMapUnmanaged(*const tree.Core, void) = .empty,
    jt_count: u32 = 0,

    /// Lex the statement that starts at `pos` (blank text and leading
    /// semicolons are skipped). An empty statement has no tokens but eof.
    pub fn init(arena: Allocator, src: [:0]const u8, pos: usize, lex_error: ?*LexError) Error!Parser {
        var l = lexer.Lexer.init(arena, src, pos);
        var toks: std.ArrayList(Token) = .empty;
        var end: usize = src.len;
        while (true) {
            const t = l.next() catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.LexFailed => {
                    if (lex_error) |e| e.* = .{ .msg = l.err_msg, .pos = l.err_pos };
                    return error.ParseFailed;
                },
            };
            if (t.kind == .semi) {
                if (toks.items.len == 0) continue;
                end = t.end;
                try toks.append(arena, .{ .kind = .eof, .start = t.start, .end = t.start, .text = "" });
                break;
            }
            try toks.append(arena, t);
            if (t.kind == .eof) break;
        }
        return .{ .arena = arena, .src = src, .toks = toks.items, .end = end };
    }

    pub fn isEmpty(p: *const Parser) bool {
        return p.toks.len == 0 or p.toks[0].kind == .eof;
    }

    // ------------------------------------------------------------ tokens

    pub fn peek(p: *const Parser) Token {
        return p.toks[p.i];
    }

    pub fn peekAt(p: *const Parser, k: usize) Token {
        const j = @min(p.i + k, p.toks.len - 1);
        return p.toks[j];
    }

    pub fn advance(p: *Parser) Token {
        const t = p.toks[p.i];
        if (t.kind != .eof) p.i += 1;
        return t;
    }

    pub fn lastEnd(p: *const Parser) u32 {
        return if (p.i == 0) p.toks[0].start else p.toks[p.i - 1].end;
    }

    pub fn isKw(p: *const Parser, kw: []const u8) bool {
        return p.peek().isKw(kw);
    }

    pub fn isKwAt(p: *const Parser, k: usize, kw: []const u8) bool {
        return p.peekAt(k).isKw(kw);
    }

    pub fn eatKw(p: *Parser, kw: []const u8) bool {
        if (!p.isKw(kw)) return false;
        _ = p.advance();
        return true;
    }

    pub fn expectKw(p: *Parser, kw: []const u8) Error!void {
        if (!p.eatKw(kw)) return p.missing("ORA-00905: missing keyword");
    }

    pub fn isAnyKw(p: *const Parser, comptime kws: []const []const u8) bool {
        return p.peek().isAnyKw(kws);
    }

    pub fn ifExists(p: *Parser) Error!bool {
        if (!(p.isKw("if") and p.isKwAt(1, "exists"))) return false;
        _ = p.advance();
        _ = p.advance();
        return true;
    }

    pub fn ifNotExists(p: *Parser) Error!bool {
        if (!(p.isKw("if") and p.isKwAt(1, "not"))) return false;
        _ = p.advance();
        _ = p.advance();
        try p.expectKw("exists");
        return true;
    }

    pub fn eat(p: *Parser, kind: lexer.Kind) bool {
        if (p.peek().kind != kind) return false;
        _ = p.advance();
        return true;
    }

    pub fn expect(p: *Parser, kind: lexer.Kind) Error!Token {
        if (p.peek().kind != kind) {
            return switch (kind) {
                .rparen => p.missing("ORA-00907: missing right parenthesis"),
                .lparen => p.missing("ORA-00906: missing left parenthesis"),
                .comma => p.missing("ORA-00917: missing comma"),
                else => p.syntaxError(),
            };
        }
        return p.advance();
    }

    pub fn isOp(p: *const Parser, op: []const u8) bool {
        return p.peek().isOp(op);
    }

    pub fn eatOp(p: *Parser, op: []const u8) bool {
        if (!p.isOp(op)) return false;
        _ = p.advance();
        return true;
    }

    pub fn fail(p: *Parser, pos: usize, comptime fmt: []const u8, args: anytype) Error {
        p.err_pos = pos;
        p.err_msg = try std.fmt.allocPrint(p.arena, fmt, args);
        return error.ParseFailed;
    }

    /// An Oracle error at the next token.
    pub fn missing(p: *Parser, msg: []const u8) Error {
        return p.fail(p.peek().start, "{s}", .{msg});
    }

    /// The error of an unexpected token: ORA-00933 when a statement could
    /// have ended there, else ORA-00936 (an expression is missing).
    pub fn syntaxError(p: *Parser) Error {
        const t = p.peek();
        if (t.kind == .eof) return p.missing("ORA-00936: missing expression");
        return p.missing("ORA-00933: SQL command not properly ended");
    }

    pub fn unsupported(p: *Parser, pos: usize, what: []const u8) Error {
        return p.fail(pos, "xqlite: {s} is not supported", .{what});
    }

    pub fn new(p: *Parser, comptime T: type, v: T) Error!*T {
        return tree.new(p.arena, T, v);
    }

    pub fn expr(p: *Parser, pos: u32, kind: tree.Kind) Error!*Expr {
        return tree.expr(p.arena, pos, @max(pos, p.lastEnd()), kind);
    }

    fn span(p: *Parser, l: *const Expr, r: *const Expr, kind: tree.Kind) Error!*Expr {
        return tree.expr(p.arena, l.pos, r.end, kind);
    }

    pub fn list(p: *Parser, items: []const *Expr) Error![]*Expr {
        return p.arena.dupe(*Expr, items);
    }

    // ------------------------------------------------------------ schema

    pub fn readSchema(p: *Parser) Error!void {
        if (p.schema_read) return;
        const ps = p.p orelse return;
        p.schema_read = true;
        ir.stmt.readSchema(ps) catch {
            p.err_in_parse = true;
            return error.ParseFailed;
        };
    }

    /// The registered schemas (catalog/schema.zig: the users of CREATE
    /// USER), read once per statement; none without the statement.
    pub fn registered(p: *Parser) Error![]const nsp.Info {
        if (p.schemas) |l| return l;
        const ps = p.p orelse return &.{};
        try p.readSchema();
        const l = nsp.list(ps.db, p.arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return p.fail(0, "{s}", .{@import("../../sql/main.zig").errmsg(ps.db)}),
        };
        p.schemas = l;
        return l;
    }

    /// The user's schema is main.
    pub const schema_config: nsp.Config = .{ .default_schema = ora_state.user };

    /// The current schema (ALTER SESSION SET CURRENT_SCHEMA) when it is
    /// not the user's, else null.
    pub fn currentSchema(p: *const Parser) ?[]const u8 {
        if (p.no_schema) return null;
        const ps = p.p orelse return null;
        return ps.db.xq.oracle.current_schema;
    }

    /// What a missing schema fails as.
    pub const Missing = enum { table, user, user_or_role, sequence, index };

    fn noSchema(p: *Parser, s: Name, n: Name, m: Missing) Error {
        return switch (m) {
            .table => p.fail(s.pos, "ORA-00942: table or view \"{s}\".\"{s}\" does not exist", .{ s.text, n.text }),
            .user => p.fail(s.pos, "ORA-01918: user '{s}' does not exist", .{s.text}),
            .user_or_role => p.fail(s.pos, "ORA-01917: user or role '{s}' does not exist", .{s.text}),
            .sequence => p.fail(s.pos, "ORA-02289: sequence does not exist", .{}),
            .index => p.fail(s.pos, "ORA-01418: specified index does not exist", .{}),
        };
    }

    /// The SQLite object of `s.n`, null if `s` is no schema: the user's
    /// (MAIN, and SYS, whose objects are the data dictionary and DUAL)
    /// is main, an attached database (or TEMP) itself, a user of CREATE
    /// USER main with the mangled name "S.N".
    pub fn schemaTarget(p: *Parser, s: Name, n: Name) Error!?nsp.Target {
        if (std.ascii.eqlIgnoreCase(s.text, "SYS")) return .{ .db = "main", .name = n.text, .bare = n.text };
        const ps = p.p orelse return .{ .db = "main", .name = n.text, .bare = n.text };
        try p.readSchema();
        return nsp.resolve(ps.db, p.arena, try p.registered(), schema_config, s.text, n.text) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NoSuchSchema => null,
        };
    }

    /// `s.n` resolved (schemaTarget()); no schema fails as `m` says.
    pub fn qualified(p: *Parser, s: Name, n: Name, m: Missing) Error!nsp.Target {
        return (try p.schemaTarget(s, n)) orelse p.noSchema(s, n, m);
    }

    pub const Lookup = enum { relation, index, sequence };

    /// An unqualified name: null (as written) when the current schema is
    /// the user's, for a WITH query, a temporary table and DUAL; else
    /// the object of the current schema (whether it exists or not).
    pub fn unqualified(p: *Parser, n: Name, kind: Lookup) Error!?nsp.Target {
        const cur = p.currentSchema() orelse return null;
        const ps = p.p.?;
        if (kind == .relation) for (p.cte_names.items) |c| if (std.mem.eql(u8, c, n.text)) return null;
        try p.readSchema();
        if (kind != .sequence and objectExists(ps.db, kind, "temp", n.text)) return null;
        const m = try nsp.mangle(p.arena, cur, n.text);
        if (kind == .relation and std.mem.eql(u8, n.text, "DUAL") and !objectExists(ps.db, .relation, "main", m)) return null;
        return .{ .db = "main", .name = m, .mangled = true, .bare = n.text };
    }

    /// A name resolved, and the alias a mangled one takes (so that
    /// `t.col` finds it).
    pub const Rel = struct { q: tree.QName, alias: ?Name = null };

    /// `q` resolved: a mangled name is written without its database
    /// (main), aliased with its bare name.
    pub fn lookup(p: *Parser, q: QName, kind: Lookup) Error!Rel {
        if (q.schema) |s| {
            const t = try p.qualified(s, q.name, switch (kind) {
                .relation => .table,
                .index => .index,
                .sequence => .sequence,
            });
            if (t.mangled) return .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name };
            return .{ .q = .{ .schema = .{ .text = t.db, .pos = s.pos }, .name = q.name } };
        }
        if (try p.unqualified(q.name, kind)) |t| return .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name };
        return .{ .q = .{ .name = q.name } };
    }

    /// The table (or view) `q` of a query or DML statement.
    pub fn relation(p: *Parser, q: QName) Error!Rel {
        return p.lookup(q, .relation);
    }

    pub const Created = struct { t: nsp.Target, schema: ?Name };

    /// Where DDL creates object `q`: its schema (`no_user` says the
    /// error if there is no such user: ORA-01918 for a table, ORA-01917
    /// for a view or sequence), else temp for a temporary table, else the current
    /// schema. `schema` is null for an unqualified name of the user's
    /// schema (written as it is).
    pub fn createTarget(p: *Parser, q: QName, temp: bool, no_user: Missing) Error!Created {
        if (q.schema) |s| {
            const t = try p.qualified(s, q.name, no_user);
            if (temp and t.mangled) return p.unsupported(s.pos, "a temporary table in another user's schema");
            return .{ .t = t, .schema = .{ .text = t.db, .pos = s.pos } };
        }
        const plain: nsp.Target = .{ .db = if (temp) "temp" else "main", .name = q.name.text, .bare = q.name.text };
        if (temp) return .{ .t = plain, .schema = null };
        const cur = p.currentSchema() orelse return .{ .t = plain, .schema = null };
        const s = nsp.find(try p.registered(), cur) orelse return p.fail(q.name.pos, "ORA-01435: user does not exist", .{});
        const t: nsp.Target = .{ .db = "main", .name = try nsp.mangle(p.arena, s.name, q.name.text), .mangled = true, .bare = q.name.text };
        return .{ .t = t, .schema = .{ .text = "main", .pos = q.name.pos } };
    }

    /// The prefix "S." of a mangled name ("" for none).
    pub fn prefixOf(t: nsp.Target) []const u8 {
        return if (t.mangled) t.name[0 .. t.name.len - t.bare.len] else "";
    }

    /// The prefix "S." of a resolved name ("" for none).
    pub fn relPrefix(r: Rel) []const u8 {
        const a = r.alias orelse return "";
        return r.q.name.text[0 .. r.q.name.text.len - a.text.len];
    }

    /// The table `q` names, if it exists.
    pub fn findTable(p: *Parser, q: tree.QName) Error!?*int.Table {
        const ps = p.p orelse return null;
        try p.readSchema();
        return build.findTable(ps.db, q.name.text, if (q.schema) |s| s.text else null);
    }

    /// The query standing for a data dictionary view (null: not one).
    fn catalogView(p: *Parser, q: QName) Error!?*tree.Select {
        const ps = p.p orelse return null;
        try p.readSchema();
        if (q.schema) |s| if (!std.ascii.eqlIgnoreCase(s.text, "SYS")) return null;
        if (build.findTable(ps.db, q.name.text, null) != null) return null;
        if (q.schema == null) if (try p.unqualified(q.name, .relation)) |t| if (build.findTable(ps.db, t.name, "main") != null) return null;
        const text = (try views.definition(ps, q.name.text)) orelse return null;
        var sub = Parser.init(p.arena, text, 0, null) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => return p.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text}),
        };
        sub.p = ps;
        sub.schema_read = true;
        sub.no_schema = true;
        const sel = sub.select() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => {
                if (sub.err_in_parse) {
                    p.err_in_parse = true;
                    return error.ParseFailed;
                }
                return p.fail(q.name.pos, "internal error in the definition of {s}: {s}", .{ q.name.text, sub.err_msg });
            },
        };
        if (sub.peek().kind != .eof) return p.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text});
        sel.src = text;
        return sel;
    }

    // ------------------------------------------------------------- names

    /// A column or table name: a quoted identifier or an unquoted word
    /// that is not reserved.
    pub fn colId(p: *Parser) Error!Name {
        const t = p.peek();
        if (t.kind == .qident or (t.kind == .ident and !isReserved(t.text))) {
            _ = p.advance();
            return .{ .text = t.text, .pos = t.start };
        }
        if (t.kind == .ident) return p.missing("ORA-00904: : invalid identifier");
        return p.syntaxError();
    }

    /// Any identifier, reserved or not (after AS, after a dot).
    pub fn anyName(p: *Parser) Error!Name {
        const t = p.peek();
        if (t.kind == .qident or t.kind == .ident) {
            _ = p.advance();
            return .{ .text = t.text, .pos = t.start };
        }
        return p.syntaxError();
    }

    pub fn qname(p: *Parser) Error!QName {
        const first = try p.colId();
        if (p.peek().kind == .dot) {
            _ = p.advance();
            const second = try p.anyName();
            return .{ .schema = first, .name = second };
        }
        return .{ .name = first };
    }

    pub fn nameList(p: *Parser) Error![]Name {
        var out: std.ArrayList(Name) = .empty;
        while (true) {
            try out.append(p.arena, try p.colId());
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    pub fn parenNameList(p: *Parser) Error![]Name {
        _ = try p.expect(.lparen);
        const l = try p.nameList();
        _ = try p.expect(.rparen);
        return l;
    }

    pub fn signedInt(p: *Parser) Error!i64 {
        var neg = false;
        if (p.eatOp("-")) neg = true else _ = p.eatOp("+");
        const t = p.peek();
        if (t.kind != .integer) return p.missing("ORA-01722: invalid number");
        _ = p.advance();
        const v = std.fmt.parseInt(i64, t.text, 10) catch return p.fail(t.start, "ORA-01426: numeric overflow", .{});
        return if (neg) -v else v;
    }

    // ============================================================ SELECT

    fn startsSelect(p: *const Parser, k: usize) bool {
        const t = p.peekAt(k);
        return t.isAnyKw(&.{ "select", "with" });
    }

    fn parenStartsSelect(p: *const Parser) bool {
        var k: usize = 0;
        while (p.peekAt(k).kind == .lparen) k += 1;
        return k > 0 and p.startsSelect(k);
    }

    pub fn select(p: *Parser) Error!*tree.Select {
        const pos = p.peek().start;
        var with: ?*tree.With = null;
        if (p.isKw("with")) with = try p.withClause();
        return p.selectAfterWith(with, pos);
    }

    pub fn selectAfterWith(p: *Parser, with: ?*tree.With, pos: u32) Error!*tree.Select {
        const body = try p.setExpr();
        var s: tree.Select = .{ .with = with, .body = body, .pos = pos };
        if (p.isKw("order")) {
            _ = p.advance();
            _ = p.eatKw("siblings");
            try p.expectKw("by");
            s.order_by = try p.sortList();
        }
        // OFFSET n ROWS, FETCH FIRST n ROWS ONLY, FOR UPDATE.
        while (true) {
            if (p.isKw("offset")) {
                const at = p.advance().start;
                if (s.offset != null) return p.fail(at, "ORA-00933: SQL command not properly ended", .{});
                s.offset = try p.addExpr();
                if (!p.eatKw("row")) try p.expectKw("rows");
            } else if (p.isKw("fetch")) {
                const at = p.advance().start;
                if (s.limit != null) return p.fail(at, "ORA-00933: SQL command not properly ended", .{});
                if (!p.eatKw("first")) try p.expectKw("next");
                if (p.isKw("row") or p.isKw("rows")) {
                    s.limit = try p.expr(at, .{ .integer = "1" });
                } else {
                    s.limit = try p.addExpr();
                    if (p.isKw("percent")) return p.unsupported(at, "FETCH ... PERCENT");
                }
                if (!p.eatKw("row")) try p.expectKw("rows");
                if (p.isKw("with")) return p.unsupported(at, "FETCH ... WITH TIES");
                try p.expectKw("only");
            } else if (p.isKw("for") and p.isKwAt(1, "update")) {
                // FOR UPDATE: a no-op, writers are serialized.
                _ = p.advance();
                _ = p.advance();
                if (p.eatKw("of")) {
                    while (true) {
                        _ = try p.anyName();
                        while (p.eat(.dot)) _ = try p.anyName();
                        if (!p.eat(.comma)) break;
                    }
                }
                if (p.eatKw("nowait")) {} else if (p.eatKw("wait")) {
                    _ = try p.signedInt();
                } else if (p.eatKw("skip")) try p.expectKw("locked");
            } else break;
        }
        // A parenthesized query alone is that query.
        if (with == null and s.order_by.len == 0 and s.limit == null and s.offset == null) {
            if (body.* == .nested) return body.nested;
        }
        return p.applyRownum(try p.new(tree.Select, s));
    }

    fn withClause(p: *Parser) Error!*tree.With {
        try p.expectKw("with");
        if (p.isKw("function") or p.isKw("procedure")) return p.unsupported(p.peek().start, "PL/SQL in WITH");
        var ctes: std.ArrayList(tree.Cte) = .empty;
        while (true) {
            var cte: tree.Cte = .{ .name = try p.colId(), .select = undefined };
            try p.cte_names.append(p.arena, cte.name.text);
            if (p.peek().kind == .lparen) cte.cols = try p.parenNameList();
            try p.expectKw("as");
            if (p.eatKw("materialized")) {
                cte.materialized = true;
            } else if (p.isKw("not") and p.isKwAt(1, "materialized")) {
                _ = p.advance();
                _ = p.advance();
                cte.materialized = false;
            }
            _ = try p.expect(.lparen);
            cte.select = try p.select();
            _ = try p.expect(.rparen);
            if (p.isKw("search") or p.isKw("cycle")) return p.unsupported(p.peek().start, "SEARCH and CYCLE clauses");
            try ctes.append(p.arena, cte);
            if (!p.eat(.comma)) break;
        }
        // Oracle's recursive subquery factoring has no RECURSIVE; SQLite's
        // WITH lets a query name itself either way.
        return p.new(tree.With, .{ .recursive = false, .ctes = ctes.items });
    }

    /// UNION [ALL], INTERSECT and MINUS (EXCEPT), all of the same
    /// precedence, left to right.
    fn setExpr(p: *Parser) Error!*tree.Body {
        var left = try p.simpleSelect();
        while (true) {
            const op: tree.SetOp = if (p.eatKw("union"))
                .@"union"
            else if (p.eatKw("intersect"))
                .intersect
            else if (p.eatKw("minus") or p.eatKw("except"))
                .except
            else
                break;
            const all = p.eatKw("all");
            if (!all) _ = p.eatKw("distinct");
            const right = try p.simpleSelect();
            left = try p.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = left, .right = right } });
        }
        return left;
    }

    fn simpleSelect(p: *Parser) Error!*tree.Body {
        const t = p.peek();
        if (t.kind == .lparen) {
            _ = p.advance();
            const s = try p.select();
            _ = try p.expect(.rparen);
            return p.new(tree.Body, .{ .nested = s });
        }
        if (t.isKw("select")) return p.new(tree.Body, .{ .core = try p.core() });
        if (t.isKw("values")) {
            _ = p.advance();
            var rows: std.ArrayList([]*Expr) = .empty;
            while (true) {
                p.nextval_seen.clearRetainingCapacity();
                _ = try p.expect(.lparen);
                try rows.append(p.arena, try p.exprList());
                _ = try p.expect(.rparen);
                if (!p.eat(.comma)) break;
            }
            return p.new(tree.Body, .{ .values = rows.items });
        }
        if (t.kind == .eof) return p.missing("ORA-00928: missing SELECT keyword");
        return p.missing("ORA-00928: missing SELECT keyword");
    }

    fn core(p: *Parser) Error!*tree.Core {
        const pos = p.advance().start; // SELECT
        var c: tree.Core = .{ .cols = &.{}, .pos = pos };
        if (p.eatKw("distinct") or p.eatKw("unique")) {
            c.distinct = true;
        } else _ = p.eatKw("all");
        if (p.atClauseEnd()) return p.missing("ORA-00936: missing expression");
        c.cols = try p.targetList();
        if (p.isKw("into")) return p.unsupported(p.peek().start, "SELECT INTO (PL/SQL)");
        if (p.eatKw("from")) {
            const saved = p.dual_star;
            defer p.dual_star = saved;
            p.dual_star = false;
            for (c.cols) |rc| switch (rc) {
                .expr => |x| if (mentionsDummy(x.e)) {
                    p.dual_star = true;
                },
                else => p.dual_star = true,
            };
            c.from = try p.fromList();
        } else if (!p.atClauseEnd()) {
            return p.missing("ORA-00923: FROM keyword not found where expected");
        }
        if (p.eatKw("where")) c.where = try p.expr0();
        if (p.isKw("start") or p.isKw("connect")) return p.unsupported(p.peek().start, "CONNECT BY hierarchical queries");
        if (p.isKw("group")) {
            _ = p.advance();
            try p.expectKw("by");
            if (p.isAnyKw(&.{ "rollup", "cube", "grouping" })) return p.unsupported(p.peek().start, "GROUP BY ROLLUP/CUBE/GROUPING SETS");
            c.group_by = try p.exprList();
        }
        if (p.eatKw("having")) c.having = try p.expr0();
        if (p.eatKw("window")) {
            var wins: std.ArrayList(tree.NamedWindow) = .empty;
            while (true) {
                const name = try p.colId();
                try p.expectKw("as");
                try wins.append(p.arena, .{ .name = name, .spec = try p.windowSpec() });
                if (!p.eat(.comma)) break;
            }
            c.windows = wins.items;
        }
        const cp = try p.new(tree.Core, c);
        try p.outerJoins(cp);
        try p.rownumWhere(cp);
        return cp;
    }

    fn atClauseEnd(p: *const Parser) bool {
        const t = p.peek();
        if (t.kind == .eof or t.kind == .rparen) return true;
        const words = [_][]const u8{ "from", "where", "group", "having", "window", "order", "offset", "fetch", "union", "intersect", "minus", "except", "into", "for", "connect", "start" };
        for (words) |w| if (t.isKw(w)) return true;
        return false;
    }

    pub fn targetList(p: *Parser) Error![]tree.ResultCol {
        p.nextval_seen.clearRetainingCapacity();
        var out: std.ArrayList(tree.ResultCol) = .empty;
        while (true) {
            try out.append(p.arena, try p.target());
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    fn target(p: *Parser) Error!tree.ResultCol {
        const t = p.peek();
        if (t.isOp("*")) {
            _ = p.advance();
            return .{ .star = t.start };
        }
        // t.* and s.t.*
        if (t.kind == .ident or t.kind == .qident) {
            var k: usize = 1;
            var names: std.ArrayList(Name) = .empty;
            while (p.peekAt(k).kind == .dot) : (k += 2) {
                if (p.peekAt(k + 1).isOp("*")) {
                    var j: usize = 0;
                    while (j < k) : (j += 2) {
                        const nt = p.peekAt(j);
                        if (nt.kind != .ident and nt.kind != .qident) break;
                        try names.append(p.arena, .{ .text = nt.text, .pos = nt.start });
                    } else {
                        const star = p.peekAt(k + 1);
                        p.i += k + 2;
                        // schema.t.*: the schema is the current user's.
                        if (names.items.len > 1) names.items = names.items[names.items.len - 1 ..];
                        return .{ .table_star = .{ .names = names.items, .star_pos = star.start } };
                    }
                    break;
                }
                const nt = p.peekAt(k + 1);
                if (nt.kind != .ident and nt.kind != .qident) break;
            }
        }
        const e = try p.expr0();
        var label: ?Name = null;
        if (p.eatKw("as")) {
            label = try p.anyName();
        } else {
            const a = p.peek();
            if (a.kind == .qident or (a.kind == .ident and !noAlias(a.text))) {
                _ = p.advance();
                label = .{ .text = a.text, .pos = a.start };
            }
        }
        return .{ .expr = .{ .e = e, .alias = label, .name = if (label == null) try p.columnName(e) else null } };
    }

    /// Oracle's name of a result column without an alias: null for a
    /// column (SQLite names it after the column), the pseudo-column's
    /// name (NEXTVAL, ROWID), else the text of the expression in upper
    /// case without blanks.
    fn columnName(p: *Parser, e: *const Expr) Error!?[]const u8 {
        if (p.pseudo_names.get(e)) |n| return n;
        if (e.kind == .column) return null;
        const text = p.src[@min(e.pos, p.src.len)..@min(e.end, p.src.len)];
        var out: std.ArrayList(u8) = .empty;
        // Blanks go, and the quotes of quoted names (not those in
        // string literals).
        var in_string = false;
        for (text) |c| {
            if (c == '\'') in_string = !in_string;
            if (std.ascii.isWhitespace(c) or (c == '"' and !in_string)) continue;
            try out.append(p.arena, std.ascii.toUpper(c));
        }
        return out.items;
    }

    pub fn sortList(p: *Parser) Error![]tree.SortItem {
        var out: std.ArrayList(tree.SortItem) = .empty;
        while (true) {
            var item: tree.SortItem = .{ .expr = try p.expr0() };
            if (p.eatKw("asc")) {
                item.dir = .asc;
            } else if (p.eatKw("desc")) {
                item.dir = .desc;
            }
            if (p.eatKw("nulls")) {
                if (p.eatKw("first")) {
                    item.nulls = .first;
                } else {
                    try p.expectKw("last");
                    item.nulls = .last;
                }
            } else {
                // Oracle: NULLs sort as if larger than any value.
                item.nulls = if (item.dir == .desc) .first else .last;
            }
            try out.append(p.arena, item);
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    // -------------------------------------------------------------- FROM

    pub fn fromList(p: *Parser) Error![]tree.FromItem {
        var items: std.ArrayList(tree.FromItem) = .empty;
        try p.tableRef(&items, .none);
        while (p.eat(.comma)) try p.tableRef(&items, .comma);
        // DUAL is no table; for a `*`, a row with its column DUMMY.
        var out: std.ArrayList(tree.FromItem) = .empty;
        for (items.items) |it| {
            if (p.isDual(it)) {
                if (!p.dual_star) continue;
                try out.append(p.arena, try p.dualRow(it));
                continue;
            }
            var x = it;
            if (out.items.len == 0) x.join = .none;
            try out.append(p.arena, x);
        }
        return out.items;
    }

    /// DUAL as (SELECT 'X' AS DUMMY) DUAL.
    fn dualRow(p: *Parser, it: tree.FromItem) Error!tree.FromItem {
        const pos = it.source.table.name.pos;
        var cols = try p.arena.alloc(tree.ResultCol, 1);
        cols[0] = .{ .expr = .{ .e = try p.stringAt(pos, "X"), .alias = .{ .text = "DUMMY", .pos = pos } } };
        const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = try p.new(tree.Core, .{ .cols = cols, .pos = pos }) }), .pos = pos });
        return .{ .join = it.join, .source = .{ .subquery = sel }, .alias = it.alias orelse .{ .name = it.source.table.name } };
    }

    fn isDual(p: *Parser, it: tree.FromItem) bool {
        if (it.source != .table or it.on != null or it.using.len > 0) return false;
        const q = it.source.table;
        if (!std.mem.eql(u8, q.name.text, "DUAL")) return false;
        if (p.p) |ps| if (build.findTable(ps.db, "DUAL", if (q.schema) |s| s.text else null) != null) return false;
        return true;
    }

    fn tableRef(p: *Parser, items: *std.ArrayList(tree.FromItem), join: tree.JoinKind) Error!void {
        var first = try p.fromPrimary();
        first.join = join;
        try items.append(p.arena, first);
        while (true) {
            var natural = false;
            if (p.eatKw("natural")) natural = true;
            var kind: tree.JoinKind = .inner;
            if (p.eatKw("join")) {} else if (p.eatKw("inner")) {
                try p.expectKw("join");
            } else if (p.eatKw("left")) {
                _ = p.eatKw("outer");
                try p.expectKw("join");
                kind = .left;
            } else if (p.eatKw("right")) {
                _ = p.eatKw("outer");
                try p.expectKw("join");
                kind = .right;
            } else if (p.eatKw("full")) {
                _ = p.eatKw("outer");
                try p.expectKw("join");
                kind = .full;
            } else if (p.eatKw("cross")) {
                if (p.isKw("apply")) return p.unsupported(p.peek().start, "CROSS APPLY");
                try p.expectKw("join");
                kind = .cross;
            } else {
                if (natural) return p.syntaxError();
                break;
            }
            var item = try p.fromPrimary();
            item.join = kind;
            item.natural = natural;
            if (kind != .cross and !natural) {
                if (p.eatKw("on")) {
                    item.on = try p.expr0();
                } else if (p.eatKw("using")) {
                    item.using = try p.parenNameList();
                } else return p.missing("ORA-00905: missing keyword");
            }
            try items.append(p.arena, item);
        }
    }

    fn tableItem(p: *Parser, q: QName) Error!tree.FromItem {
        if (try p.catalogView(q)) |sel| {
            return .{ .source = .{ .subquery = sel }, .alias = .{ .name = q.name } };
        }
        const r = try p.relation(q);
        return .{ .source = .{ .table = r.q }, .alias = if (r.alias) |a| .{ .name = a } else null };
    }

    fn fromPrimary(p: *Parser) Error!tree.FromItem {
        const t = p.peek();
        if (t.isKw("lateral")) return p.unsupported(t.start, "LATERAL");
        if (t.kind == .lparen) {
            if (p.parenStartsSelect()) {
                const save = p.i;
                _ = p.advance();
                if (p.select()) |s| {
                    if (p.eat(.rparen)) {
                        var item: tree.FromItem = .{ .source = .{ .subquery = s } };
                        item.alias = try p.alias();
                        return item;
                    }
                } else |err| if (err == error.OutOfMemory or p.err_in_parse) return err;
                p.i = save;
            }
            _ = p.advance();
            const inner = try p.fromList();
            _ = try p.expect(.rparen);
            var item: tree.FromItem = .{ .source = .{ .nested = inner } };
            item.alias = try p.alias();
            return item;
        }
        if (t.isKw("table") and p.peekAt(1).kind == .lparen) return p.unsupported(t.start, "TABLE() collection expressions");
        if (t.isKw("json_table") and p.peekAt(1).kind == .lparen) return jsonsql.jsonTable(p);
        _ = p.eatKw("only");
        const name = try p.qname();
        if (p.peek().kind == .lparen) {
            // A table-valued function (SQLite's: pragma_table_info() ...).
            const c = try p.funcCall(name.name);
            const al = try p.alias();
            const f = try p.new(tree.Func, .{ .name = c.name, .args = c.args });
            return .{ .source = .{ .func = f }, .alias = al };
        }
        var item = try p.tableItem(name);
        if (p.isKw("sample")) return p.unsupported(p.peek().start, "SAMPLE");
        if (p.isKw("as") and p.isKwAt(1, "of")) return p.unsupported(p.peek().start, "flashback queries (AS OF)");
        if (try p.alias()) |al| item.alias = al;
        return item;
    }

    /// `[AS] alias` (Oracle has no AS before a table alias, xqlite takes
    /// one).
    pub fn alias(p: *Parser) Error!?tree.Alias {
        if (p.eatKw("as")) return .{ .name = try p.colId() };
        const a = p.peek();
        if (a.kind == .qident or (a.kind == .ident and !noAlias(a.text))) {
            _ = p.advance();
            return .{ .name = .{ .text = a.text, .pos = a.start } };
        }
        return null;
    }

    // ------------------------------------------------------ outer joins

    /// The (+) marks of a WHERE: each conjunct with a marked column of a
    /// FROM item becomes that item's ON, the item a LEFT JOIN (a RIGHT
    /// JOIN when the marked item is the first of two).
    fn outerJoins(p: *Parser, c: *tree.Core) Error!void {
        if (p.outer_marks.count() == 0) return;
        const where = c.where orelse return;
        var conjuncts: std.ArrayList(*Expr) = .empty;
        try splitAnd(p.arena, where, &conjuncts);
        var rest: std.ArrayList(*Expr) = .empty;
        var ons = try p.arena.alloc(?*Expr, c.from.len);
        @memset(ons, null);
        var any = false;
        for (conjuncts.items) |x| {
            var marked: ?usize = null;
            var bad = false;
            try p.markedItem(x, c.from, &marked, &bad);
            if (bad) return p.fail(x.pos, "ORA-01468: a predicate may reference only one outer-joined table", .{});
            const k = marked orelse {
                try rest.append(p.arena, x);
                continue;
            };
            any = true;
            ons[k] = if (ons[k]) |prev| try p.span(prev, x, .{ .binary = .{ .op = .@"and", .l = prev, .r = x } }) else x;
        }
        if (!any) return;
        var from = try p.arena.dupe(tree.FromItem, c.from);
        for (ons, 0..) |on_opt, k| {
            const on = on_opt orelse continue;
            if (from[k].join != .comma and from[k].join != .none) return p.fail(on.pos, "ORA-25156: old style outer join (+) cannot be used with ANSI joins", .{});
            if (k > 0) {
                from[k].join = .left;
                from[k].on = on;
            } else {
                // The first item outer-joined: the second is joined to it
                // with RIGHT JOIN.
                if (from.len != 2 or ons[1] != null) return p.unsupported(on.pos, "this (+) outer join (put the outer-joined table last)");
                from[1].join = .right;
                from[1].on = on;
            }
        }
        c.from = from;
        c.where = if (rest.items.len == 0) null else blk: {
            var w = rest.items[0];
            for (rest.items[1..]) |x| w = try p.span(w, x, .{ .binary = .{ .op = .@"and", .l = w, .r = x } });
            break :blk w;
        };
    }

    /// The FROM item a conjunct's (+) marks name (they must name one).
    fn markedItem(p: *Parser, e: *const Expr, from: []const tree.FromItem, out: *?usize, bad: *bool) Error!void {
        if (p.outer_marks.contains(e)) {
            const names = e.kind.column;
            const k = try p.itemOf(names, from) orelse return p.fail(e.pos, "ORA-00904: \"{s}\": invalid identifier", .{names[names.len - 1].text});
            if (out.*) |prev| {
                if (prev != k) bad.* = true;
            } else out.* = k;
            return;
        }
        var it = Children.of(e);
        while (it.next()) |child| try p.markedItem(child, from, out, bad);
    }

    /// The FROM item a column reference belongs to.
    fn itemOf(p: *Parser, names: []const Name, from: []const tree.FromItem) Error!?usize {
        for (from, 0..) |it, k| {
            if (names.len >= 2) {
                const q = names[names.len - 2].text;
                const label = if (it.alias) |a| a.name.text else if (it.source == .table) it.source.table.name.text else continue;
                if (std.ascii.eqlIgnoreCase(label, q)) return k;
                continue;
            }
            if (it.source != .table) continue;
            const t = (try p.findTable(it.source.table)) orelse continue;
            if (build.columnIndex(t, names[0].text) >= 0) return k;
        }
        return null;
    }

    // ------------------------------------------------------------ ROWNUM

    /// WHERE ROWNUM <= n (< n, = 1, BETWEEN 1 AND n), alone or in a
    /// conjunction: the conjunct is removed and the query gets LIMIT n
    /// (applyRownum()). Other ROWNUM conditions are not supported.
    fn rownumWhere(p: *Parser, c: *tree.Core) Error!void {
        const lim = try p.takeRownum(&c.where) orelse return;
        try p.rownum_limits.put(p.arena, c, lim);
    }

    /// The LIMIT of the ROWNUM condition of a WHERE (UPDATE and DELETE
    /// take it too), which leaves the WHERE.
    pub fn takeRownum(p: *Parser, where_ptr: *?*Expr) Error!?*Expr {
        const where = where_ptr.* orelse return null;
        if (!p.usesRownum(where)) return null;
        var conjuncts: std.ArrayList(*Expr) = .empty;
        try splitAnd(p.arena, where, &conjuncts);
        var rest: std.ArrayList(*Expr) = .empty;
        var lim: ?*Expr = null;
        for (conjuncts.items) |x| {
            if (!p.usesRownum(x)) {
                try rest.append(p.arena, x);
                continue;
            }
            const n = try p.rownumBound(x) orelse return p.unsupported(x.pos, "this ROWNUM condition");
            if (lim != null) return p.unsupported(x.pos, "several ROWNUM conditions");
            lim = n;
        }
        where_ptr.* = if (rest.items.len == 0) null else blk: {
            var w = rest.items[0];
            for (rest.items[1..]) |x| w = try p.span(w, x, .{ .binary = .{ .op = .@"and", .l = w, .r = x } });
            break :blk w;
        };
        return lim.?;
    }

    fn isRownum(p: *const Parser, e: *const Expr) bool {
        return p.rownum_nodes.contains(e);
    }

    fn usesRownum(p: *const Parser, e: *const Expr) bool {
        if (p.isRownum(e)) return true;
        var it = Children.of(e);
        while (it.next()) |child| if (p.usesRownum(child)) return true;
        return false;
    }

    /// The LIMIT of a ROWNUM condition, null if it is not one of the
    /// supported forms. A bound below 1 gives LIMIT 0.
    fn rownumBound(p: *Parser, x: *Expr) Error!?*Expr {
        switch (x.kind) {
            .compare => |cmp| {
                var op = cmp.op;
                var n = cmp.r;
                if (p.isRownum(cmp.r)) {
                    n = cmp.l;
                    op = switch (op) {
                        .lt => .gt,
                        .le => .ge,
                        .gt => .lt,
                        .ge => .le,
                        else => op,
                    };
                } else if (!p.isRownum(cmp.l)) return null;
                if (p.usesRownum(n)) return null;
                return switch (op) {
                    .le => n,
                    .lt => try p.span(n, n, .{ .binary = .{ .op = .sub, .l = n, .r = try p.expr(n.pos, .{ .integer = "1" }) } }),
                    // ROWNUM = 1 is the first row, ROWNUM = n (n > 1) none.
                    .eq => try p.span(n, n, .{ .case = .{ .operand = null, .whens = try p.list(&.{ try p.span(n, n, .{ .compare = .{ .op = .eq, .l = n, .r = try p.expr(n.pos, .{ .integer = "1" }) } }), try p.expr(n.pos, .{ .integer = "1" }) }), .@"else" = try p.expr(n.pos, .{ .integer = "0" }) } }),
                    // ROWNUM > n holds for no row when n >= 1.
                    .gt => try p.span(n, n, .{ .case = .{ .operand = null, .whens = try p.list(&.{ try p.span(n, n, .{ .compare = .{ .op = .lt, .l = n, .r = try p.expr(n.pos, .{ .integer = "1" }) } }), try p.expr(n.pos, .{ .integer = "-1" }) }), .@"else" = try p.expr(n.pos, .{ .integer = "0" }) } }),
                    .ge => try p.span(n, n, .{ .case = .{ .operand = null, .whens = try p.list(&.{ try p.span(n, n, .{ .compare = .{ .op = .le, .l = n, .r = try p.expr(n.pos, .{ .integer = "1" }) } }), try p.expr(n.pos, .{ .integer = "-1" }) }), .@"else" = try p.expr(n.pos, .{ .integer = "0" }) } }),
                    else => null,
                };
            },
            .between => |b| {
                if (!p.isRownum(b.e) or b.not or p.usesRownum(b.lo) or p.usesRownum(b.hi)) return null;
                if (b.lo.kind != .integer or !std.mem.eql(u8, b.lo.kind.integer, "1")) return null;
                return b.hi;
            },
            else => return null,
        }
    }

    /// Put the LIMIT of a WHERE ROWNUM on the query: the Select itself
    /// when ROWNUM is computed after nothing else (no ORDER BY, grouping
    /// or DISTINCT), else a subquery that limits first, as Oracle numbers
    /// rows before it sorts or groups.
    fn applyRownum(p: *Parser, s: *tree.Select) Error!*tree.Select {
        if (p.rownum_limits.count() == 0) return s;
        try p.rownumBody(s.body, false);
        if (s.body.* != .core) return s;
        const c = s.body.core;
        const lim = p.rownum_limits.get(c) orelse return s;
        _ = p.rownum_limits.remove(c);
        const plain = s.order_by.len == 0 and !c.distinct and c.group_by.len == 0 and c.having == null and !hasAggregate(c);
        if (plain and s.limit == null and s.offset == null) {
            s.limit = lim;
            return s;
        }
        if (s.order_by.len > 0 and c.group_by.len == 0 and c.having == null and !hasAggregate(c) and !c.distinct) {
            // SELECT * FROM (SELECT ... LIMIT n) ORDER BY ...
            const inner = try p.new(tree.Select, .{ .body = s.body, .limit = lim, .pos = s.pos });
            const outer = try p.new(tree.Select, s.*);
            outer.body = try p.new(tree.Body, .{ .nested = inner });
            return outer;
        }
        // Grouping: FROM (SELECT * FROM t WHERE ... LIMIT n) t (one FROM item,
        // whose qualified names keep meaning the same).
        if (c.from.len != 1) return p.unsupported(c.pos, "ROWNUM with grouping over several tables");
        const item = c.from[0];
        var cols = try p.arena.alloc(tree.ResultCol, 1);
        cols[0] = .{ .star = c.pos };
        const inner_core = try p.new(tree.Core, .{ .cols = cols, .from = c.from, .where = c.where, .pos = c.pos });
        const inner = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = inner_core }), .limit = lim, .pos = c.pos });
        var from = try p.arena.alloc(tree.FromItem, 1);
        const label: ?Name = if (item.alias) |a| a.name else if (item.source == .table) item.source.table.name else null;
        from[0] = .{ .source = .{ .subquery = inner }, .alias = if (label) |l| .{ .name = l } else null };
        c.from = from;
        c.where = null;
        return s;
    }

    /// The cores of a compound (or nested) body with a ROWNUM limit get
    /// it in a subquery of their own.
    fn rownumBody(p: *Parser, b: *tree.Body, nested: bool) Error!void {
        switch (b.*) {
            .compound => |x| {
                try p.rownumBody(x.left, true);
                try p.rownumBody(x.right, true);
            },
            .core => |c| if (nested) {
                const lim = p.rownum_limits.get(c) orelse return;
                const inner = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = c }), .pos = c.pos });
                const limited = try p.applyRownum(inner);
                _ = lim;
                b.* = .{ .nested = limited };
            },
            else => {},
        }
    }

    // ======================================================= expressions

    pub fn exprList(p: *Parser) Error![]*Expr {
        var out: std.ArrayList(*Expr) = .empty;
        while (true) {
            try out.append(p.arena, try p.expr0());
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    pub fn expr0(p: *Parser) Error!*Expr {
        return p.orExpr();
    }

    fn orExpr(p: *Parser) Error!*Expr {
        var l = try p.andExpr();
        while (p.eatKw("or")) {
            const r = try p.andExpr();
            l = try p.binary(.@"or", l, r);
        }
        return l;
    }

    fn andExpr(p: *Parser) Error!*Expr {
        var l = try p.notExpr();
        while (p.eatKw("and")) {
            const r = try p.notExpr();
            l = try p.binary(.@"and", l, r);
        }
        return l;
    }

    fn notExpr(p: *Parser) Error!*Expr {
        const t = p.peek();
        if (t.isKw("not")) {
            _ = p.advance();
            const e = try p.notExpr();
            return p.expr(t.start, .{ .unary = .{ .op = .not, .e = e } });
        }
        return p.cmpExpr();
    }

    fn cmpOp(t: Token) ?tree.CmpOp {
        if (t.kind != .op) return null;
        const map = [_]struct { []const u8, tree.CmpOp }{
            .{ "=", .eq }, .{ "<>", .ne }, .{ "!=", .ne }, .{ "^=", .ne }, .{ "~=", .ne },
            .{ "<", .lt }, .{ "<=", .le }, .{ ">", .gt },  .{ ">=", .ge },
        };
        for (map) |m| if (std.mem.eql(u8, t.text, m[0])) return m[1];
        return null;
    }

    /// Comparisons, IS [NOT] NULL, [NOT] LIKE/BETWEEN/IN: one level in
    /// Oracle.
    fn cmpExpr(p: *Parser) Error!*Expr {
        var l = try p.addExpr();
        while (true) {
            if (cmpOp(p.peek())) |op| {
                const at = p.advance().start;
                if (p.isAnyKw(&.{ "any", "some", "all" })) {
                    const all = p.advance().isKw("all");
                    if (!((op == .eq and !all) or (op == .ne and all))) return p.unsupported(at, "this ANY/ALL comparison");
                    _ = try p.expect(.lparen);
                    if (p.startsSelect(0) or p.parenStartsSelect()) {
                        const s = try p.select();
                        _ = try p.expect(.rparen);
                        l = try p.expr(l.pos, .{ .in_select = .{ .e = l, .not = all, .sel = s } });
                    } else {
                        const items = try p.exprList();
                        _ = try p.expect(.rparen);
                        l = try p.expr(l.pos, .{ .in_list = .{ .e = l, .not = all, .items = items } });
                    }
                    continue;
                }
                const r = try p.addExpr();
                l = try p.span(l, r, .{ .compare = .{ .op = op, .l = l, .r = r } });
                continue;
            }
            if (p.isKw("is")) {
                _ = p.advance();
                const not = p.eatKw("not");
                if (p.eatKw("null")) {
                    l = try p.expr(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                } else if (p.eatKw("true")) {
                    l = try p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = true, .not = not } });
                } else if (p.eatKw("false")) {
                    l = try p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = false, .not = not } });
                } else if (p.isKw("json")) {
                    l = try jsonsql.isJson(p, l, not);
                } else return p.missing("ORA-00908: missing NULL keyword");
                continue;
            }
            var not = false;
            const save = p.i;
            if (p.isKw("not") and (p.isKwAt(1, "between") or p.isKwAt(1, "in") or p.isKwAt(1, "like"))) {
                _ = p.advance();
                not = true;
            }
            if (p.eatKw("between")) {
                const lo = try p.addExpr();
                try p.expectKw("and");
                const hi = try p.addExpr();
                l = try p.expr(l.pos, .{ .between = .{ .e = l, .not = not, .lo = lo, .hi = hi } });
            } else if (p.eatKw("in")) {
                _ = try p.expect(.lparen);
                if (p.startsSelect(0) or p.parenStartsSelect()) {
                    const s = try p.select();
                    _ = try p.expect(.rparen);
                    l = try p.expr(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = s } });
                } else {
                    const items = try p.exprList();
                    _ = try p.expect(.rparen);
                    l = try p.expr(l.pos, .{ .in_list = .{ .e = l, .not = not, .items = items } });
                }
            } else if (p.eatKw("like")) {
                // Case-sensitive, no escape character without ESCAPE.
                const pat = try p.addExpr();
                var esc: tree.Escape = .none;
                if (p.eatKw("escape")) esc = .{ .expr = try p.addExpr() };
                l = try p.expr(l.pos, .{ .like = .{ .e = l, .pat = pat, .not = not, .case_sensitive = true, .escape = esc } });
            } else {
                p.i = save;
                break;
            }
        }
        return l;
    }

    /// + - and ||, left to right.
    pub fn addExpr(p: *Parser) Error!*Expr {
        var l = try p.mulExpr();
        while (true) {
            if (p.isOp("+") or p.isOp("-")) {
                const op: tree.BinOp = if (p.advance().isOp("+")) .add else .sub;
                const r = try p.mulExpr();
                l = try p.binary(op, l, r);
            } else if (p.eatOp("||")) {
                const r = try p.mulExpr();
                l = try p.concat(l, r);
            } else break;
        }
        return l;
    }

    /// `a || b`: NULLs skipped, and NULL if the result is '' (Oracle's
    /// empty string): nullif(concat(a, b, ...), '').
    pub fn concat(p: *Parser, l: *Expr, r: *Expr) Error!*Expr {
        const args = if (p.concat_nodes.contains(l))
            try std.mem.concat(p.arena, *Expr, &.{ l.kind.func.args[0].kind.concat.args, &.{r} })
        else
            try p.list(&.{ l, r });
        const c = try p.span(l, r, .{ .concat = .{ .args = args, .null_policy = .skip } });
        const x = try p.nullIfEmpty(c);
        try p.concat_nodes.put(p.arena, x, {});
        return x;
    }

    /// nullif(e, ''): the empty string as NULL.
    fn nullIfEmpty(p: *Parser, e: *Expr) Error!*Expr {
        const empty = try tree.expr(p.arena, e.pos, e.pos, .{ .string = "" });
        const f = try p.new(tree.Func, .{ .name = .{ .text = "nullif", .pos = e.pos }, .args = try p.list(&.{ e, empty }) });
        return tree.expr(p.arena, e.pos, e.end, .{ .func = f });
    }

    fn mulExpr(p: *Parser) Error!*Expr {
        var l = try p.unary();
        while (true) {
            if (p.eatOp("*")) {
                l = try p.binary(.mul, l, try p.unary());
            } else if (p.eatOp("/")) {
                // Oracle's NUMBER division is exact: as reals.
                const r = try p.unary();
                l = try p.span(l, r, .{ .div = .{ .kind = .real, .l = l, .r = r } });
            } else break;
        }
        return l;
    }

    fn unary(p: *Parser) Error!*Expr {
        const t = p.peek();
        if (t.isKw("prior")) return p.unsupported(t.start, "CONNECT BY (PRIOR)");
        const op: tree.UnOp = if (t.isOp("-")) .neg else if (t.isOp("+")) .plus else return p.postfix();
        _ = p.advance();
        const e = try p.unary();
        return p.expr(t.start, .{ .unary = .{ .op = op, .e = e } });
    }

    fn postfix(p: *Parser) Error!*Expr {
        const e = try p.primary();
        // (+): an outer join mark on a column.
        if (p.peek().kind == .lparen and p.peekAt(1).isOp("+") and p.peekAt(2).kind == .rparen) {
            if (e.kind != .column) return p.fail(e.pos, "ORA-00936: missing expression", .{});
            _ = p.advance();
            _ = p.advance();
            _ = p.advance();
            try p.outer_marks.put(p.arena, e, {});
        }
        if (p.isKw("collate")) return p.unsupported(p.peek().start, "COLLATE");
        if (p.isKw("at") and (p.isKwAt(1, "time") or p.isKwAt(1, "local"))) return p.unsupported(p.peek().start, "AT TIME ZONE");
        return e;
    }

    pub fn binary(p: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return p.span(l, r, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    fn primary(p: *Parser) Error!*Expr {
        const t = p.peek();
        switch (t.kind) {
            .integer => {
                _ = p.advance();
                return p.expr(t.start, .{ .integer = t.text });
            },
            .float => {
                _ = p.advance();
                return p.expr(t.start, .{ .float = t.text });
            },
            .string => {
                _ = p.advance();
                // The empty string is NULL.
                if (t.text.len == 0) return p.expr(t.start, .null);
                return p.expr(t.start, .{ .string = t.text });
            },
            .param => {
                _ = p.advance();
                const name = t.text[1..];
                if (name.len > 0 and std.ascii.isDigit(name[0])) {
                    const n = std.fmt.parseInt(u32, name, 10) catch return p.fail(t.start, "ORA-01036: illegal variable name/number", .{});
                    if (n == 0) return p.fail(t.start, "ORA-01036: illegal variable name/number", .{});
                    return p.expr(t.start, .{ .param = n });
                }
                return p.expr(t.start, .{ .named_param = t.text });
            },
            .lparen => return p.parenExpr(),
            .qident => return p.nameExpr(),
            .ident => {},
            else => return p.missing("ORA-00936: missing expression"),
        }
        const w = t.text;
        if (eq(w, "NULL")) return p.keywordExpr(.null);
        if (eq(w, "TRUE")) return p.keywordExpr(.{ .boolean = true });
        if (eq(w, "FALSE")) return p.keywordExpr(.{ .boolean = false });
        if (eq(w, "DEFAULT")) return p.keywordExpr(.default);
        if (eq(w, "CASE")) return p.caseExpr();
        if (eq(w, "CAST")) {
            _ = p.advance();
            _ = try p.expect(.lparen);
            if (p.isKw("multiset")) return p.unsupported(p.peek().start, "CAST(MULTISET ...)");
            const e = try p.expr0();
            try p.expectKw("as");
            const ty = try p.typeName();
            _ = try p.expect(.rparen);
            return p.castExpr(t.start, e, ty);
        }
        if (eq(w, "EXISTS")) {
            _ = p.advance();
            _ = try p.expect(.lparen);
            const s = try p.select();
            _ = try p.expect(.rparen);
            return p.expr(t.start, .{ .exists = s });
        }
        if (eq(w, "SYSDATE") or eq(w, "CURRENT_DATE")) {
            _ = p.advance();
            return p.sysdate(t.start);
        }
        if (eq(w, "SYSTIMESTAMP") or eq(w, "CURRENT_TIMESTAMP") or eq(w, "LOCALTIMESTAMP")) {
            _ = p.advance();
            // CURRENT_TIMESTAMP(3): the precision is ignored.
            if (p.peek().kind == .lparen and p.peekAt(1).kind == .integer and p.peekAt(2).kind == .rparen) p.i += 3;
            return p.systimestamp(t.start);
        }
        if (eq(w, "USER")) {
            _ = p.advance();
            return p.expr(t.start, .{ .string = "MAIN" });
        }
        if (eq(w, "UID")) {
            _ = p.advance();
            return p.expr(t.start, .{ .integer = "0" });
        }
        if (eq(w, "ROWNUM")) {
            _ = p.advance();
            // row_number() OVER (): the number of the row as the query
            // produces it (in WHERE, a LIMIT: rownumWhere()).
            const spec = try p.new(tree.WindowSpec, .{});
            const f = try p.new(tree.Func, .{ .name = .{ .text = "row_number", .pos = t.start }, .over = spec });
            const x = try p.expr(t.start, .{ .func = f });
            try p.rownum_nodes.put(p.arena, x, {});
            return x;
        }
        if (eq(w, "ROWID")) {
            _ = p.advance();
            const n = try p.arena.alloc(Name, 1);
            n[0] = .{ .text = "rowid", .pos = t.start };
            const x = try p.expr(t.start, .{ .column = n });
            try p.pseudo_names.put(p.arena, x, "ROWID");
            return x;
        }
        if (eq(w, "LEVEL") or eq(w, "PRIOR") or eq(w, "CONNECT_BY_ROOT")) return p.unsupported(t.start, "CONNECT BY hierarchical queries");
        if ((eq(w, "DATE") or eq(w, "TIMESTAMP")) and p.peekAt(1).kind == .string) {
            _ = p.advance();
            const s = p.advance();
            return p.dateLiteral(t.start, s, eq(w, "TIMESTAMP"));
        }
        if (eq(w, "INTERVAL") and p.peekAt(1).kind == .string) return p.unsupported(t.start, "INTERVAL literals");
        if (isReserved(w) and !(p.peekAt(1).kind == .lparen and isFuncNameKeyword(w))) {
            return p.missing("ORA-00936: missing expression");
        }
        return p.nameExpr();
    }

    fn keywordExpr(p: *Parser, kind: tree.Kind) Error!*Expr {
        const t = p.advance();
        return p.expr(t.start, kind);
    }

    /// SYSDATE: the statement's time, 'YYYY-MM-DD HH:MM:SS' (UTC).
    fn sysdate(p: *Parser, pos: u32) Error!*Expr {
        const e = try p.call(pos, "strftime", null, &.{ try p.stringAt(pos, "%Y-%m-%d %H:%M:%S"), try p.stringAt(pos, "now") });
        try p.date_nodes.put(p.arena, e, .date);
        return e;
    }

    /// SYSTIMESTAMP: 'YYYY-MM-DD HH:MM:SS.ffffff' (milliseconds).
    fn systimestamp(p: *Parser, pos: u32) Error!*Expr {
        const e = try p.call(pos, "strftime", null, &.{ try p.stringAt(pos, "%Y-%m-%d %H:%M:%f000"), try p.stringAt(pos, "now") });
        try p.date_nodes.put(p.arena, e, .timestamp);
        return e;
    }

    /// DATE 'YYYY-MM-DD', TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.f]': their
    /// text as the dialect stores them.
    fn dateLiteral(p: *Parser, pos: u32, s: Token, timestamp: bool) Error!*Expr {
        const d = datetime.parseIso(s.text) orelse return p.fail(s.start, "ORA-01861: literal does not match format string", .{});
        if (!timestamp and s.text.len != 10) return p.fail(s.start, "ORA-01861: literal does not match format string", .{});
        var buf: [48]u8 = undefined;
        const text = if (timestamp) datetime.writeTimestamp(&buf, d, 6) else datetime.writeDate(&buf, d);
        const e = try p.expr(pos, .{ .string = try p.arena.dupe(u8, text) });
        try p.date_nodes.put(p.arena, e, if (timestamp) .timestamp else .date);
        return e;
    }

    /// A column reference, s.NEXTVAL/CURRVAL, or a function call.
    fn nameExpr(p: *Parser) Error!*Expr {
        const start = p.peek().start;
        var names: std.ArrayList(Name) = .empty;
        const first = p.advance();
        if (first.kind == .ident and p.peek().kind == .lparen and jsonsql.isFunction(first.text)) return jsonsql.call(p, start, first);
        try names.append(p.arena, .{ .text = first.text, .pos = first.start });
        while (p.peek().kind == .dot) {
            // t.col.a.size(): dot notation with an item method.
            if (names.items.len >= 2 and jsonsql.methodAhead(p)) break;
            _ = p.advance();
            const nt = p.peek();
            try names.append(p.arena, try p.anyName());
            // seq.NEXTVAL, schema.seq.CURRVAL
            if (nt.kind == .ident and (eq(nt.text, "NEXTVAL") or eq(nt.text, "CURRVAL"))) {
                const seq = names.items[names.items.len - 2];
                if (names.items.len > 3) return p.syntaxError();
                const q: QName = .{ .schema = if (names.items.len == 3) names.items[0] else null, .name = seq };
                const r = try p.lookup(q, .sequence);
                // Sequences are all in main.
                const sname = if (r.alias != null) r.q.name.text else seq.text;
                if (p.p) |ps| if (!sequenceExists(ps.db, sname)) return p.fail(seq.pos, "ORA-02289: sequence does not exist", .{});
                var fname: []const u8 = if (eq(nt.text, "NEXTVAL")) "nextval" else "currval";
                if (eq(nt.text, "NEXTVAL")) {
                    if (p.nextval_seen.contains(sname)) fname = "currval" else try p.nextval_seen.put(p.arena, sname, {});
                }
                const x = try p.call(start, fname, .oracle, &.{try p.stringAt(seq.pos, sname)});
                try p.pseudo_names.put(p.arena, x, if (eq(nt.text, "NEXTVAL")) "NEXTVAL" else "CURRVAL");
                return x;
            }
        }
        if (p.peek().kind == .lparen and !(p.peekAt(1).isOp("+") and p.peekAt(2).kind == .rparen)) {
            const n = names.items;
            if (n.len > 2) return p.syntaxError();
            // pkg.f(): packages are not supported, schema.f() is f().
            const c = try p.funcCall(n[n.len - 1]);
            return p.callExpr(start, c);
        }
        if (names.items.len >= 3 or (names.items.len == 2 and (p.peek().isOp("[") or jsonsql.methodAhead(p)))) {
            return jsonsql.dotExpr(p, start, names.items);
        }
        return p.expr(start, .{ .column = names.items });
    }

    fn parenExpr(p: *Parser) Error!*Expr {
        const start = p.peek().start;
        if (p.parenStartsSelect()) {
            const save = p.i;
            _ = p.advance();
            if (p.select()) |s| {
                if (p.eat(.rparen)) return p.expr(start, .{ .subquery = s });
            } else |err| if (err == error.OutOfMemory or p.err_in_parse) return err;
            p.i = save;
        }
        _ = p.advance();
        const e = try p.expr0();
        if (p.peek().kind == .comma) {
            var items: std.ArrayList(*Expr) = .empty;
            try items.append(p.arena, e);
            while (p.eat(.comma)) try items.append(p.arena, try p.expr0());
            _ = try p.expect(.rparen);
            return p.expr(start, .{ .row = items.items });
        }
        _ = try p.expect(.rparen);
        e.pos = start;
        e.end = p.lastEnd();
        return e;
    }

    fn caseExpr(p: *Parser) Error!*Expr {
        const start = p.advance().start;
        var operand: ?*Expr = null;
        if (!p.isKw("when")) operand = try p.expr0();
        var whens: std.ArrayList(*Expr) = .empty;
        while (p.eatKw("when")) {
            try whens.append(p.arena, try p.expr0());
            try p.expectKw("then");
            try whens.append(p.arena, try p.expr0());
        }
        if (whens.items.len == 0) return p.missing("ORA-00905: missing keyword");
        var else_: ?*Expr = null;
        if (p.eatKw("else")) else_ = try p.expr0();
        try p.expectKw("end");
        return p.expr(start, .{ .case = .{ .operand = operand, .whens = whens.items, .@"else" = else_ } });
    }

    // ========================================================= functions

    fn funcCall(p: *Parser, name: Name) Error!Call {
        _ = try p.expect(.lparen);
        var f: Call = .{ .name = name };
        const n = name.text;
        if (eq(n, "TRIM") or eq(n, "EXTRACT")) {
            if (try p.specialCall(&f)) return p.finishCall(f);
        }
        if (p.peek().isOp("*")) {
            _ = p.advance();
            f.star = true;
        } else if (p.peek().kind != .rparen) {
            if (p.eatKw("distinct") or p.eatKw("unique")) f.distinct = true else _ = p.eatKw("all");
            f.args = try p.exprList();
            if (p.peek().isOp("=>")) return p.unsupported(p.peek().start, "named arguments");
            if (p.isKw("on") and p.isKwAt(1, "overflow")) return p.unsupported(p.peek().start, "LISTAGG ... ON OVERFLOW");
        }
        _ = try p.expect(.rparen);
        return p.finishCall(f);
    }

    fn finishCall(p: *Parser, f_arg: Call) Error!Call {
        var f = f_arg;
        if (p.isKw("within") and p.isKwAt(1, "group")) {
            _ = p.advance();
            _ = p.advance();
            _ = try p.expect(.lparen);
            try p.expectKw("order");
            try p.expectKw("by");
            f.order_by = try p.sortList();
            _ = try p.expect(.rparen);
        }
        if (p.isKw("keep")) return p.unsupported(p.peek().start, "KEEP (DENSE_RANK ...)");
        if (p.isKw("respect") or p.isKw("ignore")) {
            if (p.isKwAt(1, "nulls")) return p.unsupported(p.peek().start, "IGNORE/RESPECT NULLS");
        }
        if (p.eatKw("over")) {
            if (p.peek().kind == .lparen) {
                f.over = try p.windowSpec();
            } else {
                f.over = try p.new(tree.WindowSpec, .{ .base = try p.colId(), .name_only = true });
            }
        }
        return f;
    }

    /// TRIM([LEADING|TRAILING|BOTH] [c] FROM s) and EXTRACT(field FROM
    /// d); false (nothing consumed) for the ordinary syntax.
    fn specialCall(p: *Parser, f: *Call) Error!bool {
        const n = f.name.text;
        var args: std.ArrayList(*Expr) = .empty;
        if (eq(n, "EXTRACT")) {
            const t = p.peek();
            if (t.kind != .ident) return p.missing("ORA-00905: missing keyword");
            _ = p.advance();
            const fields = [_][]const u8{ "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND" };
            for (fields) |fw| {
                if (eq(t.text, fw)) break;
            } else return p.unsupported(t.start, "this EXTRACT field");
            try p.expectKw("from");
            try args.append(p.arena, try p.expr(t.start, .{ .string = t.text }));
            try args.append(p.arena, try p.expr0());
            _ = try p.expect(.rparen);
            f.name.text = "extract";
            f.args = args.items;
            return true;
        }
        // TRIM
        var kind: []const u8 = "trim";
        var keyword = false;
        if (p.eatKw("both")) {
            keyword = true;
        } else if (p.eatKw("leading")) {
            kind = "ltrim";
            keyword = true;
        } else if (p.eatKw("trailing")) {
            kind = "rtrim";
            keyword = true;
        }
        var chars: ?*Expr = null;
        var subject: *Expr = undefined;
        if (p.eatKw("from")) {
            subject = try p.expr0();
        } else {
            const first = try p.expr0();
            if (p.eatKw("from")) {
                chars = first;
                subject = try p.expr0();
            } else {
                if (keyword) return p.missing("ORA-00907: missing right parenthesis");
                subject = first;
            }
        }
        _ = try p.expect(.rparen);
        try args.append(p.arena, subject);
        if (chars) |c| {
            try args.append(p.arena, c);
            // LTRIM/RTRIM take a set; TRIM's must be one character.
            if (!std.mem.eql(u8, kind, "trim")) try args.append(p.arena, c);
            if (!std.mem.eql(u8, kind, "trim")) args.items.len = 2;
        }
        f.name.text = kind;
        f.args = args.items;
        return true;
    }

    /// The expression a call means: Oracle's functions to the dialect's
    /// table (funcs.zig) or SQLite's, the ones that become other
    /// expressions (NVL, DECODE ...).
    fn callExpr(p: *Parser, pos: u32, c: Call) Error!*Expr {
        const n = c.name.text;
        const plain = c.over == null and c.filter == null and c.order_by.len == 0 and !c.distinct and !c.star;
        const argc = c.args.len;
        if (plain) {
            if (eq(n, "NVL")) {
                if (argc != 2) return p.argCount(c);
                return p.call(pos, "coalesce", null, c.args);
            }
            if (eq(n, "NVL2")) {
                if (argc != 3) return p.argCount(c);
                const test_ = try p.expr(pos, .{ .is_null = .{ .e = c.args[0], .not = true } });
                return p.expr(pos, .{ .case = .{ .operand = null, .whens = try p.list(&.{ test_, c.args[1] }), .@"else" = c.args[2] } });
            }
            if (eq(n, "DECODE")) {
                // DECODE(e, s1, r1, ..., [d]): NULL matches NULL.
                if (argc < 3) return p.argCount(c);
                var whens: std.ArrayList(*Expr) = .empty;
                var k: usize = 1;
                while (k + 1 < argc) : (k += 2) {
                    try whens.append(p.arena, try p.span(c.args[0], c.args[k], .{ .compare = .{ .op = .is, .l = c.args[0], .r = c.args[k] } }));
                    try whens.append(p.arena, c.args[k + 1]);
                }
                const else_: ?*Expr = if (k < argc) c.args[k] else null;
                return p.expr(pos, .{ .case = .{ .operand = null, .whens = whens.items, .@"else" = else_ } });
            }
            if (eq(n, "CONCAT")) {
                if (argc != 2) return p.argCount(c);
                const x = try p.concat(c.args[0], c.args[1]);
                // The call's span (for its column name), not the arguments'.
                x.pos = pos;
                x.end = p.lastEnd();
                return x;
            }
            if (eq(n, "LENGTH") or eq(n, "LENGTHC")) return p.call(pos, "lengthc", .oracle, c.args);
            if (eq(n, "UPPER") or eq(n, "LOWER")) {
                // SQLite's (sqlite3 can run them in an index), '' as NULL.
                if (argc != 1) return p.argCount(c);
                const x = try p.nullIfEmpty(try p.call(pos, if (eq(n, "UPPER")) "upper" else "lower", null, c.args));
                x.end = p.lastEnd();
                return x;
            }
            if (eq(n, "SUBSTRB") or eq(n, "SUBSTRC")) return p.call(pos, "substr", .oracle, c.args);
            if (eq(n, "INSTRB") or eq(n, "INSTRC")) return p.call(pos, "instr", .oracle, c.args);
            if (eq(n, "CHR")) return p.call(pos, "char", null, c.args);
            if (eq(n, "ASCII")) return p.call(pos, "unicode", null, c.args);
            if (eq(n, "SYS_GUID") and argc == 0) return p.call(pos, "randomblob", null, &.{try p.expr(pos, .{ .integer = "16" })});
            if (eq(n, "LNNVL")) {
                if (argc != 1) return p.argCount(c);
                const t = try p.expr(pos, .{ .is_bool = .{ .e = c.args[0], .value = true, .not = true } });
                return t;
            }
            if (eq(n, "NANVL")) {
                if (argc != 2) return p.argCount(c);
                return p.call(pos, "coalesce", null, c.args[0..1]);
            }
            if (eq(n, "TO_CLOB") or eq(n, "TO_NCHAR") or eq(n, "TO_NCLOB")) {
                if (argc != 1) return p.argCount(c);
                return p.call(pos, "to_char", .oracle, c.args);
            }
            if (eq(n, "RAWTOHEX")) {
                if (argc != 1) return p.argCount(c);
                return p.call(pos, "hex", null, c.args);
            }
            if (eq(n, "HEXTORAW")) {
                if (argc != 1) return p.argCount(c);
                return p.call(pos, "unhex", null, c.args);
            }
            if (eq(n, "LOG")) {
                if (argc != 2) return p.argCount(c);
            }
            if (eq(n, "ABS")) return p.call(pos, "abs", null, c.args);
            if (eq(n, "COALESCE")) return p.call(pos, "coalesce", null, c.args);
            if (eq(n, "NULLIF")) return p.call(pos, "nullif", null, c.args);
            if (eq(n, "REGEXP_LIKE") or eq(n, "REGEXP_SUBSTR") or eq(n, "REGEXP_REPLACE") or eq(n, "REGEXP_INSTR") or eq(n, "REGEXP_COUNT")) {
                return p.unsupported(c.name.pos, "regular expression functions");
            }
            if (eq(n, "TO_DATE") or eq(n, "ADD_MONTHS") or eq(n, "LAST_DAY") or eq(n, "NEXT_DAY") or eq(n, "TO_TIMESTAMP")) {
                const lower_name = try std.ascii.allocLowerString(p.arena, n);
                const e = try p.call(pos, lower_name, .oracle, c.args);
                try p.date_nodes.put(p.arena, e, if (eq(n, "TO_TIMESTAMP")) .timestamp else .date);
                return e;
            }
        }
        if (eq(n, "LISTAGG")) {
            if (argc < 1 or argc > 2) return p.argCount(c);
            const sep = if (argc == 2) c.args[1] else try p.expr(pos, .{ .string = "" });
            const f = try p.new(tree.Func, .{
                .name = .{ .text = "group_concat", .pos = c.name.pos },
                .args = try p.list(&.{ c.args[0], sep }),
                .distinct = c.distinct,
                .order_by = c.order_by,
                .over = c.over,
            });
            if (c.distinct and c.order_by.len > 0) return p.unsupported(c.name.pos, "LISTAGG(DISTINCT ...) WITHIN GROUP");
            return p.expr(pos, .{ .func = f });
        }
        const mapped: []const u8 = mappedName(n) orelse blk: {
            // Oracle's own: the dialect's table.
            const lower_name = try std.ascii.allocLowerString(p.arena, n);
            if (isDialectFunction(lower_name)) {
                const f = try p.new(tree.Func, .{ .name = .{ .text = lower_name, .pos = c.name.pos }, .dialect = .oracle, .args = c.args, .star = c.star, .distinct = c.distinct, .order_by = c.order_by, .filter = c.filter, .over = c.over });
                const e = try p.expr(pos, .{ .func = f });
                if ((eq(n, "TRUNC") or eq(n, "ROUND")) and argc >= 1 and try p.dateKindOf(c.args[0], &.{}) != .none) {
                    try p.date_nodes.put(p.arena, e, .date);
                }
                return e;
            }
            if (isSqliteAggregate(lower_name)) break :blk lower_name;
            // Another function: by the name as written (SQLite's, the
            // engine's or the application's, case-insensitive).
            break :blk n;
        };
        const f = try p.new(tree.Func, .{
            .name = .{ .text = mapped, .pos = c.name.pos },
            .args = c.args,
            .star = c.star,
            .distinct = c.distinct,
            .order_by = c.order_by,
            .filter = c.filter,
            .over = c.over,
        });
        return p.expr(pos, .{ .func = f });
    }

    fn argCount(p: *Parser, c: Call) Error {
        return p.fail(c.name.pos, "ORA-00909: invalid number of arguments", .{});
    }

    pub fn call(p: *Parser, pos: u32, name: []const u8, owner: ?Dialect, args: []const *Expr) Error!*Expr {
        const f = try p.new(tree.Func, .{ .name = .{ .text = name, .pos = pos }, .dialect = owner, .args = try p.list(args) });
        return p.expr(pos, .{ .func = f });
    }

    pub fn stringAt(p: *Parser, pos: u32, s: []const u8) Error!*Expr {
        return tree.expr(p.arena, pos, pos, .{ .string = s });
    }

    fn windowSpec(p: *Parser) Error!*tree.WindowSpec {
        _ = try p.expect(.lparen);
        var w: tree.WindowSpec = .{};
        const t = p.peek();
        if ((t.kind == .ident and !isReserved(t.text) and !t.isKw("partition") and !t.isKw("rows") and !t.isKw("range") and !t.isKw("groups")) or t.kind == .qident) {
            w.base = try p.colId();
        }
        if (p.eatKw("partition")) {
            try p.expectKw("by");
            w.partition = try p.exprList();
        }
        if (p.isKw("order")) {
            _ = p.advance();
            try p.expectKw("by");
            w.order_by = try p.sortList();
        }
        if (p.isAnyKw(&.{ "rows", "range", "groups" })) {
            const u = p.advance();
            var fr: tree.Frame = .{ .unit = if (u.isKw("rows")) .rows else if (u.isKw("range")) .range else .groups, .start = undefined, .end = null };
            if (p.eatKw("between")) {
                fr.start = try p.frameBound();
                try p.expectKw("and");
                fr.end = try p.frameBound();
            } else {
                fr.start = try p.frameBound();
            }
            if (p.eatKw("exclude")) {
                if (p.eatKw("current")) {
                    try p.expectKw("row");
                    fr.exclude = .current_row;
                } else if (p.eatKw("group")) {
                    fr.exclude = .group;
                } else if (p.eatKw("ties")) {
                    fr.exclude = .ties;
                } else {
                    try p.expectKw("no");
                    try p.expectKw("others");
                    fr.exclude = .no_others;
                }
            }
            w.frame = fr;
        }
        _ = try p.expect(.rparen);
        return p.new(tree.WindowSpec, w);
    }

    fn frameBound(p: *Parser) Error!tree.Bound {
        if (p.eatKw("unbounded")) {
            if (p.eatKw("preceding")) return .{ .kind = .unbounded_preceding };
            try p.expectKw("following");
            return .{ .kind = .unbounded_following };
        }
        if (p.eatKw("current")) {
            try p.expectKw("row");
            return .{ .kind = .current_row };
        }
        const e = try p.addExpr();
        if (p.eatKw("preceding")) return .{ .kind = .preceding, .expr = e };
        try p.expectKw("following");
        return .{ .kind = .following, .expr = e };
    }

    // ============================================================= types

    /// A type name: NUMBER[(p[,s])], VARCHAR2(n [BYTE|CHAR]), TIMESTAMP[(p)]
    /// [WITH [LOCAL] TIME ZONE], the ANSI names (INTEGER, DECIMAL, DOUBLE
    /// PRECISION ...) mapped to Oracle's.
    pub fn typeName(p: *Parser) Error!types.TypeName {
        const t = p.peek();
        if (t.kind != .ident) return p.missing("ORA-00902: invalid datatype");
        _ = p.advance();
        const w = t.text;
        var ty: types.TypeName = .{ .name = w, .pos = t.start };
        if (eq(w, "INTEGER") or eq(w, "INT") or eq(w, "SMALLINT")) {
            ty = .{ .name = "NUMBER", .scale = 0, .pos = t.start };
            return ty;
        }
        if (eq(w, "DECIMAL") or eq(w, "DEC") or eq(w, "NUMERIC")) ty.name = "NUMBER";
        if (eq(w, "REAL")) return .{ .name = "FLOAT", .precision = 63, .pos = t.start };
        if (eq(w, "DOUBLE")) {
            try p.expectKw("precision");
            return .{ .name = "FLOAT", .precision = 126, .pos = t.start };
        }
        if (eq(w, "VARCHAR") or eq(w, "STRING")) ty.name = "VARCHAR2";
        if (eq(w, "CHARACTER")) ty.name = if (p.eatKw("varying")) "VARCHAR2" else "CHAR";
        if (eq(w, "CHAR") and p.eatKw("varying")) ty.name = "VARCHAR2";
        if (eq(w, "NATIONAL")) {
            if (!p.eatKw("character")) try p.expectKw("char");
            ty.name = if (p.eatKw("varying")) "NVARCHAR2" else "NCHAR";
        }
        if (eq(w, "LONG") and p.eatKw("raw")) ty.name = "LONG RAW";
        if (eq(w, "INTERVAL")) {
            if (p.eatKw("year")) {
                if (p.peek().kind == .lparen) _ = try p.parenInt();
                try p.expectKw("to");
                try p.expectKw("month");
                return .{ .name = "INTERVAL YEAR TO MONTH", .pos = t.start };
            }
            try p.expectKw("day");
            if (p.peek().kind == .lparen) _ = try p.parenInt();
            try p.expectKw("to");
            try p.expectKw("second");
            if (p.peek().kind == .lparen) _ = try p.parenInt();
            return .{ .name = "INTERVAL DAY TO SECOND", .pos = t.start };
        }
        // Spelled as in the table of types.zig, upper case.
        ty.name = canonical(ty.name);
        if (types.family(ty.name) == null) return p.fail(t.start, "ORA-00902: invalid datatype", .{});
        if (p.peek().kind == .lparen) {
            _ = p.advance();
            if (p.isOp("*")) {
                _ = p.advance();
            } else {
                ty.precision = try p.signedInt();
            }
            if (p.eatKw("byte")) {} else if (p.eatKw("char")) ty.char_semantics = true;
            if (p.eat(.comma)) ty.scale = try p.signedInt();
            _ = try p.expect(.rparen);
            if (ty.precision == null and ty.scale == null) ty.scale = 0;
        }
        if (eq(ty.name, "TIMESTAMP")) {
            if (p.isKw("with") and (p.isKwAt(1, "time") or p.isKwAt(1, "local"))) {
                _ = p.advance();
                const local = p.eatKw("local");
                try p.expectKw("time");
                try p.expectKw("zone");
                ty.name = if (local) "TIMESTAMP WITH LOCAL TIME ZONE" else "TIMESTAMP WITH TIME ZONE";
            }
        }
        if ((eq(ty.name, "CHAR") or eq(ty.name, "NCHAR")) and ty.precision == null) ty.precision = 1;
        if (eq(ty.name, "NVARCHAR2") or eq(ty.name, "NCHAR")) ty.char_semantics = true;
        if ((eq(ty.name, "VARCHAR2") or eq(ty.name, "NVARCHAR2") or eq(ty.name, "RAW")) and ty.precision == null) {
            return p.fail(t.start, "ORA-00906: missing left parenthesis", .{});
        }
        return ty;
    }

    fn parenInt(p: *Parser) Error!i64 {
        _ = try p.expect(.lparen);
        const v = try p.signedInt();
        _ = try p.expect(.rparen);
        return v;
    }

    /// CAST(e AS type): xq_ora_cast(e, 'TYPE').
    fn castExpr(p: *Parser, pos: u32, e: *Expr, ty: types.TypeName) Error!*Expr {
        const spelling = try types.format(p.arena, ty);
        const x = try p.expr(pos, .{ .cast = .{ .e = e, .target_type = spelling, .mode = .{ .typed = .{ .func = "xq_ora_cast", .type_arg = spelling } } } });
        const fam = types.family(ty.name).?;
        if (fam == .date) try p.date_nodes.put(p.arena, x, .date);
        if (fam == .timestamp) try p.date_nodes.put(p.arena, x, .timestamp);
        return x;
    }

    // ============================================== dates (arithmetic)

    /// Whether `e` is a date or a timestamp, as far as the parser knows:
    /// what it made (SYSDATE, TO_DATE, date literals ...), a column of a
    /// DATE/TIMESTAMP type of a table in `scope`, date arithmetic.
    /// The type family of the column `e` refers to (null: not a column of
    /// a table the catalog has the type of).
    pub fn columnFamily(p: *Parser, e: *const Expr, scope: []const []const tree.FromItem) Error!?types.Family {
        if (e.kind != .column) return null;
        const decl = (try p.columnDeclType(e.kind.column, scope)) orelse return null;
        const ty = types.parse(decl) orelse return null;
        return types.family(ty.name);
    }

    pub fn dateKindOf(p: *Parser, e: *const Expr, scope: []const []const tree.FromItem) Error!Kind {
        if (p.date_nodes.get(e)) |k| return k;
        switch (e.kind) {
            .column => |names| {
                const decl = (try p.columnDeclType(names, scope)) orelse return .none;
                const ty = types.parse(decl) orelse return .none;
                return switch (types.family(ty.name) orelse return .none) {
                    .date => .date,
                    .timestamp => .timestamp,
                    else => .none,
                };
            },
            .subquery => |s| {
                // A scalar subquery: its column.
                if (s.body.* != .core) return .none;
                const c = s.body.core;
                if (c.cols.len != 1 or c.cols[0] != .expr) return .none;
                var inner: std.ArrayList([]const tree.FromItem) = .empty;
                try inner.appendSlice(p.arena, scope);
                try inner.append(p.arena, c.from);
                return p.dateKindOf(c.cols[0].expr.e, inner.items);
            },
            .func => |f| {
                if (f.dialect == .oracle and (std.mem.eql(u8, f.name.text, "trunc") or std.mem.eql(u8, f.name.text, "round")) and f.args.len >= 1) {
                    if (try p.dateKindOf(f.args[0], scope) != .none) return .date;
                }
                if (f.name.text.len > 0 and std.mem.eql(u8, f.name.text, "nullif")) return .none;
                if (std.mem.eql(u8, f.name.text, "coalesce") and f.args.len > 0) return p.dateKindOf(f.args[0], scope);
                return .none;
            },
            else => return .none,
        }
    }

    /// The declared type (catalog spelling) of the column `names` refers
    /// to among the tables of `scope` (innermost query last).
    fn columnDeclType(p: *Parser, names: []const Name, scope: []const []const tree.FromItem) Error!?[]const u8 {
        const ps = p.p orelse return null;
        var level = scope.len;
        while (level > 0) {
            level -= 1;
            for (scope[level]) |it| {
                if (it.source != .table) continue;
                const q = it.source.table;
                if (names.len >= 2) {
                    const label = if (it.alias) |a| a.name.text else q.name.text;
                    if (!std.ascii.eqlIgnoreCase(label, names[names.len - 2].text)) continue;
                }
                const t = (try p.findTable(q)) orelse continue;
                if (build.columnIndex(t, names[names.len - 1].text) < 0) {
                    if (names.len >= 2) return null;
                    continue;
                }
                const schema = catalog.schemaName(ps.db, t);
                const key = try std.fmt.allocPrint(p.arena, "{s}.{s}", .{ schema, t.name });
                const entries = p.decl_types.get(key) orelse blk: {
                    const es: []const catalog.Entry = if (catalog.exists(ps.db, schema))
                        catalog.entries(ps.db, p.arena, schema, t.name) catch &.{}
                    else
                        &.{};
                    try p.decl_types.put(p.arena, key, es);
                    break :blk es;
                };
                for (entries) |en| {
                    if (std.mem.eql(u8, en.key, catalog.Key.decl_type) and std.ascii.eqlIgnoreCase(en.col, names[names.len - 1].text)) return en.value;
                }
                return null;
            }
        }
        return null;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Whether SQLite database `db_name` has an object `name` of kind `kind`
/// (sequences are all in main).
fn objectExists(db: *int.Sqlite3, kind: Parser.Lookup, db_name: []const u8, name: []const u8) bool {
    return switch (kind) {
        .relation => build.findTable(db, name, db_name) != null,
        .index => build.findIndex(db, name, db_name) != null,
        .sequence => std.mem.eql(u8, db_name, "main") and sequenceExists(db, name),
    };
}

/// Whether sequence `name` exists (a query of xq_sequence, now).
pub fn sequenceExists(db: *int.Sqlite3, name: []const u8) bool {
    if (!catalog.sequence.exists(db, catalog.main_schema)) return false;
    var q = catalog.Query.init(db, "SELECT 1 FROM main.xq_sequence WHERE name=?1") catch return false;
    defer q.deinit();
    q.bindText(1, name) catch return false;
    return q.step() catch false;
}

/// Reserved words that may still name a function.
fn isFuncNameKeyword(w: []const u8) bool {
    return eq(w, "CHAR") or eq(w, "DATE") or eq(w, "RAW") or eq(w, "REPLACE");
}

fn canonical(w: []const u8) []const u8 {
    const names = [_][]const u8{ "NUMBER", "FLOAT", "BINARY_FLOAT", "BINARY_DOUBLE", "VARCHAR2", "NVARCHAR2", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG", "DATE", "TIMESTAMP", "BLOB", "RAW", "BOOLEAN", "ROWID", "UROWID", "LONG RAW", "JSON" };
    for (names) |n| if (eq(n, w)) return n;
    return w;
}

/// Oracle's names of SQLite's functions (and engine functions), when
/// they differ or need no dialect function.
fn mappedName(n: []const u8) ?[]const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "STDDEV", "xq_stddev_samp" }, .{ "STDDEV_SAMP", "xq_stddev_samp" }, .{ "STDDEV_POP", "xq_stddev_pop" },
        .{ "VARIANCE", "xq_var_samp" },  .{ "VAR_SAMP", "xq_var_samp" },       .{ "VAR_POP", "xq_var_pop" },
        .{ "COUNT", "count" },           .{ "SUM", "sum" },                    .{ "AVG", "avg" },
        .{ "MIN", "min" },               .{ "MAX", "max" },                    .{ "ROW_NUMBER", "row_number" },
        .{ "RANK", "rank" },             .{ "DENSE_RANK", "dense_rank" },      .{ "PERCENT_RANK", "percent_rank" },
        .{ "CUME_DIST", "cume_dist" },   .{ "NTILE", "ntile" },                .{ "LAG", "lag" },
        .{ "LEAD", "lead" },             .{ "FIRST_VALUE", "first_value" },    .{ "LAST_VALUE", "last_value" },
        .{ "NTH_VALUE", "nth_value" },
    };
    for (map) |m| if (eq(m[0], n)) return m[1];
    return null;
}

fn isSqliteAggregate(name: []const u8) bool {
    _ = name;
    return false;
}

fn isDialectFunction(name: []const u8) bool {
    return @import("../dialect.zig").spec(.oracle).function_map.get(name) != null;
}

/// Whether `e` refers to DUAL's column DUMMY.
fn mentionsDummy(e: *const Expr) bool {
    if (e.kind == .column) {
        const names = e.kind.column;
        return std.mem.eql(u8, names[names.len - 1].text, "DUMMY");
    }
    var it = Children.of(e);
    while (it.next()) |c| if (mentionsDummy(c)) return true;
    return false;
}

/// Whether a query's result columns or HAVING aggregate.
fn hasAggregate(c: *const tree.Core) bool {
    for (c.cols) |rc| switch (rc) {
        .expr => |x| if (aggregates(x.e)) return true,
        else => {},
    };
    if (c.having) |h| if (aggregates(h)) return true;
    return false;
}

fn aggregates(e: *const Expr) bool {
    if (e.kind == .func) {
        const f = e.kind.func;
        if (f.over == null) {
            const aggs = [_][]const u8{ "count", "sum", "avg", "min", "max", "group_concat", "xq_stddev_samp", "xq_stddev_pop", "xq_var_samp", "xq_var_pop", "total", "xq_ora_json_arrayagg", "xq_ora_json_objectagg" };
            for (aggs) |a| if (eq(a, f.name.text) and !(f.args.len > 1 and (eq(a, "min") or eq(a, "max")))) return true;
        }
    }
    if (e.kind == .subquery or e.kind == .exists or e.kind == .in_select) return false;
    var it = Children.of(e);
    while (it.next()) |child| if (aggregates(child)) return true;
    return false;
}

/// The conjuncts of `e` (AND), in order.
pub fn splitAnd(a: Allocator, e: *Expr, out: *std.ArrayList(*Expr)) error{OutOfMemory}!void {
    if (e.kind == .binary and e.kind.binary.op == .@"and") {
        try splitAnd(a, e.kind.binary.l, out);
        try splitAnd(a, e.kind.binary.r, out);
        return;
    }
    try out.append(a, e);
}

/// The direct subexpressions of an expression (not those of subqueries).
pub const Children = struct {
    buf: [4]*const Expr = undefined,
    extra: []const *Expr = &.{},
    n: usize = 0,
    i: usize = 0,
    j: usize = 0,

    pub fn of(e: *const Expr) Children {
        var c: Children = .{};
        switch (e.kind) {
            .unary => |u| c.add(u.e),
            .binary => |b| {
                c.add(b.l);
                c.add(b.r);
            },
            .div => |d| {
                c.add(d.l);
                c.add(d.r);
            },
            .compare => |x| {
                c.add(x.l);
                c.add(x.r);
            },
            .concat => |x| c.extra = x.args,
            .cast => |x| c.add(x.e),
            .func => |f| {
                c.extra = f.args;
                if (f.filter) |x| c.add(x);
            },
            .case => |x| {
                if (x.operand) |o| c.add(o);
                if (x.@"else") |o| c.add(o);
                c.extra = x.whens;
            },
            .in_list => |x| {
                c.add(x.e);
                c.extra = x.items;
            },
            .in_select => |x| c.add(x.e),
            .between => |x| {
                c.add(x.e);
                c.add(x.lo);
                c.add(x.hi);
            },
            .like => |x| {
                c.add(x.e);
                c.add(x.pat);
                if (x.escape == .expr) c.add(x.escape.expr);
            },
            .is_null => |x| c.add(x.e),
            .is_bool => |x| c.add(x.e),
            .row => |items| c.extra = items,
            .collate => |x| c.add(x.e),
            .coerce => |x| c.add(x.e),
            else => {},
        }
        return c;
    }

    fn add(c: *Children, e: *const Expr) void {
        c.buf[c.n] = e;
        c.n += 1;
    }

    pub fn next(c: *Children) ?*const Expr {
        if (c.i < c.n) {
            c.i += 1;
            return c.buf[c.i - 1];
        }
        if (c.j < c.extra.len) {
            c.j += 1;
            return c.extra[c.j - 1];
        }
        return null;
    }
};
