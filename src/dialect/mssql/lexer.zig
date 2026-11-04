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
const sqllex = @import("sqllex");

/// SQL Server's rules for the scanners: identifiers of letters, `_`, `#`
/// and any non-ASCII byte, then digits, `$` and `@` too; nested block
/// comments.
pub const spec: sqllex.Spec = .{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_#" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_#$@" }),
    .comments = .{ .block = .nested },
    .numbers = .{ .radix = "xX" },
};
const scan = sqllex.Scanner(spec);

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
    /// Its byte offsets in the statement (0 for a token made of other
    /// text, to decode it).
    start: u32 = 0,
    end: u32 = 0,

    pub fn is(t: Token, op: []const u8) bool {
        return t.kind == .op and std.mem.eql(u8, t.text, op);
    }

    pub const isOp = is;

    /// An unquoted word equal to `kw` (case-insensitive).
    pub fn isKw(t: Token, kw: []const u8) bool {
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, kw);
    }

    pub fn isAnyKw(t: Token, comptime kws: []const []const u8) bool {
        inline for (kws) |kw| if (t.isKw(kw)) return true;
        return false;
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
        lx.pos = scan.skip(lx.sql, lx.pos).end;
    }

    pub fn next(lx: *Lexer) Token {
        lx.skipSpace();
        const s = lx.sql;
        const start = lx.pos;
        const c = s[start];
        if (c == 0) return .{ .kind = .eof, .text = s[start..start], .start = @intCast(start), .end = @intCast(start) };
        const kind: Kind = switch (c) {
            '[' => lx.quoted(start, ']', .quoted_ident),
            '"' => lx.quoted(start, '"', .quoted_ident),
            '\'' => lx.quoted(start, '\'', .string),
            '0'...'9' => lx.number(start),
            '.' => if (scan.isDigit(s[start + 1])) lx.number(start) else lx.one(.op),
            '?' => lx.one(.param),
            '@' => lx.variable(start),
            'n', 'N' => blk: {
                if (s[start + 1] == '\'') {
                    break :blk lx.quoted(start + 1, '\'', .string);
                }
                break :blk lx.word(start);
            },
            else => if (scan.isIdentStart(c)) lx.word(start) else lx.operator(),
        };
        return .{ .kind = kind, .text = s[start..lx.pos], .start = @intCast(start), .end = @intCast(lx.pos) };
    }

    /// A quoted token from `start` (its opening quote): `q` ends it, a
    /// doubled `q` stands for one.
    fn quoted(lx: *Lexer, start: usize, q: u8, kind: Kind) Kind {
        const r = sqllex.quotedEnd(lx.sql, start, q, false);
        lx.pos = r.end;
        return if (r.closed) kind else .illegal;
    }

    fn number(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        if (scan.radixPrefix(s, start)) |base| {
            lx.pos = sqllex.radixDigits(s, start + 2, base, false).end;
            return .hex;
        }
        const n = scan.number(s, start);
        lx.pos = n.end;
        return if (n.float) .float else .integer;
    }

    /// A word, or GO alone on its line.
    fn word(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        lx.pos = scan.word(s, lx.pos);
        if (lx.pos - start == 2 and std.ascii.eqlIgnoreCase(s[start..lx.pos], "GO") and sqllex.blankBefore(s, start)) {
            // GO [count] then the end of the line (or a comment).
            var i = lx.pos;
            while (s[i] == ' ' or s[i] == '\t') i += 1;
            while (scan.isDigit(s[i])) i += 1;
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
        lx.pos = scan.word(s, lx.pos);
        if (lx.pos == first) return .illegal;
        return if (sys) .sys_var else .variable;
    }

    /// A token of one character.
    fn one(lx: *Lexer, k: Kind) Kind {
        lx.pos += 1;
        return k;
    }

    fn operator(lx: *Lexer) Kind {
        const n = sqllex.longestOp(&.{ "<=", ">=", "<>", "!=", "!<", "!>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::" }, lx.sql, lx.pos);
        if (n > 0) {
            lx.pos += n;
            return .op;
        }
        switch (lx.sql[lx.pos]) {
            '(', ')', ',', '.', ';', '+', '-', '*', '/', '%', '=', '<', '>', '~', '^', '&', '|', '{', '}', ':' => return lx.one(.op),
            else => return lx.one(.illegal),
        }
    }
};

/// The name an identifier token stands for: the word itself, or the
/// text between the delimiters with doubled closing delimiters undone
/// (in `a` if any).
pub fn identValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    if (t.kind != .quoted_ident) return t.text;
    const q: u8 = if (t.text[0] == '[') ']' else '"';
    return sqllex.undouble(a, t.text[1 .. t.text.len - 1], q);
}

/// The value of a string token ('...' or N'...').
pub fn stringValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    var z = t.text;
    if (z[0] == 'n' or z[0] == 'N') z = z[1..];
    return sqllex.undouble(a, z[1 .. z.len - 1], '\'');
}

/// The hex digits of a binary constant (0x0A), padded to an even count
/// with a leading 0 (0xA is 0x0A, as in SQL Server).
pub fn hexDigits(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    return sqllex.evenDigits(a, t.text[2..]);
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
