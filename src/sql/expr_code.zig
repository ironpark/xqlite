//! Code generation for expressions (the second half of expr.c): values
//! into registers, conditional jumps, IN operators and subqueries.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const expr_mod = @import("expr.zig");
const build = @import("build.zig");
const select_mod = @import("select.zig");
const callback = @import("callback.zig");
const numeric = @import("xqlite_base").numeric;
const coll_mod = @import("coll.zig");
const walker = @import("walker.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const serial = @import("../vdbe/serial.zig");
const ctype = @import("xqlite_base").ctype;
const typing = @import("typing.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Select = int.Select;
const Table = int.Table;
const Column = int.Column;
const Index = int.Index;
const CollSeq = int.CollSeq;
const Vdbe = vi.Vdbe;
const Reg = aux.operand.Reg;
const Cursor = aux.operand.Cursor;
const Label = aux.operand.Label;
const Addr = aux.operand.Addr;
const Jump = aux.operand.Jump;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const TK = int.TK;
const EP = int.EP;
const SF = int.SF;
const Aff = int.Aff;
const OE = int.OE;
const RC = int.RC;
const COLFLAG = int.COLFLAG;
const TF = int.TF;
const FUNC = callback.FUNC;
const Walker = walker.Walker;
const WRC = walker.WRC;
const SRT = select_mod.SRT;

const getTempReg = expr_mod.getTempReg;
const releaseTempReg = expr_mod.releaseTempReg;
const getTempRange = expr_mod.getTempRange;
const releaseTempRange = expr_mod.releaseTempRange;

/// sqlite3ExprCodeExprList() flags (SQLITE_ECEL_*).
pub const ECEL_DUP: u8 = 0x01;
pub const ECEL_FACTOR: u8 = 0x02;
pub const ECEL_REF: u8 = 0x04;
pub const ECEL_OMITREF: u8 = 0x08;

/// sqlite3FindInIndex() results (IN_INDEX_*), numbered as in C.
pub const IN_INDEX = enum(u8) {
    /// Search the rowid of the table.
    ROWID = 1,
    /// Search an ephemeral b-tree.
    EPH = 2,
    /// An existing index, ascending or descending.
    INDEX_ASC = 3,
    INDEX_DESC = 4,
    /// No table: compare with each value of the list.
    NOOP = 5,
};

/// sqlite3FindInIndex() flags (IN_INDEX_*).
pub const IN_INDEX_NOOP_OK: u32 = 0x0001;
pub const IN_INDEX_MEMBERSHIP: u32 = 0x0002;
pub const IN_INDEX_LOOP: u32 = 0x0004;

const JUMPIFNULL = vi.SQLITE_JUMPIFNULL;
const NULLEQ = vi.SQLITE_NULLEQ;

/// ConstFactorOk(): constants may be moved to the initialization code.
fn constFactorOk(p: *const Parse) bool {
    return p.ok_const_factor;
}

/// Record an out-of-memory condition while coding.
fn oom(p: *Parse) void {
    build.oomFault(p);
}

fn vdbe(p: *Parse) *Vdbe {
    return p.vdbe.?;
}

/// A copy of `e` in the statement's memory, or null (with the error
/// recorded) if out of memory.
fn dup(p: *Parse, e: ?*const Expr) ?*Expr {
    return expr_mod.exprDup(p.arena, e) catch {
        oom(p);
        return null;
    };
}

/// Port of codeCompare(): code comparison `opcode` of registers `in1`
/// and `in2`, jumping to `dest` (a Label, an Addr or a Jump) if true. As
/// in C, `opcode` is the TK_ code of the comparison, which numbers its
/// opcode (OP.fromTk()).
fn codeCompare(p: *Parse, left: *Expr, right: *Expr, opcode: u8, in1: Reg, in2: Reg, dest: anytype, jump_if_null: u16, is_commuted: bool) void {
    if (p.n_err != 0) return;
    const p4 = if (is_commuted)
        expr_mod.binaryCompareCollSeq(p, right, left)
    else
        expr_mod.binaryCompareCollSeq(p, left, right);
    const p5 = expr_mod.binaryCompareP5(left, right, jump_if_null);
    _ = aux.emitAny4(vdbe(p), OP.fromTk(opcode), .{ .reg, .jump, .reg }, .{ in2, dest, in1 }, if (p4) |c| .{ .collseq = c } else .notused);
    aux.changeP5(vdbe(p), p5);
}

/// Port of exprCodeSubselect().
fn exprCodeSubselect(p: *Parse, e: *Expr) Reg {
    if (e.op == TK.SELECT) return codeSubselect(p, e);
    return .none;
}

/// Port of exprVectorRegister(): the register of field `field` of a
/// vector, with its expression in `out_expr`.
fn exprVectorRegister(p: *Parse, v: *Expr, field: usize, reg_select: Reg, tmp: *Expr, out_expr: **Expr, reg_free: *Reg) Reg {
    const op = v.op;
    if (op == TK.REGISTER) {
        out_expr.* = expr_mod.vectorFieldSubexpr(v, field);
        return Reg.from(v.i_table).at(field);
    }
    if (op == TK.SELECT) {
        // Wrap the subquery column so its affinity, but not its collation,
        // is used.
        tmp.* = .{ .op = TK.SELECT_COLUMN, .left = v, .i_column = @intCast(field) };
        tmp.i_table = @intCast(v.x.select.?.e_list.?.len());
        out_expr.* = tmp;
        return reg_select.at(field);
    }
    if (op == TK.VECTOR) {
        out_expr.* = v.x.list.?.at(field).expr.?;
        return codeTemp(p, out_expr.*, reg_free);
    }
    return .none;
}

/// Port of codeVectorCompare(): compare two vectors, leaving 1, 0 or NULL
/// in `dest`.
fn codeVectorCompare(p: *Parse, e: *Expr, dest: Reg, op: u8, p5: u16) void {
    const v = vdbe(p);
    const left = e.left.?;
    const right = e.right.?;
    const n_left = expr_mod.vectorSize(left);
    // The comparison of the field before, or the OP_ElseEq after it.
    var addr_cmp: ?Addr = null;
    const done = aux.newLabel(p);
    const is_commuted = e.flags.Commuted;
    if (p.n_err != 0) return;
    if (n_left != expr_mod.vectorSize(right)) {
        util.errorMsg(p, "row value misused", .{});
        return;
    }
    var opx = op;
    if (op == TK.LE) opx = TK.LT;
    if (op == TK.GE) opx = TK.GT;
    if (op == TK.NE) opx = TK.EQ;

    const reg_left = exprCodeSubselect(p, left);
    const reg_right = exprCodeSubselect(p, right);

    _ = aux.emit(v, .Integer, .{ 1, dest });
    var i: usize = 0;
    while (true) : (i += 1) {
        var reg_free1: Reg = .none;
        var reg_free2: Reg = .none;
        var pl: *Expr = undefined;
        var pr: *Expr = undefined;
        var tmp1: Expr = .{ .op = 0 };
        var tmp2: Expr = .{ .op = 0 };
        if (addr_cmp) |a| aux.landHere(v, a);
        const r1 = exprVectorRegister(p, left, i, reg_left, &tmp1, &pl, &reg_free1);
        const r2 = exprVectorRegister(p, right, i, reg_right, &tmp2, &pr, &reg_free2);
        addr_cmp = aux.here(v);
        codeCompare(p, pl, pr, opx, r1, r2, done, p5, is_commuted);
        releaseTempReg(p, reg_free1);
        releaseTempReg(p, reg_free2);
        if ((opx == TK.LT or opx == TK.GT) and i < n_left - 1) {
            addr_cmp = aux.emit(v, .ElseEq, .{});
        }
        if (p5 == NULLEQ) {
            _ = aux.emit(v, .Integer, .{ 0, dest });
        } else {
            _ = aux.emit(v, .ZeroOrNull, .{ r1, dest, r2 });
        }
        if (i == n_left - 1) break;
        if (opx == TK.EQ) {
            _ = aux.emit(v, .NotNull, .{ dest, done });
        } else {
            _ = aux.emit(v, .Goto, .{ 0, done });
            if (i == n_left - 2) opx = op;
        }
    }
    aux.landHere(v, addr_cmp.?);
    aux.place(v, done);
    if (op == TK.NE) _ = aux.emit(v, .Not, .{ dest, dest });
}

/// Port of exprEvalRhsFirst(): only the left operand has a subquery.
fn evalRhsFirst(e: *const Expr) bool {
    return e.left.?.flags.Subquery and !e.right.?.flags.Subquery;
}

/// Port of exprComputeOperands(): code both operands of a binary
/// operator, the one with a subquery last, skipping it (jump returned)
/// if the other is NULL.
fn computeOperands(p: *Parse, e: *Expr, r1: *Reg, r2: *Reg, free1: *Reg, free2: *Reg) ?Addr {
    const v = vdbe(p);
    var addr_is_null: ?Addr = null;
    if (evalRhsFirst(e) and expr_mod.canBeNull(e.right.?)) {
        r2.* = codeTemp(p, e.right, free2);
        addr_is_null = aux.emit(v, .IsNull, .{r2.*});
    }
    r1.* = codeTemp(p, e.left, free1);
    if (addr_is_null == null) {
        if (e.right.?.flags.Subquery and expr_mod.canBeNull(e.left.?)) {
            addr_is_null = aux.emit(v, .IsNull, .{r1.*});
        }
        r2.* = codeTemp(p, e.right, free2);
    }
    return addr_is_null;
}

// ======================================================== IN operator

/// Port of isCandidateForInOpt(): a subquery on the right of IN that
/// reads columns of one table directly, or null.
fn isCandidateForInOpt(x: *const Expr) ?*Select {
    if (!x.useXSelect()) return null;
    if (x.flags.VarSelect) return null;
    const s = x.x.select.?;
    if (s.prior != null) return null;
    if (s.sel_flags.Aggregate) return null;
    if (s.limit != null) return null;
    if (s.where != null) return null;
    const src = s.src.?;
    if (src.len() != 1) return null;
    if (src.at(0).fg.is_subquery) return null;
    const t = src.at(0).s_tab.?;
    if (t.e_tab_type == .vtab) return null;
    for (s.e_list.?.slice()) |item| {
        if (item.expr.?.op != TK.COLUMN) return null;
    }
    return s;
}

/// Port of sqlite3SetHasNullFlag(): leave NULL in `reg` if the first
/// column of `cur` has a NULL, else non-NULL.
fn setHasNullFlag(v: *Vdbe, cur: Cursor, reg: Reg, sort_order: u8) void {
    _ = aux.emit(v, .Integer, .{ 0, reg });
    const addr1 = aux.emitAny(v, if (sort_order == 0) OP.Rewind else OP.Last, .{ .cursor, .jump, .int }, .{cur});
    _ = aux.emit(v, .Column, .{ cur, 0, reg });
    aux.changeP5(v, OPFLAG.TYPEOFARG);
    aux.landHere(v, addr1);
}

/// Port of sqlite3InRhsIsConstant().
fn inRhsIsConstant(p: *Parse, in: *Expr) bool {
    const lhs = in.left;
    in.left = null;
    const res = expr_mod.isConstant(p, in);
    in.left = lhs;
    return res;
}

/// Port of sqlite3FindInIndex(): find or build a b-tree for the right side
/// of IN: the table itself (IN_INDEX.ROWID), an index, or an ephemeral
/// table (IN_INDEX.EPH); IN_INDEX.NOOP means compare against each value.
/// The cursor goes to `tab` (null for IN_INDEX.NOOP), and with
/// `rhs_has_null` a register that is set if the right side may hold a
/// NULL.
pub fn findInIndex(p: *Parse, x: *Expr, in_flags: u32, rhs_has_null_arg: ?*Reg, ai_map: ?[]i32, tab: *?Cursor) IN_INDEX {
    var rhs_has_null = rhs_has_null_arg;
    // Null until chosen (0 in C).
    var e_type: ?IN_INDEX = null;
    const must_be_unique = in_flags & IN_INDEX_LOOP != 0;
    // The cursor of the b-tree; none if there is no b-tree (IN_INDEX.NOOP).
    var tab_cur: ?Cursor = p.newCursor();
    const v = build.getVdbe(p).?;

    // NULLs are impossible if no result column can be NULL.
    if (rhs_has_null != null and x.useXSelect()) {
        for (x.x.select.?.e_list.?.slice()) |item| {
            if (expr_mod.canBeNull(item.expr.?)) break;
        } else rhs_has_null = null;
    }

    // An existing table or index may serve.
    if (p.n_err == 0) if (isCandidateForInOpt(x)) |s| {
        const db = p.db;
        const e_list = s.e_list.?;
        const n_expr = e_list.len();
        const t = s.src.?.at(0).s_tab.?;
        const i_db: usize = @intCast(@import("prepare.zig").schemaToIndex(db, t.schema));
        build.codeVerifySchema(p, i_db);
        build.tableLock(p, i_db, t.tnum, false, t.name);
        if (n_expr == 1 and e_list.at(0).expr.?.i_column < 0) {
            // "x IN (SELECT rowid FROM table)".
            const addr = aux.emit(v, .Once, .{});
            @import("insert.zig").openTable(p, tab_cur.?, i_db, t, OP.OpenRead);
            e_type = .ROWID;
            _ = aux.explain(p, false, "USING ROWID SEARCH ON TABLE {s} FOR IN-OPERATOR", .{t.name});
            aux.landHere(v, addr);
        } else {
            // The comparison affinity must match each column's.
            var affinity_ok = true;
            for (0..n_expr) |i| {
                if (!affinity_ok) break;
                const lhs = expr_mod.vectorFieldSubexpr(x.left.?, i);
                const i_col = e_list.at(i).expr.?.i_column;
                const idxaff = expr_mod.tableColumnAffinity(t, i_col);
                const cmpaff = expr_mod.compareAffinity(lhs, idxaff);
                switch (cmpaff) {
                    Aff.blob, Aff.text => {},
                    else => affinity_ok = expr_mod.isNumericAffinity(idxaff),
                }
            }
            if (affinity_ok) {
                var idx_opt = t.index;
                while (idx_opt) |idx| : (idx_opt = idx.next) {
                    if (e_type != null) break;
                    if (idx.n_column < n_expr) continue;
                    if (idx.part_idx_where != null) continue;
                    if (idx.n_column >= int.bms - 1) continue;
                    if (must_be_unique) {
                        if (idx.n_key_col > n_expr or (idx.n_column > n_expr and !idx.isUnique())) continue;
                    }
                    var col_used: int.Bitmask = 0;
                    var i: usize = 0;
                    while (i < n_expr) : (i += 1) {
                        const lhs = expr_mod.vectorFieldSubexpr(x.left.?, i);
                        const rhs = e_list.at(i).expr.?;
                        const req = expr_mod.binaryCompareCollSeq(p, lhs, rhs);
                        var j: usize = 0;
                        while (j < n_expr) : (j += 1) {
                            if (idx.ai_column[j] != rhs.i_column) continue;
                            if (req) |r| if (!ctype.eqlNoCase(r.name, idx.coll[j])) continue;
                            break;
                        }
                        if (j == n_expr) break;
                        const m_col = @as(int.Bitmask, 1) << @intCast(j);
                        if (m_col & col_used != 0) break;
                        col_used |= m_col;
                        if (ai_map) |m| m[i] = @intCast(j);
                    }
                    if (col_used == (@as(int.Bitmask, 1) << @intCast(n_expr)) - 1) {
                        const addr = aux.emit(v, .Once, .{});
                        _ = aux.explain(p, false, "USING INDEX {s} FOR IN-OPERATOR", .{idx.name});
                        _ = aux.emit(v, .OpenRead, .{ tab_cur.?, idx.tnum, i_db });
                        aux.setP4KeyInfo(p, idx);
                        e_type = if (idx.sort_order[0] == int.SortOrder.desc) .INDEX_DESC else .INDEX_ASC;
                        if (rhs_has_null) |r| {
                            r.* = p.newReg();
                            if (n_expr == 1) setHasNullFlag(v, tab_cur.?, r.*, idx.sort_order[0]);
                        }
                        aux.landHere(v, addr);
                    }
                }
            }
        }
    };

    // A short or non-constant list is not worth a b-tree.
    if (e_type == null and in_flags & IN_INDEX_NOOP_OK != 0 and x.useXList() and
        (!inRhsIsConstant(p, x) or x.x.list.?.len() <= 2))
    {
        p.n_tab -= 1;
        tab_cur = null;
        e_type = .NOOP;
    }

    if (e_type == null) {
        // Build an ephemeral table.
        const saved_n_query_loop = p.n_query_loop;
        var r_may_have_null: Reg = .none;
        var bloom_ok = in_flags & IN_INDEX_MEMBERSHIP != 0;
        e_type = .EPH;
        if (in_flags & IN_INDEX_LOOP != 0) {
            p.n_query_loop = 0;
        } else if (rhs_has_null) |r| {
            r_may_have_null = p.newReg();
            r.* = r_may_have_null;
        }
        if (!bloom_ok and x.useXSelect() and x.x.select.?.sel_flags.ClonedRhsIn) bloom_ok = true;
        codeRhsOfIN(p, x, tab_cur.?, bloom_ok);
        if (!r_may_have_null.isNone()) setHasNullFlag(v, tab_cur.?, r_may_have_null, 0);
        p.n_query_loop = saved_n_query_loop;
    }

    if (ai_map) |m| if (e_type.? != .INDEX_ASC and e_type.? != .INDEX_DESC) {
        for (m[0..expr_mod.vectorSize(x.left.?)], 0..) |*a, i| a.* = @intCast(i);
    };
    tab.* = tab_cur;
    return e_type.?;
}

/// Port of exprINAffinity(): the comparison affinity of each column of an
/// IN operator.
fn exprINAffinity(p: *Parse, e: *const Expr) ?[]u8 {
    const left = e.left.?;
    const n_val = expr_mod.vectorSize(left);
    const sel: ?*Select = if (e.useXSelect()) e.x.select else null;
    const ret = p.arena.alloc(u8, n_val) catch {
        oom(p);
        return null;
    };
    for (ret, 0..) |*r, i| {
        const a = expr_mod.affinity(expr_mod.vectorFieldSubexpr(left, i));
        r.* = if (sel) |s| expr_mod.compareAffinity(s.e_list.?.at(i).expr.?, a) else a;
    }
    return ret;
}

/// Port of findCompatibleInRhsSubrtn(): reuse an earlier identical IN
/// subroutine.
fn findCompatibleInRhsSubrtn(p: *Parse, e: *Expr, new_sig: ?*vi.SubrtnSig) bool {
    const sig_new = new_sig orelse return false;
    const v = vdbe(p);
    const ops = v.ops.items;
    if (ops.len < 2) return false;
    for (ops[1 .. ops.len - 1]) |*op| {
        if (op.p4type != .subrtnsig) continue;
        const sig = op.p4.subrtnsig;
        if (!sig.complete) continue;
        if (sig_new.sel_id != sig.sel_id) continue;
        if (!std.mem.eql(u8, sig_new.aff orelse "", sig.aff orelse "")) continue;
        e.y = .{ .sub = .{ .addr = sig.i_addr, .reg_return = sig.reg_return } };
        e.i_table = sig.i_table;
        e.flags.Subrtn = true;
        return true;
    }
    return false;
}

/// Port of sqlite3CodeRhsOfIN(): code the ephemeral table holding the
/// right side of an IN operator (once, as a subroutine, unless it is
/// correlated or not constant).
pub fn codeRhsOfIN(p: *Parse, e: *Expr, tab_cur: Cursor, allow_bloom_arg: bool) void {
    var allow_bloom = allow_bloom_arg;
    const v = vdbe(p);
    // The OP_Once of a right side that is computed once.
    var addr_once: ?Addr = null;
    var sig: ?*vi.SubrtnSig = null;

    if (!e.flags.VarSelect and p.i_self_tab == 0) {
        // The result can be computed once and reused.
        if (e.useXSelect() and !e.x.select.?.sel_flags.All) {
            if (v.alloc().create(vi.SubrtnSig) catch null) |s| {
                const aff = exprINAffinity(p, e);
                s.* = .{ .sel_id = @intCast(e.x.select.?.sel_id), .aff = if (aff) |a| v.alloc().dupeSentinel(u8, a, 0) catch null else null };
                sig = s;
            }
        }
        if (e.flags.Subrtn or findCompatibleInRhsSubrtn(p, e, sig)) {
            const once = aux.emit(v, .Once, .{});
            if (e.useXSelect()) _ = aux.explain(p, false, "REUSE LIST SUBQUERY {d}", .{e.x.select.?.sel_id});
            _ = aux.emit(v, .Gosub, .{ e.y.sub.reg_return, e.y.sub.addr });
            _ = aux.emit(v, .OpenDup, .{ tab_cur, Cursor.from(e.i_table) });
            aux.landHere(v, once);
            return;
        }
        // Begin the subroutine.
        e.flags.Subrtn = true;
        const reg_return = p.newReg();
        e.y = .{ .sub = .{ .reg_return = reg_return, .addr = aux.emit(v, .BeginSubrtn, .{ 0, reg_return }).plus(1) } };
        if (sig) |s| {
            s.complete = false;
            s.i_addr = e.y.sub.addr;
            s.reg_return = e.y.sub.reg_return;
            s.i_table = tab_cur.int();
            aux.changeP4(v, null, .{ .subrtnsig = s });
        }
        addr_once = aux.emit(v, .Once, .{});
    }

    const left = e.left.?;
    const n_val = expr_mod.vectorSize(left);

    e.i_table = tab_cur.int();
    const addr = aux.emit(v, .OpenEphemeral, .{ tab_cur, n_val });
    var key_info_opt = select_mod.keyInfoAlloc(p, n_val, 1);
    if (key_info_opt == null) return;

    if (e.useXSelect()) {
        // expr IN (SELECT ...): the results go into the table.
        const sel = e.x.select.?;
        const e_list = sel.e_list.?;
        _ = aux.explain(p, true, "{s}LIST SUBQUERY {d}", .{ if (addr_once != null) "" else "CORRELATED ", sel.sel_id });
        if (e_list.len() == n_val) {
            var dest = select_mod.selectDestInit(SRT.Set, .{ .cursor = tab_cur });
            dest.aff_sdst = exprINAffinity(p, e);
            sel.i_limit = .none;
            const key_info = key_info_opt.?;
            for (0..n_val) |i| {
                const x = expr_mod.vectorFieldSubexpr(left, i);
                const c = expr_mod.binaryCompareCollSeq(p, x, e_list.at(i).expr.?);
                key_info.coll[i] = c;
                if (!serial.isBinary(c)) allow_bloom = false;
            }
            // The OP_Blob that makes the Bloom filter, if there is one.
            var addr_bloom: ?Addr = null;
            if (addr_once != null and allow_bloom and !p.db.optDisabled(int.OPT.BloomFilter)) {
                const reg_bloom = p.newReg();
                addr_bloom = aux.emit(v, .Blob, .{ 10000, reg_bloom });
                dest.reg_bloom = reg_bloom;
                aux.changeP4(v, addr, .{ .keyinfo = key_info });
                key_info_opt = null;
            }
            const copy = expr_mod.selectDup(p.arena, sel) catch {
                oom(p);
                return;
            };
            const rc = select_mod.select(p, copy.?, &dest);
            if (addr_bloom) |bloom| {
                // The Bloom filter's register goes in P3 of the OP_Once.
                aux.getOp(v, addr_once.?).p3 = dest.reg_bloom.int();
                if (dest.reg_bloom.isNone()) aux.getOp(v, bloom).p1 = 10;
            }
            rc catch return;
        }
    } else if (e.x.list) |list| {
        // expr IN (exprlist): insert each value with the left side's
        // affinity (or none).
        var aff = expr_mod.affinity(left);
        if (aff <= Aff.none) {
            aff = Aff.blob;
        } else if (aff == Aff.real) {
            aff = Aff.numeric;
        }
        key_info_opt.?.coll[0] = expr_mod.inCollSeq(p, e.left);
        const r1 = getTempReg(p);
        const r2 = getTempReg(p);
        const aff_str = [1]u8{aff};
        for (list.slice()) |item| {
            const e2 = item.expr.?;
            // A non-constant value must be recomputed each time.
            if (addr_once) |once| if (!expr_mod.isConstant(p, e2)) {
                _ = aux.changeToNoop(v, once.plus(-1));
                _ = aux.changeToNoop(v, once);
                e.flags.Subrtn = false;
                addr_once = null;
            };
            exprCode(p, e2, r1);
            _ = aux.emitStr(v, .MakeRecord, .{ r1, 1, r2 }, &aff_str);
            _ = aux.emitInt(v, .IdxInsert, .{ tab_cur, r2, r1 }, 1);
        }
        releaseTempReg(p, r1);
        releaseTempReg(p, r2);
    }
    if (sig) |s| s.complete = true;
    if (key_info_opt) |k| aux.changeP4(v, addr, .{ .keyinfo = k });
    if (addr_once) |once| {
        _ = aux.emit(v, .NullRow, .{tab_cur});
        aux.landHere(v, once);
        // Subroutine return.
        _ = aux.emit(v, .Return, .{ e.y.sub.reg_return, e.y.sub.addr, 1 });
        expr_mod.clearTempRegCache(p);
    }
}

/// Port of sqlite3CodeSubselect(): code a scalar subquery or EXISTS once
/// (as a subroutine); returns the register of its (first) result, or 0
/// on error.
pub fn codeSubselect(p: *Parse, e: *Expr) Reg {
    const v = vdbe(p);
    if (p.n_err != 0) return .none;
    const sel = e.x.select.?;

    // Already coded: call the subroutine.
    if (e.flags.Subrtn) {
        _ = aux.explain(p, false, "REUSE SUBQUERY {d}", .{sel.sel_id});
        _ = aux.emit(v, .Gosub, .{ e.y.sub.reg_return, e.y.sub.addr });
        return .from(e.i_table);
    }

    // Begin the subroutine.
    e.flags.Subrtn = true;
    const reg_return = p.newReg();
    e.y = .{ .sub = .{ .reg_return = reg_return, .addr = aux.emit(v, .BeginSubrtn, .{ 0, reg_return }).plus(1) } };

    // An uncorrelated subquery runs once.
    const addr_once: ?Addr = if (!e.flags.VarSelect) aux.emit(v, .Once, .{}) else null;
    const addr_explain = aux.explain(p, true, "{s}SCALAR SUBQUERY {d}", .{ if (addr_once != null) "" else "CORRELATED ", sel.sel_id });
    aux.scanStatusCounters(v, addr_explain, addr_explain, null);

    // The first row of a SELECT goes into registers; EXISTS leaves 0 or 1.
    // Either way the query gets LIMIT 1.
    const n_reg: i32 = if (e.op == TK.SELECT) @intCast(sel.e_list.?.len()) else 1;
    const result = p.newRegs(n_reg);
    var dest = select_mod.selectDestInit(undefined, .{ .reg = result }); // e_dest set below (0 in C)
    if (e.op == TK.SELECT) {
        dest.e_dest = SRT.Mem;
        if (sel.sel_flags.Distinct and sel.limit != null and sel.limit.?.right != null) {
            // With DISTINCT and OFFSET, results are copied over only
            // after the OFFSET.
            dest.i_sdst = p.newRegs(n_reg);
        } else {
            dest.i_sdst = result;
        }
        dest.n_sdst = n_reg;
        _ = aux.emit(v, .Null, .{ 0, result, Reg.from(p.n_mem) });
    } else {
        dest.e_dest = SRT.Exists;
        _ = aux.emit(v, .Integer, .{ 0, result });
    }
    if (sel.limit) |lim| {
        // A limit X other than 0 or 1 becomes X<>0.
        const left = lim.left.?;
        if (!left.flags.IntValue or (left.u.value != 1 and left.u.value != 0)) {
            const zero = expr_mod.exprInt32(p.arena, 0) catch return oomZero(p);
            zero.aff_expr = Aff.numeric;
            lim.left = expr_mod.pExpr(p, TK.NE, dup(p, left), zero) catch return oomZero(p);
        }
    } else {
        const one = expr_mod.exprInt32(p.arena, 1) catch return oomZero(p);
        sel.limit = expr_mod.pExpr(p, TK.LIMIT, one, null) catch return oomZero(p);
    }
    sel.i_limit = .none;
    select_mod.select(p, sel, &dest) catch {
        e.op2 = e.op;
        e.op = TK.ERROR;
        return .none;
    };
    const r_reg = dest.parm.reg;
    e.i_table = r_reg.int();
    if (addr_once) |once| aux.landHere(v, once);
    if (addr_explain) |a| aux.scanStatusRange(v, a, .{ .span = .{ .start = a } });

    if (dest.e_dest == SRT.Mem and canReturnSubtype(p, sel.e_list.?.at(0).expr)) {
        _ = aux.emit(v, .ClrSubtype, .{r_reg});
    }

    // Subroutine return.
    _ = aux.emit(v, .Return, .{ e.y.sub.reg_return, e.y.sub.addr, 1 });
    expr_mod.clearTempRegCache(p);
    return r_reg;
}

fn oomZero(p: *Parse) Reg {
    oom(p);
    return .none;
}

/// Port of sqlite3ExprCodeIN(): code "x IN (...)": jump to
/// `dest_if_false` if the left side is not in the set, to `dest_if_null`
/// if NULLs make that unknown, and fall through if it is. Each is a
/// Label, an Addr or a Jump.
inline fn codeIN(p: *Parse, e: *Expr, dest_if_false: anytype, dest_if_null: anytype) void {
    codeINJump(p, e, Jump.of(dest_if_false), Jump.of(dest_if_null));
}

/// codeIN() on Jumps: the one body.
fn codeINJump(p: *Parse, e: *Expr, dest_if_false: Jump, dest_if_null: Jump) void {
    var r_rhs_has_null: Reg = .none;
    const ok_const_factor = p.ok_const_factor;
    const left = e.left.?;
    if (expr_mod.checkIN(p, e)) return;
    const zaff = exprINAffinity(p, e) orelse return;
    const n_vector = expr_mod.vectorSize(left);
    const ai_map = p.arena.alloc(i32, n_vector) catch return oom(p);
    @memset(ai_map, 0);
    const v = vdbe(p);
    var tab_opt: ?Cursor = null;
    const e_type = findInIndex(
        p,
        e,
        IN_INDEX_MEMBERSHIP | IN_INDEX_NOOP_OK,
        if (dest_if_false == dest_if_null) null else &r_rhs_has_null,
        ai_map,
        &tab_opt,
    );

    // The left side, in registers. It is not factored out, as
    // OP_Affinity may be applied to it below.
    p.ok_const_factor = false;
    var dummy: Reg = .none;
    var r_lhs = exprCodeVector(p, left, &dummy);
    p.ok_const_factor = ok_const_factor;

    // Without a b-tree, compare with each value in turn.
    if (e_type == .NOOP) {
        const list = e.x.list.?;
        const coll = expr_mod.inCollSeq(p, e.left);
        const label_ok = aux.newLabel(p);
        // NULL if any of the values compared is NULL, if that matters.
        var reg_ck_null: Reg = .none;
        if (dest_if_null != dest_if_false) {
            reg_ck_null = getTempReg(p);
            _ = aux.emit(v, .BitAnd, .{ r_lhs, r_lhs, reg_ck_null });
        }
        for (list.slice(), 0..) |item, ii| {
            var reg_to_free: Reg = .none;
            const r2: Reg = codeTemp(p, item.expr, &reg_to_free);
            if (!reg_ck_null.isNone() and expr_mod.canBeNull(item.expr.?)) {
                _ = aux.emit(v, .BitAnd, .{ reg_ck_null, r2, reg_ck_null });
            }
            releaseTempReg(p, reg_to_free);
            const p4: vi.P4 = if (coll) |c| .{ .collseq = c } else .notused;
            // A value that is the left side itself is in if it is not
            // NULL. OP_NotNull and OP_IsNull do not read P3; it is left
            // as the comparison would have it.
            if (ii < list.len() - 1 or dest_if_null != dest_if_false) {
                _ = if (r_lhs != r2)
                    aux.emit4(v, .Eq, .{ r_lhs, label_ok, r2 }, p4)
                else
                    aux.emit4(v, .NotNull, .{ r_lhs, label_ok, r2.int() }, p4);
                aux.changeP5(v, zaff[0]);
            } else {
                _ = if (r_lhs != r2)
                    aux.emit4(v, .Ne, .{ r_lhs, dest_if_false, r2 }, p4)
                else
                    aux.emit4(v, .IsNull, .{ r_lhs, dest_if_false, r2.int() }, p4);
                aux.changeP5(v, @as(u16, zaff[0]) | JUMPIFNULL);
            }
        }
        if (!reg_ck_null.isNone()) {
            _ = aux.emit(v, .IsNull, .{ reg_ck_null, dest_if_null });
            _ = aux.emit(v, .Goto, .{ 0, dest_if_false });
        }
        aux.place(v, label_ok);
        releaseTempReg(p, reg_ck_null);
        return;
    }
    // findInIndex() gives a cursor for every IN_INDEX but NOOP.
    const tab_cur = tab_opt.?;

    if (e_type != .ROWID) {
        // Apply affinity, then reorder the left side to the index's
        // column order.
        if (n_vector == 1) {
            const a = zaff[0];
            if (a >= Aff.text and a != expr_mod.affinity(left)) {
                // Work on a copy, which OP_Affinity may change.
                const r_tmp = getTempReg(p);
                _ = aux.emit(v, .Copy, .{ r_lhs, r_tmp, 0 });
                r_lhs = r_tmp;
                _ = aux.emitStr(v, .Affinity, .{ r_lhs, 1 }, zaff[0..1]);
            }
        } else {
            _ = aux.emitStr(v, .Affinity, .{ r_lhs, n_vector }, zaff);
        }
        var i: usize = 0;
        while (i < n_vector and ai_map[i] == i) i += 1;
        if (i != n_vector) {
            const r_lhs_orig = r_lhs;
            r_lhs = getTempRange(p, n_vector);
            for (0..n_vector) |k| {
                _ = aux.emit(v, .Copy, .{ r_lhs_orig.at(k), r_lhs.at(ai_map[k]), 0 });
            }
        }
    }

    // Step 2: a NULL on the left means the result is FALSE or NULL.
    var dest_step6: ?Label = null;
    const dest_step2 = if (dest_if_null == dest_if_false) dest_if_false else blk: {
        const step6 = aux.newLabel(p);
        dest_step6 = step6;
        break :blk Jump.of(step6);
    };
    for (0..n_vector) |i| {
        const x = expr_mod.vectorFieldSubexpr(left, i);
        if (p.n_err != 0) return;
        if (expr_mod.canBeNull(x)) {
            _ = aux.emit(v, .IsNull, .{ r_lhs.at(ai_map[i]), dest_step2 });
        }
    }

    // Step 3: search the right side.
    var addr_truth_op: Addr = undefined;
    if (e_type == .ROWID) {
        // Steps 3 and 4 together: a rowid is never NULL.
        _ = aux.emit(v, .SeekRowid, .{ tab_cur, dest_if_false, r_lhs });
        addr_truth_op = aux.emit(v, .Goto, .{});
    } else {
        if (dest_if_false == dest_if_null) {
            // Steps 3 and 5 together.
            if (e.flags.Subrtn) {
                const op = aux.getOp(v, e.y.sub.addr);
                if (op.p3 > 0) {
                    _ = aux.emitInt(v, .Filter, .{ Reg.from(op.p3), dest_if_false, r_lhs }, @intCast(n_vector));
                }
            }
            _ = aux.emitInt(v, .NotFound, .{ tab_cur, dest_if_false, r_lhs }, @intCast(n_vector));
            return;
        }
        addr_truth_op = aux.emitInt(v, .Found, .{ tab_cur, 0, r_lhs }, @intCast(n_vector));
    }

    // Step 4: not found and no NULLs on the right means FALSE.
    if (!r_rhs_has_null.isNone() and n_vector == 1) {
        _ = aux.emit(v, .NotNull, .{ r_rhs_has_null, dest_if_false });
    }

    // Step 5.
    if (dest_if_false == dest_if_null) _ = aux.emit(v, .Goto, .{ 0, dest_if_false });

    // Step 6: compare with each row; any NULL comparison means NULL.
    if (dest_step6) |step6| aux.place(v, step6);
    const addr_top = if (e_type == .INDEX_DESC)
        aux.emit(v, .Last, .{ tab_cur, dest_if_false })
    else
        aux.emit(v, .Rewind, .{ tab_cur, dest_if_false });
    // With a vector, a row that differs is passed over.
    const next_row: ?Label = if (n_vector > 1) aux.newLabel(p) else null;
    const dest_not_null = if (next_row) |l| Jump.of(l) else dest_if_false;
    for (0..n_vector) |i| {
        const r3 = getTempReg(p);
        const x = expr_mod.vectorFieldSubexpr(left, i);
        const coll = if (e.useXSelect())
            expr_mod.binaryCompareCollSeq(p, x, e.x.select.?.e_list.?.at(i).expr.?)
        else
            expr_mod.inCollSeq(p, x);
        _ = aux.emit(v, .Column, .{ tab_cur, ai_map[i], r3 });
        _ = aux.emit4(v, .Ne, .{ r_lhs.at(ai_map[i]), dest_not_null, r3 }, if (coll) |c| .{ .collseq = c } else .notused);
        releaseTempReg(p, r3);
    }
    _ = aux.emit(v, .Goto, .{ 0, dest_if_null });
    if (next_row) |l| {
        aux.place(v, l);
        _ = aux.emit(v, .Next, .{ tab_cur, addr_top.plus(1) });
        // Step 7: FALSE.
        _ = aux.emit(v, .Goto, .{ 0, dest_if_false });
    }
    aux.landHere(v, addr_truth_op);
}

// ============================================================ values

/// Port of codeReal(): load the floating point literal `z`.
fn codeReal(v: *Vdbe, z: [:0]const u8, negate: bool, mem: Reg) void {
    var value: f64 = 0;
    _ = numeric.atoF(z.ptr, &value);
    if (negate) value = -value;
    _ = aux.addDouble(v, mem, value);
}

/// Port of codeInteger(): load an integer literal; too large ones become
/// REAL (hex ones are an error).
fn codeInteger(p: *Parse, e: *Expr, neg: bool, mem: Reg) void {
    const v = vdbe(p);
    if (e.flags.IntValue) {
        var i = e.u.value;
        if (neg) i = -i;
        _ = aux.emit(v, .Integer, .{ i, mem });
        return;
    }
    const z = e.token();
    var value: i64 = 0;
    const c = util.decOrHexToI64(z, &value);
    if ((c == .min_magnitude and !neg) or c == .overflow or (neg and value == std.math.minInt(i64))) {
        if (z.len >= 2 and ctype.eqlNoCase(z[0..2], "0x")) {
            util.errorMsg(p, "hex literal too big: {s}{s}", .{ if (neg) "-" else "", z });
            expr_mod.recordErrorOffsetOfExpr(p, e);
        } else {
            codeReal(v, z, neg, mem);
        }
    } else {
        if (neg) value = if (c == .min_magnitude) std.math.minInt(i64) else -value;
        _ = aux.addInt64(v, mem, value);
    }
}

/// Port of sqlite3ExprCodeLoadIndexColumn(): load column `i_idx_col` of
/// `idx` for the table row under cursor `i_tab_cur`.
pub fn codeLoadIndexColumn(p: *Parse, idx: *Index, tab_cur: Cursor, i_idx_col: usize, out: Reg) void {
    const i_tab_col = idx.ai_column[i_idx_col];
    if (i_tab_col == int.XN_EXPR) {
        p.i_self_tab = tab_cur.int() + 1;
        codeCopy(p, idx.col_expr.?.at(i_idx_col).expr, out);
        p.i_self_tab = 0;
    } else {
        codeGetColumnOfTable(vdbe(p), idx.table, tab_cur, i_tab_col, out);
    }
}

/// Port of sqlite3ExprCodeGeneratedColumn(): compute generated column
/// `col` into `reg_out`.
pub fn codeGeneratedColumn(p: *Parse, t: *Table, col: *Column, out: Reg) void {
    const v = vdbe(p);
    const n_err = p.n_err;
    std.debug.assert(p.i_self_tab != 0);
    // The row is read from a cursor: its columns are NULL on a NULL row.
    const addr: ?Addr = if (p.i_self_tab > 0) aux.emit(v, .IfNullRow, .{ Cursor.from(p.i_self_tab - 1), 0, out }) else null;
    codeCopy(p, build.columnExpr(t, col), out);
    if (col.col_flags.VIRTUAL and t.tab_flags.Strict) {
        const idx = (@intFromPtr(col) - @intFromPtr(t.cols.ptr)) / @sizeOf(Column);
        _ = aux.emit4(v, .TypeCheck, .{ out, 1, 2 + @as(i32, @intCast(idx)) }, .{ .table = t });
    } else if (col.affinity >= Aff.text) {
        _ = aux.emitStr(v, .Affinity, .{ out, 1 }, &[1]u8{col.affinity});
    }
    if (addr) |a| aux.landHere(v, a);
    if (p.n_err > n_err) p.db.err_byte_offset = -1;
}

/// Port of sqlite3ExprCodeGetColumnOfTable(): load column `i_col` of the
/// row under cursor `i_tab_cur` (the PRIMARY KEY cursor for WITHOUT
/// ROWID tables).
pub fn codeGetColumnOfTable(v: *Vdbe, t: *Table, tab_cur: Cursor, i_col: i32, out: Reg) void {
    std.debug.assert(i_col != int.XN_EXPR);
    if (i_col < 0 or i_col == t.i_pkey) {
        _ = aux.emit(v, .Rowid, .{ tab_cur, out });
        return;
    }
    const col = &t.cols[@intCast(i_col)];
    var x: i32 = undefined;
    if (t.e_tab_type == .vtab) {
        _ = aux.emit(v, .VColumn, .{ tab_cur, i_col, out });
        return;
    } else if (col.col_flags.VIRTUAL) {
        const p = v.parse.?;
        if (col.col_flags.BUSY) {
            util.errorMsg(p, "generated column loop on \"{s}\"", .{col.name()});
        } else {
            const saved_self_tab = p.i_self_tab;
            col.col_flags.BUSY = true;
            p.i_self_tab = tab_cur.int() + 1;
            codeGeneratedColumn(p, t, col, out);
            p.i_self_tab = saved_self_tab;
            col.col_flags.BUSY = false;
        }
        return;
    } else if (!t.hasRowid()) {
        x = build.tableColumnToIndex(build.primaryKeyIndex(t).?, i_col);
    } else {
        x = build.tableColumnToStorage(t, @intCast(i_col));
    }
    _ = aux.emit(v, .Column, .{ tab_cur, x, out });
    @import("update.zig").columnDefault(v, t, i_col, out);
}

/// Port of sqlite3ExprCodeGetColumn(): load column `i_column` of `t`
/// (cursor `i_table`) into `i_reg`, with P5 flags of OP_Column.
pub fn codeGetColumn(p: *Parse, t: *Table, i_column: i32, table: Cursor, reg: Reg, p5: u8) Reg {
    const v = vdbe(p);
    codeGetColumnOfTable(v, t, table, i_column, reg);
    if (p5 != 0) {
        const op = aux.getLastOp(v);
        if (op.opcode == OP.Column) op.p5 = p5;
        if (op.opcode == OP.VColumn) op.p5 = p5 & @as(u8, @intCast(OPFLAG.NOCHNG));
    }
    return reg;
}

/// Port of sqlite3ExprCodeMove().
pub fn codeMove(p: *Parse, from: Reg, to: Reg, n_reg: i32) void {
    _ = aux.emit(vdbe(p), .Move, .{ from, to, n_reg });
}

/// Port of exprCodeVector(): code a scalar or vector into consecutive
/// registers; returns the first, with a freeable temporary in `freeable`.
fn exprCodeVector(p: *Parse, e: *Expr, freeable: *Reg) Reg {
    const n_result = expr_mod.vectorSize(e);
    if (n_result == 1) return codeTemp(p, e, freeable);
    freeable.* = .none;
    if (e.op == TK.SELECT) return codeSubselect(p, e);
    const result = p.newRegs(n_result);
    for (e.x.list.?.slice(), 0..) |item, i| codeFactorable(p, item.expr, result.at(i));
    return result;
}

/// Port of setDoNotMergeFlagOnCopy().
fn setDoNotMergeFlagOnCopy(v: *Vdbe) void {
    if (aux.getLastOp(v).opcode == OP.Copy) aux.changeP5(v, 1);
}

/// Port of exprCodeInlineFunction(): coalesce(), iif() and friends,
/// coded inline.
fn codeInlineFunction(p: *Parse, farg: *ExprList, func_id: usize, target_arg: Reg) Reg {
    var target = target_arg;
    const v = vdbe(p);
    const n_farg = farg.len();
    switch (func_id) {
        expr_mod.INLINEFUNC_coalesce => {
            // Stop at the first non-NULL argument.
            const end_coalesce = aux.newLabel(p);
            exprCode(p, farg.at(0).expr, target);
            for (farg.slice()[1..]) |item| {
                _ = aux.emit(v, .NotNull, .{ target, end_coalesce });
                exprCode(p, item.expr, target);
            }
            setDoNotMergeFlagOnCopy(v);
            aux.place(v, end_coalesce);
        },
        expr_mod.INLINEFUNC_iif => {
            var case_expr: Expr = .{ .op = TK.CASE, .x = .{ .list = farg } };
            return codeTarget(p, &case_expr, target);
        },
        expr_mod.INLINEFUNC_expr_compare => {
            _ = aux.emit(v, .Integer, .{ expr_mod.compare(null, farg.at(0).expr, farg.at(1).expr, -1), target });
        },
        expr_mod.INLINEFUNC_expr_implies_expr => {
            _ = aux.emit(v, .Integer, .{ @intFromBool(expr_mod.impliesExpr(p, farg.at(0).expr.?, farg.at(1).expr.?, -1)), target });
        },
        expr_mod.INLINEFUNC_implies_nonnull_row => {
            const a1 = farg.at(1).expr.?;
            if (a1.op == TK.COLUMN) {
                _ = aux.emit(v, .Integer, .{ @intFromBool(expr_mod.impliesNonNullRow(farg.at(0).expr, a1.i_table, true)), target });
            } else {
                _ = aux.emit(v, .Null, .{ 0, target });
            }
        },
        expr_mod.INLINEFUNC_affinity => {
            const names = [_][]const u8{ "blob", "text", "numeric", "integer", "real", "flexnum" };
            const aff = expr_mod.affinity(farg.at(0).expr.?);
            _ = aux.loadString(v, target, if (aff <= Aff.none) "none" else names[aff - Aff.blob]);
        },
        else => {
            // unlikely() and friends: the value of the first argument.
            std.debug.assert(n_farg == 1 or n_farg == 2);
            target = codeTarget(p, farg.at(0).expr, target);
        },
    }
    return target;
}

fn nodeCanReturnSubtype(w: *Walker, e: *Expr) WRC {
    if (e.op == TK.CASE or e.op == TK.UPLUS or e.op == TK.COLLATE or e.op == TK.CAST) return WRC.Continue;
    if (e.op != TK.FUNCTION and e.op != TK.AGG_FUNCTION) return WRC.Prune;
    const db = w.parse.?.db;
    const n: i32 = if (e.x.list) |l| @intCast(l.len()) else 0;
    const def = callback.findFunction(db, e.token(), n, db.enc, false) orelse return WRC.Continue;
    if (def.func_flags.RESULT_SUBTYPE) {
        w.e_code = 1;
        return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of sqlite3ExprCanReturnSubtype(): `e` might return a value with a
/// subtype.
pub fn canReturnSubtype(p: *Parse, e: ?*Expr) bool {
    var w: Walker = .{ .parse = p, .expr_callback = nodeCanReturnSubtype };
    _ = walker.walkExpr(&w, e);
    return w.e_code != 0;
}

/// Port of exprCodeTargetAndOr(): AND or OR into `target`, short-circuit
/// where a subquery can be skipped.
fn codeTargetAndOr(p: *Parse, e: *Expr, target: Reg, tmp_reg: *Reg) Reg {
    const op = e.op;
    const v = vdbe(p);
    const alt = expr_mod.simplifiedAndOr(e);
    if (alt != e) {
        const r1: Reg = codeTarget(p, alt, target);
        _ = aux.emit(v, .And, .{ r1, r1, target });
        return target;
    }
    const skip_op: OP = if (op == TK.AND) OP.IfNot else OP.If;
    const skip_shape = .{ .reg, .jump, .int };
    // The jump over the other side, and the register that decided it.
    var addr_skip: ?Addr = null;
    var reg_ss: Reg = .none;
    var r1: Reg = undefined;
    var r2: Reg = undefined;
    if (evalRhsFirst(e)) {
        // The right side first; it may decide the result alone.
        r2 = codeTarget(p, e.right, target);
        reg_ss = r2;
        addr_skip = aux.emitAny(v, skip_op, skip_shape, .{r2});
        r1 = codeTemp(p, e.left, tmp_reg);
    } else {
        r1 = codeTarget(p, e.left, target);
        if (e.right.?.flags.Subquery) {
            reg_ss = r1;
            addr_skip = aux.emitAny(v, skip_op, skip_shape, .{r1});
        }
        r2 = codeTemp(p, e.right, tmp_reg);
    }
    _ = aux.emitAny(v, OP.fromTk(op), .{ .reg, .reg, .reg }, .{ r2, r1, target });
    if (addr_skip) |skip| {
        _ = aux.emit(v, .Goto, .{ 0, aux.here(v).plus(2) });
        aux.landHere(v, skip);
        _ = aux.emit(v, .Or, .{ reg_ss, reg_ss, target });
    }
    return target;
}

/// Port of sqlite3IndexedExprLookup(): if `e` is one of the indexed
/// expressions of Parse.idx_epr, code reading it from the index into
/// `target` and return `target`; else null.
fn indexedExprLookup(p: *Parse, e: *Expr, target: Reg) ?Reg {
    var it = p.idx_epr;
    while (it) |ie| : (it = ie.next) {
        var i_data_cur = ie.i_data_cur;
        if (i_data_cur < 0) continue;
        if (p.i_self_tab != 0) {
            if (ie.i_data_cur != p.i_self_tab - 1) continue;
            i_data_cur = -1;
        }
        if (expr_mod.compare(null, e, ie.expr, i_data_cur) != 0) continue;
        const expr_aff = expr_mod.affinity(e);
        if ((expr_aff <= Aff.blob and ie.aff != Aff.blob) or
            (expr_aff == Aff.text and ie.aff != Aff.text) or
            (expr_aff >= Aff.numeric and ie.aff != Aff.numeric))
        {
            // Affinity mismatch on a generated column.
            continue;
        }
        // A function that might set a subtype keeps being computed if it
        // is itself an argument of another function.
        if (e.flags.SubtArg and canReturnSubtype(p, e)) continue;

        const v = vdbe(p);
        if (ie.b_maybe_null_row or expr_mod.isConstant(p, e)) {
            // Compute the value from the expression if the index might be
            // on the NULL row of an outer join, or if it is a constant
            // (which might be used outside the loop that positions the
            // index).
            const addr = aux.here(v);
            _ = aux.emit(v, .IfNullRow, .{ Cursor.from(ie.i_idx_cur), addr.plus(3), target });
            _ = aux.emit(v, .Column, .{ Cursor.from(ie.i_idx_cur), ie.i_idx_col, target });
            _ = aux.emit(v, .Goto, .{});
            const saved = p.idx_epr;
            p.idx_epr = null;
            exprCode(p, e, target);
            p.idx_epr = saved;
            aux.landHere(v, addr.plus(2));
        } else {
            _ = aux.emit(v, .Column, .{ Cursor.from(ie.i_idx_cur), ie.i_idx_col, target });
        }
        return target;
    }
    return null;
}

/// Port of exprPartidxExprLookup(): if column `e` is fixed to a constant
/// by the WHERE clause of a partial index the query uses
/// (Parse.idx_part_expr), code that constant and return its register;
/// else none.
fn exprPartidxExprLookup(p: *Parse, e: *Expr, target: Reg) Reg {
    var it = p.idx_part_expr;
    while (it) |ie| : (it = ie.next) {
        if (e.i_column != ie.i_idx_col or e.i_table != ie.i_data_cur) continue;
        const v = vdbe(p);
        const addr: ?Addr = if (ie.b_maybe_null_row) aux.emit(v, .IfNullRow, .{Cursor.from(ie.i_idx_cur)}) else null;
        const ret: Reg = codeTarget(p, ie.expr, target);
        _ = aux.emitStr(v, .Affinity, .{ ret, 1 }, &[1]u8{ie.aff});
        // Values read from columns have no subtype.
        if (canReturnSubtype(p, ie.expr)) _ = aux.emit(v, .ClrSubtype, .{ret});
        if (addr) |a| {
            aux.landHere(v, a);
            aux.changeP3(v, a, ret.int());
        }
        return ret;
    }
    return .none;
}

/// Port of sqlite3ExprCodeTarget(): code `e`, trying to leave the result
/// in `target`. Returns the register that holds it.
pub fn codeTarget(p: *Parse, e_arg: ?*Expr, out: Reg) Reg {
    const v = vdbe(p);
    var in_reg: Reg = out;
    var reg_free1: Reg = .none;
    var reg_free2: Reg = .none;
    var r1: Reg = undefined;
    var r2: Reg = undefined;
    var p5: u16 = 0;
    var e_opt = e_arg;
    std.debug.assert(out.int() > 0 and out.int() <= p.n_mem);

    defer {
        releaseTempReg(p, reg_free1);
        releaseTempReg(p, reg_free2);
    }

    while (true) {
        const e = e_opt orelse {
            _ = aux.emit(v, .Null, .{ 0, out });
            return out;
        };
        if (p.idx_epr != null and !e.flags.Leaf) {
            if (indexedExprLookup(p, e, out)) |r| return r;
        }
        var op = e.op;
        std.debug.assert(op != TK.ORDER);
        switch (op) {
            TK.AGG_COLUMN, TK.COLUMN => {
                if (op == TK.AGG_COLUMN) {
                    const agg = e.agg_info.?;
                    if (e.i_agg >= agg.cols.items.len) {
                        // The left table of a RIGHT JOIN is NULL.
                        _ = aux.emit(v, .Null, .{ 0, out });
                        return out;
                    }
                    const col = &agg.cols.items[@intCast(e.i_agg)];
                    if (!agg.direct_mode) {
                        return agg.columnReg(@intCast(e.i_agg));
                    } else if (agg.use_sorting_idx) {
                        _ = aux.emit(v, .Column, .{ agg.sorting_idx_ptab, col.i_sorter_column, out });
                        if (col.tab) |t| if (col.i_column >= 0 and t.cols[@intCast(col.i_column)].affinity == Aff.real) {
                            _ = aux.emit(v, .RealAffinity, .{out});
                        };
                        return out;
                    } else if (e.y.tab == null) {
                        _ = aux.emit(v, .Column, .{ Cursor.from(e.i_table), e.i_column, out });
                        return out;
                    }
                }
                var i_tab = e.i_table;
                if (e.flags.FixedCol) {
                    // A constant by WHERE clause constraints; apply the
                    // column's affinity to it.
                    const fixed: Reg = codeTarget(p, e.left, out);
                    const aff = expr_mod.tableColumnAffinity(e.y.tab.?, e.i_column);
                    if (aff > Aff.blob) _ = aux.emitStr(v, .Affinity, .{ fixed, 1 }, &[1]u8{aff});
                    return fixed;
                }
                if (i_tab < 0) {
                    if (p.i_self_tab < 0) {
                        // A column of the row unpacked into registers from
                        // -i_self_tab (CHECK constraints, generated columns).
                        const t = e.y.tab.?;
                        const i_col = e.i_column;
                        if (i_col < 0) return .from(-1 - p.i_self_tab);
                        const col = &t.cols[@intCast(i_col)];
                        const src: Reg = .from(build.tableColumnToStorage(t, @intCast(i_col)) - p.i_self_tab);
                        if (col.col_flags.intersects(COLFLAG.GENERATED)) {
                            if (col.col_flags.BUSY) {
                                util.errorMsg(p, "generated column loop on \"{s}\"", .{col.name()});
                                return .none;
                            }
                            col.col_flags.BUSY = true;
                            if (col.col_flags.NOTAVAIL) codeGeneratedColumn(p, t, col, src);
                            col.col_flags.clear(.{ .BUSY = true, .NOTAVAIL = true });
                            return src;
                        } else if (col.affinity == Aff.real) {
                            _ = aux.emit(v, .SCopy, .{ src, out });
                            _ = aux.emit(v, .RealAffinity, .{out});
                            return out;
                        }
                        return src;
                    }
                    // A column of an index's table.
                    i_tab = p.i_self_tab - 1;
                } else if (p.idx_part_expr != null) {
                    const r = exprPartidxExprLookup(p, e, out);
                    if (!r.isNone()) return r;
                }
                return codeGetColumn(p, e.y.tab.?, e.i_column, .from(i_tab), out, e.op2);
            },
            TK.INTEGER => {
                codeInteger(p, e, false, out);
                return out;
            },
            TK.TRUEFALSE => {
                _ = aux.emit(v, .Integer, .{ @intFromBool(expr_mod.truthValue(e)), out });
                return out;
            },
            TK.FLOAT => {
                codeReal(v, e.token(), false, out);
                return out;
            },
            TK.STRING => {
                _ = aux.loadString(v, out, e.token());
                return out;
            },
            TK.NULLS => {
                _ = aux.emit(v, .Null, .{ 0, out, out.at(e.y.n_reg - 1) });
                return out;
            },
            TK.BLOB => {
                const tok = e.token();
                const z = tok[2 .. tok.len - 1];
                const blob = util.hexToBlob(p.arena, z) catch {
                    oom(p);
                    return out;
                };
                _ = aux.emitStr(v, .Blob, .{ blob.len, out }, blob);
                return out;
            },
            TK.VARIABLE => {
                _ = aux.emit(v, .Variable, .{ e.i_column, out });
                return out;
            },
            TK.REGISTER => return .from(e.i_table),
            TK.CAST => {
                exprCode(p, e.left, out);
                _ = aux.emit(v, .Cast, .{ out, build.affinityType(e.token(), null) });
                return in_reg;
            },
            TK.IS, TK.ISNOT, TK.LT, TK.LE, TK.GT, TK.GE, TK.NE, TK.EQ => {
                if (op == TK.IS or op == TK.ISNOT) {
                    op = if (op == TK.IS) TK.EQ else TK.NE;
                    p5 = NULLEQ;
                }
                const left = e.left.?;
                var addr_is_null: ?Addr = null;
                if (expr_mod.isVector(left)) {
                    codeVectorCompare(p, e, out, op, p5);
                } else {
                    if (e.flags.Subquery and p5 != NULLEQ) {
                        addr_is_null = computeOperands(p, e, &r1, &r2, &reg_free1, &reg_free2);
                    } else {
                        r1 = codeTemp(p, e.left, &reg_free1);
                        r2 = codeTemp(p, e.right, &reg_free2);
                    }
                    _ = aux.emit(v, .Integer, .{ 1, in_reg });
                    codeCompare(p, left, e.right.?, op, r1, r2, aux.here(v).plus(2), p5, e.flags.Commuted);
                    if (p5 == NULLEQ) {
                        _ = aux.emit(v, .Integer, .{ 0, in_reg });
                    } else {
                        _ = aux.emit(v, .ZeroOrNull, .{ r1, in_reg, r2 });
                        if (addr_is_null) |a| {
                            _ = aux.emit(v, .Goto, .{ 0, aux.here(v).plus(2) });
                            aux.landHere(v, a);
                            _ = aux.emit(v, .Null, .{ 0, in_reg });
                        }
                    }
                }
                return in_reg;
            },
            TK.AND, TK.OR => {
                in_reg = codeTargetAndOr(p, e, out, &reg_free1);
                return in_reg;
            },
            TK.PLUS, TK.STAR, TK.MINUS, TK.REM, TK.BITAND, TK.BITOR, TK.SLASH, TK.LSHIFT, TK.RSHIFT, TK.CONCAT => {
                var addr_is_null: ?Addr = null;
                if (e.flags.Subquery) {
                    addr_is_null = computeOperands(p, e, &r1, &r2, &reg_free1, &reg_free2);
                } else {
                    r1 = codeTemp(p, e.left, &reg_free1);
                    r2 = codeTemp(p, e.right, &reg_free2);
                }
                _ = aux.emitAny(v, OP.fromTk(op), .{ .reg, .reg, .reg }, .{ r2, r1, out });
                // xqlite: the width of the result's integer type, which
                // the dialect checks (0 in SQLite's dialect).
                if (e.xq_type != 0) switch (op) {
                    TK.PLUS, TK.MINUS, TK.STAR, TK.SLASH, TK.REM => aux.changeP5(v, typing.arithWidth(p, e)),
                    else => {},
                };
                if (addr_is_null) |a| {
                    _ = aux.emit(v, .Goto, .{ 0, aux.here(v).plus(2) });
                    aux.landHere(v, a);
                    _ = aux.emit(v, .Null, .{ 0, out });
                }
                return in_reg;
            },
            TK.UMINUS => {
                const left = e.left.?;
                if (left.op == TK.INTEGER) {
                    codeInteger(p, left, true, out);
                    return out;
                } else if (left.op == TK.FLOAT) {
                    codeReal(v, left.token(), true, out);
                    return out;
                }
                var temp_x: Expr = .{ .op = TK.INTEGER, .flags = .{ .IntValue = true, .TokenOnly = true }, .u = .{ .value = 0 } };
                r1 = codeTemp(p, &temp_x, &reg_free1);
                r2 = codeTemp(p, e.left, &reg_free2);
                _ = aux.emit(v, .Subtract, .{ r2, r1, out });
                if (e.xq_type != 0) aux.changeP5(v, typing.arithWidth(p, e));
                return in_reg;
            },
            TK.BITNOT, TK.NOT => {
                r1 = codeTemp(p, e.left, &reg_free1);
                _ = aux.emitAny(v, OP.fromTk(op), .{ .reg, .reg, .int }, .{ r1, in_reg });
                return in_reg;
            },
            TK.TRUTH => {
                r1 = codeTemp(p, e.left, &reg_free1);
                const is_true = expr_mod.truthValue(e.right.?);
                const b_normal = e.op2 == TK.IS;
                _ = aux.emitInt(v, .IsTrue, .{ r1, in_reg, @intFromBool(!is_true) }, @intFromBool(is_true != b_normal));
                return in_reg;
            },
            TK.ISNULL, TK.NOTNULL => {
                _ = aux.emit(v, .Integer, .{ 1, out });
                r1 = codeTemp(p, e.left, &reg_free1);
                const addr = aux.emitAny(v, OP.fromTk(op), .{ .reg, .jump, .int }, .{r1});
                _ = aux.emit(v, .Integer, .{ 0, out });
                aux.landHere(v, addr);
                return in_reg;
            },
            TK.AGG_FUNCTION => {
                const info = e.agg_info;
                if (info == null or e.i_agg < 0 or e.i_agg >= info.?.funcs.items.len) {
                    util.errorMsg(p, "misuse of aggregate: {s}()", .{e.token()});
                    expr_mod.recordErrorOffsetOfExpr(p, e);
                    return in_reg;
                }
                const reg = info.?.funcReg(@intCast(e.i_agg));
                // xqlite: a sum() of a narrow integer type (SQL Server's
                // SUM() of an int is an int) is checked as it is read:
                // 0 + sum, of that width.
                if (e.xq_type != 0) {
                    const w = typing.arithWidth(p, e);
                    if (w != 0 and ctype.eqlNoCase(e.token(), "sum")) {
                        var zero: Expr = .{ .op = TK.INTEGER, .flags = .{ .IntValue = true, .TokenOnly = true }, .u = .{ .value = 0 } };
                        const r0: Reg = codeTemp(p, &zero, &reg_free1);
                        _ = aux.emit(v, .Add, .{ r0, reg, out });
                        aux.changeP5(v, w);
                        return out;
                    }
                }
                return reg;
            },
            TK.FUNCTION => return codeFunction(p, e, out),
            TK.EXISTS, TK.SELECT => {
                if (p.db.malloc_failed) return .none;
                if (op == TK.SELECT) {
                    const n_col = e.x.select.?.e_list.?.len();
                    if (n_col != 1) {
                        expr_mod.subselectError(p, n_col, 1);
                        return in_reg;
                    }
                }
                return codeSubselect(p, e);
            },
            TK.SELECT_COLUMN => {
                const left = e.left.?;
                if (left.i_table == 0 or p.within_rj_subrtn > left.op2) {
                    left.i_table = codeSubselect(p, left).int();
                    left.op2 = p.within_rj_subrtn;
                }
                const n = expr_mod.vectorSize(left);
                if (e.i_table != n) {
                    util.errorMsg(p, "{d} columns assigned {d} values", .{ e.i_table, n });
                }
                return .from(left.i_table + e.i_column);
            },
            TK.IN => {
                const dest_if_false = aux.newLabel(p);
                const dest_if_null = aux.newLabel(p);
                _ = aux.emit(v, .Null, .{ 0, out });
                codeIN(p, e, dest_if_false, dest_if_null);
                _ = aux.emit(v, .Integer, .{ 1, out });
                aux.place(v, dest_if_false);
                _ = aux.emit(v, .AddImm, .{ out, 0 });
                aux.place(v, dest_if_null);
                return out;
            },
            TK.BETWEEN => {
                codeBetween(p, e, .{ .reg = out }, 0);
                return out;
            },
            TK.COLLATE => {
                if (!e.flags.Collate) {
                    // A "soft" COLLATE from a pushed-down constraint:
                    // subtypes may not cross a subquery boundary.
                    exprCode(p, e.left, out);
                    _ = aux.emit(v, .ClrSubtype, .{out});
                    return out;
                }
                e_opt = e.left;
                continue;
            },
            TK.SPAN, TK.UPLUS => {
                e_opt = e.left;
                continue;
            },
            TK.TRIGGER => {
                // A column of new.* or old.* in a trigger program: P1 of
                // OP_Param is (n+1)*i_table + 1 + the storage column.
                const t = e.y.tab.?;
                const i_col = e.i_column;
                const p1 = e.i_table * (@as(i32, @intCast(t.cols.len)) + 1) + 1 + build.tableColumnToStorage(t, i_col);
                _ = aux.emit(v, .Param, .{ p1, out });
                if (i_col >= 0 and t.cols[@intCast(i_col)].affinity == Aff.real) {
                    _ = aux.emit(v, .RealAffinity, .{out});
                }
                return in_reg;
            },
            TK.VECTOR => {
                util.errorMsg(p, "row value misused", .{});
                return in_reg;
            },
            TK.IF_NULL_ROW => {
                const ok_const_factor = p.ok_const_factor;
                if (e.agg_info) |agg| {
                    if (!agg.direct_mode) return agg.columnReg(@intCast(e.i_agg));
                    if (agg.use_sorting_idx) {
                        _ = aux.emit(v, .Column, .{ agg.sorting_idx_ptab, agg.cols.items[@intCast(e.i_agg)].i_sorter_column, out });
                        return out;
                    }
                }
                const addr_inr = aux.emit(v, .IfNullRow, .{ Cursor.from(e.i_table), 0, out });
                // OP_IfNullRow may overwrite the result with NULL, so it
                // must really be in `out` and not a factored constant.
                p.ok_const_factor = false;
                exprCode(p, e.left, out);
                p.ok_const_factor = ok_const_factor;
                aux.landHere(v, addr_inr);
                return in_reg;
            },
            TK.CASE => {
                codeCase(p, e, out, &reg_free1);
                return in_reg;
            },
            TK.RAISE => {
                if (p.trigger_tab == null and p.nested == 0) {
                    util.errorMsg(p, "RAISE() may only be used within a trigger-program", .{});
                    return .none;
                }
                if (e.aff_expr == OE.Abort.int()) @import("main.zig").mayAbort(p);
                if (e.aff_expr == OE.Ignore.int()) {
                    _ = aux.emit(v, .Halt, .{ RC.OK, OE.Ignore.int() });
                } else {
                    r1 = codeTemp(p, e.left, &reg_free1);
                    // P3 of OP_Halt is a number to operand.kinds(), and
                    // here the register of the message.
                    _ = aux.emit(v, .Halt, .{ @as(i32, if (p.trigger_tab != null) RC.CONSTRAINT_TRIGGER else RC.ERROR), e.aff_expr, r1 });
                }
                return in_reg;
            },
            else => {
                std.debug.assert(op == TK.NULL or op == TK.ERROR or p.db.malloc_failed);
                _ = aux.emit(v, .Null, .{ 0, out });
                return out;
            },
        }
    }
}

/// The TK_CASE part of sqlite3ExprCodeTarget(): "CASE x WHEN e1 THEN r1
/// ... ELSE y END" is coded as "CASE WHEN x=e1 THEN r1 ...".
fn codeCase(p: *Parse, e: *Expr, out: Reg, reg_free1: *Reg) void {
    const v = vdbe(p);
    const e_list = e.x.list.?;
    const items = e_list.slice();
    const n_expr = items.len;
    const end_label = aux.newLabel(p);
    var op_compare: Expr = .{ .op = TK.EQ };
    var test_expr: ?*Expr = null;
    const x = e.left;
    if (x) |xe| {
        const del = dup(p, xe) orelse return;
        expr_mod.toRegister(del, exprCodeVector(p, del, reg_free1));
        op_compare.left = del;
        test_expr = &op_compare;
        // The register may be copied into the result, so it must not
        // be reused.
        reg_free1.* = .none;
    }
    var i: usize = 0;
    while (i + 1 < n_expr) : (i += 2) {
        if (x != null) {
            op_compare.right = items[i].expr;
        } else {
            test_expr = items[i].expr;
        }
        const next_case = aux.newLabel(p);
        exprIfFalse(p, test_expr, next_case, JUMPIFNULL);
        exprCode(p, items[i + 1].expr, out);
        _ = aux.emit(v, .Goto, .{ 0, end_label });
        aux.place(v, next_case);
    }
    if (n_expr & 1 != 0) {
        exprCode(p, items[n_expr - 1].expr, out);
    } else {
        _ = aux.emit(v, .Null, .{ 0, out });
    }
    setDoNotMergeFlagOnCopy(v);
    aux.place(v, end_label);
}

/// The TK_FUNCTION part of sqlite3ExprCodeTarget().
fn codeFunction(p: *Parse, e: *Expr, out: Reg) Reg {
    const v = vdbe(p);
    const db = p.db;
    if (e.flags.WinFunc) return e.y.win.?.reg_result;

    // A constant function call is computed once.
    if (constFactorOk(p) and expr_mod.isConstantNotJoin(p, e)) return codeRunJustOnce(p, e, null);

    const farg = e.x.list;
    const n_farg: usize = if (farg) |f| f.len() else 0;
    const id = e.token();
    const def_opt = callback.findFunction(db, id, @intCast(n_farg), db.enc, false);
    if (def_opt == null or def_opt.?.x_finalize != null or
        (def_opt.?.func_flags.INTERNAL and p.nested == 0 and !db.m_db_flags.InternalFunc))
    {
        util.errorMsg(p, "unknown function: {s}()", .{id});
        expr_mod.recordErrorOffsetOfExpr(p, e);
        return out;
    }
    var def = def_opt.?;
    if (def.func_flags.INLINE) if (farg) |f| {
        return codeInlineFunction(p, f, @intFromPtr(def.user_data), out);
    };
    if (def.func_flags.intersects(.{ .DIRECT = true, .UNSAFE = true })) expr_mod.functionUsable(p, e, def);

    var const_mask: u32 = 0;
    var coll: ?*const CollSeq = null;
    if (farg) |f| for (f.slice(), 0..) |item, i| {
        if (i < 32 and expr_mod.isConstant(p, item.expr)) const_mask |= @as(u32, 1) << @intCast(i);
        if (def.func_flags.NEEDCOLL and coll == null) coll = expr_mod.collSeq(p, item.expr);
    };
    // The first register of the arguments.
    var r1: Reg = .none;
    if (farg) |f| {
        if (const_mask != 0) {
            r1 = p.newRegs(n_farg);
        } else {
            r1 = getTempRange(p, n_farg);
        }
        // length(), typeof() and octet_length() of a column need not load
        // all of it.
        if (def.func_flags.intersects(.{ .LENGTH = true, .TYPEOF = true })) {
            const a0 = f.at(0).expr.?;
            if (a0.op == TK.COLUMN or a0.op == TK.AGG_COLUMN) {
                // The P5 of the OP_Column (OPFLAG_LENGTHARG etc.: the same bits).
                a0.op2 = @intCast(def.func_flags.only(FUNC.BYTELEN).int());
            }
        }
        _ = codeExprList(p, f, r1, .none, ECEL_FACTOR);
    }
    // A virtual table may overload the function when its first argument
    // (the second for infix LIKE, GLOB, REGEXP and MATCH, whose left
    // operand it is) is one of its columns.
    if (farg) |f| {
        const vtab = @import("vtab.zig");
        if (n_farg >= 2 and e.flags.InfixFunc) {
            def = vtab.overloadFunction(db, v.alloc(), def, @intCast(n_farg), f.at(1).expr);
        } else if (n_farg > 0) {
            def = vtab.overloadFunction(db, v.alloc(), def, @intCast(n_farg), f.at(0).expr);
        }
    }
    if (def.func_flags.NEEDCOLL) {
        _ = aux.emit4(v, .CollSeq, .{}, .{ .collseq = coll orelse coll_mod.dfltColl(p.db) });
    }
    _ = aux.addFunctionCall(p, @bitCast(const_mask), r1, out, @intCast(n_farg), def, e.op2);
    if (n_farg != 0 and const_mask == 0) releaseTempRange(p, r1, n_farg);
    return out;
}

/// Port of sqlite3ExprCodeRunJustOnce(): code `e` once per run: in the
/// initialization code (constants without functions), or behind OP_Once.
/// Without `dest` any register may be used (and shared by equal
/// expressions). Returns the register.
pub fn codeRunJustOnce(p: *Parse, e_arg: ?*Expr, dest: ?Reg) Reg {
    var reg_dest = dest;
    std.debug.assert(constFactorOk(p) and (dest == null or !dest.?.isNone()));
    if (dest == null) if (p.const_expr) |list| {
        for (list.slice()) |item| {
            if (item.fg.reusable and expr_mod.compare(null, item.expr, e_arg, -1) == 0) {
                return item.u.const_expr_reg;
            }
        }
    };
    // A null expression codes a NULL, as in C.
    const e = dup(p, e_arg);
    if (e == null and p.db.malloc_failed) return dest orelse .none;
    if (e != null and e.?.flags.HasFunc) {
        const v = vdbe(p);
        const addr = aux.emit(v, .Once, .{});
        p.ok_const_factor = false;
        if (!p.db.malloc_failed) {
            if (reg_dest == null) {
                reg_dest = p.newReg();
            }
            exprCode(p, e, reg_dest.?);
        }
        p.ok_const_factor = true;
        aux.landHere(v, addr);
    } else {
        const list = expr_mod.listAppend(p, p.const_expr, e) catch {
            oom(p);
            return dest orelse .none;
        };
        const item = list.last();
        item.fg.reusable = dest == null;
        const reg = reg_dest orelse p.newReg();
        reg_dest = reg;
        item.u = .{ .const_expr_reg = reg };
        p.const_expr = list;
    }
    return reg_dest orelse .none;
}

/// Port of sqlite3ExprNullRegisterRange(): set `n_reg` registers from
/// `reg` to NULL during initialization.
pub fn nullRegisterRange(p: *Parse, reg: Reg, n_reg: i32) void {
    const ok_const_factor = p.ok_const_factor;
    var t: Expr = .{ .op = TK.NULLS, .y = .{ .n_reg = n_reg } };
    p.ok_const_factor = true;
    _ = codeRunJustOnce(p, &t, reg);
    p.ok_const_factor = ok_const_factor;
}

/// Port of sqlite3ExprCodeTemp(): code `e` into some register, returned;
/// `reg` receives it if it is a temporary to release, else `.none`.
pub fn codeTemp(p: *Parse, e_arg: ?*Expr, reg: *Reg) Reg {
    const e = expr_mod.skipCollateAndLikely(e_arg);
    if (constFactorOk(p) and e != null and e.?.op != TK.REGISTER and expr_mod.isConstantNotJoin(p, e)) {
        reg.* = .none;
        return codeRunJustOnce(p, e.?, null);
    }
    const r1 = getTempReg(p);
    const r2 = codeTarget(p, e, r1);
    if (r2 == r1) {
        reg.* = r1;
    } else {
        releaseTempReg(p, r1);
        reg.* = .none;
    }
    return r2;
}

/// Port of sqlite3ExprCode(): code `e` into register `target`.
pub fn exprCode(p: *Parse, e: ?*Expr, target: Reg) void {
    std.debug.assert(target.int() > 0 and target.int() <= p.n_mem);
    const v = p.vdbe orelse return;
    const in_reg = codeTarget(p, e, target);
    if (in_reg != target) {
        const x = expr_mod.skipCollateAndLikely(e);
        const op: OP = if (x != null and (x.?.flags.Subquery or x.?.op == TK.REGISTER)) OP.Copy else OP.SCopy;
        _ = aux.emitAny(v, op, .{ .reg, .reg, .int }, .{ in_reg, target });
    }
}

/// Port of sqlite3ExprCodeCopy(): code a copy of `e`, which is left
/// unchanged.
pub fn codeCopy(p: *Parse, e: ?*Expr, target: Reg) void {
    const c = dup(p, e);
    if (!p.db.malloc_failed) exprCode(p, c, target);
}

/// Port of sqlite3ExprCodeFactorable(): like exprCode(), but a constant
/// may be computed during initialization.
pub fn codeFactorable(p: *Parse, e: ?*Expr, target: Reg) void {
    if (p.ok_const_factor and expr_mod.isConstantNotJoin(p, e)) {
        _ = codeRunJustOnce(p, e, target);
    } else {
        codeCopy(p, e, target);
    }
}

/// Port of sqlite3ExprCodeExprList(): code the expressions of `list` into
/// consecutive registers from `target`. Returns the number coded.
pub fn codeExprList(p: *Parse, list: *ExprList, target: Reg, src_reg: Reg, flags_arg: u8) i32 {
    var flags = flags_arg;
    const copy_op: OP = if (flags & ECEL_DUP != 0) OP.Copy else OP.SCopy;
    const v = vdbe(p);
    var n: i32 = @intCast(list.len());
    if (!constFactorOk(p)) flags &= ~ECEL_FACTOR;
    var i: i32 = 0;
    for (list.slice()) |item| {
        const e = item.expr;
        const j = item.u.x.order_by_col;
        const dst = target.at(i);
        if (flags & ECEL_REF != 0 and j > 0) {
            if (flags & ECEL_OMITREF != 0) {
                n -= 1;
                continue;
            }
            _ = aux.emitAny(v, copy_op, .{ .reg, .reg, .int }, .{ src_reg.at(@as(i32, j) - 1), dst });
        } else if (flags & ECEL_FACTOR != 0 and expr_mod.isConstantNotJoin(p, e)) {
            _ = codeRunJustOnce(p, e.?, dst);
        } else {
            const in_reg = codeTarget(p, e, dst);
            if (in_reg != dst) {
                const op = aux.getLastOp(v);
                // Widen the OP_Copy just before if this one continues it.
                if (copy_op == OP.Copy and op.opcode == OP.Copy and
                    op.p1 + op.p3 + 1 == in_reg.int() and op.p2 + op.p3 + 1 == dst.int() and op.p5 == 0)
                {
                    op.p3 += 1;
                } else {
                    _ = aux.emitAny(v, copy_op, .{ .reg, .reg, .int }, .{ in_reg, dst });
                }
            }
        }
        i += 1;
    }
    return n;
}

/// The jumps of exprCodeBetween(): ifTrue or ifFalse.
const JumpFn = *const fn (p: *Parse, e: ?*Expr, dest: Jump, jump_if_null: u16) void;

/// Where exprCodeBetween() puts its result: in a register, or a jump
/// (ifTrue or ifFalse) to a place.
const BetweenDest = union(enum) {
    reg: Reg,
    jump: struct { f: JumpFn, to: Jump },
};

/// Port of exprCodeBetween(): "x BETWEEN y AND z" as "x>=y AND x<=z"
/// computing x once: store the result in `dest`, or jump to it.
fn codeBetween(p: *Parse, e: *Expr, dest: BetweenDest, jump_if_null: u16) void {
    var reg_free1: Reg = .none;
    const del = dup(p, e.left) orelse return;
    var comp_left: Expr = .{ .op = TK.GE, .left = del, .right = e.x.list.?.at(0).expr };
    var comp_right: Expr = .{ .op = TK.LE, .left = del, .right = e.x.list.?.at(1).expr };
    var expr_and: Expr = .{ .op = TK.AND, .left = &comp_left, .right = &comp_right };
    expr_mod.toRegister(del, exprCodeVector(p, del, &reg_free1));
    switch (dest) {
        .jump => |j| j.f(p, &expr_and, j.to, jump_if_null),
        .reg => |r| {
            // EP_OuterON keeps the AND from being factored out as a constant.
            del.flags.OuterON = true;
            _ = codeTarget(p, &expr_and, r);
        },
    }
    releaseTempReg(p, reg_free1);
}

/// Port of sqlite3ExprIfTrue(): jump to `to` (a Label, an Addr or a
/// Jump) if `e` is true; also if it is NULL and `jump_if_null` is
/// SQLITE_JUMPIFNULL.
pub inline fn exprIfTrue(p: *Parse, e: ?*Expr, to: anytype, jump_if_null: u16) void {
    ifTrue(p, e, Jump.of(to), jump_if_null);
}

/// exprIfTrue() on a Jump: the one body, also the JumpFn of codeBetween().
fn ifTrue(p: *Parse, e_arg: ?*Expr, to: Jump, jump_if_null_arg: u16) void {
    const v = p.vdbe orelse return;
    const e = e_arg orelse return;
    var jump_if_null = jump_if_null_arg;
    var op: u8 = e.op;
    var reg_free1: Reg = .none;
    var reg_free2: Reg = .none;
    defer {
        releaseTempReg(p, reg_free1);
        releaseTempReg(p, reg_free2);
    }
    switch (op) {
        TK.AND, TK.OR => {
            const alt = expr_mod.simplifiedAndOr(e);
            if (alt != e) return exprIfTrue(p, alt, to, jump_if_null);
            const first, const second = if (evalRhsFirst(e)) .{ e.right, e.left } else .{ e.left, e.right };
            if (op == TK.AND) {
                const d2 = aux.newLabel(p);
                exprIfFalse(p, first, d2, jump_if_null ^ JUMPIFNULL);
                exprIfTrue(p, second, to, jump_if_null);
                aux.place(v, d2);
            } else {
                exprIfTrue(p, first, to, jump_if_null);
                exprIfTrue(p, second, to, jump_if_null);
            }
            return;
        },
        TK.NOT => return exprIfFalse(p, e.left, to, jump_if_null),
        TK.TRUTH => {
            const is_not = e.op2 == TK.ISNOT;
            const is_true = expr_mod.truthValue(e.right.?);
            if (is_true != is_not) {
                exprIfTrue(p, e.left, to, if (is_not) JUMPIFNULL else 0);
            } else {
                exprIfFalse(p, e.left, to, if (is_not) JUMPIFNULL else 0);
            }
            return;
        },
        TK.IS, TK.ISNOT, TK.LT, TK.LE, TK.GT, TK.GE, TK.NE, TK.EQ => {
            if (op == TK.IS or op == TK.ISNOT) {
                op = if (op == TK.IS) TK.EQ else TK.NE;
                jump_if_null = NULLEQ;
            }
            if (!expr_mod.isVector(e.left.?)) {
                var r1: Reg = undefined;
                var r2: Reg = undefined;
                var addr_is_null: ?Addr = null;
                if (e.flags.Subquery and jump_if_null != NULLEQ) {
                    addr_is_null = computeOperands(p, e, &r1, &r2, &reg_free1, &reg_free2);
                } else {
                    r1 = codeTemp(p, e.left, &reg_free1);
                    r2 = codeTemp(p, e.right, &reg_free2);
                }
                codeCompare(p, e.left.?, e.right.?, op, r1, r2, to, jump_if_null, e.flags.Commuted);
                if (addr_is_null) |a| {
                    if (jump_if_null != 0) aux.setJump(v, a, to) else aux.landHere(v, a);
                }
                return;
            }
        },
        TK.ISNULL, TK.NOTNULL => {
            const r1: Reg = codeTemp(p, e.left, &reg_free1);
            if (!reg_free1.isNone()) aux.typeofColumn(v, r1);
            _ = aux.emitAny(v, OP.fromTk(op), .{ .reg, .jump, .int }, .{ r1, to });
            return;
        },
        TK.BETWEEN => return codeBetween(p, e, .{ .jump = .{ .f = ifTrue, .to = to } }, jump_if_null),
        TK.IN => {
            const dest_if_false = aux.newLabel(p);
            const dest_if_null = if (jump_if_null != 0) to else Jump.of(dest_if_false);
            codeIN(p, e, dest_if_false, dest_if_null);
            _ = aux.emit(v, .Goto, .{ 0, to });
            aux.place(v, dest_if_false);
            return;
        },
        else => {},
    }
    if (e.alwaysTrue()) {
        _ = aux.emit(v, .Goto, .{ 0, to });
    } else if (e.alwaysFalse()) {
        // No-op.
    } else {
        const r1: Reg = codeTemp(p, e, &reg_free1);
        _ = aux.emit(v, .If, .{ r1, to, @intFromBool(jump_if_null != 0) });
    }
}

/// Port of sqlite3ExprIfFalse(): jump to `to` (a Label, an Addr or a
/// Jump) if `e` is false; also if it is NULL and `jump_if_null` is
/// SQLITE_JUMPIFNULL.
pub inline fn exprIfFalse(p: *Parse, e: ?*Expr, to: anytype, jump_if_null: u16) void {
    ifFalse(p, e, Jump.of(to), jump_if_null);
}

/// exprIfFalse() on a Jump: the one body, also the JumpFn of codeBetween().
fn ifFalse(p: *Parse, e_arg: ?*Expr, to: Jump, jump_if_null_arg: u16) void {
    const v = p.vdbe orelse return;
    const e = e_arg orelse return;
    var jump_if_null = jump_if_null_arg;
    var reg_free1: Reg = .none;
    var reg_free2: Reg = .none;
    defer {
        releaseTempReg(p, reg_free1);
        releaseTempReg(p, reg_free2);
    }
    // The opcode testing the opposite of a comparison: TK_ISNULL is
    // OP_NotNull, TK_NE is OP_Eq, TK_LT is OP_Ge, and so on.
    var op: u8 = @intCast(((@as(i32, e.op) + (TK.ISNULL & 1)) ^ 1) - (TK.ISNULL & 1));
    switch (e.op) {
        TK.AND, TK.OR => {
            const alt = expr_mod.simplifiedAndOr(e);
            if (alt != e) return exprIfFalse(p, alt, to, jump_if_null);
            const first, const second = if (evalRhsFirst(e)) .{ e.right, e.left } else .{ e.left, e.right };
            if (e.op == TK.AND) {
                exprIfFalse(p, first, to, jump_if_null);
                exprIfFalse(p, second, to, jump_if_null);
            } else {
                const d2 = aux.newLabel(p);
                exprIfTrue(p, first, d2, jump_if_null ^ JUMPIFNULL);
                exprIfFalse(p, second, to, jump_if_null);
                aux.place(v, d2);
            }
            return;
        },
        TK.NOT => return exprIfTrue(p, e.left, to, jump_if_null),
        TK.TRUTH => {
            const is_not = e.op2 == TK.ISNOT;
            const is_true = expr_mod.truthValue(e.right.?);
            if (is_true != is_not) {
                // IS TRUE and IS NOT FALSE.
                exprIfFalse(p, e.left, to, if (is_not) 0 else JUMPIFNULL);
            } else {
                // IS FALSE and IS NOT TRUE.
                exprIfTrue(p, e.left, to, if (is_not) 0 else JUMPIFNULL);
            }
            return;
        },
        TK.IS, TK.ISNOT, TK.LT, TK.LE, TK.GT, TK.GE, TK.NE, TK.EQ => {
            if (e.op == TK.IS or e.op == TK.ISNOT) {
                op = if (e.op == TK.IS) TK.NE else TK.EQ;
                jump_if_null = NULLEQ;
            }
            if (!expr_mod.isVector(e.left.?)) {
                var r1: Reg = undefined;
                var r2: Reg = undefined;
                var addr_is_null: ?Addr = null;
                if (e.flags.Subquery and jump_if_null != NULLEQ) {
                    addr_is_null = computeOperands(p, e, &r1, &r2, &reg_free1, &reg_free2);
                } else {
                    r1 = codeTemp(p, e.left, &reg_free1);
                    r2 = codeTemp(p, e.right, &reg_free2);
                }
                codeCompare(p, e.left.?, e.right.?, op, r1, r2, to, jump_if_null, e.flags.Commuted);
                if (addr_is_null) |a| {
                    if (jump_if_null != 0) aux.setJump(v, a, to) else aux.landHere(v, a);
                }
                return;
            }
        },
        TK.ISNULL, TK.NOTNULL => {
            const r1: Reg = codeTemp(p, e.left, &reg_free1);
            if (!reg_free1.isNone()) aux.typeofColumn(v, r1);
            _ = aux.emitAny(v, OP.fromTk(op), .{ .reg, .jump, .int }, .{ r1, to });
            return;
        },
        TK.BETWEEN => return codeBetween(p, e, .{ .jump = .{ .f = ifFalse, .to = to } }, jump_if_null),
        TK.IN => {
            if (jump_if_null != 0) {
                codeIN(p, e, to, to);
            } else {
                const dest_if_null = aux.newLabel(p);
                codeIN(p, e, to, dest_if_null);
                aux.place(v, dest_if_null);
            }
            return;
        },
        else => {},
    }
    if (e.alwaysFalse()) {
        _ = aux.emit(v, .Goto, .{ 0, to });
    } else if (e.alwaysTrue()) {
        // No-op.
    } else {
        const r1: Reg = codeTemp(p, e, &reg_free1);
        _ = aux.emit(v, .IfNot, .{ r1, to, @intFromBool(jump_if_null != 0) });
    }
}

/// Port of sqlite3ExprIfFalseDup(): exprIfFalse() on a copy of `e`.
pub fn exprIfFalseDup(p: *Parse, e: ?*Expr, dest: anytype, jump_if_null: u16) void {
    const c = dup(p, e);
    if (!p.db.malloc_failed) exprIfFalse(p, c, dest, jump_if_null);
}
