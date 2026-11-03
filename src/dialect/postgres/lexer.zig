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
//!    cast operator.
//!
//! Tokens carry their byte range in the statement text and their value:
//! the folded name of an identifier, the decoded text of a string or
//! quoted identifier (allocated in the arena when it differs from the
//! source).

const std = @import("std");
const sqllex = @import("sqllex");
const ErrorFields = @import("../../sql/util.zig").ErrorFields;
const decimal = @import("../decimal.zig");

/// PostgreSQL's rules for the scanners (scan.l): identifiers of letters,
/// `_` and any non-ASCII byte, then digits and `$` too; nested block
/// comments; 1_000, and 1..2 as 1 and `..`.
pub const spec: sqllex.Spec = .{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
    .comments = .{ .block = .nested },
    .numbers = .{ .underscores = true, .range_dots = true, .radix = "xXoObB" },
};
const scan = sqllex.Scanner(spec);

pub const Kind = enum {
    eof,
    /// An unquoted identifier or keyword; `text` is folded to lower case.
    ident,
    /// A "quoted identifier"; `text` is the name.
    qident,
    /// A string constant; `text` is its value.
    string,
    integer,
    float,
    /// $n; `text` is the digits.
    param,
    /// An operator; `text` is its spelling.
    op,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    semi,
    dot,
    colon,
    /// `::`
    cast,
};

pub const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,
    text: []const u8,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    /// Whether this is the unquoted keyword `kw`, which must be in lower
    /// case as identifiers fold to it: one with upper case could never
    /// match, so it does not compile.
    pub fn isKw(t: Token, comptime kw: []const u8) bool {
        comptime sqllex.assertFolded(.lower, kw);
        return t.kind == .ident and std.mem.eql(u8, t.text, kw);
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
    /// The last error (error.LexFailed): its message and HINT, and
    /// where.
    err: ErrorFields = .{ .message = "" },
    err_pos: usize = 0,
    /// The SQLSTATE of the last error if it is not a syntax error.
    err_state: ?@import("../../sql/sqlite_int.zig").ErrorState = null,
    /// standard_conforming_strings: off, '...' strings take backslash
    /// escapes (as E'...'), and U&'...' is an error.
    standard_strings: bool = true,

    pub fn init(arena: std.mem.Allocator, src: [:0]const u8, pos: usize) Lexer {
        return .{ .src = src, .pos = pos, .arena = arena };
    }

    fn fail(l: *Lexer, at: usize, comptime fmt: []const u8, args: anytype) Error {
        l.err_pos = at;
        l.err = .{ .message = try std.fmt.allocPrint(l.arena, fmt, args) };
        return error.LexFailed;
    }

    /// fail() with PostgreSQL's HINT.
    fn failHint(l: *Lexer, at: usize, hint: []const u8, comptime fmt: []const u8, args: anytype) Error {
        const err = l.fail(at, fmt, args);
        l.err.hint = hint;
        return err;
    }

    /// The HINTs of a Unicode escape that is none: of E'...' and of U&'...'.
    const e_escape_hint = "Unicode escapes must be \\uXXXX or \\UXXXXXXXX.";
    const u_escape_hint = "Unicode escapes must be \\XXXX or \\+XXXXXX.";

    /// The text from `at` to the end of the line, for "at or near".
    fn near(l: *Lexer, at: usize) []const u8 {
        return sqllex.restOfLine(l.src, at);
    }

    /// Skip spaces and comments. Returns an error for an unterminated
    /// block comment.
    pub fn skipSpace(l: *Lexer) Error!void {
        const t = scan.skip(l.src, l.pos);
        if (t.open_comment) |at| return l.fail(at, "unterminated /* comment at or near \"{s}\"", .{l.near(at)});
        l.pos = t.end;
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
            '[' => return l.single(.lbracket),
            ']' => return l.single(.rbracket),
            ',' => return l.single(.comma),
            ';' => return l.single(.semi),
            ':' => {
                if (s[start + 1] == ':') {
                    l.pos += 2;
                    return l.tok(.cast, start, l.pos, "::");
                }
                if (s[start + 1] == '=') {
                    l.pos += 2;
                    return l.tok(.op, start, l.pos, ":=");
                }
                return l.single(.colon);
            },
            '.' => {
                if (scan.isDigit(s[start + 1])) return l.number();
                return l.single(.dot);
            },
            '\'' => return l.string(start, start, !l.standard_strings),
            '"' => return l.quotedIdent(),
            '$' => {
                if (scan.isDigit(s[start + 1])) {
                    const e = sqllex.digits.span(s, start + 1);
                    if (scan.isIdent(s[e])) return l.fail(start, "trailing junk after parameter at or near \"{s}\"", .{s[start .. e + 1]});
                    l.pos = e;
                    return l.tok(.param, start, e, s[start + 1 .. e]);
                }
                if (scan.dollarTag(s, start)) |tag_end| return l.dollarString(start, tag_end);
                return l.fail(start, "syntax error at or near \"$\"", .{});
            },
            '0'...'9' => return l.number(),
            else => {},
        }
        if ((c == 'u' or c == 'U') and s[start + 1] == '&' and (s[start + 2] == '\'' or s[start + 2] == '"')) {
            if (s[start + 2] == '\'' and !l.standard_strings) {
                const err = l.fail(start, "unsafe use of string constant with Unicode escapes", .{});
                l.err.detail = "String constants with Unicode escapes cannot be used when \"standard_conforming_strings\" is off.";
                l.err_state = .of("0A000");
                return err;
            }
            return l.unicodeLiteral(start);
        }
        if (scan.isIdentStart(c)) {
            // E'...', N'...' (one letter right before a quote).
            if (s[start + 1] == '\'') {
                if (c == 'e' or c == 'E') return l.string(start, start + 1, true);
                if (c == 'n' or c == 'N') return l.string(start, start + 1, !l.standard_strings);
            }
            const w = try scan.foldedWord(l.arena, s, start, .lower);
            l.pos = w.end;
            return l.tok(.ident, start, w.end, w.text);
        }
        if (op_chars.has(c)) return l.operator();
        return l.fail(start, "syntax error at or near \"{s}\"", .{s[start .. start + sqllex.charLen(s, start)]});
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
        if (scan.radixPrefix(s, start)) |base| {
            // PostgreSQL's scanner: 0x(_?hexdigit)+, longest match first;
            // "0x" or "0x_" alone is hexfail, a digit or letter after the
            // number (0x1g, 0b102: "0" and an identifier) is junk.
            const r = sqllex.radixDigits(s, start + 2, base, true);
            var e = r.end;
            const j = scan.word(s, start + 1);
            if (j > e and !(r.count == 0 and j == e + 1 and s[e] == '_')) {
                return l.fail(start, "trailing junk after numeric literal at or near \"{s}\"", .{s[start..j]});
            }
            if (r.count == 0) {
                if (s[e] == '_') e += 1;
                l.pos = e;
                return l.fail(start, "invalid {s} integer at or near \"{s}\"", .{ switch (base) {
                    16 => "hexadecimal",
                    8 => "octal",
                    else => "binary",
                }, s[start..e] });
            }
            l.pos = e;
            // Its decimal digits: a number beyond a bigint is a numeric,
            // as a decimal one is.
            return l.tok(.integer, start, e, try toDecimal(l.arena, s[start + 2 .. e], base));
        }
        const n = scan.number(s, start);
        const e = n.end;
        if (scan.isIdentStart(s[e])) {
            return l.fail(start, "trailing junk after numeric literal at or near \"{s}\"", .{s[start..scan.word(s, e)]});
        }
        l.pos = e;
        var text: []const u8 = s[start..e];
        if (n.underscores) {
            var out: std.ArrayList(u8) = .empty;
            for (text) |ch| if (ch != '_') try out.append(l.arena, ch);
            text = out.items;
        }
        if (text[0] == '.') text = try std.mem.concat(l.arena, u8, &.{ "0", text });
        return l.tok(if (n.float) .float else .integer, start, e, text);
    }

    /// A string constant whose opening quote is at `quote` (the token
    /// starts at `start`, before an E or N prefix).
    fn string(l: *Lexer, start: usize, quote: usize, escapes: bool) Error!Token {
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
                while (scan.isSpace(s[j])) : (j += 1) {
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
        l.pos = i;
        const value = if (copied) out.items else s[quote + 1 .. i - 1];
        return l.tok(.string, start, i, value);
    }

    /// One backslash escape of an E'' string at `i`; returns the index
    /// after it.
    fn escape(l: *Lexer, start: usize, i: usize, out: *std.ArrayList(u8)) Error!usize {
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
    fn unicodeLiteral(l: *Lexer, start: usize) Error!Token {
        const s = l.src;
        var t: Token = undefined;
        if (s[start + 2] == '\'') {
            t = try l.string(start, start + 2, false);
        } else {
            l.pos = start + 2;
            t = try l.quotedIdent();
            t.start = @intCast(start);
        }
        // UESCAPE 'c'.
        var esc: u8 = '\\';
        const after = l.pos;
        try l.skipSpace();
        const w = l.pos;
        if (w + 7 <= s.len and std.ascii.eqlIgnoreCase(s[w .. w + 7], "uescape") and !scan.isIdent(s[w + 7])) {
            l.pos = w + 7;
            const e = try l.next();
            const raw = s[e.start..e.end];
            if (e.kind != .string or raw[0] != '\'') return l.fail(e.start, "UESCAPE must be followed by a simple string literal at or near \"{s}\"", .{raw});
            if (e.text.len != 1 or std.ascii.isHex(e.text[0]) or std.mem.indexOfScalar(u8, "+'\" \t\n\r\x0b\x0c", e.text[0]) != null)
                return l.fail(e.start, "invalid Unicode escape character at or near \"{s}\"", .{raw});
            esc = e.text[0];
        } else l.pos = after;
        const in = t.text;
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
        if (t.kind == .qident and out.items.len == 0) return l.fail(start, "zero-length delimited identifier at or near \"\"\"\"", .{});
        t.text = out.items;
        t.end = @intCast(@max(t.end, l.pos));
        return t;
    }

    fn quotedIdent(l: *Lexer) Error!Token {
        const start = l.pos;
        const q = try sqllex.undoubled(l.arena, l.src, start, '"');
        if (!q.closed) return l.fail(start, "unterminated quoted identifier at or near \"{s}\"", .{l.near(start)});
        l.pos = q.end;
        if (q.text.len == 0) return l.fail(start, "zero-length delimited identifier at or near \"\"\"\"", .{});
        return l.tok(.qident, start, q.end, q.text);
    }

    /// $tag$...$tag$, the opening delimiter s[start..tag_end].
    fn dollarString(l: *Lexer, start: usize, tag_end: usize) Error!Token {
        const s = l.src;
        const d = sqllex.dollarEnd(s, start, tag_end);
        if (!d.closed) return l.fail(start, "unterminated dollar-quoted string at or near \"{s}\"", .{l.near(start)});
        l.pos = d.end;
        return l.tok(.string, start, d.end, d.body);
    }

    fn operator(l: *Lexer) Token {
        const s = l.src;
        const start = l.pos;
        var e = start;
        while (op_chars.has(s[e])) : (e += 1) {
            // A comment starts inside the run: the operator ends there.
            if (e > start and scan.commentAt(s, e)) break;
        }
        var n = e - start;
        if (n > 1 and (s[start + n - 1] == '+' or s[start + n - 1] == '-')) {
            var special = false;
            for (s[start .. start + n]) |ch| {
                if (std.mem.indexOfScalar(u8, "~!@#%^&|`?", ch) != null) special = true;
            }
            if (!special) {
                while (n > 1 and (s[start + n - 1] == '+' or s[start + n - 1] == '-')) n -= 1;
            }
        }
        l.pos = start + n;
        return l.tok(.op, start, l.pos, s[start..l.pos]);
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

/// Digits of base `base` (and `_` separators) written in decimal, of any
/// length.
fn toDecimal(a: std.mem.Allocator, digits: []const u8, base: u8) error{OutOfMemory}![]const u8 {
    // Little-endian decimal digits.
    var dec: std.ArrayList(u8) = .empty;
    for (digits) |ch| {
        if (ch != '_') try decimal.mulAddDigit(a, &dec, base, sqllex.digitValue(ch));
    }
    if (dec.items.len == 0) try dec.append(a, 0);
    std.mem.reverse(u8, dec.items);
    for (dec.items) |*d| d.* += '0';
    return dec.items;
}

const op_chars: sqllex.Set = .of(.{ .chars = "+-*/<>=~!@#%^&|`?" });

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
            try testing.expectEqualStrings(msg, l.err.message);
            return;
        };
        if (t.kind == .eof) return error.TestExpectedError;
    }
}

test "pg lexer: identifiers fold, quoted ones keep their case" {
    try expectTokens("SELECT Foo, \"Bar\", \"a\"\"b\", _x1$ FROM t", &.{
        .{ .ident, "select" }, .{ .ident, "foo" }, .{ .comma, "," },    .{ .qident, "Bar" }, .{ .comma, "," },
        .{ .qident, "a\"b" },  .{ .comma, "," },   .{ .ident, "_x1$" }, .{ .ident, "from" }, .{ .ident, "t" },
    });
    // Backticks and brackets are not identifiers.
    try expectTokens("`a` [b]", &.{
        .{ .op, "`" }, .{ .ident, "a" }, .{ .op, "`" }, .{ .lbracket, "[" }, .{ .ident, "b" }, .{ .rbracket, "]" },
    });
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
        .{ .ident, "a" }, .{ .cast, "::" }, .{ .ident, "int" }, .{ .op, "||" },     .{ .ident, "b" }, .{ .op, "<>" },
        .{ .ident, "c" }, .{ .op, "!=" },   .{ .ident, "d" },   .{ .op, "<=" },     .{ .op, "-" },    .{ .integer, "1" },
        .{ .ident, "a" }, .{ .op, "<" },    .{ .op, "-" },      .{ .integer, "1" }, .{ .ident, "x" }, .{ .op, "~~" },
        .{ .ident, "y" },
    });
    try expectTokens("a /* x /* nested */ y */ + -- comment\n b", &.{ .{ .ident, "a" }, .{ .op, "+" }, .{ .ident, "b" } });
    try expectTokens("a+/*c*/b", &.{ .{ .ident, "a" }, .{ .op, "+" }, .{ .ident, "b" } });
    try expectLexError("/* a /* b */", "unterminated /* comment at or near \"/* a /* b */\"");
    try expectLexError("SELECT 123abc", "trailing junk after numeric literal at or near \"123abc\"");
}

test "pg lexer: Unicode escapes" {
    try expectTokens("U&'d\\0061t\\+000061' U&\"d!0061\" UESCAPE '!' E'\\uD83D\\uDE00' u&'a\\\\b'", &.{
        .{ .string, "data" }, .{ .qident, "da" }, .{ .string, "\u{1F600}" }, .{ .string, "a\\b" },
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
