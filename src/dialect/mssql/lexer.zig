//! The T-SQL tokenizer.
//!
//! Tokens are slices of the statement text (so that the IR's offsets and
//! error positions point into it); the value of a string or a delimited
//! identifier is computed on demand (stringValue(), identValue()).
//!
//!  - Identifiers: words (letters, digits, `_`, `@`, `#`, `$`; `#t` and
//!    `##t` name temporary tables), `[bracketed]` (`]]` is a `]`) and
//!    `"quoted"` (QUOTED_IDENTIFIER ON, `""` is a `"`).
//!  - Strings: `'it''s'` and `N'unicode'`.
//!  - Numbers: integers, decimals, `1e3`, binary constants `0x0A1B`
//!    (`0x` alone is an empty one).
//!  - Variables: `@name` (a local variable) and `@@name` (a function such
//!    as @@ROWCOUNT).
//!  - Comments: `--` to the end of the line and `/* */`, which nest.
//!  - GO: the batch separator, a line holding only `GO` (and an optional
//!    count): a statement end, as `;`.

const std = @import("std");
const lex = @import("../lex.zig");

pub const Kind = enum {
    eof,
    /// An unquoted word: a keyword or a name.
    ident,
    /// [name] or "name".
    quoted_ident,
    /// '...' or N'...'.
    string,
    integer,
    /// A number with a fraction or an exponent.
    float,
    /// 0x0A1B: a binary constant.
    hex,
    /// `?`
    param,
    /// @name
    variable,
    /// @@name
    sys_var,
    /// Punctuation and operators: ( ) , . ; + - * / % = < > <= >= <> !=
    /// !< !> & | ^ ~ += -= *= /= %= &= |= ^= ::
    op,
    /// The batch separator GO.
    go,
    /// A character that starts no token, or an unterminated literal.
    illegal,
};

pub const Token = struct {
    kind: Kind,
    /// The text of the token in the statement.
    text: []const u8,

    pub fn is(t: Token, op: []const u8) bool {
        return t.kind == .op and std.mem.eql(u8, t.text, op);
    }

    /// An unquoted word equal to `kw` (case-insensitive).
    pub fn isKw(t: Token, kw: []const u8) bool {
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, kw);
    }

    pub fn isAnyKw(t: Token, comptime kws: []const []const u8) bool {
        inline for (kws) |kw| if (t.isKw(kw)) return true;
        return false;
    }

    pub fn end(t: Token) [*]const u8 {
        return t.text.ptr + t.text.len;
    }
};

pub const Lexer = struct {
    sql: [:0]const u8,
    pos: usize = 0,

    pub fn init(sql: [:0]const u8) Lexer {
        return .{ .sql = sql };
    }

    /// Skip spaces and comments (an unterminated /* comment runs to the
    /// end).
    fn skipSpace(lx: *Lexer) void {
        const s = lx.sql;
        while (true) {
            switch (s[lx.pos]) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => lx.pos += 1,
                '-' => {
                    if (s[lx.pos + 1] != '-') return;
                    while (s[lx.pos] != 0 and s[lx.pos] != '\n') lx.pos += 1;
                },
                '/' => {
                    if (s[lx.pos + 1] != '*') return;
                    var depth: usize = 1;
                    var i = lx.pos + 2;
                    while (s[i] != 0 and depth > 0) {
                        if (s[i] == '/' and s[i + 1] == '*') {
                            depth += 1;
                            i += 2;
                        } else if (s[i] == '*' and s[i + 1] == '/') {
                            depth -= 1;
                            i += 2;
                        } else i += 1;
                    }
                    lx.pos = i;
                },
                else => return,
            }
        }
    }

    pub fn next(lx: *Lexer) Token {
        lx.skipSpace();
        const s = lx.sql;
        const start = lx.pos;
        const c = s[start];
        if (c == 0) return .{ .kind = .eof, .text = s[start..start] };
        const kind: Kind = switch (c) {
            '[' => lx.quoted(start, ']', .quoted_ident),
            '"' => lx.quoted(start, '"', .quoted_ident),
            '\'' => lx.quoted(start, '\'', .string),
            '0'...'9' => lx.number(start),
            '.' => if (std.ascii.isDigit(s[start + 1])) lx.number(start) else lx.op1(),
            '?' => lx.op1Kind(.param),
            '@' => lx.variable(start),
            'n', 'N' => blk: {
                if (s[start + 1] == '\'') {
                    break :blk lx.quoted(start + 1, '\'', .string);
                }
                break :blk lx.word(start);
            },
            else => if (isIdentStart(c)) lx.word(start) else lx.operator(),
        };
        return .{ .kind = kind, .text = s[start..lx.pos] };
    }

    /// A quoted token from `start` (its opening quote): `q` ends it, a
    /// doubled `q` stands for one.
    fn quoted(lx: *Lexer, start: usize, q: u8, kind: Kind) Kind {
        const r = lex.quotedEnd(lx.sql, start, q, false);
        lx.pos = r.end;
        return if (r.closed) kind else .illegal;
    }

    fn number(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        var i = start;
        if (s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
            i += 2;
            while (std.ascii.isHex(s[i])) i += 1;
            lx.pos = i;
            return .hex;
        }
        var kind: Kind = .integer;
        while (std.ascii.isDigit(s[i])) i += 1;
        if (s[i] == '.') {
            kind = .float;
            i += 1;
            while (std.ascii.isDigit(s[i])) i += 1;
        }
        if ((s[i] == 'e' or s[i] == 'E') and (std.ascii.isDigit(s[i + 1]) or
            ((s[i + 1] == '+' or s[i + 1] == '-') and std.ascii.isDigit(s[i + 2]))))
        {
            kind = .float;
            i += 2;
            while (std.ascii.isDigit(s[i])) i += 1;
        }
        lx.pos = i;
        return kind;
    }

    /// A word, or GO alone on its line.
    fn word(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        while (isIdentChar(s[lx.pos])) lx.pos += 1;
        if (lx.pos - start == 2 and std.ascii.eqlIgnoreCase(s[start..lx.pos], "GO") and atLineStart(s, start)) {
            // GO [count] then the end of the line (or a comment).
            var i = lx.pos;
            while (s[i] == ' ' or s[i] == '\t') i += 1;
            while (std.ascii.isDigit(s[i])) i += 1;
            while (s[i] == ' ' or s[i] == '\t' or s[i] == '\r') i += 1;
            if (s[i] == 0 or s[i] == '\n' or (s[i] == '-' and s[i + 1] == '-')) {
                lx.pos = i;
                return .go;
            }
        }
        return .ident;
    }

    fn variable(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        const sys = s[start + 1] == '@';
        lx.pos = start + 1 + @intFromBool(sys);
        const first = lx.pos;
        while (isIdentChar(s[lx.pos])) lx.pos += 1;
        if (lx.pos == first) return .illegal;
        return if (sys) .sys_var else .variable;
    }

    fn op1(lx: *Lexer) Kind {
        lx.pos += 1;
        return .op;
    }

    fn op1Kind(lx: *Lexer, k: Kind) Kind {
        lx.pos += 1;
        return k;
    }

    fn operator(lx: *Lexer) Kind {
        const rest = lx.sql[lx.pos..];
        const ops2 = [_][]const u8{ "<=", ">=", "<>", "!=", "!<", "!>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::" };
        for (ops2) |o| if (std.mem.startsWith(u8, rest, o)) {
            lx.pos += 2;
            return .op;
        };
        switch (rest[0]) {
            '(', ')', ',', '.', ';', '+', '-', '*', '/', '%', '=', '<', '>', '~', '^', '&', '|', '{', '}', ':' => return lx.op1(),
            else => {
                lx.pos += 1;
                return .illegal;
            },
        }
    }
};

/// Whether only spaces are between the start of the line and `i`.
fn atLineStart(s: []const u8, i: usize) bool {
    var j = i;
    while (j > 0) {
        j -= 1;
        switch (s[j]) {
            ' ', '\t', '\r' => {},
            '\n' => return true,
            else => return false,
        }
    }
    return true;
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '#' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '#' or c == '$' or c == '@' or c >= 0x80;
}

/// The name an identifier token stands for: the word itself, or the
/// text between the delimiters with doubled closing delimiters undone
/// (in `a` if any).
pub fn identValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    if (t.kind != .quoted_ident) return t.text;
    const q: u8 = if (t.text[0] == '[') ']' else '"';
    return undouble(a, t.text[1 .. t.text.len - 1], q);
}

/// The value of a string token ('...' or N'...').
pub fn stringValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    var z = t.text;
    if (z[0] == 'n' or z[0] == 'N') z = z[1..];
    return undouble(a, z[1 .. z.len - 1], '\'');
}

fn undouble(a: std.mem.Allocator, inner: []const u8, q: u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, q) == null) return inner;
    var out: std.ArrayList(u8) = try .initCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        out.appendAssumeCapacity(inner[i]);
        if (inner[i] == q) i += 1;
    }
    return out.items;
}

/// The hex digits of a binary constant (0x0A), padded to an even count
/// with a leading 0 (0xA is 0x0A, as in SQL Server).
pub fn hexDigits(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    const digits = t.text[2..];
    if (digits.len % 2 == 0) return digits;
    const out = try a.alloc(u8, digits.len + 1);
    out[0] = '0';
    @memcpy(out[1..], digits);
    return out;
}

fn testTokens(sql: [:0]const u8, expected: []const struct { Kind, []const u8 }) !void {
    var lx: Lexer = .init(sql);
    for (expected) |e| {
        const t = lx.next();
        try std.testing.expectEqual(e[0], t.kind);
        try std.testing.expectEqualStrings(e[1], t.text);
    }
    try std.testing.expectEqual(Kind.eof, lx.next().kind);
}

test "lexer: identifiers, strings, comments, GO" {
    try testTokens("SELECT [a]]b], \"c\"\"d\", N'x''y', #t, @v, @@ROWCOUNT -- c\n/* a /* nested */ b */ 0x1F, 1.5e3, .5", &.{
        .{ .ident, "SELECT" },            .{ .quoted_ident, "[a]]b]" }, .{ .op, "," },
        .{ .quoted_ident, "\"c\"\"d\"" }, .{ .op, "," },                .{ .string, "N'x''y'" },
        .{ .op, "," },                    .{ .ident, "#t" },            .{ .op, "," },
        .{ .variable, "@v" },             .{ .op, "," },                .{ .sys_var, "@@ROWCOUNT" },
        .{ .hex, "0x1F" },                .{ .op, "," },                .{ .float, "1.5e3" },
        .{ .op, "," },                    .{ .float, ".5" },
    });
    try testTokens("SELECT 1\nGO\nSELECT go FROM t\n  go 2\n", &.{
        .{ .ident, "SELECT" }, .{ .integer, "1" }, .{ .go, "GO" },   .{ .ident, "SELECT" }, .{ .ident, "go" },
        .{ .ident, "FROM" },   .{ .ident, "t" },   .{ .go, "go 2" },
    });
    try testTokens("a!=b !< c += 1", &.{ .{ .ident, "a" }, .{ .op, "!=" }, .{ .ident, "b" }, .{ .op, "!<" }, .{ .ident, "c" }, .{ .op, "+=" }, .{ .integer, "1" } });
}

test "lexer: values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("it's", try stringValue(a, .{ .kind = .string, .text = "'it''s'" }));
    try std.testing.expectEqualStrings("é", try stringValue(a, .{ .kind = .string, .text = "N'é'" }));
    try std.testing.expectEqualStrings("a]b", try identValue(a, .{ .kind = .quoted_ident, .text = "[a]]b]" }));
    try std.testing.expectEqualStrings("a\"b", try identValue(a, .{ .kind = .quoted_ident, .text = "\"a\"\"b\"" }));
    try std.testing.expectEqualStrings("0a", try hexDigits(a, .{ .kind = .hex, .text = "0xa" }));
}
