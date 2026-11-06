//! A recursive descent parser for the PostgreSQL statements the dialect
//! supports (see docs/postgres/README.md), producing the syntax tree
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
const sqlparse = @import("sql/parse");
const syntax = @import("../syntax.zig");
const words = sqlparse.words;
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
const json = @import("json.zig");
const array = @import("array.zig");
const uuid = @import("uuid.zig");
const ivinput = @import("ivinput.zig");
const ctypes = @import("../../sql/types.zig");
const Children = @import("jtype.zig").Children;

const Token = lexer.Token;
const keywords = lexer.keywords;
const Name = tree.Name;
const Expr = tree.Expr;
const Allocator = std.mem.Allocator;

pub const Error = error{ ParseFailed, OutOfMemory };

/// Whether `word` (in lower case) is one of PostgreSQL's reserved
/// keywords or its "type_func_name" ones: neither can be a column name or
/// a bare alias (lexer.lex.keywords).
pub fn isReserved(word: []const u8) bool {
    const k = keywords.lookup(word);
    return k != 0 and keywords.class(k) == .reserved and eql(word, keywords.name(k));
}

/// The words that start a type in a typed literal (`DATE '2024-01-01'`).
const type_words = words.folded(.lower, &.{
    "date",  "time",      "timestamp", "timestamptz", "timetz",  "interval", "boolean", "bool",
    "int",   "integer",   "int2",      "int4",        "int8",    "smallint", "bigint",  "real",
    "float", "float4",    "float8",    "double",      "numeric", "decimal",  "text",    "varchar",
    "char",  "character", "bytea",     "uuid",        "json",    "jsonb",
});

/// The error of a statement that does not lex (Parser.init()).
pub const LexError = driver.LexError;
/// What the session changes in the lexing (standard_conforming_strings).
pub const Options = driver.Options;
const driver = @import("../driver.zig");

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

/// The tokens of a statement and its error (pkg/sql/parse).
pub const Cursor = sqlparse.Cursor(sqlparse.Buffered(Token), int.ErrorState, struct {
    /// PostgreSQL's `syntax error at or near "X"` at token `t`.
    pub fn syntaxErrorAt(c: anytype, t: Token) Error {
        // The end of a statement: PostgreSQL names its semicolon.
        if (t.kind == .eof and t.start < c.sql.len and c.sql[t.start] == ';') return c.failState(t.start, .of("42601"), "syntax error at or near \";\"", .{});
        if (t.kind == .eof) return c.failState(t.start, .of("42601"), "syntax error at end of input", .{});
        return c.failState(t.start, .of("42601"), "syntax error at or near \"{s}\"", .{c.sql[t.start..t.end]});
    }
});

pub const Parser = struct {
    arena: Allocator,
    /// The tokens, the text they are in and the error (diag: its message,
    /// offset and int.ErrorState).
    c: Cursor,
    /// Offset after the statement (and its semicolon).
    end: usize,
    /// The decoded values of the tokens (val()).
    values: lexer.Values,
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
    /// The table of a SELECT ... INTO (the statement is a CREATE TABLE AS).
    select_into: ?struct { q: QName, temp: bool, pos: usize } = null,
    /// Unqualified names are not looked up in search_path (the text of a
    /// catalog view).
    no_path: bool = false,
    /// Result column names of rewritten nodes.
    figs: std.AutoHashMapUnmanaged(*const Expr, Fig) = .empty,
    /// The JSON set-returning functions of FROM (and of select lists):
    /// json_each() items and the columns they stand for (jtype.zig
    /// resolves references to them).
    srfs: std.AutoHashMapUnmanaged(*const tree.Func, Srf) = .empty,
    /// The references to json_each() columns srfColumn() made (not to
    /// be resolved again).
    srf_refs: std.AutoHashMapUnmanaged(*const Expr, void) = .empty,
    srf_count: u32 = 0,
    /// The operators' parser's state (exprAbove()).
    pratt: sqlparse.pratt.State = .{},

    /// Lex the statement that starts at `pos` (blank text and leading
    /// semicolons are skipped), its strings as `options` read them (a
    /// statement of the session: Options.of() its connection; text the
    /// dialect writes itself: the defaults). An empty statement has no
    /// tokens but eof. A lexical error fails with its message and offset
    /// in `lex_error`.
    pub fn init(arena: Allocator, src: [:0]const u8, pos: usize, lex_error: ?*LexError, options: Options) Error!Parser {
        var f: lexer.LexFailure = .{ .pos = 0 };
        const st = lexer.statement(arena, src, pos, options.standard_strings, &f) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.LexFailed => {
                if (lex_error) |e| e.* = .{ .fields = f.fields, .pos = f.pos, .state = f.state };
                return error.ParseFailed;
            },
        };
        return .{
            .arena = arena,
            .c = .{ .arena = arena, .sql = src, .src = .init(operatorSyntax(src, st.toks)) },
            .end = st.end,
            .values = st.values,
        };
    }

    /// The value of token `t`: a word folded to lower case, a quoted
    /// identifier's name, a string's value (escapes decoded), a number's
    /// decimal digits, a parameter's number, an operator itself.
    pub fn val(p: *const Parser, t: Token) []const u8 {
        return lexer.value(p.c.sql, &p.values, t);
    }

    /// Whether `t` is an operator of PostgreSQL's (`[`, `]`, `:` and
    /// `::` are tokens of their own).
    fn isOperator(sql: []const u8, t: Token) bool {
        if (t.kind != .op) return false;
        const op = t.text(sql);
        return !(eql(op, "[") or eql(op, "]") or eql(op, ":") or eql(op, "::"));
    }

    /// `OPERATOR(pg_catalog.~)` (psql writes it) is the operator itself.
    fn operatorSyntax(sql: []const u8, toks: []Token) []Token {
        var out: usize = 0;
        var i: usize = 0;
        while (i < toks.len) {
            if (toks[i].isKw("operator") and i + 1 < toks.len and toks[i + 1].kind == .lparen) {
                var j = i + 2;
                while (j + 1 < toks.len and toks[j].kind == .word and toks[j + 1].kind == .dot) j += 2;
                if (j + 1 < toks.len and isOperator(sql, toks[j]) and toks[j + 1].kind == .rparen) {
                    toks[out] = toks[j];
                    out += 1;
                    i = j + 2;
                    continue;
                }
            }
            toks[out] = toks[i];
            out += 1;
            i += 1;
        }
        return toks[0..out];
    }

    /// failState() of an error with PostgreSQL's fields (util.ErrorFields).
    pub fn failFields(p: *Parser, pos: usize, state: int.ErrorState, f: @import("../../sql/util.zig").ErrorFields) Error {
        const msg, const st = try @import("../../sql/util.zig").joinFields(p.arena, state, f);
        return p.c.failState(pos, st, "{s}", .{msg});
    }

    /// Fail with the error a statement run while compiling this one left
    /// in the connection `db`, as it is (its ErrorState too).
    pub fn failFrom(p: *Parser, pos: usize, db: *int.Sqlite3) Error {
        return p.c.failState(pos, db.err_state, "{s}", .{@import("../../sql/main.zig").errmsg(db)});
    }

    /// After a parenthesized query failed: whether its error stands (any
    /// but a syntax error: a relation that does not exist, a feature not
    /// supported) rather than the parenthesis being read another way.
    fn keepsError(p: *const Parser, err: Error) bool {
        if (err == error.OutOfMemory or p.err_in_parse) return true;
        const st = p.c.diag.state orelse return false;
        return !std.mem.eql(u8, &st.sqlstate, "42601");
    }

    pub fn unsupported(p: *Parser, pos: usize, what: []const u8) Error {
        return p.c.failState(pos, .of("0A000"), "{s} is not supported", .{what});
    }

    fn new(p: *Parser, comptime T: type, v: T) Error!*T {
        return tree.new(p.arena, T, v);
    }

    fn expr(p: *Parser, pos: u32, kind: tree.Kind) Error!*Expr {
        return tree.expr(p.arena, pos, p.c.lastEnd(), kind);
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
            else => return p.failFrom(0, ps.db),
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
            return p.c.failState(s.pos, .of("3F000"), "schema \"{s}\" does not exist", .{s.text});
        };
        try p.readSchema();
        return nsp.resolve(ps.db, p.arena, try p.registered(), schema_config, s.text, n.text) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NoSuchSchema => p.c.failState(s.pos, .of("3F000"), "schema \"{s}\" does not exist", .{s.text}),
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
            if (temp and !eql(t.db, "temp")) return p.c.failState(s.pos, .of("42P16"), "cannot create temporary relation in non-temporary schema", .{});
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
        return p.c.failState(q.name.pos, .of("3F000"), "no schema has been selected to create in", .{});
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
                    return p.c.failState(s.pos, .of("42P01"), "{s} \"{s}.{s}\" does not exist", .{ if (kind == .index) "index" else "relation", s.text, q.name.text });
                }
            }
            const t = try p.qualified(s, q.name);
            if (t.mangled) return .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name };
            return .{ .q = .{ .schema = .{ .text = t.db, .pos = s.pos }, .name = .{ .text = t.name, .pos = q.name.pos } } };
        }
        return switch (try p.unqualified(q.name, kind)) {
            .keep => .{ .q = .{ .name = q.name } },
            .target => |t| .{ .q = .{ .name = .{ .text = t.name, .pos = q.name.pos } }, .alias = q.name },
            .missing => p.c.failState(q.name.pos, .of("42P01"), "{s} \"{s}\" does not exist", .{ switch (kind) {
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
                return p.c.failState(q.name.pos, .of("42P01"), "relation \"{s}.{s}\" does not exist", .{ s, q.name.text });
            };
            return null;
        };
        var sub = Parser.init(p.arena, text, 0, null, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseFailed => return p.c.failState(q.name.pos, .of("XX000"), "internal error in the definition of {s}", .{q.name.text}),
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
                return p.c.failState(q.name.pos, .of("XX000"), "internal error in the definition of {s}: {s}", .{ q.name.text, sub.c.diag.msg });
            },
        };
        if (sub.c.peek().kind != .eof) return p.c.failState(q.name.pos, .of("XX000"), "internal error in the definition of {s}", .{q.name.text});
        sel.src = text;
        return sel;
    }

    // ------------------------------------------------------------- names

    /// A column or table name: a quoted identifier or an unquoted word
    /// that is not reserved.
    pub fn colId(p: *Parser) Error!Name {
        const t = p.c.peek();
        if (t.kind == .quoted_ident or (t.kind == .word and !t.isReserved())) {
            p.c.skip();
            return .{ .text = p.val(t), .pos = t.start };
        }
        return p.c.syntaxError();
    }

    /// Any identifier, reserved or not (after AS, after a dot).
    pub fn anyName(p: *Parser) Error!Name {
        const t = p.c.peek();
        if (t.kind == .quoted_ident or t.kind == .word) {
            p.c.skip();
            return .{ .text = p.val(t), .pos = t.start };
        }
        return p.c.syntaxError();
    }

    pub fn qname(p: *Parser) Error!QName {
        const first = try p.colId();
        if (p.c.peek().kind == .dot) {
            p.c.skip();
            const second = try p.anyName();
            if (p.c.peek().kind == .dot) {
                // catalog.schema.name: the catalog is the database.
                p.c.skip();
                const third = try p.anyName();
                return .{ .schema = second, .name = third };
            }
            return .{ .schema = first, .name = second };
        }
        return .{ .name = first };
    }

    pub fn nameList(p: *Parser) Error![]Name {
        return p.c.list(Name, p, colId);
    }

    fn parenNameList(p: *Parser) Error![]Name {
        _ = try p.c.expect(.lparen);
        const l = try p.nameList();
        _ = try p.c.expect(.rparen);
        return l;
    }

    pub fn signedInt(p: *Parser) Error!i64 {
        var neg = false;
        if (p.c.eatOp("-")) neg = true else _ = p.c.eatOp("+");
        const t = p.c.peek();
        if (t.kind != .integer) return p.c.syntaxError();
        p.c.skip();
        const v = std.fmt.parseInt(i64, p.val(t), 10) catch return p.c.failState(t.start, .of("22003"), "value \"{s}\" is out of range for type bigint", .{p.val(t)});
        return if (neg) -v else v;
    }

    // ======================================================== statements

    pub fn statement(p: *Parser) Error!tree.Stmt {
        const s = try p.stmt();
        if (p.c.peek().kind != .eof) return p.c.syntaxError();
        return s;
    }

    fn stmt(p: *Parser) Error!tree.Stmt {
        const s = try p.stmtInto();
        if (p.select_into) |x| {
            // SELECT ... INTO t: CREATE TABLE t AS SELECT ...
            if (s != .select) return p.c.failState(x.pos, .of("42601"), "SELECT ... INTO is not allowed here", .{});
            const dest = try p.createTarget(x.q, x.temp);
            const temp = x.temp or eql(dest.db, "temp");
            return .{ .create_table = try p.new(tree.CreateTable, .{
                .temp = temp,
                .name = .{
                    .schema = if ((x.q.schema != null or dest.mangled) and !temp) Name{ .text = dest.db } else null,
                    .name = .{ .text = dest.name, .pos = x.q.name.pos },
                },
                .as_select = s.select,
                .strict = true,
            }) };
        }
        return s;
    }

    fn stmtInto(p: *Parser) Error!tree.Stmt {
        const t = p.c.peek();
        if (t.kind == .lparen) return .{ .select = try p.select() };
        if (t.kind != .word) return p.c.syntaxError();
        const w = p.val(t);
        if (eql(w, "select") or eql(w, "values") or eql(w, "table")) return .{ .select = try p.select() };
        if (eql(w, "with")) {
            const with = try p.withClause();
            if (p.c.isKw("insert")) return .{ .insert = try p.insert(with) };
            if (p.c.isKw("update")) return .{ .update = try p.update(with) };
            if (p.c.isKw("delete")) return .{ .delete = try p.delete(with) };
            const s = try p.selectAfterWith(with, t.start);
            return .{ .select = s };
        }
        if (eql(w, "insert")) return .{ .insert = try p.insert(null) };
        if (eql(w, "update")) return .{ .update = try p.update(null) };
        if (eql(w, "delete")) return .{ .delete = try p.delete(null) };
        if (eql(w, "begin")) {
            p.c.skip();
            _ = p.c.eatKw("work") or p.c.eatKw("transaction");
            try p.transactionModes();
            return .begin;
        }
        if (eql(w, "start")) {
            p.c.skip();
            try p.c.expectKw("transaction");
            try p.transactionModes();
            return .begin;
        }
        if (eql(w, "commit") or eql(w, "end")) {
            p.c.skip();
            _ = p.c.eatKw("work") or p.c.eatKw("transaction");
            try p.andChain();
            return .commit;
        }
        if (eql(w, "rollback") or eql(w, "abort")) {
            p.c.skip();
            _ = p.c.eatKw("work") or p.c.eatKw("transaction");
            if (eql(w, "rollback") and p.c.eatKw("to")) {
                _ = p.c.eatKw("savepoint");
                return .{ .rollback_to = try p.colId() };
            }
            try p.andChain();
            return .rollback;
        }
        if (eql(w, "savepoint")) {
            p.c.skip();
            return .{ .savepoint = try p.colId() };
        }
        if (eql(w, "release")) {
            p.c.skip();
            _ = p.c.eatKw("savepoint");
            return .{ .release = try p.colId() };
        }
        if (eql(w, "create")) return p.create();
        if (eql(w, "drop")) return .{ .drop = try p.drop() };
        if (eql(w, "alter")) return .{ .alter_table = try p.alterTable() };
        if (eql(w, "truncate")) return .{ .truncate = try p.truncate() };
        if (eql(w, "explain")) {
            p.c.skip();
            if (p.c.peek().kind == .lparen) {
                // EXPLAIN (option [value], ...)
                var depth: usize = 0;
                while (true) {
                    const x = p.c.advance();
                    if (x.kind == .lparen) depth += 1;
                    if (x.kind == .rparen) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    if (x.kind == .eof) return p.c.syntaxError();
                }
            } else {
                _ = p.c.eatKw("analyze") or p.c.eatKw("analyse");
                _ = p.c.eatKw("verbose");
            }
            const inner = try p.new(tree.Stmt, try p.stmt());
            return .{ .explain = inner };
        }
        return p.c.syntaxError();
    }

    fn transactionModes(p: *Parser) Error!void {
        while (true) {
            if (try p.c.optKws(&.{ "isolation", "level" })) {
                if (p.c.eatKw("serializable")) {} else if (try p.c.optKws(&.{ "repeatable", "read" })) {} else if (p.c.eatKw("read")) {
                    if (!p.c.eatKw("committed")) try p.c.expectKw("uncommitted");
                } else return p.c.syntaxError();
            } else if (p.c.eatKw("read")) {
                if (!p.c.eatKw("write")) try p.c.expectKw("only");
            } else if (p.c.eatKws(&.{ "not", "deferrable" })) {} else if (p.c.eatKw("deferrable")) {} else break;
            _ = p.c.eat(.comma);
        }
    }

    fn andChain(p: *Parser) Error!void {
        if (p.c.eatKw("and")) {
            const pos = p.c.peek().start;
            if (try p.c.optKws(&.{ "no", "chain" })) {} else {
                try p.c.expectKw("chain");
                return p.unsupported(pos, "AND CHAIN");
            }
        }
    }

    // ============================================================ SELECT

    fn startsSelect(p: *const Parser, k: usize) bool {
        const t = p.c.peekAt(k);
        return t.isAnyKw(&.{ "select", "values", "with", "table" });
    }

    /// Whether a parenthesized query starts here: `(` then (more `(`s
    /// and) SELECT, VALUES, WITH or TABLE.
    fn parenStartsSelect(p: *const Parser) bool {
        var k: usize = 0;
        while (p.c.peekAt(k).kind == .lparen) k += 1;
        return k > 0 and p.startsSelect(k);
    }

    pub fn select(p: *Parser) Error!*tree.Select {
        const pos = p.c.peek().start;
        var with: ?*tree.With = null;
        if (p.c.isKw("with")) with = try p.withClause();
        return p.selectAfterWith(with, pos);
    }

    fn selectAfterWith(p: *Parser, with: ?*tree.With, pos: u32) Error!*tree.Select {
        const body = try p.setExpr();
        var s: tree.Select = .{ .with = with, .body = body, .pos = pos };
        if (try p.c.optKws(&.{ "order", "by" })) {
            s.order_by = try p.sortList();
        }
        // LIMIT/OFFSET/FETCH in any order, and locking clauses.
        while (true) {
            if (p.c.eatKw("limit")) {
                if (s.limit != null) return p.c.failState(p.c.prev().start, .of("42601"), "multiple LIMIT clauses not allowed", .{});
                if (p.c.eatKw("all")) continue;
                s.limit = try p.expr0();
                if (p.c.eat(.comma)) return p.c.failState(p.c.prev().start, .of("0A000"), "LIMIT #,# syntax is not supported", .{});
            } else if (p.c.eatKw("offset")) {
                if (s.offset != null) return p.c.failState(p.c.prev().start, .of("42601"), "multiple OFFSET clauses not allowed", .{});
                s.offset = try p.expr0();
                _ = p.c.eatKw("row") or p.c.eatKw("rows");
            } else if (p.c.isKw("fetch")) {
                const at = p.c.advance().start;
                if (s.limit != null) return p.c.failState(at, .of("42601"), "multiple LIMIT clauses not allowed", .{});
                if (!p.c.eatKw("first")) try p.c.expectKw("next");
                if (p.c.isKw("row") or p.c.isKw("rows")) {
                    s.limit = try p.expr(at, .{ .integer = "1" });
                } else {
                    s.limit = try p.unary();
                }
                if (!p.c.eatKw("row")) try p.c.expectKw("rows");
                if (p.c.isKw("with")) return p.unsupported(at, "FETCH ... WITH TIES");
                try p.c.expectKw("only");
            } else if (p.c.isKw("for")) {
                // FOR UPDATE/SHARE: a no-op, writers are serialized.
                p.c.skip();
                if (p.c.eatKw("update")) {} else if (p.c.eatKw("share")) {} else if (try p.c.optKws(&.{ "no", "key", "update" })) {} else if (try p.c.optKws(&.{ "key", "share" })) {} else return p.c.syntaxError();
                if (p.c.eatKw("of")) _ = try p.nameList();
                if (p.c.eatKw("nowait")) {} else if (p.c.eatKw("skip")) try p.c.expectKw("locked");
            } else break;
        }
        // A parenthesized query alone is that query.
        if (with == null and s.order_by.len == 0 and s.limit == null and s.offset == null) {
            if (body.* == .nested) return body.nested;
        }
        return p.new(tree.Select, s);
    }

    fn withClause(p: *Parser) Error!*tree.With {
        try p.c.expectKw("with");
        const recursive = p.c.eatKw("recursive");
        var ctes: std.ArrayList(tree.Cte) = .empty;
        while (true) {
            var cte: tree.Cte = .{ .name = try p.colId(), .select = undefined };
            try p.cte_names.append(p.arena, cte.name.text);
            if (p.c.peek().kind == .lparen) cte.cols = try p.parenNameList();
            try p.c.expectKw("as");
            if (p.c.eatKw("materialized")) {
                cte.materialized = true;
            } else if (p.c.eatKws(&.{ "not", "materialized" })) {
                cte.materialized = false;
            }
            _ = try p.c.expect(.lparen);
            if (p.c.isAnyKw(&.{ "insert", "update", "delete" })) {
                return p.unsupported(p.c.peek().start, "a data-modifying statement in WITH");
            }
            cte.select = try p.select();
            _ = try p.c.expect(.rparen);
            try ctes.append(p.arena, cte);
            if (!p.c.eat(.comma)) break;
        }
        return p.new(tree.With, .{ .recursive = recursive, .ctes = ctes.items });
    }

    /// UNION and EXCEPT, left to right, over INTERSECT (which binds
    /// tighter in PostgreSQL).
    fn setExpr(p: *Parser) Error!*tree.Body {
        var left = try p.intersectExpr();
        while (true) {
            const op: tree.SetOp = if (p.c.eatKw("union")) .@"union" else if (p.c.eatKw("except")) .except else break;
            const all = p.c.eatKw("all");
            if (!all) _ = p.c.eatKw("distinct");
            const right = try p.intersectExpr();
            left = try p.new(tree.Body, .{ .compound = .{ .op = op, .all = all, .left = left, .right = right } });
        }
        return left;
    }

    fn intersectExpr(p: *Parser) Error!*tree.Body {
        var left = try p.simpleSelect();
        while (p.c.eatKw("intersect")) {
            const all = p.c.eatKw("all");
            if (!all) _ = p.c.eatKw("distinct");
            const right = try p.simpleSelect();
            left = try p.new(tree.Body, .{ .compound = .{ .op = .intersect, .all = all, .left = left, .right = right } });
        }
        return left;
    }

    fn simpleSelect(p: *Parser) Error!*tree.Body {
        const t = p.c.peek();
        if (t.kind == .lparen) {
            p.c.skip();
            const s = try p.select();
            _ = try p.c.expect(.rparen);
            return p.new(tree.Body, .{ .nested = s });
        }
        if (t.isKw("select")) return p.new(tree.Body, .{ .core = try p.core() });
        if (t.isKw("values")) {
            p.c.skip();
            var rows: std.ArrayList([]*Expr) = .empty;
            while (true) {
                _ = try p.c.expect(.lparen);
                try rows.append(p.arena, try p.exprList());
                _ = try p.c.expect(.rparen);
                if (!p.c.eat(.comma)) break;
            }
            return p.new(tree.Body, .{ .values = rows.items });
        }
        if (t.isKw("table")) {
            p.c.skip();
            const name = try p.qname();
            var cols = try p.arena.alloc(tree.ResultCol, 1);
            cols[0] = .{ .star = t.start };
            var from = try p.arena.alloc(tree.FromItem, 1);
            from[0] = try p.tableItem(name);
            return p.new(tree.Body, .{ .core = try p.new(tree.Core, .{ .cols = cols, .from = from, .pos = t.start }) });
        }
        return p.c.syntaxError();
    }

    fn core(p: *Parser) Error!*tree.Core {
        const pos = p.c.advance().start; // SELECT
        var c: tree.Core = .{ .cols = &.{}, .pos = pos };
        if (p.c.eatKw("distinct")) {
            c.distinct = true;
            if (p.c.isKw("on")) return p.unsupported(p.c.peek().start, "DISTINCT ON");
        } else _ = p.c.eatKw("all");
        if (!p.atClauseEnd()) c.cols = try p.targetList();
        if (p.c.isKw("into")) {
            const into_pos = p.c.advance().start;
            if (p.select_into != null) return p.c.failState(into_pos, .of("42601"), "SELECT ... INTO is not allowed here", .{});
            var temp = false;
            if (p.c.eatKw("temp") or p.c.eatKw("temporary")) temp = true else _ = p.c.eatKw("unlogged");
            _ = p.c.eatKw("table");
            p.select_into = .{ .q = try p.qname(), .temp = temp, .pos = into_pos };
        }
        if (c.cols.len == 0) return p.unsupported(p.c.peek().start, "SELECT without result columns");
        if (p.c.eatKw("from")) c.from = try p.fromList();
        if (p.c.eatKw("where")) c.where = try p.expr0();
        if (try p.c.optKws(&.{ "group", "by" })) {
            _ = p.c.eatKw("all");
            if (p.c.isAnyKw(&.{ "rollup", "cube", "grouping" })) return p.unsupported(p.c.peek().start, "GROUP BY ROLLUP/CUBE/GROUPING SETS");
            c.group_by = try p.exprList();
        }
        if (p.c.eatKw("having")) c.having = try p.expr0();
        if (p.c.eatKw("window")) {
            var wins: std.ArrayList(tree.NamedWindow) = .empty;
            while (true) {
                const name = try p.colId();
                try p.c.expectKw("as");
                try wins.append(p.arena, .{ .name = name, .spec = try p.windowSpec() });
                if (!p.c.eat(.comma)) break;
            }
            c.windows = wins.items;
        }
        try p.selectListSrfs(&c);
        return p.new(tree.Core, c);
    }

    /// The end of the SELECT list: FROM or another clause, or the end.
    fn atClauseEnd(p: *const Parser) bool {
        const t = p.c.peek();
        if (t.kind == .eof or t.kind == .rparen) return true;
        return t.isAnyKw(&.{ "from", "where", "group", "having", "window", "order", "limit", "offset", "fetch", "union", "intersect", "except", "into", "for" });
    }

    pub fn targetList(p: *Parser) Error![]tree.ResultCol {
        var out: std.ArrayList(tree.ResultCol) = .empty;
        while (true) {
            try out.append(p.arena, try p.target());
            if (!p.c.eat(.comma)) break;
        }
        return out.items;
    }

    fn target(p: *Parser) Error!tree.ResultCol {
        const t = p.c.peek();
        if (p.c.isOpTok(t, "*")) {
            p.c.skip();
            return .{ .star = t.start };
        }
        // t.* and s.t.*
        if (t.kind == .word or t.kind == .quoted_ident) {
            var k: usize = 1;
            var names: std.ArrayList(Name) = .empty;
            while (p.c.peekAt(k).kind == .dot) : (k += 2) {
                if (p.c.isOpTok(p.c.peekAt(k + 1), "*")) {
                    var j: usize = 0;
                    while (j < k) : (j += 2) {
                        const nt = p.c.peekAt(j);
                        if (nt.kind != .word and nt.kind != .quoted_ident) break;
                        try names.append(p.arena, .{ .text = p.val(nt), .pos = nt.start });
                    } else {
                        const star = p.c.peekAt(k + 1);
                        p.c.skipN(k + 2);
                        return .{ .table_star = .{ .names = names.items, .star_pos = star.start } };
                    }
                    break;
                }
                const nt = p.c.peekAt(k + 1);
                if (nt.kind != .word and nt.kind != .quoted_ident) break;
            }
        }
        const e = try p.expr0();
        var label: ?Name = null;
        if (p.c.eatKw("as")) {
            label = try p.anyName();
        } else {
            const a = p.c.peek();
            if (a.kind == .quoted_ident or (a.kind == .word and !a.isReserved())) {
                p.c.skip();
                label = .{ .text = p.val(a), .pos = a.start };
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
        return syntax.sortList(p, expr0, .{ .nulls = true, .using = true });
    }

    // -------------------------------------------------------------- FROM

    pub fn fromList(p: *Parser) Error![]tree.FromItem {
        var items: std.ArrayList(tree.FromItem) = .empty;
        try p.tableRef(&items, .none);
        while (p.c.eat(.comma)) try p.tableRef(&items, .comma);
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
            if (p.c.eatKw("natural")) natural = true;
            var kind: tree.JoinKind = .inner;
            if (p.c.eatKw("join")) {} else if (try p.c.optKws(&.{ "inner", "join" })) {} else if (p.c.eatKw("left")) {
                _ = p.c.eatKw("outer");
                try p.c.expectKw("join");
                kind = .left;
            } else if (p.c.eatKw("right")) {
                _ = p.c.eatKw("outer");
                try p.c.expectKw("join");
                kind = .right;
            } else if (p.c.eatKw("full")) {
                _ = p.c.eatKw("outer");
                try p.c.expectKw("join");
                kind = .full;
            } else if (try p.c.optKws(&.{ "cross", "join" })) {
                kind = .cross;
            } else {
                if (natural) return p.c.syntaxError();
                break;
            }
            var item = try p.fromPrimary();
            item.join = kind;
            item.natural = natural;
            if (kind != .cross and !natural) {
                if (p.c.eatKw("on")) {
                    item.on = try p.expr0();
                } else if (p.c.eatKw("using")) {
                    item.using = try p.parenNameList();
                } else return p.c.syntaxError();
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
        const t = p.c.peek();
        if (t.isKw("lateral")) {
            // LATERAL function(...): a function's arguments may name the
            // items before it anyway.
            const n1 = p.c.peekAt(1);
            if (!((n1.kind == .word or n1.kind == .quoted_ident) and p.c.peekAt(2).kind == .lparen)) return p.unsupported(t.start, "LATERAL");
            p.c.skip();
        }
        if (t.kind == .lparen) {
            if (p.parenStartsSelect()) {
                const save = p.c.mark();
                p.c.skip();
                if (p.select()) |s| {
                    if (p.c.eat(.rparen)) {
                        var item: tree.FromItem = .{ .source = .{ .subquery = s } };
                        item.alias = try p.alias(true);
                        return item;
                    }
                } else |err| if (p.keepsError(err)) return err;
                p.c.reset(save);
            }
            p.c.skip();
            const inner = try p.fromList();
            _ = try p.c.expect(.rparen);
            var item: tree.FromItem = .{ .source = .{ .nested = inner } };
            item.alias = try p.alias(false);
            return item;
        }
        _ = p.c.eatKw("only");
        const name = try p.qname();
        if (p.c.peek().kind == .lparen) {
            if (arraySrfKind(name)) |k| return p.arraySrf(name, k);
            if (name.schema == null) if (srfKind(name.name.text)) |k| return p.jsonSrf(name.name, k);
            if (name.schema == null and eql(name.name.text, "pg_input_error_info")) return p.inputErrorSrf(name.name);
            const c = try p.funcCall(name.name, name.schema);
            if (eql(c.name.text, "pg_partition_ancestors") and c.args.len == 1) {
                const ord = p.c.isKw("with") and p.c.isKwAt(1, "ordinality");
                if (ord) {
                    p.c.skip();
                    p.c.skip();
                }
                return p.partitionAncestors(c, try p.alias(true), ord);
            }
            const al = try p.alias(true);
            if (eql(c.name.text, "generate_series")) return p.generateSeries(c, al);
            const f = try p.new(tree.Func, .{ .name = c.name, .args = c.args });
            return .{ .source = .{ .func = f }, .alias = al };
        }
        _ = p.c.eatOp("*");
        var item = try p.tableItem(name);
        if (try p.alias(true)) |al| item.alias = al;
        if (p.c.isKw("tablesample")) return p.unsupported(p.c.peek().start, "TABLESAMPLE");
        return item;
    }

    /// pg_partition_ancestors(rel) [WITH ORDINALITY] in FROM: the relation
    /// itself, its only ancestor (xqlite has no partitions):
    /// (SELECT rel AS relid [, 1 AS ordinality]) AS alias.
    fn partitionAncestors(p: *Parser, c: Call, al: ?tree.Alias, ord: bool) Error!tree.FromItem {
        const pos = c.name.pos;
        const alias_cols: []const Name = if (al) |a| a.cols else &.{};
        const n: usize = if (ord) 2 else 1;
        if (alias_cols.len > n) return p.c.failState(alias_cols[n].pos, .of("42601"), "too many column aliases", .{});
        var cols = try p.arena.alloc(tree.ResultCol, n);
        const rel = try p.castExpr(pos, c.args[0], .{ .name = "regclass", .pos = pos });
        cols[0] = .{ .expr = .{ .e = rel, .alias = .{ .text = if (alias_cols.len > 0) alias_cols[0].text else if (al) |a| a.name.text else "pg_partition_ancestors" } } };
        if (ord) cols[1] = .{ .expr = .{ .e = try p.expr(pos, .{ .integer = "1" }), .alias = .{ .text = if (alias_cols.len > 1) alias_cols[1].text else "ordinality" } } };
        const body = try p.new(tree.Body, .{ .core = try p.new(tree.Core, .{ .cols = cols, .pos = pos }) });
        const sub = try p.new(tree.Select, .{ .body = body, .pos = pos });
        const label: Name = if (al) |a| a.name else .{ .text = "pg_partition_ancestors", .pos = pos };
        return .{ .source = .{ .subquery = sub }, .alias = .{ .name = label } };
    }

    /// generate_series(...) in FROM: its column is named after the
    /// function or the alias, as in PostgreSQL (SQLite's is "value"):
    /// (SELECT value AS col FROM generate_series(...)) AS alias.
    fn generateSeries(p: *Parser, c: Call, al: ?tree.Alias) Error!tree.FromItem {
        const alias_cols: []const Name = if (al) |a| a.cols else &.{};
        if (alias_cols.len > 1) return p.c.failState(alias_cols[1].pos, .of("42601"), "too many column aliases for generate_series", .{});
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

    // ===================================================== JSON functions

    /// A JSON set-returning function in FROM (json_each(), jsonb_array_
    /// elements(), json_to_recordset() AS x(a int, ...) ...): the
    /// table-valued json_each() of the rows xq_pg_rows_*() builds, its
    /// columns recorded in `srfs` for jtype.zig (which replaces
    /// references to them).
    fn jsonSrf(p: *Parser, name: Name, kind: SrfKind) Error!tree.FromItem {
        const fname = name.text;
        var args: []*Expr = &.{};
        var base: ?QName = null;
        if (kind == .populate) {
            // (NULL::table, json): the record type is a table's.
            _ = try p.c.expect(.lparen);
            try p.c.expectKw("null");
            if (!p.c.eatOp("::")) return p.unsupported(p.c.peek().start, "a record argument other than NULL::table");
            base = try p.qname();
            _ = try p.c.expect(.comma);
            args = try p.exprList();
            _ = try p.c.expect(.rparen);
        } else {
            const c = try p.funcCall(name, null);
            args = c.args;
        }
        const want: usize = switch (kind) {
            .path => 2,
            else => 1,
        };
        if (args.len < want or (kind != .path and args.len != want) or args.len > 4) {
            return p.c.failState(name.pos, .of("42883"), "function {s} with {d} arguments does not exist", .{ fname, args.len });
        }
        var ordinality = false;
        if (p.c.eatKws(&.{ "with", "ordinality" })) {
            ordinality = true;
        }
        // The alias, with column definitions for json_to_record().
        var label: Name = name;
        var alias_cols: std.ArrayList(Name) = .empty;
        var defs: std.ArrayList(SrfCol) = .empty;
        const has_alias = p.c.isKw("as") or (p.c.peek().kind == .quoted_ident or (p.c.peek().kind == .word and !p.c.peek().isReserved() and !p.c.isKw("on") and !p.c.isKw("using")));
        if (has_alias) {
            _ = p.c.eatKw("as");
            label = try p.colId();
            if (p.c.eat(.lparen)) {
                while (true) {
                    const cn = try p.colId();
                    if (kind == .records) {
                        const ty = try p.typeName();
                        try defs.append(p.arena, .{ .name = cn.text, .index = @intCast(defs.items.len), .cast = ty });
                    } else try alias_cols.append(p.arena, cn);
                    if (!p.c.eat(.comma)) break;
                }
                _ = try p.c.expect(.rparen);
            }
        }
        const pos = name.pos;
        var cols: std.ArrayList(SrfCol) = .empty;
        const jsonb = std.mem.startsWith(u8, fname, "jsonb");
        const as_text = std.mem.endsWith(u8, fname, "_text");
        const jtype: ?types.TypeName = if (as_text) null else .{ .name = if (jsonb) "jsonb" else "json", .pos = pos };
        var rows_args: std.ArrayList(*Expr) = .empty;
        try rows_args.append(p.arena, args[0]);
        var rows_fn: []const u8 = undefined;
        switch (kind) {
            .each => {
                rows_fn = "xq_pg_rows_each";
                try cols.append(p.arena, .{ .name = "key", .index = 0 });
                try cols.append(p.arena, .{ .name = "value", .index = 1, .cast = jtype });
            },
            .elements => {
                rows_fn = "xq_pg_rows_elements";
                try cols.append(p.arena, .{ .name = "value", .cast = jtype });
            },
            .keys => {
                rows_fn = "xq_pg_rows_keys";
                try cols.append(p.arena, .{ .name = if (has_alias) label.text else fname });
            },
            .path => {
                rows_fn = "xq_pg_rows_path";
                try cols.append(p.arena, .{ .name = if (has_alias) label.text else fname, .cast = .{ .name = "jsonb", .pos = pos } });
            },
            .records => {
                rows_fn = "xq_pg_rows_records";
                if (defs.items.len == 0) return p.c.failState(pos, .of("42601"), "a column definition list is required for functions returning \"record\"", .{});
                try cols.appendSlice(p.arena, defs.items);
            },
            .populate => {
                rows_fn = "xq_pg_rows_records";
                try p.recordColumns(base.?, &cols);
            },
            .unnest, .subscripts, .expand, .re_matches, .re_split => unreachable,
        }
        if (kind == .path) {
            try rows_args.append(p.arena, args[1]);
            try rows_args.append(p.arena, if (args.len > 2) args[2] else try p.expr(pos, .null));
            try rows_args.append(p.arena, if (args.len > 3) args[3] else try p.expr(pos, .{ .integer = "0" }));
        } else {
            try rows_args.append(p.arena, try p.stringAt(pos, fname));
        }
        if (kind == .records or kind == .populate) {
            if (kind == .populate) rows_args.items[1] = try p.stringAt(pos, if (std.mem.endsWith(u8, fname, "set")) "json_populate_recordset" else "json_populate_record");
            if (jsonb and kind == .populate) rows_args.items[1] = try p.stringAt(pos, if (std.mem.endsWith(u8, fname, "set")) "jsonb_populate_recordset" else "jsonb_populate_record");
            for (cols.items) |col| try rows_args.append(p.arena, try p.stringAt(pos, col.name));
        }
        if (ordinality) try cols.append(p.arena, .{ .name = "ordinality", .ordinality = true });
        if (alias_cols.items.len > cols.items.len) return p.c.failState(alias_cols.items[cols.items.len].pos, .of("42601"), "too many column aliases specified for function {s}", .{fname});
        for (alias_cols.items, 0..) |a, i| cols.items[i].name = a.text;
        const rows = try p.call(pos, rows_fn, null, rows_args.items);
        const f = try p.new(tree.Func, .{ .name = .{ .text = "json_each", .pos = pos }, .args = try p.list(&.{rows}) });
        try p.srfs.put(p.arena, f, .{ .cols = cols.items });
        return .{ .source = .{ .func = f }, .alias = .{ .name = label } };
    }

    /// unnest(a [, b ...]), generate_subscripts(a, d [, reverse]) and
    /// information_schema._pg_expandarray(a) in FROM: the table-valued
    /// json_each() of the rows xq_pg_rows_*() makes of the arrays (as
    /// jsonSrf()), several unnest()'s arrays side by side (NULL past the
    /// end of the shorter: xq_pg_rows_zip()).
    fn arraySrf(p: *Parser, q: QName, kind: SrfKind) Error!tree.FromItem {
        const name = q.name;
        const fname = name.text;
        const c = try p.funcCall(name, q.schema);
        const args = c.args;
        const pos = name.pos;
        const ok = switch (kind) {
            .unnest => args.len >= 1,
            .subscripts => args.len == 2 or args.len == 3,
            .re_matches, .re_split => args.len == 2 or args.len == 3,
            else => args.len == 1,
        };
        if (!ok) return p.c.failState(pos, .of("42883"), "function {s} with {d} arguments does not exist", .{ fname, args.len });
        var ordinality = false;
        if (p.c.eatKws(&.{ "with", "ordinality" })) {
            ordinality = true;
        }
        var label: Name = name;
        var alias_cols: []const Name = &.{};
        const has_alias = p.c.isKw("as") or (p.c.peek().kind == .quoted_ident or (p.c.peek().kind == .word and !p.c.peek().isReserved() and !p.c.isKw("on") and !p.c.isKw("using")));
        if (has_alias) {
            _ = p.c.eatKw("as");
            label = try p.colId();
            if (p.c.peek().kind == .lparen) alias_cols = try p.parenNameList();
        }
        var cols: std.ArrayList(SrfCol) = .empty;
        var rows: *Expr = undefined;
        switch (kind) {
            .unnest => {
                if (args.len == 1) {
                    rows = try p.call(pos, "xq_pg_rows_unnest", null, &.{args[0]});
                    try cols.append(p.arena, .{ .name = if (has_alias and !ordinality) label.text else fname });
                } else {
                    var each: std.ArrayList(*Expr) = .empty;
                    for (args, 0..) |a, i| {
                        try each.append(p.arena, try p.call(pos, "xq_pg_rows_unnest", null, &.{a}));
                        try cols.append(p.arena, .{ .name = fname, .index = @intCast(i) });
                    }
                    rows = try p.call(pos, "xq_pg_rows_zip", null, each.items);
                }
            },
            .subscripts => {
                rows = try p.call(pos, "xq_pg_rows_subscripts", null, &.{ args[0], args[1], if (args.len > 2) args[2] else try p.expr(pos, .{ .integer = "0" }) });
                try cols.append(p.arena, .{ .name = if (has_alias and !ordinality) label.text else fname });
            },
            .re_matches, .re_split => {
                rows = try p.regexpRows(pos, kind, args);
                try cols.append(p.arena, .{ .name = if (has_alias and !ordinality) label.text else fname, .cast = if (kind == .re_matches) text_array else null });
            },
            else => {
                rows = try p.call(pos, "xq_pg_rows_expand", null, &.{ args[0], try p.expr(pos, .{ .integer = "0" }) });
                try cols.append(p.arena, .{ .name = "x", .index = 0 });
                try cols.append(p.arena, .{ .name = "n", .index = 1 });
            },
        }
        if (ordinality) try cols.append(p.arena, .{ .name = "ordinality", .ordinality = true });
        if (alias_cols.len > cols.items.len) return p.c.failState(alias_cols[cols.items.len].pos, .of("42601"), "too many column aliases specified for function {s}", .{fname});
        for (alias_cols, 0..) |a, i| cols.items[i].name = a.text;
        const f = try p.new(tree.Func, .{ .name = .{ .text = "json_each", .pos = pos }, .args = try p.list(&.{rows}) });
        try p.srfs.put(p.arena, f, .{ .cols = cols.items });
        return .{ .source = .{ .func = f }, .alias = .{ .name = label } };
    }

    /// The rows of regexp_matches(s, p [, flags]) or
    /// regexp_split_to_table(s, p [, flags]) (regexp.zig).
    fn regexpRows(p: *Parser, pos: u32, kind: SrfKind, args: []const *Expr) Error!*Expr {
        const flags = if (args.len > 2) args[2] else try p.stringAt(pos, "");
        const name = if (kind == .re_matches) "xq_pg_rows_regexp_matches" else "xq_pg_rows_regexp_split";
        return p.call(pos, name, null, &.{ args[0], args[1], flags });
    }

    /// pg_input_error_info(text, type) in FROM: the json_each() of the one
    /// row xq_pg_rows_input_error() makes (inputinfo.zig), as jsonSrf().
    fn inputErrorSrf(p: *Parser, name: Name) Error!tree.FromItem {
        const c = try p.funcCall(name, null);
        if (c.args.len != 2) return p.c.failState(name.pos, .of("42883"), "function pg_input_error_info with {d} arguments does not exist", .{c.args.len});
        var label: Name = name;
        var alias_cols: []const Name = &.{};
        const has_alias = p.c.isKw("as") or (p.c.peek().kind == .quoted_ident or (p.c.peek().kind == .word and !p.c.peek().isReserved() and !p.c.isKw("on") and !p.c.isKw("using")));
        if (has_alias) {
            _ = p.c.eatKw("as");
            label = try p.colId();
            if (p.c.peek().kind == .lparen) alias_cols = try p.parenNameList();
        }
        var cols: std.ArrayList(SrfCol) = .empty;
        for ([_][]const u8{ "message", "detail", "hint", "sql_error_code" }, 0..) |cn, i| {
            try cols.append(p.arena, .{ .name = cn, .index = @intCast(i), .cast = .{ .name = "text", .pos = name.pos } });
        }
        if (alias_cols.len > cols.items.len) return p.c.failState(alias_cols[cols.items.len].pos, .of("42601"), "too many column aliases specified for function {s}", .{name.text});
        for (alias_cols, 0..) |a, i| cols.items[i].name = a.text;
        const rows = try p.call(name.pos, "xq_pg_rows_input_error", null, c.args);
        const f = try p.new(tree.Func, .{ .name = .{ .text = "json_each", .pos = name.pos }, .args = try p.list(&.{rows}) });
        try p.srfs.put(p.arena, f, .{ .cols = cols.items });
        return .{ .source = .{ .func = f }, .alias = .{ .name = label } };
    }

    /// The columns of the row type of table `q` (json_populate_record()).
    fn recordColumns(p: *Parser, q: QName, cols: *std.ArrayList(SrfCol)) Error!void {
        const rel = try p.lookup(q, .relation);
        const ps = p.p orelse return p.c.failState(q.name.pos, .of("42704"), "type \"{s}\" does not exist", .{q.name.text});
        const t = build.findTable(ps.db, rel.q.name.text, if (rel.q.schema) |sc| sc.text else null) orelse
            return p.c.failState(q.name.pos, .of("42704"), "type \"{s}\" does not exist", .{q.name.text});
        const m = catalog.metaOf(ps.db, t) catch null;
        for (t.cols) |*c| {
            const decl = if (m) |x| x.declType(c.name()) else null;
            var ty: ?types.TypeName = null;
            if (decl) |d| {
                const z = try p.arena.dupeSentinel(u8, d, 0);
                var sub = Parser.init(p.arena, z, 0, null, .{}) catch return p.c.failState(q.name.pos, .of("42704"), "type \"{s}\" does not exist", .{d});
                ty = sub.typeName() catch null;
            }
            try cols.append(p.arena, .{ .name = c.name(), .index = @intCast(cols.items.len), .cast = ty orelse .{ .name = "text", .pos = q.name.pos } });
        }
    }

    /// The expression column `col` of SRF item `alias` stands for.
    pub fn srfColumn(p: *Parser, item: []const u8, col: SrfCol, pos: u32) Error!*Expr {
        const names = try p.arena.alloc(Name, 2);
        names[0] = .{ .text = item, .pos = pos };
        names[1] = .{ .text = if (col.ordinality) "key" else "value", .pos = pos };
        var v = try p.expr(pos, .{ .column = names });
        try p.srf_refs.put(p.arena, v, {});
        if (col.ordinality) return p.expr(pos, .{ .binary = .{ .op = .add, .l = v, .r = try p.expr(pos, .{ .integer = "1" }) } });
        if (col.index) |i| {
            const path = try std.fmt.allocPrint(p.arena, "$[{d}]", .{i});
            v = try p.call(pos, "json_extract", null, &.{ v, try p.stringAt(pos, path) });
        }
        if (col.cast) |ty| v = try p.castExpr(pos, v, ty);
        return v;
    }

    /// Set-returning calls of the select list (jsonb_array_elements(j),
    /// json_object_keys(j), jsonb_path_query(j, p)): a json_each() item
    /// joined after the others, each call replaced by its column. Several
    /// run in step, as in PostgreSQL (the rows of the longest, NULL past
    /// the end of the others: xq_pg_rows_zip()).
    fn selectListSrfs(p: *Parser, c: *tree.Core) Error!void {
        var found: std.ArrayList(*Expr) = .empty;
        for (c.cols) |rc| if (rc == .expr) try p.findSrfs(rc.expr.e, &found);
        if (found.items.len == 0) return;
        const pos = found.items[0].pos;
        if (c.group_by.len > 0) return p.unsupported(pos, "a set-returning function in a select list with GROUP BY");
        var rows: std.ArrayList(*Expr) = .empty;
        var cols: std.ArrayList(SrfCol) = .empty;
        for (found.items, 0..) |e, i| {
            const f = e.kind.func;
            const kind = srfKind(f.name.text).?;
            switch (kind) {
                .each, .records, .populate => return p.unsupported(e.pos, "a record-returning function in a select list"),
                .re_matches, .re_split => {
                    const n = f.args.len;
                    if (n != 2 and n != 3) return p.c.failState(f.name.pos, .of("42883"), "function {s} with {d} arguments does not exist", .{ f.name.text, n });
                    try rows.append(p.arena, try p.regexpRows(e.pos, kind, f.args));
                    try cols.append(p.arena, .{
                        .name = f.name.text,
                        .index = if (found.items.len > 1) @intCast(i) else null,
                        .cast = if (kind == .re_matches) text_array else null,
                    });
                    continue;
                },
                .unnest, .subscripts, .expand => {
                    const n = f.args.len;
                    if (!(if (kind == .subscripts) n == 2 or n == 3 else n == 1)) {
                        return p.c.failState(f.name.pos, .of("42883"), "function {s} with {d} arguments does not exist", .{ f.name.text, n });
                    }
                    const zero = try p.expr(e.pos, .{ .integer = "0" });
                    const r = switch (kind) {
                        .unnest => try p.call(e.pos, "xq_pg_rows_unnest", null, &.{f.args[0]}),
                        .subscripts => try p.call(e.pos, "xq_pg_rows_subscripts", null, &.{ f.args[0], f.args[1], if (n > 2) f.args[2] else zero }),
                        else => try p.call(e.pos, "xq_pg_rows_expand", null, &.{ f.args[0], try p.expr(e.pos, .{ .integer = "1" }) }),
                    };
                    try rows.append(p.arena, r);
                    try cols.append(p.arena, .{
                        .name = f.name.text,
                        .index = if (found.items.len > 1) @intCast(i) else null,
                        // A subscript is an integer (json_extract()'s is no type).
                        .cast = if (kind == .subscripts) .{ .name = "integer", .pos = e.pos } else null,
                    });
                    continue;
                },
                else => {},
            }
            const want: usize = if (kind == .path) 2 else 1;
            if (f.args.len < want or (kind != .path and f.args.len != want) or f.args.len > 4) {
                return p.c.failState(f.name.pos, .of("42883"), "function {s} with {d} arguments does not exist", .{ f.name.text, f.args.len });
            }
            const fname = f.name.text;
            var rows_args: std.ArrayList(*Expr) = .empty;
            try rows_args.append(p.arena, f.args[0]);
            var col: SrfCol = .{ .name = fname, .index = if (found.items.len > 1) @intCast(i) else null };
            const rows_fn: []const u8 = switch (kind) {
                .elements => blk: {
                    if (!std.mem.endsWith(u8, fname, "_text")) col.cast = .{ .name = if (std.mem.startsWith(u8, fname, "jsonb")) "jsonb" else "json", .pos = e.pos };
                    break :blk "xq_pg_rows_elements";
                },
                .keys => "xq_pg_rows_keys",
                .path => blk: {
                    col.cast = .{ .name = "jsonb", .pos = e.pos };
                    break :blk "xq_pg_rows_path";
                },
                else => unreachable,
            };
            if (kind == .path) {
                try rows_args.append(p.arena, f.args[1]);
                try rows_args.append(p.arena, if (f.args.len > 2) f.args[2] else try p.expr(e.pos, .null));
                try rows_args.append(p.arena, if (f.args.len > 3) f.args[3] else try p.expr(e.pos, .{ .integer = "0" }));
            } else try rows_args.append(p.arena, try p.stringAt(e.pos, fname));
            try rows.append(p.arena, try p.call(e.pos, rows_fn, null, rows_args.items));
            try cols.append(p.arena, col);
        }
        p.srf_count += 1;
        const label = try std.fmt.allocPrint(p.arena, "xq_srf{d}", .{p.srf_count});
        const all = if (rows.items.len == 1) rows.items[0] else try p.call(pos, "xq_pg_rows_zip", null, rows.items);
        const each = try p.new(tree.Func, .{ .name = .{ .text = "json_each", .pos = pos }, .args = try p.list(&.{all}) });
        var from: std.ArrayList(tree.FromItem) = .empty;
        try from.appendSlice(p.arena, c.from);
        try from.append(p.arena, .{ .join = if (c.from.len > 0) .comma else .none, .source = .{ .func = each }, .alias = .{ .name = .{ .text = label, .pos = pos } } });
        try p.srfs.put(p.arena, each, .{ .cols = &.{} });
        c.from = from.items;
        for (found.items, cols.items) |e, col| {
            const v = try p.srfColumn(label, col, e.pos);
            e.kind = v.kind;
            if (e.kind == .column) try p.srf_refs.put(p.arena, e, {});
        }
    }

    /// The set-returning calls in `e` (not in subqueries).
    fn findSrfs(p: *Parser, e: *Expr, found: *std.ArrayList(*Expr)) Error!void {
        if (e.kind == .func) {
            const f = e.kind.func;
            if (f.dialect == null and f.over == null and srfKind(f.name.text) != null) {
                try found.append(p.arena, e);
                return;
            }
        }
        var it = Children.of(e);
        while (it.next()) |x| try p.findSrfs(x, found);
    }

    /// `e IS [NOT] JSON [VALUE|ARRAY|OBJECT|SCALAR] [WITH|WITHOUT UNIQUE [KEYS]]`
    /// (after JSON).
    fn isJson(p: *Parser, l: *Expr, not: bool) Error!*Expr {
        var kind: []const u8 = "0";
        if (p.c.eatKw("value")) {} else if (p.c.eatKw("array")) {
            kind = "1";
        } else if (p.c.eatKw("object")) {
            kind = "2";
        } else if (p.c.eatKw("scalar")) kind = "3";
        var unique: []const u8 = "0";
        if ((p.c.isKw("with") or p.c.isKw("without")) and p.c.isKwAt(1, "unique")) {
            if (p.c.advance().isKw("with")) unique = "1";
            p.c.skip();
            _ = p.c.eatKw("keys");
        }
        const e = try p.call(l.pos, "xq_pg_is_json", null, &.{ l, try p.expr(l.pos, .{ .integer = kind }), try p.expr(l.pos, .{ .integer = unique }) });
        if (!not) return e;
        return p.expr(l.pos, .{ .unary = .{ .op = .not, .e = e } });
    }

    /// The DEFAULT (`default`) or generated value of a numeric column, as
    /// the column stores it (decimal.zig's key): a number or a string
    /// constant its key as a blob constant (so that the schema keeps a
    /// constant sqlite3 reads), another value through xq_dec_key(e, p, s).
    fn numericStored(p: *Parser, ty: types.TypeName, e: *Expr, default: bool) Error!*Expr {
        if (ty.array or !eql(ty.name, "numeric")) return e;
        if (e.kind == .null) return e;
        const mods = numericMods(ty);
        if (default) if (constantText(e)) |lit| {
            const decimal = @import("../decimal.zig");
            var buf: [256]u8 = undefined;
            const text = if (lit.neg) std.fmt.bufPrint(&buf, "-{s}", .{lit.text}) catch lit.text else lit.text;
            if (decimal.parse(p.arena, text)) |d0| {
                var d = d0;
                const fits = if (mods) |m| blk: {
                    d = decimal.applyTypmod(p.arena, d, @intCast(m[0]), @intCast(m[1])) catch break :blk false;
                    break :blk true;
                } else true;
                // Out of the type's range: the error when a row takes it.
                if (fits) {
                    if (decimal.check(d)) |_| {
                        const k = decimal.key(p.arena, d, false) catch return error.OutOfMemory;
                        return p.expr(e.pos, .{ .blob = try std.fmt.allocPrint(p.arena, "{x}", .{k}) });
                    } else |_| {}
                }
            } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        };
        const mode: tree.CastMode = if (mods) |m|
            .{ .func_args = .{ .func = "xq_dec_key", .args = try p.arena.dupe(i64, &m) } }
        else
            .{ .func = "xq_dec_key" };
        return tree.expr(p.arena, e.pos, e.end, .{ .cast = .{ .e = e, .target_type = try types.format(p.arena, ty), .mode = mode } });
    }

    /// The arguments of xq_pg_iv_in() after the value, for type modifier
    /// `tm`, in the session (ivinput.inArgs()).
    fn ivInArgs(p: *Parser, tm: i64) Error![]const i64 {
        var buf: [2]i64 = undefined;
        return p.arena.dupe(i64, ivinput.inArgs(if (p.p) |ps| ps.db else null, tm, &buf));
    }

    /// The DEFAULT of a json/jsonb column: a constant checked (and for
    /// jsonb made its JSONB blob) here, so that the schema keeps a
    /// literal sqlite3 reads; another jsonb expression made a blob
    /// (jsonbStored()).
    /// The DEFAULT of an interval column: a BLOB (xq_pg_iv_in(e,
    /// typmod)), as the values stored into it.
    fn jsonDefault(p: *Parser, ty: types.TypeName, e: *Expr) Error!*Expr {
        if (!ty.array and eql(ty.name, "interval") and e.kind != .null) {
            const tm = types.intervalTypmod(ty);
            if (tm < 0 and e.kind == .cast and eql(e.kind.cast.target_type, "interval")) return e;
            return p.expr(e.pos, .{ .cast = .{ .e = e, .target_type = "interval", .mode = .{ .func_args = .{ .func = "xq_pg_iv_in", .args = try p.ivInArgs(tm) } } } });
        }
        const jsonb = eql(ty.name, "jsonb");
        if (ty.array or !(jsonb or eql(ty.name, "json"))) return e;
        var lit = e;
        if (lit.kind == .cast and (eql(lit.kind.cast.target_type, "jsonb") or eql(lit.kind.cast.target_type, "json"))) lit = lit.kind.cast.e;
        if (lit.kind != .string) return if (jsonb) p.jsonbStored(ty, e) else e;
        const text = lit.kind.string;
        const v = (if (jsonb) json.parseJsonb(p.arena, text) else json.parse(p.arena, text, false)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return p.c.failState(lit.pos, .of("22P02"), "invalid input syntax for type json", .{});
        };
        if (!jsonb) return lit;
        const b = json.toBlob(p.arena, v) catch return error.OutOfMemory;
        return p.expr(lit.pos, .{ .blob = try std.fmt.allocPrint(p.arena, "{x}", .{b}) });
    }

    /// A value a jsonb column stores that is not a constant (a DEFAULT,
    /// a generated column's): xq_pg_jsonb_bin(e), its JSONB blob.
    fn jsonbStored(p: *Parser, ty: types.TypeName, e: *Expr) Error!*Expr {
        if (ty.array or !eql(ty.name, "jsonb") or e.kind == .null) return e;
        return p.call(e.pos, "xq_pg_jsonb_bin", null, &.{e});
    }

    /// The DEFAULT of a uuid column: a string literal (or its cast to
    /// uuid) is the blob of its 16 bytes, read now as PostgreSQL reads it
    /// (uuid.zig); another expression as written.
    fn uuidDefault(p: *Parser, ty: types.TypeName, e: *Expr) Error!*Expr {
        if (ty.array or !eql(ty.name, "uuid")) return e;
        var lit = e;
        if (lit.kind == .cast and eql(lit.kind.cast.target_type, "uuid")) lit = lit.kind.cast.e;
        if (lit.kind != .string) return e;
        const b = uuid.parse(lit.kind.string) orelse return p.c.failState(lit.pos, .of("22P02"), "invalid input syntax for type uuid: \"{s}\"", .{lit.kind.string});
        return p.expr(lit.pos, .{ .blob = try std.fmt.allocPrint(p.arena, "{x}", .{&b}) });
    }

    /// JSON_OBJECT(k VALUE v | k : v, ...), JSON_ARRAY(v, ... | query),
    /// JSON_ARRAYAGG(v [ORDER BY]), JSON_OBJECTAGG(k : v), with [NULL |
    /// ABSENT] ON NULL, [WITH | WITHOUT] UNIQUE [KEYS], RETURNING json |
    /// jsonb; null for json_object(text[]) and other calls.
    fn jsonCtor(p: *Parser, start: u32, name: Name) Error!?*Expr {
        const n = name.text;
        const which: enum { object, array, arrayagg, objectagg } = if (eql(n, "json_object")) .object else if (eql(n, "json_array")) .array else if (eql(n, "json_arrayagg")) .arrayagg else if (eql(n, "json_objectagg")) .objectagg else return null;
        const save = p.c.mark();
        _ = try p.c.expect(.lparen);
        var absent = which == .array or which == .arrayagg;
        var unique = false;
        var jsonb = false;
        var args: std.ArrayList(*Expr) = .empty;
        var order_by: []tree.SortItem = &.{};
        var query: ?*tree.Select = null;
        if (which == .array and p.startsSelect(0)) {
            query = try p.select();
        } else if (p.c.peek().kind != .rparen and !p.isCtorClause()) {
            while (true) {
                const k = try p.expr0();
                if (which == .object or which == .objectagg) {
                    if (!p.c.eatKw("value") and !p.c.eatOp(":")) {
                        if (which == .object and args.items.len == 0) {
                            // json_object(text[] [, text[]]): the function.
                            p.c.reset(save);
                            return null;
                        }
                        return p.c.syntaxError();
                    }
                    try args.append(p.arena, k);
                    try args.append(p.arena, try p.formatJson(try p.expr0()));
                } else try args.append(p.arena, try p.formatJson(k));
                if (which == .arrayagg or which == .objectagg) break;
                if (!p.c.eat(.comma)) break;
            }
        }
        if (which == .arrayagg and p.c.isKw("order")) {
            p.c.skip();
            try p.c.expectKw("by");
            order_by = try p.sortList();
        }
        while (true) {
            if ((p.c.isKw("null") or p.c.isKw("absent")) and p.c.isKwAt(1, "on")) {
                absent = p.c.advance().isKw("absent");
                p.c.skip();
                try p.c.expectKw("null");
            } else if ((p.c.isKw("with") or p.c.isKw("without")) and p.c.isKwAt(1, "unique")) {
                unique = p.c.advance().isKw("with");
                p.c.skip();
                _ = p.c.eatKw("keys");
            } else if (p.c.eatKw("returning")) {
                const ty = try p.typeName();
                jsonb = eql(ty.name, "jsonb");
                if (!jsonb and !eql(ty.name, "json")) return p.unsupported(ty.pos, "RETURNING a type other than json or jsonb");
                try p.formatClause();
            } else break;
        }
        _ = try p.c.expect(.rparen);
        const flags: i64 = @as(i64, @intFromBool(jsonb)) | @as(i64, if (absent) 2 else 0) | @as(i64, if (unique) 4 else 0);
        const flag_e = try p.expr(start, .{ .integer = try std.fmt.allocPrint(p.arena, "{d}", .{flags}) });
        var e: *Expr = undefined;
        switch (which) {
            .object, .array => {
                if (query) |q| {
                    // (SELECT JSON_ARRAYAGG(x) FROM (query) AS q(x)).
                    const names = try p.arena.alloc(Name, 1);
                    names[0] = .{ .text = "xq_v", .pos = start };
                    const col = try p.expr(start, .{ .column = names });
                    const v = try p.call(start, "xq_pg_json_arrayagg", null, &.{ col, flag_e });
                    var from = try p.arena.alloc(tree.FromItem, 1);
                    const cols_names = try p.arena.alloc(Name, 1);
                    cols_names[0] = names[0];
                    from[0] = .{ .source = .{ .subquery = q }, .alias = .{ .name = .{ .text = "xq_q", .pos = start }, .cols = cols_names } };
                    const rcs = try p.arena.alloc(tree.ResultCol, 1);
                    rcs[0] = .{ .expr = .{ .e = v } };
                    const core_ = try p.new(tree.Core, .{ .cols = rcs, .from = from, .pos = start });
                    const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core_ }), .pos = start });
                    e = try p.expr(start, .{ .subquery = sel });
                } else {
                    try args.insert(p.arena, 0, flag_e);
                    e = try p.call(start, if (which == .object) "xq_pg_json_ctor_object" else "xq_pg_json_ctor_array", null, args.items);
                }
            },
            .arrayagg, .objectagg => {
                if (args.items.len == 0) return p.c.syntaxError();
                try args.append(p.arena, flag_e);
                var c: Call = .{ .name = .{ .text = if (which == .arrayagg) "xq_pg_json_arrayagg" else "xq_pg_json_objectagg", .pos = start }, .args = args.items, .order_by = order_by };
                c = try p.finishCall(c);
                const f = try p.new(tree.Func, .{ .name = c.name, .args = c.args, .order_by = c.order_by, .filter = c.filter, .over = c.over });
                e = try p.expr(start, .{ .func = f });
            },
        }
        e.end = p.c.lastEnd();
        try p.setFig(e, .{ .call = n });
        return e;
    }

    fn isCtorClause(p: *const Parser) bool {
        return ((p.c.isKw("null") or p.c.isKw("absent")) and p.c.isKwAt(1, "on")) or
            ((p.c.isKw("with") or p.c.isKw("without")) and p.c.isKwAt(1, "unique")) or p.c.isKw("returning");
    }

    /// `v [FORMAT JSON [ENCODING UTF8]]`: with FORMAT JSON the text is
    /// json.
    fn formatJson(p: *Parser, v: *Expr) Error!*Expr {
        if (!p.c.isKw("format")) return v;
        try p.formatClause();
        return p.castExpr(v.pos, v, .{ .name = "json", .pos = v.pos });
    }

    fn formatClause(p: *Parser) Error!void {
        if (!p.c.eatKw("format")) return;
        try p.c.expectKw("json");
        if (p.c.eatKw("encoding")) {
            const enc = try p.colId();
            if (!std.ascii.eqlIgnoreCase(enc.text, "utf8")) return p.c.failState(enc.pos, .of("0A000"), "unsupported JSON encoding", .{});
        }
    }

    /// `[AS] alias [(cols)]`.
    fn alias(p: *Parser, allow_cols: bool) Error!?tree.Alias {
        var name: Name = undefined;
        if (p.c.eatKw("as")) {
            name = try p.colId();
        } else {
            const a = p.c.peek();
            if (a.kind == .quoted_ident or (a.kind == .word and !a.isReserved() and !a.isKw("set"))) {
                p.c.skip();
                name = .{ .text = p.val(a), .pos = a.start };
            } else return null;
        }
        var al: tree.Alias = .{ .name = name };
        if (p.c.peek().kind == .lparen) {
            if (!allow_cols) return p.c.syntaxError();
            al.cols = try p.parenNameList();
        }
        return al;
    }

    // ======================================================= expressions

    pub fn exprList(p: *Parser) Error![]*Expr {
        return p.c.list(*Expr, p, expr0);
    }

    /// A full expression (a_expr).
    pub fn expr0(p: *Parser) Error!*Expr {
        return p.exprAbove(0);
    }

    /// An expression of the operators above BETWEEN/IN/LIKE (|| and the
    /// other operators, arithmetic, unary, postfix).
    fn otherExpr(p: *Parser) Error!*Expr {
        return p.exprAbove(lv.other);
    }

    /// A unary expression with its postfix operators and AT TIME ZONE.
    fn unary(p: *Parser) Error!*Expr {
        return p.exprAbove(lv.at);
    }

    // The precedence of the operators (sqlparse.pratt). The levels are
    // those of the chain of functions this parser had (orExpr → andExpr
    // → notExpr → ... → postfix), lowest first: OR, AND, NOT, IS (and
    // ISNULL, NOTNULL), comparison, BETWEEN/IN/LIKE/SIMILAR, the other
    // operators (||, ->, & ...), + -, * / %, ^ (left-associative),
    // unary + - ~, AT TIME ZONE/AT LOCAL, and ::/COLLATE/[...]/.field.
    //
    // What the chain did besides precedence, kept:
    //
    //  - after a form whose right side is not an expression of the next
    //    level (IS NULL, ISNULL, IN (...), = ANY (...), LIKE ANY (...)),
    //    only operators of its level or looser follow (caps): `a IN (1)
    //    + 1` ends at `+`;
    //  - NOT is an operator where a_expr starts (and after AND, OR, NOT);
    //    elsewhere (`x = NOT y`) its word is an operand (prefixAt);
    //  - an operand of AT TIME ZONE has no AT TIME ZONE of its own:
    //    `x AT TIME ZONE - z AT TIME ZONE w` is `(x AT TIME ZONE -z) AT
    //    TIME ZONE w` (unary minus reads above its loop's `min` there);
    //  - an operator that is not one of PostgreSQL's fails where the
    //    level of the other operators would read it (unmatched()).

    /// The levels (binding powers) of the operators.
    const lv = struct {
        const @"or": u8 = 10;
        const @"and": u8 = 20;
        const not: u8 = 30;
        const is: u8 = 40;
        const cmp: u8 = 50;
        const pred: u8 = 60;
        const other: u8 = 70;
        const add: u8 = 80;
        const mul: u8 = 90;
        const pow: u8 = 100;
        const at: u8 = 120;
        const postfix: u8 = 130;
    };

    pub const OpTag = enum {
        @"or",
        @"and",
        not,
        is,
        isnull,
        notnull,
        cmp,
        between,
        not_between,
        in,
        not_in,
        like,
        not_like,
        ilike,
        not_ilike,
        similar,
        not_similar,
        like_op,
        concat,
        bit_and,
        bit_or,
        bit_xor,
        shl,
        shr,
        json,
        regex,
        add,
        sub,
        mul,
        div,
        rem,
        pow,
        neg,
        plus,
        bit_not,
        at_time_zone,
        at_local,
        cast,
        collate,
        subscript,
        field,
    };

    const op_table = blk: {
        const P = sqlparse.pratt;
        const T = OpTag;
        var t: []const P.Op(T) = &.{
            P.left(T, .@"or", lv.@"or", .{ .kw = "or" }),
            P.left(T, .@"and", lv.@"and", .{ .kw = "and" }),
            P.prefixAt(T, .not, lv.not, lv.not, .{ .kw = "not" }),
            P.left(T, .is, lv.is, .{ .kw = "is" }),
            P.postfix(T, .isnull, lv.is, .{ .kw = "isnull", .cap = lv.is }),
            P.postfix(T, .notnull, lv.is, .{ .kw = "notnull", .cap = lv.is }),
        };
        for (cmp_ops) |o| t = t ++ &[_]P.Op(T){P.left(T, .cmp, lv.cmp, .{ .op = o[0] })};
        t = t ++ &[_]P.Op(T){
            P.left(T, .not_between, lv.pred, .{ .kw = "not", .then = "between" }),
            P.left(T, .not_in, lv.pred, .{ .kw = "not", .then = "in", .cap = lv.pred }),
            P.left(T, .not_like, lv.pred, .{ .kw = "not", .then = "like" }),
            P.left(T, .not_ilike, lv.pred, .{ .kw = "not", .then = "ilike" }),
            P.left(T, .not_similar, lv.pred, .{ .kw = "not", .seq = &.{ .{ .kw = "similar" }, .{ .kw = "to" } } }),
            P.left(T, .between, lv.pred, .{ .kw = "between" }),
            P.left(T, .in, lv.pred, .{ .kw = "in", .cap = lv.pred }),
            P.left(T, .like, lv.pred, .{ .kw = "like" }),
            P.left(T, .ilike, lv.pred, .{ .kw = "ilike" }),
            P.left(T, .similar, lv.pred, .{ .kw = "similar", .then = "to" }),
            P.left(T, .like_op, lv.pred, .{ .op = "~~" }),
            P.left(T, .like_op, lv.pred, .{ .op = "!~~" }),
            P.left(T, .like_op, lv.pred, .{ .op = "~~*" }),
            P.left(T, .like_op, lv.pred, .{ .op = "!~~*" }),
            P.left(T, .concat, lv.other, .{ .op = "||" }),
            P.left(T, .bit_and, lv.other, .{ .op = "&" }),
            P.left(T, .bit_or, lv.other, .{ .op = "|" }),
            P.left(T, .bit_xor, lv.other, .{ .op = "#" }),
            P.left(T, .shl, lv.other, .{ .op = "<<" }),
            P.left(T, .shr, lv.other, .{ .op = ">>" }),
        };
        for (json_operators) |o| t = t ++ &[_]P.Op(T){P.left(T, .json, lv.other, .{ .op = o[0] })};
        for (regex_operators) |o| t = t ++ &[_]P.Op(T){P.left(T, .regex, lv.other, .{ .op = o[0] })};
        t = t ++ &[_]P.Op(T){
            P.left(T, .add, lv.add, .{ .op = "+" }),
            P.left(T, .sub, lv.add, .{ .op = "-" }),
            P.left(T, .mul, lv.mul, .{ .op = "*" }),
            P.left(T, .div, lv.mul, .{ .op = "/" }),
            P.left(T, .rem, lv.mul, .{ .op = "%" }),
            P.left(T, .pow, lv.pow, .{ .op = "^" }),
            // The operand of a unary operator has its AT TIME ZONE.
            P.prefix(T, .neg, lv.at, .{ .op = "-" }),
            P.prefix(T, .plus, lv.at, .{ .op = "+" }),
            P.prefix(T, .bit_not, lv.at, .{ .op = "~" }),
            // Looser than ::, of whose loop they were: the zone has its
            // casts but no AT of its own.
            P.left(T, .at_time_zone, lv.at, .{ .kw = "at", .seq = &.{ .{ .kw = "time" }, .{ .kw = "zone" } } }),
            P.postfix(T, .at_local, lv.at, .{ .kw = "at", .then = "local" }),
            P.postfix(T, .cast, lv.postfix, .{ .op = "::" }),
            P.postfix(T, .collate, lv.postfix, .{ .kw = "collate" }),
            P.postfix(T, .subscript, lv.postfix, .{ .op = "[" }),
            P.postfix(T, .field, lv.postfix, .{ .kind = "dot", .seq = &.{.{ .kind = "word" }} }),
            P.postfix(T, .field, lv.postfix, .{ .kind = "dot", .seq = &.{.{ .kind = "quoted_ident" }} }),
        };
        break :blk t[0..t.len].*;
    };

    const Ops = sqlparse.pratt.Pratt(Parser, *Expr, OpTag, &op_table);

    /// An expression of the operators binding at least `min`.
    fn exprAbove(p: *Parser, min: u8) Error!*Expr {
        return Ops.expr(p, min);
    }

    pub fn operand(p: *Parser) Error!*Expr {
        return p.primary();
    }

    /// The loop ended at a token that is no operator of the table: an
    /// operator that is not PostgreSQL's fails where the level of the
    /// other operators would have read it.
    pub fn unmatched(p: *Parser, l: *Expr, min: u8, last: ?u8) Error!void {
        _ = l;
        if (min > lv.other or (last orelse 255) < lv.other) return;
        const t = p.c.peek();
        if (isOperator(p.c.sql, t) and p.otherOp(t) == null and p.cmpOp(t) == null and !isArith(p.val(t)) and !isLikeOp(p.val(t))) {
            return p.failFields(t.start, .of("42883"), .{ .message = try std.fmt.allocPrint(p.arena, "operator does not exist: {s}", .{p.val(t)}), .hint = @import("operators.zig").hint(.not_exist) });
        }
    }

    pub fn prefix(p: *Parser, tag: OpTag, m: Ops.Matched, rbp: u8) Error!*Expr {
        const op: tree.UnOp = switch (tag) {
            .not => .not,
            .neg => .neg,
            .plus => .plus,
            .bit_not => .bit_not,
            else => unreachable,
        };
        // In the zone of AT TIME ZONE (min above AT) the operand has none.
        const e = try p.exprAbove(if (tag == .not) rbp else @max(rbp, m.min));
        return p.expr(m.first.start, .{ .unary = .{ .op = op, .e = e } });
    }

    pub fn infix(p: *Parser, tag: OpTag, l: *Expr, m: Ops.Matched, rbp: u8) Error!*Expr {
        return switch (tag) {
            .@"or" => p.binary(.@"or", l, try p.exprAbove(rbp)),
            .@"and" => p.binary(.@"and", l, try p.exprAbove(rbp)),
            .is => p.isRest(l, rbp),
            .cmp => p.compare(l, m.first, rbp),
            .between, .not_between => {
                if (p.c.eatKw("symmetric")) return p.unsupported(m.last.start, "BETWEEN SYMMETRIC");
                _ = p.c.eatKw("asymmetric");
                const lo = try p.otherExpr();
                try p.c.expectKw("and");
                const hi = try p.otherExpr();
                return p.expr(l.pos, .{ .between = .{ .e = l, .not = tag == .not_between, .lo = lo, .hi = hi } });
            },
            .in, .not_in => {
                const not = tag == .not_in;
                _ = try p.c.expect(.lparen);
                if (p.startsSelect(0) or p.parenStartsSelect()) {
                    const s = try p.select();
                    _ = try p.c.expect(.rparen);
                    return p.expr(l.pos, .{ .in_select = .{ .e = l, .not = not, .sel = s } });
                }
                const items = try p.exprList();
                _ = try p.c.expect(.rparen);
                return p.expr(l.pos, .{ .in_list = .{ .e = l, .not = not, .items = items } });
            },
            .like => p.likeRest(l, false, false),
            .not_like => p.likeRest(l, true, false),
            .ilike => p.likeRest(l, false, true),
            .not_ilike => p.likeRest(l, true, true),
            .similar => p.similarRest(l, false),
            .not_similar => p.similarRest(l, true),
            .like_op => p.likeRest(l, p.val(m.first)[0] == '!', p.val(m.first)[p.val(m.first).len - 1] == '*'),
            .concat, .bit_and, .bit_or, .bit_xor, .shl, .shr, .json, .regex => {
                const r = try p.exprAbove(rbp);
                return switch (tag) {
                    .concat => p.span(l, r, .{ .concat = .{ .args = try p.list(&.{ l, r }), .null_policy = .propagate } }),
                    .bit_and => p.binary(.bit_and, l, r),
                    .bit_or => p.binary(.bit_or, l, r),
                    // No opcode: integer.zig's function, of the types
                    // overload.zig checks.
                    .bit_xor => p.span(l, r, .{ .func = try p.new(tree.Func, .{ .name = .{ .text = "xq_pg_int_xor", .pos = l.pos }, .args = try p.list(&.{ l, r }) }) }),
                    .shl => p.binary(.shl, l, r),
                    .shr => p.binary(.shr, l, r),
                    .json => p.jsonOp(p.val(m.first), l, r),
                    else => p.regexOp(regexOperator(p.val(m.first)).?, l, r),
                };
            },
            .add => p.binary(.add, l, try p.exprAbove(rbp)),
            .sub => p.binary(.sub, l, try p.exprAbove(rbp)),
            .mul => p.binary(.mul, l, try p.exprAbove(rbp)),
            .div => {
                const r = try p.exprAbove(rbp);
                return p.span(l, r, .{ .div = .{ .kind = .sqlite, .l = l, .r = r } });
            },
            .rem => p.binary(.rem, l, try p.exprAbove(rbp)),
            // a ^ b is power(a, b), PostgreSQL's (a real).
            .pow => {
                const r = try p.exprAbove(rbp);
                const f = try p.new(tree.Func, .{ .name = .{ .text = "power", .pos = l.pos }, .dialect = .postgres, .args = try p.list(&.{ l, r }) });
                return p.span(l, r, .{ .func = f });
            },
            // x AT TIME ZONE z: timezone(z, x) by its syntax's name
            // (dtfuncs.zig), a column named "timezone".
            .at_time_zone => {
                const z = try p.exprAbove(rbp);
                const x = try p.call(l.pos, "xq_pg_at_time_zone", null, &.{ z, l });
                try p.setFig(x, .{ .call = "timezone" });
                return x;
            },
            else => unreachable,
        };
    }

    pub fn postfix(p: *Parser, tag: OpTag, l: *Expr, m: Ops.Matched) Error!*Expr {
        return switch (tag) {
            .isnull => p.expr(l.pos, .{ .is_null = .{ .e = l, .not = false } }),
            .notnull => p.expr(l.pos, .{ .is_null = .{ .e = l, .not = true } }),
            .cast => p.castExpr(l.pos, l, try p.typeName()),
            .collate => {
                var name = try p.anyName();
                // pg_catalog."C", pg_catalog.default
                if (p.c.peek().kind == .dot and eql(name.text, "pg_catalog")) {
                    p.c.skip();
                    name = try p.anyName();
                }
                return p.expr(l.pos, .{ .collate = .{ .e = l, .collation = collationName(name.text) } });
            },
            .subscript => p.subscripts(l, m.first.start),
            .field => {
                // (r).field of a record (_pg_expandarray()'s x and n).
                const t = m.last;
                if (t.isReserved()) return p.c.syntaxErrorAt(t);
                const x = try p.call(l.pos, "xq_pg_record_field", null, &.{ l, try p.stringAt(t.start, p.val(t)) });
                x.end = p.c.lastEnd();
                try p.setFig(x, .{ .call = p.val(t) });
                return x;
            },
            // The session's zone, UTC.
            .at_local => p.call(l.pos, "timezone", .postgres, &.{ try p.stringAt(l.pos, "UTC"), l }),
            else => unreachable,
        };
    }

    /// `l IS [NOT] ...` after IS.
    fn isRest(p: *Parser, l: *Expr, rbp: u8) Error!*Expr {
        const not = p.c.eatKw("not");
        if (p.c.isAnyKw(&.{ "null", "true", "false", "unknown", "json" })) p.pratt.cap(lv.is);
        if (p.c.eatKw("null")) return p.expr(l.pos, .{ .is_null = .{ .e = l, .not = not } });
        if (p.c.eatKw("true")) return p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = true, .not = not } });
        if (p.c.eatKw("false")) return p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = false, .not = not } });
        if (p.c.eatKw("unknown")) return p.expr(l.pos, .{ .is_bool = .{ .e = l, .value = null, .not = not } });
        if (p.c.eatKw("json")) return p.isJson(l, not);
        if (try p.c.optKws(&.{ "distinct", "from" })) {
            const r = try p.exprAbove(rbp);
            // IS DISTINCT FROM is IS NOT, IS NOT DISTINCT FROM IS.
            return p.span(l, r, .{ .compare = .{ .op = if (not) .is else .is_not, .l = l, .r = r } });
        }
        return p.c.syntaxError();
    }

    const cmp_ops = [_]struct { []const u8, tree.CmpOp }{
        .{ "=", .eq }, .{ "<>", .ne }, .{ "!=", .ne }, .{ "<", .lt }, .{ "<=", .le }, .{ ">", .gt }, .{ ">=", .ge },
    };

    fn cmpOp(p: *const Parser, t: Token) ?tree.CmpOp {
        if (!isOperator(p.c.sql, t)) return null;
        for (cmp_ops) |m| if (std.mem.eql(u8, p.val(t), m[0])) return m[1];
        return null;
    }

    /// `l op r` after the comparison operator `tok`, or `l op ANY (...)`,
    /// `l = ANY (subquery)`.
    fn compare(p: *Parser, l: *Expr, tok: Token, rbp: u8) Error!*Expr {
        const op = p.cmpOp(tok).?;
        const at = tok.start;
        // x = ANY (subquery), x <> ALL (subquery)
        if (p.c.isAnyKw(&.{ "any", "some", "all" }) and p.c.peekAt(1).kind == .lparen) {
            const all = p.c.advance().isKw("all");
            if (!((op == .eq and !all) or (op == .ne and all)) or !p.parenStartsSelect()) {
                const aop: array.AnyOp = switch (op) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    else => return p.unsupported(at, "this ANY/ALL comparison"),
                };
                const e = try p.anyAll(l, aop, all);
                p.pratt.cap(lv.cmp);
                return e;
            }
            _ = try p.c.expect(.lparen);
            const s = try p.select();
            _ = try p.c.expect(.rparen);
            p.pratt.cap(lv.cmp);
            return p.expr(l.pos, .{ .in_select = .{ .e = l, .not = all, .sel = s } });
        }
        const r = try p.exprAbove(rbp);
        return p.span(l, r, .{ .compare = .{ .op = op, .l = l, .r = r } });
    }

    /// LIKE is case-sensitive, ILIKE folds ASCII letters; both escape
    /// with `\` without an ESCAPE clause.
    fn likeRest(p: *Parser, l: *Expr, not: bool, ilike: bool) Error!*Expr {
        if (p.c.isAnyKw(&.{ "any", "some", "all" }) and p.c.peekAt(1).kind == .lparen) {
            const all = p.c.advance().isKw("all");
            const op: array.AnyOp = if (ilike) (if (not) .not_ilike else .ilike) else if (not) .not_like else .like;
            const e = try p.anyAll(l, op, all);
            p.pratt.cap(lv.pred);
            return e;
        }
        const pat = try p.otherExpr();
        var esc: tree.Escape = .backslash;
        if (p.c.eatKw("escape")) esc = .{ .expr = try p.otherExpr() };
        return p.expr(l.pos, .{ .like = .{ .e = l, .pat = pat, .not = not, .case_sensitive = !ilike, .escape = esc } });
    }

    /// `l [NOT] SIMILAR TO pat [ESCAPE e]`: as PostgreSQL rewrites it,
    /// `l ~ similar_to_escape(pat [, e])` (xq_pg_re(l,
    /// xq_pg_similar_escape(pat [, e]), ''), regexp.zig).
    fn similarRest(p: *Parser, l: *Expr, not: bool) Error!*Expr {
        const pat = try p.otherExpr();
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(p.arena, pat);
        if (p.c.eatKw("escape")) try args.append(p.arena, try p.otherExpr());
        const re = try p.call(pat.pos, "xq_pg_similar_escape", null, args.items);
        return p.regexOp(.{ .fold = false, .negate = not }, l, re);
    }

    const OtherOp = enum { concat, bit_and, bit_or, bit_xor, shl, shr, json, regex };

    /// Operators of the "any other operator" level.
    fn otherOp(p: *const Parser, t: Token) ?OtherOp {
        if (!isOperator(p.c.sql, t)) return null;
        const map = [_]struct { []const u8, OtherOp }{
            .{ "||", .concat }, .{ "&", .bit_and }, .{ "|", .bit_or }, .{ "#", .bit_xor }, .{ "<<", .shl }, .{ ">>", .shr },
        };
        for (map) |m| if (std.mem.eql(u8, p.val(t), m[0])) return m[1];
        if (jsonOperator(p.val(t)) != null) return .json;
        if (regexOperator(p.val(t)) != null) return .regex;
        return null;
    }

    /// `l op r` of regular expression operator `op` (regexOperator()):
    /// xq_pg_re(l, r, flags) (regexp.zig), under NOT for `!~` and `!~*`.
    pub fn regexOp(p: *Parser, op: RegexOp, l: *Expr, r: *Expr) Error!*Expr {
        const flags = try p.expr(r.pos, .{ .string = if (op.fold) "i" else "" });
        const fun = try p.new(tree.Func, .{ .name = .{ .text = "xq_pg_re", .pos = l.pos }, .args = try p.list(&.{ l, r, flags }) });
        const x = try p.span(l, r, .{ .func = fun });
        if (!op.negate) return x;
        return p.span(l, r, .{ .unary = .{ .op = .not, .e = x } });
    }

    /// A json/jsonb operator: the engine function of its json variant
    /// (jtype.zig makes it jsonb's when the left operand is jsonb).
    fn jsonOp(p: *Parser, op: []const u8, l: *Expr, r: *Expr) Error!*Expr {
        const f = jsonOperator(op).?;
        const args = if (f.swap) try p.list(&.{ r, l }) else try p.list(&.{ l, r });
        const fun = try p.new(tree.Func, .{ .name = .{ .text = f.func, .pos = l.pos }, .args = args });
        return p.span(l, r, .{ .func = fun });
    }

    fn isArith(op: []const u8) bool {
        const ops = [_][]const u8{ "+", "-", "*", "/", "%", "^" };
        for (ops) |o| if (std.mem.eql(u8, o, op)) return true;
        return false;
    }

    fn isLikeOp(op: []const u8) bool {
        return std.mem.eql(u8, op, "~~") or std.mem.eql(u8, op, "!~~") or std.mem.eql(u8, op, "~~*") or std.mem.eql(u8, op, "!~~*");
    }

    fn binary(p: *Parser, op: tree.BinOp, l: *Expr, r: *Expr) Error!*Expr {
        return p.span(l, r, .{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    /// `e::ty` (and CAST, typed literals) as types.castPlan() says;
    /// '\x0102'::bytea is a blob constant.
    fn castExpr(p: *Parser, pos: u32, e_arg: *Expr, ty: types.TypeName) Error!*Expr {
        var x: *Expr = undefined;
        var e = e_arg;
        // A reg* value (an OID) cast to text is its name.
        if (!ty.array and (eql(ty.name, "text") or eql(ty.name, "name") or eql(ty.name, "character varying") or eql(ty.name, "character"))) {
            if (regOutputOf(e)) |f| {
                const strong = p.strongName(e);
                e = try p.call(e.pos, f, null, &.{e});
                if (strong) |n| try p.setFig(e, .{ .call = n });
            }
        }
        if (std.mem.eql(u8, ty.name, "bytea") and !ty.array and e.kind == .string and std.mem.startsWith(u8, e.kind.string, "\\x")) {
            const hex = e.kind.string[2..];
            for (hex) |ch| if (!std.ascii.isHex(ch)) return p.c.failState(pos, .of("22023"), "invalid hexadecimal digit: \"{c}\"", .{ch});
            if (hex.len % 2 != 0) return p.c.failState(pos, .of("22023"), "invalid hexadecimal data: odd number of digits", .{});
            x = try p.expr(pos, .{ .blob = hex });
        } else if (ty.array) {
            // An array's text, read as its elements' type reads them
            // (array.zig): `'{1, 01}'::int[]` is `{1,1}`.
            if (!types.arrayElement(ty)) return p.typeError(ty, error.UnknownType);
            const name = try types.format(p.arena, ty);
            const t = ctypes.parse(.postgres, name);
            x = try p.expr(pos, .{ .cast = .{ .e = e, .target_type = name, .mode = .{ .func = array.inputName(t.element) } } });
        } else {
            const plan = types.castPlan(ty) catch |err| return p.typeError(ty, err);
            const mode: tree.CastMode = switch (plan) {
                .sqlite => |t| .{ .affinity = t },
                .func => |f| .{ .func = f },
                .truncate => |n| .{ .truncate = n },
                .round => |s| .{ .round = s },
                .numeric => |m| .{ .func_args = .{ .func = "xq_dec", .args = try p.arena.dupe(i64, &m) } },
                .interval => |m| .{ .func_args = .{ .func = "xq_pg_iv_in", .args = try p.ivInArgs(m) } },
            };
            // numeric(p, s) is of its precision and scale, character(n) of
            // its length (shown padded to it).
            const target_type = if (plan == .numeric or plan == .truncate) try types.format(p.arena, ty) else ty.name;
            x = try p.expr(pos, .{ .cast = .{ .e = e, .target_type = target_type, .mode = mode } });
        }
        try p.setFig(x, .{ .cast = .{ .strong = p.strongName(e), .type_name = ty.name } });
        return x;
    }

    /// `[v, ...]` of ARRAY[...]: xq_pg_array(v, ...), `[[1,2],[3,4]]` of
    /// xq_pg_array()s (overload.zig makes an array of arrays
    /// xq_pg_array_nested(), and gives the values of a type their text).
    fn arrayCtor(p: *Parser, pos: u32) Error!*Expr {
        try p.c.expectOp("[");
        var items: std.ArrayList(*Expr) = .empty;
        if (!p.c.isOp("]")) {
            if (p.c.isOp("[")) {
                while (true) {
                    try items.append(p.arena, try p.arrayCtor(p.c.peek().start));
                    if (!p.c.eat(.comma)) break;
                }
            } else try items.appendSlice(p.arena, try p.exprList());
        }
        try p.c.expectOp("]");
        return p.call(pos, "xq_pg_array", null, items.items);
    }

    /// (SELECT f(xq_v) FROM (q) AS xq_q(xq_v)): an aggregate of the one
    /// column of query `q`, in its order.
    fn aggregateOf(p: *Parser, pos: u32, f: []const u8, q: *tree.Select) Error!*Expr {
        const names = try p.arena.alloc(Name, 1);
        names[0] = .{ .text = "xq_v", .pos = pos };
        const col = try p.expr(pos, .{ .column = names });
        const v = try p.call(pos, f, null, &.{col});
        var from = try p.arena.alloc(tree.FromItem, 1);
        from[0] = .{ .source = .{ .subquery = q }, .alias = .{ .name = .{ .text = "xq_q", .pos = pos }, .cols = names } };
        const rcs = try p.arena.alloc(tree.ResultCol, 1);
        rcs[0] = .{ .expr = .{ .e = v } };
        const core_ = try p.new(tree.Core, .{ .cols = rcs, .from = from, .pos = pos });
        const sel = try p.new(tree.Select, .{ .body = try p.new(tree.Body, .{ .core = core_ }), .pos = pos });
        return p.expr(pos, .{ .subquery = sel });
    }

    /// `l op ANY (a)` / ALL after the keyword: (a) an array, or a query
    /// (ARRAY(query)): xq_pg_any(l, a, op, all).
    fn anyAll(p: *Parser, l: *Expr, op: array.AnyOp, all: bool) Error!*Expr {
        const at = p.c.peek().start;
        _ = try p.c.expect(.lparen);
        var a: *Expr = undefined;
        if (p.startsSelect(0)) {
            const q = try p.select();
            a = try p.call(at, "coalesce", null, &.{ try p.aggregateOf(at, "xq_pg_array_agg", q), try p.stringAt(at, "{}") });
        } else a = try p.expr0();
        _ = try p.c.expect(.rparen);
        const ope = try p.expr(at, .{ .integer = try std.fmt.allocPrint(p.arena, "{d}", .{@backingInt(op)}) });
        const alle = try p.expr(at, .{ .integer = if (all) "1" else "0" });
        const f = try p.new(tree.Func, .{ .name = .{ .text = "xq_pg_any", .pos = l.pos }, .args = try p.list(&.{ l, a, ope, alle }) });
        const e = try p.expr(l.pos, .{ .func = f });
        e.end = p.c.lastEnd();
        return e;
    }

    /// `e[i][j]` (xq_pg_subscript(e, i, j)) or with a slice `e[lo:hi]`
    /// (xq_pg_slice(e, lo, hi, ...), an omitted bound NULL, a plain
    /// subscript i as 1:i): named as `e`.
    fn subscripts(p: *Parser, base: *Expr, first: u32) Error!*Expr {
        var bounds: std.ArrayList([2]?*Expr) = .empty;
        var slice = false;
        var at = first;
        while (true) {
            var lo: ?*Expr = null;
            var hi: ?*Expr = null;
            if (!p.c.isOp(":")) lo = try p.expr0();
            if (p.c.eatOp(":")) {
                slice = true;
                if (!p.c.isOp("]")) hi = try p.expr0();
                if (lo == null) lo = try p.expr(at, .null);
                if (hi == null) hi = try p.expr(at, .null);
            } else {
                hi = lo;
                lo = null;
            }
            try p.c.expectOp("]");
            try bounds.append(p.arena, .{ lo, hi });
            if (!p.c.isOp("[")) break;
            at = p.c.advance().start;
        }
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(p.arena, base);
        for (bounds.items) |b| {
            if (slice) {
                try args.append(p.arena, b[0] orelse try p.expr(base.pos, .{ .integer = "1" }));
                try args.append(p.arena, b[1].?);
            } else try args.append(p.arena, b[1].?);
        }
        const f = try p.new(tree.Func, .{ .name = .{ .text = if (slice) "xq_pg_slice" else "xq_pg_subscript", .pos = base.pos }, .args = args.items });
        const e = try p.expr(base.pos, .{ .func = f });
        e.end = p.c.lastEnd();
        try p.setFig(e, .{ .call = p.strongName(base) orelse p.columnName(base) orelse "?column?" });
        return e;
    }

    /// The output function of `e` if it is a cast to a reg* type of
    /// OIDs (types.regOutput()).
    fn regOutputOf(e: *const Expr) ?[:0]const u8 {
        return switch (e.kind) {
            .cast => |c| types.regOutput(c.target_type),
            else => null,
        };
    }

    /// The result columns of the statement's query that are reg* casts
    /// show the object's name, as PostgreSQL prints a regclass; inside
    /// the query they stay OIDs (to compare with oid columns).
    pub fn regOutputs(p: *Parser, st: tree.Stmt) Error!void {
        switch (st) {
            .select => |s| try p.regBody(s.body),
            else => {},
        }
    }

    fn regBody(p: *Parser, b: *tree.Body) Error!void {
        switch (b.*) {
            .core => |c| for (c.cols) |*col| switch (col.*) {
                .expr => |*x| if (regOutputOf(x.e)) |f| {
                    x.e = try p.call(x.e.pos, f, null, &.{x.e});
                },
                else => {},
            },
            .compound => |c| {
                try p.regBody(c.left);
                try p.regBody(c.right);
            },
            .nested => |s| try p.regBody(s.body),
            .values => {},
        }
    }

    pub fn typeError(p: *Parser, ty: types.TypeName, err: types.Error) Error {
        return switch (err) {
            error.Array => p.c.failState(ty.pos, .of("0A000"), "array of {s} is not implemented", .{ty.name}),
            error.UnknownType => p.c.failState(ty.pos, .of("42704"), "type \"{s}{s}\" does not exist", .{ ty.name, if (ty.array) "[]" else "" }),
        };
    }

    fn primary(p: *Parser) Error!*Expr {
        const t = p.c.peek();
        switch (t.kind) {
            .integer => {
                p.c.skip();
                return p.expr(t.start, .{ .integer = p.val(t) });
            },
            .float => {
                p.c.skip();
                return p.expr(t.start, .{ .float = p.val(t) });
            },
            .string => {
                p.c.skip();
                return p.expr(t.start, .{ .string = p.val(t) });
            },
            .param => {
                p.c.skip();
                const n = std.fmt.parseInt(u32, p.val(t), 10) catch return p.c.failState(t.start, .of("42P02"), "there is no parameter ${s}", .{p.val(t)});
                if (n == 0) return p.c.failState(t.start, .of("42P02"), "there is no parameter $0", .{});
                return p.expr(t.start, .{ .param = n });
            },
            .lparen => return p.parenExpr(),
            .quoted_ident => return p.nameExpr(),
            .word => {},
            else => return p.c.syntaxError(),
        }
        const w = p.val(t);
        if (eql(w, "null")) return p.keywordExpr(.null);
        if (eql(w, "true")) return p.keywordExpr(.{ .boolean = true });
        if (eql(w, "false")) return p.keywordExpr(.{ .boolean = false });
        if (eql(w, "default")) return p.keywordExpr(.default);
        if (eql(w, "case")) return p.caseExpr();
        if (eql(w, "cast")) {
            p.c.skip();
            _ = try p.c.expect(.lparen);
            const e = try p.expr0();
            try p.c.expectKw("as");
            const ty = try p.typeName();
            _ = try p.c.expect(.rparen);
            return p.castExpr(t.start, e, ty);
        }
        if (eql(w, "exists")) {
            p.c.skip();
            _ = try p.c.expect(.lparen);
            const s = try p.select();
            _ = try p.c.expect(.rparen);
            return p.expr(t.start, .{ .exists = s });
        }
        if (eql(w, "array")) {
            if (p.c.peekAt(1).kind == .lparen and p.startsSelect(2)) {
                // ARRAY(query): coalesce((SELECT xq_pg_array_agg(v) FROM
                // (query) AS q(v)), '{}'), in the query's order.
                p.c.skip();
                p.c.skip();
                const q = try p.select();
                _ = try p.c.expect(.rparen);
                const agg = try p.aggregateOf(t.start, "xq_pg_array_agg", q);
                const e = try p.call(t.start, "coalesce", null, &.{ agg, try p.stringAt(t.start, "{}") });
                try p.setFig(e, .{ .call = "array" });
                return e;
            }
            if (!p.c.isOpTok(p.c.peekAt(1), "[")) return p.unsupported(t.start, "ARRAY");
            p.c.skip();
            const e = try p.arrayCtor(t.start);
            if (e.kind.func.args.len == 0 and !p.c.isOp("::") and !p.c.isKw("as")) {
                return p.failFields(t.start, .of("42P18"), .{ .message = "cannot determine type of empty array", .hint = "Explicitly cast to the desired type, for example ARRAY[]::integer[]." });
            }
            try p.setFig(e, .{ .call = "array" });
            return e;
        }
        if (eql(w, "row") and p.c.peekAt(1).kind == .lparen) {
            p.c.skip();
            p.c.skip();
            const items: []*Expr = if (p.c.peek().kind == .rparen) &.{} else try p.exprList();
            _ = try p.c.expect(.rparen);
            return p.expr(t.start, .{ .row = items });
        }
        if (eql(w, "current_date") or eql(w, "current_time") or eql(w, "current_timestamp") or
            eql(w, "localtime") or eql(w, "localtimestamp") or eql(w, "current_user") or eql(w, "session_user") or
            eql(w, "user") or eql(w, "current_role") or eql(w, "current_catalog") or eql(w, "current_schema"))
        {
            p.c.skip();
            // CURRENT_TIMESTAMP(3): the precision is ignored.
            if ((eql(w, "current_time") or eql(w, "current_timestamp") or eql(w, "localtime") or eql(w, "localtimestamp")) and p.c.peek().kind == .lparen) {
                p.c.skip();
                _ = try p.c.expect(.integer);
                _ = try p.c.expect(.rparen);
            } else if (eql(w, "current_schema") and p.c.peek().kind == .lparen and p.c.peekAt(1).kind == .rparen) {
                p.c.skip();
                p.c.skip();
            }
            return p.callExpr(t.start, .{ .name = .{ .text = if (eql(w, "user")) "current_user" else w, .pos = t.start } });
        }
        // A typed literal: DATE '2024-01-01', INTERVAL '1 day' ...
        if (isTypeWord(w)) {
            const save = p.c.mark();
            if (p.typeName()) |ty_arg| {
                var ty = ty_arg;
                const s = p.c.peek();
                if (s.kind == .string) {
                    p.c.skip();
                    // INTERVAL '1' YEAR TO MONTH: the fields after the string.
                    if (eql(ty.name, "interval") and ty.mods.len == 0 and ty.fields.len == 0 and !ty.array) try p.intervalFields(&ty);
                    const lit = try p.expr(s.start, .{ .string = p.val(s) });
                    return p.castExpr(t.start, lit, ty);
                }
            } else |err| if (err == error.OutOfMemory) return err;
            p.c.reset(save);
        }
        if (isReserved(w) and !(p.c.peekAt(1).kind == .lparen and isFuncNameKeyword(w))) return p.c.syntaxError();
        return p.nameExpr();
    }

    fn keywordExpr(p: *Parser, kind: tree.Kind) Error!*Expr {
        const t = p.c.advance();
        return p.expr(t.start, kind);
    }

    /// A column reference or a function call.
    fn nameExpr(p: *Parser) Error!*Expr {
        const start = p.c.peek().start;
        var names: std.ArrayList(Name) = .empty;
        const first = p.c.advance();
        try names.append(p.arena, .{ .text = p.val(first), .pos = first.start });
        while (p.c.peek().kind == .dot) {
            p.c.skip();
            try names.append(p.arena, try p.anyName());
        }
        if (p.c.peek().kind == .lparen) {
            const n = names.items;
            if (n.len > 2) return p.c.syntaxError();
            if (n.len == 1) if (try p.jsonCtor(start, n[0])) |e| return e;
            const c = try p.funcCall(n[n.len - 1], if (n.len == 2) n[0] else null);
            return p.callExpr(start, c);
        }
        if (names.items.len > 3) return p.c.failState(start, .of("42601"), "improper qualified name (too many dotted names)", .{});
        if (names.items.len == 3) {
            // schema.table.column: a table of a schema of CREATE SCHEMA
            // has its bare name as alias, as has a catalog view.
            if (eql(names.items[0].text, "pg_catalog") or eql(names.items[0].text, "information_schema")) {
                return p.expr(start, .{ .column = names.items[1..] });
            }
            const t = try p.qualified(names.items[0], names.items[1]);
            if (t.mangled) return p.expr(start, .{ .column = names.items[1..] });
            names.items[0] = .{ .text = t.db, .pos = names.items[0].pos };
        }
        return p.expr(start, .{ .column = names.items });
    }

    fn parenExpr(p: *Parser) Error!*Expr {
        const start = p.c.peek().start;
        if (p.parenStartsSelect()) {
            const save = p.c.mark();
            p.c.skip();
            if (p.select()) |s| {
                if (p.c.eat(.rparen)) return p.expr(start, .{ .subquery = s });
            } else |err| if (p.keepsError(err)) return err;
            p.c.reset(save);
        }
        p.c.skip();
        const e = try p.expr0();
        if (p.c.peek().kind == .comma) {
            var items: std.ArrayList(*Expr) = .empty;
            try items.append(p.arena, e);
            while (p.c.eat(.comma)) try items.append(p.arena, try p.expr0());
            _ = try p.c.expect(.rparen);
            return p.expr(start, .{ .row = items.items });
        }
        _ = try p.c.expect(.rparen);
        // Keep the parentheses in the span (for the name of a column).
        e.pos = start;
        e.end = p.c.lastEnd();
        return e;
    }

    fn caseExpr(p: *Parser) Error!*Expr {
        return syntax.caseExpr(p, expr0);
    }

    // ========================================================= functions

    /// The call after its name: arguments, FILTER, OVER. The special
    /// syntax of substring/position/trim/extract/overlay is read here.
    fn funcCall(p: *Parser, name: Name, schema: ?Name) Error!Call {
        if (schema) |s| if (!eql(s.text, "pg_catalog") and !eql(s.text, "public") and !(eql(s.text, "information_schema") and eql(name.text, "_pg_expandarray"))) {
            return p.c.failState(s.pos, .of("3F000"), "schema \"{s}\" does not exist", .{s.text});
        };
        _ = try p.c.expect(.lparen);
        var f: Call = .{ .name = name };
        const n = name.text;
        if (eql(n, "substring") or eql(n, "position") or eql(n, "extract")) f.label = n;
        if (eql(n, "substring") or eql(n, "position") or eql(n, "trim") or eql(n, "extract") or eql(n, "overlay")) {
            if (try p.specialCall(&f)) return p.finishCall(f);
        }
        if (p.c.isOp("*")) {
            p.c.skip();
            f.star = true;
        } else if (p.c.peek().kind != .rparen) {
            if (p.c.eatKw("distinct")) f.distinct = true else _ = p.c.eatKw("all");
            try p.callArgs(&f);
            if (try p.c.optKws(&.{ "order", "by" })) {
                f.order_by = try p.sortList();
            }
        } else try p.placeArgs(&f, &.{}, false);
        _ = try p.c.expect(.rparen);
        return p.finishCall(f);
    }

    /// The arguments of a call: positional ones, then named ones (`name
    /// := v`, `name => v`) put in the places of the parameters of the
    /// built-in function (namedParams(), its defaults for those not
    /// given); a last `VARIADIC array` (variadicCall()).
    fn callArgs(p: *Parser, f: *Call) Error!void {
        var args: std.ArrayList(*Expr) = .empty;
        var names: std.ArrayList(?Name) = .empty;
        var named = false;
        var variadic: ?u32 = null;
        while (true) {
            const t = p.c.peek();
            if (variadic != null) return p.c.syntaxError();
            if (t.isKw("variadic")) {
                p.c.skip();
                variadic = p.c.peek().start;
            }
            if ((t.kind == .word or t.kind == .quoted_ident) and (p.c.isOpTok(p.c.peekAt(1), ":=") or p.c.isOpTok(p.c.peekAt(1), "=>"))) {
                p.c.skip();
                p.c.skip();
                for (names.items) |n| if (n) |x| if (eql(x.text, p.val(t)))
                    return p.c.failState(t.start, .of("42601"), "argument name \"{s}\" used more than once", .{p.val(t)});
                try names.append(p.arena, .{ .text = p.val(t), .pos = t.start });
                named = true;
            } else {
                if (named) return p.c.failState(t.start, .of("42601"), "positional argument cannot follow named argument", .{});
                try names.append(p.arena, null);
            }
            try args.append(p.arena, try p.expr0());
            if (!p.c.eat(.comma)) break;
        }
        f.args = args.items;
        if (variadic) |pos| return p.variadicCall(f, pos);
        return p.placeArgs(f, names.items, named);
    }

    /// The arguments of `f` (named as `names` says) in the places of the
    /// parameters of its function (namedParams()).
    fn placeArgs(p: *Parser, f: *Call, names: []const ?Name, named: bool) Error!void {
        const params = namedParams(f.name.text) orelse {
            if (named) return p.noFunction(f.name, f.args, names);
            return;
        };
        if (!named and params.defaults == 0) return;
        // The arguments by the parameters' places.
        const out = try p.arena.alloc(?*Expr, params.names.len);
        @memset(out, null);
        for (f.args, names, 0..) |a, n, i| {
            const at = if (n) |x| for (params.names, 0..) |pn, k| {
                if (eql(pn, x.text)) break k;
            } else null else if (i < out.len) i else null;
            const k = at orelse return p.noFunction(f.name, f.args, names);
            out[k] = a;
        }
        var placed: std.ArrayList(*Expr) = .empty;
        for (out, 0..) |a, k| {
            if (a) |x| {
                try placed.append(p.arena, x);
                continue;
            }
            // A parameter not given: its default, if it has one.
            if (k < params.names.len - params.defaults) return p.noFunction(f.name, f.args, names);
            try placed.append(p.arena, try p.expr(f.name.pos, .{ .integer = "0" }));
        }
        f.args = placed.items;
    }

    /// "function f(a => integer, ...) does not exist", the arguments'
    /// types as their literals tell (argTypeName()).
    fn noFunction(p: *Parser, name: Name, args: []const *Expr, names: []const ?Name) Error {
        const shown = try p.arena.alloc([]const u8, args.len);
        for (args, shown, 0..) |a, *s, i| {
            const t = try p.argTypeName(a);
            const n: ?Name = if (i < names.len) names[i] else null;
            s.* = if (n) |nm| try std.fmt.allocPrint(p.arena, "{s} => {s}", .{ nm.text, t }) else t;
        }
        return p.failFields(name.pos, .of("42883"), try @import("frontend.zig").functionNotExist(p.arena, name.text, shown));
    }

    /// The type of argument `e` as far as the parser knows it: of a
    /// literal, a cast, an ARRAY[...] of literals; "unknown" for a string
    /// or another expression.
    fn argTypeName(p: *Parser, e: *const Expr) Error![]const u8 {
        return switch (e.kind) {
            .integer => "integer",
            .float => "numeric",
            .boolean => "boolean",
            .cast => |c| c.target_type,
            .func => |f| if (eql(f.name.text, "xq_pg_array") and f.args.len > 0)
                try std.mem.concat(p.arena, u8, &.{ if (f.args[0].kind == .string) "text" else try p.argTypeName(f.args[0]), "[]" })
            else
                "unknown",
            else => "unknown",
        };
    }

    /// f(..., VARIADIC a): concat() and concat_ws() of the elements of
    /// array a (array_to_string(), NULL for a NULL array); format() and
    /// the JSON builders of the elements of an ARRAY[...] as the
    /// arguments themselves.
    fn variadicCall(p: *Parser, f: *Call, pos: u32) Error!void {
        const n = f.name.text;
        const fixed: usize = if (eql(n, "concat") or eql(n, "json_build_array") or eql(n, "json_build_object") or
            eql(n, "jsonb_build_array") or eql(n, "jsonb_build_object"))
            0
        else if (eql(n, "concat_ws") or eql(n, "format"))
            1
        else
            return p.noFunction(f.name, f.args, &.{});
        if (f.args.len != fixed + 1) return p.noFunction(f.name, f.args, &.{});
        const a = f.args[fixed];
        // Not an array.
        switch (a.kind) {
            .integer, .float, .boolean, .string => return p.c.failState(pos, .of("42804"), "VARIADIC argument must be an array", .{}),
            .cast => |c| if (!std.mem.endsWith(u8, c.target_type, "[]")) return p.c.failState(pos, .of("42804"), "VARIADIC argument must be an array", .{}),
            else => {},
        }
        if (eql(n, "concat") or eql(n, "concat_ws")) {
            f.label = n;
            const sep = if (fixed == 1) f.args[0] else try p.stringAt(pos, "");
            f.name = .{ .text = "array_to_string", .pos = f.name.pos };
            f.args = try p.list(&.{ a, sep });
            return;
        }
        // The elements of ARRAY[...] (cast: each element cast).
        var arr = a;
        var elem_type: ?types.TypeName = null;
        if (arr.kind == .cast and arr.kind.cast.e.kind == .func) {
            const tn = arr.kind.cast.target_type;
            elem_type = .{ .name = tn[0 .. tn.len - 2], .pos = arr.pos };
            arr = arr.kind.cast.e;
        }
        if (arr.kind == .func and eql(arr.kind.func.name.text, "xq_pg_array")) {
            var placed: std.ArrayList(*Expr) = .empty;
            try placed.appendSlice(p.arena, f.args[0..fixed]);
            for (arr.kind.func.args) |x| try placed.append(p.arena, if (elem_type) |ty| try p.castExpr(x.pos, x, ty) else x);
            f.args = placed.items;
            return;
        }
        // VARIADIC NULL: no arguments.
        if (arr.kind == .null or (arr.kind == .cast and arr.kind.cast.e.kind == .null)) {
            f.args = f.args[0..fixed];
            return;
        }
        return p.unsupported(pos, "VARIADIC of this argument");
    }

    fn finishCall(p: *Parser, f_arg: Call) Error!Call {
        var f = f_arg;
        if (p.c.isKw("within") and p.c.isKwAt(1, "group")) return p.unsupported(p.c.peek().start, "WITHIN GROUP");
        if (p.c.isKw("filter") and p.c.peekAt(1).kind == .lparen) {
            p.c.skip();
            p.c.skip();
            try p.c.expectKw("where");
            f.filter = try p.expr0();
            _ = try p.c.expect(.rparen);
        }
        if (p.c.eatKw("over")) {
            if (p.c.peek().kind == .lparen) {
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
        const save = p.c.mark();
        var args: std.ArrayList(*Expr) = .empty;
        if (eql(n, "extract")) {
            const t = p.c.peek();
            const field: []const u8 = switch (t.kind) {
                .word, .quoted_ident, .string => p.val(t),
                else => return p.c.syntaxError(),
            };
            p.c.skip();
            try p.c.expectKw("from");
            try args.append(p.arena, try p.expr(t.start, .{ .string = field }));
            try args.append(p.arena, try p.expr0());
            _ = try p.c.expect(.rparen);
            f.name.text = "date_part";
            f.args = args.items;
            return true;
        }
        if (eql(n, "trim")) {
            var kind: []const u8 = "btrim";
            if (p.c.eatKw("both")) {} else if (p.c.eatKw("leading")) {
                kind = "ltrim";
            } else if (p.c.eatKw("trailing")) {
                kind = "rtrim";
            }
            var chars: ?*Expr = null;
            var subject: *Expr = undefined;
            if (p.c.eatKw("from")) {
                subject = try p.expr0();
            } else {
                const first = try p.expr0();
                if (p.c.eatKw("from")) {
                    chars = first;
                    subject = try p.expr0();
                } else if (p.c.eat(.comma)) {
                    subject = first;
                    chars = try p.expr0();
                } else {
                    subject = first;
                }
            }
            _ = try p.c.expect(.rparen);
            try args.append(p.arena, subject);
            if (chars) |c| try args.append(p.arena, c);
            f.name.text = kind;
            f.args = args.items;
            return true;
        }
        if (eql(n, "position")) {
            const a = try p.otherExpr();
            if (!p.c.eatKw("in")) {
                p.c.reset(save);
                return false;
            }
            const b = try p.otherExpr();
            _ = try p.c.expect(.rparen);
            try args.append(p.arena, b);
            try args.append(p.arena, a);
            f.name.text = "strpos";
            f.args = args.items;
            return true;
        }
        if (eql(n, "substring")) {
            const x = try p.expr0();
            if (p.c.peek().kind == .comma or p.c.peek().kind == .rparen) {
                p.c.reset(save);
                return false;
            }
            try args.append(p.arena, x);
            var similar = false;
            if (p.c.eatKw("from")) {
                try args.append(p.arena, try p.expr0());
                if (p.c.eatKw("for")) try args.append(p.arena, try p.expr0());
            } else if (p.c.eatKw("for")) {
                try args.append(p.arena, try p.expr(x.pos, .{ .integer = "1" }));
                try args.append(p.arena, try p.expr0());
            } else if (p.c.eatKw("similar")) {
                try args.append(p.arena, try p.expr0());
                try p.c.expectKw("escape");
                try args.append(p.arena, try p.expr0());
                similar = true;
            } else return p.c.syntaxError();
            _ = try p.c.expect(.rparen);
            f.name.text = substringName(args.items, similar);
            f.args = args.items;
            return true;
        }
        if (eql(n, "overlay")) {
            return p.unsupported(f.name.pos, "OVERLAY");
        }
        return false;
    }

    /// The function substring(args) is (`similar`: SUBSTRING(x SIMILAR
    /// pattern ESCAPE e)), as PostgreSQL's substring(text, text) and
    /// substring(text, text, text) are chosen for string constants: of a
    /// pattern or a SIMILAR pattern and its escape textregexsubstr()
    /// (regexp.zig); otherwise SQLite's substr().
    fn substringName(args: []const *Expr, similar: bool) []const u8 {
        const pattern = switch (args.len) {
            2 => args[1].kind == .string,
            3 => args[1].kind == .string and args[2].kind == .string,
            else => false,
        };
        return if (similar or pattern) "textregexsubstr" else "substr";
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
                    if (c.args.len != 0) return p.c.failState(c.name.pos, .of("42883"), "function {s} does not exist", .{n});
                    const x = try p.now(pos);
                    if (eql(n, "localtimestamp")) x.kind.func.result_type = "timestamp without time zone";
                    break :blk x;
                },
                .localtime => blk: {
                    const x = try p.call(pos, "current_time", null, &.{});
                    x.kind.func.result_type = "time without time zone";
                    break :blk x;
                },
                .current_user => try p.call(pos, "current_user", .postgres, &.{}),
                .current_database => try p.call(pos, "current_database", .postgres, &.{}),
                .date_part => try p.datePart(pos, c),
            };
        } else {
            const mapped = if (eql(n, "substring") and plain and (c.args.len == 2 or c.args.len == 3)) substringName(c.args, false) else funcName(n);
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
    /// Of type timestamptz (Func.result_type).
    fn now(p: *Parser, pos: u32) Error!*Expr {
        const e = try p.call(pos, "strftime", null, &.{ try p.stringAt(pos, "%Y-%m-%d %H:%M:%f"), try p.stringAt(pos, "now") });
        e.kind.func.result_type = "timestamp with time zone";
        return e;
    }

    /// date_part('field', x) (and EXTRACT(field FROM x)) with strftime().
    fn datePart(p: *Parser, pos: u32, c: Call) Error!*Expr {
        if (c.args.len != 2 or c.args[0].kind != .string) return p.c.failState(c.name.pos, .of("0A000"), "function date_part with these arguments is not supported", .{});
        // Of an interval or of a timestamp, as the type of x chooses
        // (repr/interval.zig): xq_pg_part(field, x, the timestamp's part
        // or NULL, whether EXTRACT).
        const t = try p.timestampPart(pos, c) orelse try p.expr(pos, .null);
        return p.call(pos, "xq_pg_part", .postgres, &.{ c.args[0], c.args[1], t, try p.expr(pos, .{ .integer = if (c.label != null) "1" else "0" }) });
    }

    fn timestampPart(p: *Parser, pos: u32, c: Call) Error!?*Expr {
        const plan = datePartPlan(c.args[0].kind.string) orelse return null;
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
        _ = try p.c.expect(.lparen);
        var w: tree.WindowSpec = .{};
        const t = p.c.peek();
        if ((t.kind == .word and !t.isReserved() and !t.isKw("partition") and !t.isKw("rows") and !t.isKw("range") and !t.isKw("groups")) or t.kind == .quoted_ident) {
            w.base = try p.colId();
        }
        try syntax.windowClauses(p, &w, expr0, .{ .groups = true });
        _ = try p.c.expect(.rparen);
        return p.new(tree.WindowSpec, w);
    }

    // ============================================================= types

    /// numeric(p [, s]): PostgreSQL's bounds.
    fn numericTypmod(p: *Parser, pos: u32, mods: []const i64) Error!void {
        if (mods.len > 2) return p.c.failState(pos, .of("22023"), "invalid NUMERIC type modifier", .{});
        if (mods[0] < 1 or mods[0] > 1000) return p.c.failState(pos, .of("22023"), "NUMERIC precision {d} must be between 1 and 1000", .{mods[0]});
        if (mods.len == 2 and (mods[1] < -1000 or mods[1] > 1000)) return p.c.failState(pos, .of("22023"), "NUMERIC scale {d} must be between -1000 and 1000", .{mods[1]});
    }

    /// The fields of an interval type or literal (PostgreSQL's
    /// opt_interval): YEAR, ..., SECOND[(p)], YEAR TO MONTH, DAY TO HOUR,
    /// DAY TO MINUTE, DAY TO SECOND[(p)], HOUR TO MINUTE, HOUR TO
    /// SECOND[(p)], MINUTE TO SECOND[(p)]: ty.fields, the precision
    /// ty.mods.
    fn intervalFields(p: *Parser, ty: *types.TypeName) Error!void {
        const iv_words = [_][]const u8{ "year", "month", "day", "hour", "minute", "second" };
        const first = p.c.peek();
        const a = for (iv_words) |w| {
            if (first.kind == .word and eql(p.val(first), w)) break w;
        } else return;
        p.c.skip();
        var b: []const u8 = "";
        if (p.c.isKw("to")) {
            const to = p.c.peekAt(1);
            const ok = for (iv_words) |w| {
                if (to.kind == .word and eql(p.val(to), w)) break true;
            } else false;
            if (!ok or ivinput.rangeOfFields(a, p.val(to)) == null) {
                p.c.skip();
                return p.c.syntaxError();
            }
            p.c.skip();
            b = p.val(p.c.advance());
        }
        const last = if (b.len > 0) b else a;
        if (eql(last, "second") and p.c.peek().kind == .lparen) {
            const lp = p.c.advance();
            const n = try p.signedInt();
            _ = try p.c.expect(.rparen);
            ty.mods = try p.arena.dupe(i64, &.{n});
            try p.intervalPrecision(lp.start, ty.mods);
        }
        ty.fields = if (b.len > 0) try std.mem.concat(p.arena, u8, &.{ a, " to ", b }) else a;
    }

    /// intervaltypmodin()'s check of a precision: negative is an error,
    /// more than 6 is 6.
    fn intervalPrecision(p: *Parser, pos: u32, mods: []const i64) Error!void {
        if (mods.len != 1) return p.c.failState(pos, .of("22023"), "invalid INTERVAL type modifier", .{});
        if (mods[0] < 0) return p.c.failState(pos, .of("22023"), "INTERVAL({d}) precision must not be negative", .{mods[0]});
    }

    pub fn typeName(p: *Parser) Error!types.TypeName {
        const t = p.c.peek();
        if (t.kind != .word and t.kind != .quoted_ident) return p.c.syntaxError();
        p.c.skip();
        var w = p.val(t);
        // pg_catalog.int4
        if (p.c.peek().kind == .dot) {
            if (!eql(w, "pg_catalog") and !eql(w, "public")) return p.c.failState(t.start, .of("42704"), "type \"{s}\" does not exist", .{p.c.sql[t.start..p.c.peekAt(1).end]});
            p.c.skip();
            const n = try p.anyName();
            w = n.text;
        }
        var ty: types.TypeName = .{ .name = w, .pos = t.start };
        if (t.kind == .word) {
            if (eql(w, "double")) {
                try p.c.expectKw("precision");
                ty.name = "double precision";
            } else if (eql(w, "character") or eql(w, "char") or eql(w, "nchar")) {
                ty.name = if (p.c.eatKw("varying")) "character varying" else "character";
            } else if (eql(w, "national")) {
                if (!p.c.eatKw("character")) try p.c.expectKw("char");
                ty.name = if (p.c.eatKw("varying")) "character varying" else "character";
            } else if (eql(w, "varchar")) {
                ty.name = "character varying";
            } else if (eql(w, "bit")) {
                ty.name = if (p.c.eatKw("varying")) "bit varying" else "bit";
            } else {
                ty.name = canonicalType(w);
            }
        }
        if (eql(ty.name, "float")) {
            // float(p): real up to 24 bits of precision.
            var real = false;
            if (p.c.peek().kind == .lparen) {
                p.c.skip();
                const bits = try p.signedInt();
                _ = try p.c.expect(.rparen);
                if (bits < 1 or bits > 53) return p.c.failState(t.start, .of("22023"), "precision for type float must be between 1 and 53 bits", .{});
                real = bits <= 24;
            }
            ty.name = if (real) "real" else "double precision";
        }
        if (p.c.peek().kind == .lparen and takesMods(ty.name)) {
            p.c.skip();
            var mods: std.ArrayList(i64) = .empty;
            while (true) {
                try mods.append(p.arena, try p.signedInt());
                if (!p.c.eat(.comma)) break;
            }
            _ = try p.c.expect(.rparen);
            ty.mods = mods.items;
            if (eql(ty.name, "numeric")) try p.numericTypmod(t.start, ty.mods);
        }
        if (eql(ty.name, "timestamp") or eql(ty.name, "time")) {
            var tz = false;
            if (p.c.eatKws(&.{ "with", "time" })) {
                try p.c.expectKw("zone");
                tz = true;
            } else if (p.c.eatKws(&.{ "without", "time" })) {
                try p.c.expectKw("zone");
            }
            ty.name = if (eql(ty.name, "timestamp"))
                (if (tz) "timestamp with time zone" else "timestamp without time zone")
            else
                (if (tz) "time with time zone" else "time without time zone");
        } else if (eql(ty.name, "interval")) {
            if (ty.mods.len > 0) {
                try p.intervalPrecision(t.start, ty.mods);
            } else try p.intervalFields(&ty);
        }
        while (p.c.isOp("[")) {
            p.c.skip();
            if (p.c.peek().kind == .integer) p.c.skip();
            try p.c.expectOp("]");
            ty.array = true;
        }
        if (p.c.isKw("array")) {
            p.c.skip();
            ty.array = true;
        }
        return ty;
    }

    // ============================================================== DML

    fn insert(p: *Parser, with: ?*tree.With) Error!*tree.Insert {
        const pos = p.c.advance().start; // INSERT
        try p.c.expectKw("into");
        const rel = try p.relation(try p.qname());
        var ins: tree.Insert = .{ .with = with, .table = rel.q, .alias = rel.alias, .source = null, .pos = pos };
        if (p.c.eatKw("as")) ins.alias = try p.colId();
        if (p.c.peek().kind == .lparen and !p.parenStartsSelect()) ins.cols = try p.parenNameList();
        if (p.c.eatKw("overriding")) {
            if (!p.c.eatKw("system")) try p.c.expectKw("user");
            try p.c.expectKw("value");
            ins.overriding = true;
        }
        if (p.c.eatKws(&.{ "default", "values" })) {} else {
            ins.source = try p.select();
        }
        if (p.c.eatKws(&.{ "on", "conflict" })) {
            var oc: tree.OnConflict = .{};
            if (p.c.peek().kind == .lparen) {
                p.c.skip();
                var items: std.ArrayList(*Expr) = .empty;
                while (true) {
                    var e = try p.expr0();
                    if (e.kind == .collate) e = e.kind.collate.e;
                    try items.append(p.arena, e);
                    if (!p.c.eat(.comma)) break;
                }
                _ = try p.c.expect(.rparen);
                oc.target = items.items;
                if (p.c.eatKw("where")) oc.target_where = try p.expr0();
            } else if (p.c.isKw("on") and p.c.isKwAt(1, "constraint")) {
                return p.unsupported(p.c.peek().start, "ON CONFLICT ON CONSTRAINT");
            }
            try p.c.expectKw("do");
            if (p.c.eatKw("nothing")) {} else {
                const at = p.c.peek().start;
                try p.c.expectKw("update");
                if (oc.target.len == 0) return p.c.failState(at, .of("42601"), "ON CONFLICT DO UPDATE requires inference specification or constraint name", .{});
                try p.c.expectKw("set");
                oc.update = try p.setList();
                if (p.c.eatKw("where")) oc.where = try p.expr0();
            }
            ins.on_conflict = try p.new(tree.OnConflict, oc);
        }
        if (p.c.eatKw("returning")) ins.returning = try p.targetList();
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
            if (p.c.peek().kind == .lparen) {
                const cols = try p.parenNameList();
                if (!p.c.eatOp("=")) return p.c.syntaxError();
                const v = try p.expr0();
                try out.append(p.arena, .{ .cols = cols, .multi = true, .value = v });
            } else {
                var cols = try p.arena.alloc(Name, 1);
                cols[0] = try p.colId();
                if (p.c.peek().kind == .dot) return p.unsupported(p.c.peek().start, "assigning to a field of a column");
                // col[i][j] = v: col = xq_pg_array_set(col, v, i, j).
                var subs: std.ArrayList(*Expr) = .empty;
                while (p.c.isOp("[")) {
                    p.c.skip();
                    try subs.append(p.arena, try p.expr0());
                    if (p.c.isOp(":")) return p.unsupported(p.c.peek().start, "assigning to an array slice");
                    try p.c.expectOp("]");
                }
                if (!p.c.eatOp("=")) return p.c.syntaxError();
                var v = try p.expr0();
                if (subs.items.len > 0) {
                    const names = try p.arena.alloc(Name, 1);
                    names[0] = cols[0];
                    var args: std.ArrayList(*Expr) = .empty;
                    try args.append(p.arena, try p.expr(cols[0].pos, .{ .column = names }));
                    try args.append(p.arena, v);
                    try args.appendSlice(p.arena, subs.items);
                    v = try p.call(cols[0].pos, "xq_pg_array_set", null, args.items);
                }
                try out.append(p.arena, .{ .cols = cols, .multi = false, .value = v });
            }
            if (!p.c.eat(.comma)) break;
        }
        return out.items;
    }

    fn update(p: *Parser, with: ?*tree.With) Error!*tree.Update {
        const pos = p.c.advance().start; // UPDATE
        _ = p.c.eatKw("only");
        const rel = try p.relation(try p.qname());
        var u: tree.Update = .{ .with = with, .table = rel.q, .alias = rel.alias, .sets = &.{}, .pos = pos };
        _ = p.c.eatOp("*");
        if (p.c.eatKw("as")) {
            u.alias = try p.colId();
        } else if (!p.c.isKw("set")) {
            const a = p.c.peek();
            if (a.kind == .quoted_ident or (a.kind == .word and !a.isReserved())) {
                p.c.skip();
                u.alias = .{ .text = p.val(a), .pos = a.start };
            }
        }
        try p.c.expectKw("set");
        u.sets = try p.setList();
        if (p.c.eatKw("from")) u.from = try p.fromList();
        if (p.c.eatKw("where")) {
            if (p.c.isKw("current") and p.c.isKwAt(1, "of")) return p.unsupported(p.c.peek().start, "WHERE CURRENT OF");
            u.where = try p.expr0();
        }
        if (p.c.eatKw("returning")) u.returning = try p.targetList();
        return p.new(tree.Update, u);
    }

    fn delete(p: *Parser, with: ?*tree.With) Error!*tree.Delete {
        const pos = p.c.advance().start; // DELETE
        try p.c.expectKw("from");
        _ = p.c.eatKw("only");
        const rel = try p.relation(try p.qname());
        var d: tree.Delete = .{ .with = with, .table = rel.q, .alias = rel.alias, .pos = pos };
        _ = p.c.eatOp("*");
        if (p.c.eatKw("as")) {
            d.alias = try p.colId();
        } else {
            const a = p.c.peek();
            if (a.kind == .quoted_ident or (a.kind == .word and !a.isReserved())) {
                p.c.skip();
                d.alias = .{ .text = p.val(a), .pos = a.start };
            }
        }
        if (p.c.eatKw("using")) d.using = try p.fromList();
        if (p.c.eatKw("where")) {
            if (p.c.isKw("current") and p.c.isKwAt(1, "of")) return p.unsupported(p.c.peek().start, "WHERE CURRENT OF");
            d.where = try p.expr0();
        }
        if (p.c.eatKw("returning")) d.returning = try p.targetList();
        return p.new(tree.Delete, d);
    }

    // ============================================================== DDL

    fn create(p: *Parser) Error!tree.Stmt {
        const at = p.c.advance().start; // CREATE
        var or_replace = false;
        if (try p.c.optKws(&.{ "or", "replace" })) {
            or_replace = true;
        }
        var temp = false;
        if (p.c.eatKw("global") or p.c.eatKw("local")) {
            if (!p.c.isKw("temp") and !p.c.isKw("temporary")) return p.c.syntaxError();
        }
        if (p.c.eatKw("temp") or p.c.eatKw("temporary")) temp = true else _ = p.c.eatKw("unlogged");
        if (p.c.isKw("table")) {
            if (or_replace) return p.c.syntaxError();
            return .{ .create_table = try p.createTable(temp) };
        }
        if (p.c.isKw("view")) {
            p.c.skip();
            const q = try p.qname();
            const t = try p.createTarget(q, temp);
            temp = temp or eql(t.db, "temp");
            var v: tree.CreateView = .{ .or_replace = or_replace, .temp = temp, .name = .{ .schema = .{ .text = t.db }, .name = .{ .text = t.name, .pos = q.name.pos } }, .select = undefined };
            if (p.c.peek().kind == .lparen) v.cols = try p.parenNameList();
            if (p.c.eatKw("with")) {
                _ = try p.c.expect(.lparen);
                while (p.c.peek().kind != .rparen and p.c.peek().kind != .eof) p.c.skip();
                _ = try p.c.expect(.rparen);
            }
            try p.c.expectKw("as");
            v.select = try p.select();
            if (p.c.isKw("with")) return p.unsupported(p.c.peek().start, "WITH CHECK OPTION");
            return .{ .create_view = try p.new(tree.CreateView, v) };
        }
        if (p.c.isKw("sequence")) {
            p.c.skip();
            var s: tree.CreateSequence = .{ .name = undefined };
            s.if_not_exists = try p.c.ifNotExists();
            const q = try p.qname();
            const t = try p.createTarget(q, false);
            if (!eql(t.db, "main")) return p.c.fail(q.schema.?.pos, "xqlite: sequences are only supported in public and in schemas of CREATE SCHEMA", .{});
            s.name = .{ .name = .{ .text = t.name, .pos = q.name.pos } };
            s.opts = try p.seqOptions();
            return .{ .create_sequence = try p.new(tree.CreateSequence, s) };
        }
        if (p.c.isKw("unique") or p.c.isKw("index")) {
            if (or_replace or temp) return p.c.syntaxError();
            return .{ .create_index = try p.createIndex() };
        }
        if (p.c.isAnyKw(&.{ "schema", "database", "extension", "type", "function", "trigger", "domain", "procedure", "role", "user" })) {
            return p.c.failState(at, .of("0A000"), "CREATE {s} is not supported", .{std.ascii.allocUpperString(p.arena, p.val(p.c.peek())) catch return error.OutOfMemory});
        }
        return p.c.syntaxError();
    }

    fn seqOptions(p: *Parser) Error!tree.SeqOpts {
        var o: tree.SeqOpts = .{};
        while (true) {
            if (p.c.eatKw("as")) {
                _ = try p.typeName();
            } else if (p.c.eatKw("increment")) {
                _ = p.c.eatKw("by");
                o.increment = try p.signedInt();
            } else if (p.c.eatKw("minvalue")) {
                o.min = try p.signedInt();
            } else if (p.c.eatKw("maxvalue")) {
                o.max = try p.signedInt();
            } else if (p.c.eatKw("start")) {
                _ = p.c.eatKw("with");
                o.start = try p.signedInt();
            } else if (p.c.eatKw("cache")) {
                _ = try p.signedInt();
            } else if (p.c.eatKw("cycle")) {
                o.cycle = true;
            } else if (p.c.eatKw("no")) {
                if (p.c.eatKw("minvalue")) {} else if (p.c.eatKw("maxvalue")) {} else if (p.c.eatKw("cycle")) {
                    o.cycle = false;
                } else return p.c.syntaxError();
            } else if (try p.c.optKws(&.{ "owned", "by" })) {
                if (!p.c.eatKw("none")) _ = try p.qname();
            } else break;
        }
        return o;
    }

    fn createTable(p: *Parser, temp_arg: bool) Error!*tree.CreateTable {
        p.c.skip(); // TABLE
        const if_not_exists = try p.c.ifNotExists();
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
        if (p.c.eatKw("as")) {
            ct.as_select = try p.select();
            if (p.c.eatKw("with")) {
                _ = p.c.eatKw("no");
                try p.c.expectKw("data");
            }
            return p.new(tree.CreateTable, ct);
        }
        _ = try p.c.expect(.lparen);
        var cols: std.ArrayList(tree.ColumnDef) = .empty;
        var cons: std.ArrayList(tree.TableConstraint) = .empty;
        if (p.c.peek().kind != .rparen) while (true) {
            const t = p.c.peek();
            if (t.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign", "exclude" })) {
                try cons.append(p.arena, try p.tableConstraint(table));
            } else if (t.isKw("like")) {
                return p.unsupported(t.start, "CREATE TABLE ... LIKE");
            } else {
                const c = try p.columnDef(table);
                for (cols.items) |prev| if (eql(prev.name.text, c.name.text)) {
                    return p.c.failState(c.name.pos, .of("42701"), "column \"{s}\" specified more than once", .{c.name.text});
                };
                try cols.append(p.arena, c);
            }
            if (!p.c.eat(.comma)) break;
        };
        _ = try p.c.expect(.rparen);
        if (cols.items.len == 0) return p.c.failState(q.name.pos, .of("42P16"), "a table must have at least one column", .{});
        ct.columns = cols.items;
        ct.constraints = cons.items;
        // The identity sequences are in the table's schema.
        if (dest.mangled) for (ct.columns) |c| for (c.constraints) |*cc| if (cc.kind == .identity) {
            cc.kind.identity.sequence = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ prefixOf(dest), cc.kind.identity.sequence });
        };
        // Storage options are ignored.
        while (true) {
            if (p.c.eatKw("with")) {
                _ = try p.c.expect(.lparen);
                while (p.c.peek().kind != .rparen and p.c.peek().kind != .eof) p.c.skip();
                _ = try p.c.expect(.rparen);
            } else if (try p.c.optKws(&.{ "without", "oids" })) {} else if (p.c.eatKws(&.{ "on", "commit" })) {
                if (try p.c.optKws(&.{ "preserve", "rows" })) {} else if (p.c.eatKw("delete")) {
                    return p.unsupported(p.c.prev().start, "ON COMMIT DELETE ROWS");
                } else try p.c.expectKw("drop");
            } else if (p.c.eatKw("tablespace")) {
                _ = try p.colId();
            } else if (p.c.isKw("inherits") or p.c.isKw("partition")) {
                return p.unsupported(p.c.peek().start, "table inheritance and partitioning");
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
            if (p.c.eatKw("constraint")) cname = try p.colId();
            var cc: RawConstraint = .{ .name = cname, .kind = .null };
            if (p.c.eatKw("not")) {
                if (p.c.eatKw("null")) {
                    cc.kind = .not_null;
                } else {
                    try p.c.expectKw("deferrable");
                    continue;
                }
            } else if (p.c.eatKw("null")) {
                cc.kind = .null;
            } else if (p.c.eatKw("check")) {
                _ = try p.c.expect(.lparen);
                cc.kind = .{ .check = try p.expr0() };
                _ = try p.c.expect(.rparen);
                _ = try p.c.optKws(&.{ "no", "inherit" });
            } else if (p.c.eatKw("default")) {
                cc.kind = .{ .default = try p.otherExpr() };
            } else if (p.c.eatKw("unique")) {
                try p.nullsDistinct();
                cc.kind = .unique;
            } else if (try p.c.optKws(&.{ "primary", "key" })) {
                cc.kind = .primary_key;
            } else if (p.c.isKw("references")) {
                cc.kind = .{ .references = try p.references() };
            } else if (p.c.eatKw("generated")) {
                var always = true;
                if (try p.c.optKws(&.{ "by", "default" })) {
                    always = false;
                } else try p.c.expectKw("always");
                try p.c.expectKw("as");
                if (p.c.eatKw("identity")) {
                    var opts: tree.SeqOpts = .{};
                    if (p.c.peek().kind == .lparen) {
                        p.c.skip();
                        opts = try p.seqOptions();
                        _ = try p.c.expect(.rparen);
                    }
                    cc.kind = .{ .identity = .{ .always = always, .opts = opts } };
                } else {
                    if (!always) return p.c.syntaxError();
                    _ = try p.c.expect(.lparen);
                    const e = try p.expr0();
                    _ = try p.c.expect(.rparen);
                    try p.c.expectKw("stored");
                    cc.kind = .{ .generated = e };
                }
            } else if (p.c.eatKw("deferrable") or p.c.eatKw("initially")) {
                if (p.c.prev().isKw("initially")) {
                    if (!p.c.eatKw("deferred")) try p.c.expectKw("immediate");
                }
                continue;
            } else if (p.c.eatKw("collate")) {
                collate = try p.anyName();
                continue;
            } else {
                if (cname != null) return p.c.syntaxError();
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
            return p.c.failState(name.pos, .of("42601"), "multiple default values specified for column \"{s}\" of table \"{s}\"", .{ name.text, table });
        }
        if (identity != null and info.storage[0] != 'I') return p.c.failState(ty.pos, .of("42804"), "identity column type must be smallint, integer, or bigint", .{});

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
                .default => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .default = try p.numericStored(ty, try p.uuidDefault(ty, try p.jsonDefault(ty, e)), true) } }),
                .primary_key => try cons.append(p.arena, .{ .name = cname, .kind = .{ .primary_key = .{} } }),
                .unique => try cons.append(p.arena, .{ .name = cname, .kind = .unique }),
                .references => |r| try cons.append(p.arena, .{ .name = cname, .kind = .{ .references = r } }),
                .generated => |e| try cons.append(p.arena, .{ .name = cname, .kind = .{ .generated = .{ .e = try p.numericStored(ty, try p.jsonbStored(ty, e), false), .stored = true } } }),
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
            // A key of decimal.zig (of numeric(p, s) as is).
            .numeric => {
                var args: std.ArrayList(*Expr) = .empty;
                try args.append(a, col);
                if (numericMods(ty)) |m| for (m) |v| try args.append(a, try int_.lit(a, pos, v));
                return .{ .name = "invalid input syntax for type numeric", .kind = .{ .check = try p.call(pos, "xq_dec_valid", null, args.items) } };
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
            // A JSONB blob, as json_valid(x, 8) checks one (sqlite3 too).
            .jsonb => return .{ .name = "invalid input syntax for type json", .kind = .{ .check = try p.call(pos, "json_valid", null, &.{ col, try int_.lit(a, pos, 8) }) } },
            .array => return .{ .name = "malformed array literal", .kind = .{ .check = try p.call(pos, "xq_pg_array_valid", null, &.{col}) } },
            // 16 bytes (a value stored goes through xq_pg_uuid(), which
            // fails on what is not one; this keeps out other blobs).
            .uuid => {
                const len = try p.call(pos, "length", null, &.{col});
                return .{ .name = "invalid input syntax for type uuid", .kind = .{ .check = try tree.expr(a, pos, pos, .{ .compare = .{ .op = .eq, .l = len, .r = try int_.lit(a, pos, 16) } }) } };
            },
            .interval => return .{ .name = "invalid input syntax for type interval", .kind = .{ .check = try p.call(pos, "xq_pg_iv_valid", null, &.{col}) } },
        }
    }

    fn nullsDistinct(p: *Parser) Error!void {
        if (p.c.isKw("nulls")) {
            const at = p.c.advance().start;
            if (try p.c.optKws(&.{ "not", "distinct" })) {
                return p.unsupported(at, "NULLS NOT DISTINCT");
            }
            try p.c.expectKw("distinct");
        }
    }

    fn references(p: *Parser) Error!tree.Ref {
        try p.c.expectKw("references");
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
        if (p.c.peek().kind == .lparen) r.cols = try p.parenNameList();
        while (true) {
            if (p.c.eatKw("match")) {
                if (!p.c.eatKw("full") and !p.c.eatKw("simple")) try p.c.expectKw("partial");
            } else if (p.c.isKw("on") and (p.c.isKwAt(1, "delete") or p.c.isKwAt(1, "update"))) {
                p.c.skip();
                const del = p.c.advance().isKw("delete");
                const act = try p.refAction();
                if (del) r.on_delete = act else r.on_update = act;
            } else if (p.c.eatKws(&.{ "not", "deferrable" })) {} else if (p.c.eatKw("deferrable")) {} else if (p.c.eatKw("initially")) {
                if (p.c.eatKw("deferred")) r.deferred = true else try p.c.expectKw("immediate");
            } else break;
        }
        return r;
    }

    fn refAction(p: *Parser) Error!tree.RefAction {
        if (p.c.eatKw("cascade")) return .cascade;
        if (p.c.eatKw("restrict")) return .restrict;
        if (try p.c.optKws(&.{ "no", "action" })) {
            return .none;
        }
        try p.c.expectKw("set");
        if (p.c.eatKw("null")) return .set_null;
        try p.c.expectKw("default");
        return .set_default;
    }

    fn tableConstraint(p: *Parser, table: []const u8) Error!tree.TableConstraint {
        var name: ?Name = null;
        if (p.c.eatKw("constraint")) name = try p.colId();
        const t = p.c.peek();
        var tc: tree.TableConstraint = .{ .name = if (name) |n| n.text else null, .kind = undefined };
        if (p.c.eatKw("check")) {
            _ = try p.c.expect(.lparen);
            tc.kind = .{ .check = try p.expr0() };
            _ = try p.c.expect(.rparen);
            _ = try p.c.optKws(&.{ "no", "inherit" });
            if (name == null) tc.name = try std.fmt.allocPrint(p.arena, "{s}_check", .{table});
        } else if (p.c.eatKw("unique")) {
            try p.nullsDistinct();
            tc.kind = .{ .unique = try p.parenNameList() };
            try p.indexTail();
        } else if (try p.c.optKws(&.{ "primary", "key" })) {
            tc.kind = .{ .primary_key = try p.parenNameList() };
            try p.indexTail();
        } else if (try p.c.optKws(&.{ "foreign", "key" })) {
            const cols = try p.parenNameList();
            tc.kind = .{ .foreign_key = .{ .cols = cols, .ref = try p.references() } };
        } else if (p.c.isKw("exclude")) {
            return p.unsupported(t.start, "EXCLUDE constraints");
        } else return p.c.syntaxError();
        while (true) {
            if (p.c.eatKws(&.{ "not", "deferrable" })) {} else if (p.c.eatKw("deferrable")) {} else if (p.c.eatKw("initially")) {
                if (!p.c.eatKw("deferred")) try p.c.expectKw("immediate");
            } else break;
        }
        return tc;
    }

    /// INCLUDE (...) / WITH (...) / USING INDEX TABLESPACE after a key.
    fn indexTail(p: *Parser) Error!void {
        if (p.c.eatKw("include")) _ = try p.parenNameList();
    }

    /// CREATE INDEX; an index without a name gets PostgreSQL's
    /// (ddl.zig), here an empty one.
    fn createIndex(p: *Parser) Error!*tree.CreateIndex {
        var ci: tree.CreateIndex = .{ .name = .{ .name = .{ .text = "" } }, .table = undefined, .items = &.{} };
        if (p.c.eatKw("unique")) ci.unique = true;
        try p.c.expectKw("index");
        _ = p.c.eatKw("concurrently");
        ci.if_not_exists = try p.c.ifNotExists();
        if (!p.c.isKw("on")) ci.name.name = try p.colId();
        try p.c.expectKw("on");
        _ = p.c.eatKw("only");
        // The index is in the schema of its table.
        const iq = try p.qname();
        if (iq.schema) |s| _ = try p.qualified(s, iq.name);
        const rel = try p.lookup(iq, .relation);
        if (rel.q.schema) |s| ci.name.schema = .{ .text = s.text };
        ci.table = rel.q.name;
        if (rel.alias) |bare| if (ci.name.name.text.len > 0) {
            const head = rel.q.name.text[0 .. rel.q.name.text.len - bare.text.len];
            ci.name.name.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ head, ci.name.name.text });
        };
        if (p.c.eatKw("using")) {
            const m = try p.anyName();
            // gin (and hash) indexes are B-tree indexes of the same
            // columns: they serve equality, not @> or ?.
            if (!eql(m.text, "btree") and !eql(m.text, "gin") and !eql(m.text, "hash")) return p.c.failState(m.pos, .of("0A000"), "index method \"{s}\" is not supported", .{m.text});
        }
        _ = try p.c.expect(.lparen);
        var items: std.ArrayList(tree.IndexItem) = .empty;
        while (true) {
            var item: tree.IndexItem = .{ .expr = undefined };
            const e = try p.otherExpr();
            if (e.kind == .collate) {
                item.expr = e.kind.collate.e;
                item.collate = e.kind.collate.collation;
            } else item.expr = e;
            // An operator class.
            if (p.c.peek().kind == .word and !p.c.peek().isReserved() and !p.c.isKw("nulls")) p.c.skip();
            if (p.c.eatKw("desc")) item.desc = true else _ = p.c.eatKw("asc");
            if (p.c.eatKw("nulls")) {
                if (!p.c.eatKw("first")) try p.c.expectKw("last");
            }
            try items.append(p.arena, item);
            if (!p.c.eat(.comma)) break;
        }
        _ = try p.c.expect(.rparen);
        ci.items = items.items;
        if (p.c.eatKw("include")) _ = try p.parenNameList();
        try p.nullsDistinct();
        if (p.c.eatKw("with")) {
            _ = try p.c.expect(.lparen);
            while (p.c.peek().kind != .rparen and p.c.peek().kind != .eof) p.c.skip();
            _ = try p.c.expect(.rparen);
        }
        if (p.c.eatKw("tablespace")) _ = try p.colId();
        if (p.c.eatKw("where")) ci.where = try p.expr0();
        return p.new(tree.CreateIndex, ci);
    }

    fn drop(p: *Parser) Error!*tree.Drop {
        p.c.skip(); // DROP
        const t = p.c.peek();
        var d: tree.Drop = .{ .kind = undefined, .name = undefined };
        if (p.c.eatKw("table")) {
            d.kind = .table;
        } else if (p.c.eatKw("view")) {
            d.kind = .view;
        } else if (p.c.eatKw("index")) {
            d.kind = .index;
            _ = p.c.eatKw("concurrently");
        } else if (p.c.eatKw("sequence")) {
            d.kind = .sequence;
        } else if (t.kind == .word and t.isAnyKw(&.{ "schema", "database", "extension", "type", "function", "trigger" })) {
            return p.c.failState(t.start, .of("0A000"), "DROP {s} is not supported", .{std.ascii.allocUpperString(p.arena, p.val(t)) catch return error.OutOfMemory});
        } else return p.c.syntaxError();
        d.if_exists = try p.c.ifExists();
        const kind: Lookup = switch (d.kind) {
            .table, .view => .relation,
            .index => .index,
            .sequence => .sequence,
        };
        // DROP TABLE a, b: each name resolved (d.others after the first).
        var names: std.ArrayList(tree.QName) = .empty;
        while (true) {
            const q = try p.qname();
            const name: tree.QName = if (q.schema) |s| blk: {
                const x = try p.qualified(s, q.name);
                if (d.kind == .sequence and !eql(x.db, "main")) return p.c.failState(s.pos, .of("42704"), "sequence \"{s}\" does not exist", .{q.name.text});
                break :blk .{ .schema = .{ .text = x.db, .pos = s.pos }, .name = .{ .text = x.name, .pos = q.name.pos } };
            } else switch (try p.unqualified(q.name, kind)) {
                .keep => .{ .name = q.name },
                .target => |x| .{ .schema = .{ .text = x.db, .pos = q.name.pos }, .name = .{ .text = x.name, .pos = q.name.pos } },
                .missing => blk: {
                    if (!d.if_exists) return p.c.failState(q.name.pos, .of("42P01"), "{s} \"{s}\" does not exist", .{ @tagName(d.kind), q.name.text });
                    // Not on search_path: a name nothing has (pg_temp's
                    // tables have no dot).
                    break :blk .{ .schema = .{ .text = "main" }, .name = .{ .text = try nsp.mangle(p.arena, "pg_temp", q.name.text), .pos = q.name.pos } };
                },
            };
            try names.append(p.arena, name);
            if (!p.c.eat(.comma)) break;
        }
        d.name = names.items[0];
        d.others = names.items[1..];
        if (p.c.eatKw("cascade")) {} else _ = p.c.eatKw("restrict");
        return p.new(tree.Drop, d);
    }

    fn alterTable(p: *Parser) Error!*tree.AlterTable {
        p.c.skip(); // ALTER
        if (!p.c.isKw("table")) {
            const t = p.c.peek();
            if (t.kind == .word) return p.c.failState(t.start, .of("0A000"), "ALTER {s} is not supported", .{std.ascii.allocUpperString(p.arena, p.val(t)) catch return error.OutOfMemory});
            return p.c.syntaxError();
        }
        p.c.skip();
        var a: tree.AlterTable = .{ .name = undefined, .action = undefined };
        a.if_exists = try p.c.ifExists();
        _ = p.c.eatKw("only");
        const q = try p.qname();
        var head: []const u8 = "";
        if (q.schema) |s| {
            const t = try p.qualified(s, q.name);
            head = prefixOf(t);
            a.name = .{ .schema = .{ .text = t.db, .pos = s.pos }, .name = .{ .text = t.name, .pos = q.name.pos } };
        } else switch (try p.unqualified(q.name, .relation)) {
            .keep => a.name = .{ .name = q.name },
            .target => |t| {
                head = prefixOf(t);
                a.name = .{ .schema = .{ .text = t.db, .pos = q.name.pos }, .name = .{ .text = t.name, .pos = q.name.pos } };
            },
            .missing => {
                if (!a.if_exists) return p.c.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
                a.name = .{ .schema = .{ .text = "main" }, .name = .{ .text = try nsp.mangle(p.arena, "pg_temp", q.name.text), .pos = q.name.pos } };
            },
        }
        const at = p.c.peek().start;
        if (p.c.eatKw("rename")) {
            if (p.c.eatKw("to")) {
                // The table stays in its schema.
                var to = try p.colId();
                if (head.len > 0) to.text = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ head, to.text });
                a.action = .{ .rename_to = to };
            } else {
                if (p.c.isKw("constraint")) return p.unsupported(at, "ALTER TABLE ... RENAME CONSTRAINT");
                _ = p.c.eatKw("column");
                const old = try p.colId();
                try p.c.expectKw("to");
                a.action = .{ .rename_column = .{ .old = old, .new = try p.colId() } };
            }
        } else if (p.c.eatKw("add")) {
            if (p.c.isAnyKw(&.{ "constraint", "check", "unique", "primary", "foreign" })) {
                return p.unsupported(at, "ALTER TABLE ... ADD CONSTRAINT");
            }
            _ = p.c.eatKw("column");
            const ine = try p.c.ifNotExists();
            a.action = .{ .add_column = .{ .if_not_exists = ine, .def = try p.columnDef(q.name.text) } };
        } else if (p.c.eatKw("drop")) {
            if (p.c.isKw("constraint")) return p.unsupported(at, "ALTER TABLE ... DROP CONSTRAINT");
            _ = p.c.eatKw("column");
            const ie = try p.c.ifExists();
            a.action = .{ .drop_column = .{ .if_exists = ie, .name = try p.colId() } };
            _ = p.c.eatKw("cascade") or p.c.eatKw("restrict");
        } else if (p.c.isKw("alter")) {
            return p.unsupported(at, "ALTER TABLE ... ALTER COLUMN");
        } else return p.c.syntaxError();
        if (p.c.peek().kind == .comma) return p.unsupported(p.c.peek().start, "several ALTER TABLE actions");
        return p.new(tree.AlterTable, a);
    }

    fn truncate(p: *Parser) Error!*tree.Truncate {
        p.c.skip();
        _ = p.c.eatKw("table");
        _ = p.c.eatKw("only");
        const q = try p.qname();
        _ = p.c.eatOp("*");
        if (p.c.eat(.comma)) return p.c.failState(p.c.peek().start, .of("0A000"), "TRUNCATE of several tables is not supported", .{});
        var t: tree.Truncate = .{ .table = (try p.relation(q)).q };
        if (try p.c.optKws(&.{ "restart", "identity" })) {
            t.restart_identity = true;
        } else if (p.c.eatKw("continue")) try p.c.expectKw("identity");
        _ = p.c.eatKw("cascade") or p.c.eatKw("restrict");
        return p.new(tree.Truncate, t);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The type of regexp_matches()'s column.
const text_array: types.TypeName = .{ .name = "text", .array = true, .pos = 0 };

/// A column of a JSON set-returning function (Parser.srfColumn()): of
/// the SQLite json_each() row of the item, `value` itself or element
/// `index` of it, cast to `cast`; `ordinality` is WITH ORDINALITY's.
pub const SrfCol = struct {
    name: []const u8,
    index: ?u32 = null,
    cast: ?types.TypeName = null,
    ordinality: bool = false,
};

pub const Srf = struct { cols: []SrfCol };

const SrfKind = enum { each, elements, keys, path, records, populate, unnest, subscripts, expand, re_matches, re_split };

/// The set-returning functions of arrays.
fn arraySrfKind(q: QName) ?SrfKind {
    const n = q.name.text;
    if (q.schema) |s| {
        if (eql(s.text, "information_schema")) return if (eql(n, "_pg_expandarray")) .expand else null;
        if (!eql(s.text, "pg_catalog")) return null;
    }
    if (eql(n, "unnest")) return .unnest;
    if (eql(n, "generate_subscripts")) return .subscripts;
    if (eql(n, "regexp_matches")) return .re_matches;
    if (eql(n, "regexp_split_to_table")) return .re_split;
    return null;
}

fn srfKind(name: []const u8) ?SrfKind {
    const map = std.StaticStringMap(SrfKind).initComptime(.{
        .{ "json_each", .each },                    .{ "json_each_text", .each },
        .{ "jsonb_each", .each },                   .{ "jsonb_each_text", .each },
        .{ "json_array_elements", .elements },      .{ "json_array_elements_text", .elements },
        .{ "jsonb_array_elements", .elements },     .{ "jsonb_array_elements_text", .elements },
        .{ "json_object_keys", .keys },             .{ "jsonb_object_keys", .keys },
        .{ "jsonb_path_query", .path },             .{ "json_to_record", .records },
        .{ "json_to_recordset", .records },         .{ "jsonb_to_record", .records },
        .{ "jsonb_to_recordset", .records },        .{ "json_populate_record", .populate },
        .{ "json_populate_recordset", .populate },  .{ "jsonb_populate_record", .populate },
        .{ "jsonb_populate_recordset", .populate }, .{ "unnest", .unnest },
        .{ "generate_subscripts", .subscripts },    .{ "_pg_expandarray", .expand },
        .{ "regexp_matches", .re_matches },         .{ "regexp_split_to_table", .re_split },
    });
    return map.get(name);
}

/// What a json/jsonb operator calls (jfuncs.zig); `swap`: with the
/// operands the other way round.
const JsonOperator = struct { func: []const u8, swap: bool = false };

const json_operators = [_]struct { []const u8, JsonOperator }{
    .{ "->", JsonOperator{ .func = "xq_pg_json_get" } },
    .{ "->>", JsonOperator{ .func = "xq_pg_json_get_text" } },
    .{ "#>", JsonOperator{ .func = "xq_pg_json_path" } },
    .{ "#>>", JsonOperator{ .func = "xq_pg_json_path_text" } },
    .{ "@>", JsonOperator{ .func = "xq_pg_jsonb_contains" } },
    .{ "<@", JsonOperator{ .func = "xq_pg_jsonb_contains", .swap = true } },
    .{ "?", JsonOperator{ .func = "xq_pg_jsonb_exists" } },
    .{ "?|", JsonOperator{ .func = "xq_pg_jsonb_exists_any" } },
    .{ "?&", JsonOperator{ .func = "xq_pg_jsonb_exists_all" } },
    .{ "#-", JsonOperator{ .func = "xq_pg_jsonb_delete_path" } },
    .{ "@?", JsonOperator{ .func = "xq_pg_jsonb_path_exists_op" } },
    .{ "@@", JsonOperator{ .func = "xq_pg_jsonb_path_match_op" } },
    // Of arrays (overload.zig makes @> and <@ of arrays theirs).
    .{ "&&", JsonOperator{ .func = "xq_pg_array_overlap" } },
};

fn jsonOperator(op: []const u8) ?JsonOperator {
    const map = std.StaticStringMap(JsonOperator).initComptime(json_operators);
    return map.get(op);
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

/// A regular expression operator: `~` (`fold`: `~*`, case-insensitive;
/// `negate`: `!~`, `!~*`).
pub const RegexOp = struct { fold: bool, negate: bool };

/// The regular expression operator named `op` (`~`, `~*`, `!~`, `!~*`),
/// also for OPERATOR(pg_catalog.~); null for another.
const regex_operators = [_]struct { []const u8, RegexOp }{
    .{ "~", .{ .fold = false, .negate = false } }, .{ "~*", .{ .fold = true, .negate = false } },
    .{ "!~", .{ .fold = false, .negate = true } }, .{ "!~*", .{ .fold = true, .negate = true } },
};

pub fn regexOperator(op: []const u8) ?RegexOp {
    for (regex_operators) |m| if (std.mem.eql(u8, op, m[0])) return m[1];
    return null;
}

/// The calls (without OVER, FILTER or ORDER BY) that become something
/// else: now() and its synonyms (no arguments), localtime,
/// current_role/session_user (current_user()), current_catalog
/// (current_database()), date_part().
const SpecialFunc = enum { now, localtime, current_user, current_database, date_part };

/// The parameters of a built-in function that takes arguments by name,
/// the last `defaults` of them with a default (0).
const Params = struct { names: []const []const u8, defaults: usize = 0 };

fn namedParams(name: []const u8) ?Params {
    const map = [_]struct { []const u8, Params }{
        .{ "make_interval", .{ .names = &.{ "years", "months", "weeks", "days", "hours", "mins", "secs" }, .defaults = 7 } },
        .{ "make_date", .{ .names = &.{ "year", "month", "day" } } },
        .{ "make_time", .{ .names = &.{ "hour", "min", "sec" } } },
        .{ "make_timestamp", .{ .names = &.{ "year", "month", "mday", "hour", "min", "sec" } } },
    };
    for (map) |m| if (eql(m[0], name)) return m[1];
    return null;
}

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
        .{ "chr", "char" },           .{ "gen_random_uuid", "uuidv4" },
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

/// The text of a constant number or string, and whether it is negated
/// (`-1.5`, `'2.50'`, `'3'::numeric`); null for another expression.
fn constantText(e: *const Expr) ?struct { text: []const u8, neg: bool = false } {
    switch (e.kind) {
        .integer => |z| return .{ .text = z },
        .float => |z| return .{ .text = z },
        .string => |z| return .{ .text = z },
        .unary => |u| if (u.op == .neg) switch (u.e.kind) {
            .integer, .float => |z| return .{ .text = z, .neg = true },
            else => {},
        },
        .cast => |c| if (std.mem.startsWith(u8, c.target_type, "numeric") and c.e.kind == .string) return .{ .text = c.e.kind.string },
        else => {},
    }
    return null;
}

/// The precision and scale of numeric(p [, s]), null for numeric.
pub fn numericMods(ty: types.TypeName) ?[2]i64 {
    if (ty.array or !eql(ty.name, "numeric")) return null;
    return switch (ty.mods.len) {
        1 => .{ ty.mods[0], 0 },
        2 => .{ ty.mods[0], ty.mods[1] },
        else => null,
    };
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
