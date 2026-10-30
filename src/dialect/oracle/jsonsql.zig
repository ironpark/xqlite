//! Oracle's SQL/JSON syntax: the parser's side of jsonfuncs.zig.
//!
//!  - the functions JSON_VALUE, JSON_QUERY, JSON_EXISTS, JSON_OBJECT,
//!    JSON_ARRAY, JSON_OBJECTAGG, JSON_ARRAYAGG, JSON_MERGEPATCH,
//!    JSON_SERIALIZE, JSON_TRANSFORM, JSON and JSON_SCALAR, with their
//!    clauses (RETURNING, PASSING, ON ERROR/EMPTY, wrappers, ON NULL ...)
//!    as calls of the engine functions xq_ora_json_* whose options are
//!    string literals (call());
//!  - `x IS [NOT] JSON [STRICT|LAX] [WITH UNIQUE KEYS]` (isJson());
//!  - dot notation t.col.a.b[0].size() (dotExpr(), resolved after the
//!    statement is parsed: resolveDot());
//!  - JSON_TABLE in FROM (jsonTable()): the table-valued function
//!    xq_ora_json_table(doc, spec) whose columns c0, c1 ... the
//!    references to the JSON_TABLE's columns are rewritten to
//!    (rewriteCore()).
//!
//! The pass after parsing (from dates.zig, which keeps the scope of
//! tables) resolves what needs the FROM clause: dot notation (the alias
//! and whether the column is of type JSON), JSON_TABLE columns, JSON
//! type columns and dates given to the JSON constructors (JSON and ISO
//! 8601 text), JSON_OBJECT(*), and a number compared with JSON_VALUE's
//! text (Oracle converts the text).

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const build = @import("../../sql/build.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const J = @import("json.zig");
const jf = @import("jsonfuncs.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Name = tree.Name;
const Token = @import("lexer.zig").Token;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const function_names = [_][]const u8{
    "JSON_VALUE",  "JSON_QUERY",      "JSON_EXISTS",    "JSON_OBJECT",    "JSON_ARRAY", "JSON_OBJECTAGG",
    "JSON_ARRAYAGG", "JSON_MERGEPATCH", "JSON_SERIALIZE", "JSON_TRANSFORM", "JSON",       "JSON_SCALAR",
};

/// Whether `name(` is one of the SQL/JSON functions call() parses.
pub fn isFunction(name: []const u8) bool {
    for (function_names) |n| if (eq(n, name)) return true;
    return false;
}

/// A dot notation reference (t.col.a.b) before the FROM clause is known.
pub const Dot = struct {
    /// The names as written: alias, column, then the path's.
    names: []const Name,
    /// The path has more than member names (brackets, a method).
    complex: bool,
};

/// A JSON_TABLE in FROM: its label and columns (c0, c1 ...).
pub const Table = struct {
    label: []const u8,
    cols: []const Column,
};

pub const Column = struct {
    /// The column's name (folded as identifiers are).
    name: []const u8,
    index: usize,
    family: ?types.Family = null,
};

// ================================================================ calls

fn str(p: *Parser, pos: u32, s: []const u8) Error!*Expr {
    return p.stringAt(pos, s);
}

fn int(p: *Parser, pos: u32, v: i64) Error!*Expr {
    return tree.expr(p.arena, pos, pos, .{ .integer = try std.fmt.allocPrint(p.arena, "{d}", .{v}) });
}

fn nullLit(p: *Parser, pos: u32) Error!*Expr {
    return tree.expr(p.arena, pos, pos, .null);
}

/// The path literal of a JSON function, checked as Oracle checks it when
/// the statement is compiled.
fn pathLiteral(p: *Parser) Error![]const u8 {
    const t = p.peek();
    if (t.kind != .string) return p.missing("ORA-40597: JSON path expression syntax error");
    _ = p.advance();
    try checkPath(p, t.start, t.text);
    return t.text;
}

fn checkPath(p: *Parser, pos: u32, text: []const u8) Error!void {
    const s = std.mem.trimStart(u8, text, " \t\n\r");
    if (s.len == 0 or s[0] != '$') {
        if (std.ascii.startsWithIgnoreCase(s, "lax") or std.ascii.startsWithIgnoreCase(s, "strict")) {
            return p.fail(pos, "ORA-40442: JSON path expression syntax error ('{s}')", .{text});
        }
        return p.fail(pos, "ORA-40597: JSON path expression syntax error ('{s}')", .{text});
    }
    _ = J.parsePath(p.arena, text) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.BadPath => return p.fail(pos, "ORA-40442: JSON path expression syntax error ('{s}')", .{text}),
    };
}

/// `RETURNING type` (VARCHAR2 alone is VARCHAR2(4000)): the catalog
/// spelling.
fn returning(p: *Parser) Error![]const u8 {
    const t = p.peek();
    if ((t.isKw("varchar2") or t.isKw("varchar")) and p.peekAt(1).kind != .lparen) {
        _ = p.advance();
        return "VARCHAR2(4000)";
    }
    const ty = try p.typeName();
    return types.format(p.arena, ty);
}

/// `FORMAT JSON` after a value.
fn formatJson(p: *Parser) Error!bool {
    if (p.isKw("format") and p.isKwAt(1, "json")) {
        _ = p.advance();
        _ = p.advance();
        return true;
    }
    return false;
}

const HandlerKind = enum { on_error, on_empty, on_mismatch, on_null };

const Clause = struct {
    kind: HandlerKind,
    /// N, E, D, A (EMPTY [ARRAY]), O (EMPTY OBJECT), T, F, I(GNORE).
    code: u8,
    default: ?*Expr = null,
};

/// `ERROR|NULL|DEFAULT e|EMPTY [ARRAY|OBJECT]|TRUE|FALSE|IGNORE ON
/// ERROR|EMPTY|MISMATCH|NULL`, or null (nothing consumed).
fn handlerClause(p: *Parser) Error!?Clause {
    const t = p.peek();
    const save = p.i;
    var c: Clause = .{ .kind = .on_error, .code = 'N' };
    if (t.isKw("error")) {
        c.code = 'E';
        _ = p.advance();
    } else if (t.isKw("null")) {
        c.code = 'N';
        _ = p.advance();
    } else if (t.isKw("true")) {
        c.code = 'T';
        _ = p.advance();
    } else if (t.isKw("false")) {
        c.code = 'F';
        _ = p.advance();
    } else if (t.isKw("ignore")) {
        c.code = 'I';
        _ = p.advance();
    } else if (t.isKw("empty")) {
        _ = p.advance();
        c.code = 'A';
        if (p.eatKw("object")) {
            c.code = 'O';
        } else _ = p.eatKw("array");
    } else if (t.isKw("default")) {
        _ = p.advance();
        c.code = 'D';
        c.default = try p.addExpr();
    } else return null;
    if (!p.eatKw("on")) {
        p.i = save;
        return null;
    }
    if (p.eatKw("error")) {
        c.kind = .on_error;
    } else if (p.eatKw("empty")) {
        c.kind = .on_empty;
    } else if (p.eatKw("mismatch")) {
        c.kind = .on_mismatch;
    } else if (p.eatKw("null")) {
        c.kind = .on_null;
    } else return p.missing("ORA-00905: missing keyword");
    return c;
}

/// `PASSING e AS name, ...`: name, value argument pairs.
fn passingClause(p: *Parser, args: *std.ArrayList(*Expr)) Error!void {
    if (!p.eatKw("passing")) return;
    while (true) {
        const v = try p.addExpr();
        try p.expectKw("as");
        const n = try p.anyName();
        try args.append(p.arena, try str(p, n.pos, n.text));
        try args.append(p.arena, v);
        if (!p.eat(.comma)) break;
    }
}

/// A value given to a JSON constructor: FORMAT JSON makes it JSON, a
/// boolean literal is JSON true/false (marked for the pass after
/// parsing, which makes JSON columns JSON and dates ISO text).
fn ctorValue(p: *Parser) Error!*Expr {
    var v = try p.expr0();
    if (try formatJson(p)) {
        v = try p.call(v.pos, "xq_ora_json", null, &.{v});
    } else if (v.kind == .boolean) {
        v = try p.call(v.pos, "xq_ora_json", null, &.{try str(p, v.pos, if (v.kind.boolean) "true" else "false")});
    }
    try p.json_values.put(p.arena, v, {});
    return v;
}

fn optionsExpr(p: *Parser, pos: u32, fields: []const []const u8) Error!*Expr {
    return str(p, pos, try std.mem.join(p.arena, "|", fields));
}

fn finish(p: *Parser, pos: u32, name: []const u8, args: []const *Expr) Error!*Expr {
    _ = try p.expect(.rparen);
    const e = try p.call(pos, name, null, args);
    e.end = p.lastEnd();
    return e;
}

/// A call of an SQL/JSON function; `name` was read, `(` is next.
pub fn call(p: *Parser, pos: u32, name: Token) Error!*Expr {
    _ = try p.expect(.lparen);
    const n = name.text;
    if (eq(n, "JSON_VALUE")) return jsonValue(p, pos);
    if (eq(n, "JSON_QUERY")) return jsonQuery(p, pos);
    if (eq(n, "JSON_EXISTS")) return jsonExists(p, pos);
    if (eq(n, "JSON_OBJECT")) return jsonObject(p, pos);
    if (eq(n, "JSON_ARRAY")) return jsonArray(p, pos);
    if (eq(n, "JSON_OBJECTAGG")) return objectAgg(p, pos);
    if (eq(n, "JSON_ARRAYAGG")) return arrayAgg(p, pos);
    if (eq(n, "JSON_MERGEPATCH")) return mergePatch(p, pos);
    if (eq(n, "JSON_SERIALIZE")) return serialize(p, pos);
    if (eq(n, "JSON_TRANSFORM")) return transform(p, pos);
    // JSON(x), JSON_SCALAR(x)
    const x = try p.expr0();
    return finish(p, pos, if (eq(n, "JSON")) "xq_ora_json" else "xq_ora_json_scalar", &.{x});
}

/// The document argument: `expr [FORMAT JSON]`, the comma, the path.
fn docAndPath(p: *Parser) Error!struct { doc: *Expr, path: []const u8, path_pos: u32 } {
    const doc = try p.expr0();
    _ = try formatJson(p);
    _ = try p.expect(.comma);
    const pp = p.peek().start;
    const path = try pathLiteral(p);
    return .{ .doc = doc, .path = path, .path_pos = pp };
}

fn jsonValue(p: *Parser, pos: u32) Error!*Expr {
    const dp = try docAndPath(p);
    var vars: std.ArrayList(*Expr) = .empty;
    try passingClause(p, &vars);
    var ty: []const u8 = "";
    var truncate = false;
    var on_empty: []const u8 = "";
    var on_error: []const u8 = "";
    var def_empty = try nullLit(p, pos);
    var def_error = try nullLit(p, pos);
    while (true) {
        if (p.eatKw("returning")) {
            ty = try returning(p);
            if (p.eatKw("truncate")) truncate = true;
            continue;
        }
        if (p.eatKw("truncate")) {
            truncate = true;
            continue;
        }
        if (p.isKw("allow") or p.isKw("disallow")) {
            _ = p.advance();
            try p.expectKw("scalars");
            continue;
        }
        const c = (try handlerClause(p)) orelse break;
        const code = try p.arena.dupe(u8, &.{c.code});
        switch (c.kind) {
            .on_error => {
                on_error = code;
                if (c.default) |d| def_error = d;
            },
            .on_empty => {
                on_empty = code;
                if (c.default) |d| def_empty = d;
            },
            else => {},
        }
    }
    var args: std.ArrayList(*Expr) = .empty;
    try args.appendSlice(p.arena, &.{ dp.doc, try str(p, dp.path_pos, dp.path), try optionsExpr(p, pos, &.{ ty, on_empty, on_error, if (truncate) "T" else "" }), def_empty, def_error });
    try args.appendSlice(p.arena, vars.items);
    const e = try finish(p, pos, "xq_ora_json_value", args.items);
    try p.json_text_nodes.put(p.arena, e, {});
    return e;
}

/// WITH [CONDITIONAL|UNCONDITIONAL] [ARRAY] WRAPPER, WITHOUT [ARRAY]
/// WRAPPER: U, C or N; null if not one.
fn wrapperClause(p: *Parser) Error!?[]const u8 {
    if (p.isKw("with") and (p.isKwAt(1, "wrapper") or p.isKwAt(1, "array") or p.isKwAt(1, "conditional") or p.isKwAt(1, "unconditional"))) {
        _ = p.advance();
        var w: []const u8 = "U";
        if (p.eatKw("conditional")) {
            w = "C";
        } else _ = p.eatKw("unconditional");
        _ = p.eatKw("array");
        try p.expectKw("wrapper");
        return w;
    }
    if (p.isKw("without")) {
        _ = p.advance();
        _ = p.eatKw("array");
        try p.expectKw("wrapper");
        return "N";
    }
    return null;
}

fn jsonQuery(p: *Parser, pos: u32) Error!*Expr {
    const dp = try docAndPath(p);
    var vars: std.ArrayList(*Expr) = .empty;
    try passingClause(p, &vars);
    var ty: []const u8 = "";
    var on_empty: []const u8 = "";
    var on_error: []const u8 = "";
    var wrapper: []const u8 = "N";
    var pretty = false;
    var ascii = false;
    while (true) {
        if (p.eatKw("returning")) {
            ty = try returning(p);
            continue;
        }
        if (p.eatKw("pretty")) {
            pretty = true;
            continue;
        }
        if (p.eatKw("ascii")) {
            ascii = true;
            continue;
        }
        if (p.isKw("allow") or p.isKw("disallow")) {
            _ = p.advance();
            try p.expectKw("scalars");
            continue;
        }
        if (try wrapperClause(p)) |w| {
            wrapper = w;
            continue;
        }
        const c = (try handlerClause(p)) orelse break;
        if (c.code == 'D') return p.fail(pos, "ORA-40450: invalid ON ERROR clause", .{});
        const code = try p.arena.dupe(u8, &.{c.code});
        switch (c.kind) {
            .on_error => on_error = code,
            .on_empty => on_empty = code,
            else => {},
        }
    }
    var args: std.ArrayList(*Expr) = .empty;
    try args.appendSlice(p.arena, &.{ dp.doc, try str(p, dp.path_pos, dp.path), try optionsExpr(p, pos, &.{ ty, on_empty, on_error, wrapper, if (pretty) "P" else "", if (ascii) "A" else "" }) });
    try args.appendSlice(p.arena, vars.items);
    return finish(p, pos, "xq_ora_json_query", args.items);
}

fn jsonExists(p: *Parser, pos: u32) Error!*Expr {
    const dp = try docAndPath(p);
    var vars: std.ArrayList(*Expr) = .empty;
    try passingClause(p, &vars);
    var on_error: []const u8 = "F";
    while (try handlerClause(p)) |c| {
        if (c.kind == .on_error) on_error = try p.arena.dupe(u8, &.{c.code});
    }
    var args: std.ArrayList(*Expr) = .empty;
    try args.appendSlice(p.arena, &.{ dp.doc, try str(p, dp.path_pos, dp.path), try str(p, pos, on_error) });
    try args.appendSlice(p.arena, vars.items);
    return finish(p, pos, "xq_ora_json_exists", args.items);
}

/// The trailing clauses of the constructors: [NULL|ABSENT ON NULL]
/// [RETURNING type] [STRICT] [WITH UNIQUE KEYS]: the flags and the type.
const CtorOpts = struct { flags: i64, ty: []const u8 = "" };

fn ctorClauses(p: *Parser, null_on_null: bool) Error!CtorOpts {
    var o: CtorOpts = .{ .flags = 0 };
    var non = null_on_null;
    while (true) {
        if (p.isKw("null") and p.isKwAt(1, "on") and p.isKwAt(2, "null")) {
            p.i += 3;
            non = true;
        } else if (p.isKw("absent") and p.isKwAt(1, "on") and p.isKwAt(2, "null")) {
            p.i += 3;
            non = false;
        } else if (p.eatKw("returning")) {
            o.ty = try returning(p);
        } else if (p.eatKw("strict")) {} else if (p.isKw("with") and p.isKwAt(1, "unique")) {
            p.i += 2;
            try p.expectKw("keys");
            o.flags |= 4;
        } else if (p.isKw("without") and p.isKwAt(1, "unique")) {
            p.i += 2;
            try p.expectKw("keys");
        } else break;
    }
    o.flags |= if (non) 2 else 1;
    return o;
}

fn ctorOptions(p: *Parser, pos: u32, o: CtorOpts) Error!*Expr {
    return optionsExpr(p, pos, &.{ o.ty, try std.fmt.allocPrint(p.arena, "{d}", .{o.flags}) });
}

fn atCtorEnd(p: *Parser) bool {
    const t = p.peek();
    if (t.kind == .rparen) return true;
    if ((t.isKw("null") or t.isKw("absent")) and p.isKwAt(1, "on") and p.isKwAt(2, "null")) return true;
    return t.isKw("returning") or t.isKw("strict") or (t.isKw("with") and p.isKwAt(1, "unique")) or (t.isKw("without") and p.isKwAt(1, "unique"));
}

fn jsonObject(p: *Parser, pos: u32) Error!*Expr {
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(p.arena, undefined);
    var star = false;
    while (!atCtorEnd(p)) {
        if (p.peek().isOp("*")) {
            _ = p.advance();
            star = true;
        } else {
            const kw_key = p.eatKw("key");
            const kt = p.peek();
            const key = try p.addExpr();
            if (p.eatKw("value") or p.eatKw("is") or p.eatOp(":")) {
                try args.append(p.arena, key);
                try args.append(p.arena, try ctorValue(p));
            } else {
                // JSON_OBJECT(col): the column's name as written.
                if (kw_key or key.kind != .column) return p.missing("ORA-00905: missing keyword");
                const names = key.kind.column;
                const last = names[names.len - 1];
                const raw = rawName(p, last, kt);
                try args.append(p.arena, try str(p, key.pos, raw));
                try p.json_values.put(p.arena, key, {});
                try args.append(p.arena, key);
            }
        }
        if (!p.eat(.comma)) break;
    }
    const o = try ctorClauses(p, true);
    args.items[0] = try ctorOptions(p, pos, o);
    const e = try finish(p, pos, "xq_ora_json_object", args.items);
    if (star) try p.json_object_star.put(p.arena, e, {});
    return e;
}

/// The name `n` as written in the statement (unquoted names keep their
/// case: JSON_OBJECT(k) is {"k": ...}).
fn rawName(p: *Parser, n: Name, _: Token) []const u8 {
    if (n.pos < p.src.len and p.src[n.pos] == '"') return n.text;
    const end = @min(n.pos + n.text.len, p.src.len);
    return p.src[n.pos..end];
}

fn jsonArray(p: *Parser, pos: u32) Error!*Expr {
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(p.arena, undefined);
    while (!atCtorEnd(p)) {
        try args.append(p.arena, try ctorValue(p));
        if (!p.eat(.comma)) break;
    }
    const o = try ctorClauses(p, false);
    args.items[0] = try ctorOptions(p, pos, o);
    return finish(p, pos, "xq_ora_json_array", args.items);
}

fn arrayAgg(p: *Parser, pos: u32) Error!*Expr {
    const v = try ctorValue(p);
    var order: []tree.SortItem = &.{};
    if (p.isKw("order")) {
        _ = p.advance();
        try p.expectKw("by");
        order = try p.sortList();
    }
    const o = try ctorClauses(p, false);
    _ = try p.expect(.rparen);
    const f = try p.new(tree.Func, .{ .name = .{ .text = "xq_ora_json_arrayagg", .pos = pos }, .args = try p.list(&.{ try ctorOptions(p, pos, o), v }), .order_by = order });
    return p.expr(pos, .{ .func = f });
}

fn objectAgg(p: *Parser, pos: u32) Error!*Expr {
    _ = p.eatKw("key");
    const k = try p.addExpr();
    if (!(p.eatKw("value") or p.eatKw("is") or p.eatOp(":"))) return p.missing("ORA-00905: missing keyword");
    const v = try ctorValue(p);
    const o = try ctorClauses(p, true);
    return finish(p, pos, "xq_ora_json_objectagg", &.{ try ctorOptions(p, pos, o), k, v });
}

/// [RETURNING type] [PRETTY] [ASCII] [ORDERED] [TRUNCATE] [NULL|ERROR ON
/// ERROR]: "type|P|A|T|handler|O".
fn outputClauses(p: *Parser, pos: u32, default_error: []const u8) Error!*Expr {
    var f = [6][]const u8{ "", "", "", "", default_error, "" };
    while (true) {
        if (p.eatKw("returning")) {
            f[0] = try returning(p);
        } else if (p.eatKw("pretty")) {
            f[1] = "P";
        } else if (p.eatKw("ascii")) {
            f[2] = "A";
        } else if (p.eatKw("truncate")) {
            f[3] = "T";
        } else if (p.eatKw("ordered")) {
            f[5] = "O";
        } else if (try handlerClause(p)) |c| {
            if (c.kind == .on_error) f[4] = if (c.code == 'E') "E" else "N";
        } else break;
    }
    return optionsExpr(p, pos, &f);
}

fn mergePatch(p: *Parser, pos: u32) Error!*Expr {
    const t = try p.expr0();
    _ = try p.expect(.comma);
    const patch = try p.expr0();
    const o = try outputClauses(p, pos, "N");
    return finish(p, pos, "xq_ora_json_mergepatch", &.{ t, patch, o });
}

fn serialize(p: *Parser, pos: u32) Error!*Expr {
    const x = try p.expr0();
    _ = try formatJson(p);
    const o = try outputClauses(p, pos, "E");
    return finish(p, pos, "xq_ora_json_serialize", &.{ x, o });
}

fn transform(p: *Parser, pos: u32) Error!*Expr {
    const doc = try p.expr0();
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(p.arena, doc);
    try args.append(p.arena, undefined);
    while (p.eat(.comma)) {
        const t = p.peek();
        const ops = [_][]const u8{ "SET", "INSERT", "REPLACE", "APPEND", "REMOVE", "RENAME", "KEEP" };
        const op = for (ops) |o| {
            if (t.isKw(o)) break o;
        } else return p.unsupported(t.start, "this JSON_TRANSFORM operation");
        _ = p.advance();
        while (true) {
            const pp = p.peek().start;
            const path = try pathLiteral(p);
            try args.append(p.arena, try str(p, t.start, op));
            try args.append(p.arena, try str(p, pp, path));
            if (eq(op, "REMOVE") or eq(op, "KEEP")) {
                try args.append(p.arena, try nullLit(p, pp));
            } else if (eq(op, "RENAME")) {
                if (!p.eatOp("=")) try p.expectKw("with");
                const nt = p.peek();
                if (nt.kind != .string) return p.missing("ORA-00936: missing expression");
                _ = p.advance();
                try args.append(p.arena, try str(p, nt.start, nt.text));
            } else {
                if (!p.eatOp("=")) return p.missing("ORA-00905: missing keyword");
                try args.append(p.arena, try ctorValue(p));
            }
            if (try handlerClause(p)) |_| return p.unsupported(t.start, "JSON_TRANSFORM handlers (ON EXISTING/MISSING/NULL)");
            // KEEP '$.a', '$.b'
            if (eq(op, "KEEP") and p.peek().kind == .comma and p.peekAt(1).kind == .string) {
                _ = p.advance();
                continue;
            }
            break;
        }
    }
    args.items[1] = try outputClauses(p, pos, "E");
    return finish(p, pos, "xq_ora_json_transform", args.items);
}

// ============================================================== IS JSON

/// `l IS [NOT] JSON ...`, after IS [NOT] (JSON is next).
pub fn isJson(p: *Parser, l: *Expr, not: bool) Error!*Expr {
    const start = p.advance().start; // JSON
    if (p.peek().kind == .lparen) return p.fail(start, "ORA-61763: JSON modifier check on IS JSON is only supported on JSON type.", .{});
    var fl: i64 = 0;
    while (true) {
        if (p.eatKw("strict")) {
            fl |= 1;
        } else if (p.eatKw("lax")) {
            fl &= ~@as(i64, 1);
        } else if (p.isKw("format") and p.isKwAt(1, "json")) {
            p.i += 2;
        } else if (p.eatKw("allow")) {
            try p.expectKw("scalars");
        } else if (p.eatKw("disallow")) {
            try p.expectKw("scalars");
            fl |= 4;
        } else if (p.isKw("with") and p.isKwAt(1, "unique")) {
            p.i += 2;
            try p.expectKw("keys");
            fl |= 2;
        } else if (p.isKw("without") and p.isKwAt(1, "unique")) {
            p.i += 2;
            try p.expectKw("keys");
        } else break;
    }
    const f = try p.new(tree.Func, .{ .name = .{ .text = "xq_ora_is_json", .pos = start }, .args = try p.list(&.{ l, try int(p, start, fl) }) });
    const e = try tree.expr(p.arena, l.pos, p.lastEnd(), .{ .func = f });
    if (!not) return e;
    return tree.expr(p.arena, l.pos, p.lastEnd(), .{ .unary = .{ .op = .not, .e = e } });
}

// ========================================================= dot notation

const methods = [_][]const u8{ "size", "type", "length", "lower", "upper", "number", "numberOnly", "string", "stringOnly", "boolean", "booleanOnly", "abs", "ceiling", "floor", "double", "float", "count", "sum", "avg", "min", "max", "minNumber", "maxNumber", "date", "timestamp" };

fn isMethod(raw: []const u8) bool {
    for (methods) |m| if (eq(m, raw)) return true;
    return false;
}

/// Whether `.method()` (an item method of dot notation) is next.
pub fn methodAhead(p: *const Parser) bool {
    if (p.peek().kind != .dot) return false;
    const t = p.peekAt(1);
    return t.kind == .ident and p.peekAt(2).kind == .lparen and p.peekAt(3).kind == .rparen and isMethod(t.text);
}

/// t.col.a.b[0].c.size(): the names read so far (`names`, at least 2:
/// the alias and the column) and the rest of the path. A placeholder
/// call xq_ora_json_dot(t.col, '$.a.b', flags) that resolveDot() makes
/// dot notation or a column again (db.t.col).
pub fn dotExpr(p: *Parser, start: u32, names: []const Name) Error!*Expr {
    var path: std.ArrayList(u8) = .empty;
    try path.append(p.arena, '$');
    var complex = false;
    var label: ?[]const u8 = null;
    for (names[2..]) |n| {
        try appendMember(p, &path, n);
        if (label == null) label = n.text;
    }
    var method = false;
    while (true) {
        if (p.peek().isOp("[")) {
            complex = true;
            const open = p.advance();
            var depth: usize = 1;
            while (depth > 0) {
                const t = p.advance();
                if (t.kind == .eof) return p.missing("ORA-00907: missing right parenthesis");
                if (t.isOp("[")) depth += 1;
                if (t.isOp("]")) depth -= 1;
            }
            try path.appendSlice(p.arena, p.src[open.start..p.lastEnd()]);
            continue;
        }
        if (p.peek().kind == .dot and !method) {
            const nt = p.peekAt(1);
            if (nt.kind != .ident and nt.kind != .qident) break;
            _ = p.advance();
            _ = p.advance();
            const raw = rawText(p, nt);
            if (nt.kind == .ident and p.peek().kind == .lparen and p.peekAt(1).kind == .rparen and isMethod(raw)) {
                p.i += 2;
                try path.append(p.arena, '.');
                try path.appendSlice(p.arena, raw);
                try path.appendSlice(p.arena, "()");
                method = true;
                complex = true;
                continue;
            }
            const n: Name = .{ .text = nt.text, .pos = nt.start };
            try appendMember(p, &path, n);
            if (!complex) label = n.text;
            continue;
        }
        break;
    }
    if (names.len > 3 or complex) {} else {
        // t.col.a: perhaps db.t.col (resolveDot() decides).
    }
    const col_names = try p.arena.dupe(Name, names[0..2]);
    const col = try tree.expr(p.arena, start, p.lastEnd(), .{ .column = col_names });
    const flags: i64 = if (method) 2 else 0;
    const e = try p.call(start, "xq_ora_json_dot", null, &.{ col, try str(p, start, path.items), try int(p, start, flags) });
    e.end = p.lastEnd();
    try p.dot_nodes.put(p.arena, e, .{ .names = try p.arena.dupe(Name, names), .complex = complex or names.len > 3 });
    if (label) |l| try p.pseudo_names.put(p.arena, e, try std.ascii.allocUpperString(p.arena, l));
    return e;
}

fn rawText(p: *const Parser, t: Token) []const u8 {
    if (t.kind == .qident) return t.text;
    return p.src[t.start..t.end];
}

/// `.name` of a path: the name as written (quoted when it must be).
fn appendMember(p: *Parser, path: *std.ArrayList(u8), n: Name) Error!void {
    const quoted = n.pos < p.src.len and p.src[n.pos] == '"';
    const raw = if (quoted) n.text else p.src[n.pos..@min(n.pos + n.text.len, p.src.len)];
    try path.append(p.arena, '.');
    var plain = !quoted and raw.len > 0;
    for (raw) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
        plain = false;
    };
    if (plain) return path.appendSlice(p.arena, raw);
    try J.writeString(p.arena, path, raw, false);
}

// ============================================================ JSON_TABLE

/// JSON_TABLE(doc [FORMAT JSON], 'path' [ERROR|NULL ON ERROR] COLUMNS
/// (...)) [alias]: xq_ora_json_table(doc, spec).
pub fn jsonTable(p: *Parser) Error!tree.FromItem {
    const start = p.advance().start; // JSON_TABLE
    _ = try p.expect(.lparen);
    const doc = try p.expr0();
    _ = try formatJson(p);
    var path: []const u8 = "$";
    var pp = p.peek().start;
    if (p.eat(.comma)) {
        pp = p.peek().start;
        path = try pathLiteral(p);
    }
    var on_error: []const u8 = "N";
    while (try handlerClause(p)) |c| {
        if (c.kind == .on_error and c.code == 'E') on_error = "E";
    }
    if (p.isKw("type")) return p.unsupported(p.peek().start, "JSON_TABLE TYPE (STRICT|LAX)");
    try p.expectKw("columns");
    var cols: std.ArrayList(Column) = .empty;
    const spec_cols = try columns(p, &cols);
    _ = try p.expect(.rparen);
    if (cols.items.len > jf.max_columns) return p.unsupported(start, "JSON_TABLE with more than 100 columns");
    var members: std.ArrayList(J.Member) = .empty;
    try members.append(p.arena, .{ .key = "p", .value = .{ .string = path } });
    try members.append(p.arena, .{ .key = "e", .value = .{ .string = on_error } });
    try members.append(p.arena, .{ .key = "c", .value = spec_cols });
    const spec = try J.toText(p.arena, .{ .object = members.items }, .{});
    const f = try p.new(tree.Func, .{ .name = .{ .text = jf.json_table_name, .pos = start }, .args = try p.list(&.{ doc, try str(p, pp, spec) }) });
    var al = try p.alias();
    if (al == null) {
        p.jt_count += 1;
        al = .{ .name = .{ .text = try std.fmt.allocPrint(p.arena, "xq_json_table{d}", .{p.jt_count}), .pos = start } };
    }
    try p.jt_items.put(p.arena, f, try p.new(Table, .{ .label = al.?.name.text, .cols = cols.items }));
    return .{ .source = .{ .func = f }, .alias = al };
}

fn jstr(s: []const u8) J.Value {
    return .{ .string = s };
}

/// COLUMNS (...): the spec of the columns (json.zig's value), the
/// columns appended to `out` (numbered in order, nested ones included).
fn columns(p: *Parser, out: *std.ArrayList(Column)) Error!J.Value {
    _ = try p.expect(.lparen);
    var items: std.ArrayList(J.Value) = .empty;
    while (true) {
        var ms: std.ArrayList(J.Member) = .empty;
        if (p.isKw("nested")) {
            _ = p.advance();
            _ = p.eatKw("path");
            const pp = p.peek().start;
            _ = pp;
            const path = try pathLiteral(p);
            try p.expectKw("columns");
            try ms.append(p.arena, .{ .key = "k", .value = jstr("n") });
            try ms.append(p.arena, .{ .key = "p", .value = jstr(path) });
            try ms.append(p.arena, .{ .key = "c", .value = try columns(p, out) });
            try items.append(p.arena, .{ .object = ms.items });
            if (!p.eat(.comma)) break;
            continue;
        }
        const nt = p.peek();
        const name = try p.colId();
        const raw = rawText(p, nt);
        var col: Column = .{ .name = name.text, .index = out.items.len };
        if (p.isKw("for") and p.isKwAt(1, "ordinality")) {
            p.i += 2;
            try ms.append(p.arena, .{ .key = "k", .value = jstr("o") });
            col.family = .number;
            try out.append(p.arena, col);
            try items.append(p.arena, .{ .object = ms.items });
            if (!p.eat(.comma)) break;
            continue;
        }
        var kind: []const u8 = "v";
        var ty: []const u8 = "";
        var path: ?[]const u8 = null;
        var on_error: []const u8 = "";
        var on_empty: []const u8 = "";
        var def_error: ?J.Value = null;
        var def_empty: ?J.Value = null;
        var truncate = false;
        var wrapper: []const u8 = "N";
        // The type, unless a clause comes first.
        const t = p.peek();
        if (t.kind == .ident and !t.isAnyKw(&.{ "format", "exists", "path", "error", "null", "default", "empty", "truncate", "with", "without", "allow", "disallow" })) {
            ty = try returning(p);
        }
        while (true) {
            if (p.eatKw("truncate")) {
                truncate = true;
            } else if (try formatJson(p)) {
                kind = "q";
            } else if (p.eatKw("exists")) {
                kind = "x";
            } else if (p.eatKw("path")) {
                path = try pathLiteral(p);
            } else if (try wrapperClause(p)) |w| {
                wrapper = w;
            } else if (p.isKw("allow") or p.isKw("disallow")) {
                _ = p.advance();
                try p.expectKw("scalars");
            } else if (try handlerClause(p)) |c| {
                const code = try p.arena.dupe(u8, &.{c.code});
                var dv: ?J.Value = null;
                if (c.default) |d| dv = try literalValue(p, d);
                switch (c.kind) {
                    .on_error => {
                        on_error = code;
                        def_error = dv;
                    },
                    .on_empty => {
                        on_empty = code;
                        def_empty = dv;
                    },
                    else => {},
                }
            } else break;
        }
        // Without PATH: '$.name', the name as written.
        const p_text = path orelse blk: {
            var b: std.ArrayList(u8) = .empty;
            try b.append(p.arena, '$');
            try appendMember(p, &b, .{ .text = if (nt.kind == .qident) name.text else raw, .pos = nt.start });
            break :blk b.items;
        };
        try ms.append(p.arena, .{ .key = "k", .value = jstr(kind) });
        if (ty.len > 0) try ms.append(p.arena, .{ .key = "t", .value = jstr(ty) });
        try ms.append(p.arena, .{ .key = "p", .value = jstr(p_text) });
        if (on_error.len > 0) try ms.append(p.arena, .{ .key = "e", .value = jstr(on_error) });
        if (on_empty.len > 0) try ms.append(p.arena, .{ .key = "m", .value = jstr(on_empty) });
        if (def_error) |d| try ms.append(p.arena, .{ .key = "de", .value = d });
        if (def_empty) |d| try ms.append(p.arena, .{ .key = "dm", .value = d });
        if (truncate) try ms.append(p.arena, .{ .key = "tr", .value = .{ .number = "1" } });
        if (!std.mem.eql(u8, wrapper, "N")) try ms.append(p.arena, .{ .key = "w", .value = jstr(wrapper) });
        col.family = if (std.mem.eql(u8, kind, "v") and ty.len > 0) (if (types.parse(ty)) |tn| types.family(tn.name) else null) else null;
        try out.append(p.arena, col);
        try items.append(p.arena, .{ .object = ms.items });
        if (!p.eat(.comma)) break;
    }
    _ = try p.expect(.rparen);
    return .{ .array = items.items };
}

/// A DEFAULT of a JSON_TABLE column: a literal.
fn literalValue(p: *Parser, e: *const Expr) Error!J.Value {
    return switch (e.kind) {
        .string => |s| .{ .string = s },
        .integer => |s| .{ .number = s },
        .float => |s| .{ .number = try jf.canonNumber(p.arena, s) },
        .unary => |u| blk: {
            if (u.op != .neg) break :blk p.fail(e.pos, "ORA-40451: invalid default value", .{});
            const inner = try literalValue(p, u.e);
            if (inner != .number) break :blk p.fail(e.pos, "ORA-40451: invalid default value", .{});
            break :blk .{ .number = try std.fmt.allocPrint(p.arena, "-{s}", .{inner.number}) };
        },
        .null => .null,
        else => p.fail(e.pos, "ORA-40451: invalid default value", .{}),
    };
}

// ================================================== the pass after parsing

pub const Scope = std.ArrayList([]const tree.FromItem);

/// The label of a FROM item (its alias, else its table's name).
fn labelOf(it: tree.FromItem) ?[]const u8 {
    if (it.alias) |a| return a.name.text;
    if (it.source == .table) return it.source.table.name.text;
    return null;
}

/// The FROM items of `items` (joins flattened).
fn flatItems(p: *Parser, items: []const tree.FromItem, out: *std.ArrayList(tree.FromItem)) Error!void {
    for (items) |it| switch (it.source) {
        .nested => |inner| try flatItems(p, inner, out),
        else => try out.append(p.arena, it),
    };
}

/// The FROM item labelled `label` in scope (innermost first).
fn findLabel(p: *Parser, scope: []const []const tree.FromItem, label: []const u8) Error!?tree.FromItem {
    var level = scope.len;
    while (level > 0) {
        level -= 1;
        var flat: std.ArrayList(tree.FromItem) = .empty;
        try flatItems(p, scope[level], &flat);
        for (flat.items) |it| if (labelOf(it)) |l| if (eq(l, label)) return it;
    }
    return null;
}

fn familyOfColumn(p: *Parser, e: *const Expr, scope: []const []const tree.FromItem) Error!?types.Family {
    if (e.kind != .column) return null;
    if (try jtColumnOf(p, e, scope)) |c| return c.family;
    return p.columnFamily(e, scope);
}

/// The JSON_TABLE column a reference names, if it is one (after
/// rewriting: label.cN).
fn jtColumnOf(p: *Parser, e: *const Expr, scope: []const []const tree.FromItem) Error!?Column {
    const names = e.kind.column;
    if (names.len != 2) return null;
    const it = (try findLabel(p, scope, names[0].text)) orelse return null;
    if (it.source != .func) return null;
    const t = p.jt_items.get(it.source.func) orelse return null;
    for (t.cols) |c| {
        var buf: [16]u8 = undefined;
        const cn = std.fmt.bufPrint(&buf, "c{d}", .{c.index}) catch continue;
        if (eq(cn, names[1].text)) return c;
    }
    return null;
}

/// What the pass does to an expression before its children: dot
/// notation, JSON constructor values, JSON_OBJECT(*), comparisons of
/// JSON_VALUE's text with numbers.
pub fn expr(p: *Parser, e: *Expr, scope: *Scope) Error!void {
    if (p.dot_nodes.get(e)) |d| try resolveDot(p, e, d, scope.items);
    if (e.kind == .func) {
        const f = e.kind.func;
        if (p.json_object_star.contains(e)) try objectStar(p, f, scope.items);
        if (std.mem.startsWith(u8, f.name.text, "xq_ora_json")) {
            for (f.args) |*arg| {
                // Once: the value may end up under the call it becomes.
                if (!p.json_values.remove(arg.*)) continue;
                arg.* = try constructorValue(p, arg.*, scope.items);
            }
        }
    }
    switch (e.kind) {
        .compare => |*c| {
            try numberSide(p, &c.l, c.r);
            try numberSide(p, &c.r, c.l);
        },
        .between => |*b| {
            if (isNumberLit(b.lo) or isNumberLit(b.hi)) try toNumber(p, &b.e);
        },
        .in_list => |*x| {
            for (x.items) |item| if (isNumberLit(item)) {
                try toNumber(p, &x.e);
                break;
            };
        },
        else => {},
    }
}

fn isNumberLit(e: *const Expr) bool {
    return switch (e.kind) {
        .integer, .float => true,
        .unary => |u| (u.op == .neg or u.op == .plus) and isNumberLit(u.e),
        else => false,
    };
}

/// JSON_VALUE's text (or dot notation's) compared with a number: the
/// number the text spells.
fn numberSide(p: *Parser, side: **Expr, other: *const Expr) Error!void {
    if (!isNumberLit(other)) return;
    try toNumber(p, side);
}

fn toNumber(p: *Parser, side: **Expr) Error!void {
    const x = side.*;
    if (x.kind != .func) return;
    const f = x.kind.func;
    const is_text = (std.mem.eql(u8, f.name.text, "xq_ora_json_value") and p.json_text_nodes.contains(x) and textReturning(f)) or
        (std.mem.eql(u8, f.name.text, "xq_ora_json_dot"));
    if (!is_text) return;
    side.* = try tree.expr(p.arena, x.pos, x.end, .{ .cast = .{ .e = x, .target_type = "NUMBER", .mode = .{ .typed = .{ .func = "xq_ora_cast", .type_arg = "NUMBER" } } } });
}

/// Whether JSON_VALUE returns text (no RETURNING, or a character type).
fn textReturning(f: *const tree.Func) bool {
    if (f.args.len < 3 or f.args[2].kind != .string) return false;
    const ty = jf.optsField(f.args[2].kind.string, 0);
    if (ty.len == 0) return true;
    const tn = types.parse(ty) orelse return false;
    const fam = types.family(tn.name) orelse return false;
    return fam == .varchar or fam == .char or fam == .clob;
}

/// A value of a JSON constructor: a JSON column is JSON
/// (xq_ora_json()), a date ISO 8601 text (replace(d, ' ', 'T')).
fn constructorValue(p: *Parser, v: *Expr, scope: []const []const tree.FromItem) Error!*Expr {
    if (v.kind == .column) {
        if (try familyOfColumn(p, v, scope)) |fam| if (fam == .json) return p.call(v.pos, "xq_ora_json", null, &.{v});
    }
    if (try p.dateKindOf(v, scope) != .none) {
        return p.call(v.pos, "replace", null, &.{ v, try str(p, v.pos, " "), try str(p, v.pos, "T") });
    }
    return v;
}

/// t.col.path: dot notation if `t` is a FROM item in scope, else the
/// column db.t.col (a path of more names is an error).
fn resolveDot(p: *Parser, e: *Expr, d: Dot, scope: []const []const tree.FromItem) Error!void {
    const f = e.kind.func;
    if (try findLabel(p, scope, d.names[0].text)) |it| {
        _ = it;
        if (try familyOfColumn(p, f.args[0], scope)) |fam| if (fam == .json) {
            const fl = std.fmt.parseInt(i64, f.args[2].kind.integer, 10) catch 0;
            f.args[2] = try int(p, e.pos, fl | 1);
        };
        return;
    }
    // schema.table.column, the table in scope.
    if (d.complex or d.names.len != 3 or try findLabel(p, scope, d.names[1].text) == null) {
        return p.fail(d.names[0].pos, "ORA-00904: \"{s}\": invalid identifier", .{d.names[0].text});
    }
    const names = try p.arena.dupe(Name, d.names);
    names[0] = try p.dbName(names[0]);
    e.kind = .{ .column = names };
    _ = p.pseudo_names.remove(e);
}

/// JSON_OBJECT(*): the columns of the FROM items in scope, as KEY 'NAME'
/// VALUE t.name pairs.
fn objectStar(p: *Parser, f: *tree.Func, scope: []const []const tree.FromItem) Error!void {
    if (scope.len == 0) return p.fail(f.name.pos, "ORA-00936: missing expression", .{});
    var flat: std.ArrayList(tree.FromItem) = .empty;
    try flatItems(p, scope[scope.len - 1], &flat);
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(p.arena, f.args[0]);
    const pos = f.name.pos;
    for (flat.items) |it| {
        const label = labelOf(it) orelse return p.unsupported(pos, "JSON_OBJECT(*) over this FROM item");
        var cols: std.ArrayList([]const u8) = .empty;
        var refs: std.ArrayList([]const u8) = .empty;
        switch (it.source) {
            .table => |q| {
                const t = (try p.findTable(q)) orelse return p.fail(pos, "ORA-00942: table or view does not exist", .{});
                for (t.cols) |col| {
                    if (col.col_flags.HIDDEN) continue;
                    try cols.append(p.arena, col.name());
                    try refs.append(p.arena, col.name());
                }
            },
            .func => |fn_| {
                const t = p.jt_items.get(fn_) orelse return p.unsupported(pos, "JSON_OBJECT(*) over this FROM item");
                for (t.cols) |c| {
                    try cols.append(p.arena, c.name);
                    try refs.append(p.arena, try std.fmt.allocPrint(p.arena, "c{d}", .{c.index}));
                }
            },
            else => return p.unsupported(pos, "JSON_OBJECT(*) over this FROM item"),
        }
        for (cols.items, refs.items) |cn, rn| {
            const names = try p.arena.alloc(Name, 2);
            names[0] = .{ .text = label, .pos = pos };
            names[1] = .{ .text = rn, .pos = pos };
            const ref = try tree.expr(p.arena, pos, pos, .{ .column = names });
            try args.append(p.arena, try str(p, pos, cn));
            try args.append(p.arena, try constructorValue(p, ref, scope));
        }
    }
    // The pairs written after * stay after it.
    try args.appendSlice(p.arena, f.args[1..]);
    f.args = args.items;
}

// ---------------------------------------------------- JSON_TABLE columns

const Jt = struct { label: []const u8, t: *const Table };

/// Rewrite the references to the columns of the JSON_TABLEs of query `c`
/// (and its ORDER BY) to the table function's columns cN: `jt.a` and an
/// unqualified `a` that no other table of the query has, in `*` and
/// `jt.*` too; then the subqueries of the query, for qualified names.
pub fn rewriteCore(p: *Parser, c: *tree.Core, order_by: []tree.SortItem) Error!void {
    if (p.jt_done.contains(c)) return;
    try p.jt_done.put(p.arena, c, {});
    var flat: std.ArrayList(tree.FromItem) = .empty;
    try flatItems(p, c.from, &flat);
    var jts: std.ArrayList(Jt) = .empty;
    for (flat.items) |it| if (it.source == .func) if (p.jt_items.get(it.source.func)) |t| {
        try jts.append(p.arena, .{ .label = labelOf(it).?, .t = t });
    };
    if (jts.items.len == 0) return;
    const ctx: Rewrite = .{ .p = p, .jts = jts.items, .from = flat.items };
    // Result columns: stars expanded, names kept.
    var cols: std.ArrayList(tree.ResultCol) = .empty;
    for (c.cols) |rc| switch (rc) {
        .star => |pos| for (flat.items) |it| {
            if (jtOf(&ctx, labelOf(it) orelse "")) |jt| {
                try appendJtCols(p, &cols, jt, pos);
                continue;
            }
            const label = labelOf(it) orelse return p.unsupported(pos, "* with a JSON_TABLE and an unnamed subquery");
            const names = try p.arena.alloc(Name, 1);
            names[0] = .{ .text = label, .pos = pos };
            try cols.append(p.arena, .{ .table_star = .{ .names = names, .star_pos = pos } });
        },
        .table_star => |ts| {
            if (ts.names.len == 1) if (jtOf(&ctx, ts.names[0].text)) |jt| {
                try appendJtCols(p, &cols, jt, ts.star_pos);
                continue;
            };
            try cols.append(p.arena, rc);
        },
        .expr => |x| {
            var y = x;
            if (try ctx.column(x.e, true)) |col| if (x.alias == null) {
                y.alias = .{ .text = col.name, .pos = x.e.pos };
                y.name = null;
            };
            try ctx.walk(x.e, true);
            try cols.append(p.arena, .{ .expr = y });
        },
    };
    c.cols = cols.items;
    for (c.from) |it| if (it.on) |on| try ctx.walk(on, true);
    if (c.where) |w| try ctx.walk(w, true);
    for (c.group_by) |g| try ctx.walk(g, true);
    if (c.having) |h| try ctx.walk(h, true);
    for (order_by) |it| try ctx.walk(it.expr, true);
    for (c.from) |it| if (it.source == .func) for (it.source.func.args) |a| try ctx.walk(a, true);
}

fn jtOf(ctx: *const Rewrite, label: []const u8) ?Jt {
    for (ctx.jts) |jt| if (eq(jt.label, label)) return jt;
    return null;
}

fn appendJtCols(p: *Parser, cols: *std.ArrayList(tree.ResultCol), jt: Jt, pos: u32) Error!void {
    for (jt.t.cols) |col| {
        const names = try p.arena.alloc(Name, 2);
        names[0] = .{ .text = jt.label, .pos = pos };
        names[1] = .{ .text = try std.fmt.allocPrint(p.arena, "c{d}", .{col.index}), .pos = pos };
        const e = try tree.expr(p.arena, pos, pos, .{ .column = names });
        try cols.append(p.arena, .{ .expr = .{ .e = e, .alias = .{ .text = col.name, .pos = pos } } });
    }
}

const Rewrite = struct {
    p: *Parser,
    jts: []const Jt,
    from: []const tree.FromItem,

    /// The JSON_TABLE column `e` names (and rewrite it to label.cN).
    fn column(r: *const Rewrite, e: *Expr, unqualified: bool) Error!?Column {
        if (e.kind != .column) return null;
        const names = e.kind.column;
        var jt: ?Jt = null;
        var cname: []const u8 = undefined;
        if (names.len == 2) {
            jt = jtOf(r, names[0].text);
            cname = names[1].text;
        } else if (names.len == 1 and unqualified) {
            cname = names[0].text;
            for (r.jts) |x| for (x.t.cols) |col| if (eq(col.name, cname)) {
                if (jt == null) jt = x;
            };
            if (jt != null and try r.otherHas(cname)) return null;
        }
        const t = jt orelse return null;
        for (t.t.cols) |col| if (std.mem.eql(u8, col.name, cname)) {
            const out = try r.p.arena.alloc(Name, 2);
            out[0] = .{ .text = t.label, .pos = names[0].pos };
            out[1] = .{ .text = try std.fmt.allocPrint(r.p.arena, "c{d}", .{col.index}), .pos = names[names.len - 1].pos };
            e.kind = .{ .column = out };
            return col;
        };
        return null;
    }

    /// Whether a table of the query has column `name`.
    fn otherHas(r: *const Rewrite, name: []const u8) Error!bool {
        for (r.from) |it| {
            if (it.source != .table) continue;
            const t = (try r.p.findTable(it.source.table)) orelse continue;
            if (build.columnIndex(t, name) >= 0) return true;
        }
        return false;
    }

    fn walk(r: *const Rewrite, e: *Expr, unqualified: bool) Error!void {
        if (try r.column(e, unqualified)) |_| return;
        switch (e.kind) {
            .exists, .subquery => |s| return r.select(s),
            .in_select => |x| {
                try r.walk(x.e, unqualified);
                return r.select(x.sel);
            },
            .func => |f| {
                for (f.args) |a| try r.walk(a, unqualified);
                if (f.filter) |x| try r.walk(x, unqualified);
                for (f.order_by) |it| try r.walk(it.expr, unqualified);
                if (f.over) |w| {
                    for (w.partition) |x| try r.walk(x, unqualified);
                    for (w.order_by) |it| try r.walk(it.expr, unqualified);
                }
                return;
            },
            else => {},
        }
        var it = parser.Children.of(e);
        while (it.next()) |child| try r.walk(@constCast(child), unqualified);
    }

    /// A subquery: qualified references only.
    fn select(r: *const Rewrite, s: *tree.Select) Error!void {
        try r.body(s.body);
        for (s.order_by) |it| try r.walk(it.expr, false);
    }

    fn body(r: *const Rewrite, b: *tree.Body) Error!void {
        switch (b.*) {
            .core => |c| {
                for (c.cols) |rc| if (rc == .expr) try r.walk(rc.expr.e, false);
                if (c.where) |w| try r.walk(w, false);
                for (c.group_by) |g| try r.walk(g, false);
                if (c.having) |h| try r.walk(h, false);
                for (c.from) |it| {
                    if (it.on) |on| try r.walk(on, false);
                    if (it.source == .subquery) try r.select(it.source.subquery);
                    if (it.source == .func) for (it.source.func.args) |a| try r.walk(a, false);
                }
            },
            .values => |rows| for (rows) |row| for (row) |x| try r.walk(x, false),
            .compound => |x| {
                try r.body(x.left);
                try r.body(x.right);
            },
            .nested => |s| try r.select(s),
        }
    }
};
