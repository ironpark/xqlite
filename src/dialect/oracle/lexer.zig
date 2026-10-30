//! The lexical structure of Oracle SQL, for what the Oracle dialect
//! parses:
//!
//!  - identifiers: unquoted ones fold to UPPER case (ASCII), "quoted"
//!    ones keep their case ("" is a quote); `$` and `#` may follow the
//!    first character;
//!  - strings: '...' ('' is a quote), N'...', and the alternative quoting
//!    q'[...]' (also Q, nq; the delimiters [] {} () <> or any other
//!    character twice);
//!  - numbers: 42, 4.2, .5, 1e10, with an f/d suffix (BINARY_FLOAT and
//!    BINARY_DOUBLE literals) ignored;
//!  - bind variables :name and :1 (`text` with the colon);
//!  - comments: -- to the end of the line and /* ... */ (not nested);
//!  - a `/` alone on its line ends a statement, as in SQL*Plus scripts;
//!  - operators: || <> != ^= ~= <= >= => and the single characters.
//!
//! Tokens carry their byte range in the statement text and their value:
//! the folded name of an identifier, the decoded text of a string or
//! quoted identifier (allocated in the arena when it differs from the
//! source).

const std = @import("std");
const lex = @import("../lex.zig");
const ctype = @import("xqlite_base").ctype;

pub const Kind = enum {
    eof,
    /// An unquoted identifier or keyword; `text` is folded to upper case.
    ident,
    /// A "quoted identifier"; `text` is the name.
    qident,
    /// A string constant; `text` is its value.
    string,
    integer,
    float,
    /// :name or :1; `text` is the spelling with the colon.
    param,
    /// An operator; `text` is its spelling.
    op,
    lparen,
    rparen,
    comma,
    semi,
    dot,
};

pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    text: []const u8,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    /// Whether this is the unquoted keyword `kw` (any case). Identifiers
    /// fold to upper case, so `kw` is folded once, at compile time.
    pub fn isKw(t: Token, comptime kw: []const u8) bool {
        const upper = comptime blk: {
            var u: [kw.len]u8 = undefined;
            for (kw, &u) |c, *o| o.* = std.ascii.toUpper(c);
            const final = u;
            break :blk final;
        };
        return t.kind == .ident and std.mem.eql(u8, t.text, &upper);
    }

    pub fn isAnyKw(t: Token, comptime kws: []const []const u8) bool {
        inline for (kws) |kw| if (t.isKw(kw)) return true;
        return false;
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
                l.pos += 2;
                while (true) {
                    if (s[l.pos] == 0) return l.fail(start, "ORA-01742: comment not properly terminated", .{});
                    if (s[l.pos] == '*' and s[l.pos + 1] == '/') {
                        l.pos += 2;
                        break;
                    }
                    l.pos += 1;
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
            ',' => return l.single(.comma),
            ';' => return l.single(.semi),
            '/' => if (l.slashLine(start)) return l.single(.semi),
            ':' => {
                const n = s[start + 1];
                if (isDigit(n) or isIdentStart(n)) {
                    var e = start + 1;
                    while (isIdentChar(s[e])) e += 1;
                    l.pos = e;
                    return l.tok(.param, start, e, s[start..e]);
                }
                if (n == '"') {
                    // :"Name"
                    l.pos = start + 1;
                    const q = try l.quotedIdent();
                    return l.tok(.param, start, q.end, try std.mem.concat(l.arena, u8, &.{ ":", q.text }));
                }
            },
            '.' => {
                if (isDigit(s[start + 1])) return l.number();
                return l.single(.dot);
            },
            '\'' => return l.string(start, start),
            '"' => return l.quotedIdent(),
            '0'...'9' => return l.number(),
            else => {},
        }
        if (isIdentStart(c)) {
            // N'...', q'[...]', nq'[...]'.
            const c1 = s[start + 1];
            if ((c == 'n' or c == 'N') and c1 == '\'') return l.string(start, start + 1);
            if ((c == 'q' or c == 'Q') and c1 == '\'') return l.qString(start, start + 1);
            if ((c == 'n' or c == 'N') and (c1 == 'q' or c1 == 'Q') and s[start + 2] == '\'') return l.qString(start, start + 2);
            var e = start;
            var upper = true;
            while (isIdentChar(s[e])) : (e += 1) {
                if (s[e] >= 'a' and s[e] <= 'z') upper = false;
            }
            l.pos = e;
            const raw = s[start..e];
            if (upper) return l.tok(.ident, start, e, raw);
            const folded = try l.arena.alloc(u8, raw.len);
            for (raw, folded) |ch, *o| o.* = std.ascii.toUpper(ch);
            return l.tok(.ident, start, e, folded);
        }
        if (isOpChar(c)) return l.operator();
        return l.fail(start, "ORA-00911: {s}: invalid character", .{s[start .. start + utf8Len(c, s[start..])]});
    }

    /// Whether the `/` at `at` is alone on its line (spaces aside): a
    /// statement terminator of SQL*Plus scripts.
    fn slashLine(l: *Lexer, at: usize) bool {
        const s = l.src;
        var i = at;
        while (i > 0) {
            i -= 1;
            if (s[i] == '\n') break;
            if (s[i] != ' ' and s[i] != '\t' and s[i] != '\r') return false;
        }
        var j = at + 1;
        while (s[j] != 0 and s[j] != '\n') : (j += 1) {
            if (s[j] != ' ' and s[j] != '\t' and s[j] != '\r') return false;
        }
        return true;
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
        while (isDigit(s[e])) e += 1;
        if (s[e] == '.' and s[e + 1] != '.') {
            is_float = true;
            e += 1;
            while (isDigit(s[e])) e += 1;
        }
        if ((s[e] == 'e' or s[e] == 'E') and (isDigit(s[e + 1]) or ((s[e + 1] == '+' or s[e + 1] == '-') and isDigit(s[e + 2])))) {
            is_float = true;
            e += 2;
            while (isDigit(s[e])) e += 1;
        }
        var text: []const u8 = s[start..e];
        // 1.5f, 2d: BINARY_FLOAT/BINARY_DOUBLE literals.
        var end = e;
        if ((s[e] == 'f' or s[e] == 'F' or s[e] == 'd' or s[e] == 'D') and !isIdentChar(s[e + 1])) {
            end = e + 1;
            is_float = true;
        }
        l.pos = end;
        if (text[0] == '.') text = try std.mem.concat(l.arena, u8, &.{ "0", text });
        if (text[text.len - 1] == '.') text = try std.mem.concat(l.arena, u8, &.{ text, "0" });
        // An integer too large for 64 bits is a real.
        if (!is_float and std.fmt.parseInt(i64, text, 10) == error.Overflow) is_float = true;
        return l.tok(if (is_float) .float else .integer, start, end, text);
    }

    /// A string constant whose opening quote is at `quote` (the token
    /// starts at `start`, before an N prefix).
    fn string(l: *Lexer, start: usize, quote: usize) Error!Token {
        const q = try lex.undoubled(l.arena, l.src, quote, '\'') orelse
            return l.fail(start, "ORA-01756: quoted string not properly terminated", .{});
        l.pos = q.end;
        return l.tok(.string, start, q.end, q.text);
    }

    /// q'<d>...<d>' with the quote at `quote`.
    fn qString(l: *Lexer, start: usize, quote: usize) Error!Token {
        const s = l.src;
        const open = s[quote + 1];
        if (open == 0 or isSpace(open)) return l.fail(start, "ORA-01756: quoted string not properly terminated", .{});
        const close: u8 = switch (open) {
            '[' => ']',
            '{' => '}',
            '(' => ')',
            '<' => '>',
            else => open,
        };
        const body = quote + 2;
        var i = body;
        while (true) : (i += 1) {
            if (s[i] == 0) return l.fail(start, "ORA-01756: quoted string not properly terminated", .{});
            if (s[i] == close and s[i + 1] == '\'') break;
        }
        l.pos = i + 2;
        return l.tok(.string, start, l.pos, s[body..i]);
    }

    fn quotedIdent(l: *Lexer) Error!Token {
        const start = l.pos;
        const q = try lex.undoubled(l.arena, l.src, start, '"') orelse
            return l.fail(start, "ORA-01740: missing double quote in identifier", .{});
        l.pos = q.end;
        if (q.text.len == 0) return l.fail(start, "ORA-01741: illegal zero-length identifier", .{});
        return l.tok(.qident, start, q.end, q.text);
    }

    fn operator(l: *Lexer) Token {
        const s = l.src;
        const start = l.pos;
        const two = [_][]const u8{ "||", "<>", "!=", "^=", "~=", "<=", ">=", "=>" };
        for (two) |op| {
            if (s[start] == op[0] and s[start + 1] == op[1]) {
                l.pos = start + 2;
                return l.tok(.op, start, l.pos, s[start..l.pos]);
            }
        }
        l.pos = start + 1;
        return l.tok(.op, start, l.pos, s[start..l.pos]);
    }
};

const isSpace = ctype.isSpace;
const isDigit = ctype.isDigit;

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c) or c == '$' or c == '#';
}

fn isOpChar(c: u8) bool {
    return c != 0 and std.mem.indexOfScalar(u8, "+-*/<>=!^~|@%&?:[]", c) != null;
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

test "oracle lexer: identifiers fold to upper case, quoted ones keep theirs" {
    try expectTokens("select Foo, \"Bar\", \"a\"\"b\", x$1#, emp_id FROM t", &.{
        .{ .ident, "SELECT" }, .{ .ident, "FOO" }, .{ .comma, "," },    .{ .qident, "Bar" }, .{ .comma, "," },
        .{ .qident, "a\"b" },  .{ .comma, "," },   .{ .ident, "X$1#" }, .{ .comma, "," },    .{ .ident, "EMP_ID" },
        .{ .ident, "FROM" },   .{ .ident, "T" },
    });
}

test "oracle lexer: strings" {
    try expectTokens("'it''s' '' N'x' q'[a'b]' Q'{c}' q'!d!' nq'<e>'", &.{
        .{ .string, "it's" }, .{ .string, "" },  .{ .string, "x" }, .{ .string, "a'b" },
        .{ .string, "c" },    .{ .string, "d" }, .{ .string, "e" },
    });
    try expectLexError("SELECT 'abc", "ORA-01756: quoted string not properly terminated");
    try expectLexError("SELECT q'[abc'", "ORA-01756: quoted string not properly terminated");
    try expectLexError("SELECT \"\"", "ORA-01741: illegal zero-length identifier");
}

test "oracle lexer: numbers, binds, operators, comments, slash lines" {
    try expectTokens("1 1.5 .5 1e3 2.5E-2 3. 1.5f 2d :x :1 :Abc", &.{
        .{ .integer, "1" },  .{ .float, "1.5" }, .{ .float, "0.5" }, .{ .float, "1e3" }, .{ .float, "2.5E-2" },
        .{ .float, "3.0" },  .{ .float, "1.5" }, .{ .float, "2" },   .{ .param, ":x" },  .{ .param, ":1" },
        .{ .param, ":Abc" },
    });
    try expectTokens("a||b<>c!=d^=e<=f>=g", &.{
        .{ .ident, "A" }, .{ .op, "||" }, .{ .ident, "B" }, .{ .op, "<>" }, .{ .ident, "C" }, .{ .op, "!=" },
        .{ .ident, "D" }, .{ .op, "^=" }, .{ .ident, "E" }, .{ .op, "<=" }, .{ .ident, "F" }, .{ .op, ">=" },
        .{ .ident, "G" },
    });
    try expectTokens("a /* x */ + -- c\n b / c\n /\n", &.{
        .{ .ident, "A" }, .{ .op, "+" }, .{ .ident, "B" }, .{ .op, "/" }, .{ .ident, "C" }, .{ .semi, "/" },
    });
    try expectLexError("/* a", "ORA-01742: comment not properly terminated");
}
