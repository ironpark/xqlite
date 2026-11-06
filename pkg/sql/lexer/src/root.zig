//! sqllex: the building blocks of SQL lexers, with no dependency but std.
//!
//! What SQL dialects share is in the scanning, not in the tokens: each
//! dialect has its own token kinds, its own order of trying them and its
//! own error wording, but the runs of identifier characters, white space
//! and comments, quoted tokens with doubled quotes, decimal numbers and
//! radix digits are scanned the same way, up to a few rules. So this
//! package gives scanners, and a dialect's lexer stays a dispatch on the
//! first character that calls them:
//!
//! - `Spec` holds a dialect's rules (which characters start and continue
//!   an unquoted word, the comments, the numbers), and `Scanner(spec)`
//!   the scanners specialized to them at compile time: `skip()` (white
//!   space and comments), `commentAt()`, `word()`,
//!   `number()`, `radixPrefix()`, `dollarTag()`.
//! - The rest takes no spec: `quotedEnd()` and `undoubled()` (a quoted
//!   token whose doubled quote stands for one), `blockCommentEnd()`,
//!   `lineEnd()`, `radixDigits()`, `longestOp()`, `dollarEnd()`,
//!   `indexOfAnyOrNul()`.
//! - Decoding is separate from scanning, so that a lexer that keeps raw
//!   slices of the text and decodes on demand and one that decodes as it
//!   tokenizes use the same code: `undouble()`, `fold()`,
//!   `evenDigits()`.
//! - Positions: `lineOf()`, `restOfLine()`, `charLen()`, `blankBefore()`,
//!   `blankAfter()`.
//!
//! Every scanner takes the text as `[:0]const u8` and an index into it,
//! and returns an index: the NUL at the end stops each loop, so a scanner
//! may look a byte past where it is without a bounds check (the text
//! holds no other NUL that matters: a NUL ends it as the end does). What
//! a dialect says about a token left open (an error, or a token of its
//! own) is the dialect's: scanners return where it ends and whether it
//! is closed (`Extent`, or a struct with those two fields and the text).

const std = @import("std");
const lexer = @import("lexer.zig");
const token = @import("token.zig");
const keywords = @import("keywords.zig");

pub const Token = token.Token;
pub const TokenOf = token.TokenOf;
pub const Kind = token.Kind;
pub const Sub = token.Sub;
pub const Lexer = lexer.Lexer;
pub const Options = lexer.Options;
pub const Quote = lexer.Quote;
pub const Prefix = lexer.Prefix;
pub const Keywords = keywords.Keywords;
pub const KeywordClass = keywords.Class;
pub const KeywordEntry = keywords.Entry;
pub const allKeywords = keywords.all;
pub const value = @import("value.zig");

// ============================================================ characters

/// A set of bytes, a table looked up at compile-time-known places (a
/// dialect's sets are comptime constants). It never holds NUL, so a
/// scan of the set's characters stops at the end of the text.
pub const Set = struct {
    bits: [256]bool,

    const empty: Set = .{ .bits = @splat(false) };

    /// Character classes a set is made of.
    pub const Class = struct {
        /// A-Z and a-z.
        letters: bool = false,
        /// 0-9.
        digits: bool = false,
        /// Every byte from 0x80: the bytes of a UTF-8 sequence, so that
        /// any non-ASCII character belongs (as in every dialect here).
        high: bool = false,
        /// These characters too.
        chars: []const u8 = "",
    };

    pub fn of(comptime class: Class) Set {
        var chars: []const u8 = class.chars;
        if (class.letters) chars = chars ++ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
        if (class.digits) chars = chars ++ "0123456789";
        if (class.high) for (0x80..0x100) |c| {
            chars = chars ++ .{@as(u8, c)};
        };
        return empty.with(chars);
    }

    /// This set and the characters `chars`.
    pub fn with(comptime set: Set, comptime chars: []const u8) Set {
        @setEvalBranchQuota(2000);
        var bits = set.bits;
        for (chars) |c| {
            if (c == 0) @compileError("a Set cannot hold NUL");
            bits[c] = true;
        }
        return .{ .bits = bits };
    }

    /// This set without the characters `chars`.
    fn without(comptime set: Set, comptime chars: []const u8) Set {
        var bits = set.bits;
        for (chars) |c| bits[c] = false;
        return .{ .bits = bits };
    }

    pub inline fn has(comptime set: Set, c: u8) bool {
        return set.bits[c];
    }

    /// The index after the run of the set's characters at `i`.
    pub inline fn span(comptime set: Set, s: [:0]const u8, i: usize) usize {
        var e = i;
        while (set.bits[s[e]]) e += 1;
        return e;
    }

    /// Whether every character of `sub` is in `set`.
    fn contains(comptime set: Set, comptime sub: Set) bool {
        for (sub.bits, set.bits) |x, y| if (x and !y) return false;
        return true;
    }
};

/// The white space of SQL as every dialect here has it (C's isspace():
/// space, tab, newline, vertical tab, form feed, carriage return).
pub const space: Set = .of(.{ .chars = " \t\n\r\x0b\x0c" });

pub const digits: Set = .of(.{ .digits = true });

// ================================================================= specs

/// The lexical rules of a dialect that its scanners follow.
pub const Spec = struct {
    /// The characters that start an unquoted word (an identifier or a
    /// keyword).
    ident_start: Set,
    /// The characters of an unquoted word after the first: a superset of
    /// `ident_start`.
    ident: Set,
    comments: Comments = .{},
    numbers: Numbers = .{},

    // What Lexer() reads besides (lexer.zig).

    /// The quote characters, in the order they are tried.
    quotes: []const lexer.Quote = &.{},
    /// Letters before a quote that make a string of another form.
    prefixes: []const lexer.Prefix = &.{},
    /// Strings that follow a string after white space with a newline in
    /// it are part of it (PostgreSQL).
    string_continuation: bool = false,
    /// A delimited identifier with no characters is `illegal` (empty).
    empty_ident_illegal: bool = false,
    /// $tag$...$tag$ (PostgreSQL).
    dollar_quotes: bool = false,
    params: lexer.Params = .{},
    /// @x and @@x (SQL Server).
    variables: bool = false,
    ops: lexer.Ops = .{},
    /// A `/` alone on its line ends a statement (Oracle's SQL*Plus).
    slash_line: bool = false,
};

pub const Comments = struct {
    /// `--` to the end of the line.
    dash_dash: DashDash = .line,
    /// `#` to the end of the line (MySQL).
    hash: bool = false,
    /// `/* ... */`.
    block: Block = .flat,
    /// What a block comment that is not closed is to Lexer().
    unclosed: enum { comment, illegal } = .comment,

    pub const DashDash = enum {
        /// `--` starts a comment.
        line,
        /// Only `--` followed by a space or a control character (or the
        /// end), so that `1--2` is 1 - -2 (MySQL).
        before_space,
    };

    pub const Block = enum {
        /// Not a comment to skip(): the dialect skips these itself
        /// (MariaDB, whose executable comments `/*! ... */` are code).
        none,
        /// The first `*/` closes it.
        flat,
        /// `/*` inside opens another, and each needs its `*/` (the SQL
        /// standard, PostgreSQL, SQL Server).
        nested,
    };
};

/// Where `_` may separate digits (1_000).
pub const Separators = enum {
    /// Nowhere: `_` ends the digits.
    none,
    /// Between two digits (PostgreSQL 16).
    between,
    /// Anywhere in the digits, also first or doubled: the token takes
    /// them and the dialect checks them later (SQLite's QNUMBER).
    any,
};

pub const Numbers = struct {
    /// `_` separating digits.
    underscores: Separators = .none,
    /// `..` after the digits is not a fraction: 1..2 is 1, then `..`
    /// (PostgreSQL, Oracle). Else 1..2 is `1.` and `.2`.
    range_dots: bool = false,
    /// The letters after a `0` that start a radix integer (radixPrefix()):
    /// `x` 16, `o` 8, `b` 2, in the cases given (`"xX"` for 0x1F and
    /// 0X1F).
    radix: []const u8 = "",
    /// What follows a number (Lexer()).
    tail: lexer.Tail = .none,
    /// A radix prefix with no digits (Lexer()).
    radix_empty: lexer.RadixEmpty = .token,
    /// Letters after a decimal number (not before a word character) that
    /// make it a float and are part of it (Oracle's 1.5f, 2d).
    float_suffix: []const u8 = "",
};

/// SQLite's rules (tokenize.c), for code that reads SQLite text: the
/// dialects' catalogs read what sqlite_schema keeps. SQLite's own
/// lexer (src/dialect/sqlite/lexer.zig) is Lexer(spec) with its own
/// hooks and keyword table and does not use these; a test in the engine
/// (pgcatalog.zig) checks that the two agree on where tokens end.
///  - words: a letter, `_` or a byte from 0x80, then those, digits and
///    `$` (IdChar());
///  - comments: `--` to the end of the line, `/* */` not nested;
///  - numbers: `_` anywhere in the digits (SQLite checks them later),
///    `0x` hexadecimal; `1..2` is `1.` and `.2`.
pub const sqlite: Spec = .{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
    .comments = .{ .dash_dash = .line, .block = .flat },
    .numbers = .{ .underscores = .any, .radix = "xX" },
};

/// A decimal number scanned by `Scanner.number()`.
pub const Number = struct {
    /// The index after it.
    end: usize,
    /// Whether it has a fraction or an exponent.
    float: bool,
    /// Whether it has `_` separators (Numbers.underscores).
    underscores: bool,
};

/// White space and comments skipped by `Scanner.skip()`.
pub const Trivia = struct {
    /// The index after them: of the next token, or of the NUL at the end.
    end: usize,
    /// Where a block comment that is not closed starts (then `end` is
    /// the end of the text).
    open_comment: ?usize = null,
};

/// The scanners of the dialect whose rules are `spec`.
pub fn Scanner(comptime spec: Spec) type {
    comptime {
        if (!spec.ident.contains(spec.ident_start)) @compileError("Spec.ident must hold every character of Spec.ident_start");
        for (spec.numbers.radix) |c| _ = radixBase(c) orelse @compileError("not a radix letter: " ++ .{c});
    }
    return struct {
        /// A dollar quote's tag: the characters of a word but `$`.
        const tag_start = spec.ident_start.without("$");
        const tag = spec.ident.without("$");
        const radix: Set = .of(.{ .chars = spec.numbers.radix });

        pub inline fn isIdentStart(c: u8) bool {
            return spec.ident_start.has(c);
        }

        pub inline fn isIdent(c: u8) bool {
            return spec.ident.has(c);
        }

        pub inline fn isSpace(c: u8) bool {
            return space.has(c);
        }

        pub inline fn isDigit(c: u8) bool {
            return digits.has(c);
        }

        /// The index after the unquoted word at `i` (a run of
        /// `Spec.ident`; `i` is where the dialect saw it start).
        pub inline fn word(s: [:0]const u8, i: usize) usize {
            return spec.ident.span(s, i);
        }

        /// Whether a comment of the spec (one that skip() skips) starts
        /// at `i`.
        pub inline fn commentAt(s: [:0]const u8, i: usize) bool {
            const c = spec.comments;
            return switch (s[i]) {
                '-' => s[i + 1] == '-' and (c.dash_dash == .line or s[i + 2] <= ' '),
                '#' => c.hash,
                '/' => c.block != .none and s[i + 1] == '*',
                else => false,
            };
        }

        /// Skip the white space and comments at `i`.
        pub fn skip(s: [:0]const u8, i_start: usize) Trivia {
            var i = i_start;
            while (true) {
                if (space.has(s[i])) {
                    i += 1;
                } else if (!commentAt(s, i)) {
                    return .{ .end = i };
                } else if (s[i] == '/') {
                    const r = blockCommentEnd(spec.comments.block == .nested, s, i);
                    if (!r.closed) return .{ .end = r.end, .open_comment = i };
                    i = r.end;
                } else {
                    i = lineEnd(s, i);
                }
            }
        }

        /// The decimal number at `i`, a digit or a `.` before one: digits,
        /// a fraction (`.` and digits, maybe none), an exponent (`e` or
        /// `E`, a sign, digits; only if a digit follows). What follows the
        /// number (a suffix, junk, a word that starts with digits) is the
        /// dialect's.
        pub fn number(s: [:0]const u8, i: usize) Number {
            const n = spec.numbers;
            var r: Number = .{ .end = i, .float = false, .underscores = false };
            r.end = digitRun(s, r.end, &r.underscores);
            if (s[r.end] == '.' and !(n.range_dots and s[r.end + 1] == '.')) {
                r.float = true;
                r.end = digitRun(s, r.end + 1, &r.underscores);
            }
            if ((s[r.end] == 'e' or s[r.end] == 'E') and (digits.has(s[r.end + 1]) or
                ((s[r.end + 1] == '+' or s[r.end + 1] == '-') and digits.has(s[r.end + 2]))))
            {
                r.float = true;
                r.end = digitRun(s, r.end + 2, &r.underscores);
            }
            return r;
        }

        inline fn digitRun(s: [:0]const u8, i: usize, underscores: *bool) usize {
            var e = i;
            switch (spec.numbers.underscores) {
                .none => while (digits.has(s[e])) : (e += 1) {},
                .between => while (digits.has(s[e]) or (s[e] == '_' and digits.has(s[e + 1]))) : (e += 1) {
                    if (s[e] == '_') underscores.* = true;
                },
                .any => while (digits.has(s[e]) or s[e] == '_') : (e += 1) {
                    if (s[e] == '_') underscores.* = true;
                },
            }
            return e;
        }

        /// If a radix prefix of the spec (`0` and a letter of
        /// Numbers.radix) is at `i`, the base it stands for; the digits
        /// start at `i + 2` (radixDigits()).
        pub inline fn radixPrefix(s: [:0]const u8, i: usize) ?u8 {
            if (s[i] != '0' or !radix.has(s[i + 1])) return null;
            return radixBase(s[i + 1]);
        }

        /// If a dollar-quote delimiter (`$$` or `$tag$`, the tag a word
        /// without `$`) starts at `i` (a `$`), the index after it.
        pub fn dollarTag(s: [:0]const u8, i: usize) ?usize {
            var e = i + 1;
            if (s[e] == '$') return e + 1;
            if (!tag_start.has(s[e])) return null;
            e = tag.span(s, e);
            if (s[e] != '$') return null;
            return e + 1;
        }
    };
}

fn radixBase(c: u8) ?u8 {
    return switch (c) {
        'x', 'X' => 16,
        'o', 'O' => 8,
        'b', 'B' => 2,
        else => null,
    };
}

// ============================================================== scanning

/// Where a token ends, and whether it is closed (else `end` is the
/// index of the NUL at the end of the text).
pub const Extent = struct { end: usize, closed: bool };

/// The index of the first byte at or after `i` that is one of `needles`
/// or NUL (the one at the end if no other), sixteen bytes at a time.
pub inline fn indexOfAnyOrNul(comptime n: usize, s: [:0]const u8, i: usize, needles: [n]u8) usize {
    const lanes = 16;
    const V = @Vector(lanes, u8);
    var e = i;
    while (e + lanes <= s.len) : (e += lanes) {
        const v: V = s[e..][0..lanes].*;
        var hit = v == @as(V, @splat(0));
        inline for (needles) |c| hit = hit | (v == @as(V, @splat(c)));
        if (@reduce(.Or, hit)) return e + std.simd.firstTrue(hit).?;
    }
    while (true) : (e += 1) {
        const c = s[e];
        if (c == 0) return e;
        inline for (needles) |x| if (c == x) return e;
    }
}

/// The index of the newline or NUL that ends the line `i` is on.
pub inline fn lineEnd(s: [:0]const u8, i: usize) usize {
    return indexOfAnyOrNul(1, s, i, .{'\n'});
}

/// The block comment that starts at `i` (its `/*`); with `nested`, each
/// `/*` inside opens another.
pub fn blockCommentEnd(comptime nested: bool, s: [:0]const u8, i: usize) Extent {
    var e = i + 2;
    if (!nested) {
        while (true) {
            e = indexOfAnyOrNul(1, s, e, .{'*'});
            if (s[e] == 0) return .{ .end = e, .closed = false };
            if (s[e + 1] == '/') return .{ .end = e + 2, .closed = true };
            e += 1;
        }
    }
    var depth: usize = 1;
    while (true) {
        e = indexOfAnyOrNul(2, s, e, .{ '*', '/' });
        if (s[e] == 0) return .{ .end = e, .closed = false };
        if (s[e] == '/' and s[e + 1] == '*') {
            depth += 1;
            e += 2;
        } else if (s[e] == '*' and s[e + 1] == '/') {
            e += 2;
            depth -= 1;
            if (depth == 0) return .{ .end = e, .closed = true };
        } else e += 1;
    }
}

/// The quoted token whose opening quote is at `open`, closed by `close`
/// (the opening one, or `]` after `[`), a doubled `close` standing for
/// one. With `escapes`, a backslash escapes the character after it
/// (MySQL).
pub fn quotedEnd(s: [:0]const u8, open: usize, close: u8, escapes: bool) Extent {
    return if (escapes) quotedEndOf(s, open, close, true) else quotedEndOf(s, open, close, false);
}

inline fn quotedEndOf(s: [:0]const u8, open: usize, close: u8, comptime escapes: bool) Extent {
    var i = open + 1;
    while (true) {
        i = if (escapes) indexOfAnyOrNul(2, s, i, .{ close, '\\' }) else indexOfAnyOrNul(1, s, i, .{close});
        const c = s[i];
        if (c == 0) return .{ .end = i, .closed = false };
        if (escapes and c == '\\') {
            i += if (s[i + 1] != 0) 2 else 1;
        } else {
            if (s[i + 1] != close) return .{ .end = i + 1, .closed = true };
            i += 2;
        }
    }
}

/// A quoted token scanned by `undoubled()`.
pub const Quoted = struct {
    /// The index after it (after its closing quote if it is closed).
    end: usize,
    closed: bool,
    /// The text between the quotes, undoubled (if closed).
    text: []const u8,
};

/// The quoted token whose opening quote `q` is at `open` (quotedEnd())
/// and the text between its quotes with doubled quotes undoubled
/// (undouble(): a slice of `s` if there are none, else a copy in `a`).
pub fn undoubled(a: std.mem.Allocator, s: [:0]const u8, open: usize, q: u8) error{OutOfMemory}!Quoted {
    const r = quotedEnd(s, open, q, false);
    if (!r.closed) return .{ .end = r.end, .closed = false, .text = "" };
    return .{ .end = r.end, .closed = true, .text = try undouble(a, s[open + 1 .. r.end - 1], q) };
}

/// A dollar-quoted string scanned by `dollarEnd()`.
pub const Dollar = struct {
    /// The index after its closing delimiter (or of the NUL at the end).
    end: usize,
    closed: bool,
    /// The text between the delimiters (if closed).
    body: []const u8,
};

/// The dollar-quoted string whose opening delimiter, `s[open..body]`,
/// Scanner.dollarTag() found.
pub fn dollarEnd(s: [:0]const u8, open: usize, body: usize) Dollar {
    const n = std.mem.indexOfPos(u8, s, body, s[open..body]) orelse return .{ .end = s.len, .closed = false, .body = "" };
    return .{ .end = n + (body - open), .closed = true, .body = s[body..n] };
}

/// The value of each byte as a digit in any base up to 36 (0-9, then a-z
/// or A-Z), 0xff if none.
const digit_values: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xff);
    for (0..10) |k| t['0' + k] = k;
    for (0..26) |k| {
        t['a' + k] = 10 + k;
        t['A' + k] = 10 + k;
    }
    break :blk t;
};

/// The value of digit `c` in any base up to 36 (0-9, then a-z or A-Z),
/// 0xff if none.
pub inline fn digitValue(c: u8) u8 {
    return digit_values[c];
}

/// The digits of base `base` at `i` (after a prefix such as 0x), with
/// `_` separators where `sep` allows them (`.between`: before a digit).
pub fn radixDigits(s: [:0]const u8, i: usize, base: u8, comptime sep: Separators) struct {
    /// The index after them.
    end: usize,
    /// How many digits (not counting the separators).
    count: usize,
} {
    var e = i;
    var count: usize = 0;
    switch (sep) {
        .none => {
            while (digitValue(s[e]) < base) e += 1;
            count = e - i;
        },
        .between => while (true) {
            const u: usize = @intFromBool(s[e] == '_');
            if (digitValue(s[e + u]) >= base) break;
            e += u + 1;
            count += 1;
        },
        .any => while (true) : (e += 1) {
            if (digitValue(s[e]) < base) {
                count += 1;
            } else if (s[e] != '_') break;
        },
    }
    return .{ .end = e, .count = count };
}

/// The length of the first of the operators `ops` that `s` has at `i`,
/// 0 if none. They are tried in order, so a longer one must come before
/// one that starts it (`<=>` before `<=`): this does not compile
/// otherwise. A switch on the first byte picks the ones to try.
pub inline fn longestOp(comptime ops: []const []const u8, s: [:0]const u8, i: usize) usize {
    comptime for (ops, 0..) |a, k| {
        if (a.len == 0 or std.mem.indexOfScalar(u8, a, 0) != null) @compileError("an operator is not empty and has no NUL");
        for (ops[k + 1 ..]) |b| if (b.len > a.len and std.mem.startsWith(u8, b, a))
            @compileError("operator " ++ b ++ " after " ++ a ++ ", which starts it");
    };
    @setEvalBranchQuota(1000 + 256 * 4 * ops.len);
    switch (s[i]) {
        inline else => |first| {
            inline for (ops) |op| {
                if (op[0] == first and startsAt(s, i + 1, op[1..])) return op.len;
            }
            return 0;
        },
    }
}

/// Whether `s` has `text` (no NUL in it) at `i`. A byte past the end is
/// read only after the NUL matched, which it cannot.
inline fn startsAt(s: [:0]const u8, i: usize, comptime text: []const u8) bool {
    inline for (text, 0..) |c, k| {
        if (s[i + k] != c) return false;
    }
    return true;
}

// ============================================================== decoding

/// `inner` (the text between a token's quotes) with each doubled `q`
/// undoubled: `inner` itself if it has none, else a copy in `a`.
pub fn undouble(a: std.mem.Allocator, inner: []const u8, q: u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, q) == null) return inner;
    var out: std.ArrayList(u8) = try .initCapacity(a, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        out.appendAssumeCapacity(inner[i]);
        if (inner[i] == q) i += 1;
    }
    return out.items;
}

pub const Case = enum { lower, upper };

/// Fails to compile unless `word` is in `case` (no ASCII letter of the
/// other case): a word that a lexer's folded names are matched against
/// could never match otherwise.
pub fn assertFolded(comptime case: Case, comptime word: []const u8) void {
    comptime for (word) |c| if (notIn(case, c)) @compileError("word not in " ++ @tagName(case) ++ " case: " ++ word);
}

/// `word` folded to `case` (ASCII letters only): `word` itself if it is
/// in that case already, else a copy in `a`.
pub fn fold(a: std.mem.Allocator, word: []const u8, comptime case: Case) error{OutOfMemory}![]const u8 {
    for (word) |c| {
        if (notIn(case, c)) break;
    } else return word;
    return foldCopy(a, word, case);
}

/// Whether `c` is a letter of the other case than `case`.
inline fn notIn(comptime case: Case, c: u8) bool {
    return if (case == .lower) c >= 'A' and c <= 'Z' else c >= 'a' and c <= 'z';
}

fn foldCopy(a: std.mem.Allocator, word: []const u8, comptime case: Case) error{OutOfMemory}![]const u8 {
    const out = try a.alloc(u8, word.len);
    for (word, out) |c, *o| o.* = if (case == .lower) std.ascii.toLower(c) else std.ascii.toUpper(c);
    return out;
}

/// Hex digits padded to an even count with a leading 0 (0xA is 0x0A in
/// MySQL and SQL Server): `hex` itself if even, else a copy in `a`.
pub fn evenDigits(a: std.mem.Allocator, hex: []const u8) error{OutOfMemory}![]const u8 {
    if (hex.len % 2 == 0) return hex;
    const out = try a.alloc(u8, hex.len + 1);
    out[0] = '0';
    @memcpy(out[1..], hex);
    return out;
}

// ============================================================= positions

/// The line (from 1) that `pos` is on.
pub fn lineOf(s: []const u8, pos: usize) usize {
    return 1 + std.mem.count(u8, s[0..pos], "\n");
}

/// The text from `at` to the end of its line (for an error's "near"):
/// to the newline or the NUL, as lineEnd(). A NUL inside the text ends
/// it for the lexers, and for a C caller reading the message.
pub fn restOfLine(s: [:0]const u8, at: usize) []const u8 {
    return s[at..lineEnd(s, at)];
}

/// The length of the UTF-8 character at `i` (1 for a byte that starts
/// none), no more than is left of `s`: 0 at the end.
pub fn charLen(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const n: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(n, s.len - i);
}

/// Whether only spaces, tabs and carriage returns are between the start
/// of the line and `i`.
pub fn blankBefore(s: []const u8, i: usize) bool {
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

/// Whether only spaces, tabs and carriage returns are between `i` and
/// the end of the line.
pub fn blankAfter(s: [:0]const u8, i: usize) bool {
    var j = i;
    while (s[j] != 0 and s[j] != '\n') : (j += 1) {
        switch (s[j]) {
            ' ', '\t', '\r' => {},
            else => return false,
        }
    }
    return true;
}

// ================================================================= tests

const testing = std.testing;

test {
    _ = keywords;
    _ = lexer;
    _ = value;
}

/// Specs like the dialects' (src/dialect/*/lexer.zig), to test the rules
/// they pick.
const pg_like = Scanner(.{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
    .comments = .{ .block = .nested },
    .numbers = .{ .underscores = .between, .range_dots = true, .radix = "xXoObB" },
});
const oracle_like = Scanner(.{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$#" }),
    .numbers = .{ .range_dots = true },
});
const mysql_like = Scanner(.{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_$" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_$" }),
    .comments = .{ .dash_dash = .before_space, .hash = true },
    .numbers = .{ .radix = "xXb" },
});
const tsql_like = Scanner(.{
    .ident_start = .of(.{ .letters = true, .high = true, .chars = "_#" }),
    .ident = .of(.{ .letters = true, .digits = true, .high = true, .chars = "_#$@" }),
    .comments = .{ .block = .nested },
});

test "sets" {
    const set: Set = comptime Set.of(.{ .letters = true, .chars = "_" }).with("$").without("a");
    try testing.expect(set.has('Z') and set.has('_') and set.has('$') and !set.has('a') and !set.has('1') and !set.has(0));
    try testing.expectEqual(@as(usize, 4), set.span("xY_$a", 0));
    try testing.expect(space.has('\x0b') and !space.has(0) and !space.has('a'));
    try testing.expect(pg_like.isIdentStart(0xc3) and !pg_like.isIdentStart('$') and pg_like.isIdent('$'));
    try testing.expect(!oracle_like.isIdentStart('#') and oracle_like.isIdent('#'));
    try testing.expect(tsql_like.isIdentStart('#') and tsql_like.isIdent('@') and !mysql_like.isIdent('@'));
    try testing.expect(pg_like.isDigit('7') and !pg_like.isDigit('a') and pg_like.isSpace('\x0c'));
}

test "words" {
    try testing.expectEqual(@as(usize, 6), pg_like.word("ab$1é+", 0));
    try testing.expectEqual(@as(usize, 4), oracle_like.word("x$1#,", 0));
    try testing.expectEqual(@as(usize, 4), tsql_like.word("##t@ ", 0));
    // A word that starts with digits (MySQL's 1abc) is the dialect's call.
    try testing.expectEqual(@as(usize, 4), mysql_like.word("1abc", 0));
}

test "comments" {
    // Both kinds of line comment run to the newline (not past it).
    try testing.expectEqual(Trivia{ .end = 7 }, pg_like.skip("  -- c\nx", 0));
    try testing.expectEqual(Trivia{ .end = 3 }, pg_like.skip("--c", 0));
    // Nested or not.
    try testing.expectEqual(Trivia{ .end = 22 }, pg_like.skip("/* a /* nested */ b */x", 0));
    try testing.expectEqual(Trivia{ .end = 16 }, oracle_like.skip("/* a /* flat */ b */", 0));
    try testing.expectEqual(Trivia{ .end = 12, .open_comment = 0 }, pg_like.skip("/* a /* b */", 0));
    try testing.expectEqual(Trivia{ .end = 7, .open_comment = 3 }, oracle_like.skip(" \n /* a", 0));
    // `/*/` does not close itself; `/**/` is empty.
    try testing.expect(pg_like.skip("/*/", 0).open_comment != null);
    try testing.expectEqual(Trivia{ .end = 4 }, tsql_like.skip("/**/", 0));
    // MySQL: `-- ` and `#`; `--x` is no comment.
    try testing.expectEqual(Trivia{ .end = 0 }, mysql_like.skip("--x", 0));
    try testing.expectEqual(Trivia{ .end = 2 }, mysql_like.skip("--", 0));
    try testing.expectEqual(Trivia{ .end = 7 }, mysql_like.skip("-- a\n#b", 0));
    try testing.expectEqual(Trivia{ .end = 0 }, pg_like.skip("#b", 0));
    try testing.expect(mysql_like.commentAt("#", 0) and !pg_like.commentAt("#", 0) and pg_like.commentAt("/*", 0) and !pg_like.commentAt("/", 0));
    // A minus alone, a slash alone.
    try testing.expectEqual(Trivia{ .end = 1 }, pg_like.skip(" -1", 0));
    try testing.expectEqual(Trivia{ .end = 0 }, pg_like.skip("/x", 0));
    try testing.expectEqual(Extent{ .end = 6, .closed = true }, blockCommentEnd(false, "/*/**/", 0));
    try testing.expectEqual(Extent{ .end = 6, .closed = false }, blockCommentEnd(true, "/*/**/", 0));
    // Longer than a vector, and a NUL that ends the text early.
    try testing.expectEqual(Extent{ .end = 39, .closed = true }, blockCommentEnd(false, "/* 345678901234567890123456789012345 */x", 0));
    try testing.expectEqual(Extent{ .end = 20, .closed = false }, blockCommentEnd(true, "/* 34567890123456789\x00 */ 12345678901234567890", 0));
    try testing.expectEqual(@as(usize, 21), lineEnd("-- 345678901234567890\n", 0));
    try testing.expectEqual(@as(usize, 18), lineEnd("-- 345678901234567\x00 \n", 0));
}

fn expectNumber(comptime S: type, src: [:0]const u8, end: usize, float: bool) !void {
    const n = S.number(src, 0);
    testing.expectEqual(end, n.end) catch |err| {
        std.debug.print("{s}\n", .{src});
        return err;
    };
    try testing.expectEqual(float, n.float);
}

test "numbers" {
    try expectNumber(pg_like, "42", 2, false);
    try expectNumber(pg_like, "4.2", 3, true);
    try expectNumber(pg_like, ".5", 2, true);
    try expectNumber(pg_like, "3.", 2, true);
    try expectNumber(pg_like, "1e10", 4, true);
    try expectNumber(pg_like, "1E+3x", 4, true);
    // `1e` and `1e+` have no exponent: the e is the dialect's (junk, or
    // a word).
    try expectNumber(pg_like, "1e", 1, false);
    try expectNumber(pg_like, "1e+", 1, false);
    try expectNumber(pg_like, "1.5e-", 3, true);
    // Separators between digits only.
    try expectNumber(pg_like, "1_000", 5, false);
    try testing.expect(pg_like.number("1_000", 0).underscores);
    try expectNumber(pg_like, "1__0", 1, false);
    try expectNumber(pg_like, "1_", 1, false);
    try expectNumber(pg_like, "1_0.0_1e1_0", 11, true);
    try expectNumber(oracle_like, "1_000", 1, false);
    // 123abc: the number ends at the letters (junk to PostgreSQL, a word
    // to MySQL).
    try expectNumber(pg_like, "123abc", 3, false);
    // 1..2
    try expectNumber(pg_like, "1..2", 1, false);
    try expectNumber(oracle_like, "1..2", 1, false);
    try expectNumber(mysql_like, "1..2", 2, true);
    try expectNumber(tsql_like, "1.2.3", 3, true);
}

test "radix digits" {
    try testing.expectEqual(@as(?u8, 16), pg_like.radixPrefix("0X1", 0));
    try testing.expectEqual(@as(?u8, 8), pg_like.radixPrefix("0o1", 0));
    try testing.expectEqual(@as(?u8, 2), mysql_like.radixPrefix("0b1", 0));
    try testing.expectEqual(@as(?u8, null), mysql_like.radixPrefix("0B1", 0));
    try testing.expectEqual(@as(?u8, null), tsql_like.radixPrefix("0x1", 0));
    try testing.expectEqual(@as(?u8, null), pg_like.radixPrefix("1x1", 0));
    try testing.expectEqual(@as(usize, 4), radixDigits("0x1F", 2, 16, .none).end);
    try testing.expectEqual(@as(usize, 2), radixDigits("0x1Fg", 2, 16, .none).count);
    // 0x alone, 0x_ alone.
    try testing.expectEqual(@as(usize, 0), radixDigits("0x", 2, 16, .between).count);
    const lone = radixDigits("0x_", 2, 16, .between);
    try testing.expect(lone.count == 0 and lone.end == 2);
    const sep = radixDigits("0b1_01_", 2, 2, .between);
    try testing.expect(sep.count == 3 and sep.end == 6);
    try testing.expectEqual(@as(usize, 3), radixDigits("0o78", 2, 8, .none).end);
    try testing.expectEqual(@as(u8, 35), digitValue('Z'));
    try testing.expectEqual(@as(u8, 0xff), digitValue(0));
    for (0..256) |c| try testing.expectEqual(std.fmt.charToDigit(@intCast(c), 36) catch 0xff, digitValue(@intCast(c)));
}

test "quoted tokens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try undoubled(a, "x'it''s' y", 1, '\'');
    try testing.expect(r.closed);
    try testing.expectEqualStrings("it's", r.text);
    try testing.expectEqual(@as(usize, 8), r.end);
    try testing.expectEqual(Quoted{ .end = 5, .closed = false, .text = "" }, try undoubled(a, "'open", 0, '\''));
    try testing.expect(!(try undoubled(a, "'open''", 0, '\'')).closed);
    try testing.expectEqualStrings("", (try undoubled(a, "''", 0, '\'')).text);
    try testing.expectEqual(Extent{ .end = 6, .closed = true }, quotedEnd("'a\\'b'", 0, '\'', true));
    // Without escapes the backslash is a character: the quote after it
    // closes the token.
    try testing.expectEqual(Extent{ .end = 4, .closed = true }, quotedEnd("'a\\'b", 0, '\'', false));
    try testing.expectEqual(Extent{ .end = 3, .closed = false }, quotedEnd("'ab", 0, '\'', false));
    // A backslash at the end escapes nothing.
    try testing.expectEqual(Extent{ .end = 3, .closed = false }, quotedEnd("'a\\", 0, '\'', true));
    // [brackets]: `]]` is a `]`.
    try testing.expectEqual(Extent{ .end = 6, .closed = true }, quotedEnd("[a]]b]c", 0, ']', false));
    // Longer than a vector.
    try testing.expectEqual(Extent{ .end = 38, .closed = true }, quotedEnd("'234567890123456789\\'12345678901234''' x", 0, '\'', true));
    try testing.expectEqualStrings("a]b", try undouble(a, "a]]b", ']'));
    try testing.expectEqualStrings("a`b", try undouble(a, "a``b", '`'));
    const plain = "plain";
    try testing.expect((try undouble(a, plain, '\'')).ptr == plain.ptr);
}

test "dollar quotes" {
    const s: [:0]const u8 = "$$a'b$$ $f$ $$ $f$ $1 $a $é$x$é$ $_1$";
    try testing.expectEqual(@as(?usize, 2), pg_like.dollarTag(s, 0));
    const d = dollarEnd(s, 0, 2);
    try testing.expect(d.closed and d.end == 7);
    try testing.expectEqualStrings("a'b", d.body);
    try testing.expectEqual(@as(?usize, 11), pg_like.dollarTag(s, 8));
    try testing.expectEqual(@as(usize, 18), dollarEnd(s, 8, 11).end);
    try testing.expectEqualStrings(" $$ ", dollarEnd(s, 8, 11).body);
    // $1 is a parameter, $a no tag (no closing $).
    try testing.expectEqual(@as(?usize, null), pg_like.dollarTag(s, 19));
    try testing.expectEqual(@as(?usize, null), pg_like.dollarTag(s, 22));
    try testing.expectEqual(@as(?usize, 29), pg_like.dollarTag(s, 25));
    try testing.expectEqual(@as(?usize, 6), pg_like.dollarTag("x $_1$", 2));
    // Not closed.
    try testing.expectEqual(Dollar{ .end = 6, .closed = false, .body = "" }, dollarEnd("$q$abc", 0, 3));
}

test "operators" {
    const ops = [_][]const u8{ "<=>", "->>", "<=", "->", "||" };
    try testing.expectEqual(@as(usize, 3), longestOp(&ops, "a<=>b", 1));
    try testing.expectEqual(@as(usize, 2), longestOp(&ops, "a<=b", 1));
    try testing.expectEqual(@as(usize, 2), longestOp(&ops, "->", 0));
    try testing.expectEqual(@as(usize, 0), longestOp(&ops, "<", 0));
    try testing.expectEqual(@as(usize, 0), longestOp(&ops, "", 0));
}

test "decoding" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("select_é", try fold(a, "SeLeCt_é", .lower));
    try testing.expectEqualStrings("SELECT_é", try fold(a, "SeLeCt_é", .upper));
    const lower = "already";
    try testing.expect((try fold(a, lower, .lower)).ptr == lower.ptr);
    comptime assertFolded(.lower, "select_1");
    comptime assertFolded(.upper, "SELECT_1");
    try testing.expectEqualStrings("0a", try evenDigits(a, "a"));
    try testing.expectEqualStrings("0a1b", try evenDigits(a, "0a1b"));
}

test "positions" {
    const s: [:0]const u8 = "SELECT 1\n  FROM t\r\n  /\nGO 2";
    try testing.expectEqual(@as(usize, 1), lineOf(s, 3));
    try testing.expectEqual(@as(usize, 2), lineOf(s, 9));
    try testing.expectEqualStrings("FROM t\r", restOfLine(s, 11));
    try testing.expectEqualStrings("GO 2", restOfLine(s, 23));
    // A NUL ends the line as the end does.
    try testing.expectEqualStrings("ab", restOfLine("ab\x00cd\nx", 0));
    try testing.expect(blankBefore(s, 11) and !blankBefore(s, 13) and blankBefore(s, 0));
    try testing.expect(blankBefore(s, 21) and blankAfter(s, 22) and !blankAfter(s, 11));
    try testing.expect(blankAfter(s, 27));
    try testing.expectEqual(@as(usize, 2), charLen("é", 0));
    try testing.expectEqual(@as(usize, 1), charLen("\xc3", 0));
    try testing.expectEqual(@as(usize, 1), charLen("\xff", 0));
    try testing.expectEqual(@as(usize, 0), charLen("ab", 2));
    try testing.expectEqual(@as(usize, 0), charLen("ab", 5));
}

test "SQLite's rules" {
    const S = Scanner(sqlite);
    try std.testing.expect(S.isIdentStart('_') and !S.isIdentStart('$') and S.isIdent('$') and S.isIdent(0xc3));
    try std.testing.expectEqual(@as(usize, 6), S.number("1.5e-3", 0).end);
    try std.testing.expectEqual(@as(usize, 5), S.number("1_000", 0).end);
    try std.testing.expectEqual(@as(usize, 4), S.number("9__.", 0).end);
    try std.testing.expectEqual(@as(usize, 6), radixDigits("0x1__F", 2, 16, .any).end);
    try std.testing.expectEqual(@as(usize, 2), S.number("1..2", 0).end);
    try std.testing.expectEqual(@as(?u8, 16), S.radixPrefix("0X1F", 0));
    try std.testing.expectEqual(@as(usize, 9), S.skip("-- x\n/**/a", 0).end);
}
