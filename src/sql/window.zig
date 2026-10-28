//! Window functions (port of window.c): the built-in window functions,
//! the Window objects built while parsing, the rewrite of a SELECT with
//! window functions into a query over a subquery, and the code that
//! computes the window functions as that subquery's rows are read.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const walker = @import("walker.zig");
const ctype = @import("../util/ctype.zig");
const build = @import("build.zig");
const select_mod = @import("select.zig");
const ec = @import("expr_code.zig");
const callback = @import("callback.zig");
const numeric = @import("numeric.zig");
const where_mod = @import("where.zig");
const main_mod = @import("main.zig");
const update = @import("update.zig");
const func_mod = @import("func.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const api = @import("../vdbe/api.zig");

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
const OP = vi.OP;
const Aff = int.Aff;
const RC = int.RC;
const OE = int.OE;
const TF = int.TF;
const FUNC = callback.FUNC;
const SrcList = int.SrcList;
const Table = int.Table;
const FuncDef = int.FuncDef;
const Context = vi.Context;
const Mem = vi.Mem;
const Walker = walker.Walker;
const WRC = walker.WRC;

// ================================================ built-in window functions

const aggContext = func_mod.aggContext;

/// row_number(). The frame is coerced to ROWS BETWEEN UNBOUNDED PRECEDING
/// AND CURRENT ROW.
fn rowNumberStepFunc(ctx: *Context, _: []*Mem) void {
    if (aggContext(i64, ctx, true)) |p| p.* += 1;
}

fn rowNumberValueFunc(ctx: *Context) void {
    const p = aggContext(i64, ctx, true);
    api.resultInt64(ctx, if (p) |n| n.* else 0);
}

/// The context of rank(), dense_rank(), percent_rank() and cume_dist()
/// (struct CallCount).
const CallCount = struct {
    n_value: i64,
    n_step: i64,
    n_total: i64,
};

/// dense_rank(). The frame is RANGE BETWEEN UNBOUNDED PRECEDING AND
/// CURRENT ROW.
fn denseRankStepFunc(ctx: *Context, _: []*Mem) void {
    if (aggContext(CallCount, ctx, true)) |p| p.n_step = 1;
}

fn denseRankValueFunc(ctx: *Context) void {
    if (aggContext(CallCount, ctx, true)) |p| {
        if (p.n_step != 0) {
            p.n_value += 1;
            p.n_step = 0;
        }
        api.resultInt64(ctx, p.n_value);
    }
}

/// The context of nth_value() and first_value() in "slow mode", when the
/// EXCLUDE clause is not NO OTHERS (struct NthValueCtx).
const NthValueCtx = struct {
    n_step: i64,
    value: ?*Mem,
};

fn nthValueStepFunc(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(NthValueCtx, ctx, true) orelse return;
    const i_val: i64 = switch (api.valueNumericType(argv[1])) {
        vi.SQLITE_INTEGER => api.valueInt64(argv[1]),
        vi.SQLITE_FLOAT => blk: {
            const f = api.valueDouble(argv[1]);
            if (@as(f64, @floatFromInt(numeric.realToI64(f))) != f) return nthValueError(ctx);
            break :blk @intFromFloat(f);
        },
        else => return nthValueError(ctx),
    };
    if (i_val <= 0) return nthValueError(ctx);
    p.n_step += 1;
    if (i_val == p.n_step) {
        p.value = api.valueDup(argv[0]);
        if (p.value == null) api.resultErrorNomem(ctx);
    }
}

fn nthValueError(ctx: *Context) void {
    api.resultError(ctx, "second argument to nth_value must be a positive integer");
}

fn nthValueFinalizeFunc(ctx: *Context) void {
    const p = aggContext(NthValueCtx, ctx, false) orelse return;
    if (p.value) |val| {
        api.resultValue(ctx, val);
        api.valueFree(val);
        p.value = null;
    }
}

fn firstValueStepFunc(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(NthValueCtx, ctx, true) orelse return;
    if (p.value == null) {
        p.value = api.valueDup(argv[0]);
        if (p.value == null) api.resultErrorNomem(ctx);
    }
}

fn firstValueFinalizeFunc(ctx: *Context) void {
    const p = aggContext(NthValueCtx, ctx, true) orelse return;
    if (p.value) |val| {
        api.resultValue(ctx, val);
        api.valueFree(val);
        p.value = null;
    }
}

/// rank(). The frame is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT
/// ROW.
fn rankStepFunc(ctx: *Context, _: []*Mem) void {
    if (aggContext(CallCount, ctx, true)) |p| {
        p.n_step += 1;
        if (p.n_value == 0) p.n_value = p.n_step;
    }
}

fn rankValueFunc(ctx: *Context) void {
    if (aggContext(CallCount, ctx, true)) |p| {
        api.resultInt64(ctx, p.n_value);
        p.n_value = 0;
    }
}

/// percent_rank(). The frame is GROUPS BETWEEN CURRENT ROW AND UNBOUNDED
/// FOLLOWING.
fn percentRankStepFunc(ctx: *Context, _: []*Mem) void {
    if (aggContext(CallCount, ctx, true)) |p| p.n_total += 1;
}

fn percentRankInvFunc(ctx: *Context, _: []*Mem) void {
    const p = aggContext(CallCount, ctx, true).?;
    p.n_step += 1;
}

fn percentRankValueFunc(ctx: *Context) void {
    if (aggContext(CallCount, ctx, true)) |p| {
        p.n_value = p.n_step;
        if (p.n_total > 1) {
            const r = @as(f64, @floatFromInt(p.n_value)) / @as(f64, @floatFromInt(p.n_total - 1));
            api.resultDouble(ctx, r);
        } else {
            api.resultDouble(ctx, 0.0);
        }
    }
}

/// cume_dist(). The frame is GROUPS BETWEEN 1 FOLLOWING AND UNBOUNDED
/// FOLLOWING.
fn cumeDistStepFunc(ctx: *Context, _: []*Mem) void {
    if (aggContext(CallCount, ctx, true)) |p| p.n_total += 1;
}

fn cumeDistInvFunc(ctx: *Context, _: []*Mem) void {
    const p = aggContext(CallCount, ctx, true).?;
    p.n_step += 1;
}

fn cumeDistValueFunc(ctx: *Context) void {
    if (aggContext(CallCount, ctx, false)) |p| {
        const r = @as(f64, @floatFromInt(p.n_step)) / @as(f64, @floatFromInt(p.n_total));
        api.resultDouble(ctx, r);
    }
}

/// The context of ntile() (struct NtileCtx).
const NtileCtx = struct {
    /// Total rows in the partition.
    n_total: i64,
    /// The argument N of ntile(N).
    n_param: i64,
    /// The current row.
    i_row: i64,
};

/// ntile(). The frame is ROWS BETWEEN CURRENT ROW AND UNBOUNDED
/// FOLLOWING.
fn ntileStepFunc(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(NtileCtx, ctx, true) orelse return;
    if (p.n_total == 0) {
        p.n_param = api.valueInt64(argv[0]);
        if (p.n_param <= 0) api.resultError(ctx, "argument of ntile must be a positive integer");
    }
    p.n_total += 1;
}

fn ntileInvFunc(ctx: *Context, _: []*Mem) void {
    const p = aggContext(NtileCtx, ctx, true).?;
    p.i_row += 1;
}

fn ntileValueFunc(ctx: *Context) void {
    const p = aggContext(NtileCtx, ctx, true) orelse return;
    if (p.n_param <= 0) return;
    // The C code keeps the bucket size in an int.
    const n_size: i64 = @as(i32, @truncate(@divTrunc(p.n_total, p.n_param)));
    if (n_size == 0) {
        api.resultInt64(ctx, p.i_row + 1);
    } else {
        const n_large = p.n_total - p.n_param * n_size;
        const i_small = n_large * (n_size + 1);
        const i_row = p.i_row;
        if (i_row < i_small) {
            api.resultInt64(ctx, 1 + @divTrunc(i_row, n_size + 1));
        } else {
            api.resultInt64(ctx, 1 + n_large + @divTrunc(i_row - i_small, n_size));
        }
    }
}

/// The context of last_value() (struct LastValueCtx).
const LastValueCtx = struct {
    val: ?*Mem,
    n_val: i32,
};

fn lastValueStepFunc(ctx: *Context, argv: []*Mem) void {
    const p = aggContext(LastValueCtx, ctx, true) orelse return;
    api.valueFree(p.val);
    p.val = api.valueDup(argv[0]);
    if (p.val == null) {
        api.resultErrorNomem(ctx);
    } else {
        p.n_val += 1;
    }
}

fn lastValueInvFunc(ctx: *Context, _: []*Mem) void {
    const p = aggContext(LastValueCtx, ctx, true) orelse return;
    p.n_val -= 1;
    if (p.n_val == 0) {
        api.valueFree(p.val);
        p.val = null;
    }
}

fn lastValueValueFunc(ctx: *Context) void {
    const p = aggContext(LastValueCtx, ctx, false) orelse return;
    if (p.val) |val| api.resultValue(ctx, val);
}

fn lastValueFinalizeFunc(ctx: *Context) void {
    const p = aggContext(LastValueCtx, ctx, true) orelse return;
    if (p.val) |val| {
        api.resultValue(ctx, val);
        api.valueFree(val);
        p.val = null;
    }
}

/// The names of the built-in window functions. A FuncDef is one of them
/// if its name is the same pointer (isFunc()), as in the C code.
const row_number_name: [:0]const u8 = "row_number";
const dense_rank_name: [:0]const u8 = "dense_rank";
const rank_name: [:0]const u8 = "rank";
const percent_rank_name: [:0]const u8 = "percent_rank";
const cume_dist_name: [:0]const u8 = "cume_dist";
const ntile_name: [:0]const u8 = "ntile";
const last_value_name: [:0]const u8 = "last_value";
const nth_value_name: [:0]const u8 = "nth_value";
const first_value_name: [:0]const u8 = "first_value";
const lead_name: [:0]const u8 = "lead";
const lag_name: [:0]const u8 = "lag";

/// pFunc->zName==xxxName.
fn isFunc(f: *const FuncDef, name: [:0]const u8) bool {
    return f.name.ptr == name.ptr;
}

/// Placeholders for the methods of the built-in window functions that are
/// coded in-line and never call them.
fn noopStepFunc(_: *Context, _: []*Mem) void {
    unreachable;
}

fn noopValueFunc(_: *Context) void {}

/// WINDOWFUNCALL(): a window function with xStep, xFinal, xValue and
/// xInverse.
fn windowFuncAll(name: [:0]const u8, n_arg: i16, step: FuncDef.StepFn, final: FuncDef.FinalFn, value: FuncDef.FinalFn, inverse: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{ .enc = vi.ENC.UTF8, .BUILTIN = true, .WINDOW = true },
        .x_sfunc = step,
        .x_finalize = final,
        .x_value = value,
        .x_inverse = inverse,
        .name = name,
    };
}

/// WINDOWFUNCNOOP(): a window function coded as bytecode.
fn windowFuncNoop(name: [:0]const u8, n_arg: i16) FuncDef {
    return windowFuncAll(name, n_arg, noopStepFunc, noopValueFunc, noopValueFunc, noopStepFunc);
}

/// WINDOWFUNCX(): xStep and one routine for xFinalize and xValue; xInverse
/// is never called.
fn windowFuncX(name: [:0]const u8, n_arg: i16, step: FuncDef.StepFn, value: FuncDef.FinalFn) FuncDef {
    return windowFuncAll(name, n_arg, step, value, value, noopStepFunc);
}

/// aWindowFuncs[] of sqlite3WindowFunctions(): the built-in window
/// functions that are not also aggregates, in callback.builtins.
pub const funcs = [_]FuncDef{
    windowFuncX(row_number_name, 0, rowNumberStepFunc, rowNumberValueFunc),
    windowFuncX(dense_rank_name, 0, denseRankStepFunc, denseRankValueFunc),
    windowFuncX(rank_name, 0, rankStepFunc, rankValueFunc),
    windowFuncAll(percent_rank_name, 0, percentRankStepFunc, percentRankValueFunc, percentRankValueFunc, percentRankInvFunc),
    windowFuncAll(cume_dist_name, 0, cumeDistStepFunc, cumeDistValueFunc, cumeDistValueFunc, cumeDistInvFunc),
    windowFuncAll(ntile_name, 1, ntileStepFunc, ntileValueFunc, ntileValueFunc, ntileInvFunc),
    windowFuncAll(last_value_name, 1, lastValueStepFunc, lastValueFinalizeFunc, lastValueValueFunc, lastValueInvFunc),
    windowFuncAll(nth_value_name, 2, nthValueStepFunc, nthValueFinalizeFunc, noopValueFunc, noopStepFunc),
    windowFuncAll(first_value_name, 1, firstValueStepFunc, firstValueFinalizeFunc, noopValueFunc, noopStepFunc),
    windowFuncNoop(lead_name, 1),
    windowFuncNoop(lead_name, 2),
    windowFuncNoop(lead_name, 3),
    windowFuncNoop(lag_name, 1),
    windowFuncNoop(lag_name, 2),
    windowFuncNoop(lag_name, 3),
};

// ============================================================ Window objects

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
    if (!expr_mod.isConstant(null, e)) {
        if (p.inRenameObject()) @import("alter.zig").renameExprUnmap(p, e);
        return try expr_mod.exprAlloc(p.arena, TK.NULL, null, false);
    }
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
    e.flags.set(.{ .WinFunc = true, .FullSize = true });
    w.owner = e;
    if (e.flags.Distinct and w.e_frm_type != TK.FILTER) {
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
        s.sel_flags.MultiPart = true;
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

fn gatherCallback(w: *walker.Walker, e: *Expr) WRC {
    if (e.op == TK.FUNCTION and e.flags.WinFunc) {
        const win = e.y.win.?;
        std.debug.assert(win.this == null);
        windowLink(w.u.select, win);
    }
    return walker.WRC.Continue;
}

fn gatherSelectCallback(w: *walker.Walker, s: *Select) WRC {
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
pub fn windowUpdate(p: *Parse, list: ?*Window, win: *Window, func: *const FuncDef) Oom!void {
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
    } else if (func.func_flags.WINDOW) {
        if (win.filter != null) {
            util.errorMsg(p, "FILTER clause may only be used with aggregate window functions", .{});
        } else {
            const Up = struct { name: [:0]const u8, frm: u8, start: u8, end: u8 };
            const ups = [_]Up{
                .{ .name = row_number_name, .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = dense_rank_name, .frm = TK.RANGE, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = rank_name, .frm = TK.RANGE, .start = TK.UNBOUNDED, .end = TK.CURRENT },
                .{ .name = percent_rank_name, .frm = TK.GROUPS, .start = TK.CURRENT, .end = TK.UNBOUNDED },
                .{ .name = cume_dist_name, .frm = TK.GROUPS, .start = TK.FOLLOWING, .end = TK.UNBOUNDED },
                .{ .name = ntile_name, .frm = TK.ROWS, .start = TK.CURRENT, .end = TK.UNBOUNDED },
                .{ .name = lead_name, .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.UNBOUNDED },
                .{ .name = lag_name, .frm = TK.ROWS, .start = TK.UNBOUNDED, .end = TK.CURRENT },
            };
            for (ups) |u| {
                if (isFunc(func, u.name)) {
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

// ================================================================ rewrite

/// The context of selectWindowRewriteExprCb() (struct WindowRewrite).
pub const WindowRewrite = struct {
    win: *Window,
    src: *SrcList,
    sub: ?*ExprList,
    tab: *Table,
    /// The current sub-select, if any.
    sub_select: ?*Select = null,
};

/// Port of selectWindowRewriteExprCb(): move a column, aggregate or
/// window function of another window into the subquery's result list
/// (if not there yet) and read it from the ephemeral table instead.
fn selectWindowRewriteExprCb(w: *Walker, e: *Expr) WRC {
    return rewriteExpr(w, e) catch {
        build.oomFault(w.parse.?);
        return WRC.Abort;
    };
}

fn rewriteExpr(w: *Walker, e: *Expr) Oom!WRC {
    const r = w.u.rewrite;
    const p = w.parse.?;

    // In a scalar sub-select of the SELECT, only columns of the outer
    // SELECT are rewritten; aggregates and window functions belong to the
    // sub-select.
    if (r.sub_select != null) {
        if (e.op != TK.COLUMN) return WRC.Continue;
        for (r.src.slice()) |item| {
            if (e.i_table == item.i_cursor) break;
        } else return WRC.Continue;
    }

    switch (e.op) {
        TK.FUNCTION, TK.IF_NULL_ROW, TK.AGG_FUNCTION, TK.COLUMN => {
            if (e.op == TK.FUNCTION) {
                if (!e.flags.WinFunc) return WRC.Continue;
                var it: ?*Window = r.win;
                while (it) |win| : (it = win.next_win) {
                    if (e.y.win == win) {
                        std.debug.assert(win.owner == e);
                        return WRC.Prune;
                    }
                }
            }
            if (p.db.malloc_failed) return WRC.Abort;
            var i_col: ?usize = null;
            if (r.sub) |sub| {
                for (sub.slice(), 0..) |item, i| {
                    if (expr_mod.compare(null, item.expr, e, -1) == 0) {
                        i_col = i;
                        break;
                    }
                }
            }
            if (i_col == null) {
                const dup = try expr_mod.exprDup(p.arena, e);
                if (dup) |d| if (d.op == TK.AGG_FUNCTION) {
                    d.op = TK.FUNCTION;
                };
                r.sub = try expr_mod.listAppend(p, r.sub, dup);
            }
            if (r.sub) |sub| {
                const f = e.flags.only(.{ .Collate = true, .OuterON = true, .InnerON = true });
                const join = e.w;
                e.* = .{
                    .op = TK.COLUMN,
                    .i_column = @intCast(i_col orelse sub.len() - 1),
                    .i_table = r.win.i_eph_csr,
                    .y = .{ .tab = r.tab },
                    .flags = f,
                };
                if (f.intersects(.{ .OuterON = true, .InnerON = true })) e.w = join;
            }
            if (p.db.malloc_failed) return WRC.Abort;
        },
        else => {},
    }
    return WRC.Continue;
}

/// Port of selectWindowRewriteSelectCb().
fn selectWindowRewriteSelectCb(w: *Walker, s: *Select) WRC {
    const r = w.u.rewrite;
    const save = r.sub_select;
    if (save == s) return WRC.Continue;
    r.sub_select = s;
    _ = walker.walkSelect(w, s);
    r.sub_select = save;
    return WRC.Prune;
}

/// Port of selectWindowRewriteEList(): append each column, aggregate and
/// window function (of a window not in the list `win`) of `e_list` to
/// `sub`, and replace it with a TK_COLUMN reading that column of
/// win.i_eph_csr.
fn selectWindowRewriteEList(p: *Parse, win: *Window, src: *SrcList, e_list: ?*ExprList, tab: *Table, sub: *?*ExprList) void {
    var r: WindowRewrite = .{ .win = win, .src = src, .sub = sub.*, .tab = tab };
    var w: Walker = .{
        .parse = p,
        .expr_callback = selectWindowRewriteExprCb,
        .select_callback = selectWindowRewriteSelectCb,
        .u = .{ .rewrite = &r },
    };
    _ = walker.walkExprList(&w, e_list);
    sub.* = r.sub;
}

/// Port of exprListAppendList(): append a copy of each expression of
/// `append` to `list`. With `int_to_null`, integer literals become NULL
/// (they would be taken as column numbers in an ORDER BY).
fn exprListAppendList(p: *Parse, list_arg: ?*ExprList, append_arg: ?*ExprList, int_to_null: bool) Oom!?*ExprList {
    var list = list_arg;
    const append = append_arg orelse return list;
    const n_init = if (list) |l| l.len() else 0;
    for (append.slice(), 0..) |item, i| {
        const dup = try expr_mod.exprDup(p.arena, item.expr);
        if (int_to_null) {
            if (expr_mod.skipCollateAndLikely(dup)) |sub| {
                if (expr_mod.isInteger(sub, null) != null) {
                    sub.op = TK.NULL;
                    sub.flags.clear(.{ .IntValue = true, .IsTrue = true, .IsFalse = true });
                    sub.u = .{ .token = null };
                }
            }
        }
        const l = try expr_mod.listAppend(p, list, dup);
        l.at(n_init + i).fg.sort_flags = item.fg.sort_flags;
        list = l;
    }
    return list;
}

/// Port of sqlite3WindowExtraAggFuncDepth(): the subquery added by the
/// rewrite is one more level between an aggregate and the query it
/// belongs to.
fn windowExtraAggFuncDepth(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.AGG_FUNCTION and e.op2 >= w.walker_depth) e.op2 += 1;
    return WRC.Continue;
}

/// Port of disallowAggregatesInOrderByCb().
fn disallowAggregatesInOrderByCb(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.AGG_FUNCTION and e.agg_info == null) {
        util.errorMsg(w.parse.?, "misuse of aggregate: {s}()", .{e.token()});
    }
    return WRC.Continue;
}

/// Port of sqlite3WindowRewrite(): if `s` uses window functions, rewrite
/// it to read from a subquery whose rows come in the order the window
/// functions need them, as in "SELECT REWRITING" of window.c. Fails on
/// error (C: nonzero), which is in the Parse.
pub fn windowRewrite(p: *Parse, s: *Select) (Oom || int.ParseError)!void {
    if (s.win == null or s.prior != null or s.sel_flags.WinRewrite or p.inRenameObject()) return;
    const v = build.getVdbe(p) orelse return error.ParseFailed;
    const db = p.db;
    const src = s.src.?;
    const where = s.where;
    const group_by = s.group_by;
    const having = s.having;
    var sublist: ?*ExprList = null;
    const m_win = s.win.?;
    const sel_flags = s.sel_flags;

    const tab = try p.arena.create(Table);
    tab.* = .{ .name = try p.arena.dupeSentinel(u8, "", 0) };
    var w = expr_mod.aggInfoPersistWalker(p);
    _ = walker.walkSelect(&w, s);
    if (!s.sel_flags.Aggregate) {
        w.expr_callback = disallowAggregatesInOrderByCb;
        w.select_callback = null;
        _ = walker.walkExprList(&w, s.order_by);
    }

    s.src = null;
    s.where = null;
    s.group_by = null;
    s.having = null;
    s.sel_flags.Aggregate = false;
    s.sel_flags.WinRewrite = true;

    // The ORDER BY of the subquery is the PARTITION BY and ORDER BY of the
    // window. The ORDER BY of the SELECT is dropped if that makes it
    // redundant.
    var sort = try exprListAppendList(p, null, m_win.partition, true);
    sort = try exprListAppendList(p, sort, m_win.order_by, true);
    if (sort) |so| if (s.order_by) |ob| if (ob.len() <= so.len()) {
        const n_save = so.items.items.len;
        so.items.items.len = ob.len();
        if (expr_mod.listCompare(so, ob, -1) == 0) s.order_by = null;
        so.items.items.len = n_save;
    };

    // The cursor of the ephemeral table buffering rows (and three more
    // opened on it). It is opened later, once its width is known.
    m_win.i_eph_csr = p.n_tab;
    p.n_tab += 4;

    selectWindowRewriteEList(p, m_win, src, s.e_list, tab, &sublist);
    selectWindowRewriteEList(p, m_win, src, s.order_by, tab, &sublist);
    m_win.n_buffer_col = if (sublist) |l| @intCast(l.len()) else 0;

    // The PARTITION BY and ORDER BY expressions, to find the partition and
    // peer boundaries.
    sublist = try exprListAppendList(p, sublist, m_win.partition, false);
    sublist = try exprListAppendList(p, sublist, m_win.order_by, false);

    // The arguments of each window function, and two registers for each:
    // the accumulator and the result.
    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        const args = win.owner.?.x.list;
        if (win.w_func.?.func_flags.SUBTYPE) {
            selectWindowRewriteEList(p, m_win, src, args, tab, &sublist);
            win.i_arg_col = if (sublist) |l| @intCast(l.len()) else 0;
            win.expr_args = true;
        } else {
            win.i_arg_col = if (sublist) |l| @intCast(l.len()) else 0;
            sublist = try exprListAppendList(p, sublist, args, false);
        }
        if (win.filter) |filter| {
            sublist = try expr_mod.listAppend(p, sublist, try expr_mod.exprDup(p.arena, filter));
        }
        p.n_mem += 1;
        win.reg_accum = p.n_mem;
        p.n_mem += 1;
        win.reg_result = p.n_mem;
        _ = aux.addOp2(v, OP.Null, 0, win.reg_accum);
    }

    // "SELECT row_number() OVER () FROM t1" selects nothing from t1: keep
    // the subquery legal with a constant.
    if (sublist == null) sublist = try expr_mod.listAppend(p, null, try expr_mod.exprInt32(p.arena, 0));

    const sub = try select_mod.selectNew(p, sublist, src, where, group_by, having, sort, .{}, null);
    const new_src = (try build.srcListAppend(p, null, null, null)) orelse return error.ParseFailed;
    s.src = new_src;
    const item = new_src.at(0);
    try build.srcItemAttachSubquery(p, item, sub);
    item.fg.is_correlated = true;
    select_mod.srcListAssignCursors(p, new_src);
    sub.sel_flags.set(.{ .Expanded = true, .OrderByReqd = true });
    const tab2 = try select_mod.resultSetOfSelect(p, sub, Aff.none);
    if (sel_flags.Aggregate) sub.sel_flags.Aggregate = true;
    var failed = false;
    if (tab2) |t2| {
        tab.* = t2.*;
        tab.tab_flags.Ephemeral = true;
        item.s_tab = tab;
        var w2: Walker = .{
            .expr_callback = windowExtraAggFuncDepth,
            .select_callback = walker.walkerDepthIncrease,
            .select_callback2 = walker.walkerDepthDecrease,
        };
        _ = walker.walkSelect(&w2, sub);
    } else {
        failed = true;
    }
    if (failed or db.malloc_failed) return error.ParseFailed;
}

// ======================================================== code generation

/// Port of sqlite3WindowCodeInit(): before sqlite3WhereBegin() of the
/// rewritten SELECT, open the ephemeral table and its cursors and set up
/// the registers sqlite3WindowCodeStep() uses.
pub fn windowCodeInit(p: *Parse, s: *Select) void {
    const item0 = s.src.?.at(0);
    std.debug.assert(item0.fg.is_subquery);
    const n_eph_expr: i32 = @intCast(item0.u4.subq.?.select.e_list.?.len());
    const m_win = s.win.?;
    const v = p.vdbe.?;

    _ = aux.addOp2(v, OP.OpenEphemeral, m_win.i_eph_csr, n_eph_expr);
    _ = aux.addOp2(v, OP.OpenDup, m_win.i_eph_csr + 1, m_win.i_eph_csr);
    _ = aux.addOp2(v, OP.OpenDup, m_win.i_eph_csr + 2, m_win.i_eph_csr);
    _ = aux.addOp2(v, OP.OpenDup, m_win.i_eph_csr + 3, m_win.i_eph_csr);

    // Registers for the PARTITION BY values, set to NULL.
    if (m_win.partition) |part| {
        const n_expr: i32 = @intCast(part.len());
        m_win.reg_part = p.n_mem + 1;
        p.n_mem += n_expr;
        _ = aux.addOp3(v, OP.Null, 0, m_win.reg_part, m_win.reg_part + n_expr - 1);
    }

    p.n_mem += 1;
    m_win.reg_one = p.n_mem;
    _ = aux.addOp2(v, OP.Integer, 1, m_win.reg_one);

    if (m_win.e_exclude != 0) {
        p.n_mem += 1;
        m_win.reg_start_rowid = p.n_mem;
        p.n_mem += 1;
        m_win.reg_end_rowid = p.n_mem;
        m_win.csr_app = p.n_tab;
        p.n_tab += 1;
        _ = aux.addOp2(v, OP.Integer, 1, m_win.reg_start_rowid);
        _ = aux.addOp2(v, OP.Integer, 0, m_win.reg_end_rowid);
        _ = aux.addOp2(v, OP.OpenDup, m_win.csr_app, m_win.i_eph_csr);
        return;
    }

    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        const f = win.w_func.?;
        if (f.func_flags.MINMAX and win.e_start != TK.UNBOUNDED) {
            // The in-line min() and max() use an ephemeral table and three
            // registers: reg_app+0 is the argument for MakeRecord, reg_app+1
            // a counter that makes the keys unique, reg_app+2 the record.
            const list = win.owner.?.x.list.?;
            const key_info = select_mod.keyInfoFromExprList(p, list, 0, 0);
            win.csr_app = p.n_tab;
            p.n_tab += 1;
            win.reg_app = p.n_mem + 1;
            p.n_mem += 3;
            if (key_info) |ki| if (f.name[1] == 'i') {
                std.debug.assert(ki.sort_flags[0] == 0);
                ki.sort_flags[0] = int.KeyInfoOrder.desc;
            };
            _ = aux.addOp2(v, OP.OpenEphemeral, win.csr_app, 2);
            if (key_info) |ki| aux.appendP4(v, .{ .keyinfo = ki });
            _ = aux.addOp2(v, OP.Integer, 0, win.reg_app + 1);
        } else if (isFunc(f, nth_value_name) or isFunc(f, first_value_name)) {
            // Two registers for the start and end of the current frame.
            win.reg_app = p.n_mem + 1;
            win.csr_app = p.n_tab;
            p.n_tab += 1;
            p.n_mem += 2;
            _ = aux.addOp2(v, OP.OpenDup, win.csr_app, m_win.i_eph_csr);
        } else if (isFunc(f, lead_name) or isFunc(f, lag_name)) {
            win.csr_app = p.n_tab;
            p.n_tab += 1;
            _ = aux.addOp2(v, OP.OpenDup, win.csr_app, m_win.i_eph_csr);
        }
    }
}

const WINDOW_STARTING_INT = 0;
const WINDOW_ENDING_INT = 1;
const WINDOW_NTH_VALUE_INT = 2;
const WINDOW_STARTING_NUM = 3;
const WINDOW_ENDING_NUM = 4;

/// Port of windowCheckValue(): code a check that the PRECEDING or
/// FOLLOWING offset (or nth_value() argument) in `reg` is a non-negative
/// (positive) integer or number, halting with an error otherwise.
fn windowCheckValue(p: *Parse, reg: i32, e_cond: usize) void {
    const errs = [_][:0]const u8{
        "frame starting offset must be a non-negative integer",
        "frame ending offset must be a non-negative integer",
        "second argument to nth_value must be a positive integer",
        "frame starting offset must be a non-negative number",
        "frame ending offset must be a non-negative number",
    };
    const ops = [_]OP{ OP.Ge, OP.Ge, OP.Gt, OP.Ge, OP.Ge };
    const v = p.vdbe.?;
    const reg_zero = expr_mod.getTempReg(p);
    _ = aux.addOp2(v, OP.Integer, 0, reg_zero);
    if (e_cond >= WINDOW_STARTING_NUM) {
        const reg_string = expr_mod.getTempReg(p);
        _ = aux.addOp4(v, OP.String8, 0, reg_string, 0, .{ .z = "" });
        _ = aux.addOp3(v, OP.Ge, reg_string, aux.currentAddr(v) + 2, reg);
        aux.changeP5(v, Aff.numeric | vi.SQLITE_JUMPIFNULL);
    } else {
        _ = aux.addOp2(v, OP.MustBeInt, reg, aux.currentAddr(v) + 2);
    }
    _ = aux.addOp3(v, ops[e_cond], reg_zero, aux.currentAddr(v) + 2, reg);
    aux.changeP5(v, Aff.numeric);
    main_mod.mayAbort(p);
    _ = aux.addOp2(v, OP.Halt, RC.ERROR, OE.Abort.int());
    aux.appendP4(v, .{ .z = errs[e_cond] });
    expr_mod.releaseTempReg(p, reg_zero);
}

/// Port of windowArgCount().
fn windowArgCount(win: *Window) i32 {
    const list = win.owner.?.x.list;
    return if (list) |l| @intCast(l.len()) else 0;
}

/// A cursor on the ephemeral table and the registers holding the peer
/// values of its row (struct WindowCsrAndReg).
const WindowCsrAndReg = struct {
    csr: i32 = 0,
    reg: i32 = 0,
};

/// The state shared by sqlite3WindowCodeStep() and its helpers (struct
/// WindowCodeArg). `e_delete` is the operation after which a row may be
/// deleted from the ephemeral table (WINDOW_RETURN_ROW, _AGGINVERSE,
/// _AGGSTEP) or 0 for never. `start`, `current` and `end` are the cursors
/// of the next row to call xInverse on, to return, and to call xStep on.
const WindowCodeArg = struct {
    parse: *Parse,
    m_win: *Window,
    v: *vi.Vdbe,
    /// OP_Gosub to this address to return one row.
    addr_gosub: i32,
    /// Register of that OP_Gosub.
    reg_gosub: i32,
    /// First of the argument registers.
    reg_arg: i32 = 0,
    e_delete: i32 = 0,
    reg_rowid: i32 = 0,
    start: WindowCsrAndReg = .{},
    current: WindowCsrAndReg = .{},
    end: WindowCsrAndReg = .{},
};

/// Port of windowReadPeerValues(): read the ORDER BY values of the row of
/// `csr` into the registers from `reg`.
fn windowReadPeerValues(cx: *WindowCodeArg, csr: i32, reg: i32) void {
    const m_win = cx.m_win;
    const order_by = m_win.order_by orelse return;
    const v = cx.v;
    const n_part: i32 = if (m_win.partition) |l| @intCast(l.len()) else 0;
    const i_col_off = m_win.n_buffer_col + n_part;
    var i: i32 = 0;
    while (i < order_by.len()) : (i += 1) {
        _ = aux.addOp3(v, OP.Column, csr, i_col_off + i, reg + i);
    }
}

/// Port of windowAggStep(): call xStep (or xInverse) of each window
/// function of the list `m_win`, or code the in-line equivalent of the
/// built-in ones. The arguments are read from `csr` into the registers
/// from `reg`.
fn windowAggStep(cx: *WindowCodeArg, m_win: *Window, csr: i32, b_inverse: bool, reg: i32) void {
    const p = cx.parse;
    const v = p.vdbe.?;
    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        const func = win.w_func.?;
        var n_arg: i32 = if (win.expr_args) 0 else windowArgCount(win);
        var addr_if: i32 = 0;
        std.debug.assert(!b_inverse or win.e_start != TK.UNBOUNDED);

        var i: i32 = 0;
        while (i < n_arg) : (i += 1) {
            if (i != 1 or !isFunc(func, nth_value_name)) {
                _ = aux.addOp3(v, OP.Column, csr, win.i_arg_col + i, reg + i);
            } else {
                _ = aux.addOp3(v, OP.Column, m_win.i_eph_csr, win.i_arg_col + i, reg + i);
            }
        }
        var reg_arg = reg;

        if (win.filter != null) {
            const reg_tmp = expr_mod.getTempReg(p);
            _ = aux.addOp3(v, OP.Column, csr, win.i_arg_col + n_arg, reg_tmp);
            addr_if = aux.addOp3(v, OP.IfNot, reg_tmp, 0, 1);
            expr_mod.releaseTempReg(p, reg_tmp);
        }

        if (m_win.reg_start_rowid == 0 and func.func_flags.MINMAX and win.e_start != TK.UNBOUNDED) {
            const addr_is_null = aux.addOp1(v, OP.IsNull, reg_arg);
            if (!b_inverse) {
                _ = aux.addOp2(v, OP.AddImm, win.reg_app + 1, 1);
                _ = aux.addOp2(v, OP.SCopy, reg_arg, win.reg_app);
                _ = aux.addOp3(v, OP.MakeRecord, win.reg_app, 2, win.reg_app + 2);
                _ = aux.addOp2(v, OP.IdxInsert, win.csr_app, win.reg_app + 2);
            } else {
                _ = aux.addOp4Int(v, OP.SeekGE, win.csr_app, 0, reg_arg, 1);
                _ = aux.addOp1(v, OP.Delete, win.csr_app);
                aux.jumpHere(v, aux.currentAddr(v) - 2);
            }
            aux.jumpHere(v, addr_is_null);
        } else if (win.reg_app != 0) {
            std.debug.assert(win.filter == null);
            std.debug.assert(isFunc(func, nth_value_name) or isFunc(func, first_value_name));
            _ = aux.addOp2(v, OP.AddImm, win.reg_app + 1 - @intFromBool(b_inverse), 1);
        } else if (func.x_sfunc.? != &noopStepFunc) {
            const list = win.owner.?.x.list;
            if (win.expr_args) {
                var i_op = aux.currentAddr(v);
                n_arg = @intCast(list.?.len());
                reg_arg = expr_mod.getTempRange(p, n_arg);
                _ = ec.codeExprList(p, list.?, reg_arg, 0, 0);
                const i_end = aux.currentAddr(v);
                while (i_op < i_end) : (i_op += 1) {
                    const op = aux.getOp(v, i_op);
                    if (op.opcode == OP.Column and op.p1 == m_win.i_eph_csr) op.p1 = csr;
                }
            }
            if (func.func_flags.NEEDCOLL) {
                std.debug.assert(n_arg > 0);
                const coll = expr_mod.nnCollSeq(p, list.?.at(0).expr);
                _ = aux.addOp4(v, OP.CollSeq, 0, 0, 0, .{ .collseq = coll });
            }
            _ = aux.addOp3(v, if (b_inverse) OP.AggInverse else OP.AggStep, @intFromBool(b_inverse), reg_arg, win.reg_accum);
            aux.appendP4(v, .{ .funcdef = func });
            aux.changeP5(v, @intCast(n_arg));
            if (win.expr_args) expr_mod.releaseTempRange(p, reg_arg, n_arg);
        }

        if (addr_if != 0) aux.jumpHere(v, addr_if);
    }
}

/// The operations of windowCodeOp(), and the values of
/// WindowCodeArg.e_delete.
const WINDOW_RETURN_ROW = 1;
const WINDOW_AGGINVERSE = 2;
const WINDOW_AGGSTEP = 3;

/// Port of windowAggFinal(): call xValue (or xFinalize if `b_fin`) of
/// each window function, or code the in-line equivalent.
fn windowAggFinal(cx: *WindowCodeArg, b_fin: bool) void {
    const p = cx.parse;
    const m_win = cx.m_win;
    const v = p.vdbe.?;
    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        if (m_win.reg_start_rowid == 0 and win.w_func.?.func_flags.MINMAX and win.e_start != TK.UNBOUNDED) {
            _ = aux.addOp2(v, OP.Null, 0, win.reg_result);
            _ = aux.addOp1(v, OP.Last, win.csr_app);
            _ = aux.addOp3(v, OP.Column, win.csr_app, 0, win.reg_result);
            aux.jumpHere(v, aux.currentAddr(v) - 2);
        } else if (win.reg_app != 0) {
            std.debug.assert(m_win.reg_start_rowid == 0);
        } else {
            const n_arg = windowArgCount(win);
            if (b_fin) {
                _ = aux.addOp2(v, OP.AggFinal, win.reg_accum, n_arg);
                aux.appendP4(v, .{ .funcdef = win.w_func.? });
                _ = aux.addOp2(v, OP.Copy, win.reg_accum, win.reg_result);
                _ = aux.addOp2(v, OP.Null, 0, win.reg_accum);
            } else {
                _ = aux.addOp3(v, OP.AggValue, win.reg_accum, n_arg, win.reg_result);
                aux.appendP4(v, .{ .funcdef = win.w_func.? });
            }
        }
    }
}

/// Port of windowFullScan(): compute the window functions of the current
/// row by scanning its whole frame (with an EXCLUDE clause), leaving the
/// results in the Window.reg_result registers.
fn windowFullScan(cx: *WindowCodeArg) void {
    const p = cx.parse;
    const m_win = cx.m_win;
    const v = cx.v;

    const csr = m_win.csr_app;
    const n_peer: i32 = if (m_win.order_by) |l| @intCast(l.len()) else 0;

    const lbl_next = aux.makeLabel(p);
    const lbl_brk = aux.makeLabel(p);

    const reg_c_rowid = expr_mod.getTempReg(p);
    const reg_rowid = expr_mod.getTempReg(p);
    var reg_c_peer: i32 = 0;
    var reg_peer: i32 = 0;
    if (n_peer != 0) {
        reg_c_peer = expr_mod.getTempRange(p, n_peer);
        reg_peer = expr_mod.getTempRange(p, n_peer);
    }

    _ = aux.addOp2(v, OP.Rowid, m_win.i_eph_csr, reg_c_rowid);
    windowReadPeerValues(cx, m_win.i_eph_csr, reg_c_peer);

    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        _ = aux.addOp2(v, OP.Null, 0, win.reg_accum);
    }

    _ = aux.addOp3(v, OP.SeekGE, csr, lbl_brk, m_win.reg_start_rowid);
    const addr_next = aux.currentAddr(v);
    _ = aux.addOp2(v, OP.Rowid, csr, reg_rowid);
    _ = aux.addOp3(v, OP.Gt, m_win.reg_end_rowid, lbl_brk, reg_rowid);

    if (m_win.e_exclude == TK.CURRENT) {
        _ = aux.addOp3(v, OP.Eq, reg_c_rowid, lbl_next, reg_rowid);
    } else if (m_win.e_exclude != TK.NO) {
        var addr_eq: i32 = 0;
        var key_info: ?*vi.KeyInfo = null;
        if (m_win.order_by) |ob| key_info = select_mod.keyInfoFromExprList(p, ob, 0, 0);
        if (m_win.e_exclude == TK.TIES) {
            addr_eq = aux.addOp3(v, OP.Eq, reg_c_rowid, 0, reg_rowid);
        }
        if (key_info) |ki| {
            windowReadPeerValues(cx, csr, reg_peer);
            _ = aux.addOp3(v, OP.Compare, reg_peer, reg_c_peer, n_peer);
            aux.appendP4(v, .{ .keyinfo = ki });
            const addr = aux.currentAddr(v) + 1;
            _ = aux.addOp3(v, OP.Jump, addr, lbl_next, addr);
        } else {
            _ = aux.addOp2(v, OP.Goto, 0, lbl_next);
        }
        if (addr_eq != 0) aux.jumpHere(v, addr_eq);
    }

    windowAggStep(cx, m_win, csr, false, cx.reg_arg);

    aux.resolveLabel(v, lbl_next);
    _ = aux.addOp2(v, OP.Next, csr, addr_next);
    aux.jumpHere(v, addr_next - 1);
    aux.jumpHere(v, addr_next + 1);
    expr_mod.releaseTempReg(p, reg_rowid);
    expr_mod.releaseTempReg(p, reg_c_rowid);
    if (n_peer != 0) {
        expr_mod.releaseTempRange(p, reg_peer, n_peer);
        expr_mod.releaseTempRange(p, reg_c_peer, n_peer);
    }

    windowAggFinal(cx, true);
}

/// Port of windowReturnOneRow(): call the subroutine of select.c that
/// returns the current row of Window.i_eph_csr, after computing the
/// values of nth_value(), first_value(), lag() and lead(), which are
/// coded in-line.
fn windowReturnOneRow(cx: *WindowCodeArg) void {
    const m_win = cx.m_win;
    const v = cx.v;

    if (m_win.reg_start_rowid != 0) {
        windowFullScan(cx);
    } else {
        const p = cx.parse;
        var it: ?*Window = m_win;
        while (it) |win| : (it = win.next_win) {
            const func = win.w_func.?;
            if (isFunc(func, nth_value_name) or isFunc(func, first_value_name)) {
                const csr = win.csr_app;
                const lbl = aux.makeLabel(p);
                const tmp_reg = expr_mod.getTempReg(p);
                _ = aux.addOp2(v, OP.Null, 0, win.reg_result);

                if (isFunc(func, nth_value_name)) {
                    _ = aux.addOp3(v, OP.Column, m_win.i_eph_csr, win.i_arg_col + 1, tmp_reg);
                    windowCheckValue(p, tmp_reg, WINDOW_NTH_VALUE_INT);
                } else {
                    _ = aux.addOp2(v, OP.Integer, 1, tmp_reg);
                }
                _ = aux.addOp3(v, OP.Add, tmp_reg, win.reg_app, tmp_reg);
                _ = aux.addOp3(v, OP.Gt, win.reg_app + 1, lbl, tmp_reg);
                _ = aux.addOp3(v, OP.SeekRowid, csr, 0, tmp_reg);
                _ = aux.addOp3(v, OP.Column, csr, win.i_arg_col, win.reg_result);
                aux.resolveLabel(v, lbl);
                expr_mod.releaseTempReg(p, tmp_reg);
            } else if (isFunc(func, lead_name) or isFunc(func, lag_name)) {
                const n_arg = windowArgCount(win);
                const csr = win.csr_app;
                const lbl = aux.makeLabel(p);
                const tmp_reg = expr_mod.getTempReg(p);
                const i_eph = m_win.i_eph_csr;

                if (n_arg < 3) {
                    _ = aux.addOp2(v, OP.Null, 0, win.reg_result);
                } else {
                    _ = aux.addOp3(v, OP.Column, i_eph, win.i_arg_col + 2, win.reg_result);
                }
                _ = aux.addOp2(v, OP.Rowid, i_eph, tmp_reg);
                if (n_arg < 2) {
                    const val: i32 = if (isFunc(func, lead_name)) 1 else -1;
                    _ = aux.addOp2(v, OP.AddImm, tmp_reg, val);
                } else {
                    const op = if (isFunc(func, lead_name)) OP.Add else OP.Subtract;
                    const tmp_reg2 = expr_mod.getTempReg(p);
                    _ = aux.addOp3(v, OP.Column, i_eph, win.i_arg_col + 1, tmp_reg2);
                    _ = aux.addOp3(v, op, tmp_reg2, tmp_reg, tmp_reg);
                    expr_mod.releaseTempReg(p, tmp_reg2);
                }

                _ = aux.addOp3(v, OP.SeekRowid, csr, lbl, tmp_reg);
                _ = aux.addOp3(v, OP.Column, csr, win.i_arg_col, win.reg_result);
                aux.resolveLabel(v, lbl);
                expr_mod.releaseTempReg(p, tmp_reg);
            }
        }
    }
    _ = aux.addOp2(v, OP.Gosub, cx.reg_gosub, cx.addr_gosub);
}

/// Port of windowInitAccum(): set the accumulator of each window function
/// to NULL, and initialize the state of the in-line built-ins. Returns
/// the first of the registers for function arguments.
fn windowInitAccum(p: *Parse, m_win: *Window) i32 {
    const v = p.vdbe.?;
    var n_arg: i32 = 0;
    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        const func = win.w_func.?;
        std.debug.assert(win.reg_accum != 0);
        _ = aux.addOp2(v, OP.Null, 0, win.reg_accum);
        n_arg = @max(n_arg, windowArgCount(win));
        if (m_win.reg_start_rowid == 0) {
            if (isFunc(func, nth_value_name) or isFunc(func, first_value_name)) {
                _ = aux.addOp2(v, OP.Integer, 0, win.reg_app);
                _ = aux.addOp2(v, OP.Integer, 0, win.reg_app + 1);
            }
            if (func.func_flags.MINMAX and win.csr_app != 0) {
                std.debug.assert(win.e_start != TK.UNBOUNDED);
                _ = aux.addOp1(v, OP.ResetSorter, win.csr_app);
                _ = aux.addOp2(v, OP.Integer, 0, win.reg_app + 1);
            }
        }
    }
    const reg_arg = p.n_mem + 1;
    p.n_mem += n_arg;
    return reg_arg;
}

/// Port of windowCacheFrame(): whether the frame must be kept in the
/// ephemeral table even if no xInverse calls need it.
fn windowCacheFrame(m_win: *Window) bool {
    if (m_win.reg_start_rowid != 0) return true;
    var it: ?*Window = m_win;
    while (it) |win| : (it = win.next_win) {
        const func = win.w_func.?;
        if (isFunc(func, nth_value_name) or isFunc(func, first_value_name) or
            isFunc(func, lead_name) or isFunc(func, lag_name))
        {
            return true;
        }
    }
    return false;
}

/// Port of windowIfNewPeer(): compare the ORDER BY values in the
/// registers from `reg_new` with those from `reg_old`. If they differ,
/// copy the new ones over the old ones and fall through; else jump to
/// `addr`.
fn windowIfNewPeer(p: *Parse, order_by: ?*ExprList, reg_new: i32, reg_old: i32, addr: i32) void {
    const v = p.vdbe.?;
    if (order_by) |ob| {
        const n_val: i32 = @intCast(ob.len());
        const key_info = select_mod.keyInfoFromExprList(p, ob, 0, 0);
        _ = aux.addOp3(v, OP.Compare, reg_old, reg_new, n_val);
        if (key_info) |ki| aux.appendP4(v, .{ .keyinfo = ki });
        _ = aux.addOp3(v, OP.Jump, aux.currentAddr(v) + 1, addr, aux.currentAddr(v) + 1);
        _ = aux.addOp3(v, OP.Copy, reg_new, reg_old, n_val - 1);
    } else {
        _ = aux.addOp2(v, OP.Goto, 0, addr);
    }
}

/// Port of windowCodeRangeTest(): for a RANGE offset frame boundary, code
///
///   if( csr1.peerVal + regVal >= csr2.peerVal ) goto lbl;
///
/// with `op` (OP_Ge, OP_Gt or OP_Le) as the comparison. For a DESC ORDER
/// BY, regVal is subtracted and the comparison reversed. If csr1.peerVal
/// is not a number, it is compared unchanged.
fn windowCodeRangeTest(cx: *WindowCodeArg, op_arg: OP, csr1: i32, reg_val: i32, csr2: i32, lbl: i32) void {
    const p = cx.parse;
    const v = p.vdbe.?;
    const order_by = cx.m_win.order_by.?;
    const reg1 = expr_mod.getTempReg(p);
    const reg2 = expr_mod.getTempReg(p);
    p.n_mem += 1;
    const reg_string = p.n_mem;
    var arith: OP = OP.Add;
    const addr_done = aux.makeLabel(p);
    var op = op_arg;

    // The peer value of each cursor.
    windowReadPeerValues(cx, csr1, reg1);
    windowReadPeerValues(cx, csr2, reg2);

    std.debug.assert(op == OP.Ge or op == OP.Gt or op == OP.Le);
    std.debug.assert(order_by.len() == 1);
    const sort_flags = order_by.at(0).fg.sort_flags;
    if (sort_flags & int.KeyInfoOrder.desc != 0) {
        op = switch (op) {
            OP.Ge => OP.Le,
            OP.Gt => OP.Lt,
            else => OP.Ge,
        };
        arith = OP.Subtract;
    }

    // With NULLS LAST (BIGNULL), NULL is larger than all other values,
    // which OP_Ge and friends do not handle; the cases where reg1 or reg2
    // is NULL are coded separately.
    if (sort_flags & int.KeyInfoOrder.bignull != 0) {
        // reg1 is NULL.
        const addr = aux.addOp1(v, OP.NotNull, reg1);
        switch (op) {
            OP.Ge => _ = aux.addOp2(v, OP.Goto, 0, lbl),
            OP.Gt => _ = aux.addOp2(v, OP.NotNull, reg2, lbl),
            OP.Le => _ = aux.addOp2(v, OP.IsNull, reg2, lbl),
            else => {},
        }
        _ = aux.addOp2(v, OP.Goto, 0, addr_done);

        // reg1 is not NULL but reg2 is.
        aux.jumpHere(v, addr);
        _ = aux.addOp2(v, OP.IsNull, reg2, if (op == OP.Gt or op == OP.Ge) addr_done else lbl);
    }

    // Add (or subtract) regVal to reg1 unless it is not numeric:
    //
    //   if( reg1>='' ) goto addrGe;
    //   reg1 = reg1 +/- regVal
    //   addrGe:
    //
    // as all strings and blobs are >= ''.
    _ = aux.addOp4(v, OP.String8, 0, reg_string, 0, .{ .z = "" });
    const addr_ge = aux.addOp3(v, OP.Ge, reg_string, 0, reg1);
    if ((op == OP.Ge and arith == OP.Add) or (op == OP.Le and arith == OP.Subtract)) {
        _ = aux.addOp3(v, op, reg2, lbl, reg1);
    }
    _ = aux.addOp3(v, arith, reg_val, reg1, reg1);
    aux.jumpHere(v, addr_ge);

    // Compare reg2 with reg1.
    _ = aux.addOp3(v, op, reg2, lbl, reg1);
    const coll = expr_mod.nnCollSeq(p, order_by.at(0).expr);
    aux.appendP4(v, .{ .collseq = coll });
    aux.changeP5(v, vi.SQLITE_NULLEQ);
    aux.resolveLabel(v, addr_done);

    expr_mod.releaseTempReg(p, reg1);
    expr_mod.releaseTempReg(p, reg2);
}

/// Port of windowCodeOp(): code one RETURN_ROW, AGGSTEP or AGGINVERSE
/// operation (see sqlite3WindowCodeStep()). Returns the address of an
/// OP_Goto to patch if `jump_on_eof`, else 0.
fn windowCodeOp(cx: *WindowCodeArg, op: i32, reg_countdown: i32, jump_on_eof: bool) i32 {
    const p = cx.parse;
    const m_win = cx.m_win;
    var ret: i32 = 0;
    const v = cx.v;
    const b_peer = m_win.e_frm_type != TK.ROWS;

    const lbl_done = aux.makeLabel(p);
    var addr_next_range: i32 = 0;

    // AGGINVERSE is a no-op if the frame starts with UNBOUNDED PRECEDING.
    if (op == WINDOW_AGGINVERSE and m_win.e_start == TK.UNBOUNDED) {
        std.debug.assert(reg_countdown == 0 and !jump_on_eof);
        return 0;
    }

    if (reg_countdown > 0) {
        if (m_win.e_frm_type == TK.RANGE) {
            addr_next_range = aux.currentAddr(v);
            std.debug.assert(op == WINDOW_AGGINVERSE or op == WINDOW_AGGSTEP);
            if (op == WINDOW_AGGINVERSE) {
                if (m_win.e_start == TK.FOLLOWING) {
                    windowCodeRangeTest(cx, OP.Le, cx.current.csr, reg_countdown, cx.start.csr, lbl_done);
                } else {
                    windowCodeRangeTest(cx, OP.Ge, cx.start.csr, reg_countdown, cx.current.csr, lbl_done);
                }
            } else {
                windowCodeRangeTest(cx, OP.Gt, cx.end.csr, reg_countdown, cx.current.csr, lbl_done);
            }
        } else {
            _ = aux.addOp3(v, OP.IfPos, reg_countdown, lbl_done, 1);
        }
    }

    if (op == WINDOW_RETURN_ROW and m_win.reg_start_rowid == 0) {
        windowAggFinal(cx, false);
    }
    const addr_continue = aux.currentAddr(v);

    // For (RANGE BETWEEN a FOLLOWING AND b FOLLOWING) or (RANGE BETWEEN b
    // PRECEDING AND a PRECEDING), the start cursor may not pass the end
    // cursor (if a>b), nor the end cursor reach EOF while the input is
    // still finding rows.
    if (m_win.e_start == m_win.e_end and reg_countdown != 0 and m_win.e_frm_type == TK.RANGE) {
        const reg_rowid1 = expr_mod.getTempReg(p);
        const reg_rowid2 = expr_mod.getTempReg(p);
        if (op == WINDOW_AGGINVERSE) {
            _ = aux.addOp2(v, OP.Rowid, cx.start.csr, reg_rowid1);
            _ = aux.addOp2(v, OP.Rowid, cx.end.csr, reg_rowid2);
            _ = aux.addOp3(v, OP.Ge, reg_rowid2, lbl_done, reg_rowid1);
        } else if (cx.reg_rowid != 0) {
            _ = aux.addOp2(v, OP.Rowid, cx.end.csr, reg_rowid1);
            _ = aux.addOp3(v, OP.Ge, cx.reg_rowid, lbl_done, reg_rowid1);
        }
        expr_mod.releaseTempReg(p, reg_rowid1);
        expr_mod.releaseTempReg(p, reg_rowid2);
        std.debug.assert(m_win.e_start == TK.PRECEDING or m_win.e_start == TK.FOLLOWING);
    }

    var csr: i32 = undefined;
    var reg: i32 = undefined;
    switch (op) {
        WINDOW_RETURN_ROW => {
            csr = cx.current.csr;
            reg = cx.current.reg;
            windowReturnOneRow(cx);
        },
        WINDOW_AGGINVERSE => {
            csr = cx.start.csr;
            reg = cx.start.reg;
            if (m_win.reg_start_rowid != 0) {
                std.debug.assert(m_win.reg_end_rowid != 0);
                _ = aux.addOp2(v, OP.AddImm, m_win.reg_start_rowid, 1);
            } else {
                windowAggStep(cx, m_win, csr, true, cx.reg_arg);
            }
        },
        else => {
            std.debug.assert(op == WINDOW_AGGSTEP);
            csr = cx.end.csr;
            reg = cx.end.reg;
            if (m_win.reg_start_rowid != 0) {
                std.debug.assert(m_win.reg_end_rowid != 0);
                _ = aux.addOp2(v, OP.AddImm, m_win.reg_end_rowid, 1);
            } else {
                windowAggStep(cx, m_win, csr, false, cx.reg_arg);
            }
        },
    }

    if (op == cx.e_delete) {
        _ = aux.addOp1(v, OP.Delete, csr);
        aux.changeP5(v, vi.OPFLAG.SAVEPOSITION);
    }

    if (jump_on_eof) {
        _ = aux.addOp2(v, OP.Next, csr, aux.currentAddr(v) + 2);
        ret = aux.addOp0(v, OP.Goto);
    } else {
        _ = aux.addOp2(v, OP.Next, csr, aux.currentAddr(v) + 1 + @as(i32, @intFromBool(b_peer)));
        if (b_peer) _ = aux.addOp2(v, OP.Goto, 0, lbl_done);
    }

    if (b_peer) {
        const n_reg: i32 = if (m_win.order_by) |l| @intCast(l.len()) else 0;
        const reg_tmp = if (n_reg != 0) expr_mod.getTempRange(p, n_reg) else 0;
        windowReadPeerValues(cx, csr, reg_tmp);
        windowIfNewPeer(p, m_win.order_by, reg_tmp, reg, addr_continue);
        expr_mod.releaseTempRange(p, reg_tmp, n_reg);
    }

    if (addr_next_range != 0) _ = aux.addOp2(v, OP.Goto, 0, addr_next_range);
    aux.resolveLabel(v, lbl_done);
    return ret;
}

/// Port of windowExprGtZero(): whether `e` is known when compiling to be
/// greater than zero as an integer.
fn windowExprGtZero(p: *Parse, e: ?*Expr) bool {
    const val = update.valueFromExpr(p.vdbe.?, e, Aff.numeric) catch {
        p.db.oomFault();
        return false;
    };
    return if (val) |m| api.valueInt(m) > 0 else false;
}

/// Port of sqlite3WindowCodeStep(): after sqlite3WhereBegin() of the
/// rewritten SELECT `s`, code the computation of the window functions
/// for each row of the subquery, calling the subroutine at `addr_gosub`
/// to return each output row. Calls sqlite3WhereEnd().
///
/// For "ROWS BETWEEN <expr1> PRECEDING AND <expr2> FOLLOWING" the code is
///
///     ... loop started by sqlite3WhereBegin() ...
///       if( new partition ){
///         Gosub flush
///       }
///       Insert new row into eph table.
///       if( first row of partition ){
///         Rewind(csrEnd); Rewind(csrStart); Rewind(csrCurrent)
///         regEnd = <expr2>
///         regStart = <expr1>
///       }else{
///         AGGSTEP
///         if( (regEnd--)<=0 ){
///           RETURN_ROW
///           if( (regStart--)<=0 ){
///             AGGINVERSE
///           }
///         }
///       }
///     }
///     flush:
///       AGGSTEP
///       while( 1 ){
///         RETURN ROW
///         if( csrCurrent is EOF ) break;
///         if( (regStart--)<=0 ){
///           AggInverse(csrStart)
///           Next(csrStart)
///         }
///       }
///
/// where AGGSTEP calls xStep on the row of csrEnd and advances it,
/// RETURN_ROW returns the row of csrCurrent and advances it, and
/// AGGINVERSE calls xInverse on the row of csrStart and advances it. The
/// other frame types use variants of this; see the comment on
/// sqlite3WindowCodeStep() in window.c.
pub fn windowCodeStep(p: *Parse, s: *Select, w_info: *where_mod.WhereInfo, reg_gosub: i32, addr_gosub: i32) void {
    const m_win = s.win.?;
    const order_by = m_win.order_by;
    const v = p.vdbe.?;
    const item0 = s.src.?.at(0);
    const csr_input = item0.i_cursor;
    const n_input: i32 = @intCast(item0.s_tab.?.cols.len);
    var addr_gosub_flush: i32 = 0;
    var addr_integer: i32 = 0;
    var reg_new_peer: i32 = 0;
    var reg_peer: i32 = 0;
    var reg_flush_part: i32 = 0;
    var reg_start: i32 = 0;
    var reg_end: i32 = 0;

    const lbl_where_end = aux.makeLabel(p);

    var cx: WindowCodeArg = .{
        .parse = p,
        .m_win = m_win,
        .v = v,
        .reg_gosub = reg_gosub,
        .addr_gosub = addr_gosub,
    };
    cx.current.csr = m_win.i_eph_csr;
    const csr_write = cx.current.csr + 1;
    cx.start.csr = cx.current.csr + 2;
    cx.end.csr = cx.current.csr + 3;

    // When rows may be deleted from the ephemeral table: never (0), once
    // out of the frame (AGGINVERSE), once returned (RETURN_ROW), or once
    // in the frame (AGGSTEP).
    switch (m_win.e_start) {
        TK.FOLLOWING => {
            if (m_win.e_frm_type != TK.RANGE and windowExprGtZero(p, m_win.start)) {
                cx.e_delete = WINDOW_RETURN_ROW;
            }
        },
        TK.UNBOUNDED => {
            if (!windowCacheFrame(m_win)) {
                if (m_win.e_end == TK.PRECEDING) {
                    if (m_win.e_frm_type != TK.RANGE and windowExprGtZero(p, m_win.end)) {
                        cx.e_delete = WINDOW_AGGSTEP;
                    }
                } else {
                    cx.e_delete = WINDOW_RETURN_ROW;
                }
            }
        },
        else => cx.e_delete = WINDOW_AGGINVERSE,
    }

    // Registers for the row of the subquery, that row as a record, and its
    // rowid in the ephemeral table.
    const reg_new = p.n_mem + 1;
    p.n_mem += n_input;
    p.n_mem += 1;
    const reg_record = p.n_mem;
    p.n_mem += 1;
    cx.reg_rowid = p.n_mem;

    // Registers for the values of "<expr> PRECEDING" and "<expr>
    // FOLLOWING".
    if (m_win.e_start == TK.PRECEDING or m_win.e_start == TK.FOLLOWING) {
        p.n_mem += 1;
        reg_start = p.n_mem;
    }
    if (m_win.e_end == TK.PRECEDING or m_win.e_end == TK.FOLLOWING) {
        p.n_mem += 1;
        reg_end = p.n_mem;
    }

    // Unless the frame is ROWS, registers for the peer values of the main
    // loop and of each cursor.
    if (m_win.e_frm_type != TK.ROWS) {
        const n_peer: i32 = if (order_by) |l| @intCast(l.len()) else 0;
        reg_new_peer = reg_new + m_win.n_buffer_col;
        if (m_win.partition) |part| reg_new_peer += @intCast(part.len());
        reg_peer = p.n_mem + 1;
        p.n_mem += n_peer;
        cx.start.reg = p.n_mem + 1;
        p.n_mem += n_peer;
        cx.current.reg = p.n_mem + 1;
        p.n_mem += n_peer;
        cx.end.reg = p.n_mem + 1;
        p.n_mem += n_peer;
    }

    // Read the row of the subquery and make it a record.
    var i_input: i32 = 0;
    while (i_input < n_input) : (i_input += 1) {
        _ = aux.addOp3(v, OP.Column, csr_input, i_input, reg_new + i_input);
    }
    _ = aux.addOp3(v, OP.MakeRecord, reg_new, n_input, reg_record);

    // With a PARTITION BY, a new partition calls the flush subroutine (its
    // OP_Gosub is patched later).
    if (m_win.partition) |part| {
        const n_part: i32 = @intCast(part.len());
        const reg_new_part = reg_new + m_win.n_buffer_col;
        const key_info = select_mod.keyInfoFromExprList(p, part, 0, 0);

        p.n_mem += 1;
        reg_flush_part = p.n_mem;
        const addr = aux.addOp3(v, OP.Compare, reg_new_part, m_win.reg_part, n_part);
        if (key_info) |ki| aux.appendP4(v, .{ .keyinfo = ki });
        _ = aux.addOp3(v, OP.Jump, addr + 2, addr + 4, addr + 2);
        addr_gosub_flush = aux.addOp1(v, OP.Gosub, reg_flush_part);
        _ = aux.addOp3(v, OP.Copy, reg_new_part, m_win.reg_part, n_part - 1);
    }

    // Insert the row into the ephemeral table.
    _ = aux.addOp2(v, OP.NewRowid, csr_write, cx.reg_rowid);
    _ = aux.addOp3(v, OP.Insert, csr_write, reg_record, cx.reg_rowid);
    const addr_ne = aux.addOp3(v, OP.Ne, m_win.reg_one, 0, cx.reg_rowid);

    // The first row of each partition.
    cx.reg_arg = windowInitAccum(p, m_win);

    if (reg_start != 0) {
        ec.exprCode(p, m_win.start, reg_start);
        windowCheckValue(p, reg_start, WINDOW_STARTING_INT + @as(usize, if (m_win.e_frm_type == TK.RANGE) 3 else 0));
    }
    if (reg_end != 0) {
        ec.exprCode(p, m_win.end, reg_end);
        windowCheckValue(p, reg_end, WINDOW_ENDING_INT + @as(usize, if (m_win.e_frm_type == TK.RANGE) 3 else 0));
    }

    if (m_win.e_frm_type != TK.RANGE and m_win.e_start == m_win.e_end and reg_start != 0) {
        const op = if (m_win.e_start == TK.FOLLOWING) OP.Ge else OP.Le;
        const addr_ge = aux.addOp3(v, op, reg_start, 0, reg_end);
        windowAggFinal(&cx, false);
        _ = aux.addOp1(v, OP.Rewind, cx.current.csr);
        windowReturnOneRow(&cx);
        _ = aux.addOp1(v, OP.ResetSorter, cx.current.csr);
        _ = aux.addOp2(v, OP.Goto, 0, lbl_where_end);
        aux.jumpHere(v, addr_ge);
    }
    if (m_win.e_start == TK.FOLLOWING and m_win.e_frm_type != TK.RANGE and reg_end != 0) {
        std.debug.assert(m_win.e_end == TK.FOLLOWING);
        _ = aux.addOp3(v, OP.Subtract, reg_start, reg_end, reg_start);
    }

    if (m_win.e_start != TK.UNBOUNDED) _ = aux.addOp1(v, OP.Rewind, cx.start.csr);
    _ = aux.addOp1(v, OP.Rewind, cx.current.csr);
    _ = aux.addOp1(v, OP.Rewind, cx.end.csr);
    if (reg_peer != 0) if (order_by) |ob| {
        const n: i32 = @intCast(ob.len());
        _ = aux.addOp3(v, OP.Copy, reg_new_peer, reg_peer, n - 1);
        _ = aux.addOp3(v, OP.Copy, reg_peer, cx.start.reg, n - 1);
        _ = aux.addOp3(v, OP.Copy, reg_peer, cx.current.reg, n - 1);
        _ = aux.addOp3(v, OP.Copy, reg_peer, cx.end.reg, n - 1);
    };

    _ = aux.addOp2(v, OP.Goto, 0, lbl_where_end);

    aux.jumpHere(v, addr_ne);

    // The second and later rows.
    if (reg_peer != 0) windowIfNewPeer(p, order_by, reg_new_peer, reg_peer, lbl_where_end);
    if (m_win.e_start == TK.FOLLOWING) {
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, 0, false);
        if (m_win.e_end != TK.UNBOUNDED) {
            if (m_win.e_frm_type == TK.RANGE) {
                const lbl = aux.makeLabel(p);
                const addr_next = aux.currentAddr(v);
                windowCodeRangeTest(&cx, OP.Ge, cx.current.csr, reg_end, cx.end.csr, lbl);
                _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
                _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, false);
                _ = aux.addOp2(v, OP.Goto, 0, addr_next);
                aux.resolveLabel(v, lbl);
            } else {
                _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, reg_end, false);
                _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
            }
        }
    } else if (m_win.e_end == TK.PRECEDING) {
        const b_rps = m_win.e_start == TK.PRECEDING and m_win.e_frm_type == TK.RANGE;
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, reg_end, false);
        if (b_rps) _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
        _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, false);
        if (!b_rps) _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
    } else {
        var addr: i32 = 0;
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, 0, false);
        if (m_win.e_end != TK.UNBOUNDED) {
            if (m_win.e_frm_type == TK.RANGE) {
                var lbl: i32 = 0;
                addr = aux.currentAddr(v);
                if (reg_end != 0) {
                    lbl = aux.makeLabel(p);
                    windowCodeRangeTest(&cx, OP.Ge, cx.current.csr, reg_end, cx.end.csr, lbl);
                }
                _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, false);
                _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
                if (reg_end != 0) {
                    _ = aux.addOp2(v, OP.Goto, 0, addr);
                    aux.resolveLabel(v, lbl);
                }
            } else {
                if (reg_end != 0) addr = aux.addOp3(v, OP.IfPos, reg_end, 0, 1);
                _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, false);
                _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
                if (reg_end != 0) aux.jumpHere(v, addr);
            }
        }
    }

    // The end of the main input loop.
    aux.resolveLabel(v, lbl_where_end);
    where_mod.whereEnd(w_info);

    // Fall through to the flush.
    if (m_win.partition != null) {
        addr_integer = aux.addOp2(v, OP.Integer, 0, reg_flush_part);
        aux.jumpHere(v, addr_gosub_flush);
    }

    cx.reg_rowid = 0;
    const addr_empty = aux.addOp1(v, OP.Rewind, csr_write);
    if (m_win.e_end == TK.PRECEDING) {
        const b_rps = m_win.e_start == TK.PRECEDING and m_win.e_frm_type == TK.RANGE;
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, reg_end, false);
        if (b_rps) _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
        _ = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, false);
    } else if (m_win.e_start == TK.FOLLOWING) {
        var addr_start: i32 = undefined;
        var addr_break1: i32 = undefined;
        var addr_break2: i32 = undefined;
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, 0, false);
        if (m_win.e_frm_type == TK.RANGE) {
            addr_start = aux.currentAddr(v);
            addr_break2 = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, true);
            addr_break1 = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, true);
        } else if (m_win.e_end == TK.UNBOUNDED) {
            addr_start = aux.currentAddr(v);
            addr_break1 = windowCodeOp(&cx, WINDOW_RETURN_ROW, reg_start, true);
            addr_break2 = windowCodeOp(&cx, WINDOW_AGGINVERSE, 0, true);
        } else {
            std.debug.assert(m_win.e_end == TK.FOLLOWING);
            // regEnd = regEnd - regStart; regStart = 0.
            _ = aux.addOp3(v, OP.Subtract, reg_start, reg_end, reg_end);
            _ = aux.addOp2(v, OP.Integer, 0, reg_start);

            addr_start = aux.currentAddr(v);
            addr_break1 = windowCodeOp(&cx, WINDOW_RETURN_ROW, reg_end, true);
            addr_break2 = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, true);
        }
        _ = aux.addOp2(v, OP.Goto, 0, addr_start);
        aux.jumpHere(v, addr_break2);
        addr_start = aux.currentAddr(v);
        const addr_break3 = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, true);
        _ = aux.addOp2(v, OP.Goto, 0, addr_start);
        aux.jumpHere(v, addr_break1);
        aux.jumpHere(v, addr_break3);
    } else {
        _ = windowCodeOp(&cx, WINDOW_AGGSTEP, 0, false);
        const addr_start = aux.currentAddr(v);
        const addr_break = windowCodeOp(&cx, WINDOW_RETURN_ROW, 0, true);
        _ = windowCodeOp(&cx, WINDOW_AGGINVERSE, reg_start, false);
        _ = aux.addOp2(v, OP.Goto, 0, addr_start);
        aux.jumpHere(v, addr_break);
    }
    aux.jumpHere(v, addr_empty);

    _ = aux.addOp1(v, OP.ResetSorter, cx.current.csr);
    if (m_win.partition != null) {
        if (m_win.reg_start_rowid != 0) {
            _ = aux.addOp2(v, OP.Integer, 1, m_win.reg_start_rowid);
            _ = aux.addOp2(v, OP.Integer, 0, m_win.reg_end_rowid);
        }
        aux.changeP1(v, addr_integer, aux.currentAddr(v));
        _ = aux.addOp1(v, OP.Return, reg_flush_part);
    }
}
