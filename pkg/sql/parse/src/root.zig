//! sqlparse: what the hand-written SQL parsers of the dialects share,
//! below the syntax tree they build (docs/sqlparse.md). It depends on
//! std and sql/lexer.
//!
//! A dialect's parser keeps its token kinds, its grammar, its
//! precedence and its error wording; what is the same in every one is
//! here:
//!
//! - token sources: `Buffered(Token)`, the tokens of a statement lexed
//!   beforehand (PostgreSQL, Oracle), and `Streaming(Lexer)`, a lexer
//!   read as the parser goes, lookahead by a copy of the lexer (MariaDB,
//!   SQL Server, where only the parser knows where a statement ends);
//! - `Cursor(Source, State, Hooks)`: the operations on the tokens of a
//!   source (peek, advance, keywords, operators, rewinding) and the
//!   error record (`Diag`): a parser holds one cursor and calls it;
//! - `words`: sets of words (reserved words, type names) built at
//!   compile time.
//!
//! What a dialect's token must have (checkToken()): `kind`, an enum with
//! `eof`; `start` and `end`, byte offsets in the statement text;
//! `isKw(comptime kw)`, whether it is the unquoted keyword `kw` as the
//! dialect compares keywords (folded or not), and `isOp(op)`. The eof
//! token repeats: advancing past it stays on it.

const std = @import("std");

pub const words = @import("words.zig");

pub const Error = error{ ParseFailed, OutOfMemory };

/// Fails to compile unless `T` is a token a cursor can read.
pub fn checkToken(comptime T: type) void {
    comptime {
        if (!@hasField(T, "kind") or !@hasField(T, "start") or !@hasField(T, "end"))
            @compileError(@typeName(T) ++ " needs the fields kind, start and end");
        const Kind = @FieldType(T, "kind");
        if (@typeInfo(Kind) != .@"enum" or !@hasField(Kind, "eof"))
            @compileError(@typeName(T) ++ ".kind needs to be an enum with eof");
        if (!@hasDecl(T, "isKw") or !@hasDecl(T, "isOp"))
            @compileError(@typeName(T) ++ " needs isKw() and isOp()");
    }
}

/// Fails to compile if `Hooks` has a public declaration that is no hook
/// (a misspelt optional hook would be ignored).
fn checkHooks(comptime Hooks: type) void {
    if (!@hasDecl(Hooks, "syntaxErrorAt")) @compileError(@typeName(Hooks) ++ " needs syntaxErrorAt()");
    for (@typeInfo(Hooks).@"struct".decl_names) |d| {
        for ([_][]const u8{ "syntaxErrorAt", "missingKeyword", "missingToken", "stateOfFormat" }) |name| {
            if (std.mem.eql(u8, d, name)) break;
        } else @compileError(@typeName(Hooks) ++ "." ++ d ++ " is not a hook");
    }
}

// ============================================================== sources

/// The tokens of a statement lexed beforehand, ending with an eof
/// token. A mark is an index.
pub fn Buffered(comptime T: type) type {
    checkToken(T);
    return struct {
        const B = @This();
        pub const Token = T;
        pub const Mark = usize;

        toks: []const T,
        i: usize = 0,

        pub fn init(toks: []const T) B {
            std.debug.assert(toks.len > 0 and toks[toks.len - 1].kind == .eof);
            return .{ .toks = toks };
        }

        pub inline fn peek(b: *const B) T {
            return b.toks[b.i];
        }

        pub inline fn peekAt(b: *const B, k: usize) T {
            return b.toks[@min(b.i + k, b.toks.len - 1)];
        }

        pub inline fn advance(b: *B) T {
            const t = b.toks[b.i];
            if (t.kind != .eof) b.i += 1;
            return t;
        }

        /// The token consumed last (the first token if none was).
        pub inline fn prev(b: *const B) T {
            return b.toks[b.i -| 1];
        }

        /// The end of the token consumed last (the start of the first if
        /// none was).
        pub inline fn lastEnd(b: *const B) u32 {
            return if (b.i == 0) b.toks[0].start else b.toks[b.i - 1].end;
        }

        pub inline fn mark(b: *const B) Mark {
            return b.i;
        }

        pub inline fn reset(b: *B, m: Mark) void {
            b.i = m;
        }
    };
}

/// A lexer read as the parser goes: `Lexer.next()` returns the next
/// token (a lexical error is a token of the dialect's), at the end eof
/// again. Lookahead lexes a copy of the lexer, a mark is a copy of the
/// state.
pub fn Streaming(comptime Lexer: type) type {
    const T = @typeInfo(@TypeOf(Lexer.next)).@"fn".return_type.?;
    checkToken(T);
    return struct {
        const S = @This();
        pub const Token = T;
        /// The whole state: the lexer, the next token and the end of the
        /// last one.
        pub const Mark = S;

        lx: Lexer,
        tok: T,
        /// The end of the token consumed last (0 before any was).
        prev_end: u32 = 0,

        /// The source reading `lx` from where it is.
        pub fn init(lx: Lexer) S {
            var l = lx;
            const t = l.next();
            return .{ .lx = l, .tok = t };
        }

        pub inline fn peek(s: *const S) T {
            return s.tok;
        }

        pub inline fn peekAt(s: *const S, k: usize) T {
            if (k == 0) return s.tok;
            var copy = s.lx;
            var t = copy.next();
            for (1..k) |_| t = copy.next();
            return t;
        }

        pub fn advance(s: *S) T {
            const t = s.tok;
            if (t.kind == .eof) return t;
            s.prev_end = t.end;
            s.tok = s.lx.next();
            return t;
        }

        pub inline fn lastEnd(s: *const S) u32 {
            return s.prev_end;
        }

        pub inline fn mark(s: *const S) Mark {
            return s.*;
        }

        pub inline fn reset(s: *S, m: Mark) void {
            s.* = m;
        }
    };
}

// =============================================================== errors

/// The error of a statement (the last one recorded: a parser returns
/// once it records one): its message (in the cursor's arena), the offset
/// it is at (null: no place in the text), and its state (`State`: the
/// engine's error state; null if the dialect gives none).
pub fn Diag(comptime State: type) type {
    return struct {
        msg: []const u8 = "",
        pos: ?usize = null,
        state: ?State = null,
        /// Whether an error was recorded.
        failed: bool = false,
    };
}

// =============================================================== cursor

/// A parser's view of its tokens: those of `Source` (Buffered or
/// Streaming) and the error of the statement.
///
/// `Hooks` is what is the dialect's:
///  - `pub fn syntaxErrorAt(c: anytype, t: Token) Error`: its syntax error
///    at token `t` (syntaxError() is at the next token: what expect*()
///    fail with), recorded with fail();
/// and optionally:
///  - `pub fn missingKeyword(c: anytype) Error`: expectKw()'s error
///    (else syntaxError());
///  - `pub fn missingToken(c: anytype, kind) Error`: expect()'s error
///    (else syntaxError());
///  - `pub fn stateOfFormat(comptime fmt) ?State`: the state of an error
///    fail() records, which the caller does not give (else
///    `State.ofFormat(fmt)` if State has it, else none).
pub fn Cursor(comptime Source: type, comptime State: type, comptime Hooks: type) type {
    comptime checkHooks(Hooks);
    return struct {
        const C = @This();
        pub const Token = Source.Token;
        pub const Kind = @FieldType(Token, "kind");
        pub const Mark = Source.Mark;

        arena: std.mem.Allocator,
        /// The text the offsets of tokens are in.
        sql: [:0]const u8,
        src: Source,
        diag: Diag(State) = .{},

        // -------------------------------------------------------- tokens

        pub inline fn peek(c: *const C) Token {
            return c.src.peek();
        }

        /// The token `k` after the next one (0: the next one).
        pub inline fn peekAt(c: *const C, k: usize) Token {
            return c.src.peekAt(k);
        }

        pub inline fn advance(c: *C) Token {
            return c.src.advance();
        }

        /// advance() of a token not needed.
        pub inline fn skip(c: *C) void {
            _ = c.src.advance();
        }

        /// advance() `n` times.
        pub fn skipN(c: *C, n: usize) void {
            for (0..n) |_| c.skip();
        }

        /// The token consumed last (Buffered only).
        pub inline fn prev(c: *const C) Token {
            return c.src.prev();
        }

        /// The offset of the next token.
        pub inline fn here(c: *const C) u32 {
            return c.peek().start;
        }

        /// The offset after the token consumed last.
        pub inline fn lastEnd(c: *const C) u32 {
            return c.src.lastEnd();
        }

        pub inline fn mark(c: *const C) Mark {
            return c.src.mark();
        }

        pub inline fn reset(c: *C, m: Mark) void {
            c.src.reset(m);
        }

        pub inline fn atEof(c: *const C) bool {
            return c.peek().kind == .eof;
        }

        pub inline fn is(c: *const C, kind: Kind) bool {
            return c.peek().kind == kind;
        }

        pub fn eat(c: *C, kind: Kind) bool {
            if (c.peek().kind != kind) return false;
            c.skip();
            return true;
        }

        pub fn expect(c: *C, kind: Kind) Error!Token {
            if (c.peek().kind != kind) {
                return if (@hasDecl(Hooks, "missingToken")) Hooks.missingToken(c, kind) else c.syntaxError();
            }
            return c.advance();
        }

        // ------------------------------------------------------ keywords

        pub inline fn isKw(c: *const C, comptime kw: []const u8) bool {
            return c.peek().isKw(kw);
        }

        pub inline fn isKwAt(c: *const C, k: usize, comptime kw: []const u8) bool {
            return c.peekAt(k).isKw(kw);
        }

        pub fn isAnyKw(c: *const C, comptime kws: []const []const u8) bool {
            const t = c.peek();
            inline for (kws) |kw| if (t.isKw(kw)) return true;
            return false;
        }

        pub inline fn eatKw(c: *C, comptime kw: []const u8) bool {
            if (!c.isKw(kw)) return false;
            c.skip();
            return true;
        }

        pub inline fn expectKw(c: *C, comptime kw: []const u8) Error!void {
            if (!c.eatKw(kw)) return c.missingKeyword();
        }

        /// Whether the next tokens are the keywords `kws`; if so they are
        /// consumed.
        pub fn eatKws(c: *C, comptime kws: []const []const u8) bool {
            inline for (kws, 0..) |kw, k| if (!c.isKwAt(k, kw)) return false;
            for (kws) |_| c.skip();
            return true;
        }

        /// The keywords `kws` in a row, optional: none of them (false), or
        /// all (true); the first without the rest is a syntax error.
        pub fn optKws(c: *C, comptime kws: []const []const u8) Error!bool {
            if (!c.eatKw(kws[0])) return false;
            inline for (kws[1..]) |kw| try c.expectKw(kw);
            return true;
        }

        /// An optional IF EXISTS.
        pub fn ifExists(c: *C) Error!bool {
            return c.optKws(&.{ "if", "exists" });
        }

        /// An optional IF NOT EXISTS.
        pub fn ifNotExists(c: *C) Error!bool {
            return c.optKws(&.{ "if", "not", "exists" });
        }

        /// The keyword error expectKw() fails with (Hooks.missingKeyword,
        /// else the syntax error).
        pub fn missingKeyword(c: *C) Error {
            return if (@hasDecl(Hooks, "missingKeyword")) Hooks.missingKeyword(c) else c.syntaxError();
        }

        // ----------------------------------------------------- operators

        pub inline fn isOp(c: *const C, op: []const u8) bool {
            return c.peek().isOp(op);
        }

        pub fn eatOp(c: *C, op: []const u8) bool {
            if (!c.isOp(op)) return false;
            c.skip();
            return true;
        }

        pub fn expectOp(c: *C, op: []const u8) Error!void {
            if (!c.eatOp(op)) return c.syntaxError();
        }

        /// A comma: the token kind `comma` if the dialect has one, else
        /// the operator `,`.
        pub fn eatComma(c: *C) bool {
            if (comptime @hasField(Kind, "comma")) return c.eat(.comma);
            return c.eatOp(",");
        }

        /// One or more of `item(ctx)` separated by commas, in the arena.
        pub fn list(c: *C, comptime T: type, ctx: anytype, comptime item: anytype) Error![]T {
            var out: std.ArrayList(T) = .empty;
            while (true) {
                try out.append(c.arena, try item(ctx));
                if (!c.eatComma()) break;
            }
            return out.items;
        }

        // -------------------------------------------------------- errors

        /// The error of `sub`, a cursor of text the dialect wrote, as this
        /// one's (at no place in this text); `err` again.
        pub fn failedIn(c: *C, sub: *const C, err: Error) Error {
            if (sub.diag.failed) {
                c.diag = sub.diag;
                c.diag.pos = null;
            }
            return err;
        }

        /// Record an error at `pos` (null: at no place), of the state its format means
        /// (State.ofFormat(), else none), and fail.
        pub fn fail(c: *C, pos: ?usize, comptime fmt: []const u8, args: anytype) Error {
            return c.failState(pos, null, fmt, args);
        }

        /// fail() of an error whose state is known (null: as fail()).
        pub fn failState(c: *C, pos: ?usize, state: ?State, comptime fmt: []const u8, args: anytype) Error {
            c.diag = .{
                .msg = try std.fmt.allocPrint(c.arena, fmt, args),
                .pos = pos,
                .state = state orelse comptime defaultState(fmt),
                .failed = true,
            };
            return error.ParseFailed;
        }

        fn defaultState(comptime fmt: []const u8) ?State {
            if (@hasDecl(Hooks, "stateOfFormat")) return Hooks.stateOfFormat(fmt);
            if (@hasDecl(State, "ofFormat")) return State.ofFormat(fmt);
            return null;
        }

        /// The dialect's syntax error at the next token.
        pub fn syntaxError(c: *C) Error {
            return Hooks.syntaxErrorAt(c, c.peek());
        }

        /// The dialect's syntax error at token `t`.
        pub fn syntaxErrorAt(c: *C, t: Token) Error {
            return Hooks.syntaxErrorAt(c, t);
        }
    };
}

// ================================================================ tests

const testing = std.testing;

/// A toy dialect: words, `(`, `)`, `,` and single-character operators;
/// keywords compare without case.
const Toy = struct {
    const Kind = enum { eof, word, lparen, rparen, comma, op };
    const Token = struct {
        kind: Kind,
        start: u32,
        end: u32,
        text: []const u8,

        pub fn isKw(t: Token, comptime kw: []const u8) bool {
            return t.kind == .word and std.ascii.eqlIgnoreCase(t.text, kw);
        }

        pub fn isOp(t: Token, op: []const u8) bool {
            return t.kind == .op and std.mem.eql(u8, t.text, op);
        }
    };

    const Lexer = struct {
        s: [:0]const u8,
        pos: u32 = 0,

        fn next(l: *Lexer) Token {
            while (l.s[l.pos] == ' ') l.pos += 1;
            const start = l.pos;
            const c = l.s[start];
            const kind: Kind = switch (c) {
                0 => return .{ .kind = .eof, .start = start, .end = start, .text = "" },
                '(' => .lparen,
                ')' => .rparen,
                ',' => .comma,
                'a'...'z', 'A'...'Z' => blk: {
                    while (std.ascii.isAlphabetic(l.s[l.pos])) l.pos += 1;
                    break :blk .word;
                },
                else => .op,
            };
            if (kind != .word) l.pos += 1;
            return .{ .kind = kind, .start = start, .end = l.pos, .text = l.s[start..l.pos] };
        }
    };

    const State = struct {
        code: u8,
        pub fn ofFormat(comptime fmt: []const u8) State {
            return .{ .code = if (std.mem.startsWith(u8, fmt, "syntax")) 1 else 2 };
        }
    };

    const Hooks = struct {
        pub fn syntaxErrorAt(c: anytype, t: Token) Error {
            if (t.kind == .eof) return c.fail(t.start, "syntax error at end", .{});
            return c.fail(t.start, "syntax error near {s}", .{t.text});
        }
    };

    fn lexAll(a: std.mem.Allocator, s: [:0]const u8) ![]Token {
        var l: Lexer = .{ .s = s };
        var out: std.ArrayList(Token) = .empty;
        while (true) {
            const t = l.next();
            try out.append(a, t);
            if (t.kind == .eof) return out.items;
        }
    }
};

fn exercise(c: anytype) !void {
    try testing.expect(c.isKw("SELECT") and c.isKwAt(1, "a") and c.isAnyKw(&.{ "x", "select" }));
    try c.expectKw("select");
    try testing.expectEqual(@as(u32, 6), c.lastEnd());
    try testing.expectEqual(@as(u32, 7), c.here());
    const m = c.mark();
    try testing.expectEqualStrings("a", c.advance().text);
    try testing.expect(c.eat(.comma));
    if (@hasDecl(@TypeOf(c.src), "prev")) try testing.expectEqualStrings(",", c.prev().text);
    c.reset(m);
    try testing.expectEqualStrings("a", c.peek().text);
    try testing.expectEqual(@as(u32, 6), c.lastEnd());
    try testing.expect(!(try c.ifExists()));
    c.skipN(2);
    try testing.expect(try c.ifNotExists());
    try testing.expect(c.eatOp("+") and !c.eatOp("+"));
    try testing.expectError(error.ParseFailed, c.expectOp("+"));
    try testing.expectEqualStrings("syntax error near -", c.diag.msg);
    try testing.expectEqual(@as(?u8, 1), if (c.diag.state) |s| s.code else null);
    try testing.expectEqual(@as(?usize, 26), c.diag.pos);
    try testing.expectEqual(error.ParseFailed, c.failState(3, .{ .code = 9 }, "{d} apples", .{3}));
    try testing.expectEqualStrings("3 apples", c.diag.msg);
    try testing.expectEqual(@as(u8, 9), c.diag.state.?.code);
    c.skip();
    try testing.expectError(error.ParseFailed, c.expect(.word));
    try testing.expectEqualStrings("syntax error at end", c.diag.msg);
    // eof repeats.
    try testing.expect(c.atEof());
    c.skip();
    try testing.expect(c.atEof() and c.peekAt(3).kind == .eof);
    // The first keyword of a sequence without the rest.
    c.reset(m);
    c.skip();
    c.skip();
    try testing.expectError(error.ParseFailed, c.optKws(&.{ "if", "exists" }));
    c.reset(m);
    c.skip();
    c.skip();
    try testing.expect(!c.eatKws(&.{ "if", "exists" }));
    try testing.expectEqualStrings("if", c.peek().text);
    try testing.expect(c.eatKws(&.{ "if", "not" }));
    try testing.expect(c.isKw("exists"));
}

test "lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const C = Cursor(Streaming(Toy.Lexer), Toy.State, Toy.Hooks);
    const sql = "a, b , c d";
    var c: C = .{ .arena = arena.allocator(), .sql = sql, .src = .init(.{ .s = sql }) };
    const word = struct {
        fn f(x: *C) Error![]const u8 {
            return (try x.expect(.word)).text;
        }
    }.f;
    const l = try c.list([]const u8, &c, word);
    try testing.expectEqual(@as(usize, 3), l.len);
    try testing.expectEqualStrings("c", l[2]);
    try testing.expect(c.isKw("d"));
}

test "hooks for missing tokens" {
    const H = struct {
        pub fn syntaxErrorAt(c: anytype, t: Toy.Token) Error {
            return c.fail(t.start, "syntax", .{});
        }
        pub fn missingKeyword(c: anytype) Error {
            return c.fail(c.here(), "missing keyword", .{});
        }
        pub fn missingToken(c: anytype, kind: Toy.Kind) Error {
            return c.fail(c.here(), "missing {t}", .{kind});
        }
        pub fn stateOfFormat(comptime fmt: []const u8) ?Toy.State {
            return .{ .code = fmt.len };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: Cursor(Streaming(Toy.Lexer), Toy.State, H) = .{ .arena = arena.allocator(), .sql = text, .src = .init(.{ .s = text }) };
    try testing.expectError(error.ParseFailed, c.expectKw("from"));
    try testing.expectEqualStrings("missing keyword", c.diag.msg);
    try testing.expectEqual(@as(u8, 15), c.diag.state.?.code);
    try testing.expectError(error.ParseFailed, c.expect(.lparen));
    try testing.expectEqualStrings("missing lparen", c.diag.msg);
    try testing.expectError(error.ParseFailed, c.expectOp("("));
    try testing.expectEqualStrings("syntax", c.diag.msg);
}

const text = "select a, if not exists + -";

test "buffered cursor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const toks = try Toy.lexAll(arena.allocator(), text);
    var c: Cursor(Buffered(Toy.Token), Toy.State, Toy.Hooks) = .{
        .arena = arena.allocator(),
        .sql = text,
        .src = .init(toks),
    };
    try exercise(&c);
}

test "streaming cursor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: Cursor(Streaming(Toy.Lexer), Toy.State, Toy.Hooks) = .{
        .arena = arena.allocator(),
        .sql = text,
        .src = .init(.{ .s = text }),
    };
    try exercise(&c);
    // Lookahead does not move the lexer.
    c.reset(c.mark());
    var d: Cursor(Streaming(Toy.Lexer), Toy.State, Toy.Hooks) = .{ .arena = arena.allocator(), .sql = text, .src = .init(.{ .s = text }) };
    try testing.expectEqualStrings("if", d.peekAt(3).text);
    try testing.expectEqualStrings("select", d.peek().text);
}

test {
    _ = words;
}
