//! sqlite3_complete() and sqlite3_incomplete() (port of complete.c): decide
//! whether SQL text ends with a complete statement, as the shell does to
//! know when to run what it has read.

const std = @import("std");
const ctype = @import("../util/ctype.zig");
const RC = @import("sqlite_int.zig").RC;

// Token types of the state machine.
const tk_semi = 0;
const tk_ws = 1;
const tk_other = 2;
const tk_explain = 3;
const tk_create = 4;
const tk_temp = 5;
const tk_trigger = 6;
const tk_end = 7;

/// State transitions, indexed by [state][token]. States: 0 NOTHING (only
/// white space so far), 1 START (at the end of a statement), 2 NORMAL,
/// 3 EXPLAIN, 4 CREATE, 5 TRIGGER (inside a trigger body, which must end
/// with ";END;"), 6 SEMI (seen the ";" of ";END;"), 7 END (seen ";END").
const trans = [8][8]u8{
    //  SEMI  WS  OTHER  EXPLAIN  CREATE  TEMP  TRIGGER  END
    .{ 1, 0, 2, 3, 4, 2, 2, 2 }, // 0 NOTHING
    .{ 1, 1, 2, 3, 4, 2, 2, 2 }, // 1 START
    .{ 1, 2, 2, 2, 2, 2, 2, 2 }, // 2 NORMAL
    .{ 1, 3, 3, 2, 4, 2, 2, 2 }, // 3 EXPLAIN
    .{ 1, 4, 2, 2, 2, 4, 5, 2 }, // 4 CREATE
    .{ 6, 5, 5, 5, 5, 5, 5, 5 }, // 5 TRIGGER
    .{ 6, 6, 5, 5, 5, 5, 5, 7 }, // 6 SEMI
    .{ 1, 7, 5, 5, 5, 5, 5, 5 }, // 7 END
};

/// What each final state still needs: 1 a semicolon, 2 "END;", 3 ";END;".
const statemap = [8]u8{ 0, 0, 1, 1, 1, 3, 2, 1 };

/// Port of sqlite3_incomplete(): 0 if `sql` (read up to its end or a NUL)
/// is complete, RC.EMPTY if it holds only white space and comments, else
/// a value describing what is missing: bit 0 set; bits 8..15 what the
/// statement must still end with (1 ";", 2 "END;", 3 ";END;"); bits
/// 16..23 the open quote or comment character ('\'', '"', '`', ']', '-'
/// or '/'); the upper 32 bits the count of unmatched "(" (signed).
pub fn incomplete(sql: []const u8) i64 {
    var state: u8 = 0;
    var pending: u8 = 0;
    var n_paren: i32 = 0;
    var i: usize = 0;
    const at = struct {
        fn f(s: []const u8, j: usize) u8 {
            return if (j < s.len) s[j] else 0;
        }
    }.f;

    scan: while (at(sql, i) != 0) {
        var token: u8 = undefined;
        switch (sql[i]) {
            ';' => token = tk_semi,
            ' ', '\r', '\t', '\n', '\x0c' => token = tk_ws,
            '/' => {
                if (at(sql, i + 1) != '*') {
                    token = tk_other;
                } else {
                    i += 2;
                    while (at(sql, i) != 0 and (sql[i] != '*' or at(sql, i + 1) != '/')) i += 1;
                    if (at(sql, i) == 0) {
                        pending = '/';
                        break :scan;
                    }
                    i += 1;
                    token = tk_ws;
                }
            },
            '-' => {
                if (at(sql, i + 1) != '-') {
                    token = tk_other;
                } else {
                    while (at(sql, i) != 0 and sql[i] != '\n') i += 1;
                    if (at(sql, i) == 0) {
                        pending = '-';
                        break :scan;
                    }
                    token = tk_ws;
                }
            },
            '[' => {
                i += 1;
                while (at(sql, i) != 0 and sql[i] != ']') i += 1;
                if (at(sql, i) == 0) {
                    pending = ']';
                    break :scan;
                }
                token = tk_other;
            },
            '`', '"', '\'' => |c| {
                i += 1;
                while (at(sql, i) != 0 and sql[i] != c) i += 1;
                if (at(sql, i) == 0) {
                    pending = c;
                    break :scan;
                }
                token = tk_other;
            },
            '(' => {
                n_paren += 1;
                token = tk_other;
            },
            ')' => {
                n_paren -= 1;
                token = tk_other;
            },
            else => |c| {
                if (ctype.isIdChar(c)) {
                    // Keywords and unquoted identifiers.
                    var n_id: usize = 1;
                    while (ctype.isIdChar(at(sql, i + n_id))) n_id += 1;
                    const word = sql[i..][0..n_id];
                    token = if (ctype.eqlNoCase(word, "create"))
                        tk_create
                    else if (ctype.eqlNoCase(word, "trigger"))
                        tk_trigger
                    else if (ctype.eqlNoCase(word, "temp") or ctype.eqlNoCase(word, "temporary"))
                        tk_temp
                    else if (ctype.eqlNoCase(word, "end"))
                        tk_end
                    else if (ctype.eqlNoCase(word, "explain"))
                        tk_explain
                    else
                        tk_other;
                    i += n_id - 1;
                } else {
                    // Operators and special symbols.
                    token = tk_other;
                }
            },
        }
        state = trans[state][token];
        i += 1;
    }

    if (state == 0 and pending == 0) return RC.EMPTY;
    if (state == 1) n_paren = 0;
    const paren: u64 = @as(u32, @bitCast(n_paren));
    return @bitCast((paren << 32) |
        (@as(u64, pending) << 16) |
        (@as(u64, statemap[state]) << 8) |
        @intFromBool(state > 1 or pending != 0));
}

/// Port of sqlite3_complete(): whether `sql` ends with a complete
/// statement (for CREATE TRIGGER, one ending in ";END;").
pub fn complete(sql: []const u8) bool {
    return incomplete(sql) == 0;
}

test "complete: simple statements" {
    const t = std.testing;
    try t.expect(complete("SELECT 1;"));
    try t.expect(complete("SELECT 1;  \n"));
    try t.expect(complete("SELECT 1; SELECT 2;"));
    try t.expect(!complete("SELECT 1"));
    try t.expect(!complete("SELECT 1; SELECT 2"));
    try t.expect(!complete(""));
    try t.expect(!complete("   \n"));
    try t.expect(complete(";"));
    try t.expect(complete("SELECT 1; -- trailing comment\n"));
    try t.expect(complete("SELECT 1; /* c */"));
    // Stops at a NUL as the C code does.
    try t.expect(complete("SELECT 1;\x00SELECT"));
}

test "complete: quotes and comments hide semicolons" {
    const t = std.testing;
    try t.expect(!complete("SELECT 'a;"));
    try t.expect(complete("SELECT 'a;';"));
    try t.expect(!complete("SELECT \"a;"));
    try t.expect(!complete("SELECT [a;"));
    try t.expect(complete("SELECT [a;];"));
    try t.expect(!complete("SELECT `a;"));
    try t.expect(!complete("SELECT 1 -- ;"));
    try t.expect(!complete("SELECT 1 /* ; "));
    try t.expect(complete("SELECT 1 /* ; */;"));
    try t.expect(complete("SELECT 1 - 2;"));
    try t.expect(complete("SELECT 4 / 2;"));
}

test "complete: CREATE TRIGGER needs ;END;" {
    const t = std.testing;
    const body = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES(new.a);";
    try t.expect(!complete(body));
    try t.expect(!complete(body ++ " END"));
    try t.expect(complete(body ++ " END;"));
    try t.expect(complete(body ++ "\nEND;\n"));
    try t.expect(complete("create temp trigger tr after delete on t begin delete from u; end;"));
    try t.expect(!complete("CREATE TEMPORARY TRIGGER tr BEFORE DELETE ON t BEGIN SELECT 1; SELECT 2;"));
    try t.expect(complete("EXPLAIN CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;"));
    // Not a trigger: a column named "trigger" in a table.
    try t.expect(complete("CREATE TABLE x(trigger);"));
    try t.expect(complete("CREATE TABLE end(a);"));
}

test "incomplete: what is missing" {
    const t = std.testing;
    try t.expectEqual(@as(i64, RC.EMPTY), incomplete(" -- c\n"));
    try t.expectEqual(@as(i64, 0x0101), incomplete("SELECT 1"));
    try t.expectEqual(@as(i64, 0x270101), incomplete("SELECT 'x"));
    try t.expectEqual(@as(i64, (2 << 32) | 0x0101), incomplete("SELECT f((1"));
    try t.expectEqual(@as(i64, 0x0301), incomplete("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1"));
    try t.expectEqual(@as(i64, 0x0201), incomplete("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1;"));
}
