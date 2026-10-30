//! A subset of PostgreSQL's SQL/JSON path language (jsonpath), for
//! jsonb_path_query() and friends, `@?` and `@@`:
//!
//!  - `lax` (the default) and `strict` mode;
//!  - `$`, `@` (in filters), `$name` (a variable of the vars argument),
//!    `.key`, `."key"`, `.*`, `[*]`, `[n]`, `[n to m]`, `[last]`,
//!    `[last - 1]`, `.**`;
//!  - filters `? (predicate)`: `==`, `!=`/`<>`, `<`, `<=`, `>`, `>=`,
//!    `&&`, `||`, `!`, `exists (path)`, `starts with`, `is unknown`;
//!  - arithmetic `+ - * / %` of single numbers, unary `-`/`+`;
//!  - methods type(), size(), double(), abs(), floor(), ceiling().
//!
//! Lax mode unwraps arrays where an object or a scalar is expected and
//! wraps a scalar where an array is, and a missing key is an empty
//! result; strict mode makes those errors. Not supported: like_regex,
//! `.**{n to m}`, keyvalue(), datetime(), string methods.

const std = @import("std");
const json = @import("json.zig");
const Value = json.Value;
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, Syntax, Eval };

/// What went wrong, for the message of the SQL function.
pub const Diag = struct {
    msg: []const u8 = "",
};

const Node = union(enum) {
    root,
    current,
    last,
    variable: []const u8,
    literal: Value,
    /// An accessor applied to the items of `base`.
    key: struct { base: *Node, name: []const u8 },
    any_key: *Node,
    any_elem: *Node,
    /// `.**`: the item and everything in it.
    any_path: *Node,
    subscript: struct { base: *Node, items: []Range },
    filter: struct { base: *Node, pred: *Node },
    method: struct { base: *Node, name: []const u8 },
    binary: struct { op: Op, l: *Node, r: *Node },
    unary: struct { op: Op, e: *Node },
    exists: *Node,
    starts_with: struct { l: *Node, r: *Node },
    is_unknown: *Node,
};

const Range = struct { from: *Node, to: ?*Node };

const Op = enum { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge, @"and", @"or", not, neg, plus };

pub const Path = struct {
    strict: bool,
    expr: *Node,

    /// Whether the path is a predicate (what `@@` and
    /// jsonb_path_match() take).
    pub fn isPredicate(p: Path) bool {
        return isPred(p.expr);
    }
};

fn isPred(n: *const Node) bool {
    return switch (n.*) {
        .binary => |b| switch (b.op) {
            .eq, .ne, .lt, .le, .gt, .ge, .@"and", .@"or" => true,
            else => false,
        },
        .unary => |u| u.op == .not,
        .exists, .starts_with, .is_unknown => true,
        else => false,
    };
}

// ================================================================ lexing

const Tok = struct {
    kind: enum { ident, string, number, variable, punct, eof },
    text: []const u8,
};

const Lexer = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    toks: std.ArrayList(Tok) = .empty,
    diag: *Diag,

    fn run(l: *Lexer) Error![]Tok {
        const s = l.s;
        while (true) {
            while (l.i < s.len and std.ascii.isWhitespace(s[l.i])) l.i += 1;
            if (l.i >= s.len) break;
            const c = s[l.i];
            const start = l.i;
            if (c == '"') {
                l.i += 1;
                var out: std.ArrayList(u8) = .empty;
                while (true) {
                    if (l.i >= s.len) return l.syntax("unterminated quoted string");
                    const ch = s[l.i];
                    if (ch == '"') break;
                    if (ch == '\\') {
                        l.i += 1;
                        if (l.i >= s.len) return l.syntax("unterminated quoted string");
                        const e = s[l.i];
                        switch (e) {
                            'n' => try out.append(l.a, '\n'),
                            't' => try out.append(l.a, '\t'),
                            'r' => try out.append(l.a, '\r'),
                            'b' => try out.append(l.a, 8),
                            'f' => try out.append(l.a, 12),
                            'u' => {
                                if (l.i + 5 > s.len) return l.syntax("invalid Unicode escape sequence");
                                const cp = std.fmt.parseInt(u21, s[l.i + 1 .. l.i + 5], 16) catch return l.syntax("invalid Unicode escape sequence");
                                var buf: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(cp, &buf) catch return l.syntax("invalid Unicode escape sequence");
                                try out.appendSlice(l.a, buf[0..n]);
                                l.i += 4;
                            },
                            else => try out.append(l.a, e),
                        }
                        l.i += 1;
                        continue;
                    }
                    try out.append(l.a, ch);
                    l.i += 1;
                }
                l.i += 1;
                try l.toks.append(l.a, .{ .kind = .string, .text = out.items });
            } else if (std.ascii.isDigit(c) or (c == '.' and l.i + 1 < s.len and std.ascii.isDigit(s[l.i + 1]))) {
                while (l.i < s.len and std.ascii.isDigit(s[l.i])) l.i += 1;
                if (l.i + 1 < s.len and s[l.i] == '.' and std.ascii.isDigit(s[l.i + 1])) {
                    l.i += 1;
                    while (l.i < s.len and std.ascii.isDigit(s[l.i])) l.i += 1;
                }
                if (l.i < s.len and (s[l.i] == 'e' or s[l.i] == 'E')) {
                    var k = l.i + 1;
                    if (k < s.len and (s[k] == '+' or s[k] == '-')) k += 1;
                    if (k < s.len and std.ascii.isDigit(s[k])) {
                        l.i = k;
                        while (l.i < s.len and std.ascii.isDigit(s[l.i])) l.i += 1;
                    }
                }
                if (l.i < s.len and (std.ascii.isAlphabetic(s[l.i]) or s[l.i] == '_')) return l.syntax("trailing junk after numeric literal");
                var t = s[start..l.i];
                if (t[0] == '.') t = try std.mem.concat(l.a, u8, &.{ "0", t });
                try l.toks.append(l.a, .{ .kind = .number, .text = t });
            } else if (c == '$' and l.i + 1 < s.len and (std.ascii.isAlphabetic(s[l.i + 1]) or s[l.i + 1] == '_' or s[l.i + 1] == '"')) {
                l.i += 1;
                if (s[l.i] == '"') {
                    const e = std.mem.indexOfScalarPos(u8, s, l.i + 1, '"') orelse return l.syntax("unterminated quoted string");
                    try l.toks.append(l.a, .{ .kind = .variable, .text = s[l.i + 1 .. e] });
                    l.i = e + 1;
                } else {
                    const b = l.i;
                    while (l.i < s.len and (std.ascii.isAlphanumeric(s[l.i]) or s[l.i] == '_')) l.i += 1;
                    try l.toks.append(l.a, .{ .kind = .variable, .text = s[b..l.i] });
                }
            } else if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) {
                while (l.i < s.len and (std.ascii.isAlphanumeric(s[l.i]) or s[l.i] == '_' or s[l.i] >= 0x80)) l.i += 1;
                try l.toks.append(l.a, .{ .kind = .ident, .text = s[start..l.i] });
            } else {
                const two = [_][]const u8{ "==", "!=", "<>", "<=", ">=", "&&", "||" };
                var len: usize = 1;
                for (two) |t| if (std.mem.startsWith(u8, s[l.i..], t)) {
                    len = 2;
                };
                if (len == 1 and std.mem.indexOfScalar(u8, "$@.[]()*,?<>!+-/%=", c) == null) {
                    l.diag.msg = try std.fmt.allocPrint(l.a, "syntax error at or near \"{s}\" of jsonpath input", .{s[start .. start + 1]});
                    return error.Syntax;
                }
                l.i += len;
                try l.toks.append(l.a, .{ .kind = .punct, .text = s[start..l.i] });
            }
        }
        try l.toks.append(l.a, .{ .kind = .eof, .text = "" });
        return l.toks.items;
    }

    fn syntax(l: *Lexer, what: []const u8) Error {
        l.diag.msg = std.fmt.allocPrint(l.a, "{s} at or near \"{s}\" of jsonpath input", .{ what, l.s[@min(l.i, l.s.len)..] }) catch return error.OutOfMemory;
        return error.Syntax;
    }
};

// =============================================================== parsing

const Parser = struct {
    a: Allocator,
    toks: []Tok,
    i: usize = 0,
    diag: *Diag,
    /// Inside a filter (`@` allowed) or a subscript (`last` allowed).
    in_filter: u32 = 0,
    in_subscript: u32 = 0,

    fn peek(p: *Parser) Tok {
        return p.toks[p.i];
    }

    fn isP(p: *Parser, t: []const u8) bool {
        const k = p.peek();
        return k.kind == .punct and std.mem.eql(u8, k.text, t);
    }

    fn isW(p: *Parser, w: []const u8) bool {
        const k = p.peek();
        return k.kind == .ident and std.mem.eql(u8, k.text, w);
    }

    fn eatP(p: *Parser, t: []const u8) bool {
        if (!p.isP(t)) return false;
        p.i += 1;
        return true;
    }

    fn expectP(p: *Parser, t: []const u8) Error!void {
        if (!p.eatP(t)) return p.syntax();
    }

    fn syntax(p: *Parser) Error {
        const t = p.peek();
        p.diag.msg = if (t.kind == .eof)
            "syntax error at end of jsonpath input"
        else
            try std.fmt.allocPrint(p.a, "syntax error at or near \"{s}\" of jsonpath input", .{t.text});
        return error.Syntax;
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const x = try p.a.create(Node);
        x.* = n;
        return x;
    }

    fn orExpr(p: *Parser) Error!*Node {
        var l = try p.andExpr();
        while (p.eatP("||")) l = try p.node(.{ .binary = .{ .op = .@"or", .l = l, .r = try p.andExpr() } });
        return l;
    }

    fn andExpr(p: *Parser) Error!*Node {
        var l = try p.notExpr();
        while (p.eatP("&&")) l = try p.node(.{ .binary = .{ .op = .@"and", .l = l, .r = try p.notExpr() } });
        return l;
    }

    fn notExpr(p: *Parser) Error!*Node {
        if (p.eatP("!")) {
            try p.expectP("(");
            const e = try p.orExpr();
            try p.expectP(")");
            return p.node(.{ .unary = .{ .op = .not, .e = e } });
        }
        return p.predicate();
    }

    fn predicate(p: *Parser) Error!*Node {
        if (p.isW("exists") and p.toks[p.i + 1].kind == .punct and std.mem.eql(u8, p.toks[p.i + 1].text, "(")) {
            p.i += 2;
            const e = try p.orExpr();
            try p.expectP(")");
            return p.node(.{ .exists = e });
        }
        const l = try p.additive();
        const cmps = [_]struct { []const u8, Op }{ .{ "==", .eq }, .{ "!=", .ne }, .{ "<>", .ne }, .{ "<=", .le }, .{ ">=", .ge }, .{ "<", .lt }, .{ ">", .gt } };
        for (cmps) |c| if (p.eatP(c[0])) {
            const r = try p.additive();
            return p.node(.{ .binary = .{ .op = c[1], .l = l, .r = r } });
        };
        if (p.isW("starts")) {
            p.i += 1;
            if (!p.isW("with")) return p.syntax();
            p.i += 1;
            const r = try p.additive();
            return p.node(.{ .starts_with = .{ .l = l, .r = r } });
        }
        if (p.isW("like_regex")) {
            p.diag.msg = "like_regex is not supported";
            return error.Syntax;
        }
        if (p.isW("is")) {
            p.i += 1;
            if (!p.isW("unknown")) return p.syntax();
            p.i += 1;
            return p.node(.{ .is_unknown = l });
        }
        return l;
    }

    fn additive(p: *Parser) Error!*Node {
        var l = try p.multiplicative();
        while (true) {
            const op: Op = if (p.eatP("+")) .add else if (p.eatP("-")) .sub else break;
            l = try p.node(.{ .binary = .{ .op = op, .l = l, .r = try p.multiplicative() } });
        }
        return l;
    }

    fn multiplicative(p: *Parser) Error!*Node {
        var l = try p.unary();
        while (true) {
            const op: Op = if (p.eatP("*")) .mul else if (p.eatP("/")) .div else if (p.eatP("%")) .mod else break;
            l = try p.node(.{ .binary = .{ .op = op, .l = l, .r = try p.unary() } });
        }
        return l;
    }

    fn unary(p: *Parser) Error!*Node {
        if (p.eatP("-")) return p.node(.{ .unary = .{ .op = .neg, .e = try p.unary() } });
        if (p.eatP("+")) return p.node(.{ .unary = .{ .op = .plus, .e = try p.unary() } });
        return p.accessorExpr();
    }

    fn accessorExpr(p: *Parser) Error!*Node {
        var e = try p.primary();
        while (true) {
            if (p.isP(".")) {
                p.i += 1;
                const t = p.peek();
                if (t.kind == .punct and std.mem.eql(u8, t.text, "*")) {
                    p.i += 1;
                    if (p.eatP("*")) {
                        if (p.isP("{")) return p.syntax();
                        e = try p.node(.{ .any_path = e });
                        continue;
                    }
                    e = try p.node(.{ .any_key = e });
                } else if (t.kind == .ident and p.toks[p.i + 1].kind == .punct and std.mem.eql(u8, p.toks[p.i + 1].text, "(")) {
                    p.i += 2;
                    try p.expectP(")");
                    const known = [_][]const u8{ "type", "size", "double", "abs", "floor", "ceiling" };
                    var ok = false;
                    for (known) |k| if (std.mem.eql(u8, k, t.text)) {
                        ok = true;
                    };
                    if (!ok) {
                        p.diag.msg = try std.fmt.allocPrint(p.a, "jsonpath method {s}() is not supported", .{t.text});
                        return error.Syntax;
                    }
                    e = try p.node(.{ .method = .{ .base = e, .name = t.text } });
                } else if (t.kind == .ident or t.kind == .string) {
                    p.i += 1;
                    e = try p.node(.{ .key = .{ .base = e, .name = t.text } });
                } else return p.syntax();
            } else if (p.isP("[")) {
                p.i += 1;
                if (p.eatP("*")) {
                    try p.expectP("]");
                    e = try p.node(.{ .any_elem = e });
                    continue;
                }
                var items: std.ArrayList(Range) = .empty;
                p.in_subscript += 1;
                while (true) {
                    const from = try p.additive();
                    var to: ?*Node = null;
                    if (p.isW("to")) {
                        p.i += 1;
                        to = try p.additive();
                    }
                    try items.append(p.a, .{ .from = from, .to = to });
                    if (!p.eatP(",")) break;
                }
                p.in_subscript -= 1;
                try p.expectP("]");
                e = try p.node(.{ .subscript = .{ .base = e, .items = items.items } });
            } else if (p.isP("?")) {
                p.i += 1;
                try p.expectP("(");
                p.in_filter += 1;
                const pred = try p.orExpr();
                p.in_filter -= 1;
                try p.expectP(")");
                e = try p.node(.{ .filter = .{ .base = e, .pred = pred } });
            } else break;
        }
        return e;
    }

    fn primary(p: *Parser) Error!*Node {
        const t = p.peek();
        switch (t.kind) {
            .punct => {
                if (std.mem.eql(u8, t.text, "$")) {
                    p.i += 1;
                    return p.node(.root);
                }
                if (std.mem.eql(u8, t.text, "@")) {
                    if (p.in_filter == 0) {
                        p.diag.msg = "@ is not allowed in root expressions";
                        return error.Syntax;
                    }
                    p.i += 1;
                    return p.node(.current);
                }
                if (std.mem.eql(u8, t.text, "(")) {
                    p.i += 1;
                    const e = try p.orExpr();
                    try p.expectP(")");
                    return e;
                }
                return p.syntax();
            },
            .variable => {
                p.i += 1;
                return p.node(.{ .variable = t.text });
            },
            .string => {
                p.i += 1;
                return p.node(.{ .literal = .{ .v = .{ .string = t.text } } });
            },
            .number => {
                p.i += 1;
                return p.node(.{ .literal = .{ .v = .{ .number = json.numericOut(p.a, t.text) catch return p.syntax() } } });
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                    p.i += 1;
                    return p.node(.{ .literal = .{ .v = .{ .bool = t.text[0] == 't' } } });
                }
                if (std.mem.eql(u8, t.text, "null")) {
                    p.i += 1;
                    return p.node(.{ .literal = json.null_value });
                }
                if (std.mem.eql(u8, t.text, "last")) {
                    if (p.in_subscript == 0) {
                        p.diag.msg = "LAST is allowed only in array subscripts";
                        return error.Syntax;
                    }
                    p.i += 1;
                    return p.node(.last);
                }
                return p.syntax();
            },
            .eof => return p.syntax(),
        }
    }
};

/// Parse a jsonpath.
pub fn compile(a: Allocator, text: []const u8, diag: *Diag) Error!Path {
    var l: Lexer = .{ .a = a, .s = text, .diag = diag };
    const toks = try l.run();
    var p: Parser = .{ .a = a, .toks = toks, .diag = diag };
    var strict = false;
    if (p.isW("strict")) {
        strict = true;
        p.i += 1;
    } else if (p.isW("lax")) p.i += 1;
    const e = try p.orExpr();
    if (p.peek().kind != .eof) return p.syntax();
    return .{ .strict = strict, .expr = e };
}

// ============================================================ evaluation

const Truth = enum { true, false, unknown };

pub const Exec = struct {
    a: Allocator,
    root: Value,
    vars: ?Value,
    strict: bool,
    diag: *Diag,

    fn fail(x: *Exec, comptime fmt: []const u8, args: anytype) Error {
        x.diag.msg = try std.fmt.allocPrint(x.a, fmt, args);
        return error.Eval;
    }

    /// The items `n` yields for current item `cur` (`last` the index of
    /// the last element of the array being subscripted).
    fn eval(x: *Exec, n: *const Node, cur: Value, last: ?i64, out: *std.ArrayList(Value)) Error!void {
        switch (n.*) {
            .root => try out.append(x.a, x.root),
            .current => try out.append(x.a, cur),
            .last => try out.append(x.a, .{ .v = .{ .number = try std.fmt.allocPrint(x.a, "{d}", .{last orelse 0}) } }),
            .literal => |v| try out.append(x.a, v),
            .variable => |name| {
                const vars = x.vars orelse return x.fail("could not find jsonpath variable \"{s}\"", .{name});
                const v = vars.get(name) orelse return x.fail("could not find jsonpath variable \"{s}\"", .{name});
                try out.append(x.a, v);
            },
            .key => |k| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(k.base, cur, last, &base);
                for (base.items) |b| try x.keyOf(b, k.name, out, true);
            },
            .any_key => |b| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(b, cur, last, &base);
                for (base.items) |v| try x.anyKey(v, out, true);
            },
            .any_path => |b| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(b, cur, last, &base);
                for (base.items) |v| try x.descendants(v, out);
            },
            .any_elem => |b| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(b, cur, last, &base);
                for (base.items) |v| switch (v.v) {
                    .array => |items| try out.appendSlice(x.a, items),
                    else => if (x.strict) return x.fail("jsonpath wildcard array accessor can only be applied to an array", .{}) else try out.append(x.a, v),
                };
            },
            .subscript => |s| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(s.base, cur, last, &base);
                for (base.items) |v| {
                    const items: []const Value = switch (v.v) {
                        .array => |it| it,
                        else => blk: {
                            if (x.strict) return x.fail("jsonpath array accessor can only be applied to an array", .{});
                            break :blk &.{v};
                        },
                    };
                    const lst: i64 = @as(i64, @intCast(items.len)) - 1;
                    for (s.items) |r| {
                        const from = try x.index(r.from, cur, lst);
                        const to = if (r.to) |t| try x.index(t, cur, lst) else from;
                        if (x.strict and (from < 0 or to > lst or from > to)) return x.fail("jsonpath array subscript is out of bounds", .{});
                        var i = @max(from, 0);
                        while (i <= @min(to, lst)) : (i += 1) try out.append(x.a, items[@intCast(i)]);
                    }
                }
            },
            .filter => |f| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(f.base, cur, last, &base);
                for (base.items) |v| {
                    // Lax mode filters the elements of an array.
                    if (!x.strict and v.v == .array) {
                        for (v.v.array) |e| if (try x.pred(f.pred, e, last) == .true) try out.append(x.a, e);
                    } else if (try x.pred(f.pred, v, last) == .true) try out.append(x.a, v);
                }
            },
            .method => |m| {
                var base: std.ArrayList(Value) = .empty;
                try x.eval(m.base, cur, last, &base);
                for (base.items) |v| try x.method(m.name, v, out);
            },
            .binary => |b| switch (b.op) {
                .add, .sub, .mul, .div, .mod => {
                    const l = try x.single(b.l, cur, last, b.op, "left");
                    const r = try x.single(b.r, cur, last, b.op, "right");
                    try out.append(x.a, try x.arith(b.op, l, r));
                },
                else => try out.append(x.a, try x.truthValue(try x.pred(n, cur, last))),
            },
            .unary => |u| switch (u.op) {
                .neg, .plus => {
                    var base: std.ArrayList(Value) = .empty;
                    try x.eval(u.e, cur, last, &base);
                    for (base.items) |v| {
                        const items: []const Value = if (!x.strict and v.v == .array) v.v.array else &.{v};
                        for (items) |e| {
                            if (e.v != .number) return x.fail("operand of unary jsonpath operator {s} is not a numeric value", .{if (u.op == .neg) "-" else "+"});
                            if (u.op == .plus) {
                                try out.append(x.a, e);
                            } else {
                                const t = e.v.number;
                                const neg = if (t[0] == '-') t[1..] else try std.mem.concat(x.a, u8, &.{ "-", t });
                                try out.append(x.a, .{ .v = .{ .number = json.numericOut(x.a, neg) catch return x.fail("numeric value out of range", .{}) } });
                            }
                        }
                    }
                },
                else => try out.append(x.a, try x.truthValue(try x.pred(n, cur, last))),
            },
            .exists, .starts_with, .is_unknown => try out.append(x.a, try x.truthValue(try x.pred(n, cur, last))),
        }
    }

    fn truthValue(x: *Exec, t: Truth) Error!Value {
        _ = x;
        return switch (t) {
            .true => .{ .v = .{ .bool = true } },
            .false => .{ .v = .{ .bool = false } },
            .unknown => json.null_value,
        };
    }

    fn keyOf(x: *Exec, v: Value, name: []const u8, out: *std.ArrayList(Value), unwrap: bool) Error!void {
        switch (v.v) {
            .object => {
                if (v.get(name)) |f| {
                    try out.append(x.a, f);
                } else if (x.strict) return x.fail("JSON object does not contain key \"{s}\"", .{name});
            },
            .array => |items| {
                if (x.strict or !unwrap) return x.fail("jsonpath member accessor can only be applied to an object", .{});
                for (items) |e| try x.keyOf(e, name, out, false);
            },
            else => if (x.strict) return x.fail("jsonpath member accessor can only be applied to an object", .{}),
        }
    }

    fn descendants(x: *Exec, v: Value, out: *std.ArrayList(Value)) Error!void {
        try out.append(x.a, v);
        switch (v.v) {
            .object => |pairs| for (pairs) |pp| try x.descendants(pp.value, out),
            .array => |items| for (items) |e| try x.descendants(e, out),
            else => {},
        }
    }

    fn anyKey(x: *Exec, v: Value, out: *std.ArrayList(Value), unwrap: bool) Error!void {
        switch (v.v) {
            .object => |pairs| for (pairs) |pp| try out.append(x.a, pp.value),
            .array => |items| {
                if (x.strict or !unwrap) return x.fail("jsonpath wildcard member accessor can only be applied to an object", .{});
                for (items) |e| try x.anyKey(e, out, false);
            },
            else => if (x.strict) return x.fail("jsonpath wildcard member accessor can only be applied to an object", .{}),
        }
    }

    fn index(x: *Exec, n: *const Node, cur: Value, last: i64) Error!i64 {
        var r: std.ArrayList(Value) = .empty;
        try x.eval(n, cur, last, &r);
        if (r.items.len != 1 or r.items[0].v != .number) return x.fail("jsonpath array subscript is not a single numeric value", .{});
        const f = std.fmt.parseFloat(f64, r.items[0].v.number) catch return x.fail("jsonpath array subscript is not a single numeric value", .{});
        if (!(f > -2147483648.0 and f < 2147483648.0)) return x.fail("jsonpath array subscript is out of integer range", .{});
        return @intFromFloat(@trunc(f));
    }

    fn single(x: *Exec, n: *const Node, cur: Value, last: ?i64, op: Op, side: []const u8) Error![]const u8 {
        var r: std.ArrayList(Value) = .empty;
        try x.eval(n, cur, last, &r);
        var items = r.items;
        if (!x.strict and items.len == 1 and items[0].v == .array) items = items[0].v.array;
        if (items.len != 1 or items[0].v != .number) {
            return x.fail("{s} operand of jsonpath operator {s} is not a single numeric value", .{ side, opText(op) });
        }
        return items[0].v.number;
    }

    /// Numeric arithmetic as PostgreSQL's numeric does it: exact, the
    /// scale of + - % the larger one, of * the sum, of / at least 16
    /// significant digits (select_div_scale()); floats past 36 digits.
    fn arith(x: *Exec, op: Op, l: []const u8, r: []const u8) Error!Value {
        const fl = std.fmt.parseFloat(f64, l) catch 0;
        const fr = std.fmt.parseFloat(f64, r) catch 0;
        if ((op == .div or op == .mod) and fr == 0) return x.fail("division by zero", .{});
        const dl = Dec.parse(l) orelse return x.floatResult(op, fl, fr);
        const dr = Dec.parse(r) orelse return x.floatResult(op, fl, fr);
        const res = Dec.apply(op, dl, dr) orelse return x.floatResult(op, fl, fr);
        return .{ .v = .{ .number = try res.text(x.a) } };
    }

    fn floatResult(x: *Exec, op: Op, fl: f64, fr: f64) Error!Value {
        const v = switch (op) {
            .add => fl + fr,
            .sub => fl - fr,
            .mul => fl * fr,
            .div => fl / fr,
            .mod => @rem(fl, fr),
            else => unreachable,
        };
        return .{ .v = .{ .number = try formatNumber(x.a, v) } };
    }

    fn method(x: *Exec, name: []const u8, v: Value, out: *std.ArrayList(Value)) Error!void {
        const eq = std.mem.eql;
        if (eq(u8, name, "type")) {
            return out.append(x.a, .{ .v = .{ .string = v.typeName() } });
        }
        if (eq(u8, name, "size")) {
            const n: usize = switch (v.v) {
                .array => |items| items.len,
                else => blk: {
                    if (x.strict) return x.fail("jsonpath item method .size() can only be applied to an array", .{});
                    break :blk 1;
                },
            };
            return out.append(x.a, .{ .v = .{ .number = try std.fmt.allocPrint(x.a, "{d}", .{n}) } });
        }
        // Numeric methods unwrap arrays in lax mode.
        if (!x.strict and v.v == .array) {
            for (v.v.array) |e| try x.method(name, e, out);
            return;
        }
        if (eq(u8, name, "double")) {
            const f: f64 = switch (v.v) {
                .number => |n| std.fmt.parseFloat(f64, n) catch 0,
                .string => |s| std.fmt.parseFloat(f64, s) catch return x.fail("argument \"{s}\" of jsonpath item method .double() is invalid for type double precision", .{s}),
                else => return x.fail("jsonpath item method .double() can only be applied to a string or numeric value", .{}),
            };
            return out.append(x.a, .{ .v = .{ .number = try formatNumber(x.a, f) } });
        }
        if (v.v != .number) return x.fail("jsonpath item method .{s}() can only be applied to a numeric value", .{name});
        const t = v.v.number;
        const neg = t[0] == '-';
        const abs = if (neg) t[1..] else t;
        const dot = std.mem.indexOfScalar(u8, abs, '.');
        const ip = if (dot) |d| abs[0..d] else abs;
        const has_frac = if (dot) |d| !allZeros(abs[d + 1 ..]) else false;
        var r: []const u8 = undefined;
        if (eq(u8, name, "abs")) {
            r = abs;
        } else if (eq(u8, name, "floor") or eq(u8, name, "ceiling")) {
            const up = eq(u8, name, "ceiling") != neg;
            var s = ip;
            if (has_frac and up) s = try incDigits(x.a, ip);
            r = if (neg and !allZeros(s)) try std.mem.concat(x.a, u8, &.{ "-", s }) else s;
        } else unreachable;
        try out.append(x.a, .{ .v = .{ .number = r } });
    }

    /// A predicate's truth for current item `cur`.
    fn pred(x: *Exec, n: *const Node, cur: Value, last: ?i64) Error!Truth {
        switch (n.*) {
            .binary => |b| switch (b.op) {
                .@"and" => {
                    const l = try x.pred(b.l, cur, last);
                    if (l == .false) return .false;
                    const r = try x.pred(b.r, cur, last);
                    if (r == .false) return .false;
                    return if (l == .true and r == .true) .true else .unknown;
                },
                .@"or" => {
                    const l = try x.pred(b.l, cur, last);
                    if (l == .true) return .true;
                    const r = try x.pred(b.r, cur, last);
                    if (r == .true) return .true;
                    return if (l == .false and r == .false) .false else .unknown;
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    var l: std.ArrayList(Value) = .empty;
                    var r: std.ArrayList(Value) = .empty;
                    x.operand(b.l, cur, last, &l) catch |e| return x.unknownOn(e);
                    x.operand(b.r, cur, last, &r) catch |e| return x.unknownOn(e);
                    var found = false;
                    var err = false;
                    for (l.items) |p| for (r.items) |q| switch (cmp(b.op, p, q)) {
                        .true => {
                            if (!x.strict) return .true;
                            found = true;
                        },
                        .false => {},
                        .unknown => {
                            if (x.strict) return .unknown;
                            err = true;
                        },
                    };
                    if (found) return .true;
                    return if (err) .unknown else .false;
                },
                else => {
                    const v = x.single(n, cur, last, b.op, "left") catch |e| return x.unknownOn(e);
                    _ = v;
                    return .unknown;
                },
            },
            .unary => |u| switch (u.op) {
                .not => return switch (try x.pred(u.e, cur, last)) {
                    .true => .false,
                    .false => .true,
                    .unknown => .unknown,
                },
                else => return .unknown,
            },
            .exists => |e| {
                var r: std.ArrayList(Value) = .empty;
                x.eval(e, cur, last, &r) catch |err| return x.unknownOn(err);
                return if (r.items.len > 0) .true else .false;
            },
            .starts_with => |s| {
                var l: std.ArrayList(Value) = .empty;
                var r: std.ArrayList(Value) = .empty;
                x.operand(s.l, cur, last, &l) catch |e| return x.unknownOn(e);
                x.eval(s.r, cur, last, &r) catch |e| return x.unknownOn(e);
                if (r.items.len != 1 or r.items[0].v != .string) return .unknown;
                var err = false;
                for (l.items) |v| {
                    if (v.v != .string) {
                        err = true;
                        continue;
                    }
                    if (std.mem.startsWith(u8, v.v.string, r.items[0].v.string)) return .true;
                }
                return if (err) .unknown else .false;
            },
            .is_unknown => |e| return if (try x.pred(e, cur, last) == .unknown) .true else .false,
            else => {
                // A path used as a predicate: its single boolean.
                var r: std.ArrayList(Value) = .empty;
                x.eval(n, cur, last, &r) catch |err| return x.unknownOn(err);
                if (r.items.len == 1 and r.items[0].v == .bool) return if (r.items[0].v.bool) .true else .false;
                return .unknown;
            },
        }
    }

    fn unknownOn(x: *Exec, e: Error) Error!Truth {
        _ = x;
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .unknown;
    }

    /// The items of a comparison operand (lax mode unwraps arrays).
    fn operand(x: *Exec, n: *const Node, cur: Value, last: ?i64, out: *std.ArrayList(Value)) Error!void {
        var r: std.ArrayList(Value) = .empty;
        try x.eval(n, cur, last, &r);
        for (r.items) |v| {
            if (!x.strict and v.v == .array) try out.appendSlice(x.a, v.v.array) else try out.append(x.a, v);
        }
    }

    /// The items of path `p` for the document.
    pub fn run(x: *Exec, p: Path) Error![]Value {
        var out: std.ArrayList(Value) = .empty;
        try x.eval(p.expr, x.root, null, &out);
        return out.items;
    }

    /// The truth of predicate path `p` (null for unknown).
    pub fn match(x: *Exec, p: Path) Error!?bool {
        if (p.isPredicate()) return switch (try x.pred(p.expr, x.root, null)) {
            .true => true,
            .false => false,
            .unknown => null,
        };
        const items = try x.run(p);
        if (items.len == 1) switch (items[0].v) {
            .bool => |b| return b,
            .null => return null,
            else => {},
        };
        return x.fail("single boolean result is expected", .{});
    }
};

/// A decimal: `v` / 10^scale.
const Dec = struct {
    v: i128,
    scale: u32,

    fn parse(t: []const u8) ?Dec {
        var s = t;
        var neg = false;
        if (s.len > 0 and s[0] == '-') {
            neg = true;
            s = s[1..];
        }
        if (std.mem.indexOfAny(u8, s, "eE") != null) return null;
        var v: i128 = 0;
        var scale: u32 = 0;
        var seen_dot = false;
        var digits: u32 = 0;
        for (s) |c| {
            if (c == '.') {
                seen_dot = true;
                continue;
            }
            if (!std.ascii.isDigit(c)) return null;
            digits += 1;
            if (digits > 36) return null;
            v = v * 10 + (c - '0');
            if (seen_dot) scale += 1;
        }
        return .{ .v = if (neg) -v else v, .scale = scale };
    }

    fn pow10(n: u32) ?i128 {
        if (n > 37) return null;
        var p: i128 = 1;
        for (0..n) |_| p *= 10;
        return p;
    }

    fn rescale(d: Dec, scale: u32) ?i128 {
        return std.math.mul(i128, d.v, pow10(scale - d.scale) orelse return null) catch null;
    }

    /// (weight, first digit) of |d| in base 10000, as numeric stores it.
    fn weightDigit(d: Dec) struct { i32, i128 } {
        var a = if (d.v < 0) -d.v else d.v;
        if (a == 0) return .{ 0, 0 };
        // Make the scale a multiple of 4 so groups line up with the point.
        var sc: i32 = @intCast(d.scale);
        while (@mod(sc, 4) != 0) : (sc += 1) a *= 10;
        var w: i32 = -@divExact(sc, 4) - 1;
        var top: i128 = a;
        while (top >= 10000) {
            top = @divTrunc(top, 10000);
            w += 1;
        }
        return .{ w + 1, top };
    }

    fn apply(op: Op, l: Dec, r: Dec) ?Dec {
        const s = @max(l.scale, r.scale);
        switch (op) {
            .add, .sub, .mod => {
                const a = l.rescale(s) orelse return null;
                const b = r.rescale(s) orelse return null;
                const v = switch (op) {
                    .add => std.math.add(i128, a, b) catch return null,
                    .sub => std.math.sub(i128, a, b) catch return null,
                    else => @rem(a, b),
                };
                return .{ .v = v, .scale = s };
            },
            .mul => return .{ .v = std.math.mul(i128, l.v, r.v) catch return null, .scale = l.scale + r.scale },
            .div => {
                const wl = l.weightDigit();
                const wr = r.weightDigit();
                var qweight = wl[0] - wr[0];
                if (wl[1] <= wr[1]) qweight -= 1;
                var rscale: i32 = 16 - qweight * 4;
                rscale = @max(rscale, @as(i32, @intCast(l.scale)), @as(i32, @intCast(r.scale)), 0);
                const rs: u32 = @intCast(@min(rscale, 30));
                // l / r * 10^rs, rounded half away from zero.
                const shift = @as(i32, @intCast(rs)) + @as(i32, @intCast(r.scale)) - @as(i32, @intCast(l.scale)) + 1;
                if (shift < 0) return null;
                const num = std.math.mul(i128, l.v, pow10(@intCast(shift)) orelse return null) catch return null;
                var q = @divTrunc(num, r.v);
                const neg = q < 0;
                if (neg) q = -q;
                q = @divTrunc(q + 5, 10);
                return .{ .v = if (neg) -q else q, .scale = rs };
            },
            else => return null,
        }
    }

    fn text(d: Dec, a: Allocator) Error![]const u8 {
        const neg = d.v < 0;
        const abs: u128 = @intCast(if (neg) -d.v else d.v);
        var digits = try std.fmt.allocPrint(a, "{d}", .{abs});
        if (digits.len <= d.scale) {
            const pad = try a.alloc(u8, d.scale + 1 - digits.len);
            @memset(pad, '0');
            digits = try std.mem.concat(a, u8, &.{ pad, digits });
        }
        const ip = digits[0 .. digits.len - d.scale];
        const fp = digits[digits.len - d.scale ..];
        const sign: []const u8 = if (neg and abs != 0) "-" else "";
        if (d.scale == 0) return std.mem.concat(a, u8, &.{ sign, ip });
        return std.mem.concat(a, u8, &.{ sign, ip, ".", fp });
    }
};

fn cmp(op: Op, p: Value, q: Value) Truth {
    const pn = p.v == .null;
    const qn = q.v == .null;
    if (pn or qn) {
        if (pn and qn) return truth(op, .eq);
        return if (op == .ne) .true else .false;
    }
    const o: std.math.Order = switch (p.v) {
        .number => |a| if (q.v == .number) json.numCompare(a, q.v.number) else return .unknown,
        .string => |a| if (q.v == .string) std.mem.order(u8, a, q.v.string) else return .unknown,
        .bool => |a| if (q.v == .bool) std.math.order(@intFromBool(a), @intFromBool(q.v.bool)) else return .unknown,
        else => return .unknown,
    };
    return truth(op, o);
}

fn truth(op: Op, o: std.math.Order) Truth {
    const r = switch (op) {
        .eq => o == .eq,
        .ne => o != .eq,
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
        else => false,
    };
    return if (r) .true else .false;
}

fn opText(op: Op) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        else => "?",
    };
}

fn allZeros(s: []const u8) bool {
    for (s) |c| if (c != '0') return false;
    return true;
}

/// The decimal digits `s` plus one.
fn incDigits(a: Allocator, s: []const u8) Error![]const u8 {
    const out = try a.alloc(u8, s.len + 1);
    @memcpy(out[1..], s);
    out[0] = '0';
    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (out[i] == '9') {
            out[i] = '0';
        } else {
            out[i] += 1;
            break;
        }
    }
    return if (out[0] == '0') out[1..] else out;
}

/// A float as a JSON number: integral values without a fraction.
pub fn formatNumber(a: Allocator, v: f64) Error![]const u8 {
    if (v == @trunc(v) and @abs(v) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(v))});
    const t = try std.fmt.allocPrint(a, "{d}", .{v});
    return json.numericOut(a, t) catch t;
}

// ================================================================= tests

fn expectQuery(doc: []const u8, path: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};
    const p = try compile(a, path, &diag);
    var x: Exec = .{ .a = a, .root = try json.parseJsonb(a, doc), .vars = null, .strict = p.strict, .diag = &diag };
    const items = try x.run(p);
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |v, i| {
        if (i > 0) try out.append(a, ';');
        try json.writeJsonb(a, &out, v);
    }
    try std.testing.expectEqualStrings(want, out.items);
}

test "jsonpath" {
    const doc = "{\"a\": [1, 2, 3, 4], \"b\": {\"c\": \"x\", \"d\": null}, \"e\": [{\"f\": 1}, {\"f\": 5}]}";
    try expectQuery(doc, "$.a[*]", "1;2;3;4");
    try expectQuery(doc, "$.a[*] ? (@ > 2)", "3;4");
    try expectQuery(doc, "$.a[1 to 2]", "2;3");
    try expectQuery(doc, "$.a[last]", "4");
    try expectQuery(doc, "$.a[last - 1]", "3");
    try expectQuery(doc, "$.b.c", "\"x\"");
    try expectQuery(doc, "$.b.*", "\"x\";null");
    try expectQuery(doc, "$.e.f", "1;5");
    try expectQuery(doc, "$.e[*] ? (@.f > 2).f", "5");
    try expectQuery(doc, "$.nope", "");
    try expectQuery(doc, "$.a.size()", "4");
    try expectQuery(doc, "$.b.type()", "\"object\"");
    try expectQuery(doc, "$.a[0] + 10", "11");
    try expectQuery("{\"a\": 10}", "$.a / 3", "3.3333333333333333");
    try expectQuery("{\"a\": 1}", "$.a / 3", "0.33333333333333333333");
    try expectQuery("{\"a\": 1.5}", "$.a * 2", "3.0");
    try expectQuery("{\"a\": 7}", "$.a % 3", "1");
    try expectQuery("{\"a\": 10}", "$.a / 2", "5.0000000000000000");
    try expectQuery(doc, "$.a[*] ? (@ == 1 || @ == 4)", "1;4");
    try expectQuery(doc, "$.b ? (exists (@.c))", "{\"c\": \"x\", \"d\": null}");
    try expectQuery(doc, "$.b.c starts with \"x\"", "true");
    try expectQuery(doc, "$.a[*] > 3", "true");
    try expectQuery(doc, "-$.a[0]", "-1");
    try expectQuery("1.5", "$.floor()", "1");
    try expectQuery("-1.5", "$.ceiling()", "-1");
    try expectQuery("-1.5", "$.floor()", "-2");
    try expectQuery("{\"a\":{\"b\":{\"c\":1}}}", "$.**", "{\"a\": {\"b\": {\"c\": 1}}};{\"b\": {\"c\": 1}};{\"c\": 1};1");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try std.testing.expectError(error.Syntax, compile(arena.allocator(), "$.a[", &diag));
    try std.testing.expectError(error.Syntax, compile(arena.allocator(), "@.a", &diag));
}
