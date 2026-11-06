//! The values of tokens, decoded from their text on demand: names,
//! strings without escapes, the parts of a quoted token, numbers. What
//! a backslash means in a string is the dialect's (PostgreSQL's E'...'
//! and MySQL's strings differ): it decodes those itself, over
//! `segments()`.

const std = @import("std");
const root = @import("root.zig");
const Token = @import("token.zig").Token;

const Allocator = std.mem.Allocator;

/// The name a word or a delimited identifier stands for: a word folded
/// to `case` (null: as written), the text between the quotes of a
/// delimited one with doubled quotes undoubled. Not for U&"...".
pub fn name(a: Allocator, sql: [:0]const u8, t: anytype, comptime case: ?root.Case) Allocator.Error![]const u8 {
    const raw = t.text(sql);
    if (t.kind != .quoted_ident) return if (case) |c| root.fold(a, raw, c) else raw;
    const close: u8 = if (raw[0] == '[') ']' else raw[0];
    return root.undouble(a, raw[1 .. raw.len - 1], close);
}

/// The index of the opening quote of the quoted token `t` (after a
/// prefix: N, E, X, U&, $tag$ is none).
pub fn openQuote(sql: []const u8, t: anytype) usize {
    var i: usize = t.start;
    while (std.ascii.isAlphabetic(sql[i]) or sql[i] == '&') i += 1;
    return i;
}

/// The quoted parts of a string (more than one if it continues over a
/// newline: Spec.string_continuation), the text between each one's
/// quotes as written.
pub const Segments = struct {
    sql: []const u8,
    /// The next opening quote, or `end`.
    i: usize,
    end: usize,
    q: u8,
    escapes: bool,

    pub const Segment = struct {
        /// The index of the text's first character.
        start: usize,
        text: []const u8,
    };

    pub fn next(it: *Segments) ?Segment {
        if (it.i >= it.end) return null;
        const open = it.i;
        var i = open + 1;
        while (true) {
            const c = it.sql[i];
            if (it.escapes and c == '\\') {
                i += 2;
            } else if (c == it.q) {
                if (i + 1 < it.end and it.sql[i + 1] == it.q) {
                    i += 2;
                } else break;
            } else i += 1;
        }
        const close = i;
        i += 1;
        while (i < it.end and it.sql[i] != it.q) i += 1;
        it.i = i;
        return .{ .start = open + 1, .text = it.sql[open + 1 .. close] };
    }
};

/// The segments of the string `t` (a closed one, '...' after its
/// prefix), scanned as the lexer did: `escapes` if a backslash escaped.
pub fn segments(sql: []const u8, t: anytype, escapes: bool) Segments {
    const open = openQuote(sql, t);
    return .{ .sql = sql, .i = open, .end = t.end, .q = sql[open], .escapes = escapes };
}

/// The value of a string with no escapes: its segments, doubled quotes
/// undoubled (a slice of `sql` if it is one segment without any).
pub fn plainString(a: Allocator, sql: []const u8, t: anytype) Allocator.Error![]const u8 {
    var it = segments(sql, t, false);
    const first = it.next().?;
    const one = try root.undouble(a, first.text, it.q);
    const second = it.next() orelse return one;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, one);
    var seg: ?Segments.Segment = second;
    while (seg) |s| : (seg = it.next()) try out.appendSlice(a, try root.undouble(a, s.text, it.q));
    return out.items;
}

/// The text between the delimiters of $tag$...$tag$.
pub fn dollarBody(sql: []const u8, t: anytype) []const u8 {
    const raw = t.text(sql);
    const tag = std.mem.indexOfScalarPos(u8, raw, 1, '$').? + 1;
    return raw[tag .. raw.len - tag];
}

/// The text between the delimiters of q'[...]' (and nq'...').
pub fn altBody(sql: []const u8, t: anytype) []const u8 {
    const open = openQuote(sql, t);
    return sql[open + 2 .. t.end - 2];
}

/// The digits of a number as written without `_` separators and its
/// radix prefix, and a `0` before a leading `.`: a slice of `sql` if no
/// change.
pub fn digits(a: Allocator, sql: []const u8, t: anytype) Allocator.Error![]const u8 {
    var raw = t.text(sql);
    if (t.sub != .none) raw = raw[2..];
    var out: []const u8 = raw;
    if (std.mem.indexOfScalar(u8, raw, '_') != null) {
        var buf: std.ArrayList(u8) = .empty;
        for (raw) |c| if (c != '_') try buf.append(a, c);
        out = buf.items;
    }
    if (out.len > 0 and out[0] == '.') out = try std.mem.concat(a, u8, &.{ "0", out });
    return out;
}

/// The decimal text of the integer `t` of any radix and length.
pub fn decimal(a: Allocator, sql: []const u8, t: anytype) Allocator.Error![]const u8 {
    const base: u8 = switch (t.sub) {
        .hex => 16,
        .octal => 8,
        .binary => 2,
        else => return digits(a, sql, t),
    };
    // Little-endian decimal digits.
    var dec: std.ArrayList(u8) = .empty;
    for (t.text(sql)[2..]) |ch| {
        if (ch == '_') continue;
        var carry: u32 = root.digitValue(ch);
        for (dec.items) |*d| {
            const v = @as(u32, d.*) * base + carry;
            d.* = @intCast(v % 10);
            carry = v / 10;
        }
        while (carry > 0) {
            try dec.append(a, @intCast(carry % 10));
            carry /= 10;
        }
    }
    if (dec.items.len == 0) try dec.append(a, 0);
    std.mem.reverse(u8, dec.items);
    for (dec.items) |*d| d.* += '0';
    return dec.items;
}

const testing = std.testing;

test "values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql: [:0]const u8 = "Ab \"x\"\"y\" [a]]b] 'it''s'\n 'z' $q$a$b$q$ nq'[x]' 0x1F 1_000 .5 0b";
    try testing.expectEqualStrings("ab", try name(a, sql, Token{ .kind = .word, .start = 0, .end = 2 }, .lower));
    try testing.expectEqualStrings("AB", try name(a, sql, Token{ .kind = .word, .start = 0, .end = 2 }, .upper));
    try testing.expectEqualStrings("Ab", try name(a, sql, Token{ .kind = .word, .start = 0, .end = 2 }, null));
    try testing.expectEqualStrings("x\"y", try name(a, sql, Token{ .kind = .quoted_ident, .start = 3, .end = 9 }, .lower));
    try testing.expectEqualStrings("a]b", try name(a, sql, Token{ .kind = .quoted_ident, .start = 10, .end = 16 }, null));
    try testing.expectEqualStrings("it'sz", try plainString(a, sql, Token{ .kind = .string, .start = 17, .end = 29 }));
    try testing.expectEqualStrings("a$b", dollarBody(sql, Token{ .kind = .string, .sub = .dollar, .start = 30, .end = 39 }));
    try testing.expectEqualStrings("x", altBody(sql, Token{ .kind = .string, .sub = .alt_quote, .start = 40, .end = 47 }));
    try testing.expectEqualStrings("31", try decimal(a, sql, Token{ .kind = .integer, .sub = .hex, .start = 48, .end = 52 }));
    try testing.expectEqualStrings("1000", try digits(a, sql, Token{ .kind = .integer, .start = 53, .end = 58 }));
    try testing.expectEqualStrings("0.5", try digits(a, sql, Token{ .kind = .float, .start = 59, .end = 61 }));
    try testing.expectEqualStrings("0", try decimal(a, sql, Token{ .kind = .integer, .sub = .binary, .start = 62, .end = 64 }));
}
