//! Sets of words (reserved words, type names) a dialect's parser looks
//! tokens up in, built at compile time.

const std = @import("std");
const sqllex = @import("sql/lexer");

pub const Case = sqllex.Case;

/// A set for tokens that the lexer folds to `case` (PostgreSQL to lower
/// case, Oracle to upper case), matched exactly. A word not in that case
/// could never match, so it does not compile.
pub fn folded(comptime case: Case, comptime list: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(20 * list.len + 1000);
    var kvs: [list.len]struct { []const u8 } = undefined;
    for (list, &kvs) |w, *kv| {
        sqllex.assertFolded(case, w);
        kv.* = .{w};
    }
    return .initComptime(kvs);
}

test "folded sets" {
    const lower = comptime folded(.lower, &.{ "select", "from" });
    try std.testing.expect(lower.has("from") and !lower.has("FROM"));
}
