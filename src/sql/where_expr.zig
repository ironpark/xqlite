//! Port of whereexpr.c: splitting and analysis of the WHERE clause.

const std = @import("std");
const int = @import("sqlite_int.zig");
const wi = @import("where_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const func = @import("func.zig");
const numeric = @import("numeric.zig");
const resolve = @import("resolve.zig");
const select_mod = @import("select.zig");
const build = @import("build.zig");
const coll_mod = @import("coll.zig");
const ctype = @import("../util/ctype.zig");
const aux = @import("../vdbe/aux.zig");
const vi = @import("../vdbe/vdbe_int.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const SrcItem = int.SrcItem;
const Select = int.Select;
const Table = int.Table;
const CollSeq = int.CollSeq;
const Bitmask = int.Bitmask;
const Oom = int.Oom;
const TK = int.TK;
const EP = int.EP;
const SF = int.SF;
const JT = int.JT;
const Aff = int.Aff;
const WhereInfo = wi.WhereInfo;
const WhereClause = wi.WhereClause;
const WhereTerm = wi.WhereTerm;
const WhereMaskSet = wi.WhereMaskSet;
const WhereLoop = wi.WhereLoop;
const WhereOrInfo = wi.WhereOrInfo;
const WhereAndInfo = wi.WhereAndInfo;
const TERM = wi.TERM;
const WO = wi.WO;
const getMask = wi.getMask;

const INDEX_CONSTRAINT = @import("vtab.zig").INDEX_CONSTRAINT;

/// ExprIsVtab(): a column of a virtual table.
fn exprIsVtab(e: *const Expr) bool {
    return e.op == TK.COLUMN and e.y.tab.?.isVirtual();
}

/// Port of whereClauseInsert(): append a term for `e` and return its
/// index. May reallocate wc.a, invalidating WhereTerm pointers into it.
/// C starts from 8 inline slots (aStatic) and doubles; the first insert
/// here allocates those 8.
fn whereClauseInsert(wc: *WhereClause, e: *Expr, wt_flags: TERM) Oom!i32 {
    if (wc.n_term >= wc.nSlot()) {
        const old = wc.a;
        const n_slot: usize = if (old.len == 0) 8 else old.len * 2;
        const a = try wi.whereMalloc(wc.w_info, WhereTerm, n_slot);
        @memcpy(a[0..@intCast(wc.n_term)], old[0..@intCast(wc.n_term)]);
        wc.a = a;
    }
    const idx = wc.n_term;
    wc.n_term += 1;
    const term = &wc.a[@intCast(idx)];
    if (!wt_flags.VIRTUAL) wc.n_base = wc.n_term;
    const truth_prob: int.LogEst = if (e.flags.Unlikely)
        util.logEst(@intCast(e.i_table)) - 270
    else
        1;
    // C sets iParent=-1 and then zeroes everything from eOperator on,
    // which includes iParent and leftCursor.
    term.* = .{
        .expr = expr_mod.skipCollateAndLikely(e).?,
        .wc = wc,
        .truth_prob = truth_prob,
        .wt_flags = wt_flags,
        .i_parent = 0,
        .left_cursor = 0,
    };
    return idx;
}

/// Port of allowedOp(): one of "=", "<", ">", "<=", ">=", "IN", "IS" and
/// "IS NULL".
fn allowedOp(op: u8) bool {
    if (op > TK.GE) return false;
    if (op >= TK.EQ) return true;
    return op == TK.IN or op == TK.ISNULL or op == TK.IS;
}

/// Port of exprCommute(): turn "X op Y" into "Y op X".
fn exprCommute(p: *Parse, e: *Expr) TERM {
    if (e.left.?.op == TK.VECTOR or e.right.?.op == TK.VECTOR or
        expr_mod.binaryCompareCollSeq(p, e.left.?, e.right) !=
            expr_mod.binaryCompareCollSeq(p, e.right.?, e.left))
    {
        e.flags.Commuted = !e.flags.Commuted;
    }
    std.mem.swap(?*Expr, &e.left, &e.right);
    if (e.op >= TK.GT) {
        std.debug.assert(e.op >= TK.GT and e.op <= TK.GE);
        e.op = ((e.op - TK.GT) ^ 2) + TK.GT;
    }
    return .{};
}

/// Port of operatorMask(): TK_xx operator to WO_xx bitmask.
fn operatorMask(op: u8) u16 {
    std.debug.assert(allowedOp(op));
    if (op >= TK.EQ) return WO.EQ << @intCast(op - TK.EQ);
    if (op == TK.IN) return WO.IN;
    if (op == TK.ISNULL) return WO.ISNULL;
    std.debug.assert(op == TK.IS);
    return WO.IS;
}

/// Port of isLikeOrGlob(): true if `e` is a LIKE or GLOB that can be
/// optimized with inequality constraints, setting `prefix` to a TK_STRING
/// with the pattern prefix. Parse has no pReprepare, so a TK_VARIABLE
/// pattern never has a bound value (sqlite3VdbeGetBoundValue() is null).
fn isLikeOrGlob(p: *Parse, e: *Expr, prefix: *?*Expr, is_complete: *bool, no_case: *bool) Oom!bool {
    const db = p.db;
    var wc: [4]u8 = undefined;
    if (!func.isLikeFunction(db, e, no_case, &wc)) return false;
    std.debug.assert(e.useXList());
    const list = e.x.list.?;
    const left = list.at(1).expr.?;

    const right = expr_mod.skipCollate(list.at(0).expr).?;
    const op = right.op;
    var z_opt: ?[*:0]const u8 = null;
    if (op == TK.VARIABLE and !db.flags.EnableQPSG) {
        const i_col = right.i_column;
        // sqlite3VdbeGetBoundValue(): no bound value available.
        aux.reprepareOnBind(p.vdbe.?, i_col);
        std.debug.assert(right.op == TK.VARIABLE or right.op == TK.REGISTER);
    } else if (op == TK.STRING) {
        z_opt = right.token().ptr;
    }
    if (z_opt) |z| {
        // Count the prefix bytes before the first wildcard, U+fffd or
        // malformed utf-8 (only ASCII for a UTF16LE database).
        var cnt: usize = 0;
        var c: u8 = undefined;
        while (true) {
            c = z[cnt];
            if (c == 0 or c == wc[0] or c == wc[1] or c == wc[2]) break;
            cnt += 1;
            if (c == wc[3] and z[cnt] > 0 and z[cnt] < 0x80) {
                cnt += 1;
            } else if (c >= 0x80) {
                var z2: [*:0]const u8 = z + cnt - 1;
                if (c == 0xff or func.utf8Read(&z2) == 0xfffd or db.enc == vi.ENC.UTF16LE) {
                    cnt -= 1;
                    break;
                } else {
                    cnt = @intFromPtr(z2) - @intFromPtr(z);
                }
            }
        }

        // The pattern must not begin with a wildcard, the prefix must not
        // end with 0xff, and must not be a single escape character.
        if ((cnt > 1 or (cnt > 0 and z[0] != wc[3])) and 255 != z[cnt - 1]) {
            is_complete.* = c == wc[0] and z[cnt + 1] == 0 and db.enc != vi.ENC.UTF16LE;

            // The pattern prefix, with escapes removed.
            const pfx = try expr_mod.expr(p.arena, TK.STRING, std.mem.span(z));
            const z_new = pfx.u.token.?;
            z_new[cnt] = 0;
            var i_from: usize = 0;
            var i_to: usize = 0;
            while (i_from < cnt) : (i_from += 1) {
                if (z_new[i_from] == wc[3]) i_from += 1;
                z_new[i_to] = z_new[i_from];
                i_to += 1;
            }
            z_new[i_to] = 0;
            std.debug.assert(i_to > 0);
            pfx.u = .{ .token = z_new[0..i_to :0] };

            // Unless the LHS is an ordinary TEXT column, the prefix bounds
            // must not look like numbers.
            if (left.op != TK.COLUMN or expr_mod.affinity(left) != Aff.text or
                (left.useYTab() and left.y.tab != null and left.y.tab.?.isVirtual()))
            {
                var r_dummy: f64 = undefined;
                var is_num = numeric.atoF(z_new.ptr, &r_dummy);
                if (is_num <= 0) {
                    if (i_to == 1 and z_new[0] == '-') {
                        is_num = 1;
                    } else {
                        z_new[i_to - 1] +%= 1;
                        is_num = numeric.atoF(z_new.ptr, &r_dummy);
                        z_new[i_to - 1] -%= 1;
                    }
                }
                if (is_num > 0) return false;
            }
            prefix.* = pfx;

            // A bound-parameter pattern: reprepare when it is rebound.
            if (op == TK.VARIABLE) {
                const v = p.vdbe.?;
                aux.reprepareOnBind(v, right.i_column);
                if (is_complete.* and right.token()[1] != 0) {
                    // Keep an OP_Variable for sqlite3_bind_parameter_name().
                    const r1 = expr_mod.getTempReg(p);
                    _ = ec.codeTarget(p, right, r1);
                    aux.changeP3(v, aux.currentAddr(v) - 1, 0);
                    expr_mod.releaseTempReg(p, r1);
                }
            }
        } else {
            z_opt = null;
        }
    }
    return z_opt != null;
}

/// Port of sqlite3ExprIsLikeOperator(): the SQLITE_INDEX_CONSTRAINT_xxx
/// value of "like", "glob", "match" or "regexp", else 0.
pub fn exprIsLikeOperator(e: *const Expr) u8 {
    const ops = [_]struct { z: []const u8, e_op: u8 }{
        .{ .z = "match", .e_op = INDEX_CONSTRAINT.MATCH },
        .{ .z = "glob", .e_op = INDEX_CONSTRAINT.GLOB },
        .{ .z = "like", .e_op = INDEX_CONSTRAINT.LIKE },
        .{ .z = "regexp", .e_op = INDEX_CONSTRAINT.REGEXP },
    };
    std.debug.assert(e.op == TK.FUNCTION);
    std.debug.assert(!e.flags.IntValue);
    for (ops) |o| {
        if (ctype.strICmp(e.token(), o.z) == 0) return o.e_op;
    }
    return 0;
}

/// Port of isAuxiliaryVtabOperator(): 1 or 2 if `e` is a form passed to
/// xBestIndex of a virtual table (MATCH, GLOB, LIKE, REGEXP, a function
/// xFindFunction offers, !=, IS NOT or NOT NULL on one of its columns),
/// else 0.
fn isAuxiliaryVtabOperator(db: *int.Sqlite3, e: *Expr, e_op2: *u8, pp_left: *?*Expr, pp_right: *?*Expr) i32 {
    if (e.op == TK.FUNCTION) {
        std.debug.assert(e.useXList());
        const list = e.x.list orelse return 0;
        if (list.len() != 2) return 0;
        // MATCH, GLOB, LIKE and REGEXP attach on their second argument.
        const col = list.at(1).expr.?;
        if (exprIsVtab(col)) {
            const i = exprIsLikeOperator(e);
            if (i != 0) {
                e_op2.* = i;
                pp_right.* = list.at(0).expr;
                pp_left.* = col;
                return 1;
            }
        }
        // OVERLOADED(vtab_column, expr) where xFindFunction returns at
        // least SQLITE_INDEX_CONSTRAINT_FUNCTION (the name may be in any
        // case here).
        const col0 = list.at(0).expr.?;
        if (exprIsVtab(col0)) {
            const vtab = @import("vtab.zig");
            const pv = vtab.getVTable(db, col0.y.tab.?).?.vtab.?;
            std.debug.assert(!e.flags.IntValue);
            if (pv.module.x_find_function) |x_find| {
                var x_not_used: ?int.FuncDef.StepFn = null;
                var not_used: ?*anyopaque = null;
                const i = x_find(pv, 2, e.token(), &x_not_used, &not_used);
                if (i >= INDEX_CONSTRAINT.FUNCTION) {
                    e_op2.* = @intCast(i);
                    pp_right.* = list.at(1).expr;
                    pp_left.* = col0;
                    return 1;
                }
            }
        }
    } else if (e.op >= TK.EQ) {
        return 0;
    } else if (e.op == TK.NE or e.op == TK.ISNOT or e.op == TK.NOTNULL) {
        var res: i32 = 0;
        var left = e.left;
        var right = e.right;
        if (exprIsVtab(left.?)) res += 1;
        if (right != null and exprIsVtab(right.?)) {
            res += 1;
            std.mem.swap(?*Expr, &left, &right);
        }
        pp_left.* = left;
        pp_right.* = right;
        if (e.op == TK.NE) e_op2.* = INDEX_CONSTRAINT.NE;
        if (e.op == TK.ISNOT) e_op2.* = INDEX_CONSTRAINT.ISNOT;
        if (e.op == TK.NOTNULL) e_op2.* = INDEX_CONSTRAINT.ISNOTNULL;
        return res;
    }
    return 0;
}

/// Port of transferJoinMarkings(): copy the ON/USING markings of `base`.
fn transferJoinMarkings(derived: ?*Expr, base: *Expr) void {
    if (derived) |d| if (base.flags.intersects(.{ .OuterON = true, .InnerON = true })) {
        d.flags.set(base.flags.only(.{ .OuterON = true, .InnerON = true }));
        d.w = .{ .join = base.w.join };
    };
}

/// Port of markTermAsChild().
fn markTermAsChild(wc: *WhereClause, i_child: i32, i_parent: i32) void {
    const child = &wc.a[@intCast(i_child)];
    const parent = &wc.a[@intCast(i_parent)];
    child.i_parent = i_parent;
    child.truth_prob = parent.truth_prob;
    std.debug.assert(parent.n_child < std.math.maxInt(u8));
    parent.n_child += 1;
}

/// Port of whereNthSubterm(): the N-th AND-connected subterm of `term`,
/// or `term` itself for N==0 if it is not a conjunction.
fn whereNthSubterm(term: *WhereTerm, n: i32) ?*WhereTerm {
    if (term.e_operator != WO.AND) return if (n == 0) term else null;
    const and_wc = &term.and_info.?.wc;
    if (n < and_wc.n_term) return &and_wc.a[@intCast(n)];
    return null;
}

/// Port of whereCombineDisjuncts(): for "A op1 B OR A op2 B" with
/// compatible operators, add the virtual term "A op B" (x<y OR x=y -> x<=y).
fn whereCombineDisjuncts(src: *SrcList, wc: *WhereClause, one: *WhereTerm, two: *WhereTerm) Oom!void {
    var e_op: u16 = one.e_operator | two.e_operator;
    const cmp_ops = WO.EQ | WO.LT | WO.LE | WO.GT | WO.GE;
    if (one.wt_flags.VNULL or two.wt_flags.VNULL) return;
    if (one.e_operator & cmp_ops == 0) return;
    if (two.e_operator & cmp_ops == 0) return;
    if (e_op & (WO.EQ | WO.LT | WO.LE) != e_op and e_op & (WO.EQ | WO.GT | WO.GE) != e_op) return;
    const a = one.expr;
    const b = two.expr;
    if (expr_mod.compare(null, a.left, b.left, -1) != 0) return;
    if (expr_mod.compare(null, a.right, b.right, -1) != 0) return;
    if (a.flags.Commuted != b.flags.Commuted) return;
    // The two subterms can be combined.
    if (e_op & (e_op - 1) != 0) {
        if (e_op & (WO.LT | WO.LE) != 0) {
            e_op = WO.LE;
        } else {
            std.debug.assert(e_op & (WO.GT | WO.GE) != 0);
            e_op = WO.GE;
        }
    }
    const new = (try expr_mod.exprDup(wc.w_info.parse.arena, a)).?;
    var op: u8 = TK.EQ;
    while (e_op != (WO.EQ << @intCast(op - TK.EQ))) : (op += 1) {
        std.debug.assert(op < TK.GE);
    }
    new.op = op;
    const idx_new = try whereClauseInsert(wc, new, .{ .VIRTUAL = true, .DYNAMIC = true });
    try exprAnalyzeTerm(src, wc, idx_new);
}

/// Port of exprAnalyzeOrTerm(): analyze a term of two or more
/// OR-connected subterms. Attaches a WhereOrInfo; may add a virtual
/// "x IN (...)" term (case 1) or a combined inequality (case 2), and
/// records the tables indexable by every subterm (case 3).
fn exprAnalyzeOrTerm(src: *SrcList, wc: *WhereClause, idx_term: i32) Oom!void {
    const w = wc.w_info;
    const p = w.parse;
    const db = p.db;
    const term = &wc.a[@intCast(idx_term)];
    const e = term.expr;

    // Break the OR clause into its subterms.
    std.debug.assert(!term.wt_flags.intersects(.{ .DYNAMIC = true, .ORINFO = true, .ANDINFO = true }));
    std.debug.assert(e.op == TK.OR);
    const or_info = try p.arena.create(WhereOrInfo);
    or_info.* = .{ .wc = .{ .w_info = w } };
    term.or_info = or_info;
    term.wt_flags.ORINFO = true;
    const or_wc = &or_info.wc;
    clauseInit(or_wc, w);
    try split(or_wc, e, TK.OR);
    try exprAnalyze(src, or_wc);
    if (db.malloc_failed) return;
    std.debug.assert(or_wc.n_term >= 2);

    // The tables that might satisfy cases 1 or 3.
    var indexable: Bitmask = ~@as(Bitmask, 0);
    var chng_to_in: Bitmask = ~@as(Bitmask, 0);
    {
        var i: i32 = or_wc.n_term - 1;
        var k: usize = 0;
        while (i >= 0 and indexable != 0) : ({
            i -= 1;
            k += 1;
        }) {
            const or_term = &or_wc.a[k];
            if (or_term.e_operator & WO.SINGLE == 0) {
                std.debug.assert(!or_term.wt_flags.intersects(.{ .ANDINFO = true, .ORINFO = true }));
                chng_to_in = 0;
                const and_info = try p.arena.create(WhereAndInfo);
                and_info.* = .{ .wc = .{ .w_info = w } };
                var b: Bitmask = 0;
                or_term.and_info = and_info;
                or_term.wt_flags.ANDINFO = true;
                or_term.e_operator = WO.AND;
                or_term.left_cursor = -1;
                const and_wc = &and_info.wc;
                clauseInit(and_wc, wc.w_info);
                try split(and_wc, or_term.expr, TK.AND);
                try exprAnalyze(src, and_wc);
                and_wc.outer = wc;
                if (!db.malloc_failed) {
                    for (and_wc.terms()) |*and_term| {
                        if (allowedOp(and_term.expr.op) or and_term.e_operator == WO.AUX) {
                            b |= getMask(&w.s_mask_set, and_term.left_cursor);
                        }
                    }
                }
                indexable &= b;
            } else if (or_term.wt_flags.COPIED) {
                // Revisited with the corresponding TERM_VIRTUAL term.
            } else {
                var b = getMask(&w.s_mask_set, or_term.left_cursor);
                if (or_term.wt_flags.VIRTUAL) {
                    const other = &or_wc.a[@intCast(or_term.i_parent)];
                    b |= getMask(&w.s_mask_set, other.left_cursor);
                }
                indexable &= b;
                if (or_term.e_operator & WO.EQ == 0) {
                    chng_to_in = 0;
                } else {
                    chng_to_in &= b;
                }
            }
        }
    }

    // The tables that satisfy case 3 (possibly none).
    or_info.indexable = indexable;
    term.e_operator = WO.OR;
    term.left_cursor = -1;
    if (indexable != 0) wc.has_or = true;

    // Case 2, for a two-way OR.
    if (indexable != 0 and or_wc.n_term == 2) {
        var i_one: i32 = 0;
        while (whereNthSubterm(&or_wc.a[0], i_one)) |one| {
            i_one += 1;
            var i_two: i32 = 0;
            while (whereNthSubterm(&or_wc.a[1], i_two)) |two| {
                i_two += 1;
                try whereCombineDisjuncts(src, wc, one, two);
            }
        }
    }

    // chngToIN holds 0, 1 or 2 tables that might satisfy case 1. Check
    // that one column of one of them is on one side of every "==".
    if (chng_to_in != 0) {
        var ok_to_chng_to_in = false;
        var i_column: i32 = -1;
        var i_cursor: i32 = -1;
        var j: i32 = 0;

        // Find a table and column that appears in every subterm.
        while (j < 2 and !ok_to_chng_to_in) : (j += 1) {
            var left: ?*Expr = null;
            var k: usize = 0;
            var i: i32 = or_wc.n_term - 1;
            while (i >= 0) : ({
                i -= 1;
                k += 1;
            }) {
                const or_term = &or_wc.a[k];
                std.debug.assert(or_term.e_operator & WO.EQ != 0);
                or_term.wt_flags.OK = false;
                if (or_term.left_cursor == i_cursor) {
                    // 2-bit case, second iteration: a first-iteration term.
                    std.debug.assert(j == 1);
                    continue;
                }
                if (chng_to_in & getMask(&w.s_mask_set, or_term.left_cursor) == 0) {
                    // t1.a==t2.b with only t2 in chngToIN: use the inverted
                    // copy instead.
                    std.debug.assert(or_term.wt_flags.intersects(.{ .COPIED = true, .VIRTUAL = true }));
                    continue;
                }
                std.debug.assert(or_term.e_operator & (WO.OR | WO.AND) == 0);
                i_column = or_term.left_column;
                i_cursor = or_term.left_cursor;
                left = or_term.expr.left;
                break;
            }
            if (i < 0) {
                // No candidate; only possible on the second iteration.
                std.debug.assert(j == 1);
                std.debug.assert(std.math.isPowerOfTwo(chng_to_in));
                std.debug.assert(chng_to_in == getMask(&w.s_mask_set, i_cursor));
                break;
            }

            // Check that the candidate is common to every term.
            ok_to_chng_to_in = true;
            while (i >= 0 and ok_to_chng_to_in) : ({
                i -= 1;
                k += 1;
            }) {
                const or_term = &or_wc.a[k];
                std.debug.assert(or_term.e_operator & WO.EQ != 0);
                std.debug.assert(or_term.e_operator & (WO.OR | WO.AND) == 0);
                if (or_term.left_cursor != i_cursor) {
                    or_term.wt_flags.OK = false;
                } else if (or_term.left_column != i_column or (i_column == int.XN_EXPR and
                    expr_mod.compare(p, or_term.expr.left, left, -1) != 0))
                {
                    ok_to_chng_to_in = false;
                } else {
                    // A column on the right needs no type conversion
                    // (ticket #2249).
                    const aff_right = expr_mod.affinity(or_term.expr.right.?);
                    const aff_left = expr_mod.affinity(or_term.expr.left.?);
                    if (aff_right != 0 and aff_right != aff_left) {
                        ok_to_chng_to_in = false;
                    } else {
                        or_term.wt_flags.OK = true;
                    }
                }
            }
        }

        // Build "x IN (...)" unless the collating sequences differ.
        if (ok_to_chng_to_in) {
            var list: ?*ExprList = null;
            var left: ?*Expr = null;
            var coll_seq: ?*const CollSeq = null;
            var new: ?*Expr = null;

            var k: usize = 0;
            var i: i32 = or_wc.n_term - 1;
            while (i >= 0) : ({
                i -= 1;
                k += 1;
            }) {
                const or_term = &or_wc.a[k];
                if (!or_term.wt_flags.OK) continue;
                std.debug.assert(or_term.e_operator & WO.EQ != 0);
                std.debug.assert(or_term.e_operator & (WO.OR | WO.AND) == 0);
                std.debug.assert(or_term.left_cursor == i_cursor);
                std.debug.assert(or_term.left_column == i_column);
                const this = or_term.expr;
                const dup = try expr_mod.exprDup(p.arena, this.right);
                list = try expr_mod.listAppend(w.parse, list, dup);
                if (left == null) {
                    left = this.left;
                    coll_seq = expr_mod.compareCollSeq(p, this);
                } else {
                    if (coll_seq != expr_mod.compareCollSeq(p, this)) {
                        left = null; // collating sequence mismatch
                        break;
                    }
                }
            }
            if (left) |l| {
                var dup = (try expr_mod.exprDup(p.arena, l)).?;
                if (expr_mod.collSeq(p, dup) != coll_seq and coll_seq != null) {
                    dup = try expr_mod.addCollateString(p, dup, coll_seq.?.name);
                }
                new = try expr_mod.pExpr(p, TK.IN, dup, null);
            }
            if (new) |n| {
                transferJoinMarkings(n, e);
                std.debug.assert(n.useXList());
                n.x = .{ .list = list };
                const idx_new = try whereClauseInsert(wc, n, .{ .VIRTUAL = true, .DYNAMIC = true });
                try exprAnalyzeTerm(src, wc, idx_new);
                markTermAsChild(wc, idx_new, idx_term);
            }
        }
    }
}

/// Port of termIsEquivalence(): true if the RHS of the column==column
/// term `e` may be substituted for its LHS elsewhere in the WHERE clause.
fn termIsEquivalence(p: *Parse, e: *Expr, src: *SrcList) bool {
    if (p.db.optDisabled(int.OPT.Transitive)) return false; // (1)
    if (e.op != TK.EQ and e.op != TK.IS) return false; // (2)
    if (e.flags.intersects(.{ .OuterON = true, .Collate = true })) return false; // (3)
    if (e.op == TK.IS and src.len() >= 2 and src.at(0).fg.jointype.LTORJ) {
        return false; // (4)
    }
    const aff1 = expr_mod.affinity(e.left.?);
    const aff2 = expr_mod.affinity(e.right.?);
    if (aff1 != aff2 and (!expr_mod.isNumericAffinity(aff1) or !expr_mod.isNumericAffinity(aff2))) {
        return false; // (5)
    }
    if (!expr_mod.collSeqMatch(p, e.left.?, e.right.?)) return false; // (6)
    return true;
}

/// Port of exprSelectUsage(): the tables used by a SELECT and its priors.
fn exprSelectUsage(ms: *WhereMaskSet, s_arg: ?*Select) Bitmask {
    var mask: Bitmask = 0;
    var s = s_arg;
    while (s) |sel| : (s = sel.prior) {
        mask |= exprListUsage(ms, sel.e_list);
        mask |= exprListUsage(ms, sel.group_by);
        mask |= exprListUsage(ms, sel.order_by);
        mask |= exprUsage(ms, sel.where);
        mask |= exprUsage(ms, sel.having);
        if (sel.src) |src| {
            for (src.slice()) |*item| {
                if (item.fg.is_subquery) mask |= exprSelectUsage(ms, item.u4.subq.?.select);
                if (!item.fg.is_using) mask |= exprUsage(ms, item.u3.on);
                if (item.fg.is_tab_func) mask |= exprListUsage(ms, item.u1.func_arg);
            }
        }
    }
    return mask;
}

/// Port of exprMightBeIndexed2(): look for `e` among the expressions of
/// the indexes of FROM entries j and later.
fn exprMightBeIndexed2(from: *SrcList, ai_cur_col: *[2]i32, e: *Expr, j_arg: usize) bool {
    var j = j_arg;
    while (true) {
        const i_cur = from.at(j).i_cursor;
        var idx_opt = from.at(j).s_tab.?.index;
        while (idx_opt) |idx| : (idx_opt = idx.next) {
            const col_expr = idx.col_expr orelse continue;
            for (0..idx.n_key_col) |i| {
                if (idx.ai_column[i] != int.XN_EXPR) continue;
                std.debug.assert(idx.has_expr);
                if (expr_mod.compareSkip(e, col_expr.at(i).expr, i_cur) == 0 and
                    !expr_mod.isConstant(null, col_expr.at(i).expr))
                {
                    ai_cur_col[0] = i_cur;
                    ai_cur_col[1] = int.XN_EXPR;
                    return true;
                }
            }
        }
        j += 1;
        if (j >= from.len()) break;
    }
    return false;
}

/// Port of exprMightBeIndexed(): true if `e`, an operand of comparison
/// `op`, is a column (always, for automatic indexes) or an indexed
/// expression; sets ai_cur_col to its cursor and column (or XN_EXPR).
fn exprMightBeIndexed(from: *SrcList, ai_cur_col: *[2]i32, e_arg: *Expr, op: u8) bool {
    var e = e_arg;
    // For a vector on either side of an inequality, use its first element.
    std.debug.assert(op <= TK.GE);
    if (e.op == TK.VECTOR and op >= TK.GT and op <= TK.GE) {
        std.debug.assert(e.useXList());
        e = e.x.list.?.at(0).expr.?;
    }

    if (e.op == TK.COLUMN) {
        ai_cur_col[0] = e.i_table;
        ai_cur_col[1] = e.i_column;
        return true;
    }

    for (from.slice(), 0..) |*item, i| {
        var idx_opt = item.s_tab.?.index;
        while (idx_opt) |idx| : (idx_opt = idx.next) {
            if (idx.col_expr != null) return exprMightBeIndexed2(from, ai_cur_col, e, i);
        }
    }
    return false;
}

/// Port of the static exprAnalyze() (renamed: the pub exprAnalyze() is
/// sqlite3WhereExprAnalyze()): fill in the WhereTerm wc.a[idx_term] from
/// its expression. "<expr> <op> X" is commuted to "X <op> <expr>"; for
/// "X <op> Y" with both sides indexable a commuted virtual copy is added.
/// BETWEEN, OR, IS NOT NULL, LIKE/GLOB and row values add virtual terms.
fn exprAnalyzeTerm(src: *SrcList, wc: *WhereClause, idx_term: i32) Oom!void {
    const w = wc.w_info;
    const p = w.parse;
    const db = p.db;
    var extra_right: Bitmask = 0;
    var str1: ?*Expr = null;
    var is_complete = false;
    var no_case = false;
    var e_op2: u8 = 0;

    if (db.malloc_failed) return;
    std.debug.assert(wc.n_term > idx_term);
    var term = &wc.a[@intCast(idx_term)];
    const mask_set = &w.s_mask_set;
    var e = term.expr;
    std.debug.assert(e.op != TK.AS and e.op != TK.COLLATE);

    // exprAnalyze_restart:
    while (true) {
        mask_set.b_var_select = false;
        const prereq_left = exprUsage(mask_set, e.left);
        const op = e.op;
        var prereq_all: Bitmask = undefined;
        if (op == TK.IN) {
            std.debug.assert(e.right == null);
            if (expr_mod.checkIN(p, e)) return;
            if (e.useXSelect()) {
                term.prereq_right = exprSelectUsage(mask_set, e.x.select);
            } else {
                term.prereq_right = exprListUsage(mask_set, e.x.list);
            }
            prereq_all = prereq_left | term.prereq_right;
        } else {
            term.prereq_right = exprUsage(mask_set, e.right);
            if (e.left == null or e.flags.intersects(.{ .xIsSelect = true, .IfNullRow = true }) or e.x.list != null) {
                prereq_all = exprUsageNN(mask_set, e);
            } else {
                prereq_all = prereq_left | term.prereq_right;
            }
        }
        if (mask_set.b_var_select) term.wt_flags.VARSELECT = true;

        if (e.flags.intersects(.{ .OuterON = true, .InnerON = true })) {
            const x = getMask(mask_set, e.w.join);
            if (e.flags.OuterON) {
                prereq_all |= x;
                // ON terms may not use an index on the left table of a
                // LEFT JOIN (ticket #3015).
                extra_right = x -% 1;
            } else if ((prereq_all >> 1) >= x) {
                e.flags.InnerON = false;
            }
        }
        term.prereq_all = prereq_all;
        term.left_cursor = -1;
        term.i_parent = -1;
        term.e_operator = 0;
        if (allowedOp(op)) {
            var ai_cur_col: [2]i32 = undefined;
            var left = expr_mod.skipCollate(e.left).?;
            const right = expr_mod.skipCollate(e.right);
            const op_mask: u16 = if (term.prereq_right & prereq_left == 0) WO.ALL else WO.EQUIV;

            if (term.i_field > 0) {
                std.debug.assert(op == TK.IN);
                std.debug.assert(left.op == TK.VECTOR);
                std.debug.assert(left.useXList());
                left = left.x.list.?.at(@intCast(term.i_field - 1)).expr.?;
            }

            if (exprMightBeIndexed(src, &ai_cur_col, left, op)) {
                term.left_cursor = ai_cur_col[0];
                std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
                term.left_column = ai_cur_col[1];
                term.e_operator = operatorMask(op) & op_mask;
            }
            if (op == TK.IS) term.wt_flags.IS = true;
            if (right != null and exprMightBeIndexed(src, &ai_cur_col, right.?, op) and
                !right.?.flags.FixedCol)
            {
                var new: *WhereTerm = undefined;
                var dup: *Expr = undefined;
                var e_extra_op: u16 = 0;
                std.debug.assert(term.i_field == 0);
                if (term.left_cursor >= 0) {
                    dup = (try expr_mod.exprDup(p.arena, e)).?;
                    if (db.malloc_failed) return;
                    const idx_new = try whereClauseInsert(wc, dup, .{ .VIRTUAL = true, .DYNAMIC = true });
                    new = &wc.a[@intCast(idx_new)];
                    markTermAsChild(wc, idx_new, idx_term);
                    if (op == TK.IS) new.wt_flags.IS = true;
                    term = &wc.a[@intCast(idx_term)];
                    term.wt_flags.COPIED = true;
                    if (termIsEquivalence(p, dup, w.tab_list)) {
                        term.e_operator |= WO.EQUIV;
                        e_extra_op = WO.EQUIV;
                    }
                } else {
                    dup = e;
                    new = term;
                }
                new.wt_flags.set(exprCommute(p, dup));
                new.left_cursor = ai_cur_col[0];
                std.debug.assert(term.e_operator & (WO.OR | WO.AND) == 0);
                new.left_column = ai_cur_col[1];
                new.prereq_right = prereq_left | extra_right;
                new.prereq_all = prereq_all;
                new.e_operator = (operatorMask(dup.op) + e_extra_op) & op_mask;
            } else if (op == TK.ISNULL and !e.flags.OuterON and !expr_mod.canBeNull(left)) {
                std.debug.assert(!e.flags.IntValue);
                e.op = TK.TRUEFALSE; // See tag-20230504-1
                e.u = .{ .token = try p.arena.dupeSentinel(u8, "false", 0) };
                e.flags.IsFalse = true;
                term.prereq_all = 0;
                term.e_operator = 0;
            }
        }

        // "a BETWEEN b AND c" adds the virtual children "a>=b" and "a<=c".
        else if (e.op == TK.BETWEEN and wc.op == TK.AND) {
            const ops = [2]u8{ TK.GE, TK.LE };
            std.debug.assert(e.useXList());
            const list = e.x.list.?;
            std.debug.assert(list.len() == 2);
            std.debug.assert(wc.a[@intCast(idx_term)].n_child == 0);
            for (0..2) |i| {
                const new_expr = try expr_mod.pExpr(
                    p,
                    ops[i],
                    try expr_mod.exprDup(p.arena, e.left),
                    try expr_mod.exprDup(p.arena, list.at(i).expr),
                );
                transferJoinMarkings(new_expr, e);
                const idx_new = try whereClauseInsert(wc, new_expr, .{ .VIRTUAL = true, .DYNAMIC = true });
                try exprAnalyzeTerm(src, wc, idx_new);
                term = &wc.a[@intCast(idx_term)];
                markTermAsChild(wc, idx_new, idx_term);
            }
        }

        // Two or more OR-connected subterms.
        else if (e.op == TK.OR and !e.flags.Collate) {
            const alt = expr_mod.simplifiedAndOr(e);
            if (alt != e) {
                e = expr_mod.skipCollateAndLikely(alt).?;
                term.expr = e;
                continue;
            }
            std.debug.assert(wc.op == TK.AND);
            try exprAnalyzeOrTerm(src, wc, idx_term);
            term = &wc.a[@intCast(idx_term)];
        }

        // "x IS NOT NULL" adds the virtual term "x>NULL" (TERM_VNULL) for
        // a column x that is not the rowid.
        else if (e.op == TK.NOTNULL) {
            if (e.left.?.op == TK.COLUMN and e.left.?.i_column >= 0 and !e.flags.OuterON) {
                const left = e.left.?;
                const new_expr = try expr_mod.pExpr(
                    p,
                    TK.GT,
                    try expr_mod.exprDup(p.arena, left),
                    try expr_mod.exprAlloc(p.arena, TK.NULL, null, false),
                );
                const idx_new = try whereClauseInsert(wc, new_expr, .{ .VIRTUAL = true, .DYNAMIC = true, .VNULL = true });
                if (idx_new != 0) {
                    const new_term = &wc.a[@intCast(idx_new)];
                    new_term.prereq_right = 0;
                    new_term.left_cursor = left.i_table;
                    new_term.left_column = left.i_column;
                    new_term.e_operator = WO.GT;
                    markTermAsChild(wc, idx_new, idx_term);
                    term = &wc.a[@intCast(idx_term)];
                    term.wt_flags.COPIED = true;
                    new_term.prereq_all = term.prereq_all;
                }
            }
        }

        // "x LIKE 'aBc%'" adds "x>='ABC' AND x<'abd'": the last prefix
        // character is incremented for the upper bound; without case
        // sensitivity the lower bound is upper-case and the upper bound
        // lower-case so the range also works for BLOBs.
        else if (e.op == TK.FUNCTION and wc.op == TK.AND and
            try isLikeOrGlob(p, e, &str1, &is_complete, &no_case))
        {
            const wt_flags: TERM = .{ .LIKEOPT = true, .VIRTUAL = true, .DYNAMIC = true };
            std.debug.assert(e.useXList());
            const left = e.x.list.?.at(1).expr.?;
            const s1 = str1.?;
            const s2 = (try expr_mod.exprDup(p.arena, s1)).?;

            if (no_case and !p.db.malloc_failed) {
                term.wt_flags.LIKE = true;
                const t1 = s1.u.token.?;
                const t2 = s2.u.token.?;
                var i: usize = 0;
                while (t1[i] != 0) : (i += 1) {
                    const c = t1[i];
                    t1[i] = ctype.toUpper(c);
                    t2[i] = ctype.toLower(c);
                }
            }

            if (!db.malloc_failed) {
                // The last character before the first wildcard.
                const t2 = s2.u.token.?;
                var pc: usize = std.mem.indexOfScalar(u8, t2, 0) orelse t2.len;
                pc -= 1;
                if (no_case) {
                    // Incrementing '@' would enter the alphabetic range, where
                    // case conversion breaks the inequality: run the full LIKE.
                    if (t2[pc] == 'A' - 1) is_complete = false;
                    t2[pc] = ctype.toLower(t2[pc]);
                }
                // Increment the last utf8 character of the prefix.
                while (t2[pc] == 0xBF and pc > 0) {
                    t2[pc] = 0x80;
                    pc -= 1;
                }
                std.debug.assert(t2[pc] != 0xFF);
                t2[pc] += 1;
            }
            const coll_seq_name: []const u8 = if (no_case) "NOCASE" else coll_mod.str_binary;
            var new_expr1 = (try expr_mod.exprDup(p.arena, left)).?;
            new_expr1 = try expr_mod.pExpr(
                p,
                TK.GE,
                try expr_mod.addCollateString(p, new_expr1, coll_seq_name),
                s1,
            );
            transferJoinMarkings(new_expr1, e);
            const idx_new1 = try whereClauseInsert(wc, new_expr1, wt_flags);
            var new_expr2 = (try expr_mod.exprDup(p.arena, left)).?;
            new_expr2 = try expr_mod.pExpr(
                p,
                TK.LT,
                try expr_mod.addCollateString(p, new_expr2, coll_seq_name),
                s2,
            );
            transferJoinMarkings(new_expr2, e);
            const idx_new2 = try whereClauseInsert(wc, new_expr2, wt_flags);
            try exprAnalyzeTerm(src, wc, idx_new1);
            try exprAnalyzeTerm(src, wc, idx_new2);
            term = &wc.a[@intCast(idx_term)];
            if (is_complete) {
                markTermAsChild(wc, idx_new1, idx_term);
                markTermAsChild(wc, idx_new2, idx_term);
            }
        }

        // A vector == or IS, "(a, b) == (?, ?)", not entirely made of
        // subqueries, is replaced by one term per component
        // (tag-20220128a).
        var n_left: usize = 0;
        if ((e.op == TK.EQ or e.op == TK.IS) and
            blk: {
                n_left = expr_mod.vectorSize(e.left.?);
                break :blk n_left > 1;
            } and
            expr_mod.vectorSize(e.right.?) == n_left and
            (!e.left.?.flags.xIsSelect or !e.right.?.flags.xIsSelect) and
            wc.op == TK.AND)
        {
            for (0..n_left) |i| {
                const n: i32 = @intCast(n_left);
                const left = try expr_mod.forVectorField(p, e.left.?, @intCast(i), n);
                const right = try expr_mod.forVectorField(p, e.right.?, @intCast(i), n);
                const new = try expr_mod.pExpr(p, e.op, left, right);
                transferJoinMarkings(new, e);
                const idx_new = try whereClauseInsert(wc, new, .{ .DYNAMIC = true, .SLICE = true });
                try exprAnalyzeTerm(src, wc, idx_new);
            }
            term = &wc.a[@intCast(idx_term)];
            term.wt_flags.set(.{ .CODED = true, .VIRTUAL = true }); // disable the original
            term.e_operator = WO.ROWVAL;
        }

        // A vector IN, "(a, b) IN (SELECT ...)" with a simple SELECT on the
        // right, gets one virtual term per LHS field, all using `e`.
        else if (e.op == TK.IN and term.i_field == 0 and e.left.?.op == TK.VECTOR and
            e.useXSelect() and
            (e.x.select.?.prior == null or e.x.select.?.sel_flags.Values) and
            e.x.select.?.win == null and
            !e.x.select.?.sel_flags.MinMaxAgg and
            wc.op == TK.AND and
            e.x.select.?.e_list.?.len() <= std.math.maxInt(u8))
        {
            std.debug.assert(term.n_child == 0);
            var i: usize = 0;
            while (i < expr_mod.vectorSize(e.left.?)) : (i += 1) {
                const idx_new = try whereClauseInsert(wc, e, .{ .VIRTUAL = true, .SLICE = true });
                wc.a[@intCast(idx_new)].i_field = @intCast(i + 1);
                try exprAnalyzeTerm(src, wc, idx_new);
                markTermAsChild(wc, idx_new, idx_term);
            }
        }

        // A WO_AUX term for operators only virtual tables use (MATCH, LIKE,
        // GLOB, REGEXP, !=, IS NOT, NOT NULL).
        else if (wc.op == TK.AND) {
            var right: ?*Expr = null;
            var left: ?*Expr = null;
            var res = isAuxiliaryVtabOperator(db, e, &e_op2, &left, &right);
            while (res > 0) : (res -= 1) {
                const prereq_expr = exprUsage(mask_set, right);
                const prereq_column = exprUsage(mask_set, left);
                if (prereq_expr & prereq_column == 0) {
                    const new_expr = try expr_mod.pExpr(p, TK.MATCH, null, try expr_mod.exprDup(p.arena, right));
                    if (e.flags.OuterON) {
                        new_expr.flags.OuterON = true;
                        new_expr.w = .{ .join = e.w.join };
                    }
                    const idx_new = try whereClauseInsert(wc, new_expr, .{ .VIRTUAL = true, .DYNAMIC = true });
                    const new_term = &wc.a[@intCast(idx_new)];
                    new_term.prereq_right = prereq_expr | extra_right;
                    new_term.left_cursor = left.?.i_table;
                    new_term.left_column = left.?.i_column;
                    new_term.e_operator = WO.AUX;
                    new_term.e_match_op = e_op2;
                    markTermAsChild(wc, idx_new, idx_term);
                    term = &wc.a[@intCast(idx_term)];
                    term.wt_flags.COPIED = true;
                    new_term.prereq_all = term.prereq_all;
                }
                std.mem.swap(?*Expr, &left, &right);
            }
        }

        // ON terms of a LEFT JOIN may not drive an index for tables to the
        // left of the join.
        term = &wc.a[@intCast(idx_term)];
        term.prereq_right |= extra_right;
        return;
    }
}

/// Port of sqlite3WhereSplit(): add the `op`-connected subexpressions of
/// `e` to `wc` (e itself is not altered).
pub fn split(wc: *WhereClause, e: ?*Expr, op: u8) Oom!void {
    const e2 = expr_mod.skipCollateAndLikely(e);
    wc.op = op;
    const x = e2 orelse return;
    if (x.op != op) {
        _ = try whereClauseInsert(wc, e.?, .{});
    } else {
        try split(wc, x.left, op);
        try split(wc, x.right, op);
    }
}

/// Port of whereAddLimitExpr(): add a WO_AUX LIMIT or OFFSET term whose
/// value is in register `i_reg` (or a TK_INTEGER if `e` is a constant).
fn whereAddLimitExpr(wc: *WhereClause, i_reg: i32, e: ?*Expr, i_csr: i32, e_match_op: u8) Oom!void {
    const p = wc.w_info.parse;
    var new: *Expr = undefined;
    const i_val = expr_mod.isInteger(e, p);
    if (i_val != null and i_val.? >= 0) {
        const val = try expr_mod.exprInt32(p.arena, i_val.?);
        new = try expr_mod.pExpr(p, TK.MATCH, null, val);
    } else {
        const val = try expr_mod.exprAlloc(p.arena, TK.REGISTER, null, false);
        val.i_table = i_reg;
        new = try expr_mod.pExpr(p, TK.MATCH, null, val);
    }
    const idx = try whereClauseInsert(wc, new, .{ .DYNAMIC = true, .VIRTUAL = true });
    const term = &wc.a[@intCast(idx)];
    term.left_cursor = i_csr;
    term.e_operator = WO.AUX;
    term.e_match_op = e_match_op;
}

/// Port of sqlite3WhereClauseInit(). C points `a` at the 8-slot aStatic
/// array; here the first whereClauseInsert() allocates those slots.
pub fn clauseInit(wc: *WhereClause, w_info: *WhereInfo) void {
    wc.w_info = w_info;
    wc.has_or = false;
    wc.outer = null;
    wc.n_term = 0;
    wc.n_base = 0;
    wc.a = &.{};
}

/// Port of sqlite3WhereClauseClear(): the dynamic expressions and the
/// OR/AND infos live in the Parse arena, so there is nothing to free.
pub fn clauseClear(wc: *WhereClause) void {
    std.debug.assert(wc.n_term >= wc.n_base);
}

/// Port of sqlite3WhereAddLimit(): add LIMIT/OFFSET terms for a SELECT
/// over a single virtual table whose WHERE and ORDER BY all go to
/// xBestIndex.
pub fn addLimit(wc: *WhereClause, sel: *Select) Oom!void {
    std.debug.assert(sel.limit != null); // 1 -- checked by caller
    const src = sel.src.?;
    if (sel.group_by == null and
        !sel.sel_flags.intersects(.{ .Distinct = true, .Aggregate = true }) and // 2
        (src.len() == 1 and src.at(0).s_tab.?.isVirtual())) // 3
    {
        const order_by = sel.order_by;
        const i_csr = src.at(0).i_cursor;

        // Condition (4): every term goes to xBestIndex.
        for (wc.terms()) |*t| {
            if (t.wt_flags.CODED) {
                // A decomposed vector term (tag-20220128a).
                std.debug.assert(t.wt_flags.VIRTUAL);
                std.debug.assert(t.e_operator == WO.ROWVAL);
                continue;
            }
            // Its children are checked on their own.
            if (t.n_child != 0) continue;
            if (t.left_cursor == i_csr and t.prereq_right == 0) continue;
            // A child whose single-child parent goes to xBestIndex.
            if (t.i_parent >= 0) {
                const parent = &wc.a[@intCast(t.i_parent)];
                if (parent.left_cursor == i_csr and parent.prereq_right == 0 and parent.n_child == 1) {
                    continue;
                }
            }
            return;
        }

        // Condition (5): the ORDER BY goes to xBestIndex.
        if (order_by) |ob| {
            for (ob.slice()) |*item| {
                const x = item.expr.?;
                if (x.op != TK.COLUMN) return;
                if (x.i_table != i_csr) return;
                if (item.fg.sort_flags & int.KeyInfoOrder.bignull != 0) return;
            }
        }

        const limit = sel.limit.?;
        std.debug.assert(limit.op == TK.LIMIT);
        if (sel.i_offset != 0 and !sel.sel_flags.Compound) {
            try whereAddLimitExpr(wc, sel.i_offset, limit.right, i_csr, INDEX_CONSTRAINT.OFFSET);
        }
        if (sel.i_offset == 0 or !sel.sel_flags.Compound) {
            try whereAddLimitExpr(wc, sel.i_limit, limit.left, i_csr, INDEX_CONSTRAINT.LIMIT);
        }
    }
}

/// Port of sqlite3WhereExprUsageFull(): the out-of-line part of
/// exprUsageNN() for non-leaf expressions.
fn exprUsageFull(ms: *WhereMaskSet, e: *Expr) Bitmask {
    var mask: Bitmask = if (e.op == TK.IF_NULL_ROW) getMask(ms, e.i_table) else 0;
    if (e.left) |l| mask |= exprUsageNN(ms, l);
    if (e.right) |r| {
        mask |= exprUsageNN(ms, r);
        std.debug.assert(e.x.list == null);
    } else if (e.useXSelect()) {
        if (e.flags.VarSelect) ms.b_var_select = true;
        mask |= exprSelectUsage(ms, e.x.select);
    } else if (e.x.list) |l| {
        mask |= exprListUsage(ms, l);
    }
    if ((e.op == TK.FUNCTION or e.op == TK.AGG_FUNCTION) and e.useYWin()) {
        const win = e.y.win.?;
        mask |= exprListUsage(ms, win.partition);
        mask |= exprListUsage(ms, win.order_by);
        mask |= exprUsage(ms, win.filter);
    }
    return mask;
}

/// Port of sqlite3WhereExprUsageNN(): the tables referenced by `e`.
pub fn exprUsageNN(ms: *WhereMaskSet, e: *Expr) Bitmask {
    if (e.op == TK.COLUMN and !e.flags.FixedCol) {
        return getMask(ms, e.i_table);
    } else if (e.flags.intersects(.{ .TokenOnly = true, .Leaf = true })) {
        std.debug.assert(e.op != TK.IF_NULL_ROW);
        return 0;
    }
    return exprUsageFull(ms, e);
}

/// Port of sqlite3WhereExprUsage().
pub fn exprUsage(ms: *WhereMaskSet, e: ?*Expr) Bitmask {
    return if (e) |x| exprUsageNN(ms, x) else 0;
}

/// Port of sqlite3WhereExprListUsage().
pub fn exprListUsage(ms: *WhereMaskSet, list: ?*ExprList) Bitmask {
    var mask: Bitmask = 0;
    if (list) |l| {
        for (l.slice()) |item| mask |= exprUsage(ms, item.expr);
    }
    return mask;
}

/// Port of sqlite3WhereExprAnalyze(): analyze every term, last first, so
/// that the virtual terms added on the end are not analyzed again.
pub fn exprAnalyze(tab_list: *SrcList, wc: *WhereClause) Oom!void {
    var i: i32 = wc.n_term - 1;
    while (i >= 0) : (i -= 1) {
        try exprAnalyzeTerm(tab_list, wc, i);
    }
}

/// Port of sqlite3WhereTabFuncArgs(): turn the arguments of a
/// table-valued function into equality constraints on its HIDDEN columns.
pub fn tabFuncArgs(p: *Parse, item: *SrcItem, wc: *WhereClause) Oom!void {
    if (!item.fg.is_tab_func) return;
    const tab = item.s_tab.?;
    if (!tab.isVirtual()) {
        util.errorMsg(p, "'{s}' is not a function", .{item.name orelse ""});
        return;
    }
    const args = item.u1.func_arg orelse return;
    var k: usize = 0;
    for (args.slice(), 0..) |arg, j| {
        while (k < tab.cols.len and !tab.cols[k].col_flags.HIDDEN) k += 1;
        if (k >= tab.cols.len) {
            util.errorMsg(p, "too many arguments on {s}() - max {d}", .{ tab.name, j });
            return;
        }
        const col_ref = try expr_mod.exprAlloc(p.arena, TK.COLUMN, null, false);
        col_ref.i_table = item.i_cursor;
        col_ref.i_column = @intCast(k);
        k += 1;
        std.debug.assert(col_ref.useYTab());
        col_ref.y = .{ .tab = tab };
        item.col_used |= resolve.exprColUsed(col_ref);
        const rhs = try expr_mod.pExpr(p, TK.UPLUS, try expr_mod.exprDup(p.arena, arg.expr), null);
        const term = try expr_mod.pExpr(p, TK.EQ, col_ref, rhs);
        const join_type: EP = if (item.fg.jointype.intersects(.{ .LEFT = true, .RIGHT = true })) .{ .OuterON = true } else .{ .InnerON = true };
        select_mod.setJoinExpr(term, item.i_cursor, join_type);
        _ = try whereClauseInsert(wc, term, .{ .DYNAMIC = true });
    }
}

/// Port of sqlite3WhereLoopBloomable(): true if `l` can use a Bloom
/// filter (tag-202607231411).
pub fn loopBloomable(l: *const WhereLoop) bool {
    if (l.ws_flags.IPK) return true;
    if (!l.ws_flags.INDEXED) return false;
    return build.indexBloomable(l.btree.index.?, l.btree.n_eq);
}
