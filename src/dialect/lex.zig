//! Scanning the quoted tokens the dialects' lexers share: a string or
//! identifier between quotes, in which a doubled quote stands for the
//! quote itself. What a dialect says about one left open is its own.

const std = @import("std");

/// The extent of the quoted token that starts at `open` (its opening
/// quote) and closes with `q`: `end` is the index after the closing
/// quote, or, if the token is left open, of the NUL that ends `s`. With
/// `escapes`, a backslash escapes the character after it (MariaDB).
pub fn quotedEnd(s: [:0]const u8, open: usize, q: u8, escapes: bool) struct { end: usize, closed: bool } {
    var i = open + 1;
    while (true) {
        const c = s[i];
        if (c == 0) return .{ .end = i, .closed = false };
        if (c == '\\' and escapes and s[i + 1] != 0) {
            i += 2;
        } else if (c == q) {
            if (s[i + 1] != q) return .{ .end = i + 1, .closed = true };
            i += 2;
        } else i += 1;
    }
}

/// The text between the quote `q` at `open` and its closing one, with
/// doubled quotes undoubled (a slice of `s` if there are none, else a copy
/// in `arena`), and the index after the closing quote; null if the token
/// is left open.
pub fn undoubled(arena: std.mem.Allocator, s: [:0]const u8, open: usize, q: u8) error{OutOfMemory}!?struct { text: []const u8, end: usize } {
    var out: std.ArrayList(u8) = .empty;
    var i = open + 1;
    var seg = i;
    var copied = false;
    while (true) {
        if (s[i] == 0) return null;
        if (s[i] == q) {
            if (s[i + 1] == q) {
                try out.appendSlice(arena, s[seg .. i + 1]);
                copied = true;
                i += 2;
                seg = i;
                continue;
            }
            try out.appendSlice(arena, s[seg..i]);
            i += 1;
            break;
        }
        i += 1;
    }
    return .{ .text = if (copied) out.items else s[open + 1 .. i - 1], .end = i };
}

test "quoted tokens" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try undoubled(a, "x'it''s' y", 1, '\'')).?;
    try std.testing.expectEqualStrings("it's", r.text);
    try std.testing.expectEqual(@as(usize, 8), r.end);
    try std.testing.expect(try undoubled(a, "'open", 0, '\'') == null);
    try std.testing.expectEqual(@as(usize, 6), quotedEnd("'a\\'b'", 0, '\'', true).end);
    // Without escapes the backslash is a character: the quote after it
    // closes the token.
    const plain = quotedEnd("'a\\'b", 0, '\'', false);
    try std.testing.expect(plain.closed and plain.end == 4);
    try std.testing.expect(!quotedEnd("'ab", 0, '\'', false).closed);
}
