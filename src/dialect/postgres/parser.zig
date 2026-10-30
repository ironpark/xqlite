//! A recursive descent parser for the PostgreSQL statements the dialect
//! supports (see docs/postgres.md), producing the syntax tree
//! IR (src/ir/tree.zig) with PostgreSQL's semantics resolved:
//!
//!  - names: unquoted identifiers folded (lexer.zig); schemas mapped to
//!    SQLite databases (`public` is main, `pg_temp` temp, an attached
//!    database itself, a schema of CREATE SCHEMA main with the mangled
//!    name "s.t" of catalog/schema.zig, aliased t), unqualified names
//!    looked up along search_path (session.zig); information_schema and
//!    pg_catalog views replaced by the queries of catalog_views.zig;
//!  - casts as types.castPlan() says, '\x..'::bytea a blob; LIKE
//!    case-sensitive and ILIKE folding, `\` their default escape; `||`
//!    NULL if an operand is; `/` SQLite's (integer division of integers);
//!  - functions mapped to SQLite's (substring is substr ...), the special
//!    syntax (now(), EXTRACT, trim(... FROM ...)) rewritten, a function
//!    of the dialect's table marked as such (tree.Func.dialect);
//!  - ORDER BY without NULLS FIRST/LAST puts NULLs last ascending and
//!    first descending (SQLite does the opposite);
//!  - result columns named as PostgreSQL names them (FigureColname():
//!    "?column?", the function, the type of a cast of a constant ...);
//!  - INSERT with fewer values than columns fills the leading ones, a
//!    string constant for a numeric column is the number it spells;
//!  - DDL: types mapped to STRICT storage with the checks of types.zig,
//!    SERIAL and GENERATED ... AS IDENTITY to tree.Identity columns.
//!
//! What needs the schema (schema names, catalog views, INSERT's columns)
//! reads it through `p`, the statement being compiled.
//!
//! Operator precedence is PostgreSQL's (lowest first): OR, AND, NOT,
//! IS/ISNULL/NOTNULL, comparison, BETWEEN/IN/LIKE/ILIKE, other operators
//! (||, ->, & ...), + -, * / %, ^, unary + - ~, ::/COLLATE.
//!
//! A statement is lexed up to its terminating semicolon first (lexing
//! does not depend on parsing), so lookahead never fails; `end` is the
//! offset after the semicolon, where the next statement starts.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const ir = @import("../../ir/ir.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const views = @import("catalog_views.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
const pg_state = @import("state.zig");

const Token = lexer.Token;
const Name = tree.Name;
const Expr = tree.Expr;
const Allocator = std.mem.Allocator;

pub const Error = error{ ParseFailed, OutOfMemory };

/// PostgreSQL's reserved keywords and the "type_func_name" ones: neither
/// can be a column name or a bare alias.
const reserved = wordSet(&.{
    "all",           "analyse",      "analyze",      "and",               "any",          "array",
    "as",            "asc",          "asymmetric",   "both",              "case",         "cast",
    "check",         "collate",      "column",       "constraint",        "create",       "current_catalog",
    "current_date",  "current_role", "current_time", "current_timestamp", "current_user", "default",
    "deferrable",    "desc",         "distinct",     "do",                "else",         "end",
    "except",        "false",        "fetch",        "for",               "foreign",      "from",
    "grant",         "group",        "having",       "in",                "initially",    "intersect",
    "into",          "lateral",      "leading",      "limit",             "localtime",    "localtimestamp",
    "not",           "null",         "offset",       "on",                "only",         "or",
    "order",         "placing",      "primary",      "references",        "returning",    "select",
    "session_user",  "some",         "symmetric",    "system_user",       "table",        "then",
    "to",            "trailing",     "true",         "union",             "unique",       "user",
    "using",         "variadic",     "when",         "where",             "window",       "with",
    // type_func_name_keyword
    "authorization", "binary",       "collation",    "concurrently",      "cross",        "current_schema",
    "freeze",        "full",         "ilike",        "inner",             "is",           "isnull",
    "join",          "left",         "like",         "natural",           "notnull",      "outer",
    "overlaps",      "right",        "similar",      "tablesample",       "verbose",
});

/// A set of (lower-case) words.
fn wordSet(comptime words: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(10_000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

pub fn isReserved(word: []const u8) bool {
    return reserved.has(word);
}

/// The words that start a type in a typed literal (`DATE '2024-01-01'`).
const type_words = wordSet(&.{
    "date",  "time",      "timestamp", "timestamptz", "timetz",  "interval", "boolean", "bool",
    "int",   "integer",   "int2",      "int4",        "int8",    "smallint", "bigint",  "real",
    "float", "float4",    "float8",    "double",      "numeric", "decimal",  "text",    "varchar",
    "char",  "character", "bytea",     "uuid",        "json",    "jsonb",
});

/// The error of a statement that does not lex (Parser.init()).
pub const LexError = struct {
    msg: []const u8 = "",
    pos: usize = 0,
};

/// `[schema.]name` as written (the schema is PostgreSQL's).
pub const QName = struct {
    schema: ?Name = null,
    name: Name,
};

/// What PostgreSQL names a result column that is this node, for nodes
/// the parser rewrote: a call (its name as written), a cast (the name
/// its operand gives, else the type's internal name).
const Fig = union(enum) {
    call: []const u8,
    cast: struct { strong: ?[]const u8, type_name: []const u8 },
};

/// A function call as written, before it is resolved (callExpr()).
const Call = struct {
    name: Name,
    args: []*Expr = &.{},
    /// f(*)
    star: bool = false,
    distinct: bool = false,
    order_by: []tree.SortItem = &.{},
    filter: ?*Expr = null,
    over: ?*tree.WindowSpec = null,
    /// The name of the column of a call written with a special syntax
    /// (substring(x FROM a) is "substring", not "substr").
    label: ?[]const u8 = null,
};

pub const Parser = struct {
    arena: Allocator,
    src: [:0]const u8,
    toks: []Token,
    i: usize = 0,
    err_msg: []const u8 = "",
    err_pos: usize = 0,
    /// Offset after the statement (and its semicolon).
    end: usize,
    /// The statement being compiled, for what depends on the schema; null
    /// to parse without it (schema names other than public and pg_temp
    /// are then unknown, catalog views are tables).
    p: ?*int.Parse = null,
    /// The error is in `p` already (the schema could not be read).
    err_in_parse: bool = false,
    schema_read: bool = false,
    /// The registered schemas (catalog/schema.zig), read once.
    schemas: ?[]const nsp.Info = null,
    /// The names of the WITH queries of the statement: an unqualified
    /// relation with one of these names is not looked up in search_path.
    cte_names: std.ArrayList([]const u8) = .empty,
    /// The table CREATE TABLE creates (its REFERENCES may name it).
    creating: ?nsp.Target = null,
    /// Unqualified names are not looked up in search_path (the text of a
    /// catalog view).
    no_path: bool = false,
    /// Result column names of rewritten nodes.
    figs: std.AutoHashMapUnmanaged(*const Expr, Fig) = .empty,

    /// Lex the statement that starts at `pos` (blank text and leading
    /// semicolons are skipped). An empty statement has no tokens but eof.
    /// A lexical error fails with its message and offset in `lex_error`.
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

    /// The end offset of the last token consumed.
    fn lastEnd(p: *const Parser) u32 {
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
        if (!p.eatKw(kw)) return p.syntaxError();
    }

    pub fn isAnyKw(p: *const Parser, comptime kws: []const []const u8) bool {
        return p.peek().isAnyKw(kws);
    }

    /// An optional IF EXISTS: whether it is there.
    pub fn ifExists(p: *Parser) Error!bool {
        if (!p.eatKw("if")) return false;
        try p.expectKw("exists");
        return true;
    }

    /// An optional IF NOT EXISTS: whether it is there.
    pub fn ifNotExists(p: *Parser) Error!bool {
        if (!p.eatKw("if")) return false;
        try p.expectKw("not");
        try p.expectKw("exists");
        return true;
    }

    pub fn eat(p: *Parser, kind: lexer.Kind) bool {
        if (p.peek().kind != kind) return false;
        _ = p.advance();
        return true;
    }

    pub fn expect(p: *Parser, kind: lexer.Kind) Error!Token {
        if (p.peek().kind != kind) return p.syntaxError();
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

    /// PostgreSQL's `syntax error at or near "X"` for the next token.
    pub fn syntaxError(p: *Parser) Error {
        const t = p.peek();
        // The end of a statement: PostgreSQL names its semicolon.
        if (t.kind == .eof and t.start < p.src.len and p.src[t.start] == ';') return p.fail(t.start, "syntax error at or near \";\"", .{});
        if (t.kind == .eof) return p.fail(t.start, "syntax error at end of input", .{});
        return p.fail(t.start, "syntax error at or near \"{s}\"", .{p.src[t.start..t.end]});
    }

    fn unsupported(p: *Parser, pos: usize, what: []const u8) Error {
        return p.fail(pos, "{s} is not supported", .{what});
    }

    fn new(p: *Parser, comptime T: type, v: T) Error!*T {
        return tree.new(p.arena, T, v);
    }

    fn expr(p: *Parser, pos: u32, kind: tree.Kind) Error!*Expr {
        return tree.expr(p.arena, pos, p.lastEnd(), kind);
    }

    /// A node spanning `l` to `r`.
    fn span(p: *Parser, l: *const Expr, r: *const Expr, kind: tree.Kind) Error!*Expr {
        return tree.expr(p.arena, l.pos, r.end, kind);
    }

    fn list(p: *Parser, items: []const *Expr) Error![]*Expr {
        return p.arena.dupe(*Expr, items);
    }

    // ------------------------------------------------------------ schema

    /// Read the schema (once) for what depends on it.
    pub fn readSchema(p: *Parser) Error!void {
        if (p.schema_read) return;
        const ps = p.p orelse return;
        p.schema_read = true;
        ir.stmt.readSchema(ps) catch {
            p.err_in_parse = true;
            return error.ParseFailed;
        };
    }

    /// The registered schemas (read once per statement); none when
    /// parsing without the statement.
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

    /// The schema names of the connection's search_path.
    pub fn searchPath(p: *Parser) Error![]const []const u8 {
        const text = if (p.p) |ps| ps.db.xq.postgres.searchPath() else pg_state.default_search_path;
        return pg_state.splitPath(p.arena, text);
    }

    pub const schema_config: nsp.Config = .{ .default_schema = "public", .temp_schema = "pg_temp" };

    /// The SQLite object of `s.n`: public is main, pg_temp temp, an
    /// attached database itself, a schema of CREATE SCHEMA main with the
    /// mangled name "s.n".
    pub fn qualified(p: *Parser, s: Name, n: Name) Error!nsp.Target {
        const ps = p.p orelse {
            if (eql(s.text, "public")) return .{ .db = "main", .name = n.text, .bare = n.text };
            if (eql(s.text, "pg_temp")) return .{ .db = "temp", .name = n.text, .bare = n.text };
            return p.fail(s.pos, "schema \"{s}\" does not exist", .{s.text});
        };
        try p.readSchema();
        return nsp.resolve(ps.db, p.arena, try p.registered(), schema_config, s.text, n.text) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NoSuchSchema => p.fail(s.pos, "schema \"{s}\" does not exist", .{s.text}),
        };
    }

    pub const Lookup = enum { relation, index, sequence };

    /// An unqualified name looked up in search_path: `keep` it (an object
    /// of public or pg_temp, a WITH query, or not found while public is
    /// on the path: SQLite's lookup gives the same answer), the `target`
    /// in a schema of CREATE SCHEMA, or `missing` (not on the path, but
    /// in public, which is not).
    pub const Found = union(enum) { keep, target: nsp.Target, missing };

    pub fn unqualified(p: *Parser, n: Name, kind: Lookup) Error!Found {
        const ps = p.p orelse return .keep;
        if (p.no_path) return .keep;
        if (kind == .relation) for (p.cte_names.items) |c| if (eql(c, n.text)) return .keep;
        const schemas = try p.registered();
        const path = try p.searchPath();
        var has_public = false;
        for (path) |e| has_public = has_public or eql(e, "public");
        if (schemas.len == 0 and has_public) return .keep;
        const db = ps.db;
        if (kind != .sequence and objectExists(db, kind, "temp", n.text)) return .keep;
        for (path) |e| {
            if (eql(e, "public")) {
                if (objectExists(db, kind, "main", n.text)) return .keep;
                continue;
            }
            const s = nsp.find(schemas, e) orelse continue;
            const m = try nsp.mangle(p.arena, s.name, n.text);
            if (objectExists(db, kind, "main", m)) return .{ .target = .{ .db = "main", .name = m, .mangled = true, .bare = n.text } };
        }
        if (!has_public and objectExists(db, kind, "main", n.text)) return .missing;
        return .keep;
    }

    /// Where an object DDL creates goes: `q`'s schema, else temp for a
    /// temporary object, else the first schema of search_path that
    /// exists (PostgreSQL's current_schema()).
    pub fn createTarget(p: *Parser, q: QName, temp: bool) Error!nsp.Target {
        if (q.schema) |s| {
            const t = try p.qualified(s, q.name);
            if (temp and !eql(t.db, "temp")) return p.fail(s.pos, "cannot create temporary relation in non-temporary schema", .{});
            return t;
        }
        if (temp) return .{ .db = "temp", .name = q.name.text, .bare = q.name.text };
        if (p.p == null) return .{ .db = "main", .name = q.name.text, .bare = q.name.text };
        const schemas = try p.registered();
        for (try p.searchPath()) |e| {
            if (eql(e, "public")) return .{ .db = "main", .name = q.name.text, .bare = q.name.text };
            const s = nsp.find(schemas, e) orelse continue;
            return .{ .db = "main", .name = try nsp.mangle(p.arena, s.name, q.name.text), .mangled = true, .bare = q.name.text };
        }
        return p.fail(q.name.pos, "no schema has been selected to create in", .{});
    }

    /// The prefix "s." of a mangled target ("" for none).
    pub fn prefixOf(t: nsp.Target) []const u8 {
        return if (t.mangled) t.name[0 .. t.name.len - t.bare.len] else "";
    }

    /// A relation resolved, and the alias a mangled one takes.
    pub const Rel = struct { q: tree.QName, alias: ?Name = null };

    /// The table (or other relation) `q` of a query or DML statement.
    fn relation(p: *Parser, q: QName) Error!Rel {
        return p.lookup(q, .relation);
    }

    /// The constant name of nextval('name') etc. resolved as PostgreSQL's
    /// regclass reads it ([schema.]name, unquoted parts folded, the
    /// schema from search_path) into the name of xq_sequence, which the
    /// sequence functions take as is.
    fn sequenceArg(p: *Parser, e: *Expr) Error!*Expr {
        const text = e.kind.string;
        var parts: std.ArrayList(Name) = .empty;
        var cur: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (i == text.len or text[i] == '.') {
                try parts.append(p.arena, .{ .text = cur.items, .pos = e.pos });
                cur = .empty;
                continue;
            }
            if (text[i] == '"') {
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '"') {
                        if (i + 1 < text.len and text[i + 1] == '"') {
                            i += 1;
                        } else break;
                    }
                    try cur.append(p.arena, text[i]);
                }
                continue;
            }
            try cur.append(p.arena, std.ascii.toLower(text[i]));
        }
        const n = parts.items;
        if (n.len > 3 or n[n.len - 1].text.len == 0) return e;
        const name: []const u8 = if (n.len == 1) switch (try p.unqualified(n[0], .sequence)) {
            .keep, .missing => n[0].text,
            .target => |t| t.name,
        } else blk: {
            const t = try p.qualified(n[n.len - 2], n[n.len - 1]);
            if (t.mangled) break :blk t.name;
            // public.q: q if it exists, else the name as written (not found).
            if (p.p) |ps| if (eql(t.db, "main") and !objectExists(ps.db, .sequence, "main", t.bare)) break :blk text;
            break :blk t.bare;
        };
        return p.expr(e.pos, .{ .string = name });
    }

    /// `q` resolved (see unqualified()); an unqualified name missing from
    /// search_path fails as PostgreSQL does.
    /// A mangled name is written without its database (main): a view
    /// naming it still works where main is attached under another name.
    pub fn lookup(p: *Parser, q: QName, kind: Lookup) Error!Rel {
        if (q.schema) |s| {
            // PostgreSQL names the relation, not its schema, when a
            // query's schema does not exist.
            if (p.p != null and !eql(s.text, "public") and !eql(s.text, "pg_temp")) {
                const ps = p.p.?;
                try p.readSchema();
                if (build.findDbName(ps.db, s.text) == null and nsp.find(try p.registered(), s.text) == null) {
                    return p.fail(s.pos, "{s} \"{s}.{s}\" does not exist", .{ if (kind == .index) "index" else "relation", s.text, q.name.text });
                }
            }
            const t = try p.qualified(s, q.name);
            if (t.mangled) return .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name };
            return .{ .q = .{ .schema = .{ .text = t.db, .pos = s.pos }, .name = .{ .text = t.name, .pos = q.name.pos } } };
        }
        return switch (try p.unqualified(q.name, kind)) {
            .keep => .{ .q = .{ .name = q.name } },
            .target => |t| .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name },
            .missing => p.fail(q.name.pos, "{s} \"{s}\" does not exist", .{ switch (kind) {
                .relation, .sequence => "relation",
                .index => "index",
            }, q.name.text }),
        };
    }

    /// The query standing for an information_schema or pg_catalog view
    /// (null: not one).
    fn catalogView(p: *Parser, q: QName) Error!?*tree.Select {
        const ps = p.p orelse return null;
        try p.readSchema();
        const schema: ?[]const u8 = if (q.schema) |s| s.text else null;
        if (schema == null and build.findTable(ps.db, q.name.text, null) != null) return null;
        const text = (try views.definition(ps, schema, q.name.text)) orelse {
            if (schema) |s| if (eql(s, "information_schema") or eql(s, "pg_catalog")) {
                return p.fail(q.name.pos, "relation \"{s}.{s}\" does not exist", .{ s, q.name.text });
            };
            return null;
        };
        var sub = Parser.init(p.arena, text, 0, null) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => return p.fail(q.name.pos, "internal error in the definition of {s}", .{q.name.text}),
        };
        sub.p = ps;
        sub.schema_read = true;
        sub.no_path = true;
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
            if (p.peek().kind == .dot) {
                // catalog.schema.name: the catalog is the database.
                _ = p.advance();
                const third = try p.anyName();
                return .{ .schema = second, .name = third };
            }
            return .{ .schema = first, .name = second };
        }
        return .{ .name = first };
    }

    fn nameList(p: *Parser) Error![]Name {
        var out: std.ArrayList(Name) = .empty;
        while (true) {
            try out.append(p.arena, try p.colId());
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    fn parenNameList(p: *Parser) Error![]Name {
        _ = try p.expect(.lparen);
        const l = try p.nameList();
        _ = try p.expect(.rparen);
        return l;
    }

    pub fn signedInt(p: *Parser) Error!i64 {
        var neg = false;
        if (p.eatOp("-")) neg = true else _ = p.eatOp("+");
        const t = p.peek();
        if (t.kind != .integer) return p.syntaxError();
        _ = p.advance();
        const v = std.fmt.parseInt(i64, t.text, 10) catch return p.fail(t.start, "value \"{s}\" is out of range for type bigint", .{t.text});
        return if (neg) -v else v;
    }

    // ======================================================== statements

    pub fn statement(p: *Parser) Error!tree.Stmt {
        const s = try p.stmt();
        if (p.peek().kind != .eof) return p.syntaxError();
        return s;
    }

    fn stmt(p: *Parser) Error!tree.Stmt {
        const t = p.peek();
        if (t.kind == .lparen) return .{ .select = try p.select() };
        if (t.kind != .ident) return p.syntaxError();
        const w = t.text;
        if (eql(w, "select") or eql(w, "values") or eql(w, "table")) return .{ .select = try p.select() };
        if (eql(w, "with")) {
            const with = try p.withClause();
            if (p.isKw("insert")) return .{ .insert = try p.insert(with) };
            if (p.isKw("update")) return .{ .update = try p.update(with) };
            if (p.isKw("delete")) return .{ .delete = try p.delete(with) };
            const s = try p.selectAfterWith(with, t.start);
            return .{ .select = s };
        }
        if (eql(w, "insert")) return .{ .insert = try p.insert(null) };
        if (eql(w, "update")) return .{ .update = try p.update(null) };
        if (eql(w, "delete")) return .{ .delete = try p.delete(null) };
        if (eql(w, "begin")) {
            _ = p.advance();
            _ = p.eatKw("work") or p.eatKw("transaction");
            try p.transactionModes();
            return .begin;
        }
        if (eql(w, "start")) {
            _ = p.advance();
            try p.expectKw("transaction");
            try p.transactionModes();
            return .begin;
        }
        if (eql(w, "commit") or eql(w, "end")) {
            _ = p.advance();
            _ = p.eatKw("work") or p.eatKw("transaction");
            try p.andChain();
            return .commit;
        }
        if (eql(w, "rollback") or eql(w, "abort")) {
            _ = p.advance();
            _ = p.eatKw("work") or p.eatKw("transaction");
            if (eql(w, "rollback") and p.eatKw("to")) {
                _ = p.eatKw("savepoint");
                return .{ .rollback_to = try p.colId() };
            }
            try p.andChain();
            return .rollback;
        }
        if (eql(w, "savepoint")) {
            _ = p.advance();
            return .{ .savepoint = try p.colId() };
        }
        if (eql(w, "release")) {
            _ = p.advance();
            _ = p.eatKw("savepoint");
            return .{ .release = try p.colId() };
        }
        if (eql(w, "create")) return p.create();
        if (eql(w, "drop")) return .{ .drop = try p.drop() };
        if (eql(w, "alter")) return .{ .alter_table = try p.alterTable() };
        if (eql(w, "truncate")) return .{ .truncate = try p.truncate() };
        if (eql(w, "explain")) {
            _ = p.advance();
            if (p.peek().kind == .lparen) {
                // EXPLAIN (option [value], ...)
                var depth: usize = 0;
                while (true) {
                    const x = p.advance();
                    if (x.kind == .lparen) depth += 1;
                    if (x.kind == .rparen) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    if (x.kind == .eof) return p.syntaxError();
                }
            } else {
                _ = p.eatKw("analyze") or p.eatKw("analyse");
                _ = p.eatKw("verbose");
            }
            const inner = try p.new(tree.Stmt, try p.stmt());
            return .{ .explain = inner };
        }
        return p.syntaxError();
    }

    fn transactionModes(p: *Parser) Error!void {
        while (true) {
            if (p.eatKw("isolation")) {
                try p.expectKw("level");
                if (p.eatKw("serializable")) {} else if (p.eatKw("repeatable")) {
                    try p.expectKw("read");
                } else if (p.eatKw("read")) {
                    if (!p.eatKw("committed")) try p.expectKw("uncommitted");
                } else return p.syntaxError();
            } else if (p.eatKw("read")) {
                if (!p.eatKw("write")) try p.expectKw("only");
            } else if (p.isKw("not") and p.isKwAt(1, "deferrable")) {
                _ = p.advance();
                _ = p.advance();
            } else if (p.eatKw("deferrable")) {} else break;
            _ = p.eat(.comma);
        }
    }

    fn andChain(p: *Parser) Error!void {
        if (p.eatKw("and")) {
            const pos = p.peek().start;
            if (p.eatKw("no")) {
                try p.expectKw("chain");
            } else {
                try p.expectKw("chain");
                return p.unsupported(pos, "AND CHAIN");
            }
        }
    }

    // ============================================================ SELECT

    fn startsSelect(p: *const Parser, k: usize) bool {
        const t = p.peekAt(k);
        return t.isAnyKw(&.{ "select", "values", "with", "table" });
    }

    /// Whether a parenthesized query starts here: `(` then (more `(`s
    /// and) SELECT, VALUES, WITH or TABLE.
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

    fn selectAfterWith(p: *Parser, with: ?*tree.With, pos: u32) Error!*tree.Select {
        const body = try p.setExpr();
        var s: tree.Select = .{ .with = with, .body = body, .pos = pos };
        if (p.isKw("order")) {
            _ = p.advance();
            try p.expectKw("by");
            s.order_by = try p.sortList();
        }
        // LIMIT/OFFSET/FETCH in any order, and locking clauses.
        while (true) {
            if (p.eatKw("limit")) {
                if (s.limit != null) return p.fail(p.toks[p.i - 1].start, "multiple LIMIT clauses not allowed", .{});
                if (p.eatKw("all")) continue;
                s.limit = try p.expr0();
                if (p.eat(.comma)) return p.fail(p.toks[p.i - 1].start, "LIMIT #,# syntax is not supported", .{});
            } else if (p.eatKw("offset")) {
                if (s.offset != null) return p.fail(p.toks[p.i - 1].start, "multiple OFFSET clauses not allowed", .{});
                s.offset = try p.expr0();
                _ = p.eatKw("row") or p.eatKw("rows");
            } else if (p.isKw("fetch")) {
                const at = p.advance().start;
                if (s.limit != null) return p.fail(at, "multiple LIMIT clauses not allowed", .{});
                if (!p.eatKw("first")) try p.expectKw("next");
                if (p.isKw("row") or p.isKw("rows")) {
                    s.limit = try p.expr(at, .{ .integer = "1" });
                } else {
                    s.limit = try p.unary();
                }
                if (!p.eatKw("row")) try p.expectKw("rows");
                if (p.isKw("with")) return p.unsupported(at, "FETCH ... WITH TIES");
                try p.expectKw("only");
            } else if (p.isKw("for")) {
                // FOR UPDATE/SHARE: a no-op, writers are serialized.
                _ = p.advance();
                if (p.eatKw("update")) {} else if (p.eatKw("share")) {} else if (p.eatKw("no")) {
                    try p.expectKw("key");
                    try p.expectKw("update");
                } else if (p.eatKw("key")) {
                    try p.expectKw("share");
                } else return p.syntaxError();
                if (p.eatKw("of")) _ = try p.nameList();
                if (p.eatKw("nowait")) {} else if (p.eatKw("skip")) try p.expectKw("locked");
            } else break;
        }
        // A parenthesized query alone is that query.
        if (with == null and s.order_by.len == 0 and s.limit == null and s.offset == null) {
            if (body.* == .nested) return body.nested;
        }
        return p.new(tree.Select, s);
    }

    fn withClause(p: *Parser) Error!*tree.With {
        try p.expectKw("with");
        const recursive = p.eatKw("recursive");
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
            if (p.isAnyKw(&.{ "insert", "update", "delete" })) {
                return p.unsupported(p.peek().start, "a data-modifying statement in WITH");
            }
            cte.select = try p.select();
            _ = try p.expect(.rparen);
            try ctes.append(p.arena, cte);
            if (!p.eat(.comma)) break;
        }
        return p.new(tree.With, .{ .recursive = recursive, .ctes = ctes.items });
    }

    /// UNION and EXCEPT, left to right, over INTERSECT (which binds
    /// tighter in PostgreSQL).
    fn setExpr(p: *Parser) Error!*tree.Body {
        var left = try p.intersectExpr();
        while (true) {
            const op: tree.SetOp = if (p.eatKw("union")) .@"union" else if (p.eatKw("except")) .except else break;
            const all = p.eatKw("all");
            if (!all) _ = p.eatKw("distinct");
            const right = try p.intersectExpr();
            left = try p.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = left, .right = right } });
        }
        return left;
    }

    fn intersectExpr(p: *Parser) Error!*tree.Body {
        var left = try p.simpleSelect();
        while (p.eatKw("intersect")) {
            const all = p.eatKw("all");
            if (!all) _ = p.eatKw("distinct");
            const right = try p.simpleSelect();
            left = try p.new(tree.Body, .{ .compound = .{ .op = .intersect, .all = all, .left = left, .right = right } });
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
                _ = try p.expect(.lparen);
                try rows.append(p.arena, try p.exprList());
                _ = try p.expect(.rparen);
                if (!p.eat(.comma)) break;
            }
            return p.new(tree.Body, .{ .values = rows.items });
        }
        if (t.isKw("table")) {
            _ = p.advance();
            const name = try p.qname();
            var cols = try p.arena.alloc(tree.ResultCol, 1);
            cols[0] = .{ .star = t.start };
            var from = try p.arena.alloc(tree.FromItem, 1);
            from[0] = try p.tableItem(name);
            return p.new(tree.Body, .{ .core = try p.new(tree.Core, .{ .cols = cols, .from = from, .pos = t.start }) });
        }
        return p.syntaxError();
    }

    fn core(p: *Parser) Error!*tree.Core {
        const pos = p.advance().start; // SELECT
        var c: tree.Core = .{ .cols = &.{}, .pos = pos };
        if (p.eatKw("distinct")) {
            c.distinct = true;
            if (p.isKw("on")) return p.unsupported(p.peek().start, "DISTINCT ON");
        } else _ = p.eatKw("all");
        if (!p.atClauseEnd()) c.cols = try p.targetList();
        if (p.isKw("into")) return p.unsupported(p.peek().start, "SELECT INTO");
        if (c.cols.len == 0) return p.unsupported(p.peek().start, "SELECT without result columns");
        if (p.eatKw("from")) c.from = try p.fromList();
        if (p.eatKw("where")) c.where = try p.expr0();
        if (p.isKw("group")) {
            _ = p.advance();
            try p.expectKw("by");
            _ = p.eatKw("all");
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
        return p.new(tree.Core, c);
    }

    /// The end of the SELECT list: FROM or another clause, or the end.
    fn atClauseEnd(p: *const Parser) bool {
        const t = p.peek();
        if (t.kind == .eof or t.kind == .rparen) return true;
        const words = [_][]const u8{ "from", "where", "group", "having", "window", "order", "limit", "offset", "fetch", "union", "intersect", "except", "into", "for" };
        for (words) |w| if (t.isKw(w)) return true;
        return false;
    }

    pub fn targetList(p: *Parser) Error![]tree.ResultCol {
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
            if (a.kind == .qident or (a.kind == .ident and !isReserved(a.text))) {
                _ = p.advance();
                label = .{ .text = a.text, .pos = a.start };
            }
        }
        return .{ .expr = .{ .e = e, .alias = label, .name = if (label == null) p.columnName(e) else null } };
    }

    // ------------------------------------------------------------ naming

    /// The name PostgreSQL gives a result column without an alias
    /// (FigureColname()): the column, the function, the type of a cast of
    /// a constant, "case", "exists" ..., or "?column?". Null for a column
    /// reference, which SQLite names after the column itself.
    fn columnName(p: *const Parser, e: *const Expr) ?[]const u8 {
        if (p.figs.get(e)) |f| return switch (f) {
            .call => |n| n,
            .cast => |c| c.strong orelse types.internalName(c.type_name),
        };
        return switch (e.kind) {
            .column => null,
            .collate => |c| p.columnName(c.e),
            .case => "case",
            .exists => "exists",
            .row => "row",
            .boolean => "bool",
            .subquery => |s| p.subqueryName(s),
            else => "?column?",
        };
    }

    /// A name a cast keeps (FigureColname()'s strength 2): of a column, a
    /// call, EXISTS, ROW, a scalar subquery.
    fn strongName(p: *const Parser, e: *const Expr) ?[]const u8 {
        if (p.figs.get(e)) |f| return switch (f) {
            .call => |n| n,
            .cast => |c| c.strong,
        };
        return switch (e.kind) {
            .column => |names| names[names.len - 1].text,
            .collate => |c| p.strongName(c.e),
            .exists => "exists",
            .row => "row",
            .subquery => |s| p.subqueryName(s),
            else => null,
        };
    }

    fn subqueryName(p: *const Parser, s: *const tree.Select) []const u8 {
        if (s.body.* == .core) {
            const cols = s.body.core.cols;
            if (cols.len >= 1) switch (cols[0]) {
                .expr => |x| {
                    if (x.alias) |a| return a.text;
                    return p.strongName(x.e) orelse "?column?";
                },
                else => {},
            };
        }
        return "?column?";
    }

    fn setFig(p: *Parser, e: *const Expr, f: Fig) Error!void {
        try p.figs.put(p.arena, e, f);
    }

    pub fn sortList(p: *Parser) Error![]tree.SortItem {
        var out: std.ArrayList(tree.SortItem) = .empty;
        while (true) {
            var item: tree.SortItem = .{ .expr = try p.expr0() };
            if (p.eatKw("asc")) {
                item.dir = .asc;
            } else if (p.eatKw("desc")) {
                item.dir = .desc;
            } else if (p.isKw("using")) {
                const at = p.advance().start;
                if (p.eatOp("<")) item.dir = .asc else if (p.eatOp(">")) item.dir = .desc else return p.unsupported(at, "ORDER BY USING with this operator");
            }
            if (p.eatKw("nulls")) {
                if (p.eatKw("first")) {
                    item.nulls = .first;
                } else {
                    try p.expectKw("last");
                    item.nulls = .last;
                }
            } else {
                // PostgreSQL: NULLs sort as if larger than any value.
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
        return items.items;
    }

    /// A FROM item and the joins that follow it, appended to `items`
    /// (SQLite's FROM is a flat list, each item joined to those before).
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
                } else return p.syntaxError();
            }
            try items.append(p.arena, item);
        }
    }

    /// A FROM item naming a table, or a catalog view.
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
                        item.alias = try p.alias(true);
                        return item;
                    }
                } else |err| if (err == error.OutOfMemory or p.err_in_parse) return err;
                p.i = save;
            }
            _ = p.advance();
            const inner = try p.fromList();
            _ = try p.expect(.rparen);
            var item: tree.FromItem = .{ .source = .{ .nested = inner } };
            item.alias = try p.alias(false);
            return item;
        }
        _ = p.eatKw("only");
        const name = try p.qname();
        if (p.peek().kind == .lparen) {
            const c = try p.funcCall(name.name, name.schema);
            const al = try p.alias(true);
            if (eql(c.name.text, "generate_series")) return p.generateSeries(c, al);
            const f = try p.new(tree.Func, .{ .name = c.name, .args = c.args });
            return .{ .source = .{ .func = f }, .alias = al };
        }
        _ = p.eatOp("*");
        var item = try p.tableItem(name);
        if (try p.alias(true)) |al| item.alias = al;
        if (p.isKw("tablesample")) return p.unsupported(p.peek().start, "TABLESAMPLE");
        return item;
    }

    /// generate_series(...) in FROM: its column is named after the
    /// function or the alias, as in PostgreSQL (SQLite's is "value"):
    /// (SELECT value AS col FROM generate_series(...)) AS alias.
    fn generateSeries(p: *Parser, c: Call, al: ?tree.Alias) Error!tree.FromItem {
        const alias_cols: []const Name = if (al) |a| a.cols else &.{};
        if (alias_cols.len > 1) return p.fail(alias_cols[1].pos, "too many column aliases for generate_series", .{});
        const col: []const u8 = if (alias_cols.len == 1) alias_cols[0].text else if (al) |a| a.name.text else "generate_series";
        const f = try p.new(tree.Func, .{ .name = .{ .text = "generate_series", .pos = c.name.pos }, .args = c.args });
        var from = try p.arena.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .func = f } };
        var cols = try p.arena.alloc(tree.ResultCol, 1);
        const value = try p.arena.alloc(Name, 1);
        value[0] = .{ .text = "value", .pos = c.name.pos };
        cols[0] = .{ .expr = .{ .e = try tree.expr(p.arena, c.name.pos, c.name.pos, .{ .column = value }), .alias = .{ .text = col } } };
        const body = try p.new(tree.Body, .{ .core = try p.new(tree.Core, .{ .cols = cols, .from = from, .pos = c.name.pos }) });
        const sub = try p.new(tree.Select, .{ .body = body, .pos = c.name.pos });
        const label: Name = if (al) |a| a.name else .{ .text = "generate_series", .pos = c.name.pos };
        return .{ .source = .{ .subquery = sub }, .alias = .{ .name = label } };
    }

    /// `[AS] alias [(cols)]`.
    fn alias(p: *Parser, allow_cols: bool) Error!?tree.Alias {
        var name: Name = undefined;
        if (p.eatKw("as")) {
            name = try p.colId();
        } else {
            const a = p.peek();
            if (a.kind == .qident or (a.kind == .ident and !isReserved(a.text) and !a.isKw("set"))) {
                _ = p.advance();
                name = .{ .text = a.text, .pos = a.start };
            } else return null;
        }
        var al: tree.Alias = .{ .name = name };
        if (p.peek().kind == .lparen) {
            if (!allow_cols) return p.syntaxError();
            al.cols = try p.parenNameList();
        }
        return al;
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

    /// A full expression (a_expr).
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
        return p.isExpr();
    }

    fn isExpr(p: *Parser) Error!*Expr {
        var l = try p.cmpExpr();
        while (true) {
            if (p.eatKw("isnull")) {
                l = try p.expr(l.pos, .{ .is_null = .{ .e = l, .not = false } });
            } else if (p.eatKw("notnull")) {
                l = try p.expr(l.pos, .{ .is_null = .{ .e = l, .not = true } });
            } else if (p.eatKw("is")) {
                const not = p.eatKw("not");
                if (p.eatKw("null")) {
                    l = try p.expr(l.pos, .{ .is_null = .{ .e = l, .not = not } });
                } else if (p.eatKw("true")) {
                    l = try p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = true, .not = not } });
                } else if (p.eatKw("false")) {
                    l = try p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = false, .not = not } });
                } else if (p.eatKw("unknown")) {
                    l = try p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = null, .not = not } });
                } else if (p.eatKw("distinct")) {
                    try p.expectKw("from");
                    const r = try p.cmpExpr();
                    // IS DISTINCT FROM is IS NOT, IS NOT DISTINCT FROM IS.
                    l = try p.span(l, r, .{ .compare = .{ .op = if (not) .is else .is_not, .l = l, .r = r } });
                } else return p.syntaxError();
            } else break;
        }
        return l;
    }

    fn cmpOp(t: Token) ?tree.CmpOp {
        if (t.kind != .op) return null;
        const map = [_]struct { []const u8, tree.CmpOp }{
            .{ "=", .eq }, .{ "<>", .ne }, .{ "!=", .ne }, .{ "<", .lt }, .{ "<=", .le }, .{ ">", .gt }, .{ ">=", .ge },
        };
        for (map) |m| if (std.mem.eql(u8, t.text, m[0])) return m[1];
        return null;
    }

    fn cmpExpr(p: *Parser) Error!*Expr {
        var l = try p.predicate();
        while (cmpOp(p.peek())) |op| {
            const at = p.advance().start;
            // x = ANY (subquery), x <> ALL (subquery)
            if (p.isAnyKw(&.{ "any", "some", "all" })) {
                const all = p.advance().isKw("all");
                if (!((op == .eq and !all) or (op == .ne and all)) or !p.parenStartsSelect()) {
                    return p.unsupported(at, "this ANY/ALL comparison");
                }
                _ = try p.expect(.lparen);
                const s = try p.select();
                _ = try p.expect(.rparen);
                l = try p.expr(l.pos, .{ .in_select = .{ .e = l, .not = all, .sel = s } });
                continue;
            }
            const r = try p.predicate();
            l = try p.span(l, r, .{ .compare = .{ .op = op, .l = l, .r = r } });
        }
        return l;
    }

    fn predicate(p: *Parser) Error!*Expr {
        var l = try p.otherExpr();
        while (true) {
            var not = false;
            const save = p.i;
            if (p.isKw("not") and (p.isKwAt(1, "between") or p.isKwAt(1, "in") or p.isKwAt(1, "like") or p.isKwAt(1, "ilike") or p.isKwAt(1, "similar"))) {
                _ = p.advance();
                not = true;
            }
            const t = p.peek();
            if (p.eatKw("between")) {
                if (p.eatKw("symmetric")) return p.unsupported(t.start, "BETWEEN SYMMETRIC");
                _ = p.eatKw("asymmetric");
                const lo = try p.otherExpr();
                try p.expectKw("and");
                const hi = try p.otherExpr();
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
            } else if (p.isKw("like") or p.isKw("ilike")) {
                const ilike = p.advance().isKw("ilike");
                l = try p.likeRest(l, not, ilike);
            } else if (p.isKw("similar")) {
                return p.unsupported(t.start, "SIMILAR TO");
            } else if (!not and (t.isOp("~~") or t.isOp("!~~") or t.isOp("~~*") or t.isOp("!~~*"))) {
                _ = p.advance();
                l = try p.likeRest(l, t.text[0] == '!', t.text[t.text.len - 1] == '*');
            } else {
                p.i = save;
                break;
            }
        }
        return l;
    }

    /// LIKE is case-sensitive, ILIKE folds ASCII letters; both escape
    /// with `\` without an ESCAPE clause.
    fn likeRest(p: *Parser, l: *Expr, not: bool, ilike: bool) Error!*Expr {
        const pat = try p.otherExpr();
        var esc: tree.Escape = .backslash;
        if (p.eatKw("escape")) esc = .{ .expr = try p.otherExpr() };
        return p.expr(l.pos, .{ .like = .{ .e = l, .pat = pat, .not = not, .case_sensitive = !ilike, .escape = esc } });
    }

    const OtherOp = enum { concat, bit_and, bit_or, shl, shr, json_get, json_get_text };

    /// Operators of the "any other operator" level.
    fn otherOp(t: Token) ?OtherOp {
        if (t.kind != .op) return null;
        const map = [_]struct { []const u8, OtherOp }{
            .{ "||", .concat },   .{ "&", .bit_and },         .{ "|", .bit_or }, .{ "<<", .shl }, .{ ">>", .shr },
            .{ "->", .json_get }, .{ "->>", .json_get_text },
        };
        for (map) |m| if (std.mem.eql(u8, t.text, m[0])) return m[1];
        return null;
    }

    fn otherExpr(p: *Parser) Error!*Expr {
        var l = try p.addExpr();
        while (true) {
            const t = p.peek();
            if (otherOp(t)) |op| {
                _ = p.advance();
                const r = try p.addExpr();
                l = switch (op) {
                    .concat => try p.span(l, r, .{ .concat = .{ .args = try p.list(&.{ l, r }), .null_policy = .propagate } }),
                    .bit_and => try p.binary(.bit_and, l, r),
                    .bit_or => try p.binary(.bit_or, l, r),
                    .shl => try p.binary(.shl, l, r),
                    .shr => try p.binary(.shr, l, r),
                    .json_get => try p.binary(.json_get, l, r),
                    .json_get_text => try p.binary(.json_get_text, l, r),
                };
            } else if (t.kind == .op and cmpOp(t) == null and !isArith(t.text) and !isLikeOp(t.text)) {
                return p.fail(t.start, "operator does not exist: {s}", .{t.text});
            } else break;
        }
        return l;
    }

    fn isArith(op: []const u8) bool {
        const ops = [_][]const u8{ "+", "-", "*", "/", "%", "^" };
        for (ops) |o| if (std.mem.eql(u8, o, op)) return true;
        return false;
    }

    fn isLikeOp(op: []const u8) bool {
        return std.mem.eql(u8, op, "~~") or std.mem.eql(u8, op, "!~~") or std.mem.eql(u8, op, "~~*") or std.mem.eql(u8, op, "!~~*");
    }

    fn addExpr(p: *Parser) Error!*Expr {
        var l = try p.mulExpr();
        while (true) {
            const op: tree.BinOp = if (p.isOp("+")) .add else if (p.isOp("-")) .sub else break;
            _ = p.advance();
            const r = try p.mulExpr();
            l = try p.binary(op, l, r);
        }
        return l;
    }

    fn mulExpr(p: *Parser) Error!*Expr {
        var l = try p.powExpr();
        while (true) {
            if (p.eatOp("*")) {
                l = try p.binary(.mul, l, try p.powExpr());
            } else if (p.eatOp("/")) {
                const r = try p.powExpr();
                l = try p.span(l, r, .{ .div = .{ .kind = .sqlite, .l = l, .r = r } });
            } else if (p.eatOp("%")) {
                l = try p.binary(.rem, l, try p.powExpr());
            } else break;
        }
        return l;
    }

    /// a ^ b is power(a, b), PostgreSQL's (a real).
    fn powExpr(p: *Parser) Error!*Expr {
        var l = try p.unary();
        while (p.eatOp("^")) {
            const r = try p.unary();
            const f = try p.new(tree.Func, .{ .name = .{ .text = "power", .pos = l.pos }, .dialect = .postgres, .args = try p.list(&.{ l, r }) });
            l = try p.span(l, r, .{ .func = f });
        }
        return l;
    }

    fn unary(p: *Parser) Error!*Expr {
        const t = p.peek();
        const op: tree.UnOp = if (t.isOp("-")) .neg else if (t.isOp("+")) .plus else if (t.isOp("~")) .bit_not else return p.postfix();
        _ = p.advance();
        const e = try p.unary();
        return p.expr(t.start, .{ .unary = .{ .op = op, .e = e } });
    }

    fn postfix(p: *Parser) Error!*Expr {
        var e = try p.primary();
        while (true) {
            if (p.eat(.cast)) {
                const ty = try p.typeName();
                e = try p.castExpr(e.pos, e, ty);
            } else if (p.isKw("collate")) {
                _ = p.advance();
                const name = try p.anyName();
                e = try p.expr(e.pos, .{ .collate = .{ .e = e, .collation = collationName(name.text) } });
            } else if (p.peek().kind == .lbracket) {
                return p.unsupported(p.peek().start, "array subscripts");
            } else if (p.isKw("at") and p.isKwAt(1, "time")) {
                return p.unsupported(p.peek().start, "AT TIME ZONE");
            } else break;
        }
        return e;
    }

    fn binary(p: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return p.span(l, r, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    /// `e::ty` (and CAST, typed literals) as types.castPlan() says;
    /// '\x0102'::bytea is a blob constant.
    fn castExpr(p: *Parser, pos: u32, e: *Expr, ty: types.TypeName) Error!*Expr {
        var x: *Expr = undefined;
        if (std.mem.eql(u8, ty.name, "bytea") and !ty.array and e.kind == .string and std.mem.startsWith(u8, e.kind.string, "\\x")) {
            const hex = e.kind.string[2..];
            for (hex) |ch| if (!std.ascii.isHex(ch)) return p.fail(pos, "invalid hexadecimal digit: \"{c}\"", .{ch});
            if (hex.len % 2 != 0) return p.fail(pos, "invalid hexadecimal data: odd number of digits", .{});
            x = try p.expr(pos, .{ .blob = hex });
        } else {
            const plan = types.castPlan(ty) catch |err| return p.typeError(ty, err);
            const mode: tree.CastMode = switch (plan) {
                .sqlite => |t| .{ .affinity = t },
                .func => |f| .{ .func = f },
                .truncate => |n| .{ .truncate = n },
                .round => |s| .{ .round = s },
            };
            x = try p.expr(pos, .{ .cast = .{ .e = e, .target_type = ty.name, .mode = mode } });
        }
        try p.setFig(x, .{ .cast = .{ .strong = p.strongName(e), .type_name = ty.name } });
        return x;
    }

    pub fn typeError(p: *Parser, ty: types.TypeName, err: types.Error) Error {
        return switch (err) {
            error.Array => p.fail(ty.pos, "arrays are not supported", .{}),
            error.UnknownType => p.fail(ty.pos, "type \"{s}\" does not exist", .{ty.name}),
        };
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
                return p.expr(t.start, .{ .string = t.text });
            },
            .param => {
                _ = p.advance();
                const n = std.fmt.parseInt(u32, t.text, 10) catch return p.fail(t.start, "there is no parameter ${s}", .{t.text});
                if (n == 0) return p.fail(t.start, "there is no parameter $0", .{});
                return p.expr(t.start, .{ .param = n });
            },
            .lparen => return p.parenExpr(),
            .qident => return p.nameExpr(),
            .ident => {},
            else => return p.syntaxError(),
        }
        const w = t.text;
        if (eql(w, "null")) return p.keywordExpr(.null);
        if (eql(w, "true")) return p.keywordExpr(.{ .boolean = true });
        if (eql(w, "false")) return p.keywordExpr(.{ .boolean = false });
        if (eql(w, "default")) return p.keywordExpr(.default);
        if (eql(w, "case")) return p.caseExpr();
        if (eql(w, "cast")) {
            _ = p.advance();
            _ = try p.expect(.lparen);
            const e = try p.expr0();
            try p.expectKw("as");
            const ty = try p.typeName();
            _ = try p.expect(.rparen);
            return p.castExpr(t.start, e, ty);
        }
        if (eql(w, "exists")) {
            _ = p.advance();
            _ = try p.expect(.lparen);
            const s = try p.select();
            _ = try p.expect(.rparen);
            return p.expr(t.start, .{ .exists = s });
        }
        if (eql(w, "array")) return p.unsupported(t.start, "ARRAY");
        if (eql(w, "row") and p.peekAt(1).kind == .lparen) {
            _ = p.advance();
            _ = p.advance();
            const items: []*Expr = if (p.peek().kind == .rparen) &.{} else try p.exprList();
            _ = try p.expect(.rparen);
            return p.expr(t.start, .{ .row = items });
        }
        if (eql(w, "current_date") or eql(w, "current_time") or eql(w, "current_timestamp") or
            eql(w, "localtime") or eql(w, "localtimestamp") or eql(w, "current_user") or eql(w, "session_user") or
            eql(w, "user") or eql(w, "current_role") or eql(w, "current_catalog") or eql(w, "current_schema"))
        {
            _ = p.advance();
            // CURRENT_TIMESTAMP(3): the precision is ignored.
            if ((eql(w, "current_time") or eql(w, "current_timestamp") or eql(w, "localtime") or eql(w, "localtimestamp")) and p.peek().kind == .lparen) {
                _ = p.advance();
                _ = try p.expect(.integer);
                _ = try p.expect(.rparen);
            } else if (eql(w, "current_schema") and p.peek().kind == .lparen and p.peekAt(1).kind == .rparen) {
                _ = p.advance();
                _ = p.advance();
            }
            return p.callExpr(t.start, .{ .name = .{ .text = if (eql(w, "user")) "current_user" else w, .pos = t.start } });
        }
        // A typed literal: DATE '2024-01-01', INTERVAL '1 day' ...
        if (isTypeWord(w)) {
            const save = p.i;
            if (p.typeName()) |ty| {
                const s = p.peek();
                if (s.kind == .string) {
                    _ = p.advance();
                    const lit = try p.expr(s.start, .{ .string = s.text });
                    return p.castExpr(t.start, lit, ty);
                }
            } else |err| if (err == error.OutOfMemory) return err;
            p.i = save;
        }
        if (isReserved(w) and !(p.peekAt(1).kind == .lparen and isFuncNameKeyword(w))) return p.syntaxError();
        return p.nameExpr();
    }

    fn keywordExpr(p: *Parser, kind: tree.Kind) Error!*Expr {
        const t = p.advance();
        return p.expr(t.start, kind);
    }

    /// A column reference or a function call.
    fn nameExpr(p: *Parser) Error!*Expr {
        const start = p.peek().start;
        var names: std.ArrayList(Name) = .empty;
        const first = p.advance();
        try names.append(p.arena, .{ .text = first.text, .pos = first.start });
        while (p.peek().kind == .dot) {
            _ = p.advance();
            try names.append(p.arena, try p.anyName());
        }
        if (p.peek().kind == .lparen) {
            const n = names.items;
            if (n.len > 2) return p.syntaxError();
            const c = try p.funcCall(n[n.len - 1], if (n.len == 2) n[0] else null);
            return p.callExpr(start, c);
        }
        if (names.items.len > 3) return p.fail(start, "improper qualified name (too many dotted names)", .{});
        if (names.items.len == 3) {
            // schema.table.column: a table of a schema of CREATE SCHEMA
            // has its bare name as alias.
            const t = try p.qualified(names.items[0], names.items[1]);
            if (t.mangled) return p.expr(start, .{ .column = names.items[1..] });
            names.items[0] = .{ .text = t.db, .pos = names.items[0].pos };
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
        // Keep the parentheses in the span (for the name of a column).
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
        if (whens.items.len == 0) return p.syntaxError();
        var else_: ?*Expr = null;
        if (p.eatKw("else")) else_ = try p.expr0();
        try p.expectKw("end");
        return p.expr(start, .{ .case = .{ .operand = operand, .whens = whens.items, .@"else" = else_ } });
    }

    // ========================================================= functions

    /// The call after its name: arguments, FILTER, OVER. The special
    /// syntax of substring/position/trim/extract/overlay is read here.
    fn funcCall(p: *Parser, name: Name, schema: ?Name) Error!Call {
        if (schema) |s| if (!eql(s.text, "pg_catalog") and !eql(s.text, "public")) {
            return p.fail(s.pos, "schema \"{s}\" does not exist", .{s.text});
        };
        _ = try p.expect(.lparen);
        var f: Call = .{ .name = name };
        const n = name.text;
        if (eql(n, "substring") or eql(n, "position") or eql(n, "extract")) f.label = n;
        if (eql(n, "substring") or eql(n, "position") or eql(n, "trim") or eql(n, "extract") or eql(n, "overlay")) {
            if (try p.specialCall(&f)) return p.finishCall(f);
        }
        if (p.peek().isOp("*")) {
            _ = p.advance();
            f.star = true;
        } else if (p.peek().kind != .rparen) {
            if (p.eatKw("distinct")) f.distinct = true else _ = p.eatKw("all");
            if (p.isKw("variadic")) return p.unsupported(p.peek().start, "VARIADIC");
            f.args = try p.exprList();
            if (p.isKw("order")) {
                _ = p.advance();
                try p.expectKw("by");
                f.order_by = try p.sortList();
            }
        }
        _ = try p.expect(.rparen);
        return p.finishCall(f);
    }

    fn finishCall(p: *Parser, f_arg: Call) Error!Call {
        var f = f_arg;
        if (p.isKw("within") and p.isKwAt(1, "group")) return p.unsupported(p.peek().start, "WITHIN GROUP");
        if (p.isKw("filter") and p.peekAt(1).kind == .lparen) {
            _ = p.advance();
            _ = p.advance();
            try p.expectKw("where");
            f.filter = try p.expr0();
            _ = try p.expect(.rparen);
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

    /// substring(x FROM a FOR b), position(a IN b), trim([BOTH|LEADING|
    /// TRAILING] [chars] FROM x), extract(field FROM x): false (nothing
    /// consumed) if the call uses the ordinary syntax.
    fn specialCall(p: *Parser, f: *Call) Error!bool {
        const n = f.name.text;
        const save = p.i;
        var args: std.ArrayList(*Expr) = .empty;
        if (eql(n, "extract")) {
            const t = p.peek();
            const field: []const u8 = switch (t.kind) {
                .ident, .qident, .string => t.text,
                else => return p.syntaxError(),
            };
            _ = p.advance();
            try p.expectKw("from");
            try args.append(p.arena, try p.expr(t.start, .{ .string = field }));
            try args.append(p.arena, try p.expr0());
            _ = try p.expect(.rparen);
            f.name.text = "date_part";
            f.args = args.items;
            return true;
        }
        if (eql(n, "trim")) {
            var kind: []const u8 = "btrim";
            if (p.eatKw("both")) {} else if (p.eatKw("leading")) {
                kind = "ltrim";
            } else if (p.eatKw("trailing")) {
                kind = "rtrim";
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
                } else if (p.eat(.comma)) {
                    subject = first;
                    chars = try p.expr0();
                } else {
                    subject = first;
                }
            }
            _ = try p.expect(.rparen);
            try args.append(p.arena, subject);
            if (chars) |c| try args.append(p.arena, c);
            f.name.text = kind;
            f.args = args.items;
            return true;
        }
        if (eql(n, "position")) {
            const a = try p.otherExpr();
            if (!p.eatKw("in")) {
                p.i = save;
                return false;
            }
            const b = try p.otherExpr();
            _ = try p.expect(.rparen);
            try args.append(p.arena, b);
            try args.append(p.arena, a);
            f.name.text = "strpos";
            f.args = args.items;
            return true;
        }
        if (eql(n, "substring")) {
            const x = try p.expr0();
            if (p.peek().kind == .comma or p.peek().kind == .rparen) {
                p.i = save;
                return false;
            }
            try args.append(p.arena, x);
            if (p.eatKw("from")) {
                try args.append(p.arena, try p.expr0());
                if (p.eatKw("for")) try args.append(p.arena, try p.expr0());
            } else if (p.eatKw("for")) {
                try args.append(p.arena, try p.expr(x.pos, .{ .integer = "1" }));
                try args.append(p.arena, try p.expr0());
            } else if (p.isKw("similar")) {
                return p.unsupported(p.peek().start, "SUBSTRING ... SIMILAR");
            } else return p.syntaxError();
            _ = try p.expect(.rparen);
            f.name.text = "substr";
            f.args = args.items;
            return true;
        }
        if (eql(n, "overlay")) {
            return p.unsupported(f.name.pos, "OVERLAY");
        }
        return false;
    }

    /// The expression a call means: PostgreSQL's name mapped to SQLite's
    /// (funcName()), the calls that become something else (now(),
    /// date_part() ...), a function of the dialect's table marked so.
    fn callExpr(p: *Parser, pos: u32, c: Call) Error!*Expr {
        const n = c.name.text;
        var e: *Expr = undefined;
        const plain = c.over == null and c.filter == null and c.order_by.len == 0;
        if (if (plain) specialFunc(n) else null) |sc| {
            e = switch (sc) {
                .now => blk: {
                    if (c.args.len != 0) return p.fail(c.name.pos, "function {s} does not exist", .{n});
                    break :blk try p.now(pos);
                },
                .localtime => try p.call(pos, "current_time", null, &.{}),
                .current_user => try p.call(pos, "current_user", .postgres, &.{}),
                .current_database => try p.call(pos, "current_database", .postgres, &.{}),
                .date_part => try p.datePart(pos, c),
            };
        } else {
            const mapped = funcName(n);
            const name: Name = if (mapped.ptr == n.ptr) c.name else .{ .text = mapped, .pos = c.name.pos };
            if ((eql(mapped, "nextval") or eql(mapped, "currval") or eql(mapped, "setval")) and c.args.len > 0 and c.args[0].kind == .string) {
                c.args[0] = try p.sequenceArg(c.args[0]);
            }
            const f = try p.new(tree.Func, .{
                .name = name,
                .dialect = if (isDialectFunction(mapped)) .postgres else null,
                .args = c.args,
                .star = c.star,
                .distinct = c.distinct,
                .order_by = c.order_by,
                .filter = c.filter,
                .over = c.over,
            });
            e = try p.expr(pos, .{ .func = f });
        }
        try p.setFig(e, .{ .call = c.label orelse n });
        return e;
    }

    /// A call the parser makes: `owner` a dialect for a function of its
    /// table.
    fn call(p: *Parser, pos: u32, name: []const u8, owner: ?@import("../dialect.zig").Dialect, args: []const *Expr) Error!*Expr {
        const f = try p.new(tree.Func, .{ .name = .{ .text = name, .pos = pos }, .dialect = owner, .args = try p.list(args) });
        return p.expr(pos, .{ .func = f });
    }

    fn stringAt(p: *Parser, pos: u32, s: []const u8) Error!*Expr {
        return p.expr(pos, .{ .string = s });
    }

    /// now(): the statement's time as 'YYYY-MM-DD HH:MM:SS.SSS' (UTC, no
    /// zone), which SQLite's date functions read back.
    fn now(p: *Parser, pos: u32) Error!*Expr {
        return p.call(pos, "strftime", null, &.{ try p.stringAt(pos, "%Y-%m-%d %H:%M:%f"), try p.stringAt(pos, "now") });
    }

    /// date_part('field', x) (and EXTRACT(field FROM x)) with strftime().
    fn datePart(p: *Parser, pos: u32, c: Call) Error!*Expr {
        if (c.args.len != 2 or c.args[0].kind != .string) return p.fail(c.name.pos, "function date_part with these arguments is not supported", .{});
        const plan = datePartPlan(c.args[0].kind.string) orelse
            return p.fail(c.args[0].pos, "unit \"{s}\" not recognized for type timestamp", .{c.args[0].kind.string});
        const x = c.args[1];
        if (plan.func) |fname| return p.call(pos, fname, null, &.{x});
        const s = try p.call(pos, "strftime", null, &.{ try p.stringAt(pos, plan.fmt), x });
        var v = try p.expr(pos, .{ .cast = .{ .e = s, .target_type = plan.cast, .mode = .{ .affinity = plan.cast } } });
        if (plan.quarter) {
            v = try p.expr(pos, .{ .binary = .{ .op = .add, .l = v, .r = try p.expr(pos, .{ .integer = "2" }) } });
            v = try p.expr(pos, .{ .div = .{ .kind = .sqlite, .l = v, .r = try p.expr(pos, .{ .integer = "3" }) } });
        }
        return v;
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
        const e = try p.expr0();
        if (p.eatKw("preceding")) return .{ .kind = .preceding, .expr = e };
        try p.expectKw("following");
        return .{ .kind = .following, .expr = e };
    }

    // ============================================================= types

    pub fn typeName(p: *Parser) Error!types.TypeName {
        const t = p.peek();
        if (t.kind != .ident and t.kind != .qident) return p.syntaxError();
        _ = p.advance();
        var w = t.text;
        // pg_catalog.int4
        if (p.peek().kind == .dot) {
            if (!eql(w, "pg_catalog") and !eql(w, "public")) return p.fail(t.start, "type \"{s}\" does not exist", .{p.src[t.start..p.peekAt(1).end]});
            _ = p.advance();
            const n = try p.anyName();
            w = n.text;
        }
        var ty: types.TypeName = .{ .name = w, .pos = t.start };
        if (t.kind == .ident) {
            if (eql(w, "double")) {
                try p.expectKw("precision");
                ty.name = "double precision";
            } else if (eql(w, "character") or eql(w, "char") or eql(w, "nchar")) {
                ty.name = if (p.eatKw("varying")) "character varying" else "character";
            } else if (eql(w, "national")) {
                if (!p.eatKw("character")) try p.expectKw("char");
                ty.name = if (p.eatKw("varying")) "character varying" else "character";
            } else if (eql(w, "varchar")) {
                ty.name = "character varying";
            } else if (eql(w, "bit")) {
                ty.name = if (p.eatKw("varying")) "bit varying" else "bit";
            } else {
                ty.name = canonicalType(w);
            }
        }
        if (eql(ty.name, "float")) {
            // float(p): real up to 24 bits of precision.
            var real = false;
            if (p.peek().kind == .lparen) {
                _ = p.advance();
                const bits = try p.signedInt();
                _ = try p.expect(.rparen);
                if (bits < 1 or bits > 53) return p.fail(t.start, "precision for type float must be between 1 and 53 bits", .{});
                real = bits <= 24;
            }
            ty.name = if (real) "real" else "double precision";
        }
        if (p.peek().kind == .lparen and takesMods(ty.name)) {
            _ = p.advance();
            var mods: std.ArrayList(i64) = .empty;
            while (true) {
                try mods.append(p.arena, try p.signedInt());
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.rparen);
            ty.mods = mods.items;
        }
        if (eql(ty.name, "timestamp") or eql(ty.name, "time")) {
            var tz = false;
            if (p.isKw("with") and p.isKwAt(1, "time")) {
                _ = p.advance();
                _ = p.advance();
                try p.expectKw("zone");
                tz = true;
            } else if (p.isKw("without") and p.isKwAt(1, "time")) {
                _ = p.advance();
                _ = p.advance();
                try p.expectKw("zone");
            }
            ty.name = if (eql(ty.name, "timestamp"))
                (if (tz) "timestamp with time zone" else "timestamp without time zone")
            else
                (if (tz) "time with time zone" else "time without time zone");
        } else if (eql(ty.name, "interval")) {
            // INTERVAL YEAR TO MONTH and the like: the fields are ignored.
            const fields = [_][]const u8{ "year", "month", "day", "hour", "minute", "second" };
            var any = true;
            while (any) {
                any = false;
                for (fields) |fw| if (p.eatKw(fw)) {
                    any = true;
                };
                if (p.eatKw("to")) any = true;
            }
        }
        while (p.peek().kind == .lbracket) {
            _ = p.advance();
            if (p.peek().kind == .integer) _ = p.advance();
            _ = try p.expect(.rbracket);
            ty.array = true;
        }
        if (p.isKw("array")) {
            _ = p.advance();
            ty.array = true;
        }
        return ty;
    }

    // ============================================================== DML

    fn insert(p: *Parser, with: ?*tree.With) Error!*tree.Insert {
        const pos = p.advance().start; // INSERT
        try p.expectKw("into");
        const rel = try p.relation(try p.qname());
        var ins: tree.Insert = .{ .with = with, .table = rel.q, .alias = rel.alias, .source = null, .pos = pos };
        if (p.eatKw("as")) ins.alias = try p.colId();
        if (p.peek().kind == .lparen and !p.parenStartsSelect()) ins.cols = try p.parenNameList();
        if (p.eatKw("overriding")) {
            if (!p.eatKw("system")) try p.expectKw("user");
            try p.expectKw("value");
            ins.overriding = true;
        }
        if (p.isKw("default") and p.isKwAt(1, "values")) {
            _ = p.advance();
            _ = p.advance();
        } else {
            ins.source = try p.select();
        }
        if (p.isKw("on") and p.isKwAt(1, "conflict")) {
            _ = p.advance();
            _ = p.advance();
            var oc: tree.OnConflict = .{};
            if (p.peek().kind == .lparen) {
                _ = p.advance();
                var items: std.ArrayList(*Expr) = .empty;
                while (true) {
                    var e = try p.expr0();
                    if (e.kind == .collate) e = e.kind.collate.e;
                    try items.append(p.arena, e);
                    if (!p.eat(.comma)) break;
                }
                _ = try p.expect(.rparen);
                oc.target = items.items;
                if (p.eatKw("where")) oc.target_where = try p.expr0();
            } else if (p.isKw("on") and p.isKwAt(1, "constraint")) {
                return p.unsupported(p.peek().start, "ON CONFLICT ON CONSTRAINT");
            }
            try p.expectKw("do");
            if (p.eatKw("nothing")) {} else {
                const at = p.peek().start;
                try p.expectKw("update");
                if (oc.target.len == 0) return p.fail(at, "ON CONFLICT DO UPDATE requires inference specification or constraint name", .{});
                try p.expectKw("set");
                oc.update = try p.setList();
                if (p.eatKw("where")) oc.where = try p.expr0();
            }
            ins.on_conflict = try p.new(tree.OnConflict, oc);
        }
        if (p.eatKw("returning")) ins.returning = try p.targetList();
        try p.insertColumns(&ins);
        return p.new(tree.Insert, ins);
    }

    /// PostgreSQL's INSERT semantics that depend on the table: fewer
    /// values than columns fill the leading columns (the others get their
    /// defaults; SQLite wants a column list), and a string constant for a
    /// numeric column (ANY in a STRICT table) is the number it spells, as
    /// PostgreSQL reads '1.5' for a numeric.
    fn insertColumns(p: *Parser, ins: *tree.Insert) Error!void {
        const ps = p.p orelse return;
        const src = ins.source orelse return;
        try p.readSchema();
        const t = build.findTable(ps.db, ins.table.name.text, if (ins.table.schema) |s| s.text else null) orelse return;
        if (ins.cols.len == 0) if (valuesWidth(src)) |n| {
            var all: std.ArrayList(Name) = .empty;
            for (t.cols) |*c| if (!c.col_flags.intersects(int.COLFLAG.NOINSERT)) try all.append(p.arena, .{ .text = c.name(), .pos = ins.pos });
            if (n < all.items.len) ins.cols = all.items[0..n];
        };
        if (src.body.* != .values or !t.tab_flags.Strict) return;
        for (src.body.values) |row| {
            for (row, 0..) |*item, i| {
                if (item.*.kind != .string) continue;
                const c = insertColumn(t, ins.cols, i) orelse continue;
                if (!std.ascii.eqlIgnoreCase(build.columnType(c, ""), "ANY")) continue;
                const lit = numericLiteral(item.*.kind.string) orelse continue;
                var x = try tree.expr(p.arena, item.*.pos, item.*.end, lit.kind);
                if (lit.neg) x = try tree.expr(p.arena, item.*.pos, item.*.end, .{ .unary = .{ .op = .neg, .e = x } });
                item.* = x;
            }
        }
    }

    fn setList(p: *Parser) Error![]tree.SetItem {
        var out: std.ArrayList(tree.SetItem) = .empty;
        while (true) {
            if (p.peek().kind == .lparen) {
                const cols = try p.parenNameList();
                if (!p.eatOp("=")) return p.syntaxError();
                const v = try p.expr0();
                try out.append(p.arena, .{ .cols = cols, .multi = true, .value = v });
            } else {
                var cols = try p.arena.alloc(Name, 1);
                cols[0] = try p.colId();
                if (p.peek().kind == .dot) return p.unsupported(p.peek().start, "assigning to a field of a column");
                if (!p.eatOp("=")) return p.syntaxError();
                const v = try p.expr0();
                try out.append(p.arena, .{ .cols = cols, .multi = false, .value = v });
            }
            if (!p.eat(.comma)) break;
        }
        return out.items;
    }

    fn update(p: *Parser, with: ?*tree.With) Error!*tree.Update {
        const pos = p.advance().start; // UPDATE
        _ = p.eatKw("only");
        const rel = try p.relation(try p.qname());
        var u: tree.Update = .{ .with = with, .table = rel.q, .alias = rel.alias, .sets = &.{}, .pos = pos };
        _ = p.eatOp("*");
        if (p.eatKw("as")) {
            u.alias = try p.colId();
        } else if (!p.isKw("set")) {
            const a = p.peek();
            if (a.kind == .qident or (a.kind == .ident and !isReserved(a.text))) {
                _ = p.advance();
                u.alias = .{ .text = a.text, .pos = a.start };
            }
        }
        try p.expectKw("set");
        u.sets = try p.setList();
        if (p.eatKw("from")) u.from = try p.fromList();
        if (p.eatKw("where")) {
            if (p.isKw("current") and p.isKwAt(1, "of")) return p.unsupported(p.peek().start, "WHERE CURRENT OF");
            u.where = try p.expr0();
        }
        if (p.eatKw("returning")) u.returning = try p.targetList();
        return p.new(tree.Update, u);
    }

    fn delete(p: *Parser, with: ?*tree.With) Error!*tree.Delete {
        const pos = p.advance().start; // DELETE
        try p.expectKw("from");
        _ = p.eatKw("only");
        const rel = try p.relation(try p.qname());
        var d: tree.Delete = .{ .with = with, .table = rel.q, .alias = rel.alias, .pos = pos };
        _ = p.eatOp("*");
        if (p.eatKw("as")) {
            d.alias = try p.colId();
        } else {
            const a = p.peek();
            if (a.kind == .qident or (a.kind == .ident and !isReserved(a.text))) {
                _ = p.advance();
                d.alias = .{ .text = a.text, .pos = a.start };
            }
        }
        if (p.eatKw("using")) d.using = try p.fromList();
        if (p.eatKw("where")) {
            if (p.isKw("current") and p.isKwAt(1, "of")) return p.unsupported(p.peek().start, "WHERE CURRENT OF");
            d.where = try p.expr0();
        }
        if (p.eatKw("returning")) d.returning = try p.targetList();
        return p.new(tree.Delete, d);
    }

    // ============================================================== DDL

    fn create(p: *Parser) Error!tree.Stmt {
        const at = p.advance().start; // CREATE
        var or_replace = false;
        if (p.eatKw("or")) {
            try p.expectKw("replace");
            or_replace = true;
        }
        var temp = false;
        if (p.eatKw("global") or p.eatKw("local")) {
            if (!p.isKw("temp") and !p.isKw("temporary")) return p.syntaxError();
        }
        if (p.eatKw("temp") or p.eatKw("temporary")) temp = true else _ = p.eatKw("unlogged");
        if (p.isKw("table")) {
            if (or_replace) return p.syntaxError();
            return .{ .create_table = try p.createTable(temp) };
        }
        if (p.isKw("view")) {
            _ = p.advance();
            const q = try p.qname();
            const t = try p.createTarget(q, temp);
            temp = temp or eql(t.db, "temp");
            var v: tree.CreateView = .{ .or_replace = or_replace, .temp = temp, .name = .{ .schema = .{ .text = t.db }, .name = .{ .text = t.name, .pos = q.name.pos } }, .select = undefined };
            if (p.peek().kind == .lparen) v.cols = try p.parenNameList();
            if (p.eatKw("with")) {
                _ = try p.expect(.lparen);
                while (p.peek().kind != .rparen and p.peek().kind != .eof) _ = p.advance();
                _ = try p.expect(.rparen);
            }
            try p.expectKw("as");
            v.select = try p.select();
            if (p.isKw("with")) return p.unsupported(p.peek().start, "WITH CHECK OPTION");
            return .{ .create_view = try p.new(tree.CreateView, v) };
        }
        if (p.isKw("sequence")) {
            _ = p.advance();
            var s: tree.CreateSequence = .{ .name = undefined };
            s.if_not_exists = try p.ifNotExists();
            const q = try p.qname();
            const t = try p.createTarget(q, false);
            if (!eql(t.db, "main")) return p.fail(q.schema.?.pos, "xqlite: sequences are only supported in public and in schemas of CREATE SCHEMA", .{});
            s.name = .{ .name = .{ .text = t.name, .pos = q.name.pos } };
            s.opts = try p.seqOptions();
            return .{ .create_sequence = try p.new(tree.CreateSequence, s) };
        }
        if (p.isKw("unique") or p.isKw("index")) {
            if (or_replace or temp) return p.syntaxError();
            return .{ .create_index = try p.createIndex() };
        }
        if (p.isAnyKw(&.{ "schema", "database", "extension", "type", "function", "trigger", "domain", "procedure", "role", "user" })) {
            return p.fail(at, "CREATE {s} is not supported", .{std.ascii.allocUpperString(p.arena, p.peek().text) catch return error.OutOfMemory});
        }
        return p.syntaxError();
    }

    fn seqOptions(p: *Parser) Error!tree.SeqOpts {
        var o: tree.SeqOpts = .{};
        while (true) {
            if (p.eatKw("as")) {
                _ = try p.typeName();
            } else if (p.eatKw("increment")) {
                _ = p.eatKw("by");
                o.increment = try p.signedInt();
            } else if (p.eatKw("minvalue")) {
                o.min = try p.signedInt();
            } else if (p.eatKw("maxvalue")) {
                o.max = try p.signedInt();
            } else if (p.eatKw("start")) {
                _ = p.eatKw("with");
                o.start = try p.signedInt();
            } else if (p.eatKw("cache")) {
                _ = try p.signedInt();
            } else if (p.eatKw("cycle")) {
                o.cycle = true;
            } else if (p.eatKw("no")) {
                if (p.eatKw("minvalue")) {} else if (p.eatKw("maxvalue")) {} else if (p.eatKw("cycle")) {
                    o.cycle = false;
                } else return p.syntaxError();
            } else if (p.eatKw("owned")) {
                try p.expectKw("by");
                if (!p.eatKw("none")) _ = try p.qname();
            } else break;
        }
        return o;
    }

    fn createTable(p: *Parser, temp_arg: bool) Error!*tree.CreateTable {
        _ = p.advance(); // TABLE
        const if_not_exists = try p.ifNotExists();
        const q = try p.qname();
        const dest = try p.createTarget(q, temp_arg);
        const temp = temp_arg or eql(dest.db, "temp");
        p.creating = dest;
        var ct: tree.CreateTable = .{
            .temp = temp,
            .if_not_exists = if_not_exists,
            .name = .{
                .schema = if ((q.schema != null or dest.mangled) and !temp) Name{ .text = dest.db } else null,
                .name = .{ .text = dest.name, .pos = q.name.pos },
            },
            .strict = true,
        };
        const table = q.name.text;
        if (p.eatKw("as")) {
            ct.as_select = try p.select();
            if (p.eatKw("with")) {
                _ = p.eatKw("no");
                try p.expectKw("data");
            }
            return p.new(tree.CreateTable, ct);
        }
        _ = try p.expect(.lparen);
        var cols: std.ArrayList(tree.ColumnDef) = .empty;
        var cons: std.ArrayList(tree.TableConstraint) = .empty;
        if (p.peek().kind != .rparen) while (true) {
            const t = p.peek();
            if (t.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign", "exclude" })) {
                try cons.append(p.arena, try p.tableConstraint(table));
            } else if (t.isKw("like")) {
                return p.unsupported(t.start, "CREATE TABLE ... LIKE");
            } else {
                const c = try p.columnDef(table);
                for (cols.items) |prev| if (eql(prev.name.text, c.name.text)) {
                    return p.fail(c.name.pos, "column \"{s}\" specified more than once", .{c.name.text});
                };
                try cols.append(p.arena, c);
            }
            if (!p.eat(.comma)) break;
        };
        _ = try p.expect(.rparen);
        if (cols.items.len == 0) return p.fail(q.name.pos, "a table must have at least one column", .{});
        ct.columns = cols.items;
        ct.constraints = cons.items;
        // The identity sequences are in the table's schema.
        if (dest.mangled) for (ct.columns) |c| for (c.constraints) |*cc| if (cc.kind == .identity) {
            cc.kind.identity.sequence = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefixOf(dest), cc.kind.identity.sequence });
        };
        // Storage options are ignored.
        while (true) {
            if (p.eatKw("with")) {
                _ = try p.expect(.lparen);
                while (p.peek().kind != .rparen and p.peek().kind != .eof) _ = p.advance();
                _ = try p.expect(.rparen);
            } else if (p.eatKw("without")) {
                try p.expectKw("oids");
            } else if (p.isKw("on") and p.isKwAt(1, "commit")) {
                _ = p.advance();
                _ = p.advance();
                if (p.eatKw("preserve")) {
                    try p.expectKw("rows");
                } else if (p.eatKw("delete")) {
                    return p.unsupported(p.toks[p.i - 1].start, "ON COMMIT DELETE ROWS");
                } else try p.expectKw("drop");
            } else if (p.eatKw("tablespace")) {
                _ = try p.colId();
            } else if (p.isKw("inherits") or p.isKw("partition")) {
                return p.unsupported(p.peek().start, "table inheritance and partitioning");
            } else break;
        }
        return p.new(tree.CreateTable, ct);
    }

    /// A column constraint as written.
    const RawConstraint = struct {
        name: ?Name = null,
        kind: union(enum) {
            not_null,
            null,
            check: *Expr,
            default: *Expr,
            primary_key,
            unique,
            references: tree.Ref,
            identity: struct { always: bool, opts: tree.SeqOpts },
            /// GENERATED ALWAYS AS (expr) STORED
            generated: *Expr,
        },
    };

    /// A column definition of table `table`, its PostgreSQL type mapped
    /// to a STRICT storage type (types.info()) with the type's check, a
    /// SERIAL or identity column to a tree.Identity of sequence
    /// <table>_<column>_seq (as PostgreSQL names it).
    pub fn columnDef(p: *Parser, table: []const u8) Error!tree.ColumnDef {
        const name = try p.colId();
        const ty = try p.typeName();
        var collate: ?Name = null;
        var raw: std.ArrayList(RawConstraint) = .empty;
        while (true) {
            var cname: ?Name = null;
            if (p.eatKw("constraint")) cname = try p.colId();
            var cc: RawConstraint = .{ .name = cname, .kind = .null };
            if (p.eatKw("not")) {
                if (p.eatKw("null")) {
                    cc.kind = .not_null;
                } else {
                    try p.expectKw("deferrable");
                    continue;
                }
            } else if (p.eatKw("null")) {
                cc.kind = .null;
            } else if (p.eatKw("check")) {
                _ = try p.expect(.lparen);
                cc.kind = .{ .check = try p.expr0() };
                _ = try p.expect(.rparen);
                if (p.eatKw("no")) try p.expectKw("inherit");
            } else if (p.eatKw("default")) {
                cc.kind = .{ .default = try p.otherExpr() };
            } else if (p.eatKw("unique")) {
                try p.nullsDistinct();
                cc.kind = .unique;
            } else if (p.eatKw("primary")) {
                try p.expectKw("key");
                cc.kind = .primary_key;
            } else if (p.isKw("references")) {
                cc.kind = .{ .references = try p.references() };
            } else if (p.eatKw("generated")) {
                var always = true;
                if (p.eatKw("by")) {
                    try p.expectKw("default");
                    always = false;
                } else try p.expectKw("always");
                try p.expectKw("as");
                if (p.eatKw("identity")) {
                    var opts: tree.SeqOpts = .{};
                    if (p.peek().kind == .lparen) {
                        _ = p.advance();
                        opts = try p.seqOptions();
                        _ = try p.expect(.rparen);
                    }
                    cc.kind = .{ .identity = .{ .always = always, .opts = opts } };
                } else {
                    if (!always) return p.syntaxError();
                    _ = try p.expect(.lparen);
                    const e = try p.expr0();
                    _ = try p.expect(.rparen);
                    try p.expectKw("stored");
                    cc.kind = .{ .generated = e };
                }
            } else if (p.eatKw("deferrable") or p.eatKw("initially")) {
                if (p.toks[p.i - 1].isKw("initially")) {
                    if (!p.eatKw("deferred")) try p.expectKw("immediate");
                }
                continue;
            } else if (p.eatKw("collate")) {
                collate = try p.anyName();
                continue;
            } else {
                if (cname != null) return p.syntaxError();
                break;
            }
            try raw.append(p.arena, cc);
        }
        return p.resolveColumn(table, name, ty, collate, raw.items);
    }

    fn resolveColumn(p: *Parser, table: []const u8, name: Name, ty: types.TypeName, collate: ?Name, raw: []const RawConstraint) Error!tree.ColumnDef {
        const info = types.info(ty) catch |err| return p.typeError(ty, err);
        var identity: ?@FieldType(@FieldType(RawConstraint, "kind"), "identity") = null;
        var has_default = false;
        for (raw) |cc| switch (cc.kind) {
            .identity => |id| identity = id,
            .default => has_default = true,
            else => {},
        };
        if ((identity != null and info.serial) or ((identity != null or info.serial) and has_default)) {
            return p.fail(name.pos, "multiple default values specified for column \"{s}\" of table \"{s}\"", .{ name.text, table });
        }
        if (identity != null and info.storage[0] != 'I') return p.fail(ty.pos, "identity column type must be smallint, integer, or bigint", .{});

        var cons: std.ArrayList(tree.ColConstraint) = .empty;
        if (identity != null or info.serial) {
            var id: tree.Identity = .{ .sequence = try std.fmt.allocPrint(p.arena, "{s}_{s}_seq", .{ table, name.text }) };
            if (identity) |x| {
                id.always = x.always;
                id.opts = x.opts;
            }
            // The range of the column's type bounds the sequence.
            if (id.opts.max == null and (id.opts.increment orelse 1) > 0) {
                if (info.check == .smallint_range) id.opts.max = 32767;
                if (info.check == .integer_range) id.opts.max = 2147483647;
            }
            try cons.append(p.arena, .{ .kind = .{ .identity = id } });
        }
        for (raw) |cc| {
            const cname: ?[]const u8 = if (cc.name) |n| n.text else null;
            switch (cc.kind) {
                .identity => {},
                .not_null => try cons.append(p.arena, .{ .name = cname, .kind = .not_null }),
                .null => try cons.append(p.arena, .{ .name = cname, .kind = .null }),
                .check => |e| try cons.append(p.arena, .{
                    .name = cname orelse try std.fmt.allocPrint(p.arena, "{s}_{s}_check", .{ table, name.text }),
                    .kind = .{ .check = e },
                }),
                .default => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .default = e } }),
                .primary_key => try cons.append(p.arena, .{ .name = cname, .kind = .{ .primary_key = .{} } }),
                .unique => try cons.append(p.arena, .{ .name = cname, .kind = .unique }),
                .references => |r| try cons.append(p.arena, .{ .name = cname, .kind = .{ .references = r } }),
                .generated => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .generated = .{ .e = e, .stored = true } } }),
            }
        }
        if (collate) |c| try cons.append(p.arena, .{ .kind = .{ .collate = collationName(c.text) } });
        if (try p.typeCheck(name, ty, info)) |check| try cons.append(p.arena, check);
        return .{ .name = name, .type = info.storage, .decl_type = try types.format(p.arena, ty), .constraints = cons.items };
    }

    /// The CHECK constraint of a type, named with PostgreSQL's message.
    fn typeCheck(p: *Parser, name: Name, ty: types.TypeName, info: types.Info) Error!?tree.ColConstraint {
        const a = p.arena;
        const pos = name.pos;
        const names = try a.alloc(Name, 1);
        names[0] = .{ .text = name.text, .pos = pos };
        const col = try tree.expr(a, pos, pos, .{ .column = names });
        const int_ = struct {
            fn lit(arena: Allocator, at: u32, v: i64) Error!*Expr {
                const digits = try std.fmt.allocPrint(arena, "{d}", .{@abs(v)});
                const x = try tree.expr(arena, at, at, .{ .integer = digits });
                if (v >= 0) return x;
                return tree.expr(arena, at, at, .{ .unary = .{ .op = .neg, .e = x } });
            }
        };
        switch (info.check) {
            .none => return null,
            .smallint_range, .integer_range => {
                const small = info.check == .smallint_range;
                const lo: i64 = if (small) -32768 else -2147483648;
                const hi: i64 = if (small) 32767 else 2147483647;
                return .{
                    .name = if (small) "smallint out of range" else "integer out of range",
                    .kind = .{ .check = try tree.expr(a, pos, pos, .{ .between = .{ .e = col, .not = false, .lo = try int_.lit(a, pos, lo), .hi = try int_.lit(a, pos, hi) } }) },
                };
            },
            .numeric => {
                const f = try p.call(pos, "typeof", null, &.{col});
                const items = try p.list(&.{ try p.stringAt(pos, "integer"), try p.stringAt(pos, "real"), try p.stringAt(pos, "null") });
                return .{ .name = "invalid input syntax for type numeric", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .in_list = .{ .e = f, .not = false, .items = items } }) } };
            },
            .boolean => {
                const items = try p.list(&.{ try int_.lit(a, pos, 0), try int_.lit(a, pos, 1) });
                return .{ .name = "invalid input syntax for type boolean", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .in_list = .{ .e = col, .not = false, .items = items } }) } };
            },
            .length => {
                const n = types.maxLength(ty).?;
                const tname = if (eql(ty.name, "character")) "character" else "character varying";
                const len = try p.call(pos, "length", null, &.{col});
                return .{
                    .name = try std.fmt.allocPrint(a, "value too long for type {s}({d})", .{ tname, n }),
                    .kind = .{ .check = try tree.expr(a, pos, pos, .{ .compare = .{ .op = .le, .l = len, .r = try int_.lit(a, pos, n) } }) },
                };
            },
            .json => return .{ .name = "invalid input syntax for type json", .kind = .{ .check = try p.call(pos, "json_valid", null, &.{col}) } },
        }
    }

    fn nullsDistinct(p: *Parser) Error!void {
        if (p.isKw("nulls")) {
            const at = p.advance().start;
            if (p.eatKw("not")) {
                try p.expectKw("distinct");
                return p.unsupported(at, "NULLS NOT DISTINCT");
            }
            try p.expectKw("distinct");
        }
    }

    fn references(p: *Parser) Error!tree.Ref {
        try p.expectKw("references");
        const q = try p.qname();
        var r: tree.Ref = .{ .table = q.name };
        // SQLite's REFERENCES names a table of the same database.
        if (q.schema) |s| {
            r.table.text = (try p.qualified(s, q.name)).name;
        } else if (p.creating != null and eql(p.creating.?.bare, q.name.text)) {
            r.table.text = p.creating.?.name;
        } else switch (try p.unqualified(q.name, .relation)) {
            .target => |t| r.table.text = t.name,
            else => {},
        }
        if (p.peek().kind == .lparen) r.cols = try p.parenNameList();
        while (true) {
            if (p.eatKw("match")) {
                if (!p.eatKw("full") and !p.eatKw("simple")) try p.expectKw("partial");
            } else if (p.isKw("on") and (p.isKwAt(1, "delete") or p.isKwAt(1, "update"))) {
                _ = p.advance();
                const del = p.advance().isKw("delete");
                const act = try p.refAction();
                if (del) r.on_delete = act else r.on_update = act;
            } else if (p.isKw("not") and p.isKwAt(1, "deferrable")) {
                _ = p.advance();
                _ = p.advance();
            } else if (p.eatKw("deferrable")) {} else if (p.eatKw("initially")) {
                if (p.eatKw("deferred")) r.deferred = true else try p.expectKw("immediate");
            } else break;
        }
        return r;
    }

    fn refAction(p: *Parser) Error!tree.RefAction {
        if (p.eatKw("cascade")) return .cascade;
        if (p.eatKw("restrict")) return .restrict;
        if (p.eatKw("no")) {
            try p.expectKw("action");
            return .none;
        }
        try p.expectKw("set");
        if (p.eatKw("null")) return .set_null;
        try p.expectKw("default");
        return .set_default;
    }

    fn tableConstraint(p: *Parser, table: []const u8) Error!tree.TableConstraint {
        var name: ?Name = null;
        if (p.eatKw("constraint")) name = try p.colId();
        const t = p.peek();
        var tc: tree.TableConstraint = .{ .name = if (name) |n| n.text else null, .kind = undefined };
        if (p.eatKw("check")) {
            _ = try p.expect(.lparen);
            tc.kind = .{ .check = try p.expr0() };
            _ = try p.expect(.rparen);
            if (p.eatKw("no")) try p.expectKw("inherit");
            if (name == null) tc.name = try std.fmt.allocPrint(p.arena, "{s}_check", .{table});
        } else if (p.eatKw("unique")) {
            try p.nullsDistinct();
            tc.kind = .{ .unique = try p.parenNameList() };
            try p.indexTail();
        } else if (p.eatKw("primary")) {
            try p.expectKw("key");
            tc.kind = .{ .primary_key = try p.parenNameList() };
            try p.indexTail();
        } else if (p.eatKw("foreign")) {
            try p.expectKw("key");
            const cols = try p.parenNameList();
            tc.kind = .{ .foreign_key = .{ .cols = cols, .ref = try p.references() } };
        } else if (p.isKw("exclude")) {
            return p.unsupported(t.start, "EXCLUDE constraints");
        } else return p.syntaxError();
        while (true) {
            if (p.isKw("not") and p.isKwAt(1, "deferrable")) {
                _ = p.advance();
                _ = p.advance();
            } else if (p.eatKw("deferrable")) {} else if (p.eatKw("initially")) {
                if (!p.eatKw("deferred")) try p.expectKw("immediate");
            } else break;
        }
        return tc;
    }

    /// INCLUDE (...) / WITH (...) / USING INDEX TABLESPACE after a key.
    fn indexTail(p: *Parser) Error!void {
        if (p.eatKw("include")) _ = try p.parenNameList();
    }

    /// CREATE INDEX; an index without a name gets PostgreSQL's
    /// (ddl.zig), here an empty one.
    fn createIndex(p: *Parser) Error!*tree.CreateIndex {
        var ci: tree.CreateIndex = .{ .name = .{ .name = .{ .text = "" } }, .table = undefined, .items = &.{} };
        if (p.eatKw("unique")) ci.unique = true;
        try p.expectKw("index");
        _ = p.eatKw("concurrently");
        ci.if_not_exists = try p.ifNotExists();
        if (!p.isKw("on")) ci.name.name = try p.colId();
        try p.expectKw("on");
        _ = p.eatKw("only");
        // The index is in the schema of its table.
        const iq = try p.qname();
        if (iq.schema) |s| _ = try p.qualified(s, iq.name);
        const rel = try p.lookup(iq, .relation);
        if (rel.q.schema) |s| ci.name.schema = .{ .text = s.text };
        ci.table = rel.q.name;
        if (rel.alias) |bare| if (ci.name.name.text.len > 0) {
            const prefix = rel.q.name.text[0 .. rel.q.name.text.len - bare.text.len];
            ci.name.name.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefix, ci.name.name.text });
        };
        if (p.eatKw("using")) {
            const m = try p.anyName();
            if (!eql(m.text, "btree")) return p.fail(m.pos, "index method \"{s}\" is not supported", .{m.text});
        }
        _ = try p.expect(.lparen);
        var items: std.ArrayList(tree.IndexItem) = .empty;
        while (true) {
            var item: tree.IndexItem = .{ .expr = undefined };
            const e = try p.otherExpr();
            if (e.kind == .collate) {
                item.expr = e.kind.collate.e;
                item.collate = e.kind.collate.collation;
            } else item.expr = e;
            // An operator class.
            if (p.peek().kind == .ident and !isReserved(p.peek().text) and !p.isKw("nulls")) _ = p.advance();
            if (p.eatKw("desc")) item.desc = true else _ = p.eatKw("asc");
            if (p.eatKw("nulls")) {
                if (!p.eatKw("first")) try p.expectKw("last");
            }
            try items.append(p.arena, item);
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.rparen);
        ci.items = items.items;
        if (p.eatKw("include")) _ = try p.parenNameList();
        try p.nullsDistinct();
        if (p.eatKw("with")) {
            _ = try p.expect(.lparen);
            while (p.peek().kind != .rparen and p.peek().kind != .eof) _ = p.advance();
            _ = try p.expect(.rparen);
        }
        if (p.eatKw("tablespace")) _ = try p.colId();
        if (p.eatKw("where")) ci.where = try p.expr0();
        return p.new(tree.CreateIndex, ci);
    }

    fn drop(p: *Parser) Error!*tree.Drop {
        _ = p.advance(); // DROP
        const t = p.peek();
        var d: tree.Drop = .{ .kind = undefined, .name = undefined };
        if (p.eatKw("table")) {
            d.kind = .table;
        } else if (p.eatKw("view")) {
            d.kind = .view;
        } else if (p.eatKw("index")) {
            d.kind = .index;
            _ = p.eatKw("concurrently");
        } else if (p.eatKw("sequence")) {
            d.kind = .sequence;
        } else if (t.kind == .ident and t.isAnyKw(&.{ "schema", "database", "extension", "type", "function", "trigger" })) {
            return p.fail(t.start, "DROP {s} is not supported", .{std.ascii.allocUpperString(p.arena, t.text) catch return error.OutOfMemory});
        } else return p.syntaxError();
        d.if_exists = try p.ifExists();
        const q = try p.qname();
        if (p.eat(.comma)) return p.fail(p.peek().start, "dropping several objects in one statement is not supported", .{});
        const kind: Lookup = switch (d.kind) {
            .table, .view => .relation,
            .index => .index,
            .sequence => .sequence,
        };
        if (q.schema) |s| {
            const x = try p.qualified(s, q.name);
            if (d.kind == .sequence and !eql(x.db, "main")) return p.fail(s.pos, "sequence \"{s}\" does not exist", .{q.name.text});
            d.name = .{ .schema = .{ .text = x.db, .pos = s.pos }, .name = .{ .text = x.name, .pos = q.name.pos } };
        } else switch (try p.unqualified(q.name, kind)) {
            .keep => d.name = .{ .name = q.name },
            .target => |x| d.name = .{ .schema = .{ .text = x.db, .pos = q.name.pos }, .name = .{ .text = x.name, .pos = q.name.pos } },
            .missing => {
                if (!d.if_exists) return p.fail(q.name.pos, "{s} \"{s}\" does not exist", .{ @tagName(d.kind), q.name.text });
                // Not on search_path: a name nothing has (pg_temp's
                // tables have no dot).
                d.name = .{ .schema = .{ .text = "main" }, .name = .{ .text = try nsp.mangle(p.arena, "pg_temp", q.name.text), .pos = q.name.pos } };
            },
        }
        if (p.eatKw("cascade")) {} else _ = p.eatKw("restrict");
        return p.new(tree.Drop, d);
    }

    fn alterTable(p: *Parser) Error!*tree.AlterTable {
        _ = p.advance(); // ALTER
        if (!p.isKw("table")) {
            const t = p.peek();
            if (t.kind == .ident) return p.fail(t.start, "ALTER {s} is not supported", .{std.ascii.allocUpperString(p.arena, t.text) catch return error.OutOfMemory});
            return p.syntaxError();
        }
        _ = p.advance();
        var a: tree.AlterTable = .{ .name = undefined, .action = undefined };
        a.if_exists = try p.ifExists();
        _ = p.eatKw("only");
        const q = try p.qname();
        var prefix: []const u8 = "";
        if (q.schema) |s| {
            const t = try p.qualified(s, q.name);
            prefix = prefixOf(t);
            a.name = .{ .schema = .{ .text = t.db, .pos = s.pos }, .name = .{ .text = t.name, .pos = q.name.pos } };
        } else switch (try p.unqualified(q.name, .relation)) {
            .keep => a.name = .{ .name = q.name },
            .target => |t| {
                prefix = prefixOf(t);
                a.name = .{ .schema = .{ .text = t.db, .pos = q.name.pos }, .name = .{ .text = t.name, .pos = q.name.pos } };
            },
            .missing => {
                if (!a.if_exists) return p.fail(q.name.pos, "relation \"{s}\" does not exist", .{q.name.text});
                a.name = .{ .schema = .{ .text = "main" }, .name = .{ .text = try nsp.mangle(p.arena, "pg_temp", q.name.text), .pos = q.name.pos } };
            },
        }
        const at = p.peek().start;
        if (p.eatKw("rename")) {
            if (p.eatKw("to")) {
                // The table stays in its schema.
                var to = try p.colId();
                if (prefix.len > 0) to.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefix, to.text });
                a.action = .{ .rename_to = to };
            } else {
                if (p.isKw("constraint")) return p.unsupported(at, "ALTER TABLE ... RENAME CONSTRAINT");
                _ = p.eatKw("column");
                const old = try p.colId();
                try p.expectKw("to");
                a.action = .{ .rename_column = .{ .old = old, .new = try p.colId() } };
            }
        } else if (p.eatKw("add")) {
            if (p.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign" })) {
                return p.unsupported(at, "ALTER TABLE ... ADD CONSTRAINT");
            }
            _ = p.eatKw("column");
            const ine = try p.ifNotExists();
            a.action = .{ .add_column = .{ .if_not_exists = ine, .def = try p.columnDef(q.name.text) } };
        } else if (p.eatKw("drop")) {
            if (p.isKw("constraint")) return p.unsupported(at, "ALTER TABLE ... DROP CONSTRAINT");
            _ = p.eatKw("column");
            const ie = try p.ifExists();
            a.action = .{ .drop_column = .{ .if_exists = ie, .name = try p.colId() } };
            _ = p.eatKw("cascade") or p.eatKw("restrict");
        } else if (p.isKw("alter")) {
            return p.unsupported(at, "ALTER TABLE ... ALTER COLUMN");
        } else return p.syntaxError();
        if (p.peek().kind == .comma) return p.unsupported(p.peek().start, "several ALTER TABLE actions");
        return p.new(tree.AlterTable, a);
    }

    fn truncate(p: *Parser) Error!*tree.Truncate {
        _ = p.advance();
        _ = p.eatKw("table");
        _ = p.eatKw("only");
        const q = try p.qname();
        _ = p.eatOp("*");
        if (p.eat(.comma)) return p.fail(p.peek().start, "TRUNCATE of several tables is not supported", .{});
        var t: tree.Truncate = .{ .table = (try p.relation(q)).q };
        if (p.eatKw("restart")) {
            try p.expectKw("identity");
            t.restart_identity = true;
        } else if (p.eatKw("continue")) try p.expectKw("identity");
        _ = p.eatKw("cascade") or p.eatKw("restrict");
        return p.new(tree.Truncate, t);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isTypeWord(w: []const u8) bool {
    return type_words.has(w);
}

/// Reserved words that may still name a function: left(), right().
fn isFuncNameKeyword(w: []const u8) bool {
    return eql(w, "left") or eql(w, "right") or eql(w, "collation") or eql(w, "current_schema");
}

/// Whether SQLite database `db_name` has an object `name` of kind `kind`
/// (sequences are all in main).
fn objectExists(db: *int.Sqlite3, kind: Parser.Lookup, db_name: []const u8, name: []const u8) bool {
    return switch (kind) {
        .relation => build.findTable(db, name, db_name) != null,
        .index => build.findIndex(db, name, db_name) != null,
        .sequence => eql(db_name, "main") and @import("ddl.zig").sequenceExists(db, name),
    };
}

/// The canonical spelling of a one-word type name.
fn canonicalType(w: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "int", "integer" },                          .{ "int4", "integer" },               .{ "integer", "integer" },
        .{ "int2", "smallint" },                        .{ "smallint", "smallint" },          .{ "int8", "bigint" },
        .{ "bigint", "bigint" },                        .{ "serial4", "serial" },             .{ "serial8", "bigserial" },
        .{ "serial2", "smallserial" },                  .{ "float4", "real" },                .{ "float8", "double precision" },
        .{ "bool", "boolean" },                         .{ "decimal", "numeric" },            .{ "dec", "numeric" },
        .{ "timestamptz", "timestamp with time zone" }, .{ "timetz", "time with time zone" }, .{ "bpchar", "character" },
    };
    for (map) |m| if (eql(m[0], w)) return m[1];
    return w;
}

fn takesMods(name: []const u8) bool {
    const names = [_][]const u8{ "character varying", "character", "numeric", "float", "timestamp", "time", "interval", "bit", "bit varying" };
    for (names) |n| if (eql(n, name)) return true;
    return false;
}

/// The SQLite collation of a PostgreSQL collation name: "C" and "POSIX"
/// (and the default) are BINARY; SQLite's own names pass through.
pub fn collationName(name: []const u8) []const u8 {
    if (eql(name, "C") or eql(name, "POSIX") or std.ascii.eqlIgnoreCase(name, "default") or std.ascii.eqlIgnoreCase(name, "ucs_basic")) return "BINARY";
    return name;
}

/// Whether `name` is a function of the dialect's table
/// (dialect.Hooks.functions).
fn isDialectFunction(name: []const u8) bool {
    return @import("../dialect.zig").spec(.postgres).function_map.get(name) != null;
}

/// The calls (without OVER, FILTER or ORDER BY) that become something
/// else: now() and its synonyms (no arguments), localtime,
/// current_role/session_user (current_user()), current_catalog
/// (current_database()), date_part().
const SpecialFunc = enum { now, localtime, current_user, current_database, date_part };

fn specialFunc(name: []const u8) ?SpecialFunc {
    const map = std.StaticStringMap(SpecialFunc).initComptime(.{
        .{ "now", .now },                   .{ "current_timestamp", .now },
        .{ "localtimestamp", .now },        .{ "transaction_timestamp", .now },
        .{ "statement_timestamp", .now },   .{ "clock_timestamp", .now },
        .{ "localtime", .localtime },       .{ "current_role", .current_user },
        .{ "session_user", .current_user }, .{ "current_catalog", .current_database },
        .{ "date_part", .date_part },
    });
    return map.get(name);
}

/// The SQLite name of a PostgreSQL function, if it differs (else `n`).
fn funcName(n: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "substring", "substr" },   .{ "strpos", "instr" },            .{ "btrim", "trim" },
        .{ "char_length", "length" }, .{ "character_length", "length" }, .{ "bool_and", "min" },
        .{ "bool_or", "max" },        .{ "every", "min" },               .{ "ascii", "unicode" },
        .{ "chr", "char" },
    };
    for (map) |m| if (eql(m[0], n)) return m[1];
    return n;
}

/// How date_part() (EXTRACT) reads a field with strftime().
const DatePart = struct {
    fmt: []const u8 = "",
    cast: []const u8 = "INTEGER",
    quarter: bool = false,
    /// A function of the value instead (epoch: unixepoch()).
    func: ?[]const u8 = null,
};

fn datePartPlan(field_arg: []const u8) ?DatePart {
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
    for (map) |m| if (eql(m[0], field)) return m[1];
    return null;
}

/// The number of values of the rows of a VALUES or SELECT source, if
/// the tree tells (no `*`).
fn valuesWidth(s: *const tree.Select) ?usize {
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

/// The column value `i` of an INSERT into `cols` of `t` is for.
fn insertColumn(t: *int.Table, cols: []const Name, i: usize) ?*int.Column {
    if (cols.len > 0) {
        if (i >= cols.len) return null;
        for (t.cols) |*c| if (std.ascii.eqlIgnoreCase(c.name(), cols[i].text)) return c;
        return null;
    }
    var k: usize = 0;
    for (t.cols) |*c| {
        if (c.col_flags.intersects(int.COLFLAG.NOINSERT)) continue;
        if (k == i) return c;
        k += 1;
    }
    return null;
}

/// The literal a string spells as a number ('1.5'), null if none.
fn numericLiteral(s_arg: []const u8) ?struct { kind: tree.Kind, neg: bool = false } {
    const s = std.mem.trim(u8, s_arg, " ");
    if (s.len == 0) return null;
    if (std.fmt.parseInt(i64, s, 10)) |_| {
        // The tree's integers have no sign.
        if (s[0] == '-' or s[0] == '+') return .{ .kind = .{ .integer = s[1..] }, .neg = s[0] == '-' };
        return .{ .kind = .{ .integer = s } };
    } else |_| {}
    for (s) |ch| if (!(std.ascii.isDigit(ch) or ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E')) return null;
    _ = std.fmt.parseFloat(f64, s) catch return null;
    return .{ .kind = .{ .float = s } };
}
