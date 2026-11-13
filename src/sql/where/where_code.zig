//! Port of wherecode.c: code generation for one loop of the WHERE clause,
//! the EXPLAIN QUERY PLAN text of a loop, and the RIGHT JOIN loop.
//!
//! Not ported: the virtual-table loop (Case 1), cursor hints
//! (SQLITE_ENABLE_CURSOR_HINTS is off) and scan status.

const std = @import("std");
const int = @import("../sqlite_int.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const aux = @import("../../vdbe/aux.zig");
const wi = @import("where_int.zig");
const wl = @import("where_loop.zig");
const where_mod = @import("where.zig");
const build = @import("../build.zig");
const expr_mod = @import("../expr.zig");
const ec = @import("../expr_code.zig");
const insert = @import("../insert.zig");
const util = @import("../util.zig");
const vtab = @import("../vtab.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Index = int.Index;
const Bitmask = int.Bitmask;
const Oom = int.Oom;
const Aff = int.Aff;
const EP = int.EP;
const JT = int.JT;
const TK = int.TK;
const WHERE = int.WHERE;
const OP = vi.OP;
const Vdbe = vi.Vdbe;
const Reg = aux.operand.Reg;
const Cursor = aux.operand.Cursor;
const Label = aux.operand.Label;
const Addr = aux.operand.Addr;
const Writer = std.Io.Writer;
const WhereInfo = wi.WhereInfo;
const WhereLevel = wi.WhereLevel;
const WhereLoop = wi.WhereLoop;
const WhereTerm = wi.WhereTerm;
const WhereClause = wi.WhereClause;
const TERM = wi.TERM;
const WO = wi.WO;

// ============================================================ EXPLAIN

/// Port of explainIndexColumnName(): the name of the i-th column of `idx`.
fn explainIndexColumnName(idx: *const Index, i: usize) []const u8 {
    const c = idx.ai_column[i];
    if (c == int.XN_EXPR) return "<expr>";
    if (c == int.XN_ROWID) return "rowid";
    return idx.table.cols[@intCast(c)].name();
}

/// Port of explainAppendTerm(): append "(a,b)<op>(?,?)" for `n_term`
/// columns starting at `i_term`, preceded by " AND " if `b_and`.
fn explainAppendTerm(w: *Writer, idx: *const Index, n_term: usize, i_term: usize, b_and: bool, op: u8) Writer.Error!void {
    std.debug.assert(n_term >= 1);
    if (b_and) try w.writeAll(" AND ");
    if (n_term > 1) try w.writeByte('(');
    for (0..n_term) |i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll(explainIndexColumnName(idx, i_term + i));
    }
    if (n_term > 1) try w.writeByte(')');
    try w.writeByte(op);
    if (n_term > 1) try w.writeByte('(');
    for (0..n_term) |i| {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('?');
    }
    if (n_term > 1) try w.writeByte(')');
}

/// Port of explainIndexRange(): append the subset of rows scanned by the
/// index loop as an expression, as " (a=? AND b>?)".
fn explainIndexRange(w: *Writer, loop: *const WhereLoop) Writer.Error!void {
    const idx = loop.btree.index.?;
    const n_eq = loop.btree.n_eq;
    const n_skip = loop.n_skip;
    if (n_eq == 0 and !loop.ws_flags.intersects(.{ .BTM_LIMIT = true, .TOP_LIMIT = true })) return;
    try w.writeAll(" (");
    var i: usize = 0;
    while (i < n_eq) : (i += 1) {
        const z = explainIndexColumnName(idx, i);
        if (i != 0) try w.writeAll(" AND ");
        if (i >= n_skip) {
            try w.print("{s}=?", .{z});
        } else {
            try w.print("ANY({s})", .{z});
        }
    }
    const j = i;
    var b_and = i != 0;
    if (loop.ws_flags.BTM_LIMIT) {
        try explainAppendTerm(w, idx, loop.btree.n_btm, j, b_and, '>');
        b_and = true;
    }
    if (loop.ws_flags.TOP_LIMIT) {
        try explainAppendTerm(w, idx, loop.btree.n_top, j, b_and, '<');
    }
    try w.writeByte(')');
}

/// The text of sqlite3WhereAddExplainText().
fn explainScanText(w: *Writer, item: *const SrcItem, loop: *const WhereLoop, is_search: bool) Writer.Error!void {
    const flags = loop.ws_flags;
    try w.print("{s} {f}{s}", .{
        if (is_search) "SEARCH" else "SCAN",
        util.srcItemName(item),
        if (item.fg.from_exists) " EXISTS" else "",
    });
    if (!flags.intersects(.{ .IPK = true, .VIRTUALTABLE = true })) {
        const idx = loop.btree.index.?;
        std.debug.assert(!flags.AUTO_INDEX or flags.IDX_ONLY);
        var fmt: ?[]const u8 = null;
        var with_name = false;
        if (!item.s_tab.?.hasRowid() and idx.isPrimaryKey()) {
            if (is_search) fmt = "PRIMARY KEY";
        } else if (flags.PARTIALIDX) {
            fmt = "AUTOMATIC PARTIAL COVERING INDEX";
        } else if (flags.AUTO_INDEX) {
            fmt = "AUTOMATIC COVERING INDEX";
        } else if (flags.intersects(.{ .IDX_ONLY = true, .EXPRIDX = true })) {
            fmt = "COVERING INDEX ";
            with_name = true;
        } else {
            fmt = "INDEX ";
            with_name = true;
        }
        if (fmt) |f| {
            try w.writeAll(" USING ");
            try w.writeAll(f);
            if (with_name) try w.writeAll(idx.name);
            try explainIndexRange(w, loop);
        }
    } else if (flags.IPK and flags.intersects(wi.WS.CONSTRAINT)) {
        const z_rowid = "rowid";
        try w.print(" USING INTEGER PRIMARY KEY ({s}", .{z_rowid});
        var c_range_op: u8 = undefined;
        if (flags.intersects(.{ .COLUMN_EQ = true, .COLUMN_IN = true })) {
            c_range_op = '=';
        } else if (flags.contains(wi.WS.BOTH_LIMIT)) {
            try w.print(">? AND {s}", .{z_rowid});
            c_range_op = '<';
        } else if (flags.BTM_LIMIT) {
            c_range_op = '>';
        } else {
            std.debug.assert(flags.TOP_LIMIT);
            c_range_op = '<';
        }
        try w.print("{c}?)", .{c_range_op});
    } else if (flags.VIRTUALTABLE) {
        try w.writeAll(" VIRTUAL TABLE INDEX ");
        const idx_str: []const u8 = loop.vtab.idx_str orelse "";
        if (loop.vtab.b_idx_num_hex) {
            try w.print("0x{x}:{s}", .{ @as(u32, @bitCast(loop.vtab.idx_num)), idx_str });
        } else {
            try w.print("{d}:{s}", .{ loop.vtab.idx_num, idx_str });
        }
    }
    if (item.fg.jointype.LEFT) try w.writeAll(" LEFT-JOIN");
}

/// Port of sqlite3WhereAddExplainText(): set P4 of the OP_Explain at
/// `addr` to the text describing the loop of `level`.
pub fn addExplainText(p: *Parse, addr: Addr, tab_list: *SrcList, level: *WhereLevel, wctrl_flags: int.WHERE) Oom!void {
    if (build.toplevel(p).explain != .query_plan and !aux.isStmtScanStatus(p.db)) return;
    const v = p.vdbe.?;
    if (p.db.malloc_failed) return;
    const item = tab_list.at(level.i_from);
    const loop = level.w_loop.?;
    const flags = loop.ws_flags;
    const is_search = flags.intersects(.{ .BTM_LIMIT = true, .TOP_LIMIT = true }) or
        (!flags.VIRTUALTABLE and loop.btree.n_eq > 0) or
        wctrl_flags.intersects(.{ .ORDERBY_MIN = true, .ORDERBY_MAX = true });

    var out: Writer.Allocating = try .initCapacity(v.alloc(), 100);
    defer out.deinit();
    explainScanText(&out.writer, item, loop, is_search) catch return error.OutOfMemory;
    const z = try out.toOwnedSliceSentinel(0);
    const op = aux.getOp(v, addr);
    std.debug.assert(op.opcode == OP.Explain);
    op.setP4(.{ .z = z });
}

/// Port of sqlite3WhereExplainOneScan(): the address of the OP_Explain, or
/// null.
pub fn explainOneScan(p: *Parse, tab_list: *SrcList, level: *WhereLevel, wctrl_flags: int.WHERE) Oom!?Addr {
    var ret: ?Addr = null;
    if (build.toplevel(p).explain == .query_plan or aux.isStmtScanStatus(p.db)) {
        const loop = level.w_loop.?;
        if (!loop.ws_flags.MULTI_OR and !wctrl_flags.OR_SUBCLAUSE) {
            const v = p.vdbe.?;
            const addr = aux.here(v);
            ret = aux.emit(v, .Explain, .{ addr.int(), p.addr_explain, loop.r_run });
            try addExplainText(p, addr, tab_list, level, wctrl_flags);
        }
    }
    return ret;
}

/// The text of sqlite3WhereExplainBloomFilter().
fn explainBloomText(w: *Writer, item: *const SrcItem, loop: *const WhereLoop) Writer.Error!void {
    try w.print("BLOOM FILTER ON {f} (", .{util.srcItemName(item)});
    if (loop.ws_flags.IPK) {
        const tab = item.s_tab.?;
        if (tab.i_pkey >= 0) {
            try w.print("{s}=?", .{tab.cols[@intCast(tab.i_pkey)].name()});
        } else {
            try w.writeAll("rowid=?");
        }
    } else {
        var i: usize = loop.n_skip;
        while (i < loop.btree.n_eq) : (i += 1) {
            const z = explainIndexColumnName(loop.btree.index.?, i);
            if (i > loop.n_skip) try w.writeAll(" AND ");
            try w.print("{s}=?", .{z});
        }
    }
    try w.writeByte(')');
}

/// Port of sqlite3WhereExplainBloomFilter(): the address of the OP_Explain.
pub fn explainBloomFilter(p: *Parse, w: *WhereInfo, level: *WhereLevel) Oom!Addr {
    const item = w.tab_list.at(level.i_from);
    const v = p.vdbe.?;
    var out: Writer.Allocating = try .initCapacity(v.alloc(), 100);
    defer out.deinit();
    explainBloomText(&out.writer, item, level.w_loop.?) catch return error.OutOfMemory;
    const msg = try out.toOwnedSliceSentinel(0);
    const ret = aux.emit4(v, .Explain, .{ v.nOp(), p.addr_explain }, .{ .z = msg });
    aux.scanStatus(v, ret, null, null, 0, null);
    return ret;
}

/// Port of sqlite3WhereAddScanStatus(): the sqlite3_stmt_scanstatus()
/// entry of the loop of `level`, which reads `src_list`; `addr_explain`
/// is its OP_Explain, or null.
pub fn addScanStatus(v: *Vdbe, src_list: *SrcList, level: *WhereLevel, addr_explain: ?Addr) void {
    if (!aux.isStmtScanStatus(v.db)) return;
    const loop = level.w_loop.?;
    const ws_flags = loop.ws_flags;
    var obj: ?[]const u8 = null;
    var via_coroutine = false;
    const item = src_list.at(level.i_from);
    if (!ws_flags.VIRTUALTABLE and loop.btree.index != null) {
        obj = loop.btree.index.?.name;
    } else {
        obj = item.name;
        via_coroutine = item.fg.via_coroutine;
    }
    aux.scanStatus(v, addr_explain, level.addr_body, level.addr_visit, loop.n_out, obj);
    if (!via_coroutine) {
        if (!ws_flags.intersects(.{ .MULTI_OR = true, .AUTO_INDEX = true })) {
            aux.scanStatusRange(v, addr_explain, .{ .cursor = level.i_tab_cur });
        }
        if (ws_flags.INDEXED) aux.scanStatusRange(v, addr_explain, .{ .cursor = level.i_idx_cur });
    } else {
        // The co-routine, up to the instruction before the one its
        // OP_InitCoroutine jumps to.
        const addr = item.u4.subq.?.addr_fill_sub.?;
        const op = aux.getOp(v, addr.plus(-1));
        aux.scanStatusRange(v, addr_explain, .{ .span = .{ .start = addr, .end = if (op.p2 > 0) Addr.from(op.p2 - 1) else null } });
    }
}

// ======================================================== term helpers

/// Port of disableTerm(): mark `term` coded so the inner loop does not
/// test it again, unless it controls a LEFT JOIN and did not come from
/// its ON clause. A parent whose children are all disabled is disabled
/// too; a TERM_LIKE parent gets TERM_LIKECOND instead of TERM_CODED.
fn disableTerm(level: *const WhereLevel, term_arg: *WhereTerm) void {
    var term = term_arg;
    var n_loop: i32 = 0;
    while (!term.wt_flags.CODED and
        (level.i_left_join.isNone() or term.expr.flags.OuterON) and
        level.not_ready & term.prereq_all == 0)
    {
        if (n_loop != 0 and term.wt_flags.LIKE) {
            term.wt_flags.LIKECOND = true;
        } else {
            term.wt_flags.CODED = true;
        }
        if (term.i_parent < 0) break;
        term = &term.wc.a[@intCast(term.i_parent)];
        // Wraps as in C: the LIMIT and OFFSET terms of a virtual table have
        // iParent 0 (whereClauseInsert()) but are no child of a[0].
        term.n_child -%= 1;
        if (term.n_child != 0) break;
        n_loop += 1;
    }
}

/// Port of codeApplyAffinity(): OP_Affinity for registers base..base+n-1,
/// skipping BLOB/NONE affinities at either end.
fn codeApplyAffinity(p: *Parse, base_arg: Reg, n_arg: i32, z_aff_arg: ?[]u8) void {
    const v = p.vdbe.?;
    var z_aff = z_aff_arg orelse {
        std.debug.assert(p.db.malloc_failed);
        return;
    };
    var base = base_arg;
    var n = n_arg;
    while (n > 0 and z_aff[0] <= Aff.blob) {
        n -= 1;
        base = base.at(1);
        z_aff = z_aff[1..];
    }
    while (n > 1 and z_aff[@intCast(n - 1)] <= Aff.blob) n -= 1;
    if (n > 0) _ = aux.emitStr(v, .Affinity, .{ base, n }, z_aff[0..@intCast(n)]);
}

/// Port of updateRangeAffinityStr(): set to BLOB the entries of `z_aff`
/// for which no conversion is needed for comparison against `right`.
fn updateRangeAffinityStr(right: *Expr, n: usize, z_aff: []u8) void {
    for (0..n) |i| {
        const e = expr_mod.vectorFieldSubexpr(right, i);
        if (expr_mod.compareAffinity(e, z_aff[i]) == Aff.blob or expr_mod.needsNoAffinityChange(e, z_aff[i])) {
            z_aff[i] = Aff.blob;
        }
    }
}

/// Port of adjustOrderByCol(): renumber the iOrderByCol references of
/// `order_by` after the result set was reduced to `e_list`.
fn adjustOrderByCol(order_by: ?*ExprList, e_list: *ExprList) void {
    const ob = order_by orelse return;
    for (ob.slice()) |*it| {
        const t = it.u.x.order_by_col;
        if (t == 0) continue;
        var j: usize = 0;
        while (j < e_list.len()) : (j += 1) {
            if (e_list.at(j).u.x.order_by_col == t) {
                it.u.x.order_by_col = @intCast(j + 1);
                break;
            }
        }
        if (j >= e_list.len()) it.u.x.order_by_col = 0;
    }
}

/// Port of removeUnindexableInClauseTerms(): a copy of the vector IN
/// expression `x` reduced to the fields used by loop terms i_eq and up.
fn removeUnindexableInClauseTerms(p: *Parse, i_eq: usize, loop: *WhereLoop, x: *Expr) Oom!*Expr {
    const new = (try expr_mod.exprDup(p.arena, x)).?;
    var sel_opt = new.x.select;
    while (sel_opt) |sel| : (sel_opt = sel.prior) {
        const orig_rhs = sel.e_list.?;
        var orig_lhs: ?*ExprList = null;
        var rhs: ?*ExprList = null;
        var lhs: ?*ExprList = null;
        var n_rhs: usize = 0;
        if (sel == new.x.select.?) orig_lhs = new.left.?.x.list;
        for (loop.a_lterm[i_eq..loop.n_lterm]) |lt_opt| {
            const lt = lt_opt.?;
            if (lt.expr != x) continue;
            std.debug.assert(lt.e_operator & (WO.OR | WO.AND) == 0);
            const i_field: usize = @intCast(lt.i_field - 1);
            if (i_field != n_rhs) new.flags.Subrtn = false;
            // A duplicate PK column.
            const fe = orig_rhs.at(i_field).expr orelse continue;
            rhs = try expr_mod.listAppend(p, rhs, fe);
            orig_rhs.at(i_field).expr = null;
            rhs.?.last().u.x.order_by_col = @intCast(i_field + 1);
            if (orig_lhs) |ol| {
                lhs = try expr_mod.listAppend(p, lhs, ol.at(i_field).expr);
                ol.at(i_field).expr = null;
            }
            n_rhs += 1;
        }
        if (orig_lhs != null) new.left.?.x = .{ .list = lhs };
        sel.e_list = rhs;
        // Required for SubrtnSig validity.
        p.n_select += 1;
        sel.sel_id = @intCast(p.n_select);
        if (lhs) |l| if (l.len() == 1) {
            // Do not make a TK_VECTOR of a single value.
            const e0 = l.at(0).expr;
            l.at(0).expr = null;
            new.left = e0;
        };
        // ORDER BY and GROUP BY references to result columns may now be
        // obsolete.
        if (rhs) |r| {
            adjustOrderByCol(sel.order_by, r);
            adjustOrderByCol(sel.group_by, r);
            for (r.slice()) |*it| it.u.x.order_by_col = 0;
        }
    }
    return new;
}

/// Port of codeINTerm(): code an X IN (...) term of loop `level`: set up
/// a loop over the values of X, the current one in register `target`.
fn codeINTerm(p: *Parse, term: *WhereTerm, level: *WhereLevel, i_eq: usize, b_rev_arg: bool, target: Reg) Oom!void {
    const x = term.expr;
    var e_type: ec.IN_INDEX = .NOOP;
    // Null only if out of memory (findInIndex() not called): IN_INDEX_LOOP
    // is never IN_INDEX.NOOP.
    var tab_opt: ?Cursor = null;
    const loop = level.w_loop.?;
    const v = p.vdbe.?;
    var n_eq: usize = 0;
    var ai_map: ?[]i32 = null;
    var b_rev = b_rev_arg;

    if (!loop.ws_flags.VIRTUALTABLE) {
        if (loop.btree.index) |ix| {
            if (ix.sort_order[i_eq] != 0) b_rev = !b_rev;
        }
    }
    std.debug.assert(x.op == TK.IN);

    for (loop.a_lterm[0..i_eq]) |lt| {
        if (lt != null and lt.?.expr == x) {
            disableTerm(level, term);
            return;
        }
    }
    for (loop.a_lterm[i_eq..loop.n_lterm]) |lt| {
        if (lt.?.expr == x) n_eq += 1;
    }

    if (!x.useXSelect() or x.x.select.?.e_list.?.len() == 1) {
        e_type = ec.findInIndex(p, x, ec.IN_INDEX_LOOP, null, null, &tab_opt);
    } else {
        const x_mod = try removeUnindexableInClauseTerms(p, i_eq, loop, x);
        // An IN(SELECT ...) driving more than one index column disables
        // the seek-scan optimization.
        if (n_eq > 1) loop.ws_flags.IN_SEEKSCAN = false;
        if (!p.db.malloc_failed) {
            const n_col = x.x.select.?.e_list.?.len();
            const m = try p.arena.alloc(i32, n_col);
            @memset(m, 0);
            ai_map = m;
            e_type = ec.findInIndex(p, x_mod, ec.IN_INDEX_LOOP, null, m, &tab_opt);
        }
    }
    const tab = tab_opt orelse Cursor.first;

    if (e_type == .INDEX_DESC) b_rev = !b_rev;
    _ = aux.emitAny(v, if (b_rev) OP.Last else OP.Rewind, .{ .cursor, .jump, .int }, .{ tab, 0 });

    std.debug.assert(!loop.ws_flags.MULTI_OR);
    loop.ws_flags.IN_ABLE = true;
    if (level.in_loops.len == 0) level.addr_nxt = aux.newLabel(p);
    if (i_eq > 0 and !loop.ws_flags.IN_SEEKSCAN) loop.ws_flags.IN_EARLYOUT = true;

    const n_old = level.in_loops.len;
    level.in_loops = try p.arena.realloc(level.in_loops, n_old + n_eq);
    for (level.in_loops[n_old..]) |*in| in.* = .{};
    var i_in = n_old;
    var i_map: usize = 0;
    var i = i_eq;
    while (i < loop.n_lterm) : (i += 1) {
        if (loop.a_lterm[i].?.expr != x) continue;
        const in = &level.in_loops[i_in];
        const out = target.at(i - i_eq);
        if (e_type == .ROWID) {
            in.addr_in_top = aux.emit(v, .Rowid, .{ tab, out });
        } else {
            var i_col: i32 = 0;
            if (ai_map) |m| {
                i_col = m[i_map];
                i_map += 1;
            }
            in.addr_in_top = aux.emit(v, .Column, .{ tab, i_col, out });
        }
        _ = aux.emit(v, .IsNull, .{out});
        if (i == i_eq) {
            in.i_cur = tab;
            in.e_end_loop_op = if (b_rev) OP.Prev else OP.Next;
            if (i_eq > 0) {
                in.i_base = target.at(-@as(i32, @intCast(i)));
                in.n_prefix = @intCast(i);
            } else {
                in.n_prefix = 0;
            }
        } else {
            in.e_end_loop_op = OP.Noop;
        }
        i_in += 1;
    }
    if (i_eq > 0 and !loop.ws_flags.intersects(.{ .IN_SEEKSCAN = true, .VIRTUALTABLE = true })) {
        _ = aux.emit(v, .SeekHit, .{ level.i_idx_cur, 0, i_eq });
    }
}

/// Port of codeEqualityTerm(): code an == or IN term; the register
/// holding its current value is returned (`target` is only guaranteed
/// for ISNULL and IN).
fn codeEqualityTerm(p: *Parse, term: *WhereTerm, level: *WhereLevel, i_eq: usize, b_rev: bool, target: Reg) Oom!Reg {
    const x = term.expr;
    var reg: Reg = undefined;
    std.debug.assert(level.w_loop.?.a_lterm[i_eq] == term);
    std.debug.assert(target.int() > 0);
    if (x.op == TK.EQ or x.op == TK.IS) {
        reg = ec.codeTarget(p, x.right, target);
    } else if (x.op == TK.ISNULL) {
        reg = target;
        _ = aux.emit(p.vdbe.?, .Null, .{ 0, reg });
    } else {
        std.debug.assert(x.op == TK.IN);
        reg = target;
        try codeINTerm(p, term, level, i_eq, b_rev, target);
    }
    // The term driving the index is always true, so disable it, unless it
    // is a transitive constraint (forum post eb8613976a).
    if (!level.w_loop.?.ws_flags.TRANSCONS or term.e_operator & WO.EQUIV == 0) {
        disableTerm(level, term);
    }
    return reg;
}

/// Port of codeAllEqualityTerms(): code the == and IN constraints of an
/// index loop into nEq consecutive registers (plus n_extra_reg more for a
/// range constraint), returning the first. `z_aff_out` receives a copy of
/// the index affinity string with entries that need no conversion set
/// to BLOB.
fn codeAllEqualityTerms(p: *Parse, level: *WhereLevel, b_rev: bool, n_extra_reg: i32, z_aff_out: *?[:0]u8) Oom!Reg {
    const v = p.vdbe.?;
    const loop = level.w_loop.?;
    std.debug.assert(!loop.ws_flags.VIRTUALTABLE);
    const n_eq: usize = loop.btree.n_eq;
    const n_skip: usize = loop.n_skip;
    const idx = loop.btree.index.?;

    const n_reg = @as(i32, @intCast(n_eq)) + n_extra_reg;
    const reg_base = p.newRegs(n_reg);

    var z_aff: ?[:0]u8 = null;
    if (insert.indexAffinityStr(p, idx)) |s| z_aff = try p.arena.dupeSentinel(u8, std.mem.sliceTo(s, 0), 0);
    std.debug.assert(z_aff != null or p.db.malloc_failed);

    if (n_skip != 0) {
        const idx_cur = level.i_idx_cur;
        const ns: i32 = @intCast(n_skip);
        _ = aux.emit(v, .Null, .{ 0, reg_base, reg_base.at(ns - 1) });
        _ = aux.emitAny(v, if (b_rev) OP.Last else OP.Rewind, .{ .cursor, .jump, .int }, .{idx_cur});
        const j = aux.emit(v, .Goto, .{});
        std.debug.assert(level.addr_skip == null);
        const skip = aux.emitAnyInt(v, if (b_rev) OP.SeekLT else OP.SeekGT, .{ .cursor, .jump, .reg }, .{ idx_cur, 0, reg_base }, ns);
        level.addr_skip = skip;
        aux.landHere(v, j);
        for (0..n_skip) |jj| {
            _ = aux.emit(v, .Column, .{ idx_cur, jj, reg_base.at(jj) });
        }
    }

    std.debug.assert(z_aff == null or z_aff.?.len >= n_eq);
    var j = n_skip;
    while (j < n_eq) : (j += 1) {
        const term = loop.a_lterm[j].?;
        const reg_j = reg_base.at(j);
        const r1 = try codeEqualityTerm(p, term, level, j, b_rev, reg_j);
        if (r1 != reg_j) _ = aux.emit(v, .Copy, .{ r1, reg_j });
        if (term.e_operator & WO.IN != 0) {
            // The RHS of "? IN (SELECT ...)" already has the comparison
            // affinity applied by sqlite3FindInIndex().
            if (term.expr.flags.xIsSelect) {
                if (z_aff) |z| z[j] = Aff.blob;
            }
        } else if (term.e_operator & WO.ISNULL == 0) {
            const right = term.expr.right.?;
            if (!term.wt_flags.IS and expr_mod.canBeNull(right)) {
                _ = aux.emit(v, .IsNull, .{ reg_j, level.addr_brk });
            }
            if (p.n_err == 0) {
                std.debug.assert(!p.db.malloc_failed);
                const z = z_aff.?;
                if (expr_mod.compareAffinity(right, z[j]) == Aff.blob) z[j] = Aff.blob;
                if (expr_mod.needsNoAffinityChange(right, z[j])) z[j] = Aff.blob;
            }
        }
    }
    z_aff_out.* = z_aff;
    return reg_base;
}

/// Port of whereLikeOptimizationStringFixup(): if the last instruction
/// is the OP_String8 of a LIKE-optimization bound, point its P3 at the
/// LIKE loop counter (and P5 at the scan direction) so the second pass
/// casts it to a BLOB.
fn whereLikeOptimizationStringFixup(v: *Vdbe, level: *const WhereLevel, term: *const WhereTerm) void {
    if (term.wt_flags.LIKEOPT) {
        std.debug.assert(level.i_like_rep_cntr > 0);
        const op = aux.getLastOp(v);
        std.debug.assert(op.opcode == OP.String8 or v.db.malloc_failed);
        op.p3 = @intCast(level.i_like_rep_cntr >> 1);
        op.p5 = @intCast(level.i_like_rep_cntr & 1);
    }
}

/// Port of codeDeferredSeek(): OP_DeferredSeek of table cursor `cur`
/// to the rowid in index cursor `idx_cur`. In an OR branch or RIGHT
/// JOIN of a read-only statement, P4 maps table columns to index
/// columns so that OP_Column may avoid the seek.
fn codeDeferredSeek(w: *WhereInfo, idx: *Index, cur: Cursor, idx_cur: Cursor) Oom!void {
    const p = w.parse;
    const v = p.vdbe.?;
    std.debug.assert(idx_cur.int() > 0);
    std.debug.assert(idx.ai_column[idx.n_column - 1] == -1);

    w.b_deferred_seek = true;
    _ = aux.emit(v, .DeferredSeek, .{ idx_cur, 0, cur });
    if (w.wctrl_flags.intersects(.{ .OR_SUBCLAUSE = true, .RIGHT_JOIN = true }) and build.toplevel(p).write_mask == 0) {
        const tab = idx.table;
        const n_col: usize = @intCast(tab.nCol());
        const ai = try v.alloc().alloc(u32, n_col + 1);
        @memset(ai, 0);
        ai[0] = @intCast(n_col);
        for (0..idx.n_column - 1) |i| {
            const x1 = idx.ai_column[i];
            std.debug.assert(x1 < tab.nCol());
            const x2 = build.tableColumnToStorage(tab, x1);
            if (x1 >= 0) ai[@as(usize, @intCast(x2)) + 1] = @intCast(i + 1);
        }
        aux.changeP4(v, null, .{ .intarray = ai });
    }
}

/// Case 1 of sqlite3WhereCodeOneLoopStart(): the loop over virtual table
/// cursor `cur`, by OP_VFilter and OP_VNext.
fn codeVirtualLoop(p: *Parse, v: *Vdbe, w: *WhereInfo, level: *WhereLevel, cur: Cursor, b_rev: bool) Oom!void {
    const db = p.db;
    const loop = level.w_loop.?;
    const n_constraint: usize = loop.n_lterm;
    // The arguments of xFilter: idxNum, argc, and then the values.
    const reg_args = expr_mod.getTempRange(p, n_constraint + 2);
    var addr_not_found = level.addr_brk;
    for (0..n_constraint) |j| {
        const target = reg_args.at(j + 2);
        const term = loop.a_lterm[j] orelse continue;
        if (term.e_operator & WO.IN != 0) {
            if (wi.smaskBit32(j) & loop.vtab.m_handle_in != 0) {
                const tab = p.newCursor();
                const cache = p.newReg();
                ec.codeRhsOfIN(p, term.expr, tab, false);
                _ = aux.emit(v, .VInitIn, .{ tab, target, cache });
            } else {
                _ = try codeEqualityTerm(p, term, level, j, b_rev, target);
                addr_not_found = level.addr_nxt;
            }
        } else {
            const right = term.expr.right;
            codeExprOrVector(p, right, target, 1);
            if (term.e_match_op == vtab.INDEX_CONSTRAINT.OFFSET and loop.vtab.b_omit_offset) {
                std.debug.assert(term.e_operator == WO.AUX);
                std.debug.assert(w.select != null and !w.select.?.i_offset.isNone());
                // Zero the OFFSET counter.
                _ = aux.emit(v, .Integer, .{ 0, w.select.?.i_offset });
            }
        }
    }
    _ = aux.emit(v, .Integer, .{ loop.vtab.idx_num, reg_args });
    _ = aux.emit(v, .Integer, .{ n_constraint, reg_args.at(1) });
    // The instruction before OP_VFilter must be the OP_Integer of argc,
    // for resolveP2Values() (tag-20250207a).
    // The program gets its own copy of the string. One the loop owns (from
    // db.gpa) is freed now, and the loop keeps the copy, which lives as
    // long as the program; out of memory, the loop keeps its string and
    // frees it with the plan.
    const addr_filter = aux.emit(v, .VFilter, .{ cur, addr_not_found, reg_args });
    if (loop.vtab.idx_str) |z| if (!db.malloc_failed) {
        if (v.alloc().dupeSentinel(u8, z, 0)) |copy| {
            aux.changeP4(v, addr_filter, .{ .z = copy });
            if (loop.vtab.need_free) {
                db.gpa.free(z);
                loop.vtab.idx_str = copy;
                loop.vtab.need_free = false;
            }
        } else |_| db.oomFault();
    };
    level.end = if (w.e_one_pass != .OFF) .none else .{ .step = .{ .op = OP.VNext, .cur = cur, .top = aux.here(v) } };
    std.debug.assert(!loop.ws_flags.MULTI_OR);

    for (0..n_constraint) |j| {
        const term = loop.a_lterm[j].?;
        if (j < 16 and (loop.vtab.omit_mask >> @intCast(j)) & 1 != 0) {
            disableTerm(level, term);
            continue;
        }
        if (term.e_operator & WO.IN != 0 and wi.smaskBit32(j) & loop.vtab.m_handle_in == 0 and !db.malloc_failed) {
            // Reload the value of the constraint into reg[reg_args+j+2]:
            // xFilter may have changed its type or encoding.
            const reg = reg_args.at(j + 2);
            for (level.in_loops) |in| {
                const op = aux.getOp(v, in.addr_in_top);
                if ((op.opcode == OP.Column and op.p3 == reg.int()) or (op.opcode == OP.Rowid and op.p2 == reg.int())) {
                    // The instruction that loaded it, again.
                    _ = aux.emitRaw(v, op.opcode, op.p1, op.p2, op.p3);
                    break;
                }
            }

            // Continue with the next row if the IN constraint fails.
            const compare = try expr_mod.pExpr(p, TK.EQ, null, null);
            if (!db.malloc_failed) {
                const i_fld = term.i_field;
                const left = term.expr.left.?;
                if (i_fld > 0) {
                    std.debug.assert(left.op == TK.VECTOR);
                    std.debug.assert(left.useXList());
                    compare.left = left.x.list.?.at(@intCast(i_fld - 1)).expr;
                } else {
                    compare.left = left;
                }
                const right = try expr_mod.exprAlloc(p.arena, TK.REGISTER, null, false);
                compare.right = right;
                right.i_table = reg.int();
                ec.exprIfFalse(p, compare, level.addr_cont, true);
                compare.left = null;
            }
        }
    }
    // The registers are kept for any IN operator loop rather than
    // released (sqlite3ReleaseTempRange() is not called).
}

/// Port of codeExprOrVector(): code the first `n_reg` elements of vector
/// `e` into registers `reg`.., or (n_reg 1) the value of `e`.
fn codeExprOrVector(p: *Parse, e_opt: ?*Expr, reg: Reg, n_reg: usize) void {
    std.debug.assert(n_reg > 0);
    if (e_opt) |e| if (expr_mod.isVector(e)) {
        if (e.useXSelect()) {
            const v = p.vdbe.?;
            std.debug.assert(e.op == TK.SELECT);
            const reg_select: Reg = ec.codeSubselect(p, e);
            _ = aux.emit(v, .Copy, .{ reg_select, reg, @as(i32, @intCast(n_reg)) - 1 });
        } else {
            const list = e.x.list.?;
            std.debug.assert(n_reg <= list.len());
            for (0..n_reg) |i| ec.exprCode(p, list.at(i).expr, reg.at(i));
        }
        return;
    };
    std.debug.assert(n_reg == 1 or p.n_err != 0);
    ec.exprCode(p, e_opt, reg);
}

/// Port of whereApplyPartialIndexConstraints(): mark coded the WHERE
/// terms implied by `truth`, the WHERE clause of the partial index that
/// drives the loop.
fn whereApplyPartialIndexConstraints(truth_arg: *Expr, i_tab_cur: i32, wc: *WhereClause) void {
    var truth = truth_arg;
    while (truth.op == TK.AND) {
        whereApplyPartialIndexConstraints(truth.left.?, i_tab_cur, wc);
        truth = truth.right.?;
    }
    for (wc.terms()) |*term| {
        if (term.wt_flags.CODED) continue;
        if (expr_mod.compare(null, term.expr, truth, i_tab_cur) == 0) {
            term.wt_flags.CODED = true;
        }
    }
}

/// Port of filterPullDown(): right after an OP_Filter, also check the
/// Bloom filters of inner loops before the index lookup, and clear their
/// reg_filter so they are not checked again.
fn filterPullDown(p: *Parse, w: *WhereInfo, i_level_arg: usize, addr_nxt: Label, not_ready: Bitmask) Oom!void {
    var i_level = i_level_arg + 1;
    while (i_level < w.n_level) : (i_level += 1) {
        const level = &w.a[i_level];
        const loop = level.w_loop.?;
        if (level.reg_filter.isNone()) continue;
        if (loop.n_skip != 0) continue;
        // ConstructBloomFilter() does not set reg_filter in this case.
        if (loop.prereq & not_ready != 0) continue;
        const saved_addr_brk = level.addr_brk;
        level.addr_brk = addr_nxt;
        if (loop.ws_flags.IPK) {
            const term = loop.a_lterm[0].?;
            var reg_rowid = expr_mod.getTempReg(p);
            reg_rowid = try codeEqualityTerm(p, term, level, 0, false, reg_rowid);
            _ = aux.emit(p.vdbe.?, .MustBeInt, .{ reg_rowid, addr_nxt });
            _ = aux.emitInt(p.vdbe.?, .Filter, .{ level.reg_filter, addr_nxt, reg_rowid }, 1);
        } else {
            const n_eq = loop.btree.n_eq;
            var z_start_aff: ?[:0]u8 = null;
            std.debug.assert(loop.ws_flags.INDEXED);
            std.debug.assert(!loop.ws_flags.COLUMN_IN);
            const r1 = try codeAllEqualityTerms(p, level, false, 0, &z_start_aff);
            codeApplyAffinity(p, r1, n_eq, z_start_aff);
            _ = aux.emitInt(p.vdbe.?, .Filter, .{ level.reg_filter, addr_nxt, r1 }, n_eq);
        }
        level.reg_filter = .none;
        level.addr_brk = saved_addr_brk;
    }
}

/// Port of whereLoopIsOneRow(): an indexed loop with IN operators visits
/// at most one row per key.
fn whereLoopIsOneRow(loop: *const WhereLoop) bool {
    const idx = loop.btree.index.?;
    if (idx.on_error != .None and loop.n_skip == 0 and loop.btree.n_eq == idx.n_key_col) {
        for (loop.a_lterm[0..loop.btree.n_eq]) |lt| {
            if (lt.?.e_operator & (WO.IS | WO.ISNULL) != 0) return false;
        }
        return true;
    }
    return false;
}

/// Port of whereExprIsReady(): false if `e` must wait for outer join
/// processing instead of being coded in the loop of `tab_item`: WHERE
/// terms with any RIGHT or LEFT join, and ON clauses that are not of an
/// outer join or not yet ripe (tag-20220513a).
fn whereExprIsReady(w: *WhereInfo, level: *const WhereLevel, tab_item: *const SrcItem, e: *const Expr) bool {
    const jtype = tab_item.fg.jointype;
    if (jtype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true })) {
        if (!e.flags.intersects(.{ .OuterON = true, .InnerON = true })) {
            return false;
        } else if (jtype.LEFT and !e.flags.OuterON) {
            return false;
        } else {
            const m = wi.getMask(&w.s_mask_set, e.w.join);
            if (m & level.not_ready != 0) return false;
        }
    }
    return true;
}

// ================================================================ loops

/// Null for the two combinations that cannot happen (0 in C).
const a_start_op = [8]?OP{
    null,
    null,
    OP.Rewind, // 2: (!start_constraints && startEq &&  !bRev)
    OP.Last, // 3: (!start_constraints && startEq &&   bRev)
    OP.SeekGT, // 4: (start_constraints  && !startEq && !bRev)
    OP.SeekLT, // 5: (start_constraints  && !startEq &&  bRev)
    OP.SeekGE, // 6: (start_constraints  &&  startEq && !bRev)
    OP.SeekLE, // 7: (start_constraints  &&  startEq &&  bRev)
};

const a_end_op = [4]OP{
    OP.IdxGE, // 0: (end_constraints && !bRev && !endEq)
    OP.IdxGT, // 1: (end_constraints && !bRev &&  endEq)
    OP.IdxLE, // 2: (end_constraints &&  bRev && !endEq)
    OP.IdxLT, // 3: (end_constraints &&  bRev &&  endEq)
};

/// Port of sqlite3WhereCodeOneLoopStart(): code the start of loop
/// `i_level` (`level` is &w.a[i_level]); returns the tables not yet
/// available after it.
pub fn codeOneLoopStart(p: *Parse, v: *Vdbe, w: *WhereInfo, i_level: usize, level: *WhereLevel, not_ready: Bitmask) Oom!Bitmask {
    const wc = &w.s_wc;
    const loop = level.w_loop.?;
    const tab_item = w.tab_list.at(level.i_from);
    const i_cur = tab_item.i_cursor;
    const cur: Cursor = .from(i_cur);
    level.not_ready = not_ready & ~wi.getMask(&w.s_mask_set, i_cur);
    const b_rev_bit: u1 = @intCast((w.rev_mask >> @intCast(i_level)) & 1);
    const b_rev = b_rev_bit != 0;
    var idx: ?*Index = null;

    // Labels for "break" and "continue". addr_nxt continues with the next
    // IN combination; without IN operators it is addr_brk.
    const addr_brk = level.addr_brk;
    level.addr_nxt = level.addr_brk;
    const addr_cont = aux.newLabel(p);
    level.addr_cont = addr_cont;

    // The match flag of the right table of a LEFT JOIN.
    std.debug.assert(w.wctrl_flags.intersects(.{ .OR_SUBCLAUSE = true, .RIGHT_JOIN = true }) or
        level.i_from > 0 or !tab_item.fg.jointype.LEFT);
    if (level.i_from > 0 and tab_item.fg.jointype.LEFT) {
        level.i_left_join = p.newReg();
        _ = aux.emit(v, .Integer, .{ 0, level.i_left_join });
        if (tab_item.fg.via_coroutine) _ = aux.emit(v, .NullRow, .{ cur, 1 });
    }

    if (tab_item.fg.via_coroutine) {
        // A FROM-clause subquery implemented as a co-routine.
        std.debug.assert(tab_item.fg.is_subquery);
        const subq = tab_item.u4.subq.?;
        const reg_yield = subq.reg_return;
        _ = aux.emit(v, .InitCoroutine, .{ reg_yield, 0, subq.addr_fill_sub.? });
        level.end = .{ .goto = aux.emit(v, .Yield, .{ reg_yield, addr_brk }) };
    } else if (loop.ws_flags.VIRTUALTABLE) {
        // Case 1: a virtual table, read with OP_VFilter and OP_VNext.
        try codeVirtualLoop(p, v, w, level, cur, b_rev);
    } else if (loop.ws_flags.IPK and loop.ws_flags.intersects(.{ .COLUMN_IN = true, .COLUMN_EQ = true })) {
        // Case 2: one row by rowid equality, or several by "rowid IN (...)".
        std.debug.assert(loop.btree.n_eq == 1);
        const term = loop.a_lterm[0].?;
        const release_reg = p.newReg();
        const rowid_reg = try codeEqualityTerm(p, term, level, 0, b_rev, release_reg);
        if (rowid_reg != release_reg) expr_mod.releaseTempReg(p, release_reg);
        const addr_nxt = level.addr_nxt;
        if (!level.reg_filter.isNone()) {
            _ = aux.emit(v, .MustBeInt, .{ rowid_reg, addr_nxt });
            _ = aux.emitInt(v, .Filter, .{ level.reg_filter, addr_nxt, rowid_reg }, 1);
            try filterPullDown(p, w, i_level, addr_nxt, not_ready);
        }
        _ = aux.emit(v, .SeekRowid, .{ cur, addr_nxt, rowid_reg });
        level.end = .none;
    } else if (loop.ws_flags.IPK and loop.ws_flags.COLUMN_RANGE) {
        // Case 3: an inequality on the rowid.
        var test_op: OP = OP.Noop;
        var mem_end_value: Reg = .none;
        var j: usize = 0;
        var start: ?*WhereTerm = null;
        var end: ?*WhereTerm = null;
        if (loop.ws_flags.BTM_LIMIT) {
            start = loop.a_lterm[j];
            j += 1;
        }
        if (loop.ws_flags.TOP_LIMIT) {
            end = loop.a_lterm[j];
            j += 1;
        }
        std.debug.assert(start != null or end != null);
        if (b_rev) std.mem.swap(?*WhereTerm, &start, &end);
        if (start) |s| {
            // Maps TK_GT, TK_LE, TK_LT, TK_GE to seek opcodes.
            const a_move_op = [4]OP{ OP.SeekGT, OP.SeekLE, OP.SeekLT, OP.SeekGE };
            std.debug.assert(TK.LE == TK.GT + 1 and TK.LT == TK.GT + 2 and TK.GE == TK.GT + 3);
            std.debug.assert(!s.wt_flags.VNULL);
            const x = s.expr;
            var r1: Reg = undefined;
            var r_temp: Reg = .none;
            var op: OP = undefined;
            if (expr_mod.isVector(x.right.?)) {
                r_temp = expr_mod.getTempReg(p);
                r1 = r_temp;
                codeExprOrVector(p, x.right, r1, 1);
                const k: usize = @intCast(((@as(i32, x.op) - TK.GT - 1) & 0x3) | 0x1);
                op = a_move_op[k];
            } else {
                r1 = ec.codeTemp(p, x.right, &r_temp);
                disableTerm(level, s);
                op = a_move_op[x.op - TK.GT];
            }
            _ = aux.emitAny(v, op, .{ .cursor, .jump, .reg }, .{ cur, addr_brk, r1 });
            expr_mod.releaseTempReg(p, r_temp);
        } else {
            _ = aux.emitAny(v, if (b_rev) OP.Last else OP.Rewind, .{ .cursor, .jump, .int }, .{ cur, level.addr_halt });
        }
        if (end) |e| {
            const x = e.expr;
            std.debug.assert(!e.wt_flags.VNULL);
            mem_end_value = p.newReg();
            codeExprOrVector(p, x.right, mem_end_value, 1);
            const is_vec = expr_mod.isVector(x.right.?);
            if (!is_vec and (x.op == TK.LT or x.op == TK.GT)) {
                test_op = if (b_rev) OP.Le else OP.Ge;
            } else {
                test_op = if (b_rev) OP.Lt else OP.Gt;
            }
            if (!is_vec) disableTerm(level, e);
        }
        level.end = .{ .step = .{ .op = if (b_rev) OP.Prev else OP.Next, .cur = cur, .top = aux.here(v) } };
        if (test_op != OP.Noop) {
            const rowid_reg = p.newReg();
            _ = aux.emit(v, .Rowid, .{ cur, rowid_reg });
            _ = aux.emitAny(v, test_op, .{ .reg, .jump, .reg }, .{ mem_end_value, addr_brk, rowid_reg });
            aux.changeP5(v, vi.CmpP5.init(Aff.numeric, .{ .jump_if_null = true }));
        }
    } else if (loop.ws_flags.INDEXED) {
        idx = try codeIndexLoop(p, v, w, i_level, level, not_ready, b_rev_bit);
    } else if (loop.ws_flags.MULTI_OR) {
        try codeMultiOrLoop(p, v, w, i_level, level);
    } else {
        // Case 6: no usable index; scan the whole table.
        const a_step = [2]OP{ OP.Next, OP.Prev };
        const a_start = [2]OP{ OP.Rewind, OP.Last };
        if (tab_item.fg.is_recursive) {
            // A recursive table has one row in a pseudo-cursor: no Rewind
            // or Next.
            level.end = .none;
        } else {
            const start = aux.emitAny(v, a_start[b_rev_bit], .{ .cursor, .jump, .int }, .{ cur, level.addr_halt });
            level.end = .{ .step = .{ .op = a_step[b_rev_bit], .cur = cur, .top = start.plus(1), .p5 = .fullscan_step } };
        }
    }

    level.addr_visit = aux.here(v);

    // Code every term that can be computed from the tables available now:
    // pass 1 only terms covered by the index, pass 2 the rest without
    // correlated subqueries, pass 3 everything else ("MySQL push-down").
    var i_loop: i32 = if (idx != null) 1 else 2;
    while (true) {
        var i_next: i32 = 0;
        for (wc.terms()) |*term| {
            var skip_like: ?Addr = null;
            if (term.wt_flags.intersects(.{ .VIRTUAL = true, .CODED = true })) continue;
            if (term.prereq_all & level.not_ready != 0) {
                w.untested_terms = true;
                continue;
            }
            const e = term.expr;
            if (!whereExprIsReady(w, level, tab_item, e)) continue;
            if (i_loop == 1 and !expr_mod.coveredByIndex(e, level.i_tab_cur.int(), idx.?)) {
                i_next = 2;
                continue;
            }
            if (i_loop < 3 and term.wt_flags.VARSELECT) {
                if (i_next == 0) i_next = 3;
                continue;
            }
            if (term.wt_flags.LIKECOND) {
                // The range scan proves the LIKE true for strings, so skip
                // the like() call except on the pass that compares BLOBs.
                const x = level.i_like_rep_cntr;
                if (x > 0) {
                    skip_like = aux.emitAny(v, if (x & 1 != 0) OP.IfNot else OP.If, .{ .reg, .jump, .int }, .{Reg.from(@intCast(x >> 1))});
                }
            }
            ec.exprIfFalse(p, e, addr_cont, true);
            if (skip_like) |a| aux.landHere(v, a);
            term.wt_flags.CODED = true;
        }
        i_loop = i_next;
        if (i_loop <= 0) break;
    }

    // Implied constraints by transitivity of "==": with "t1.a=t2.b" and
    // "t2.b=123", the t1 loop can test "t1.a=123".
    for (wc.a[0..@intCast(wc.n_base)]) |*term| {
        if (term.wt_flags.intersects(.{ .VIRTUAL = true, .CODED = true })) continue;
        if (term.e_operator & (WO.EQ | WO.IS) == 0) continue;
        if (term.e_operator & WO.EQUIV == 0) continue;
        if (term.left_cursor != i_cur) continue;
        if (tab_item.fg.jointype.intersects(.{ .LEFT = true, .LTORJ = true, .RIGHT = true })) continue;
        const e = term.expr;
        std.debug.assert(!e.flags.OuterON);
        std.debug.assert(term.prereq_right & level.not_ready != 0);
        std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
        const alt = wl.findTerm(wc, i_cur, term.left_column, not_ready, WO.EQ | WO.IN | WO.IS, null) orelse continue;
        if (alt.wt_flags.CODED) continue;
        if (alt.expr.flags.Collate) continue;
        if (alt.e_operator & WO.IN != 0 and alt.expr.useXSelect() and alt.expr.x.select.?.e_list.?.len() > 1) {
            continue;
        }
        var e_alt = alt.expr.*;
        e_alt.left = e.left;
        ec.exprIfFalse(p, &e_alt, addr_cont, true);
        alt.wt_flags.CODED = true;
    }

    // RIGHT OUTER JOIN: record that the current row of the right table
    // matched, by storing its PK in the iMatch index and the Bloom filter.
    if (level.rj) |rj| {
        const tab = w.tab_list.at(level.i_from).s_tab.?;
        var r: Reg = undefined;
        var n_pk: i32 = undefined;
        if (tab.hasRowid()) {
            r = expr_mod.getTempRange(p, 2);
            ec.codeGetColumnOfTable(v, tab, level.i_tab_cur, -1, r.at(1));
            n_pk = 1;
        } else {
            const pk = build.primaryKeyIndex(tab).?;
            n_pk = pk.n_key_col;
            r = expr_mod.getTempRange(p, n_pk + 1);
            for (0..pk.n_key_col) |i_pk| {
                const i_col = pk.ai_column[i_pk];
                ec.codeGetColumnOfTable(v, tab, cur, i_col, r.at(1 + i_pk));
            }
        }
        const jmp1 = aux.emitInt(v, .Found, .{ rj.i_match, 0, r.at(1) }, n_pk);
        _ = aux.emit(v, .MakeRecord, .{ r.at(1), n_pk, r });
        _ = aux.emitInt(v, .IdxInsert, .{ rj.i_match, r, r.at(1) }, n_pk);
        if (!rj.reg_bloom.isNone()) {
            _ = aux.emitInt(v, .FilterAdd, .{ rj.reg_bloom, 0, r.at(1) }, n_pk);
            // As in C, the OP_IdxInsert's flag lands on OP_FilterAdd,
            // which does not read P5.
            aux.changeP5(v, vi.p5.int(vi.InsertP5{ .use_seek_result = true }));
        }
        aux.landHere(v, jmp1);
        expr_mod.releaseTempRange(p, r, n_pk + 1);
    }

    // LEFT OUTER JOIN: record that a row of the right table matched.
    if (!level.i_left_join.isNone()) {
        level.addr_first = aux.here(v);
        _ = aux.emit(v, .Integer, .{ 1, level.i_left_join });
    }

    if (level.rj) |rj| {
        // The subroutine for the interior loops of the RIGHT JOIN: inline
        // normally, and run at the end for unmatched rows of the table
        // with all tables to the left set to NULL.
        _ = aux.emit(v, .BeginSubrtn, .{ 0, rj.reg_return });
        rj.addr_subrtn = aux.here(v);
        std.debug.assert(p.within_rj_subrtn < 255);
        p.within_rj_subrtn += 1;
    }

    if (!level.i_left_join.isNone() or level.rj != null) {
        // WHERE clause constraints apply to the result of the OUTER JOIN,
        // so code them after its row elimination (tag-20220513a).
        for (wc.a[0..@intCast(wc.n_base)]) |*term| {
            if (term.wt_flags.intersects(.{ .VIRTUAL = true, .CODED = true })) continue;
            if (term.prereq_all & level.not_ready != 0) {
                std.debug.assert(w.untested_terms);
                continue;
            }
            if (tab_item.fg.jointype.LTORJ) continue;
            ec.exprIfFalse(p, term.expr, addr_cont, true);
            term.wt_flags.CODED = true;
        }
    }
    return level.not_ready;
}

/// The instruction that starts an index range scan: a seek, whose P3 is
/// the register of the key, or OP_Rewind or OP_Last, which take no key
/// but get the register in P3 all the same.
fn emitRangeStart(v: *Vdbe, op: OP, cur: Cursor, dest: Label, key: Reg, n_key: i32) void {
    switch (op) {
        OP.Rewind, OP.Last => _ = aux.emitAnyInt(v, op, .{ .cursor, .jump, .int }, .{ cur, dest, key.int() }, n_key),
        else => _ = aux.emitAnyInt(v, op, .{ .cursor, .jump, .reg }, .{ cur, dest, key }, n_key),
    }
}

/// Case 4 of sqlite3WhereCodeOneLoopStart(): a search using an index,
/// with zero or more ==/IN/IS terms on its left-most columns and maybe
/// an inequality on the next one. Returns pIdx, or null if the loop uses
/// the index only.
fn codeIndexLoop(p: *Parse, v: *Vdbe, w: *WhereInfo, i_level: usize, level: *WhereLevel, not_ready: Bitmask, b_rev_bit: u1) Oom!?*Index {
    const loop = level.w_loop.?;
    const wc = &w.s_wc;
    const tab_item = w.tab_list.at(level.i_from);
    const i_cur = tab_item.i_cursor;
    const cur: Cursor = .from(i_cur);
    const addr_cont = level.addr_cont;
    const b_rev = b_rev_bit != 0;
    const b_rev_i: i32 = b_rev_bit;

    const n_eq: u16 = loop.btree.n_eq;
    var n_btm: u16 = loop.btree.n_btm;
    var n_top: u16 = loop.btree.n_top;
    var range_start: ?*WhereTerm = null;
    var range_end: ?*WhereTerm = null;
    var n_extra_reg: i32 = 0;
    var z_start_aff: ?[:0]u8 = null;
    var z_end_aff: ?[:0]u8 = null;
    var b_seek_past_null: i32 = 0;
    var b_stop_at_null: i32 = 0;
    var reg_bignull: Reg = .none;
    var addr_seek_scan: ?Addr = null;

    var idx: ?*Index = loop.btree.index.?;
    const ix = idx.?;
    const idx_cur = level.i_idx_cur;
    std.debug.assert(n_eq >= loop.n_skip);

    // The inequality terms at the start and end of the range.
    var j: usize = n_eq;
    if (loop.ws_flags.BTM_LIMIT) {
        range_start = loop.a_lterm[j];
        j += 1;
        n_extra_reg = @max(n_extra_reg, @as(i32, loop.btree.n_btm));
        // LIKE optimization range constraints always come in pairs.
        std.debug.assert(!range_start.?.wt_flags.LIKEOPT or loop.ws_flags.TOP_LIMIT);
    }
    if (loop.ws_flags.TOP_LIMIT) {
        range_end = loop.a_lterm[j];
        j += 1;
        n_extra_reg = @max(n_extra_reg, @as(i32, loop.btree.n_top));
        if (range_end.?.wt_flags.LIKEOPT) {
            std.debug.assert(range_start != null and range_start.?.wt_flags.LIKEOPT);
            const reg_like = p.newReg();
            level.i_like_rep_cntr = @intCast(reg_like.int());
            _ = aux.emit(v, .Integer, .{ 1, reg_like });
            level.addr_like_rep = aux.here(v);
            // iLikeRepCntr holds 2x the counter register; the low bit is
            // whether the scan is DESC.
            level.i_like_rep_cntr <<= 1;
            const desc: u32 = @intFromBool(ix.sort_order[n_eq] == int.SortOrder.desc);
            level.i_like_rep_cntr |= @as(u32, b_rev_bit) ^ desc;
        }
        if (range_start == null) {
            const c = ix.ai_column[n_eq];
            if ((c >= 0 and ix.table.cols[@intCast(c)].not_null == .None) or c == int.XN_EXPR) {
                b_seek_past_null = 1;
            }
        }
    }
    std.debug.assert(range_end == null or !range_end.?.wt_flags.VNULL);

    // A "big-null" sort on column nEq (ASC NULLS LAST or DESC NULLS
    // FIRST) scans the NULL and non-NULL entries separately.
    if (!loop.ws_flags.intersects(.{ .TOP_LIMIT = true, .BTM_LIMIT = true }) and loop.ws_flags.BIGNULL_SORT) {
        std.debug.assert(b_seek_past_null == 0 and n_extra_reg == 0 and n_btm == 0 and n_top == 0);
        n_extra_reg = 1;
        b_seek_past_null = 1;
        reg_bignull = p.newReg();
        level.reg_bignull = reg_bignull;
        if (!level.i_left_join.isNone()) _ = aux.emit(v, .Integer, .{ 0, reg_bignull });
        level.addr_bignull = aux.newLabel(p);
    }

    // A reverse scan of an ascending index, or a forward scan of a
    // descending one, swaps the start and end terms.
    if (n_eq < ix.n_column and b_rev == (ix.sort_order[n_eq] == int.SortOrder.asc)) {
        std.mem.swap(?*WhereTerm, &range_end, &range_start);
        std.mem.swap(i32, &b_seek_past_null, &b_stop_at_null);
        std.mem.swap(u16, &n_btm, &n_top);
    }

    if (i_level > 0 and loop.ws_flags.IN_SEEKSCAN) {
        // Make sure the index cursor is not on a valid row for the first
        // iteration, in case OP_SeekScan is used.
        _ = aux.emit(v, .NullRow, .{idx_cur});
    }

    // The ==/IN terms go to registers reg_base...
    const reg_base = try codeAllEqualityTerms(p, level, b_rev, n_extra_reg, &z_start_aff);
    std.debug.assert(z_start_aff == null or z_start_aff.?.len >= n_eq);
    if (z_start_aff) |z| if (n_top != 0) {
        z_end_aff = try p.arena.dupeSentinel(u8, std.mem.sliceTo(z[n_eq..], 0), 0);
    };
    // addr_bignull is set exactly when reg_bignull is, above.
    const addr_nxt = level.addr_bignull orelse level.addr_nxt;

    var start_eq: i32 = @intFromBool(range_start == null or range_start.?.e_operator & (WO.LE | WO.GE) != 0);
    var end_eq: i32 = @intFromBool(range_end == null or range_end.?.e_operator & (WO.LE | WO.GE) != 0);
    var start_constraints: i32 = @intFromBool(range_start != null or n_eq > 0);

    // Seek the index cursor to the start of the range.
    var n_constraint: i32 = n_eq;
    if (range_start) |rs| {
        const right = rs.expr.right.?;
        codeExprOrVector(p, right, reg_base.at(n_eq), n_btm);
        whereLikeOptimizationStringFixup(v, level, rs);
        if (!rs.wt_flags.VNULL and expr_mod.canBeNull(right)) {
            _ = aux.emit(v, .IsNull, .{ reg_base.at(n_eq), addr_nxt });
        }
        if (z_start_aff) |z| updateRangeAffinityStr(right, n_btm, z[n_eq..]);
        n_constraint += n_btm;
        if (!expr_mod.isVector(right)) {
            disableTerm(level, rs);
        } else {
            start_eq = 1;
        }
        b_seek_past_null = 0;
    } else if (b_seek_past_null != 0) {
        start_eq = 0;
        _ = aux.emit(v, .Null, .{ 0, reg_base.at(n_eq) });
        start_constraints = 1;
        n_constraint += 1;
    } else if (!reg_bignull.isNone()) {
        _ = aux.emit(v, .Null, .{ 0, reg_base.at(n_eq) });
        start_constraints = 1;
        n_constraint += 1;
    }
    codeApplyAffinity(p, reg_base, n_constraint - b_seek_past_null, z_start_aff);
    if (loop.n_skip > 0 and n_constraint == loop.n_skip) {
        // The skip-scan code in codeAllEqualityTerms() already left the
        // cursor on the right row.
    } else {
        if (!reg_bignull.isNone()) _ = aux.emit(v, .Integer, .{ 1, reg_bignull });
        if (!level.reg_filter.isNone()) {
            _ = aux.emitInt(v, .Filter, .{ level.reg_filter, addr_nxt, reg_base }, n_eq);
            try filterPullDown(p, w, i_level, addr_nxt, not_ready);
        }

        var op = a_start_op[@intCast((start_constraints << 2) + (start_eq << 1) + b_rev_i)].?;
        if (loop.ws_flags.IN_SEEKSCAN and op == OP.SeekGE) {
            std.debug.assert(reg_bignull.isNone());
            // TUNING: try about log(N) steps before giving up and seeking.
            const scan = aux.emit(v, .SeekScan, .{@divTrunc(@as(i32, ix.ai_row_log_est[0]) + 9, 10)});
            addr_seek_scan = scan;
            if (range_start != null or range_end != null) {
                aux.changeP5(v, 1);
                aux.setJump(v, scan, aux.here(v).plus(1));
                addr_seek_scan = null;
            }
        }
        emitRangeStart(v, op, idx_cur, addr_nxt, reg_base, n_constraint);

        std.debug.assert(b_seek_past_null == 0 or b_stop_at_null == 0);
        if (!reg_bignull.isNone()) {
            std.debug.assert(b_seek_past_null == 1 or b_stop_at_null == 1);
            std.debug.assert(b_stop_at_null == start_eq);
            _ = aux.emit(v, .Goto, .{ 0, aux.here(v).plus(2) });
            op = a_start_op[@intCast(@as(i32, @intFromBool(n_constraint > 1)) * 4 + 2 + b_rev_i)].?;
            emitRangeStart(v, op, idx_cur, addr_nxt, reg_base, n_constraint - start_eq);
        }
    }

    // Load the value of the inequality at the end of the range.
    n_constraint = n_eq;
    std.debug.assert(level.end == .none);
    if (range_end) |re| {
        const right = re.expr.right.?;
        std.debug.assert(addr_seek_scan == null);
        codeExprOrVector(p, right, reg_base.at(n_eq), n_top);
        whereLikeOptimizationStringFixup(v, level, re);
        if (!re.wt_flags.VNULL and expr_mod.canBeNull(right)) {
            _ = aux.emit(v, .IsNull, .{ reg_base.at(n_eq), addr_nxt });
        }
        if (z_end_aff) |z| {
            updateRangeAffinityStr(right, n_top, z);
            codeApplyAffinity(p, reg_base.at(n_eq), n_top, z);
        } else {
            std.debug.assert(p.db.malloc_failed);
        }
        n_constraint += n_top;
        if (!expr_mod.isVector(right)) {
            disableTerm(level, re);
        } else {
            end_eq = 1;
        }
    } else if (b_stop_at_null != 0) {
        if (reg_bignull.isNone()) {
            _ = aux.emit(v, .Null, .{ 0, reg_base.at(n_eq) });
            end_eq = 0;
        }
        n_constraint += 1;
    }

    // Top of the loop body.
    const top = aux.here(v);

    // Check whether the index cursor is past the end of the range.
    if (n_constraint != 0) {
        if (!reg_bignull.isNone()) {
            // Skip the end-of-range check during the NULL-scan.
            _ = aux.emit(v, .IfNot, .{ reg_bignull, aux.here(v).plus(3) });
        }
        const op = a_end_op[@intCast(b_rev_i * 2 + end_eq)];
        _ = aux.emitAnyInt(v, op, .{ .cursor, .jump, .reg }, .{ idx_cur, addr_nxt, reg_base }, n_constraint);
        if (addr_seek_scan) |a| aux.landHere(v, a);
    }
    if (!reg_bignull.isNone()) {
        // During the NULL-scan, stop at the end of the NULLs.
        std.debug.assert(b_seek_past_null + b_stop_at_null == 1);
        _ = aux.emit(v, .If, .{ reg_bignull, aux.here(v).plus(2) });
        const op = a_end_op[@intCast(b_rev_i * 2 + b_seek_past_null)];
        _ = aux.emitAnyInt(v, op, .{ .cursor, .jump, .reg }, .{ idx_cur, addr_nxt, reg_base }, n_constraint + b_seek_past_null);
    }

    if (loop.ws_flags.IN_EARLYOUT) {
        _ = aux.emit(v, .SeekHit, .{ idx_cur, n_eq, n_eq });
    }

    // Seek the table cursor, if needed.
    const omit_table = loop.ws_flags.IDX_ONLY and
        !w.wctrl_flags.intersects(.{ .OR_SUBCLAUSE = true, .RIGHT_JOIN = true });
    if (omit_table) {
        // A covering index: the table is not needed.
    } else if (ix.table.hasRowid()) {
        try codeDeferredSeek(w, ix, cur, idx_cur);
    } else if (cur != idx_cur) {
        const pk = build.primaryKeyIndex(ix.table).?;
        const n_pk: i32 = pk.n_key_col;
        const rowid_reg = expr_mod.getTempRange(p, n_pk);
        for (0..pk.n_key_col) |jj| {
            const k = build.tableColumnToIndex(ix, pk.ai_column[jj]);
            _ = aux.emit(v, .Column, .{ idx_cur, k, rowid_reg.at(jj) });
        }
        _ = aux.emitInt(v, .NotFound, .{ cur, addr_cont, rowid_reg }, n_pk);
    }

    if (level.i_left_join.isNone()) {
        // A partial index driving the loop implies some WHERE terms; not
        // on an outer join (tickets 623eff57e76d45f6, 7dee41d32506c4ae).
        if (ix.part_idx_where) |pw| {
            if (level.rj == null) whereApplyPartialIndexConstraints(pw, i_cur, wc);
        }
    } else {
        // The OR optimization does not apply to the right table of a LEFT
        // JOIN.
        std.debug.assert(!w.wctrl_flags.intersects(.{ .OR_SUBCLAUSE = true, .RIGHT_JOIN = true }));
    }

    // The instruction that ends the loop.
    if (loop.ws_flags.ONEROW or
        (level.in_loops.len != 0 and reg_bignull.isNone() and whereLoopIsOneRow(loop)))
    {
        level.end = .none;
    } else {
        level.end = .{ .step = .{
            .op = if (b_rev) OP.Prev else OP.Next,
            .cur = idx_cur,
            .top = top,
            .p3 = if (loop.ws_flags.UNQ_WANTED) 1 else 0,
            .p5 = if (!loop.ws_flags.intersects(wi.WS.CONSTRAINT)) .fullscan_step else .none,
        } };
    }
    if (omit_table) idx = null;
    return idx;
}

/// Case 5 of sqlite3WhereCodeOneLoopStart(): two or more separately
/// indexed terms connected by OR. Each term gets its own sub-WHERE loop
/// (sqlite3WhereBegin() with WHERE_OR_SUBCLAUSE) that skips rows already
/// seen (a RowSet, or an ephemeral index of PKs for WITHOUT ROWID) and
/// calls the loop body as a subroutine:
///
///          Null       1                # Zero the rowset in reg 1
///        sqlite3WhereBegin(<term>)     # once per OR term
///          RowSetTest                  # Insert rowid into rowset
///          Gosub      2 A
///        sqlite3WhereEnd()
///          Goto       B                # The loop is finished.
///       A: <loop body>
///          Return     2                # Jump back to the Gosub
///       B: <after the loop>
fn codeMultiOrLoop(p: *Parse, v: *Vdbe, w: *WhereInfo, i_level: usize, level: *WhereLevel) Oom!void {
    const loop = level.w_loop.?;
    const wc = &w.s_wc;
    const tab_item = w.tab_list.at(level.i_from);
    const i_cur = tab_item.i_cursor;
    const cur: Cursor = .from(i_cur);

    var cov: ?*Index = null;
    const i_cov_cur = p.newCursor();
    const reg_return = p.newReg();
    // The rows seen so far: a RowSet in a register, or the cursor of an
    // ephemeral index of the PKs of a WITHOUT ROWID table.
    var reg_rowset: Reg = .none;
    var seen_cur: Cursor = undefined;
    var reg_rowid: Reg = .none;
    const loop_body = aux.newLabel(p);
    var untested_terms = false;
    var and_expr: ?*Expr = null;
    const tab = tab_item.s_tab.?;

    const term = loop.a_lterm[0].?;
    std.debug.assert(term.e_operator & WO.OR != 0);
    std.debug.assert(term.wt_flags.ORINFO);
    const or_wc = &term.or_info.?.wc;

    // The SrcList of the sub-WHERE loops: this table in a[0], then the
    // notReady tables.
    var or_tab: *SrcList = undefined;
    if (w.n_level > 1 or tab_item.fg.from_exists) {
        const n_not_ready = w.n_level - i_level - 1;
        const ot = try p.arena.create(SrcList);
        ot.* = .{};
        try ot.items.ensureTotalCapacityPrecise(p.arena, n_not_ready + 1);
        ot.items.appendAssumeCapacity(tab_item.*);
        for (1..n_not_ready + 1) |k| {
            ot.items.appendAssumeCapacity(w.tab_list.at(w.a[i_level + k].i_from).*);
        }
        // The EXISTS early exit applies to this table's whole loop, not
        // to the sub-loops.
        ot.at(0).fg.from_exists = false;
        or_tab = ot;
    } else {
        or_tab = w.tab_list;
    }

    // The rowset starts empty (NULL), or an ephemeral index for the PKs of
    // a WITHOUT ROWID table. regReturn starts as the address after the
    // final OP_Return, for LEFT JOIN cases that jump into the body.
    if (!w.wctrl_flags.DUPLICATES_OK) {
        if (tab.hasRowid()) {
            reg_rowset = p.newReg();
            _ = aux.emit(v, .Null, .{ 0, reg_rowset });
        } else {
            const pk = build.primaryKeyIndex(tab).?;
            seen_cur = p.newCursor();
            _ = aux.emit(v, .OpenEphemeral, .{ seen_cur, pk.n_key_col });
            aux.setP4KeyInfo(p, pk);
        }
        reg_rowid = p.newReg();
    }
    const ret_init = aux.emit(v, .Integer, .{ 0, reg_return });

    // For a WHERE clause "(x1 OR x2 OR ...) AND y", code each xN as
    // "xN AND w", where w is the usable terms of y: no ON clause terms
    // of a LEFT JOIN, no vector slices (dbsqlfuzz 80a9fade844b4fb4), no
    // subqueries (tag-20220303a).
    if (wc.n_term > 1) {
        for (wc.terms()) |*t| {
            if (t == term) continue;
            if (t.wt_flags.intersects(.{ .VIRTUAL = true, .CODED = true, .SLICE = true })) continue;
            if (t.e_operator & WO.ALL == 0) continue;
            const e = t.expr;
            if (e.flags.Subquery) continue;
            if (!whereExprIsReady(w, level, tab_item, e)) continue;
            const dup = try expr_mod.exprDup(p.arena, e);
            and_expr = try expr_mod.exprAnd(p, and_expr, dup);
        }
        if (and_expr != null) {
            // C uses TK_AND|0x10000 to avoid the AND short-circuit of
            // sqlite3PExpr(); pExpr() has none.
            and_expr = try expr_mod.pExpr(p, TK.AND, null, and_expr);
        }
    }

    // A separate WHERE loop for each OR term, calling the loop body as a
    // subroutine for rows not seen before.
    _ = aux.explain(p, true, "MULTI-INDEX OR", .{});
    const n_or_term: usize = @intCast(or_wc.n_term);
    for (0..n_or_term) |ii| {
        const or_term = &or_wc.a[ii];
        if (or_term.left_cursor != i_cur and or_term.e_operator & WO.AND == 0) continue;
        var or_expr = (try expr_mod.exprDup(p.arena, or_term.expr)).?;
        var jmp1: ?Addr = null;
        if (and_expr) |ae| {
            ae.left = or_expr;
            or_expr = ae;
        }
        _ = aux.explain(p, true, "INDEX {d}", .{ii + 1});
        const sub = where_mod.whereBegin(p, or_tab, or_expr, null, null, null, .{ .OR_SUBCLAUSE = true }, .{ .cursor = i_cov_cur }) orelse continue;
        const addr_explain = try explainOneScan(p, or_tab, &sub.a[0], .{});
        addScanStatus(v, or_tab, &sub.a[0], addr_explain);

        // Skip rows seen by prior sub-WHERE loops, and record this one.
        if (!w.wctrl_flags.DUPLICATES_OK) {
            const i_set: i32 = if (ii == n_or_term - 1) -1 else @intCast(ii);
            if (tab.hasRowid()) {
                ec.codeGetColumnOfTable(v, tab, cur, -1, reg_rowid);
                jmp1 = aux.emitInt(v, .RowSetTest, .{ reg_rowset, 0, reg_rowid }, i_set);
            } else {
                const pk = build.primaryKeyIndex(tab).?;
                const n_pk: i32 = pk.n_key_col;
                const r = expr_mod.getTempRange(p, n_pk);
                for (0..pk.n_key_col) |i_pk| {
                    const i_col = pk.ai_column[i_pk];
                    ec.codeGetColumnOfTable(v, tab, cur, i_col, r.at(i_pk));
                }
                // As with OP_RowSetTest: iSet 0 means the key cannot be
                // present yet, -1 that it need not be inserted.
                if (i_set != 0) {
                    jmp1 = aux.emitInt(v, .Found, .{ seen_cur, 0, r }, n_pk);
                }
                if (i_set >= 0) {
                    _ = aux.emit(v, .MakeRecord, .{ r, n_pk, reg_rowid });
                    _ = aux.emitInt(v, .IdxInsert, .{ seen_cur, reg_rowid, r }, n_pk);
                    if (i_set != 0) aux.changeP5(v, vi.InsertP5{ .use_seek_result = true });
                }
                expr_mod.releaseTempRange(p, r, n_pk);
            }
        }

        // Invoke the main loop body as a subroutine.
        _ = aux.emit(v, .Gosub, .{ reg_return, loop_body });
        if (jmp1) |a| aux.landHere(v, a);

        // Terms of notReady tables in this OR term are tested later.
        if (sub.untested_terms) untested_terms = true;

        // If every OR term uses the same index (on the same cursor), it
        // may serve as a covering index.
        const sub_loop = sub.a[0].w_loop.?;
        std.debug.assert(!sub_loop.ws_flags.AUTO_INDEX);
        if (sub_loop.ws_flags.INDEXED and
            (ii == 0 or sub_loop.btree.index == cov) and
            (tab.hasRowid() or !sub_loop.btree.index.?.isPrimaryKey()))
        {
            std.debug.assert(sub.a[0].i_idx_cur == i_cov_cur);
            cov = sub_loop.btree.index;
        } else {
            cov = null;
        }
        if (where_mod.usesDeferredSeek(sub)) w.b_deferred_seek = true;

        where_mod.whereEnd(sub);
        aux.explainPop(p);
    }
    aux.explainPop(p);
    std.debug.assert(level.w_loop == loop);
    std.debug.assert(loop.ws_flags.MULTI_OR);
    std.debug.assert(!loop.ws_flags.IN_ABLE);
    level.covering_idx = cov;
    if (cov != null) level.i_idx_cur = i_cov_cur;
    if (and_expr) |ae| ae.left = null;
    aux.changeP1(v, ret_init, v.nOp());
    _ = aux.emit(v, .Goto, .{ 0, level.addr_brk });
    aux.place(v, loop_body);

    // The loop ends with OP_Return; its P2 is the top of the containing
    // loop: an indentation hint for the bytecode formatter
    // (tag-20220407a).
    level.end = .{ .ret = .{ .reg = reg_return, .top = aux.here(v) } };

    if (!untested_terms) disableTerm(level, term);
}

/// Port of sqlite3WhereRightJoinLoop(): the loop over the rows of the
/// right table of a RIGHT JOIN that matched no row, running the
/// interior subroutine with the tables to the left set to NULL.
pub fn rightJoinLoop(w: *WhereInfo, i_level: usize, level: *WhereLevel) Oom!void {
    const p = w.parse;
    const v = p.vdbe.?;
    const rj = level.rj.?;
    var sub_where: ?*Expr = null;
    const wc = &w.s_wc;
    const loop = level.w_loop.?;
    const tab_item = w.tab_list.at(level.i_from);
    var m_all: Bitmask = 0;

    _ = aux.explain(p, true, "RIGHT-JOIN {s}", .{tab_item.s_tab.?.name});
    for (w.a[0..i_level]) |*lk| {
        std.debug.assert(lk.w_loop.?.i_tab == lk.i_from);
        const right = w.tab_list.at(lk.i_from);
        m_all |= lk.w_loop.?.mask_self;
        if (right.fg.via_coroutine) {
            std.debug.assert(right.fg.is_subquery);
            const subq = right.u4.subq.?;
            const n: i32 = @intCast(subq.select.e_list.?.len());
            const reg_result = subq.reg_result;
            _ = aux.emit(v, .Null, .{ 0, reg_result, reg_result.at(n - 1) });
        }
        _ = aux.emit(v, .NullRow, .{lk.i_tab_cur});
        if (lk.i_idx_cur.int() != 0) _ = aux.emit(v, .NullRow, .{lk.i_idx_cur});
    }
    if (!tab_item.fg.jointype.LTORJ) {
        m_all |= loop.mask_self;
        for (wc.terms()) |*term| {
            if (term.wt_flags.intersects(.{ .VIRTUAL = true, .SLICE = true }) and term.e_operator != WO.ROWVAL) break;
            if (term.prereq_all & ~m_all != 0) continue;
            if (term.expr.flags.intersects(.{ .OuterON = true, .InnerON = true })) continue;
            sub_where = try expr_mod.exprAnd(p, sub_where, try expr_mod.exprDup(p.arena, term.expr));
        }
    }
    if (level.i_idx_cur.int() != 0) {
        // Expressions of sub_where that read the index of the right table
        // fall back to the table when the index cursor is on a NULL row,
        // so make sure it is.
        _ = aux.emit(v, .NullRow, .{level.i_idx_cur});
    }
    const from = try p.arena.create(SrcList);
    from.* = .{};
    try from.items.append(p.arena, tab_item.*);
    from.at(0).fg.jointype = .{};
    if (p.within_rj_subrtn >= 100) {
        // A historical limit; only an attack would do 100 RIGHT JOINs.
        util.errorMsg(p, "too many RIGHT JOINs", .{});
        return;
    }
    p.within_rj_subrtn += 1;
    if (where_mod.whereBegin(p, from, sub_where, null, null, null, .{ .RIGHT_JOIN = true }, .none)) |sub| {
        const i_cur = level.i_tab_cur;
        const tab = tab_item.s_tab.?;
        const pk: ?*Index = if (tab.hasRowid()) null else build.primaryKeyIndex(tab).?;
        const n_pk: i32 = if (pk) |k| k.n_key_col else 1;
        const r = p.newRegs(n_pk);
        const addr_cont = where_mod.continueLabel(sub);
        if (pk) |k| {
            for (0..k.n_key_col) |i_pk| {
                const i_col = k.ai_column[i_pk];
                ec.codeGetColumnOfTable(v, tab, i_cur, i_col, r.at(i_pk));
            }
        } else {
            ec.codeGetColumnOfTable(v, tab, i_cur, -1, r);
        }

        // Skip rows of the right table that appeared in an output row.
        if (!rj.reg_bloom.isNone()) {
            _ = aux.emitInt(v, .Filter, .{ rj.reg_bloom, aux.here(v).plus(2), r }, n_pk);
        }
        _ = aux.emitInt(v, .Found, .{ rj.i_match, addr_cont, r }, n_pk);
        const r2 = expr_mod.getTempReg(p);

        // Record the row in the iMatch index.
        _ = aux.emit(v, .MakeRecord, .{ r, n_pk, r2 });
        _ = aux.emitInt(v, .IdxInsert, .{ rj.i_match, r2, r }, n_pk);
        expr_mod.releaseTempReg(p, r2);
        if (!rj.reg_bloom.isNone()) {
            _ = aux.emitInt(v, .FilterAdd, .{ rj.reg_bloom, 0, r }, n_pk);
            // As in C, the OP_IdxInsert's flag lands on OP_FilterAdd,
            // which does not read P5.
            aux.changeP5(v, vi.p5.int(vi.InsertP5{ .use_seek_result = true }));
        }

        // Output the row with NULLs for the tables to the left.
        _ = aux.emit(v, .Gosub, .{ rj.reg_return, rj.addr_subrtn });
        where_mod.whereEnd(sub);
    }
    aux.explainPop(p);
    std.debug.assert(p.within_rj_subrtn > 0);
    p.within_rj_subrtn -= 1;
}
