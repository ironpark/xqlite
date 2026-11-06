//! Lexer(D): a dialect's lexer, made from its lexical rules (`D.spec`,
//! a Spec with the parts below), its keywords (`D.keywords`) and hooks
//! for what no rule says.
//!
//! The lexer never fails: what is no token is an `illegal` token, its
//! `sub` saying why, and its error is the dialect's to word. It decodes
//! nothing (value.zig and the dialect do, on demand).
//!
//! A token is read in this order:
//!  1. white space and comments (Spec.comments; the hook `skip`);
//!  2. the hook `scan`, which may read a token of its own;
//!  3. ( ) , ; and `.` (a number if a digit follows);
//!  4. the statement-ending line (Spec.slash_line);
//!  5. quotes (Spec.quotes), parameters and variables (Spec.params,
//!     Spec.variables), dollar quotes, numbers;
//!  6. a prefixed string (Spec.prefixes), else a word (and its keyword;
//!     the hook `word`);
//!  7. operators (Spec.ops), else an illegal character.
//!
//! Hooks (`D`'s optional functions, `l` the lexer):
//!  - `skip(l) ?Token`: skip white space and comments instead of
//!    Spec.comments, an `illegal` token if a comment is not closed;
//!  - `scan(l, start) ?Token`: a token at `start` that the rules do not
//!    read (PostgreSQL's U&'...'), null to go on with them;
//!  - `word(l, t) Token`: a word read, or another token in its place
//!    (SQL Server's GO line);
//!  - `number(l, t) Token`: a number read, or what it stands for.
//! and `State`, a type for the hooks' state (`l.state`).

const std = @import("std");
const root = @import("root.zig");
const tok = @import("token.zig");

const Set = root.Set;
const Kind = tok.Kind;
const Sub = tok.Sub;

/// What a session changes in how text is lexed.
pub const Options = struct {
    /// A backslash escapes in the quotes that allow it (Quote.escapes,
    /// Prefix.escapes): MySQL unless NO_BACKSLASH_ESCAPES, PostgreSQL
    /// with standard_conforming_strings off.
    backslash_escapes: bool = false,
    /// "x" is an identifier (Quote.when): MySQL's ANSI_QUOTES.
    ansi_quotes: bool = false,
};

/// A quote character and what it delimits.
pub const Quote = struct {
    open: u8,
    close: u8,
    kind: Kind,
    /// Whether it applies.
    when: When = .always,
    /// A backslash escapes the next character when Options.
    /// backslash_escapes says so.
    escapes: bool = false,
    /// A doubled `close` stands for one (else the first `close` ends it:
    /// SQLite's [x]).
    doubled: bool = true,

    pub const When = enum { always, ansi_quotes, not_ansi_quotes };
};

/// Letters (any case) before a quote that make a string of a form.
pub const Prefix = struct {
    letters: []const u8,
    sub: Sub,
    escapes: Escapes = .options,
    /// What follows the letters.
    body: Body = .quoted,

    pub const Escapes = enum { never, always, options };
    pub const Body = enum {
        /// '...', as a string of Spec.quotes.
        quoted,
        /// Oracle's q'c...c' (c one of [ { ( < or any other character,
        /// closed by ] } ) > or itself).
        alt,
    };
};

/// What follows a number that is no part of it.
pub const Tail = enum {
    /// Nothing: the next token starts there.
    none,
    /// A letter: the number and the word are an `illegal`
    /// trailing_junk (PostgreSQL).
    junk,
    /// A character of a word after an integer: the whole is a word
    /// (MySQL's 1abc, 0x1g).
    word,
    /// Characters of a word: the number and they are an `illegal`
    /// bad_char (SQLite).
    illegal,
};

/// A radix prefix (0x) with no digit after it.
pub const RadixEmpty = enum {
    /// An integer with no digits (SQL Server's 0x).
    token,
    /// An `illegal` bad_radix (PostgreSQL).
    illegal,
    /// Not a radix prefix: `0` is read as a decimal number (MySQL,
    /// SQLite).
    decimal,
};

pub const Params = struct {
    /// `?`
    question: enum { none, positional, numbered } = .none,
    /// $1
    dollar_number: bool = false,
    /// :name, :1, :"name"
    colon: bool = false,
};

pub const Ops = struct {
    /// Operators of more than one character, a longer one before one
    /// that starts it (longestOp()).
    list: []const []const u8 = &.{},
    /// PostgreSQL's operators: any run of these characters, cut before a
    /// comment and without a trailing + or - unless the run has one of
    /// ~ ! @ # % ^ & | ` ? (scan.l).
    run: ?Set = null,
    /// Operators of one character.
    singles: Set = .of(.{}),
};

/// The lexer of the dialect `D`.
pub fn Lexer(comptime D: type) type {
    comptime checkDialect(D);
    return struct {
        const L = @This();
        pub const spec: root.Spec = D.spec;
        pub const scan = root.Scanner(spec);
        pub const State = if (@hasDecl(D, "State")) D.State else struct {};
        pub const Keywords = if (@hasDecl(D, "keywords")) D.keywords else void;
        pub const Token = tok.TokenOf(Keywords);

        sql: [:0]const u8,
        pos: usize,
        opts: Options = .{},
        state: State = .{},

        pub fn init(sql: [:0]const u8, pos: usize, opts: Options) L {
            return .{ .sql = sql, .pos = pos, .opts = opts };
        }

        pub fn token(l: *const L, kind: Kind, sub: Sub, start: usize, end: usize) Token {
            _ = l;
            return .{ .kind = kind, .sub = sub, .start = @intCast(start), .end = @intCast(end) };
        }

        /// A token from `start` to `end`, the lexer after it.
        pub fn take(l: *L, kind: Kind, sub: Sub, start: usize, end: usize) Token {
            l.pos = end;
            return l.token(kind, sub, start, end);
        }

        /// Skip white space and comments (an `illegal` token if a comment
        /// is not closed and Spec.comments says so).
        pub fn skip(l: *L) ?Token {
            if (@hasDecl(D, "skip")) return D.skip(l);
            const t = scan.skip(l.sql, l.pos);
            if (t.open_comment) |at| if (spec.comments.unclosed == .illegal)
                return l.take(.illegal, .unterminated, at, t.end);
            l.pos = t.end;
            return null;
        }

        pub fn next(l: *L) Token {
            if (l.skip()) |t| return t;
            const s = l.sql;
            const start = l.pos;
            const c = s[start];
            if (c == 0) return l.token(.eof, .none, start, start);
            if (@hasDecl(D, "scan")) if (D.scan(l, start)) |t| return t;
            switch (c) {
                '(' => return l.take(.lparen, .none, start, start + 1),
                ')' => return l.take(.rparen, .none, start, start + 1),
                ',' => return l.take(.comma, .none, start, start + 1),
                ';' => return l.take(.semi, .none, start, start + 1),
                '.' => return if (scan.isDigit(s[start + 1])) l.number(start) else l.take(.dot, .none, start, start + 1),
                '/' => if (spec.slash_line and root.blankBefore(s, start) and root.blankAfter(s, start + 1))
                    return l.take(.terminator, .none, start, start + 1),
                '0'...'9' => return l.number(start),
                '?' => switch (spec.params.question) {
                    .none => {},
                    .positional => return l.take(.param, .positional, start, start + 1),
                    .numbered => {
                        const e = root.digits.span(s, start + 1);
                        return l.take(.param, if (e > start + 1) .numbered else .positional, start, e);
                    },
                },
                ':' => if (spec.params.colon) {
                    const n = s[start + 1];
                    if (scan.isDigit(n) or scan.isIdentStart(n)) return l.take(.param, .named, start, scan.word(s, start + 1));
                    if (n == '"') {
                        const q = l.quoted(start + 1, comptime quoteOf('"'));
                        if (q.kind == .illegal) return l.take(.illegal, q.sub, start, q.end);
                        return l.take(.param, .named, start, q.end);
                    }
                },
                '@' => if (spec.variables) {
                    const sys = s[start + 1] == '@';
                    const first = start + 1 + @intFromBool(sys);
                    const e = scan.word(s, first);
                    if (e == first) return l.take(.illegal, .bad_char, start, e);
                    return l.take(.variable, if (sys) .system else .user, start, e);
                },
                '$' => if (spec.params.dollar_number or spec.dollar_quotes) {
                    if (spec.params.dollar_number and scan.isDigit(s[start + 1])) {
                        const e = root.digits.span(s, start + 1);
                        if (spec.numbers.tail == .junk and scan.isIdent(s[e])) return l.take(.illegal, .trailing_junk, start, e + 1);
                        return l.take(.param, .numbered, start, e);
                    }
                    if (spec.dollar_quotes) if (scan.dollarTag(s, start)) |body| {
                        const d = root.dollarEnd(s, start, body);
                        if (!d.closed) return l.take(.illegal, .unterminated, start, d.end);
                        return l.take(.string, .dollar, start, d.end);
                    };
                    return l.take(.illegal, .bad_char, start, start + 1);
                },
                else => {},
            }
            inline for (spec.quotes) |q| {
                if (c == q.open and l.quoteApplies(q)) return l.quoted(start, q);
            }
            if (scan.isIdentStart(c)) {
                inline for (spec.prefixes) |p| {
                    if (prefixAt(s, start, p.letters)) return l.prefixed(start, p);
                }
                var t = l.take(.word, .none, start, scan.word(s, start));
                if (@hasDecl(D, "keywords")) t.kw = D.keywords.lookup(t.text(s));
                if (@hasDecl(D, "word")) return D.word(l, t);
                return t;
            }
            return l.operator(start);
        }

        fn quoteApplies(l: *const L, comptime q: Quote) bool {
            return switch (q.when) {
                .always => true,
                .ansi_quotes => l.opts.ansi_quotes,
                .not_ansi_quotes => !l.opts.ansi_quotes,
            };
        }

        fn quoteOf(comptime open: u8) Quote {
            for (spec.quotes) |q| if (q.open == open) return q;
            @compileError("no such quote in the spec");
        }

        /// The quoted token whose quote `q` opens at `open`, the token
        /// starting at `start` (before a prefix).
        pub fn quotedFrom(l: *L, start: usize, open: usize, comptime q: Quote, escapes: bool, sub: Sub) Token {
            const s = l.sql;
            const r = if (!q.doubled) closeAt(s, open, q.close) else root.quotedEnd(s, open, q.close, escapes);
            if (!r.closed) return l.take(.illegal, .unterminated, start, r.end);
            var end = r.end;
            if (q.kind == .string and spec.string_continuation) {
                const c = continued(s, end, escapes);
                if (!c.closed) return l.take(.illegal, .unterminated, start, c.end);
                end = c.end;
            }
            if (q.kind == .quoted_ident and spec.empty_ident_illegal and end == open + 2) return l.take(.illegal, .empty, start, end);
            return l.take(q.kind, sub, start, end);
        }

        fn quoted(l: *L, start: usize, comptime q: Quote) Token {
            return l.quotedFrom(start, start, q, q.escapes and l.opts.backslash_escapes, .none);
        }

        /// After a string closed at `end`: more strings that follow after
        /// white space with a newline in it are part of it (PostgreSQL,
        /// the SQL standard). Where the last ends, or the one not closed.
        fn continued(s: [:0]const u8, end_arg: usize, escapes: bool) root.Extent {
            var end = end_arg;
            while (true) {
                var j = end;
                var newline = false;
                while (root.space.has(s[j])) : (j += 1) {
                    if (s[j] == '\n' or s[j] == '\r') newline = true;
                }
                if (!newline or s[j] != '\'') return .{ .end = end, .closed = true };
                const r = root.quotedEnd(s, j, '\'', escapes);
                if (!r.closed) return r;
                end = r.end;
            }
        }

        fn prefixed(l: *L, start: usize, comptime p: Prefix) Token {
            const open = start + p.letters.len;
            switch (p.body) {
                .quoted => {
                    const q = comptime quoteOf('\'');
                    const escapes = switch (p.escapes) {
                        .never => false,
                        .always => true,
                        .options => l.opts.backslash_escapes,
                    };
                    return l.quotedFrom(start, open, q, escapes, p.sub);
                },
                .alt => {
                    const s = l.sql;
                    const d = s[open + 1];
                    if (d == 0 or root.space.has(d)) return l.take(.illegal, .unterminated, start, s.len);
                    const close: u8 = switch (d) {
                        '[' => ']',
                        '{' => '}',
                        '(' => ')',
                        '<' => '>',
                        else => d,
                    };
                    var i = open + 2;
                    while (true) : (i += 1) {
                        if (s[i] == 0) return l.take(.illegal, .unterminated, start, i);
                        if (s[i] == close and s[i + 1] == '\'') break;
                    }
                    return l.take(.string, p.sub, start, i + 2);
                },
            }
        }

        /// A number at `start`, a digit or a `.` before one.
        pub fn number(l: *L, start: usize) Token {
            const t = l.numberRaw(start);
            if (@hasDecl(D, "number") and (t.kind == .integer or t.kind == .float)) return D.number(l, t);
            return t;
        }

        fn numberRaw(l: *L, start: usize) Token {
            const s = l.sql;
            const n = spec.numbers;
            if (scan.radixPrefix(s, start)) |base| radix: {
                const sub: Sub = switch (base) {
                    16 => .hex,
                    8 => .octal,
                    else => .binary,
                };
                if (n.radix_empty == .decimal and root.digitValue(s[start + 2]) >= base) break :radix;
                const r = root.radixDigits(s, start + 2, base, n.underscores);
                var e = r.end;
                switch (n.tail) {
                    .none => {},
                    .word => if (scan.isIdent(s[e])) return l.wordFrom(start),
                    .illegal => if (scan.isIdent(s[e])) return l.take(.illegal, .bad_char, start, scan.word(s, e)),
                    .junk => {
                        // PostgreSQL: a word right after the digits is
                        // junk, but for 0x_ alone (an invalid integer).
                        const j = scan.word(s, start + 1);
                        if (j > e and !(r.count == 0 and j == e + 1 and s[e] == '_')) return l.take(.illegal, .trailing_junk, start, j);
                    },
                }
                if (r.count == 0) switch (n.radix_empty) {
                    .token, .decimal => {},
                    .illegal => {
                        if (s[e] == '_') e += 1;
                        return l.take(.illegal, .bad_radix, start, e);
                    },
                };
                return l.take(.integer, sub, start, e);
            }
            const num = scan.number(s, start);
            var e = num.end;
            var float = num.float;
            if (n.float_suffix.len > 0 and std.mem.indexOfScalar(u8, n.float_suffix, s[e]) != null and !scan.isIdent(s[e + 1])) {
                e += 1;
                float = true;
            }
            switch (n.tail) {
                .none => {},
                .junk => if (scan.isIdentStart(s[e])) return l.take(.illegal, .trailing_junk, start, scan.word(s, e)),
                .word => if (!float and scan.isIdent(s[e])) return l.wordFrom(start),
                .illegal => if (scan.isIdent(s[e])) return l.take(.illegal, .bad_char, start, scan.word(s, e)),
            }
            return l.take(if (float) .float else .integer, .none, start, e);
        }

        /// A word from `start`, which may start with digits (MySQL).
        fn wordFrom(l: *L, start: usize) Token {
            var t = l.take(.word, .none, start, scan.word(l.sql, start));
            if (@hasDecl(D, "keywords")) t.kw = D.keywords.lookup(t.text(l.sql));
            return t;
        }

        fn operator(l: *L, start: usize) Token {
            const s = l.sql;
            const ops = spec.ops;
            const n = root.longestOp(ops.list, s, start);
            if (n > 0) return l.take(.op, .none, start, start + n);
            if (ops.run) |run| if (run.has(s[start])) {
                var e = start;
                while (run.has(s[e])) : (e += 1) {
                    // A comment starts inside the run: the operator ends there.
                    if (e > start and scan.commentAt(s, e)) break;
                }
                var len = e - start;
                if (len > 1 and (s[start + len - 1] == '+' or s[start + len - 1] == '-')) {
                    const special: Set = comptime .of(.{ .chars = "~!@#%^&|`?" });
                    for (s[start .. start + len]) |ch| {
                        if (special.has(ch)) break;
                    } else while (len > 1 and (s[start + len - 1] == '+' or s[start + len - 1] == '-')) len -= 1;
                }
                return l.take(.op, .none, start, start + len);
            };
            if (ops.singles.has(s[start])) return l.take(.op, .none, start, start + 1);
            return l.take(.illegal, .bad_char, start, start + 1);
        }
    };
}

/// Whether the letters of `letters` (any case; other characters as they
/// are) and then a `'` are at `i`.
inline fn prefixAt(s: [:0]const u8, i: usize, comptime letters: []const u8) bool {
    inline for (letters, 0..) |c, k| {
        if (std.ascii.toLower(s[i + k]) != std.ascii.toLower(c)) return false;
    }
    return s[i + letters.len] == '\'';
}

/// A quoted token closed by the first `close` (no doubling).
fn closeAt(s: [:0]const u8, open: usize, close: u8) root.Extent {
    const e = root.indexOfAnyOrNul(1, s, open + 1, .{close});
    if (s[e] == 0) return .{ .end = e, .closed = false };
    return .{ .end = e + 1, .closed = true };
}

const allowed_decls = [_][]const u8{ "spec", "keywords", "State", "skip", "scan", "word", "number" };

fn checkDialect(comptime D: type) void {
    if (!@hasDecl(D, "spec")) @compileError(@typeName(D) ++ " has no spec");
    for (@typeInfo(D).@"struct".decl_names) |name| {
        for (allowed_decls) |a| {
            if (std.mem.eql(u8, name, a)) break;
        } else @compileError(@typeName(D) ++ " declares " ++ name ++ ", which is no part of a lexer (" ++
            "spec, keywords, State, skip, scan, word, number)");
    }
}
