//! SQLite's lexical structure (tokenize.c) for sqllex.Lexer():
//!
//!  - words: a letter, `_` or a byte from 0x80, then those, digits and
//!    `$`; a keyword (the table of mkkeywordhash, in its order, for
//!    sqlite3_keyword_name()) whatever its case;
//!  - '...' strings; "...", `...` and [...] identifiers ([...] without
//!    doubling); X'...' blobs of an even count of hex digits;
//!  - numbers: 42, 4.2, .5, 1e10, 0x1F, `_` anywhere in the digits
//!    (checked by the parser), a number run into a word is illegal;
//!  - parameters: ?, ?NNN, :name, @name, $name, #name (with `::` and a
//!    Tcl `(...)` suffix);
//!  - comments: `--` to the end of the line, `/* */` (to the end if not
//!    closed; `/*` at the very end is two operators); a UTF-8 BOM is
//!    white space;
//!  - operators: - -> ->> ( ) ; + * / % = == < <= <> << > >= >> != , & ~
//!    | || . (and `!` alone is illegal).

const std = @import("std");
const sqllex = @import("sql/lexer");
/// The token codes (TK_*).
pub const TK = @import("../../sql/tk.zig").TK;

/// SQLite's keywords: mkkeywordhash's table in its order (the order of
/// sqlite3_keyword_name()). A keyword that falls back to an identifier
/// (parse.y's %fallback ID, fallsBack()) is `unreserved`.
pub const keywords = sqllex.Keywords(&keyword_entries);

/// The keywords and their token codes, mkkeywordhash's order.
pub const keyword_list = blk: {
    var l: [entries.len]struct { name: []const u8, code: u8 } = undefined;
    for (entries, &l) |e, *o| o.* = .{ .name = e[0], .code = e[1] };
    break :blk l;
};

const keyword_entries = blk: {
    var e: [entries.len]sqllex.KeywordEntry = undefined;
    for (entries, &e) |k, *o| o.* = .{ k[0], if (fallsBack(k[1])) .unreserved else .reserved };
    break :blk e;
};

/// The token code (TK_*) of keyword number `kw`.
pub fn tokenCode(kw: u16) u8 {
    return codes[kw];
}

const codes = blk: {
    var c: [entries.len + 1]u8 = undefined;
    c[0] = TK.ID;
    for (entries, 1..) |k, i| c[i] = k[1];
    break :blk c;
};

/// The keywords that parse.y's `%fallback ID` lets be identifiers where
/// the grammar has no use for them as keywords.
pub fn fallsBack(tk: u8) bool {
    return switch (tk) {
        TK.ABORT, TK.ACTION, TK.AFTER, TK.ANALYZE, TK.ASC, TK.ATTACH, TK.BEFORE, TK.BEGIN, TK.BY, TK.CASCADE, TK.CAST, TK.COLUMNKW, TK.CONFLICT, TK.DATABASE, TK.DEFERRED, TK.DESC, TK.DETACH, TK.DO, TK.EACH, TK.END, TK.EXCLUSIVE, TK.EXPLAIN, TK.FAIL, TK.FOR, TK.IGNORE, TK.IMMEDIATE, TK.INITIALLY, TK.INSTEAD, TK.LIKE_KW, TK.MATCH, TK.NO, TK.PLAN, TK.QUERY, TK.KEY, TK.OF, TK.OFFSET, TK.PRAGMA, TK.RAISE, TK.RECURSIVE, TK.RELEASE, TK.REPLACE, TK.RESTRICT, TK.ROW, TK.ROWS, TK.ROLLBACK, TK.SAVEPOINT, TK.TEMP, TK.TRIGGER, TK.VACUUM, TK.VIEW, TK.VIRTUAL, TK.WITH, TK.WITHOUT, TK.NULLS, TK.FIRST, TK.LAST, TK.CURRENT, TK.FOLLOWING, TK.PARTITION, TK.PRECEDING, TK.RANGE, TK.UNBOUNDED, TK.EXCLUDE, TK.GROUPS, TK.OTHERS, TK.TIES, TK.GENERATED, TK.ALWAYS, TK.MATERIALIZED, TK.REINDEX, TK.RENAME, TK.CTIME_KW, TK.IF => true,
        else => false,
    };
}

/// mkkeywordhash's table: name and token code.
const entries = [_]struct { []const u8, u8 }{
    .{ "REINDEX", TK.REINDEX },
    .{ "INDEXED", TK.INDEXED },
    .{ "INDEX", TK.INDEX },
    .{ "DESC", TK.DESC },
    .{ "ESCAPE", TK.ESCAPE },
    .{ "EACH", TK.EACH },
    .{ "CHECK", TK.CHECK },
    .{ "KEY", TK.KEY },
    .{ "BEFORE", TK.BEFORE },
    .{ "FOREIGN", TK.FOREIGN },
    .{ "FOR", TK.FOR },
    .{ "IGNORE", TK.IGNORE },
    .{ "REGEXP", TK.LIKE_KW },
    .{ "EXPLAIN", TK.EXPLAIN },
    .{ "INSTEAD", TK.INSTEAD },
    .{ "ADD", TK.ADD },
    .{ "DATABASE", TK.DATABASE },
    .{ "AS", TK.AS },
    .{ "SELECT", TK.SELECT },
    .{ "TABLE", TK.TABLE },
    .{ "LEFT", TK.JOIN_KW },
    .{ "THEN", TK.THEN },
    .{ "END", TK.END },
    .{ "DEFERRABLE", TK.DEFERRABLE },
    .{ "ELSE", TK.ELSE },
    .{ "EXCLUDE", TK.EXCLUDE },
    .{ "DELETE", TK.DELETE },
    .{ "TEMPORARY", TK.TEMP },
    .{ "TEMP", TK.TEMP },
    .{ "OR", TK.OR },
    .{ "ISNULL", TK.ISNULL },
    .{ "NULLS", TK.NULLS },
    .{ "SAVEPOINT", TK.SAVEPOINT },
    .{ "INTERSECT", TK.INTERSECT },
    .{ "TIES", TK.TIES },
    .{ "NOTNULL", TK.NOTNULL },
    .{ "NOT", TK.NOT },
    .{ "NO", TK.NO },
    .{ "NULL", TK.NULL },
    .{ "LIKE", TK.LIKE_KW },
    .{ "EXCEPT", TK.EXCEPT },
    .{ "TRANSACTION", TK.TRANSACTION },
    .{ "ACTION", TK.ACTION },
    .{ "ON", TK.ON },
    .{ "NATURAL", TK.JOIN_KW },
    .{ "ALTER", TK.ALTER },
    .{ "RAISE", TK.RAISE },
    .{ "EXCLUSIVE", TK.EXCLUSIVE },
    .{ "EXISTS", TK.EXISTS },
    .{ "CONSTRAINT", TK.CONSTRAINT },
    .{ "INTO", TK.INTO },
    .{ "OFFSET", TK.OFFSET },
    .{ "OF", TK.OF },
    .{ "SET", TK.SET },
    .{ "TRIGGER", TK.TRIGGER },
    .{ "RANGE", TK.RANGE },
    .{ "GENERATED", TK.GENERATED },
    .{ "DETACH", TK.DETACH },
    .{ "HAVING", TK.HAVING },
    .{ "GLOB", TK.LIKE_KW },
    .{ "BEGIN", TK.BEGIN },
    .{ "INNER", TK.JOIN_KW },
    .{ "REFERENCES", TK.REFERENCES },
    .{ "UNIQUE", TK.UNIQUE },
    .{ "QUERY", TK.QUERY },
    .{ "WITHOUT", TK.WITHOUT },
    .{ "WITH", TK.WITH },
    .{ "OUTER", TK.JOIN_KW },
    .{ "RELEASE", TK.RELEASE },
    .{ "ATTACH", TK.ATTACH },
    .{ "BETWEEN", TK.BETWEEN },
    .{ "NOTHING", TK.NOTHING },
    .{ "GROUPS", TK.GROUPS },
    .{ "GROUP", TK.GROUP },
    .{ "CASCADE", TK.CASCADE },
    .{ "ASC", TK.ASC },
    .{ "DEFAULT", TK.DEFAULT },
    .{ "CASE", TK.CASE },
    .{ "COLLATE", TK.COLLATE },
    .{ "CREATE", TK.CREATE },
    .{ "CURRENT_DATE", TK.CTIME_KW },
    .{ "IMMEDIATE", TK.IMMEDIATE },
    .{ "JOIN", TK.JOIN },
    .{ "INSERT", TK.INSERT },
    .{ "MATCH", TK.MATCH },
    .{ "PLAN", TK.PLAN },
    .{ "ANALYZE", TK.ANALYZE },
    .{ "PRAGMA", TK.PRAGMA },
    .{ "MATERIALIZED", TK.MATERIALIZED },
    .{ "DEFERRED", TK.DEFERRED },
    .{ "DISTINCT", TK.DISTINCT },
    .{ "IS", TK.IS },
    .{ "UPDATE", TK.UPDATE },
    .{ "VALUES", TK.VALUES },
    .{ "VIRTUAL", TK.VIRTUAL },
    .{ "ALWAYS", TK.ALWAYS },
    .{ "WHEN", TK.WHEN },
    .{ "WHERE", TK.WHERE },
    .{ "RECURSIVE", TK.RECURSIVE },
    .{ "ABORT", TK.ABORT },
    .{ "AFTER", TK.AFTER },
    .{ "RENAME", TK.RENAME },
    .{ "AND", TK.AND },
    .{ "DROP", TK.DROP },
    .{ "PARTITION", TK.PARTITION },
    .{ "AUTOINCREMENT", TK.AUTOINCR },
    .{ "TO", TK.TO },
    .{ "IN", TK.IN },
    .{ "CAST", TK.CAST },
    .{ "COLUMN", TK.COLUMNKW },
    .{ "COMMIT", TK.COMMIT },
    .{ "CONFLICT", TK.CONFLICT },
    .{ "CROSS", TK.JOIN_KW },
    .{ "CURRENT_TIMESTAMP", TK.CTIME_KW },
    .{ "CURRENT_TIME", TK.CTIME_KW },
    .{ "CURRENT", TK.CURRENT },
    .{ "PRECEDING", TK.PRECEDING },
    .{ "FAIL", TK.FAIL },
    .{ "LAST", TK.LAST },
    .{ "FILTER", TK.FILTER },
    .{ "REPLACE", TK.REPLACE },
    .{ "FIRST", TK.FIRST },
    .{ "FOLLOWING", TK.FOLLOWING },
    .{ "FROM", TK.FROM },
    .{ "FULL", TK.JOIN_KW },
    .{ "LIMIT", TK.LIMIT },
    .{ "IF", TK.IF },
    .{ "ORDER", TK.ORDER },
    .{ "RESTRICT", TK.RESTRICT },
    .{ "OTHERS", TK.OTHERS },
    .{ "OVER", TK.OVER },
    .{ "RETURNING", TK.RETURNING },
    .{ "RIGHT", TK.JOIN_KW },
    .{ "ROLLBACK", TK.ROLLBACK },
    .{ "ROWS", TK.ROWS },
    .{ "ROW", TK.ROW },
    .{ "UNBOUNDED", TK.UNBOUNDED },
    .{ "UNION", TK.UNION },
    .{ "USING", TK.USING },
    .{ "VACUUM", TK.VACUUM },
    .{ "VIEW", TK.VIEW },
    .{ "WINDOW", TK.WINDOW },
    .{ "DO", TK.DO },
    .{ "BY", TK.BY },
    .{ "INITIALLY", TK.INITIALLY },
    .{ "ALL", TK.ALL },
    .{ "PRIMARY", TK.PRIMARY },
};

pub const lex = struct {
    pub const spec: sqllex.Spec = .{
        .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
        .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
        .numbers = .{ .underscores = .any, .radix = "xX", .tail = .illegal, .radix_empty = .decimal },
        .quotes = &.{
            .{ .open = '\'', .close = '\'', .kind = .string },
            .{ .open = '"', .close = '"', .kind = .quoted_ident },
            .{ .open = '`', .close = '`', .kind = .quoted_ident },
            .{ .open = '[', .close = ']', .kind = .quoted_ident, .doubled = false },
        },
        .params = .{ .question = .numbered },
        .ops = .{
            .list = &.{ "->>", "->", "==", "<=", "<>", "<<", ">=", ">>", "!=", "||" },
            .singles = .of(.{ .chars = "+-*/%=<>|&~" }),
        },
    };
    pub const keywords = @import("lexer.zig").keywords;

    /// None: getToken() reads white space and comments itself (as tokens
    /// of their own), and the lexer starts at a token. The hook keeps the
    /// default skip from reading `/*` at the very end as a comment.
    pub fn skip(_: anytype) ?Lexer.Token {
        return null;
    }

    /// X'...', and the parameters :name @name $name #name.
    pub fn scan(l: anytype, start: usize) ?Lexer.Token {
        const s = l.sql;
        switch (s[start]) {
            'x', 'X' => {
                if (s[start + 1] != '\'') return null;
                var i = start + 2;
                while (std.ascii.isHex(s[i])) i += 1;
                if (s[i] != '\'' or i % 2 != start % 2) {
                    while (s[i] != 0 and s[i] != '\'') i += 1;
                    if (s[i] != 0) i += 1;
                    return l.take(.illegal, .bad_char, start, i);
                }
                return l.take(.string, .blob, start, i + 1);
            },
            ':', '@', '$', '#' => {
                // sqlite3GetToken()'s CC_DOLLAR and CC_VARALPHA.
                var n: usize = 0;
                var i = start + 1;
                var illegal = false;
                while (true) : (i += 1) {
                    const c = s[i];
                    if (c == 0) break;
                    if (Lexer.scan.isIdent(c)) {
                        n += 1;
                    } else if (c == '(' and n > 0) {
                        // Tcl array element: $name(index).
                        while (true) {
                            i += 1;
                            const d = s[i];
                            if (d == 0 or sqllex.space.has(d) or d == ')') break;
                        }
                        if (s[i] == ')') i += 1 else illegal = true;
                        break;
                    } else if (c == ':' and s[i + 1] == ':') {
                        i += 1;
                    } else break;
                }
                if (n == 0 or illegal) return l.take(.illegal, .bad_char, start, i);
                return l.take(.param, .named, start, i);
            },
            else => return null,
        }
    }
};

pub const Lexer = sqllex.Lexer(lex);
pub const Token = Lexer.Token;

/// The token code (TK_*) the parser reads `t` as (tokenize.c's).
pub fn code(sql: []const u8, t: Token) u8 {
    return switch (t.kind) {
        .eof => 0,
        .word => tokenCode(t.kw),
        .quoted_ident => TK.ID,
        .string => if (t.sub == .blob) TK.BLOB else TK.STRING,
        .integer, .float => blk: {
            const raw = t.text(sql);
            if (std.mem.indexOfScalar(u8, raw, '_') != null) break :blk TK.QNUMBER;
            break :blk if (t.kind == .integer) TK.INTEGER else TK.FLOAT;
        },
        .param => TK.VARIABLE,
        .lparen => TK.LP,
        .rparen => TK.RP,
        .comma => TK.COMMA,
        .semi => TK.SEMI,
        .dot => TK.DOT,
        .illegal => TK.ILLEGAL,
        .op => opCode(t.text(sql)),
        .variable, .terminator => unreachable,
    };
}

/// A token of sqlite3GetToken(): its code and length.
pub const Scanned = struct { tk: u8, len: usize };

/// sqlite3GetToken(): the token at `pos` of `sql`, white space
/// (TK_SPACE) and comments (TK_COMMENT) too; at the end TK_ILLEGAL of
/// length 0.
pub fn getToken(sql: [:0]const u8, pos: usize) Scanned {
    const s = sql;
    const c = s[pos];
    if (sqllex.space.has(c)) return .{ .tk = TK.SPACE, .len = sqllex.space.span(s, pos) - pos };
    if (c == 0xef and s[pos + 1] == 0xbb and s[pos + 2] == 0xbf) return .{ .tk = TK.SPACE, .len = 3 };
    if (c == '-' and s[pos + 1] == '-') return .{ .tk = TK.COMMENT, .len = sqllex.lineEnd(s, pos) - pos };
    if (c == '/' and s[pos + 1] == '*' and s[pos + 2] != 0) return .{ .tk = TK.COMMENT, .len = sqllex.blockCommentEnd(false, s, pos).end - pos };
    if (c == 0) return .{ .tk = TK.ILLEGAL, .len = 0 };
    var l = Lexer.init(sql, pos, .{});
    const t = l.next();
    return .{ .tk = code(sql, t), .len = t.end - pos };
}

/// The token code of keyword `word` (any case), TK_ID if it is none
/// (keywordCode() of tokenize.c).
pub fn keywordCode(word: []const u8) u8 {
    return tokenCode(keywords.lookup(word));
}

fn opCode(op: []const u8) u8 {
    const two = op.len > 1;
    return switch (op[0]) {
        '-' => if (two) TK.PTR else TK.MINUS,
        '+' => TK.PLUS,
        '*' => TK.STAR,
        '/' => TK.SLASH,
        '%' => TK.REM,
        '=' => TK.EQ,
        '<' => if (!two) TK.LT else switch (op[1]) {
            '=' => TK.LE,
            '>' => TK.NE,
            else => TK.LSHIFT,
        },
        '>' => if (!two) TK.GT else if (op[1] == '=') TK.GE else TK.RSHIFT,
        '!' => TK.NE,
        '|' => if (two) TK.CONCAT else TK.BITOR,
        '&' => TK.BITAND,
        '~' => TK.BITNOT,
        else => unreachable,
    };
}

// ================================================================= tests

test "sqlite lexer: token kinds and lengths" {
    const cases = [_]struct { []const u8, u8, usize }{
        .{ "select", TK.SELECT, 6 },
        .{ "SeLeCt x", TK.SELECT, 6 },
        .{ "selectx", TK.ID, 7 },
        .{ "current_timestamp", TK.CTIME_KW, 17 },
        .{ "xyz", TK.ID, 3 },
        .{ "x'0aFF'", TK.BLOB, 7 },
        .{ "x'0aF'", TK.ILLEGAL, 6 },
        .{ "123", TK.INTEGER, 3 },
        .{ "1_000", TK.QNUMBER, 5 },
        .{ "0x1F", TK.INTEGER, 4 },
        .{ "1.5e10", TK.FLOAT, 6 },
        .{ ".5", TK.FLOAT, 2 },
        .{ "1e", TK.ILLEGAL, 2 },
        .{ "12abc", TK.ILLEGAL, 5 },
        .{ "'it''s'", TK.STRING, 7 },
        .{ "'open", TK.ILLEGAL, 5 },
        .{ "\"id\"", TK.ID, 4 },
        .{ "[a b]", TK.ID, 5 },
        .{ "`q`", TK.ID, 3 },
        .{ "?12", TK.VARIABLE, 3 },
        .{ ":name", TK.VARIABLE, 5 },
        .{ "$a(b c)", TK.ILLEGAL, 4 },
        .{ "$a::b(x)", TK.VARIABLE, 8 },
        .{ "@", TK.ILLEGAL, 1 },
        .{ "-- c\nx", TK.COMMENT, 4 },
        .{ "/* c */x", TK.COMMENT, 7 },
        .{ "/* c", TK.COMMENT, 4 },
        .{ "->>", TK.PTR, 3 },
        .{ "<>", TK.NE, 2 },
        .{ "!=", TK.NE, 2 },
        .{ "==", TK.EQ, 2 },
        .{ "||", TK.CONCAT, 2 },
        .{ "\xef\xbb\xbfx", TK.SPACE, 3 },
        .{ "\xc3\xa9t\xc3\xa9", TK.ID, 5 },
        .{ "", TK.ILLEGAL, 0 },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        @memcpy(buf[0..c[0].len], c[0]);
        buf[c[0].len] = 0;
        const t = getToken(buf[0..c[0].len :0], 0);
        errdefer std.debug.print("input {s}\n", .{c[0]});
        try std.testing.expectEqual(c[1], t.tk);
        try std.testing.expectEqual(c[2], t.len);
    }
}
