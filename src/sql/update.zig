//! UPDATE statements (port of update.c).

const std = @import("std");
const int = @import("sqlite_int.zig");
const vtab = @import("vtab.zig");
const wi = @import("where/where_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const mem = @import("../vdbe/mem.zig");
const build = @import("build.zig");
const util = @import("util.zig");
const numeric = @import("xqlite_base").numeric;

const Expr = int.Expr;
const Mem = vi.Mem;
const MEM = vi.MEM;
const TK = int.TK;
const EP = int.EP;
const Aff = int.Aff;

const Parse = int.Parse;
const ExprList = int.ExprList;
const SrcList = int.SrcList;
const Index = int.Index;
const NameContext = int.NameContext;
const Oom = int.Oom;
const OE = int.OE;
const NC = int.NC;
const SF = int.SF;
const TF = int.TF;
const COLFLAG = int.COLFLAG;
const WHERE = int.WHERE;
const OPFLAG = vi.OPFLAG;
const Reg = aux.operand.Reg;
const Cursor = aux.operand.Cursor;
const Addr = aux.operand.Addr;
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const typing = @import("typing.zig");
const auth = @import("auth.zig");
const prepare = @import("prepare.zig");
const insert = @import("insert.zig");
const delete_mod = @import("delete.zig");
const trigger = @import("trigger.zig");
const fkey = @import("fkey.zig");
const where_mod = @import("where/where.zig");
const main_mod = @import("main.zig");
const select_mod = @import("select.zig");
const SRT = select_mod.SRT;
const ONEPASS = where_mod.ONEPASS;

/// Port of exprRowColumn(): a TK_ROW expression the resolver turns into
/// column `i_col` of the first FROM-clause table.
fn exprRowColumn(p: *Parse, i_col: i32) Oom!*Expr {
    const e = try expr_mod.pExpr(p, TK.ROW, null, null);
    e.i_column = @intCast(i_col + 1);
    return e;
}

/// Port of updateFromSelect(): for UPDATE ... FROM, write the key of each
/// row to change (or all the columns of a view) followed by the new
/// values to the ephemeral table `eph_cur`.
fn updateFromSelect(p: *Parse, eph_cur: Cursor, pk: ?*Index, changes: *ExprList, tab_list: *SrcList, where: ?*Expr) Oom!void {
    const t = tab_list.at(0).s_tab.?;
    const src = (try expr_mod.srcListDup(p.arena, tab_list)).?;
    const where2 = try expr_mod.exprDup(p.arena, where);
    src.at(0).i_cursor = -1;
    src.at(0).s_tab = null;
    var list: ?*ExprList = null;
    var e_dest: SRT = undefined;
    if (pk) |k| {
        for (0..k.n_key_col) |i| list = try expr_mod.listAppend(p, list, try exprRowColumn(p, k.ai_column[i]));
        e_dest = if (t.isVirtual()) SRT.Table else SRT.Upfrom;
    } else if (t.isView()) {
        for (0..t.cols.len) |i| list = try expr_mod.listAppend(p, list, try exprRowColumn(p, @intCast(i)));
        e_dest = SRT.Table;
    } else {
        e_dest = if (t.isVirtual()) SRT.Table else SRT.Upfrom;
        list = try expr_mod.listAppend(p, null, try expr_mod.pExpr(p, TK.ROW, null, null));
    }
    for (changes.slice()) |item| list = try expr_mod.listAppend(p, list, try expr_mod.exprDup(p.arena, item.expr));
    const sel = try select_mod.selectNew(p, list, src, where2, null, null, null, .{ .UFSrcCheck = true, .IncludeHidden = true, .UpdateFrom = true }, null);
    sel.sel_flags.OrderByReqd = true;
    var dest = select_mod.selectDestInit(e_dest, eph_cur.int());
    dest.i_sd_parm2 = if (pk) |k| k.n_key_col else -1;
    select_mod.select(p, sel, &dest) catch {};
    // xqlite: the types the query gave the new values, for the stores of
    // the dialect's types (the values written are the query's).
    if (sel.e_list) |l| if (l.len() >= changes.len()) {
        const off = l.len() - changes.len();
        for (changes.slice(), 0..) |*item, i| if (item.expr) |x| if (l.at(off + i).expr) |y| {
            x.xq_type = y.xq_type;
        };
    };
}

/// Port of indexColumnIsBeingUpdated().
fn indexColumnIsBeingUpdated(idx: *Index, i_col: usize, ax_ref: []const i32, chng_rowid: bool) bool {
    const i_idx_col = idx.ai_column[i_col];
    if (i_idx_col >= 0) return ax_ref[@intCast(i_idx_col)] >= 0;
    return insert.exprReferencesUpdatedColumn(idx.col_expr.?.at(i_col).expr, ax_ref, chng_rowid);
}

/// Port of indexWhereClauseMightChange().
fn indexWhereClauseMightChange(idx: *Index, ax_ref: []const i32, chng_rowid: bool) bool {
    const w = idx.part_idx_where orelse return false;
    return insert.exprReferencesUpdatedColumn(w, ax_ref, chng_rowid);
}

/// Port of sqlite3Update(): UPDATE `tab_list` SET `changes` [FROM ...]
/// WHERE `where`. With `upsert`, the DO UPDATE of an upsert: one row, on
/// the cursors of the INSERT, which already point at it.
pub fn update(p: *Parse, tab_list: ?*int.SrcList, changes: ?*int.ExprList, where: ?*int.Expr, on_error: OE, order_by: ?*int.ExprList, limit: ?*int.Expr, upsert: ?*int.Upsert) void {
    if (p.syntax_only) return;
    _ = .{ order_by, limit };
    // Nothing after an error (a list is null after some:
    // sqlite3ExprListAppendVector()).
    if (p.n_err != 0) return;
    updateImpl(p, tab_list.?, changes.?, where, on_error, upsert) catch build.oomFault(p);
}

fn updateImpl(p: *Parse, tab_list: *SrcList, changes: *ExprList, where: ?*Expr, on_error: OE, upsert: ?*int.Upsert) Oom!void {
    const db = p.db;

    const t = build.srcListLookup(p, tab_list) orelse return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    var tmask: u8 = 0;
    const trig = trigger.triggersExist(p, t, TK.UPDATE, changes, &tmask);
    const is_view = t.isView();

    // With a FROM clause, the number of new values.
    const n_change_from: i32 = if (tab_list.len() > 1) @intCast(changes.len()) else 0;
    std.debug.assert(n_change_from == 0 or upsert == null);

    build.viewGetColumnNames(p, t) catch return;
    if (delete_mod.isReadOnly(p, t, trig)) return;

    // Cursors for the table and all its indexes (used or not, the index
    // cursors follow the table's).
    const i_base_cur = p.n_tab;
    var data_cur: Cursor = .from(p.n_tab);
    p.n_tab += 1;
    var i_idx_cur = data_cur.int() + 1;
    const pk: ?*Index = if (t.hasRowid()) null else build.primaryKeyIndex(t);
    var n_idx: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |ix| : (idx_opt = ix.next) {
        if (pk == ix) data_cur = .from(p.n_tab);
        p.n_tab += 1;
        n_idx += 1;
    }
    if (upsert) |u| {
        // The cursors the INSERT opened.
        data_cur = .from(u.i_data_cur);
        i_idx_cur = u.i_idx_cur;
        p.n_tab = i_base_cur;
    }
    tab_list.at(0).i_cursor = data_cur.int();

    // ax_ref[i]: the change of column i, or -1. reg_idx: a register range
    // per index to update (0 if not), and one for the record. to_open:
    // the table and the indexes to open.
    const ax_ref = try p.arena.alloc(i32, t.cols.len);
    @memset(ax_ref, -1);
    const reg_idx = try p.arena.alloc(i32, n_idx + 1);
    const to_open = try p.arena.alloc(bool, n_idx + 2);
    @memset(to_open, true);
    to_open[n_idx + 1] = false;

    var nc: NameContext = .{ .parse = p, .src_list = tab_list, .nc_flags = .{ .UUpsert = true }, .u_nc = .{ .upsert = upsert } };

    const v = build.getVdbe(p) orelse return;

    // Resolve the new values and map them to columns.
    var chng_rowid = false;
    var chng_pk = false;
    var rowid_expr: ?*Expr = null;
    var i_rowid_expr: i32 = -1;
    for (changes.slice(), 0..) |item, ii| {
        const i: i32 = @intCast(ii);
        // With a FROM clause, the SELECT resolves them.
        if (n_change_from == 0) resolve.resolveExprNames(&nc, item.expr) catch return;
        const name = item.e_name.?;
        const j = build.columnIndex(t, name);
        if (j >= 0) {
            const ju: usize = @intCast(j);
            if (j == t.i_pkey) {
                chng_rowid = true;
                rowid_expr = item.expr;
                i_rowid_expr = i;
            } else if (pk != null and t.cols[ju].col_flags.PRIMKEY) {
                chng_pk = true;
            } else if (t.cols[ju].col_flags.intersects(COLFLAG.GENERATED)) {
                util.errorMsg(p, "cannot UPDATE generated column \"{s}\"", .{t.cols[ju].name()});
                return;
            }
            ax_ref[ju] = i;
            // xqlite: a parameter stored into the column is of its type.
            if (n_change_from == 0 and typing.active(db)) typing.assign(p, item.expr.?, resolve.tableColumnType(p, t, ju) catch return build.oomFault(p));
        } else if (pk == null and resolve.isRowid(name)) {
            chng_rowid = true;
            rowid_expr = item.expr;
            i_rowid_expr = i;
        } else {
            util.errorMsgState(p, null, .of("42703"), "no such column: {s}", .{name});
            p.check_schema = true;
            return;
        }
        const rc = auth.check(p, auth.Code.UPDATE, t.name, if (j < 0) "ROWID" else t.cols[@intCast(j)].name(), db.dbs.items[i_db].name);
        if (rc == auth.DENY) return;
        if (rc == auth.IGNORE and j >= 0) ax_ref[@intCast(j)] = -1;
    }
    const chng_key = chng_rowid or chng_pk;

    // Generated columns change if what they use changes.
    if (t.tab_flags.intersects(TF.HasGenerated)) {
        while (true) {
            var progress = false;
            for (t.cols, 0..) |*c, i| {
                if (ax_ref[i] >= 0) continue;
                if (!c.col_flags.intersects(COLFLAG.GENERATED)) continue;
                if (insert.exprReferencesUpdatedColumn(build.columnExpr(t, c), ax_ref, chng_rowid)) {
                    ax_ref[i] = 99999;
                    progress = true;
                }
            }
            if (!progress) break;
        }
    }

    // The new values are not used by the WHERE loop; but a virtual table
    // must make every column available.
    tab_list.at(0).col_used = if (t.isVirtual()) wi.ALLBITS else 0;

    const has_fk = fkey.fkRequired(p, t, ax_ref, chng_key);

    // The indexes whose entries may change.
    var b_replace = on_error == OE.Replace;
    var n_all_idx: usize = 0;
    idx_opt = t.index;
    while (idx_opt) |ix| : ({
        idx_opt = ix.next;
        n_all_idx += 1;
    }) {
        var reg: i32 = 0;
        if (chng_key or has_fk > 1 or ix == pk or indexWhereClauseMightChange(ix, ax_ref, chng_rowid)) {
            p.n_mem += 1;
            reg = p.n_mem;
            p.n_mem += ix.n_column;
        } else {
            for (0..ix.n_key_col) |i| {
                if (indexColumnIsBeingUpdated(ix, i, ax_ref, chng_rowid)) {
                    p.n_mem += 1;
                    reg = p.n_mem;
                    p.n_mem += ix.n_column;
                    if (on_error == OE.Default and ix.on_error == OE.Replace) b_replace = true;
                    break;
                }
            }
        }
        if (reg == 0) to_open[n_all_idx + 1] = false;
        reg_idx[n_all_idx] = reg;
    }
    p.n_mem += 1;
    reg_idx[n_all_idx] = p.n_mem;
    // REPLACE may delete through any index.
    if (b_replace) @memset(to_open[0 .. n_idx + 1], true);

    if (p.nested == 0) aux.countChanges(v);
    build.beginWriteOperation(p, trig != null or has_fk != 0, i_db);

    // Registers. row_set shares the register of the record until the
    // two-pass method needs it.
    var row_set: Reg = .none;
    var old_rowid: Reg = .none;
    var new_rowid: Reg = .none;
    var reg_old: Reg = .none;
    var reg_new: Reg = .none;
    if (!t.isVirtual()) {
        row_set = .from(reg_idx[n_all_idx]);
        p.n_mem += 1;
        old_rowid = .from(p.n_mem);
        new_rowid = old_rowid;
        if (chng_pk or trig != null or has_fk != 0) {
            reg_old = .from(p.n_mem + 1);
            p.n_mem += @intCast(t.cols.len);
        }
        if (chng_key or trig != null or has_fk != 0) {
            p.n_mem += 1;
            new_rowid = .from(p.n_mem);
        }
        reg_new = .from(p.n_mem + 1);
        p.n_mem += @intCast(t.cols.len);
    }

    // The checks of the view's triggers are made on behalf of the view.
    var s_context: auth.Context = .{};
    defer auth.contextPop(&s_context);
    if (is_view) auth.contextPush(p, &s_context, t.name);

    // A view (with INSTEAD OF triggers) is realized into an ephemeral
    // table.
    if (n_change_from == 0 and is_view) delete_mod.materializeView(p, t, where, null, null, data_cur.int());

    if (n_change_from == 0) resolve.resolveExprNames(&nc, where) catch return;

    // Virtual tables are done apart.
    if (t.isVirtual()) {
        try updateVirtualTable(p, tab_list, t, changes, rowid_expr, ax_ref, where, on_error);
        return;
    }

    const label_break = aux.newLabel(p);
    var label_continue = label_break;

    // The register that counts the rows updated, if they are counted.
    var row_count: Reg = .none;
    if (db.flags.CountRows and p.trigger_tab == null and p.nested == 0 and !p.returning and upsert == null) {
        p.n_mem += 1;
        row_count = .from(p.n_mem);
        _ = aux.emit(v, .Integer, .{ 0, row_count });
    }

    // The ephemeral table of the rows to update (none for an upsert, which
    // never uses it) and the instruction that opens it.
    var eph_cur: Cursor = undefined;
    var addr_open: ?Addr = null;
    var n_pk: i32 = 0;
    var pk_reg: Reg = .none;
    var key: Reg = .none;
    var n_key: i32 = 0;
    if (n_change_from == 0 and t.hasRowid()) {
        _ = aux.emit(v, .Null, .{ 0, row_set, old_rowid });
        eph_cur = .from(p.n_tab);
        p.n_tab += 1;
        // P3 is the register OP_Insert takes its (empty) record from.
        addr_open = aux.emit(v, .OpenEphemeral, .{ eph_cur, 0, row_set });
    } else {
        n_pk = if (pk) |k| k.n_key_col else 0;
        pk_reg = .from(p.n_mem + 1);
        p.n_mem += n_pk;
        p.n_mem += n_change_from;
        p.n_mem += 1;
        key = .from(p.n_mem);
        if (upsert == null) {
            const n_eph_col = n_pk + n_change_from + (if (is_view) @as(i32, @intCast(t.cols.len)) else 0);
            eph_cur = .from(p.n_tab);
            p.n_tab += 1;
            if (pk != null) _ = aux.emit(v, .Null, .{ 0, pk_reg, pk_reg.at(n_pk - 1) });
            addr_open = aux.emit(v, .OpenEphemeral, .{ eph_cur, n_eph_col });
            if (pk) |k| {
                if (build.keyInfoOfIndex(p, k)) |ki| {
                    ki.n_all_field = @intCast(n_eph_col);
                    aux.appendP4(v, .{ .keyinfo = ki });
                }
            }
            if (n_change_from != 0) {
                try updateFromSelect(p, eph_cur, pk, changes, tab_list, where);
                if (is_view) data_cur = eph_cur;
            }
        }
    }

    var e_one_pass: ONEPASS = ONEPASS.OFF;
    var ai_cur_one_pass: [2]i32 = .{ -1, -1 };
    // Whether OP_FinishSeek must resolve an OP_DeferredSeek of the loop.
    var b_finish_seek = true;
    var w: ?*where_mod.WhereInfo = null;
    if (n_change_from != 0) {
        main_mod.multiWrite(p);
        n_key = n_pk;
        key = pk_reg;
    } else {
        if (upsert != null) {
            // The INSERT left the data cursor on the row to update: no
            // search, only the WHERE of the DO UPDATE.
            e_one_pass = ONEPASS.SINGLE;
            ec.exprIfFalse(p, where, label_break.int(), vi.SQLITE_JUMPIFNULL);
            b_finish_seek = false;
        } else {
            // The rows to update. A one-pass update of several rows is not
            // safe if anything else may move the cursor.
            var flags: WHERE = .{ .ONEPASS_DESIRED = true };
            if (p.nested == 0 and trig == null and has_fk == 0 and !chng_key and !b_replace and
                (where == null or !where.?.flags.Subquery))
            {
                flags.ONEPASS_MULTIROW = true;
            }
            w = where_mod.whereBegin(p, tab_list, where, null, null, null, flags, i_idx_cur) orelse return;
            e_one_pass = where_mod.okOnePass(w.?, &ai_cur_one_pass);
            b_finish_seek = where_mod.usesDeferredSeek(w.?);
            if (e_one_pass != ONEPASS.SINGLE) {
                main_mod.multiWrite(p);
                if (e_one_pass == ONEPASS.MULTI) {
                    const i_cur = ai_cur_one_pass[1];
                    if (i_cur >= 0 and i_cur != data_cur.int() and to_open[@intCast(i_cur - i_base_cur)]) e_one_pass = ONEPASS.OFF;
                }
            }
        }

        if (t.hasRowid()) {
            // The rowid of the row: to the FIFO for two passes.
            _ = aux.emit(v, .Rowid, .{ data_cur, old_rowid });
            if (e_one_pass == ONEPASS.OFF) {
                p.n_mem += 1;
                reg_idx[n_all_idx] = p.n_mem;
                _ = aux.emit(v, .Insert, .{ eph_cur, row_set, old_rowid });
            } else if (addr_open) |a| {
                _ = aux.changeToNoop(v, a.int());
            }
        } else {
            // The PRIMARY KEY of the row: a record in the ephemeral table
            // for two passes.
            const k = pk.?;
            for (0..k.n_key_col) |i| ec.codeGetColumnOfTable(v, t, data_cur.int(), k.ai_column[i], pk_reg.at(i).int());
            if (e_one_pass != ONEPASS.OFF) {
                if (addr_open) |a| _ = aux.changeToNoop(v, a.int());
                n_key = n_pk;
                key = pk_reg;
            } else {
                _ = aux.emitStr(v, .MakeRecord, .{ pk_reg, n_pk, key }, insert.indexAffinityPrefix(p, k, @intCast(n_pk)));
                _ = aux.emitInt(v, .IdxInsert, .{ eph_cur, key, pk_reg }, n_pk);
            }
        }
    }

    // The top of the loop over the ephemeral table (two passes).
    var addr_top: Addr = undefined;
    if (upsert == null) {
        if (n_change_from == 0 and e_one_pass != ONEPASS.MULTI) where_mod.whereEnd(w.?);

        if (!is_view) {
            // Open the indexes to update.
            if (e_one_pass != ONEPASS.OFF) {
                if (ai_cur_one_pass[0] >= 0) to_open[@intCast(ai_cur_one_pass[0] - i_base_cur)] = false;
                if (ai_cur_one_pass[1] >= 0) to_open[@intCast(ai_cur_one_pass[1] - i_base_cur)] = false;
            }
            var addr_once: ?Addr = null;
            if (e_one_pass == ONEPASS.MULTI and n_idx - @intFromBool(ai_cur_one_pass[1] >= 0) > 0) addr_once = aux.emit(v, .Once, .{});
            var not_used1: i32 = 0;
            var not_used2: i32 = 0;
            _ = insert.openTableAndIndices(p, t, OP.OpenWrite, 0, i_base_cur, to_open, &not_used1, &not_used2);
            if (addr_once) |a| aux.jumpHereOrPopInst(v, a.int());
        }

        // The top of the loop over the rows.
        if (e_one_pass != ONEPASS.OFF) {
            if (ai_cur_one_pass[0] != data_cur.int() and ai_cur_one_pass[1] != data_cur.int()) {
                _ = aux.emitInt(v, .NotFound, .{ data_cur, label_break, key }, n_key);
            }
            if (e_one_pass != ONEPASS.SINGLE) label_continue = aux.newLabel(p);
            _ = aux.emit(v, .IsNull, .{ if (pk != null) key else old_rowid, label_break });
        } else if (pk != null or n_change_from != 0) {
            label_continue = aux.newLabel(p);
            _ = aux.emit(v, .Rewind, .{ eph_cur, label_break });
            addr_top = aux.here(v);
            if (n_change_from != 0) {
                if (!is_view) {
                    if (pk != null) {
                        for (0..@intCast(n_pk)) |i| _ = aux.emit(v, .Column, .{ eph_cur, i, pk_reg.at(i) });
                        _ = aux.emitInt(v, .NotFound, .{ data_cur, label_continue, pk_reg }, n_pk);
                    } else {
                        _ = aux.emit(v, .Rowid, .{ eph_cur, old_rowid });
                        _ = aux.emit(v, .NotExists, .{ data_cur, label_continue, old_rowid });
                    }
                }
            } else {
                _ = aux.emit(v, .RowData, .{ eph_cur, key });
                _ = aux.emitInt(v, .NotFound, .{ data_cur, label_continue, key }, 0);
            }
        } else {
            _ = aux.emit(v, .Rewind, .{ eph_cur, label_break });
            label_continue = aux.newLabel(p);
            addr_top = aux.emit(v, .Rowid, .{ eph_cur, old_rowid });
            _ = aux.emit(v, .NotExists, .{ data_cur, label_continue, old_rowid });
        }
    }

    // The new rowid.
    if (chng_rowid) {
        if (n_change_from == 0) {
            ec.exprCode(p, rowid_expr, new_rowid.int());
        } else {
            _ = aux.emit(v, .Column, .{ eph_cur, i_rowid_expr, new_rowid });
        }
        _ = aux.emit(v, .MustBeInt, .{new_rowid});
        main_mod.mayAbort(p);
    }

    // The old content, when needed.
    if (chng_pk or has_fk != 0 or trig != null) {
        var oldmask: u32 = if (has_fk != 0) fkey.fkOldmask(p, t) else 0;
        oldmask |= trigger.triggerColmask(p, trig, changes, false, int.TRIGGER_BEFORE | int.TRIGGER_AFTER, t, on_error);
        for (t.cols, 0..) |c, i| {
            const k = reg_old.at(build.tableColumnToStorage(t, @intCast(i)));
            if (oldmask == 0xffffffff or (i < 32 and oldmask & (@as(u32, 1) << @intCast(i)) != 0) or c.col_flags.PRIMKEY) {
                ec.codeGetColumnOfTable(v, t, data_cur.int(), @intCast(i), k.int());
            } else {
                _ = aux.emit(v, .Null, .{ 0, k });
            }
        }
        if (!chng_rowid and pk == null) _ = aux.emit(v, .Copy, .{ old_rowid, new_rowid });
    }

    // The new content, from reg_new.
    const newmask = trigger.triggerColmask(p, trig, changes, true, int.TRIGGER_BEFORE, t, on_error);
    {
        // xqlite: the functions the values of the dialect's types go
        // through (none in SQLite's dialect).
        const stores = if (is_view) null else typing.storeFunctions(p, t) catch return build.oomFault(p);
        var k = reg_new;
        for (t.cols, 0..) |c, i| {
            defer k = k.at(1);
            if (@as(i32, @intCast(i)) == t.i_pkey) {
                _ = aux.emit(v, .Null, .{ 0, k });
            } else if (c.col_flags.intersects(COLFLAG.GENERATED)) {
                if (c.col_flags.VIRTUAL) k = k.at(-1);
            } else {
                const j = ax_ref[i];
                if (j >= 0) {
                    if (n_change_from != 0) {
                        const n_off: i32 = if (is_view) @intCast(t.cols.len) else n_pk;
                        _ = aux.emit(v, .Column, .{ eph_cur, n_off + j, k });
                    } else {
                        ec.exprCode(p, changes.at(@intCast(j)).expr, k.int());
                    }
                    if (stores) |f| if (f[i]) |st| {
                        const x = changes.at(@intCast(j)).expr.?;
                        if (n_change_from != 0) {
                            // The value of a type known: as pick() goes
                            // (a string is not a numeric's text_store).
                            const known = typing.typeOf(db, x.xq_type).logical != .unknown;
                            if (if (known) st.pick(db, x) else st.untyped()) |s| insert.codeStore(p, s, k.int());
                        } else if (st.pick(db, x)) |s| {
                            if (typing.readStoredLiteral(p, s, x) catch return build.oomFault(p)) return;
                            insert.codeStore(p, s, k.int());
                        }
                    };
                } else if (tmask & int.TRIGGER_BEFORE == 0 or i > 31 or newmask & (@as(u32, 1) << @intCast(i)) != 0) {
                    ec.codeGetColumnOfTable(v, t, data_cur.int(), @intCast(i), k.int());
                    b_finish_seek = false;
                } else {
                    _ = aux.emit(v, .Null, .{ 0, k });
                }
            }
        }
    }
    if (t.tab_flags.intersects(TF.HasGenerated)) insert.computeGeneratedColumns(p, reg_new.int(), t);

    if (tmask & int.TRIGGER_BEFORE != 0) {
        insert.tableAffinity(p, t, reg_new.int());
        trigger.codeRowTrigger(p, trig, TK.UPDATE, changes, int.TRIGGER_BEFORE, t, old_rowid.int(), on_error, label_continue.int());

        if (!is_view) {
            // The trigger may have deleted the row: then go to the next.
            if (pk != null) {
                _ = aux.emitInt(v, .NotFound, .{ data_cur, label_continue, key }, n_key);
            } else {
                _ = aux.emit(v, .NotExists, .{ data_cur, label_continue, old_rowid });
            }
            // It may also have changed the columns the UPDATE does not
            // set: reload them (the others keep their values from before
            // the trigger).
            var k = reg_new;
            for (t.cols, 0..) |c, i| {
                defer k = k.at(1);
                if (c.col_flags.intersects(COLFLAG.GENERATED)) {
                    if (c.col_flags.VIRTUAL) k = k.at(-1);
                } else if (ax_ref[i] < 0 and @as(i32, @intCast(i)) != t.i_pkey) {
                    ec.codeGetColumnOfTable(v, t, data_cur.int(), @intCast(i), k.int());
                }
            }
            if (t.tab_flags.intersects(TF.HasGenerated)) insert.computeGeneratedColumns(p, reg_new.int(), t);
        }
    }

    if (!is_view) {
        var replaced = b_replace;
        insert.generateConstraintChecks(p, t, reg_idx, data_cur.int(), i_idx_cur, new_rowid.int(), old_rowid.int(), chng_key, on_error, label_continue.int(), &replaced, ax_ref, null);
        b_replace = replaced;

        // REPLACE or a new key may have moved the cursor.
        if (b_replace or chng_key) {
            if (pk != null) {
                _ = aux.emitInt(v, .NotFound, .{ data_cur, label_continue, key }, n_key);
            } else {
                _ = aux.emit(v, .NotExists, .{ data_cur, label_continue, old_rowid });
            }
        }

        if (has_fk != 0) fkey.fkCheck(p, t, old_rowid.int(), 0, ax_ref, chng_key);

        // Replace the index entries and the record.
        delete_mod.generateRowIndexDelete(p, t, data_cur.int(), i_idx_cur, reg_idx, -1);

        // OP_FinishSeek resolves an OP_DeferredSeek if no OP_Column may
        // have run since; it is skipped when it surely did.
        if (b_finish_seek) _ = aux.emit(v, .FinishSeek, .{data_cur});
        if (has_fk > 1 or chng_key) _ = aux.emit(v, .Delete, .{data_cur});
        if (has_fk != 0) fkey.fkCheck(p, t, 0, new_rowid.int(), ax_ref, chng_key);
        insert.completeInsertion(p, t, data_cur.int(), i_idx_cur, new_rowid.int(), reg_idx, OPFLAG.ISUPDATE | (if (e_one_pass == ONEPASS.MULTI) OPFLAG.SAVEPOSITION else 0), false, false);
        if (has_fk != 0) fkey.fkActions(p, t, changes, old_rowid.int(), ax_ref, chng_key);
    }

    if (!row_count.isNone()) _ = aux.emit(v, .AddImm, .{ row_count, 1 });
    if (trig != null) trigger.codeRowTrigger(p, trig, TK.UPDATE, changes, int.TRIGGER_AFTER, t, old_rowid.int(), on_error, label_continue.int());

    // The next row.
    if (e_one_pass == ONEPASS.SINGLE) {
        // Nothing to loop over.
    } else if (e_one_pass == ONEPASS.MULTI) {
        aux.place(v, label_continue);
        where_mod.whereEnd(w.?);
    } else {
        aux.place(v, label_continue);
        _ = aux.emit(v, .Next, .{ eph_cur, addr_top });
    }
    aux.place(v, label_break);

    if (p.nested == 0 and p.trigger_tab == null and upsert == null) insert.autoincrementEnd(p);
    if (!row_count.isNone()) delete_mod.codeChangeCount(v, row_count.int(), "rows updated");
}

/// Port of updateVirtualTable(): UPDATE of a virtual table. By default the
/// old rowid, the new rowid and the columns of each row to change go to
/// an ephemeral table, then each row to xUpdate (OP_VUpdate). With the
/// one-pass strategy (when xBestIndex says the WHERE matches at most one
/// row) they go to xUpdate from registers instead.
fn updateVirtualTable(p: *Parse, src: *SrcList, t: *int.Table, changes: *ExprList, rowid: ?*Expr, ax_ref: []const i32, where: ?*Expr, on_error: OE) Oom!void {
    const v = p.vdbe.?;
    const db = p.db;
    const n_arg: i32 = 2 + @as(i32, @intCast(t.cols.len));
    const csr: Cursor = .from(src.at(0).i_cursor);
    var w: ?*where_mod.WhereInfo = null;

    // The registers of the arguments of xUpdate, and the ephemeral table
    // of their records.
    const ephem_tab: Cursor = .from(p.n_tab);
    p.n_tab += 1;
    var addr = aux.emit(v, .OpenEphemeral, .{ ephem_tab, n_arg });
    const reg_arg: Reg = .from(p.n_mem + 1);
    p.n_mem += n_arg;
    var e_one_pass: ONEPASS = undefined;
    if (src.len() > 1) {
        var pk: ?*Index = null;
        var row: *Expr = undefined;
        if (t.hasRowid()) {
            row = if (rowid) |r| (try expr_mod.exprDup(p.arena, r)).? else try expr_mod.pExpr(p, TK.ROW, null, null);
        } else {
            pk = build.primaryKeyIndex(t).?;
            std.debug.assert(pk.?.n_key_col == 1);
            const i_pk = pk.?.ai_column[0];
            if (ax_ref[@intCast(i_pk)] >= 0) {
                row = (try expr_mod.exprDup(p.arena, changes.at(@intCast(ax_ref[@intCast(i_pk)])).expr)).?;
            } else {
                row = try exprRowColumn(p, i_pk);
            }
        }
        var list = try expr_mod.listAppend(p, null, row);
        for (0..t.cols.len) |i| {
            if (ax_ref[i] >= 0) {
                list = try expr_mod.listAppend(p, list, try expr_mod.exprDup(p.arena, changes.at(@intCast(ax_ref[i])).expr));
            } else {
                const row_expr = try exprRowColumn(p, @intCast(i));
                row_expr.op2 = @intCast(vi.OPFLAG.NOCHNG);
                list = try expr_mod.listAppend(p, list, row_expr);
            }
        }
        try updateFromSelect(p, ephem_tab, pk, list, src, where);
        e_one_pass = ONEPASS.OFF;
    } else {
        p.n_mem += 1;
        const reg_rec: Reg = .from(p.n_mem);
        p.n_mem += 1;
        const reg_rowid: Reg = .from(p.n_mem);

        // Scan the virtual table.
        w = where_mod.whereBegin(p, src, where, null, null, null, .{ .ONEPASS_DESIRED = true }, 0) orelse return;

        // The arguments.
        for (t.cols, 0..) |*c, ii| {
            const i: i32 = @intCast(ii);
            std.debug.assert(!c.col_flags.intersects(COLFLAG.GENERATED));
            if (ax_ref[ii] >= 0) {
                ec.exprCode(p, changes.at(@intCast(ax_ref[ii])).expr, reg_arg.at(2 + i).int());
            } else {
                _ = aux.emit(v, .VColumn, .{ csr, i, reg_arg.at(2 + i) });
                // For sqlite3_vtab_nochange().
                aux.changeP5(v, vi.OPFLAG.NOCHNG);
            }
        }
        if (t.hasRowid()) {
            _ = aux.emit(v, .Rowid, .{ csr, reg_arg });
            if (rowid) |r| {
                ec.exprCode(p, r, reg_arg.at(1).int());
            } else {
                _ = aux.emit(v, .Rowid, .{ csr, reg_arg.at(1) });
            }
        } else {
            const pk = build.primaryKeyIndex(t).?;
            std.debug.assert(pk.n_key_col == 1);
            const i_pk = pk.ai_column[0];
            _ = aux.emit(v, .VColumn, .{ csr, i_pk, reg_arg });
            _ = aux.emit(v, .SCopy, .{ reg_arg.at(@as(i32, 2) + i_pk), reg_arg.at(1) });
        }

        var a_dummy: [2]i32 = undefined;
        e_one_pass = where_mod.okOnePass(w.?, &a_dummy);
        // No ONEPASS.MULTI on virtual tables.
        std.debug.assert(e_one_pass == ONEPASS.OFF or e_one_pass == ONEPASS.SINGLE);
        if (e_one_pass != ONEPASS.OFF) {
            // One pass: no ephemeral table.
            _ = aux.changeToNoop(v, addr.int());
            _ = aux.emit(v, .Close, .{csr});
        } else {
            // The record of the arguments goes to the ephemeral table.
            main_mod.multiWrite(p);
            _ = aux.emit(v, .MakeRecord, .{ reg_arg, n_arg, reg_rec });
            _ = aux.emit(v, .NewRowid, .{ ephem_tab, reg_rowid });
            _ = aux.emit(v, .Insert, .{ ephem_tab, reg_rec, reg_rowid });
        }
    }

    if (e_one_pass == ONEPASS.OFF) {
        // End the virtual table scan, and loop over the ephemeral table,
        // loading the arguments from each row.
        if (src.len() == 1) where_mod.whereEnd(w.?);
        addr = aux.emit(v, .Rewind, .{ephem_tab});
        var i: i32 = 0;
        while (i < n_arg) : (i += 1) _ = aux.emit(v, .Column, .{ ephem_tab, i, reg_arg.at(i) });
    }
    vtab.makeWritable(p, t);
    _ = aux.emit4(v, .VUpdate, .{ 0, n_arg, reg_arg }, build.vtabP4(db, t));
    aux.changeP5(v, (if (on_error == OE.Default) OE.Abort else on_error).int());
    main_mod.mayAbort(p);

    // The end of the loop over the ephemeral table; or with one pass,
    // where an empty scan jumps.
    if (e_one_pass == ONEPASS.OFF) {
        _ = aux.emit(v, .Next, .{ ephem_tab, addr.plus(1) });
        aux.landHere(v, addr);
        _ = aux.emit(v, .Close, .{ephem_tab});
    } else {
        where_mod.whereEnd(w.?);
    }
}

/// Port of sqlite3ColumnDefault(): after OP_Column of column `i` of `t`,
/// give it the DEFAULT value for rows stored before the column was added
/// (as P4), and REAL affinity if it has it.
pub fn columnDefault(v: *vi.Vdbe, t: *int.Table, i: i32, reg: i32) void {
    const col = &t.cols[@intCast(i)];
    if (col.i_dflt != 0) {
        // columnDefaultUncommonCase().
        const e = build.columnExprAuth(t, col, v.parse.?);
        if (valueFromExpr(v, e, col.affinity) catch blk: {
            v.db.oomFault();
            break :blk null;
        }) |m| aux.appendP4(v, .{ .mem = m });
    }
    if (col.affinity == Aff.real) _ = aux.emit(v, .RealAffinity, .{Reg.from(reg)});
}

const OP = vi.OP;

/// Port of sqlite3ValueFromExpr() (vdbemem.c) for a constant literal: its
/// value with affinity `aff`, allocated with the program `v`, or null if
/// `e` is not such a constant.
pub fn valueFromExpr(v: *vi.Vdbe, e_arg: ?*const Expr, aff: u8) mem.Error!?*Mem {
    const e = e_arg orelse return null;
    const m = (try valueFromExprImpl(v, e, aff)) orelse return null;
    // Only an integer too big for 6 bytes becomes a real here: OP_Column
    // reads a default into an index key without OP_RealAffinity, and
    // smaller ones are stored as integers then, as a REAL column stores
    // them.
    if (aff == Aff.real and m.flags.Int and (m.u.i < -140737488355328 or m.u.i > 140737488355327)) {
        mem.realify(m);
    }
    return m;
}

fn newValue(v: *vi.Vdbe) mem.Error!*Mem {
    const m = try v.alloc().create(Mem);
    m.* = .{ .db = v.db, .flags = .{ .Null = true } };
    return m;
}

/// Port of valueFromExpr() (vdbemem.c).
fn valueFromExprImpl(v: *vi.Vdbe, e_arg: *const Expr, aff: u8) mem.Error!?*Mem {
    var e = e_arg;
    var op = e.op;
    while (op == TK.UPLUS or op == TK.SPAN) {
        e = e.left.?;
        op = e.op;
    }
    if (op == TK.REGISTER) op = e.op2;
    const a = v.alloc();
    // The value is in the database encoding (C's `enc` argument is
    // always ENC(db) here).
    const enc = v.db.enc;

    if (op == TK.CAST) {
        const cast_aff = build.affinityType(e.token(), null);
        const m = (try valueFromExprImpl(v, e.left.?, cast_aff)) orelse return null;
        try mem.cast(m, cast_aff, enc);
        try mem.applyAffinity(m, aff, enc);
        return m;
    }

    // A negative literal in one step (needed for -9223372036854775808),
    // but not for hex literals.
    var neg: i64 = 1;
    var zneg: []const u8 = "";
    if (op == TK.UMINUS) {
        const left = e.left.?;
        if (left.op == TK.INTEGER or left.op == TK.FLOAT) {
            if (left.flags.IntValue or left.token().len < 2 or left.token()[0] != '0' or (left.token()[1] & ~@as(u8, 0x20)) != 'X') {
                e = left;
                op = e.op;
                neg = -1;
                zneg = "-";
            }
        }
    }

    if (op == TK.STRING or op == TK.FLOAT or op == TK.INTEGER) {
        const m = try newValue(v);
        if (e.flags.IntValue) {
            mem.setInt64(m, @as(i64, e.u.value) * neg);
        } else {
            var ival: i64 = 0;
            if (op == TK.INTEGER and util.decOrHexToI64(e.token(), &ival) == .ok) {
                mem.setInt64(m, ival * neg);
            } else {
                const z = try std.mem.concatWithSentinel(a, u8, &.{ zneg, e.token() }, 0);
                try mem.setStr(m, z, vi.ENC.UTF8, .static);
            }
        }
        if (aff == Aff.blob) {
            if (op == TK.FLOAT) {
                var r: f64 = 0;
                _ = numeric.atoF(@ptrCast(m.z.?), &r);
                m.u = .{ .r = r };
                m.flags = .{ .Real = true };
            } else if (op == TK.INTEGER) {
                try mem.applyAffinity(m, Aff.numeric, vi.ENC.UTF8);
            }
        } else {
            try mem.applyAffinity(m, aff, vi.ENC.UTF8);
        }
        if (m.flags.intersects(.{ .Int = true, .IntReal = true, .Real = true })) m.flags.Str = false;
        if (enc != vi.ENC.UTF8) try mem.changeEncoding(m, enc);
        return m;
    } else if (op == TK.UMINUS) {
        // Several minus signs: -(-5).
        const m = (try valueFromExprImpl(v, e.left.?, aff)) orelse return null;
        mem.numerify(m);
        if (m.flags.Real) {
            m.u.r = -m.u.r;
        } else if (m.u.i == std.math.minInt(i64)) {
            m.u = .{ .r = -@as(f64, @floatFromInt(std.math.minInt(i64))) };
            m.setTypeFlag(.{ .Real = true });
        } else {
            m.u.i = -m.u.i;
        }
        try mem.applyAffinity(m, aff, enc);
        return m;
    } else if (op == TK.NULL) {
        return try newValue(v);
    } else if (op == TK.BLOB) {
        const m = try newValue(v);
        const tok = e.token();
        const blob = try util.hexToBlob(a, tok[2 .. tok.len - 1]);
        try mem.setStr(m, blob, 0, .static);
        return m;
    } else if (op == TK.TRUEFALSE) {
        const m = try newValue(v);
        m.flags = .{ .Int = true };
        m.u = .{ .i = @intFromBool(e.token().len == 4) };
        try mem.applyAffinity(m, aff, enc);
        return m;
    }
    return null;
}
