//! Sets of words (reserved words, type names) the dialects' parsers look
//! tokens up in, built at compile time.

const std = @import("std");
const ctype = @import("xqlite_base").ctype;

pub const Case = enum { lower, upper };

/// A set for tokens that the lexer folds to `case` (PostgreSQL to lower
/// case, Oracle to upper case), matched exactly. A word not in that case
/// could never match, so it does not compile.
pub fn folded(comptime case: Case, comptime words: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(20 * words.len + 1000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, &kvs) |w, *kv| {
        for (w) |c| if (if (case == .lower) std.ascii.isUpper(c) else std.ascii.isLower(c))
            @compileError("word not in " ++ @tagName(case) ++ " case: " ++ w);
        kv.* = .{w};
    }
    return .initComptime(kvs);
}

/// A set for tokens as written, matched without regard to ASCII case
/// (MariaDB, SQL Server).
pub fn noCase(comptime words: []const []const u8) std.StaticStringMapWithEql(void, ctype.eqlNoCase) {
    @setEvalBranchQuota(20 * words.len + 1000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, &kvs) |w, *kv| kv.* = .{w};
    return .initComptime(kvs);
}

test "folded and case-insensitive sets" {
    const lower = comptime folded(.lower, &.{ "select", "from" });
    try std.testing.expect(lower.has("from") and !lower.has("FROM"));
    const any = comptime noCase(&.{"SELECT"});
    try std.testing.expect(any.has("select") and any.has("Select"));
}
