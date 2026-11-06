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
//!  - bind variables :name, :1 and :"name" (their value with the colon);
//!  - comments: -- to the end of the line and /* ... */ (not nested);
//!  - a `/` alone on its line ends a statement, as in SQL*Plus scripts;
//!  - operators: || <> != ^= ~= <= >= => and the single characters.
//!
//! The lexer is sqllex.Lexer(lex): tokens carry their kind, keyword
//! and byte range in the statement text, and value() decodes their
//! value on demand (the folded name of an identifier, the text of a
//! string or quoted identifier).

const std = @import("std");
const sqllex = @import("sql/lexer");

/// Oracle's lexical rules for sqllex.Lexer().
pub const lex = struct {
    pub const spec: sqllex.Spec = .{
        .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
        .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$#" }),
        .comments = .{ .unclosed = .illegal },
        .numbers = .{ .range_dots = true, .float_suffix = "fFdD" },
        .quotes = &.{
            .{ .open = '\'', .close = '\'', .kind = .string },
            .{ .open = '"', .close = '"', .kind = .quoted_ident },
        },
        .prefixes = &.{
            .{ .letters = "n", .sub = .national },
            .{ .letters = "q", .sub = .alt_quote, .body = .alt },
            .{ .letters = "nq", .sub = .alt_quote, .body = .alt },
        },
        .empty_ident_illegal = true,
        .params = .{ .colon = true },
        .ops = .{ .list = &.{ "||", "<>", "!=", "^=", "~=", "<=", ">=", "=>" }, .singles = op_chars },
        .slash_line = true,
    };

    pub const keywords = keyword_table;

    /// An integer too long for a NUMBER(19) is a float (as Oracle's
    /// literals beyond 64 bits).
    pub fn number(l: anytype, t: anytype) @TypeOf(t) {
        var r = t;
        const raw = t.text(l.sql);
        if (t.kind == .integer and raw.len >= 19 and std.fmt.parseInt(i64, raw, 10) == error.Overflow) r.kind = .float;
        return r;
    }
};

pub const Lexer = sqllex.Lexer(lex);
pub const Token = Lexer.Token;
pub const Kind = sqllex.Kind;
pub const Keywords = lex.keywords;

/// The keywords: Oracle's reserved words are of the class `reserved`.
const keyword_table = sqllex.Keywords(sqllex.allKeywords(.reserved, &reserved_words) ++ sqllex.allKeywords(.unreserved, &other_words));

const op_chars: sqllex.Set = .of(.{ .chars = "+-*/<>=!^~|@%&?:[]" });

/// Oracle's reserved words (V$RESERVED_WORDS), which cannot name a
/// column or table unquoted.
const reserved_words = [_][]const u8{
    "ACCESS",     "ADD",      "ALL",        "ALTER",    "AND",        "ANY",        "AS",        "ASC",
    "AUDIT",      "BETWEEN",  "BY",         "CHAR",     "CHECK",      "CLUSTER",    "COLUMN",    "COMMENT",
    "COMPRESS",   "CONNECT",  "CREATE",     "CURRENT",  "DATE",       "DECIMAL",    "DEFAULT",   "DELETE",
    "DESC",       "DISTINCT", "DROP",       "ELSE",     "EXCLUSIVE",  "EXISTS",     "FILE",      "FLOAT",
    "FOR",        "FROM",     "GRANT",      "GROUP",    "HAVING",     "IDENTIFIED", "IMMEDIATE", "IN",
    "INCREMENT",  "INDEX",    "INITIAL",    "INSERT",   "INTEGER",    "INTERSECT",  "INTO",      "IS",
    "LEVEL",      "LIKE",     "LOCK",       "LONG",     "MAXEXTENTS", "MINUS",      "MLSLABEL",  "MODE",
    "MODIFY",     "NOAUDIT",  "NOCOMPRESS", "NOT",      "NOWAIT",     "NULL",       "NUMBER",    "OF",
    "OFFLINE",    "ON",       "ONLINE",     "OPTION",   "OR",         "ORDER",      "PCTFREE",   "PRIOR",
    "PUBLIC",     "RAW",      "RENAME",     "RESOURCE", "REVOKE",     "ROW",        "ROWID",     "ROWNUM",
    "ROWS",       "SELECT",   "SESSION",    "SET",      "SHARE",      "SIZE",       "SMALLINT",  "START",
    "SUCCESSFUL", "SYNONYM",  "SYSDATE",    "TABLE",    "THEN",       "TO",         "TRIGGER",   "UID",
    "UNION",      "UNIQUE",   "UPDATE",     "USER",     "VALIDATE",   "VALUES",     "VARCHAR",   "VARCHAR2",
    "VIEW",       "WHENEVER", "WHERE",      "WITH",
};

/// The other words the parser compares as keywords.
const other_words = [_][]const u8{
    "ABSENT",            "ALLOW",         "ALWAYS",       "APPEND",    "APPLY",          "ARRAY",        "ASCII",
    "AT",                "AUTHORIZATION", "BITMAP",       "BOTH",      "BYTE",           "CACHE",        "CASCADE",
    "CASE",              "CAST",          "CHARACTER",    "COLLATE",   "COLUMNS",        "COMMIT",       "CONDITIONAL",
    "CONNECT_BY_ROOT",   "CONSTRAINT",    "CONSTRAINTS",  "CROSS",     "CUBE",           "CURRENT_DATE", "CURRENT_SCHEMA",
    "CURRENT_TIMESTAMP", "CURRVAL",       "CYCLE",        "DAY",       "DEFERRABLE",     "DEFERRED",     "DEFINITION",
    "DISABLE",           "DISALLOW",      "EDITIONABLE",  "EMPTY",     "ENABLE",         "END",          "ERROR",
    "ERRORS",            "ESCAPE",        "EXCEPT",       "EXCLUDE",   "EXTEND",         "FALSE",        "FETCH",
    "FIRST",             "FOLLOWING",     "FORCE",        "FOREIGN",   "FORMAT",         "FULL",         "FUNCTION",
    "GENERATED",         "GLOBAL",        "GROUPING",     "GROUPS",    "HOUR",           "IDENTITY",     "IF",
    "IGNORE",            "INITIALLY",     "INNER",        "INTERVAL",  "JOIN",           "JSON",         "JSON_TABLE",
    "KEEP",              "KEY",           "KEYS",         "LAST",      "LATERAL",        "LAX",          "LEADING",
    "LEFT",              "LIBRARY",       "LIMIT",        "LOCAL",     "LOCALTIMESTAMP", "LOCKED",       "LOG",
    "MATCHED",           "MATERIALIZED",  "MAXVALUE",     "MINUTE",    "MINVALUE",       "MISMATCH",     "MODEL",
    "MONTH",             "MULTISET",      "NATURAL",      "NESTED",    "NEXT",           "NEXTVAL",      "NO",
    "NOCACHE",           "NOCYCLE",       "NOEXTEND",     "NOFORCE",   "NOKEEP",         "NOMAXVALUE",   "NOMINVALUE",
    "NONEDITIONABLE",    "NOORDER",       "NORELY",       "NOSCALE",   "NOSHARD",        "NOVALIDATE",   "NULLS",
    "OBJECT",            "OFFSET",        "ONLY",         "ORDERED",   "ORDINALITY",     "ORGANIZATION", "OTHERS",
    "OUTER",             "OVER",          "OVERFLOW",     "PACKAGE",   "PARTITION",      "PASSING",      "PATH",
    "PERCENT",           "PIVOT",         "PLAN",         "PRECEDING", "PRECISION",      "PRESERVE",     "PRETTY",
    "PRIMARY",           "PRIVATE",       "PROCEDURE",    "PURGE",     "RANGE",          "READ",         "REFERENCES",
    "RELY",              "REMOVE",        "REPLACE",      "RESPECT",   "RETURN",         "RETURNING",    "RIGHT",
    "ROLLUP",            "SAMPLE",        "SAVEPOINT",    "SCALARS",   "SCALE",          "SCHEMA",       "SEARCH",
    "SECOND",            "SEQUENCE",      "SHARD",        "SIBLINGS",  "SKIP",           "SOME",         "STATEMENT_ID",
    "STRICT",            "SYSTEM",        "SYSTIMESTAMP", "TEMPORARY", "TIES",           "TIME",         "TIMESTAMP",
    "TRAILING",          "TRANSACTION",   "TRUE",         "TRUNCATE",  "TYPE",           "UNBOUNDED",    "UNCONDITIONAL",
    "UNPIVOT",           "USING",         "VALUE",        "VARYING",   "VIRTUAL",        "WAIT",         "WHEN",
    "WINDOW",            "WITHIN",        "WITHOUT",      "WORK",      "WRAPPER",        "WRITE",        "YEAR",
    "ZONE",
};

/// Whether `t` is a reserved word (unquoted).
pub fn isReserved(t: Token) bool {
    return Keywords.class(t.kw) == .reserved;
}

/// The value of token `t` of `sql`: an identifier folded to upper case,
/// a quoted identifier or a string without its quotes (q'[...]': its
/// body), a number as text (`.5` as `0.5`, `3.` as `3.0`, without an f/d
/// suffix), a bind variable with its colon (:"x" as `:x`), else the text
/// as written. In `a` when it differs from the text.
pub fn value(a: std.mem.Allocator, sql: [:0]const u8, t: Token) error{OutOfMemory}![]const u8 {
    const raw = t.text(sql);
    switch (t.kind) {
        .word => return sqllex.fold(a, raw, .upper),
        .quoted_ident => return sqllex.value.name(a, sql, t, null),
        .string => {
            if (t.sub == .alt_quote) return sqllex.value.altBody(sql, t);
            return sqllex.value.plainString(a, sql, t);
        },
        .integer, .float => {
            var text = raw;
            switch (text[text.len - 1]) {
                'f', 'F', 'd', 'D' => text = text[0 .. text.len - 1],
                else => {},
            }
            if (text[0] == '.') text = try std.mem.concat(a, u8, &.{ "0", text });
            if (text[text.len - 1] == '.') text = try std.mem.concat(a, u8, &.{ text, "0" });
            return text;
        },
        .param => {
            if (raw[1] != '"') return raw;
            return std.mem.concat(a, u8, &.{ ":", try sqllex.undouble(a, raw[2 .. raw.len - 1], '"') });
        },
        else => return raw,
    }
}

/// The error of an `illegal` token `t` of `sql`, and where it is.
pub fn illegalError(a: std.mem.Allocator, sql: [:0]const u8, t: Token) error{OutOfMemory}!struct { msg: []const u8, pos: usize } {
    const raw = t.text(sql);
    var pos: usize = t.start;
    const msg: []const u8 = switch (t.sub) {
        .unterminated => switch (raw[0]) {
            '/' => "ORA-01742: comment not properly terminated",
            '"' => "ORA-01740: missing double quote in identifier",
            ':' => blk: {
                pos += 1;
                break :blk "ORA-01740: missing double quote in identifier";
            },
            else => "ORA-01756: quoted string not properly terminated",
        },
        .empty => blk: {
            if (raw[0] == ':') pos += 1;
            break :blk "ORA-01741: illegal zero-length identifier";
        },
        else => try std.fmt.allocPrint(a, "ORA-00911: {s}: invalid character", .{sql[t.start .. t.start + sqllex.charLen(sql, t.start)]}),
    };
    return .{ .msg = msg, .pos = pos };
}

// ================================================================= tests

const testing = std.testing;

fn expectTokens(src: [:0]const u8, expected: []const struct { Kind, []const u8 }) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(src, 0, .{});
    for (expected) |e| {
        const t = l.next();
        testing.expectEqual(e[0], t.kind) catch |err| {
            std.debug.print("at {d}: {s}\n", .{ t.start, t.text(src) });
            return err;
        };
        try testing.expectEqualStrings(e[1], try value(arena.allocator(), src, t));
    }
    try testing.expectEqual(Kind.eof, l.next().kind);
}

fn expectLexError(src: [:0]const u8, msg: []const u8, pos: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var l = Lexer.init(src, 0, .{});
    while (true) {
        const t = l.next();
        if (t.kind == .eof) return error.TestExpectedError;
        if (t.kind != .illegal) continue;
        const e = try illegalError(arena.allocator(), src, t);
        try testing.expectEqualStrings(msg, e.msg);
        try testing.expectEqual(pos, e.pos);
        return;
    }
}

test "oracle lexer: identifiers fold to upper case, quoted ones keep theirs" {
    try expectTokens("select Foo, \"Bar\", \"a\"\"b\", x$1#, emp_id FROM t", &.{
        .{ .word, "SELECT" },       .{ .word, "FOO" }, .{ .comma, "," },   .{ .quoted_ident, "Bar" }, .{ .comma, "," },
        .{ .quoted_ident, "a\"b" }, .{ .comma, "," },  .{ .word, "X$1#" }, .{ .comma, "," },          .{ .word, "EMP_ID" },
        .{ .word, "FROM" },         .{ .word, "T" },
    });
}

test "oracle lexer: keywords" {
    var l = Lexer.init("select Select \"SELECT\" level", 0, .{});
    const a = l.next();
    const b = l.next();
    const c = l.next();
    const d = l.next();
    try testing.expect(a.isKw("SELECT") and b.isKw("select") and !c.isKw("select"));
    try testing.expect(isReserved(a) and isReserved(d) and !isReserved(c));
    try testing.expect(b.isKwText("Select") and !b.isKwText("FROM") and !c.isKwText("SELECT"));
}

test "oracle lexer: strings" {
    try expectTokens("'it''s' '' N'x' q'[a'b]' Q'{c}' q'!d!' nq'<e>' n'a''b'", &.{
        .{ .string, "it's" }, .{ .string, "" },  .{ .string, "x" }, .{ .string, "a'b" },
        .{ .string, "c" },    .{ .string, "d" }, .{ .string, "e" }, .{ .string, "a'b" },
    });
    try expectLexError("SELECT 'abc", "ORA-01756: quoted string not properly terminated", 7);
    try expectLexError("SELECT q'[abc'", "ORA-01756: quoted string not properly terminated", 7);
    try expectLexError("SELECT \"\"", "ORA-01741: illegal zero-length identifier", 7);
    try expectLexError("SELECT :\"\"", "ORA-01741: illegal zero-length identifier", 8);
    try expectLexError("SELECT :\"a", "ORA-01740: missing double quote in identifier", 8);
    try expectLexError("SELECT \"a", "ORA-01740: missing double quote in identifier", 7);
    try expectLexError("SELECT 1 $", "ORA-00911: $: invalid character", 9);
}

test "oracle lexer: numbers, binds, operators, comments, slash lines" {
    try expectTokens("1 1.5 .5 1e3 2.5E-2 3. 1.5f 2d :x :1 :Abc :\"a\"\"b\" 12345678901234567890", &.{
        .{ .integer, "1" },  .{ .float, "1.5" },   .{ .float, "0.5" },                  .{ .float, "1e3" }, .{ .float, "2.5E-2" },
        .{ .float, "3.0" },  .{ .float, "1.5" },   .{ .float, "2" },                    .{ .param, ":x" },  .{ .param, ":1" },
        .{ .param, ":Abc" }, .{ .param, ":a\"b" }, .{ .float, "12345678901234567890" },
    });
    try expectTokens("a||b<>c!=d^=e<=f>=g", &.{
        .{ .word, "A" }, .{ .op, "||" }, .{ .word, "B" }, .{ .op, "<>" }, .{ .word, "C" }, .{ .op, "!=" },
        .{ .word, "D" }, .{ .op, "^=" }, .{ .word, "E" }, .{ .op, "<=" }, .{ .word, "F" }, .{ .op, ">=" },
        .{ .word, "G" },
    });
    try expectTokens("a /* x */ + -- c\n b / c\n /\n", &.{
        .{ .word, "A" }, .{ .op, "+" }, .{ .word, "B" }, .{ .op, "/" }, .{ .word, "C" }, .{ .terminator, "/" },
    });
    try expectLexError("/* a", "ORA-01742: comment not properly terminated", 0);
}
