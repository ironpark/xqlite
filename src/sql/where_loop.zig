//! Port of where.c (loop builders): WhereScan, sqlite3WhereFindTerm(), cost estimates, whereLoopAdd*().

const std = @import("std");
const int = @import("sqlite_int.zig");
const wi = @import("where_int.zig");
const WS = wi.WS;
const we = @import("where_expr.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const walker = @import("walker.zig");
const coll_mod = @import("coll.zig");
const serial = @import("../vdbe/serial.zig");
const ctype = @import("../util/ctype.zig");
const vtab = @import("vtab.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Table = int.Table;
const Index = int.Index;
const LogEst = int.LogEst;
const Bitmask = int.Bitmask;
const Oom = int.Oom;
const ParseError = int.ParseError;
const RC = int.RC;
const TK = int.TK;
const EP = int.EP;
const JT = int.JT;
const TF = int.TF;
const SF = int.SF;
const OE = int.OE;
const OPT = int.OPT;
const WHERE = int.WHERE;
const Aff = int.Aff;
const XN_ROWID = int.XN_ROWID;
const XN_EXPR = int.XN_EXPR;
const Walker = walker.Walker;
const WRC = walker.WRC;
const WhereInfo = wi.WhereInfo;
const WhereClause = wi.WhereClause;
const WhereTerm = wi.WhereTerm;
const WhereScan = wi.WhereScan;
const WhereLoop = wi.WhereLoop;
const WhereLoopBuilder = wi.WhereLoopBuilder;
const WhereOrSet = wi.WhereOrSet;
const WO = wi.WO;
const TERM = wi.TERM;

/// The outcome of whereLoopInsert() and the whereLoopAdd*() family when
/// it does not fail: `done` is C's SQLITE_DONE, the query planner search
/// limit was hit and the search stops.
const Flow = enum { ok, done };

/// The failures of the whereLoopAdd*() family: running out of memory, or
/// error.ParseFailed where C returns another nonzero result code (an
/// error of xBestIndex, a malfunction it causes, or an earlier error of
/// the Parse). The error is then already in the Parse; only its being
/// nonzero matters to the caller, as in C.
const AddError = Oom || ParseError;

/// C's `rc==SQLITE_OK` for the rc of the whereLoopAdd*() family.
fn isOk(rc: AddError!Flow) bool {
    return if (rc) |flow| flow == .ok else |_| false;
}

/// TOPBIT: the "column 63 or later" bit of a column-usage Bitmask.
const TOPBIT: Bitmask = @as(Bitmask, 1) << (int.bms - 1);

/// SQLITE_INDEX_CONSTRAINT_LIKE, as returned by exprIsLikeOperator().
const INDEX_CONSTRAINT_LIKE: u8 = 65;

/// The index of `t` in `wc.a` (C pointer arithmetic pTerm - pWC->a).
fn termIndex(wc: *const WhereClause, t: *const WhereTerm) usize {
    return (@intFromPtr(t) - @intFromPtr(wc.a.ptr)) / @sizeOf(WhereTerm);
}

// ============================================================ WhereOrSet

/// Port of whereOrMove(): move the content of `src` into `dest`.
fn whereOrMove(dest: *WhereOrSet, src: *const WhereOrSet) void {
    dest.n = src.n;
    @memcpy(dest.a[0..dest.n], src.a[0..src.n]);
}

/// Port of whereOrInsert(): keep the N_OR_COST best prerequisite/cost
/// entries in `set`. True if the new entry was kept.
pub fn whereOrInsert(set: *WhereOrSet, prereq: Bitmask, r_run: LogEst, n_out: LogEst) bool {
    var p: *wi.WhereOrCost = undefined;
    found: {
        var i: usize = 0;
        while (i < set.n) : (i += 1) {
            p = &set.a[i];
            if (r_run <= p.r_run and (prereq & p.prereq) == prereq) break :found;
            if (p.r_run <= r_run and (p.prereq & prereq) == p.prereq) return false;
        }
        if (set.n < wi.N_OR_COST) {
            p = &set.a[set.n];
            set.n += 1;
            p.n_out = n_out;
        } else {
            p = &set.a[0];
            var j: usize = 1;
            while (j < set.n) : (j += 1) {
                if (p.r_run > set.a[j].r_run) p = &set.a[j];
            }
            if (p.r_run <= r_run) return false;
        }
    }
    p.prereq = prereq;
    p.r_run = r_run;
    if (p.n_out > n_out) p.n_out = n_out;
    return true;
}

// ============================================================ WhereScan

/// Port of whereRightSubexprIsColumn(): the right operand of `p` if it is
/// a TK_COLUMN (not EP_FixedCol), else null.
fn whereRightSubexprIsColumn(p: *Expr) ?*Expr {
    const r = expr_mod.skipCollateAndLikely(p.right) orelse return null;
    if (r.op == TK.COLUMN and !r.flags.FixedCol) return r;
    return null;
}

/// Port of indexInAffinityOk(): the collation name of WO_IN term `term`
/// if it is compatible with an index column of affinity `idxaff`, else
/// null. Handles one field of "(x,y,..) IN (SELECT ...)".
fn indexInAffinityOk(p: *Parse, term: *WhereTerm, idxaff: u8) ?[]const u8 {
    var x: *Expr = term.expr;
    var inexpr: Expr = .{ .op = TK.EQ };
    std.debug.assert(term.e_operator & WO.IN != 0);
    if (expr_mod.isVector(x.left.?)) {
        const i_field: usize = @intCast(term.i_field - 1);
        inexpr.left = x.left.?.x.list.?.at(i_field).expr;
        std.debug.assert(x.useXSelect());
        inexpr.right = x.x.select.?.e_list.?.at(i_field).expr;
        x = &inexpr;
    }
    if (expr_mod.indexAffinityOk(x, idxaff)) {
        const ret = expr_mod.compareCollSeq(p, x);
        return if (ret) |c| c.name else coll_mod.str_binary;
    }
    return null;
}

/// Port of whereScanNext(): the next WhereTerm matching the criteria set
/// up by whereScanInit(), or null.
pub fn whereScanNext(scan: *WhereScan) ?*WhereTerm {
    var k: i32 = scan.k;
    std.debug.assert(scan.i_equiv <= scan.n_equiv);
    var wc_opt: ?*WhereClause = scan.wc;
    while (true) {
        const i_column: i16 = scan.ai_column[scan.i_equiv - 1];
        const i_cur: i32 = scan.ai_cur[scan.i_equiv - 1];
        std.debug.assert(i_cur >= 0);
        while (wc_opt) |wc| {
            while (k < wc.n_term) : (k += 1) {
                const term = &wc.a[@intCast(k)];
                std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0 or term.left_cursor < 0);
                if (term.left_cursor == i_cur and
                    term.left_column == i_column and
                    (i_column != XN_EXPR or
                        expr_mod.compareSkip(term.expr.left, scan.idx_expr, i_cur) == 0) and
                    (scan.i_equiv <= 1 or !term.expr.flags.OuterON))
                {
                    if (term.e_operator & WO.EQUIV != 0 and scan.n_equiv < scan.ai_cur.len) {
                        if (whereRightSubexprIsColumn(term.expr)) |x| {
                            var j: usize = 0;
                            while (j < scan.n_equiv) : (j += 1) {
                                if (scan.ai_cur[j] == x.i_table and scan.ai_column[j] == x.i_column) break;
                            }
                            if (j == scan.n_equiv) {
                                scan.ai_cur[j] = x.i_table;
                                scan.ai_column[j] = x.i_column;
                                scan.n_equiv += 1;
                            }
                        }
                    }
                    if (term.e_operator & scan.op_mask != 0) {
                        // Verify the affinity and collating sequence match.
                        if (scan.z_coll_name != null and term.e_operator & WO.ISNULL == 0) {
                            const p = wc.w_info.parse;
                            const x = term.expr;
                            var z_coll_name: []const u8 = undefined;
                            if (term.e_operator & WO.IN != 0) {
                                z_coll_name = indexInAffinityOk(p, term, scan.idxaff) orelse continue;
                            } else {
                                if (!expr_mod.indexAffinityOk(x, scan.idxaff)) continue;
                                std.debug.assert(x.left != null);
                                const coll = expr_mod.compareCollSeq(p, x);
                                z_coll_name = if (coll) |c| c.name else coll_mod.str_binary;
                            }
                            if (ctype.strICmp(z_coll_name, scan.z_coll_name.?) != 0) continue;
                        }
                        if (term.e_operator & (WO.EQ | WO.IS) != 0) {
                            const x = term.expr.right.?;
                            if (x.op == TK.COLUMN and x.i_table == scan.ai_cur[0] and
                                x.i_column == scan.ai_column[0]) continue;
                        }
                        scan.wc = wc;
                        scan.k = k + 1;
                        return term;
                    }
                }
            }
            wc_opt = wc.outer;
            k = 0;
        }
        if (scan.i_equiv >= scan.n_equiv) break;
        wc_opt = scan.orig_wc;
        k = 0;
        scan.i_equiv += 1;
    }
    return null;
}

/// Port of whereScanInitIndexExpr(): whereScanInit() for a column of an
/// index on an expression.
fn whereScanInitIndexExpr(scan: *WhereScan) ?*WhereTerm {
    scan.idxaff = expr_mod.affinity(scan.idx_expr.?);
    return whereScanNext(scan);
}

/// Port of whereScanInit(): set up `scan` to find terms "X <op> <expr>"
/// where X is column `i_column` of table `i_cur` (or of index `idx`) and
/// <op> is in `op_mask`. Returns the first match.
pub fn whereScanInit(scan: *WhereScan, wc: *WhereClause, i_cur: i32, i_column_arg: i32, op_mask: u32, idx: ?*Index) ?*WhereTerm {
    var i_column = i_column_arg;
    scan.orig_wc = wc;
    scan.wc = wc;
    scan.idx_expr = null;
    scan.idxaff = 0;
    scan.z_coll_name = null;
    scan.op_mask = op_mask;
    scan.k = 0;
    scan.ai_cur[0] = i_cur;
    scan.n_equiv = 1;
    scan.i_equiv = 1;
    if (idx) |x| {
        const j: usize = @intCast(i_column);
        i_column = x.ai_column[j];
        if (i_column == x.table.i_pkey) {
            i_column = XN_ROWID;
        } else if (i_column >= 0) {
            scan.idxaff = x.table.cols[@intCast(i_column)].affinity;
            scan.z_coll_name = x.coll[j];
        } else if (i_column == XN_EXPR) {
            scan.idx_expr = x.col_expr.?.at(j).expr;
            scan.z_coll_name = x.coll[j];
            scan.ai_column[0] = XN_EXPR;
            return whereScanInitIndexExpr(scan);
        }
    } else if (i_column == XN_EXPR) {
        return null;
    }
    scan.ai_column[0] = @intCast(i_column);
    return whereScanNext(scan);
}

/// Port of sqlite3WhereFindTerm(): a term "X <op> <expr>" for column
/// `i_column` of `i_cur` (or of `idx`) whose RHS does not use
/// `not_ready`, preferring one with a constant RHS.
pub fn findTerm(wc: *WhereClause, i_cur: i32, i_column: i32, not_ready: Bitmask, op_arg: u32, idx: ?*Index) ?*WhereTerm {
    var result: ?*WhereTerm = null;
    var scan: WhereScan = .{};
    var p = whereScanInit(&scan, wc, i_cur, i_column, op_arg, idx);
    const op = op_arg & (WO.EQ | WO.IS);
    while (p) |t| {
        if (t.prereq_right & not_ready == 0) {
            if (t.prereq_right == 0 and t.e_operator & op != 0) return t;
            if (result == null) result = t;
        }
        p = whereScanNext(&scan);
    }
    return result;
}

/// Port of findIndexCol(): the entry of `list` matching column `i_col`
/// of `idx`, or -1.
fn findIndexCol(p: *Parse, list: *ExprList, i_base: i32, idx: *Index, i_col: usize) i32 {
    const z_coll = idx.coll[i_col];
    for (list.slice(), 0..) |*item, i| {
        const e = expr_mod.skipCollateAndLikely(item.expr) orelse continue;
        if ((e.op == TK.COLUMN or e.op == TK.AGG_COLUMN) and
            e.i_column == idx.ai_column[i_col] and e.i_table == i_base)
        {
            const coll = expr_mod.nnCollSeq(p, item.expr);
            if (ctype.strICmp(coll.name, z_coll) == 0) return @intCast(i);
        }
    }
    return -1;
}

/// Port of indexColumnNotNull(): column `i_col` of `idx` is NOT NULL.
fn indexColumnNotNull(idx: *const Index, i_col: usize) bool {
    std.debug.assert(i_col < idx.n_column);
    const j = idx.ai_column[i_col];
    if (j >= 0) return idx.table.cols[@intCast(j)].not_null != .None;
    if (j == -1) return true;
    std.debug.assert(j == -2);
    return false; // An indexed expression can always yield a NULL.
}

/// Port of isDistinctRedundant(): the DISTINCT list is redundant because
/// some subset of its columns is collectively unique and non-null.
pub fn isDistinctRedundant(p: *Parse, tab_list: *SrcList, wc: *WhereClause, distinct: *ExprList) bool {
    if (tab_list.len() != 1) return false;
    const i_base = tab_list.at(0).i_cursor;
    const tab = tab_list.at(0).s_tab.?;

    // An IPK column of iBase makes it redundant.
    for (distinct.slice()) |*item| {
        const e = expr_mod.skipCollateAndLikely(item.expr) orelse continue;
        if (e.op != TK.COLUMN and e.op != TK.AGG_COLUMN) continue;
        if (e.i_table == i_base and e.i_column < 0) return true;
    }

    // A UNIQUE index whose columns are each in the DISTINCT list or fixed
    // by "col=X" (and NOT NULL if not fixed) makes it redundant.
    var it = tab.index;
    while (it) |idx| : (it = idx.next) {
        if (!idx.isUnique()) continue;
        if (idx.part_idx_where != null) continue;
        var i: usize = 0;
        while (i < idx.n_key_col) : (i += 1) {
            if (findTerm(wc, i_base, @intCast(i), ~@as(Bitmask, 0), WO.EQ, idx) == null) {
                if (findIndexCol(p, distinct, i_base, idx, i) < 0) break;
                if (!indexColumnNotNull(idx, i)) break;
            }
        }
        if (i == idx.n_key_col) return true;
    }
    return false;
}

/// Port of estLog(): estimate the logarithm of `n` to base 2.
pub fn estLog(n: LogEst) LogEst {
    return if (n <= 10) 0 else util.logEst(@intCast(n)) - 33;
}

// ================================================== outer joins, autoindex

/// Port of constraintCompatibleWithOuterJoin(): `term` may be used to
/// access `src`, the right operand of a LEFT JOIN or either operand of a
/// RIGHT JOIN.
pub fn constraintCompatibleWithOuterJoin(term: *const WhereTerm, src: *const SrcItem) bool {
    std.debug.assert(src.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true }));
    if (!term.expr.flags.intersects(.{ .OuterON = true, .InnerON = true }) or term.expr.w.join != src.i_cursor) return false;
    if (src.fg.jointype.intersects(.{ .LEFT = true, .RIGHT = true }) and term.expr.flags.InnerON) return false;
    return true;
}

/// Port of columnIsGoodIndexCandidate(): column `i_col` of `tab` might be
/// a good column for an automatic index.
pub fn columnIsGoodIndexCandidate(tab: *const Table, i_col: i32) bool {
    var it = tab.index;
    while (it) |idx| : (it = idx.next) {
        var j: usize = 0;
        while (j < idx.n_key_col) : (j += 1) {
            if (idx.ai_column[j] == i_col) {
                if (j == 0) return false;
                if (idx.has_stat1 and idx.ai_row_log_est[j + 1] > 20) return false;
                break;
            }
        }
    }
    return true;
}

/// Port of termCanDriveIndex(): `term` could drive an index on `src`,
/// were there one.
pub fn termCanDriveIndex(term: *const WhereTerm, src: *const SrcItem, not_ready: Bitmask) bool {
    if (term.left_cursor != src.i_cursor) return false;
    if (term.e_operator & (WO.EQ | WO.IS) == 0) return false;
    std.debug.assert(!src.fg.jointype.RIGHT);
    if (src.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true }) and
        !constraintCompatibleWithOuterJoin(term, src)) return false;
    if (term.prereq_right & not_ready != 0) return false;
    std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
    const left_col = term.left_column;
    if (left_col < 0) return false;
    const tab = src.s_tab.?;
    const aff = tab.cols[@intCast(left_col)].affinity;
    if (!expr_mod.indexAffinityOk(term.expr, aff)) return false;
    return columnIsGoodIndexCandidate(tab, left_col);
}

// ============================================================ estimates

/// Port of whereRangeAdjust(): the rows visited after range bound `term`
/// (if any) is applied to a scan of `n_new` rows.
fn whereRangeAdjust(term: ?*const WhereTerm, n_new: LogEst) LogEst {
    var n_ret = n_new;
    if (term) |t| {
        if (t.truth_prob <= 0) {
            n_ret += t.truth_prob;
        } else if (!t.wt_flags.VNULL) {
            n_ret -= 20; // 20 == logEst(4)
        }
    }
    return n_ret;
}

/// Port of whereRangeScanEst() (non-STAT4): reduce loop.nOut for the
/// range bounds `lower` and `upper`.
fn whereRangeScanEst(p: *Parse, builder: *WhereLoopBuilder, lower: ?*WhereTerm, upper: ?*WhereTerm, loop: *WhereLoop) void {
    _ = builder;
    var n_out: i32 = loop.n_out;
    std.debug.assert(lower != null or upper != null);
    std.debug.assert(upper == null or !upper.?.wt_flags.VNULL or p.n_err > 0);
    var n_new: i32 = whereRangeAdjust(lower, @intCast(n_out));
    n_new = whereRangeAdjust(upper, @intCast(n_new));

    // TUNING: both bounds without likelihood() narrow the range by a
    // further 75%.
    if (lower != null and lower.?.truth_prob > 0 and upper != null and upper.?.truth_prob > 0) {
        n_new -= 20;
    }

    n_out -= @as(i32, @intFromBool(lower != null)) + @intFromBool(upper != null);
    if (n_new < 10) n_new = 10;
    if (n_new < n_out) n_out = n_new;
    loop.n_out = @intCast(n_out);
}

// ============================================================ WhereLoop

/// Port of whereLoopInit(): make `l` a valid, empty WhereLoop.
pub fn whereLoopInit(l: *WhereLoop) void {
    l.a_lterm = &l.a_lterm_space;
    l.n_lterm = 0;
    l.ws_flags = .{};
}

/// Port of whereLoopClearUnion(): free the idxStr of a virtual table
/// loop that owns it (the rest of the memory belongs to the arena).
pub fn whereLoopClearUnion(db: *int.Sqlite3, l: *WhereLoop) void {
    if (l.ws_flags.VIRTUALTABLE and l.vtab.need_free) {
        if (l.vtab.idx_str) |z| db.gpa.free(z);
        l.vtab.need_free = false;
        l.vtab.idx_str = null;
    }
}

/// Port of whereLoopClear(): reset `l` as if newly initialized (the
/// memory itself belongs to the arena).
fn whereLoopClear(db: *int.Sqlite3, l: *WhereLoop) void {
    whereLoopClearUnion(db, l);
    l.a_lterm = &l.a_lterm_space;
    l.n_lterm = 0;
    l.ws_flags = .{};
}

/// Port of whereLoopResize(): make room for at least `n` aLTerm[] slots.
pub fn whereLoopResize(a: std.mem.Allocator, l: *WhereLoop, n_arg: usize) Oom!void {
    if (l.nLSlot() >= n_arg) return;
    const n = (n_arg + 7) & ~@as(usize, 7);
    const new = try a.alloc(?*WhereTerm, n);
    @memcpy(new[0..l.a_lterm.len], l.a_lterm);
    l.a_lterm = new;
}

/// Port of whereLoopXfer(): copy `from` into `to` (the fields above the
/// whereLoopXfer() marker, then aLTerm[]).
fn whereLoopXfer(db: *int.Sqlite3, a: std.mem.Allocator, to: *WhereLoop, from: *WhereLoop) Oom!void {
    whereLoopClearUnion(db, to);
    if (from.n_lterm > to.nLSlot()) try whereLoopResize(a, to, from.n_lterm);
    to.prereq = from.prereq;
    to.mask_self = from.mask_self;
    to.i_tab = from.i_tab;
    to.i_sort_idx = from.i_sort_idx;
    to.r_setup = from.r_setup;
    to.r_run = from.r_run;
    to.n_out = from.n_out;
    to.btree = from.btree;
    to.vtab = from.vtab;
    to.ws_flags = from.ws_flags;
    to.n_lterm = from.n_lterm;
    to.n_skip = from.n_skip;
    @memcpy(to.a_lterm[0..to.n_lterm], from.a_lterm[0..to.n_lterm]);
    if (from.ws_flags.VIRTUALTABLE) {
        // `to` owns the idxStr now.
        from.vtab.need_free = false;
    } else if (from.ws_flags.AUTO_INDEX) {
        from.btree.index = null;
    }
}

/// Port of whereLoopCheaperProperSubset(): X is a proper subset of Y but
/// costs no more, so their costs need adjusting.
fn whereLoopCheaperProperSubset(x: *const WhereLoop, y: *const WhereLoop) bool {
    if (x.r_run > y.r_run and x.n_out > y.n_out) return false; // (1d) and (2a)
    std.debug.assert(!x.ws_flags.VIRTUALTABLE);
    std.debug.assert(!y.ws_flags.VIRTUALTABLE);
    if (x.btree.n_eq < y.btree.n_eq and // (1b)
        x.btree.index == y.btree.index and // (1a)
        x.n_skip == 0 and y.n_skip == 0) // (1c)
    {
        return true; // Case 1 is true
    }
    if (@as(i32, x.n_lterm) - x.n_skip >= @as(i32, y.n_lterm) - y.n_skip) return false; // (2b)
    if (y.n_skip > x.n_skip) return false; // (2d)
    var i: i32 = @as(i32, x.n_lterm) - 1;
    while (i >= 0) : (i -= 1) {
        const xt = x.a_lterm[@intCast(i)] orelse continue;
        var j: i32 = @as(i32, y.n_lterm) - 1;
        while (j >= 0) : (j -= 1) {
            if (y.a_lterm[@intCast(j)] == xt) break;
        }
        if (j < 0) return false; // (2c)
    }
    if (x.ws_flags.IDX_ONLY and !y.ws_flags.IDX_ONLY) {
        return false; // (2e)
    }
    return true; // Case 2 is true
}

/// Port of whereLoopAdjustCost(): make `template` cheaper than its proper
/// subsets and costlier than its proper supersets in list `p`.
fn whereLoopAdjustCost(p_arg: ?*const WhereLoop, template: *WhereLoop) void {
    if (!template.ws_flags.INDEXED) return;
    var it = p_arg;
    while (it) |p| : (it = p.next_loop) {
        if (p.i_tab != template.i_tab) continue;
        if (!p.ws_flags.INDEXED) continue;
        if (whereLoopCheaperProperSubset(p, template)) {
            template.r_run = @min(p.r_run, template.r_run);
            template.n_out = @min(p.n_out - 1, template.n_out);
        } else if (whereLoopCheaperProperSubset(template, p)) {
            template.r_run = @max(p.r_run, template.r_run);
            template.n_out = @max(p.n_out + 1, template.n_out);
        }
    }
}

/// Port of whereLoopFindLesser(): the link to a loop in `*pp_prev_arg`
/// that `template` can replace, the tail link if it is to be appended, or
/// null if it should be discarded.
fn whereLoopFindLesser(pp_prev_arg: *?*WhereLoop, template: *const WhereLoop) ?*?*WhereLoop {
    var pp_prev = pp_prev_arg;
    while (pp_prev.*) |p| : (pp_prev = &p.next_loop) {
        if (p.i_tab != template.i_tab or p.i_sort_idx != template.i_sort_idx) continue;
        std.debug.assert(p.r_setup == 0 or template.r_setup == 0 or p.r_setup == template.r_setup);
        // SETUP-INVARIANT: automatic index loops are inserted first.
        std.debug.assert(p.r_setup >= template.r_setup);

        // An index with == constraints beats an automatic index, unless
        // it is a skip-scan.
        if (p.ws_flags.AUTO_INDEX and
            template.n_skip == 0 and
            template.ws_flags.INDEXED and
            template.ws_flags.COLUMN_EQ and
            (p.prereq & template.prereq) == template.prereq)
        {
            break;
        }

        // p is no worse in dependencies and cost: discard template.
        if ((p.prereq & template.prereq) == p.prereq and
            p.r_setup <= template.r_setup and
            p.r_run <= template.r_run and
            p.n_out <= template.n_out)
        {
            return null;
        }

        // template is no worse than p: overwrite p.
        if ((p.prereq & template.prereq) == template.prereq and
            p.r_run >= template.r_run and
            p.n_out >= template.n_out)
        {
            std.debug.assert(p.r_setup >= template.r_setup);
            break;
        }
    }
    return pp_prev;
}

/// Port of whereLoopInsert(): add `template` to the loop list, replacing
/// worse loops, or record it in builder.or_set. `done` (SQLITE_DONE) when
/// the planner search limit is hit.
fn whereLoopInsert(builder: *WhereLoopBuilder, template: *WhereLoop) Oom!Flow {
    const w = builder.w_info;
    const a = w.parse.arena;

    // Stop the search once we hit the query planner search limit.
    if (builder.i_plan_limit == 0) {
        if (builder.or_set) |s| s.n = 0;
        return .done;
    }
    builder.i_plan_limit -= 1;

    whereLoopAdjustCost(w.loops, template);

    // With an or_set, only keep track of the costs and prereqs.
    if (builder.or_set) |s| {
        if (template.n_lterm != 0) {
            _ = whereOrInsert(s, template.prereq, template.r_run, template.n_out);
        }
        return .ok;
    }

    // Look for an existing WhereLoop to replace with template.
    const pp_prev = whereLoopFindLesser(&w.loops, template) orelse return .ok;
    var p: *WhereLoop = undefined;
    if (pp_prev.*) |existing| {
        p = existing;
        // Delete any other entries after p that template also supplants.
        var pp_tail: *?*WhereLoop = &p.next_loop;
        while (pp_tail.* != null) {
            pp_tail = whereLoopFindLesser(pp_tail, template) orelse break;
            const to_del = pp_tail.* orelse break;
            pp_tail.* = to_del.next_loop;
            // whereLoopDelete(): the rest is arena memory.
            whereLoopClearUnion(w.parse.db, to_del);
        }
    } else {
        p = try a.create(WhereLoop);
        p.* = .{};
        whereLoopInit(p);
        p.next_loop = null;
        pp_prev.* = p;
    }
    try whereLoopXfer(w.parse.db, a, p, template);
    if (!p.ws_flags.VIRTUALTABLE) {
        if (p.btree.index) |idx| {
            if (idx.idx_type == .ipk) p.btree.index = null;
        }
    }
    return .ok;
}

/// Port of exprNodePatternLengthEst(): track the longest string literal,
/// counted as a LIKE (e_code 1) or GLOB (0) pattern.
fn exprNodePatternLengthEst(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.STRING) {
        var sz: i32 = 0;
        const z: [:0]const u8 = e.u.token orelse "";
        var c1: u8 = undefined;
        var c2: u8 = undefined;
        var c3: u8 = undefined;
        if (w.e_code != 0) {
            c1 = '%';
            c2 = '_';
            c3 = 0;
        } else {
            c1 = '*';
            c2 = '?';
            c3 = '[';
        }
        var i: usize = 0;
        while (true) {
            const c = z[i];
            if (c == 0) break;
            i += 1;
            if (c == c3) {
                if (z[i] != 0) i += 1;
                while (z[i] != 0 and z[i] != ']') i += 1;
            } else if (c != c1 and c != c2) {
                sz += 1;
            }
        }
        if (sz > w.u.sz) w.u.sz = sz;
    }
    return WRC.Continue;
}

/// Port of estLikePatternLength(): the length of the longest string
/// literal in `p`.
fn estLikePatternLength(p: ?*Expr, e_code: u16) i32 {
    var w: Walker = .{
        .expr_callback = exprNodePatternLengthEst,
        .select_callback = walker.selectWalkFail,
        .e_code = e_code,
        .u = .{ .sz = 0 },
    };
    _ = walker.walkExpr(&w, p);
    return w.u.sz;
}

/// Port of whereLoopOutputAdjust(): lower loop.nOut for WHERE terms that
/// reference the loop but are not used by its index.
fn whereLoopOutputAdjust(wc: *WhereClause, loop: *WhereLoop, n_row: LogEst) void {
    const not_allowed = ~(loop.prereq | loop.mask_self);
    var i_reduce: LogEst = 0; // loop.nOut should not exceed nRow-iReduce

    // Accuracy does not matter for a single table without ORDER BY.
    if (wc.w_info.tab_list.len() <= 1 and wc.w_info.order_by == null) return;

    std.debug.assert(!loop.ws_flags.AUTO_INDEX);
    for (wc.a[0..@intCast(wc.n_base)], 0..) |*term, i_term| {
        if (term.prereq_all & not_allowed != 0) continue;
        if (term.prereq_all & loop.mask_self == 0) continue;
        if (term.wt_flags.VIRTUAL) continue;
        var j: i32 = @as(i32, loop.n_lterm) - 1;
        while (j >= 0) : (j -= 1) {
            const x = loop.a_lterm[@intCast(j)] orelse continue;
            if (x == term) break;
            // C compares &pWC->a[iParent] with pTerm; x may belong to
            // another clause, so compare the indexes instead of indexing.
            if (x.i_parent >= 0 and x.i_parent == i_term) break;
        }
        if (j < 0) {
            util.progressCheck(wc.w_info.parse);
            if (loop.mask_self == term.prereq_all) {
                // Self-culling: only for comparisons that are not true with
                // a NULL operand, or outside an OUTER JOIN.
                if (term.e_operator & 0x3f != 0 or
                    !wc.w_info.tab_list.at(loop.i_tab).fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true }))
                {
                    loop.ws_flags.SELFCULL = true;
                }
            }
            if (term.truth_prob <= 0) {
                // A likelihood() hint gives the probability.
                loop.n_out += term.truth_prob;
            } else {
                const op_expr = term.expr;
                loop.n_out -= 1;
                if (term.e_operator & (WO.EQ | WO.IS) != 0 and
                    !term.wt_flags.intersects(TERM.HIGHTRUTH)) // tag-20200224-1
                {
                    const right = op_expr.right;
                    const p = wc.w_info.parse;
                    var k: LogEst = 20;
                    if (expr_mod.isInteger(right, p)) |v| {
                        if (v >= -1 and v <= 1) k = 10;
                    }
                    if (i_reduce < k) {
                        term.wt_flags.HEURTRUTH = true;
                        i_reduce = k;
                    }
                } else if (op_expr.flags.InfixFunc and op_expr.op == TK.FUNCTION) {
                    std.debug.assert(op_expr.useXList());
                    std.debug.assert(op_expr.x.list.?.len() >= 2);
                    const e_op = we.exprIsLikeOperator(op_expr);
                    if (e_op > 0) {
                        const rhs = op_expr.x.list.?.at(0).expr;
                        const sz_pattern = estLikePatternLength(rhs, @intFromBool(e_op == INDEX_CONSTRAINT_LIKE));
                        if (sz_pattern > 0) {
                            loop.n_out = @intCast(@as(i32, loop.n_out) - sz_pattern * 2);
                        }
                    }
                }
            }
        }
    }
    if (loop.n_out > n_row - i_reduce) {
        loop.n_out = n_row - i_reduce;
    }
}

/// Port of whereRangeVectorLen(): how many elements of vector range
/// comparison `term` can use index columns nEq onward.
fn whereRangeVectorLen(p: *Parse, i_cur: i32, idx: *Index, n_eq: usize, term: *WhereTerm) u16 {
    var n_cmp: usize = expr_mod.vectorSize(term.expr.left.?);
    n_cmp = @min(n_cmp, idx.n_column - n_eq);
    var i: usize = 1;
    while (i < n_cmp) : (i += 1) {
        std.debug.assert(term.expr.left.?.useXList());
        var lhs = term.expr.left.?.x.list.?.at(i).expr.?;
        var rhs = term.expr.right.?;
        if (rhs.useXSelect()) {
            rhs = rhs.x.select.?.e_list.?.at(i).expr.?;
        } else {
            rhs = rhs.x.list.?.at(i).expr.?;
        }

        // The LHS must be the right column of the right table, with the
        // same sort order as the leftmost index column.
        if (lhs.op != TK.COLUMN or
            lhs.i_table != i_cur or
            lhs.i_column != idx.ai_column[i + n_eq] or
            idx.sort_order[i + n_eq] != idx.sort_order[n_eq])
        {
            break;
        }

        const aff = expr_mod.compareAffinity(rhs, expr_mod.affinity(lhs));
        const idxaff = expr_mod.tableColumnAffinity(idx.table, lhs.i_column);
        if (aff != idxaff) break;

        if (term.expr.flags.Commuted) std.mem.swap(*Expr, &rhs, &lhs);
        const coll = expr_mod.binaryCompareCollSeq(p, lhs, rhs) orelse break;
        if (ctype.strICmp(coll.name, idx.coll[i + n_eq]) != 0) break;
    }
    return @intCast(i);
}

/// Port of whereLoopAddBtreeIndex(): with builder.new matching nEq
/// columns of `probe`, try to match one more. Fails only on an earlier
/// error of the Parse (C returns pParse->rc).
fn whereLoopAddBtreeIndex(builder: *WhereLoopBuilder, src: *SrcItem, probe: *Index, n_in_mul: LogEst) AddError!Flow {
    const w = builder.w_info;
    const p = w.parse;
    const db = p.db;
    const a = p.arena;
    const new = builder.new;
    var scan: WhereScan = .{};
    var flow: Flow = .ok;
    var top: ?*WhereTerm = null;
    var btm: ?*WhereTerm = null;

    std.debug.assert(!db.malloc_failed or p.n_err > 0);
    if (p.n_err != 0) {
        if (p.rc == RC.OK) return .ok;
        return error.ParseFailed;
    }

    std.debug.assert(!new.ws_flags.VIRTUALTABLE);
    std.debug.assert(!new.ws_flags.TOP_LIMIT);
    var op_mask: u32 = undefined;
    if (new.ws_flags.BTM_LIMIT) {
        op_mask = WO.LT | WO.LE;
    } else {
        std.debug.assert(new.btree.n_btm == 0);
        op_mask = WO.EQ | WO.IN | WO.GT | WO.GE | WO.LT | WO.LE | WO.ISNULL | WO.IS;
    }
    if (probe.unordered) op_mask &= ~@as(u32, WO.GT | WO.GE | WO.LT | WO.LE);

    std.debug.assert(new.btree.n_eq < probe.n_column);
    std.debug.assert(new.btree.n_eq < probe.n_key_col or probe.idx_type != .primarykey);

    const saved_n_eq = new.btree.n_eq;
    const saved_n_btm = new.btree.n_btm;
    const saved_n_top = new.btree.n_top;
    const saved_n_skip = new.n_skip;
    const saved_n_lterm = new.n_lterm;
    const saved_ws_flags = new.ws_flags;
    const saved_prereq = new.prereq;
    const saved_n_out = new.n_out;
    var term_opt = whereScanInit(&scan, builder.wc, src.i_cursor, saved_n_eq, op_mask, probe);
    new.r_setup = 0;
    const r_size: LogEst = probe.ai_row_log_est[0];
    const r_log_size = estLog(r_size);
    while (flow == .ok and term_opt != null) : (term_opt = whereScanNext(&scan)) {
        const term = term_opt.?;
        const e_op: u16 = term.e_operator;
        var n_in: LogEst = 0;
        if ((e_op == WO.ISNULL or term.wt_flags.VNULL) and
            indexColumnNotNull(probe, saved_n_eq))
        {
            continue; // ignore IS [NOT] NULL constraints on NOT NULL columns
        }
        if (term.prereq_right & new.mask_self != 0) continue;

        // The upper bound of a LIKE optimization range must not mix with a
        // lower bound from some other source.
        if (term.wt_flags.LIKEOPT and term.e_operator == WO.LT) continue;

        if (src.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true }) and
            !constraintCompatibleWithOuterJoin(term, src))
        {
            continue;
        }
        if (probe.isUnique() and @as(i32, saved_n_eq) == @as(i32, probe.n_key_col) - 1) {
            builder.bld_flags1 |= wi.BLDF1_UNIQUE;
        } else {
            builder.bld_flags1 |= wi.BLDF1_INDEXED;
        }
        new.ws_flags = saved_ws_flags;
        new.btree.n_eq = saved_n_eq;
        new.btree.n_btm = saved_n_btm;
        new.btree.n_top = saved_n_top;
        new.n_lterm = saved_n_lterm;
        if (new.n_lterm >= new.nLSlot()) try whereLoopResize(a, new, @as(usize, new.n_lterm) + 1);
        new.a_lterm[new.n_lterm] = term;
        new.n_lterm += 1;
        new.prereq = (saved_prereq | term.prereq_right) & ~new.mask_self;

        std.debug.assert(n_in_mul == 0 or
            new.ws_flags.COLUMN_NULL or
            new.ws_flags.COLUMN_IN or
            new.ws_flags.SKIPSCAN);

        if (e_op & WO.IN != 0) {
            const e = term.expr;
            if (e.useXSelect()) {
                // "x IN (SELECT ...)": TUNING: the SELECT returns 25 rows.
                var b_redundant = false;
                n_in = 46; // 46 == logEst(25)

                // For "(x,y) IN (SELECT ...)" apply nIn once only, and do
                // not add the same vector field twice (tag-20250707-01).
                var i: usize = 0;
                while (i + 1 < new.n_lterm) : (i += 1) {
                    if (new.a_lterm[i]) |lt| {
                        if (lt.expr == e) {
                            n_in = 0;
                            if (lt.i_field == term.i_field) b_redundant = true;
                        }
                    }
                }
                if (b_redundant) {
                    new.n_lterm -= 1;
                    continue;
                }
            } else if (e.x.list != null and e.x.list.?.len() != 0) {
                // "x IN (value, value, ...)"
                n_in = util.logEst(e.x.list.?.len());
            }
            if (probe.has_stat1 and r_log_size >= 10) {
                // Scanning the M rows matching earlier columns and testing
                // the IN separately beats the K seeks if M*log(K) <
                // K*log(N), with a bias of 10 toward the indexed IN.
                const m: LogEst = probe.ai_row_log_est[saved_n_eq];
                const log_k = estLog(n_in);
                const x: LogEst = m + log_k + 10 - (n_in + r_log_size);
                if (x >= 0) {
                    // prefers indexed lookup
                } else if (n_in_mul < 2 and !db.optDisabled(OPT.SeekScan)) {
                    new.ws_flags.IN_SEEKSCAN = true;
                } else {
                    continue;
                }
            }
            new.ws_flags.COLUMN_IN = true;
        } else if (e_op & (WO.EQ | WO.IS) != 0) {
            const i_col = probe.ai_column[saved_n_eq];
            new.ws_flags.COLUMN_EQ = true;
            std.debug.assert(saved_n_eq == new.btree.n_eq);
            if (i_col == XN_ROWID or
                (i_col >= 0 and n_in_mul == 0 and @as(i32, saved_n_eq) == @as(i32, probe.n_key_col) - 1))
            {
                if (i_col == XN_ROWID or probe.uniq_not_null or
                    (probe.n_key_col == 1 and probe.on_error != OE.None and e_op & WO.EQ != 0))
                {
                    new.ws_flags.ONEROW = true;
                } else {
                    new.ws_flags.UNQ_WANTED = true;
                }
            }
            if (scan.i_equiv > 1) new.ws_flags.TRANSCONS = true;
        } else if (e_op & WO.ISNULL != 0) {
            new.ws_flags.COLUMN_NULL = true;
        } else {
            const n_vec_len = whereRangeVectorLen(p, src.i_cursor, probe, saved_n_eq, term);
            if (e_op & (WO.GT | WO.GE) != 0) {
                new.ws_flags.set(.{ .COLUMN_RANGE = true, .BTM_LIMIT = true });
                new.btree.n_btm = n_vec_len;
                btm = term;
                top = null;
                if (term.wt_flags.LIKEOPT) {
                    // LIKE optimization range constraints come in pairs.
                    const t = &term.wc.a[termIndex(term.wc, term) + 1];
                    top = t;
                    std.debug.assert(termIndex(term.wc, t) < term.wc.n_term);
                    std.debug.assert(t.wt_flags.LIKEOPT);
                    std.debug.assert(t.e_operator == WO.LT);
                    try whereLoopResize(a, new, @as(usize, new.n_lterm) + 1);
                    new.a_lterm[new.n_lterm] = t;
                    new.n_lterm += 1;
                    new.ws_flags.TOP_LIMIT = true;
                    new.btree.n_top = 1;
                }
            } else {
                std.debug.assert(e_op & (WO.LT | WO.LE) != 0);
                new.ws_flags.set(.{ .COLUMN_RANGE = true, .TOP_LIMIT = true });
                new.btree.n_top = n_vec_len;
                top = term;
                btm = if (new.ws_flags.BTM_LIMIT) new.a_lterm[new.n_lterm - 2] else null;
            }
        }

        // Update new.nOut for this term (but not nIn/nInMul).
        std.debug.assert(new.n_out == saved_n_out);
        if (new.ws_flags.COLUMN_RANGE) {
            whereRangeScanEst(p, builder, btm, top, new);
        } else {
            new.btree.n_eq += 1;
            const n_eq = new.btree.n_eq;
            std.debug.assert(e_op & (WO.ISNULL | WO.EQ | WO.IN | WO.IS) != 0);
            std.debug.assert(new.n_out == saved_n_out);
            if (term.truth_prob <= 0 and probe.ai_column[saved_n_eq] >= 0) {
                std.debug.assert(e_op & WO.IN != 0 or n_in == 0);
                new.n_out += term.truth_prob;
                new.n_out -= n_in;
            } else {
                new.n_out += probe.ai_row_log_est[n_eq] - probe.ai_row_log_est[n_eq - 1];
                if (e_op & WO.ISNULL != 0) {
                    // TUNING: "col IS NULL" matches twice as many rows as
                    // (col=?).
                    new.n_out += 10;
                }
            }
        }

        // rCostIdx: one seek plus stepping nOut times through the index.
        const tab = src.s_tab.?;
        std.debug.assert(tab.sz_tab_row > 0);
        var r_cost_idx: LogEst = undefined;
        if (probe.idx_type == .ipk) {
            // szIdxRow under-estimates the leaf pages of an IPK table.
            r_cost_idx = new.n_out + 16;
        } else {
            r_cost_idx = @intCast(@as(i32, new.n_out) + 1 +
                @divTrunc(15 * @as(i32, probe.sz_idx_row), @as(i32, tab.sz_tab_row)));
        }
        r_cost_idx = util.logEstAdd(r_log_size, r_cost_idx);

        // Add the cost of nOut table lookups unless all data comes from
        // the index.
        new.r_run = r_cost_idx;
        if (!new.ws_flags.intersects(.{ .IDX_ONLY = true, .IPK = true, .EXPRIDX = true })) {
            new.r_run = util.logEstAdd(new.r_run, new.n_out + 16);
        }

        const n_out_unadjusted = new.n_out;
        new.r_run += n_in_mul + n_in;
        new.n_out += n_in_mul + n_in;
        whereLoopOutputAdjust(builder.wc, new, r_size);
        if (src.fg.from_exists) new.n_out = 0;
        flow = try whereLoopInsert(builder, new);

        if (new.ws_flags.COLUMN_RANGE) {
            new.n_out = saved_n_out;
        } else {
            new.n_out = n_out_unadjusted;
        }

        if (!new.ws_flags.TOP_LIMIT and
            new.btree.n_eq < probe.n_column and
            (new.btree.n_eq < probe.n_key_col or probe.idx_type != .primarykey))
        {
            if (new.btree.n_eq > 3) util.progressCheck(p);
            // C ignores the result of the recursion.
            _ = whereLoopAddBtreeIndex(builder, src, probe, n_in_mul + n_in) catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.ParseFailed => {},
            };
        }
        new.n_out = saved_n_out;
    }
    new.prereq = saved_prereq;
    new.btree.n_eq = saved_n_eq;
    new.btree.n_btm = saved_n_btm;
    new.btree.n_top = saved_n_top;
    new.n_skip = saved_n_skip;
    new.ws_flags = saved_ws_flags;
    new.n_out = saved_n_out;
    new.n_lterm = saved_n_lterm;

    // Consider a skip-scan if the leftmost columns are unconstrained and
    // repeat on average at least 18 times (42 == logEst(18)).
    if (saved_n_eq == saved_n_skip and
        saved_n_eq + 1 < probe.n_key_col and
        saved_n_eq == new.n_lterm and
        !probe.no_skip_scan and
        probe.has_stat1 and
        !db.optDisabled(OPT.SkipScan) and
        probe.ai_row_log_est[saved_n_eq + 1] >= 42 and // TUNING: minimum for skip-scan
        !src.fg.from_exists)
    {
        try whereLoopResize(a, new, @as(usize, new.n_lterm) + 1);
        flow = .ok;
        new.btree.n_eq += 1;
        new.n_skip += 1;
        new.a_lterm[new.n_lterm] = null;
        new.n_lterm += 1;
        new.ws_flags.SKIPSCAN = true;
        var n_iter: LogEst = probe.ai_row_log_est[saved_n_eq] - probe.ai_row_log_est[saved_n_eq + 1];
        new.n_out -= n_iter;
        // TUNING: a 1.375 fudge factor makes skip-scan slightly less likely.
        n_iter += 5;
        _ = whereLoopAddBtreeIndex(builder, src, probe, n_iter + n_in_mul) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.ParseFailed => {},
        };
        new.n_out = saved_n_out;
        new.btree.n_eq = saved_n_eq;
        new.n_skip = saved_n_skip;
        new.ws_flags = saved_ws_flags;
    }
    return flow;
}

/// Port of indexMightHelpWithOrderBy(): `index` might help implement the
/// ORDER BY clause.
fn indexMightHelpWithOrderBy(builder: *WhereLoopBuilder, index: *Index, i_cursor: i32) bool {
    if (index.unordered) return false;
    const ob = builder.w_info.order_by orelse return false;
    for (ob.slice()) |*item| {
        const e = expr_mod.skipCollateAndLikely(item.expr) orelse continue;
        if ((e.op == TK.COLUMN or e.op == TK.AGG_COLUMN) and e.i_table == i_cursor) {
            if (e.i_column < 0) return true;
            for (index.ai_column[0..index.n_key_col]) |c| {
                if (e.i_column == c) return true;
            }
        } else if (index.col_expr) |col_expr| {
            var jj: usize = 0;
            while (jj < index.n_key_col) : (jj += 1) {
                if (index.ai_column[jj] != XN_EXPR) continue;
                if (expr_mod.compareSkip(e, col_expr.at(jj).expr, i_cursor) == 0) return true;
            }
        }
    }
    return false;
}

/// Port of whereUsablePartialIndex(): a partial index with WHERE clause
/// `where_arg` can be used by this query.
fn whereUsablePartialIndex(i_tab: i32, jointype: int.JT, wc: *WhereClause, where_arg: *Expr) bool {
    if (jointype.LTORJ) return false;
    const p = wc.w_info.parse;
    var where = where_arg;
    while (where.op == TK.AND) {
        if (!whereUsablePartialIndex(i_tab, jointype, wc, where.left.?)) return false;
        where = where.right.?;
    }
    for (wc.terms()) |*term| {
        const e = term.expr;
        if ((!e.flags.OuterON or e.w.join == i_tab) and
            (!jointype.OUTER or e.flags.OuterON) and
            expr_mod.impliesExpr(p, e, where, i_tab) and
            !expr_mod.impliesExpr(p, e, where, -1) and
            !term.wt_flags.VNULL)
        {
            return true;
        }
    }
    return false;
}

/// Port of exprIsCoveredByIndex(): `e` matches one of the expressions of
/// index `idx`.
fn exprIsCoveredByIndex(e: *const Expr, idx: *const Index, i_tab_cur: i32) bool {
    var i: usize = 0;
    while (i < idx.n_column) : (i += 1) {
        if (idx.ai_column[i] == XN_EXPR and
            expr_mod.compare(null, e, idx.col_expr.?.at(i).expr, i_tab_cur) == 0)
        {
            return true;
        }
    }
    return false;
}

/// Context of whereIsCoveringIndexWalkCallback() (CoveringIndexCheck).
pub const CoveringIndexCheck = struct {
    /// The index.
    idx: *Index,
    /// Cursor number for the corresponding table.
    i_tab_cur: i32,
    /// Uses an indexed expression.
    b_expr: bool = false,
    /// Uses an unindexed column not within an indexed expression.
    b_unidx: bool = false,
};

/// Port of whereIsCoveringIndexWalkCallback(): abort on a column of the
/// table that the index lacks; prune on an indexed expression.
fn whereIsCoveringIndexWalkCallback(w: *Walker, e: *Expr) WRC {
    const ck = w.u.cov_idx_ck;
    const idx = ck.idx;
    if (e.op == TK.COLUMN or e.op == TK.AGG_COLUMN) {
        if (e.i_table != ck.i_tab_cur) return WRC.Continue;
        for (idx.ai_column[0..idx.n_column]) |c| {
            if (c == e.i_column) return WRC.Continue;
        }
        ck.b_unidx = true;
        return WRC.Abort;
    } else if (idx.has_expr and exprIsCoveredByIndex(e, idx, ck.i_tab_cur)) {
        ck.b_expr = true;
        return WRC.Prune;
    }
    return WRC.Continue;
}

/// Port of whereIsCoveringIndex(): 0 if `idx` is not a covering index,
/// WHERE_IDX_ONLY if it is, WHERE_EXPRIDX if it probably is (indexed
/// expressions), found by walking the whole SELECT.
fn whereIsCoveringIndex(w_info: *WhereInfo, idx: *Index, i_tab_cur: i32) WS {
    const sel = w_info.select orelse return .{}; // Cannot check: assume not.
    if (!idx.has_expr) {
        var i: usize = 0;
        while (i < idx.n_column) : (i += 1) {
            if (idx.ai_column[i] >= int.bms - 1) break;
        }
        // No column >62 is indexed, yet such columns are used.
        if (i >= idx.n_column) return .{};
    }
    var ck: CoveringIndexCheck = .{ .idx = idx, .i_tab_cur = i_tab_cur };
    var w: Walker = .{
        .expr_callback = whereIsCoveringIndexWalkCallback,
        .select_callback = walker.selectWalkNoop,
        .u = .{ .cov_idx_ck = &ck },
    };
    _ = walker.walkSelect(&w, sel);
    if (ck.b_unidx) return .{};
    if (ck.b_expr) return .{ .EXPRIDX = true };
    return .{ .IDX_ONLY = true };
}

/// Port of wherePartIdxExpr(): find "col=<constant>" terms of partial
/// index WHERE clause `part` that let col be replaced by the constant.
/// With `mask`, clear those columns' bits; with `item`, add
/// Parse.pIdxPartExpr entries.
pub fn wherePartIdxExpr(p: *Parse, idx: *Index, part_arg: ?*Expr, mask: ?*Bitmask, i_idx_cur: i32, item: ?*SrcItem) Oom!void {
    std.debug.assert(item == null or !item.?.fg.jointype.RIGHT);
    std.debug.assert((item == null or mask == null) and (mask != null or item != null));
    var part = part_arg.?;

    if (part.op == TK.AND) {
        try wherePartIdxExpr(p, idx, part.right, mask, i_idx_cur, item);
        part = part.left.?;
    }

    if (part.op == TK.EQ or part.op == TK.IS) {
        const left = part.left.?;
        const right = part.right;
        if (left.op != TK.COLUMN) return;
        if (!expr_mod.isConstant(null, right)) return;
        if (!serial.isBinary(expr_mod.compareCollSeq(p, part))) return;
        if (left.i_column < 0) return;
        const aff = idx.table.cols[@intCast(left.i_column)].affinity;
        if (aff >= Aff.text) {
            if (item) |it| {
                const ie = try p.arena.create(int.IndexedExpr);
                ie.* = .{
                    .expr = (try expr_mod.exprDup(p.arena, right)).?,
                    .i_data_cur = it.i_cursor,
                    .i_idx_cur = i_idx_cur,
                    .i_idx_col = left.i_column,
                    .b_maybe_null_row = it.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true }),
                    .aff = aff,
                    .next = p.idx_part_expr,
                };
                p.idx_part_expr = ie;
            } else if (left.i_column < int.bms - 1) {
                mask.?.* &= ~(@as(Bitmask, 1) << @intCast(left.i_column));
            }
        }
    }
}

/// Port of whereLoopAddBtree(): add the WhereLoops for b-tree table
/// builder.new.iTab: automatic indexes, full scans and index lookups.
fn whereLoopAddBtree(builder: *WhereLoopBuilder, m_prereq: Bitmask) AddError!Flow {
    const new = builder.new;
    const w = builder.w_info;
    const p = w.parse;
    const tab_list = w.tab_list;
    const src = tab_list.at(new.i_tab);
    const tab = src.s_tab.?;
    const wc = builder.wc;
    var flow: Flow = .ok;
    var i_sort_idx: u8 = 1;
    std.debug.assert(tab.e_tab_type != .vtab);

    var probe_opt: ?*Index = undefined;
    if (src.fg.is_indexed_by) {
        std.debug.assert(!src.fg.is_cte);
        // An INDEXED BY clause specifies a particular index to use.
        probe_opt = src.u2.ib_index;
    } else if (!tab.hasRowid()) {
        probe_opt = tab.index;
    } else {
        // A fake Index for the rowid primary key, first in a chain with
        // the real indexes. C keeps it on the stack; loops stored by
        // whereLoopInsert() drop the pointer (IPK), but the template keeps
        // it, so it lives in the arena here.
        const pk = try p.arena.create(Index);
        const ai_column_pk = try p.arena.alloc(i16, 1);
        const ai_row_est_pk = try p.arena.alloc(LogEst, 2);
        ai_column_pk[0] = -1;
        ai_row_est_pk[0] = tab.n_row_log_est;
        ai_row_est_pk[1] = 0;
        pk.* = .{
            .name = try p.arena.dupeSentinel(u8, "", 0),
            .n_key_col = 1,
            .n_column = 1,
            .ai_column = ai_column_pk,
            .ai_row_log_est = ai_row_est_pk,
            .on_error = OE.Replace,
            .table = tab,
            .sz_idx_row = 3, // TUNING: interior rows of an IPK table are very small
            .idx_type = .ipk,
        };
        // The real indexes are only considered without NOT INDEXED.
        if (!src.fg.not_indexed) pk.next = tab.index;
        probe_opt = pk;
    }
    var r_size: LogEst = tab.n_row_log_est;

    // Automatic indexes.
    if (builder.or_set == null and // Not part of an OR optimization
        !w.wctrl_flags.intersects(.{ .RIGHT_JOIN = true, .OR_SUBCLAUSE = true }) and
        p.db.flags.AutoIndex and
        !src.fg.is_indexed_by and
        !src.fg.not_indexed and
        !src.fg.is_correlated and
        !src.fg.is_recursive and
        !src.fg.jointype.RIGHT)
    {
        const r_log_size = estLog(r_size);
        var t: usize = 0;
        while (flow == .ok and t < wc.n_term) : (t += 1) {
            const term = &wc.a[t];
            if (term.prereq_right & new.mask_self != 0) continue;
            if (termCanDriveIndex(term, src, 0)) {
                new.btree.n_eq = 1;
                new.n_skip = 0;
                new.btree.index = null;
                new.n_lterm = 1;
                new.a_lterm[0] = term;
                // TUNING: building the automatic index costs X*N*log2(N),
                // X being 7 (LogEst 28) for tables and 0.5 (LogEst -10)
                // for views and subqueries.
                new.r_setup = r_log_size + r_size;
                if (!tab.isView() and !tab.tab_flags.Ephemeral) {
                    new.r_setup += 28;
                } else {
                    new.r_setup -= 25;
                }
                if (new.r_setup < 0) new.r_setup = 0;
                // TUNING: each index lookup yields 20 rows (43 ==
                // logEst(20)).
                new.n_out = 43;
                new.r_run = util.logEstAdd(r_log_size, new.n_out);
                new.ws_flags = .{ .AUTO_INDEX = true };
                new.prereq = m_prereq | term.prereq_right;
                flow = try whereLoopInsert(builder, new);
            }
        }
    }

    // Loop over all indexes; with INDEXED BY, only probe.
    while (flow == .ok and probe_opt != null) : ({
        probe_opt = if (src.fg.is_indexed_by) null else probe_opt.?.next;
        i_sort_idx +%= 1;
    }) {
        const probe = probe_opt.?;
        if (probe.part_idx_where) |piw| {
            if (!whereUsablePartialIndex(src.i_cursor, src.fg.jointype, wc, piw)) {
                continue; // Partial index inappropriate for this query
            }
        }
        if (probe.no_query) continue;
        r_size = probe.ai_row_log_est[0];
        new.btree.n_eq = 0;
        new.btree.n_btm = 0;
        new.btree.n_top = 0;
        new.btree.n_distinct_col = 0;
        new.n_skip = 0;
        new.n_lterm = 0;
        new.i_sort_idx = 0;
        new.r_setup = 0;
        new.prereq = m_prereq;
        new.n_out = r_size;
        new.btree.index = probe;
        new.btree.order_by = null;
        const b = indexMightHelpWithOrderBy(builder, probe, src.i_cursor);

        // ONEPASS_DESIRED never occurs together with ORDER BY.
        std.debug.assert(!w.wctrl_flags.ONEPASS_DESIRED or !b);
        if (probe.idx_type == .ipk) {
            // Integer primary key index: full table scan.
            new.ws_flags = .{ .IPK = true };
            new.i_sort_idx = if (b) i_sort_idx else 0;
            // TUNING: a full table scan costs 3.0*N, to discourage it.
            new.r_run = r_size + 16;
            whereLoopOutputAdjust(wc, new, r_size);
            if (src.fg.is_subquery) {
                if (src.fg.via_coroutine) new.ws_flags.COROUTINE = true;
                // The ORDER BY of a recursive CTE does not fix its order.
                const sub = src.u4.subq.?.select;
                if (!sub.sel_flags.Recursive) {
                    new.btree.order_by = sub.order_by;
                }
            } else if (src.fg.from_exists) {
                new.n_out = 0;
            }
            flow = try whereLoopInsert(builder, new);
            new.n_out = r_size;
            if (flow != .ok) break;
        } else {
            var m: Bitmask = undefined;
            if (probe.is_covering) {
                m = 0;
                new.ws_flags = .{ .IDX_ONLY = true, .INDEXED = true };
            } else {
                m = src.col_used & probe.col_not_idxed;
                if (probe.part_idx_where) |piw| {
                    try wherePartIdxExpr(p, probe, piw, &m, 0, null);
                }
                new.ws_flags = .{ .INDEXED = true };
                if (m == TOPBIT or (probe.has_expr and !probe.has_vcol and m != 0)) {
                    const is_cov = whereIsCoveringIndex(w, probe, src.i_cursor);
                    if (is_cov.isEmpty()) {
                        std.debug.assert(m != 0);
                    } else {
                        m = 0;
                        new.ws_flags.set(is_cov);
                    }
                } else if (m == 0 and (tab.hasRowid() or w.select != null)) {
                    new.ws_flags = .{ .IDX_ONLY = true, .INDEXED = true };
                }
            }

            // Full scan via index. (sqlite3GlobalConfig.bUseCis is
            // SQLITE_ALLOW_COVERING_INDEX_SCAN, on by default.)
            if (b or
                !tab.hasRowid() or
                probe.part_idx_where != null or
                src.fg.is_indexed_by or
                (m == 0 and
                    !probe.unordered and
                    probe.sz_idx_row < tab.sz_tab_row and
                    !w.wctrl_flags.ONEPASS_DESIRED and
                    !p.db.optDisabled(OPT.CoverIdxScan)))
            {
                new.i_sort_idx = if (b) i_sort_idx else 0;

                // Visiting the index rows costs N*K, K between 1.1 and 3.0
                // depending on the relative row sizes.
                new.r_run = @intCast(@as(i32, r_size) + 1 +
                    @divTrunc(15 * @as(i32, probe.sz_idx_row), @as(i32, tab.sz_tab_row)));
                if (m != 0) {
                    // Non-covering: add 3x the table lookups, less those
                    // avoided by terms the index alone can evaluate.
                    var n_lookup: LogEst = r_size + 16; // Base cost: N*3
                    const i_cur = src.i_cursor;
                    const wc2 = &w.s_wc;
                    for (wc2.terms()) |*term| {
                        if (!expr_mod.coveredByIndex(term.expr, i_cur, probe)) break;
                        if (term.truth_prob <= 0) {
                            n_lookup += term.truth_prob;
                        } else {
                            n_lookup -= 1;
                            if (term.e_operator & (WO.EQ | WO.IS) != 0) n_lookup -= 19;
                        }
                    }
                    new.r_run = util.logEstAdd(new.r_run, n_lookup);
                }
                whereLoopOutputAdjust(wc, new, r_size);
                if (src.fg.jointype.RIGHT and probe.col_expr != null) {
                    // No SCAN of an index-on-expression in a RIGHT JOIN: its
                    // cursor might be misplaced in the no-match loop.
                } else {
                    if (src.fg.from_exists) new.n_out = 0;
                    flow = try whereLoopInsert(builder, new);
                }
                new.n_out = r_size;
                if (flow != .ok) break;
            }
        }

        builder.bld_flags1 = 0;
        const rc = whereLoopAddBtreeIndex(builder, src, probe, 0);
        if (builder.bld_flags1 == wi.BLDF1_INDEXED) {
            // A non-unique index (or a prefix of a unique one) is used, so
            // sqlite_stat1 data matters for scoring the plan.
            tab.tab_flags.MaybeReanalyze = true;
        }
        flow = try rc;
    }
    return flow;
}

// ======================================================== virtual tables

/// Port of allocateIndexInfo() (where.c): the sqlite3_index_info for
/// xBestIndex of virtual table `src`, listing the WHERE terms on it
/// (marked TERM_OK) and the ORDER BY if the table can do all of it.
/// Constraints that may not be omitted are flagged in `no_omit`.
fn allocateIndexInfo(w: *WhereInfo, wc: *WhereClause, m_unusable: Bitmask, src: *SrcItem, no_omit: *u16) Oom!*vtab.HiddenIndexInfo {
    const p = w.parse;
    const tab = src.s_tab.?;
    std.debug.assert(tab.isVirtual());
    var m_no_omit: u16 = 0;
    var e_distinct: i32 = 0;
    const order_by = w.order_by;

    // Mark the WHERE terms on this virtual table TERM_OK.
    var n_term: usize = 0;
    var it: ?*WhereClause = wc;
    while (it) |c| : (it = c.outer) {
        for (c.terms()) |*term| {
            term.wt_flags.OK = false;
            if (term.left_cursor != src.i_cursor) continue;
            if (term.prereq_right & m_unusable != 0) continue;
            // IsPowerOfTwo(), which holds for 0 too.
            const eop = term.e_operator & ~WO.EQUIV;
            std.debug.assert(eop & (eop -% 1) == 0);
            if (term.e_operator & ~WO.EQUIV == 0) continue;
            if (term.wt_flags.VNULL) continue;
            std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
            std.debug.assert(term.left_column >= XN_ROWID);
            std.debug.assert(term.left_column < tab.nCol());
            if (src.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true }) and
                !constraintCompatibleWithOuterJoin(term, src))
            {
                continue;
            }
            n_term += 1;
            term.wt_flags.OK = true;
        }
    }

    // The ORDER BY goes to xBestIndex if it is all columns of this table.
    var n_order_by: usize = 0;
    if (order_by) |ob| {
        const n = ob.len();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = ob.at(i).expr.?;
            // Constant terms are skipped.
            if (expr_mod.isConstant(null, e)) continue;
            // Virtual tables cannot do NULLS FIRST.
            if (ob.at(i).fg.sort_flags & int.KeyInfoOrder.bignull != 0) break;
            // A column of the table.
            if (e.op == TK.COLUMN and e.i_table == src.i_cursor) {
                std.debug.assert(e.i_column >= XN_ROWID and e.i_column < tab.nCol());
                continue;
            }
            // A column with a COLLATE that is the column's own.
            if (e.op == TK.COLLATE) if (e.left) |e2| if (e2.op == TK.COLUMN and e2.i_table == src.i_cursor) {
                std.debug.assert(!e.flags.IntValue);
                e.i_column = e2.i_column;
                if (e2.i_column < 0) continue; // the rowid has no collation
                const z_coll = @import("build.zig").columnColl(&tab.cols[@intCast(e2.i_column)]) orelse coll_mod.str_binary;
                if (ctype.strICmp(e.token(), z_coll) == 0) continue;
            };
            break;
        }
        if (i == n) {
            const b_sort_by_group: i32 = @intFromBool(w.wctrl_flags.SORTBYGROUP);
            n_order_by = n;
            if (w.wctrl_flags.DISTINCTBY and !src.fg.rowid_used) {
                e_distinct = 2 + b_sort_by_group;
            } else if (w.wctrl_flags.GROUPBY) {
                e_distinct = 1 - b_sort_by_group;
            } else if (w.wctrl_flags.WANT_DISTINCT) {
                e_distinct = 3;
            }
        }
    }

    const a = p.arena;
    const h = try a.create(vtab.HiddenIndexInfo);
    h.* = .{
        .info = .{
            .constraints = try a.alloc(vtab.IndexConstraint, n_term),
            .order_by = try a.alloc(vtab.IndexOrderBy, n_order_by),
            .usage = try a.alloc(vtab.IndexConstraintUsage, n_term),
            .col_used = src.col_used,
        },
        .wc = wc,
        .parse = p,
        .e_distinct = e_distinct,
        .rhs = try a.alloc(?*@import("../vdbe/vdbe_int.zig").Mem, n_term),
    };
    @memset(h.rhs, null);
    @memset(h.info.usage, .{});
    const info = &h.info;
    if (!tab.hasRowid()) {
        // The bits of the PRIMARY KEY columns are always set, for RIGHT
        // joins and OR loops.
        const pk = @import("build.zig").primaryKeyIndex(tab).?;
        for (pk.ai_column[0..pk.n_key_col]) |c| {
            var i_col: i32 = c;
            std.debug.assert(i_col >= 0);
            if (i_col >= int.bms - 1) i_col = int.bms - 1;
            info.col_used |= wi.maskBit(i_col);
        }
    }

    var j: usize = 0;
    var i: i32 = 0;
    it = wc;
    while (it) |c| : (it = c.outer) {
        for (c.terms()) |*term| {
            defer i += 1;
            if (!term.wt_flags.OK) continue;
            const cons = &info.constraints[j];
            cons.* = .{ .i_column = term.left_column, .i_term_offset = i, .op = 0 };
            var op = term.e_operator & WO.ALL;
            if (op == WO.IN) {
                if (!term.wt_flags.SLICE) {
                    h.m_in |= wi.smaskBit32(j);
                }
                op = WO.EQ;
            }
            if (op == WO.AUX) {
                cons.op = term.e_match_op;
            } else if (op & (WO.ISNULL | WO.IS) != 0) {
                cons.op = if (op == WO.ISNULL) vtab.INDEX_CONSTRAINT.ISNULL else vtab.INDEX_CONSTRAINT.IS;
            } else {
                // The WO_ and SQLITE_INDEX_CONSTRAINT_ codes are the same
                // (WO_EQUIV is cut off, as by the u8 cast in C).
                cons.op = @truncate(op);
                std.debug.assert(term.e_operator & (WO.IN | WO.EQ | WO.LT | WO.LE | WO.GT | WO.GE | WO.AUX) != 0);
                if (op & (WO.LT | WO.LE | WO.GT | WO.GE) != 0 and expr_mod.isVector(term.expr.right.?)) {
                    if (j < 16) m_no_omit |= @as(u16, 1) << @intCast(j);
                    if (op == WO.LT) cons.op = @intCast(WO.LE);
                    if (op == WO.GT) cons.op = @intCast(WO.GE);
                }
            }
            j += 1;
        }
    }
    std.debug.assert(j == n_term);
    j = 0;
    if (n_order_by > 0) for (order_by.?.slice()[0..n_order_by]) |item| {
        const e = item.expr.?;
        if (expr_mod.isConstant(null, e)) continue;
        std.debug.assert(e.op == TK.COLUMN or (e.op == TK.COLLATE and e.left.?.op == TK.COLUMN and e.i_column == e.left.?.i_column));
        info.order_by[j] = .{ .i_column = e.i_column, .desc = item.fg.sort_flags & int.KeyInfoOrder.desc != 0 };
        j += 1;
    };
    info.order_by = info.order_by[0..j];

    no_omit.* = m_no_omit;
    return h;
}

/// Port of freeIdxStr() (where.c): free IndexInfo.idx_str if the core
/// owns it.
fn freeIdxStr(db: *int.Sqlite3, info: *vtab.IndexInfo) void {
    if (info.need_to_free_idx_str) {
        if (info.idx_str) |z| db.gpa.free(z);
        info.idx_str = null;
        info.need_to_free_idx_str = false;
    }
}

/// Port of freeIndexInfo() (where.c): the right-hand-side values and the
/// structure itself are in the statement's memory.
fn freeIndexInfo(db: *int.Sqlite3, h: *vtab.HiddenIndexInfo) void {
    for (h.rhs) |*r| {
        if (r.*) |m| @import("../vdbe/mem.zig").release(m);
        r.* = null;
    }
    freeIdxStr(db, &h.info);
}

/// The outcome of an xBestIndex call that did not fail: `constraint` is
/// its SQLITE_CONSTRAINT, an unusable combination of constraints, which
/// gives no plan but is not an error.
const BestIndex = enum { ok, constraint };

/// Port of vtabBestIndex() (where.c): call xBestIndex. Its other result
/// codes are left in `p` (error.ParseFailed).
fn vtabBestIndex(p: *Parse, tab: *Table, info: *vtab.IndexInfo) ParseError!BestIndex {
    const db = p.db;
    const vt = vtab.getVTable(db, tab).?;
    const pv = vt.vtab.?;
    db.n_schema_lock += 1;
    const rc = pv.module.x_best_index.?(pv, info);
    db.n_schema_lock -= 1;
    if (rc != RC.OK and rc != RC.CONSTRAINT) {
        if (rc == RC.NOMEM) {
            db.oomFault();
        } else if (pv.err_msg) |msg| {
            util.errorMsg(p, "{s}", .{msg});
        } else {
            util.errorMsg(p, "{s}", .{util.errStr(rc)});
        }
    }
    if (tab.u.vtab.p.?.b_all_schemas) vtabUsesAllSchemas(p);
    if (pv.err_msg) |msg| db.gpa.free(msg);
    pv.err_msg = null;
    return switch (rc) {
        RC.OK => .ok,
        RC.CONSTRAINT => .constraint,
        else => error.ParseFailed,
    };
}

/// Port of sqlite3VtabUsesAllSchemas() (where.c): the statement uses every
/// database (as sqlite_dbpage does): read transactions on all of them, or
/// write transactions if it writes.
pub fn vtabUsesAllSchemas(p: *Parse) void {
    const build = @import("build.zig");
    const n_db = p.db.dbs.items.len;
    for (0..n_db) |i| build.codeVerifySchema(p, i);
    if (p.write_mask != 0) {
        for (0..n_db) |i| build.beginWriteOperation(p, false, i);
    }
}

/// Port of isLimitTerm() (where.c): a LIMIT or OFFSET term of a virtual
/// table.
fn isLimitTerm(term: *const WhereTerm) bool {
    std.debug.assert(term.e_operator == WO.AUX or term.e_match_op == 0);
    return term.e_match_op >= vtab.INDEX_CONSTRAINT.LIMIT and term.e_match_op <= vtab.INDEX_CONSTRAINT.OFFSET;
}

/// Port of allConstraintsUsed() (where.c): the first `n_cons` constraints
/// have an argvIndex.
fn allConstraintsUsed(usage: []const vtab.IndexConstraintUsage, n_cons: usize) bool {
    for (usage[0..n_cons]) |u| {
        if (u.argv_index <= 0) return false;
    }
    return true;
}

/// Port of whereLoopAddVirtualOne() (where.c): call xBestIndex with the
/// constraints usable with `m_usable` (and not using an operator of
/// `m_exclude`) and add the plan it returns. `b_in` tells whether the plan
/// uses an IN term; `retry_limit` (null to ignore LIMIT and OFFSET terms)
/// is set if the plan must be redone without LIMIT and OFFSET.
fn whereLoopAddVirtualOne(
    builder: *WhereLoopBuilder,
    m_prereq: Bitmask,
    m_usable: Bitmask,
    m_exclude: u16,
    h: *vtab.HiddenIndexInfo,
    m_no_omit: u16,
    b_in: *bool,
    retry_limit: ?*bool,
) AddError!Flow {
    const wc = builder.wc;
    const info = &h.info;
    const usage = info.usage;
    const new = builder.new;
    const p = builder.w_info.parse;
    const src = builder.w_info.tab_list.at(new.i_tab);
    const n_constraint = info.constraints.len;
    const db = p.db;

    std.debug.assert(m_usable & m_prereq == m_prereq);
    b_in.* = false;
    new.prereq = m_prereq;

    // Mark the usable constraints.
    for (info.constraints) |*cons| {
        const term = vtab.termFromWhereClause(wc, cons.i_term_offset).?;
        cons.usable = false;
        if (term.prereq_right & m_usable == term.prereq_right and
            term.e_operator & m_exclude == 0 and
            (retry_limit != null or !isLimitTerm(term)))
        {
            cons.usable = true;
        }
    }

    // Initialize the outputs.
    @memset(usage, .{});
    std.debug.assert(!info.need_to_free_idx_str);
    info.idx_str = null;
    info.idx_num = 0;
    info.order_by_consumed = false;
    info.estimated_cost = 1e99 / 2.0;
    info.estimated_rows = 25;
    info.idx_flags = 0;
    h.m_handle_in = 0;

    // Invoke xBestIndex.
    switch (try vtabBestIndex(p, src.s_tab.?, info)) {
        .ok => {},
        .constraint => {
            // An unusable combination of constraints: no plan.
            freeIdxStr(db, info);
            return .ok;
        },
    }

    var mx_term: i32 = -1;
    std.debug.assert(new.nLSlot() >= n_constraint);
    @memset(new.a_lterm[0..n_constraint], null);
    new.vtab = .{};
    for (info.constraints, 0..) |*cons, i| {
        const i_term = usage[i].argv_index - 1;
        if (i_term >= 0) {
            const j = cons.i_term_offset;
            const term_opt = if (j < 0) null else vtab.termFromWhereClause(wc, j);
            if (i_term >= n_constraint or term_opt == null or
                new.a_lterm[@intCast(i_term)] != null or !cons.usable)
            {
                util.errorMsg(p, "{s}.xBestIndex malfunction", .{src.s_tab.?.name});
                freeIdxStr(db, info);
                return error.ParseFailed;
            }
            const term = term_opt.?;
            new.prereq |= term.prereq_right;
            std.debug.assert(i_term < new.nLSlot());
            new.a_lterm[@intCast(i_term)] = term;
            if (i_term > mx_term) mx_term = i_term;
            if (usage[i].omit) {
                if (i < 16 and (@as(u16, 1) << @intCast(i)) & m_no_omit == 0) {
                    new.vtab.omit_mask |= @as(u16, 1) << @intCast(i_term);
                }
                if (term.e_match_op == vtab.INDEX_CONSTRAINT.OFFSET) new.vtab.b_omit_offset = true;
            }
            if (wi.smaskBit32(i) & h.m_handle_in != 0) {
                new.vtab.m_handle_in |= @as(u32, 1) << @intCast(@as(u32, @intCast(i_term)) & 31);
            } else if (term.e_operator & WO.IN != 0) {
                // A plan with an IN constraint cannot consume the ORDER
                // BY: the order of the IN values is not that of the output,
                // and several outputs of one value do not merge.
                info.order_by_consumed = false;
                info.idx_flags &= ~vtab.INDEX_SCAN_UNIQUE;
                b_in.* = true;
                std.debug.assert(m_exclude & WO.IN == 0);
            }

            // LIMIT and OFFSET terms come last, and only with retry_limit.
            std.debug.assert(retry_limit != null or !isLimitTerm(term));
            if (isLimitTerm(term) and (b_in.* or !allConstraintsUsed(usage, i))) {
                // With an IN term handled as separate xFilter calls, or
                // other constraints unused, LIMIT and OFFSET cannot be
                // used: the caller retries without them.
                freeIdxStr(db, info);
                retry_limit.?.* = true;
                return .ok;
            }
        }
    }

    new.n_lterm = @intCast(mx_term + 1);
    for (new.a_lterm[0..new.n_lterm]) |t| {
        if (t == null) {
            // The argvIndex values must be contiguous.
            util.errorMsg(p, "{s}.xBestIndex malfunction", .{src.s_tab.?.name});
            freeIdxStr(db, info);
            return error.ParseFailed;
        }
    }
    std.debug.assert(new.n_lterm <= new.nLSlot());
    new.vtab.idx_num = info.idx_num;
    // The plan takes the string: it owns it with need_to_free_idx_str
    // (whereLoopInsert() hands it to the loop it fills); otherwise the
    // module keeps it valid (P4_STATIC).
    new.vtab.idx_str = info.idx_str;
    new.vtab.need_free = info.need_to_free_idx_str;
    info.idx_str = null;
    info.need_to_free_idx_str = false;
    defer whereLoopClearUnion(db, new);
    // C stores (i8)nOrderBy, so a count that truncates to 0 is not ordered.
    new.vtab.is_ordered = info.order_by_consumed and @as(u8, @truncate(info.order_by.len)) != 0;
    new.vtab.b_idx_num_hex = info.idx_flags & vtab.INDEX_SCAN_HEX != 0;
    new.r_setup = 0;
    new.r_run = util.logEstFromDouble(info.estimated_cost);
    new.n_out = util.logEst(@bitCast(info.estimated_rows));

    // WHERE_ONEROW if xBestIndex says the scan visits at most one row.
    if (info.idx_flags & vtab.INDEX_SCAN_UNIQUE != 0) {
        new.ws_flags.ONEROW = true;
    } else {
        new.ws_flags.ONEROW = false;
    }
    return try whereLoopInsert(builder, new);
}

/// Port of whereLoopAddVirtual() (where.c): add the WhereLoops of virtual
/// table builder.new.iTab, calling xBestIndex for each distinct set of
/// usable constraints. Tables of `m_prereq` come before it; those of
/// `m_unusable` after it.
fn whereLoopAddVirtual(builder: *WhereLoopBuilder, m_prereq: Bitmask, m_unusable: Bitmask) AddError!Flow {
    std.debug.assert(m_prereq & m_unusable == 0);
    const w = builder.w_info;
    const p = w.parse;
    const wc = builder.wc;
    const new = builder.new;
    const src = w.tab_list.at(new.i_tab);
    std.debug.assert(src.s_tab.?.isVirtual());
    var m_no_omit: u16 = 0;
    const h = try allocateIndexInfo(w, wc, m_unusable, src, &m_no_omit);
    defer freeIndexInfo(p.db, h);
    const info = &h.info;
    new.r_setup = 0;
    new.ws_flags = .{ .VIRTUALTABLE = true };
    new.n_lterm = 0;
    new.vtab.need_free = false;
    const n_constraint = info.constraints.len;
    try whereLoopResize(p.arena, new, n_constraint);

    // First with all constraints usable.
    var b_in = false;
    var b_retry = false;
    var flow = try whereLoopAddVirtualOne(builder, m_prereq, wi.ALLBITS, 0, h, m_no_omit, &b_in, &b_retry);
    if (b_retry) {
        std.debug.assert(flow == .ok);
        flow = try whereLoopAddVirtualOne(builder, m_prereq, wi.ALLBITS, 0, h, m_no_omit, &b_in, null);
    }

    // If that plan needs no other table and uses no IN, others would be
    // the same (if xBestIndex is sane).
    const m_best = new.prereq & ~m_prereq;
    if (flow == .ok and (m_best != 0 or b_in)) {
        var seen_zero = false; // a plan with no prereqs
        var seen_zero_no_in = false; // ... and no IN
        var m_prev: Bitmask = 0;
        var m_best_no_in: Bitmask = 0;

        // A plan with an IN: try again without IN terms.
        if (b_in) {
            flow = try whereLoopAddVirtualOne(builder, m_prereq, wi.ALLBITS, WO.IN, h, m_no_omit, &b_in, null);
            std.debug.assert(!b_in);
            m_best_no_in = new.prereq & ~m_prereq;
            if (m_best_no_in == 0) {
                seen_zero = true;
                seen_zero_no_in = true;
            }
        }

        // Once for each distinct (prereqRight & ~mPrereq) of the terms.
        while (flow == .ok) {
            var m_next: Bitmask = wi.ALLBITS;
            for (info.constraints) |cons| {
                const m_this = vtab.termFromWhereClause(wc, cons.i_term_offset).?.prereq_right & ~m_prereq;
                if (m_this > m_prev and m_this < m_next) m_next = m_this;
            }
            m_prev = m_next;
            if (m_next == wi.ALLBITS) break;
            if (m_next == m_best or m_next == m_best_no_in) continue;
            flow = try whereLoopAddVirtualOne(builder, m_prereq, m_next | m_prereq, 0, h, m_no_omit, &b_in, null);
            if (new.prereq == m_prereq) {
                seen_zero = true;
                if (!b_in) seen_zero_no_in = true;
            }
        }

        // A plan that needs no other table, with all of them disabled.
        if (flow == .ok and !seen_zero) {
            flow = try whereLoopAddVirtualOne(builder, m_prereq, m_prereq, 0, h, m_no_omit, &b_in, null);
            if (!b_in) seen_zero_no_in = true;
        }

        // And one without IN as well.
        if (flow == .ok and !seen_zero_no_in) {
            flow = try whereLoopAddVirtualOne(builder, m_prereq, m_prereq, WO.IN, h, m_no_omit, &b_in, null);
        }
    }
    return flow;
}

/// Port of whereLoopAddOr(): add WhereLoops for the OR terms of the
/// WHERE clause usable by builder.new.iTab. As in C, a failed sub-search
/// does not stop the OR term (the next one overwrites rc); only running
/// out of memory returns at once.
fn whereLoopAddOr(builder: *WhereLoopBuilder, m_prereq: Bitmask, m_unusable: Bitmask) AddError!Flow {
    const w = builder.w_info;
    const wc = builder.wc;
    const n_term: usize = @intCast(wc.n_term);
    const new = builder.new;
    var rc: AddError!Flow = .ok;
    var temp_wc: WhereClause = undefined;
    var sum: WhereOrSet = .{};
    var cur: WhereOrSet = .{};
    const item = w.tab_list.at(new.i_tab);
    const i_cur = item.i_cursor;

    // The multi-index OR optimization does not work for RIGHT and FULL JOIN.
    if (item.fg.jointype.RIGHT) return .ok;

    var t: usize = 0;
    while (t < n_term and isOk(rc)) : (t += 1) {
        const term = &wc.a[t];
        if (term.e_operator & WO.OR != 0 and term.or_info.?.indexable & new.mask_self != 0) {
            const or_wc = &term.or_info.?.wc;
            var once = true;

            var sub_build = builder.*;
            sub_build.or_set = &cur;

            for (or_wc.terms()) |*or_term| {
                if (or_term.e_operator & WO.AND != 0) {
                    sub_build.wc = &or_term.and_info.?.wc;
                } else if (or_term.left_cursor == i_cur) {
                    temp_wc = .{
                        .w_info = wc.w_info,
                        .outer = wc,
                        .op = TK.AND,
                        .n_term = 1,
                        .n_base = 1,
                        .a = @as(*[1]WhereTerm, or_term),
                    };
                    sub_build.wc = &temp_wc;
                } else {
                    continue;
                }
                cur.n = 0;
                if (item.s_tab.?.isVirtual()) {
                    rc = whereLoopAddVirtual(&sub_build, m_prereq, m_unusable);
                } else {
                    rc = whereLoopAddBtree(&sub_build, m_prereq);
                }
                if (isOk(rc)) {
                    rc = whereLoopAddOr(&sub_build, m_prereq, m_unusable);
                }
                if (rc) |_| {} else |e| if (e == error.OutOfMemory) return e;
                if (cur.n == 0) {
                    sum.n = 0;
                    break;
                } else if (once) {
                    whereOrMove(&sum, &cur);
                    once = false;
                } else {
                    var prev: WhereOrSet = .{};
                    whereOrMove(&prev, &sum);
                    sum.n = 0;
                    for (prev.a[0..prev.n]) |pa| {
                        for (cur.a[0..cur.n]) |ca| {
                            _ = whereOrInsert(
                                &sum,
                                pa.prereq | ca.prereq,
                                util.logEstAdd(pa.r_run, ca.r_run),
                                util.logEstAdd(pa.n_out, ca.n_out),
                            );
                        }
                    }
                }
            }
            new.n_lterm = 1;
            new.a_lterm[0] = term;
            new.ws_flags = .{ .MULTI_OR = true };
            new.r_setup = 0;
            new.i_sort_idx = 0;
            new.btree = .{};
            new.vtab = .{};
            var i: usize = 0;
            while (isOk(rc) and i < sum.n) : (i += 1) {
                // TUNING: add the smallest penalty so the OR-scan always
                // costs more than its most expensive sub-scan.
                new.r_run = sum.a[i].r_run + 1;
                new.n_out = sum.a[i].n_out;
                new.prereq = sum.a[i].prereq;
                rc = try whereLoopInsert(builder, new);
            }
        }
    }
    return rc;
}

/// Port of whereLoopAddAll(): add the WhereLoops for all tables.
/// error.ParseFailed where C returns a nonzero result code other than
/// SQLITE_NOMEM (which is error.OutOfMemory): the error is in the Parse.
pub fn whereLoopAddAll(builder: *WhereLoopBuilder) AddError!void {
    const w = builder.w_info;
    var m_prereq: Bitmask = 0;
    var m_prior: Bitmask = 0;
    const tab_list = w.tab_list;
    const db = w.parse.db;
    var rc: AddError!Flow = .ok;
    var b_first_past_rj = false;
    var has_right_cross_join = false;
    const new = builder.new;

    // pNew must already be initialized.
    std.debug.assert(new.n_lterm == 0);
    std.debug.assert(new.ws_flags.isEmpty());
    std.debug.assert(new.nLSlot() >= new.a_lterm_space.len);

    builder.i_plan_limit = wi.QUERY_PLANNER_LIMIT;
    var i_tab: usize = 0;
    while (i_tab < w.n_level) : (i_tab += 1) {
        const item = tab_list.at(i_tab);
        var m_unusable: Bitmask = 0;
        new.i_tab = @intCast(i_tab);
        builder.i_plan_limit += wi.QUERY_PLANNER_LIMIT_INCR;
        new.mask_self = wi.getMask(&w.s_mask_set, item.i_cursor);
        if (b_first_past_rj or item.fg.jointype.intersects(.{ .OUTER = true, .CROSS = true, .LTORJ = true })) {
            // Prevent reordering across CROSS and outer joins; the right
            // operand of a RIGHT JOIN stays put relative to later terms.
            if (item.fg.jointype.intersects(.{ .LTORJ = true, .CROSS = true })) {
                has_right_cross_join = true;
            }
            m_prereq |= m_prior;
            b_first_past_rj = item.fg.jointype.RIGHT;
        } else if (item.fg.from_exists) {
            // EXISTS-to-JOIN terms stay right of their dependencies.
            const wc = &w.s_wc;
            for (wc.a[0..@intCast(wc.n_base)]) |*term| {
                if (new.mask_self & term.prereq_all != 0) {
                    m_prereq |= term.prereq_all & (new.mask_self -% 1);
                }
            }
        } else if (!has_right_cross_join) {
            m_prereq = 0;
        }
        if (item.s_tab.?.isVirtual()) {
            for (tab_list.slice()[i_tab + 1 ..]) |*p| {
                if (p.fg.jointype.intersects(.{ .OUTER = true, .CROSS = true })) {
                    m_unusable |= wi.getMask(&w.s_mask_set, p.i_cursor);
                }
            }
            rc = whereLoopAddVirtual(builder, m_prereq, m_unusable);
        } else {
            rc = whereLoopAddBtree(builder, m_prereq);
        }
        if (isOk(rc) and builder.wc.has_or) {
            rc = whereLoopAddOr(builder, m_prereq, m_unusable);
        }
        m_prior |= new.mask_self;
        if (!isOk(rc) or db.malloc_failed) {
            const done = if (rc) |flow| flow == .done else |_| false;
            if (done) {
                // The query planner search limit was hit. (C logs
                // "abbreviated query algorithm search"; no sqlite3_log
                // here.)
                rc = .ok;
            } else {
                break;
            }
        }
    }

    whereLoopClear(db, new);
    _ = try rc;
}
