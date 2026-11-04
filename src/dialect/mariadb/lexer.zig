//! The MariaDB tokenizer.
//!
//! Tokens are slices of the statement text (so that the IR's Token
//! offsets and error positions point into it); the value of a string
//! literal (escapes, doubled quotes) is computed on demand by
//! stringValue(). What depends on sql_mode:
//!  - ANSI_QUOTES: "x" is an identifier (else a string, as 'x');
//!  - NO_BACKSLASH_ESCAPES: a backslash in a string is an ordinary
//!    character (else it starts an escape: \0 \' \" \b \n \r \t \Z \\,
//!    \% and \_ stay as written for LIKE, any other \c is c);
//!  - PIPES_AS_CONCAT is the parser's business (`||` is one token).
//!
//! Comments: `#` and `-- ` (two dashes and a space or control
//! character) to the end of the line, `/* */`. An executable comment
//! `/*! ... */`, `/*!NNNNN ... */` or `/*M!NNNNN ... */` is code: its
//! contents are tokenized (unless the version NNNNN is above ours, then
//! it is a comment), and its closing `*/` is skipped.

const std = @import("std");
const sqllex = @import("sql/lexer");
const state = @import("state.zig");

/// MariaDB's rules for the scanners: identifiers of letters, `_`, `$`
/// and any non-ASCII byte, then digits too; `#` and `-- ` comments. Block
/// comments are skipped by Lexer.skipSpace() itself, which knows the
/// executable ones.
pub const spec: sqllex.Spec = .{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_$" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
    .comments = .{ .dash_dash = .before_space, .hash = true, .block = .none },
    .numbers = .{ .radix = "xXb" },
};
const scan = sqllex.Scanner(spec);

pub const Kind = enum {
    eof,
    /// An unquoted word: a keyword or a name.
    ident,
    /// `name` (or "name" under ANSI_QUOTES).
    quoted_ident,
    /// '...' (or "..." unless ANSI_QUOTES); N'...' too.
    string,
    integer,
    /// A number with a fraction or an exponent.
    float,
    /// X'0A1B' or 0x0A1B: a binary string.
    hex,
    /// B'0101' or 0b0101.
    bit,
    /// `?`
    param,
    /// @name, @'name', @`name`: a user variable.
    user_var,
    /// @@name, @@session.name ...: a system variable.
    sys_var,
    /// Punctuation and operators: ( ) , . ; + - * / % = < > <= >= <> !=
    /// <=> ! ~ ^ & | && || << >> := { }
    op,
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

/// Our version as executable comments compare it (MAJOR*10000 +
/// MINOR*100 + PATCH).
pub const version_id: u32 = 110800;

pub const Lexer = struct {
    sql: [:0]const u8,
    pos: usize = 0,
    /// Executable comments open at `pos` (their `*/` is skipped).
    exec_depth: u8 = 0,
    ansi_quotes: bool,
    backslash_escapes: bool,

    pub fn init(sql: [:0]const u8, mode: state.SqlMode) Lexer {
        return .{
            .sql = sql,
            .ansi_quotes = mode.has(.ANSI_QUOTES),
            .backslash_escapes = !mode.has(.NO_BACKSLASH_ESCAPES),
        };
    }

    /// Skip spaces and comments (an unterminated /* comment runs to the
    /// end).
    fn skipSpace(lx: *Lexer) void {
        const s = lx.sql;
        while (true) {
            lx.pos = scan.skip(s, lx.pos).end;
            switch (s[lx.pos]) {
                '*' => {
                    if (lx.exec_depth > 0 and s[lx.pos + 1] == '/') {
                        lx.exec_depth -= 1;
                        lx.pos += 2;
                    } else return;
                },
                '/' => {
                    if (s[lx.pos + 1] != '*') return;
                    var i = lx.pos + 2;
                    const mariadb_only = s[i] == 'M' and s[i + 1] == '!';
                    if (mariadb_only) i += 1;
                    if (s[i] == '!') {
                        i += 1;
                        var ver: u32 = 0;
                        var digits: usize = 0;
                        while (scan.isDigit(s[i]) and digits < 6) : (digits += 1) {
                            ver = ver * 10 + (s[i] - '0');
                            i += 1;
                        }
                        if (digits == 0 or ver <= version_id) {
                            lx.exec_depth += 1;
                            lx.pos = i;
                            continue;
                        }
                    }
                    // An ordinary comment (or one for a later version).
                    lx.pos = sqllex.blockCommentEnd(false, s, lx.pos).end;
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
        if (c == 0) return .{ .kind = .eof, .text = s[start..start], .start = @intCast(start), .end = @intCast(start) };
        const kind: Kind = switch (c) {
            '`' => lx.quoted(start, '`', .quoted_ident, false),
            '\'' => lx.quoted(start, '\'', .string, lx.backslash_escapes),
            '"' => if (lx.ansi_quotes)
                lx.quoted(start, '"', .quoted_ident, false)
            else
                lx.quoted(start, '"', .string, lx.backslash_escapes),
            '0'...'9' => lx.number(start),
            '.' => if (scan.isDigit(s[start + 1])) lx.number(start) else lx.one(.op),
            '?' => lx.one(.param),
            '@' => lx.variable(start),
            'x', 'X', 'b', 'B', 'n', 'N' => blk: {
                if (s[start + 1] == '\'') {
                    lx.pos += 1;
                    const k = lx.quoted(lx.pos, '\'', .string, (c == 'n' or c == 'N') and lx.backslash_escapes);
                    if (k == .illegal) break :blk .illegal;
                    break :blk switch (c) {
                        'x', 'X' => .hex,
                        'b', 'B' => .bit,
                        else => .string,
                    };
                }
                break :blk lx.word();
            },
            else => if (scan.isIdentStart(c)) lx.word() else lx.operator(),
        };
        return .{ .kind = kind, .text = s[start..lx.pos], .start = @intCast(start), .end = @intCast(lx.pos) };
    }

    /// A quoted token from `start` (its opening quote): the closing
    /// quote ends it, a doubled one stands for one, and a backslash
    /// escapes the next character if `escapes`.
    fn quoted(lx: *Lexer, start: usize, q: u8, kind: Kind, escapes: bool) Kind {
        const r = sqllex.quotedEnd(lx.sql, start, q, escapes);
        lx.pos = r.end;
        return if (r.closed) kind else .illegal;
    }

    fn number(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        // 0x1F, 0b01 (else 0x is a name): a name if a word character
        // follows the digits.
        if (scan.radixPrefix(s, start)) |base| if (sqllex.digitValue(s[start + 2]) < base) {
            const i = sqllex.radixDigits(s, start + 2, base, false).end;
            if (scan.isIdent(s[i])) {
                lx.pos = start;
                return lx.word();
            }
            lx.pos = i;
            return if (base == 16) .hex else .bit;
        };
        const n = scan.number(s, start);
        // 1abc is a name in MariaDB.
        if (!n.float and scan.isIdent(s[n.end])) {
            lx.pos = start;
            return lx.word();
        }
        lx.pos = n.end;
        return if (n.float) .float else .integer;
    }

    fn word(lx: *Lexer) Kind {
        lx.pos = scan.word(lx.sql, lx.pos);
        return .ident;
    }

    fn variable(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        if (s[start + 1] == '@') {
            lx.pos = start + 2;
            if (s[lx.pos] == '`') return if (lx.quoted(lx.pos, '`', .sys_var, false) == .illegal) .illegal else .sys_var;
            lx.pos = var_chars.span(s, lx.pos);
            return if (lx.pos == start + 2) .illegal else .sys_var;
        }
        lx.pos = start + 1;
        switch (s[lx.pos]) {
            '`', '\'', '"' => return if (lx.quoted(lx.pos, s[lx.pos], .user_var, false) == .illegal) .illegal else .user_var,
            else => {},
        }
        lx.pos = var_chars.span(s, lx.pos);
        return if (lx.pos == start + 1) .illegal else .user_var;
    }

    /// A token of one character.
    fn one(lx: *Lexer, k: Kind) Kind {
        lx.pos += 1;
        return k;
    }

    fn operator(lx: *Lexer) Kind {
        const s = lx.sql;
        // -> and ->> are MySQL's JSON operators (parser.zig).
        const n = sqllex.longestOp(&.{ "<=>", "->>", "<=", ">=", "<>", "!=", "&&", "||", "<<", ">>", ":=", "->" }, s, lx.pos);
        if (n > 0) {
            lx.pos += n;
            return .op;
        }
        switch (s[lx.pos]) {
            '(', ')', ',', '.', ';', '+', '-', '*', '/', '%', '=', '<', '>', '!', '~', '^', '&', '|', '{', '}', ':' => return lx.one(.op),
            else => return lx.one(.illegal),
        }
    }
};

/// Where the second statement of `sql` starts, if it has one: the first
/// token after a `;`, as the parser sees it (atStmtEnd(), with the
/// sql_mode `mode`). For the MySQL server, whose client without
/// CLIENT_MULTI_STATEMENTS MariaDB answers with a syntax error near that
/// token (src/server/mysql/Handler.zig).
pub fn secondStatement(sql: [:0]const u8, mode: state.SqlMode) ?usize {
    var lx: Lexer = .init(sql, mode);
    var after_semicolon = false;
    while (true) {
        const t = lx.next();
        if (t.kind == .eof) return null;
        if (after_semicolon and !t.is(";")) return t.text.ptr - sql.ptr;
        if (t.is(";")) after_semicolon = true;
    }
}

/// The characters of a variable's name: those of a word, and `.`
/// (@@session.sql_mode).
const var_chars = spec.ident.with(".");

/// The name an identifier token stands for: the word itself, or the
/// text between the quotes with doubled quotes undone (in `a` if any).
pub fn identValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    if (t.kind != .quoted_ident) return t.text;
    return sqllex.undouble(a, t.text[1 .. t.text.len - 1], t.text[0]);
}

/// The value of a string token ('...', "...", N'...'): doubled quotes and
/// (if `escapes`) backslash escapes undone. X'..' and B'..' are not
/// strings (see hexValue()/bitValue()).
pub fn stringValue(a: std.mem.Allocator, t: Token, escapes: bool) error{OutOfMemory}![]const u8 {
    var z = t.text;
    if (z[0] == 'n' or z[0] == 'N') z = z[1..];
    const q = z[0];
    const inner = z[1 .. z.len - 1];
    if (!escapes) return sqllex.undouble(a, inner, q);
    const plain = std.mem.indexOfScalar(u8, inner, q) == null and
        (!escapes or std.mem.indexOfScalar(u8, inner, '\\') == null);
    if (plain) return inner;
    var out: std.ArrayList(u8) = try .initCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == q) {
            // A doubled quote.
            out.appendAssumeCapacity(q);
            i += 1;
        } else if (c == '\\' and escapes and i + 1 < inner.len) {
            i += 1;
            switch (inner[i]) {
                '0' => out.appendAssumeCapacity(0),
                'b' => out.appendAssumeCapacity(0x08),
                'n' => out.appendAssumeCapacity('\n'),
                'r' => out.appendAssumeCapacity('\r'),
                't' => out.appendAssumeCapacity('\t'),
                'Z' => out.appendAssumeCapacity(0x1a),
                // Kept for LIKE, whose escape character is the backslash.
                '%', '_' => {
                    out.appendAssumeCapacity('\\');
                    out.appendAssumeCapacity(inner[i]);
                },
                else => |e| out.appendAssumeCapacity(e),
            }
        } else out.appendAssumeCapacity(c);
    }
    return out.items;
}

/// The hex digits of a hex token (X'0A' or 0x0A), padded to an even
/// count with a leading 0 (MariaDB's 0xA is 0x0A); null if X'..' has an
/// odd count (an error in MariaDB).
pub fn hexDigits(a: std.mem.Allocator, t: Token) error{OutOfMemory}!?[]const u8 {
    const digits = if (t.text[0] == '0') t.text[2..] else t.text[2 .. t.text.len - 1];
    if (digits.len % 2 != 0 and t.text[0] != '0') return null;
    return try sqllex.evenDigits(a, digits);
}

/// The value of a bit token (B'0101' or 0b0101), null if out of range.
pub fn bitValue(t: Token) ?i64 {
    const digits = if (t.text[0] == '0') t.text[2..] else t.text[2 .. t.text.len - 1];
    var v: u64 = 0;
    for (digits) |d| {
        if (v >> 63 != 0) return null;
        v = v * 2 + (d - '0');
    }
    return @bitCast(v);
}

fn testTokens(sql: [:0]const u8, mode: state.SqlMode, expected: []const struct { Kind, []const u8 }) !void {
    var lx: Lexer = .init(sql, mode);
    for (expected) |e| {
        const t = lx.next();
        try std.testing.expectEqual(e[0], t.kind);
        try std.testing.expectEqualStrings(e[1], t.text);
    }
    try std.testing.expectEqual(Kind.eof, lx.next().kind);
}

test "lexer: quoting, comments and executable comments" {
    const d = state.SqlMode.default;
    try testTokens("SELECT `a``b`, \"s\", 'x' -- c\n# c\n/* c */ 1", d, &.{
        .{ .ident, "SELECT" }, .{ .quoted_ident, "`a``b`" }, .{ .op, "," },
        .{ .string, "\"s\"" }, .{ .op, "," },                .{ .string, "'x'" },
        .{ .integer, "1" },
    });
    // --x is minus minus x.
    try testTokens("1--2", d, &.{ .{ .integer, "1" }, .{ .op, "-" }, .{ .op, "-" }, .{ .integer, "2" } });
    try testTokens("/*! STRAIGHT_JOIN */ /*!50100 a */ /*!999999 b */ /*M!100100 c*/", d, &.{
        .{ .ident, "STRAIGHT_JOIN" }, .{ .ident, "a" }, .{ .ident, "c" },
    });
    try testTokens("\"x\"", state.SqlMode.default.with(.ANSI_QUOTES), &.{.{ .quoted_ident, "\"x\"" }});
    try testTokens("a<=>b||c&&!d:=@v,@@session.sql_mode,?", d, &.{
        .{ .ident, "a" }, .{ .op, "<=>" },                     .{ .ident, "b" }, .{ .op, "||" },   .{ .ident, "c" },
        .{ .op, "&&" },   .{ .op, "!" },                       .{ .ident, "d" }, .{ .op, ":=" },   .{ .user_var, "@v" },
        .{ .op, "," },    .{ .sys_var, "@@session.sql_mode" }, .{ .op, "," },    .{ .param, "?" },
    });
    try testTokens("X'0a' 0x1F b'101' 0b11 1.5e3 .5 N'n' 1abc", d, &.{
        .{ .hex, "X'0a'" },   .{ .hex, "0x1F" }, .{ .bit, "b'101'" },  .{ .bit, "0b11" },
        .{ .float, "1.5e3" }, .{ .float, ".5" }, .{ .string, "N'n'" }, .{ .ident, "1abc" },
    });
}

test "lexer: string values" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var lx: Lexer = .init("'a\\nb\\'c''d\\\\e\\%\\x'", state.SqlMode.default);
    const t = lx.next();
    try std.testing.expectEqual(Kind.string, t.kind);
    try std.testing.expectEqualStrings("a\nb'c'd\\e\\%x", try stringValue(aa, t, true));
    var lx2: Lexer = .init("'a\\' 'b'", state.SqlMode.default.with(.NO_BACKSLASH_ESCAPES));
    const t2 = lx2.next();
    try std.testing.expectEqualStrings("a\\", try stringValue(aa, t2, false));
    try std.testing.expectEqualStrings("'b'", lx2.next().text);
    const id: Token = .{ .kind = .quoted_ident, .text = "`a``b`" };
    try std.testing.expectEqualStrings("a`b", try identValue(aa, id));
}

test "lexer: second statement" {
    const d = state.SqlMode.default;
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT 1;", d));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT ';x' ; -- y\n # z\n /* w */ ;", d));
    try std.testing.expectEqual(@as(?usize, 10), secondStatement("SELECT 1; SELECT 2", d));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT 'a\\';b', `x;``y`", d));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT 1 --x", d));
    // --x is not a comment: `;` ends the first statement.
    try std.testing.expectEqual(@as(?usize, 4), secondStatement("1--;x", d));
    // A backslash escapes nothing under NO_BACKSLASH_ESCAPES, and never
    // in an identifier ("..." under ANSI_QUOTES).
    try std.testing.expectEqual(@as(?usize, 13), secondStatement("SELECT 'a\\'; SELECT 2", d.with(.NO_BACKSLASH_ESCAPES)));
    try std.testing.expectEqual(@as(?usize, 13), secondStatement("SELECT \"a\\\"; SELECT 2", d.with(.ANSI_QUOTES)));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT \"a\\\"; SELECT 2\"", d));
    // Executable comments are code, at any place: their `;` too, and
    // the text after one. One for a later version is a comment.
    try std.testing.expectEqual(@as(?usize, 15), secondStatement("SELECT 1 /*! ; SELECT 2 */", d));
    try std.testing.expectEqual(@as(?usize, 24), secondStatement("SELECT 1; /*M!100100 */ SELECT 2", d));
    try std.testing.expectEqual(@as(?usize, 21), secondStatement("SELECT 1; /*M!100100 SELECT 2 */", d));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT 1; /*!999999 SELECT 2 */", d));
    try std.testing.expectEqual(@as(?usize, null), secondStatement("SELECT 1; /*!*/", d));
}
