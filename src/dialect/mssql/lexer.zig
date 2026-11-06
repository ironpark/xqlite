//! The T-SQL tokenizer: sqllex.Lexer() with SQL Server's rules (`lex`).
//!
//! Tokens are offsets in the statement text (so that the IR's offsets
//! and error positions point into it); the value of a string or a
//! delimited identifier is computed on demand (stringValue(),
//! identValue()).
//!
//!  - Identifiers: words (letters, digits, `_`, `@`, `#`, `$`; `#t` and
//!    `##t` name temporary tables), `[bracketed]` (`]]` is a `]`) and
//!    `"quoted"` (QUOTED_IDENTIFIER ON, `""` is a `"`).
//!  - Strings: `'it''s'` and `N'unicode'` (sub `national`).
//!  - Numbers: integers, decimals, `1e3`, binary constants `0x0A1B` (an
//!    integer of sub `hex`; `0x` alone is an empty one).
//!  - Variables: `@name` (a local variable, sub `user`) and `@@name` (a
//!    function such as @@ROWCOUNT, sub `system`).
//!  - Comments: `--` to the end of the line and `/* */`, which nest.
//!  - GO: the batch separator, a line holding only `GO` (and an optional
//!    count): a statement end (kind `terminator`), as `;`.
//!  - Keywords: every word the parser compares as one (`lex.keywords`);
//!    SQL Server's reserved words, which are no name, are of the class
//!    `reserved`.

const std = @import("std");
const sqllex = @import("sql/lexer");

/// SQL Server's lexical rules for sqllex.Lexer().
pub const lex = struct {
    pub const spec: sqllex.Spec = .{
        .ident_start = .of(.{ .letters = true, .high = true, .chars = "_#" }),
        .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_#$@" }),
        .comments = .{ .block = .nested },
        .numbers = .{ .radix = "xX" },
        .quotes = &.{
            .{ .open = '[', .close = ']', .kind = .quoted_ident },
            .{ .open = '"', .close = '"', .kind = .quoted_ident },
            .{ .open = '\'', .close = '\'', .kind = .string },
        },
        .prefixes = &.{.{ .letters = "n", .sub = .national }},
        .params = .{ .question = .positional },
        .variables = true,
        .ops = .{
            .list = &.{ "<=", ">=", "<>", "!=", "!<", "!>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "::" },
            .singles = .of(.{ .chars = "+-*/%=<>~^&|{}:" }),
        },
    };

    /// The keywords. The reserved ones are SQL Server's reserved words
    /// and the words that cannot be an alias where one is optional
    /// (Token.isReserved()).
    pub const keywords = sqllex.Keywords(&.{
        .{ "ABSENT", .unreserved },
        .{ "ACTION", .unreserved },
        .{ "ADD", .reserved },
        .{ "ALL", .reserved },
        .{ "ALTER", .reserved },
        .{ "AND", .reserved },
        .{ "ANY", .reserved },
        .{ "APPLY", .reserved },
        .{ "ARRAY", .unreserved },
        .{ "AS", .reserved },
        .{ "ASC", .reserved },
        .{ "AUTHORIZATION", .unreserved },
        .{ "AUTO", .unreserved },
        .{ "BEGIN", .reserved },
        .{ "BETWEEN", .reserved },
        .{ "BREAK", .reserved },
        .{ "BROWSE", .unreserved },
        .{ "BY", .reserved },
        .{ "CACHE", .unreserved },
        .{ "CASCADE", .reserved },
        .{ "CASE", .reserved },
        .{ "CHECK", .reserved },
        .{ "CLUSTERED", .reserved },
        .{ "COLLATE", .reserved },
        .{ "COLUMN", .reserved },
        .{ "COMMIT", .reserved },
        .{ "CONSTRAINT", .reserved },
        .{ "CONTINUE", .reserved },
        .{ "CREATE", .reserved },
        .{ "CROSS", .reserved },
        .{ "CUBE", .unreserved },
        .{ "CURRENT", .reserved },
        .{ "CURRENT_DATE", .reserved },
        .{ "CURRENT_TIME", .reserved },
        .{ "CURRENT_TIMESTAMP", .reserved },
        .{ "CURRENT_USER", .reserved },
        .{ "CURSOR", .unreserved },
        .{ "CYCLE", .unreserved },
        .{ "DATABASE", .unreserved },
        .{ "DECLARE", .reserved },
        .{ "DEFAULT", .reserved },
        .{ "DEFAULT_SCHEMA", .unreserved },
        .{ "DELETE", .reserved },
        .{ "DELETED", .unreserved },
        .{ "DENY", .reserved },
        .{ "DESC", .reserved },
        .{ "DISTINCT", .reserved },
        .{ "DISTRIBUTED", .unreserved },
        .{ "DROP", .reserved },
        .{ "ELSE", .reserved },
        .{ "ENCRYPTION", .unreserved },
        .{ "END", .reserved },
        .{ "ESCAPE", .reserved },
        .{ "EXCEPT", .reserved },
        .{ "EXCLUDE", .unreserved },
        .{ "EXEC", .reserved },
        .{ "EXECUTE", .reserved },
        .{ "EXISTS", .reserved },
        .{ "FETCH", .reserved },
        .{ "FILESTREAM", .unreserved },
        .{ "FILESTREAM_ON", .unreserved },
        .{ "FIRST", .unreserved },
        .{ "FOLLOWING", .unreserved },
        .{ "FOR", .reserved },
        .{ "FORCESCAN", .unreserved },
        .{ "FORCESEEK", .unreserved },
        .{ "FOREIGN", .reserved },
        .{ "FROM", .reserved },
        .{ "FULL", .reserved },
        .{ "FUNCTION", .reserved },
        .{ "GOTO", .reserved },
        .{ "GRANT", .reserved },
        .{ "GROUP", .reserved },
        .{ "GROUPING", .unreserved },
        .{ "GROUPS", .unreserved },
        .{ "HASH", .unreserved },
        .{ "HAVING", .reserved },
        .{ "HOLDLOCK", .unreserved },
        .{ "IDENTITY", .reserved },
        .{ "IDENTITY_INSERT", .unreserved },
        .{ "IF", .reserved },
        .{ "IMPLICIT_TRANSACTIONS", .unreserved },
        .{ "IN", .reserved },
        .{ "INCLUDE", .unreserved },
        .{ "INCLUDE_NULL_VALUES", .unreserved },
        .{ "INCREMENT", .unreserved },
        .{ "INDEX", .reserved },
        .{ "INNER", .reserved },
        .{ "INSERT", .reserved },
        .{ "INSERTED", .unreserved },
        .{ "INT", .unreserved },
        .{ "INTERSECT", .reserved },
        .{ "INTO", .reserved },
        .{ "IS", .reserved },
        .{ "JOIN", .reserved },
        .{ "JSON", .unreserved },
        .{ "KEY", .reserved },
        .{ "LAST", .unreserved },
        .{ "LEFT", .reserved },
        .{ "LIKE", .reserved },
        .{ "LOGIN", .unreserved },
        .{ "LOOP", .unreserved },
        .{ "MARK", .unreserved },
        .{ "MATCHED", .unreserved },
        .{ "MAX", .unreserved },
        .{ "MAXVALUE", .unreserved },
        .{ "MERGE", .reserved },
        .{ "MINVALUE", .unreserved },
        .{ "NEXT", .unreserved },
        .{ "NO", .unreserved },
        .{ "NOLOCK", .unreserved },
        .{ "NONCLUSTERED", .reserved },
        .{ "NOT", .reserved },
        .{ "NOWAIT", .unreserved },
        .{ "NULL", .reserved },
        .{ "NULLS", .unreserved },
        .{ "OBJECT", .unreserved },
        .{ "OFF", .unreserved },
        .{ "OFFSET", .reserved },
        .{ "ON", .reserved },
        .{ "ONLY", .unreserved },
        .{ "OPENJSON", .unreserved },
        .{ "OPTION", .reserved },
        .{ "OR", .reserved },
        .{ "ORDER", .reserved },
        .{ "OTHERS", .unreserved },
        .{ "OUTER", .reserved },
        .{ "OUTPUT", .reserved },
        .{ "OVER", .reserved },
        .{ "PAGLOCK", .unreserved },
        .{ "PARTITION", .unreserved },
        .{ "PATH", .unreserved },
        .{ "PERCENT", .reserved },
        .{ "PERSISTED", .unreserved },
        .{ "PIVOT", .reserved },
        .{ "PRECEDING", .unreserved },
        .{ "PRECISION", .unreserved },
        .{ "PRIMARY", .reserved },
        .{ "PRINT", .reserved },
        .{ "PROC", .reserved },
        .{ "PROCEDURE", .reserved },
        .{ "RAISERROR", .unreserved },
        .{ "RANGE", .unreserved },
        .{ "READCOMMITTED", .unreserved },
        .{ "READPAST", .unreserved },
        .{ "READUNCOMMITTED", .unreserved },
        .{ "REFERENCES", .reserved },
        .{ "REMOTE", .unreserved },
        .{ "REPEATABLEREAD", .unreserved },
        .{ "REPLICATION", .unreserved },
        .{ "RETURN", .reserved },
        .{ "REVOKE", .reserved },
        .{ "RIGHT", .reserved },
        .{ "ROLE", .unreserved },
        .{ "ROLLBACK", .reserved },
        .{ "ROLLUP", .unreserved },
        .{ "ROOT", .unreserved },
        .{ "ROW", .unreserved },
        .{ "ROWCOUNT", .unreserved },
        .{ "ROWGUIDCOL", .unreserved },
        .{ "ROWLOCK", .unreserved },
        .{ "ROWS", .unreserved },
        .{ "SAVE", .reserved },
        .{ "SCALAR", .unreserved },
        .{ "SCHEMA", .unreserved },
        .{ "SCHEMABINDING", .unreserved },
        .{ "SELECT", .reserved },
        .{ "SEQUENCE", .unreserved },
        .{ "SERIALIZABLE", .unreserved },
        .{ "SESSION_USER", .unreserved },
        .{ "SET", .reserved },
        .{ "SOME", .reserved },
        .{ "SOURCE", .unreserved },
        .{ "SPARSE", .unreserved },
        .{ "START", .unreserved },
        .{ "SYNONYM", .unreserved },
        .{ "SYSTEM_USER", .unreserved },
        .{ "TABLE", .reserved },
        .{ "TABLOCK", .unreserved },
        .{ "TABLOCKX", .unreserved },
        .{ "TARGET", .unreserved },
        .{ "TEXTIMAGE_ON", .unreserved },
        .{ "THEN", .reserved },
        .{ "THROW", .unreserved },
        .{ "TIES", .unreserved },
        .{ "TO", .reserved },
        .{ "TOP", .reserved },
        .{ "TRAN", .reserved },
        .{ "TRANSACTION", .reserved },
        .{ "TRANSFER", .unreserved },
        .{ "TRIGGER", .unreserved },
        .{ "TRUNCATE", .reserved },
        .{ "TRY", .unreserved },
        .{ "TYPE", .unreserved },
        .{ "UNBOUNDED", .unreserved },
        .{ "UNION", .reserved },
        .{ "UNIQUE", .reserved },
        .{ "UNPIVOT", .reserved },
        .{ "UPDATE", .reserved },
        .{ "UPDLOCK", .unreserved },
        .{ "USE", .reserved },
        .{ "USER", .unreserved },
        .{ "USING", .reserved },
        .{ "VALUE", .unreserved },
        .{ "VALUES", .reserved },
        .{ "VARYING", .unreserved },
        .{ "VIEW", .reserved },
        .{ "VIEW_METADATA", .unreserved },
        .{ "WAITFOR", .unreserved },
        .{ "WHEN", .reserved },
        .{ "WHERE", .reserved },
        .{ "WHILE", .reserved },
        .{ "WINDOW", .reserved },
        .{ "WITH", .reserved },
        .{ "WITHIN", .reserved },
        .{ "WITHOUT_ARRAY_WRAPPER", .unreserved },
        .{ "WORK", .unreserved },
        .{ "XLOCK", .unreserved },
        .{ "XML", .unreserved },
    });

    /// GO alone on its line (and a count) ends a batch.
    pub fn word(l: anytype, t: anytype) @TypeOf(t) {
        const s = l.sql;
        const start: usize = t.start;
        if (t.end - start == 2 and std.ascii.eqlIgnoreCase(t.text(s), "GO") and sqllex.blankBefore(s, start)) {
            var i: usize = t.end;
            while (s[i] == ' ' or s[i] == '\t') i += 1;
            while (@TypeOf(l.*).scan.isDigit(s[i])) i += 1;
            while (s[i] == ' ' or s[i] == '\t' or s[i] == '\r') i += 1;
            if (s[i] == 0 or s[i] == '\n' or (s[i] == '-' and s[i + 1] == '-')) return l.take(.terminator, .none, start, i);
        }
        return t;
    }
};

pub const Lexer = sqllex.Lexer(lex);
pub const Token = Lexer.Token;
pub const Keywords = lex.keywords;

/// Whether `t` is a decimal integer (not 0x...).
pub fn isDecimal(t: Token) bool {
    return t.kind == .integer and t.sub == .none;
}

/// Whether `t` is a local variable, @name (not @@name).
pub fn isUserVar(t: Token) bool {
    return t.kind == .variable and t.sub == .user;
}

/// Whether `t` is an operator or punctuation: ( ) , . ; + - * / % = < >
/// <= >= <> != !< !> & | ^ ~ += -= *= /= %= &= |= ^= :: { } :
pub fn isOpKind(t: Token) bool {
    return switch (t.kind) {
        .op, .lparen, .rparen, .comma, .semi, .dot => true,
        else => false,
    };
}

/// The name an identifier token stands for: the word itself, or the
/// text between the delimiters with doubled closing delimiters undone
/// (in `a` if any).
pub fn identValue(a: std.mem.Allocator, sql: [:0]const u8, t: Token) error{OutOfMemory}![]const u8 {
    return sqllex.value.name(a, sql, t, null);
}

/// The value of a string token ('...' or N'...').
pub fn stringValue(a: std.mem.Allocator, sql: []const u8, t: Token) error{OutOfMemory}![]const u8 {
    return sqllex.value.plainString(a, sql, t);
}

/// The hex digits of a binary constant (0x0A), padded to an even count
/// with a leading 0 (0xA is 0x0A, as in SQL Server).
pub fn hexDigits(a: std.mem.Allocator, sql: []const u8, t: Token) error{OutOfMemory}![]const u8 {
    return sqllex.evenDigits(a, t.text(sql)[2..]);
}

fn testTokens(sql: [:0]const u8, expected: []const struct { sqllex.Kind, []const u8 }) !void {
    var lx: Lexer = .init(sql, 0, .{});
    for (expected) |e| {
        const t = lx.next();
        try std.testing.expectEqual(e[0], t.kind);
        try std.testing.expectEqualStrings(e[1], t.text(sql));
    }
    try std.testing.expectEqual(sqllex.Kind.eof, lx.next().kind);
}

test "lexer: identifiers, strings, comments, GO" {
    try testTokens("SELECT [a]]b], \"c\"\"d\", N'x''y', #t, @v, @@ROWCOUNT -- c\n/* a /* nested */ b */ 0x1F, 1.5e3, .5", &.{
        .{ .word, "SELECT" },             .{ .quoted_ident, "[a]]b]" }, .{ .comma, "," },
        .{ .quoted_ident, "\"c\"\"d\"" }, .{ .comma, "," },             .{ .string, "N'x''y'" },
        .{ .comma, "," },                 .{ .word, "#t" },             .{ .comma, "," },
        .{ .variable, "@v" },             .{ .comma, "," },             .{ .variable, "@@ROWCOUNT" },
        .{ .integer, "0x1F" },            .{ .comma, "," },             .{ .float, "1.5e3" },
        .{ .comma, "," },                 .{ .float, ".5" },
    });
    try testTokens("SELECT 1\nGO\nSELECT go FROM t\n  go 2\n", &.{
        .{ .word, "SELECT" }, .{ .integer, "1" }, .{ .terminator, "GO" },   .{ .word, "SELECT" }, .{ .word, "go" },
        .{ .word, "FROM" },   .{ .word, "t" },    .{ .terminator, "go 2" },
    });
    try testTokens("a!=b !< c += 1", &.{ .{ .word, "a" }, .{ .op, "!=" }, .{ .word, "b" }, .{ .op, "!<" }, .{ .word, "c" }, .{ .op, "+=" }, .{ .integer, "1" } });
}

test "lexer: keywords" {
    const sql = "select [select] Rows #t";
    var lx: Lexer = .init(sql, 0, .{});
    const sel = lx.next();
    try std.testing.expect(sel.isKw("SELECT") and sel.isReserved());
    const q = lx.next();
    try std.testing.expect(!q.isKw("SELECT") and !q.isReserved());
    const rows = lx.next();
    try std.testing.expect(rows.isKw("rows") and rows.isKwText("ROWS") and !rows.isReserved());
    try std.testing.expect(lx.next().kw == 0);
}

test "lexer: values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql = "'it''s' N'\xc3\xa9' [a]]b] \"a\"\"b\" 0xa";
    var lx: Lexer = .init(sql, 0, .{});
    try std.testing.expectEqualStrings("it's", try stringValue(a, sql, lx.next()));
    try std.testing.expectEqualStrings("\xc3\xa9", try stringValue(a, sql, lx.next()));
    try std.testing.expectEqualStrings("a]b", try identValue(a, sql, lx.next()));
    try std.testing.expectEqualStrings("a\"b", try identValue(a, sql, lx.next()));
    try std.testing.expectEqualStrings("0a", try hexDigits(a, sql, lx.next()));
}
