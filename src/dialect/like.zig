//! xq_like(pattern, s [, escape]) and xq_ilike(): the IR's Like
//! (src/ir/tree.zig) as lowering and rendering write it for every
//! dialect: case-sensitive (xq_ilike: ASCII case-insensitive), `_` one
//! character, `%` any run, `\\` the default escape, '' for none.
//! Engine functions outside the dialect directories, so that a build
//! with any set of dialects (-Ddialects) has them.

const std = @import("std");
const api = @import("../vdbe/api.zig");
const int = @import("../sql/sqlite_int.zig");
const dfunc = @import("func.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const anyNull = dfunc.anyNull;
const text = dfunc.text;

const det: dfunc.Options = .{ .deterministic = true };

/// Hooks.engine_functions of no dialect: dialect.zig adds them.
pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_like", 2, det, likeFunc),
    dfunc.scalar("xq_like", 3, det, likeFunc),
    dfunc.scalar("xq_ilike", 2, det, ilikeFunc),
    dfunc.scalar("xq_ilike", 3, det, ilikeFunc),
};

pub const likeFunc = dfunc.bind(like, .{false});
pub const ilikeFunc = dfunc.bind(like, .{true});

fn like(ctx: *Context, argv: []*Mem, fold: bool) void {
    if (anyNull(argv)) return api.resultNull(ctx);
    const pat = text(ctx, argv[0]) orelse return;
    const s = text(ctx, argv[1]) orelse return;
    var esc: ?u21 = '\\';
    if (argv.len == 3) {
        const e = text(ctx, argv[2]) orelse return;
        if (e.len == 0) {
            esc = null;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(e[0]) catch 1;
            if (n != e.len) return api.resultErrorState(ctx, .of("22025"), "invalid escape string");
            esc = std.unicode.utf8Decode(e) catch e[0];
        }
    }
    const r = likeMatch(pat, s, esc, fold) catch return api.resultErrorState(ctx, .of("22025"), "LIKE pattern must not end with escape character");
    api.resultInt64(ctx, @intFromBool(r));
}

fn nextCp(s: []const u8, i: *usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 1;
    const end = @min(s.len, i.* + n);
    const cp = std.unicode.utf8Decode(s[i.*..end]) catch s[i.*];
    i.* = end;
    return cp;
}

fn foldCp(c: u21, fold: bool) u21 {
    if (fold and c < 128) return std.ascii.toLower(@intCast(c));
    return c;
}

/// PostgreSQL's LIKE: `_` one character, `%` any run, `esc` quotes the
/// next character.
pub fn likeMatch(pat: []const u8, s: []const u8, esc: ?u21, fold: bool) error{TrailingEscape}!bool {
    var pi: usize = 0;
    var si: usize = 0;
    // Backtracking point: the pattern after the last %, and where in s.
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (pi < pat.len) {
            var pj = pi;
            const pc = nextCp(pat, &pj);
            if (pc == '%') {
                star_p = pj;
                star_s = si;
                pi = pj;
                continue;
            }
            if (si < s.len) {
                var sj = si;
                const sc = nextCp(s, &sj);
                var matched = false;
                if (pc == '_') {
                    matched = true;
                } else if (esc != null and pc == esc.?) {
                    if (pj >= pat.len) return error.TrailingEscape;
                    var pk = pj;
                    const lit = nextCp(pat, &pk);
                    if (foldCp(lit, fold) == foldCp(sc, fold)) {
                        matched = true;
                        pj = pk;
                    }
                } else if (foldCp(pc, fold) == foldCp(sc, fold)) {
                    matched = true;
                }
                if (matched) {
                    pi = pj;
                    si = sj;
                    continue;
                }
            } else if (esc != null and pc == esc.? and pj >= pat.len) {
                return error.TrailingEscape;
            }
        } else if (si >= s.len) {
            return true;
        }
        // Mismatch: let the last % take one more character.
        const sp = star_p orelse return false;
        if (star_s >= s.len) return false;
        _ = nextCp(s, &star_s);
        pi = sp;
        si = star_s;
    }
}

test "like matching" {
    const t = std.testing;
    try t.expect(try likeMatch("a%", "abc", '\\', false));
    try t.expect(!try likeMatch("A%", "abc", '\\', false));
    try t.expect(try likeMatch("A%", "abc", '\\', true));
    try t.expect(try likeMatch("_b_", "abc", '\\', false));
    try t.expect(try likeMatch("%c", "abc", '\\', false));
    try t.expect(try likeMatch("%b%", "abc", '\\', false));
    try t.expect(!try likeMatch("%d%", "abc", '\\', false));
    try t.expect(try likeMatch("a\\%", "a%", '\\', false));
    try t.expect(!try likeMatch("a\\%", "ab", '\\', false));
    try t.expect(try likeMatch("a!_", "a_", '!', false));
    try t.expect(try likeMatch("é_", "éx", null, false));
    try t.expect(try likeMatch("%", "", '\\', false));
    try t.expect(try likeMatch("%a%a", "banana", '\\', false));
    try t.expectError(error.TrailingEscape, likeMatch("a\\", "a", '\\', false));
}
