//! DELETE statements (port of delete.c): the DELETE driver, and the row
//! and index-entry deletes INSERT and UPDATE share. Views, triggers and
//! DELETE ... LIMIT come later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const vtab = @import("vtab.zig");
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
const where_mod = @import("where/where.zig");
const main_mod = @import("main.zig");
const auth = @import("auth.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Table = int.Table;
const Index = int.Index;
const Trigger = int.Trigger;
const NameContext = int.NameContext;
const Vdbe = vi.Vdbe;
const Reg = aux.operand.Reg;
const Cursor = aux.operand.Cursor;
const Label = aux.operand.Label;
const Addr = aux.operand.Addr;
const Oom = int.Oom;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const TF = int.TF;
const TK = int.TK;
const OE = int.OE;
const NC = int.NC;
const WHERE = int.WHERE;
const ONEPASS = where_mod.ONEPASS;

/// Port of sqlite3CodeChangeCount(): return the number of rows changed
/// as the statement's result.
pub fn codeChangeCount(v: *Vdbe, reg_counter: i32, col_name: [:0]const u8) void {
    _ = aux.emit(v, .FkCheck, .{});
    _ = aux.emit(v, .ResultRow, .{ Reg.from(reg_counter), 1 });
    aux.setNumCols(v, 1);
    aux.setColName(v, 0, vi.COLNAME_NAME, col_name);
}

/// Port of vtabIsReadOnly(): a virtual table without xUpdate. Within
/// triggers, writing a SQLITE_VTAB_DIRECTONLY table, or (with PRAGMA
/// trusted_schema=OFF) one that is not SQLITE_VTAB_INNOCUOUS, is an error.
fn vtabIsReadOnly(p: *Parse, t: *Table) bool {
    std.debug.assert(t.isVirtual());
    if (vtab.getVTable(p.db, t).?.mod.module.x_update == null) return true;
    if ((p.toplevel != null or p.prep_flags & aux.PREPARE_FROM_DDL != 0) and
        t.u.vtab.p.?.e_vtab_risk.unsafeInSchema(p.db.flags.TrustedSchema))
    {
        util.errorMsg(p, "unsafe use of virtual table \"{s}\"", .{t.name});
    }
    return false;
}

/// Port of tabIsReadOnly(): a virtual table without xUpdate, sqlite_schema
/// (outside nested parses and writable_schema) and, in defensive mode,
/// shadow tables.
fn tabIsReadOnly(p: *Parse, t: *Table) bool {
    if (t.isVirtual()) return vtabIsReadOnly(p, t);
    if (!t.tab_flags.intersects(.{ .Readonly = true, .Shadow = true })) return false;
    if (t.tab_flags.Readonly) return !build.writableSchema(p.db) and p.nested == 0;
    return build.readOnlyShadowTables(p.db);
}

/// Port of sqlite3IsReadOnly(): an error unless `t` may be written.
pub fn isReadOnly(p: *Parse, t: *Table, trig: ?*Trigger) bool {
    if (tabIsReadOnly(p, t)) {
        util.errorMsg(p, "table {s} may not be modified", .{t.name});
        return true;
    }
    if (t.isView() and (trig == null or (trig.?.returning and trig.?.next == null))) {
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
    build.viewGetColumnNames(p, t) catch return;
    if (isReadOnly(p, t, trig)) return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const rcauth = auth.check(p, auth.Code.DELETE, t.name, null, db.dbs.items[i_db].name);
    if (rcauth == auth.DENY) return;
    var s_context: auth.Context = .{};
    defer auth.contextPop(&s_context);

    // Cursors for the table and its indexes.
    const tab_cur: Cursor = .from(p.n_tab);
    const i_tab_cur = tab_cur.int();
    tab_list.at(0).i_cursor = i_tab_cur;
    p.n_tab += 1;
    var n_idx: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |ix| : (idx_opt = ix.next) {
        p.n_tab += 1;
        n_idx += 1;
    }

    // The checks of the view's triggers are made on behalf of the view.
    if (is_view) auth.contextPush(p, &s_context, t.name);

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
    resolve.resolveExprNames(&nc, where) catch return;

    // The register that counts the rows deleted, if they are counted.
    var mem_cnt: Reg = .none;
    if (db.flags.CountRows and p.nested == 0 and p.trigger_tab == null and !p.returning) {
        p.n_mem += 1;
        mem_cnt = .from(p.n_mem);
        _ = aux.emit(v, .Integer, .{ 0, mem_cnt });
    }

    if (rcauth == auth.OK and where == null and !b_complex and !t.isVirtual()) {
        // Without a WHERE clause the b-trees are just cleared.
        build.tableLock(p, @intCast(i_db), t.tnum, true, t.name);
        // OP_Clear adds the rows it removes to r[P3] if P3 is positive.
        const clear_count: i32 = if (mem_cnt.isNone()) -1 else mem_cnt.int();
        if (t.hasRowid()) {
            _ = aux.emitStr(v, .Clear, .{ t.tnum, i_db, clear_count }, t.name);
        }
        idx_opt = t.index;
        while (idx_opt) |ix| : (idx_opt = ix.next) {
            if (ix.isPrimaryKey() and !t.hasRowid()) {
                _ = aux.emit(v, .Clear, .{ ix.tnum, i_db, clear_count });
            } else {
                _ = aux.emit(v, .Clear, .{ ix.tnum, i_db });
            }
        }
    } else {
        var wcf: WHERE = .{ .ONEPASS_DESIRED = true, .DUPLICATES_OK = true };
        if (nc.nc_flags.Subquery) b_complex = true;
        if (!b_complex) wcf.ONEPASS_MULTIROW = true;

        // The keys of the rows to delete: a RowSet of rowids, or for a
        // WITHOUT ROWID table an ephemeral table of PRIMARY KEYs.
        var pk: ?*Index = null;
        var n_pk: i16 = 1;
        var pk_reg: Reg = .none;
        var eph_cur: Cursor = undefined;
        var row_set: Reg = .none;
        var addr_eph_open: ?Addr = null;
        if (t.hasRowid()) {
            p.n_mem += 1;
            row_set = .from(p.n_mem);
            _ = aux.emit(v, .Null, .{ 0, row_set });
        } else {
            pk = build.primaryKeyIndex(t);
            n_pk = @intCast(pk.?.n_key_col);
            pk_reg = .from(p.n_mem + 1);
            p.n_mem += n_pk;
            eph_cur = .from(p.n_tab);
            p.n_tab += 1;
            addr_eph_open = aux.emit(v, .OpenEphemeral, .{ eph_cur, n_pk });
            aux.setP4KeyInfo(p, pk.?);
        }

        // The rows matching the WHERE clause.
        const w = where_mod.whereBegin(p, tab_list, where, null, null, null, wcf, i_tab_cur + 1) orelse return;
        var ai_cur_one_pass: [2]i32 = .{ -1, -1 };
        const e_one_pass = where_mod.okOnePass(w, &ai_cur_one_pass);
        if (e_one_pass != ONEPASS.SINGLE) main_mod.multiWrite(p);
        if (where_mod.usesDeferredSeek(w)) _ = aux.emit(v, .FinishSeek, .{tab_cur});
        if (!mem_cnt.isNone()) _ = aux.emit(v, .AddImm, .{ mem_cnt, 1 });

        // The key of the current row.
        var key: Reg = undefined;
        if (pk) |k| {
            for (0..k.n_key_col) |i| {
                ec.codeGetColumnOfTable(v, t, i_tab_cur, k.ai_column[i], pk_reg.at(i).int());
            }
            key = pk_reg;
        } else {
            p.n_mem += 1;
            key = .from(p.n_mem);
            ec.codeGetColumnOfTable(v, t, i_tab_cur, -1, key.int());
        }

        var n_key: i16 = undefined;
        var to_open: ?[]bool = null;
        // One pass: where to go when the row is gone already.
        var bypass: Label = undefined;
        if (e_one_pass != ONEPASS.OFF) {
            // One pass: the key stays in its registers.
            n_key = n_pk;
            const o = try p.arena.alloc(bool, n_idx + 2);
            @memset(o, true);
            o[n_idx + 1] = false;
            if (ai_cur_one_pass[0] >= 0) o[@intCast(ai_cur_one_pass[0] - i_tab_cur)] = false;
            if (ai_cur_one_pass[1] >= 0) o[@intCast(ai_cur_one_pass[1] - i_tab_cur)] = false;
            to_open = o;
            if (addr_eph_open) |a| _ = aux.changeToNoop(v, a.int());
            bypass = aux.newLabel(p);
        } else {
            if (pk) |k| {
                p.n_mem += 1;
                key = .from(p.n_mem);
                n_key = 0;
                _ = aux.emitStr(v, .MakeRecord, .{ pk_reg, n_pk, key }, insert.indexAffinityPrefix(p, k, @intCast(n_pk)));
                _ = aux.emitInt(v, .IdxInsert, .{ eph_cur, key, pk_reg }, n_pk);
            } else {
                n_key = 1;
                _ = aux.emit(v, .RowSetAdd, .{ row_set, key });
            }
            where_mod.whereEnd(w);
        }

        // Open the table and its indexes for writing (a view only fires
        // its INSTEAD OF triggers).
        if (!is_view) {
            // With several rows in one pass, the cursors are opened once.
            const once: ?Addr = if (e_one_pass == ONEPASS.MULTI) aux.emit(v, .Once, .{}) else null;
            _ = insert.openTableAndIndices(p, t, OP.OpenWrite, OPFLAG.FORDELETE, i_tab_cur, to_open, &i_data_cur, &i_idx_cur);
            if (once) |a| aux.jumpHereOrPopInst(v, a.int());
        }

        // The loop over the keys found.
        var addr_loop: Addr = undefined;
        if (e_one_pass != ONEPASS.OFF) {
            if (!t.isVirtual() and to_open.?[@intCast(i_data_cur - i_tab_cur)]) {
                _ = aux.emitInt(v, .NotFound, .{ Cursor.from(i_data_cur), bypass, key }, n_key);
            }
        } else if (pk != null) {
            addr_loop = aux.emit(v, .Rewind, .{eph_cur});
            if (t.isVirtual()) {
                _ = aux.emit(v, .Column, .{ eph_cur, 0, key });
            } else {
                _ = aux.emit(v, .RowData, .{ eph_cur, key });
            }
        } else {
            addr_loop = aux.emit(v, .RowSetRead, .{ row_set, 0, key });
        }

        if (t.isVirtual()) {
            vtab.makeWritable(p, t);
            std.debug.assert(e_one_pass == ONEPASS.OFF or e_one_pass == ONEPASS.SINGLE);
            main_mod.mayAbort(p);
            if (e_one_pass == ONEPASS.SINGLE) {
                _ = aux.emit(v, .Close, .{tab_cur});
                if (p.toplevel == null) p.is_multi_write = false;
            }
            _ = aux.emit4(v, .VUpdate, .{ 0, 1, key }, build.vtabP4(db, t));
            aux.changeP5(v, OE.Abort.int());
        } else {
            generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, key.int(), n_key, p.nested == 0, OE.Default, e_one_pass, ai_cur_one_pass[1]);
        }

        if (e_one_pass != ONEPASS.OFF) {
            aux.place(v, bypass);
            where_mod.whereEnd(w);
        } else if (pk != null) {
            _ = aux.emit(v, .Next, .{ eph_cur, addr_loop.plus(1) });
            aux.landHere(v, addr_loop);
        } else {
            _ = aux.emit(v, .Goto, .{ 0, addr_loop });
            aux.landHere(v, addr_loop);
        }
    }

    if (p.nested == 0 and p.trigger_tab == null) insert.autoincrementEnd(p);
    if (!mem_cnt.isNone()) codeChangeCount(v, mem_cnt.int(), "rows deleted");
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
    const sel = try select_mod.selectNew(p, null, from, where, null, null, order_by, .{ .IncludeHidden = true }, limit);
    var dest = select_mod.selectDestInit(select_mod.SRT.EphemTab, i_cur);
    select_mod.select(p, sel, &dest) catch {};
}

/// Port of sqlite3GenerateRowDelete(): delete one row and its index
/// entries. Its key is in the `n_pk` registers from `i_pk` (a record if
/// `n_pk` is 0); with `e_mode` other than ONEPASS.OFF `i_data_cur`
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
    onconf: OE,
    e_mode: ONEPASS,
    i_idx_no_seek_arg: i32,
) void {
    const v = p.vdbe.?;
    const data_cur: Cursor = .from(i_data_cur);
    const pk_reg: Reg = .from(i_pk);
    var i_idx_no_seek = i_idx_no_seek_arg;
    var i_old: i32 = 0;

    // Seek the row; it may be gone already (deleted by a trigger).
    const gone = aux.newLabel(p);
    const i_label = gone.int();
    const op_seek: OP = if (t.hasRowid()) .NotExists else .NotFound;
    const seek_shape = .{ .cursor, .jump, .reg };
    if (e_mode == ONEPASS.OFF) _ = aux.emitAnyInt(v, op_seek, seek_shape, .{ data_cur, gone, pk_reg }, n_pk);

    // The OLD.* registers of triggers and foreign keys.
    if (fkey.fkRequired(p, t, null, false) != 0 or trig != null) {
        var mask = trigger.triggerColmask(p, trig, null, false, int.TRIGGER_BEFORE | int.TRIGGER_AFTER, t, onconf);
        mask |= fkey.fkOldmask(p, t);
        i_old = p.n_mem + 1;
        p.n_mem += 1 + @as(i32, @intCast(t.cols.len));
        _ = aux.emit(v, .Copy, .{ pk_reg, Reg.from(i_old) });
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
            _ = aux.emitAnyInt(v, op_seek, seek_shape, .{ data_cur, gone, pk_reg }, n_pk);
            i_idx_no_seek = -1;
        }
        fkey.fkCheck(p, t, i_old, 0, null, false);
    }

    // The index entries and the row. OP_Delete with OPFLAG_NCHANGE counts
    // the change (and calls the update hook).
    if (!t.isView()) {
        var p5: u16 = 0;
        generateRowIndexDelete(p, t, i_data_cur, i_idx_cur, null, i_idx_no_seek);
        _ = aux.emit(v, .Delete, .{ data_cur, if (count) OPFLAG.NCHANGE else 0 });
        if (p.nested == 0 or std.ascii.eqlIgnoreCase(t.name, "sqlite_stat1")) aux.appendP4(v, .{ .table = t });
        if (e_mode != ONEPASS.OFF) aux.changeP5(v, OPFLAG.AUXDELETE);
        if (i_idx_no_seek >= 0 and i_idx_no_seek != i_data_cur) _ = aux.emit(v, .Delete, .{Cursor.from(i_idx_no_seek)});
        if (e_mode == ONEPASS.MULTI) p5 |= OPFLAG.SAVEPOSITION;
        aux.changeP5(v, p5);
    }

    fkey.fkActions(p, t, null, i_old, null, false);
    if (trig != null) trigger.codeRowTrigger(p, trig, TK.DELETE, null, int.TRIGGER_AFTER, t, i_old, onconf, i_label);
    aux.place(v, gone);
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
        _ = aux.emit4(v, .IdxDelete, .{ Cursor.from(cur), Reg.from(r1), p3 }, .{ .index = idx });
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
    if (reg_out != 0) _ = aux.emit(v, .MakeRecord, .{ Reg.from(reg_base), n_col, Reg.from(reg_out) });
    expr_mod.releaseTempRange(p, reg_base, n_col);
    return reg_base;
}

/// Port of sqlite3ResolvePartIdxLabel().
pub fn resolvePartIdxLabel(p: *Parse, label: i32) void {
    if (label != 0) aux.resolveLabel(p.vdbe.?, label);
}
