//! PostgreSQL's text of what the schema keeps as SQLite text: a CHECK's,
//! a DEFAULT's or a generated column's expression, an index's columns and
//! predicate, a view's query, as pg_get_constraintdef(), pg_get_expr(),
//! pg_get_indexdef() and pg_get_viewdef() print them (PostgreSQL's
//! ruleutils.c), in either of their modes (pretty or not).
//!
//! The frontend wrote the calls of the engine PostgreSQL's operators
//! chose into that text (ddltype.zig: xq_dec_key(price) >= xq_dec_key(0),
//! xq_pg_jsonb_get(j, 'a'), xq_pg_any(x, a, 0, 0) ...). The text is read
//! into a tree here, each such call is made the operator, the constant or
//! the cast PostgreSQL's parser would have made (price >= (0)::numeric),
//! the constants get the types PostgreSQL gives them and the implicit
//! casts it adds (('x'::text), (v)::text for a varchar), by the types of
//! the columns, and the tree is printed as ruleutils.c prints a parse
//! tree: every operator in parentheses, or, pretty, only where its
//! precedence asks for them. Nothing is stored: the schema's text stays
//! what the engine reads.
//!
//! What is not understood (a subquery, a window, a set operation, a
//! function or a type of an engine call not listed) makes the caller keep
//! the older text: null.

const std = @import("std");
const pgc = @import("pgcatalog.zig");
const datetime = @import("datetime.zig");
const json = @import("json.zig");
const uuid_mod = @import("uuid.zig");
const parser = @import("parser.zig");
const integer = @import("integer.zig");
const operators = @import("operators.zig");

const Allocator = std.mem.Allocator;
const Oom = error{OutOfMemory};
const Error = error{ OutOfMemory, Unsupported };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn ieql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ================================================================ scope

/// A relation an expression reads: its name (or alias) and columns.
pub const Item = struct {
    /// The name the expression qualifies its columns with (the alias,
    /// else the relation's SQLite name).
    name: []const u8,
    /// What qualifies its columns in PostgreSQL's text (the alias, else
    /// the relation's name without a CREATE SCHEMA schema's "s."); "" for
    /// `name`.
    label: []const u8 = "",
    attrs: []const pgc.Attr,
};

pub const Scope = struct {
    items: []const Item = &.{},
    /// Columns qualified with their relation (a view of several).
    qualify: bool = false,
    /// The type (OID) a column stores the expression as (a DEFAULT's, a
    /// generated column's): PostgreSQL's assignment cast to it, which it
    /// does not show but parenthesizes under in pretty mode.
    as_type: u32 = 0,
};

/// The PostgreSQL text of SQLite expression text `z` over `scope`, null if
/// it is beyond this module.
pub fn expr(a: Allocator, z: []const u8, scope: Scope, pretty: bool) Oom!?[]const u8 {
    var p = Parser.init(a, z) catch |e| return orNull(e);
    const n = p.expr() catch |e| return orNull(e);
    if (!p.atEnd()) return null;
    var f: Fixer = .{ .a = a, .scope = scope };
    var t = f.fix(n) catch |e| return orNull(e);
    if (scope.as_type != 0) {
        const ty = typeName(scope.as_type);
        if (t.kind == .str and t.ty.len == 0) {
            t = f.coerce(t, ty) catch |e| return orNull(e);
        } else if (t.ty.len > 0 and !eql(t.ty, ty)) {
            t = f.node(.{ .kind = .cast, .text = ty, .ty = ty, .args = f.list(&.{t}) catch return error.OutOfMemory, .hidden = true }) catch return error.OutOfMemory;
        }
    }
    var pr: Printer = .{ .a = a, .pretty = pretty, .scope = scope };
    pr.expr(t) catch |e| return orNull(e);
    return pr.out.items;
}

/// An index column's text (pg_get_indexdef()): in parentheses unless a
/// function call.
pub fn indexColumn(a: Allocator, z: []const u8, scope: Scope, pretty: bool) Oom!?[]const u8 {
    var p = Parser.init(a, z) catch |e| return orNull(e);
    const n = p.expr() catch |e| return orNull(e);
    if (!p.atEnd()) return null;
    var f: Fixer = .{ .a = a, .scope = scope };
    const t = f.fix(n) catch |e| return orNull(e);
    var pr: Printer = .{ .a = a, .pretty = pretty, .scope = scope };
    pr.expr(t) catch |e| return orNull(e);
    if (t.kind == .func) return pr.out.items;
    return try std.fmt.allocPrint(a, "({s})", .{pr.out.items});
}

/// The columns (attribute numbers) expression text `z` reads of the one
/// relation of `scope` (a CHECK's conkey), in their order there.
pub fn columns(a: Allocator, z: []const u8, scope: Scope) Oom![]const i16 {
    var out: std.ArrayList(i16) = .empty;
    if (scope.items.len != 1) return out.items;
    var p = Parser.init(a, z) catch return out.items;
    const n = p.expr() catch return out.items;
    var seen: std.AutoArrayHashMapUnmanaged(i16, void) = .empty;
    try collect(a, n, scope.items[0].attrs, &seen);
    try out.appendSlice(a, seen.keys());
    std.mem.sort(i16, out.items, {}, std.sort.asc(i16));
    return out.items;
}

fn collect(a: Allocator, n: *const Node, attrs: []const pgc.Attr, seen: *std.AutoArrayHashMapUnmanaged(i16, void)) Oom!void {
    if (n.kind == .col) {
        for (attrs) |at| if (ieql(at.name, n.text)) try seen.put(a, at.num, {});
    }
    for (n.args) |x| try collect(a, x, attrs, seen);
}

fn orNull(e: Error) Oom!?[]const u8 {
    return if (e == error.OutOfMemory) error.OutOfMemory else null;
}

// ================================================================= tree

const Kind = enum {
    col,
    int,
    num,
    str,
    null_,
    bool_,
    /// Text kept as it is (an engine's spelling PostgreSQL shares).
    raw,
    /// A binary operator (`text`).
    op,
    /// A prefix operator.
    prefix,
    and_,
    or_,
    not,
    isnull,
    notnull,
    /// IS [NOT] DISTINCT FROM (flag: NOT).
    distinct,
    func,
    /// `x::type` (implicit or not, as PostgreSQL shows both).
    cast,
    /// CASE: args [base] (when then)* [else].
    case_,
    array,
    /// x op ANY (array), flag: ALL.
    any,
    subscript,
    collate,
    row,
    /// SQLite's x IN (list), x BETWEEN a AND b, x LIKE y while parsed.
    in_,
    between,
    like,
    star,
};

const Node = struct {
    kind: Kind,
    /// A column's name, a constant's text, an operator, a function's
    /// name, a cast's type, a collation.
    text: []const u8 = "",
    qual: ?[]const u8 = null,
    args: []*Node = &.{},
    /// PostgreSQL's type (format_type()'s spelling), "" for unknown.
    ty: []const u8 = "",
    /// NOT (in_, between, like, distinct), ALL (any), DISTINCT (func).
    flag: bool = false,
    /// CASE: has a base expression; has an ELSE.
    base: bool = false,
    has_else: bool = false,
    /// A cast that is a function (int4 to numeric): simple in pretty mode.
    func_cast: bool = false,
    /// An implicit cast PostgreSQL does not show (showimplicit false).
    hidden: bool = false,
};

// =============================================================== tokens

const TokKind = enum { word, quoted, string, number, punct, blob, eof };
const Tok = struct { kind: TokKind, text: []const u8, start: usize, end: usize };

fn tokenize(a: Allocator, z: []const u8) Error![]Tok {
    var out: std.ArrayList(Tok) = .empty;
    var s: pgc.Scanner = .{ .z = z };
    const ops = [_][]const u8{ "->>", "->", "||", "<=", ">=", "<>", "!=", "==", "<<", ">>", "::" };
    while (true) {
        const t = s.next();
        var k: TokKind = switch (t.kind) {
            .word => .word,
            .quoted => .quoted,
            .string => .string,
            .number => .number,
            .punct => .punct,
            .eof => .eof,
        };
        var end = t.end;
        if (k == .punct) {
            for (ops) |o| if (std.mem.startsWith(u8, z[t.start..], o)) {
                end = t.start + o.len;
                s.i = end;
                break;
            };
        }
        // X'..': a BLOB.
        if (k == .word and t.text.len == 1 and (t.text[0] == 'x' or t.text[0] == 'X') and t.end < z.len and z[t.end] == '\'') {
            const x = s.next();
            k = .blob;
            end = x.end;
        }
        try out.append(a, .{ .kind = k, .text = z[t.start..end], .start = t.start, .end = end });
        if (k == .eof) break;
    }
    return out.items;
}

// =============================================================== parser

const Parser = struct {
    a: Allocator,
    z: []const u8,
    toks: []Tok,
    i: usize = 0,

    fn init(a: Allocator, z: []const u8) Error!Parser {
        return .{ .a = a, .z = z, .toks = try tokenize(a, z) };
    }

    fn peek(p: *Parser) Tok {
        return p.toks[p.i];
    }

    fn peekAt(p: *Parser, k: usize) Tok {
        return p.toks[@min(p.i + k, p.toks.len - 1)];
    }

    fn atEnd(p: *Parser) bool {
        return p.peek().kind == .eof;
    }

    fn isWord(t: Tok, w: []const u8) bool {
        return t.kind == .word and ieql(t.text, w);
    }

    fn isPunct(t: Tok, w: []const u8) bool {
        return t.kind == .punct and eql(t.text, w);
    }

    fn word(p: *Parser, w: []const u8) bool {
        if (!isWord(p.peek(), w)) return false;
        p.i += 1;
        return true;
    }

    fn punct(p: *Parser, w: []const u8) bool {
        if (!isPunct(p.peek(), w)) return false;
        p.i += 1;
        return true;
    }

    fn expect(p: *Parser, w: []const u8) Error!void {
        if (!p.punct(w)) return error.Unsupported;
    }

    fn expectWord(p: *Parser, w: []const u8) Error!void {
        if (!p.word(w)) return error.Unsupported;
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const x = try p.a.create(Node);
        x.* = n;
        return x;
    }

    fn list(p: *Parser, xs: []const *Node) Error![]*Node {
        return p.a.dupe(*Node, xs);
    }

    fn ident(p: *Parser) Error![]const u8 {
        const t = p.peek();
        if (t.kind != .word and t.kind != .quoted) return error.Unsupported;
        p.i += 1;
        return identText(p.a, t);
    }

    fn expr(p: *Parser) Error!*Node {
        return p.orExpr();
    }

    fn orExpr(p: *Parser) Error!*Node {
        var l = try p.andExpr();
        while (p.word("OR")) {
            const r = try p.andExpr();
            l = try p.flatten(.or_, l, r);
        }
        return l;
    }

    fn andExpr(p: *Parser) Error!*Node {
        var l = try p.notExpr();
        while (p.word("AND")) {
            const r = try p.notExpr();
            l = try p.flatten(.and_, l, r);
        }
        return l;
    }

    /// `a AND b AND c` (or `(a AND b) AND c`) is one AND of three in
    /// PostgreSQL's grammar (makeAndExpr()); `a AND (b AND c)` is not.
    fn flatten(p: *Parser, k: Kind, l: *Node, r: *Node) Error!*Node {
        if (l.kind == k) {
            var xs: std.ArrayList(*Node) = .empty;
            try xs.appendSlice(p.a, l.args);
            try xs.append(p.a, r);
            l.args = xs.items;
            return l;
        }
        return p.node(.{ .kind = k, .args = try p.list(&.{ l, r }) });
    }

    fn notExpr(p: *Parser) Error!*Node {
        if (isWord(p.peek(), "NOT") and !isWord(p.peekAt(1), "EXISTS")) {
            p.i += 1;
            const x = try p.notExpr();
            return p.node(.{ .kind = .not, .args = try p.list(&.{x}) });
        }
        return p.cmpExpr();
    }

    fn cmpExpr(p: *Parser) Error!*Node {
        var l = try p.relExpr();
        while (true) {
            const t = p.peek();
            if (isPunct(t, "=") or isPunct(t, "==") or isPunct(t, "!=") or isPunct(t, "<>")) {
                p.i += 1;
                const r = try p.relExpr();
                const op: []const u8 = if (t.text[0] == '=') "=" else "<>";
                l = try p.node(.{ .kind = .op, .text = op, .args = try p.list(&.{ l, r }) });
                continue;
            }
            if (isWord(t, "ISNULL") or isWord(t, "NOTNULL")) {
                p.i += 1;
                l = try p.node(.{ .kind = if (isWord(t, "ISNULL")) .isnull else .notnull, .args = try p.list(&.{l}) });
                continue;
            }
            if (isWord(t, "IS")) {
                p.i += 1;
                const not = p.word("NOT");
                if (p.word("NULL")) {
                    l = try p.node(.{ .kind = if (not) .notnull else .isnull, .args = try p.list(&.{l}) });
                    continue;
                }
                if (p.word("DISTINCT")) {
                    try p.expectWord("FROM");
                    const r = try p.relExpr();
                    l = try p.node(.{ .kind = .distinct, .flag = not, .args = try p.list(&.{ l, r }) });
                    continue;
                }
                const r = try p.relExpr();
                // SQLite's IS: IS NOT DISTINCT FROM.
                l = try p.node(.{ .kind = .distinct, .flag = !not, .args = try p.list(&.{ l, r }) });
                continue;
            }
            var not = false;
            if (isWord(t, "NOT")) {
                const n1 = p.peekAt(1);
                if (isWord(n1, "NULL")) {
                    p.i += 2;
                    l = try p.node(.{ .kind = .notnull, .args = try p.list(&.{l}) });
                    continue;
                }
                if (!(isWord(n1, "IN") or isWord(n1, "LIKE") or isWord(n1, "BETWEEN") or isWord(n1, "GLOB"))) return l;
                p.i += 1;
                not = true;
            }
            const u = p.peek();
            if (isWord(u, "IN")) {
                p.i += 1;
                try p.expect("(");
                const t2 = p.peek();
                if (isWord(t2, "SELECT") or isWord(t2, "WITH") or isWord(t2, "VALUES")) return error.Unsupported;
                var xs: std.ArrayList(*Node) = .empty;
                try xs.append(p.a, l);
                if (!p.punct(")")) {
                    while (true) {
                        try xs.append(p.a, try p.expr());
                        if (p.punct(")")) break;
                        try p.expect(",");
                    }
                }
                l = try p.node(.{ .kind = .in_, .flag = not, .args = xs.items });
                continue;
            }
            if (isWord(u, "LIKE") or isWord(u, "GLOB")) {
                p.i += 1;
                const r = try p.relExpr();
                var xs: std.ArrayList(*Node) = .empty;
                try xs.appendSlice(p.a, &.{ l, r });
                if (p.word("ESCAPE")) try xs.append(p.a, try p.relExpr());
                l = try p.node(.{ .kind = .like, .flag = not, .text = if (isWord(u, "GLOB")) "GLOB" else "LIKE", .args = xs.items });
                continue;
            }
            if (isWord(u, "BETWEEN")) {
                p.i += 1;
                const lo = try p.relExpr();
                try p.expectWord("AND");
                const hi = try p.relExpr();
                l = try p.node(.{ .kind = .between, .flag = not, .args = try p.list(&.{ l, lo, hi }) });
                continue;
            }
            return l;
        }
    }

    fn binary(p: *Parser, comptime next: fn (*Parser) Error!*Node, ops: []const []const u8) Error!*Node {
        var l = try next(p);
        loop: while (true) {
            const t = p.peek();
            for (ops) |o| if (isPunct(t, o)) {
                p.i += 1;
                const r = try next(p);
                l = try p.node(.{ .kind = .op, .text = o, .args = try p.list(&.{ l, r }) });
                continue :loop;
            };
            return l;
        }
    }

    fn relExpr(p: *Parser) Error!*Node {
        return p.binary(bitExpr, &.{ "<", "<=", ">", ">=" });
    }

    fn bitExpr(p: *Parser) Error!*Node {
        return p.binary(addExpr, &.{ "&", "|", "<<", ">>" });
    }

    fn addExpr(p: *Parser) Error!*Node {
        return p.binary(mulExpr, &.{ "+", "-" });
    }

    fn mulExpr(p: *Parser) Error!*Node {
        return p.binary(concatExpr, &.{ "*", "/", "%" });
    }

    fn concatExpr(p: *Parser) Error!*Node {
        return p.binary(unary, &.{ "||", "->", "->>" });
    }

    fn unary(p: *Parser) Error!*Node {
        const t = p.peek();
        if (isPunct(t, "-") or isPunct(t, "+") or isPunct(t, "~")) {
            p.i += 1;
            const x = try p.unary();
            if (t.text[0] == '+') return x;
            return p.node(.{ .kind = .prefix, .text = t.text, .args = try p.list(&.{x}) });
        }
        var x = try p.primary();
        while (p.word("COLLATE")) {
            const c = try p.ident();
            // The engine's collations (xq_pg_array ...) are no
            // PostgreSQL's.
            if (std.ascii.startsWithIgnoreCase(c, "xq_")) continue;
            x = try p.node(.{ .kind = .collate, .text = c, .args = try p.list(&.{x}) });
        }
        return x;
    }

    fn primary(p: *Parser) Error!*Node {
        const t = p.peek();
        switch (t.kind) {
            .number => {
                p.i += 1;
                const is_int = std.mem.indexOfAny(u8, t.text, ".eE") == null;
                if (std.ascii.startsWithIgnoreCase(t.text, "0x")) return error.Unsupported;
                return p.node(.{ .kind = if (is_int) .int else .num, .text = t.text });
            },
            .string => {
                p.i += 1;
                return p.node(.{ .kind = .str, .text = try stringValue(p.a, t.text) });
            },
            .blob => return error.Unsupported,
            .punct => {
                if (isPunct(t, "(")) {
                    p.i += 1;
                    const t2 = p.peek();
                    if (isWord(t2, "SELECT") or isWord(t2, "WITH") or isWord(t2, "VALUES")) return error.Unsupported;
                    const x = try p.expr();
                    if (p.punct(")")) return x;
                    var xs: std.ArrayList(*Node) = .empty;
                    try xs.append(p.a, x);
                    while (p.punct(",")) try xs.append(p.a, try p.expr());
                    try p.expect(")");
                    return p.node(.{ .kind = .row, .args = xs.items });
                }
                if (isPunct(t, "*")) {
                    p.i += 1;
                    return p.node(.{ .kind = .star });
                }
                return error.Unsupported;
            },
            .word, .quoted => {},
            .eof => return error.Unsupported,
        }
        if (t.kind == .word) {
            if (ieql(t.text, "NULL")) {
                p.i += 1;
                return p.node(.{ .kind = .null_ });
            }
            if (ieql(t.text, "TRUE") or ieql(t.text, "FALSE")) {
                p.i += 1;
                return p.node(.{ .kind = .bool_, .text = if (ieql(t.text, "TRUE")) "true" else "false" });
            }
            if (ieql(t.text, "CURRENT_TIMESTAMP") or ieql(t.text, "CURRENT_DATE") or ieql(t.text, "CURRENT_TIME")) {
                p.i += 1;
                return p.node(.{ .kind = .raw, .text = try std.ascii.allocUpperString(p.a, t.text), .ty = if (ieql(t.text, "CURRENT_DATE")) "date" else if (ieql(t.text, "CURRENT_TIME")) "time with time zone" else "timestamp with time zone" });
            }
            if (ieql(t.text, "EXISTS") or ieql(t.text, "SELECT") or ieql(t.text, "RAISE")) return error.Unsupported;
            if (ieql(t.text, "CAST") and isPunct(p.peekAt(1), "(")) {
                p.i += 2;
                const x = try p.expr();
                try p.expectWord("AS");
                const start = p.peek().start;
                var end = start;
                var depth: usize = 0;
                while (true) {
                    const u = p.peek();
                    if (u.kind == .eof) return error.Unsupported;
                    if (isPunct(u, "(")) depth += 1;
                    if (isPunct(u, ")")) {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    end = u.end;
                    p.i += 1;
                }
                p.i += 1;
                return p.node(.{ .kind = .cast, .text = try sqliteType(p.a, p.z[start..end]), .args = try p.list(&.{x}) });
            }
            if (ieql(t.text, "CASE")) {
                p.i += 1;
                var xs: std.ArrayList(*Node) = .empty;
                var n: Node = .{ .kind = .case_ };
                if (!isWord(p.peek(), "WHEN")) {
                    n.base = true;
                    try xs.append(p.a, try p.expr());
                }
                while (p.word("WHEN")) {
                    try xs.append(p.a, try p.expr());
                    try p.expectWord("THEN");
                    try xs.append(p.a, try p.expr());
                }
                if (p.word("ELSE")) {
                    n.has_else = true;
                    try xs.append(p.a, try p.expr());
                }
                try p.expectWord("END");
                n.args = xs.items;
                return p.node(n);
            }
        }
        // A name: a column (qualified) or a function's.
        const name = try p.ident();
        if (isPunct(p.peek(), "(")) {
            p.i += 1;
            var n: Node = .{ .kind = .func, .text = name };
            var xs: std.ArrayList(*Node) = .empty;
            if (p.punct("*")) {
                try xs.append(p.a, try p.node(.{ .kind = .star }));
                try p.expect(")");
            } else if (!p.punct(")")) {
                if (p.word("DISTINCT")) n.flag = true;
                while (true) {
                    try xs.append(p.a, try p.expr());
                    if (p.punct(")")) break;
                    try p.expect(",");
                }
            }
            if (isWord(p.peek(), "FILTER") or isWord(p.peek(), "OVER")) return error.Unsupported;
            n.args = xs.items;
            return p.node(n);
        }
        if (p.punct(".")) {
            if (p.punct("*")) return p.node(.{ .kind = .star, .qual = name });
            const col = try p.ident();
            if (p.punct(".")) {
                // schema.table.column: the table's.
                const c2 = try p.ident();
                return p.node(.{ .kind = .col, .qual = col, .text = c2 });
            }
            return p.node(.{ .kind = .col, .qual = name, .text = col });
        }
        return p.node(.{ .kind = .col, .text = name });
    }
};

fn identText(a: Allocator, t: Tok) Oom![]const u8 {
    if (t.kind != .quoted) return t.text;
    const q = t.text[0];
    const close: u8 = if (q == '[') ']' else q;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < t.text.len) : (i += 1) {
        if (t.text[i] == close and i + 2 < t.text.len and t.text[i + 1] == close) i += 1;
        try out.append(a, t.text[i]);
    }
    return out.items;
}

fn stringValue(a: Allocator, z: []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < z.len) : (i += 1) {
        if (z[i] == '\'' and i + 2 < z.len and z[i + 1] == '\'') i += 1;
        try out.append(a, z[i]);
    }
    return out.items;
}

/// PostgreSQL's type of a SQLite CAST's.
fn sqliteType(a: Allocator, z: []const u8) Oom![]const u8 {
    const t = std.mem.trim(u8, z, " ");
    const map = [_]struct { []const u8, []const u8 }{
        .{ "TEXT", "text" },  .{ "INTEGER", "bigint" },  .{ "INT", "integer" },     .{ "REAL", "double precision" },
        .{ "BLOB", "bytea" }, .{ "NUMERIC", "numeric" }, .{ "BOOLEAN", "boolean" },
    };
    for (map) |m| if (ieql(t, m[0])) return m[1];
    return std.ascii.allocLowerString(a, t);
}

// ================================================================ types

const T = struct {
    const int2 = "smallint";
    const int4 = "integer";
    const int8 = "bigint";
    const numeric = "numeric";
    const float8 = "double precision";
    const float4 = "real";
    const text = "text";
    const varchar = "character varying";
    const bpchar = "character";
    const boolean = "boolean";
    const interval = "interval";
    const uuid = "uuid";
    const jsonb = "jsonb";
    const json = "json";
    const date = "date";
    const ts = "timestamp without time zone";
    const tstz = "timestamp with time zone";
};

const Cat = enum { unknown, int, numeric, float, string, other };

fn cat(ty: []const u8) Cat {
    if (ty.len == 0) return .unknown;
    if (eql(ty, T.int2) or eql(ty, T.int4) or eql(ty, T.int8)) return .int;
    if (eql(ty, T.numeric)) return .numeric;
    if (eql(ty, T.float8) or eql(ty, T.float4)) return .float;
    if (eql(ty, T.text) or eql(ty, T.varchar) or eql(ty, T.bpchar) or eql(ty, "name")) return .string;
    return .other;
}

fn intRank(ty: []const u8) u8 {
    if (eql(ty, T.int2)) return 0;
    if (eql(ty, T.int4)) return 1;
    return 2;
}

fn isArray(ty: []const u8) bool {
    return std.mem.endsWith(u8, ty, "[]");
}

/// The type a column of `oid` shows (format_type() without its typmod).
fn typeName(oid: u32) []const u8 {
    if (pgc.builtinType(oid)) |t| return t.fmt;
    return T.text;
}

// =============================================================== fixing

/// The engine's calls made PostgreSQL's operators, its constants typed and
/// its implicit casts added.
const Fixer = struct {
    a: Allocator,
    scope: Scope,

    fn node(f: *Fixer, n: Node) Error!*Node {
        const x = try f.a.create(Node);
        x.* = n;
        return x;
    }

    fn list(f: *Fixer, xs: []const *Node) Error![]*Node {
        return f.a.dupe(*Node, xs);
    }

    fn colType(f: *Fixer, n: *const Node) []const u8 {
        for (f.scope.items) |it| {
            if (n.qual) |q| if (!ieql(q, it.name)) continue;
            for (it.attrs) |at| if (ieql(at.name, n.text)) return typeName(at.type_oid);
        }
        return "";
    }

    fn fix(f: *Fixer, n: *Node) Error!*Node {
        switch (n.kind) {
            .col => {
                n.ty = f.colType(n);
                if (n.ty.len == 0) n.ty = T.text;
                return n;
            },
            .int => {
                const v = std.fmt.parseInt(i64, n.text, 10) catch return error.Unsupported;
                n.ty = if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) T.int4 else T.int8;
                return n;
            },
            .num => {
                n.ty = T.numeric;
                return n;
            },
            .str, .null_, .star => return n,
            .bool_ => {
                n.ty = T.boolean;
                return n;
            },
            .raw => return n,
            .prefix => {
                const x = try f.fix(n.args[0]);
                if (eql(n.text, "-") and (x.kind == .int or x.kind == .num) and x.text[0] != '-') {
                    x.text = try std.fmt.allocPrint(f.a, "-{s}", .{x.text});
                    return f.fix(x);
                }
                n.args[0] = x;
                n.ty = x.ty;
                return n;
            },
            .op => {
                n.args[0] = try f.fix(n.args[0]);
                n.args[1] = try f.fix(n.args[1]);
                return f.binop(n);
            },
            .and_, .or_ => {
                for (n.args) |*x| x.* = try f.boolArg(try f.fix(x.*));
                n.ty = T.boolean;
                return n;
            },
            .not => {
                const x = try f.boolArg(try f.fix(n.args[0]));
                // NOT (a ~~ b): a !~~ b.
                if (x.kind == .op) {
                    const neg = [_]struct { []const u8, []const u8 }{ .{ "~~", "!~~" }, .{ "~~*", "!~~*" }, .{ "~", "!~" }, .{ "~*", "!~*" } };
                    for (neg) |m| if (eql(x.text, m[0])) {
                        x.text = m[1];
                        return x;
                    };
                }
                n.args[0] = x;
                n.ty = T.boolean;
                return n;
            },
            .isnull, .notnull => {
                n.args[0] = try f.fix(n.args[0]);
                n.ty = T.boolean;
                return n;
            },
            .distinct => {
                n.args[0] = try f.fix(n.args[0]);
                n.args[1] = try f.fix(n.args[1]);
                _ = try f.common(n.args, false);
                n.ty = T.boolean;
                if (n.flag) {
                    n.flag = false;
                    return f.node(.{ .kind = .not, .ty = T.boolean, .args = try f.list(&.{n}) });
                }
                return n;
            },
            .func => {
                for (n.args) |*x| x.* = try f.fix(x.*);
                return f.call(n);
            },
            .cast => {
                const x = try f.fix(n.args[0]);
                return f.castTo(x, n.text, true);
            },
            .case_ => {
                for (n.args) |*x| x.* = try f.fix(x.*);
                var results: std.ArrayList(*Node) = .empty;
                const start: usize = if (n.base) 1 else 0;
                var i = start;
                while (i + 1 < n.args.len) : (i += 2) {
                    if (!n.base) n.args[i] = try f.boolArg(n.args[i]);
                    try results.append(f.a, n.args[i + 1]);
                }
                if (n.has_else) try results.append(f.a, n.args[n.args.len - 1]);
                const ty = try f.common(results.items, true);
                // The results, put back.
                var k: usize = 0;
                i = start;
                while (i + 1 < n.args.len) : (i += 2) {
                    n.args[i + 1] = results.items[k];
                    k += 1;
                }
                if (n.has_else) n.args[n.args.len - 1] = results.items[k];
                n.ty = ty;
                return n;
            },
            .collate => {
                n.args[0] = try f.fix(n.args[0]);
                n.ty = n.args[0].ty;
                return n;
            },
            .row => {
                for (n.args) |*x| x.* = try f.fix(x.*);
                n.ty = "record";
                return n;
            },
            .in_ => {
                // x IN (a, b): x = ANY (ARRAY[a, b]); a list of one: x = a.
                for (n.args) |*x| x.* = try f.fix(x.*);
                const x = n.args[0];
                if (n.args.len == 2) {
                    const e = try f.binop(try f.node(.{ .kind = .op, .text = if (n.flag) "<>" else "=", .args = try f.list(&.{ x, n.args[1] }) }));
                    return e;
                }
                _ = try f.common(n.args, true);
                const elems = try f.list(n.args[1..]);
                const arr = try f.node(.{ .kind = .array, .args = elems, .ty = try std.fmt.allocPrint(f.a, "{s}[]", .{n.args[0].ty}) });
                return f.node(.{ .kind = .any, .text = if (n.flag) "<>" else "=", .flag = n.flag, .args = try f.list(&.{ n.args[0], arr }), .ty = T.boolean });
            },
            .between => {
                // PostgreSQL 18 makes x BETWEEN a AND b (x >= a AND x <= b).
                for (n.args) |*x| x.* = try f.fix(x.*);
                const x = n.args[0];
                const lo = try f.binop(try f.node(.{ .kind = .op, .text = if (n.flag) "<" else ">=", .args = try f.list(&.{ x, n.args[1] }) }));
                const x2 = try f.node(x.*);
                const hi = try f.binop(try f.node(.{ .kind = .op, .text = if (n.flag) ">" else "<=", .args = try f.list(&.{ x2, n.args[2] }) }));
                return f.node(.{ .kind = if (n.flag) .or_ else .and_, .args = try f.list(&.{ lo, hi }), .ty = T.boolean });
            },
            .like => {
                if (eql(n.text, "GLOB") or n.args.len > 2) return error.Unsupported;
                const l = try f.fix(n.args[0]);
                const r = try f.fix(n.args[1]);
                return f.binop(try f.node(.{ .kind = .op, .text = if (n.flag) "!~~" else "~~", .args = try f.list(&.{ l, r }) }));
            },
            .array, .any, .subscript => return n,
        }
    }

    /// An operand of AND, OR, NOT, WHEN: a boolean (a SQLite 0 or 1 is
    /// one of the engine's).
    fn boolArg(f: *Fixer, x: *Node) Error!*Node {
        _ = f;
        if (x.kind == .str and x.ty.len == 0) x.ty = T.boolean;
        return x;
    }

    /// Unknown constants given type `ty` (their text as the type's
    /// output), others cast to it.
    fn coerce(f: *Fixer, x: *Node, ty: []const u8) Error!*Node {
        if (eql(x.ty, ty) or ty.len == 0) return x;
        if (x.kind == .str and x.ty.len == 0) {
            try f.typeConst(x, ty);
            return x;
        }
        if (x.kind == .null_) {
            x.ty = ty;
            return x;
        }
        return f.castTo(x, ty, false);
    }

    /// String constant `x` made a constant of type `ty`, as PostgreSQL
    /// reads it when it parses the expression ('5'::integer: 5).
    fn typeConst(f: *Fixer, x: *Node, ty: []const u8) Error!void {
        x.ty = ty;
        if (integer.Width.named(ty)) |w| {
            const v = integer.parse(x.text, w) catch return;
            x.kind = .int;
            x.text = try std.fmt.allocPrint(f.a, "{d}", .{v});
            return;
        }
        x.text = try normalize(f.a, x.text, ty);
        if (eql(ty, T.boolean)) boolConst(x);
    }

    fn castTo(f: *Fixer, x: *Node, ty: []const u8, explicit: bool) Error!*Node {
        if (x.kind == .str and x.ty.len == 0) {
            // A constant cast is the constant of the type.
            try f.typeConst(x, ty);
            return x;
        }
        if (eql(x.ty, ty) and !explicit) return x;
        const xc = cat(x.ty);
        const tc = cat(ty);
        const func_cast = (xc == .int or xc == .numeric or xc == .float) and (tc == .int or tc == .numeric or tc == .float);
        return f.node(.{ .kind = .cast, .text = ty, .ty = ty, .args = try f.list(&.{x}), .func_cast = func_cast });
    }

    /// The type of `xs` together (PostgreSQL's select_common_type()):
    /// unknown constants given it, the others cast to it if `cast`.
    fn common(f: *Fixer, xs: []*Node, cast: bool) Error![]const u8 {
        var ty: []const u8 = "";
        for (xs) |x| {
            if (x.ty.len == 0 or x.kind == .null_) continue;
            if (ty.len == 0) {
                ty = x.ty;
                continue;
            }
            const a = cat(ty);
            const b = cat(x.ty);
            if (a == .int and b == .int) {
                if (intRank(x.ty) > intRank(ty)) ty = x.ty;
            } else if ((a == .int and b == .numeric) or (a == .numeric and b == .int)) {
                ty = T.numeric;
            } else if ((a == .int or a == .numeric) and b == .float) {
                ty = T.float8;
            } else if (a == .string and b == .string and !eql(ty, x.ty)) {
                ty = T.text;
            }
        }
        if (ty.len == 0) ty = T.text;
        for (xs) |*x| {
            if (x.*.ty.len == 0) {
                x.* = try f.coerce(x.*, ty);
            } else if (cast and !eql(x.*.ty, ty)) {
                x.* = try f.coerce(x.*, ty);
            }
        }
        return ty;
    }

    /// The type an unknown constant takes against an operand of `ty`.
    fn labelFor(ty: []const u8) []const u8 {
        if (eql(ty, T.varchar)) return T.text;
        if (eql(ty, T.bpchar)) return "bpchar";
        return ty;
    }

    /// A varchar (or char against text) operand of a text operator.
    fn textArg(f: *Fixer, x: *Node) Error!*Node {
        if (x.kind == .str and x.ty.len == 0) return f.coerce(x, T.text);
        if (eql(x.ty, T.varchar) or eql(x.ty, T.bpchar) or eql(x.ty, "name")) return f.castTo(x, T.text, false);
        return x;
    }

    fn binop(f: *Fixer, n: *Node) Error!*Node {
        const op = n.text;
        var l = n.args[0];
        var r = n.args[1];
        const cmp = eql(op, "=") or eql(op, "<>") or eql(op, "<") or eql(op, "<=") or eql(op, ">") or eql(op, ">=");
        const arith = eql(op, "+") or eql(op, "-") or eql(op, "*") or eql(op, "/") or eql(op, "%");
        if (eql(op, "||")) {
            if (isArray(l.ty) or isArray(r.ty)) {
                n.ty = if (isArray(l.ty)) l.ty else r.ty;
                return n;
            }
            n.args[0] = try f.textArg(l);
            n.args[1] = try f.textArg(r);
            n.ty = T.text;
            return n;
        }
        if (eql(op, "~~") or eql(op, "!~~") or eql(op, "~~*") or eql(op, "!~~*") or eql(op, "~") or eql(op, "~*") or eql(op, "!~") or eql(op, "!~*")) {
            n.args[0] = if (eql(l.ty, T.bpchar)) l else try f.textArg(l);
            n.args[1] = try f.textArg(r);
            n.ty = T.boolean;
            return n;
        }
        if (!cmp and !arith) {
            n.ty = l.ty;
            return n;
        }
        const lc = cat(l.ty);
        const rc = cat(r.ty);
        var ty: []const u8 = l.ty;
        if (lc == .unknown and rc == .unknown) {
            l = try f.coerce(l, T.text);
            r = try f.coerce(r, T.text);
            ty = T.text;
        } else if (lc == .unknown) {
            if (eql(r.ty, T.varchar)) r = try f.castTo(r, T.text, false);
            l = try f.coerce(l, labelFor(r.ty));
            ty = r.ty;
        } else if (rc == .unknown) {
            if (eql(l.ty, T.varchar)) l = try f.castTo(l, T.text, false);
            r = try f.coerce(r, labelFor(l.ty));
            ty = l.ty;
        } else if (lc == .int and rc == .int) {
            ty = if (intRank(r.ty) > intRank(l.ty)) r.ty else l.ty;
        } else if ((lc == .int or lc == .numeric) and (rc == .int or rc == .numeric)) {
            l = try f.coerce(l, T.numeric);
            r = try f.coerce(r, T.numeric);
            ty = T.numeric;
        } else if ((lc == .int or lc == .numeric or lc == .float) and (rc == .int or rc == .numeric or rc == .float)) {
            l = try f.coerce(l, T.float8);
            r = try f.coerce(r, T.float8);
            ty = T.float8;
        } else if (lc == .string and rc == .string) {
            if (!(eql(l.ty, T.bpchar) and eql(r.ty, T.bpchar))) {
                l = try f.textArg(l);
                r = try f.textArg(r);
            }
            ty = T.text;
        } else if (eql(l.ty, T.interval) and (rc == .int or rc == .numeric) and (eql(op, "*") or eql(op, "/"))) {
            r = try f.coerce(r, T.float8);
            ty = T.interval;
        } else if (eql(r.ty, T.interval) and (lc == .int or lc == .numeric) and eql(op, "*")) {
            l = try f.coerce(l, T.float8);
            ty = T.interval;
        } else if (eql(l.ty, T.date) and lc != rc and rc == .int) {
            ty = T.date;
        } else if (eql(l.ty, T.date) and eql(r.ty, T.date) and eql(op, "-")) {
            ty = T.int4;
        } else if ((eql(l.ty, T.ts) or eql(l.ty, T.tstz)) and eql(r.ty, l.ty) and eql(op, "-")) {
            ty = T.interval;
        }
        n.args[0] = l;
        n.args[1] = r;
        n.ty = if (cmp) T.boolean else ty;
        return n;
    }

    /// A call: an engine function made what PostgreSQL wrote, another one
    /// typed.
    fn call(f: *Fixer, n: *Node) Error!*Node {
        const name = n.text;
        const args = n.args;
        if (std.ascii.startsWithIgnoreCase(name, "xq_postgres_")) {
            n.text = name["xq_postgres_".len..];
            return f.plainCall(n);
        }
        if (!std.ascii.startsWithIgnoreCase(name, "xq_")) return f.plainCall(n);
        const lname = try std.ascii.allocLowerString(f.a, name);
        // Wrappers the engine compares, orders or keeps a column's scale
        // by: the value.
        const keys = [_]struct { []const u8, []const u8 }{
            .{ "xq_dec_key", T.numeric },    .{ "xq_dec", T.numeric },         .{ "xq_dec_text", T.numeric },
            .{ "xq_pg_iv_key", T.interval }, .{ "xq_pg_iv_high", T.interval }, .{ "xq_pg_iv_text", T.interval },
            .{ "xq_pg_jsonb_key", T.jsonb }, .{ "xq_pg_jsonb_bin", T.jsonb },  .{ "xq_pg_jsonb_text", T.jsonb },
            .{ "xq_pg_uuid_text", T.uuid },
        };
        for (keys) |k| if (eql(lname, k[0]) and args.len >= 1) return f.asType(args[0], k[1]);
        // Casts.
        const casts = [_]struct { []const u8, []const u8 }{
            .{ "xq_pg_int2", T.int2 },                   .{ "xq_pg_int4", T.int4 },            .{ "xq_pg_int8", T.int8 },
            .{ "xq_dec_int2", T.int2 },                  .{ "xq_dec_int4", T.int4 },           .{ "xq_dec_int8", T.int8 },
            .{ "xq_dec_float4", T.float4 },              .{ "xq_dec_float8", T.float8 },       .{ "xq_pg_bool", T.boolean },
            .{ "xq_pg_date", T.date },                   .{ "xq_pg_timestamp", T.ts },         .{ "xq_pg_timestamptz", T.tstz },
            .{ "xq_pg_time", "time without time zone" }, .{ "xq_pg_interval", T.interval },    .{ "xq_pg_iv", T.interval },
            .{ "xq_pg_uuid", T.uuid },                   .{ "xq_pg_jsonb", T.jsonb },          .{ "xq_pg_json", T.json },
            .{ "xq_dec_number", T.numeric },
            // integer.zig's.
                        .{ integer.castName(.int2), T.int2 }, .{ integer.castName(.int4), T.int4 },
            .{ integer.castName(.int8), T.int8 },
        };
        // An interval's input with its type modifier (ivinput.zig, a
        // cast or DEFAULT of interval(p) / interval year to month ...):
        // its constant as the modifier keeps it, else a cast.
        if (eql(lname, "xq_pg_iv_in") and args.len == 2 and args[1].kind == .int) {
            const x = args[0];
            const tm = std.fmt.parseInt(i32, args[1].text, 10) catch return error.Unsupported;
            if (x.kind == .str and x.ty.len == 0) {
                const iv = ivinput.decode(x.text, tm) catch return f.castTo(x, T.interval, true);
                var buf: datetime.Buf = undefined;
                x.text = try f.a.dupe(u8, datetime.formatIntervalPg(iv, &buf));
                x.ty = T.interval;
                return x;
            }
            return f.castTo(x, T.interval, true);
        }
        for (casts) |c| if (eql(lname, c[0]) and args.len == 1) {
            const x = args[0];
            if (x.kind == .str and x.ty.len == 0) return f.castTo(x, c[1], true);
            if (eql(c[1], T.numeric) and (x.kind == .int or x.kind == .num)) return f.asType(x, c[1]);
            return f.castTo(x, c[1], true);
        };
        // numeric's operators and functions.
        const dec_ops = [_]struct { []const u8, []const u8 }{ .{ "xq_dec_add", "+" }, .{ "xq_dec_sub", "-" }, .{ "xq_dec_mul", "*" }, .{ "xq_dec_div", "/" }, .{ "xq_dec_mod", "%" } };
        for (dec_ops) |o| if (eql(lname, o[0]) and args.len == 2) {
            const l = try f.asType(args[0], T.numeric);
            const r = try f.asType(args[1], T.numeric);
            return f.node(.{ .kind = .op, .text = o[1], .args = try f.list(&.{ l, r }), .ty = T.numeric });
        };
        if (eql(lname, "xq_dec_neg") and args.len == 1) {
            return f.node(.{ .kind = .prefix, .text = "-", .args = try f.list(&.{try f.asType(args[0], T.numeric)}), .ty = T.numeric });
        }
        if (std.mem.startsWith(u8, lname, "xq_dec_")) {
            const fname = lname["xq_dec_".len..];
            const known = [_][]const u8{ "round", "trunc", "abs", "floor", "ceil", "sign", "scale", "min_scale", "trim_scale", "sum", "avg", "sqrt", "exp", "ln", "power", "mod", "div_trunc" };
            for (known) |k| if (eql(fname, k)) {
                if (args.len >= 1) args[0] = try f.asType(args[0], T.numeric);
                n.text = if (eql(k, "div_trunc")) "div" else k;
                n.ty = if (eql(k, "scale") or eql(k, "min_scale")) T.int4 else T.numeric;
                return n;
            };
            return error.Unsupported;
        }
        // interval's.
        if (std.mem.startsWith(u8, lname, "xq_pg_iv_") or std.mem.startsWith(u8, lname, "xq_pg_date_") or eql(lname, "xq_pg_integer_pl_date")) {
            return f.datetimeOp(n, lname);
        }
        // jsonb's and json's operators.
        const json_ops = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            // name, operator, the right operand's type, the result's
            .{ "xq_pg_jsonb_get", "->", T.text, T.jsonb },
            .{ "xq_pg_jsonb_get_text", "->>", T.text, T.text },
            .{ "xq_pg_jsonb_path", "#>", "text[]", T.jsonb },
            .{ "xq_pg_jsonb_path_text", "#>>", "text[]", T.text },
            .{ "xq_pg_jsonb_contains", "@>", T.jsonb, T.boolean },
            .{ "xq_pg_jsonb_exists", "?", T.text, T.boolean },
            .{ "xq_pg_jsonb_exists_any", "?|", "text[]", T.boolean },
            .{ "xq_pg_jsonb_exists_all", "?&", "text[]", T.boolean },
            .{ "xq_pg_jsonb_concat", "||", T.jsonb, T.jsonb },
            .{ "xq_pg_jsonb_delete", "-", T.text, T.jsonb },
            .{ "xq_pg_jsonb_delete_keys", "-", "text[]", T.jsonb },
            .{ "xq_pg_jsonb_delete_path", "#-", "text[]", T.jsonb },
            .{ "xq_pg_jsonb_path_exists_op", "@?", "jsonpath", T.boolean },
            .{ "xq_pg_jsonb_path_match_op", "@@", "jsonpath", T.boolean },
            .{ "xq_pg_json_get", "->", T.text, T.json },
            .{ "xq_pg_json_get_text", "->>", T.text, T.text },
            .{ "xq_pg_json_path", "#>", "text[]", T.json },
            .{ "xq_pg_json_path_text", "#>>", "text[]", T.text },
            .{ "xq_pg_array_contains", "@>", "", T.boolean },
            .{ "xq_pg_array_overlap", "&&", "", T.boolean },
            .{ "xq_pg_array_cat2", "||", "", "" },
            .{ "xq_pg_array_append", "||", "", "" },
            .{ "xq_pg_array_prepend", "||", "", "" },
        };
        for (json_ops) |o| if (eql(lname, o[0]) and args.len == 2) {
            var l = args[0];
            var r = args[1];
            const json_l = std.mem.startsWith(u8, lname, "xq_pg_json");
            if (json_l) {
                l = try f.asType(l, if (std.mem.startsWith(u8, lname, "xq_pg_jsonb")) T.jsonb else T.json);
                if (r.kind == .str and r.ty.len == 0) r = try f.coerce(r, o[2]);
            } else {
                if (r.kind == .str and r.ty.len == 0) r = try f.coerce(r, l.ty);
                if (l.kind == .str and l.ty.len == 0) l = try f.coerce(l, r.ty);
            }
            const ty = if (o[3].len > 0) o[3] else if (isArray(l.ty)) l.ty else r.ty;
            return f.node(.{ .kind = .op, .text = o[1], .args = try f.list(&.{ l, r }), .ty = ty });
        };
        if (eql(lname, "xq_pg_array")) {
            const ty = try f.common(args, true);
            return f.node(.{ .kind = .array, .args = args, .ty = try std.fmt.allocPrint(f.a, "{s}[]", .{ty}) });
        }
        if (std.mem.startsWith(u8, lname, "xq_pg_array_") and args.len == 1 and args[0].kind == .str) {
            const tname = lname["xq_pg_array_".len..];
            for (pgc.builtin_types) |bt| if (eql(bt.name, tname) and bt.array != 0) {
                return f.castTo(args[0], try std.fmt.allocPrint(f.a, "{s}[]", .{bt.fmt}), true);
            };
            return error.Unsupported;
        }
        if ((eql(lname, "xq_pg_subscript") or eql(lname, "xq_pg_subscript_k")) and args.len >= 2) {
            const arr = args[0];
            const ty = if (isArray(arr.ty)) arr.ty[0 .. arr.ty.len - 2] else "";
            return f.node(.{ .kind = .subscript, .args = try f.list(&.{ arr, args[1] }), .ty = ty });
        }
        if (eql(lname, "xq_pg_any") and args.len >= 4 and args[2].kind == .int and args[3].kind == .int) {
            const ops = [_][]const u8{ "=", "<>", "<", "<=", ">", ">=", "~~", "!~~", "~~*", "!~~*" };
            const code = std.fmt.parseInt(usize, args[2].text, 10) catch return error.Unsupported;
            if (code >= ops.len) return error.Unsupported;
            var x = args[0];
            const arr = args[1];
            const ety = if (isArray(arr.ty)) arr.ty[0 .. arr.ty.len - 2] else "";
            if (x.kind == .str and x.ty.len == 0 and ety.len > 0) x = try f.coerce(x, labelFor(ety));
            return f.node(.{ .kind = .any, .text = ops[code], .flag = !eql(args[3].text, "0"), .args = try f.list(&.{ x, arr }), .ty = T.boolean });
        }
        if (eql(lname, "xq_pg_regex") and args.len == 3 and args[2].kind == .str) {
            const flags = args[2].text;
            const op: []const u8 = if (flags.len == 0) "~" else if (eql(flags, "i")) "~*" else return error.Unsupported;
            return f.binop(try f.node(.{ .kind = .op, .text = op, .args = try f.list(&.{ args[0], args[1] }) }));
        }
        if ((eql(lname, "xq_like") or eql(lname, "xq_ilike")) and args.len == 2) {
            const op: []const u8 = if (eql(lname, "xq_like")) "~~" else "~~*";
            return f.binop(try f.node(.{ .kind = .op, .text = op, .args = try f.list(&.{ args[1], args[0] }) }));
        }
        return f.operatorCall(n, lname);
    }

    /// The function of a row of operators.zig's table (xq_pg_int_xor(a,
    /// b): a # b), that operator; error.Unsupported for another call.
    fn operatorCall(f: *Fixer, n: *Node, lname: []const u8) Error!*Node {
        const args = n.args;
        // The row of the operands' types, else the first of the function
        // (xq_pg_int_xor() has one per integer type).
        var row: ?*const operators.Entry = null;
        for (&operators.entries) |*e| {
            const name = e.func orelse continue;
            if (!eql(lname, name) or e.args.len != args.len) continue;
            if (row == null) row = e;
            for (e.args, args) |t, x| {
                if (!eql(t.name(), x.ty)) break;
            } else {
                row = e;
                break;
            }
        }
        const e = row orelse return error.Unsupported;
        var xs: [2]*Node = undefined;
        for (e.args, args, 0..) |t, x, i| xs[i] = if (t == .text_array) x else try f.asType(x, t.name());
        const ty = e.result.name();
        if (args.len == 1) return f.node(.{ .kind = .prefix, .text = e.op.text(), .args = try f.list(xs[0..1]), .ty = ty });
        return f.node(.{ .kind = .op, .text = e.op.text(), .args = try f.list(xs[0..2]), .ty = ty });
    }

    /// The datetime operators of the engine (xq_pg_iv_interval_pl(a, b):
    /// a + b ...).
    fn datetimeOp(f: *Fixer, n: *Node, lname: []const u8) Error!*Node {
        const args = n.args;
        const Op = struct { []const u8, []const u8, []const u8, []const u8, []const u8 };
        // name, operator, left type, right type ("" as it is), result ("" the left's)
        const ops = [_]Op{
            .{ "xq_pg_iv_interval_pl", "+", T.interval, T.interval, T.interval },
            .{ "xq_pg_iv_interval_mi", "-", T.interval, T.interval, T.interval },
            .{ "xq_pg_iv_interval_mul", "*", T.interval, T.float8, T.interval },
            .{ "xq_pg_iv_interval_div", "/", T.interval, T.float8, T.interval },
            .{ "xq_pg_iv_mul_d_interval", "*", T.float8, T.interval, T.interval },
            .{ "xq_pg_iv_timestamp_pl_interval", "+", "", T.interval, "" },
            .{ "xq_pg_iv_timestamptz_pl_interval", "+", "", T.interval, "" },
            .{ "xq_pg_iv_time_pl_interval", "+", "", T.interval, "" },
            .{ "xq_pg_iv_timestamp_mi_interval", "-", "", T.interval, "" },
            .{ "xq_pg_iv_timestamptz_mi_interval", "-", "", T.interval, "" },
            .{ "xq_pg_iv_time_mi_interval", "-", "", T.interval, "" },
            .{ "xq_pg_iv_interval_pl_timestamp", "+", T.interval, "", "" },
            .{ "xq_pg_iv_timestamp_mi", "-", "", "", T.interval },
            .{ "xq_pg_iv_timestamptz_mi", "-", "", "", T.interval },
            .{ "xq_pg_date_pli", "+", "", "", T.date },
            .{ "xq_pg_date_mii", "-", "", "", T.date },
            .{ "xq_pg_date_mi", "-", "", "", T.int4 },
            .{ "xq_pg_integer_pl_date", "+", "", "", T.date },
        };
        for (ops) |o| if (eql(lname, o[0]) and args.len == 2) {
            const l = if (o[2].len > 0) try f.asType(args[0], o[2]) else args[0];
            const r = if (o[3].len > 0) try f.asType(args[1], o[3]) else args[1];
            const ty = if (o[4].len > 0) o[4] else if (o[2].len > 0 and !eql(o[2], T.interval)) o[2] else if (eql(l.ty, T.interval)) r.ty else l.ty;
            return f.node(.{ .kind = .op, .text = o[1], .args = try f.list(&.{ l, r }), .ty = ty });
        };
        if (eql(lname, "xq_pg_iv_interval_um") and args.len == 1) {
            return f.node(.{ .kind = .prefix, .text = "-", .args = try f.list(&.{try f.asType(args[0], T.interval)}), .ty = T.interval });
        }
        if ((eql(lname, "xq_pg_iv_sum") or eql(lname, "xq_pg_iv_avg")) and args.len == 1) {
            n.text = lname["xq_pg_iv_".len..];
            n.ty = T.interval;
            return n;
        }
        return f.operatorCall(n, lname);
    }

    /// `x` as a value of type `ty`: an integer constant cast to it (0 of
    /// xq_dec_key(0): (0)::numeric), a decimal one PostgreSQL's numeric
    /// constant, a string the type's constant.
    fn asType(f: *Fixer, x: *Node, ty: []const u8) Error!*Node {
        if (eql(x.ty, ty)) return x;
        if (eql(ty, T.numeric)) {
            if (x.kind == .str and x.ty.len == 0) {
                // xq_dec_key('1.5'): the constant 1.5.
                const z = x.text;
                const isnum = z.len > 0 and for (z) |c| {
                    if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == 'e' or c == 'E' or c == '+')) break false;
                } else true;
                if (isnum and std.mem.indexOfScalar(u8, z, '.') != null) {
                    x.kind = .num;
                    x.ty = T.numeric;
                    return x;
                }
                if (isnum) {
                    x.kind = .int;
                    return f.coerce(try f.fix(x), ty);
                }
            }
            if (x.kind == .num) return x;
        }
        if (x.ty.len == 0 or cat(x.ty) != .other or x.kind == .int or x.kind == .num) return f.coerce(x, ty);
        return x;
    }

    /// A call of no engine function: its name as PostgreSQL prints it,
    /// its type, text functions' arguments text.
    fn plainCall(f: *Fixer, n: *Node) Error!*Node {
        const lname = try std.ascii.allocLowerString(f.a, n.text);
        n.text = lname;
        const text_funcs = [_][]const u8{ "upper", "lower", "btrim", "ltrim", "rtrim", "substr", "substring", "replace", "left", "right", "md5", "repeat", "reverse", "initcap", "lpad", "rpad", "translate", "split_part", "quote_ident", "quote_literal", "to_tsvector" };
        const int_text_funcs = [_][]const u8{ "length", "char_length", "character_length", "octet_length", "bit_length", "strpos", "ascii" };
        const int_funcs = [_][]const u8{ "cardinality", "array_length", "array_ndims", "array_position", "array_upper", "array_lower" };
        const keyword_funcs = [_][]const u8{ "coalesce", "nullif", "greatest", "least" };
        for (keyword_funcs) |k| if (eql(lname, k)) {
            n.text = try std.ascii.allocUpperString(f.a, lname);
            n.ty = try f.common(n.args, eql(lname, "coalesce") or eql(lname, "greatest") or eql(lname, "least"));
            if (eql(lname, "nullif")) n.ty = n.args[0].ty;
            return n;
        };
        for (text_funcs) |k| if (eql(lname, k)) {
            for (n.args, 0..) |*x, i| if (i == 0 or x.*.kind == .str) {
                x.* = try f.textArg(x.*);
            };
            n.ty = T.text;
            return n;
        };
        for (int_text_funcs) |k| if (eql(lname, k)) {
            for (n.args) |*x| x.* = try f.textArg(x.*);
            n.ty = T.int4;
            return n;
        };
        for (int_funcs) |k| if (eql(lname, k)) {
            n.ty = T.int4;
            return n;
        };
        if (eql(lname, "count")) {
            n.ty = T.int8;
            return n;
        }
        if (eql(lname, "now") or eql(lname, "statement_timestamp") or eql(lname, "transaction_timestamp") or eql(lname, "clock_timestamp")) {
            n.ty = T.tstz;
            return n;
        }
        if (eql(lname, "concat") or eql(lname, "concat_ws") or eql(lname, "format") or eql(lname, "to_char")) {
            for (n.args) |*x| if (x.*.kind == .str and x.*.ty.len == 0) {
                x.* = try f.coerce(x.*, T.text);
            };
            n.ty = T.text;
            return n;
        }
        if (n.args.len > 0) {
            const a0 = n.args[0];
            if (eql(lname, "sum") and cat(a0.ty) == .int) {
                n.ty = if (eql(a0.ty, T.int8)) T.numeric else T.int8;
                return n;
            }
            if (eql(lname, "avg") and (cat(a0.ty) == .int or cat(a0.ty) == .numeric)) {
                n.ty = T.numeric;
                return n;
            }
            n.ty = a0.ty;
        }
        if (n.ty.len == 0) n.ty = T.text;
        return n;
    }
};

/// A string constant of a boolean: PostgreSQL's constant true or false.
fn boolConst(x: *Node) void {
    const yes = [_][]const u8{ "t", "true", "y", "yes", "on", "1" };
    const no = [_][]const u8{ "f", "false", "n", "no", "off", "0" };
    const z = std.mem.trim(u8, x.text, " ");
    for (yes) |w| if (ieql(z, w)) {
        x.kind = .bool_;
        x.text = "true";
    };
    for (no) |w| if (ieql(z, w)) {
        x.kind = .bool_;
        x.text = "false";
    };
}

/// The text of an unknown constant `z` taken as type `ty`, as its type's
/// output writes it ('1 hour' as an interval: '01:00:00').
fn normalize(a: Allocator, z: []const u8, ty: []const u8) Oom![]const u8 {
    if (eql(ty, T.interval)) {
        const iv = ivinput.decode(z, -1) catch return z;
        var buf: datetime.Buf = undefined;
        return a.dupe(u8, datetime.formatIntervalPg(iv, &buf));
    }
    if (eql(ty, T.ts)) {
        const t = datetime.parseTimestamp(z, false) catch return z;
        var buf: datetime.Buf = undefined;
        return a.dupe(u8, datetime.formatTimestamp(t, &buf));
    }
    if (eql(ty, T.date)) {
        const d = datetime.parseDate(z) catch return z;
        var buf: datetime.Buf = undefined;
        return a.dupe(u8, datetime.formatDate(d, &buf));
    }
    if (eql(ty, T.jsonb)) {
        const v = json.parseJsonb(a, z) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else z;
        return json.toText(a, v, true) catch |e| if (e == error.OutOfMemory) error.OutOfMemory else z;
    }
    if (eql(ty, T.uuid)) {
        const b = uuid_mod.parse(z) orelse return z;
        const t = uuid_mod.format(&b);
        return a.dupe(u8, &t);
    }
    return z;
}

// ============================================================= printing

const Printer = struct {
    a: Allocator,
    pretty: bool,
    scope: Scope,
    out: std.ArrayList(u8) = .empty,
    indent: i32 = 0,

    fn put(pr: *Printer, z: []const u8) Error!void {
        try pr.out.appendSlice(pr.a, z);
    }

    fn print(pr: *Printer, comptime fmt: []const u8, args: anytype) Error!void {
        try pr.out.print(pr.a, fmt, args);
    }

    /// ruleutils.c's appendContextKeyword(): a new line at the indent
    /// (the spaces before it removed).
    fn keyword(pr: *Printer, z: []const u8, before: i32, after: i32, plus: i32) Error!void {
        pr.indent += before;
        while (pr.out.items.len > 0 and pr.out.items[pr.out.items.len - 1] == ' ') pr.out.items.len -= 1;
        try pr.out.append(pr.a, '\n');
        try pr.out.appendNTimes(pr.a, ' ', @intCast(@max(pr.indent, 0) + plus));
        try pr.put(z);
        pr.indent += after;
        if (pr.indent < 0) pr.indent = 0;
    }

    fn quoted(pr: *Printer, z: []const u8) Error!void {
        try pr.put(try pgc.quoteIdent(pr.a, z));
    }

    /// `n` under `parent`, in parentheses if pretty mode needs them
    /// (get_rule_expr_paren()).
    fn sub(pr: *Printer, n: *const Node, parent: *const Node) Error!void {
        if (pr.pretty and !simple(n, parent)) {
            try pr.put("(");
            try pr.expr(n);
            return pr.put(")");
        }
        return pr.expr(n);
    }

    fn open(pr: *Printer) Error!void {
        if (!pr.pretty) try pr.put("(");
    }

    fn close(pr: *Printer) Error!void {
        if (!pr.pretty) try pr.put(")");
    }

    fn expr(pr: *Printer, n: *const Node) Error!void {
        switch (n.kind) {
            .col => {
                if (pr.scope.qualify) if (n.qual) |q| {
                    for (pr.scope.items) |it| {
                        if (ieql(it.name, q)) break try pr.quoted(if (it.label.len > 0) it.label else q);
                    } else try pr.quoted(q);
                    try pr.put(".");
                } else for (pr.scope.items) |it| {
                    for (it.attrs) |at| if (ieql(at.name, n.text)) {
                        try pr.quoted(if (it.label.len > 0) it.label else it.name);
                        try pr.put(".");
                        break;
                    };
                };
                try pr.quoted(n.text);
            },
            .int => {
                if (eql(n.ty, T.int4) and n.text[0] != '-') return pr.put(n.text);
                try pr.print("'{s}'::{s}", .{ n.text, n.ty });
            },
            .num => {
                if (std.ascii.isDigit(n.text[0])) return pr.put(n.text);
                try pr.print("'{s}'::numeric", .{n.text});
            },
            .str => {
                try pr.literal(n.text);
                if (n.ty.len > 0) try pr.print("::{s}", .{if (eql(n.ty, T.bpchar)) "bpchar" else n.ty});
            },
            .null_ => {
                try pr.put("NULL");
                if (n.ty.len > 0) try pr.print("::{s}", .{n.ty});
            },
            .bool_ => try pr.put(n.text),
            .raw => try pr.put(n.text),
            .star => {
                if (n.qual) |q| {
                    try pr.quoted(q);
                    try pr.put(".");
                }
                try pr.put("*");
            },
            .op => {
                try pr.open();
                try pr.sub(n.args[0], n);
                try pr.print(" {s} ", .{n.text});
                try pr.sub(n.args[1], n);
                try pr.close();
            },
            .prefix => {
                try pr.open();
                try pr.print("{s} ", .{n.text});
                try pr.sub(n.args[0], n);
                try pr.close();
            },
            .and_, .or_ => {
                try pr.open();
                for (n.args, 0..) |x, i| {
                    if (i > 0) try pr.put(if (n.kind == .and_) " AND " else " OR ");
                    try pr.sub(x, n);
                }
                try pr.close();
            },
            .not => {
                try pr.open();
                try pr.put("NOT ");
                try pr.sub(n.args[0], n);
                try pr.close();
            },
            .isnull, .notnull => {
                try pr.open();
                try pr.sub(n.args[0], n);
                try pr.put(if (n.kind == .isnull) " IS NULL" else " IS NOT NULL");
                try pr.close();
            },
            .distinct => {
                try pr.open();
                try pr.sub(n.args[0], n);
                try pr.put(" IS DISTINCT FROM ");
                try pr.sub(n.args[1], n);
                try pr.close();
            },
            .func => {
                try pr.put(n.text);
                try pr.put("(");
                if (n.flag) try pr.put("DISTINCT ");
                for (n.args, 0..) |x, i| {
                    if (i > 0) try pr.put(", ");
                    try pr.expr(x);
                }
                try pr.put(")");
            },
            .cast => {
                const x = n.args[0];
                if (n.hidden) return if (pr.pretty) pr.sub(x, n) else pr.expr(x);
                if (pr.pretty) {
                    try pr.sub(x, n);
                } else {
                    try pr.put("(");
                    try pr.expr(x);
                    try pr.put(")");
                }
                try pr.print("::{s}", .{n.text});
            },
            .case_ => {
                try pr.keyword("CASE", 0, 4, 0);
                var i: usize = 0;
                if (n.base) {
                    try pr.put(" ");
                    try pr.expr(n.args[0]);
                    i = 1;
                }
                const end = if (n.has_else) n.args.len - 1 else n.args.len;
                while (i + 1 < end + 1 and i < end) : (i += 2) {
                    try pr.keyword("WHEN ", 0, 0, 0);
                    try pr.expr(n.args[i]);
                    try pr.put(" THEN ");
                    try pr.expr(n.args[i + 1]);
                }
                if (n.has_else) {
                    try pr.keyword("ELSE ", 0, 0, 0);
                    try pr.expr(n.args[n.args.len - 1]);
                }
                try pr.keyword("END", -4, 0, 0);
            },
            .array => {
                try pr.put("ARRAY[");
                for (n.args, 0..) |x, i| {
                    if (i > 0) try pr.put(", ");
                    try pr.expr(x);
                }
                try pr.put("]");
            },
            .any => {
                try pr.open();
                try pr.sub(n.args[0], n);
                try pr.print(" {s} {s} (", .{ n.text, if (n.flag) "ALL" else "ANY" });
                try pr.sub(n.args[1], n);
                try pr.put(")");
                try pr.close();
            },
            .subscript => {
                const arr = n.args[0];
                const paren = arr.kind != .col;
                if (paren) try pr.put("(");
                try pr.sub(arr, n);
                if (paren) try pr.put(")");
                try pr.put("[");
                try pr.expr(n.args[1]);
                try pr.put("]");
            },
            .collate => {
                try pr.open();
                try pr.sub(n.args[0], n);
                try pr.put(" COLLATE ");
                try pr.quoted(n.text);
                try pr.close();
            },
            .row => {
                try pr.put("ROW(");
                for (n.args, 0..) |x, i| {
                    if (i > 0) try pr.put(", ");
                    try pr.expr(x);
                }
                try pr.put(")");
            },
            .in_, .between, .like => return error.Unsupported,
        }
    }

    /// A GROUP BY or ORDER BY term (get_rule_sortgroupclause()): a column
    /// as it is, a call in parentheses (it may look like GROUPING SETS),
    /// another in them in pretty mode.
    fn sortItem(pr: *Printer, n: *const Node) Error!void {
        if (n.kind == .col or !(pr.pretty or n.kind == .func)) return pr.expr(n);
        try pr.put("(");
        try pr.expr(n);
        try pr.put(")");
    }

    fn literal(pr: *Printer, z: []const u8) Error!void {
        const esc = std.mem.indexOfScalar(u8, z, '\\') != null;
        if (esc) try pr.put("E");
        try pr.put("'");
        for (z) |c| {
            if (c == '\'' or c == '\\') try pr.out.append(pr.a, c);
            try pr.out.append(pr.a, c);
        }
        try pr.put("'");
    }
};

fn arithOp(op: []const u8) ?enum { lo, hi } {
    if (op.len != 1) return null;
    return switch (op[0]) {
        '+', '-' => .lo,
        '*', '/', '%' => .hi,
        else => null,
    };
}

/// ruleutils.c's isSimpleNode(): whether `n` under `parent` needs no
/// parentheses in pretty mode.
fn simple(n: *const Node, parent: *const Node) bool {
    switch (n.kind) {
        .col, .int, .num, .str, .null_, .bool_, .raw, .star => return true,
        .func, .array, .subscript, .case_, .row => return true,
        .cast => return if (n.func_cast or n.hidden) true else simple(n.args[0], n),
        .op, .prefix => {
            if (parent.kind == .op) {
                if (n.kind == .prefix) return false;
                const o = arithOp(n.text) orelse return false;
                const po = arithOp(parent.text) orelse return false;
                if (o == .hi and po == .lo) return true;
                if (o == .lo and po == .hi) return false;
                return n == parent.args[0];
            }
            return otherParent(parent);
        },
        .isnull, .notnull, .distinct => return otherParent(parent),
        .and_, .or_, .not => {
            switch (parent.kind) {
                .and_, .or_, .not => {
                    if (n.kind == .not or n.kind == .and_) return parent.kind == .and_ or parent.kind == .or_;
                    return parent.kind == .or_;
                },
                .func => return true,
                .cast => return false,
                .subscript, .array, .row, .case_ => return true,
                else => return false,
            }
        },
        .any, .collate, .in_, .between, .like => return false,
    }
}

/// isSimpleNode() of an operator, a NULL test ... under another node.
fn otherParent(parent: *const Node) bool {
    return switch (parent.kind) {
        .func => true,
        .cast => false,
        .and_, .or_, .not, .subscript, .array, .row, .case_ => true,
        else => false,
    };
}

// ================================================================ views

/// A view's query as pg_get_viewdef() prints it (`pretty`: with
/// pretty-printing; the query is indented and wrapped in either), null
/// if it is beyond this module. `columns` are the view's column names;
/// `resolve` gives the relation of a FROM item: what to print for it and
/// its columns.
pub const Resolved = struct { shown: []const u8, attrs: []const pgc.Attr };

pub fn viewDef(
    a: Allocator,
    sql: []const u8,
    names: []const []const u8,
    ctx: anytype,
    comptime resolve: fn (@TypeOf(ctx), []const u8) Oom!?Resolved,
    pretty: bool,
) Oom!?[]const u8 {
    return viewDefErr(a, sql, names, ctx, resolve, pretty, null) catch |e| orNull(e);
}

/// The column of a table each result column of a view is, where it is
/// one (the type of the view's column is that column's), null where
/// it is beyond this module.
pub fn viewSources(
    a: Allocator,
    sql: []const u8,
    ctx: anytype,
    comptime resolve: fn (@TypeOf(ctx), []const u8) Oom!?Resolved,
) Oom!?[]const ?pgc.Attr {
    var out: std.ArrayList(?pgc.Attr) = .empty;
    _ = viewDefErr(a, sql, &.{}, ctx, resolve, false, &out) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
    return out.items;
}

const FromItem = struct {
    join: []const u8 = "",
    shown: []const u8,
    on: ?*Node = null,
    using: ?[]const []const u8 = null,
};

const OrderItem = struct { e: *Node, dir: []const u8 };

fn viewDefErr(
    a: Allocator,
    sql: []const u8,
    names: []const []const u8,
    ctx: anytype,
    comptime resolve: fn (@TypeOf(ctx), []const u8) Oom!?Resolved,
    pretty: bool,
    sources: ?*std.ArrayList(?pgc.Attr),
) Error!?[]const u8 {
    var p = try Parser.init(a, sql);
    // CREATE [TEMP] VIEW name [(cols)] AS
    while (!p.atEnd() and !Parser.isWord(p.peek(), "AS")) {
        if (Parser.isPunct(p.peek(), "(")) {
            var depth: usize = 0;
            while (!p.atEnd()) {
                if (Parser.isPunct(p.peek(), "(")) depth += 1;
                if (Parser.isPunct(p.peek(), ")")) {
                    depth -= 1;
                    if (depth == 0) {
                        p.i += 1;
                        break;
                    }
                }
                p.i += 1;
            }
            continue;
        }
        p.i += 1;
    }
    try p.expectWord("AS");
    try p.expectWord("SELECT");
    const distinct = p.word("DISTINCT");
    _ = p.word("ALL");
    // The result columns.
    var targets: std.ArrayList(*Node) = .empty;
    while (true) {
        const e = try p.expr();
        if (p.word("AS")) {
            _ = try p.ident();
        } else if (p.peek().kind == .quoted or (p.peek().kind == .word and !isClause(p.peek()))) {
            _ = try p.ident();
        }
        try targets.append(a, e);
        if (!p.punct(",")) break;
    }
    // FROM.
    var items: std.ArrayList(Item) = .empty;
    var from: std.ArrayList(FromItem) = .empty;
    if (p.word("FROM")) {
        var join: []const u8 = "";
        while (true) {
            if (Parser.isPunct(p.peek(), "(")) return error.Unsupported;
            const name = try p.ident();
            var shown_name = name;
            if (p.punct(".")) shown_name = try p.ident();
            var alias: ?[]const u8 = null;
            if (p.word("AS")) {
                alias = try p.ident();
            } else if (p.peek().kind == .quoted or (p.peek().kind == .word and !isClause(p.peek()) and !isJoinWord(p.peek()))) {
                alias = try p.ident();
            }
            if (Parser.isPunct(p.peek(), "(")) return error.Unsupported;
            const r = try resolve(ctx, shown_name) orelse return error.Unsupported;
            var shown: std.ArrayList(u8) = .empty;
            try shown.appendSlice(a, r.shown);
            const bare = if (std.mem.lastIndexOfScalar(u8, shown_name, '.')) |dot| shown_name[dot + 1 ..] else shown_name;
            if (alias) |al| if (!eql(al, bare)) {
                try shown.append(a, ' ');
                try shown.appendSlice(a, try pgc.quoteIdent(a, al));
            };
            try items.append(a, .{ .name = alias orelse shown_name, .label = alias orelse bare, .attrs = r.attrs });
            var fi: FromItem = .{ .join = join, .shown = shown.items };
            if (join.len > 0) {
                if (p.word("ON")) {
                    fi.on = try p.expr();
                } else if (p.word("USING")) {
                    try p.expect("(");
                    var cols: std.ArrayList([]const u8) = .empty;
                    while (true) {
                        try cols.append(a, try p.ident());
                        if (p.punct(")")) break;
                        try p.expect(",");
                    }
                    fi.using = cols.items;
                }
            }
            try from.append(a, fi);
            // The next item's join.
            if (p.punct(",")) {
                join = ",";
                continue;
            }
            const t = p.peek();
            if (Parser.isWord(t, "NATURAL")) return error.Unsupported;
            if (isJoinWord(t)) {
                var kind: []const u8 = "JOIN";
                if (p.word("LEFT")) kind = "LEFT JOIN" else if (p.word("RIGHT")) kind = "RIGHT JOIN" else if (p.word("FULL")) kind = "FULL JOIN" else if (p.word("CROSS")) kind = "CROSS JOIN" else _ = p.word("INNER");
                _ = p.word("OUTER");
                try p.expectWord("JOIN");
                join = kind;
                continue;
            }
            break;
        }
    }
    const scope: Scope = .{ .items = items.items, .qualify = items.items.len > 1 };
    var where: ?*Node = null;
    if (p.word("WHERE")) where = try p.expr();
    var group: std.ArrayList(*Node) = .empty;
    if (p.word("GROUP")) {
        try p.expectWord("BY");
        while (true) {
            try group.append(a, try p.expr());
            if (!p.punct(",")) break;
        }
    }
    var having: ?*Node = null;
    if (p.word("HAVING")) having = try p.expr();
    if (Parser.isWord(p.peek(), "WINDOW") or Parser.isWord(p.peek(), "UNION") or Parser.isWord(p.peek(), "EXCEPT") or Parser.isWord(p.peek(), "INTERSECT")) return error.Unsupported;
    var order: std.ArrayList(OrderItem) = .empty;
    if (p.word("ORDER")) {
        try p.expectWord("BY");
        while (true) {
            const e = try p.expr();
            const desc = p.word("DESC");
            if (!desc) _ = p.word("ASC");
            var nulls_first = desc;
            if (p.word("NULLS")) {
                if (p.word("FIRST")) nulls_first = true else {
                    try p.expectWord("LAST");
                    nulls_first = false;
                }
            }
            const dir: []const u8 = if (desc and nulls_first) " DESC" else if (desc) " DESC NULLS LAST" else if (nulls_first) " NULLS FIRST" else "";
            try order.append(a, .{ .e = e, .dir = dir });
            if (!p.punct(",")) break;
        }
    }
    var limit: ?*Node = null;
    var offset: ?*Node = null;
    if (p.word("LIMIT")) {
        limit = try p.expr();
        if (p.word("OFFSET")) offset = try p.expr() else if (p.punct(",")) {
            offset = limit;
            limit = try p.expr();
        }
    }
    _ = p.punct(";");
    if (!p.atEnd()) return error.Unsupported;

    var f: Fixer = .{ .a = a, .scope = scope };
    var pr: Printer = .{ .a = a, .pretty = pretty, .scope = scope };
    pr.indent += 8;
    try pr.put(" SELECT");
    if (distinct) try pr.put(" DISTINCT");
    // * and t.*: the columns.
    var exp: std.ArrayList(*Node) = .empty;
    for (targets.items) |t| {
        if (t.kind != .star) {
            try exp.append(a, t);
            continue;
        }
        for (items.items) |it| {
            if (t.qual) |q| if (!ieql(q, it.name)) continue;
            for (it.attrs) |at| try exp.append(a, try f.node(.{ .kind = .col, .qual = it.name, .text = at.name }));
        }
    }
    if (sources) |out| for (exp.items) |t0| {
        var src: ?pgc.Attr = null;
        if (t0.kind == .col) for (items.items) |it| {
            if (t0.qual) |q| if (!ieql(q, it.name)) continue;
            for (it.attrs) |at| if (ieql(at.name, t0.text)) {
                src = at;
                break;
            };
            if (src != null) break;
        };
        try out.append(a, src);
    };
    for (exp.items, 0..) |t0, i| {
        const t = try f.fix(t0);
        if (i == 0) try pr.put(" ") else {
            try pr.put(",");
            try pr.keyword("", -8, 8, 4);
        }
        // An unknown constant is text in a view's result.
        if (t.kind == .str and t.ty.len == 0) t.ty = T.text;
        try pr.expr(t);
        const name: []const u8 = if (i < names.len) names[i] else "?column?";
        if (!(t.kind == .col and eql(t.text, name))) {
            try pr.put(" AS ");
            try pr.quoted(name);
        }
    }
    if (from.items.len > 0) {
        try pr.keyword(" FROM ", -8, 8, 2);
        var joins: usize = 0;
        for (from.items) |fi| if (fi.join.len > 0 and !eql(fi.join, ",")) {
            joins += 1;
        };
        // Joins nest to the left: ((a JOIN b ON ...) JOIN c ON ...).
        if (!pr.pretty) try pr.out.appendNTimes(a, '(', joins);
        for (from.items) |fi| {
            if (eql(fi.join, ",")) {
                try pr.put(", ");
            } else if (fi.join.len > 0) {
                const kw = try std.fmt.allocPrint(a, " {s} ", .{if (eql(fi.join, "JOIN") and fi.on == null and fi.using == null) "CROSS JOIN" else fi.join});
                try pr.keyword(kw, -8, 8, 4);
            }
            try pr.put(fi.shown);
            if (fi.using) |cols| {
                try pr.put(" USING (");
                for (cols, 0..) |c, k| {
                    if (k > 0) try pr.put(", ");
                    try pr.quoted(c);
                }
                try pr.put(")");
            } else if (fi.on) |on| {
                try pr.put(" ON ");
                try pr.open();
                try pr.expr(try f.fix(on));
                try pr.close();
            } else if (fi.join.len > 0 and !eql(fi.join, ",") and !eql(fi.join, "JOIN") and !eql(fi.join, "CROSS JOIN")) {
                try pr.put(" ON TRUE");
            }
            if (fi.join.len > 0 and !eql(fi.join, ",") and !pr.pretty) try pr.put(")");
        }
    }
    if (where) |w| {
        try pr.keyword(" WHERE ", -8, 8, 1);
        try pr.expr(try f.fix(w));
    }
    if (group.items.len > 0) {
        try pr.keyword(" GROUP BY ", -8, 8, 1);
        for (group.items, 0..) |g, i| {
            if (i > 0) try pr.put(", ");
            try pr.sortItem(try f.fix(try position(&f, g, exp.items)));
        }
    }
    if (having) |h| {
        try pr.keyword(" HAVING ", -8, 8, 0);
        try pr.expr(try f.fix(h));
    }
    if (order.items.len > 0) {
        try pr.keyword(" ORDER BY ", -8, 8, 1);
        for (order.items, 0..) |o, i| {
            if (i > 0) try pr.put(", ");
            try pr.sortItem(try f.fix(try position(&f, o.e, exp.items)));
            try pr.put(o.dir);
        }
    }
    if (offset) |o| {
        try pr.keyword(" OFFSET ", -8, 8, 0);
        try pr.expr(try f.fix(o));
    }
    if (limit) |l| {
        try pr.keyword(" LIMIT ", -8, 8, 0);
        try pr.expr(try f.fix(l));
    }
    try pr.put(";");
    return pr.out.items;
}

/// A GROUP BY or ORDER BY term: a result column's number is that column
/// (PostgreSQL prints its expression).
fn position(f: *Fixer, n: *Node, targets: []const *Node) Error!*Node {
    if (n.kind != .int) return n;
    const k = std.fmt.parseInt(usize, n.text, 10) catch return n;
    if (k == 0 or k > targets.len) return n;
    return f.node(targets[k - 1].*);
}

fn isClause(t: Tok) bool {
    const words = [_][]const u8{ "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "WINDOW", "ON", "USING" };
    for (words) |w| if (Parser.isWord(t, w)) return true;
    return false;
}

fn isJoinWord(t: Tok) bool {
    const words = [_][]const u8{ "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL" };
    for (words) |w| if (Parser.isWord(t, w)) return true;
    return false;
}

test "deparse: numeric CHECK" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const attrs = [_]pgc.Attr{
        .{ .rel = 1, .name = "price", .num = 1, .type_oid = 1700 },
        .{ .rel = 1, .name = "v", .num = 2, .type_oid = 1043 },
        .{ .rel = 1, .name = "iv", .num = 3, .type_oid = 1186 },
    };
    const scope: Scope = .{ .items = &.{.{ .name = "t", .attrs = &attrs }} };
    const z = "(xq_dec_key(\"price\") >= xq_dec_key(0))";
    try std.testing.expectEqualStrings("(price >= (0)::numeric)", (try expr(a, z, scope, false)).?);
    try std.testing.expectEqualStrings("price >= 0::numeric", (try expr(a, z, scope, true)).?);
    const z2 = "(((\"v\" = 'x') OR (xq_like('a%', \"v\"))) AND (xq_pg_iv_key(\"iv\") > xq_pg_iv_key('1 hour')))";
    try std.testing.expectEqualStrings("((((v)::text = 'x'::text) OR ((v)::text ~~ 'a%'::text)) AND (iv > '01:00:00'::interval))", (try expr(a, z2, scope, false)).?);
    try std.testing.expectEqualStrings("(v::text = 'x'::text OR v::text ~~ 'a%'::text) AND iv > '01:00:00'::interval", (try expr(a, z2, scope, true)).?);
    try std.testing.expectEqualSlices(i16, &.{1}, try columns(a, z, scope));
}

const ivinput = @import("ivinput.zig");
