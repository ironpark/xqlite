//! SELECT statements (port of select.c). This part builds Select objects
//! during parsing; code generation comes later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Select = int.Select;
const With = int.With;
const Token = int.Token;
const Oom = int.Oom;
const JT = int.JT;
const TK = int.TK;

/// Port of sqlite3SelectNew(). A missing result list means "*"; a
/// missing FROM clause is an empty one.
pub fn selectNew(
    p: *Parse,
    e_list_arg: ?*ExprList,
    src_arg: ?*SrcList,
    where: ?*Expr,
    group_by: ?*ExprList,
    having: ?*Expr,
    order_by: ?*ExprList,
    sel_flags: u32,
    limit: ?*Expr,
) Oom!*Select {
    const s = try p.arena.create(Select);
    const e_list = e_list_arg orelse
        try expr_mod.listAppend(p, null, try expr_mod.expr(p.arena, TK.ASTERISK, null));
    const src = src_arg orelse blk: {
        const l = try p.arena.create(SrcList);
        l.* = .{};
        break :blk l;
    };
    p.n_select += 1;
    s.* = .{
        .e_list = e_list,
        .op = TK.SELECT,
        .sel_flags = sel_flags,
        .sel_id = @intCast(p.n_select),
        .src = src,
        .where = where,
        .group_by = group_by,
        .having = having,
        .order_by = order_by,
        .limit = limit,
    };
    return s;
}

/// Port of findRightmost().
pub fn findRightmost(s_arg: *Select) *Select {
    var s = s_arg;
    while (s.next) |n| s = n;
    return s;
}

/// Port of sqlite3JoinType(): the JT_* mask for the one to three words
/// before JOIN ("LEFT OUTER" etc.). Nonsense combinations that SQLite has
/// always accepted are accepted; the rest are errors.
pub fn joinType(p: *Parse, a: Token, b: ?Token, c: ?Token) i32 {
    const keywords = [_]struct { []const u8, u8 }{
        .{ "natural", JT.NATURAL },
        .{ "left", JT.LEFT | JT.OUTER },
        .{ "outer", JT.OUTER },
        .{ "right", JT.RIGHT | JT.OUTER },
        .{ "full", JT.LEFT | JT.RIGHT | JT.OUTER },
        .{ "inner", JT.INNER },
        .{ "cross", JT.INNER | JT.CROSS },
    };
    var jointype: u8 = 0;
    const all = [3]?Token{ a, b, c };
    for (all) |maybe| {
        const t = maybe orelse break;
        const word = t.slice();
        for (keywords) |k| {
            if (ctype.eqlNoCase(word, k[0])) {
                jointype |= k[1];
                break;
            }
        } else {
            jointype |= JT.ERROR;
            break;
        }
    }
    if (jointype & (JT.INNER | JT.OUTER) == JT.INNER | JT.OUTER or jointype & JT.ERROR != 0 or
        jointype & (JT.OUTER | JT.LEFT | JT.RIGHT) == JT.OUTER)
    {
        const sp1 = if (b == null) "" else " ";
        const sp2 = if (c == null) "" else " ";
        util.errorMsgAt(p, a.z, "unknown join type: {s}{s}{s}{s}{s}", .{
            a.slice(),
            sp1,
            if (b) |t| t.slice() else "",
            sp2,
            if (c) |t| t.slice() else "",
        });
        return JT.INNER;
    }
    return jointype;
}

/// Port of sqlite3SelectOpName(): the operator of a compound, for error
/// messages.
pub fn selectOpName(op: u8) []const u8 {
    return switch (op) {
        TK.ALL => "UNION ALL",
        TK.INTERSECT => "INTERSECT",
        TK.EXCEPT => "EXCEPT",
        else => "UNION",
    };
}

/// Port of sqlite3WithPush(): make `w` the innermost WITH clause in scope.
pub fn withPush(p: *Parse, w_arg: ?*With) ?*With {
    const w = w_arg orelse return null;
    if (p.n_err == 0) {
        std.debug.assert(p.with != w);
        w.outer = p.with;
        p.with = w;
    }
    return w;
}

// ============================================================== codegen

/// Where the results of a SELECT go (SRT_*).
pub const SRT = struct {
    pub const Exists: u8 = 1;
    pub const Discard: u8 = 2;
    pub const DistFifo: u8 = 3;
    pub const DistQueue: u8 = 4;
    pub const Queue: u8 = 5;
    pub const Fifo: u8 = 6;
    pub const Output: u8 = 7;
    pub const Mem: u8 = 8;
    pub const Set: u8 = 9;
    pub const EphemTab: u8 = 10;
    pub const Coroutine: u8 = 11;
    pub const Table: u8 = 12;
    pub const Upfrom: u8 = 13;
};

/// SelectDest.
pub const SelectDest = struct {
    e_dest: u8,
    i_sd_parm: i32 = 0,
    i_sd_parm2: i32 = 0,
    i_sdst: i32 = 0,
    n_sdst: i32 = 0,
    aff_sdst: ?[:0]u8 = null,
    order_by: ?*ExprList = null,
};

/// Port of sqlite3Select(): generate code for a SELECT.
pub fn select(p: *Parse, s: *Select, dest: *SelectDest) void {
    _ = .{ s, dest };
    @import("pending.zig").notYet(p, "SELECT");
}
