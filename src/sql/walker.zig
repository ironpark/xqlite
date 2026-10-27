//! Generic parse-tree traversal (port of walker.c).

const std = @import("std");
const int = @import("sqlite_int.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Select = int.Select;
const SrcList = int.SrcList;
const Window = int.Window;
const EP = int.EP;

/// Callback results (WRC_*).
pub const WRC = struct {
    /// Continue down into children.
    pub const Continue: u8 = 0;
    /// Omit children but continue with siblings.
    pub const Prune: u8 = 1;
    /// Abandon the walk.
    pub const Abort: u8 = 2;
};

/// Walker: the callbacks and their context.
pub const Walker = struct {
    parse: ?*Parse = null,
    expr_callback: *const fn (w: *Walker, e: *Expr) u8,
    select_callback: ?*const fn (w: *Walker, s: *Select) u8 = null,
    select_callback2: ?*const fn (w: *Walker, s: *Select) void = null,
    walker_depth: i32 = 0,
    e_code: u16 = 0,
    m_wflags: u16 = 0,
    /// Callback-specific data.
    u: union {
        n: i32,
        i_cur: i32,
        sz: i32,
        src_list: ?*SrcList,
        group_by: ?*ExprList,
        select: ?*Select,
        tab: ?*int.Table,
        ai_col: [*]i32,
        ptr: ?*anyopaque,
        nc: ?*int.NameContext,
    } = .{ .n = 0 },
};

/// Port of walkWindowList().
fn walkWindowList(w: *Walker, list: ?*Window, one_only: bool) u8 {
    var it = list;
    while (it) |win| : (it = win.next_win) {
        if (walkExprList(w, win.order_by) != 0) return WRC.Abort;
        if (walkExprList(w, win.partition) != 0) return WRC.Abort;
        if (walkExpr(w, win.filter) != 0) return WRC.Abort;
        if (walkExpr(w, win.start) != 0) return WRC.Abort;
        if (walkExpr(w, win.end) != 0) return WRC.Abort;
        if (one_only) break;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkExprNN(): visit `e` and its subtrees, but not
/// subqueries unless a select callback is set.
pub fn walkExprNN(w: *Walker, e_arg: *Expr) u8 {
    var e = e_arg;
    while (true) {
        const rc = w.expr_callback(w, e);
        if (rc != 0) return rc & WRC.Abort;
        if (!e.has(EP.TokenOnly | EP.Leaf)) {
            if (e.left) |l| if (walkExprNN(w, l) != 0) return WRC.Abort;
            if (e.right) |r| {
                e = r;
                continue;
            } else if (e.useXSelect()) {
                if (walkSelect(w, e.x.select) != 0) return WRC.Abort;
            } else {
                if (e.x.list) |l| if (walkExprList(w, l) != 0) return WRC.Abort;
                if (e.has(EP.WinFunc)) {
                    if (walkWindowList(w, e.y.win, true) != 0) return WRC.Abort;
                }
            }
        }
        break;
    }
    return WRC.Continue;
}

pub fn walkExpr(w: *Walker, e: ?*Expr) u8 {
    return if (e) |x| walkExprNN(w, x) else WRC.Continue;
}

pub fn walkExprList(w: *Walker, list: ?*ExprList) u8 {
    const l = list orelse return WRC.Continue;
    for (l.slice()) |item| {
        if (walkExpr(w, item.expr) != 0) return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkWinDefnDummyCallback(): a select callback 2 that
/// asks walkSelectExpr to visit window definitions too.
pub fn walkWinDefnDummyCallback(_: *Walker, _: *Select) void {}

/// Port of sqlite3WalkSelectExpr(): visit the expressions of one SELECT
/// (not its FROM clause or compound parts).
pub fn walkSelectExpr(w: *Walker, s: *Select) u8 {
    if (walkExprList(w, s.e_list) != 0) return WRC.Abort;
    if (walkExpr(w, s.where) != 0) return WRC.Abort;
    if (walkExprList(w, s.group_by) != 0) return WRC.Abort;
    if (walkExpr(w, s.having) != 0) return WRC.Abort;
    if (walkExprList(w, s.order_by) != 0) return WRC.Abort;
    if (walkExpr(w, s.limit) != 0) return WRC.Abort;
    if (s.win_defn) |defn| {
        const in_rename = if (w.parse) |p| p.inRenameObject() else false;
        if (w.select_callback2 == walkWinDefnDummyCallback or in_rename or
            w.select_callback2 == @as(?*const fn (*Walker, *Select) void, @import("select.zig").selectPopWith))
        {
            return walkWindowList(w, defn, false);
        }
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkSelectFrom(): visit the subqueries and table-valued
/// function arguments of a FROM clause.
pub fn walkSelectFrom(w: *Walker, s: *Select) u8 {
    const src = s.src orelse return WRC.Continue;
    for (src.slice()) |*item| {
        if (item.fg.is_subquery and walkSelect(w, item.u4.subq.?.select) != 0) return WRC.Abort;
        if (item.fg.is_tab_func and walkExprList(w, item.u1.func_arg) != 0) return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkSelect(): visit a SELECT, its compound parts,
/// expressions and subqueries. Does nothing without a select callback.
pub fn walkSelect(w: *Walker, s_arg: ?*Select) u8 {
    var s = s_arg orelse return WRC.Continue;
    const cb = w.select_callback orelse return WRC.Continue;
    while (true) {
        const rc = cb(w, s);
        if (rc != 0) return rc & WRC.Abort;
        if (walkSelectExpr(w, s) != 0 or walkSelectFrom(w, s) != 0) return WRC.Abort;
        if (w.select_callback2) |cb2| cb2(w, s);
        s = s.prior orelse break;
    }
    return WRC.Continue;
}

pub fn walkerDepthIncrease(w: *Walker, _: *Select) u8 {
    w.walker_depth += 1;
    return WRC.Continue;
}

pub fn walkerDepthDecrease(w: *Walker, _: *Select) void {
    w.walker_depth -= 1;
}

pub fn exprWalkNoop(_: *Walker, _: *Expr) u8 {
    return WRC.Continue;
}

pub fn selectWalkNoop(_: *Walker, _: *Select) u8 {
    return WRC.Continue;
}

/// Port of sqlite3SelectWalkFail(): a select callback that aborts.
pub fn selectWalkFail(w: *Walker, _: *Select) u8 {
    w.e_code = 0;
    return WRC.Abort;
}
