//! Keyword tables: a dialect's keywords, numbered, and the class of each
//! (what a parser may read it as besides a keyword). The lexer looks up
//! every unquoted word (Token.kw), so a parser compares keywords as
//! integers; Token.isKw("from") checks the name at compile time.

const std = @import("std");

/// What a keyword may stand for besides itself.
pub const Class = enum(u8) {
    /// Any name.
    unreserved,
    /// No name.
    reserved,
};

pub const Entry = struct { []const u8, Class };

/// The keywords `entries` (in any case; matched ignoring the case of
/// ASCII letters), numbered from 1 in order.
pub fn Keywords(comptime entries: []const Entry) type {
    @setEvalBranchQuota(100_000 + 2000 * entries.len);
    const n = entries.len;
    if (n >= std.math.maxInt(u16)) @compileError("too many keywords");
    // An open-addressing hash table of the keywords in lower case: a
    // word that is none mostly ends at an empty slot or a length that
    // differs, with no comparison.
    const size = std.math.ceilPowerOfTwo(usize, 4 * n + 1) catch unreachable;
    const names, const slots, const max = comptime blk: {
        var names: [n][]const u8 = undefined;
        var slots: [size]u16 = @splat(0);
        var max: usize = 0;
        for (entries, 0..) |e, i| {
            var low: [e[0].len]u8 = undefined;
            for (e[0], &low) |c, *o| {
                if (c == 0 or c >= 0x80) @compileError("a keyword is ASCII: " ++ e[0]);
                o.* = std.ascii.toLower(c);
            }
            const final = low;
            names[i] = &final;
            max = @max(max, e[0].len);
            var h = hash(&final) & (size - 1);
            while (slots[h] != 0) : (h = (h + 1) & (size - 1)) {
                if (std.mem.eql(u8, names[slots[h] - 1], &final)) @compileError("keyword twice: " ++ e[0]);
            }
            slots[h] = i + 1;
        }
        break :blk .{ names, slots, max };
    };
    return struct {
        /// The longest keyword's length.
        const max_len = max;

        const table = slots;
        const classes = blk: {
            var c: [n + 1]Class = undefined;
            c[0] = .unreserved;
            for (entries, 1..) |e, i| c[i] = e[1];
            break :blk c;
        };

        /// The number of keyword `word` (any case), 0 if it is none.
        pub fn lookup(word: []const u8) u16 {
            if (word.len == 0 or word.len > max_len) return 0;
            var buf: [max_len]u8 = undefined;
            const low = buf[0..word.len];
            for (word, low) |c, *o| o.* = std.ascii.toLower(c);
            var h = hash(low) & (size - 1);
            while (true) : (h = (h + 1) & (size - 1)) {
                const k = table[h];
                if (k == 0) return 0;
                const kn = names[k - 1];
                if (kn.len == low.len and std.mem.eql(u8, kn, low)) return k;
            }
        }

        /// The class of keyword number `k` (0: no keyword, any name).
        pub inline fn class(k: u16) Class {
            return classes[k];
        }

        /// Keyword number `k`'s name, in lower case.
        pub fn name(k: u16) []const u8 {
            return names[k - 1];
        }
    };
}

/// The hash of a word in lower case: its length, first, second and last
/// characters (keywords differ there mostly).
inline fn hash(w: []const u8) usize {
    const a: usize = w[0];
    const b: usize = if (w.len > 1) w[1] else 0;
    const z: usize = w[w.len - 1];
    return (a *% 0x9e37 ^ b *% 0x85eb ^ z *% 0xc2b3 ^ w.len *% 0x27d5) >> 2;
}

/// `words`, every one `class`: entries for Keywords().
pub fn all(comptime class: Class, comptime words: []const []const u8) []const Entry {
    comptime {
        var out: [words.len]Entry = undefined;
        for (words, &out) |w, *e| e.* = .{ w, class };
        const final = out;
        return &final;
    }
}

const testing = std.testing;

test "keywords" {
    const K = Keywords(&.{ .{ "SELECT", .reserved }, .{ "from", .reserved }, .{ "Abort", .unreserved }, .{ "and", .reserved } });
    try testing.expectEqual(@as(u16, 1), K.lookup("select"));
    try testing.expectEqual(@as(u16, 1), K.lookup("SeLeCt"));
    try testing.expectEqual(@as(u16, 3), K.lookup("ABORT"));
    try testing.expectEqual(@as(u16, 4), K.lookup("And"));
    try testing.expectEqual(@as(u16, 0), K.lookup("selects"));
    try testing.expectEqual(@as(u16, 0), K.lookup("selecT_"));
    try testing.expectEqual(@as(u16, 0), K.lookup(""));
    try testing.expectEqual(@as(u16, 0), K.lookup("sélect"));
    try testing.expectEqual(Class.reserved, K.class(2));
    try testing.expectEqual(Class.unreserved, K.class(0));
    try testing.expectEqualStrings("abort", K.name(3));
}
