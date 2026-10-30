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
const lex = @import("../lex.zig");
const state = @import("state.zig");

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

    /// Skip spaces and comments; false if a comment is not terminated.
    fn skipSpace(lx: *Lexer) void {
        const s = lx.sql;
        while (true) {
            const c = s[lx.pos];
            switch (c) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => lx.pos += 1,
                '#' => lx.skipLine(),
                '-' => {
                    if (s[lx.pos + 1] == '-' and (s[lx.pos + 2] == 0 or s[lx.pos + 2] <= ' ')) {
                        lx.skipLine();
                    } else return;
                },
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
                        while (std.ascii.isDigit(s[i]) and digits < 6) : (digits += 1) {
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
                    var j = lx.pos + 2;
                    while (s[j] != 0 and !(s[j] == '*' and s[j + 1] == '/')) j += 1;
                    lx.pos = if (s[j] == 0) j else j + 2;
                },
                else => return,
            }
        }
    }

    fn skipLine(lx: *Lexer) void {
        while (lx.sql[lx.pos] != 0 and lx.sql[lx.pos] != '\n') lx.pos += 1;
    }

    pub fn next(lx: *Lexer) Token {
        lx.skipSpace();
        const s = lx.sql;
        const start = lx.pos;
        const c = s[start];
        if (c == 0) return .{ .kind = .eof, .text = s[start..start] };
        const kind: Kind = switch (c) {
            '`' => lx.quoted(start, '`', .quoted_ident, false),
            '\'' => lx.quoted(start, '\'', .string, lx.backslash_escapes),
            '"' => if (lx.ansi_quotes)
                lx.quoted(start, '"', .quoted_ident, false)
            else
                lx.quoted(start, '"', .string, lx.backslash_escapes),
            '0'...'9' => lx.number(start),
            '.' => if (std.ascii.isDigit(s[start + 1])) lx.number(start) else lx.op1(),
            '?' => blk: {
                lx.pos += 1;
                break :blk .param;
            },
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
            else => if (isIdentStart(c)) lx.word() else lx.operator(),
        };
        return .{ .kind = kind, .text = s[start..lx.pos] };
    }

    /// A quoted token from `start` (its opening quote): the closing
    /// quote ends it, a doubled one stands for one, and a backslash
    /// escapes the next character if `escapes`.
    fn quoted(lx: *Lexer, start: usize, q: u8, kind: Kind, escapes: bool) Kind {
        const r = lex.quotedEnd(lx.sql, start, q, escapes);
        lx.pos = r.end;
        return if (r.closed) kind else .illegal;
    }

    fn number(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        var i = start;
        if (s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
            i += 2;
            while (std.ascii.isHex(s[i])) i += 1;
            if (!isIdentChar(s[i])) {
                lx.pos = i;
                return .hex;
            }
            lx.pos = start;
            return lx.word();
        }
        if (s[i] == '0' and (s[i + 1] == 'b') and (s[i + 2] == '0' or s[i + 2] == '1')) {
            i += 2;
            while (s[i] == '0' or s[i] == '1') i += 1;
            if (!isIdentChar(s[i])) {
                lx.pos = i;
                return .bit;
            }
            lx.pos = start;
            return lx.word();
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
        // 1abc is a name in MariaDB.
        if (kind == .integer and isIdentChar(s[i])) {
            lx.pos = start;
            return lx.word();
        }
        lx.pos = i;
        return kind;
    }

    fn word(lx: *Lexer) Kind {
        while (isIdentChar(lx.sql[lx.pos])) lx.pos += 1;
        return .ident;
    }

    fn variable(lx: *Lexer, start: usize) Kind {
        const s = lx.sql;
        if (s[start + 1] == '@') {
            lx.pos = start + 2;
            if (s[lx.pos] == '`') return if (lx.quoted(lx.pos, '`', .sys_var, false) == .illegal) .illegal else .sys_var;
            while (isIdentChar(s[lx.pos]) or s[lx.pos] == '.') lx.pos += 1;
            return if (lx.pos == start + 2) .illegal else .sys_var;
        }
        lx.pos = start + 1;
        switch (s[lx.pos]) {
            '`', '\'', '"' => return if (lx.quoted(lx.pos, s[lx.pos], .user_var, false) == .illegal) .illegal else .user_var,
            else => {},
        }
        while (isIdentChar(s[lx.pos]) or s[lx.pos] == '.') lx.pos += 1;
        return if (lx.pos == start + 1) .illegal else .user_var;
    }

    fn op1(lx: *Lexer) Kind {
        lx.pos += 1;
        return .op;
    }

    fn operator(lx: *Lexer) Kind {
        const s = lx.sql;
        const rest = s[lx.pos..];
        // -> and ->> are MySQL's JSON operators (parser.zig).
        const ops3 = [_][]const u8{ "<=>", "->>" };
        const ops2 = [_][]const u8{ "<=", ">=", "<>", "!=", "&&", "||", "<<", ">>", ":=", "->" };
        for (ops3) |o| if (std.mem.startsWith(u8, rest, o)) {
            lx.pos += 3;
            return .op;
        };
        for (ops2) |o| if (std.mem.startsWith(u8, rest, o)) {
            lx.pos += 2;
            return .op;
        };
        switch (rest[0]) {
            '(', ')', ',', '.', ';', '+', '-', '*', '/', '%', '=', '<', '>', '!', '~', '^', '&', '|', '{', '}', ':' => return lx.op1(),
            else => {
                lx.pos += 1;
                return .illegal;
            },
        }
    }
};

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

/// isIdentStart() and digits.
pub const isIdentChar = @import("xqlite_base").ctype.isIdChar;

/// The name an identifier token stands for: the word itself, or the
/// text between the quotes with doubled quotes undone (in `a` if any).
pub fn identValue(a: std.mem.Allocator, t: Token) error{OutOfMemory}![]const u8 {
    if (t.kind != .quoted_ident) return t.text;
    const q = t.text[0];
    const inner = t.text[1 .. t.text.len - 1];
    if (std.mem.indexOfScalar(u8, inner, q) == null) return inner;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        try out.append(a, inner[i]);
        if (inner[i] == q) i += 1;
    }
    return out.items;
}

/// The value of a string token ('...', "...", N'...'): doubled quotes and
/// (if `escapes`) backslash escapes undone. X'..' and B'..' are not
/// strings (see hexValue()/bitValue()).
pub fn stringValue(a: std.mem.Allocator, t: Token, escapes: bool) error{OutOfMemory}![]const u8 {
    var z = t.text;
    if (z[0] == 'n' or z[0] == 'N') z = z[1..];
    const q = z[0];
    const inner = z[1 .. z.len - 1];
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
    if (digits.len % 2 == 0) return digits;
    if (t.text[0] != '0') return null;
    const out = try a.alloc(u8, digits.len + 1);
    out[0] = '0';
    @memcpy(out[1..], digits);
    return out;
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
