//! SQL normalization (port of sqlite3Normalize() of tokenize.c, built in
//! C with SQLITE_ENABLE_NORMALIZE): sqlite3_normalized_sql(), the text
//! of a statement with its literals replaced by `?`, the lists of IN
//! operators collapsed, keywords upper-cased, identifiers lower-cased
//! and white space and comments dropped. As in C it is computed the
//! first time it is asked for, so other statements pay nothing.

const std = @import("std");
const tokenize = @import("tokenize.zig");
const TK = @import("grammar.zig").TK;
const ctype = @import("../util/ctype.zig");
const util = @import("../sql/util.zig");
const vi = @import("../vdbe/vdbe_int.zig");

const Vdbe = vi.Vdbe;
const Allocator = std.mem.Allocator;

/// Port of sqlite3VdbeAddDblquoteStr(): the resolver turned the
/// double-quoted identifier `z` into a string literal; normalize() shows
/// it as one.
pub fn addDblquoteStr(v: *Vdbe, z: []const u8) void {
    const copy = v.alloc().dupe(u8, z) catch return;
    v.dbl_strs.append(v.alloc(), copy) catch {};
}

/// Port of sqlite3VdbeUsesDoubleQuotedString().
fn usesDoubleQuotedString(v: *const Vdbe, id: []const u8) bool {
    for (v.dbl_strs.items) |s| if (std.mem.eql(u8, s, id)) return true;
    return false;
}

/// Port of addSpaceSeparator().
fn addSpaceSeparator(a: Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len > 0 and ctype.isIdChar(out.items[out.items.len - 1])) try out.append(a, ' ');
}

/// Port of sqlite3_normalized_sql(): the normalized SQL of `v`, kept in
/// the statement; null if it has no SQL or memory runs out.
pub fn normalizedSql(v: *Vdbe) ?[:0]const u8 {
    if (v.norm_sql) |z| return z;
    const sql = v.sql orelse return null;
    v.norm_sql = normalize(v.alloc(), v, sql) catch return null;
    return v.norm_sql;
}

/// Port of sqlite3Normalize().
pub fn normalize(a: Allocator, v: *const Vdbe, sql: [:0]const u8) error{OutOfMemory}![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var token_type: i32 = -1;
    var prev_type: i32 = 0;
    var n_paren: i32 = 0;
    var i_start_in: usize = 0;
    var n_paren_at_in: i32 = 0;
    var i: usize = 0;
    while (sql[i] != 0) {
        if (token_type != TK.SPACE) prev_type = token_type;
        const t = tokenize.getToken(sql[i..].ptr);
        const n = t.len;
        token_type = t.tk;
        if (n == 0) break;
        const tok = sql[i..][0..n];
        defer i += n;
        switch (t.tk) {
            TK.COMMENT, TK.SPACE => {},
            TK.NULL, TK.STRING, TK.INTEGER, TK.FLOAT, TK.VARIABLE, TK.BLOB => {
                if (t.tk == TK.NULL and (prev_type == TK.IS or prev_type == TK.NOT)) {
                    try out.appendSlice(a, " NULL");
                } else {
                    try out.append(a, '?');
                }
            },
            TK.LP => {
                n_paren += 1;
                if (prev_type == TK.IN) {
                    i_start_in = out.items.len;
                    n_paren_at_in = n_paren;
                }
                try out.append(a, '(');
            },
            TK.RP => {
                if (i_start_in > 0 and n_paren == n_paren_at_in) {
                    out.shrinkRetainingCapacity(i_start_in + 1);
                    try out.appendSlice(a, "?,?,?");
                    i_start_in = 0;
                }
                n_paren -= 1;
                try out.append(a, ')');
            },
            TK.ID => {
                i_start_in = 0;
                const j = out.items.len;
                if (ctype.isQuote(tok[0])) {
                    const id_buf = try a.dupeSentinel(u8, tok, 0);
                    defer a.free(id_buf);
                    const id = util.dequote(id_buf);
                    if (tok[0] == '"' and usesDoubleQuotedString(v, id)) {
                        try out.append(a, '?');
                        continue;
                    }
                    const it = tokenize.getToken(id.ptr);
                    if (it.len == id.len and it.tk == TK.ID) {
                        try addSpaceSeparator(a, &out);
                        try out.appendSlice(a, id);
                    } else {
                        // "%w" in double quotes.
                        try out.append(a, '"');
                        for (id) |ch| {
                            if (ch == '"') try out.append(a, '"');
                            try out.append(a, ch);
                        }
                        try out.append(a, '"');
                    }
                } else {
                    try addSpaceSeparator(a, &out);
                    try out.appendSlice(a, tok);
                }
                for (out.items[j..]) |*ch| ch.* = ctype.toLower(ch.*);
            },
            else => {
                if (t.tk == TK.SELECT) i_start_in = 0;
                if (ctype.isIdChar(tok[0])) try addSpaceSeparator(a, &out);
                const j = out.items.len;
                try out.appendSlice(a, tok);
                for (out.items[j..]) |*ch| ch.* = ctype.toUpper(ch.*);
            },
        }
    }
    if (token_type != TK.SEMI) try out.append(a, ';');
    return out.toOwnedSliceSentinel(a, 0);
}

test "normalize" {
    const a = std.testing.allocator;
    var v: Vdbe = undefined;
    v.dbl_strs = .empty;
    // As SQLite 3.54.1 built with SQLITE_ENABLE_NORMALIZE prints them.
    const cases = [_][2][:0]const u8{
        .{ "select a, 'x', 12, 1.5, x'00', ?1 from t where b in (1,2,3) and c is null", "SELECT a,?,?,?,?,?FROM t WHERE b IN(?,?,?)AND c IS NULL;" },
        .{ "SELECT \"Abc\" , [x y] FROM T1 -- c\n /* d */ ;", "SELECT abc,\"x y\"FROM t1;" },
        .{ "insert into t values(null, (select 1),3)", "INSERT INTO t VALUES(?,(SELECT?),?);" },
        .{ "select a from t where a not null and a in (select b from t)", "SELECT a FROM t WHERE a NOT NULL AND a IN(SELECT b FROM t);" },
    };
    for (cases) |cs| {
        const z = try normalize(a, &v, cs[0]);
        defer a.free(z);
        try std.testing.expectEqualStrings(cs[1], z);
    }
}
