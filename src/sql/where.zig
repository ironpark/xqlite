//! Port of where.c (core): sqlite3WhereBegin()/End(), accessors, automatic
//! indexes, Bloom filters, ORDER BY analysis and the path solver. The rest
//! of the planner is in where_loop.zig, where_code.zig and where_expr.zig;
//! where_int.zig has the shared structures.

const std = @import("std");
const int = @import("sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const serial = @import("../vdbe/serial.zig");
const ctype = @import("../util/ctype.zig");
const build = @import("build.zig");
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const util = @import("util.zig");
const walker = @import("walker.zig");
const prepare = @import("prepare.zig");
const insert = @import("insert.zig");
const delete = @import("delete.zig");
const select = @import("select.zig");
const coll_mod = @import("coll.zig");
const wi = @import("where_int.zig");
const we = @import("where_expr.zig");
const wl = @import("where_loop.zig");
const wc_mod = @import("where_code.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Select = int.Select;
const Index = int.Index;
const LogEst = int.LogEst;
const Bitmask = int.Bitmask;
const Oom = int.Oom;
const Vdbe = vi.Vdbe;
const OP = vi.OP;
const EP = int.EP;
const JT = int.JT;
const TK = int.TK;
const TF = int.TF;
const OPT = int.OPT;
const WHERE = int.WHERE;
const BMS = int.bms;
const WRC = walker.WRC;
const KEYINFO_ORDER_DESC = int.KeyInfoOrder.desc;
const KEYINFO_ORDER_BIGNULL = int.KeyInfoOrder.bignull;
const XN_ROWID = int.XN_ROWID;
const XN_EXPR = int.XN_EXPR;

pub const WhereInfo = wi.WhereInfo;
const WhereClause = wi.WhereClause;
const WhereTerm = wi.WhereTerm;
const WhereLevel = wi.WhereLevel;
const WhereLoop = wi.WhereLoop;
const WherePath = wi.WherePath;
const WhereScan = wi.WhereScan;
const WhereLoopBuilder = wi.WhereLoopBuilder;
const WhereRightJoin = wi.WhereRightJoin;
const WO = wi.WO;
const TERM = wi.TERM;
const maskBit = wi.maskBit;
const ALLBITS = wi.ALLBITS;

const WHERE_COLUMN_EQ = wi.WHERE_COLUMN_EQ;
const WHERE_COLUMN_RANGE = wi.WHERE_COLUMN_RANGE;
const WHERE_COLUMN_IN = wi.WHERE_COLUMN_IN;
const WHERE_COLUMN_NULL = wi.WHERE_COLUMN_NULL;
const WHERE_CONSTRAINT = wi.WHERE_CONSTRAINT;
const WHERE_IDX_ONLY = wi.WHERE_IDX_ONLY;
const WHERE_IPK = wi.WHERE_IPK;
const WHERE_INDEXED = wi.WHERE_INDEXED;
const WHERE_VIRTUALTABLE = wi.WHERE_VIRTUALTABLE;
const WHERE_IN_ABLE = wi.WHERE_IN_ABLE;
const WHERE_ONEROW = wi.WHERE_ONEROW;
const WHERE_MULTI_OR = wi.WHERE_MULTI_OR;
const WHERE_AUTO_INDEX = wi.WHERE_AUTO_INDEX;
const WHERE_SKIPSCAN = wi.WHERE_SKIPSCAN;
const WHERE_PARTIALIDX = wi.WHERE_PARTIALIDX;
const WHERE_IN_EARLYOUT = wi.WHERE_IN_EARLYOUT;
const WHERE_BIGNULL_SORT = wi.WHERE_BIGNULL_SORT;
const WHERE_IN_SEEKSCAN = wi.WHERE_IN_SEEKSCAN;
const WHERE_TRANSCONS = wi.WHERE_TRANSCONS;
const WHERE_BLOOMFILTER = wi.WHERE_BLOOMFILTER;
const WHERE_SELFCULL = wi.WHERE_SELFCULL;
const WHERE_COROUTINE = wi.WHERE_COROUTINE;
const WHERE_EXPRIDX = wi.WHERE_EXPRIDX;

pub const ONEPASS_OFF = wi.ONEPASS_OFF;
pub const ONEPASS_SINGLE = wi.ONEPASS_SINGLE;
pub const ONEPASS_MULTI = wi.ONEPASS_MULTI;

const LOGEST_MIN: LogEst = std.math.minInt(LogEst);
const LOGEST_MAX: LogEst = std.math.maxInt(LogEst);

/// Assign the int result of C's LogEst arithmetic back to a LogEst
/// (truncating, as the C assignment does).
inline fn le(x: i32) LogEst {
    return @truncate(x);
}


/// Port of sqlite3WhereOutputRowCount(): the estimated number of output
/// rows.
pub fn outputRowCount(w: *WhereInfo) LogEst {
    return w.n_row_out;
}

/// Port of sqlite3WhereIsDistinct(): one of the WHERE_DISTINCT_* values.
pub fn isDistinct(w: *WhereInfo) u8 {
    return w.e_distinct;
}

/// Port of sqlite3WhereIsOrdered(): the number of ORDER BY terms the
/// loops satisfy (0: sort everything; all: no sort needed).
pub fn isOrdered(w: *WhereInfo) i32 {
    return if (w.n_ob_sat < 0) 0 else w.n_ob_sat;
}

/// Port of sqlite3WhereOrderByLimitOptLabel(): where to jump when a row
/// does not fit in the ORDER BY LIMIT sorter. With the optimization, the
/// continuation of the second-innermost loop.
pub fn orderByLimitOptLabel(w: *WhereInfo) i32 {
    if (!w.b_ordered_inner_loop) return w.i_continue;
    const inner = &w.a[w.n_level - 1];
    std.debug.assert(inner.addr_nxt != 0);
    return if (inner.rj != null) w.i_continue else inner.addr_nxt;
}

/// Port of sqlite3WhereMinMaxOptEarlyOut(): after the min()/max() step,
/// jump out if the answer is already known from the output order.
pub fn minMaxOptEarlyOut(v: *Vdbe, w: *WhereInfo) void {
    if (!w.b_ordered_inner_loop) return;
    if (w.n_ob_sat == 0) return;
    var i: usize = w.n_level;
    while (i > 0) {
        i -= 1;
        const inner = &w.a[i];
        if (inner.w_loop.?.ws_flags & WHERE_COLUMN_IN != 0) {
            _ = aux.goto_(v, inner.addr_nxt);
            return;
        }
    }
    _ = aux.goto_(v, w.i_break);
}

/// Port of sqlite3WhereContinueLabel().
pub fn continueLabel(w: *WhereInfo) i32 {
    std.debug.assert(w.i_continue != 0);
    return w.i_continue;
}

/// Port of sqlite3WhereBreakLabel().
pub fn breakLabel(w: *WhereInfo) i32 {
    return w.i_break;
}

/// Port of sqlite3WhereOkOnePass(): ONEPASS_OFF, _SINGLE or _MULTI, with
/// the data and index cursors (or -1) the one-pass statement uses.
pub fn okOnePass(w: *WhereInfo, ai_cur: *[2]i32) u8 {
    ai_cur.* = w.ai_cur_one_pass;
    return w.e_one_pass;
}

/// Port of sqlite3WhereUsesDeferredSeek().
pub fn usesDeferredSeek(w: *WhereInfo) bool {
    return w.b_deferred_seek;
}

/// Port of sqlite3WhereIsSorted(): with WHERE_GROUPBY|WHERE_SORTBYGROUP,
/// whether the rows are really sorted and not just grouped.
pub fn isSorted(w: *WhereInfo) bool {
    std.debug.assert(w.wctrl_flags & (WHERE.GROUPBY | WHERE.DISTINCTBY) != 0);
    std.debug.assert(w.wctrl_flags & WHERE.SORTBYGROUP != 0);
    return w.sorted;
}

/// Port of translateColumnToCopy(): from `i_start` on, OP_Column on
/// cursor `i_tab_cur` becomes OP_Copy from the registers at `i_register`
/// and OP_Rowid becomes OP_Sequence on `i_autoidx_cur`.
fn translateColumnToCopy(p: *Parse, i_start: i32, i_tab_cur: i32, i_register: i32, i_autoidx_cur: i32) void {
    const v = p.vdbe.?;
    const i_end = aux.currentAddr(v);
    if (p.db.malloc_failed) return;
    var addr = i_start;
    while (addr < i_end) : (addr += 1) {
        const op = aux.getOp(v, addr);
        if (op.p1 != i_tab_cur) continue;
        if (op.opcode == OP.Column) {
            op.opcode = OP.Copy;
            op.p1 = op.p2 + i_register;
            op.p2 = op.p3;
            op.p3 = 0;
            // Clear the MEM_Subtype flag.
            op.p5 = 2;
        } else if (op.opcode == OP.Rowid) {
            // SQLITE_ALLOW_ROWID_IN_VIEW is off.
            op.opcode = OP.Sequence;
            op.p1 = i_autoidx_cur;
        }
    }
}

// explainAutomaticIndex() is omitted: it only does anything with
// SQLITE_ENABLE_STMT_SCANSTATUS.

/// Port of constructAutomaticIndex(): code the construction of a
/// transient index for `level` and point its WhereLoop at it.
fn constructAutomaticIndex(p: *Parse, wc: *WhereClause, not_ready: Bitmask, level: *WhereLevel) Oom!void {
    const v = p.vdbe.?;
    // Skip the creation on later iterations of the loop.
    const addr_init = aux.addOp0(v, OP.Once);

    var n_key_col: i32 = 0;
    const tab_list = wc.w_info.tab_list;
    const src = tab_list.at(level.i_from);
    const table = src.s_tab.?;
    const loop = level.w_loop.?;
    var idx_cols: Bitmask = 0;
    var sent_warning = false;
    var use_bloom_filter = true;
    var partial: ?*Expr = null;
    var i_continue: i32 = 0;
    var addr_counter: i32 = 0;
    for (wc.terms()) |*term| {
        const e = term.expr;
        // Terms that restrict the rows of `src` make the index partial.
        if (term.wt_flags & TERM.VIRTUAL == 0 and
            expr_mod.isSingleTableConstraint(e, tab_list, level.i_from, false))
        {
            partial = try expr_mod.exprAnd(p, partial, try expr_mod.exprDup(p.arena, e));
        }
        if (wl.termCanDriveIndex(term, src, not_ready)) {
            std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
            const i_col = term.left_column;
            const c_mask: Bitmask = if (i_col >= BMS) maskBit(BMS - 1) else maskBit(i_col);
            if (!sent_warning) {
                // sqlite3_log(SQLITE_WARNING_AUTOINDEX, ...) is not ported.
                sent_warning = true;
            }
            if (idx_cols & c_mask == 0) {
                try wl.whereLoopResize(p.arena, loop, @intCast(n_key_col + 1));
                loop.a_lterm[@intCast(n_key_col)] = term;
                n_key_col += 1;
                idx_cols |= c_mask;
            }
        }
    }
    std.debug.assert(n_key_col > 0 or p.db.malloc_failed);
    loop.n_lterm = @intCast(n_key_col);
    loop.btree.n_eq = @intCast(n_key_col);
    loop.ws_flags = WHERE_COLUMN_EQ | WHERE_IDX_ONLY | WHERE_INDEXED | WHERE_AUTO_INDEX;

    // The automatic index must be covering: it is not updated if the
    // table changes.
    var extra_cols: Bitmask = undefined;
    if (table.isView()) {
        extra_cols = ALLBITS & ~idx_cols;
    } else {
        extra_cols = src.col_used & (~idx_cols | maskBit(BMS - 1));
    }
    const n_col: i32 = table.nCol();
    if (!table.hasRowid()) {
        // All PRIMARY KEY columns of a WITHOUT ROWID table are needed.
        var i: i32 = 0;
        while (i < n_col) : (i += 1) {
            if (table.cols[@intCast(i)].col_flags & int.COLFLAG.PRIMKEY == 0) continue;
            if (i >= BMS - 1) {
                extra_cols |= maskBit(BMS - 1);
                break;
            }
            if (idx_cols & maskBit(i) != 0) continue;
            extra_cols |= maskBit(i);
        }
    }
    const mx_bit_col: i32 = @min(BMS - 1, n_col);
    var i: i32 = 0;
    while (i < mx_bit_col) : (i += 1) {
        if (extra_cols & maskBit(i) != 0) n_key_col += 1;
    }
    if (src.col_used & maskBit(BMS - 1) != 0) {
        n_key_col += n_col - BMS + 1;
    }

    // The Index object of the automatic index.
    const has_rowid: i32 = @intFromBool(table.hasRowid());
    const idx = try build.allocateIndexObject(p.arena, @intCast(n_key_col + has_rowid), table, "auto-index");
    loop.btree.index = idx;
    var n: usize = 0;
    idx_cols = 0;
    for (wc.terms()) |*term| {
        if (wl.termCanDriveIndex(term, src, not_ready)) {
            std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
            const i_col = term.left_column;
            const c_mask: Bitmask = if (i_col >= BMS) maskBit(BMS - 1) else maskBit(i_col);
            if (idx_cols & c_mask == 0) {
                const x = term.expr;
                idx_cols |= c_mask;
                idx.ai_column[n] = @intCast(term.left_column);
                const coll = expr_mod.compareCollSeq(p, x);
                std.debug.assert(coll != null or p.n_err > 0);
                // No Bloom filter with a non-BINARY collation.
                if (!serial.isBinary(coll)) use_bloom_filter = false;
                idx.coll[n] = if (coll) |c| c.name else coll_mod.str_binary;
                n += 1;
            }
        }
    }
    std.debug.assert(n == loop.btree.n_eq);

    // The extra columns that make the index covering.
    i = 0;
    while (i < mx_bit_col) : (i += 1) {
        if (extra_cols & maskBit(i) != 0) {
            idx.ai_column[n] = @intCast(i);
            idx.coll[n] = coll_mod.str_binary;
            n += 1;
        }
    }
    if (src.col_used & maskBit(BMS - 1) != 0) {
        i = BMS - 1;
        while (i < n_col) : (i += 1) {
            idx.ai_column[n] = @intCast(i);
            idx.coll[n] = coll_mod.str_binary;
            n += 1;
        }
    }
    std.debug.assert(n == n_key_col);
    if (table.hasRowid()) {
        idx.ai_column[n] = XN_ROWID;
        idx.coll[n] = coll_mod.str_binary;
    }

    // Create the automatic index.
    std.debug.assert(level.i_idx_cur >= 0);
    level.i_idx_cur = p.n_tab;
    p.n_tab += 1;
    _ = aux.addOp2(v, OP.OpenAutoindex, level.i_idx_cur, n_key_col + 1);
    aux.setP4KeyInfo(p, idx);
    if (!p.db.optDisabled(OPT.BloomFilter) and use_bloom_filter) {
        _ = try wc_mod.explainBloomFilter(p, wc.w_info, level);
        p.n_mem += 1;
        level.reg_filter = p.n_mem;
        _ = aux.addOp2(v, OP.Blob, 10000, level.reg_filter);
    }

    // Fill the automatic index with content.
    var addr_top: i32 = undefined;
    if (src.fg.via_coroutine) {
        std.debug.assert(src.fg.is_subquery);
        const subq = src.u4.subq.?;
        const reg_yield = subq.reg_return;
        addr_counter = aux.addOp2(v, OP.Integer, 0, 0);
        _ = aux.addOp3(v, OP.InitCoroutine, reg_yield, 0, subq.addr_fill_sub);
        addr_top = aux.addOp1(v, OP.Yield, reg_yield);
    } else {
        std.debug.assert(level.addr_halt != 0);
        addr_top = aux.addOp2(v, OP.Rewind, level.i_tab_cur, level.addr_halt);
    }
    if (partial) |pe| {
        i_continue = aux.makeLabel(p);
        ec.exprIfFalse(p, pe, i_continue, vi.SQLITE_JUMPIFNULL);
        loop.ws_flags |= WHERE_PARTIALIDX;
    }
    const reg_record = expr_mod.getTempReg(p);
    const reg_base = delete.generateIndexKey(p, idx, level.i_tab_cur, reg_record, false, null, null, 0);
    if (level.reg_filter != 0) {
        std.debug.assert(we.loopBloomable(loop));
        _ = aux.addOp4Int(v, OP.FilterAdd, level.reg_filter, 0, reg_base, loop.btree.n_eq);
    }
    _ = aux.addOp2(v, OP.IdxInsert, level.i_idx_cur, reg_record);
    aux.changeP5(v, vi.OPFLAG.USESEEKRESULT);
    if (partial != null) aux.resolveLabel(v, i_continue);
    if (src.fg.via_coroutine) {
        std.debug.assert(src.fg.is_subquery and src.u4.subq != null);
        aux.changeP2(v, addr_counter, reg_base + @as(i32, @intCast(n)));
        std.debug.assert(level.i_idx_cur > 0);
        translateColumnToCopy(p, addr_top, level.i_tab_cur, src.u4.subq.?.reg_result, level.i_idx_cur);
        _ = aux.goto_(v, addr_top);
        src.fg.via_coroutine = false;
        aux.jumpHere(v, addr_top);
    } else {
        _ = aux.addOp2(v, OP.Next, level.i_tab_cur, addr_top + 1);
        aux.changeP5(v, vi.STMTSTATUS.AUTOINDEX);
        if (src.fg.jointype & JT.LEFT != 0) aux.jumpHere(v, addr_top);
    }
    expr_mod.releaseTempReg(p, reg_record);

    // Jump here when skipping the initialization.
    aux.jumpHere(v, addr_init);
}

/// Port of sqlite3ConstructBloomFilter(): code the initialization of the
/// Bloom filter of `level`, and of the inner loops whose filters can be
/// built early with it.
fn constructBloomFilter(w: *WhereInfo, i_level_arg: usize, level_arg: *WhereLevel, not_ready: Bitmask) Oom!void {
    const p = w.parse;
    const v = p.vdbe.?;
    var i_level = i_level_arg;
    var level = level_arg;
    var loop = level.w_loop.?;

    const saved_idx_epr = p.idx_epr;
    const saved_idx_part_expr = p.idx_part_expr;
    p.idx_epr = null;
    p.idx_part_expr = null;

    std.debug.assert(loop.ws_flags & WHERE_BLOOMFILTER != 0);
    std.debug.assert(loop.ws_flags & WHERE_IDX_ONLY == 0);

    const addr_once = aux.addOp0(v, OP.Once);
    while (true) {
        _ = try wc_mod.explainBloomFilter(p, w, level);
        const addr_cont = aux.makeLabel(p);
        const i_cur = level.i_tab_cur;
        p.n_mem += 1;
        level.reg_filter = p.n_mem;

        // A zero blob of at least 80K bits, more for a large table (by
        // sqlite_stat1, not measured, to keep testing simple).
        const tab_list = w.tab_list;
        const i_src = level.i_from;
        const item = tab_list.at(i_src);
        const tab = item.s_tab.?;
        var sz = util.logEstToInt(tab.n_row_log_est);
        if (sz < 10000) {
            sz = 10000;
        } else if (sz > 10000000) {
            sz = 10000000;
        }
        std.debug.assert(we.loopBloomable(loop));
        _ = aux.addOp2(v, OP.Blob, @intCast(sz), level.reg_filter);

        const addr_top = aux.addOp1(v, OP.Rewind, i_cur);
        for (w.s_wc.terms()) |*term| {
            const e = term.expr;
            if (term.wt_flags & TERM.VIRTUAL == 0 and
                expr_mod.isSingleTableConstraint(e, tab_list, i_src, false))
            {
                ec.exprIfFalse(p, term.expr, addr_cont, vi.SQLITE_JUMPIFNULL);
            }
        }
        if (loop.ws_flags & WHERE_IPK != 0) {
            const r1 = expr_mod.getTempReg(p);
            _ = aux.addOp2(v, OP.Rowid, i_cur, r1);
            _ = aux.addOp4Int(v, OP.FilterAdd, level.reg_filter, 0, r1, 1);
            expr_mod.releaseTempReg(p, r1);
        } else {
            const idx = loop.btree.index.?;
            const n: i32 = loop.btree.n_eq;
            const r1 = expr_mod.getTempRange(p, n);
            var jj: i32 = 0;
            while (jj < n) : (jj += 1) {
                std.debug.assert(idx.table == item.s_tab.?);
                ec.codeLoadIndexColumn(p, idx, i_cur, @intCast(jj), r1 + jj);
            }
            _ = aux.addOp4Int(v, OP.FilterAdd, level.reg_filter, 0, r1, n);
            expr_mod.releaseTempRange(p, r1, n);
        }
        aux.resolveLabel(v, addr_cont);
        _ = aux.addOp2(v, OP.Next, level.i_tab_cur, addr_top + 1);
        aux.jumpHere(v, addr_top);
        loop.ws_flags &= ~WHERE_BLOOMFILTER;
        i_level += 1;
        while (i_level < w.n_level) : (i_level += 1) {
            level = &w.a[i_level];
            const tab_item = w.tab_list.at(level.i_from);
            if (tab_item.fg.jointype & (JT.LEFT | JT.LTORJ) != 0) continue;
            loop = level.w_loop orelse continue;
            if (loop.prereq & not_ready != 0) continue;
            // A candidate for early evaluation, unless it uses IN.
            if (loop.ws_flags & (WHERE_BLOOMFILTER | WHERE_COLUMN_IN) == WHERE_BLOOMFILTER) break;
        }
        if (i_level >= w.n_level) break;
    }
    aux.jumpHere(v, addr_once);
    p.idx_epr = saved_idx_epr;
    p.idx_part_expr = saved_idx_part_expr;
}

/// Port of wherePathMatchSubqueryOB(): mark off the ORDER BY terms that
/// the ORDER BY of the subquery of `loop` (cursor `i_cur`) delivers.
/// True if any did.
fn wherePathMatchSubqueryOB(loop: *WhereLoop, i_loop: usize, i_cur: i32, order_by: *ExprList, rev_mask: *Bitmask, ob_sat: *Bitmask, wctrl_flags: u16) bool {
    var rev: u8 = 0;
    var rev_idx: u8 = 0;
    const sub_ob = loop.btree.order_by.?;
    var i_ob: usize = 0;
    while (maskBit(i_ob) & ob_sat.* != 0) i_ob += 1;
    var j_sub: usize = 0;
    while (j_sub < sub_ob.len() and i_ob < order_by.len()) : ({
        j_sub += 1;
        i_ob += 1;
    }) {
        const sub_item = sub_ob.at(j_sub);
        if (sub_item.u.x.order_by_col == 0) break;
        const ob_expr = order_by.at(i_ob).expr.?;
        if (ob_expr.op != TK.COLUMN and ob_expr.op != TK.AGG_COLUMN) break;
        if (ob_expr.i_table != i_cur) break;
        if (ob_expr.i_column != @as(i32, sub_item.u.x.order_by_col) - 1) break;
        if (wctrl_flags & WHERE.GROUPBY == 0) {
            const sf_ob = order_by.at(i_ob).fg.sort_flags;
            const sf_sub = sub_item.fg.sort_flags;
            if (sf_sub & KEYINFO_ORDER_BIGNULL != sf_ob & KEYINFO_ORDER_BIGNULL) break;
            rev_idx = sf_sub & KEYINFO_ORDER_DESC;
            if (j_sub > 0) {
                if (rev ^ rev_idx != sf_ob & KEYINFO_ORDER_DESC) break;
            } else {
                rev = rev_idx ^ (sf_ob & KEYINFO_ORDER_DESC);
                if (rev != 0) {
                    // A co-routine cannot run in reverse order.
                    if (loop.ws_flags & WHERE_COROUTINE != 0) break;
                    rev_mask.* |= maskBit(i_loop);
                }
            }
        }
        ob_sat.* |= maskBit(i_ob);
    }
    return j_sub > 0;
}

/// Port of wherePathSatisfiesOrderBy(): how many terms of `order_by` (an
/// ORDER BY, GROUP BY or DISTINCT list) the path `path` plus `last`
/// delivers in order: N>0 terms, 0 none, -1 not known yet. GROUP BY and
/// DISTINCT only need equal rows to be adjacent, so their terms match in
/// any order.
fn wherePathSatisfiesOrderBy(w: *WhereInfo, order_by: *ExprList, path: *WherePath, wctrl_flags: u16, n_loop: u16, last: *WhereLoop, rev_mask: *Bitmask) i8 {
    const db = w.parse.db;
    var ob_sat: Bitmask = 0;
    var loop: *WhereLoop = undefined;

    // A WhereLoop is "one-row" (WHERE_ONEROW) if it yields at most one
    // row, and "order-distinct" if its ORDER BY columns differ on every
    // row (UNIQUE and NOT NULL). One-row loops are order-distinct.
    if (n_loop != 0 and db.optDisabled(OPT.OrderByIdxJoin)) return 0;

    const n_order_by: u16 = @intCast(order_by.len());
    // Overly large ORDER BYs are not optimized.
    if (n_order_by > BMS - 1) return 0;
    var is_order_distinct = true;
    const ob_done: Bitmask = maskBit(n_order_by) - 1;
    var order_distinct_mask: Bitmask = 0;
    var ready: Bitmask = 0;
    var eq_op_mask: u16 = WO.EQ | WO.IS | WO.ISNULL;
    if (wctrl_flags & (WHERE.ORDERBY_LIMIT | WHERE.ORDERBY_MAX | WHERE.ORDERBY_MIN) != 0) {
        eq_op_mask |= WO.IN;
    }
    var i_loop: usize = 0;
    while (is_order_distinct and ob_sat < ob_done and i_loop <= n_loop) : (i_loop += 1) {
        if (i_loop > 0) ready |= loop.mask_self;
        if (i_loop < n_loop) {
            loop = path.a_loop[i_loop];
            if (wctrl_flags & WHERE.ORDERBY_LIMIT != 0) continue;
        } else {
            loop = last;
        }
        if (loop.ws_flags & WHERE_VIRTUALTABLE != 0) {
            if (loop.vtab.is_ordered != 0 and w.order_by == order_by) {
                ob_sat = ob_done;
            } else {
                // No further ORDER BY terms may be matched: the result
                // must be >= 0, not -1.
                is_order_distinct = false;
            }
            break;
        }
        const i_cur = w.tab_list.at(loop.i_tab).i_cursor;

        // Mark off the ORDER BY terms X of this table with a WHERE term
        // "X IS NULL" or "X=?" that uses only outer loops.
        var i: usize = 0;
        while (i < n_order_by) : (i += 1) {
            if (maskBit(i) & ob_sat != 0) continue;
            const ob_expr = expr_mod.skipCollateAndLikely(order_by.at(i).expr) orelse continue;
            if (ob_expr.op != TK.COLUMN and ob_expr.op != TK.AGG_COLUMN) continue;
            if (ob_expr.i_table != i_cur) continue;
            const term = wl.findTerm(&w.s_wc, i_cur, ob_expr.i_column, ~ready, eq_op_mask, null) orelse continue;
            if (term.e_operator == WO.IN) {
                // IN terms count only for the ORDER BY LIMIT optimization,
                // and only if the plan uses them.
                std.debug.assert(wctrl_flags & (WHERE.ORDERBY_LIMIT | WHERE.ORDERBY_MIN | WHERE.ORDERBY_MAX) != 0);
                var j: usize = 0;
                while (j < loop.n_lterm and term != loop.a_lterm[j]) j += 1;
                if (j >= loop.n_lterm) continue;
            }
            if (term.e_operator & (WO.EQ | WO.IS) != 0 and ob_expr.i_column >= 0) {
                const p = w.parse;
                const coll1 = expr_mod.nnCollSeq(p, order_by.at(i).expr);
                const c_expr = term.expr;
                const coll2 = expr_mod.compareCollSeq(p, c_expr);
                if (coll2 == null or ctype.strICmp(coll1.name, coll2.?.name) != 0) continue;
                const aff_right = expr_mod.affinity(c_expr.right.?);
                // The left operand is a column, so it has an affinity.
                std.debug.assert(expr_mod.affinity(c_expr.left.?) != 0);
                // An affinity conversion would be required.
                if (aff_right != 0 and aff_right != expr_mod.affinity(c_expr.left.?)) continue;
            }
            ob_sat |= maskBit(i);
        }

        if (loop.ws_flags & WHERE_ONEROW == 0) {
            var n_key_col: u16 = 0;
            var n_column: u16 = 0;
            var index: ?*Index = null;
            if (loop.ws_flags & WHERE_IPK != 0) {
                if (loop.btree.order_by != null and
                    !db.optDisabled(OPT.OrderBySubq) and
                    wherePathMatchSubqueryOB(loop, i_loop, i_cur, order_by, rev_mask, &ob_sat, wctrl_flags))
                {
                    n_column = 0;
                    is_order_distinct = false;
                } else {
                    n_column = 1;
                }
                index = null;
                n_key_col = 0;
            } else {
                index = loop.btree.index;
                if (index == null or index.?.unordered) return 0;
                const ix = index.?;
                n_key_col = ix.n_key_col;
                n_column = ix.n_column;
                std.debug.assert(n_column == n_key_col + 1 or !ix.table.hasRowid());
                std.debug.assert(ix.ai_column[n_column - 1] == XN_ROWID or !ix.table.hasRowid());
                // Possibly a false positive; corrected at tag-20210426-1.
                is_order_distinct = ix.isUnique() and loop.ws_flags & WHERE_SKIPSCAN == 0;
            }

            // The index columns not constrained by == or IN.
            var rev: u8 = 0;
            var rev_set = false;
            var distinct_columns = false;
            var j: usize = 0;
            while (j < n_column) : (j += 1) {
                // Whether to run the ORDER BY search loop.
                var b_once = true;

                std.debug.assert(j >= loop.btree.n_eq or (loop.a_lterm[j] == null) == (j < loop.n_skip));
                if (j < loop.btree.n_eq and j >= loop.n_skip) {
                    const e_op = loop.a_lterm[j].?.e_operator;
                    // Skip ==, IS and ISNULL terms (and IN for ORDER BY
                    // LIMIT). IS and ISNULL allow repeated NULL rows, so the
                    // loop is not order-distinct. A column of a multi-column
                    // (?,?) IN (SELECT...) that is not the only one used
                    // cannot match an ORDER BY term.
                    if (e_op & eq_op_mask != 0) {
                        if (e_op & (WO.ISNULL | WO.IS) != 0) is_order_distinct = false;
                        continue;
                    } else if (e_op & WO.IN != 0) {
                        const x = loop.a_lterm[j].?.expr;
                        var ii = j + 1;
                        while (ii < loop.btree.n_eq) : (ii += 1) {
                            if (loop.a_lterm[ii].?.expr == x) {
                                std.debug.assert(loop.a_lterm[ii].?.e_operator & WO.IN != 0);
                                b_once = false;
                                break;
                            }
                        }
                    }
                }

                // The table column and sort order of index column j.
                var i_column: i32 = undefined;
                var rev_idx: u8 = undefined;
                if (index) |ix| {
                    i_column = ix.ai_column[j];
                    rev_idx = ix.sort_order[j] & KEYINFO_ORDER_DESC;
                    if (i_column == ix.table.i_pkey) i_column = XN_ROWID;
                } else {
                    i_column = XN_ROWID;
                    rev_idx = 0;
                }

                // An unconstrained column that might be NULL means that
                // the loop is not well-ordered (tag-20210426-1).
                if (is_order_distinct) {
                    if (i_column >= 0 and j >= loop.btree.n_eq and
                        index.?.table.cols[@intCast(i_column)].not_null == 0)
                    {
                        is_order_distinct = false;
                    }
                    if (i_column == XN_EXPR) is_order_distinct = false;
                }

                // Find the ORDER BY term of index column j and mark it
                // satisfied.
                var is_match = false;
                i = 0;
                while (b_once and i < n_order_by) : (i += 1) {
                    if (maskBit(i) & ob_sat != 0) continue;
                    const ob_expr = expr_mod.skipCollateAndLikely(order_by.at(i).expr) orelse continue;
                    if (wctrl_flags & (WHERE.GROUPBY | WHERE.DISTINCTBY) == 0) b_once = false;
                    if (i_column >= XN_ROWID) {
                        if (ob_expr.op != TK.COLUMN and ob_expr.op != TK.AGG_COLUMN) continue;
                        if (ob_expr.i_table != i_cur) continue;
                        if (ob_expr.i_column != i_column) continue;
                    } else {
                        const ix_expr = index.?.col_expr.?.at(j).expr;
                        if (expr_mod.compareSkip(ob_expr, ix_expr, i_cur) != 0) continue;
                    }
                    if (i_column != XN_ROWID) {
                        const coll = expr_mod.nnCollSeq(w.parse, order_by.at(i).expr);
                        if (ctype.strICmp(coll.name, index.?.coll[j]) != 0) continue;
                    }
                    if (wctrl_flags & WHERE.DISTINCTBY != 0) {
                        loop.btree.n_distinct_col = @intCast(j + 1);
                    }
                    is_match = true;
                    break;
                }
                if (is_match and wctrl_flags & WHERE.GROUPBY == 0) {
                    // The sort order must be compatible with ORDER BY (it
                    // does not matter for GROUP BY).
                    if (rev_set) {
                        if (rev ^ rev_idx != order_by.at(i).fg.sort_flags & KEYINFO_ORDER_DESC) {
                            is_match = false;
                        }
                    } else {
                        rev = rev_idx ^ (order_by.at(i).fg.sort_flags & KEYINFO_ORDER_DESC);
                        if (rev != 0) rev_mask.* |= maskBit(i_loop);
                        rev_set = true;
                    }
                }
                if (is_match and order_by.at(i).fg.sort_flags & KEYINFO_ORDER_BIGNULL != 0) {
                    if (j == loop.btree.n_eq) {
                        loop.ws_flags |= WHERE_BIGNULL_SORT;
                    } else {
                        is_match = false;
                    }
                }
                if (is_match) {
                    if (i_column == XN_ROWID) distinct_columns = true;
                    ob_sat |= maskBit(i);
                } else {
                    // No match found.
                    if (j == 0 or j < n_key_col) is_order_distinct = false;
                    break;
                }
            }
            if (distinct_columns) is_order_distinct = true;
        }

        // Mark off any other ORDER BY terms that reference only
        // order-distinct loops.
        if (is_order_distinct) {
            order_distinct_mask |= loop.mask_self;
            i = 0;
            while (i < n_order_by) : (i += 1) {
                if (maskBit(i) & ob_sat != 0) continue;
                const e = order_by.at(i).expr;
                const m_term = we.exprUsage(&w.s_mask_set, e);
                if (m_term == 0 and !expr_mod.isConstant(null, e)) continue;
                if (m_term & ~order_distinct_mask == 0) ob_sat |= maskBit(i);
            }
        }
    }
    if (ob_sat == ob_done) return @intCast(n_order_by);
    if (!is_order_distinct) {
        var i: usize = n_order_by -| 1;
        while (i > 0) : (i -= 1) {
            const m: Bitmask = if (i < BMS) maskBit(i) - 1 else 0;
            if (ob_sat & m == m) return @intCast(i);
        }
        return 0;
    }
    return -1;
}

/// Port of whereSortingCost(): the cost of sorting `n_row` rows on
/// `n_order_by` terms of which the first `n_sorted` are already in order.
fn whereSortingCost(w: *WhereInfo, n_row_arg: LogEst, n_order_by: i32, n_sorted: i32) LogEst {
    var n_row = n_row_arg;
    // cost = K * N * log(N), times (Y/X) when only the last Y of X terms
    // are out of order; K grows with the number of output columns.
    std.debug.assert(w.select != null);
    std.debug.assert(w.select.?.e_list != null);
    const n_col: LogEst = util.logEst(@intCast(@divTrunc(@as(i32, @intCast(w.select.?.e_list.?.len())) + 59, 30)));
    var r_sort_cost: LogEst = le(@as(i32, n_row) + n_col);
    if (n_sorted > 0) {
        // Scale the result by (Y/X).
        r_sort_cost = le(@as(i32, r_sort_cost) + util.logEst(@intCast(@divTrunc((n_order_by - n_sorted) * 100, n_order_by))) - 66);
    }

    // Multiply by log(M), M the number of output rows: the LIMIT if it is
    // smaller, or for DISTINCT a little less than the row count.
    if (w.wctrl_flags & WHERE.USE_LIMIT != 0) {
        // TUNING: extra 2.0x with LIMIT, and 1.5x more with partial sort.
        r_sort_cost = le(@as(i32, r_sort_cost) + 10);
        if (n_sorted != 0) r_sort_cost = le(@as(i32, r_sort_cost) + 6);
        if (w.i_limit < n_row) n_row = w.i_limit;
    } else if (w.wctrl_flags & WHERE.WANT_DISTINCT != 0) {
        // TUNING: DISTINCT halves the number of output rows.
        if (n_row > 10) n_row -= 10;
    }
    r_sort_cost = le(@as(i32, r_sort_cost) + wl.estLog(n_row));
    return r_sort_cost;
}

/// Port of computeMxChoice(): the number of paths the solver keeps for a
/// join of three or more tables: 18 for a star query, else 12. A star
/// query has (aa) four or more FROM terms and a fact table (bb) inner
/// joined to (cc) three or more dimension tables that (dd) are not
/// self-joins. As a side effect, the SCAN costs of the dimension tables
/// are raised just above the fact table's, which keeps the fact table in
/// an outer loop.
fn computeMxChoice(w: *WhereInfo) i32 {
    const n_loop: usize = w.n_level;

    if (n_loop >= 4 and !w.b_star_done and !w.parse.db.optDisabled(OPT.StarQuery)) {
        var m_self_join: Bitmask = 0;
        w.b_star_done = true;

        std.debug.assert(!w.b_star_used);
        const a_from_tabs = w.tab_list.slice();
        var start = w.loops;
        var i_from_idx: usize = 0;
        var m: Bitmask = 1;
        while (i_from_idx < n_loop) : ({
            i_from_idx += 1;
            m <<= 1;
        }) {
            var n_dep: i32 = 0;
            var m_seen: Bitmask = 0;
            const fact_tab = &a_from_tabs[i_from_idx];
            if (fact_tab.fg.jointype & (JT.OUTER | JT.CROSS) != 0) {
                // The right table of an outer join: only tables to its
                // right can be dimensions (bb).
                if (i_from_idx + 3 > n_loop) break; // (cc) unreachable
                while (start) |s| {
                    if (s.i_tab > i_from_idx) break;
                    start = s.next_loop;
                }
            }
            var it = start;
            while (it) |l| : (it = l.next_loop) {
                if (a_from_tabs[l.i_tab].fg.jointype & (JT.OUTER | JT.CROSS) != 0) break; // (bb)
                if (l.prereq & m != 0 and l.mask_self & m_seen == 0 and l.mask_self & m_self_join == 0) {
                    if (a_from_tabs[l.i_tab].s_tab == fact_tab.s_tab) {
                        m_self_join |= m;
                    } else {
                        n_dep += 1;
                        m_seen |= l.mask_self;
                    }
                }
            }
            if (n_dep <= 2) continue; // (cc)

            // fact_tab is a fact table: adjust the costs.
            w.b_star_used = true;

            // The largest SCAN cost of the fact table, plus one.
            var mx_run: LogEst = LOGEST_MIN;
            it = start;
            while (it) |l| : (it = l.next_loop) {
                if (l.i_tab < i_from_idx) continue;
                if (l.i_tab > i_from_idx) break;
                if (l.r_run > mx_run) mx_run = l.r_run;
            }
            if (mx_run < LOGEST_MAX) mx_run += 1;

            // Raise the table-scan costs of the dimension tables to that.
            it = start;
            while (it) |l| : (it = l.next_loop) {
                if (l.mask_self & m_seen == 0) continue;
                if (l.n_lterm != 0) continue;
                if (l.r_run < mx_run) l.r_run = mx_run;
            }
        }
    }
    return if (w.b_star_used) 18 else 12;
}

/// Port of whereLoopIsNoBetter(): for two loops of equal cost, false if
/// `candidate` is even slightly better than `baseline`.
fn whereLoopIsNoBetter(candidate: *const WhereLoop, baseline: *const WhereLoop) bool {
    if (candidate.ws_flags & WHERE_INDEXED == 0) return true;
    if (baseline.ws_flags & WHERE_INDEXED == 0) return true;
    if (candidate.btree.index.?.sz_idx_row < baseline.btree.index.?.sz_idx_row) return false;
    return true;
}

/// Port of wherePathSolver(): find the cheapest path through the
/// WhereLoops of `w` that visits each FROM term once and load it into
/// w.a[].w_loop. Sorting `n_row_est` rows is costed in, or ignored when
/// it is 0. SQLITE_OK, or SQLITE_ERROR if there is no solution.
fn wherePathSolver(w: *WhereInfo, n_row_est: LogEst) Oom!i32 {
    const p = w.parse;
    const n_loop: usize = w.n_level;
    var mx_i: usize = 0;
    var mx_cost: LogEst = 0;
    var mx_unsort: LogEst = 0;

    // TUNING: the number of paths kept at each step: 1 for one loop, 5
    // for two, 12 or 18 for more (see computeMxChoice()).
    var mx_choice: usize = undefined;
    if (n_loop <= 1) {
        mx_choice = 1;
    } else if (n_loop == 2) {
        mx_choice = 5;
    } else if (p.n_err != 0) {
        mx_choice = 1;
    } else {
        mx_choice = @intCast(computeMxChoice(w));
    }
    std.debug.assert(n_loop <= w.tab_list.len());

    // With n_row_est 0 the ORDER BY is ignored: this call only estimates
    // the output size for the second one.
    var n_order_by: usize = undefined;
    if (w.order_by == null or n_row_est == 0) {
        n_order_by = 0;
    } else {
        n_order_by = w.order_by.?.len();
    }

    // Space for aTo, aFrom and aSortCost[].
    const paths = try p.arena.alloc(WherePath, mx_choice * 2);
    const loop_space = try p.arena.alloc(*WhereLoop, mx_choice * 2 * n_loop);
    for (paths, 0..) |*path, k| path.* = .{ .a_loop = loop_space[k * n_loop .. (k + 1) * n_loop] };
    var a_to = paths[0..mx_choice];
    var a_from = paths[mx_choice..];
    // aSortCost[X]: 0 if not computed yet, else the cost of sorting
    // n_row_est rows whose first X ORDER BY terms are in order.
    var a_sort_cost: []LogEst = &.{};
    if (n_order_by != 0) {
        a_sort_cost = try p.arena.alloc(LogEst, n_order_by);
        @memset(a_sort_cost, 0);
    }

    // Seed the search with one empty path. TUNING: no more than 28
    // iterations, so that an automatic index must pay back within 28 rows.
    a_from[0].n_row = @min(p.n_query_loop, 48);
    var n_from: usize = 1;
    std.debug.assert(a_from[0].is_ordered == 0);
    if (n_order_by != 0) {
        // No FROM terms: at most one row, which is in order. Otherwise not
        // known yet.
        a_from[0].is_ordered = if (n_loop > 0) -1 else @intCast(n_order_by);
    }

    // Compute successively longer paths from the previous generation,
    // keeping the mx_choice best.
    var i_loop: usize = 0;
    while (i_loop < n_loop) : (i_loop += 1) {
        var n_to: usize = 0;
        for (a_from[0..n_from]) |*from| {
            var it = w.loops;
            while (it) |wloop| : (it = wloop.next_loop) {
                if (wloop.prereq & ~from.mask_loop != 0) continue;
                if (wloop.mask_self & from.mask_loop != 0) continue;
                // No automatic index for a loop expected to run less than
                // 1.25 times (it can still help the outer loop of a
                // correlated subquery).
                if (wloop.ws_flags & WHERE_AUTO_INDEX != 0 and from.n_row < 3) continue;

                // wloop is a candidate for the next loop: its cost.
                var r_unsort: LogEst = le(@as(i32, wloop.r_run) + from.n_row);
                if (wloop.r_setup != 0) r_unsort = util.logEstAdd(wloop.r_setup, r_unsort);
                r_unsort = util.logEstAdd(r_unsort, from.r_unsort);
                const n_out: LogEst = le(@as(i32, from.n_row) + wloop.n_out);
                const mask_new = from.mask_loop | wloop.mask_self;
                var is_ordered: i8 = from.is_ordered;
                var rev_mask: Bitmask = undefined;
                if (is_ordered < 0) {
                    rev_mask = 0;
                    is_ordered = wherePathSatisfiesOrderBy(w, w.order_by.?, from, w.wctrl_flags, @intCast(i_loop), wloop, &rev_mask);
                } else {
                    rev_mask = from.rev_loop;
                }
                var r_cost: LogEst = undefined;
                if (is_ordered >= 0 and is_ordered < n_order_by) {
                    const k: usize = @intCast(is_ordered);
                    if (a_sort_cost[k] == 0) {
                        a_sort_cost[k] = whereSortingCost(w, n_row_est, @intCast(n_order_by), is_ordered);
                    }
                    // TUNING: a small extra penalty (3) for sorting, to
                    // favor plans that need none.
                    r_cost = le(@as(i32, util.logEstAdd(r_unsort, a_sort_cost[k])) + 3);
                } else {
                    r_cost = r_unsort;
                    // TUNING: slight bias in favor of no-sort plans.
                    r_unsort = le(@as(i32, r_unsort) - 2);
                }

                // Look for a best-so-far path over the same loops with a
                // compatible is_ordered: both -1, both >=0, or this is the
                // last round. ((a^b)&0x80)==0 tests (a==-1)==(b==-1).
                var jj: usize = 0;
                while (jj < n_to) : (jj += 1) {
                    const to = &a_to[jj];
                    if (to.mask_loop == mask_new and
                        ((@as(u8, @bitCast(to.is_ordered)) ^ @as(u8, @bitCast(is_ordered))) & 0x80 == 0 or i_loop == n_loop - 1))
                    {
                        break;
                    }
                }
                var to: *WherePath = undefined;
                if (jj >= n_to) {
                    // No match. Discard the candidate if it is no better
                    // than all mx_choice paths.
                    if (n_to >= mx_choice and
                        (r_cost > mx_cost or (r_cost == mx_cost and r_unsort >= mx_unsort)))
                    {
                        continue;
                    }
                    // Add it, replacing the worst path if the set is full.
                    if (n_to < mx_choice) {
                        jj = n_to;
                        n_to += 1;
                    } else {
                        jj = mx_i;
                    }
                    to = &a_to[jj];
                } else {
                    // to covers the same loops with the same ordering. Skip
                    // the candidate unless it is better:
                    // (to.rCost,to.nRow,to.rUnsort) <= (rCost,nOut,rUnsort).
                    to = &a_to[jj];
                    if (to.r_cost < r_cost or
                        (to.r_cost == r_cost and to.n_row < n_out) or
                        (to.r_cost == r_cost and to.n_row == n_out and to.r_unsort < r_unsort) or
                        (to.r_cost == r_cost and to.n_row == n_out and to.r_unsort == r_unsort and
                            whereLoopIsNoBetter(wloop, to.a_loop[i_loop])))
                    {
                        continue;
                    }
                    // The candidate replaces to.
                }
                // wloop is a winner: add it to the best so far.
                to.mask_loop = from.mask_loop | wloop.mask_self;
                to.rev_loop = rev_mask;
                to.n_row = n_out;
                to.r_cost = r_cost;
                to.r_unsort = r_unsort;
                to.is_ordered = is_ordered;
                @memcpy(to.a_loop[0..i_loop], from.a_loop[0..i_loop]);
                to.a_loop[i_loop] = wloop;
                if (n_to >= mx_choice) {
                    mx_i = 0;
                    mx_cost = a_to[0].r_cost;
                    mx_unsort = a_to[0].n_row;
                    jj = 1;
                    while (jj < mx_choice) : (jj += 1) {
                        const t = &a_to[jj];
                        if (t.r_cost > mx_cost or (t.r_cost == mx_cost and t.r_unsort > mx_unsort)) {
                            mx_cost = t.r_cost;
                            mx_unsort = t.r_unsort;
                            mx_i = jj;
                        }
                    }
                }
            }
        }

        // Swap the roles of aFrom and aTo for the next generation.
        const tmp = a_to;
        a_to = a_from;
        a_from = tmp;
        n_from = n_to;
    }

    if (n_from == 0) {
        util.errorMsg(p, "no query solution", .{});
        return int.RC.ERROR;
    }

    // Only one path is left, the best one.
    std.debug.assert(n_from == 1);
    const from = &a_from[0];

    std.debug.assert(w.n_level == n_loop);
    // Load the lowest cost path into w.
    i_loop = 0;
    while (i_loop < n_loop) : (i_loop += 1) {
        const level = &w.a[i_loop];
        const wloop = from.a_loop[i_loop];
        level.w_loop = wloop;
        level.i_from = wloop.i_tab;
        level.i_tab_cur = w.tab_list.at(level.i_from).i_cursor;
    }
    if (w.wctrl_flags & WHERE.WANT_DISTINCT != 0 and
        w.wctrl_flags & WHERE.DISTINCTBY == 0 and
        w.e_distinct == int.WHERE_DISTINCT_NOOP and
        n_row_est != 0)
    {
        var not_used: Bitmask = 0;
        const rc = wherePathSatisfiesOrderBy(w, w.result_set.?, from, WHERE.DISTINCTBY, @intCast(n_loop - 1), from.a_loop[n_loop - 1], &not_used);
        if (rc == w.result_set.?.len()) w.e_distinct = int.WHERE_DISTINCT_ORDERED;
    }
    w.b_ordered_inner_loop = false;
    if (w.order_by) |ob| {
        w.n_ob_sat = from.is_ordered;
        if (w.wctrl_flags & WHERE.DISTINCTBY != 0) {
            if (from.is_ordered == ob.len()) w.e_distinct = int.WHERE_DISTINCT_ORDERED;
            // See check-in [12ad822d9b827777] on 2023-03-16.
            std.debug.assert(w.select.?.order_by == null or w.n_ob_sat <= w.select.?.order_by.?.len());
        } else {
            w.rev_mask = from.rev_loop;
            if (w.n_ob_sat <= 0) {
                w.n_ob_sat = 0;
                if (n_loop > 0) {
                    const ws_flags = from.a_loop[n_loop - 1].ws_flags;
                    if (ws_flags & WHERE_ONEROW == 0 and
                        ws_flags & (WHERE_IPK | WHERE_COLUMN_IN) != (WHERE_IPK | WHERE_COLUMN_IN))
                    {
                        var m: Bitmask = 0;
                        const rc = wherePathSatisfiesOrderBy(w, ob, from, WHERE.ORDERBY_LIMIT, @intCast(n_loop - 1), from.a_loop[n_loop - 1], &m);
                        if (rc == ob.len()) {
                            w.b_ordered_inner_loop = true;
                            w.rev_mask = m;
                        }
                    }
                }
            } else if (n_loop != 0 and w.n_ob_sat == 1 and
                w.wctrl_flags & (WHERE.ORDERBY_MIN | WHERE.ORDERBY_MAX) != 0)
            {
                w.b_ordered_inner_loop = true;
            }
        }
        if (w.wctrl_flags & WHERE.SORTBYGROUP != 0 and w.n_ob_sat == ob.len() and n_loop > 0) {
            var rev_mask: Bitmask = 0;
            const n_order = wherePathSatisfiesOrderBy(w, ob, from, 0, @intCast(n_loop - 1), from.a_loop[n_loop - 1], &rev_mask);
            std.debug.assert(!w.sorted);
            if (n_order == ob.len()) {
                w.sorted = true;
                w.rev_mask = rev_mask;
            }
        }
    }

    w.n_row_out = from.n_row;
    return int.RC.OK;
}

/// Port of whereInterstageHeuristic(): between the two solver runs, for
/// each leading loop of the first plan that is an equality search, keep
/// the second run from turning it into a full scan to satisfy ORDER BY.
/// The analysis stops at the first full scan, which may still be swapped.
fn whereInterstageHeuristic(w: *WhereInfo) void {
    for (w.levels()) |*level| {
        const l = level.w_loop orelse break;
        // A vtab scan is like a full table scan.
        if (l.ws_flags & WHERE_VIRTUALTABLE != 0) break;
        if (l.ws_flags & (WHERE_COLUMN_EQ | WHERE_COLUMN_NULL | WHERE_COLUMN_IN) != 0) {
            const i_tab = l.i_tab;
            var it = w.loops;
            while (it) |loop| : (it = loop.next_loop) {
                if (loop.i_tab != i_tab) continue;
                // Auto-index and index-constrained loops may remain.
                if (loop.ws_flags & (WHERE_CONSTRAINT | WHERE_AUTO_INDEX) != 0) continue;
                // Keep the second solver run from using this one.
                loop.prereq = ALLBITS;
            }
        } else {
            break;
        }
    }
}

/// Port of whereShortCut(): plan a single-table query with == constraints
/// on the rowid or a unique index without the general planner. True if
/// it did.
fn whereShortCut(builder: *WhereLoopBuilder) bool {
    const w = builder.w_info;
    if (w.wctrl_flags & WHERE.OR_SUBCLAUSE != 0) return false;
    std.debug.assert(w.tab_list.len() >= 1);
    const item = w.tab_list.at(0);
    const tab = item.s_tab.?;
    if (tab.e_tab_type == .vtab) return false;
    if (item.fg.is_indexed_by or item.fg.not_indexed) return false;
    const i_cur = item.i_cursor;
    const wc = &w.s_wc;
    const loop = builder.new;
    loop.ws_flags = 0;
    loop.n_skip = 0;
    var scan: WhereScan = .{};
    var term = wl.whereScanInit(&scan, wc, i_cur, -1, WO.EQ | WO.IS, null);
    while (term != null and term.?.prereq_right != 0) term = wl.whereScanNext(&scan);
    if (term) |t| {
        loop.ws_flags = WHERE_COLUMN_EQ | WHERE_IPK | WHERE_ONEROW;
        loop.a_lterm[0] = t;
        loop.n_lterm = 1;
        loop.btree.n_eq = 1;
        // TUNING: cost of a rowid lookup is 10.
        loop.r_run = 33;
    } else {
        var it = tab.index;
        while (it) |idx| : (it = idx.next) {
            std.debug.assert(loop.a_lterm.ptr == @as([*]?*WhereTerm, &loop.a_lterm_space));
            if (!idx.isUnique() or idx.part_idx_where != null or idx.n_key_col > loop.a_lterm_space.len) continue;
            const op_mask: u32 = if (idx.uniq_not_null) WO.EQ | WO.IS else WO.EQ;
            var j: usize = 0;
            while (j < idx.n_key_col) : (j += 1) {
                term = wl.whereScanInit(&scan, wc, i_cur, @intCast(j), op_mask, idx);
                while (term != null and term.?.prereq_right != 0) term = wl.whereScanNext(&scan);
                if (term == null) break;
                loop.a_lterm[j] = term;
            }
            if (j != idx.n_key_col) continue;
            loop.ws_flags = WHERE_COLUMN_EQ | WHERE_ONEROW | WHERE_INDEXED;
            if (idx.is_covering or item.col_used & idx.col_not_idxed == 0) {
                loop.ws_flags |= WHERE_IDX_ONLY;
            }
            loop.n_lterm = @intCast(j);
            loop.btree.n_eq = @intCast(j);
            loop.btree.index = idx;
            // TUNING: cost of a unique index lookup is 15.
            loop.r_run = 39;
            break;
        }
    }
    if (loop.ws_flags != 0) {
        loop.n_out = 1;
        w.a[0].w_loop = loop;
        std.debug.assert(w.s_mask_set.n == 1 and i_cur == w.s_mask_set.ix[0]);
        loop.mask_self = 1;
        w.a[0].i_tab_cur = i_cur;
        w.n_row_out = 1;
        if (w.order_by) |ob| w.n_ob_sat = @intCast(ob.len());
        if (w.wctrl_flags & WHERE.WANT_DISTINCT != 0) {
            w.e_distinct = int.WHERE_DISTINCT_UNIQUE;
        }
        if (scan.i_equiv > 1) loop.ws_flags |= WHERE_TRANSCONS;
        return true;
    }
    return false;
}

/// Port of exprNodeIsDeterministic().
fn exprNodeIsDeterministic(walk: *walker.Walker, e: *Expr) u8 {
    if (e.op == TK.FUNCTION and !e.has(EP.ConstFunc)) {
        walk.e_code = 0;
        return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of exprIsDeterministic(): no non-deterministic SQL functions
/// outside of subqueries.
fn exprIsDeterministic(e: *Expr) bool {
    var walk: walker.Walker = .{
        .e_code = 1,
        .expr_callback = exprNodeIsDeterministic,
        .select_callback = walker.selectWalkFail,
    };
    _ = walker.walkExpr(&walk, e);
    return walk.e_code != 0;
}

/// Port of whereOmitNoopJoin(): drop the tables of a join that cannot
/// affect the result: (2) the right side of a LEFT JOIN, (3) with
/// DISTINCT or a one-row loop, (4) not used outside its own ON/USING
/// clause, (5) without an inner-join ON clause if there is a RIGHT JOIN.
/// The caller checks (1) not an aggregate, (6) a short enough ORDER BY,
/// and (7) the optimization is enabled.
fn whereOmitNoopJoin(w: *WhereInfo, not_ready_arg: Bitmask) Bitmask {
    var not_ready = not_ready_arg;
    std.debug.assert(w.n_level >= 2);
    std.debug.assert(!w.parse.db.optDisabled(OPT.OmitNoopJoin));
    std.debug.assert(w.result_set != null);
    std.debug.assert(w.wctrl_flags & WHERE.AGG_DISTINCT == 0);

    var tab_used = we.exprListUsage(&w.s_mask_set, w.result_set);
    if (w.order_by != null) {
        tab_used |= we.exprListUsage(&w.s_mask_set, w.order_by);
    }
    const has_right_join = w.tab_list.at(0).fg.jointype & JT.LTORJ != 0;
    var i: usize = w.n_level - 1;
    while (i >= 1) : (i -= 1) {
        const loop = w.a[i].w_loop.?;
        const item = w.tab_list.at(loop.i_tab);
        if (item.fg.jointype & (JT.LEFT | JT.RIGHT) != JT.LEFT) continue;
        if (w.wctrl_flags & WHERE.WANT_DISTINCT == 0 and loop.ws_flags & WHERE_ONEROW == 0) continue;
        if (tab_used & loop.mask_self != 0) continue;
        const terms = w.s_wc.terms();
        var k: usize = 0;
        while (k < terms.len) : (k += 1) {
            const term = &terms[k];
            if (term.prereq_all & loop.mask_self != 0) {
                if (!term.expr.has(EP.OuterON) or term.expr.w.join != item.i_cursor) break;
            }
            if (has_right_join and term.expr.has(EP.InnerON) and term.expr.w.join == item.i_cursor) {
                break; // restriction (5)
            }
        }
        if (k < terms.len) continue;
        const m1: Bitmask = maskBit(i) - 1;
        w.rev_mask = (m1 & w.rev_mask) | ((w.rev_mask >> 1) & ~m1);
        not_ready &= ~loop.mask_self;
        for (terms) |*term| {
            if (term.prereq_all & loop.mask_self != 0) {
                term.wt_flags |= TERM.CODED;
                term.prereq_all = 0;
            }
        }
        if (i != w.n_level - 1) {
            std.mem.copyForwards(WhereLevel, w.a[i .. w.n_level - 1], w.a[i + 1 .. w.n_level]);
        }
        w.n_level -= 1;
        std.debug.assert(w.n_level > 0);
    }
    return not_ready;
}

/// Port of whereCheckIfBloomFilterIsUseful(): set WHERE_BLOOMFILTER on
/// SEARCH loops that (1) run more times than their table has rows, (2)
/// are expected to find no row sometimes (WHERE_SELFCULL), (4) on a table
/// with ANALYZE data. The caller checks (3) Bloom filters are enabled.
fn whereCheckIfBloomFilterIsUseful(w: *const WhereInfo) void {
    var n_search: LogEst = 0;
    std.debug.assert(w.n_level >= 2);
    std.debug.assert(!w.parse.db.optDisabled(OPT.BloomFilter));
    for (w.a[0..w.n_level], 0..) |*level, i| {
        const loop = level.w_loop.?;
        const req_flags: u32 = WHERE_SELFCULL | WHERE_COLUMN_EQ;
        const item = w.tab_list.at(loop.i_tab);
        const tab = item.s_tab.?;
        if (tab.tab_flags & TF.HasStat1 == 0) break;
        tab.tab_flags |= TF.MaybeReanalyze;
        if (i >= 1 and
            loop.ws_flags & req_flags == req_flags and
            we.loopBloomable(loop) and
            n_search > tab.n_row_log_est)
        {
            loop.ws_flags |= WHERE_BLOOMFILTER;
            loop.ws_flags &= ~WHERE_IDX_ONLY;
        }
        n_search = le(@as(i32, n_search) + loop.n_out);
    }
}

/// Port of whereAddIndexedExpr(): add the expressions of index `idx`
/// (cursor `i_idx_cur`) to p.idx_epr, so that the code generator reads
/// them from the index instead of computing them.
fn whereAddIndexedExpr(p: *Parse, idx: *Index, i_idx_cur: i32, tab_item: *SrcItem) Oom!void {
    std.debug.assert(idx.has_expr);
    const tab = idx.table;
    var i: usize = 0;
    while (i < idx.n_column) : (i += 1) {
        const j = idx.ai_column[i];
        var e: ?*Expr = undefined;
        if (j == XN_EXPR) {
            e = idx.col_expr.?.at(i).expr;
        } else if (j >= 0 and tab.cols[@intCast(j)].col_flags & int.COLFLAG.VIRTUAL != 0) {
            e = build.columnExpr(tab, &tab.cols[@intCast(j)]);
        } else {
            continue;
        }
        if (expr_mod.isConstant(null, e)) continue;
        const ie = try p.arena.create(int.IndexedExpr);
        ie.* = .{
            .expr = (try expr_mod.exprDup(p.arena, e)).?,
            .i_data_cur = tab_item.i_cursor,
            .i_idx_cur = i_idx_cur,
            .i_idx_col = @intCast(i),
            .b_maybe_null_row = tab_item.fg.jointype & (JT.LEFT | JT.LTORJ | JT.RIGHT) != 0,
            .next = p.idx_epr,
        };
        if (insert.indexAffinityStr(p, idx)) |aff| ie.aff = aff[i];
        p.idx_epr = ie;
        // The parser cleanup that frees the list is not needed with the
        // arena.
    }
}

/// Port of whereReverseScanOrder(): PRAGMA reverse_unordered_selects:
/// reverse every table except MATERIALIZED CTEs with their own ORDER BY.
fn whereReverseScanOrder(w: *WhereInfo) void {
    for (w.tab_list.slice(), 0..) |*item, ii| {
        if (!item.fg.is_cte or
            item.u2.cte_use.?.e_m10d != .yes or
            !item.fg.is_subquery or
            item.u4.subq.?.select.order_by == null)
        {
            w.rev_mask |= maskBit(ii);
        }
    }
}

/// Port of whereInfoFree(): the memory is the Parse arena's, so only the
/// WHERE clause is cleared and the idxStr the loops own freed.
fn whereInfoFree(w: *WhereInfo) void {
    we.clauseClear(&w.s_wc);
    freeLoops(w);
}

/// The whereLoopDelete() calls of whereInfoFree(): free what the loops
/// own outside the arena.
fn freeLoops(w: *WhereInfo) void {
    var it = w.loops;
    while (it) |l| : (it = l.next_loop) wl.whereLoopClearUnion(w.parse.db, l);
}

/// The whereBeginError path of sqlite3WhereBegin().
fn whereBeginError(w: *WhereInfo) ?*WhereInfo {
    w.parse.n_query_loop = w.saved_n_query_loop;
    whereInfoFree(w);
    return null;
}

/// Port of sqlite3WhereBegin(): plan the loops over `tab_list` that visit
/// the rows satisfying `where` and code their beginning. The caller codes
/// the body, then calls whereEnd(). `order_by` is the ORDER BY, or with
/// WHERE_GROUPBY the GROUP BY. `i_aux_arg` is the index cursor with
/// WHERE_OR_SUBCLAUSE, the first index cursor with WHERE_ONEPASS_DESIRED,
/// or the LIMIT with WHERE_USE_LIMIT. Null on error (p.n_err or OOM set).
pub fn whereBegin(p: *Parse, tab_list: *SrcList, where: ?*Expr, order_by: ?*ExprList, result_set: ?*ExprList, sel: ?*Select, wctrl_flags: u16, i_aux_arg: i32) ?*WhereInfo {
    const saved_n_query_loop = p.n_query_loop;
    return whereBeginImpl(p, tab_list, where, order_by, result_set, sel, wctrl_flags, i_aux_arg) catch {
        p.n_query_loop = saved_n_query_loop;
        build.oomFault(p);
        return null;
    };
}

fn whereBeginImpl(p: *Parse, tab_list: *SrcList, where: ?*Expr, order_by_arg: ?*ExprList, result_set: ?*ExprList, sel: ?*Select, wctrl_flags_arg: u16, i_aux_arg: i32) Oom!?*WhereInfo {
    var order_by = order_by_arg;
    var wctrl_flags = wctrl_flags_arg;
    const db = p.db;
    var b_fordelete: u16 = 0;

    std.debug.assert(wctrl_flags & WHERE.ONEPASS_MULTIROW == 0 or
        (wctrl_flags & WHERE.ONEPASS_DESIRED != 0 and wctrl_flags & WHERE.OR_SUBCLAUSE == 0));
    // Only one of WHERE_OR_SUBCLAUSE or WHERE_USE_LIMIT.
    std.debug.assert(wctrl_flags & WHERE.OR_SUBCLAUSE == 0 or wctrl_flags & WHERE.USE_LIMIT == 0);

    // An ORDER/GROUP BY of more than 63 terms cannot be optimized.
    if (order_by != null and order_by.?.len() >= BMS) {
        order_by = null;
        wctrl_flags &= ~WHERE.WANT_DISTINCT;
        // Disable the omit-noop-join optimization.
        wctrl_flags |= WHERE.KEEP_ALL_JOINS;
    }

    // The number of tables in a join is limited by the bits of a Bitmask.
    if (tab_list.len() > BMS) {
        util.errorMsg(p, "at most {d} tables in a join", .{BMS});
        return null;
    }

    // With WHERE_OR_SUBCLAUSE only the first table is coded; the cursors
    // of the others are uninitialized.
    var n_tab_list: usize = if (wctrl_flags & WHERE.OR_SUBCLAUSE != 0) 1 else tab_list.len();

    // The WhereInfo, its levels and the template WhereLoop.
    const w = try p.arena.create(WhereInfo);
    w.* = .{
        .parse = p,
        .tab_list = tab_list,
        .order_by = order_by,
        .result_set = result_set,
        .n_level = @intCast(n_tab_list),
        .wctrl_flags = wctrl_flags,
        .i_limit = le(i_aux_arg),
        .saved_n_query_loop = p.n_query_loop,
        .select = sel,
        .s_wc = undefined,
        .a = try p.arena.alloc(WhereLevel, n_tab_list),
    };
    @memset(w.a, .{});
    // On OOM, as whereInfoFree() of whereBeginError.
    errdefer freeLoops(w);
    w.i_break = aux.makeLabel(p);
    w.i_continue = w.i_break;
    std.debug.assert(w.e_one_pass == ONEPASS_OFF);
    const mask_set = &w.s_mask_set;
    mask_set.n = 0;
    // Never a valid cursor, so getMask() needs no test for n==0.
    mask_set.ix[0] = -99;
    const new = try p.arena.create(WhereLoop);
    new.* = .{};
    wl.whereLoopInit(new);
    var builder: WhereLoopBuilder = .{ .w_info = w, .wc = &w.s_wc, .new = new };

    // Split the WHERE clause into its AND-connected terms.
    we.clauseInit(&w.s_wc, w);
    try we.split(&w.s_wc, where, TK.AND);

    if (n_tab_list == 0) {
        // Special case: no FROM clause.
        if (order_by) |ob| w.n_ob_sat = @intCast(ob.len());
        if (wctrl_flags & WHERE.WANT_DISTINCT != 0 and !db.optDisabled(OPT.DistinctOpt)) {
            w.e_distinct = int.WHERE_DISTINCT_UNIQUE;
        }
        if (w.select) |s| {
            if (s.sel_flags & int.SF.MultiValue == 0) {
                _ = aux.explain(p, false, "SCAN CONSTANT ROW", .{});
            }
        }
    } else {
        // FROM term N gets the bit 1<<N, so for the bit X of table T, X-1
        // is the mask of the tables left of T (ticket #3015). Every term
        // gets one, not just the first n_tab_list.
        for (tab_list.slice()) |*item| {
            wi.createMask(mask_set, item.i_cursor);
            try we.tabFuncArgs(p, item, &w.s_wc);
        }
    }

    // Analyze all of the subexpressions.
    try we.exprAnalyze(tab_list, &w.s_wc);
    if (sel) |s| {
        if (s.limit != null) try we.addLimit(&w.s_wc, s);
    }
    if (p.n_err != 0) return whereBeginError(w);

    // The False-WHERE-Term-Bypass optimization: a term that (1) uses no
    // table of the join, (2) is not from the ON clause of the right side
    // of a LEFT or FULL JOIN, (3) is not from an ON clause or there is no
    // RIGHT or FULL JOIN, and (4) has no non-deterministic functions
    // outside subqueries (legacy behaviour of "WHERE random()>0") is
    // tested once, before the loops.
    var ii: usize = 0;
    while (ii < builder.wc.n_base) : (ii += 1) {
        const t = &builder.wc.a[ii];
        if (t.wt_flags & TERM.VIRTUAL != 0) continue;
        const x = t.expr;
        std.debug.assert(t.prereq_all != 0 or !x.has(EP.OuterON));
        if (t.prereq_all == 0 and
            (n_tab_list == 0 or exprIsDeterministic(x)) and
            !(x.has(EP.InnerON) and tab_list.at(0).fg.jointype & JT.LTORJ != 0))
        {
            ec.exprIfFalse(p, x, w.i_break, vi.SQLITE_JUMPIFNULL);
            t.wt_flags |= TERM.CODED;
        }
    }

    if (wctrl_flags & WHERE.WANT_DISTINCT != 0) {
        if (db.optDisabled(OPT.DistinctOpt)) {
            wctrl_flags &= ~WHERE.WANT_DISTINCT;
            w.wctrl_flags &= ~WHERE.WANT_DISTINCT;
        } else if (wl.isDistinctRedundant(p, tab_list, &w.s_wc, result_set.?)) {
            // The DISTINCT marking is pointless.
            w.e_distinct = int.WHERE_DISTINCT_UNIQUE;
        } else if (order_by == null) {
            // ORDER BY the result set to make DISTINCT easier.
            w.wctrl_flags |= WHERE.DISTINCTBY;
            w.order_by = result_set;
        }
    }

    // Construct the WhereLoop objects and choose the plan.
    if (n_tab_list != 1 or !whereShortCut(&builder)) {
        const rc = try wl.whereLoopAddAll(&builder);
        if (rc != 0) return whereBeginError(w);
        // (The STAT4 second pass is not ported.)
        if (wi.traceEnabled()) wi.showAllLoops(w, builder.wc);

        _ = try wherePathSolver(w, 0);
        if (db.malloc_failed) return whereBeginError(w);
        if (w.order_by != null) {
            whereInterstageHeuristic(w);
            _ = try wherePathSolver(w, if (w.n_row_out < 0) 1 else le(@as(i32, w.n_row_out) + 1));
            if (db.malloc_failed) return whereBeginError(w);
        }

        // TUNING: DISTINCT on a subquery reduces the output by 8x
        // (tag-20250414a).
        if (w.wctrl_flags & WHERE.WANT_DISTINCT != 0) {
            w.n_row_out = le(@as(i32, w.n_row_out) - 30);
        }
    }
    if (w.order_by == null and db.flags & int.DbFlag.ReverseOrder != 0) {
        whereReverseScanOrder(w);
    }
    if (p.n_err != 0) return whereBeginError(w);
    std.debug.assert(!db.malloc_failed);

    // Omit the tables of a join that do not affect the result.
    var not_ready: Bitmask = ~@as(Bitmask, 0);
    if (w.n_level >= 2 and // must be a join
        result_set != null and // condition (1)
        wctrl_flags & (WHERE.AGG_DISTINCT | WHERE.KEEP_ALL_JOINS) == 0 and // (1),(6)
        !db.optDisabled(OPT.OmitNoopJoin)) // (7)
    {
        not_ready = whereOmitNoopJoin(w, not_ready);
        n_tab_list = w.n_level;
        std.debug.assert(n_tab_list > 0);
    }

    // SEARCH loops that might benefit from a Bloom filter.
    if (w.n_level >= 2 and !db.optDisabled(OPT.BloomFilter)) {
        whereCheckIfBloomFilterIsUseful(w);
    }

    p.n_query_loop = le(@as(i32, p.n_query_loop) + w.n_row_out);

    // An UPDATE or DELETE may work on the rows as they are found if it
    // asks to and the scan visits at most one row, or if multiple rows
    // are allowed, the table is not virtual, and the scan does not use the
    // OR optimization unless this is a DELETE (WHERE_DUPLICATES_OK): an
    // UPDATE relies on aiCurOnePass[1], which the OR optimization does not
    // set accurately.
    std.debug.assert(wctrl_flags & WHERE.ONEPASS_DESIRED == 0 or w.n_level == 1);
    if (wctrl_flags & WHERE.ONEPASS_DESIRED != 0) {
        const ws_flags = w.a[0].w_loop.?.ws_flags;
        const b_onerow = ws_flags & WHERE_ONEROW != 0;
        std.debug.assert(ws_flags & WHERE_VIRTUALTABLE == 0 or tab_list.at(0).s_tab.?.e_tab_type == .vtab);
        if (b_onerow or
            (wctrl_flags & WHERE.ONEPASS_MULTIROW != 0 and
                tab_list.at(0).s_tab.?.e_tab_type != .vtab and
                (ws_flags & WHERE_MULTI_OR == 0 or wctrl_flags & WHERE.DUPLICATES_OK != 0) and
                !db.optDisabled(OPT.OnePass)))
        {
            w.e_one_pass = if (b_onerow) ONEPASS_SINGLE else ONEPASS_MULTI;
            if (tab_list.at(0).s_tab.?.hasRowid() and ws_flags & WHERE_IDX_ONLY != 0) {
                if (wctrl_flags & WHERE.ONEPASS_MULTIROW != 0) {
                    b_fordelete = vi.OPFLAG.FORDELETE;
                }
                w.a[0].w_loop.?.ws_flags = ws_flags & ~WHERE_IDX_ONLY;
            }
        }
    }

    const v = p.vdbe.?;

    // Open the tables of the loops and the indexes they search.
    ii = 0;
    while (ii < n_tab_list) : (ii += 1) {
        const level = &w.a[ii];
        const tab_item = tab_list.at(level.i_from);
        const tab = tab_item.s_tab.?;
        const i_db = prepare.schemaToIndex(db, tab.schema);
        const loop = level.w_loop.?;
        level.addr_brk = aux.makeLabel(p);
        if (ii == 0 or tab_item.fg.jointype & JT.LEFT != 0) {
            level.addr_halt = level.addr_brk;
        } else if (w.a[ii - 1].rj != null) {
            level.addr_halt = w.a[ii - 1].addr_brk;
        } else {
            level.addr_halt = w.a[ii - 1].addr_halt;
        }
        if (tab.tab_flags & TF.Ephemeral != 0 or tab.isView()) {
            // Do nothing.
        } else if (loop.ws_flags & WHERE_VIRTUALTABLE != 0) {
            _ = aux.addOp4(v, OP.VOpen, tab_item.i_cursor, 0, 0, build.vtabP4(db, tab));
        } else if (tab.isVirtual()) {
            // Nothing.
        } else if ((loop.ws_flags & WHERE_IDX_ONLY == 0 and wctrl_flags & WHERE.OR_SUBCLAUSE == 0) or
            tab_item.fg.jointype & (JT.LTORJ | JT.RIGHT) != 0)
        {
            var op: u8 = OP.OpenRead;
            if (w.e_one_pass != ONEPASS_OFF) {
                op = OP.OpenWrite;
                w.ai_cur_one_pass[0] = tab_item.i_cursor;
            }
            insert.openTable(p, tab_item.i_cursor, @intCast(i_db), tab, op);
            std.debug.assert(tab_item.i_cursor == level.i_tab_cur);
            if (w.e_one_pass == ONEPASS_OFF and
                tab.nCol() < BMS and
                tab.tab_flags & (TF.HasGenerated | TF.WithoutRowid) == 0 and
                loop.ws_flags & (WHERE_AUTO_INDEX | WHERE_BLOOMFILTER) == 0)
            {
                // Only a prefix of the record is used: reduce the column
                // count in P4 of the OP_OpenRead/Write.
                var b = tab_item.col_used;
                var n: i32 = 0;
                while (b != 0) : ({
                    b >>= 1;
                    n += 1;
                }) {}
                aux.changeP4(v, -1, .{ .int32 = n });
                std.debug.assert(n <= tab.nCol());
            }
            aux.changeP5(v, b_fordelete);
            if (ii >= 2 and
                tab_item.fg.jointype & (JT.LTORJ | JT.LEFT) == 0 and
                level.addr_halt == w.a[0].addr_halt)
            {
                _ = aux.addOp2(v, OP.IfEmpty, tab_item.i_cursor, w.i_break);
            }
        } else {
            // sqlite3TableLock(): nothing to do without shared cache.
        }
        if (loop.ws_flags & WHERE_INDEXED != 0) {
            const ix = loop.btree.index.?;
            var i_index_cur: i32 = undefined;
            var op: u8 = OP.OpenRead;
            // i_aux_arg is always positive if ONEPASS is possible.
            std.debug.assert(i_aux_arg != 0 or w.wctrl_flags & WHERE.ONEPASS_DESIRED == 0);
            if (!tab.hasRowid() and ix.isPrimaryKey() and wctrl_flags & WHERE.OR_SUBCLAUSE != 0) {
                // One term of an OR-optimization on the PRIMARY KEY of a
                // WITHOUT ROWID table: no separate index.
                i_index_cur = level.i_tab_cur;
                op = 0;
            } else if (w.e_one_pass != ONEPASS_OFF) {
                var j = tab_item.s_tab.?.index;
                i_index_cur = i_aux_arg;
                std.debug.assert(wctrl_flags & WHERE.ONEPASS_DESIRED != 0);
                while (j != null and j.? != ix) {
                    i_index_cur += 1;
                    j = j.?.next;
                }
                op = OP.OpenWrite;
                w.ai_cur_one_pass[1] = i_index_cur;
            } else if (i_aux_arg != 0 and wctrl_flags & WHERE.OR_SUBCLAUSE != 0) {
                i_index_cur = i_aux_arg;
                op = OP.ReopenIdx;
            } else {
                i_index_cur = p.n_tab;
                p.n_tab += 1;
                if (ix.has_expr and !db.optDisabled(OPT.IndexedExpr)) {
                    try whereAddIndexedExpr(p, ix, i_index_cur, tab_item);
                }
                if (ix.part_idx_where != null and tab_item.fg.jointype & JT.RIGHT == 0) {
                    try wl.wherePartIdxExpr(p, ix, ix.part_idx_where, null, i_index_cur, tab_item);
                }
            }
            level.i_idx_cur = i_index_cur;
            std.debug.assert(ix.schema == tab.schema);
            std.debug.assert(i_index_cur >= 0);
            if (op != 0) {
                _ = aux.addOp3(v, op, i_index_cur, @intCast(ix.tnum), i_db);
                aux.setP4KeyInfo(p, ix);
                if (loop.ws_flags & WHERE_CONSTRAINT != 0 and
                    loop.ws_flags & (WHERE_COLUMN_RANGE | WHERE_SKIPSCAN) == 0 and
                    loop.ws_flags & WHERE_BIGNULL_SORT == 0 and
                    loop.ws_flags & WHERE_IN_SEEKSCAN == 0 and
                    w.wctrl_flags & WHERE.ORDERBY_MIN == 0 and
                    w.e_distinct != int.WHERE_DISTINCT_ORDERED)
                {
                    aux.changeP5(v, vi.OPFLAG.SEEKEQ);
                }
            }
        }
        if (i_db >= 0) build.codeVerifySchema(p, @intCast(i_db));
        if (tab_item.fg.jointype & JT.RIGHT != 0) {
            const rj = try p.arena.create(WhereRightJoin);
            rj.* = .{};
            level.rj = rj;
            var b_bloomable = false;
            rj.i_match = p.n_tab;
            p.n_tab += 1;
            p.n_mem += 1;
            rj.reg_return = p.n_mem;
            _ = aux.addOp2(v, OP.Null, 0, rj.reg_return);
            std.debug.assert(tab == tab_item.s_tab.?);
            if (tab.hasRowid()) {
                _ = aux.addOp2(v, OP.OpenEphemeral, rj.i_match, 1);
                b_bloomable = true;
                if (select.keyInfoAlloc(p, 1, 0)) |info| {
                    info.coll[0] = null;
                    info.sort_flags[0] = 0;
                    aux.appendP4(v, .{ .keyinfo = info });
                }
            } else {
                const pk = build.primaryKeyIndex(tab).?;
                _ = aux.addOp2(v, OP.OpenEphemeral, rj.i_match, pk.n_key_col);
                aux.setP4KeyInfo(p, pk);
                b_bloomable = build.indexBloomable(pk, pk.n_key_col);
            }
            if (b_bloomable) {
                p.n_mem += 1;
                rj.reg_bloom = p.n_mem;
                _ = aux.addOp2(v, OP.Blob, 65536, rj.reg_bloom);
            } else {
                rj.reg_bloom = 0;
            }
            loop.ws_flags &= ~WHERE_IDX_ONLY;
            // RIGHT JOIN processing messes up the output order, so a real
            // sort is needed.
            w.n_ob_sat = 0;
            w.e_distinct = int.WHERE_DISTINCT_UNORDERED;
        }
    }
    w.i_top = aux.currentAddr(v);
    if (db.malloc_failed) return whereBeginError(w);

    // Code the search, one nested loop per iteration.
    ii = 0;
    while (ii < n_tab_list) : (ii += 1) {
        if (p.n_err != 0) return whereBeginError(w);
        const level = &w.a[ii];
        const ws_flags = level.w_loop.?.ws_flags;
        const src = tab_list.at(level.i_from);
        if (src.fg.is_materialized) {
            std.debug.assert(src.fg.is_subquery);
            const subq = src.u4.subq.?;
            var i_once: i32 = 0;
            if (!src.fg.is_correlated) {
                i_once = aux.addOp0(v, OP.Once);
            } else {
                i_once = 0;
            }
            _ = aux.addOp2(v, OP.Gosub, subq.reg_return, subq.addr_fill_sub);
            if (i_once != 0) aux.jumpHere(v, i_once);
        }
        std.debug.assert(tab_list == w.tab_list);
        if (ws_flags & (WHERE_AUTO_INDEX | WHERE_BLOOMFILTER) != 0) {
            if (ws_flags & WHERE_AUTO_INDEX != 0) {
                try constructAutomaticIndex(p, &w.s_wc, not_ready, level);
            } else {
                try constructBloomFilter(w, ii, level, not_ready);
            }
            if (db.malloc_failed) return whereBeginError(w);
        }
        const addr_explain = try wc_mod.explainOneScan(p, tab_list, level, wctrl_flags);
        level.addr_body = aux.currentAddr(v);
        not_ready = try wc_mod.codeOneLoopStart(p, v, w, ii, level, not_ready);
        w.i_continue = level.addr_cont;
        if (ws_flags & WHERE_MULTI_OR == 0 and wctrl_flags & WHERE.OR_SUBCLAUSE == 0) {
            wc_mod.addScanStatus(v, tab_list, level, addr_explain);
        }
    }

    // Done.
    w.i_end_where = aux.currentAddr(v);
    return w;
}

/// Port of sqlite3WhereEnd(): code the end of the loops opened by
/// whereBegin(), then rewrite the table reads in the loop bodies into
/// index reads where an index is used.
pub fn whereEnd(w: *WhereInfo) void {
    const p = w.parse;
    const v = p.vdbe.?;
    const tab_list = w.tab_list;
    const db = p.db;
    const i_end = aux.currentAddr(v);
    var n_rj: u8 = 0;
    var addr_seek: i32 = 0;

    // Loop termination code.
    var i: usize = w.n_level;
    while (i > 0) {
        i -= 1;
        const level = &w.a[i];
        if (level.rj) |rj| {
            // End the subroutine that is the interior of the loop of the
            // RIGHT JOIN table. addr_cont gets a new label that is never
            // used, for the resolveLabel() below.
            aux.resolveLabel(v, level.addr_cont);
            level.addr_cont = aux.makeLabel(p);
            rj.end_subrtn = aux.currentAddr(v);
            _ = aux.addOp3(v, OP.Return, rj.reg_return, rj.addr_subrtn, 1);
            n_rj += 1;
        }
        const loop = level.w_loop.?;
        if (level.op != OP.Noop) {
            // Skip-ahead DISTINCT (SQLITE_DISABLE_SKIPAHEAD_DISTINCT off).
            if (w.e_distinct == int.WHERE_DISTINCT_ORDERED and
                i == w.n_level - 1 and // Ticket [ef9318757b152e3] 2017-10-21
                loop.ws_flags & WHERE_INDEXED != 0 and
                loop.btree.index.?.has_stat1 and
                loop.btree.n_distinct_col > 0 and
                loop.btree.index.?.ai_row_log_est[loop.btree.n_distinct_col] >= 36)
            {
                const n: i32 = loop.btree.n_distinct_col;
                const r1 = p.n_mem + 1;
                var addr_if_null: i32 = 0;
                if (level.i_left_join != 0) {
                    addr_if_null = aux.addOp2(v, OP.IfNullRow, level.i_idx_cur, r1);
                }
                var j: i32 = 0;
                while (j < n) : (j += 1) {
                    _ = aux.addOp3(v, OP.Column, level.i_idx_cur, j, r1 + j);
                }
                p.n_mem += n + 1;
                const op: u8 = if (level.op == OP.Prev) OP.SeekLT else OP.SeekGT;
                addr_seek = aux.addOp4Int(v, op, level.i_idx_cur, 0, r1, n);
                _ = aux.addOp2(v, OP.Goto, 1, level.p2);
                if (level.i_left_join != 0) aux.jumpHere(v, addr_if_null);
            }
        }
        if (tab_list.at(level.i_from).fg.from_exists) {
            // An EXISTS-to-JOIN loop stops at its first row.
            _ = aux.addOp2(v, OP.Goto, 0, level.addr_brk);
        }
        aux.resolveLabel(v, level.addr_cont);
        if (level.op != OP.Noop) {
            _ = aux.addOp3(v, level.op, level.p1, level.p2, level.p3);
            aux.changeP5(v, level.p5);
            if (addr_seek != 0) {
                aux.jumpHere(v, addr_seek);
                addr_seek = 0;
            }
            if (level.reg_bignull != 0) {
                aux.resolveLabel(v, level.addr_bignull);
                _ = aux.addOp2(v, OP.DecrJumpZero, level.reg_bignull, level.p2 - 1);
            }
        }
        if (loop.ws_flags & WHERE_IN_ABLE != 0 and level.nIn() > 0) {
            aux.resolveLabel(v, level.addr_nxt);
            var j = level.nIn();
            while (j > 0) : (j -= 1) {
                const in_ = &level.in_loops[j - 1];
                std.debug.assert(aux.getOp(v, in_.addr_in_top + 1).opcode == OP.IsNull or db.malloc_failed);
                aux.jumpHere(v, in_.addr_in_top + 1);
                if (in_.e_end_loop_op != OP.Noop) {
                    if (in_.n_prefix != 0) {
                        const b_early_out: i32 = @intFromBool(loop.ws_flags & WHERE_VIRTUALTABLE == 0 and
                            loop.ws_flags & WHERE_IN_EARLYOUT != 0);
                        if (level.i_left_join != 0) {
                            // Cursor in_.i_cur may be disabled by
                            // OP_NullRow; the jump NULLs in_.i_base, which
                            // is harmless as it is then unused.
                            _ = aux.addOp3(v, OP.IfNullRow, in_.i_cur, aux.currentAddr(v) + 2 + b_early_out, in_.i_base);
                        }
                        if (b_early_out != 0) {
                            _ = aux.addOp4Int(v, OP.IfNoHope, level.i_idx_cur, aux.currentAddr(v) + 2, in_.i_base, in_.n_prefix);
                            // The OP_IsNull on the left operand of IN must
                            // jump past the OP_IfNoHope too, as it skips
                            // the OP_Affinity that OP_IfNoHope needs.
                            aux.jumpHere(v, in_.addr_in_top + 1);
                        }
                    }
                    _ = aux.addOp2(v, in_.e_end_loop_op, in_.i_cur, in_.addr_in_top);
                }
                aux.jumpHere(v, in_.addr_in_top - 1);
            }
        }
        aux.resolveLabel(v, level.addr_brk);
        if (level.rj) |rj| {
            _ = aux.addOp3(v, OP.Return, rj.reg_return, 0, 1);
        }
        if (level.addr_skip != 0) {
            _ = aux.goto_(v, level.addr_skip);
            aux.jumpHere(v, level.addr_skip);
            aux.jumpHere(v, level.addr_skip - 2);
        }
        if (level.addr_like_rep != 0) {
            _ = aux.addOp2(v, OP.DecrJumpZero, @intCast(level.i_like_rep_cntr >> 1), level.addr_like_rep);
        }
        if (level.i_left_join != 0) {
            const ws = loop.ws_flags;
            const addr = aux.addOp1(v, OP.IfPos, level.i_left_join);
            std.debug.assert(ws & WHERE_IDX_ONLY == 0 or ws & WHERE_INDEXED != 0);
            if (ws & WHERE_IDX_ONLY == 0) {
                const src = tab_list.at(level.i_from);
                std.debug.assert(level.i_tab_cur == src.i_cursor);
                if (src.fg.via_coroutine) {
                    std.debug.assert(src.fg.is_subquery);
                    const n = src.u4.subq.?.reg_result;
                    const m: i32 = src.s_tab.?.nCol();
                    _ = aux.addOp3(v, OP.Null, 0, n, n + m - 1);
                }
                _ = aux.addOp1(v, OP.NullRow, level.i_tab_cur);
            }
            if (ws & WHERE_INDEXED != 0 or (ws & WHERE_MULTI_OR != 0 and level.covering_idx != null)) {
                if (ws & WHERE_MULTI_OR != 0) {
                    const ix = level.covering_idx.?;
                    const i_db = prepare.schemaToIndex(db, ix.schema);
                    _ = aux.addOp3(v, OP.ReopenIdx, level.i_idx_cur, @intCast(ix.tnum), i_db);
                    aux.setP4KeyInfo(p, ix);
                }
                _ = aux.addOp1(v, OP.NullRow, level.i_idx_cur);
            }
            if (ws & WHERE_IN_ABLE != 0) {
                for (level.in_loops) |*in_| {
                    if (in_.e_end_loop_op != OP.Noop) _ = aux.addOp1(v, OP.NullRow, in_.i_cur);
                }
            }
            if (level.op == OP.Return) {
                _ = aux.addOp2(v, OP.Gosub, level.p1, level.addr_first);
            } else {
                _ = aux.goto_(v, level.addr_first);
            }
            aux.jumpHere(v, addr);
        }
    }

    std.debug.assert(w.n_level <= tab_list.len());
    for (w.a[0..w.n_level], 0..) |*level, ii| {
        const tab_item = tab_list.at(level.i_from);
        const tab = tab_item.s_tab.?;
        const loop = level.w_loop.?;

        // RIGHT JOIN: output the unmatched rows of the right operand with
        // NULLs for the columns of the left operand.
        if (level.rj != null) {
            wc_mod.rightJoinLoop(w, ii, level) catch build.oomFault(p);
            continue;
        }

        // The columns of a co-routine are read from its result registers.
        if (tab_item.fg.via_coroutine) {
            std.debug.assert(tab_item.fg.is_subquery);
            std.debug.assert(tab_item.u4.subq.?.reg_result >= 0);
            translateColumnToCopy(p, level.addr_body, level.i_tab_cur, tab_item.u4.subq.?.reg_result, 0);
            continue;
        }

        // With an index, rewrite the table reads coded between whereBegin()
        // and whereEnd() into reads of the index where possible; sometimes
        // the table is then never read.
        var idx: ?*Index = null;
        if (loop.ws_flags & (WHERE_INDEXED | WHERE_IDX_ONLY) != 0) {
            idx = loop.btree.index;
        } else if (loop.ws_flags & WHERE_MULTI_OR != 0) {
            idx = level.covering_idx;
        }
        if (idx != null and !db.malloc_failed) {
            const ix = idx.?;
            const last = if (w.e_one_pass == ONEPASS_OFF or !ix.table.hasRowid()) i_end else w.i_end_where;
            if (ix.has_expr) {
                var it = p.idx_epr;
                while (it) |ie| : (it = ie.next) {
                    if (ie.i_idx_cur == level.i_idx_cur) {
                        ie.i_data_cur = -1;
                        ie.i_idx_cur = -1;
                    }
                }
            }
            // The op at addr_body never reads the table, hence the +1.
            var k = level.addr_body + 1;
            std.debug.assert(k <= last);
            while (true) {
                const op = aux.getOp(v, k);
                if (op.p1 != level.i_tab_cur) {
                    // no-op
                } else if (op.opcode == OP.Column) {
                    // (OP_Offset only with SQLITE_ENABLE_OFFSET_SQL_FUNC.)
                    var x: i32 = op.p2;
                    std.debug.assert(ix.table == tab);
                    if (!tab.hasRowid()) {
                        const pk = build.primaryKeyIndex(tab).?;
                        x = pk.ai_column[@intCast(x)];
                        std.debug.assert(x >= 0);
                    } else {
                        x = build.storageColumnToTable(tab, @intCast(x));
                    }
                    x = build.tableColumnToIndex(ix, x);
                    if (x >= 0) {
                        op.p2 = x;
                        op.p1 = level.i_idx_cur;
                    } else if (loop.ws_flags & (WHERE_IDX_ONLY | WHERE_EXPRIDX) != 0) {
                        if (loop.ws_flags & WHERE_IDX_ONLY != 0) {
                            // A covering index loop reads a column of the
                            // table that is not in the index.
                            util.errorMsg(p, "internal query planner error", .{});
                            p.rc = int.RC.INTERNAL;
                        } else {
                            // WHERE_EXPRIDX guessed the index covering, and
                            // this op proves otherwise: fix the EXPLAIN text.
                            loop.ws_flags &= ~WHERE_EXPRIDX;
                            wc_mod.addExplainText(p, level.addr_body - 1, tab_list, level, w.wctrl_flags) catch build.oomFault(p);
                        }
                    }
                } else if (op.opcode == OP.Rowid) {
                    op.p1 = level.i_idx_cur;
                    op.opcode = OP.IdxRowid;
                } else if (op.opcode == OP.IfNullRow) {
                    op.p1 = level.i_idx_cur;
                }
                k += 1;
                if (k >= last) break;
            }
        }
    }

    // The "break" point is just past the end of the outer loop.
    aux.resolveLabel(v, w.i_break);

    p.n_query_loop = w.saved_n_query_loop;
    whereInfoFree(w);
    p.within_rj_subrtn -= n_rj;
}
