//! A precedence parser for SQL expressions (Pratt's top-down operator
//! precedence): where the operators stand and how tightly they bind is a
//! table, what they mean is the dialect's.
//!
//! The table (`Op(Tag)` entries) says, for each operator, what it looks
//! like (a keyword, an operator or a token kind, maybe followed by more
//! tokens, maybe not before some token), whether it is prefix, infix or
//! postfix, and its binding powers. `Pratt(...).expr(p, min)` reads an
//! operand (a prefix operator of the table, else `p.operand()`), then as
//! long as an infix or postfix operator binding at least `min` follows,
//! consumes its tokens and calls the dialect:
//!
//!  - `p.prefix(tag, m, rbp) !Expr`: a prefix operator whose tokens are
//!    `m` (Matched), the operand to read with `expr(p, rbp)`;
//!  - `p.infix(tag, lhs, m, rbp) !Expr`: an infix operator, its right
//!    side to read with `expr(p, rbp)` — or any other way: BETWEEN reads
//!    `x AND y`, IN a parenthesized list, IS whatever follows;
//!  - `p.postfix(tag, lhs, m) !Expr`: a postfix operator (ISNULL,
//!    COLLATE x, ::type, [i]);
//!  - optionally `p.unmatched(lhs, min, last) !void` when the loop ends at
//!    a token that is no operator of the table (PostgreSQL's "operator
//!    does not exist" for an operator of its open set): `last` is the
//!    left binding power of the operator that made `lhs`, null for an
//!    operand.
//!
//! So the precedence chain of a recursive descent parser (orExpr →
//! andExpr → ... → unary) becomes one table and one switch on a tag.
//!
//! Binding powers: an infix operator of left power `l` binds when
//! `l >= min`; its right side is read with `min = r`. Left-associative:
//! r = l + 1; right-associative: r = l. A non-associative one (a < b < c)
//! is left-associative with a `cap` below its own power.
//!
//! What the grammars of SQL have besides precedence:
//!
//!  - A prefix operator only at some levels (`level`): NOT starts a
//!    condition, so `1 + NOT x` is no expression. A prefix operator is
//!    one only where `min <= level`; elsewhere its tokens are an operand.
//!  - Forms after which no tighter operator applies (`cap`): after
//!    `x IS NULL`, `x IN (...)`, `x LIKE y ESCAPE z`, a `+` cannot follow
//!    (`x IS NULL + 1` is an error, not `(x IS NULL) + 1`). After an
//!    operator of cap `c` (or one whose callback called `p.pratt.cap(c)`), only
//!    operators of left power `<= c` continue the expression, in this
//!    loop and in the loops of the operators it is the right side of
//!    (but not past a token read after it: a cap inside parentheses ends
//!    there).
//!  - Operators of several tokens (`seq`: NOT LIKE, IS NOT DISTINCT FROM,
//!    AT TIME ZONE, Oracle's (+)) and operators not before some token
//!    (`unless`: MySQL's BINARY x but not BINARY(x)).

const std = @import("std");

pub const Fix = enum { prefix, infix, postfix };

/// One token of an operator: a keyword, an operator's text
/// (Cursor.isOpTok(), punctuation too) or a token kind (by name).
pub const Tok = struct {
    kw: ?[]const u8 = null,
    op: ?[]const u8 = null,
    kind: ?[]const u8 = null,
};

/// What an operator looks like, for the constructors below: its first
/// token (`kw`, `op` or `kind`), the tokens that follow (`seq`, or `then`
/// for one keyword), a token that must not follow them (`unless`), and
/// the cap after it.
pub const Match = struct {
    kw: ?[]const u8 = null,
    op: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    then: ?[]const u8 = null,
    seq: []const Tok = &.{},
    unless: ?Tok = null,
    cap: ?u8 = null,
};

/// An operator of the table.
pub fn Op(comptime Tag: type) type {
    return struct {
        tag: Tag,
        fix: Fix,
        /// Its tokens: the first, then `seq`, all consumed; not before
        /// `unless`.
        first: Tok,
        seq: []const Tok = &.{},
        unless: ?Tok = null,
        /// Left binding power (infix, postfix).
        lbp: u8 = 0,
        /// Right binding power (prefix, infix).
        rbp: u8 = 0,
        /// A prefix operator: the highest `min` it is one at.
        level: u8 = 255,
        /// After it, only operators of left power <= cap continue.
        cap: ?u8 = null,
    };
}

/// A left-associative infix operator of power `bp`.
pub fn left(comptime Tag: type, comptime tag: Tag, comptime bp: u8, comptime m: Match) Op(Tag) {
    return with(Tag, .{ .tag = tag, .fix = .infix, .first = undefined, .lbp = bp, .rbp = bp + 1 }, m);
}

/// A right-associative infix operator of power `bp`.
pub fn right(comptime Tag: type, comptime tag: Tag, comptime bp: u8, comptime m: Match) Op(Tag) {
    return with(Tag, .{ .tag = tag, .fix = .infix, .first = undefined, .lbp = bp, .rbp = bp }, m);
}

/// A prefix operator whose operand binds at least `bp`, an operator
/// wherever an operand may start.
pub fn prefix(comptime Tag: type, comptime tag: Tag, comptime bp: u8, comptime m: Match) Op(Tag) {
    return with(Tag, .{ .tag = tag, .fix = .prefix, .first = undefined, .rbp = bp }, m);
}

/// A prefix operator whose operand binds at least `bp`, an operator
/// only where `min <= level` (NOT where a condition may start).
pub fn prefixAt(comptime Tag: type, comptime tag: Tag, comptime level: u8, comptime bp: u8, comptime m: Match) Op(Tag) {
    return with(Tag, .{ .tag = tag, .fix = .prefix, .first = undefined, .rbp = bp, .level = level }, m);
}

/// A postfix operator of power `bp`.
pub fn postfix(comptime Tag: type, comptime tag: Tag, comptime bp: u8, comptime m: Match) Op(Tag) {
    return with(Tag, .{ .tag = tag, .fix = .postfix, .first = undefined, .lbp = bp }, m);
}

fn with(comptime Tag: type, comptime base: Op(Tag), comptime m: Match) Op(Tag) {
    var o = base;
    o.first = .{ .kw = m.kw, .op = m.op, .kind = m.kind };
    o.seq = if (m.then) |t| &[_]Tok{.{ .kw = t }} ++ m.seq else m.seq;
    o.unless = m.unless;
    o.cap = m.cap;
    return o;
}

fn checkTok(comptime t: Tok, comptime what: []const u8) void {
    const n = @as(u2, @intFromBool(t.kw != null)) + @intFromBool(t.op != null) + @intFromBool(t.kind != null);
    if (n != 1) @compileError("a token of an operator is one of kw, op, kind: " ++ what);
}

/// What the engine keeps while it reads: a field `pratt` of the dialect
/// parser (so that no state is global).
pub const State = struct {
    /// The cap a callback set for the operator it is reading (cap()).
    callback_cap: ?u8 = null,
    /// Where the last expr() ended, and the cap it ended under.
    exit_end: u32 = 0,
    exit_cap: u8 = 255,

    /// From a callback: after the operator it reads only operators of
    /// left power <= `c` continue the expression (LIKE with ESCAPE).
    pub fn cap(st: *State, c: u8) void {
        st.callback_cap = @min(st.callback_cap orelse 255, c);
    }
};

/// The precedence parser of the dialect parser `P` (with a cursor `c`, a
/// `pratt: State`, the callbacks above and `operand()`), building `Expr`, with the
/// operators `table`. Among operators that match, the first in the table
/// wins (put NOT BETWEEN before NOT).
pub fn Pratt(comptime P: type, comptime Expr: type, comptime Tag: type, comptime table: []const Op(Tag)) type {
    comptime for (table) |o| {
        checkTok(o.first, @tagName(o.tag));
        for (o.seq) |t| checkTok(t, @tagName(o.tag));
        if (o.unless) |t| checkTok(t, @tagName(o.tag));
        if (o.fix != .prefix and o.lbp == 0) @compileError("an infix or postfix operator binds: " ++ @tagName(o.tag));
    };
    return struct {
        pub const Error = @typeInfo(@typeInfo(@TypeOf(P.operand)).@"fn".return_type.?).error_union.error_set;
        const Cursor = @FieldType(P, "c");
        pub const Token = Cursor.Token;

        /// The tokens an operator was read from, and the `min` of the
        /// loop that read it.
        pub const Matched = struct {
            first: Token,
            last: Token,
            min: u8,
        };

        /// An expression whose operators bind at least `min` (0: any).
        pub fn expr(p: *P, min: u8) Error!Expr {
            var ceiling: u8 = 255;
            var last: ?u8 = null;
            var lhs: Expr = blk: {
                if (matchOp(p, .prefix, min)) |o| {
                    const m = take(p, o, min);
                    p.pratt.callback_cap = null;
                    const e = try p.prefix(o.tag, m, o.rbp);
                    ceiling = after(p, o);
                    last = o.rbp;
                    break :blk e;
                }
                break :blk try p.operand();
            };
            while (true) {
                const o = matchOp(p, .infix_or_postfix, min) orelse {
                    if (@hasDecl(P, "unmatched")) try p.unmatched(lhs, min, last);
                    break;
                };
                if (o.lbp < min or o.lbp > ceiling) break;
                const m = take(p, o, min);
                p.pratt.callback_cap = null;
                switch (o.fix) {
                    .infix => lhs = try p.infix(o.tag, lhs, m, o.rbp),
                    .postfix => lhs = try p.postfix(o.tag, lhs, m),
                    .prefix => unreachable,
                }
                ceiling = after(p, o);
                last = o.lbp;
            }
            p.pratt.exit_end = p.c.lastEnd();
            p.pratt.exit_cap = ceiling;
            return lhs;
        }

        /// The cap after operator `o` was read: its own (or its
        /// callback's), and that of the expression its tokens end with.
        fn after(p: *P, o: Op(Tag)) u8 {
            var c: u8 = p.pratt.callback_cap orelse o.cap orelse 255;
            p.pratt.callback_cap = null;
            if (p.pratt.exit_end == p.c.lastEnd()) c = @min(c, p.pratt.exit_cap);
            return c;
        }

        fn take(p: *P, o: Op(Tag), min: u8) Matched {
            const first = p.c.advance();
            var lastTok = first;
            for (o.seq) |_| lastTok = p.c.advance();
            return .{ .first = first, .last = lastTok, .min = min };
        }

        const Want = enum { prefix, infix_or_postfix };

        /// The kinds of token an operator of `want` may start with.
        fn startKinds(comptime want: Want) std.EnumSet(Cursor.Kind) {
            comptime {
                var set: std.EnumSet(Cursor.Kind) = .empty;
                for (table) |o| {
                    if ((o.fix == .prefix) != (want == .prefix)) continue;
                    const t = o.first;
                    if (t.kw != null) {
                        set.insert(.word);
                    } else if (t.kind) |k| {
                        set.insert(@field(Cursor.Kind, k));
                    } else {
                        // A punctuation operator may be a kind of its own.
                        set.insert(.op);
                        for (.{ .{ "(", .lparen }, .{ ")", .rparen }, .{ ",", .comma }, .{ ";", .semi }, .{ ".", .dot } }) |pk| {
                            if (std.mem.eql(u8, t.op.?, pk[0]) and @hasField(Cursor.Kind, @tagName(pk[1]))) set.insert(@field(Cursor.Kind, @tagName(pk[1])));
                        }
                    }
                }
                return set;
            }
        }

        /// The operator of the table at the next tokens, if any.
        inline fn matchOp(p: *P, comptime want: Want, min: u8) ?Op(Tag) {
            // Most often a token that starts none (`,`, `)`, a name).
            const starts = comptime startKinds(want);
            if (!starts.contains(p.c.peekAt(0).kind)) return null;
            inline for (table) |o| {
                const fits = comptime switch (want) {
                    .prefix => o.fix == .prefix,
                    .infix_or_postfix => o.fix != .prefix,
                };
                if (fits and (want != .prefix or min <= o.level) and matches(p, o)) return o;
            }
            return null;
        }

        inline fn matches(p: *P, comptime o: Op(Tag)) bool {
            if (!tokAt(p, 0, o.first)) return false;
            inline for (o.seq, 1..) |t, k| if (!tokAt(p, k, t)) return false;
            if (o.unless) |t| if (tokAt(p, 1 + o.seq.len, t)) return false;
            return true;
        }

        inline fn tokAt(p: *P, k: usize, comptime t: Tok) bool {
            if (t.kw) |kw| return p.c.isKwAt(k, kw);
            const tok = p.c.peekAt(k);
            if (t.op) |op| return p.c.isOpTok(tok, op);
            return tok.kind == @field(Cursor.Kind, t.kind.?);
        }
    };
}

// ================================================================ tests

const testing = std.testing;

/// A toy: integers, + - * / ^ (right), unary -, postfix !, NOT (only
/// where a condition starts), AND, comparison < (non-associative),
/// x BETWEEN a AND b, NOT BETWEEN, x IS NULL (capped), x AT TIME ZONE
/// y, f (x) but not a prefix f before `(`, and parentheses; the tree
/// printed as text.
const Toy = struct {
    const Tag = enum { add, sub, mul, div, pow, neg, fact, not, @"and", lt, between, not_between, is_null, at_zone, f };
    const ops = [_]Op(Tag){
        left(Tag, .@"and", 10, .{ .kw = "and" }),
        prefixAt(Tag, .not, 20, 20, .{ .kw = "not" }),
        left(Tag, .lt, 30, .{ .op = "<", .cap = 29 }),
        left(Tag, .not_between, 30, .{ .kw = "not", .then = "between" }),
        left(Tag, .between, 30, .{ .kw = "between" }),
        postfix(Tag, .is_null, 30, .{ .kw = "is", .then = "null", .cap = 30 }),
        left(Tag, .add, 40, .{ .op = "+" }),
        left(Tag, .sub, 40, .{ .op = "-" }),
        left(Tag, .mul, 50, .{ .op = "*" }),
        left(Tag, .div, 50, .{ .op = "/" }),
        prefix(Tag, .neg, 60, .{ .op = "-" }),
        prefix(Tag, .f, 60, .{ .kw = "f", .unless = .{ .op = "(" } }),
        right(Tag, .pow, 70, .{ .op = "^" }),
        left(Tag, .at_zone, 75, .{ .kw = "at", .seq = &.{ .{ .kw = "time" }, .{ .kw = "zone" } } }),
        postfix(Tag, .fact, 80, .{ .op = "!" }),
    };
    const E = Pratt(Parser, []const u8, Tag, &ops);

    const TKind = enum { eof, word, num, op };
    const Tok_ = struct { kind: TKind, text: []const u8 };
    const Cur = struct {
        pub const Kind = TKind;
        pub const Token = Tok_;
        toks: []const Tok_,
        i: usize = 0,
        fn peekAt(c: *const Cur, k: usize) Tok_ {
            return c.toks[@min(c.i + k, c.toks.len - 1)];
        }
        fn advance(c: *Cur) Tok_ {
            const t = c.toks[c.i];
            if (t.kind != .eof) c.i += 1;
            return t;
        }
        fn skip(c: *Cur) void {
            _ = c.advance();
        }
        fn lastEnd(c: *const Cur) u32 {
            return @intCast(c.i);
        }
        fn isKwAt(c: *const Cur, k: usize, kw: []const u8) bool {
            const t = c.peekAt(k);
            return t.kind == .word and std.mem.eql(u8, t.text, kw);
        }
        fn isKw(c: *const Cur, kw: []const u8) bool {
            return c.isKwAt(0, kw);
        }
        fn isOpTok(c: *const Cur, t: Tok_, op: []const u8) bool {
            _ = c;
            return t.kind == .op and std.mem.eql(u8, t.text, op);
        }
        fn isOp(c: *const Cur, op: []const u8) bool {
            return c.isOpTok(c.peekAt(0), op);
        }
        fn is(c: *const Cur, kind: TKind) bool {
            return c.peekAt(0).kind == kind;
        }
        fn syntaxError(c: *Cur) error{ ParseFailed, OutOfMemory } {
            _ = c;
            return error.ParseFailed;
        }
    };

    const Err = error{ ParseFailed, OutOfMemory };

    const Parser = struct {
        c: Cur,
        a: std.mem.Allocator,
        pratt: State = .{},

        pub fn operand(p: *Parser) Err![]const u8 {
            const t = p.c.advance();
            switch (t.kind) {
                .num => return t.text,
                .word => if (std.mem.eql(u8, t.text, "f") and p.c.isOp("(")) {
                    p.c.skip();
                    const e = try E.expr(p, 0);
                    if (!p.c.isOp(")")) return error.ParseFailed;
                    p.c.skip();
                    return std.fmt.allocPrint(p.a, "f({s})", .{e});
                },
                .op => if (std.mem.eql(u8, t.text, "(")) {
                    const e = try E.expr(p, 0);
                    if (!p.c.isOp(")")) return error.ParseFailed;
                    p.c.skip();
                    return e;
                },
                else => {},
            }
            return error.ParseFailed;
        }

        pub fn prefix(p: *Parser, tag: Tag, m: E.Matched, rbp: u8) Err![]const u8 {
            _ = m;
            const e = try E.expr(p, rbp);
            return std.fmt.allocPrint(p.a, "({s} {s})", .{ @tagName(tag), e });
        }

        pub fn infix(p: *Parser, tag: Tag, lhs: []const u8, m: E.Matched, rbp: u8) Err![]const u8 {
            _ = m;
            if (tag == .between or tag == .not_between) {
                const lo = try E.expr(p, 40);
                if (!p.c.isKw("and")) return error.ParseFailed;
                p.c.skip();
                const hi = try E.expr(p, 40);
                return std.fmt.allocPrint(p.a, "({s} {s} {s} {s})", .{ @tagName(tag), lhs, lo, hi });
            }
            const r = try E.expr(p, rbp);
            return std.fmt.allocPrint(p.a, "({s} {s} {s})", .{ @tagName(tag), lhs, r });
        }

        pub fn postfix(p: *Parser, tag: Tag, lhs: []const u8, m: E.Matched) Err![]const u8 {
            _ = m;
            return std.fmt.allocPrint(p.a, "({s} {s})", .{ @tagName(tag), lhs });
        }
    };

    fn parse(a: std.mem.Allocator, src: []const u8) ![]const u8 {
        var toks: std.ArrayList(Tok_) = .empty;
        var it = std.mem.tokenizeScalar(u8, src, ' ');
        while (it.next()) |w| {
            const k: TKind = if (std.ascii.isDigit(w[0])) .num else if (std.ascii.isAlphabetic(w[0])) .word else .op;
            try toks.append(a, .{ .kind = k, .text = w });
        }
        try toks.append(a, .{ .kind = .eof, .text = "" });
        var p: Parser = .{ .c = .{ .toks = toks.items }, .a = a };
        const e = try E.expr(&p, 0);
        if (!p.c.is(.eof)) return error.ParseFailed;
        return e;
    }
};

fn expectTree(src: []const u8, tree: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(tree, try Toy.parse(arena.allocator(), src));
}

fn expectNoTree(src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseFailed, Toy.parse(arena.allocator(), src));
}

test "pratt: precedence and associativity" {
    try expectTree("1 + 2 * 3", "(add 1 (mul 2 3))");
    try expectTree("1 - 2 - 3", "(sub (sub 1 2) 3)");
    try expectTree("2 ^ 3 ^ 2", "(pow 2 (pow 3 2))");
    try expectTree("- 2 ^ 2", "(neg (pow 2 2))");
    try expectTree("- 2 * 3", "(mul (neg 2) 3)");
    try expectTree("3 ! * 2", "(mul (fact 3) 2)");
    try expectTree("( 1 + 2 ) * 3", "(mul (add 1 2) 3)");
    try expectTree("not 1 < 2 and 3", "(and (not (lt 1 2)) 3)");
    try expectTree("1 between 0 and 2 and 3", "(and (between 1 0 2) 3)");
    try expectTree("1 not between 0 + 1 and 2 and not 3", "(and (not_between 1 (add 0 1) 2) (not 3))");
    try expectNoTree("1 < 2 < 3");
    try expectTree("1 < 2 + 3", "(lt 1 (add 2 3))");
}

test "pratt: prefix levels, caps, sequences, lookahead" {
    // NOT only where a condition starts.
    try expectNoTree("1 + not 2");
    try expectTree("not not 1", "(not (not 1))");
    // No tighter operator after IS NULL, in this loop or an enclosing one.
    try expectNoTree("1 is null + 1");
    try expectNoTree("1 and 2 is null + 1");
    try expectNoTree("not 2 is null * 1");
    try expectTree("1 is null and 2", "(and (is_null 1) 2)");
    try expectTree("1 + 2 is null", "(is_null (add 1 2))");
    // A cap inside parentheses ends there.
    try expectTree("( 1 is null ) + 1", "(add (is_null 1) 1)");
    try expectTree("f ( 1 is null ) + 1", "(add f((is_null 1)) 1)");
    // Several tokens.
    try expectTree("1 at time zone 2 at time zone 3", "(at_zone (at_zone 1 2) 3)");
    try expectNoTree("1 at time 2");
    // Not before a token.
    try expectTree("f 1 + 2", "(add (f 1) 2)");
    try expectTree("f ( 1 ) + 2", "(add f(1) 2)");
}
