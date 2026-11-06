//! PostgreSQL's regular expressions: the advanced regular expressions
//! (AREs) of Henry Spencer's engine in src/backend/regex, for the `~`
//! operators, SIMILAR TO and the regexp_*() functions (regexp.zig).
//! (pike.zig is the older, smaller engine; the schema text of older
//! databases calls it through xq_pg_regex(), and jsonpath's like_regex
//! uses it.)
//!
//! Syntax: literals, `.`, brackets `[...]`/`[^...]` with ranges, the
//! classes `[:alpha:]` ... (alnum alpha ascii blank cntrl digit graph
//! lower print punct space upper word xdigit), `[.c.]` and `[=c=]`;
//! the escapes `\d \s \w \D \S \W`, `\a \b \B \cX \e \f \n \r \t \v
//! \uXXXX \UXXXXXXXX \xhh \0oo`, back-references `\1` ... `\mnn`, the
//! constraints `^ $ \A \Z \m \M \y \Y` and `(?=re) (?!re) (?<=re)
//! (?<!re)`; groups `(re)` and `(?:re)`, `(?#comment)`, `|`; the
//! quantifiers `* + ? {m} {m,} {m,n}` and their non-greedy forms `*?
//! ...`; the director `***:` and `***=` (the rest literal) and leading
//! embedded options `(?inx...)`. Errors are PostgreSQL's (Fail).
//!
//! Matching is PostgreSQL's: the match starts at the leftmost position
//! that has one and is the longest there (or the shortest, when the
//! expression as a whole is non-greedy: its first quantified atom that
//! has a greediness decides; an alternation is greedy); then each
//! subexpression, the earlier first, takes what its own greediness
//! wants of that span. The span is found by a Pike VM (no backtracking
//! blow-up); the subexpressions by a dissection that asks the VM which
//! lengths each part may have (backtracking over those). An expression
//! with back-references is matched by backtracking alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What is wrong with a pattern (PostgreSQL's REG_* error, its text).
pub const Fail = enum {
    paren,
    brack,
    brace,
    badbr,
    badrpt,
    eescape,
    esubreg,
    ectype,
    ecollate,
    erange,
    badopt,
    toobig,

    pub fn message(f: Fail) []const u8 {
        return switch (f) {
            .paren => "parentheses () not balanced",
            .brack => "brackets [] not balanced",
            .brace => "braces {} not balanced",
            .badbr => "invalid repetition count(s)",
            .badrpt => "quantifier operand invalid",
            .eescape => "invalid escape \\ sequence",
            .esubreg => "invalid backreference number",
            .ectype => "invalid character class",
            .ecollate => "invalid collating element",
            .erange => "invalid character range",
            .badopt => "invalid embedded option",
            .toobig => "regular expression is too complex",
        };
    }
};

pub const Error = error{ OutOfMemory, BadPattern };

/// The compile options (the flags of the regexp functions).
pub const Options = struct {
    icase: bool = false,
    /// `.` and `[^...]` do not match a newline.
    nl_dot: bool = false,
    /// `^` and `$` also match after and before a newline.
    nl_anchor: bool = false,
    expanded: bool = false,
    quote: bool = false,
    /// false: an ERE ('e'): no escapes but the character's own.
    advanced: bool = true,

    /// Apply flag letter `f` (PostgreSQL's parse_re_flags(), and the
    /// embedded options); false if it is none.
    pub fn apply(o: *Options, f: u8) bool {
        switch (f) {
            'b', 'e' => o.advanced = false,
            'c' => o.icase = false,
            'i' => o.icase = true,
            'm', 'n' => {
                o.nl_dot = true;
                o.nl_anchor = true;
            },
            'p' => {
                o.nl_dot = true;
                o.nl_anchor = false;
            },
            'q' => o.quote = true,
            's' => {
                o.nl_dot = false;
                o.nl_anchor = false;
            },
            't' => o.expanded = false,
            'w' => {
                o.nl_dot = false;
                o.nl_anchor = true;
            },
            'x' => o.expanded = true,
            else => return false,
        }
        return true;
    }
};

// ============================================================ characters

/// The character at byte `i` of `s` and its length (a byte that is no
/// UTF-8 is itself).
pub fn decode(s: []const u8, i: usize) struct { c: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .c = s[i], .len = 1 };
    if (i + n > s.len) return .{ .c = s[i], .len = 1 };
    const c = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .c = s[i], .len = 1 };
    return .{ .c = c, .len = n };
}

/// The start of the character after byte `i`.
fn nextPos(s: []const u8, i: usize) usize {
    if (i >= s.len) return i + 1;
    return i + decode(s, i).len;
}

/// The start of the character before byte `i`.
fn prevStart(s: []const u8, i: usize) usize {
    var j = i - 1;
    var k: usize = 0;
    while (j > 0 and k < 3 and s[j] & 0xC0 == 0x80) : (k += 1) j -= 1;
    const d = decode(s, j);
    return if (j + d.len == i) j else i - 1;
}

/// Simple case mappings of the common alphabets (ASCII, Latin-1,
/// Latin Extended-A, Greek, Cyrillic, fullwidth Latin).
pub fn toLower(c: u21) u21 {
    if (c < 128) return std.ascii.toLower(@intCast(c));
    if ((c >= 0xC0 and c <= 0xDE and c != 0xD7)) return c + 0x20;
    if (c >= 0x100 and c <= 0x17F) {
        if (c == 0x130) return 'i';
        if ((c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E)) return if (c & 1 == 1) c + 1 else c;
        if (c == 0x178) return 0xFF;
        if (c == 0x131 or c == 0x138 or c == 0x149 or c == 0x17F) return c;
        return if (c & 1 == 0) c + 1 else c;
    }
    if (c >= 0x391 and c <= 0x3AB and c != 0x3A2) return c + 0x20;
    if (c == 0x386) return 0x3AC;
    if (c >= 0x388 and c <= 0x38A) return c + 37;
    if (c == 0x38C) return 0x3CC;
    if (c == 0x38E or c == 0x38F) return c + 63;
    if (c >= 0x410 and c <= 0x42F) return c + 0x20;
    if (c >= 0x400 and c <= 0x40F) return c + 0x50;
    if (c >= 0x460 and c <= 0x4FF and c & 1 == 0 and !(c >= 0x482 and c <= 0x489)) return c + 1;
    if (c >= 0xFF21 and c <= 0xFF3A) return c + 0x20;
    return c;
}

pub fn toUpper(c: u21) u21 {
    if (c < 128) return std.ascii.toUpper(@intCast(c));
    if ((c >= 0xE0 and c <= 0xFE and c != 0xF7)) return c - 0x20;
    if (c == 0xFF) return 0x178;
    if (c == 0xB5) return 0x39C;
    if (c >= 0x100 and c <= 0x17F) {
        if (c == 0x131) return 'I';
        if ((c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E)) return if (c & 1 == 0) c - 1 else c;
        if (c == 0x130 or c == 0x138 or c == 0x149 or c == 0x178) return c;
        if (c == 0x17F) return 'S';
        return if (c & 1 == 1) c - 1 else c;
    }
    if (c >= 0x3B1 and c <= 0x3CB and c != 0x3C2) return c - 0x20;
    if (c == 0x3C2) return 0x3A3;
    if (c == 0x3AC) return 0x386;
    if (c >= 0x3AD and c <= 0x3AF) return c - 37;
    if (c == 0x3CC) return 0x38C;
    if (c == 0x3CD or c == 0x3CE) return c - 63;
    if (c >= 0x430 and c <= 0x44F) return c - 0x20;
    if (c >= 0x450 and c <= 0x45F) return c - 0x50;
    if (c >= 0x461 and c <= 0x4FF and c & 1 == 1 and !(c >= 0x482 and c <= 0x489)) return c - 1;
    if (c >= 0xFF41 and c <= 0xFF5A) return c - 0x20;
    return c;
}

fn foldEq(x: u21, y: u21) bool {
    return x == y or toLower(x) == toLower(y) or toUpper(x) == toUpper(y);
}

/// The character classes of brackets ([:alpha:]) and escapes (\d).
pub const Class = enum(u4) {
    alnum,
    alpha,
    ascii,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    word,
    xdigit,

    fn bit(k: Class) u16 {
        return @as(u16, 1) << @backingInt(k);
    }
};

fn isSpaceChar(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x1680, 0x2000...0x2006, 0x2008...0x200A, 0x2028, 0x2029, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// A letter, for the characters past ASCII: what is not a control,
/// space, punctuation or symbol of the common blocks.
fn isAlphaChar(c: u21) bool {
    if (c < 128) return std.ascii.isAlphabetic(@intCast(c));
    return switch (c) {
        0xAA, 0xB5, 0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2C1, 0x2C6...0x2D1, 0x2E0...0x2E4, 0x370...0x373, 0x376...0x377, 0x37B...0x37D, 0x386, 0x388...0x3FF, 0x400...0x481, 0x48A...0x52F, 0x531...0x556, 0x561...0x587, 0x5D0...0x5EA, 0x620...0x64A, 0xE01...0xE30, 0x10A0...0x10FF, 0x1100...0x11FF, 0x1E00...0x1FFF, 0x3041...0x3096, 0x30A1...0x30FA, 0x3105...0x312F, 0x3131...0x318E, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF66...0xFFDC, 0x20000...0x2FFFF => true,
        else => false,
    };
}

pub fn inClass(k: Class, c: u21) bool {
    return switch (k) {
        .alnum => isAlphaChar(c) or (c >= '0' and c <= '9'),
        .alpha => isAlphaChar(c),
        .ascii => c < 128,
        .blank => c == ' ' or c == '\t' or (c >= 128 and isSpaceChar(c) and c != 0x2028 and c != 0x2029),
        .cntrl => c < 32 or c == 127 or (c >= 0x80 and c < 0xA0) or c == 0x2028 or c == 0x2029,
        .digit => c >= '0' and c <= '9',
        .graph => !(c < 33 or c == 127 or (c >= 0x80 and c < 0xA0) or isSpaceChar(c)),
        .lower => isAlphaChar(c) and toUpper(c) != c or (c >= 'a' and c <= 'z') or c == 0xDF,
        .print => !(c < 32 or c == 127 or (c >= 0x80 and c < 0xA0) or c == 0x2028 or c == 0x2029),
        .punct => if (c < 128) std.ascii.isPrint(@intCast(c)) and !std.ascii.isAlphanumeric(@intCast(c)) and c != ' ' else !(c < 0xA0 or isSpaceChar(c) or isAlphaChar(c)),
        .space => isSpaceChar(c),
        .upper => isAlphaChar(c) and toLower(c) != c,
        .word => isAlphaChar(c) or (c >= '0' and c <= '9') or c == '_',
        .xdigit => c < 128 and std.ascii.isHex(@intCast(c)),
    };
}

fn isWord(c: u21) bool {
    return inClass(.word, c);
}

const Range = struct { lo: u21, hi: u21 };

/// A bracket expression or a class escape: a character is in it if a
/// range or a class has it, or a negated class (\D in a bracket) has
/// not; `neg` turns the whole around.
const Set = struct {
    ranges: []const Range = &.{},
    classes: u16 = 0,
    nclasses: u16 = 0,
    neg: bool = false,
    /// hasRaw() of the ASCII characters, bit c (finish() fills it in).
    ascii: u128 = 0,

    /// Fill in `ascii` (once the ranges and classes are final).
    fn finish(k: *Set) void {
        k.ascii = 0;
        for (0..128) |c| if (k.hasSlow(@intCast(c))) {
            k.ascii |= @as(u128, 1) << @intCast(c);
        };
    }

    fn hasRaw(k: *const Set, c: u21) bool {
        if (c < 128) return (k.ascii >> @intCast(c)) & 1 != 0;
        return k.hasSlow(c);
    }

    fn hasSlow(k: *const Set, c: u21) bool {
        for (k.ranges) |r| if (c >= r.lo and c <= r.hi) return true;
        var bits = k.classes;
        while (bits != 0) : (bits &= bits - 1) {
            if (inClass(@fromBackingInt(@intCast(@as(u4, @intCast(@ctz(bits))))), c)) return true;
        }
        bits = k.nclasses;
        while (bits != 0) : (bits &= bits - 1) {
            if (!inClass(@fromBackingInt(@intCast(@as(u4, @intCast(@ctz(bits))))), c)) return true;
        }
        return false;
    }

    fn has(k: *const Set, c: u21, o: Options) bool {
        var in = k.hasRaw(c);
        if (!in and o.icase) {
            const l = toLower(c);
            const u = toUpper(c);
            in = (l != c and k.hasRaw(l)) or (u != c and k.hasRaw(u));
        }
        if (k.neg) {
            if (c == '\n' and o.nl_dot) return false;
            return !in;
        }
        return in;
    }
};

// ================================================================ nodes

const Assert = enum { bol, eol, begin, end, word, nonword, wstart, wend };

const Pref = enum { none, longer, shorter, fixed_marker };

const Node = struct {
    kind: Kind,
    pref: Pref = .none,
    /// A capturing group or a back-reference is inside.
    messy: bool = false,
    /// A back-reference is inside.
    backref: bool = false,
    /// The node's code in the program: from `entry` to `exit` (the
    /// instruction after it).
    entry: u32 = 0,
    exit: u32 = 0,
    /// The groups inside: lo..hi (none if lo is 0).
    g_lo: u32 = 0,
    g_hi: u32 = 0,

    fn addGroups(n: *Node, x: *const Node) void {
        if (x.g_lo == 0) return;
        if (n.g_lo == 0 or x.g_lo < n.g_lo) n.g_lo = x.g_lo;
        n.g_hi = @max(n.g_hi, x.g_hi);
    }
};

const Kind = union(enum) {
    empty,
    char: u21,
    any,
    set: *const Set,
    assert: Assert,
    look: u32,
    cat: []*Node,
    alt: []*Node,
    rep: Rep,
    group: Group,
    backref: u32,
};

const Rep = struct { n: *Node, min: u32, max: ?u32, greedy: bool };
const Group = struct { n: *Node, idx: u32 };

const Inst = union(enum) {
    char: u21,
    any,
    set: *const Set,
    assert: Assert,
    look: u32,
    /// Both ways, the first preferred.
    split: [2]u32,
    jmp: u32,
    backref: u32,
    match,
};

/// A lookahead or lookbehind constraint: its own program (a
/// lookbehind's reads backwards: its sequences reversed).
const Look = struct { prog: []Inst, ahead: bool, neg: bool };

/// A compiled expression.
pub const Regex = struct {
    prog: []Inst,
    root: *Node,
    looks: []Look,
    /// The number of capturing groups.
    ngroups: u32,
    opt: Options,
    has_backref: bool,
};

/// A match or a group's part of it: byte offsets, null if a group took
/// no part.
pub const Span = struct { so: usize, eo: usize };

// =============================================================== parser

const max_dup = 255;

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    opt: Options,
    /// Groups opened so far, and whether each is closed.
    ngroups: u32 = 0,
    closed: std.ArrayList(bool) = .empty,
    /// In a lookaround: parentheses do not capture.
    capture: bool = true,
    depth: u32 = 0,
    looks: std.ArrayList(Look) = .empty,
    looks_nodes: std.ArrayList(*Node) = .empty,
    has_backref: bool = false,
    fail: Fail = .badrpt,
    /// Set by quantifier() when a bound is malformed.
    failed: bool = false,

    fn bad(p: *Parser, f: Fail) Error {
        p.fail = f;
        return error.BadPattern;
    }

    fn eos(p: *Parser) bool {
        return p.i >= p.s.len;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn peekAt(p: *Parser, k: usize) ?u8 {
        return if (p.i + k < p.s.len) p.s[p.i + k] else null;
    }

    fn node(p: *Parser, k: Kind) Error!*Node {
        const x = try p.a.create(Node);
        x.* = .{ .kind = k };
        return x;
    }

    fn char(p: *Parser) u21 {
        const d = decode(p.s, p.i);
        p.i += d.len;
        return d.c;
    }

    /// Skip the white space and #comments of an expanded expression.
    fn skipX(p: *Parser) void {
        if (!p.opt.expanded) return;
        while (p.i < p.s.len) {
            const d = decode(p.s, p.i);
            if (isSpaceChar(d.c)) {
                p.i += d.len;
            } else if (d.c == '#') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else break;
        }
    }

    fn alt(p: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        try items.append(p.a, try p.branch());
        while (p.peek() == '|') {
            p.i += 1;
            try items.append(p.a, try p.branch());
        }
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .alt = items.items });
    }

    fn branch(p: *Parser) Error!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (true) {
            p.skipX();
            const c = p.peek() orelse break;
            if (c == '|' or c == ')') break;
            const at = try p.atom() orelse continue;
            var item = at.n;
            p.skipX();
            if (p.quantifier()) |q| {
                if (!at.quantifiable) return p.bad(.badrpt);
                item = try p.quantified(item, q);
                p.skipX();
                if (p.quantifier() != null) return p.bad(.badrpt);
                if (p.failed) return error.BadPattern;
            } else if (p.failed) return error.BadPattern;
            try items.append(p.a, item);
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .cat = items.items });
    }

    const Quant = struct { min: u32, max: ?u32, greedy: bool, fixed: bool };

    /// The quantifier at the position, consumed; null if there is none
    /// (or it is malformed: `failed`).
    fn quantifier(p: *Parser) ?Quant {
        const c = p.peek() orelse return null;
        var q: Quant = .{ .min = 0, .max = null, .greedy = true, .fixed = false };
        switch (c) {
            '*' => p.i += 1,
            '+' => {
                p.i += 1;
                q.min = 1;
            },
            '?' => {
                p.i += 1;
                q.max = 1;
            },
            '{' => {
                const d = p.peekAt(1) orelse return null;
                if (!std.ascii.isDigit(d)) return null;
                p.i += 1;
                q.min = p.bound() orelse return null;
                if (p.peek() == ',') {
                    p.i += 1;
                    if (p.peek() != null and std.ascii.isDigit(p.peek().?)) {
                        q.max = p.bound() orelse return null;
                    }
                } else {
                    q.max = q.min;
                    q.fixed = true;
                }
                const e = p.peek() orelse {
                    p.fail = .brace;
                    p.failed = true;
                    return null;
                };
                if (e != '}') {
                    p.fail = .badbr;
                    p.failed = true;
                    return null;
                }
                p.i += 1;
                if (q.max != null and q.max.? < q.min) {
                    p.fail = .badbr;
                    p.failed = true;
                    return null;
                }
            },
            else => return null,
        }
        if (p.opt.advanced and p.peek() == '?') {
            p.i += 1;
            q.greedy = false;
        }
        return q;
    }

    fn bound(p: *Parser) ?u32 {
        var v: u32 = 0;
        var n: usize = 0;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            v = v * 10 + (c - '0');
            n += 1;
            p.i += 1;
            if (v > max_dup) {
                p.fail = .badbr;
                p.failed = true;
                return null;
            }
        }
        if (n == 0) {
            p.fail = .badbr;
            p.failed = true;
            return null;
        }
        return v;
    }

    fn quantified(p: *Parser, n: *Node, q: Quant) Error!*Node {
        if (q.min == 1 and q.max != null and q.max.? == 1 and q.fixed) return n;
        const r = try p.node(.{ .rep = .{ .n = n, .min = q.min, .max = q.max, .greedy = q.greedy } });
        if (q.fixed) r.pref = .fixed_marker else r.pref = if (q.greedy) .longer else .shorter;
        return r;
    }

    const Atom = struct { n: *Node, quantifiable: bool };

    /// The next atom; null for what is none (a comment).
    fn atom(p: *Parser) Error!?Atom {
        const c = p.peek().?;
        switch (c) {
            '(' => return p.paren(),
            ')' => return p.bad(.paren),
            '.' => {
                p.i += 1;
                return .{ .n = try p.node(.any), .quantifiable = true };
            },
            '^' => {
                p.i += 1;
                return .{ .n = try p.node(.{ .assert = .bol }), .quantifiable = false };
            },
            '$' => {
                p.i += 1;
                return .{ .n = try p.node(.{ .assert = .eol }), .quantifiable = false };
            },
            '[' => return .{ .n = try p.bracket(), .quantifiable = true },
            '\\' => return try p.escape(),
            '*', '+', '?' => return p.bad(.badrpt),
            '{' => {
                if (p.peekAt(1) != null and std.ascii.isDigit(p.peekAt(1).?)) return p.bad(.badrpt);
                p.i += 1;
                return .{ .n = try p.node(.{ .char = '{' }), .quantifiable = true };
            },
            else => return .{ .n = try p.node(.{ .char = p.char() }), .quantifiable = true },
        }
    }

    fn paren(p: *Parser) Error!?Atom {
        p.i += 1;
        var capture = p.capture;
        var look: ?struct { ahead: bool, neg: bool } = null;
        if (p.opt.advanced and p.peek() == '?') {
            const k = p.peekAt(1) orelse return p.bad(.badrpt);
            switch (k) {
                ':' => {
                    p.i += 2;
                    capture = false;
                },
                '=' => {
                    p.i += 2;
                    look = .{ .ahead = true, .neg = false };
                },
                '!' => {
                    p.i += 2;
                    look = .{ .ahead = true, .neg = true };
                },
                '<' => {
                    const k2 = p.peekAt(2) orelse return p.bad(.badrpt);
                    if (k2 != '=' and k2 != '!') return p.bad(.badrpt);
                    p.i += 3;
                    look = .{ .ahead = false, .neg = k2 == '!' };
                },
                '#' => {
                    while (p.peek()) |x| {
                        p.i += 1;
                        if (x == ')') return null;
                    }
                    return p.bad(.paren);
                },
                else => return p.bad(.badrpt),
            }
        }
        p.depth += 1;
        if (p.depth > 200) return p.bad(.toobig);
        defer p.depth -= 1;
        if (look) |lk| {
            const save = p.capture;
            p.capture = false;
            const inner = try p.alt();
            p.capture = save;
            if (p.peek() != ')') return p.bad(.paren);
            p.i += 1;
            const idx: u32 = @intCast(p.looks.items.len);
            try p.looks.append(p.a, .{ .prog = &.{}, .ahead = lk.ahead, .neg = lk.neg });
            try p.looks_nodes.append(p.a, inner);
            return .{ .n = try p.node(.{ .look = idx }), .quantifiable = false };
        }
        var idx: u32 = 0;
        if (capture) {
            p.ngroups += 1;
            idx = p.ngroups;
            try p.closed.append(p.a, false);
        }
        const inner = try p.alt();
        if (p.peek() != ')') return p.bad(.paren);
        p.i += 1;
        if (!capture) return .{ .n = inner, .quantifiable = true };
        p.closed.items[idx - 1] = true;
        return .{ .n = try p.node(.{ .group = .{ .n = inner, .idx = idx } }), .quantifiable = true };
    }

    fn hexDigits(p: *Parser, min: usize, max: usize) Error!u32 {
        var v: u32 = 0;
        var n: usize = 0;
        while (n < max) : (n += 1) {
            const c = p.peek() orelse break;
            const d = std.fmt.charToDigit(c, 16) catch break;
            if (v > 0x10FFFF) return p.bad(.eescape);
            v = v * 16 + d;
            p.i += 1;
        }
        if (n < min or v > 0x10FFFF) return p.bad(.eescape);
        return v;
    }

    fn octal(p: *Parser) Error!u21 {
        var v: u21 = 0;
        var n: usize = 0;
        const start = p.i;
        while (n < 3) : (n += 1) {
            const c = p.peek() orelse break;
            if (c < '0' or c > '7') break;
            v = v * 8 + (c - '0');
            p.i += 1;
        }
        if (n == 0) return p.bad(.eescape);
        if (v > 0xFF) {
            // One digit too many.
            p.i = start + n - 1;
            v >>= 3;
        }
        return v;
    }

    /// A character escape (`\n` ...) after the backslash, or null if
    /// the letter is no character escape.
    fn charEscape(p: *Parser, c: u8) Error!?u21 {
        switch (c) {
            'a' => return 7,
            'b' => return 8,
            'B' => return '\\',
            'c' => {
                const x = p.peek() orelse return p.bad(.eescape);
                p.i += 1;
                return x & 0o37;
            },
            'e' => return 0o33,
            'f' => return 12,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 11,
            'u' => return @intCast(try p.hexDigits(4, 4)),
            'U' => return @intCast(try p.hexDigits(8, 8)),
            'x' => return @intCast(try p.hexDigits(1, 255)),
            '0' => {
                p.i -= 1;
                return try p.octal();
            },
            else => return null,
        }
    }

    fn classEscape(c: u8) ?Set {
        return switch (c) {
            'd' => .{ .classes = Class.digit.bit() },
            'D' => .{ .classes = Class.digit.bit(), .neg = true },
            's' => .{ .classes = Class.space.bit() },
            'S' => .{ .classes = Class.space.bit(), .neg = true },
            'w' => .{ .classes = Class.word.bit() },
            'W' => .{ .classes = Class.word.bit(), .neg = true },
            else => null,
        };
    }

    fn escape(p: *Parser) Error!Atom {
        p.i += 1;
        if (p.eos()) return p.bad(.eescape);
        if (!p.opt.advanced) return .{ .n = try p.node(.{ .char = p.char() }), .quantifiable = true };
        const c = p.s[p.i];
        if (c >= 128 or !std.ascii.isAlphanumeric(c)) return .{ .n = try p.node(.{ .char = p.char() }), .quantifiable = true };
        p.i += 1;
        if (classEscape(c)) |k| return .{ .n = try p.setNode(k), .quantifiable = true };
        const as: ?Assert = switch (c) {
            'A' => .begin,
            'Z' => .end,
            'm' => .wstart,
            'M' => .wend,
            'y' => .word,
            'Y' => .nonword,
            else => null,
        };
        if (as) |x| return .{ .n = try p.node(.{ .assert = x }), .quantifiable = false };
        if (c >= '1' and c <= '9') {
            const save = p.i;
            var v: u32 = c - '0';
            while (p.peek()) |d| {
                if (!std.ascii.isDigit(d) or v > max_dup) break;
                v = v * 10 + (d - '0');
                p.i += 1;
            }
            if (p.i == save or v <= p.ngroups) {
                if (v == 0 or v > p.ngroups or !p.closed.items[v - 1]) return p.bad(.esubreg);
                if (!p.capture) return p.bad(.esubreg);
                p.has_backref = true;
                const n = try p.node(.{ .backref = v });
                return .{ .n = n, .quantifiable = true };
            }
            p.i = save - 1;
            return .{ .n = try p.node(.{ .char = try p.octal() }), .quantifiable = true };
        }
        if (try p.charEscape(c)) |x| return .{ .n = try p.node(.{ .char = x }), .quantifiable = true };
        return p.bad(.eescape);
    }

    const class_names = std.StaticStringMap(Class).initComptime(.{
        .{ "alnum", .alnum }, .{ "alpha", .alpha },   .{ "ascii", .ascii }, .{ "blank", .blank },
        .{ "cntrl", .cntrl }, .{ "digit", .digit },   .{ "graph", .graph }, .{ "lower", .lower },
        .{ "print", .print }, .{ "punct", .punct },   .{ "space", .space }, .{ "upper", .upper },
        .{ "word", .word },   .{ "xdigit", .xdigit },
    });

    const collating_names = std.StaticStringMap(u21).initComptime(.{
        .{ "NUL", 0 },                    .{ "tab", '\t' },                .{ "newline", '\n' },
        .{ "vertical-tab", 11 },          .{ "form-feed", 12 },            .{ "carriage-return", '\r' },
        .{ "space", ' ' },                .{ "exclamation-mark", '!' },    .{ "quotation-mark", '"' },
        .{ "number-sign", '#' },          .{ "dollar-sign", '$' },         .{ "percent-sign", '%' },
        .{ "ampersand", '&' },            .{ "apostrophe", '\'' },         .{ "left-parenthesis", '(' },
        .{ "right-parenthesis", ')' },    .{ "asterisk", '*' },            .{ "plus-sign", '+' },
        .{ "comma", ',' },                .{ "hyphen", '-' },              .{ "hyphen-minus", '-' },
        .{ "period", '.' },               .{ "full-stop", '.' },           .{ "slash", '/' },
        .{ "solidus", '/' },              .{ "zero", '0' },                .{ "one", '1' },
        .{ "two", '2' },                  .{ "three", '3' },               .{ "four", '4' },
        .{ "five", '5' },                 .{ "six", '6' },                 .{ "seven", '7' },
        .{ "eight", '8' },                .{ "nine", '9' },                .{ "colon", ':' },
        .{ "semicolon", ';' },            .{ "less-than-sign", '<' },      .{ "equals-sign", '=' },
        .{ "greater-than-sign", '>' },    .{ "question-mark", '?' },       .{ "commercial-at", '@' },
        .{ "left-square-bracket", '[' },  .{ "backslash", '\\' },          .{ "reverse-solidus", '\\' },
        .{ "right-square-bracket", ']' }, .{ "circumflex", '^' },          .{ "circumflex-accent", '^' },
        .{ "underscore", '_' },           .{ "low-line", '_' },            .{ "grave-accent", '`' },
        .{ "left-brace", '{' },           .{ "left-curly-bracket", '{' },  .{ "vertical-line", '|' },
        .{ "right-brace", '}' },          .{ "right-curly-bracket", '}' }, .{ "tilde", '~' },
        .{ "DEL", 127 },
    });

    /// One element of a bracket: a character (a range's end) or a set.
    const Elem = union(enum) { c: u21, set: Set };

    fn bracketElem(p: *Parser) Error!Elem {
        const c = p.peek() orelse return p.bad(.brack);
        if (c == '[' and p.peekAt(1) != null) {
            const k = p.peekAt(1).?;
            if (k == ':' or k == '.' or k == '=') {
                const start = p.i + 2;
                var j = start;
                while (j + 1 < p.s.len and !(p.s[j] == k and p.s[j + 1] == ']')) j += 1;
                if (j + 1 >= p.s.len) return p.bad(.brack);
                const name = p.s[start..j];
                p.i = j + 2;
                switch (k) {
                    ':' => {
                        var cl = class_names.get(name) orelse return p.bad(.ectype);
                        if (p.opt.icase and (cl == .upper or cl == .lower)) cl = .alpha;
                        return .{ .set = .{ .classes = cl.bit() } };
                    },
                    else => {
                        if (name.len == 0) return p.bad(.ecollate);
                        const d = decode(name, 0);
                        if (d.len == name.len) return .{ .c = d.c };
                        if (k == '.') if (collating_names.get(name)) |x| return .{ .c = x };
                        return p.bad(.ecollate);
                    },
                }
            }
        }
        if (c == '\\' and p.opt.advanced) {
            p.i += 1;
            if (p.eos()) return p.bad(.eescape);
            const e = p.s[p.i];
            if (e >= 128 or !std.ascii.isAlphanumeric(e)) return .{ .c = p.char() };
            p.i += 1;
            if (classEscape(e)) |k| {
                if (k.neg) return .{ .set = .{ .nclasses = k.classes } };
                return .{ .set = k };
            }
            if (e >= '1' and e <= '9') {
                p.i -= 1;
                return .{ .c = try p.octal() };
            }
            if (try p.charEscape(e)) |x| return .{ .c = x };
            return p.bad(.eescape);
        }
        return .{ .c = p.char() };
    }

    fn bracket(p: *Parser) Error!*Node {
        p.i += 1;
        var set: Set = .{};
        if (p.peek() == '^') {
            set.neg = true;
            p.i += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.bad(.brack);
            if (c == ']' and !first) {
                p.i += 1;
                break;
            }
            if (c == ']' and first) {
                p.i += 1;
                first = false;
                try p.rangeFrom(&ranges, ']');
                continue;
            }
            first = false;
            const e = try p.bracketElem();
            switch (e) {
                .set => |k| {
                    if (p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1).? != ']') return p.bad(.erange);
                    set.classes |= k.classes;
                    set.nclasses |= k.nclasses;
                },
                .c => |lo| try p.rangeFrom(&ranges, lo),
            }
        }
        set.ranges = ranges.items;
        return p.setNode(set);
    }

    fn setNode(p: *Parser, set: Set) Error!*Node {
        const k = try p.a.create(Set);
        k.* = set;
        k.finish();
        return p.node(.{ .set = k });
    }

    /// The range that starts with `lo` (just read), or `lo` alone.
    fn rangeFrom(p: *Parser, ranges: *std.ArrayList(Range), lo: u21) Error!void {
        var hi = lo;
        if (p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1).? != ']') {
            p.i += 1;
            const e = try p.bracketElem();
            switch (e) {
                .set => return p.bad(.erange),
                .c => |x| hi = x,
            }
            if (hi < lo) return p.bad(.erange);
        }
        try ranges.append(p.a, .{ .lo = lo, .hi = hi });
    }
};

// ======================================================= node analysis

/// Fill in `pref`, `messy` and `backref` (PostgreSQL's greediness
/// rules: a quantified atom is greedy or not by its quantifier, a fixed
/// {m} is as its atom, a branch as its first quantified atom that has a
/// greediness, an alternation of several branches greedy).
fn analyze(n: *Node) void {
    switch (n.kind) {
        .empty, .char, .any, .set, .assert, .look => {},
        .backref => {
            n.messy = true;
            n.backref = true;
        },
        .group => |g| {
            analyze(g.n);
            n.pref = g.n.pref;
            n.messy = true;
            n.backref = g.n.backref;
            n.g_lo = g.idx;
            n.g_hi = @max(g.idx, g.n.g_hi);
        },
        .rep => |r| {
            analyze(r.n);
            n.pref = if (n.pref == .fixed_marker) r.n.pref else n.pref;
            n.messy = r.n.messy;
            n.backref = r.n.backref;
            n.addGroups(r.n);
        },
        .cat => |items| {
            for (items) |x| {
                analyze(x);
                if (n.pref == .none) n.pref = x.pref;
                n.messy = n.messy or x.messy;
                n.backref = n.backref or x.backref;
                n.addGroups(x);
            }
        },
        .alt => |items| {
            for (items) |x| {
                analyze(x);
                n.messy = n.messy or x.messy;
                n.backref = n.backref or x.backref;
                n.addGroups(x);
            }
            n.pref = .longer;
        },
    }
}

// ============================================================== emitter

const max_prog = 200_000;

const Emitter = struct {
    a: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    /// The code reads backwards (a lookbehind's): a sequence's items
    /// the last first.
    back: bool = false,

    fn pc(e: *Emitter) u32 {
        return @intCast(e.prog.items.len);
    }

    fn emit(e: *Emitter, i: Inst) Error!u32 {
        if (e.prog.items.len > max_prog) return error.BadPattern;
        try e.prog.append(e.a, i);
        return e.pc() - 1;
    }

    fn node(e: *Emitter, n: *Node) Error!void {
        n.entry = e.pc();
        switch (n.kind) {
            .empty => {},
            .char => |c| _ = try e.emit(.{ .char = c }),
            .any => _ = try e.emit(.any),
            .set => |k| _ = try e.emit(.{ .set = k }),
            .assert => |x| _ = try e.emit(.{ .assert = x }),
            .look => |x| _ = try e.emit(.{ .look = x }),
            .backref => |x| _ = try e.emit(.{ .backref = x }),
            .group => |g| try e.node(g.n),
            .cat => |items| if (e.back) {
                var k = items.len;
                while (k > 0) {
                    k -= 1;
                    try e.node(items[k]);
                }
            } else for (items) |x| try e.node(x),
            .alt => |items| {
                var jumps: std.ArrayList(u32) = .empty;
                for (items, 0..) |x, k| {
                    if (k + 1 < items.len) {
                        const sp = try e.emit(.{ .split = .{ 0, 0 } });
                        e.prog.items[sp].split[0] = e.pc();
                        try e.node(x);
                        try jumps.append(e.a, try e.emit(.{ .jmp = 0 }));
                        e.prog.items[sp].split[1] = e.pc();
                    } else try e.node(x);
                }
                for (jumps.items) |j| e.prog.items[j].jmp = e.pc();
            },
            .rep => |r| {
                for (0..r.min) |_| try e.node(r.n);
                if (r.max) |max| {
                    var outs: std.ArrayList(u32) = .empty;
                    for (r.min..max) |_| {
                        const sp = try e.emit(.{ .split = .{ 0, 0 } });
                        try outs.append(e.a, sp);
                        const body = e.pc();
                        e.prog.items[sp].split = if (r.greedy) .{ body, 0 } else .{ 0, body };
                        try e.node(r.n);
                    }
                    const end = e.pc();
                    for (outs.items) |sp| {
                        if (r.greedy) e.prog.items[sp].split[1] = end else e.prog.items[sp].split[0] = end;
                    }
                } else {
                    const sp = try e.emit(.{ .split = .{ 0, 0 } });
                    const body = e.pc();
                    try e.node(r.n);
                    _ = try e.emit(.{ .jmp = sp });
                    const end = e.pc();
                    e.prog.items[sp].split = if (r.greedy) .{ body, end } else .{ end, body };
                }
            },
        }
        n.exit = e.pc();
    }
};

// =============================================================== compile

/// Compile `pattern` with options `opt`. On error.BadPattern `fail` says
/// why.
pub fn compile(a: Allocator, pattern: []const u8, opt0: Options, fail: *Fail) Error!Regex {
    var opt = opt0;
    var s = pattern;
    // The director: ***= (the rest is literal), ***: (an ARE).
    if (opt.advanced and std.mem.startsWith(u8, s, "***")) {
        if (s.len >= 4 and s[3] == '=') {
            opt.quote = true;
            s = s[4..];
        } else if (s.len >= 4 and s[3] == ':') {
            s = s[4..];
        }
    }
    var p: Parser = .{ .a = a, .s = s, .opt = opt };
    var root: *Node = undefined;
    if (opt.quote) {
        var items: std.ArrayList(*Node) = .empty;
        while (!p.eos()) try items.append(a, try p.node(.{ .char = p.char() }));
        root = if (items.items.len == 0) try p.node(.empty) else try p.node(.{ .cat = items.items });
    } else {
        // Leading embedded options: (?letters).
        if (opt.advanced and std.mem.startsWith(u8, s, "(?") and s.len > 2 and std.ascii.isAlphabetic(s[2])) {
            var j: usize = 2;
            while (j < s.len and s[j] != ')') : (j += 1) {
                if (!p.opt.apply(s[j])) {
                    fail.* = .badopt;
                    return error.BadPattern;
                }
            }
            if (j >= s.len) {
                fail.* = .badopt;
                return error.BadPattern;
            }
            p.i = j + 1;
            if (p.opt.quote) {
                var items: std.ArrayList(*Node) = .empty;
                while (!p.eos()) try items.append(a, try p.node(.{ .char = p.char() }));
                root = if (items.items.len == 0) try p.node(.empty) else try p.node(.{ .cat = items.items });
            }
        }
        if (!p.opt.quote) {
            root = p.alt() catch |err| {
                fail.* = p.fail;
                return err;
            };
            if (!p.eos()) {
                fail.* = .paren;
                return error.BadPattern;
            }
        }
    }
    analyze(root);
    for (p.looks_nodes.items) |n| analyze(n);
    var e: Emitter = .{ .a = a };
    e.node(root) catch |err| {
        fail.* = .toobig;
        return err;
    };
    _ = try e.emit(.match);
    for (p.looks.items, p.looks_nodes.items) |*lk, n| {
        var le: Emitter = .{ .a = a, .back = !lk.ahead };
        le.node(n) catch |err| {
            fail.* = .toobig;
            return err;
        };
        _ = try le.emit(.match);
        lk.prog = le.prog.items;
    }
    return .{
        .prog = e.prog.items,
        .root = root,
        .looks = p.looks.items,
        .ngroups = p.ngroups,
        .opt = p.opt,
        .has_backref = p.has_backref,
    };
}

// =============================================================== matcher

/// Matching `re` against one string: the groups of the last match.
pub const Matcher = struct {
    re: *const Regex,
    a: Allocator,
    s: []const u8,
    /// Group n's span at caps[n - 1].
    caps: []?Span,
    /// The end a dissection may not pass.
    limit: usize = 0,
    depth: u32 = 0,
    /// The VM's threads for the expression's program (findVm(), reach())
    /// and for each lookaround's (lookAt()), kept from run to run.
    vm: Scratch,
    look_vm: []Scratch,

    pub fn init(a: Allocator, re: *const Regex, s: []const u8) Error!Matcher {
        const caps = try a.alloc(?Span, re.ngroups);
        @memset(caps, null);
        const look_vm = try a.alloc(Scratch, re.looks.len);
        for (look_vm, re.looks) |*x, lk| x.* = try Scratch.init(a, lk.prog.len);
        return .{ .re = re, .a = a, .s = s, .caps = caps, .vm = try Scratch.init(a, re.prog.len), .look_vm = look_vm };
    }

    // ------------------------------------------------------- the VM

    fn step(m: *Matcher, inst: Inst, c: u21) bool {
        const o = m.re.opt;
        return switch (inst) {
            .char => |x| x == c or (o.icase and foldEq(x, c)),
            .any => !(c == '\n' and o.nl_dot),
            .set => |k| k.has(c, o),
            else => false,
        };
    }

    fn assertAt(m: *Matcher, x: Assert, i: usize) bool {
        const s = m.s;
        const o = m.re.opt;
        switch (x) {
            .bol => return i == 0 or (o.nl_anchor and s[i - 1] == '\n'),
            .eol => return i == s.len or (o.nl_anchor and s[i] == '\n'),
            .begin => return i == 0,
            .end => return i == s.len,
            else => {
                const before = i > 0 and isWord(decode(s, prevStart(s, i)).c);
                const after = i < s.len and isWord(decode(s, i).c);
                return switch (x) {
                    .word => before != after,
                    .nonword => before == after,
                    .wstart => !before and after,
                    .wend => before and !after,
                    else => unreachable,
                };
            },
        }
    }

    fn lookAt(m: *Matcher, idx: u32, i: usize) Error!bool {
        const lk = m.re.looks[idx];
        // A lookaround holds only the lookarounds inside it: its threads
        // are in use by no other run.
        const sc = &m.look_vm[idx];
        const exit: u32 = @intCast(lk.prog.len - 1);
        var h: Found = .{};
        // A lookbehind's code reads back from `i`: a match that ends
        // there, from any start.
        if (lk.ahead) {
            try m.run(sc, lk.prog, 0, exit, .one, i, m.s.len, &h);
        } else try m.run(sc, lk.prog, 0, exit, .back, i, 0, &h);
        return h.found != lk.neg;
    }

    const List = struct {
        pcs: std.ArrayList(u32) = .empty,
        starts: std.ArrayList(usize) = .empty,
        on: std.DynamicBitSet,

        fn init(a: Allocator, n: usize) Error!List {
            return .{ .on = try std.DynamicBitSet.initEmpty(a, n) };
        }

        fn clear(l: *List) void {
            l.pcs.clearRetainingCapacity();
            l.starts.clearRetainingCapacity();
            l.on.unsetAll();
        }
    };

    /// The threads of a program's run: the current and next positions'.
    const Scratch = struct {
        cur: List,
        next: List,
        stack: std.ArrayList(u32) = .empty,

        fn init(a: Allocator, n: usize) Error!Scratch {
            return .{ .cur = try List.init(a, n), .next = try List.init(a, n) };
        }
    };

    /// Add the thread at `pc0` (started at `start`) and what it reaches
    /// without reading to `l`; at `exit`, `hit(start)`.
    fn closure(m: *Matcher, prog: []const Inst, l: *List, stack: *std.ArrayList(u32), pc0: u32, exit: u32, start: usize, i: usize, hit: anytype) Error!void {
        stack.clearRetainingCapacity();
        try stack.append(m.a, pc0);
        while (stack.pop()) |pc| {
            if (pc == exit) {
                hit.at(start, i);
                continue;
            }
            if (l.on.isSet(pc)) continue;
            l.on.set(pc);
            switch (prog[pc]) {
                .jmp => |t| try stack.append(m.a, t),
                .split => |sp| {
                    try stack.append(m.a, sp[1]);
                    try stack.append(m.a, sp[0]);
                },
                .assert => |x| if (m.assertAt(x, i)) try stack.append(m.a, pc + 1),
                .look => |x| if (try m.lookAt(x, i)) try stack.append(m.a, pc + 1),
                .match => {},
                .backref => unreachable,
                .char, .any, .set => {
                    try l.pcs.append(m.a, pc);
                    try l.starts.append(m.a, start);
                },
            }
        }
    }

    const Ends = struct {
        set: *std.DynamicBitSet,
        fn at(h: *Ends, _: usize, i: usize) void {
            h.set.set(i);
        }
        fn done(_: *const Ends) bool {
            return false;
        }
    };

    const Found = struct {
        found: bool = false,
        fn at(h: *Found, _: usize, _: usize) void {
            h.found = true;
        }
        fn done(h: *const Found) bool {
            return h.found;
        }
    };

    /// Where run() starts threads: at `from` only, at the positions of a
    /// set, or at `from` reading backwards (`to` before it).
    const Starts = union(enum) { one, set: *const std.DynamicBitSet, back };

    /// Run code `entry`..`exit` of `prog` over `from`..`to`, the threads
    /// started where `starts` says, on the threads of `sc`; `hit` hears
    /// where each can end, until it is done.
    fn run(m: *Matcher, sc: *Scratch, prog: []const Inst, entry: u32, exit: u32, starts: Starts, from: usize, to: usize, hit: anytype) Error!void {
        sc.cur.clear();
        const last_start: usize = switch (starts) {
            .one, .back => from,
            .set => |b| blk: {
                var last = from;
                var it = b.iterator(.{});
                while (it.next()) |x| if (x <= to) {
                    last = x;
                };
                break :blk last;
            },
        };
        var i = from;
        while (true) {
            const begin = switch (starts) {
                .one, .back => i == from,
                .set => |b| b.isSet(i),
            };
            if (begin) try m.closure(prog, &sc.cur, &sc.stack, entry, exit, i, i, hit);
            if (hit.done()) return;
            if (starts == .back) {
                if (i <= to or sc.cur.pcs.items.len == 0) return;
            } else if (i >= to or (sc.cur.pcs.items.len == 0 and i >= last_start)) return;
            // The character after `i` (before it, reading backwards), and
            // the position past it.
            const at = if (starts == .back) prevStart(m.s, i) else i;
            const d = decode(m.s, at);
            const nx = if (starts == .back) at else i + d.len;
            sc.next.clear();
            for (sc.cur.pcs.items) |pc| {
                if (m.step(prog[pc], d.c)) try m.closure(prog, &sc.next, &sc.stack, pc + 1, exit, from, nx, hit);
            }
            std.mem.swap(List, &sc.cur, &sc.next);
            i = nx;
        }
    }

    /// Mark in `ends` every position up to `to` where the expression's
    /// code `entry`..`exit`, started at `from`, can end.
    fn reach(m: *Matcher, entry: u32, exit: u32, from: usize, to: usize, ends: *std.DynamicBitSet) Error!void {
        ends.unsetAll();
        var h: Ends = .{ .set = ends };
        try m.run(&m.vm, m.re.prog, entry, exit, .one, from, to, &h);
    }

    /// reach() from every position of `starts` (in from..to) at once.
    fn reachFrom(m: *Matcher, entry: u32, exit: u32, starts: *const std.DynamicBitSet, from: usize, to: usize, ends: *std.DynamicBitSet) Error!void {
        ends.unsetAll();
        var h: Ends = .{ .set = ends };
        try m.run(&m.vm, m.re.prog, entry, exit, .{ .set = starts }, from, to, &h);
    }

    const Best = struct {
        best: ?Span = null,
        shorter: bool,
        fn at(h: *Best, start: usize, i: usize) void {
            if (h.best) |b| {
                if (start < b.so) {
                    h.best = .{ .so = start, .eo = i };
                } else if (start == b.so and !h.shorter) {
                    h.best = .{ .so = start, .eo = i };
                }
            } else h.best = .{ .so = start, .eo = i };
        }
    };

    /// The leftmost match at or after `from`, the longest or shortest
    /// there.
    fn findVm(m: *Matcher, from: usize) Error!?Span {
        const prog = m.re.prog;
        const exit = m.re.root.exit;
        const cur = &m.vm.cur;
        const next = &m.vm.next;
        const stack = &m.vm.stack;
        cur.clear();
        var h: Best = .{ .shorter = m.re.root.pref == .shorter };
        var i = from;
        while (true) {
            // A thread starts here, after the earlier ones (their starts
            // are smaller: what they reach is theirs).
            if (h.best == null) try m.closure(prog, cur, stack, m.re.root.entry, exit, i, i, &h);
            if (cur.pcs.items.len == 0 and (h.best != null or i >= m.s.len)) break;
            if (i >= m.s.len) break;
            const d = decode(m.s, i);
            const nx = i + d.len;
            next.clear();
            for (cur.pcs.items, cur.starts.items) |pc, st| {
                if (h.best) |b| {
                    if (st > b.so or (st == b.so and h.shorter)) continue;
                }
                if (m.step(prog[pc], d.c)) try m.closure(prog, next, stack, pc + 1, exit, st, nx, &h);
            }
            std.mem.swap(List, cur, next);
            i = nx;
        }
        return h.best;
    }

    // -------------------------------------------------- dissection

    const Task = union(enum) {
        node: *const Node,
        cat_rest: struct { items: []*Node, idx: usize },
        close: struct { idx: u32, start: usize },
        more: struct { rep: *const Node, count: u32, start: usize },
        end_at: usize,
        collect: *std.DynamicBitSet,
    };

    const Cont = struct { task: Task, next: ?*const Cont };

    /// Match node `n` at `i`, then `k`.
    fn btNode(m: *Matcher, n: *const Node, i: usize, k: ?*const Cont) Error!bool {
        if (n.backref) return m.btStruct(n, i, k);
        switch (n.kind) {
            .empty, .char, .any, .set, .assert, .look, .group => return m.btStruct(n, i, k),
            else => {},
        }
        var ends = try std.DynamicBitSet.initEmpty(m.a, m.s.len + 1);
        defer ends.deinit();
        try m.reach(n.entry, n.exit, i, m.limit, &ends);
        const shorter = n.pref == .shorter;
        // The ends, in the order the node's greediness prefers.
        var list: std.ArrayList(usize) = .empty;
        defer list.deinit(m.a);
        if (shorter) {
            var it = ends.iterator(.{});
            while (it.next()) |e| try list.append(m.a, e);
        } else {
            var it = ends.iterator(.{ .direction = .reverse });
            while (it.next()) |e| try list.append(m.a, e);
        }
        for (list.items) |e| {
            if (!n.messy) {
                if (try m.bt(e, k)) return true;
            } else if (n.kind == .rep) {
                // The dissection of a span is final: what follows does
                // not depend on it (no back-references).
                const saved = try m.a.dupe(?Span, m.groupsOf(n));
                defer m.a.free(saved);
                if (try m.repDissect(n, i, e) and try m.bt(e, k)) return true;
                @memcpy(m.groupsOf(n), saved);
            } else {
                const c: Cont = .{ .task = .{ .end_at = e }, .next = k };
                if (try m.btStruct(n, i, &c)) return true;
            }
        }
        return false;
    }

    /// Match the structure of `n` at `i` (its end is fixed by `k`, or
    /// tried in its own order), then `k`.
    fn btStruct(m: *Matcher, n: *const Node, i: usize, k: ?*const Cont) Error!bool {
        m.depth += 1;
        defer m.depth -= 1;
        if (m.depth > 20_000) return error.BadPattern;
        switch (n.kind) {
            .empty => return m.bt(i, k),
            .char, .any, .set => {
                if (i >= m.s.len) return false;
                const d = decode(m.s, i);
                const inst: Inst = switch (n.kind) {
                    .char => |c| .{ .char = c },
                    .any => .any,
                    .set => |x| .{ .set = x },
                    else => unreachable,
                };
                if (!m.step(inst, d.c)) return false;
                return m.bt(i + d.len, k);
            },
            .assert => |x| return m.assertAt(x, i) and try m.bt(i, k),
            .look => |x| return (try m.lookAt(x, i)) and try m.bt(i, k),
            .backref => |g| {
                const sp = m.caps[g - 1] orelse return false;
                const sub = m.s[sp.so..sp.eo];
                var j = i;
                var x: usize = 0;
                while (x < sub.len) {
                    if (j >= m.s.len) return false;
                    const d1 = decode(sub, x);
                    const d2 = decode(m.s, j);
                    if (!(d1.c == d2.c or (m.re.opt.icase and foldEq(d1.c, d2.c)))) return false;
                    x += d1.len;
                    j += d2.len;
                }
                return m.bt(j, k);
            },
            .group => |g| {
                const c: Cont = .{ .task = .{ .close = .{ .idx = g.idx, .start = i } }, .next = k };
                return m.btNode(g.n, i, &c);
            },
            .cat => |items| return m.catFrom(items, 0, i, k),
            .alt => |items| {
                for (items) |b| if (try m.btNode(b, i, k)) return true;
                return false;
            },
            .rep => {
                return m.more(n, 0, i, i, k);
            },
        }
    }

    /// The iterations of repetition `rep` (no back-references inside)
    /// that make up exactly `begin`..`end`, their groups set by the last.
    /// x{m,n} with m > 0 is lastDissect()'s; x{0,n} (either greediness)
    /// is PostgreSQL's citerdissect() or creviterdissect(), as x itself
    /// is greedy or not: each iteration as long (or short) as x lets the
    /// rest still end there, an empty one only if needed; of an empty
    /// span one iteration if x can be empty (none if x is non-greedy).
    fn repDissect(m: *Matcher, rep: *const Node, begin: usize, end: usize) Error!bool {
        const r = rep.kind.rep;
        if (r.min > 0) return m.lastDissect(rep, begin, end);
        const child = r.n;
        const max: usize = r.max orelse std.math.maxInt(usize);
        const min: usize = @max(r.min, 1);
        // Each iteration as its own greediness wants (the shortest
        // first: no iteration of an empty span).
        const shorter = child.pref == .shorter;
        if (shorter and begin == end) {
            m.zap(child);
            return true;
        }
        var endpts: std.ArrayList(usize) = .empty;
        defer endpts.deinit(m.a);
        // ends[k]: where the k'th iteration may end (from endpts[k-1]).
        var ends: std.ArrayList(std.DynamicBitSet) = .empty;
        defer {
            for (ends.items) |*b| b.deinit();
            ends.deinit(m.a);
        }
        try endpts.append(m.a, begin);
        var k: usize = 1;
        // The bound of the k'th iteration's end: at most (greedy), at
        // least (not).
        var limit: usize = if (shorter) begin else end;
        var nverified: usize = 0;
        const save_limit = m.limit;
        m.limit = end;
        defer m.limit = save_limit;
        outer: while (k > 0) {
            if (ends.items.len < k) {
                try ends.append(m.a, try std.DynamicBitSet.initEmpty(m.a, m.s.len + 1));
            }
            if (endpts.items.len <= k) try endpts.append(m.a, 0);
            const prev = endpts.items[k - 1];
            // (Re)compute where this iteration may end.
            try m.reach(child.entry, child.exit, prev, end, &ends.items[k - 1]);
            const set = &ends.items[k - 1];
            var found: ?usize = null;
            if (shorter) {
                var lim = limit;
                // No empty iteration unless needed for the minimum.
                if (lim == prev and lim != end and (k >= min or min - k < end - lim)) lim = nextPos(m.s, lim);
                var x = lim;
                while (x <= end) : (x += 1) if (set.isSet(x)) {
                    found = x;
                    break;
                };
            } else {
                var x = limit + 1;
                while (x > prev) {
                    x -= 1;
                    if (set.isSet(x)) {
                        found = x;
                        break;
                    }
                }
            }
            const e = found orelse {
                k -= 1;
                if (!try m.backtrackRep(&endpts, &k, &limit, min, end, shorter)) break :outer;
                continue :outer;
            };
            endpts.items[k] = e;
            if (nverified >= k) nverified = k - 1;
            if (e != end) {
                if (k >= max) {
                    k -= 1;
                    if (!try m.backtrackRep(&endpts, &k, &limit, min, end, shorter)) break :outer;
                    continue :outer;
                }
                if (!shorter and e == prev and (k >= min or min - k < end - e)) {
                    if (!try m.backtrackRep(&endpts, &k, &limit, min, end, shorter)) break :outer;
                    continue :outer;
                }
                k += 1;
                limit = if (shorter) e else end;
                continue :outer;
            }
            if (k < min) {
                if (!try m.backtrackRep(&endpts, &k, &limit, min, end, shorter)) break :outer;
                continue :outer;
            }
            // Verify each iteration (its groups cleared first).
            var i = nverified + 1;
            while (i <= k) : (i += 1) {
                m.zap(child);
                const c: Cont = .{ .task = .{ .end_at = endpts.items[i] }, .next = null };
                if (!try m.btNode(child, endpts.items[i - 1], &c)) break;
                nverified = i;
            }
            if (i > k) return true;
            k = i;
            if (!try m.backtrackRep(&endpts, &k, &limit, min, end, shorter)) break :outer;
        }
        if (r.min == 0 and begin == end) {
            m.zap(child);
            return true;
        }
        return false;
    }

    /// x{m,n} of `rep` as PostgreSQL dissects it: x{m-1,n-1} (whose
    /// groups take no part) then the last x, the split by the
    /// quantifier's greediness (the most, or the fewest, for the prefix).
    fn lastDissect(m: *Matcher, rep: *const Node, begin: usize, end: usize) Error!bool {
        const r = rep.kind.rep;
        const child = r.n;
        const lo: u32 = r.min - 1;
        const hi: ?u32 = if (r.max) |x| x - 1 else null;
        const n = m.s.len + 1;
        // Where the prefix may end.
        var pre = try std.DynamicBitSet.initEmpty(m.a, n);
        defer pre.deinit();
        if (hi == null and lo == 0 and r.min <= 1) {
            // x* itself: the repetition's code from `begin`, or none.
            var ends = try std.DynamicBitSet.initEmpty(m.a, n);
            defer ends.deinit();
            try m.reach(rep.entry, rep.exit, begin, end, &ends);
            pre.setUnion(ends);
            pre.set(begin);
        } else {
            var cur = try std.DynamicBitSet.initEmpty(m.a, n);
            defer cur.deinit();
            var next = try std.DynamicBitSet.initEmpty(m.a, n);
            defer next.deinit();
            cur.set(begin);
            if (lo == 0) pre.set(begin);
            var j: u32 = 0;
            const cap: usize = lo + (end - begin) + 2;
            while (cur.findFirstSet() != null and (hi == null or j < hi.?) and j < cap) {
                try m.reachFrom(child.entry, child.exit, &cur, begin, end, &next);
                j += 1;
                if (j >= lo) pre.setUnion(next);
                if (next.eql(cur)) break;
                std.mem.swap(std.DynamicBitSet, &cur, &next);
            }
        }
        var ends = try std.DynamicBitSet.initEmpty(m.a, n);
        defer ends.deinit();
        const save_limit = m.limit;
        m.limit = end;
        defer m.limit = save_limit;
        var k: usize = 0;
        while (k <= end - begin) : (k += 1) {
            const mid = if (r.greedy) end - k else begin + k;
            if (!pre.isSet(mid)) continue;
            try m.reach(child.entry, child.exit, mid, end, &ends);
            if (!ends.isSet(end)) continue;
            m.zap(child);
            const c: Cont = .{ .task = .{ .end_at = end }, .next = null };
            if (try m.btNode(child, mid, &c)) return true;
        }
        return false;
    }

    /// The next try of the k'th iteration: shorter (greedy) or longer;
    /// false if there is none.
    fn backtrackRep(m: *Matcher, endpts: *std.ArrayList(usize), k: *usize, limit: *usize, min: usize, end: usize, shorter: bool) Error!bool {
        _ = m;
        while (k.* > 0) {
            const prev = endpts.items[k.* - 1];
            const cur = endpts.items[k.*];
            if (shorter) {
                if (cur < end) {
                    limit.* = cur + 1;
                    return true;
                }
            } else if (cur > prev) {
                const lim = cur - 1;
                if (lim > prev or (k.* < min and min - k.* >= end - prev)) {
                    limit.* = lim;
                    return true;
                }
            }
            k.* -= 1;
        }
        return false;
    }

    /// The groups inside `n`.
    fn groupsOf(m: *Matcher, n: *const Node) []?Span {
        if (n.g_lo == 0) return m.caps[0..0];
        return m.caps[n.g_lo - 1 .. n.g_hi];
    }

    /// Forget the groups inside `n`.
    fn zap(m: *Matcher, n: *const Node) void {
        if (n.g_lo == 0) return;
        @memset(m.caps[n.g_lo - 1 .. n.g_hi], null);
    }

    fn catFrom(m: *Matcher, items: []*Node, idx: usize, i: usize, k: ?*const Cont) Error!bool {
        if (idx == items.len) return m.bt(i, k);
        if (idx + 1 == items.len) return m.btNode(items[idx], i, k);
        const c: Cont = .{ .task = .{ .cat_rest = .{ .items = items, .idx = idx + 1 } }, .next = k };
        return m.btNode(items[idx], i, &c);
    }

    /// After `count` iterations of `rep`, the last from `start`, at `i`.
    fn more(m: *Matcher, rep: *const Node, count: u32, start: usize, i: usize, k: ?*const Cont) Error!bool {
        const r = rep.kind.rep;
        // A back-reference to a group that took no part fails, even
        // none of it (PostgreSQL's cbrdissect()).
        if (r.n.kind == .backref and m.caps[r.n.kind.backref - 1] == null) return false;
        var can_more = r.max == null or count < r.max.?;
        if (count > 0 and i == start and count >= r.min) {
            // An empty iteration: only the first may be, and it ends
            // the loop.
            if (count > 1 and count > r.min) return false;
            can_more = false;
        }
        const can_exit = count >= r.min;
        if (r.greedy) {
            if (can_more and try m.iterate(rep, count, i, k)) return true;
            return can_exit and try m.bt(i, k);
        }
        if (can_exit and try m.bt(i, k)) return true;
        return can_more and try m.iterate(rep, count, i, k);
    }

    fn iterate(m: *Matcher, rep: *const Node, count: u32, i: usize, k: ?*const Cont) Error!bool {
        const c: Cont = .{ .task = .{ .more = .{ .rep = rep, .count = count + 1, .start = i } }, .next = k };
        return m.btNode(rep.kind.rep.n, i, &c);
    }

    /// Continue with `k` at `i`.
    fn bt(m: *Matcher, i: usize, k: ?*const Cont) Error!bool {
        const c = k orelse return true;
        switch (c.task) {
            .node => |n| return m.btNode(n, i, c.next),
            .cat_rest => |r| return m.catFrom(r.items, r.idx, i, c.next),
            .close => |cl| {
                const old = m.caps[cl.idx - 1];
                m.caps[cl.idx - 1] = .{ .so = cl.start, .eo = i };
                if (try m.bt(i, c.next)) return true;
                m.caps[cl.idx - 1] = old;
                return false;
            },
            .more => |mo| return m.more(mo.rep, mo.count, mo.start, i, c.next),
            .end_at => |e| return i == e and try m.bt(i, c.next),
            .collect => |set| {
                set.set(i);
                return false;
            },
        }
    }

    // ----------------------------------------------------- the API

    /// The next match at or after byte `from` (a character boundary),
    /// its groups in `caps` if `groups` (else all null); null if there
    /// is none.
    pub fn exec(m: *Matcher, from: usize, groups: bool) Error!?Span {
        @memset(m.caps, null);
        const root = m.re.root;
        if (!m.re.has_backref) {
            const sp = try m.findVm(from) orelse return null;
            if (groups and m.re.ngroups > 0) {
                m.limit = sp.eo;
                const c: Cont = .{ .task = .{ .end_at = sp.eo }, .next = null };
                _ = try m.btNode(root, sp.so, &c);
            }
            return sp;
        }
        m.limit = m.s.len;
        var ends = try std.DynamicBitSet.initEmpty(m.a, m.s.len + 1);
        defer ends.deinit();
        var st = from;
        while (st <= m.s.len) {
            ends.unsetAll();
            const c: Cont = .{ .task = .{ .collect = &ends }, .next = null };
            _ = try m.btStruct(root, st, &c);
            @memset(m.caps, null);
            if (ends.findFirstSet() != null) {
                const e = if (root.pref == .shorter) ends.findFirstSet().? else ends.findLastSet().?;
                if (groups) {
                    const c2: Cont = .{ .task = .{ .end_at = e }, .next = null };
                    _ = try m.btStruct(root, st, &c2);
                }
                return .{ .so = st, .eo = e };
            }
            if (st == m.s.len) break;
            st += decode(m.s, st).len;
        }
        return null;
    }
};

/// Whether `s` has a match of `re`.
pub fn search(a: Allocator, re: *const Regex, s: []const u8) Error!bool {
    var m = try Matcher.init(a, re, s);
    return (try m.exec(0, false)) != null;
}

// ================================================================ tests

fn expectMatch(pattern: []const u8, flags: []const u8, s: []const u8, want: ?[]const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var o: Options = .{};
    for (flags) |f| _ = o.apply(f);
    var fail: Fail = undefined;
    const re = try compile(a, pattern, o, &fail);
    var m = try Matcher.init(a, &re, s);
    const sp = try m.exec(0, true);
    if (want) |w| {
        const got = sp orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(w[0], s[got.so..got.eo]);
        for (w[1..], m.caps) |x, c| {
            if (c) |cs| try std.testing.expectEqualStrings(x, s[cs.so..cs.eo]) else try std.testing.expectEqualStrings(x, "NULL");
        }
    } else try std.testing.expect(sp == null);
}

fn expectFail(pattern: []const u8, f: Fail) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fail: Fail = undefined;
    try std.testing.expectError(error.BadPattern, compile(arena.allocator(), pattern, .{}, &fail));
    try std.testing.expectEqual(f, fail);
}

test "are: PostgreSQL's matches and groups" {
    try expectMatch("(a*)*", "", "b", &.{ "", "" });
    try expectMatch("(a*)*", "", "aaa", &.{ "aaa", "aaa" });
    try expectMatch("(ab|a)*", "", "abab", &.{ "abab", "ab" });
    try expectMatch("(.*?)(\\d+)(.*)", "", "abc01234xyz", &.{ "abc0", "abc", "0", "" });
    try expectMatch("(.*)(\\d+)(.*)", "", "abc01234xyz", &.{ "abc01234xyz", "abc0123", "4", "xyz" });
    try expectMatch("(a)|(x)", "", "xyz", &.{ "x", "NULL", "x" });
    try expectMatch("(a|ab)(c|bcd)(d*)", "", "abcd", &.{ "abcd", "ab", "c", "d" });
    try expectMatch("Y*([0-9]{1,3})", "", "XY1234Z", &.{ "Y123", "123" });
    try expectMatch("Y*?([0-9]{1,3})", "", "XY1234Z", &.{ "Y1", "1" });
    try expectMatch("(ab)\\1", "", "xabab", &.{ "abab", "ab" });
    try expectMatch("(ab)\\1", "i", "ABab", &.{ "ABab", "AB" });
    try expectMatch("(x)?b", "", "abc", &.{ "b", "NULL" });
    try expectMatch("(?<=a)b", "", "abc", &.{"b"});
    try expectMatch("b(?!c)", "", "abc", null);
    try expectMatch("\\mbar\\M", "", "foo bar", &.{"bar"});
    try expectMatch("^b", "n", "a\nb", &.{"b"});
    try expectMatch("a.b", "n", "a\nb", null);
    try expectMatch("a b c?", "x", "a b", null);
    try expectMatch("[[:alpha:]]+", "", "12ab3", &.{"ab"});
    try expectMatch("[^]a]", "", "ab", &.{"b"});
    try expectMatch("(?i)A", "", "xa", &.{"a"});
    try expectMatch("***=a.c", "", "abc a.c", &.{"a.c"});
    try expectMatch("a{2}?", "", "aaa", &.{"aa"});
    try expectMatch("(?:a|ab)(c|bcd)?", "", "abcabc", &.{ "abc", "c" });
    try expectMatch("(?<=ab+)c", "", "acabbbc", &.{"c"});
    try expectMatch("(?<=a.{2})(c)", "", "xcabbc", &.{ "c", "c" });
    try expectMatch("(?<!a)b", "", "ab cb", &.{"b"});
    try expectMatch("(?<=é.)x", "", "éüx", &.{"x"});
    try expectMatch("(?<=^|,)[^,]*", "", ",ab", &.{""});
    try expectMatch("(?<=\\mab)c(.*)", "", "xabc abc", &.{ "c", "" });
    try expectMatch("(?<=a(?=b)bc)d", "", "abcd", &.{"d"});
    try expectMatch("[^[:digit:]a-c]+", "i", "1Ab9xyz", &.{"xyz"});
}

test "are: errors" {
    try expectFail("(", .paren);
    try expectFail("a)", .paren);
    try expectFail("[[:foo:]]", .ectype);
    try expectFail("a{3,2}", .badbr);
    try expectFail("a{256}", .badbr);
    try expectFail("a{1", .brace);
    try expectFail("\\1", .esubreg);
    try expectFail("(a\\1)", .esubreg);
    try expectFail("*", .badrpt);
    try expectFail("a**", .badrpt);
    try expectFail("^*", .badrpt);
    try expectFail("{1}", .badrpt);
    try expectFail("[", .brack);
    try expectFail("\\", .eescape);
    try expectFail("\\q", .eescape);
    try expectFail("[z-a]", .erange);
    try expectFail("(?z)a", .badopt);
    try expectFail("(?", .badrpt);
}
