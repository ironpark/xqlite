//! The MariaDB tokenizer: MariaDB's lexical rules for sqllex.Lexer().
//!
//! Tokens are offsets in the statement text (so that the IR's Token
//! offsets and error positions point into it); the value of a string
//! literal (escapes, doubled quotes) is computed on demand by
//! stringValue(). What depends on sql_mode (lexOptions()):
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
//!
//! Besides the shared kinds: X'0A1B' is a string of sub `blob` and 0x0A1B
//! an integer of sub `hex` (both binary strings, isHex()); B'0101' a
//! string of sub `bits` and 0b0101 an integer of sub `binary` (isBits());
//! @x a variable of sub `user`, @@x of sub `system`.

const std = @import("std");
const sqllex = @import("sql/lexer");
const state = @import("state.zig");

/// Our version as executable comments compare it (MAJOR*10000 +
/// MINOR*100 + PATCH).
pub const version_id: u32 = 110800;

/// MariaDB's lexical rules for sqllex.Lexer(), as sql_mode sets its
/// options (lexOptions()).
pub const lex = struct {
    pub const spec: sqllex.Spec = .{
        .ident_start = .of(.{ .letters = true, .high = true, .chars = "_$" }),
        .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
        .comments = .{ .dash_dash = .before_space, .hash = true, .block = .none },
        .numbers = .{ .radix = "xXb", .tail = .word, .radix_empty = .decimal },
        .quotes = &.{
            .{ .open = '`', .close = '`', .kind = .quoted_ident },
            .{ .open = '\'', .close = '\'', .kind = .string, .escapes = true },
            .{ .open = '"', .close = '"', .kind = .string, .escapes = true, .when = .not_ansi_quotes },
            .{ .open = '"', .close = '"', .kind = .quoted_ident, .when = .ansi_quotes },
        },
        .prefixes = &.{
            .{ .letters = "x", .sub = .blob, .escapes = .never },
            .{ .letters = "b", .sub = .bits, .escapes = .never },
            .{ .letters = "n", .sub = .national },
        },
        .params = .{ .question = .positional },
        .ops = .{
            .list = &.{ "<=>", "->>", "<=", ">=", "<>", "!=", "&&", "||", "<<", ">>", ":=", "->" },
            .singles = .of(.{ .chars = "+-*/%=<>!~^&|{}:" }),
        },
    };

    /// Every word the parser (and syntax.zig, sqlparse's Cursor) compares
    /// as a keyword: a word not here is never one. The reserved ones are
    /// no names where a name is optional (aliases) or where they would
    /// make no sense as one (a column reference): parser.isReserved().
    pub const keywords = sqllex.Keywords(sqllex.allKeywords(.reserved, &reserved_words) ++ sqllex.allKeywords(.unreserved, &.{
        "ACTION",         "ADD",                 "AFTER",        "ALGORITHM",        "ALTER",      "ALWAYS",         "ANALYZE",      "ANY",            "ASCII",
        "AUTO_INCREMENT", "BEGIN",               "BOOL",         "BOOLEAN",          "BOTH",       "BYTE",           "CACHE",        "CASCADE",        "CASCADED",
        "CHAIN",          "CHAR",                "CHARACTER",    "CHARSET",          "CLOB",       "CLUSTERING",     "COLUMN",       "COLUMNS",        "COLUMN_FORMAT",
        "COMMENT",        "COMMIT",              "CONVERT",      "COUNT",            "CURDATE",    "CURRENT",        "CURRENT_DATE", "CURRENT_TIME",   "CURRENT_TIMESTAMP",
        "CURRENT_USER",   "CYCLE",               "DATABASE",     "DATABASES",        "DATE",       "DATETIME",       "DEC",          "DECIMAL",        "DEFINER",
        "DELAYED",        "DESCRIBE",            "DISABLE",      "DO",               "DOUBLE",     "DUPLICATE",      "EMPTY",        "ENABLE",         "END",
        "ENGINE",         "ERROR",               "ERRORS",       "EVENT",            "EXCLUDE",    "EXPLAIN",        "EXTENDED",     "FIELDS",         "FIRST",
        "FIXED",          "FLOAT",               "FLOAT4",       "FLOAT8",           "FOLLOWING",  "FORMAT",         "FULL",         "FULLTEXT",       "FUNCTION",
        "GENERATED",      "GLOBAL",              "GROUPS",       "IF",               "IGNORED",    "INCREMENT",      "INDEXES",      "INT",            "INT1",
        "INT2",           "INT3",                "INT4",         "INT8",             "INTEGER",    "INVISIBLE",      "JSON",         "KEYS",           "KEY_BLOCK_SIZE",
        "LAST",           "LASTVAL",             "LEADING",      "LOCAL",            "LOCALTIME",  "LOCALTIMESTAMP", "LOCKED",       "LONG",           "MATCH",
        "MAXVALUE",       "MIDDLEINT",           "MINUS",        "MINVALUE",         "MODE",       "NAMES",          "NATIONAL",     "NCHAR",          "NESTED",
        "NEXT",           "NO",                  "NOCACHE",      "NOCYCLE",          "NOMAXVALUE", "NOMINVALUE",     "NOW",          "NOWAIT",         "NO_WRITE_TO_BINLOG",
        "NULLS",          "NUMBER",              "NUMERIC",      "NVARCHAR",         "OFF",        "ONLINE",         "ONLY",         "OPTION",         "ORDINALITY",
        "OTHERS",         "PARTITIONS",          "PATH",         "PERIOD",           "PERSISTENT", "PRECEDING",      "PRECISION",    "PREVIOUS",       "PROCEDURE",
        "QUICK",          "RAW",                 "REAL",         "RECURSIVE",        "RELEASE",    "RENAME",         "RESTRICT",     "ROLLBACK",       "ROLLUP",
        "ROW",            "SAVEPOINT",           "SCHEMA",       "SCHEMAS",          "SECURITY",   "SEQUENCE",       "SERIAL",       "SESSION",        "SHARE",
        "SHOW",           "SIGNED",              "SKIP",         "SOME",             "SOUNDS",     "SPATIAL",        "SQL",          "SQL_BIG_RESULT", "SQL_BUFFER_RESULT",
        "SQL_CACHE",      "SQL_CALC_FOUND_ROWS", "SQL_NO_CACHE", "SQL_SMALL_RESULT", "START",      "STORAGE",        "STORED",       "TABLE",          "TABLES",
        "TEMP",           "TEMPORARY",           "TEXT",         "TIES",             "TIME",       "TIMESTAMP",      "TO",           "TRAILING",       "TRANSACTION",
        "TRIGGER",        "TRUNCATE",            "UNBOUNDED",    "UNICODE",          "UNKNOWN",    "UNLOCK",         "UNSIGNED",     "UTC_DATE",       "UTC_TIME",
        "UTC_TIMESTAMP",  "VALUE",               "VARBINARY",    "VARCHAR",          "VARCHAR2",   "VARCHARACTER",   "VARIABLES",    "VARYING",        "VIEW",
        "VIRTUAL",        "VISIBLE",             "WAIT",         "WARNINGS",         "WORK",       "ZEROFILL",
    }));

    pub const State = struct {
        /// How many executable comments are open.
        exec_depth: u8 = 0,
    };

    /// White space and comments; an executable comment's opening is
    /// skipped (its contents are code), and so is its closing `*/`.
    pub fn skip(l: anytype) ?Token {
        const s = l.sql;
        while (true) {
            l.pos = Lexer.scan.skip(s, l.pos).end;
            switch (s[l.pos]) {
                '*' => {
                    if (l.state.exec_depth > 0 and s[l.pos + 1] == '/') {
                        l.state.exec_depth -= 1;
                        l.pos += 2;
                    } else return null;
                },
                '/' => {
                    if (s[l.pos + 1] != '*') return null;
                    var i = l.pos + 2;
                    const mariadb_only = s[i] == 'M' and s[i + 1] == '!';
                    if (mariadb_only) i += 1;
                    if (s[i] == '!') {
                        i += 1;
                        var ver: u32 = 0;
                        var digits: usize = 0;
                        while (Lexer.scan.isDigit(s[i]) and digits < 6) : (digits += 1) {
                            ver = ver * 10 + (s[i] - '0');
                            i += 1;
                        }
                        if (digits == 0 or ver <= version_id) {
                            l.state.exec_depth += 1;
                            l.pos = i;
                            continue;
                        }
                    }
                    l.pos = sqllex.blockCommentEnd(false, s, l.pos).end;
                },
                else => return null,
            }
        }
    }

    /// @name, @'name', @`name`: a user variable; @@name, @@`name`: a
    /// system variable.
    pub fn scan(l: anytype, start: usize) ?Token {
        const s = l.sql;
        if (s[start] != '@') return null;
        if (s[start + 1] == '@') {
            const first = start + 2;
            if (s[first] == '`') return quotedVar(l, start, first, .system);
            const e = var_chars.span(s, first);
            return l.take(if (e == first) .illegal else .variable, if (e == first) .bad_char else .system, start, e);
        }
        const first = start + 1;
        switch (s[first]) {
            '`', '\'', '"' => return quotedVar(l, start, first, .user),
            else => {},
        }
        const e = var_chars.span(s, first);
        return l.take(if (e == first) .illegal else .variable, if (e == first) .bad_char else .user, start, e);
    }

    fn quotedVar(l: anytype, start: usize, open: usize, sub: sqllex.Sub) Token {
        const r = sqllex.quotedEnd(l.sql, open, l.sql[open], false);
        if (!r.closed) return l.take(.illegal, .unterminated, start, r.end);
        return l.take(.variable, sub, start, r.end);
    }
};

pub const Lexer = sqllex.Lexer(lex);
pub const Token = Lexer.Token;
pub const Keywords = lex.keywords;

const reserved_words = [_][]const u8{
    "ALL",      "AND",           "AS",         "ASC",     "BETWEEN",   "BINARY",  "BY",     "CASE",
    "CHECK",    "COLLATE",       "CONSTRAINT", "CREATE",  "CROSS",     "DEFAULT", "DELETE", "DESC",
    "DISTINCT", "DISTINCTROW",   "DIV",        "DROP",    "DUAL",      "ELSE",    "ESCAPE", "EXCEPT",
    "EXISTS",   "FALSE",         "FETCH",      "FOR",     "FORCE",     "FOREIGN", "FROM",   "GROUP",
    "HAVING",   "HIGH_PRIORITY", "IGNORE",     "IN",      "INDEX",     "INNER",   "INSERT", "INTERSECT",
    "INTERVAL", "INTO",          "IS",         "JOIN",    "KEY",       "LEFT",    "LIKE",   "LIMIT",
    "LOCK",     "LOW_PRIORITY",  "MOD",        "NATURAL", "NOT",       "NULL",    "OFFSET", "ON",
    "OR",       "ORDER",         "OUTER",      "OVER",    "PARTITION", "PRIMARY", "RANGE",  "REFERENCES",
    "REGEXP",   "REPLACE",       "RETURNING",  "RIGHT",   "RLIKE",     "ROWS",    "SELECT", "SEPARATOR",
    "SET",      "STRAIGHT_JOIN", "THEN",       "TRUE",    "UNION",     "UNIQUE",  "UPDATE", "USE",
    "USING",    "VALUES",        "WHEN",       "WHERE",   "WINDOW",    "WITH",    "XOR",
};

/// The lexer of `sql` from `pos`, under sql_mode `mode`.
pub fn init(sql: [:0]const u8, pos: usize, mode: state.SqlMode) Lexer {
    return .init(sql, pos, lexOptions(mode));
}

/// The lexer's options under sql_mode `mode`.
pub fn lexOptions(mode: state.SqlMode) sqllex.Options {
    return .{ .ansi_quotes = mode.has(.ANSI_QUOTES), .backslash_escapes = !mode.has(.NO_BACKSLASH_ESCAPES) };
}

/// Where the second statement of `sql` starts, if it has one: the first
/// token after a `;`, as the parser sees it (atStmtEnd(), with the
/// sql_mode `mode`). For the MySQL server, whose client without
/// CLIENT_MULTI_STATEMENTS MariaDB answers with a syntax error near that
/// token (src/server/mysql/Handler.zig).
pub fn secondStatement(sql: [:0]const u8, mode: state.SqlMode) ?usize {
    var lx = init(sql, 0, mode);
    var after_semicolon = false;
    while (true) {
        const t = lx.next();
        if (t.kind == .eof) return null;
        if (after_semicolon and t.kind != .semi) return t.start;
        if (t.kind == .semi) after_semicolon = true;
    }
}

/// The characters of a variable's name: those of a word, and `.`
/// (@@session.sql_mode).
const var_chars = lex.spec.ident.with(".");

/// A string constant: '...', "..." (unless ANSI_QUOTES), N'...'; not
/// X'..' or B'..'.
pub fn isString(t: Token) bool {
    return t.kind == .string and (t.sub == .none or t.sub == .national);
}

/// A decimal integer (not 0x.. or 0b..).
pub fn isInteger(t: Token) bool {
    return t.kind == .integer and t.sub == .none;
}

/// X'0A1B' or 0x0A1B: a binary string.
pub fn isHex(t: Token) bool {
    return (t.kind == .string and t.sub == .blob) or (t.kind == .integer and t.sub == .hex);
}

/// B'0101' or 0b0101.
pub fn isBits(t: Token) bool {
    return (t.kind == .string and t.sub == .bits) or (t.kind == .integer and t.sub == .binary);
}

/// An unquoted word or a quoted identifier.
pub fn isIdent(t: Token) bool {
    return t.kind == .word or t.kind == .quoted_ident;
}

/// The name an identifier token stands for: the word itself, or the
/// text between the quotes with doubled quotes undone (in `a` if any).
pub fn identValue(a: std.mem.Allocator, sql: []const u8, t: Token) error{OutOfMemory}![]const u8 {
    if (t.kind != .quoted_ident) return t.text(sql);
    return quotedName(a, t.text(sql));
}

/// The name a quoted identifier written `z` (`a``b` or "a""b") stands for.
pub fn quotedName(a: std.mem.Allocator, z: []const u8) error{OutOfMemory}![]const u8 {
    return sqllex.undouble(a, z[1 .. z.len - 1], z[0]);
}

/// The value of a string token ('...', "...", N'...'): doubled quotes and
/// (if `escapes`) backslash escapes undone. X'..' and B'..' are not
/// strings (see hexDigits()/bitValue()).
pub fn stringValue(a: std.mem.Allocator, sql: []const u8, t: Token, escapes: bool) error{OutOfMemory}![]const u8 {
    return stringText(a, t.text(sql), escapes);
}

/// stringValue() of a string written `text`.
pub fn stringText(a: std.mem.Allocator, text: []const u8, escapes: bool) error{OutOfMemory}![]const u8 {
    var z = text;
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
pub fn hexDigits(a: std.mem.Allocator, sql: []const u8, t: Token) error{OutOfMemory}!?[]const u8 {
    const z = t.text(sql);
    const digits = if (z[0] == '0') z[2..] else z[2 .. z.len - 1];
    if (digits.len % 2 != 0 and z[0] != '0') return null;
    return try sqllex.evenDigits(a, digits);
}

/// The value of a bit token (B'0101' or 0b0101), null if out of range.
pub fn bitValue(sql: []const u8, t: Token) ?i64 {
    const z = t.text(sql);
    const digits = if (z[0] == '0') z[2..] else z[2 .. z.len - 1];
    var v: u64 = 0;
    for (digits) |d| {
        if (v >> 63 != 0) return null;
        v = v * 2 + (d - '0');
    }
    return @bitCast(v);
}

const Kind = sqllex.Kind;
const Sub = sqllex.Sub;

fn testTokens(sql: [:0]const u8, mode: state.SqlMode, expected: []const struct { Kind, Sub, []const u8 }) !void {
    var lx = init(sql, 0, mode);
    for (expected) |e| {
        const t = lx.next();
        try std.testing.expectEqual(e[0], t.kind);
        try std.testing.expectEqual(e[1], t.sub);
        try std.testing.expectEqualStrings(e[2], t.text(sql));
    }
    try std.testing.expectEqual(Kind.eof, lx.next().kind);
}

test "lexer: quoting, comments and executable comments" {
    const d = state.SqlMode.default;
    try testTokens("SELECT `a``b`, \"s\", 'x' -- c\n# c\n/* c */ 1", d, &.{
        .{ .word, .none, "SELECT" },  .{ .quoted_ident, .none, "`a``b`" }, .{ .comma, .none, "," },
        .{ .string, .none, "\"s\"" }, .{ .comma, .none, "," },             .{ .string, .none, "'x'" },
        .{ .integer, .none, "1" },
    });
    // --x is minus minus x.
    try testTokens("1--2", d, &.{ .{ .integer, .none, "1" }, .{ .op, .none, "-" }, .{ .op, .none, "-" }, .{ .integer, .none, "2" } });
    try testTokens("/*! STRAIGHT_JOIN */ /*!50100 a */ /*!999999 b */ /*M!100100 c*/", d, &.{
        .{ .word, .none, "STRAIGHT_JOIN" }, .{ .word, .none, "a" }, .{ .word, .none, "c" },
    });
    try testTokens("\"x\"", state.SqlMode.default.with(.ANSI_QUOTES), &.{.{ .quoted_ident, .none, "\"x\"" }});
    try testTokens("a<=>b||c&&!d:=@v,@@session.sql_mode,?", d, &.{
        .{ .word, .none, "a" },  .{ .op, .none, "<=>" },        .{ .word, .none, "b" },  .{ .op, .none, "||" },
        .{ .word, .none, "c" },  .{ .op, .none, "&&" },         .{ .op, .none, "!" },    .{ .word, .none, "d" },
        .{ .op, .none, ":=" },   .{ .variable, .user, "@v" },   .{ .comma, .none, "," }, .{ .variable, .system, "@@session.sql_mode" },
        .{ .comma, .none, "," }, .{ .param, .positional, "?" },
    });
    try testTokens("X'0a' 0x1F b'101' 0b11 1.5e3 .5 N'n' 1abc 0x1g", d, &.{
        .{ .string, .blob, "X'0a'" }, .{ .integer, .hex, "0x1F" }, .{ .string, .bits, "b'101'" },   .{ .integer, .binary, "0b11" },
        .{ .float, .none, "1.5e3" },  .{ .float, .none, ".5" },    .{ .string, .national, "N'n'" }, .{ .word, .none, "1abc" },
        .{ .word, .none, "0x1g" },
    });
    try testTokens("'open", d, &.{.{ .illegal, .unterminated, "'open" }});
    try testTokens("@ x", d, &.{ .{ .illegal, .bad_char, "@" }, .{ .word, .none, "x" } });
}

test "lexer: keywords" {
    var lx = init("select `select` Alias", 0, .default);
    const t = lx.next();
    try std.testing.expect(t.isKw("SELECT") and Keywords.class(t.kw) == .reserved);
    try std.testing.expectEqual(@as(u16, 0), lx.next().kw);
    try std.testing.expectEqual(@as(u16, 0), lx.next().kw);
}

test "lexer: string values" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const sql = "'a\\nb\\'c''d\\\\e\\%\\x'";
    var lx = init(sql, 0, .default);
    const t = lx.next();
    try std.testing.expectEqual(Kind.string, t.kind);
    try std.testing.expectEqualStrings("a\nb'c'd\\e\\%x", try stringValue(aa, sql, t, true));
    const sql2 = "'a\\' 'b'";
    var lx2 = init(sql2, 0, state.SqlMode.default.with(.NO_BACKSLASH_ESCAPES));
    const t2 = lx2.next();
    try std.testing.expectEqualStrings("a\\", try stringValue(aa, sql2, t2, false));
    try std.testing.expectEqualStrings("'b'", lx2.next().text(sql2));
    try std.testing.expectEqualStrings("a`b", try quotedName(aa, "`a``b`"));
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
