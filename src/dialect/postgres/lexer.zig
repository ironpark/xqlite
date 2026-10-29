//! The lexical structure of PostgreSQL (the scanner of src/backend/parser
//! /scan.l, for what the PostgreSQL dialect parses):
//!
//!  - identifiers: unquoted ones fold to lower case (ASCII), "quoted"
//!    ones keep their case ("" is a quote); backticks and [brackets] are
//!    not identifiers;
//!  - strings: '...' ('' is a quote, and two strings separated by
//!    whitespace with a newline are one), E'...' with backslash escapes,
//!    N'...', and dollar quoting $$...$$ / $tag$...$tag$;
//!  - numbers: 42, 4.2, .5, 1e10, 0x1F, 0o17, 0b101, 1_000;
//!  - $1 positional parameters;
//!  - comments: -- to the end of the line and nested /* ... */;
//!  - operators: any run of + - * / < > = ~ ! @ # % ^ & | ` ?, cut
//!    before -- and /*, and without a trailing + or - unless the run has
//!    one of ~ ! @ # % ^ & | ` ? (so that a<-1 is a < -1); `::` is the
//!    cast operator.
//!
//! Tokens carry their byte range in the statement text and their value:
//! the folded name of an identifier, the decoded text of a string or
//! quoted identifier (allocated in the arena when it differs from the
//! source).

const std = @import("std");

pub const Kind = enum {
    eof,
    /// An unquoted identifier or keyword; `text` is folded to lower case.
    ident,
    /// A "quoted identifier"; `text` is the name.
    qident,
    /// A string constant; `text` is its value.
    string,
    integer,
    float,
    /// $n; `text` is the digits.
    param,
    /// An operator; `text` is its spelling.
    op,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    semi,
    dot,
    colon,
    /// `::`
    cast,
};

pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    text: []const u8,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    /// Whether this is the unquoted keyword `kw` (lower case).
    pub fn isKw(t: Token, kw: []const u8) bool {
        return t.kind == .ident and std.mem.eql(u8, t.text, kw);
    }

    pub fn isOp(t: Token, op: []const u8) bool {
        return t.kind == .op and std.mem.eql(u8, t.text, op);
    }
};

pub const Error = error{ LexFailed, OutOfMemory };

pub const Lexer = struct {
    src: [:0]const u8,
    pos: usize,
    arena: std.mem.Allocator,
    /// The message of the last error (error.LexFailed), and where.
    err_msg: []const u8 = "",
    err_pos: usize = 0,

    pub fn init(arena: std.mem.Allocator, src: [:0]const u8, pos: usize) Lexer {
        return .{ .src = src, .pos = pos, .arena = arena };
    }

    fn fail(l: *Lexer, at: usize, comptime fmt: []const u8, args: anytype) Error {
        l.err_pos = at;
        l.err_msg = try std.fmt.allocPrint(l.arena, fmt, args);
        return error.LexFailed;
    }

    /// The text from `at` to the end of the line, for "at or near".
    fn near(l: *Lexer, at: usize) []const u8 {
        var e = at;
        while (e < l.src.len and l.src[e] != '\n') e += 1;
        return l.src[at..e];
    }

    /// Skip spaces and comments. Returns an error for an unterminated
    /// block comment.
    pub fn skipSpace(l: *Lexer) Error!void {
        const s = l.src;
        while (true) {
            const c = s[l.pos];
            if (isSpace(c)) {
                l.pos += 1;
            } else if (c == '-' and s[l.pos + 1] == '-') {
                while (s[l.pos] != 0 and s[l.pos] != '\n') l.pos += 1;
            } else if (c == '/' and s[l.pos + 1] == '*') {
                const start = l.pos;
                var depth: usize = 0;
                while (true) {
                    if (s[l.pos] == 0) return l.fail(start, "unterminated /* comment at or near \"{s}\"", .{l.near(start)});
                    if (s[l.pos] == '/' and s[l.pos + 1] == '*') {
                        depth += 1;
                        l.pos += 2;
                    } else if (s[l.pos] == '*' and s[l.pos + 1] == '/') {
                        depth -= 1;
                        l.pos += 2;
                        if (depth == 0) break;
                    } else {
                        l.pos += 1;
                    }
                }
            } else {
                return;
            }
        }
    }

    pub fn next(l: *Lexer) Error!Token {
        try l.skipSpace();
        const s = l.src;
        const start = l.pos;
        const c = s[start];
        if (c == 0) return l.tok(.eof, start, start, "");
        switch (c) {
            '(' => return l.single(.lparen),
            ')' => return l.single(.rparen),
            '[' => return l.single(.lbracket),
            ']' => return l.single(.rbracket),
            ',' => return l.single(.comma),
            ';' => return l.single(.semi),
            ':' => {
                if (s[start + 1] == ':') {
                    l.pos += 2;
                    return l.tok(.cast, start, l.pos, "::");
                }
                if (s[start + 1] == '=') {
                    l.pos += 2;
                    return l.tok(.op, start, l.pos, ":=");
                }
                return l.single(.colon);
            },
            '.' => {
                if (isDigit(s[start + 1])) return l.number();
                return l.single(.dot);
            },
            '\'' => return l.string(start, start, false),
            '"' => return l.quotedIdent(),
            '$' => {
                if (isDigit(s[start + 1])) {
                    var e = start + 1;
                    while (isDigit(s[e])) e += 1;
                    if (isIdentChar(s[e])) return l.fail(start, "trailing junk after parameter at or near \"{s}\"", .{s[start .. e + 1]});
                    l.pos = e;
                    return l.tok(.param, start, e, s[start + 1 .. e]);
                }
                if (l.dollarTag(start)) |tag_end| return l.dollarString(start, tag_end);
                return l.fail(start, "syntax error at or near \"$\"", .{});
            },
            '0'...'9' => return l.number(),
            else => {},
        }
        if (isIdentStart(c)) {
            // E'...', N'...' (one letter right before a quote).
            if (s[start + 1] == '\'') {
                if (c == 'e' or c == 'E') return l.string(start, start + 1, true);
                if (c == 'n' or c == 'N') return l.string(start, start + 1, false);
            }
            var e = start;
            var lower = true;
            while (isIdentChar(s[e])) : (e += 1) {
                if (s[e] >= 'A' and s[e] <= 'Z') lower = false;
            }
            l.pos = e;
            const raw = s[start..e];
            if (lower) return l.tok(.ident, start, e, raw);
            const folded = try l.arena.alloc(u8, raw.len);
            for (raw, folded) |ch, *o| o.* = std.ascii.toLower(ch);
            return l.tok(.ident, start, e, folded);
        }
        if (isOpChar(c)) return l.operator();
        return l.fail(start, "syntax error at or near \"{s}\"", .{s[start .. start + utf8Len(c, s[start..])]});
    }

    fn tok(l: *Lexer, kind: Kind, start: usize, end: usize, text: []const u8) Token {
        _ = l;
        return .{ .kind = kind, .start = @intCast(start), .end = @intCast(end), .text = text };
    }

    fn single(l: *Lexer, kind: Kind) Token {
        const start = l.pos;
        l.pos += 1;
        return l.tok(kind, start, l.pos, l.src[start..l.pos]);
    }

    fn number(l: *Lexer) Error!Token {
        const s = l.src;
        const start = l.pos;
        var e = start;
        var is_float = false;
        var underscores = false;
        if (s[e] == '0' and (s[e + 1] == 'x' or s[e + 1] == 'X' or s[e + 1] == 'o' or s[e + 1] == 'O' or s[e + 1] == 'b' or s[e + 1] == 'B')) {
            const base: u8 = switch (s[e + 1]) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                else => 2,
            };
            e += 2;
            const ds = e;
            while (std.ascii.isAlphanumeric(s[e]) or s[e] == '_') e += 1;
            l.pos = e;
            var digits: std.ArrayList(u8) = .empty;
            for (s[ds..e]) |ch| if (ch != '_') try digits.append(l.arena, ch);
            const v = std.fmt.parseInt(i64, digits.items, base) catch
                return l.fail(start, "invalid {s} integer at or near \"{s}\"", .{ switch (base) {
                    16 => "hexadecimal",
                    8 => "octal",
                    else => "binary",
                }, s[start..e] });
            return l.tok(.integer, start, e, try std.fmt.allocPrint(l.arena, "{d}", .{v}));
        }
        while (isDigit(s[e]) or (s[e] == '_' and isDigit(s[e + 1]))) : (e += 1) {
            if (s[e] == '_') underscores = true;
        }
        if (s[e] == '.' and s[e + 1] != '.') {
            is_float = true;
            e += 1;
            while (isDigit(s[e]) or (s[e] == '_' and isDigit(s[e + 1]))) : (e += 1) {
                if (s[e] == '_') underscores = true;
            }
        }
        if ((s[e] == 'e' or s[e] == 'E') and (isDigit(s[e + 1]) or ((s[e + 1] == '+' or s[e + 1] == '-') and isDigit(s[e + 2])))) {
            is_float = true;
            e += 2;
            while (isDigit(s[e])) e += 1;
        }
        if (isIdentStart(s[e])) {
            var j = e;
            while (isIdentChar(s[j])) j += 1;
            return l.fail(start, "trailing junk after numeric literal at or near \"{s}\"", .{s[start..j]});
        }
        l.pos = e;
        var text: []const u8 = s[start..e];
        if (underscores) {
            var out: std.ArrayList(u8) = .empty;
            for (text) |ch| if (ch != '_') try out.append(l.arena, ch);
            text = out.items;
        }
        if (text[0] == '.') text = try std.mem.concat(l.arena, u8, &.{ "0", text });
        return l.tok(if (is_float) .float else .integer, start, e, text);
    }

    /// A string constant whose opening quote is at `quote` (the token
    /// starts at `start`, before an E or N prefix).
    fn string(l: *Lexer, start: usize, quote: usize, escapes: bool) Error!Token {
        const s = l.src;
        var out: std.ArrayList(u8) = .empty;
        var i = quote + 1;
        var copied = false;
        var seg_start = i;
        while (true) {
            const ch = s[i];
            if (ch == 0) return l.fail(start, "unterminated quoted string at or near \"{s}\"", .{l.near(start)});
            if (ch == '\'') {
                if (s[i + 1] == '\'') {
                    try out.appendSlice(l.arena, s[seg_start..i]);
                    try out.append(l.arena, '\'');
                    copied = true;
                    i += 2;
                    seg_start = i;
                    continue;
                }
                try out.appendSlice(l.arena, s[seg_start..i]);
                i += 1;
                // 'a'
                // 'b' is 'ab': the next string after whitespace with a newline.
                var j = i;
                var newline = false;
                while (isSpace(s[j])) : (j += 1) {
                    if (s[j] == '\n' or s[j] == '\r') newline = true;
                }
                if (newline and s[j] == '\'') {
                    copied = true;
                    i = j + 1;
                    seg_start = i;
                    continue;
                }
                break;
            }
            if (escapes and ch == '\\') {
                try out.appendSlice(l.arena, s[seg_start..i]);
                copied = true;
                i = try l.escape(start, i, &out);
                seg_start = i;
                continue;
            }
            i += 1;
        }
        l.pos = i;
        const value = if (copied) out.items else s[quote + 1 .. i - 1];
        return l.tok(.string, start, i, value);
    }

    /// One backslash escape of an E'' string at `i`; returns the index
    /// after it.
    fn escape(l: *Lexer, start: usize, i: usize, out: *std.ArrayList(u8)) Error!usize {
        const s = l.src;
        const c = s[i + 1];
        switch (c) {
            0 => return l.fail(start, "unterminated quoted string at or near \"{s}\"", .{l.near(start)}),
            'b' => try out.append(l.arena, 8),
            'f' => try out.append(l.arena, 12),
            'n' => try out.append(l.arena, '\n'),
            'r' => try out.append(l.arena, '\r'),
            't' => try out.append(l.arena, '\t'),
            '0'...'7' => {
                var v: u32 = 0;
                var j = i + 1;
                while (j < i + 4 and s[j] >= '0' and s[j] <= '7') : (j += 1) v = v * 8 + (s[j] - '0');
                try out.append(l.arena, @truncate(v));
                return j;
            },
            'x' => {
                var v: u32 = 0;
                var j = i + 2;
                while (j < i + 4 and std.ascii.isHex(s[j])) : (j += 1) v = v * 16 + (std.fmt.charToDigit(s[j], 16) catch 0);
                if (j == i + 2) {
                    try out.append(l.arena, 'x');
                    return i + 2;
                }
                try out.append(l.arena, @truncate(v));
                return j;
            },
            'u', 'U' => {
                const n: usize = if (c == 'u') 4 else 8;
                var v: u21 = 0;
                for (0..n) |k| {
                    const d = std.fmt.charToDigit(s[i + 2 + k], 16) catch
                        return l.fail(i, "invalid Unicode escape at or near \"{s}\"", .{s[i..@min(s.len, i + 2 + k + 1)]});
                    v = std.math.cast(u21, @as(u32, v) * 16 + d) orelse
                        return l.fail(i, "invalid Unicode escape value at or near \"{s}\"", .{s[i .. i + 2 + n]});
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(v, &buf) catch
                    return l.fail(i, "invalid Unicode escape value at or near \"{s}\"", .{s[i .. i + 2 + n]});
                try out.appendSlice(l.arena, buf[0..len]);
                return i + 2 + n;
            },
            else => try out.append(l.arena, c),
        }
        return i + 2;
    }

    fn quotedIdent(l: *Lexer) Error!Token {
        const s = l.src;
        const start = l.pos;
        var out: std.ArrayList(u8) = .empty;
        var i = start + 1;
        var seg = i;
        var copied = false;
        while (true) {
            if (s[i] == 0) return l.fail(start, "unterminated quoted identifier at or near \"{s}\"", .{l.near(start)});
            if (s[i] == '"') {
                if (s[i + 1] == '"') {
                    try out.appendSlice(l.arena, s[seg .. i + 1]);
                    copied = true;
                    i += 2;
                    seg = i;
                    continue;
                }
                try out.appendSlice(l.arena, s[seg..i]);
                i += 1;
                break;
            }
            i += 1;
        }
        l.pos = i;
        const name = if (copied) out.items else s[start + 1 .. i - 1];
        if (name.len == 0) return l.fail(start, "zero-length delimited identifier at or near \"\"\"\"", .{});
        return l.tok(.qident, start, i, name);
    }

    /// If a dollar-quote delimiter ($$ or $tag$) starts at `start`, the
    /// index after it.
    fn dollarTag(l: *Lexer, start: usize) ?usize {
        const s = l.src;
        var i = start + 1;
        if (s[i] == '$') return i + 1;
        if (!isIdentStart(s[i])) return null;
        while (isIdentChar(s[i]) and s[i] != '$') i += 1;
        if (s[i] != '$') return null;
        return i + 1;
    }

    fn dollarString(l: *Lexer, start: usize, tag_end: usize) Error!Token {
        const s = l.src;
        const tag = s[start..tag_end];
        const body = s[tag_end..];
        const n = std.mem.indexOf(u8, body, tag) orelse
            return l.fail(start, "unterminated dollar-quoted string at or near \"{s}\"", .{l.near(start)});
        l.pos = tag_end + n + tag.len;
        return l.tok(.string, start, l.pos, body[0..n]);
    }

    fn operator(l: *Lexer) Token {
        const s = l.src;
        const start = l.pos;
        var e = start;
        while (isOpChar(s[e])) : (e += 1) {
            // A comment starts inside the run: the operator ends there.
            if (e > start and ((s[e] == '-' and s[e + 1] == '-') or (s[e] == '/' and s[e + 1] == '*'))) break;
        }
        var n = e - start;
        if (n > 1 and (s[start + n - 1] == '+' or s[start + n - 1] == '-')) {
            var special = false;
            for (s[start .. start + n]) |ch| {
                if (std.mem.indexOfScalar(u8, "~!@#%^&|`?", ch) != null) special = true;
            }
            if (!special) {
                while (n > 1 and (s[start + n - 1] == '+' or s[start + n - 1] == '-')) n -= 1;
            }
        }
        l.pos = start + n;
        return l.tok(.op, start, l.pos, s[start..l.pos]);
    }
};

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c) or c == '$';
}

fn isOpChar(c: u8) bool {
    return c != 0 and std.mem.indexOfScalar(u8, "+-*/<>=~!@#%^&|`?", c) != null;
}

fn utf8Len(c: u8, rest: []const u8) usize {
    const n: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
    return @min(n, rest.len);
}

// ================================================================= tests

const testing = std.testing;

fn expectTokens(src: [:0]const u8, expected: []const struct { Kind, []const u8 }) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(arena.allocator(), src, 0);
    for (expected) |e| {
        const t = try l.next();
        testing.expectEqual(e[0], t.kind) catch |err| {
            std.debug.print("at {d}: {s}\n", .{ t.start, t.text });
            return err;
        };
        try testing.expectEqualStrings(e[1], t.text);
    }
    try testing.expectEqual(Kind.eof, (try l.next()).kind);
}

fn expectLexError(src: [:0]const u8, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(arena.allocator(), src, 0);
    while (true) {
        const t = l.next() catch |err| {
            try testing.expectEqual(error.LexFailed, err);
            try testing.expectEqualStrings(msg, l.err_msg);
            return;
        };
        if (t.kind == .eof) return error.TestExpectedError;
    }
}

test "pg lexer: identifiers fold, quoted ones keep their case" {
    try expectTokens("SELECT Foo, \"Bar\", \"a\"\"b\", _x1$ FROM t", &.{
        .{ .ident, "select" }, .{ .ident, "foo" }, .{ .comma, "," },    .{ .qident, "Bar" }, .{ .comma, "," },
        .{ .qident, "a\"b" },  .{ .comma, "," },   .{ .ident, "_x1$" }, .{ .ident, "from" }, .{ .ident, "t" },
    });
    // Backticks and brackets are not identifiers.
    try expectTokens("`a` [b]", &.{
        .{ .op, "`" }, .{ .ident, "a" }, .{ .op, "`" }, .{ .lbracket, "[" }, .{ .ident, "b" }, .{ .rbracket, "]" },
    });
}

test "pg lexer: strings" {
    try expectTokens("'it''s' E'a\\nb\\x41\\101\\u00e9' N'x' $$a'b$$ $f$ $$ $f$", &.{
        .{ .string, "it's" },
        .{ .string, "a\nbAAé" },
        .{ .string, "x" },
        .{ .string, "a'b" },
        .{ .string, " $$ " },
    });
    // Continuation over a newline only.
    try expectTokens("'a'\n  'b' 'c'", &.{ .{ .string, "ab" }, .{ .string, "c" } });
    try expectLexError("SELECT 'abc", "unterminated quoted string at or near \"'abc\"");
    try expectLexError("SELECT $q$abc", "unterminated dollar-quoted string at or near \"$q$abc\"");
    try expectLexError("SELECT \"ab", "unterminated quoted identifier at or near \"\"ab\"");
    try expectLexError("SELECT \"\"", "zero-length delimited identifier at or near \"\"\"\"");
}

test "pg lexer: numbers, parameters, operators, comments" {
    try expectTokens("1 1.5 .5 1e3 2.5E-2 0x1F 1_000 $1 $12", &.{
        .{ .integer, "1" },  .{ .float, "1.5" },    .{ .float, "0.5" }, .{ .float, "1e3" }, .{ .float, "2.5E-2" },
        .{ .integer, "31" }, .{ .integer, "1000" }, .{ .param, "1" },   .{ .param, "12" },
    });
    try expectTokens("a::int||b<>c!=d<=-1 a<-1 x~~y", &.{
        .{ .ident, "a" }, .{ .cast, "::" }, .{ .ident, "int" }, .{ .op, "||" },     .{ .ident, "b" }, .{ .op, "<>" },
        .{ .ident, "c" }, .{ .op, "!=" },   .{ .ident, "d" },   .{ .op, "<=" },     .{ .op, "-" },    .{ .integer, "1" },
        .{ .ident, "a" }, .{ .op, "<" },    .{ .op, "-" },      .{ .integer, "1" }, .{ .ident, "x" }, .{ .op, "~~" },
        .{ .ident, "y" },
    });
    try expectTokens("a /* x /* nested */ y */ + -- comment\n b", &.{ .{ .ident, "a" }, .{ .op, "+" }, .{ .ident, "b" } });
    try expectTokens("a+/*c*/b", &.{ .{ .ident, "a" }, .{ .op, "+" }, .{ .ident, "b" } });
    try expectLexError("/* a /* b */", "unterminated /* comment at or near \"/* a /* b */\"");
    try expectLexError("SELECT 123abc", "trailing junk after numeric literal at or near \"123abc\"");
}
