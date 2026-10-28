//! UPSERT: INSERT ... ON CONFLICT (port of upsert.c): the clauses, the
//! matching of conflict targets to UNIQUE constraints, and the DO UPDATE,
//! which insert.generateConstraintChecks() codes when a constraint fails.

const std = @import("std");
const int = @import("sqlite_int.zig");
const expr_mod = @import("expr.zig");
const resolve = @import("resolve.zig");
const build = @import("build.zig");
const util = @import("util.zig");
const update_mod = @import("update.zig");
const main_mod = @import("main.zig");
const printf = @import("printf.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const Index = int.Index;
const SrcList = int.SrcList;
const Table = int.Table;
const Upsert = int.Upsert;
const Oom = int.Oom;
const OE = int.OE;
const RC = int.RC;
const TK = int.TK;
const OP = vi.OP;

/// Port of sqlite3UpsertNew(): one ON CONFLICT clause, before `next`.
/// A null `set` means DO NOTHING.
pub fn upsertNew(p: *Parse, target: ?*ExprList, target_where: ?*Expr, set: ?*ExprList, where: ?*Expr, next: ?*Upsert) Oom!*Upsert {
    const u = try p.arena.create(Upsert);
    u.* = .{
        .target = target,
        .target_where = target_where,
        .set = set,
        .where = where,
        .is_do_update = set != null,
        .next = next,
    };
    return u;
}

/// Port of sqlite3UpsertDup(): a copy of an ON CONFLICT list.
pub fn upsertDup(a: std.mem.Allocator, u_arg: ?*Upsert) Oom!?*Upsert {
    const u = u_arg orelse return null;
    const n = try a.create(Upsert);
    n.* = .{
        .target = try expr_mod.listDup(a, u.target),
        .target_where = try expr_mod.exprDup(a, u.target_where),
        .set = try expr_mod.listDup(a, u.set),
        .where = try expr_mod.exprDup(a, u.where),
        .is_do_update = u.set != null,
        .next = try upsertDup(a, u.next),
    };
    return n;
}

/// Port of sqlite3UpsertAnalyzeTarget(): resolve the conflict targets of
/// `upsert` and the clauses after it, and match each to the INTEGER
/// PRIMARY KEY or a UNIQUE index of the table (Upsert.idx). `all` is the
/// whole list. On error (C: an error count) the error is in `p`.
pub fn analyzeTarget(p: *Parse, tab_list: *SrcList, upsert: *Upsert, all: *Upsert) (Oom || int.ParseError)!void {
    std.debug.assert(tab_list.len() == 1 and tab_list.at(0).s_tab != null);
    var nc: int.NameContext = .{ .parse = p, .src_list = tab_list };
    var n_clause: u32 = 0;
    var it: ?*Upsert = upsert;
    while (it) |u| : ({
        it = u.next;
        n_clause += 1;
    }) {
        const target = u.target orelse break;
        try resolve.resolveExprListNames(&nc, target);
        try resolve.resolveExprNames(&nc, u.target_where);

        // The rowid of the table?
        const t = tab_list.at(0).s_tab.?;
        const i_cursor = tab_list.at(0).i_cursor;
        if (t.hasRowid() and target.len() == 1) {
            const term = target.at(0).expr.?;
            if (term.op == TK.COLUMN and term.i_column == int.XN_ROWID) {
                std.debug.assert(u.idx == null);
                continue;
            }
        }

        // An index column as an expression: col[0] the COLLATE and col[1]
        // the column, filled in for each column compared.
        var col: [2]Expr = .{ .{ .op = TK.COLLATE }, .{ .op = TK.COLUMN, .i_table = i_cursor } };
        col[0].left = &col[1];

        var idx_opt = t.index;
        while (idx_opt) |idx| : (idx_opt = idx.next) {
            if (!idx.isUnique()) continue;
            if (target.len() != idx.n_key_col) continue;
            if (idx.part_idx_where) |w| {
                const tw = u.target_where orelse continue;
                if (expr_mod.compare(p, tw, w, i_cursor) != 0) continue;
            }
            const nn = idx.n_key_col;
            var ii: usize = 0;
            while (ii < nn) : (ii += 1) {
                col[0].u = .{ .token = @constCast(idx.coll[ii]) };
                var e: *Expr = undefined;
                if (idx.ai_column[ii] == int.XN_EXPR) {
                    std.debug.assert(idx.has_expr);
                    e = idx.col_expr.?.at(ii).expr.?;
                    if (e.op != TK.COLLATE) {
                        col[0].left = e;
                        e = &col[0];
                    }
                } else {
                    col[0].left = &col[1];
                    col[1].i_column = idx.ai_column[ii];
                    e = &col[0];
                }
                // Column ii of the index must match a term of the target.
                const matched = for (target.slice()) |*item| {
                    if (expr_mod.compare(null, item.expr, e, i_cursor) < 2) break true;
                } else false;
                if (!matched) break;
            }
            if (ii < nn) continue;
            u.idx = idx;
            // A later clause for the same index never fires. Not an error,
            // for the sake of applications that have them.
            if (ofIndex(all, idx) != u) u.is_dup = true;
            break;
        }
        if (u.idx == null) {
            const which = if (n_clause == 0 and u.next == null)
                ""
            else
                printf.mprintf(p.arena, "%r ", &.{.{ .int = n_clause + 1 }}) catch return error.OutOfMemory;
            util.errorMsg(p, "{s}ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint", .{which});
            return error.ParseFailed;
        }
    }
}

/// Port of sqlite3UpsertNextIsIPK(): whether `u` is the last clause with
/// a conflict target, or the next one that may fire is on the INTEGER
/// PRIMARY KEY.
pub fn nextIsIpk(u: *Upsert) bool {
    var next = u.next;
    while (next) |n| : (next = n.next) {
        if (n.target == null) return true;
        if (n.idx == null) return true;
        if (!n.is_dup) return false;
    }
    return true;
}

/// Port of sqlite3UpsertOfIndex(): the clause of `list` for `idx` (null:
/// the INTEGER PRIMARY KEY), or null if none applies.
pub fn ofIndex(list: ?*Upsert, idx: ?*Index) ?*Upsert {
    var u = list;
    while (u) |x| {
        if (x.target == null or x.idx == idx) break;
        u = x.next;
    }
    return u;
}

/// Port of sqlite3UpsertDoUpdate(): code the DO UPDATE of the clause for
/// the failed constraint `idx` (null for the INTEGER PRIMARY KEY), whose
/// cursor `i_cur` is on the conflicting row (an index cursor, or the
/// table's).
pub fn doUpdate(p: *Parse, top: *Upsert, t: *Table, idx: ?*Index, i_cur: i32) Oom!void {
    const v = p.vdbe.?;
    const a = p.arena;
    const i_data_cur = top.i_data_cur;
    const u = ofIndex(top, idx).?;
    if (idx) |ix| if (i_cur != i_data_cur) {
        // Move the table cursor to the conflicting row.
        if (t.hasRowid()) {
            const reg_rowid = expr_mod.getTempReg(p);
            _ = aux.addOp2(v, OP.IdxRowid, i_cur, reg_rowid);
            _ = aux.addOp3(v, OP.SeekRowid, i_data_cur, 0, reg_rowid);
            expr_mod.releaseTempReg(p, reg_rowid);
        } else {
            const pk = build.primaryKeyIndex(t).?;
            const n_pk: i32 = pk.n_key_col;
            const i_pk = p.n_mem + 1;
            p.n_mem += n_pk;
            for (0..pk.n_key_col) |i| {
                std.debug.assert(pk.ai_column[i] >= 0);
                const k = build.tableColumnToIndex(ix, pk.ai_column[i]);
                _ = aux.addOp3(v, OP.Column, i_cur, k, i_pk + @as(i32, @intCast(i)));
            }
            const addr = aux.addOp4Int(v, OP.Found, i_data_cur, 0, i_pk, n_pk);
            _ = aux.addOp4Str(v, OP.Halt, RC.CORRUPT, OE.Abort.int(), 0, "corrupt database");
            main_mod.mayAbort(p);
            aux.jumpHere(v, addr);
        }
    };
    // The INSERT owns its FROM list; the UPDATE gets a copy.
    const src = try expr_mod.srcListDup(a, top.src);
    // excluded.* columns of type REAL hold a real.
    for (t.cols, 0..) |*c, i| {
        if (c.affinity == int.Aff.real) {
            _ = aux.addOp1(v, OP.RealAffinity, top.reg_data + build.tableColumnToStorage(t, @intCast(i)));
        }
    }
    update_mod.update(p, src, try expr_mod.listDup(a, u.set), try expr_mod.exprDup(a, u.where), OE.Abort, null, null, u);
}
