//! Foreign keys (port of fkey.c): the checks INSERT, UPDATE and DELETE
//! code while PRAGMA foreign_keys is on, and the ON DELETE/ON UPDATE
//! actions, which run as trigger programs.
//!
//! Immediate constraints count violations in a statement counter
//! (OP_FkCounter) that must be zero when the statement ends; deferred ones
//! count in a connection counter checked at COMMIT.

const std = @import("std");
const int = @import("sqlite_int.zig");
const util = @import("util.zig");
const build = @import("build.zig");
const expr_mod = @import("expr.zig");
const select_mod = @import("select.zig");
const resolve = @import("resolve.zig");
const where_mod = @import("where/where.zig");
const prepare = @import("prepare.zig");
const auth = @import("auth.zig");
const main_mod = @import("main.zig");
const insert_mod = @import("insert.zig");
const delete_mod = @import("delete.zig");
const trigger_mod = @import("trigger.zig");
const coll_mod = @import("coll.zig");
const ctype = @import("xqlite_base").ctype;
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const malloc = @import("malloc.zig");

const Parse = int.Parse;
const Table = int.Table;
const Index = int.Index;
const FKey = int.FKey;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Trigger = int.Trigger;
const TriggerStep = int.TriggerStep;
const NameContext = int.NameContext;
const Token = int.Token;
const Oom = int.Oom;
const OE = int.OE;
const TK = int.TK;
const RC = int.RC;
const Aff = int.Aff;
const DbFlag = int.DbFlag;
const COLFLAG = int.COLFLAG;
const OP = vi.OP;

/// Port of sqlite3FkLocateIndex(): the UNIQUE index of `parent` on the
/// parent key of `fk`, to `idx` (null for an INTEGER PRIMARY KEY). For a
/// composite key, `ai_col` (if given) receives the child column of each
/// index column. True, with an error, if there is no such index.
pub fn fkLocateIndex(p: *Parse, parent: *Table, fk: *FKey, idx: *?*Index, ai_col: ?*?[]i32) bool {
    return fkLocateIndexImpl(p, parent, fk, idx, ai_col) catch {
        build.oomFault(p);
        return true;
    };
}

fn fkLocateIndexImpl(p: *Parse, parent: *Table, fk: *FKey, idx_out: *?*Index, ai_col_out: ?*?[]i32) Oom!bool {
    std.debug.assert(idx_out.* == null);
    const n_col = fk.cols.len;
    const z_key = fk.cols[0].col;
    var ai_col: ?[]i32 = null;

    if (n_col == 1) {
        // A single column maps to the INTEGER PRIMARY KEY if it is named
        // or no column is named.
        if (parent.i_pkey >= 0) {
            const k = z_key orelse return false;
            if (ctype.eqlNoCase(parent.cols[@intCast(parent.i_pkey)].name(), k)) return false;
        }
    } else if (ai_col_out) |out| {
        ai_col = try p.arena.alloc(i32, n_col);
        out.* = ai_col;
    }

    var found: ?*Index = null;
    var it = parent.index;
    while (it) |idx| : (it = idx.next) {
        if (idx.n_key_col != n_col or !idx.isUnique() or idx.part_idx_where != null) continue;
        if (z_key == null) {
            // No columns named: the parent key is the PRIMARY KEY.
            if (idx.isPrimaryKey()) {
                if (ai_col) |a| for (a, fk.cols) |*x, c| {
                    x.* = c.i_from;
                };
                found = idx;
                break;
            }
            continue;
        }
        // The index must cover exactly the named columns, with their
        // default collations.
        var i: usize = 0;
        while (i < n_col) : (i += 1) {
            const i_col = idx.ai_column[i];
            if (i_col < 0) break;
            const dflt_coll = build.columnColl(&parent.cols[@intCast(i_col)]) orelse coll_mod.str_binary;
            if (!ctype.eqlNoCase(idx.coll[i], dflt_coll)) break;
            const idx_col = parent.cols[@intCast(i_col)].name();
            var j: usize = 0;
            while (j < n_col) : (j += 1) {
                if (ctype.eqlNoCase(fk.cols[j].col.?, idx_col)) {
                    if (ai_col) |a| a[i] = fk.cols[j].i_from;
                    break;
                }
            }
            if (j == n_col) break;
        }
        if (i == n_col) {
            found = idx;
            break;
        }
    }

    const idx = found orelse {
        if (!p.disable_triggers) {
            util.errorMsg(p, "foreign key mismatch - \"{s}\" referencing \"{s}\"", .{ fk.from.name, fk.to });
        }
        return true;
    };
    idx_out.* = idx;
    return false;
}

/// Port of fkLookupParent(): look for the parent row of the child row in
/// the registers from `reg_data` (rowid, then the columns), adding `n_incr`
/// to the constraint counter if it is missing. `ai_col` maps the parent
/// key columns to child columns.
fn fkLookupParent(p: *Parse, i_db: usize, t: *Table, idx: ?*Index, fk: *FKey, ai_col: []const i32, reg_data: i32, n_incr: i32, is_ignore: bool) void {
    const v = build.getVdbe(p) orelse return;
    const i_cur = p.n_tab - 1;
    const i_ok = aux.makeLabel(p);

    // When decrementing, nothing to do if the counter is already zero.
    if (n_incr < 0) _ = aux.addOp2(v, OP.FkIfZero, @intFromBool(fk.is_deferred), i_ok);
    // A NULL in the child key never violates the constraint.
    for (0..fk.cols.len) |i| {
        const reg = build.tableColumnToStorage(fk.from, @intCast(ai_col[i])) + reg_data + 1;
        _ = aux.addOp2(v, OP.IsNull, reg, i_ok);
    }

    if (!is_ignore) {
        if (idx) |ix| {
            const n_col: i32 = @intCast(fk.cols.len);
            const reg_temp = expr_mod.getTempRange(p, n_col);
            _ = aux.addOp3(v, OP.OpenRead, i_cur, @intCast(ix.tnum), @intCast(i_db));
            aux.setP4KeyInfo(p, ix);
            for (0..fk.cols.len) |i| {
                const reg = build.tableColumnToStorage(fk.from, @intCast(ai_col[i])) + 1 + reg_data;
                _ = aux.addOp2(v, OP.Copy, reg, reg_temp + @as(i32, @intCast(i)));
            }
            // A row inserted into its own parent table satisfies itself.
            if (t == fk.from and n_incr == 1) {
                const i_jump = aux.currentAddr(v) + n_col + 1;
                for (0..fk.cols.len) |i| {
                    const i_child = build.tableColumnToStorage(fk.from, @intCast(ai_col[i])) + 1 + reg_data;
                    var i_parent = 1 + reg_data + build.tableColumnToStorage(ix.table, ix.ai_column[i]);
                    // A composite key that includes the IPK.
                    if (ix.ai_column[i] == t.i_pkey) i_parent = reg_data;
                    _ = aux.addOp3(v, OP.Ne, i_child, i_jump, i_parent);
                    aux.changeP5(v, vi.SQLITE_JUMPIFNULL);
                }
                _ = aux.goto_(v, i_ok);
            }
            _ = aux.addOp4Str(v, OP.Affinity, reg_temp, n_col, 0, insert_mod.indexAffinityPrefix(p, ix, fk.cols.len));
            _ = aux.addOp4Int(v, OP.Found, i_cur, i_ok, reg_temp, n_col);
            expr_mod.releaseTempRange(p, reg_temp, n_col);
        } else {
            // The parent key is the INTEGER PRIMARY KEY: a child key that
            // is not an integer has no parent.
            const reg_temp = expr_mod.getTempReg(p);
            _ = aux.addOp2(v, OP.SCopy, build.tableColumnToStorage(fk.from, @intCast(ai_col[0])) + 1 + reg_data, reg_temp);
            const i_must_be_int = aux.addOp2(v, OP.MustBeInt, reg_temp, 0);
            // A row inserted into its own parent table satisfies itself.
            if (t == fk.from and n_incr == 1) {
                _ = aux.addOp3(v, OP.Eq, reg_data, i_ok, reg_temp);
                aux.changeP5(v, vi.SQLITE_NOTNULL);
            }
            insert_mod.openTable(p, i_cur, i_db, t, OP.OpenRead);
            _ = aux.addOp3(v, OP.NotExists, i_cur, 0, reg_temp);
            _ = aux.goto_(v, i_ok);
            aux.jumpHere(v, aux.currentAddr(v) - 2);
            aux.jumpHere(v, i_must_be_int);
            expr_mod.releaseTempReg(p, reg_temp);
        }
    }

    if (!fk.is_deferred and !p.db.flags.DeferFKs and p.toplevel == null and !p.is_multi_write) {
        // An INSERT of a single row fails at once: it runs without a
        // statement transaction.
        std.debug.assert(n_incr == 1);
        build.haltConstraint(p, RC.CONSTRAINT_FOREIGNKEY, OE.Abort, null, vi.P5_ConstraintFK);
    } else {
        if (n_incr > 0 and !fk.is_deferred) main_mod.mayAbort(p);
        _ = aux.addOp2(v, OP.FkCounter, @intFromBool(fk.is_deferred), n_incr);
    }

    aux.resolveLabel(v, i_ok);
    _ = aux.addOp1(v, OP.Close, i_cur);
}

/// Port of exprTableRegister(): column `i_col` of `t` (-1 for the rowid)
/// held in the registers from `reg_base`, with its affinity and collation.
fn exprTableRegister(p: *Parse, t: *Table, reg_base: i32, i_col: i16) Oom!*Expr {
    var e = try expr_mod.expr(p.arena, TK.REGISTER, null);
    if (i_col >= 0 and i_col != t.i_pkey) {
        const col = &t.cols[@intCast(i_col)];
        e.i_table = reg_base + build.tableColumnToStorage(t, i_col) + 1;
        e.aff_expr = col.affinity;
        const coll = build.columnColl(col) orelse coll_mod.str_binary;
        e = try expr_mod.addCollateString(p, e, coll);
    } else {
        e.i_table = reg_base;
        e.aff_expr = Aff.integer;
    }
    return e;
}

/// Port of exprTableColumn(): column `i_col` of `t` open on `i_cursor`.
fn exprTableColumn(p: *Parse, t: *Table, i_cursor: i32, i_col: i16) Oom!*Expr {
    const e = try expr_mod.expr(p.arena, TK.COLUMN, null);
    e.y = .{ .tab = t };
    e.i_table = i_cursor;
    e.i_column = i_col;
    return e;
}

/// Port of fkScanChildren(): add `n_incr` to the constraint counter for
/// each row of the child table `src` that refers to the parent row in the
/// registers from `reg_data`.
fn fkScanChildren(p: *Parse, src: *SrcList, t: *Table, idx: ?*Index, fk: *FKey, ai_col: ?[]const i32, reg_data: i32, n_incr: i32) Oom!void {
    const v = build.getVdbe(p) orelse return;
    var i_fk_if_zero: i32 = 0;
    if (n_incr < 0) i_fk_if_zero = aux.addOp2(v, OP.FkIfZero, @intFromBool(fk.is_deferred), 0);

    // WHERE parent.key1 = child.col1 AND ...
    var where: ?*Expr = null;
    for (0..fk.cols.len) |i| {
        const left = try exprTableRegister(p, t, reg_data, if (idx) |ix| ix.ai_column[i] else -1);
        const i_col = if (ai_col) |a| a[i] else fk.cols[0].i_from;
        const right = try expr_mod.expr(p.arena, TK.ID, fk.from.cols[@intCast(i_col)].name());
        where = try expr_mod.exprAnd(p, where, try expr_mod.pExpr(p, TK.EQ, left, right));
    }

    // A row of a self-referencing table does not refer to itself while it
    // is being deleted: AND NOT (it is the same row).
    if (t == fk.from and n_incr > 0) {
        var ne: *Expr = undefined;
        if (t.hasRowid()) {
            const left = try exprTableRegister(p, t, reg_data, -1);
            const right = try exprTableColumn(p, t, src.at(0).i_cursor, -1);
            ne = try expr_mod.pExpr(p, TK.NE, left, right);
        } else {
            const ix = idx.?;
            var all: ?*Expr = null;
            for (0..ix.n_key_col) |i| {
                const i_col = ix.ai_column[i];
                const left = try exprTableRegister(p, t, reg_data, i_col);
                const right = try expr_mod.expr(p.arena, TK.ID, t.cols[@intCast(i_col)].name());
                all = try expr_mod.exprAnd(p, all, try expr_mod.pExpr(p, TK.IS, left, right));
            }
            ne = try expr_mod.pExpr(p, TK.NOT, all, null);
        }
        where = try expr_mod.exprAnd(p, where, ne);
    }

    var nc: NameContext = .{ .parse = p, .src_list = src };
    resolve.resolveExprNames(&nc, where) catch {};

    if (p.n_err == 0) {
        const w = where_mod.whereBegin(p, src, where, null, null, null, .{}, 0);
        _ = aux.addOp2(v, OP.FkCounter, @intFromBool(fk.is_deferred), n_incr);
        if (w) |wi| where_mod.whereEnd(wi);
    }
    if (i_fk_if_zero != 0) aux.jumpHereOrPopInst(v, i_fk_if_zero);
}

/// Port of sqlite3FkReferences(): the foreign keys that refer to `t`.
pub fn fkReferences(t: *Table) ?*FKey {
    const s = t.schema orelse return null;
    return s.fkey_hash.get(t.name);
}

/// Port of sqlite3FkDropTable(): before DROP TABLE, delete its rows (with
/// triggers off) so that the foreign keys referring to it are checked.
pub fn fkDropTable(p: *Parse, name: *SrcList, t: *Table) void {
    fkDropTableImpl(p, name, t) catch build.oomFault(p);
}

fn fkDropTableImpl(p: *Parse, name: *SrcList, t: *Table) Oom!void {
    const db = p.db;
    if (!db.flags.ForeignKeys or !t.isOrdinary()) return;
    const v = build.getVdbe(p) orelse return;
    var i_skip: i32 = 0;
    if (fkReferences(t) == null) {
        // Only its own deferred foreign keys matter: if the counter is
        // zero, dropping the table changes nothing.
        var it = t.u.tab.fkey;
        while (it) |fk| : (it = fk.next_from) {
            if (fk.is_deferred or db.flags.DeferFKs) break;
        }
        if (it == null) return;
        i_skip = aux.makeLabel(p);
        _ = aux.addOp2(v, OP.FkIfZero, 1, i_skip);
    }

    p.disable_triggers = true;
    delete_mod.deleteFrom(p, try expr_mod.srcListDup(p.arena, name), null, null, null);
    p.disable_triggers = false;

    // An immediate violation fails the DROP now, not at the end of the
    // statement (which would drop the table anyway).
    if (!db.flags.DeferFKs) {
        _ = aux.addOp2(v, OP.FkIfZero, 0, aux.currentAddr(v) + 2);
        build.haltConstraint(p, RC.CONSTRAINT_FOREIGNKEY, OE.Abort, null, vi.P5_ConstraintFK);
    }
    if (i_skip != 0) aux.resolveLabel(v, i_skip);
}

/// Port of fkChildIsModified(): whether an UPDATE changes the child key
/// of `fk` (`a_change[i]` >= 0 for a changed column i).
fn fkChildIsModified(t: *Table, fk: *FKey, a_change: []const i32, chng_rowid: bool) bool {
    for (fk.cols) |c| {
        if (a_change[@intCast(c.i_from)] >= 0) return true;
        if (c.i_from == t.i_pkey and chng_rowid) return true;
    }
    return false;
}

/// Port of fkParentIsModified(): whether an UPDATE changes the parent key
/// of `fk`.
fn fkParentIsModified(t: *Table, fk: *FKey, a_change: []const i32, chng_rowid: bool) bool {
    for (fk.cols) |c| {
        for (t.cols, 0..) |*col, k| {
            if (a_change[k] >= 0 or (@as(i32, @intCast(k)) == t.i_pkey and chng_rowid)) {
                if (c.col) |z_key| {
                    if (ctype.eqlNoCase(col.name(), z_key)) return true;
                } else if (col.col_flags.PRIMKEY) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Port of isSetNullAction(): whether `p` codes the SET NULL action of
/// `fk`.
fn isSetNullAction(p: *Parse, fk: *FKey) bool {
    const top = build.toplevel(p);
    const prg = top.trigger_prg orelse return false;
    const trig = prg.trigger;
    return (fk.trigger[0] == trig and fk.a_action[0] == OE.SetNull) or
        (fk.trigger[1] == trig and fk.a_action[1] == OE.SetNull);
}

/// Port of sqlite3FkCheck(): code the foreign key checks of writing a row
/// of `t`. For a DELETE the old row (rowid, then columns) is in registers
/// from `reg_old` and `reg_new` is 0; for an INSERT the reverse. An UPDATE
/// calls it twice: before deleting the old record and before inserting
/// the new one. `a_change` (UPDATE) tells the changed columns.
pub fn fkCheck(p: *Parse, t: *Table, reg_old: i32, reg_new: i32, a_change: ?[]const i32, chng_rowid: bool) void {
    fkCheckImpl(p, t, reg_old, reg_new, a_change, chng_rowid) catch build.oomFault(p);
}

fn fkCheckImpl(p: *Parse, t: *Table, reg_old: i32, reg_new: i32, a_change: ?[]const i32, chng_rowid: bool) Oom!void {
    const db = p.db;
    const is_ignore_errors = p.disable_triggers;
    std.debug.assert((reg_old == 0) != (reg_new == 0));
    if (!db.flags.ForeignKeys) return;
    if (!t.isOrdinary()) return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const zdb = db.dbs.items[i_db].name;

    // The foreign keys of `t` (as the child).
    var fk_it = t.u.tab.fkey;
    while (fk_it) |fk| : (fk_it = fk.next_from) {
        if (a_change) |ac| {
            if (!ctype.eqlNoCase(t.name, fk.to) and !fkChildIsModified(t, fk, ac, chng_rowid)) continue;
        }

        // The parent table, and its index on the parent key.
        const to = if (p.disable_triggers) build.findTable(db, fk.to, zdb) else build.locateTable(p, 0, fk.to, zdb);
        var idx: ?*Index = null;
        var ai_free: ?[]i32 = null;
        if (to == null or fkLocateIndex(p, to.?, fk, &idx, &ai_free)) {
            std.debug.assert(!is_ignore_errors or (reg_old != 0 and reg_new == 0));
            if (!is_ignore_errors or db.malloc_failed) return;
            if (to == null) {
                // DROP TABLE of a table whose parent is missing: the parent
                // counts as empty, so each child row with a non-NULL key
                // was a violation.
                const v = build.getVdbe(p) orelse return;
                const i_jump = aux.currentAddr(v) + @as(i32, @intCast(fk.cols.len)) + 1;
                for (fk.cols) |c| {
                    const reg = build.tableColumnToStorage(fk.from, @intCast(c.i_from)) + reg_old + 1;
                    _ = aux.addOp2(v, OP.IsNull, reg, i_jump);
                }
                _ = aux.addOp2(v, OP.FkCounter, @intFromBool(fk.is_deferred), -1);
            }
            continue;
        }
        const pt = to.?;
        var single = [1]i32{fk.cols[0].i_from};
        const ai_col: []i32 = ai_free orelse &single;
        // With the authorizer, the parent key columns must be readable;
        // IGNORE makes them read as NULL.
        var b_ignore = false;
        for (ai_col, 0..) |*c, i| {
            if (c.* == t.i_pkey) c.* = -1;
            if (db.auth != null) {
                const col = pt.cols[@intCast(if (idx) |ix| ix.ai_column[i] else pt.i_pkey)].name();
                b_ignore = auth.readCol(p, pt.name, col, i_db) == auth.IGNORE;
            }
        }

        p.n_tab += 1;
        // A child row removed may resolve a violation; one added may
        // cause one (but not as the SET NULL action of this very key).
        if (reg_old != 0) fkLookupParent(p, i_db, pt, idx, fk, ai_col, reg_old, -1, b_ignore);
        if (reg_new != 0 and !isSetNullAction(p, fk)) fkLookupParent(p, i_db, pt, idx, fk, ai_col, reg_new, 1, b_ignore);
    }

    // The foreign keys referring to `t` (as the parent).
    fk_it = fkReferences(t);
    while (fk_it) |fk| : (fk_it = fk.next_to) {
        if (a_change) |ac| if (!fkParentIsModified(t, fk, ac, chng_rowid)) continue;

        // Inserting one row into a parent table cannot cause (or fix) an
        // immediate violation.
        if (!fk.is_deferred and !db.flags.DeferFKs and p.toplevel == null and !p.is_multi_write) {
            std.debug.assert(reg_old == 0 and reg_new != 0);
            continue;
        }

        var idx: ?*Index = null;
        var ai_col: ?[]i32 = null;
        if (fkLocateIndex(p, t, fk, &idx, &ai_col)) {
            if (!is_ignore_errors or db.malloc_failed) return;
            continue;
        }

        // The child table, as a FROM clause to scan.
        const src = (try build.srcListAppend(p, null, null, null)) orelse return;
        const item = src.at(0);
        item.s_tab = fk.from;
        item.name = fk.from.name;
        build.tableRef(p, fk.from);
        item.i_cursor = p.n_tab;
        p.n_tab += 1;

        if (reg_new != 0) try fkScanChildren(p, src, t, idx, fk, ai_col, reg_new, -1);
        if (reg_old != 0) {
            var e_action = fk.a_action[@intFromBool(a_change != null)];
            if (db.flags.FkNoAction) e_action = OE.None;
            try fkScanChildren(p, src, t, idx, fk, ai_col, reg_old, 1);
            // A CASCADE or SET NULL action (or the check at COMMIT) fixes
            // what removing the parent breaks.
            if (!fk.is_deferred and e_action != OE.Cascade and e_action != OE.SetNull) main_mod.mayAbort(p);
        }
    }
}

/// COLUMN_MASK(): bit `x` of a column mask (all bits past the 32nd).
fn columnMask(x: i32) u32 {
    return if (x > 31) 0xffffffff else @as(u32, 1) << @intCast(x);
}

/// Port of sqlite3FkOldmask(): the columns of the old row the foreign key
/// processing of an UPDATE or DELETE of `t` reads.
pub fn fkOldmask(p: *Parse, t: *Table) u32 {
    var mask: u32 = 0;
    if (!p.db.flags.ForeignKeys or !t.isOrdinary()) return mask;
    var it = t.u.tab.fkey;
    while (it) |fk| : (it = fk.next_from) {
        for (fk.cols) |c| mask |= columnMask(c.i_from);
    }
    it = fkReferences(t);
    while (it) |fk| : (it = fk.next_to) {
        var idx: ?*Index = null;
        _ = fkLocateIndex(p, t, fk, &idx, null);
        if (idx) |ix| {
            for (ix.ai_column[0..ix.n_key_col]) |c| mask |= columnMask(c);
        }
    }
    return mask;
}

/// Port of sqlite3FkRequired(): nonzero if writing `t` needs foreign key
/// processing. For an UPDATE (`a_change` given), 2 if `t` refers to itself
/// or a parent key with an action changes.
pub fn fkRequired(p: *Parse, t: *Table, a_change: ?[]const i32, chng_rowid: bool) u8 {
    var ret: u8 = 1;
    var have_fk = false;
    if (!p.db.flags.ForeignKeys or !t.isOrdinary()) return 0;
    if (a_change) |ac| {
        // An UPDATE needs it only if a child or parent key changes.
        var it = t.u.tab.fkey;
        while (it) |fk| : (it = fk.next_from) {
            if (fkChildIsModified(t, fk, ac, chng_rowid)) {
                if (ctype.eqlNoCase(t.name, fk.to)) ret = 2;
                have_fk = true;
            }
        }
        it = fkReferences(t);
        while (it) |fk| : (it = fk.next_to) {
            if (fkParentIsModified(t, fk, ac, chng_rowid)) {
                if (!p.db.flags.FkNoAction and fk.a_action[1] != OE.None) return 2;
                have_fk = true;
            }
        }
    } else {
        // A DELETE needs it if `t` is a child or a parent.
        have_fk = fkReferences(t) != null or t.u.tab.fkey != null;
    }
    return if (have_fk) ret else 0;
}

/// Port of fkActionTrigger(): the trigger that implements the ON DELETE
/// (`changes` null) or ON UPDATE action of `fk` on its parent `t`, made on
/// first use and kept with the foreign key. Null for NO ACTION.
///
/// For "CREATE TABLE c(ck REFERENCES p ON DELETE CASCADE)" it is like
/// "CREATE TRIGGER ... DELETE ON p BEGIN DELETE FROM c WHERE ck = old.pk;
/// END". Such a trigger has no name (an empty one here, with
/// is_fk_action set).
fn fkActionTrigger(p: *Parse, t: *Table, fk: *FKey, changes: ?*ExprList) Oom!?*Trigger {
    const db = p.db;
    const i_action = @intFromBool(changes != null);
    var action = fk.a_action[i_action];
    if (db.flags.FkNoAction) action = OE.None;
    if (action == OE.Restrict and db.flags.DeferFKs) return null;
    if (action == OE.None or fk.trigger[i_action] != null) return fk.trigger[i_action];

    var idx: ?*Index = null;
    var ai_col: ?[]i32 = null;
    if (fkLocateIndex(p, t, fk, &idx, &ai_col)) return null;

    const a = p.arena;
    var where: ?*Expr = null;
    var when: ?*Expr = null;
    var list: ?*ExprList = null;
    const t_old = Token.init("old");
    const t_new = Token.init("new");
    for (0..fk.cols.len) |i| {
        const i_from_col = if (ai_col) |ac| ac[i] else fk.cols[0].i_from;
        const t_to_col = Token.init(t.cols[@intCast(if (idx) |ix| ix.ai_column[i] else t.i_pkey)].name());
        const t_from_col = Token.init(fk.from.cols[@intCast(i_from_col)].name());

        // "OLD.to_col = from_col", OLD.to_col on the left so that the
        // parent's affinity and collation apply.
        const eq = try expr_mod.pExpr(p, TK.EQ, try dotExpr(p, t_old, t_to_col), try expr_mod.exprAlloc(a, TK.ID, t_from_col, false));
        where = try expr_mod.exprAnd(p, where, eq);

        // ON UPDATE: WHEN NOT(old.col1 IS new.col1 AND ...).
        if (changes != null) {
            const is = try expr_mod.pExpr(p, TK.IS, try dotExpr(p, t_old, t_to_col), try dotExpr(p, t_new, t_to_col));
            when = try expr_mod.exprAnd(p, when, is);
        }

        if (action != OE.Restrict and (action != OE.Cascade or changes != null)) {
            var new: *Expr = undefined;
            if (action == OE.Cascade) {
                new = try dotExpr(p, t_new, t_to_col);
            } else if (action == OE.SetDflt) {
                const col = &fk.from.cols[@intCast(i_from_col)];
                const dflt = if (col.col_flags.intersects(COLFLAG.GENERATED)) null else build.columnExprAuth(fk.from, col, p);
                new = if (dflt) |d| (try expr_mod.exprDup(a, d)).? else try expr_mod.exprAlloc(a, TK.NULL, null, false);
            } else {
                new = try expr_mod.exprAlloc(a, TK.NULL, null, false);
            }
            list = try expr_mod.listAppend(p, list, new);
            try expr_mod.listSetName(p, list, t_from_col, false);
        }
    }

    const z_from = fk.from.name;
    var sel: ?*int.Select = null;
    if (action == OE.Restrict) {
        // SELECT RAISE(ABORT, ...) FROM child WHERE ...
        const raise = try expr_mod.pExpr(p, TK.RAISE, try expr_mod.expr(a, TK.STRING, "FOREIGN KEY constraint failed"), null);
        raise.aff_expr = OE.Abort.int();
        const src = (try build.srcListAppend(p, null, null, null)) orelse return null;
        const item = src.at(0);
        item.name = try a.dupeSentinel(u8, z_from, 0);
        item.fg.fixed_schema = true;
        item.u4 = .{ .schema = t.schema };
        sel = try select_mod.selectNew(p, try expr_mod.listAppend(p, null, raise), src, where, null, null, null, .{}, null);
        where = null;
    }

    // The trigger lives with the foreign key, in the memory of its table:
    // not in lookaside.
    malloc.disableLookaside(db);
    defer malloc.enableLookaside(db);
    const m = build.tableAlloc(p, fk.from);
    const trig = try m.create(Trigger);
    const step = try m.create(TriggerStep);
    const step_src = try m.create(SrcList);
    step_src.* = .{};
    try step_src.items.append(m, .{ .name = try m.dupeSentinel(u8, z_from, 0), .u4 = .{ .schema = t.schema } });
    step_src.items.items[0].fg.fixed_schema = true;
    step.* = .{
        .op = switch (action) {
            OE.Restrict => TK.SELECT,
            OE.Cascade => if (changes == null) TK.DELETE else TK.UPDATE,
            else => TK.UPDATE,
        },
        .trig = trig,
        .src = step_src,
        .where = try expr_mod.exprDup(m, where),
        .expr_list = try expr_mod.listDup(m, list),
        .select = try expr_mod.selectDup(m, sel),
    };
    step.last = step;
    trig.* = .{
        .name = try m.dupeSentinel(u8, "", 0),
        .table = try m.dupeSentinel(u8, "", 0),
        .op = if (changes != null) TK.UPDATE else TK.DELETE,
        .tr_tm = 0,
        .when = if (when) |w| try expr_mod.exprDup(m, try expr_mod.pExpr(p, TK.NOT, w, null)) else null,
        .schema = t.schema,
        .tab_schema = t.schema,
        .step_list = step,
        .is_fk_action = true,
    };
    fk.trigger[i_action] = trig;
    return trig;
}

/// "tbl.col", as the parser builds it.
fn dotExpr(p: *Parse, tbl: Token, col: Token) Oom!*Expr {
    return expr_mod.pExpr(p, TK.DOT, try expr_mod.exprAlloc(p.arena, TK.ID, tbl, false), try expr_mod.exprAlloc(p.arena, TK.ID, col, false));
}

/// Port of sqlite3FkActions(): code the CASCADE, SET NULL and SET DEFAULT
/// actions of the foreign keys referring to `t`, for a DELETE (`changes`
/// null) or UPDATE of the row whose old values are in registers from
/// `reg_old`.
pub fn fkActions(p: *Parse, t: *Table, changes: ?*ExprList, reg_old: i32, a_change: ?[]const i32, chng_rowid: bool) void {
    if (!p.db.flags.ForeignKeys) return;
    var it = fkReferences(t);
    while (it) |fk| : (it = fk.next_to) {
        if (a_change == null or fkParentIsModified(t, fk, a_change.?, chng_rowid)) {
            const act = fkActionTrigger(p, t, fk, changes) catch {
                build.oomFault(p);
                return;
            };
            if (act) |trig| trigger_mod.codeRowTriggerDirect(p, trig, t, reg_old, OE.Abort, 0);
        }
    }
}

/// Port of sqlite3FkDelete(): unlink the foreign keys of a table being
/// freed from its schema's fkey_hash. Their memory (and that of their
/// action triggers) belongs to the table.
pub fn fkDelete(db: *int.Sqlite3, t: *Table) void {
    _ = db;
    std.debug.assert(t.isOrdinary());
    var fk_opt = t.u.tab.fkey;
    while (fk_opt) |fk| : (fk_opt = fk.next_from) {
        if (fk.prev_to) |prev| {
            prev.next_to = fk.next_to;
        } else if (t.schema) |s| {
            if (fk.next_to) |next| {
                // The key must not stay the name in `fk`'s memory.
                if (s.fkey_hash.getEntry(next.to)) |entry| {
                    entry.key_ptr.* = next.to;
                    entry.value_ptr.* = next;
                }
            } else {
                _ = s.fkey_hash.remove(fk.to);
            }
        }
        if (fk.next_to) |next| next.prev_to = fk.prev_to;
    }
}
