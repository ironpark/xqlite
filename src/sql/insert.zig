//! INSERT statements (port of insert.c): the INSERT driver, AUTOINCREMENT,
//! and the constraint checks and record writes UPDATE shares. UPSERT, the
//! transfer optimization and triggers come later.

const std = @import("std");
const int = @import("sqlite_int.zig");
const select_mod = @import("select.zig");
const pending = @import("pending.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const build = @import("build.zig");
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const walker = @import("walker.zig");
const util = @import("util.zig");
const prepare = @import("prepare.zig");
const delete_mod = @import("delete.zig");
const trigger = @import("trigger.zig");
const fkey = @import("fkey.zig");
const main_mod = @import("main.zig");
const where_mod = @import("where.zig");

const Parse = int.Parse;
const Expr = int.Expr;
const ExprList = int.ExprList;
const IdList = int.IdList;
const SrcList = int.SrcList;
const Select = int.Select;
const Table = int.Table;
const Trigger = int.Trigger;
const Index = int.Index;
const Column = int.Column;
const Upsert = int.Upsert;
const NameContext = int.NameContext;
const Vdbe = vi.Vdbe;
const Oom = int.Oom;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;
const SF = int.SF;
const TK = int.TK;
const TF = int.TF;
const EP = int.EP;
const OE = int.OE;
const RC = int.RC;
const Aff = int.Aff;
const COLFLAG = int.COLFLAG;
const SRT = select_mod.SRT;

/// Port of sqlite3OpenTable(): open cursor `i_cur` on table `t` with
/// OP_OpenRead or OP_OpenWrite (on the PRIMARY KEY of a WITHOUT ROWID
/// table).
pub fn openTable(p: *Parse, i_cur: i32, i_db: usize, t: *Table, opcode: u8) void {
    const v = p.vdbe.?;
    if (t.hasRowid()) {
        _ = aux.addOp4Int(v, opcode, i_cur, @intCast(t.tnum), @intCast(i_db), t.n_nv_col);
    } else {
        const pk = build.primaryKeyIndex(t).?;
        _ = aux.addOp3(v, opcode, i_cur, @intCast(pk.tnum), @intCast(i_db));
        aux.setP4KeyInfo(p, pk);
    }
}

/// Port of sqlite3IndexAffinityStr(): the affinities of the columns of
/// `idx` ('A' to 'C'), cached in the index.
pub fn indexAffinityStr(p: *Parse, idx: *Index) ?[:0]const u8 {
    if (idx.col_aff) |s| return s;
    const t = idx.table;
    const s = build.tableAlloc(p, t).allocSentinel(u8, idx.n_column, 0) catch {
        build.oomFault(p);
        return null;
    };
    for (s, 0..) |*c, n| {
        const x = idx.ai_column[n];
        var aff: u8 = if (x >= 0)
            t.cols[@intCast(x)].affinity
        else if (x == int.XN_ROWID)
            Aff.integer
        else
            expr_mod.affinity(idx.col_expr.?.at(n).expr.?);
        if (aff < Aff.blob) aff = Aff.blob;
        if (aff > Aff.numeric) aff = Aff.numeric;
        c.* = aff;
    }
    idx.col_aff = s;
    return s;
}

/// The affinities of the first `n` columns of `idx`, as SQLite passes
/// sqlite3IndexAffinityStr() with a length to OP_MakeRecord.
pub fn indexAffinityPrefix(p: *Parse, idx: *Index, n: usize) ?[]const u8 {
    const a = indexAffinityStr(p, idx) orelse return null;
    return a[0..@min(n, a.len)];
}

/// Port of sqlite3TableAffinityStr(): the affinities of the stored
/// columns of `t`, without trailing BLOBs.
fn tableAffinityStr(a: std.mem.Allocator, t: *const Table) Oom![:0]u8 {
    var buf = try a.allocSentinel(u8, t.cols.len, 0);
    var j: usize = 0;
    for (t.cols) |c| {
        if (c.col_flags & COLFLAG.VIRTUAL == 0) {
            buf[j] = c.affinity;
            j += 1;
        }
    }
    while (j > 0 and buf[j - 1] <= Aff.blob) j -= 1;
    buf[j] = 0;
    return buf[0..j :0];
}

/// Port of sqlite3TableAffinity(): apply the column affinities of `t` to
/// the registers from `reg` (or, with `reg` 0, set them as P4 of the
/// OP_MakeRecord just coded). STRICT tables get an OP_TypeCheck instead.
pub fn tableAffinity(p: *Parse, t: *Table, reg: i32) void {
    const v = p.vdbe.?;
    if (t.tab_flags & TF.Strict != 0) {
        if (reg == 0) {
            // Turn the OP_MakeRecord into OP_TypeCheck and code it again.
            aux.appendP4(v, .{ .table = t });
            const prev = aux.getLastOp(v);
            prev.opcode = OP.TypeCheck;
            const p3 = prev.p3;
            prev.p3 = 0;
            const p1 = prev.p1;
            const p2 = prev.p2;
            _ = aux.addOp3(v, OP.MakeRecord, p1, p2, p3);
        } else {
            _ = aux.addOp2(v, OP.TypeCheck, reg, t.n_nv_col);
            aux.appendP4(v, .{ .table = t });
        }
        return;
    }
    const aff = t.col_aff orelse blk: {
        const s = tableAffinityStr(build.tableAlloc(p, t), t) catch return build.oomFault(p);
        t.col_aff = s;
        break :blk s;
    };
    if (aff.len == 0) return;
    if (reg != 0) {
        _ = aux.addOp4Str(v, OP.Affinity, reg, @intCast(aff.len), 0, aff);
    } else {
        aux.changeP4Str(v, -1, aff);
    }
}

/// Port of readsTable(): the program already opens `t` (or one of its
/// indexes) of database `i_db` for reading.
fn readsTable(p: *Parse, i_db: usize, t: *Table) bool {
    const v = p.vdbe.?;
    const end = aux.currentAddr(v);
    var i: i32 = 1;
    while (i < end) : (i += 1) {
        const op = aux.getOp(v, i);
        if (op.opcode == OP.OpenRead and op.p3 == @as(i32, @intCast(i_db))) {
            const tnum: int.Pgno = @intCast(op.p2);
            if (tnum == t.tnum) return true;
            var idx = t.index;
            while (idx) |ix| : (idx = ix.next) {
                if (tnum == ix.tnum) return true;
            }
        }
    }
    return false;
}

fn exprColumnFlagUnion(w: *walker.Walker, e: *Expr) u8 {
    if (e.op == TK.COLUMN and e.i_column >= 0) {
        w.e_code |= w.u.tab.?.cols[@intCast(e.i_column)].col_flags;
    }
    return walker.WRC.Continue;
}

/// Port of sqlite3ComputeGeneratedColumns(): with the ordinary columns of
/// `t` in the registers from `reg_store`, compute its generated columns.
pub fn computeGeneratedColumns(p: *Parse, reg_store: i32, t: *Table) void {
    const v = p.vdbe.?;
    // Affinity for the ordinary columns first; '@' (none) for the stored
    // generated columns, not computed yet.
    tableAffinity(p, t, reg_store);
    if (t.tab_flags & TF.HasStored != 0) {
        const op = aux.getLastOp(v);
        if (op.opcode == OP.Affinity) {
            const z: []u8 = @constCast(op.p4.z);
            var jj: usize = 0;
            for (t.cols) |c| {
                if (jj >= z.len) break;
                if (c.col_flags & COLFLAG.VIRTUAL != 0) continue;
                if (c.col_flags & COLFLAG.STORED != 0) z[jj] = Aff.none;
                jj += 1;
            }
        } else if (op.opcode == OP.TypeCheck) {
            // Generated columns are not checked.
            op.p3 = 1;
        }
    }

    // Generated columns may use each other: mark them all unavailable,
    // then compute those whose inputs are available until done.
    for (t.cols) |*c| {
        if (c.col_flags & COLFLAG.GENERATED != 0) c.col_flags |= COLFLAG.NOTAVAIL;
    }
    var w: walker.Walker = .{ .expr_callback = exprColumnFlagUnion, .u = .{ .tab = t } };
    p.i_self_tab = -reg_store;
    var redo: ?*Column = null;
    while (true) {
        var progress = false;
        redo = null;
        for (t.cols, 0..) |*c, i| {
            if (c.col_flags & COLFLAG.NOTAVAIL == 0) continue;
            c.col_flags |= COLFLAG.BUSY;
            w.e_code = 0;
            _ = walker.walkExpr(&w, build.columnExpr(t, c));
            c.col_flags &= ~COLFLAG.BUSY;
            if (w.e_code & COLFLAG.NOTAVAIL != 0) {
                redo = c;
                continue;
            }
            progress = true;
            const x = build.tableColumnToStorage(t, @intCast(i)) + reg_store;
            ec.codeGeneratedColumn(p, t, c, x);
            c.col_flags &= ~COLFLAG.NOTAVAIL;
        }
        if (redo == null or !progress) break;
    }
    if (redo) |c| util.errorMsg(p, "generated column loop on \"{s}\"", .{c.name()});
    p.i_self_tab = 0;
}

/// Port of autoIncBegin(): the register holding the largest rowid of the
/// AUTOINCREMENT table `t`, or 0 if `t` has no AUTOINCREMENT.
fn autoIncBegin(p: *Parse, i_db: usize, t: *Table) i32 {
    const db = p.db;
    if (t.tab_flags & TF.Autoincrement == 0 or db.m_db_flags & int.DBFLAG.Vacuum != 0) return 0;
    const top = build.toplevel(p);
    const seq = db.dbs.items[i_db].schema.seq_tab;
    // sqlite_sequence must be an ordinary rowid table of two columns.
    if (seq == null or !seq.?.hasRowid() or seq.?.e_tab_type == .vtab or seq.?.cols.len != 2) {
        p.n_err += 1;
        p.rc = RC.CORRUPT_SEQUENCE;
        return 0;
    }
    if (!top.uses_ainc) top.ainc = null;
    var info = top.ainc;
    while (info) |a| : (info = a.next) {
        if (a.tab == t) return a.reg_ctr;
    }
    const a = top.arena.create(int.AutoincInfo) catch {
        build.oomFault(p);
        return 0;
    };
    // Registers: the table name, the largest rowid, its rowid in
    // sqlite_sequence, and the original largest rowid.
    top.n_mem += 1;
    a.* = .{ .next = top.ainc, .tab = t, .i_db = i_db, .reg_ctr = top.n_mem + 1 };
    top.n_mem += 3;
    top.ainc = a;
    top.uses_ainc = true;
    return a.reg_ctr;
}

/// Port of sqlite3AutoincrementBegin(): load the AUTOINCREMENT counters
/// from sqlite_sequence.
pub fn autoincrementBegin(p: *Parse) void {
    const db = p.db;
    const v = p.vdbe.?;
    var info = p.ainc;
    while (info) |a| : (info = a.next) {
        const mem_id = a.reg_ctr;
        openTable(p, 0, a.i_db, db.dbs.items[a.i_db].schema.seq_tab.?, OP.OpenRead);
        _ = aux.loadString(v, mem_id - 1, a.tab.name);
        const ops = aux.addOpList(v, &.{
            .{ .opcode = OP.Null },
            .{ .opcode = OP.Rewind, .p2 = 10 },
            .{ .opcode = OP.Column },
            .{ .opcode = OP.Ne, .p2 = 9 },
            .{ .opcode = OP.Rowid },
            .{ .opcode = OP.Column, .p2 = 1 },
            .{ .opcode = OP.AddImm },
            .{ .opcode = OP.Copy },
            .{ .opcode = OP.Goto, .p2 = 11 },
            .{ .opcode = OP.Next, .p2 = 2 },
            .{ .opcode = OP.Integer },
            .{ .opcode = OP.Close },
        }) orelse break;
        ops[0].p2 = mem_id;
        ops[0].p3 = mem_id + 2;
        ops[2].p3 = mem_id;
        ops[3].p1 = mem_id - 1;
        ops[3].p3 = mem_id;
        ops[3].p5 = vi.SQLITE_JUMPIFNULL;
        ops[4].p2 = mem_id + 1;
        ops[5].p3 = mem_id;
        ops[6].p1 = mem_id;
        ops[7].p2 = mem_id + 2;
        ops[7].p1 = mem_id;
        ops[10].p2 = mem_id;
        if (p.n_tab == 0) p.n_tab = 1;
    }
}

/// Port of autoIncStep(): keep the largest rowid in `mem_id`.
fn autoIncStep(p: *Parse, mem_id: i32, reg_rowid: i32) void {
    if (mem_id > 0) _ = aux.addOp2(p.vdbe.?, OP.MemMax, mem_id, reg_rowid);
}

/// Port of sqlite3AutoincrementEnd(): write the AUTOINCREMENT counters
/// back to sqlite_sequence.
pub fn autoincrementEnd(p: *Parse) void {
    if (!p.uses_ainc) return;
    const db = p.db;
    const v = p.vdbe.?;
    var info = p.ainc;
    while (info) |a| : (info = a.next) {
        const mem_id = a.reg_ctr;
        const i_rec = expr_mod.getTempReg(p);
        _ = aux.addOp3(v, OP.Le, mem_id + 2, aux.currentAddr(v) + 7, mem_id);
        openTable(p, 0, a.i_db, db.dbs.items[a.i_db].schema.seq_tab.?, OP.OpenWrite);
        const ops = aux.addOpList(v, &.{
            .{ .opcode = OP.NotNull, .p2 = 2 },
            .{ .opcode = OP.NewRowid },
            .{ .opcode = OP.MakeRecord, .p2 = 2 },
            .{ .opcode = OP.Insert },
            .{ .opcode = OP.Close },
        }) orelse break;
        ops[0].p1 = mem_id + 1;
        ops[1].p2 = mem_id + 1;
        ops[2].p1 = mem_id - 1;
        ops[2].p3 = i_rec;
        ops[3].p2 = i_rec;
        ops[3].p3 = mem_id + 1;
        ops[3].p5 = OPFLAG.APPEND;
        expr_mod.releaseTempReg(p, i_rec);
    }
}

/// Port of sqlite3MultiValuesEnd(). VALUES lists are always compound
/// selects here (the co-routine method is not ported), so nothing to do.
pub fn multiValuesEnd(p: *Parse, val: ?*Select) void {
    _ = .{ p, val };
}

/// Port of sqlite3MultiValues(): add a row to a multi-row VALUES clause,
/// with the "UNION ALL" method.
pub fn multiValues(p: *Parse, left_arg: *Select, row: ?*ExprList) Oom!*Select {
    var left = left_arg;
    var f: u32 = SF.Values | SF.MultiValue;
    if (left.src.?.len() != 0) {
        multiValuesEnd(p, left);
        f = SF.Values;
    } else if (left.prior != null) {
        f &= left.sel_flags;
    }
    const s = try select_mod.selectNew(p, row, null, null, null, null, null, f, null);
    left.sel_flags &= ~SF.MultiValue;
    s.op = TK.ALL;
    s.prior = left;
    left = s;
    return left;
}

/// Port of sqlite3Insert(): INSERT INTO `tab_list` [(column)] with the
/// rows of `sel` (VALUES or a SELECT), or DEFAULT VALUES if null.
pub fn insert(p: *Parse, tab_list: ?*SrcList, sel: ?*Select, column: ?*IdList, on_error: i32, upsert: ?*Upsert) void {
    if (p.syntax_only) return;
    insertImpl(p, tab_list.?, sel, column, @intCast(on_error), upsert) catch build.oomFault(p);
}

fn insertImpl(p: *Parse, tab_list: *SrcList, sel_arg: ?*Select, column: ?*IdList, on_error: u8, upsert: ?*Upsert) Oom!void {
    const db = p.db;
    if (p.n_err != 0) return;
    var sel = sel_arg;
    var list: ?*ExprList = null;

    // A single-row VALUES clause is just its expressions.
    if (sel) |s| if (s.sel_flags & SF.Values != 0 and s.prior == null) {
        list = s.e_list;
        sel = null;
    };

    const t = build.srcListLookup(p, tab_list) orelse return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    const without_rowid = !t.hasRowid();

    var tmask: u8 = 0;
    const trig = trigger.triggersExist(p, t, TK.INSERT, null, &tmask);
    const is_view = t.isView();
    if (p.n_err != 0) return;
    if (build.viewGetColumnNames(p, t) != 0) return;
    if (delete_mod.isReadOnly(p, t, trig)) return;
    if (upsert != null) {
        pending.notYet(p, "UPSERT");
        return;
    }
    if (t.e_tab_type == .vtab) {
        pending.notYet(p, "virtual tables");
        return;
    }

    const v = build.getVdbe(p) orelse return;
    if (p.nested == 0) aux.countChanges(v);
    build.beginWriteOperation(p, sel != null or trig != null, i_db);

    const reg_autoinc = autoIncBegin(p, i_db, t);

    // The rowid and the columns of the new row.
    var reg_rowid = p.n_mem + 1;
    var reg_ins = reg_rowid;
    p.n_mem += @as(i32, @intCast(t.cols.len)) + 1;
    var reg_data = reg_rowid + 1;

    // Map the IDLIST to the columns. b_id_list_in_order: the IDLIST
    // names the columns in storage order (a false negative is harmless,
    // a false positive corrupts the database).
    var ipk_column: i32 = -1;
    var b_id_list_in_order = t.tab_flags & (TF.OOOHidden | TF.HasStored) == 0;
    var tab_col_map: []i32 = &.{};
    if (column) |cl| {
        tab_col_map = try p.arena.alloc(i32, t.cols.len);
        @memset(tab_col_map, 0);
        for (cl.names.items, 0..) |name, ii| {
            const i: i32 = @intCast(ii);
            const j = build.columnIndex(t, name);
            if (j >= 0) {
                const ju: usize = @intCast(j);
                if (tab_col_map[ju] == 0) tab_col_map[ju] = i + 1;
                if (i != j) b_id_list_in_order = false;
                if (j == t.i_pkey) ipk_column = i;
                if (t.cols[ju].col_flags & (COLFLAG.STORED | COLFLAG.VIRTUAL) != 0) {
                    util.errorMsg(p, "cannot INSERT into generated column \"{s}\"", .{t.cols[ju].name()});
                    return;
                }
            } else if (resolve.isRowid(name) and !without_rowid) {
                ipk_column = i;
                b_id_list_in_order = false;
            } else {
                util.errorMsg(p, "table {f} has no column named {s}", .{ util.srcItemName(tab_list.at(0)), name });
                p.check_schema = true;
                return;
            }
        }
    }

    // The source of the rows: a co-routine running the SELECT, or the
    // single row of a VALUES clause.
    var n_column: i32 = 0;
    var src_tab: i32 = 0;
    var reg_from_select: i32 = 0;
    var use_temp_table = false;
    var dest: select_mod.SelectDest = undefined;
    if (sel) |s| {
        p.n_mem += 1;
        const reg_yield = p.n_mem;
        const addr_top = aux.currentAddr(v) + 1;
        _ = aux.addOp3(v, OP.InitCoroutine, reg_yield, 0, addr_top);
        dest = select_mod.selectDestInit(SRT.Coroutine, reg_yield);
        dest.i_sdst = if (b_id_list_in_order) reg_data else 0;
        dest.n_sdst = @intCast(t.cols.len);
        const rc = select_mod.select(p, s, &dest);
        reg_from_select = dest.i_sdst;
        if (rc != 0 or p.n_err != 0) return;
        aux.endCoroutine(v, reg_yield);
        aux.jumpHere(v, addr_top - 1);
        n_column = @intCast(s.e_list.?.len());

        // Rows go through a temporary table if the SELECT reads the
        // table written (or triggers run).
        if (trig != null or readsTable(p, i_db, t)) use_temp_table = true;
        if (use_temp_table) {
            src_tab = p.n_tab;
            p.n_tab += 1;
            const reg_rec = expr_mod.getTempReg(p);
            const reg_temp_rowid = expr_mod.getTempReg(p);
            _ = aux.addOp2(v, OP.OpenEphemeral, src_tab, n_column);
            const addr_l = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
            _ = aux.addOp3(v, OP.MakeRecord, reg_from_select, n_column, reg_rec);
            _ = aux.addOp2(v, OP.NewRowid, src_tab, reg_temp_rowid);
            _ = aux.addOp3(v, OP.Insert, src_tab, reg_rec, reg_temp_rowid);
            _ = aux.goto_(v, addr_l);
            aux.jumpHere(v, addr_l);
            expr_mod.releaseTempReg(p, reg_rec);
            expr_mod.releaseTempReg(p, reg_temp_rowid);
        }
    } else {
        var nc: NameContext = .{ .parse = p };
        src_tab = -1;
        if (list) |l| {
            n_column = @intCast(l.len());
            if (resolve.resolveExprListNames(&nc, l) != 0) return;
        }
    }

    // Without an IDLIST the values go to the columns in order, the
    // INTEGER PRIMARY KEY included.
    if (column == null and n_column > 0) {
        ipk_column = t.i_pkey;
        if (ipk_column >= 0 and t.tab_flags & TF.HasGenerated != 0) {
            var i = ipk_column - 1;
            while (i >= 0) : (i -= 1) {
                if (t.cols[@intCast(i)].col_flags & COLFLAG.GENERATED != 0) ipk_column -= 1;
            }
        }
        var n_hidden: i32 = 0;
        if (t.tab_flags & (TF.HasGenerated | TF.HasHidden) != 0) {
            for (t.cols) |c| {
                if (c.col_flags & COLFLAG.NOINSERT != 0) n_hidden += 1;
            }
        }
        const n_col: i32 = @intCast(t.cols.len);
        if (n_column != n_col - n_hidden) {
            util.errorMsg(p, "table {f} has {d} columns but {d} values were supplied", .{ util.srcItemName(tab_list.at(0)), n_col - n_hidden, n_column });
            return;
        }
    }
    if (column) |cl| if (n_column != cl.len()) {
        util.errorMsg(p, "{d} values for {d} columns", .{ n_column, cl.len() });
        return;
    };

    var reg_row_count: i32 = 0;
    if (db.flags & int.DbFlag.CountRows != 0 and p.nested == 0 and p.trigger_tab == null and !p.returning) {
        p.n_mem += 1;
        reg_row_count = p.n_mem;
        _ = aux.addOp2(v, OP.Integer, 0, reg_row_count);
    }

    // Open the table and its indexes; a register range for each index
    // entry, and one for the table record.
    var i_data_cur: i32 = 0;
    var i_idx_cur: i32 = 0;
    var reg_idx: []i32 = &.{};
    if (!is_view) {
        const n_idx = openTableAndIndices(p, t, OP.OpenWrite, 0, -1, null, &i_data_cur, &i_idx_cur);
        reg_idx = try p.arena.alloc(i32, n_idx + 1);
        var idx = t.index;
        var i: usize = 0;
        while (idx) |ix| : ({
            idx = ix.next;
            i += 1;
        }) {
            p.n_mem += 1;
            reg_idx[i] = p.n_mem;
            p.n_mem += ix.n_column;
        }
        p.n_mem += 1;
        reg_idx[i] = p.n_mem;
    }

    // The top of the loop over the rows.
    var addr_ins_top: i32 = 0;
    var addr_cont: i32 = 0;
    if (use_temp_table) {
        addr_ins_top = aux.addOp1(v, OP.Rewind, src_tab);
        addr_cont = aux.currentAddr(v);
    } else if (sel != null) {
        addr_cont = aux.addOp1(v, OP.Yield, dest.i_sd_parm);
        addr_ins_top = addr_cont;
        // An INTEGER PRIMARY KEY from the SELECT goes to the rowid slot
        // now, before its column slot is set to NULL.
        if (ipk_column >= 0) _ = aux.addOp2(v, OP.Copy, reg_from_select + ipk_column, reg_rowid);
    }

    // The ordinary columns, in storage order from reg_data. The rowid and
    // the generated columns come after.
    {
        var n_hidden: i32 = 0;
        var i_reg_store = reg_data;
        for (t.cols, 0..) |*c, ii| {
            defer i_reg_store += 1;
            const i: i32 = @intCast(ii);
            if (i == t.i_pkey) {
                // The INTEGER PRIMARY KEY is stored as NULL (it is the
                // rowid).
                _ = aux.addOp1(v, OP.SoftNull, i_reg_store);
                continue;
            }
            var k: i32 = undefined;
            const col_flags = c.col_flags;
            if (col_flags & COLFLAG.NOINSERT != 0) {
                n_hidden += 1;
                if (col_flags & COLFLAG.VIRTUAL != 0) {
                    // Not part of the record.
                    i_reg_store -= 1;
                    continue;
                } else if (col_flags & COLFLAG.STORED != 0) {
                    if (tmask & int.TRIGGER_BEFORE != 0) _ = aux.addOp1(v, OP.SoftNull, i_reg_store);
                    continue;
                } else if (column == null) {
                    ec.codeFactorable(p, build.columnExpr(t, c), i_reg_store);
                    continue;
                }
            }
            if (column != null) {
                const j = tab_col_map[ii];
                if (j == 0) {
                    // Not in the IDLIST: the DEFAULT.
                    ec.codeFactorable(p, build.columnExpr(t, c), i_reg_store);
                    continue;
                }
                k = j - 1;
            } else if (n_column == 0) {
                // DEFAULT VALUES.
                ec.codeFactorable(p, build.columnExpr(t, c), i_reg_store);
                continue;
            } else {
                k = i - n_hidden;
            }

            if (use_temp_table) {
                _ = aux.addOp3(v, OP.Column, src_tab, k, i_reg_store);
            } else if (sel != null) {
                if (reg_from_select != reg_data) _ = aux.addOp2(v, OP.SCopy, reg_from_select + k, i_reg_store);
            } else {
                const x = list.?.at(@intCast(k)).expr.?;
                const y = ec.codeTarget(p, x, i_reg_store);
                if (y != i_reg_store) _ = aux.addOp2(v, if (x.has(EP.Subquery)) OP.Copy else OP.SCopy, y, i_reg_store);
            }
        }
    }

    const end_of_loop = aux.makeLabel(p);

    // BEFORE (and INSTEAD OF) triggers, given the NEW.* row.
    if (tmask & int.TRIGGER_BEFORE != 0) {
        const n_col: i32 = @intCast(t.cols.len);
        const reg_cols = expr_mod.getTempRange(p, n_col + 1);
        // The rowid of a NULL INTEGER PRIMARY KEY is not known before the
        // insert: it is -1 here.
        if (ipk_column < 0) {
            _ = aux.addOp2(v, OP.Integer, -1, reg_cols);
        } else {
            std.debug.assert(!without_rowid);
            if (use_temp_table) {
                _ = aux.addOp3(v, OP.Column, src_tab, ipk_column, reg_cols);
            } else {
                std.debug.assert(sel == null);
                ec.exprCode(p, list.?.at(@intCast(ipk_column)).expr, reg_cols);
            }
            const addr1 = aux.addOp1(v, OP.NotNull, reg_cols);
            _ = aux.addOp2(v, OP.Integer, -1, reg_cols);
            aux.jumpHere(v, addr1);
            _ = aux.addOp1(v, OP.MustBeInt, reg_cols);
            main_mod.mayAbort(p);
        }
        _ = aux.addOp3(v, OP.Copy, reg_rowid + 1, reg_cols + 1, t.n_nv_col - 1);
        // Generated columns may use the rowid, so they come last.
        if (t.tab_flags & TF.HasGenerated != 0) computeGeneratedColumns(p, reg_cols + 1, t);
        // A view takes the values as they are.
        if (!is_view) tableAffinity(p, t, reg_cols + 1);
        trigger.codeRowTrigger(p, trig, TK.INSERT, null, int.TRIGGER_BEFORE, t, reg_cols - n_col - 1, on_error, end_of_loop);
        expr_mod.releaseTempRange(p, reg_cols, n_col + 1);
    }

    var append_flag = false;
    if (!is_view) {
        if (ipk_column >= 0) {
            // The rowid given by the row.
            if (use_temp_table) {
                _ = aux.addOp3(v, OP.Column, src_tab, ipk_column, reg_rowid);
            } else if (sel != null) {
                // Already copied above.
            } else {
                const ipk = list.?.at(@intCast(ipk_column)).expr.?;
                if (ipk.op == TK.NULL) {
                    _ = aux.addOp3(v, OP.NewRowid, i_data_cur, reg_rowid, reg_autoinc);
                    append_flag = true;
                } else {
                    ec.exprCode(p, ipk, reg_rowid);
                }
            }
            // A NULL rowid gets a new one.
            if (!append_flag) {
                const addr1 = aux.addOp1(v, OP.NotNull, reg_rowid);
                _ = aux.addOp3(v, OP.NewRowid, i_data_cur, reg_rowid, reg_autoinc);
                aux.jumpHere(v, addr1);
                _ = aux.addOp1(v, OP.MustBeInt, reg_rowid);
                main_mod.mayAbort(p);
            }
        } else if (without_rowid) {
            _ = aux.addOp2(v, OP.Null, 0, reg_rowid);
        } else {
            _ = aux.addOp3(v, OP.NewRowid, i_data_cur, reg_rowid, reg_autoinc);
            append_flag = true;
        }
        autoIncStep(p, reg_autoinc, reg_rowid);

        // Generated columns may use the rowid, so they come last.
        if (t.tab_flags & TF.HasGenerated != 0) computeGeneratedColumns(p, reg_rowid + 1, t);

        var is_replace = false;
        generateConstraintChecks(p, t, reg_idx, i_data_cur, i_idx_cur, reg_ins, 0, ipk_column >= 0, on_error, end_of_loop, &is_replace, null);
        if (db.flags & int.DbFlag.ForeignKeys != 0) fkey.fkCheck(p, t, 0, reg_ins, null, false);
        // OPFLAG_USESEEKRESULT is safe without REPLACE, or without
        // trigger programs (a REPLACE delete then resets the seek result).
        const use_seek = !is_replace or !aux.hasSubProgram(v);
        completeInsertion(p, t, i_data_cur, i_idx_cur, reg_ins, reg_idx, 0, append_flag, use_seek);
    }

    if (reg_row_count != 0) _ = aux.addOp2(v, OP.AddImm, reg_row_count, 1);

    if (trig != null) {
        trigger.codeRowTrigger(p, trig, TK.INSERT, null, int.TRIGGER_AFTER, t, reg_data - 2 - @as(i32, @intCast(t.cols.len)), on_error, end_of_loop);
    }

    // The bottom of the loop.
    aux.resolveLabel(v, end_of_loop);
    if (use_temp_table) {
        _ = aux.addOp2(v, OP.Next, src_tab, addr_cont);
        aux.jumpHere(v, addr_ins_top);
        _ = aux.addOp1(v, OP.Close, src_tab);
    } else if (sel != null) {
        _ = aux.goto_(v, addr_cont);
        aux.jumpHere(v, addr_ins_top);
    }

    if (p.nested == 0 and p.trigger_tab == null) autoincrementEnd(p);
    if (reg_row_count != 0) delete_mod.codeChangeCount(v, reg_row_count, "rows inserted");
    _ = &reg_ins;
    _ = &reg_data;
    _ = &reg_rowid;
}

/// sqlite3ExprReferencesUpdatedColumn() walker bits.
const CKCNSTRNT_COLUMN: u16 = 0x01;
const CKCNSTRNT_ROWID: u16 = 0x02;

const ChngCtx = struct { ai_chng: []const i32 };

fn checkConstraintExprNode(w: *walker.Walker, e: *Expr) u8 {
    if (e.op == TK.COLUMN) {
        const ctx: *const ChngCtx = @ptrCast(@alignCast(w.u.ptr.?));
        if (e.i_column >= 0) {
            if (ctx.ai_chng[@intCast(e.i_column)] >= 0) w.e_code |= CKCNSTRNT_COLUMN;
        } else {
            w.e_code |= CKCNSTRNT_ROWID;
        }
    }
    return walker.WRC.Continue;
}

/// Port of sqlite3ExprReferencesUpdatedColumn(): `e` uses a column
/// changed by an UPDATE (ai_chng[i] >= 0), or the rowid if `chng_rowid`.
pub fn exprReferencesUpdatedColumn(e: ?*Expr, ai_chng: []const i32, chng_rowid: bool) bool {
    var ctx: ChngCtx = .{ .ai_chng = ai_chng };
    var w: walker.Walker = .{ .expr_callback = checkConstraintExprNode, .u = .{ .ptr = &ctx } };
    _ = walker.walkExpr(&w, e);
    if (!chng_rowid) w.e_code &= ~CKCNSTRNT_ROWID;
    return w.e_code != 0;
}

/// Port of sqlite3GenerateConstraintChecks(): check the NOT NULL, CHECK,
/// rowid and UNIQUE constraints of a row about to be written, with the
/// new rowid and columns in the registers from `reg_new_data` (the old
/// ones from `reg_old_data` for an UPDATE, else 0). Index entries go to
/// the registers of `reg_idx` (0 to skip an index), and for a rowid
/// table the record to its last element.
pub fn generateConstraintChecks(
    p: *Parse,
    t: *Table,
    reg_idx: []const i32,
    i_data_cur: i32,
    i_idx_cur: i32,
    reg_new_data: i32,
    reg_old_data: i32,
    pk_chng: bool,
    override_error_arg: u8,
    ignore_dest: i32,
    may_replace: *bool,
    ai_chng: ?[]const i32,
) void {
    generateConstraintChecksImpl(p, t, reg_idx, i_data_cur, i_idx_cur, reg_new_data, reg_old_data, pk_chng, override_error_arg, ignore_dest, may_replace, ai_chng) catch build.oomFault(p);
}

fn generateConstraintChecksImpl(
    p: *Parse,
    t: *Table,
    reg_idx: []const i32,
    i_data_cur: i32,
    i_idx_cur: i32,
    reg_new_data: i32,
    reg_old_data: i32,
    pk_chng: bool,
    override_error: u8,
    ignore_dest: i32,
    may_replace: *bool,
    ai_chng: ?[]const i32,
) Oom!void {
    const db = p.db;
    const v = p.vdbe.?;
    const is_update = reg_old_data != 0;
    var seen_replace = false;
    var b_affinity_done = false;

    // The PRIMARY KEY of a WITHOUT ROWID table, and the fields of the
    // true primary key.
    const pk: ?*Index = if (t.hasRowid()) null else build.primaryKeyIndex(t);
    const n_pk_field: i32 = if (pk) |k| k.n_key_col else 1;

    // NOT NULL. A second pass handles generated columns and the columns
    // that ON CONFLICT REPLACE gave a default.
    if (t.tab_flags & TF.HasNotNull != 0) {
        var b2nd_pass = false;
        var n_seen_replace: i32 = 0;
        var n_generated: i32 = 0;
        while (true) {
            for (t.cols, 0..) |*c, ii| {
                const i: i32 = @intCast(ii);
                var on_error: u8 = c.not_null;
                if (on_error == OE.None) continue;
                if (i == t.i_pkey) continue;
                const is_generated = c.col_flags & COLFLAG.GENERATED != 0;
                if (is_generated and !b2nd_pass) {
                    n_generated += 1;
                    continue;
                }
                // Unchanged columns need no check.
                if (ai_chng) |ac| if (ac[ii] < 0 and !is_generated) continue;
                if (override_error != OE.Default) {
                    on_error = override_error;
                } else if (on_error == OE.Default) {
                    on_error = OE.Abort;
                }
                if (on_error == OE.Replace) {
                    if (b2nd_pass or c.i_dflt == 0) on_error = OE.Abort;
                } else if (b2nd_pass and !is_generated) {
                    continue;
                }
                const i_reg = build.tableColumnToStorage(t, @intCast(i)) + reg_new_data + 1;
                switch (on_error) {
                    OE.Replace => {
                        const addr1 = aux.addOp1(v, OP.NotNull, i_reg);
                        n_seen_replace += 1;
                        ec.codeCopy(p, build.columnExpr(t, c), i_reg);
                        aux.jumpHere(v, addr1);
                    },
                    OE.Abort, OE.Rollback, OE.Fail => {
                        if (on_error == OE.Abort) main_mod.mayAbort(p);
                        const msg = try std.fmt.allocPrint(p.arena, "{s}.{s}", .{ t.name, c.name() });
                        _ = aux.addOp4Str(v, OP.HaltIfNull, RC.CONSTRAINT_NOTNULL, on_error, i_reg, msg);
                        aux.changeP5(v, vi.P5_ConstraintNotNull);
                    },
                    else => {
                        _ = aux.addOp2(v, OP.IsNull, i_reg, ignore_dest);
                    },
                }
            }
            if (n_generated == 0 and n_seen_replace == 0) break;
            if (b2nd_pass) break;
            b2nd_pass = true;
            if (n_seen_replace > 0 and t.tab_flags & TF.HasGenerated != 0) computeGeneratedColumns(p, reg_new_data + 1, t);
        }
    }

    // CHECK.
    if (t.check) |checks| if (db.flags & int.DbFlag.IgnoreChecks == 0) {
        p.i_self_tab = -(reg_new_data + 1);
        var on_error: u8 = if (override_error != OE.Default) override_error else OE.Abort;
        for (checks.slice()) |item| {
            const e = item.expr;
            if (ai_chng) |ac| if (!exprReferencesUpdatedColumn(e, ac, pk_chng)) continue;
            if (!b_affinity_done) {
                tableAffinity(p, t, reg_new_data + 1);
                b_affinity_done = true;
            }
            const all_ok = aux.makeLabel(p);
            const copy = try expr_mod.exprDup(p.arena, e);
            if (!db.malloc_failed) ec.exprIfTrue(p, copy, all_ok, vi.SQLITE_JUMPIFNULL);
            if (on_error == OE.Ignore) {
                _ = aux.goto_(v, ignore_dest);
            } else {
                if (on_error == OE.Replace) on_error = OE.Abort;
                build.haltConstraint(p, RC.CONSTRAINT_CHECK, on_error, item.e_name, vi.P5_ConstraintCheck);
            }
            aux.resolveLabel(v, all_ok);
        }
        p.i_self_tab = 0;
    };

    // UNIQUE and PRIMARY KEY: (A) the rowid, (B) the indexes without
    // REPLACE, (C) those with REPLACE (createIndex() puts them last).
    //
    // Deletes by REPLACE may run "replace triggers" (DELETE triggers or
    // foreign key actions). If any did, every uniqueness constraint is
    // checked again afterwards, with ABORT: reg_trig_cnt counts them, and
    // the rechecks are chained through lbl_recheck_ok from addr_recheck.
    var trig: ?*Trigger = null;
    var reg_trig_cnt: i32 = 0;
    var addr_recheck: i32 = 0;
    var lbl_recheck_ok: i32 = 0;
    var n_replace_trig: i32 = 0;
    if (db.flags & (int.DbFlag.RecTriggers | int.DbFlag.ForeignKeys) != 0) {
        if (db.flags & int.DbFlag.RecTriggers != 0) trig = trigger.triggersExist(p, t, TK.DELETE, null, null);
        var may_fire = trig != null or fkey.fkRequired(p, t, null, false) != 0;
        // Only if a row may be deleted by a REPLACE.
        if (may_fire and override_error != OE.Replace) {
            if (override_error != OE.Default) {
                may_fire = false;
            } else if (!pk_chng or pk != null or t.key_conf != OE.Replace) {
                var it = t.index;
                while (it) |ix| : (it = ix.next) {
                    if (ix.on_error == OE.Replace) break;
                }
                if (it == null) may_fire = false;
            }
        }
        if (may_fire) {
            p.n_mem += 1;
            reg_trig_cnt = p.n_mem;
            _ = aux.addOp2(v, OP.Integer, 0, reg_trig_cnt);
            lbl_recheck_ok = aux.makeLabel(p);
            addr_recheck = lbl_recheck_ok;
        }
    }

    var ipk_top: i32 = 0;
    var ipk_bottom: i32 = 0;
    if (pk_chng and pk == null) {
        // The new rowid must not exist already.
        const addr_rowid_ok = aux.makeLabel(p);
        var on_error: u8 = t.key_conf;
        if (override_error != OE.Default) {
            on_error = override_error;
        } else if (on_error == OE.Default) {
            on_error = OE.Abort;
        }

        // A REPLACE of the rowid waits until the other constraints, which
        // may FAIL or IGNORE, have been checked.
        if (on_error == OE.Replace and on_error != override_error and t.index != null) {
            ipk_top = aux.addOp0(v, OP.Goto) + 1;
        }

        // An UPDATE need not check an unchanged rowid.
        if (is_update) {
            _ = aux.addOp3(v, OP.Eq, reg_new_data, addr_rowid_ok, reg_old_data);
            aux.changeP5(v, vi.SQLITE_NOTNULL);
        }

        _ = aux.addOp3(v, OP.NotExists, i_data_cur, addr_rowid_ok, reg_new_data);
        switch (on_error) {
            OE.Replace => {
                if (reg_trig_cnt != 0) {
                    // Delete the other row, running its triggers.
                    main_mod.multiWrite(p);
                    delete_mod.generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, reg_new_data, 1, false, OE.Replace, where_mod.ONEPASS_SINGLE, -1);
                    _ = aux.addOp2(v, OP.AddImm, reg_trig_cnt, 1);
                    n_replace_trig += 1;
                } else if (t.index != null) {
                    // The index entries of the other row go; its record is
                    // overwritten by the new one.
                    main_mod.multiWrite(p);
                    delete_mod.generateRowIndexDelete(p, t, i_data_cur, i_idx_cur, null, -1);
                }
                seen_replace = true;
            },
            OE.Ignore => _ = aux.goto_(v, ignore_dest),
            OE.Rollback, OE.Fail => build.rowidConstraint(p, on_error, t),
            else => build.rowidConstraint(p, OE.Abort, t),
        }
        aux.resolveLabel(v, addr_rowid_ok);
        if (ipk_top != 0) {
            ipk_bottom = aux.addOp0(v, OP.Goto);
            aux.jumpHere(v, ipk_top - 1);
        }
    }

    // UNIQUE indexes (and the PRIMARY KEY of a WITHOUT ROWID table):
    // build each new index entry and make sure it is not there already.
    var ix: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        ix += 1;
    }) {
        if (reg_idx[ix] == 0) continue;
        const addr_unique_ok = aux.makeLabel(p);
        if (!b_affinity_done) {
            tableAffinity(p, t, reg_new_data + 1);
            b_affinity_done = true;
        }
        const i_this_cur = i_idx_cur + @as(i32, @intCast(ix));

        // A partial index whose WHERE is false gets no entry.
        if (idx.part_idx_where) |w| {
            _ = aux.addOp2(v, OP.Null, 0, reg_idx[ix]);
            p.i_self_tab = -(reg_new_data + 1);
            ec.exprIfFalseDup(p, w, addr_unique_ok, vi.SQLITE_JUMPIFNULL);
            p.i_self_tab = 0;
        }

        // The new index entry, to reg_idx[ix].
        const reg_ix = reg_idx[ix] + 1;
        for (0..idx.n_column) |ii| {
            const i: i32 = @intCast(ii);
            const i_field = idx.ai_column[ii];
            if (i_field == int.XN_EXPR) {
                p.i_self_tab = -(reg_new_data + 1);
                ec.codeCopy(p, idx.col_expr.?.at(ii).expr, reg_ix + i);
                p.i_self_tab = 0;
            } else if (i_field == int.XN_ROWID or i_field == t.i_pkey) {
                _ = aux.addOp2(v, OP.IntCopy, reg_new_data, reg_ix + i);
            } else {
                const x = build.tableColumnToStorage(t, i_field) + reg_new_data + 1;
                _ = aux.addOp2(v, OP.SCopy, x, reg_ix + i);
            }
        }
        _ = aux.addOp3(v, OP.MakeRecord, reg_ix, idx.n_column, reg_idx[ix]);

        // The PRIMARY KEY of an UPDATE that does not change it cannot
        // collide.
        if (is_update and pk == idx and !pk_chng) {
            aux.resolveLabel(v, addr_unique_ok);
            continue;
        }

        var on_error: u8 = idx.on_error;
        if (on_error == OE.None) {
            aux.resolveLabel(v, addr_unique_ok);
            continue;
        }
        if (override_error != OE.Default) {
            on_error = override_error;
        } else if (on_error == OE.Default) {
            on_error = OE.Abort;
        }

        // No collision check is needed for a REPLACE of the PRIMARY KEY of
        // a WITHOUT ROWID table without other indexes (the new entry
        // overwrites the old).
        if (ix == 0 and idx.next == null and pk == idx and on_error == OE.Replace and
            (db.flags & int.DbFlag.RecTriggers == 0 or trigger.triggersExist(p, t, TK.DELETE, null, null) == null) and
            (db.flags & int.DbFlag.ForeignKeys == 0 or (t.u.tab.fkey == null and fkey.fkReferences(t) == null)))
        {
            aux.resolveLabel(v, addr_unique_ok);
            continue;
        }

        // Is the new entry unique?
        var addr_conflict_ck = aux.addOp4Int(v, OP.NoConflict, i_this_cur, addr_unique_ok, reg_ix, idx.n_key_col);

        // On a collision, the key of the other row goes to reg_r.
        const reg_r = if (idx == pk) reg_ix else expr_mod.getTempRange(p, n_pk_field);
        if (is_update or on_error == OE.Replace) {
            if (t.hasRowid()) {
                _ = aux.addOp2(v, OP.IdxRowid, i_this_cur, reg_r);
                // No conflict with the row being updated.
                if (is_update) {
                    _ = aux.addOp3(v, OP.Eq, reg_r, addr_unique_ok, reg_old_data);
                    aux.changeP5(v, vi.SQLITE_NOTNULL);
                }
            } else {
                const k = pk.?;
                if (idx != k) {
                    for (0..k.n_key_col) |ii| {
                        const x = build.tableColumnToIndex(idx, k.ai_column[ii]);
                        _ = aux.addOp3(v, OP.Column, i_this_cur, x, reg_r + @as(i32, @intCast(ii)));
                    }
                }
                if (is_update) {
                    // A conflict only if the PRIMARY KEY found differs from
                    // the old one.
                    var addr_jump = aux.currentAddr(v) + k.n_key_col;
                    var op: u8 = OP.Ne;
                    const reg_cmp = if (idx.isPrimaryKey()) reg_ix else reg_r;
                    for (0..k.n_key_col) |ii| {
                        const coll = @import("coll.zig").locateCollSeq(p, k.coll[ii]);
                        var x: i32 = k.ai_column[ii];
                        if (ii == k.n_key_col - 1) {
                            addr_jump = addr_unique_ok;
                            op = OP.Eq;
                        }
                        x = build.tableColumnToStorage(t, @intCast(x));
                        _ = aux.addOp4(v, op, reg_old_data + 1 + x, addr_jump, reg_cmp + @as(i32, @intCast(ii)), if (coll) |cl| .{ .collseq = cl } else .notused);
                        aux.changeP5(v, vi.SQLITE_NOTNULL);
                    }
                }
            }
        }

        const n_conflict_end = aux.currentAddr(v);
        switch (on_error) {
            OE.Rollback, OE.Abort, OE.Fail => build.uniqueConstraint(p, on_error, idx),
            OE.Ignore => _ = aux.goto_(v, ignore_dest),
            else => {
                // REPLACE: delete the other row.
                if (reg_trig_cnt != 0) {
                    main_mod.multiWrite(p);
                    n_replace_trig += 1;
                }
                if (trig != null and is_update) _ = aux.addOp1(v, OP.CursorLock, i_data_cur);
                delete_mod.generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, reg_r, @intCast(n_pk_field), false, OE.Replace, if (idx == pk) where_mod.ONEPASS_SINGLE else where_mod.ONEPASS_OFF, i_this_cur);
                if (trig != null and is_update) _ = aux.addOp1(v, OP.CursorUnlock, i_data_cur);
                seen_replace = true;
            },
        }
        if (reg_trig_cnt != 0) {
            _ = aux.addOp2(v, OP.AddImm, reg_trig_cnt, 1);
            const addr_bypass = aux.addOp0(v, OP.Goto);

            // The recheck, run after all the constraint checks if a
            // replace trigger fired: the conflict check above again,
            // jumping on to the next recheck when it passes.
            aux.resolveLabel(v, lbl_recheck_ok);
            lbl_recheck_ok = aux.makeLabel(p);
            if (idx.part_idx_where != null) _ = aux.addOp2(v, OP.IsNull, reg_ix - 1, lbl_recheck_ok);
            while (addr_conflict_ck < n_conflict_end) : (addr_conflict_ck += 1) {
                const x = aux.getOp(v, addr_conflict_ck).*;
                if (x.opcode != OP.IdxRowid or is_update) {
                    const p2 = if (vi.opcodes.properties[x.opcode] & vi.opcodes.OPFLG.JUMP != 0) lbl_recheck_ok else x.p2;
                    _ = aux.addOp4(v, x.opcode, x.p1, p2, x.p3, x.p4);
                    aux.changeP5(v, x.p5);
                }
            }
            build.uniqueConstraint(p, OE.Abort, idx);
            aux.jumpHere(v, addr_bypass);
        }
        aux.resolveLabel(v, addr_unique_ok);
        if (reg_r != reg_ix) expr_mod.releaseTempRange(p, reg_r, n_pk_field);
    }

    // The deferred REPLACE of the rowid.
    if (ipk_top != 0) {
        _ = aux.goto_(v, ipk_top);
        aux.jumpHere(v, ipk_bottom);
    }

    // Recheck the uniqueness constraints after replace triggers ran.
    if (n_replace_trig != 0) {
        _ = aux.addOp2(v, OP.IfNot, reg_trig_cnt, lbl_recheck_ok);
        if (pk == null) {
            if (is_update) {
                _ = aux.addOp3(v, OP.Eq, reg_new_data, addr_recheck, reg_old_data);
                aux.changeP5(v, vi.SQLITE_NOTNULL);
            }
            _ = aux.addOp3(v, OP.NotExists, i_data_cur, addr_recheck, reg_new_data);
            build.rowidConstraint(p, OE.Abort, t);
        } else {
            _ = aux.goto_(v, addr_recheck);
        }
    }
    if (reg_trig_cnt != 0) aux.resolveLabel(v, lbl_recheck_ok);

    // The table record.
    if (t.hasRowid()) {
        const reg_rec = reg_idx[ix];
        _ = aux.addOp3(v, OP.MakeRecord, reg_new_data + 1, t.n_nv_col, reg_rec);
        if (!b_affinity_done) tableAffinity(p, t, 0);
    }
    may_replace.* = seen_replace;
}

/// Port of sqlite3CompleteInsertion(): write the index entries and the
/// record made by generateConstraintChecks(). `update_flags` is 0 for an
/// INSERT, else OPFLAG_ISUPDATE (and OPFLAG_SAVEPOSITION).
pub fn completeInsertion(p: *Parse, t: *Table, i_data_cur: i32, i_idx_cur: i32, reg_new_data: i32, reg_idx: []const i32, update_flags: u16, append_bias: bool, use_seek_result: bool) void {
    const v = p.vdbe.?;
    var i: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        i += 1;
    }) {
        if (reg_idx[i] == 0) continue;
        // A NULL record: no entry (partial indexes, and UPDATE of an index
        // on expressions).
        if (idx.part_idx_where != null or (update_flags != 0 and idx.has_expr)) {
            _ = aux.addOp2(v, OP.IsNull, reg_idx[i], aux.currentAddr(v) + 2);
        }
        var pik_flags: u16 = if (use_seek_result) OPFLAG.USESEEKRESULT else 0;
        if (idx.isPrimaryKey() and !t.hasRowid()) {
            pik_flags |= OPFLAG.NCHANGE;
            pik_flags |= update_flags & OPFLAG.SAVEPOSITION;
        }
        const ii: i32 = @intCast(i);
        _ = aux.addOp4Int(v, OP.IdxInsert, i_idx_cur + ii, reg_idx[i], reg_idx[i] + 1, if (idx.uniq_not_null) idx.n_key_col else idx.n_column);
        aux.changeP5(v, pik_flags);
    }
    if (!t.hasRowid()) return;
    var pik_flags: u16 = 0;
    if (p.nested == 0) {
        pik_flags = OPFLAG.NCHANGE;
        pik_flags |= if (update_flags != 0) update_flags else OPFLAG.LASTROWID;
    }
    if (append_bias) pik_flags |= OPFLAG.APPEND;
    if (use_seek_result) pik_flags |= OPFLAG.USESEEKRESULT;
    _ = aux.addOp3(v, OP.Insert, i_data_cur, reg_idx[i], reg_new_data);
    if (p.nested == 0) aux.appendP4(v, .{ .table = t });
    aux.changeP5(v, pik_flags);
}

/// Port of sqlite3OpenTableAndIndices(): open cursors on `t` and its
/// indexes from `i_base` (or the next free cursor if negative), those
/// with `to_open` set if given. Returns the number of indexes; the cursor
/// of the table (the PRIMARY KEY of a WITHOUT ROWID table) goes to
/// `data_cur` and that of the first index to `idx_cur`.
pub fn openTableAndIndices(p: *Parse, t: *Table, op: u8, p5_arg: u8, i_base_arg: i32, to_open: ?[]const bool, data_cur: *i32, idx_cur: *i32) usize {
    var p5 = p5_arg;
    if (t.e_tab_type == .vtab) {
        data_cur.* = -999;
        idx_cur.* = -999;
        return 0;
    }
    const i_db: usize = @intCast(prepare.schemaToIndex(p.db, t.schema));
    const v = p.vdbe.?;
    var i_base = if (i_base_arg < 0) p.n_tab else i_base_arg;
    const i_data_cur = i_base;
    i_base += 1;
    data_cur.* = i_data_cur;
    if (t.hasRowid() and (to_open == null or to_open.?[0])) openTable(p, i_data_cur, i_db, t, op);
    idx_cur.* = i_base;
    var i: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        i += 1;
    }) {
        const i_idx_cur = i_base;
        i_base += 1;
        if (idx.isPrimaryKey() and !t.hasRowid()) {
            data_cur.* = i_idx_cur;
            p5 = 0;
        }
        if (to_open == null or to_open.?[i + 1]) {
            _ = aux.addOp3(v, op, i_idx_cur, @intCast(idx.tnum), @intCast(i_db));
            aux.setP4KeyInfo(p, idx);
            aux.changeP5(v, p5);
        }
    }
    if (i_base > p.n_tab) p.n_tab = i_base;
    return i;
}
