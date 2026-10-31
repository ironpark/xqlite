//! Generic parse-tree traversal (port of walker.c).

const int = @import("sqlite_int.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Select = int.Select;
const SrcList = int.SrcList;
const Window = int.Window;
const EP = int.EP;

/// Callback results (WRC_*), numbered as in C. A walk returns Continue
/// or Abort: after a callback's Prune the walk goes on, after an Abort it
/// stops (C: `rc & WRC_Abort`).
pub const WRC = enum(u8) {
    /// Continue down into children.
    Continue = 0,
    /// Omit children but continue with siblings.
    Prune = 1,
    /// Abandon the walk.
    Abort = 2,
};

/// Walker: the callbacks and their context.
pub const Walker = struct {
    parse: ?*Parse = null,
    expr_callback: *const fn (w: *Walker, e: *Expr) WRC,
    select_callback: ?*const fn (w: *Walker, s: *Select) WRC = null,
    select_callback2: ?*const fn (w: *Walker, s: *Select) void = null,
    walker_depth: i32 = 0,
    e_code: u16 = 0,
    m_wflags: u16 = 0,
    /// Callback-specific data: one member per kind of context, as C's
    /// union (a callback reads the member its walk set).
    u: union {
        n: i32,
        i_cur: i32,
        sz: i32,
        src_list: ?*SrcList,
        group_by: ?*ExprList,
        select: ?*Select,
        tab: ?*int.Table,
        ai_col: [*]i32,
        nc: ?*int.NameContext,
        /// pRefSrcList: sqlite3ReferencesSrcList().
        ref_src_list: *@import("expr.zig").RefSrcList,
        /// pIdxCover: sqlite3ExprCoveredByIndex().
        idx_cover: *@import("expr.zig").IdxCover,
        /// pRewrite: selectWindowRewriteEList().
        rewrite: *@import("window.zig").WindowRewrite,
        /// pConst: propagateConstants().
        where_const: *@import("select.zig").WhereConst,
        /// pRename: RENAME COLUMN and RENAME TABLE.
        rename: *@import("alter.zig").RenameCtx,
        /// pCovIdxCk: whereIsCoveringIndex().
        cov_idx_ck: *@import("where/where_loop.zig").CoveringIndexCheck,
        /// pSrcItem: recomputeColumnsUsed().
        src_item: *int.SrcItem,
        /// pFix: sqlite3FixInit().
        fix: *@import("attach.zig").DbFixer,
        /// pCheckOnCtx: sqlite3SelectCheckOnClauses().
        check_on_ctx: *@import("select.zig").CheckOnCtx,
        /// aiCol of sqlite3ExprReferencesUpdatedColumn().
        chng: *const @import("insert.zig").ChngCtx,
    } = .{ .n = 0 },
};

/// Port of walkWindowList().
fn walkWindowList(w: *Walker, list: ?*Window, one_only: bool) WRC {
    var it = list;
    while (it) |win| : (it = win.next_win) {
        if (walkExprList(w, win.order_by) != .Continue) return WRC.Abort;
        if (walkExprList(w, win.partition) != .Continue) return WRC.Abort;
        if (walkExpr(w, win.filter) != .Continue) return WRC.Abort;
        if (walkExpr(w, win.start) != .Continue) return WRC.Abort;
        if (walkExpr(w, win.end) != .Continue) return WRC.Abort;
        if (one_only) break;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkExprNN(): visit `e` and its subtrees, but not
/// subqueries unless a select callback is set.
pub fn walkExprNN(w: *Walker, e_arg: *Expr) WRC {
    var e = e_arg;
    while (true) {
        const rc = w.expr_callback(w, e);
        if (rc != .Continue) return if (rc == .Abort) .Abort else .Continue;
        if (!e.flags.intersects(.{ .TokenOnly = true, .Leaf = true })) {
            if (e.left) |l| if (walkExprNN(w, l) != .Continue) return WRC.Abort;
            if (e.right) |r| {
                e = r;
                continue;
            } else if (e.useXSelect()) {
                if (walkSelect(w, e.x.select) != .Continue) return WRC.Abort;
            } else {
                if (e.x.list) |l| if (walkExprList(w, l) != .Continue) return WRC.Abort;
                if (e.flags.WinFunc) {
                    if (walkWindowList(w, e.y.win, true) != .Continue) return WRC.Abort;
                }
            }
        }
        break;
    }
    return WRC.Continue;
}

pub fn walkExpr(w: *Walker, e: ?*Expr) WRC {
    return if (e) |x| walkExprNN(w, x) else WRC.Continue;
}

pub fn walkExprList(w: *Walker, list: ?*ExprList) WRC {
    const l = list orelse return WRC.Continue;
    for (l.slice()) |item| {
        if (walkExpr(w, item.expr) != .Continue) return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkWinDefnDummyCallback(): a select callback 2 that
/// asks walkSelectExpr to visit window definitions too.
pub fn walkWinDefnDummyCallback(_: *Walker, _: *Select) void {}

/// Port of sqlite3WalkSelectExpr(): visit the expressions of one SELECT
/// (not its FROM clause or compound parts).
pub fn walkSelectExpr(w: *Walker, s: *Select) WRC {
    if (walkExprList(w, s.e_list) != .Continue) return WRC.Abort;
    if (walkExpr(w, s.where) != .Continue) return WRC.Abort;
    if (walkExprList(w, s.group_by) != .Continue) return WRC.Abort;
    if (walkExpr(w, s.having) != .Continue) return WRC.Abort;
    if (walkExprList(w, s.order_by) != .Continue) return WRC.Abort;
    if (walkExpr(w, s.limit) != .Continue) return WRC.Abort;
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
pub fn walkSelectFrom(w: *Walker, s: *Select) WRC {
    const src = s.src orelse return WRC.Continue;
    for (src.slice()) |*item| {
        if (item.fg.is_subquery and walkSelect(w, item.u4.subq.?.select) != .Continue) return WRC.Abort;
        if (item.fg.is_tab_func and walkExprList(w, item.u1.func_arg) != .Continue) return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3WalkSelect(): visit a SELECT, its compound parts,
/// expressions and subqueries. Does nothing without a select callback.
pub fn walkSelect(w: *Walker, s_arg: ?*Select) WRC {
    var s = s_arg orelse return WRC.Continue;
    const cb = w.select_callback orelse return WRC.Continue;
    while (true) {
        const rc = cb(w, s);
        if (rc != .Continue) return if (rc == .Abort) .Abort else .Continue;
        if (walkSelectExpr(w, s) != .Continue or walkSelectFrom(w, s) != .Continue) return WRC.Abort;
        if (w.select_callback2) |cb2| cb2(w, s);
        s = s.prior orelse break;
    }
    return WRC.Continue;
}

pub fn walkerDepthIncrease(w: *Walker, _: *Select) WRC {
    w.walker_depth += 1;
    return WRC.Continue;
}

pub fn walkerDepthDecrease(w: *Walker, _: *Select) void {
    w.walker_depth -= 1;
}

pub fn exprWalkNoop(_: *Walker, _: *Expr) WRC {
    return WRC.Continue;
}

pub fn selectWalkNoop(_: *Walker, _: *Select) WRC {
    return WRC.Continue;
}

/// Port of sqlite3SelectWalkFail(): a select callback that aborts.
pub fn selectWalkFail(w: *Walker, _: *Select) WRC {
    w.e_code = 0;
    return WRC.Abort;
}
