//! DELETE statements (port of delete.c): the DELETE driver, and the row
//! and index-entry deletes INSERT and UPDATE share. Views, triggers and
//! DELETE ... LIMIT come later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const build = @import("build.zig");
const expr_mod = @import("expr.zig");
const select_mod = @import("select.zig");
const SF = int.SF;
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const util = @import("util.zig");
const prepare = @import("prepare.zig");
const insert = @import("insert.zig");
const trigger = @import("trigger.zig");
const fkey = @import("fkey.zig");
const where_mod = @import("where.zig");
const main_mod = @import("main.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Table = int.Table;
const Index = int.Index;
const Trigger = int.Trigger;
const NameContext = int.NameContext;
const Vdbe = vi.Vdbe;
const Oom = int.Oom;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const TF = int.TF;
const TK = int.TK;
const OE = int.OE;
const NC = int.NC;
const WHERE = int.WHERE;
const ONEPASS_OFF = where_mod.ONEPASS_OFF;
const ONEPASS_SINGLE = where_mod.ONEPASS_SINGLE;
const ONEPASS_MULTI = where_mod.ONEPASS_MULTI;

/// Port of sqlite3CodeChangeCount(): return the number of rows changed
/// as the statement's result.
pub fn codeChangeCount(v: *Vdbe, reg_counter: i32, col_name: [:0]const u8) void {
    _ = aux.addOp0(v, OP.FkCheck);
    _ = aux.addOp2(v, OP.ResultRow, reg_counter, 1);
    aux.setNumCols(v, 1);
    aux.setColName(v, 0, vi.COLNAME_NAME, col_name);
}

/// Port of tabIsReadOnly(): sqlite_schema (outside nested parses and
/// writable_schema) and, in defensive mode, shadow tables.
fn tabIsReadOnly(p: *Parse, t: *Table) bool {
    if (t.e_tab_type == .vtab) return false;
    if (t.tab_flags & (TF.Readonly | TF.Shadow) == 0) return false;
    if (t.tab_flags & TF.Readonly != 0) return !build.writableSchema(p.db) and p.nested == 0;
    return build.readOnlyShadowTables(p.db);
}

/// Port of sqlite3IsReadOnly(): an error unless `t` may be written.
pub fn isReadOnly(p: *Parse, t: *Table, trig: ?*Trigger) bool {
    if (tabIsReadOnly(p, t)) {
        util.errorMsg(p, "table {s} may not be modified", .{t.name});
        return true;
    }
    if (t.isView() and trig == null) {
        util.errorMsg(p, "cannot modify {s} because it is a view", .{t.name});
        return true;
    }
    return false;
}

/// Port of sqlite3DeleteFrom(): DELETE FROM `tab_list` WHERE `where`.
pub fn deleteFrom(p: *Parse, tab_list: ?*SrcList, where: ?*Expr, order_by: ?*ExprList, limit: ?*Expr) void {
    if (p.syntax_only) return;
    _ = .{ order_by, limit };
    deleteFromImpl(p, tab_list.?, where) catch build.oomFault(p);
}

fn deleteFromImpl(p: *Parse, tab_list: *SrcList, where: ?*Expr) Oom!void {
    const db = p.db;
    if (p.n_err != 0) return;

    const t = build.srcListLookup(p, tab_list) orelse return;
    const trig = trigger.triggersExist(p, t, TK.DELETE, null, null);
    const is_view = t.isView();
    var b_complex = trig != null or fkey.fkRequired(p, t, null, false) != 0;
    if (p.n_err != 0) return;
    if (build.viewGetColumnNames(p, t) != 0) return;
    if (isReadOnly(p, t, trig)) return;
    if (t.e_tab_type == .vtab) {
        pending.notYet(p, "virtual tables");
        return;
    }
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));

    // Cursors for the table and its indexes.
    const i_tab_cur = p.n_tab;
    tab_list.at(0).i_cursor = i_tab_cur;
    p.n_tab += 1;
    var n_idx: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |ix| : (idx_opt = ix.next) {
        p.n_tab += 1;
        n_idx += 1;
    }

    const v = build.getVdbe(p) orelse return;
    if (p.nested == 0) aux.countChanges(v);
    build.beginWriteOperation(p, b_complex, i_db);

    // A view (with INSTEAD OF triggers) is realized into an ephemeral
    // table.
    var i_data_cur: i32 = 0;
    var i_idx_cur: i32 = 0;
    if (is_view) {
        materializeView(p, t, where, null, null, i_tab_cur);
        i_data_cur = i_tab_cur;
        i_idx_cur = i_tab_cur;
    }

    var nc: NameContext = .{ .parse = p, .src_list = tab_list };
    if (resolve.resolveExprNames(&nc, where) != 0) return;

    var mem_cnt: i32 = 0;
    if (db.flags & int.DbFlag.CountRows != 0 and p.nested == 0 and p.trigger_tab == null and !p.returning) {
        p.n_mem += 1;
        mem_cnt = p.n_mem;
        _ = aux.addOp2(v, OP.Integer, 0, mem_cnt);
    }

    if (where == null and !b_complex) {
        // Without a WHERE clause the b-trees are just cleared.
        if (t.hasRowid()) {
            _ = aux.addOp4Str(v, OP.Clear, @intCast(t.tnum), @intCast(i_db), if (mem_cnt != 0) mem_cnt else -1, t.name);
        }
        idx_opt = t.index;
        while (idx_opt) |ix| : (idx_opt = ix.next) {
            if (ix.isPrimaryKey() and !t.hasRowid()) {
                _ = aux.addOp3(v, OP.Clear, @intCast(ix.tnum), @intCast(i_db), if (mem_cnt != 0) mem_cnt else -1);
            } else {
                _ = aux.addOp2(v, OP.Clear, @intCast(ix.tnum), @intCast(i_db));
            }
        }
    } else {
        var wcf: u16 = WHERE.ONEPASS_DESIRED | WHERE.DUPLICATES_OK;
        if (nc.nc_flags & NC.Subquery != 0) b_complex = true;
        if (!b_complex) wcf |= WHERE.ONEPASS_MULTIROW;

        // The keys of the rows to delete: a RowSet of rowids, or for a
        // WITHOUT ROWID table an ephemeral table of PRIMARY KEYs.
        var pk: ?*Index = null;
        var n_pk: i16 = 1;
        var i_pk: i32 = 0;
        var i_eph_cur: i32 = 0;
        var i_row_set: i32 = 0;
        var addr_eph_open: i32 = 0;
        if (t.hasRowid()) {
            p.n_mem += 1;
            i_row_set = p.n_mem;
            _ = aux.addOp2(v, OP.Null, 0, i_row_set);
        } else {
            pk = build.primaryKeyIndex(t);
            n_pk = @intCast(pk.?.n_key_col);
            i_pk = p.n_mem + 1;
            p.n_mem += n_pk;
            i_eph_cur = p.n_tab;
            p.n_tab += 1;
            addr_eph_open = aux.addOp2(v, OP.OpenEphemeral, i_eph_cur, n_pk);
            aux.setP4KeyInfo(p, pk.?);
        }

        // The rows matching the WHERE clause.
        const w = where_mod.whereBegin(p, tab_list, where, null, null, null, wcf, i_tab_cur + 1) orelse return;
        var ai_cur_one_pass: [2]i32 = .{ -1, -1 };
        const e_one_pass = where_mod.okOnePass(w, &ai_cur_one_pass);
        if (e_one_pass != ONEPASS_SINGLE) main_mod.multiWrite(p);
        if (where_mod.usesDeferredSeek(w)) _ = aux.addOp1(v, OP.FinishSeek, i_tab_cur);
        if (mem_cnt != 0) _ = aux.addOp2(v, OP.AddImm, mem_cnt, 1);

        // The key of the current row.
        var i_key: i32 = undefined;
        if (pk) |k| {
            for (0..k.n_key_col) |i| {
                ec.codeGetColumnOfTable(v, t, i_tab_cur, k.ai_column[i], i_pk + @as(i32, @intCast(i)));
            }
            i_key = i_pk;
        } else {
            p.n_mem += 1;
            i_key = p.n_mem;
            ec.codeGetColumnOfTable(v, t, i_tab_cur, -1, i_key);
        }

        var n_key: i16 = undefined;
        var to_open: ?[]bool = null;
        var addr_bypass: i32 = 0;
        if (e_one_pass != ONEPASS_OFF) {
            // One pass: the key stays in its registers.
            n_key = n_pk;
            const o = try p.arena.alloc(bool, n_idx + 2);
            @memset(o, true);
            o[n_idx + 1] = false;
            if (ai_cur_one_pass[0] >= 0) o[@intCast(ai_cur_one_pass[0] - i_tab_cur)] = false;
            if (ai_cur_one_pass[1] >= 0) o[@intCast(ai_cur_one_pass[1] - i_tab_cur)] = false;
            to_open = o;
            if (addr_eph_open != 0) _ = aux.changeToNoop(v, addr_eph_open);
            addr_bypass = aux.makeLabel(p);
        } else {
            if (pk) |k| {
                p.n_mem += 1;
                i_key = p.n_mem;
                n_key = 0;
                _ = aux.addOp4Str(v, OP.MakeRecord, i_pk, n_pk, i_key, insert.indexAffinityPrefix(p, k, @intCast(n_pk)));
                _ = aux.addOp4Int(v, OP.IdxInsert, i_eph_cur, i_key, i_pk, n_pk);
            } else {
                n_key = 1;
                _ = aux.addOp2(v, OP.RowSetAdd, i_row_set, i_key);
            }
            where_mod.whereEnd(w);
        }

        // Open the table and its indexes for writing (a view only fires
        // its INSTEAD OF triggers).
        if (!is_view) {
            var i_addr_once: i32 = 0;
            if (e_one_pass == ONEPASS_MULTI) i_addr_once = aux.addOp0(v, OP.Once);
            _ = insert.openTableAndIndices(p, t, OP.OpenWrite, OPFLAG.FORDELETE, i_tab_cur, to_open, &i_data_cur, &i_idx_cur);
            if (e_one_pass == ONEPASS_MULTI) aux.jumpHereOrPopInst(v, i_addr_once);
        }

        // The loop over the keys found.
        var addr_loop: i32 = 0;
        if (e_one_pass != ONEPASS_OFF) {
            if (to_open.?[@intCast(i_data_cur - i_tab_cur)]) {
                _ = aux.addOp4Int(v, OP.NotFound, i_data_cur, addr_bypass, i_key, n_key);
            }
        } else if (pk != null) {
            addr_loop = aux.addOp1(v, OP.Rewind, i_eph_cur);
            _ = aux.addOp2(v, OP.RowData, i_eph_cur, i_key);
        } else {
            addr_loop = aux.addOp3(v, OP.RowSetRead, i_row_set, 0, i_key);
        }

        generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, i_key, n_key, p.nested == 0, OE.Default, e_one_pass, ai_cur_one_pass[1]);

        if (e_one_pass != ONEPASS_OFF) {
            aux.resolveLabel(v, addr_bypass);
            where_mod.whereEnd(w);
        } else if (pk != null) {
            _ = aux.addOp2(v, OP.Next, i_eph_cur, addr_loop + 1);
            aux.jumpHere(v, addr_loop);
        } else {
            _ = aux.goto_(v, addr_loop);
            aux.jumpHere(v, addr_loop);
        }
    }

    if (p.nested == 0 and p.trigger_tab == null) insert.autoincrementEnd(p);
    if (mem_cnt != 0) codeChangeCount(v, mem_cnt, "rows deleted");
}

/// Port of sqlite3MaterializeView(): code the rows of view `view` that
/// match `where` into the ephemeral table `i_cur`.
pub fn materializeView(p: *Parse, view: *Table, where: ?*Expr, order_by: ?*ExprList, limit: ?*Expr, i_cur: i32) void {
    materializeViewImpl(p, view, where, order_by, limit, i_cur) catch build.oomFault(p);
}

fn materializeViewImpl(p: *Parse, view: *Table, where_arg: ?*Expr, order_by: ?*ExprList, limit: ?*Expr, i_cur: i32) int.Oom!void {
    const db = p.db;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, view.schema));
    const where = try expr_mod.exprDup(p.arena, where_arg);
    const from = (try build.srcListAppend(p, null, null, null)) orelse return;
    const item = from.at(0);
    item.name = try p.arena.dupeSentinel(u8, view.name, 0);
    item.u4 = .{ .database = try p.arena.dupeSentinel(u8, db.dbs.items[i_db].name, 0) };
    const sel = try select_mod.selectNew(p, null, from, where, null, null, order_by, SF.IncludeHidden, limit);
    var dest = select_mod.selectDestInit(select_mod.SRT.EphemTab, i_cur);
    _ = select_mod.select(p, sel, &dest);
}

/// Port of sqlite3GenerateRowDelete(): delete one row and its index
/// entries. Its key is in the `n_pk` registers from `i_pk` (a record if
/// `n_pk` is 0); with `e_mode` other than ONEPASS_OFF `i_data_cur`
/// already points at it. `i_idx_no_seek`, if not negative, is an index
/// cursor already on the row's entry.
pub fn generateRowDelete(
    p: *Parse,
    t: *Table,
    trig: ?*Trigger,
    i_data_cur: i32,
    i_idx_cur: i32,
    i_pk: i32,
    n_pk: i16,
    count: bool,
    onconf: u8,
    e_mode: u8,
    i_idx_no_seek_arg: i32,
) void {
    const v = p.vdbe.?;
    var i_idx_no_seek = i_idx_no_seek_arg;
    var i_old: i32 = 0;

    // Seek the row; it may be gone already (deleted by a trigger).
    const i_label = aux.makeLabel(p);
    const op_seek: u8 = if (t.hasRowid()) OP.NotExists else OP.NotFound;
    if (e_mode == ONEPASS_OFF) _ = aux.addOp4Int(v, op_seek, i_data_cur, i_label, i_pk, n_pk);

    // The OLD.* registers of triggers and foreign keys.
    if (fkey.fkRequired(p, t, null, false) != 0 or trig != null) {
        var mask = trigger.triggerColmask(p, trig, null, false, int.TRIGGER_BEFORE | int.TRIGGER_AFTER, t, onconf);
        mask |= fkey.fkOldmask(p, t);
        i_old = p.n_mem + 1;
        p.n_mem += 1 + @as(i32, @intCast(t.cols.len));
        _ = aux.addOp2(v, OP.Copy, i_pk, i_old);
        for (0..t.cols.len) |i_col| {
            if (mask == 0xffffffff or (i_col <= 31 and mask & (@as(u32, 1) << @intCast(i_col)) != 0)) {
                const kk = build.tableColumnToStorage(t, @intCast(i_col));
                ec.codeGetColumnOfTable(v, t, i_data_cur, @intCast(i_col), i_old + kk + 1);
            }
        }
        const addr_start = aux.currentAddr(v);
        trigger.codeRowTrigger(p, trig, TK.DELETE, null, int.TRIGGER_BEFORE, t, i_old, onconf, i_label);
        // BEFORE triggers may have moved the cursor or deleted the row.
        if (addr_start < aux.currentAddr(v)) {
            _ = aux.addOp4Int(v, op_seek, i_data_cur, i_label, i_pk, n_pk);
            i_idx_no_seek = -1;
        }
        fkey.fkCheck(p, t, i_old, 0, null, false);
    }

    // The index entries and the row. OP_Delete with OPFLAG_NCHANGE counts
    // the change (and calls the update hook).
    if (!t.isView()) {
        var p5: u16 = 0;
        generateRowIndexDelete(p, t, i_data_cur, i_idx_cur, null, i_idx_no_seek);
        _ = aux.addOp2(v, OP.Delete, i_data_cur, if (count) OPFLAG.NCHANGE else 0);
        if (p.nested == 0 or std.ascii.eqlIgnoreCase(t.name, "sqlite_stat1")) aux.appendP4(v, .{ .table = t });
        if (e_mode != ONEPASS_OFF) aux.changeP5(v, OPFLAG.AUXDELETE);
        if (i_idx_no_seek >= 0 and i_idx_no_seek != i_data_cur) _ = aux.addOp1(v, OP.Delete, i_idx_no_seek);
        if (e_mode == ONEPASS_MULTI) p5 |= OPFLAG.SAVEPOSITION;
        aux.changeP5(v, p5);
    }

    fkey.fkActions(p, t, null, i_old, null, false);
    if (trig != null) trigger.codeRowTrigger(p, trig, TK.DELETE, null, int.TRIGGER_AFTER, t, i_old, onconf, i_label);
    aux.resolveLabel(v, i_label);
}

/// Port of sqlite3GenerateRowIndexDelete(): delete the index entries of
/// the row `i_data_cur` points at (those with reg_idx[i] set, if given),
/// except the one of cursor `i_idx_no_seek`.
pub fn generateRowIndexDelete(p: *Parse, t: *Table, i_data_cur: i32, i_idx_cur: i32, reg_idx: ?[]const i32, i_idx_no_seek: i32) void {
    const v = p.vdbe.?;
    var r1: i32 = -1;
    var prior: ?*Index = null;
    const pk: ?*Index = if (t.hasRowid()) null else build.primaryKeyIndex(t);
    var i: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        i += 1;
    }) {
        if (reg_idx) |r| if (r[i] == 0) continue;
        if (idx == pk) continue;
        const cur = i_idx_cur + @as(i32, @intCast(i));
        if (cur == i_idx_no_seek) continue;
        var part_idx_label: i32 = 0;
        r1 = generateIndexKey(p, idx, i_data_cur, 0, true, &part_idx_label, prior, r1);
        const p3: i32 = if (idx.has_expr and reg_idx != null) reg_idx.?[i] else 0;
        _ = aux.addOp3(v, OP.IdxDelete, cur, r1, p3);
        aux.changeP4(v, -1, .{ .index = idx });
        aux.changeP5(v, if (idx.uniq_not_null) idx.n_key_col else idx.n_column);
        resolvePartIdxLabel(p, part_idx_label);
        prior = idx;
    }
}

/// Port of sqlite3GenerateIndexKey(): load the columns of the entry of
/// `idx` for the row `i_data_cur` points at into a temporary register
/// block (returned, already released), and make it a record in `reg_out`
/// if not 0. With `prefix_only` only a unique prefix. A partial index
/// gets a label in `part_idx_label` to jump to when the row has no entry.
/// `prior`/`reg_prior` are the key just made for another index, whose
/// common columns need not be loaded again.
pub fn generateIndexKey(p: *Parse, idx: *Index, i_data_cur: i32, reg_out: i32, prefix_only: bool, part_idx_label: ?*i32, prior_arg: ?*Index, reg_prior: i32) i32 {
    const v = p.vdbe.?;
    var prior = prior_arg;
    if (part_idx_label) |lbl| {
        if (idx.part_idx_where) |w| {
            lbl.* = aux.makeLabel(p);
            p.i_self_tab = i_data_cur + 1;
            ec.exprIfFalseDup(p, w, lbl.*, vi.SQLITE_JUMPIFNULL);
            p.i_self_tab = 0;
            // The WHERE clause may have clobbered the prior key.
            prior = null;
        } else {
            lbl.* = 0;
        }
    }
    const n_col: i32 = if (prefix_only and idx.uniq_not_null) idx.n_key_col else idx.n_column;
    const reg_base = expr_mod.getTempRange(p, n_col);
    if (prior) |pr| if (reg_base != reg_prior or pr.part_idx_where != null) {
        prior = null;
    };
    for (0..@intCast(n_col)) |j| {
        if (prior) |pr| if (pr.ai_column[j] == idx.ai_column[j] and pr.ai_column[j] != int.XN_EXPR) continue;
        ec.codeLoadIndexColumn(p, idx, i_data_cur, j, reg_base + @as(i32, @intCast(j)));
        // A REAL column stored as an integer goes back into the index as
        // an integer.
        if (idx.ai_column[j] >= 0) _ = aux.deletePriorOpcode(v, OP.RealAffinity);
    }
    if (reg_out != 0) _ = aux.addOp3(v, OP.MakeRecord, reg_base, n_col, reg_out);
    expr_mod.releaseTempRange(p, reg_base, n_col);
    return reg_base;
}

/// Port of sqlite3ResolvePartIdxLabel().
pub fn resolvePartIdxLabel(p: *Parse, label: i32) void {
    if (label != 0) aux.resolveLabel(p.vdbe.?, label);
}
