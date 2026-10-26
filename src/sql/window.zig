//! Window functions (port of window.c). This part builds and compares
//! Window objects during parsing; code generation comes later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const walker = @import("walker.zig");
const ctype = @import("../util/ctype.zig");

const Allocator = std.mem.Allocator;
const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Select = int.Select;
const Window = int.Window;
const Token = int.Token;
const Oom = int.Oom;
const EP = int.EP;
const SF = int.SF;
const TK = int.TK;

/// Port of windowFind(): the named window in `list`, or an error.
fn windowFind(p: *Parse, list: ?*Window, name: []const u8) ?*Window {
    var it = list;
    while (it) |w| : (it = w.next_win) {
        if (ctype.eqlNoCase(w.name orelse "", name)) return w;
    }
    util.errorMsg(p, "no such window: {s}", .{name});
    return null;
}

/// Port of sqlite3WindowOffsetExpr(): a PRECEDING/FOLLOWING offset must
/// be constant; anything else becomes NULL (and fails later).
fn offsetExpr(p: *Parse, e: ?*Expr) Oom!?*Expr {
    if (!expr_mod.isConstant(null, e)) return try expr_mod.exprAlloc(p.arena, TK.NULL, null, false);
    return e;
}

/// Port of sqlite3WindowAlloc(): a window frame. `e_type` 0 means the
/// frame was not specified (RANGE by default).
pub fn windowAlloc(
    p: *Parse,
    e_type_arg: i32,
    e_start: i32,
    start: ?*Expr,
    e_end: i32,
    end: ?*Expr,
    e_exclude_arg: u8,
) Oom!?*Window {
    var e_type = e_type_arg;
    var implicit = false;
    if (e_type == 0) {
        implicit = true;
        e_type = TK.RANGE;
    }
    // The start may not come later in UNBOUNDED PRECEDING, <expr>
    // PRECEDING, CURRENT ROW, <expr> FOLLOWING, UNBOUNDED FOLLOWING than
    // the end.
    if ((e_start == TK.CURRENT and e_end == TK.PRECEDING) or
        (e_start == TK.FOLLOWING and (e_end == TK.PRECEDING or e_end == TK.CURRENT)))
    {
        util.errorMsg(p, "unsupported frame specification", .{});
        return null;
    }
    var e_exclude = e_exclude_arg;
    if (e_exclude == 0 and p.db.optDisabled(int.OPT.WindowFunc)) e_exclude = TK.NO;
    const w = try p.arena.create(Window);
    w.* = .{
        .e_frm_type = @intCast(e_type),
        .e_start = @intCast(e_start),
        .e_end = @intCast(e_end),
        .e_exclude = e_exclude,
        .implicit_frame = implicit,
    };
    w.end = try offsetExpr(p, end);
    w.start = try offsetExpr(p, start);
    return w;
}

/// Port of sqlite3WindowAssemble(): attach PARTITION BY, ORDER BY and the
/// base window name.
pub fn windowAssemble(p: *Parse, w_arg: ?*Window, partition: ?*ExprList, order_by: ?*ExprList, base: ?Token) Oom!?*Window {
    const w = w_arg orelse return null;
    w.partition = partition;
    w.order_by = order_by;
    if (base) |b| w.base = try p.arena.dupeSentinel(u8, b.slice(), 0);
    return w;
}

/// Port of sqlite3WindowChain(): resolve "WINDOW w2 AS (w1 ...)" against
/// the earlier definitions in `list`.
pub fn windowChain(p: *Parse, w: *Window, list: ?*Window) Oom!void {
    const base = w.base orelse return;
    const exist = windowFind(p, list, base) orelse return;
    var err: ?[]const u8 = null;
    if (w.partition != null) {
        err = "PARTITION clause";
    } else if (exist.order_by != null and w.order_by != null) {
        err = "ORDER BY clause";
    } else if (!exist.implicit_frame) {
        err = "frame specification";
    }
    if (err) |e| {
        util.errorMsg(p, "cannot override {s} of window: {s}", .{ e, base });
        return;
    }
    w.partition = try expr_mod.listDup(p.arena, exist.partition);
    if (exist.order_by != null) w.order_by = try expr_mod.listDup(p.arena, exist.order_by);
    w.base = null;
}

/// Port of sqlite3WindowAttach(): make `w` the OVER/FILTER of function `e`.
pub fn windowAttach(p: *Parse, e: *Expr, w: *Window) void {
    std.debug.assert(e.op == TK.FUNCTION);
    e.y = .{ .win = w };
    e.set(EP.WinFunc | EP.FullSize);
    w.owner = e;
    if (e.flags & EP.Distinct != 0 and w.e_frm_type != TK.FILTER) {
        util.errorMsg(p, "DISTINCT is not supported for window functions", .{});
    }
}

/// Port of sqlite3WindowLink(): add `w` to the windows a SELECT computes
/// if it can share their scan.
pub fn windowLink(sel: ?*Select, w: *Window) void {
    const s = sel orelse return;
    if (s.win == null or windowCompare(null, s.win.?, w, false) == 0) {
        w.next_win = s.win;
        if (s.win) |first| first.this = &w.next_win;
        s.win = w;
        w.this = &s.win;
    } else if (expr_mod.listCompare(w.partition, s.win.?.partition, -1) != 0) {
        s.sel_flags |= SF.MultiPart;
    }
}

/// Port of sqlite3WindowCompare(): 0 if identical, 1 if different, 2 if
/// unknown. `filter` also compares the FILTER clauses.
pub fn windowCompare(p: ?*const Parse, a: *const Window, b: *const Window, filter: bool) u8 {
    if (a.e_frm_type != b.e_frm_type) return 1;
    if (a.e_start != b.e_start) return 1;
    if (a.e_end != b.e_end) return 1;
    if (a.e_exclude != b.e_exclude) return 1;
    if (expr_mod.compare(p, a.start, b.start, -1) != 0) return 1;
    if (expr_mod.compare(p, a.end, b.end, -1) != 0) return 1;
    var res = expr_mod.listCompare(a.partition, b.partition, -1);
    if (res != 0) return res;
    res = expr_mod.listCompare(a.order_by, b.order_by, -1);
    if (res != 0) return res;
    if (filter) {
        res = expr_mod.compare(p, a.filter, b.filter, -1);
        if (res != 0) return res;
    }
    return 0;
}

/// Port of sqlite3WindowDup().
pub fn windowDup(a: Allocator, owner: ?*Expr, w: *const Window) Oom!*Window {
    const n = try a.create(Window);
    n.* = .{
        .name = try expr_mod.dupZ(a, w.name),
        .base = try expr_mod.dupZ(a, w.base),
        .filter = try expr_mod.exprDup(a, w.filter),
        .w_func = w.w_func,
        .partition = try expr_mod.listDup(a, w.partition),
        .order_by = try expr_mod.listDup(a, w.order_by),
        .e_frm_type = w.e_frm_type,
        .e_end = w.e_end,
        .e_start = w.e_start,
        .e_exclude = w.e_exclude,
        .reg_result = w.reg_result,
        .reg_accum = w.reg_accum,
        .i_arg_col = w.i_arg_col,
        .i_eph_csr = w.i_eph_csr,
        .expr_args = w.expr_args,
        .start = try expr_mod.exprDup(a, w.start),
        .end = try expr_mod.exprDup(a, w.end),
        .owner = owner,
        .implicit_frame = w.implicit_frame,
    };
    return n;
}

/// Port of sqlite3WindowListDup().
pub fn windowListDup(a: Allocator, list: ?*Window) Oom!?*Window {
    var ret: ?*Window = null;
    var pp: *?*Window = &ret;
    var it = list;
    while (it) |w| : (it = w.next_win) {
        const n = try windowDup(a, null, w);
        pp.* = n;
        pp = &n.next_win;
    }
    return ret;
}

fn gatherCallback(w: *walker.Walker, e: *Expr) u8 {
    if (e.op == TK.FUNCTION and e.has(EP.WinFunc)) {
        const win = e.y.win.?;
        std.debug.assert(win.this == null);
        windowLink(w.u.select, win);
    }
    return walker.WRC.Continue;
}

fn gatherSelectCallback(w: *walker.Walker, s: *Select) u8 {
    return if (s == w.u.select) walker.WRC.Continue else walker.WRC.Prune;
}

/// Port of gatherSelectWindows() (expr.c): link the window functions of a
/// freshly copied SELECT into its window list.
pub fn gatherSelectWindows(s: *Select) void {
    var w: walker.Walker = .{
        .expr_callback = gatherCallback,
        .select_callback = gatherSelectCallback,
        .u = .{ .select = s },
    };
    _ = walker.walkSelect(&w, s);
}

/// Port of sqlite3WindowUpdate(): after resolving the window function
/// `func` of `win`, copy a named window's definition into it and coerce
/// the frame the built-in window functions need.
pub fn windowUpdate(p: *Parse, list: ?*Window, win: *Window, func: *int.FuncDef) Oom!void {
    if (win.name != null and win.e_frm_type == 0) {
        const w = windowFind(p, list, win.name.?) orelse return;
        const a = p.arena;
                win.partition = try expr_mod.listDup(a, w.partition);
        win.order_by = try expr_mod.listDup(a, w.order_by);
        win.start = try expr_mod.exprDup(a, w.start);
        win.end = try expr_mod.exprDup(a, w.end);
        win.e_start = w.e_start;
        win.e_end = w.e_end;
        win.e_frm_type = w.e_frm_type;
        win.e_exclude = w.e_exclude;
    } else {
        try windowChain(p, win, list);
    }
    if (win.e_frm_type == TK.RANGE and (win.start != null or win.end != null) and
        (win.order_by == null or win.order_by.?.len() != 1))
    {
        util.errorMsg(p, "RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression", .{});
    } else if (func.func_flags & @import("callback.zig").FUNC.WINDOW != 0) {
        if (win.filter != null) {
            util.errorMsg(p, "FILTER clause may only be used with aggregate window functions", .{});
        } else {
            const Up = struct { name: []const u8, frm: u8, start: u8, end: u8 };
            const ups = [_]Up{
                .{ .name = "row_number", .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = "dense_rank", .frm = TK.RANGE, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = "rank", .frm = TK.RANGE, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = "percent_rank", .frm = TK.GROUPS, .start = TK.CURRENT, .end = TK.UNBOUNDED },
                .{ .name = "cume_dist", .frm = TK.GROUPS, .start = TK.FOLLOWING, .end = TK.UNBOUNDED },
                .{ .name = "ntile", .frm = TK.ROWS, .start = TK.CURRENT, .end = TK.UNBOUNDED },
                .{ .name = "lead", .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.UNBOUNDED },
                .{ .name = "lag", .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.CURRENT },
            };
            for (ups) |u| {
                if (std.mem.eql(u8, func.name, u.name)) {
                    win.start = null;
                    win.end = null;
                    win.e_frm_type = u.frm;
                    win.e_start = u.start;
                    win.e_end = u.end;
                    win.e_exclude = 0;
                    if (win.e_start == TK.FOLLOWING) win.start = try expr_mod.exprInt32(p.arena, 1);
                    break;
                }
            }
        }
    }
    win.w_func = func;
}

/// Port of sqlite3WindowUnlinkFromSelect().
pub fn windowUnlinkFromSelect(w: *Window) void {
    if (w.this) |this| {
        this.* = w.next_win;
        if (w.next_win) |n| n.this = this;
        w.this = null;
    }
}
