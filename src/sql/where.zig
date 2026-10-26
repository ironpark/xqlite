//! The WHERE-clause loop generator (a reduced port of where.c and
//! wherecode.c). Every FROM-clause term is scanned in full, in the order
//! written; each conjunct of the WHERE clause is tested in the innermost
//! loop it depends on. Index lookups, the cost-based planner, ORDER BY and
//! DISTINCT elimination, and RIGHT JOIN come later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const build = @import("build.zig");
const ec = @import("expr_code.zig");
const walker = @import("walker.zig");
const prepare = @import("prepare.zig");
const insert = @import("insert.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Select = int.Select;
const LogEst = int.LogEst;
const OP = vi.OP;
const EP = int.EP;
const JT = int.JT;
const TK = int.TK;
const TF = int.TF;
const WRC = walker.WRC;

/// One conjunct of the WHERE clause (a reduced WhereTerm).
const Term = struct {
    expr: *Expr,
    /// The loop the term is tested in; -1 for before all loops.
    level: i32,
    coded: bool = false,
};

/// One nested loop (a reduced WhereLevel).
const Level = struct {
    /// Jump here to start the next row of this loop.
    addr_cont: i32,
    /// Jump here to leave this loop.
    addr_brk: i32,
    /// The instruction looping back (OP_Next or OP_Goto) and its operands.
    op: u8 = OP.Noop,
    p1: i32 = 0,
    p2: i32 = 0,
    /// The first instruction of the loop body.
    addr_body: i32 = 0,
    /// LEFT JOIN: the "matched a row" flag, and the code that runs the
    /// body again for the NULL row.
    i_left_join: i32 = 0,
    addr_first: i32 = 0,
};

/// The state between whereBegin() and whereEnd() (WhereInfo).
pub const WhereInfo = struct {
    parse: *Parse,
    tab_list: *SrcList,
    order_by: ?*ExprList,
    i_break: i32,
    i_continue: i32,
    n_row_out: LogEst,
    levels: []Level,
};

/// Walker state of termLevel(): the deepest FROM-clause term referenced.
const LevelCtx = struct {
    tab_list: *SrcList,
    max: i32 = -1,
};

fn levelOfCursor(tab_list: *SrcList, i_cur: i32) i32 {
    for (tab_list.slice(), 0..) |item, i| {
        if (item.i_cursor == i_cur) return @intCast(i);
    }
    return -1;
}

fn termLevelExpr(w: *walker.Walker, e: *Expr) u8 {
    const ctx: *LevelCtx = @ptrCast(@alignCast(w.u.ptr.?));
    if (e.op == TK.COLUMN or e.op == TK.AGG_COLUMN or e.op == TK.IF_NULL_ROW) {
        ctx.max = @max(ctx.max, levelOfCursor(ctx.tab_list, e.i_table));
    }
    return WRC.Continue;
}

/// The loop term `e` must be tested in: the deepest table it uses, and
/// for the ON clause of an OUTER JOIN no earlier than the join.
fn termLevel(tab_list: *SrcList, e: *Expr) i32 {
    var ctx: LevelCtx = .{ .tab_list = tab_list };
    var w: walker.Walker = .{
        .expr_callback = termLevelExpr,
        .select_callback = walker.selectWalkNoop,
        .u = .{ .ptr = &ctx },
    };
    _ = walker.walkExpr(&w, e);
    if (e.has(EP.OuterON)) ctx.max = @max(ctx.max, levelOfCursor(tab_list, e.w.join));
    return ctx.max;
}

/// Split the WHERE clause into its AND-connected terms.
fn splitTerms(p: *Parse, tab_list: *SrcList, e_arg: ?*Expr, out: *std.ArrayList(Term)) int.Oom!void {
    const e = e_arg orelse return;
    if (e.op == TK.AND) {
        try splitTerms(p, tab_list, e.left, out);
        try splitTerms(p, tab_list, e.right, out);
        return;
    }
    try out.append(p.arena, .{ .expr = e, .level = termLevel(tab_list, e) });
}

/// Code the terms of loop `level`. With `deferred`, the terms that a LEFT
/// JOIN tests after its match flag is set (all but its ON clause).
fn codeTerms(p: *Parse, terms: []Term, level: i32, addr_cont: i32, left_join: bool, deferred: bool) void {
    for (terms) |*t| {
        if (t.coded or t.level != level) continue;
        if (left_join and !deferred and !t.expr.has(EP.OuterON)) continue;
        ec.exprIfFalse(p, t.expr, addr_cont, vi.SQLITE_JUMPIFNULL);
        t.coded = true;
    }
}

/// Port of sqlite3WhereBegin(): open the loops over `tab_list` that
/// visit the rows satisfying `where`. The caller codes the body, then
/// calls whereEnd().
pub fn whereBegin(
    p: *Parse,
    tab_list: *SrcList,
    where: ?*Expr,
    order_by: ?*ExprList,
    result_set: ?*ExprList,
    sel: ?*Select,
    wctrl_flags: u16,
    i_aux_arg: i32,
) ?*WhereInfo {
    _ = result_set;
    _ = sel;
    _ = wctrl_flags;
    _ = i_aux_arg;
    return whereBeginImpl(p, tab_list, where, order_by) catch {
        build.oomFault(p);
        return null;
    };
}

fn whereBeginImpl(p: *Parse, tab_list: *SrcList, where: ?*Expr, order_by: ?*ExprList) int.Oom!?*WhereInfo {
    const db = p.db;
    const v = build.getVdbe(p) orelse return null;
    if (tab_list.len() > int.bms) {
        @import("util.zig").errorMsg(p, "at most {d} tables in a join", .{int.bms});
        return null;
    }
    const w = try p.arena.create(WhereInfo);
    const i_break = aux.makeLabel(p);
    w.* = .{
        .parse = p,
        .tab_list = tab_list,
        .order_by = order_by,
        .i_break = i_break,
        .i_continue = i_break,
        .n_row_out = 0,
        .levels = try p.arena.alloc(Level, tab_list.len()),
    };

    var terms: std.ArrayList(Term) = .empty;
    try splitTerms(p, tab_list, where, &terms);

    // Terms that depend on no table of the loop are tested once, first.
    for (terms.items) |*t| {
        if (t.level >= 0) continue;
        ec.exprIfFalse(p, t.expr, i_break, vi.SQLITE_JUMPIFNULL);
        t.coded = true;
    }

    // Open the cursors.
    for (tab_list.slice()) |*item| {
        const t = item.s_tab.?;
        if (t.e_tab_type == .vtab) {
            pending.notYet(p, "virtual tables");
            return null;
        }
        if (t.tab_flags & TF.Ephemeral != 0 or t.isView()) continue;
        const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
        build.codeVerifySchema(p, i_db);
        insert.openTable(p, item.i_cursor, i_db, t, OP.OpenRead);
    }

    // The loops, outermost first.
    var n_row: i32 = 0;
    for (tab_list.slice(), w.levels, 0..) |*item, *lvl, ii| {
        if (p.n_err != 0) return null;
        if (item.fg.jointype & JT.RIGHT != 0) {
            pending.notYet(p, "RIGHT and FULL OUTER JOIN");
            return null;
        }
        lvl.* = .{ .addr_cont = aux.makeLabel(p), .addr_brk = aux.makeLabel(p) };
        if (item.fg.is_materialized) {
            const subq = item.u4.subq.?;
            const i_once = if (!item.fg.is_correlated) aux.addOp0(v, OP.Once) else 0;
            _ = aux.addOp2(v, OP.Gosub, subq.reg_return, subq.addr_fill_sub);
            if (i_once != 0) aux.jumpHere(v, i_once);
        }
        lvl.addr_body = aux.currentAddr(v);
        const left_join = item.fg.jointype & JT.LEFT != 0;
        if (left_join) {
            p.n_mem += 1;
            lvl.i_left_join = p.n_mem;
            _ = aux.addOp2(v, OP.Integer, 0, lvl.i_left_join);
        }
        if (item.fg.via_coroutine) {
            const subq = item.u4.subq.?;
            _ = aux.addOp3(v, OP.InitCoroutine, subq.reg_return, 0, subq.addr_fill_sub);
            lvl.p2 = aux.addOp2(v, OP.Yield, subq.reg_return, lvl.addr_brk);
            lvl.op = OP.Goto;
        } else if (item.fg.is_recursive) {
            // The single row of a recursive CTE's pseudo-cursor: no Rewind
            // or Next.
            lvl.op = OP.Noop;
        } else {
            lvl.p1 = item.i_cursor;
            lvl.p2 = 1 + aux.addOp2(v, OP.Rewind, item.i_cursor, lvl.addr_brk);
            lvl.op = OP.Next;
        }
        n_row += item.s_tab.?.n_row_log_est;

        const level: i32 = @intCast(ii);
        codeTerms(p, terms.items, level, lvl.addr_cont, left_join, false);
        if (left_join) {
            lvl.addr_first = aux.currentAddr(v);
            _ = aux.addOp2(v, OP.Integer, 1, lvl.i_left_join);
            codeTerms(p, terms.items, level, lvl.addr_cont, left_join, true);
        }
        w.i_continue = lvl.addr_cont;
    }
    w.n_row_out = @intCast(std.math.clamp(n_row, std.math.minInt(LogEst), std.math.maxInt(LogEst)));
    return w;
}

/// Port of sqlite3WhereEnd(): close the loops opened by whereBegin().
pub fn whereEnd(w: *WhereInfo) void {
    const p = w.parse;
    const v = p.vdbe.?;
    var i = w.levels.len;
    while (i > 0) {
        i -= 1;
        const lvl = &w.levels[i];
        const item = w.tab_list.at(i);
        aux.resolveLabel(v, lvl.addr_cont);
        if (lvl.op != OP.Noop) _ = aux.addOp2(v, lvl.op, lvl.p1, lvl.p2);
        aux.resolveLabel(v, lvl.addr_brk);
        if (lvl.i_left_join != 0) {
            // No row matched: run the body once more for a row of NULLs.
            const addr = aux.addOp1(v, OP.IfPos, lvl.i_left_join);
            if (item.fg.via_coroutine) {
                const n = item.u4.subq.?.reg_result;
                const m: i32 = @intCast(item.s_tab.?.cols.len);
                _ = aux.addOp3(v, OP.Null, 0, n, n + m - 1);
            }
            _ = aux.addOp1(v, OP.NullRow, item.i_cursor);
            _ = aux.goto_(v, lvl.addr_first);
            aux.jumpHere(v, addr);
        }
    }
    aux.resolveLabel(v, w.i_break);

    // The columns of a co-routine are read from its result registers.
    for (w.levels, 0..) |lvl, ii| {
        const item = w.tab_list.at(ii);
        if (item.fg.via_coroutine) translateColumnToCopy(p, lvl.addr_body, item.i_cursor, item.u4.subq.?.reg_result);
    }
}

/// Port of translateColumnToCopy(): OP_Column on cursor `i_tab_cur` from
/// `i_start` on becomes OP_Copy from the registers at `i_register`;
/// OP_Rowid becomes OP_Null.
fn translateColumnToCopy(p: *Parse, i_start: i32, i_tab_cur: i32, i_register: i32) void {
    const v = p.vdbe.?;
    if (p.db.malloc_failed) return;
    var addr = i_start;
    const end = aux.currentAddr(v);
    while (addr < end) : (addr += 1) {
        const op = aux.getOp(v, addr);
        if (op.p1 != i_tab_cur) continue;
        if (op.opcode == OP.Column) {
            op.opcode = OP.Copy;
            op.p1 = op.p2 + i_register;
            op.p2 = op.p3;
            op.p3 = 0;
            op.p5 = 2;
        } else if (op.opcode == OP.Rowid) {
            op.opcode = OP.Null;
            op.p1 = 0;
            op.p3 = 0;
        }
    }
}

/// sqlite3WhereContinueLabel(): jump here to go to the next row.
pub fn continueLabel(w: *WhereInfo) i32 {
    return w.i_continue;
}

/// sqlite3WhereBreakLabel(): jump here to end the loops.
pub fn breakLabel(w: *WhereInfo) i32 {
    return w.i_break;
}

/// sqlite3WhereIsOrdered(): how many ORDER BY terms the loops deliver in
/// order. Only a loop over no tables is ordered.
pub fn isOrdered(w: *WhereInfo) i32 {
    if (w.tab_list.len() == 0) if (w.order_by) |ob| return @intCast(ob.len());
    return 0;
}

/// sqlite3WhereIsSorted().
pub fn isSorted(w: *WhereInfo) bool {
    _ = w;
    return false;
}

/// sqlite3WhereIsDistinct(): DISTINCT is never satisfied by the loops.
pub fn isDistinct(w: *WhereInfo) u8 {
    _ = w;
    return int.WHERE_DISTINCT_NOOP;
}

/// sqlite3WhereOutputRowCount(): the estimated number of output rows.
pub fn outputRowCount(w: *WhereInfo) LogEst {
    return w.n_row_out;
}

/// sqlite3WhereOrderByLimitOptLabel().
pub fn orderByLimitOptLabel(w: *WhereInfo) i32 {
    return w.i_continue;
}

/// sqlite3WhereMinMaxOptEarlyOut(): nothing to do without the min/max
/// optimization.
pub fn minMaxOptEarlyOut(v: *vi.Vdbe, w: *WhereInfo) void {
    _ = v;
    _ = w;
}

/// ONEPASS_*: how a DELETE or UPDATE visits its rows.
pub const ONEPASS_OFF: u8 = 0;
pub const ONEPASS_SINGLE: u8 = 1;
pub const ONEPASS_MULTI: u8 = 2;

/// sqlite3WhereOkOnePass(): whether the loop visits at most one row (or
/// can delete while it scans), with the cursors it keeps open. The full
/// scans here never qualify.
pub fn okOnePass(w: *WhereInfo, ai_cur: *[2]i32) u8 {
    _ = w;
    ai_cur.* = .{ -1, -1 };
    return 0;
}
