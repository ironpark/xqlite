//! The token every dialect's lexer makes (Lexer() of lexer.zig): what
//! kind of SQL token it is, a detail of that kind, the keyword it is, and
//! where it is in the text. It holds no text: the text is
//! `sql[t.start..t.end]`, and its value (a name folded, a string
//! unquoted) is decoded on demand (value.zig, and the dialect's escapes).

const std = @import("std");

pub const Kind = enum(u8) {
    /// The end of the text. It repeats: reading past it reads it again.
    eof,
    /// An unquoted word: a keyword or a name (`kw` says which keyword).
    word,
    /// A delimited identifier: "x", `x`, [x], U&"x".
    quoted_ident,
    /// A string constant, `sub` its form: '...', N'...', E'...', X'...'.
    string,
    integer,
    /// A number with a fraction or an exponent (or an Oracle f/d suffix).
    float,
    /// A bind parameter, `sub` its form: ?, ?1, $1, :name.
    param,
    /// A session variable: @x (`user`), @@x (`system`).
    variable,
    /// An operator or punctuation but the five below.
    op,
    lparen,
    rparen,
    comma,
    semi,
    dot,
    /// The end of a statement that is not `;`: SQL Server's GO line,
    /// Oracle's `/` line.
    terminator,
    /// Text that is no token, `sub` says why; its error is the dialect's.
    illegal,
};

/// The detail of a token's kind.
pub const Sub = enum(u8) {
    none,

    // string: the form (`none` for '...', or "..." when it is a string)
    national,
    /// E'...': backslash escapes.
    escape,
    /// U&'...' (and U&"..." of quoted_ident): Unicode escapes, maybe with
    /// a UESCAPE clause, which the token includes.
    unicode,
    /// $tag$...$tag$.
    dollar,
    /// Oracle's q'[...]' (and nq'[...]').
    alt_quote,
    /// X'0A1B'.
    blob,
    /// B'0101'.
    bits,

    // integer: the radix (`none` for decimal)
    hex,
    octal,
    binary,

    // param
    /// `?`
    positional,
    /// ?1, $1
    numbered,
    /// :name, @name, $name
    named,

    // variable
    /// @x
    user,
    /// @@x
    system,

    // illegal
    /// A character that starts no token.
    bad_char,
    /// A quoted token or a block comment not closed: the token runs to
    /// the end of the text, and its first character says what it is.
    unterminated,
    /// A delimited identifier with no characters.
    empty,
    /// A number or a parameter run into a word (PostgreSQL's 123abc).
    trailing_junk,
    /// A radix prefix with no digits (PostgreSQL's 0x).
    bad_radix,
    /// U&'...' where it is not allowed (PostgreSQL with
    /// standard_conforming_strings off).
    unicode_off,
    /// UESCAPE not followed by a simple string: the token is the one
    /// that follows.
    uescape_follow,
};

/// A token of a dialect whose keywords are `K` (a Keywords() table, or
/// void for none): the same fields for every dialect, and keyword tests
/// that resolve keywords to numbers at compile time.
pub fn TokenOf(comptime K: type) type {
    return struct {
        const T = @This();
        pub const Keywords = K;

        kind: Kind,
        sub: Sub = .none,
        /// The keyword of a `word` (its number in `K`, 1 up), 0 if none.
        kw: u16 = 0,
        /// Its byte offsets in the text.
        start: u32,
        end: u32,

        /// Its text in `sql`.
        pub inline fn text(t: T, sql: []const u8) []const u8 {
            return sql[t.start..t.end];
        }

        pub inline fn is(t: T, kind: Kind) bool {
            return t.kind == kind;
        }

        /// Whether it is the keyword `kw` (any case; one of `K`, else
        /// this does not compile).
        pub inline fn isKw(t: T, comptime kw: []const u8) bool {
            return t.kw == comptime kwId(kw);
        }

        /// Whether it is a keyword of the class `reserved` (no name
        /// unquoted).
        pub inline fn isReserved(t: T) bool {
            return K.class(t.kw) == .reserved;
        }

        /// isKw() of the keyword `kw` known at run time (any word).
        pub fn isKwText(t: T, kw: []const u8) bool {
            return t.kw != 0 and t.kw == K.lookup(kw);
        }

        pub fn isAnyKw(t: T, comptime kws: []const []const u8) bool {
            inline for (kws) |kw| if (t.isKw(kw)) return true;
            return false;
        }

        /// Whether it is the operator `op` (any punctuation of its own
        /// kind too: `(`, `)`, `,`, `;`, `.`).
        pub fn isOp(t: T, sql: []const u8, op: []const u8) bool {
            return switch (t.kind) {
                .op => std.mem.eql(u8, t.text(sql), op),
                .lparen, .rparen, .comma, .semi, .dot => op.len == 1 and sql[t.start] == op[0],
                else => false,
            };
        }

        /// The number of keyword `kw` of `K`.
        pub fn kwId(comptime kw: []const u8) u16 {
            comptime {
                @setEvalBranchQuota(100_000);
                if (K == void) @compileError("no keywords");
                const id = K.lookup(kw);
                if (id == 0) @compileError("not a keyword of the dialect: " ++ kw);
                return id;
            }
        }
    };
}

/// A token of a dialect with no keyword table.
pub const Token = TokenOf(void);

comptime {
    std.debug.assert(@sizeOf(Token) == 12);
}
