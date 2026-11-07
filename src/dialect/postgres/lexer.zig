//! The lexical structure of PostgreSQL (the scanner of src/backend/parser
//! /scan.l, for what the PostgreSQL dialect parses):
//!
//!  - identifiers: unquoted ones fold to lower case (ASCII), "quoted"
//!    ones keep their case ("" is a quote); backticks and [brackets] are
//!    not identifiers;
//!  - strings: '...' ('' is a quote, and two strings separated by
//!    whitespace with a newline are one), E'...' with backslash escapes
//!    (\uXXXX surrogate pairs one character), U&'...' and U&"..." with
//!    Unicode escapes [UESCAPE 'c'], N'...', and dollar quoting $$...$$ /
//!    $tag$...$tag$;
//!  - numbers: 42, 4.2, .5, 1e10, 0x1F, 0o17, 0b101, 1_000;
//!  - $1 positional parameters;
//!  - comments: -- to the end of the line and nested /* ... */;
//!  - operators: any run of + - * / < > = ~ ! @ # % ^ & | ` ?, cut
//!    before -- and /*, and without a trailing + or - unless the run has
//!    one of ~ ! @ # % ^ & | ` ? (so that a<-1 is a < -1); `::` is the
//!    cast operator, and `:`, `[`, `]` operators of their own.
//!
//! The tokens are sql/lexer's (`Lexer`, made from the rules of `lex`):
//! kinds and byte ranges, no values. statement() lexes a statement and
//! decodes, once, the values that are not the text as written (a name
//! folded, a string with escapes or doubled quotes, a number of another
//! radix): `Values`, which value() reads. The escapes of strings, and
//! their errors, are the Decoder's.

const std = @import("std");
const sqllex = @import("sql/lexer");
const ErrorFields = @import("../../sql/util.zig").ErrorFields;
const ErrorState = @import("../../sql/sqlite_int.zig").ErrorState;

const value_ = sqllex.value;

const op_chars: sqllex.Set = .of(.{ .chars = "+-*/<>=~!@#%^&|`?" });

/// PostgreSQL's lexical rules for sqllex.Lexer() (scan.l): the lexer
/// finds the tokens; their values and the errors of their escapes are
/// decoded afterwards (statement(), Decoder).
pub const lex = struct {
    pub const spec: sqllex.Spec = .{
        .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
        .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
        .comments = .{ .block = .nested, .unclosed = .illegal },
        .numbers = .{ .underscores = .between, .range_dots = true, .radix = "xXoObB", .tail = .junk, .radix_empty = .illegal },
        .quotes = &.{
            .{ .open = '\'', .close = '\'', .kind = .string, .escapes = true },
            .{ .open = '"', .close = '"', .kind = .quoted_ident },
        },
        .prefixes = &.{
            .{ .letters = "e", .sub = .escape, .escapes = .always },
            .{ .letters = "n", .sub = .national },
        },
        .string_continuation = true,
        .empty_ident_illegal = true,
        .dollar_quotes = true,
        .params = .{ .dollar_number = true },
        .ops = .{ .list = &.{ "::", ":=" }, .run = op_chars, .singles = .of(.{ .chars = ":[]" }) },
    };

    /// The words the parser reads as keywords. `reserved`: PostgreSQL's
    /// reserved keywords and its "type_func_name" ones, which can be
    /// neither a column name nor a bare alias (Parser.colId()); the
    /// others are any name.
    pub const keywords = sqllex.Keywords(sqllex.allKeywords(.reserved, &reserved_words) ++ sqllex.allKeywords(.unreserved, &other_words));

    /// U&'...' and U&"..." and their UESCAPE 'c' clause.
    pub fn scan(l: anytype, start: usize) ?@TypeOf(l.*).Token {
        const s = l.sql;
        const c = s[start];
        if (!((c == 'u' or c == 'U') and s[start + 1] == '&' and (s[start + 2] == '\'' or s[start + 2] == '"'))) return null;
        const str = s[start + 2] == '\'';
        if (str and l.opts.backslash_escapes) return l.take(.illegal, .unicode_off, start, start + 3);
        var t = if (str)
            l.quotedFrom(start, start + 2, lex.spec.quotes[0], false, .unicode)
        else
            l.quotedFrom(start, start + 2, lex.spec.quotes[1], false, .unicode);
        if (t.kind == .illegal) return t;
        const after = l.pos;
        if (l.skip()) |bad| return bad;
        const w = l.pos;
        if (w + 7 <= s.len and std.ascii.eqlIgnoreCase(s[w .. w + 7], "uescape") and !@TypeOf(l.*).scan.isIdent(s[w + 7])) {
            l.pos = w + 7;
            const e = l.next();
            if (e.kind == .illegal) return e;
            if (e.kind != .string or s[e.start] != '\'') return l.token(.illegal, .uescape_follow, e.start, e.end);
            t.end = e.end;
        } else l.pos = after;
        return t;
    }
};

const reserved_words = [_][]const u8{
    "all",           "analyse",      "analyze",      "and",               "any",          "array",
    "as",            "asc",          "asymmetric",   "both",              "case",         "cast",
    "check",         "collate",      "column",       "constraint",        "create",       "current_catalog",
    "current_date",  "current_role", "current_time", "current_timestamp", "current_user", "default",
    "deferrable",    "desc",         "distinct",     "do",                "else",         "end",
    "except",        "false",        "fetch",        "for",               "foreign",      "from",
    "grant",         "group",        "having",       "in",                "initially",    "intersect",
    "into",          "lateral",      "leading",      "limit",             "localtime",    "localtimestamp",
    "not",           "null",         "offset",       "on",                "only",         "or",
    "order",         "placing",      "primary",      "references",        "returning",    "select",
    "session_user",  "some",         "symmetric",    "system_user",       "table",        "then",
    "to",            "trailing",     "true",         "union",             "unique",       "user",
    "using",         "variadic",     "when",         "where",             "window",       "with",
    // type_func_name_keyword
    "authorization", "binary",       "collation",    "concurrently",      "cross",        "current_schema",
    "freeze",        "full",         "ilike",        "inner",             "is",           "isnull",
    "join",          "left",         "like",         "natural",           "notnull",      "outer",
    "overlaps",      "right",        "similar",      "tablesample",       "verbose",
};

/// The other words the parser compares as keywords.
const other_words = [_][]const u8{
    "absent",     "action",       "add",       "alter",           "always",       "at",        "between",   "by",         "cache",       "cascade",
    "chain",      "char",         "character", "characteristics", "comment",      "commit",    "committed", "conflict",   "continue",    "cube",
    "current",    "cycle",        "data",      "database",        "deferred",     "delete",    "domain",    "drop",       "encoding",    "escape",
    "exclude",    "exists",       "extension", "filter",          "first",        "following", "format",    "function",   "generated",   "global",
    "grouping",   "groups",       "identity",  "if",              "immediate",    "include",   "increment", "index",      "inherit",     "inherits",
    "insert",     "interval",     "isolation", "json",            "key",          "keys",      "last",      "level",      "local",       "locked",
    "match",      "materialized", "maxvalue",  "minvalue",        "next",         "no",        "none",      "nothing",    "nowait",      "nulls",
    "object",     "of",           "oids",      "operator",        "ordinality",   "others",    "over",      "overriding", "owned",       "partial",
    "partition",  "pg_temp",      "preceding", "precision",       "preserve",     "procedure", "public",    "range",      "read",        "recursive",
    "rename",     "repeatable",   "replace",   "reset",           "restart",      "restrict",  "role",      "rollup",     "row",         "rows",
    "savepoint",  "scalar",       "schema",    "sequence",        "serializable", "session",   "set",       "share",      "show",        "simple",
    "skip",       "start",        "stored",    "system",          "tablespace",   "temp",      "temporary", "ties",       "time",        "transaction",
    "trigger",    "type",         "unbounded", "uncommitted",     "unknown",      "unlogged",  "update",    "value",      "values",      "varying",
    "view",       "within",       "without",   "work",            "write",        "zone",      "after",     "before",     "compression", "enum",
    "expression", "statistics",   "storage",   "valid",           "owner",
};

pub const Lexer = sqllex.Lexer(lex);
pub const Token = Lexer.Token;
pub const keywords = lex.keywords;

/// Options for Lexer of a session's `standard_strings`.
pub fn lexOptions(standard_strings: bool) sqllex.Options {
    return .{ .backslash_escapes = !standard_strings };
}

pub const Error = error{ LexFailed, OutOfMemory };

/// A lexical error: its message (and DETAIL, HINT), where, and its
/// SQLSTATE if it is not a syntax error.
pub const LexFailure = struct {
    fields: ErrorFields = .{ .message = "" },
    pos: usize,
    state: ?ErrorState = null,
};

// ============================================================ statements

/// The values of a statement's tokens that are not their text as written
/// (defaultValue()): one for each token, null for the text.
pub const Values = struct {
    /// The tokens' starts, in order (the parser may change the tokens).
    starts: []const u32 = &.{},
    vals: []const ?[]const u8 = &.{},

    /// The value of the token at `start`, if it is not its text.
    fn get(v: *const Values, start: u32) ?[]const u8 {
        const Ctx = struct {
            fn order(key: u32, x: u32) std.math.Order {
                return std.math.order(key, x);
            }
        };
        const i = std.sort.binarySearch(u32, v.starts, start, Ctx.order) orelse return null;
        return v.vals[i];
    }
};

/// The tokens of a statement, up to its semicolon.
pub const Statement = struct {
    /// Its tokens, the last eof (at the semicolon, if one ends it).
    toks: []Token,
    /// The offset after the statement (and its semicolon).
    end: usize,
    values: Values,
};

/// Lex the statement that starts at `pos` (leading semicolons are
/// skipped), its strings as `standard_strings` reads them, and decode
/// the values of its tokens. The first lexical error (in the order of
/// the text) fails with error.LexFailed, into `failure`.
pub fn statement(a: std.mem.Allocator, src: [:0]const u8, pos: usize, standard_strings: bool, failure: *LexFailure) Error!Statement {
    const opts = lexOptions(standard_strings);
    var l = Lexer.init(src, pos, opts);
    var toks: std.ArrayList(Token) = .empty;
    var starts: std.ArrayList(u32) = .empty;
    var vals: std.ArrayList(?[]const u8) = .empty;
    var end: usize = src.len;
    while (true) {
        const t = l.next();
        var v: ?[]const u8 = null;
        if (hasEscapes(src, t, opts)) {
            var d: Decoder = .{ .src = src, .arena = a, .standard_strings = standard_strings };
            v = d.decode(t.start) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.LexFailed => {
                    failure.* = .{ .fields = d.err, .pos = d.err_pos, .state = d.err_state };
                    return error.LexFailed;
                },
            };
        } else v = try plainValue(a, src, t);
        if (t.kind == .illegal) {
            failure.* = try illegalError(a, src, t);
            return error.LexFailed;
        }
        if (t.kind == .semi) {
            if (toks.items.len == 0) continue;
            end = t.end;
            try toks.append(a, .{ .kind = .eof, .start = t.start, .end = t.start });
            break;
        }
        try toks.append(a, t);
        if (v != null) {
            try starts.append(a, t.start);
            try vals.append(a, v);
        }
        if (t.kind == .eof) break;
    }
    return .{ .toks = toks.items, .end = end, .values = .{ .starts = starts.items, .vals = vals.items } };
}

/// The value of token `t` of `sql`: decoded (`values`), else its text.
pub fn value(sql: []const u8, values: *const Values, t: Token) []const u8 {
    return values.get(t.start) orelse defaultValue(sql, t);
}

/// The value of `t` as a slice of its text: a word, number or operator
/// itself, a quoted one between its quotes, a parameter's digits.
fn defaultValue(sql: []const u8, t: Token) []const u8 {
    const raw = t.text(sql);
    return switch (t.kind) {
        .quoted_ident => raw[1 .. raw.len - 1],
        .string => if (t.sub == .dollar) value_.dollarBody(sql, t) else sql[value_.openQuote(sql, t) + 1 .. t.end - 1],
        .param => raw[1..],
        else => raw,
    };
}

/// The value of `t` (one without escapes) if it is not defaultValue().
fn plainValue(a: std.mem.Allocator, sql: [:0]const u8, t: Token) error{OutOfMemory}!?[]const u8 {
    const v = switch (t.kind) {
        // A keyword: its name, in lower case already.
        .word => if (t.kw != 0) return keywords.name(t.kw) else try value_.name(a, sql, t, .lower),
        .quoted_ident => try value_.name(a, sql, t, .lower),
        .string => if (t.sub == .dollar) return null else try value_.plainString(a, sql, t),
        .integer, .float => try value_.decimal(a, sql, t),
        else => return null,
    };
    const d = defaultValue(sql, t);
    return if (v.ptr == d.ptr and v.len == d.len) null else v;
}

/// A lexical error: the error of an `illegal` token `t` of `sql`.
pub fn illegalError(a: std.mem.Allocator, sql: [:0]const u8, t: Token) error{OutOfMemory}!LexFailure {
    const s = sql;
    const start: usize = t.start;
    const raw = t.text(sql);
    const near = sqllex.restOfLine(s, start);
    var f: LexFailure = .{ .pos = start };
    // U&"...: the identifier's errors are at its quote.
    const u_ident = raw.len >= 3 and (raw[0] == 'u' or raw[0] == 'U') and raw[1] == '&' and raw[2] == '"';
    f.fields.message = switch (t.sub) {
        .unterminated => switch (raw[0]) {
            '/' => try std.fmt.allocPrint(a, "unterminated /* comment at or near \"{s}\"", .{near}),
            '"' => try std.fmt.allocPrint(a, "unterminated quoted identifier at or near \"{s}\"", .{near}),
            '$' => try std.fmt.allocPrint(a, "unterminated dollar-quoted string at or near \"{s}\"", .{near}),
            else => if (u_ident) blk: {
                f.pos = start + 2;
                break :blk try std.fmt.allocPrint(a, "unterminated quoted identifier at or near \"{s}\"", .{sqllex.restOfLine(s, start + 2)});
            } else try std.fmt.allocPrint(a, "unterminated quoted string at or near \"{s}\"", .{near}),
        },
        .empty => blk: {
            if (u_ident) f.pos = start + 2;
            break :blk "zero-length delimited identifier at or near \"\"\"\"";
        },
        .trailing_junk => if (raw[0] == '$')
            try std.fmt.allocPrint(a, "trailing junk after parameter at or near \"{s}\"", .{raw})
        else
            try std.fmt.allocPrint(a, "trailing junk after numeric literal at or near \"{s}\"", .{raw}),
        .bad_radix => try std.fmt.allocPrint(a, "invalid {s} integer at or near \"{s}\"", .{ switch (raw[1]) {
            'x', 'X' => "hexadecimal",
            'o', 'O' => "octal",
            else => "binary",
        }, raw }),
        .unicode_off => blk: {
            f.fields.detail = "String constants with Unicode escapes cannot be used when \"standard_conforming_strings\" is off.";
            f.state = .of("0A000");
            break :blk "unsafe use of string constant with Unicode escapes";
        },
        .uescape_follow => try std.fmt.allocPrint(a, "UESCAPE must be followed by a simple string literal at or near \"{s}\"", .{raw}),
        else => try std.fmt.allocPrint(a, "syntax error at or near \"{s}\"", .{s[start .. start + sqllex.charLen(s, start)]}),
    };
    return f;
}

/// Whether the value of `t` is decoded with errors of its own: escapes.
/// An unterminated string with escapes too: an escape's error comes
/// before the end is seen.
pub fn hasEscapes(sql: []const u8, t: Token, opts: sqllex.Options) bool {
    return switch (t.kind) {
        .illegal => t.sub == .unterminated and switch (sql[t.start]) {
            '\'' => opts.backslash_escapes,
            'e', 'E' => sql[t.start + 1] == '\'',
            'n', 'N' => sql[t.start + 1] == '\'' and opts.backslash_escapes,
            else => false,
        },
        .string => switch (t.sub) {
            .escape, .unicode => true,
            .none, .national => opts.backslash_escapes,
            else => false,
        },
        .quoted_ident => t.sub == .unicode,
        else => false,
    };
}

// =============================================================== decoder

/// The decoder of the strings and identifiers with escapes (hasEscapes()):
/// E'...', U&'...' and U&"..." [UESCAPE 'c'], and '...' and N'...' with
/// standard_conforming_strings off. It reads the token again from its
/// start, as PostgreSQL's scanner does, and fails with the error of its
/// first bad escape.
pub const Decoder = struct {
    src: [:0]const u8,
    arena: std.mem.Allocator,
    /// standard_conforming_strings: off, '...' strings take backslash
    /// escapes (as E'...').
    standard_strings: bool = true,
    /// The last error (error.LexFailed): its message and HINT, and
    /// where.
    err: ErrorFields = .{ .message = "" },
    err_pos: usize = 0,
    /// The SQLSTATE of the last error if it is not a syntax error.
    err_state: ?ErrorState = null,

    /// A decoded string: its value and the index after it.
    const Decoded = struct { value: []const u8, end: usize };

    fn fail(l: *Decoder, at: usize, comptime fmt: []const u8, args: anytype) Error {
        l.err_pos = at;
        l.err = .{ .message = try std.fmt.allocPrint(l.arena, fmt, args) };
        return error.LexFailed;
    }

    /// fail() with PostgreSQL's HINT.
    fn failHint(l: *Decoder, at: usize, hint: []const u8, comptime fmt: []const u8, args: anytype) Error {
        const err = l.fail(at, fmt, args);
        l.err.hint = hint;
        return err;
    }

    /// The HINTs of a Unicode escape that is none: of E'...' and of U&'...'.
    const e_escape_hint = "Unicode escapes must be \\uXXXX or \\UXXXXXXXX.";
    const u_escape_hint = "Unicode escapes must be \\XXXX or \\+XXXXXX.";

    /// The text from `at` to the end of the line, for "at or near".
    fn near(l: *Decoder, at: usize) []const u8 {
        return sqllex.restOfLine(l.src, at);
    }

    /// The value of the token with escapes that starts at `start`.
    pub fn decode(l: *Decoder, start: usize) Error![]const u8 {
        const s = l.src;
        const c = s[start];
        if (c == '\'') return (try l.string(start, start, !l.standard_strings)).value;
        if ((c == 'u' or c == 'U') and s[start + 1] == '&') return l.unicodeLiteral(start);
        if (c == 'e' or c == 'E') return (try l.string(start, start + 1, true)).value;
        std.debug.assert((c == 'n' or c == 'N') and s[start + 1] == '\'');
        return (try l.string(start, start + 1, !l.standard_strings)).value;
    }

    /// A string constant whose opening quote is at `quote` (the token
    /// starts at `start`, before an E or N prefix).
    fn string(l: *Decoder, start: usize, quote: usize, escapes: bool) Error!Decoded {
        const s = l.src;
        var out: std.ArrayList(u8) = .empty;
        var i = quote + 1;
        // Whether the value is in `out` (else a slice of the text): only
        // once a doubled quote, an escape or a continuation is seen.
        var copied = false;
        var seg_start = i;
        while (true) {
            i = if (escapes) sqllex.indexOfAnyOrNul(2, s, i, .{ '\'', '\\' }) else sqllex.indexOfAnyOrNul(1, s, i, .{'\''});
            const ch = s[i];
            if (ch == 0) return l.fail(start, "unterminated quoted string at or near \"{s}\"", .{l.near(start)});
            if (ch == '\'') {
                if (s[i + 1] == '\'') {
                    try out.appendSlice(l.arena, s[seg_start .. i + 1]);
                    copied = true;
                    i += 2;
                    seg_start = i;
                    continue;
                }
                const close = i;
                i += 1;
                // 'a'
                // 'b' is 'ab': the next string after whitespace with a newline.
                var j = i;
                var newline = false;
                while (Lexer.scan.isSpace(s[j])) : (j += 1) {
                    if (s[j] == '\n' or s[j] == '\r') newline = true;
                }
                if (newline and s[j] == '\'') {
                    try out.appendSlice(l.arena, s[seg_start..close]);
                    copied = true;
                    i = j + 1;
                    seg_start = i;
                    continue;
                }
                if (copied) try out.appendSlice(l.arena, s[seg_start..close]);
                break;
            }
            // A backslash escape.
            try out.appendSlice(l.arena, s[seg_start..i]);
            copied = true;
            i = try l.escape(start, i, &out);
            seg_start = i;
        }
        return .{ .value = if (copied) out.items else s[quote + 1 .. i - 1], .end = i };
    }

    /// One backslash escape of an E'' string at `i`; returns the index
    /// after it.
    fn escape(l: *Decoder, start: usize, i: usize, out: *std.ArrayList(u8)) Error!usize {
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
                var v = unicodeEscape(s, i) orelse return l.failHint(i, e_escape_hint, "invalid Unicode escape", .{});
                var end = i + 2 + @as(usize, if (c == 'u') 4 else 8);
                if (isLowSurrogate(v)) return l.fail(i, "invalid Unicode surrogate pair at or near \"{s}\"", .{s[i..end]});
                if (isHighSurrogate(v)) {
                    // The second half must follow: \uDC00 ... as an escape.
                    const w = if (s[end] == '\\') unicodeEscape(s, end) else null;
                    const w_end = if (w != null) end + 2 + @as(usize, if (s[end + 1] == 'u') 4 else 8) else end;
                    if (w == null or !isLowSurrogate(w.?)) {
                        const tok_near = if (w != null) s[end..w_end] else s[end .. end + sqllex.charLen(s, end)];
                        return l.fail(end, "invalid Unicode surrogate pair at or near \"{s}\"", .{tok_near});
                    }
                    v = 0x10000 + ((v & 0x3FF) << 10) + (w.? & 0x3FF);
                    end = w_end;
                }
                var buf: [4]u8 = undefined;
                const len = if (v == 0 or v > 0x10FFFF) null else std.unicode.utf8Encode(@intCast(v), &buf) catch null;
                try out.appendSlice(l.arena, buf[0 .. len orelse
                    return l.fail(i, "invalid Unicode escape value at or near \"{s}\"", .{s[i..end]})]);
                return end;
            },
            else => try out.append(l.arena, c),
        }
        return i + 2;
    }

    /// U&'...' and U&"..." with Unicode escapes (\XXXX, \+XXXXXX, \\),
    /// the escape character another after UESCAPE 'c' (PostgreSQL's
    /// str_udeescape()). Errors point at the escape.
    fn unicodeLiteral(l: *Decoder, start: usize) Error![]const u8 {
        const s = l.src;
        const ident = s[start + 2] == '"';
        const lit = if (ident) try l.quotedIdent(start + 2) else try l.string(start, start + 2, false);
        // UESCAPE 'c' (the lexer read the clause: it is a string).
        var esc: u8 = '\\';
        var nl = Lexer.init(s, lit.end, lexOptions(l.standard_strings));
        _ = nl.skip();
        const w = nl.pos;
        if (w + 7 <= s.len and std.ascii.eqlIgnoreCase(s[w .. w + 7], "uescape") and !Lexer.scan.isIdent(s[w + 7])) {
            nl.pos = w + 7;
            const e = nl.next();
            const raw = s[e.start..e.end];
            if (e.kind != .string or raw[0] != '\'') return l.fail(e.start, "UESCAPE must be followed by a simple string literal at or near \"{s}\"", .{raw});
            const text = (try l.string(e.start, e.start, !l.standard_strings)).value;
            if (text.len != 1 or std.ascii.isHex(text[0]) or std.mem.indexOfScalar(u8, "+'\" \t\n\r\x0b\x0c", text[0]) != null)
                return l.fail(e.start, "invalid Unicode escape character at or near \"{s}\"", .{raw});
            esc = text[0];
        }
        const in = lit.value;
        var out: std.ArrayList(u8) = .empty;
        var pair_first: u32 = 0;
        var i: usize = 0;
        // Offsets in `in` from the token's start: U& and the quote.
        const base = start + 3;
        while (i < in.len) {
            if (in[i] != esc) {
                if (pair_first != 0) return l.fail(base + i, "invalid Unicode surrogate pair", .{});
                try out.append(l.arena, in[i]);
                i += 1;
                continue;
            }
            if (i + 1 < in.len and in[i + 1] == esc) {
                if (pair_first != 0) return l.fail(base + i, "invalid Unicode surrogate pair", .{});
                try out.append(l.arena, esc);
                i += 2;
                continue;
            }
            const n: usize = if (i + 1 < in.len and in[i + 1] == '+') 6 else 4;
            const digits_at = i + 1 + @as(usize, if (n == 6) 1 else 0);
            if (digits_at + n > in.len) return l.failHint(base + i, u_escape_hint, "invalid Unicode escape", .{});
            var v: u32 = 0;
            for (in[digits_at .. digits_at + n]) |ch| v = v * 16 + (std.fmt.charToDigit(ch, 16) catch return l.failHint(base + i, u_escape_hint, "invalid Unicode escape", .{}));
            if (v == 0 or v > 0x10FFFF) return l.fail(base + i, "invalid Unicode escape value", .{});
            if (pair_first != 0) {
                if (!isLowSurrogate(v)) return l.fail(base + i, "invalid Unicode surrogate pair", .{});
                v = 0x10000 + ((pair_first & 0x3FF) << 10) + (v & 0x3FF);
                pair_first = 0;
            } else if (isLowSurrogate(v)) return l.fail(base + i, "invalid Unicode surrogate pair", .{});
            i = digits_at + n;
            if (isHighSurrogate(v)) {
                pair_first = v;
                continue;
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(v), &buf) catch return l.fail(base + i, "invalid Unicode escape value", .{});
            try out.appendSlice(l.arena, buf[0..len]);
        }
        if (pair_first != 0) return l.fail(base + i, "invalid Unicode surrogate pair", .{});
        if (ident and out.items.len == 0) return l.fail(start, "zero-length delimited identifier at or near \"\"\"\"", .{});
        return out.items;
    }

    /// The "quoted identifier" at `start`.
    fn quotedIdent(l: *Decoder, start: usize) Error!Decoded {
        const q = try sqllex.undoubled(l.arena, l.src, start, '"');
        if (!q.closed) return l.fail(start, "unterminated quoted identifier at or near \"{s}\"", .{l.near(start)});
        if (q.text.len == 0) return l.fail(start, "zero-length delimited identifier at or near \"\"\"\"", .{});
        return .{ .value = q.text, .end = q.end };
    }
};

/// The code point of the escape \uXXXX or \UXXXXXXXX at `i`, null if
/// its hex digits are too few.
fn unicodeEscape(s: [:0]const u8, i: usize) ?u32 {
    const n: usize = switch (s[i + 1]) {
        'u' => 4,
        'U' => 8,
        else => return null,
    };
    var v: u32 = 0;
    for (0..n) |k| v = v * 16 + (std.fmt.charToDigit(s[i + 2 + k], 16) catch return null);
    return v;
}

fn isHighSurrogate(c: u32) bool {
    return c <= 0xFFFF and std.unicode.utf16IsHighSurrogate(@intCast(c));
}

fn isLowSurrogate(c: u32) bool {
    return c <= 0xFFFF and std.unicode.utf16IsLowSurrogate(@intCast(c));
}

// ================================================================= tests

const testing = std.testing;

const Expected = struct { sqllex.Kind, []const u8 };

/// The kinds and values of the tokens of `src` (the eof left out).
fn expectTokens(src: [:0]const u8, expected: []const Expected) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: LexFailure = .{ .pos = 0 };
    const st = try statement(arena.allocator(), src, 0, true, &f);
    try testing.expectEqual(expected.len + 1, st.toks.len);
    for (expected, st.toks[0..expected.len]) |e, t| {
        testing.expectEqual(e[0], t.kind) catch |err| {
            std.debug.print("at {d}: {s}\n", .{ t.start, t.text(src) });
            return err;
        };
        try testing.expectEqualStrings(e[1], value(src, &st.values, t));
    }
    try testing.expectEqual(sqllex.Kind.eof, st.toks[expected.len].kind);
}

fn expectLexError(src: [:0]const u8, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: LexFailure = .{ .pos = 0 };
    try testing.expectError(error.LexFailed, statement(arena.allocator(), src, 0, true, &f));
    try testing.expectEqualStrings(msg, f.fields.message);
}

test "pg lexer: identifiers fold, quoted ones keep their case" {
    try expectTokens("SELECT Foo, \"Bar\", \"a\"\"b\", _x1$ FROM t", &.{
        .{ .word, "select" },       .{ .word, "foo" }, .{ .comma, "," },   .{ .quoted_ident, "Bar" }, .{ .comma, "," },
        .{ .quoted_ident, "a\"b" }, .{ .comma, "," },  .{ .word, "_x1$" }, .{ .word, "from" },        .{ .word, "t" },
    });
    // Backticks and brackets are not identifiers.
    try expectTokens("`a` [b]", &.{
        .{ .op, "`" }, .{ .word, "a" }, .{ .op, "`" }, .{ .op, "[" }, .{ .word, "b" }, .{ .op, "]" },
    });
}

test "pg lexer: keywords" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "SeLeCt \"select\" foo";
    var f: LexFailure = .{ .pos = 0 };
    const st = try statement(arena.allocator(), src, 0, true, &f);
    try testing.expect(st.toks[0].isKw("select"));
    try testing.expectEqual(sqllex.KeywordClass.reserved, keywords.class(st.toks[0].kw));
    try testing.expect(!st.toks[1].isKw("select"));
    try testing.expectEqual(@as(u16, 0), st.toks[2].kw);
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
        .{ .word, "a" }, .{ .op, "::" }, .{ .word, "int" }, .{ .op, "||" },     .{ .word, "b" }, .{ .op, "<>" },
        .{ .word, "c" }, .{ .op, "!=" }, .{ .word, "d" },   .{ .op, "<=" },     .{ .op, "-" },   .{ .integer, "1" },
        .{ .word, "a" }, .{ .op, "<" },  .{ .op, "-" },     .{ .integer, "1" }, .{ .word, "x" }, .{ .op, "~~" },
        .{ .word, "y" },
    });
    try expectTokens("a /* x /* nested */ y */ + -- comment\n b", &.{ .{ .word, "a" }, .{ .op, "+" }, .{ .word, "b" } });
    try expectTokens("a+/*c*/b", &.{ .{ .word, "a" }, .{ .op, "+" }, .{ .word, "b" } });
    try expectLexError("/* a /* b */", "unterminated /* comment at or near \"/* a /* b */\"");
    try expectLexError("SELECT 123abc", "trailing junk after numeric literal at or near \"123abc\"");
}

test "pg lexer: Unicode escapes" {
    try expectTokens("U&'d\\0061t\\+000061' U&\"d!0061\" UESCAPE '!' E'\\uD83D\\uDE00' u&'a\\\\b'", &.{
        .{ .string, "data" }, .{ .quoted_ident, "da" }, .{ .string, "\u{1F600}" }, .{ .string, "a\\b" },
    });
    try expectLexError("SELECT U&'wrong: \\061'", "invalid Unicode escape");
    try expectLexError("SELECT U&'wrong: \\db99xy'", "invalid Unicode surrogate pair");
    try expectLexError("SELECT U&'wrong: \\+2FFFFF'", "invalid Unicode escape value");
    try expectLexError("SELECT U&'x' UESCAPE +", "UESCAPE must be followed by a simple string literal at or near \"+\"");
    try expectLexError("SELECT U&'x' UESCAPE '+'", "invalid Unicode escape character at or near \"'+'\"");
    try expectLexError("SELECT E'wrong: \\u061'", "invalid Unicode escape");
    try expectLexError("SELECT E'\\udb99\\u0061'", "invalid Unicode surrogate pair at or near \"\\u0061\"");
    try expectLexError("SELECT E'\\udb99'", "invalid Unicode surrogate pair at or near \"'\"");
}

test "pg lexer: a statement ends at its semicolon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = ";; a; 'unterminated";
    var f: LexFailure = .{ .pos = 0 };
    const st = try statement(arena.allocator(), src, 0, true, &f);
    try testing.expectEqual(@as(usize, 2), st.toks.len);
    try testing.expectEqual(@as(usize, 5), st.end);
    try testing.expectEqual(@as(u32, 4), st.toks[1].start);
}
