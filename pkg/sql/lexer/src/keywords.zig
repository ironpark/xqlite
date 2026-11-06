//! Keyword tables: a dialect's keywords, numbered, and the class of each
//! (what a parser may read it as besides a keyword). The lexer looks up
//! every unquoted word (Token.kw), so a parser compares keywords as
//! integers, with names of an enum that a misspelling does not compile.

const std = @import("std");

/// What a keyword may stand for besides itself (PostgreSQL's keyword
/// categories, which the other dialects' reserved words fit).
pub const Class = enum(u8) {
    /// Any name.
    unreserved,
    /// A column name, not a function or type name (PostgreSQL).
    col_name,
    /// A function or type name, not a column name (PostgreSQL).
    type_func_name,
    /// No name.
    reserved,
};

pub const Entry = struct { []const u8, Class };

/// The keywords `entries` (in any case; matched ignoring the case of
/// ASCII letters), numbered from 1 in order. `Kw` names them in lower
/// case.
pub fn Keywords(comptime entries: []const Entry) type {
    @setEvalBranchQuota(100_000 + 1000 * entries.len);
    const n = entries.len;
    if (n >= std.math.maxInt(u16)) @compileError("too many keywords");
    const names, const kvs, const max = comptime blk: {
        var names: [n][]const u8 = undefined;
        var kvs: [n]struct { []const u8, u16 } = undefined;
        var max: usize = 0;
        for (entries, 0..) |e, i| {
            var low: [e[0].len]u8 = undefined;
            for (e[0], &low) |c, *o| {
                if (c == 0 or c >= 0x80) @compileError("a keyword is ASCII: " ++ e[0]);
                o.* = std.ascii.toLower(c);
            }
            const final = low;
            names[i] = &final;
            kvs[i] = .{ &final, i + 1 };
            max = @max(max, e[0].len);
        }
        break :blk .{ names, kvs, max };
    };
    const vals = comptime blk: {
        var v: [n]u16 = undefined;
        for (&v, 0..) |*x, i| x.* = i + 1;
        break :blk v;
    };
    return struct {
        pub const Kw = @Enum(u16, .exhaustive, &names, &vals);
        pub const count = n;
        /// The longest keyword's length.
        pub const max_len = max;

        const map = std.StaticStringMap(u16).initComptime(kvs);
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
            for (word, buf[0..word.len]) |c, *o| o.* = std.ascii.toLower(c);
            return map.get(buf[0..word.len]) orelse 0;
        }

        /// The class of keyword number `k` (0: no keyword, any name).
        pub inline fn class(k: u16) Class {
            return classes[k];
        }

        /// Keyword number `k`'s name, in lower case.
        pub fn name(k: u16) []const u8 {
            return names[k - 1];
        }

        /// The number of `kw`.
        pub inline fn id(comptime kw: Kw) u16 {
            return comptime @backingInt(kw);
        }
    };
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
    try testing.expectEqual(K.id(.abort), K.lookup("ABORT"));
    try testing.expectEqual(K.id(.@"and"), K.lookup("And"));
    try testing.expectEqual(@as(u16, 0), K.lookup("selects"));
    try testing.expectEqual(@as(u16, 0), K.lookup(""));
    try testing.expectEqual(@as(u16, 0), K.lookup("sélect"));
    try testing.expectEqual(Class.reserved, K.class(K.id(.from)));
    try testing.expectEqual(Class.unreserved, K.class(0));
    try testing.expectEqualStrings("abort", K.name(K.id(.abort)));
    try testing.expectEqual(@as(usize, 6), K.max_len);
}
