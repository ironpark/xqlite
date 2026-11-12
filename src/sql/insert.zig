//! INSERT statements (port of insert.c): the INSERT driver, AUTOINCREMENT,
//! the transfer optimization, and the constraint checks and record writes
//! UPDATE shares.

const std = @import("std");
const int = @import("sqlite_int.zig");
const select_mod = @import("select.zig");
const vtab = @import("vtab.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const build = @import("build.zig");
const expr_mod = @import("expr.zig");
const ec = @import("expr_code.zig");
const resolve = @import("resolve.zig");
const walker = @import("walker.zig");
const WRC = walker.WRC;
const util = @import("util.zig");
const prepare = @import("prepare.zig");
const delete_mod = @import("delete.zig");
const trigger = @import("trigger.zig");
const fkey = @import("fkey.zig");
const main_mod = @import("main.zig");
const where_mod = @import("where/where.zig");
const ctype = @import("xqlite_base").ctype;
const coll_mod = @import("coll.zig");
const auth = @import("auth.zig");
const typing = @import("typing.zig");

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
const upsert_mod = @import("upsert.zig");
const dconstraint = @import("../dialect/constraint.zig");
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
const Reg = aux.operand.Reg;
const Cursor = aux.operand.Cursor;
const Label = aux.operand.Label;
const Addr = aux.operand.Addr;
const Jump = aux.operand.Jump;

/// The operands of OP_OpenRead and OP_OpenWrite.
const open_shape: [3]aux.operand.Kind = .{ .cursor, .int, .int };

/// Port of sqlite3OpenTable(): open cursor `i_cur` on table `t` with
/// OP_OpenRead or OP_OpenWrite (on the PRIMARY KEY of a WITHOUT ROWID
/// table).
pub fn openTable(p: *Parse, i_cur: i32, i_db: usize, t: *Table, opcode: OP) void {
    const v = p.vdbe.?;
    const cur: Cursor = .from(i_cur);
    build.tableLock(p, i_db, t.tnum, opcode == OP.OpenWrite, t.name);
    if (t.hasRowid()) {
        _ = aux.emitAnyInt(v, opcode, open_shape, .{ cur, t.tnum, i_db }, t.n_nv_col);
    } else {
        const pk = build.primaryKeyIndex(t).?;
        _ = aux.emitAny(v, opcode, open_shape, .{ cur, pk.tnum, i_db });
        aux.setP4KeyInfo(p, pk);
    }
}

/// Port of sqlite3IndexAffinityStr(): the affinities of the columns of
/// `idx` ('A' to 'C'), cached in the index.
pub fn indexAffinityStr(p: *Parse, idx: *Index) ?[:0]const u8 {
    if (idx.col_aff) |s| return s;
    const t = idx.table;
    // Schema memory (C: sqlite3DbMallocRaw(0, ...)).
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
        if (!c.col_flags.VIRTUAL) {
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
    const first: Reg = .from(reg);
    if (t.tab_flags.Strict) {
        if (first.isNone()) {
            // Turn the OP_MakeRecord into OP_TypeCheck and code it again.
            aux.appendP4(v, .{ .table = t });
            const prev = aux.getLastOp(v);
            prev.opcode = OP.TypeCheck;
            const p3 = prev.p3;
            prev.p3 = 0;
            const p1 = prev.p1;
            const p2 = prev.p2;
            _ = aux.emit(v, .MakeRecord, .{ Reg.from(p1), p2, Reg.from(p3) });
        } else {
            _ = aux.emit(v, .TypeCheck, .{ first, t.n_nv_col });
            aux.appendP4(v, .{ .table = t });
        }
        return;
    }
    const aff = t.col_aff orelse blk: {
        // Schema memory (C: sqlite3DbMallocRaw(0, ...)).
        const s = tableAffinityStr(build.tableAlloc(p, t), t) catch return build.oomFault(p);
        t.col_aff = s;
        break :blk s;
    };
    if (aff.len == 0) return;
    if (!first.isNone()) {
        _ = aux.emitStr(v, .Affinity, .{ first, aff.len }, aff);
    } else {
        aux.changeP4Str(v, -1, aff);
    }
}

/// Port of readsTable(): the program already opens `t` (or one of its
/// indexes) of database `i_db` for reading.
fn readsTable(p: *Parse, i_db: usize, t: *Table) bool {
    const v = p.vdbe.?;
    const end = aux.currentAddr(v);
    const vt: ?*int.VTable = if (t.isVirtual()) vtab.getVTable(p.db, t) else null;
    var i: i32 = 1;
    while (i < end) : (i += 1) {
        const op = aux.getOp(v, i);
        if (op.opcode == OP.VOpen and op.p4.vtab == vt) return true;
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

fn exprColumnFlagUnion(w: *walker.Walker, e: *Expr) WRC {
    if (e.op == TK.COLUMN and e.i_column >= 0) {
        w.e_code |= w.u.tab.?.cols[@intCast(e.i_column)].col_flags.int();
    }
    return WRC.Continue;
}

/// Port of sqlite3ComputeGeneratedColumns(): with the ordinary columns of
/// `t` in the registers from `reg_store`, compute its generated columns.
pub fn computeGeneratedColumns(p: *Parse, reg_store: i32, t: *Table) void {
    const v = p.vdbe.?;
    // Affinity for the ordinary columns first; '@' (none) for the stored
    // generated columns, not computed yet.
    tableAffinity(p, t, reg_store);
    if (t.tab_flags.HasStored) {
        const op = aux.getLastOp(v);
        if (op.opcode == OP.Affinity) {
            const z: []u8 = @constCast(std.mem.span(op.p4.z));
            var jj: usize = 0;
            for (t.cols) |c| {
                if (jj >= z.len) break;
                if (c.col_flags.VIRTUAL) continue;
                if (c.col_flags.STORED) z[jj] = Aff.none;
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
        if (c.col_flags.intersects(COLFLAG.GENERATED)) c.col_flags.NOTAVAIL = true;
    }
    var w: walker.Walker = .{ .expr_callback = exprColumnFlagUnion, .u = .{ .tab = t } };
    p.i_self_tab = -reg_store;
    var redo: ?*Column = null;
    while (true) {
        var progress = false;
        redo = null;
        for (t.cols, 0..) |*c, i| {
            if (!c.col_flags.NOTAVAIL) continue;
            c.col_flags.BUSY = true;
            w.e_code = 0;
            _ = walker.walkExpr(&w, build.columnExpr(t, c));
            c.col_flags.BUSY = false;
            if (COLFLAG.fromInt(w.e_code).NOTAVAIL) {
                redo = c;
                continue;
            }
            progress = true;
            const x = build.tableColumnToStorage(t, @intCast(i)) + reg_store;
            ec.codeGeneratedColumn(p, t, c, x);
            c.col_flags.NOTAVAIL = false;
        }
        if (redo == null or !progress) break;
    }
    if (redo) |c| util.errorMsg(p, "generated column loop on \"{s}\"", .{c.name()});
    p.i_self_tab = 0;
}

/// Port of autoIncBegin(): the register holding the largest rowid of the
/// AUTOINCREMENT table `t`, or none if `t` has no AUTOINCREMENT.
fn autoIncBegin(p: *Parse, i_db: usize, t: *Table) Reg {
    const db = p.db;
    if (!t.tab_flags.Autoincrement or db.m_db_flags.Vacuum) return .none;
    const top = build.toplevel(p);
    const seq = db.dbs.items[i_db].schema.seq_tab;
    // sqlite_sequence must be an ordinary rowid table of two columns.
    if (seq == null or !seq.?.hasRowid() or seq.?.e_tab_type == .vtab or seq.?.cols.len != 2) {
        p.n_err += 1;
        p.rc = RC.CORRUPT_SEQUENCE;
        return .none;
    }
    if (!top.uses_ainc) top.ainc = null;
    var info = top.ainc;
    while (info) |a| : (info = a.next) {
        if (a.tab == t) return .from(a.reg_ctr);
    }
    const a = top.arena.create(int.AutoincInfo) catch {
        build.oomFault(p);
        return .none;
    };
    // Registers: the table name, the largest rowid, its rowid in
    // sqlite_sequence, and the original largest rowid.
    top.n_mem += 1;
    a.* = .{ .next = top.ainc, .tab = t, .i_db = i_db, .reg_ctr = top.n_mem + 1 };
    top.n_mem += 3;
    top.ainc = a;
    top.uses_ainc = true;
    return .from(a.reg_ctr);
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
fn autoIncStep(p: *Parse, mem_id: Reg, rowid: Reg) void {
    if (!mem_id.isNone()) _ = aux.emit(p.vdbe.?, .MemMax, .{ mem_id, rowid });
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
        _ = aux.emit(v, .Le, .{ Reg.from(mem_id + 2), aux.here(v).plus(7), Reg.from(mem_id) });
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

/// xqlite: the parameters among the values `list` of an INSERT into `t`
/// (`column` its column list) are of the type of their column
/// (typing.assign()).
fn typeParams(p: *Parse, t: *Table, column: ?*IdList, list: *ExprList) Oom!void {
    for (list.slice(), 0..) |item, i| {
        // The column the value is for.
        const j: usize = if (column) |cl| blk: {
            if (i >= cl.names.items.len) return;
            const k = build.columnIndex(t, cl.names.items[i]);
            if (k < 0) continue;
            break :blk @intCast(k);
        } else blk: {
            var n: usize = 0;
            for (t.cols, 0..) |*c, k| {
                if (c.col_flags.intersects(COLFLAG.NOINSERT)) continue;
                if (n == i) break :blk k;
                n += 1;
            }
            return;
        };
        typing.assign(p, item.expr.?, try resolve.tableColumnType(p, t, j));
    }
}

/// xqlite: the value in register `reg`, stored into a column, through
/// `st` (typing.Store.pick()).
pub fn codeStore(p: *Parse, st: typing.Conv, reg: i32) void {
    const val: Reg = .from(reg);
    const tmp: Reg = .from(expr_mod.getTempReg(p));
    if (st.n_consts == 0) {
        _ = aux.addFunctionCall(p, 0, reg, tmp.int(), 1, st.def, 0);
    } else {
        // The value and the constants after it.
        const n: i32 = 1 + @as(i32, st.n_consts);
        const base: Reg = .from(expr_mod.getTempRange(p, n));
        _ = aux.emit(p.vdbe.?, .Copy, .{ val, base });
        for (st.consts[0..st.n_consts], 0..) |c, i| _ = aux.emit(p.vdbe.?, .Integer, .{ c, base.at(1 + i) });
        _ = aux.addFunctionCall(p, 0, base.int(), tmp.int(), n, st.def, 0);
        expr_mod.releaseTempRange(p, base.int(), n);
    }
    _ = aux.emit(p.vdbe.?, .Move, .{ tmp, val, 1 });
    expr_mod.releaseTempReg(p, tmp.int());
}

/// Port of sqlite3MultiValuesEnd(): if `val` is a VALUES clause coded
/// as a co-routine by multiValues(), finish the co-routine.
pub fn multiValuesEnd(p: *Parse, val: ?*Select) void {
    const s = val orelse return;
    if (s.src.?.len() == 0) return;
    const item = s.src.?.at(0);
    if (item.fg.is_subquery) {
        const subq = item.u4.subq.?;
        aux.endCoroutine(p.vdbe.?, subq.reg_return);
        aux.jumpHere(p.vdbe.?, subq.addr_fill_sub - 1);
    }
}

/// Port of exprListIsNoAffinity(): every expression of `row` is constant
/// and has no affinity.
fn exprListIsNoAffinity(p: *Parse, row: *ExprList) bool {
    if (!expr_mod.listIsConstant(p, row, false)) return false;
    for (row.slice()) |item| if (expr_mod.affinity(item.expr.?) != 0) return false;
    return true;
}

/// Port of sqlite3MultiValues(): add a row to a multi-row VALUES clause.
/// Each row is coded at once into a co-routine, and the result reads
/// it: `SELECT * FROM (co-routine)`. The "UNION ALL" method (`left
/// UNION ALL SELECT row`) is used instead under a WITH clause, while
/// the schema is parsed, for a row that is not constant, for a first
/// row with an affinity and in a special parse. xqlite: also when only
/// checking the syntax (no code), and in a dialect with types, whose
/// INSERT types each row for its column (typeParams()).
pub fn multiValues(p: *Parse, left_arg: *Select, row_arg: ?*ExprList) Oom!*Select {
    var left = left_arg;
    const row = row_arg.?;
    // The flags first: a dialect with types never walks the rows.
    if (typing.active(p.db) or p.syntax_only or p.has_with or p.db.init.busy or p.inSpecialParse() or
        !expr_mod.listIsConstant(p, row, true) or
        (left.src.?.len() == 0 and !exprListIsNoAffinity(p, left.e_list.?)))
    {
        var f: SF = .{ .Values = true, .MultiValue = true };
        if (left.src.?.len() != 0) {
            multiValuesEnd(p, left);
            f = .{ .Values = true };
        } else if (left.prior != null) {
            f = f.only(left.sel_flags);
        }
        const s = try select_mod.selectNew(p, row, null, null, null, null, null, f, null);
        left.sel_flags.MultiValue = false;
        s.op = TK.ALL;
        s.prior = left;
        return s;
    }

    var item: *int.SrcItem = undefined;
    if (left.src.?.len() == 0) {
        // Start the co-routine and the Select that reads it.
        const v = build.getVdbe(p) orelse return left;
        const ret = try select_mod.selectNew(p, null, null, null, null, null, null, .{}, null);
        // The schema gives the text encoding.
        if (!p.db.m_db_flags.SchemaKnownOk) prepare.readSchema(p) catch {};
        try ret.src.?.items.append(p.arena, .{});
        ret.prior = left.prior;
        ret.op = left.op;
        if (ret.prior != null) ret.sel_flags.Values = true;
        left.prior = null;
        left.op = TK.SELECT;
        item = ret.src.?.at(0);
        item.fg.via_coroutine = true;
        item.i_cursor = -1;
        item.u1 = .{ .n_row = 2 };
        try build.srcItemAttachSubquery(p, item, left);
        const subq = item.u4.subq.?;
        subq.addr_fill_sub = aux.currentAddr(v) + 1;
        p.n_mem += 1;
        subq.reg_return = p.n_mem;
        _ = aux.emit(v, .InitCoroutine, .{ Reg.from(subq.reg_return), 0, Addr.from(subq.addr_fill_sub) });
        var dest = select_mod.selectDestInit(SRT.Coroutine, subq.reg_return);
        // Two unused registers before the output, so that insert() can
        // use them as they are (rowid and the row of a virtual table).
        dest.i_sdst = p.n_mem + 3;
        dest.n_sdst = @intCast(left.e_list.?.len());
        p.n_mem += 2 + dest.n_sdst;
        left.sel_flags.MultiValue = true;
        p.xq_values_coroutine = true;
        select_mod.select(p, left, &dest) catch {};
        subq.reg_result = dest.i_sdst;
        left = ret;
    } else {
        item = left.src.?.at(0);
        item.u1.n_row += 1;
    }

    if (p.n_err == 0) {
        const subq = item.u4.subq.?;
        if (subq.select.e_list.?.len() != row.len()) {
            select_mod.selectWrongNumTermsError(p, subq.select);
        } else {
            _ = ec.codeExprList(p, row, subq.reg_result, 0, 0);
            _ = aux.emit(p.vdbe.?, .Yield, .{Reg.from(subq.reg_return)});
        }
    }
    return left;
}

/// Port of sqlite3Insert(): INSERT INTO `tab_list` [(column)] with the
/// rows of `sel` (VALUES or a SELECT), or DEFAULT VALUES if null.
pub fn insert(p: *Parse, tab_list: ?*SrcList, sel: ?*Select, column: ?*IdList, on_error: OE, upsert: ?*Upsert) void {
    if (p.syntax_only) return;
    insertImpl(p, tab_list.?, sel, column, on_error, upsert) catch build.oomFault(p);
}

fn insertImpl(p: *Parse, tab_list: *SrcList, sel_arg: ?*Select, column: ?*IdList, on_error: OE, upsert: ?*Upsert) Oom!void {
    const db = p.db;
    if (p.n_err != 0) return;
    var sel = sel_arg;
    var list: ?*ExprList = null;

    // A single-row VALUES clause is just its expressions.
    if (sel) |s| if (s.sel_flags.Values and s.prior == null) {
        list = s.e_list;
        sel = null;
    };

    const t = build.srcListLookup(p, tab_list) orelse return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    if (auth.check(p, auth.Code.INSERT, t.name, null, db.dbs.items[i_db].name) != auth.OK) return;
    const without_rowid = !t.hasRowid();

    var tmask: u8 = 0;
    const trig = trigger.triggersExist(p, t, TK.INSERT, null, &tmask);
    const is_view = t.isView();
    build.viewGetColumnNames(p, t) catch return;
    if (delete_mod.isReadOnly(p, t, trig)) return;

    const v = build.getVdbe(p) orelse return;
    if (p.nested == 0) aux.countChanges(v);
    build.beginWriteOperation(p, sel != null or trig != null, i_db);

    // INSERT INTO table1 SELECT * FROM table2 may copy the records as
    // they are (the 2nd template).
    if (column == null and sel != null and trig == null and xferOptimization(p, t, sel.?, on_error, i_db)) {
        if (p.nested == 0 and p.trigger_tab == null) autoincrementEnd(p);
        return;
    }

    const autoinc = autoIncBegin(p, i_db, t);

    // The rowid and the columns of the new row.
    var rowid: Reg = .from(p.n_mem + 1);
    var ins_reg = rowid;
    p.n_mem += @as(i32, @intCast(t.cols.len)) + 1;
    if (t.isVirtual()) {
        // xUpdate takes the rowid to delete first.
        rowid = rowid.at(1);
        p.n_mem += 1;
    }
    var data_reg = rowid.at(1);

    // Map the IDLIST to the columns. b_id_list_in_order: the IDLIST
    // names the columns in storage order (a false negative is harmless,
    // a false positive corrupts the database).
    var ipk_column: i32 = -1;
    var b_id_list_in_order = !t.tab_flags.intersects(.{ .OOOHidden = true, .HasStored = true });
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
                if (t.cols[ju].col_flags.intersects(.{ .STORED = true, .VIRTUAL = true })) {
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
    var src_tab: ?Cursor = null;
    var select_reg: Reg = .none;
    var use_temp_table = false;
    var dest: select_mod.SelectDest = undefined;
    if (sel) |s| {
        if (s.src.?.len() == 1 and s.src.?.at(0).fg.via_coroutine and s.prior == null) {
            // A multi-row VALUES clause already coded as a co-routine
            // (multiValues()).
            const item = s.src.?.at(0);
            const subq = item.u4.subq.?;
            dest = select_mod.selectDestInit(SRT.Coroutine, subq.reg_return);
            select_reg = .from(subq.reg_result);
            n_column = @intCast(subq.select.e_list.?.len());
            _ = aux.explain(p, false, "SCAN {f}", .{util.srcItemName(item)});
            if (b_id_list_in_order and n_column == t.cols.len) {
                data_reg = select_reg;
                rowid = data_reg.at(-1);
                ins_reg = rowid.at(-@as(i32, @intFromBool(t.isVirtual())));
            }
        } else {
            p.n_mem += 1;
            const yield_reg: Reg = .from(p.n_mem);
            const addr_top = aux.here(v).plus(1);
            _ = aux.emit(v, .InitCoroutine, .{ yield_reg, 0, addr_top });
            dest = select_mod.selectDestInit(SRT.Coroutine, yield_reg.int());
            dest.i_sdst = if (b_id_list_in_order) data_reg.int() else 0;
            dest.n_sdst = @intCast(t.cols.len);
            const saved_values = p.xq_insert_values;
            if (s.sel_flags.Values) p.xq_insert_values = s;
            const rc = select_mod.select(p, s, &dest);
            p.xq_insert_values = saved_values;
            select_reg = .from(dest.i_sdst);
            rc catch return;
            if (p.n_err != 0) return;
            if (typing.active(db)) {
                var it: ?*Select = s;
                while (it) |term| : (it = term.prior) typeParams(p, t, column, term.e_list.?) catch return build.oomFault(p);
            }
            aux.endCoroutine(v, yield_reg.int());
            aux.landHere(v, addr_top.plus(-1));
            n_column = @intCast(s.e_list.?.len());
        }

        // Rows go through a temporary table if the SELECT reads the
        // table written (or triggers run).
        if (trig != null or readsTable(p, i_db, t)) use_temp_table = true;
        if (use_temp_table) {
            src_tab = .from(p.n_tab);
            p.n_tab += 1;
            const rec: Reg = .from(expr_mod.getTempReg(p));
            const temp_rowid: Reg = .from(expr_mod.getTempReg(p));
            _ = aux.emit(v, .OpenEphemeral, .{ src_tab.?, n_column });
            const addr_l = aux.emit(v, .Yield, .{Reg.from(dest.i_sd_parm)});
            _ = aux.emit(v, .MakeRecord, .{ select_reg, n_column, rec });
            _ = aux.emit(v, .NewRowid, .{ src_tab.?, temp_rowid });
            _ = aux.emit(v, .Insert, .{ src_tab.?, rec, temp_rowid });
            _ = aux.emit(v, .Goto, .{ 0, addr_l });
            aux.landHere(v, addr_l);
            expr_mod.releaseTempReg(p, rec.int());
            expr_mod.releaseTempReg(p, temp_rowid.int());
        }
    } else {
        var nc: NameContext = .{ .parse = p };
        if (list) |l| {
            n_column = @intCast(l.len());
            resolve.resolveExprListNames(&nc, l) catch return;
            if (typing.active(db)) typeParams(p, t, column, l) catch return build.oomFault(p);
        }
    }

    // Without an IDLIST the values go to the columns in order, the
    // INTEGER PRIMARY KEY included.
    if (column == null and n_column > 0) {
        ipk_column = t.i_pkey;
        if (ipk_column >= 0 and t.tab_flags.intersects(TF.HasGenerated)) {
            var i = ipk_column - 1;
            while (i >= 0) : (i -= 1) {
                if (t.cols[@intCast(i)].col_flags.intersects(COLFLAG.GENERATED)) ipk_column -= 1;
            }
        }
        var n_hidden: i32 = 0;
        if (t.tab_flags.intersects(TF.HasGenerated.with(.{ .HasHidden = true }))) {
            for (t.cols) |c| {
                if (c.col_flags.intersects(COLFLAG.NOINSERT)) n_hidden += 1;
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

    var row_count: Reg = .none;
    if (db.flags.CountRows and p.nested == 0 and p.trigger_tab == null and !p.returning) {
        p.n_mem += 1;
        row_count = .from(p.n_mem);
        _ = aux.emit(v, .Integer, .{ 0, row_count });
    }

    // Open the table and its indexes; a register range for each index
    // entry, and one for the table record.
    var i_data_cur: i32 = 0;
    var i_idx_cur: i32 = 0;
    var reg_idx: []i32 = &.{};
    if (!is_view) {
        const n_idx = openTableAndIndices(p, t, OP.OpenWrite, 0, -1, null, &i_data_cur, &i_idx_cur);
        reg_idx = try p.arena.alloc(i32, n_idx + 1);
        // n_idx, not the index list: a virtual table may have indexes
        // (made by the module's declaration) but opens none.
        var idx = t.index;
        for (reg_idx[0..n_idx]) |*r| {
            const ix = idx.?;
            idx = ix.next;
            p.n_mem += 1;
            r.* = p.n_mem;
            p.n_mem += ix.n_column;
        }
        p.n_mem += 1;
        reg_idx[n_idx] = p.n_mem;
    }
    const data_cur: Cursor = .from(i_data_cur);
    if (upsert) |up| {
        if (t.e_tab_type == .vtab) {
            util.errorMsg(p, "UPSERT not implemented for virtual table \"{s}\"", .{t.name});
            return;
        }
        if (is_view) {
            util.errorMsg(p, "cannot UPSERT a view", .{});
            return;
        }
        if (build.hasExplicitNulls(p, up.target)) return;
        tab_list.at(0).i_cursor = i_data_cur;
        var nx: ?*Upsert = up;
        while (nx) |n| : (nx = n.next) {
            n.src = tab_list;
            n.reg_data = data_reg.int();
            n.i_data_cur = i_data_cur;
            n.i_idx_cur = i_idx_cur;
            if (n.target != null) upsert_mod.analyzeTarget(p, tab_list, n, up) catch |err| switch (err) {
                error.ParseFailed => return,
                error.OutOfMemory => |e| return e,
            };
        }
    }

    // The top of the loop over the rows.
    var addr_ins_top: Addr = undefined;
    var addr_cont: Addr = undefined;
    if (use_temp_table) {
        addr_ins_top = aux.emit(v, .Rewind, .{src_tab.?});
        addr_cont = aux.here(v);
    } else if (sel != null) {
        addr_cont = aux.emit(v, .Yield, .{Reg.from(dest.i_sd_parm)});
        addr_ins_top = addr_cont;
        // An INTEGER PRIMARY KEY from the SELECT goes to the rowid slot
        // now, before its column slot is set to NULL.
        if (ipk_column >= 0) _ = aux.emit(v, .Copy, .{ select_reg.at(ipk_column), rowid });
    }

    // The ordinary columns, in storage order from data_reg. The rowid and
    // the generated columns come after.
    {
        // xqlite: the functions the values of the dialect's types go
        // through (none in SQLite's dialect).
        const stores = if (is_view) null else typing.storeFunctions(p, t) catch return build.oomFault(p);
        var n_hidden: i32 = 0;
        var store_reg = data_reg;
        for (t.cols, 0..) |*c, ii| {
            defer store_reg = store_reg.at(1);
            const i: i32 = @intCast(ii);
            if (i == t.i_pkey) {
                // The INTEGER PRIMARY KEY is stored as NULL (it is the
                // rowid).
                _ = aux.emit(v, .SoftNull, .{store_reg});
                continue;
            }
            var k: i32 = undefined;
            const col_flags = c.col_flags;
            if (col_flags.intersects(COLFLAG.NOINSERT)) {
                n_hidden += 1;
                if (col_flags.VIRTUAL) {
                    // Not part of the record.
                    store_reg = store_reg.at(-1);
                    continue;
                } else if (col_flags.STORED) {
                    if (tmask & int.TRIGGER_BEFORE != 0) _ = aux.emit(v, .SoftNull, .{store_reg});
                    continue;
                } else if (column == null) {
                    ec.codeFactorable(p, build.columnExprAuth(t, c, p), store_reg.int());
                    continue;
                }
            }
            if (column != null) {
                const j = tab_col_map[ii];
                if (j == 0) {
                    // Not in the IDLIST: the DEFAULT.
                    ec.codeFactorable(p, build.columnExprAuth(t, c, p), store_reg.int());
                    continue;
                }
                k = j - 1;
            } else if (n_column == 0) {
                // DEFAULT VALUES.
                ec.codeFactorable(p, build.columnExprAuth(t, c, p), store_reg.int());
                continue;
            } else {
                k = i - n_hidden;
            }

            if (use_temp_table) {
                _ = aux.emit(v, .Column, .{ src_tab.?, k, store_reg });
            } else if (sel != null) {
                if (select_reg != data_reg) _ = aux.emit(v, .SCopy, .{ select_reg.at(k), store_reg });
            } else {
                const x = list.?.at(@intCast(k)).expr.?;
                const y: Reg = .from(ec.codeTarget(p, x, store_reg.int()));
                if (y != store_reg) _ = aux.emitAny(v, if (x.flags.Subquery) .Copy else .SCopy, .{ .reg, .reg, .int }, .{ y, store_reg });
                if (stores) |f| if (f[ii]) |st| if (st.pick(db, x)) |s| {
                    if (typing.readStoredLiteral(p, s, x) catch return build.oomFault(p)) return;
                    codeStore(p, s, store_reg.int());
                };
                continue;
            }
            // A row of the SELECT (here only from one: a VALUES of one row
            // took the branch above).
            if (stores) |f| if (f[ii]) |st| if (try st.pickColumn(p, sel.?, @intCast(k))) |s| codeStore(p, s, store_reg.int());
        }
    }

    const end_of_loop = aux.newLabel(p);

    // BEFORE (and INSTEAD OF) triggers, given the NEW.* row.
    if (tmask & int.TRIGGER_BEFORE != 0) {
        const n_col: i32 = @intCast(t.cols.len);
        const cols_reg: Reg = .from(expr_mod.getTempRange(p, n_col + 1));
        // The rowid of a NULL INTEGER PRIMARY KEY is not known before the
        // insert: it is -1 here.
        if (ipk_column < 0) {
            _ = aux.emit(v, .Integer, .{ -1, cols_reg });
        } else {
            std.debug.assert(!without_rowid);
            if (use_temp_table) {
                _ = aux.emit(v, .Column, .{ src_tab.?, ipk_column, cols_reg });
            } else {
                std.debug.assert(sel == null);
                ec.exprCode(p, list.?.at(@intCast(ipk_column)).expr, cols_reg.int());
            }
            const addr1 = aux.emit(v, .NotNull, .{cols_reg});
            _ = aux.emit(v, .Integer, .{ -1, cols_reg });
            aux.landHere(v, addr1);
            _ = aux.emit(v, .MustBeInt, .{cols_reg});
            main_mod.mayAbort(p);
        }
        _ = aux.emit(v, .Copy, .{ rowid.at(1), cols_reg.at(1), t.n_nv_col - 1 });
        // Generated columns may use the rowid, so they come last.
        if (t.tab_flags.intersects(TF.HasGenerated)) computeGeneratedColumns(p, cols_reg.at(1).int(), t);
        // A view takes the values as they are.
        if (!is_view) tableAffinity(p, t, cols_reg.at(1).int());
        trigger.codeRowTrigger(p, trig, TK.INSERT, null, int.TRIGGER_BEFORE, t, cols_reg.int() - n_col - 1, on_error, end_of_loop.int());
        expr_mod.releaseTempRange(p, cols_reg.int(), n_col + 1);
    }

    var append_flag = false;
    // xqlite: the rowid is the INTEGER PRIMARY KEY's DEFAULT (ipkDefault()),
    // checked as a given one.
    var ipk_default = false;
    if (!is_view) {
        // The row xUpdate deletes: none.
        if (t.isVirtual()) _ = aux.emit(v, .Null, .{ 0, ins_reg });
        if (ipk_column >= 0) {
            // The rowid given by the row.
            if (use_temp_table) {
                _ = aux.emit(v, .Column, .{ src_tab.?, ipk_column, rowid });
            } else if (sel != null) {
                // Already copied above.
            } else {
                const ipk = list.?.at(@intCast(ipk_column)).expr.?;
                if (ipk.op == TK.NULL and !t.isVirtual()) {
                    _ = aux.emit(v, .NewRowid, .{ data_cur, rowid, autoinc });
                    append_flag = true;
                } else {
                    ec.exprCode(p, ipk, rowid.int());
                }
            }
            // A NULL rowid gets a new one.
            if (!append_flag) {
                if (!t.isVirtual()) {
                    const addr1 = aux.emit(v, .NotNull, .{rowid});
                    _ = aux.emit(v, .NewRowid, .{ data_cur, rowid, autoinc });
                    aux.landHere(v, addr1);
                } else {
                    const addr1 = aux.here(v);
                    _ = aux.emit(v, .IsNull, .{ rowid, addr1.plus(2) });
                }
                _ = aux.emit(v, .MustBeInt, .{rowid});
                main_mod.mayAbort(p);
            }
        } else if (t.isVirtual() or without_rowid) {
            _ = aux.emit(v, .Null, .{ 0, rowid });
        } else if (ipkDefault(p, t)) |dflt| {
            ipk_default = true;
            // xqlite: a typed dialect's INTEGER PRIMARY KEY left out takes
            // its DEFAULT (PostgreSQL's `id int PRIMARY KEY DEFAULT 99`;
            // SQLite gives a new rowid), a new rowid where it is NULL.
            ec.exprCode(p, dflt, rowid.int());
            const addr1 = aux.emit(v, .NotNull, .{rowid});
            _ = aux.emit(v, .NewRowid, .{ data_cur, rowid, autoinc });
            aux.landHere(v, addr1);
            _ = aux.emit(v, .MustBeInt, .{rowid});
            main_mod.mayAbort(p);
        } else {
            _ = aux.emit(v, .NewRowid, .{ data_cur, rowid, autoinc });
            append_flag = true;
        }
        autoIncStep(p, autoinc, rowid);

        // Generated columns may use the rowid, so they come last.
        if (t.tab_flags.intersects(TF.HasGenerated)) computeGeneratedColumns(p, rowid.at(1).int(), t);

        if (t.isVirtual()) {
            vtab.makeWritable(p, t);
            _ = aux.emit4(v, .VUpdate, .{ 1, t.cols.len + 2, ins_reg }, build.vtabP4(db, t));
            aux.changeP5(v, (if (on_error == OE.Default) OE.Abort else on_error).int());
            main_mod.mayAbort(p);
        } else {
            var is_replace = false;
            generateConstraintChecks(p, t, reg_idx, i_data_cur, i_idx_cur, ins_reg.int(), 0, ipk_column >= 0 or ipk_default, on_error, end_of_loop.int(), &is_replace, null, upsert);
            if (db.flags.ForeignKeys) fkey.fkCheck(p, t, 0, ins_reg.int(), null, false);
            // OPFLAG_USESEEKRESULT is safe without REPLACE, or without
            // trigger programs (a REPLACE delete then resets the seek
            // result).
            const use_seek = !is_replace or !aux.hasSubProgram(v);
            completeInsertion(p, t, i_data_cur, i_idx_cur, ins_reg.int(), reg_idx, 0, append_flag, use_seek);
        }
    }

    if (!row_count.isNone()) _ = aux.emit(v, .AddImm, .{ row_count, 1 });

    if (trig != null) {
        trigger.codeRowTrigger(p, trig, TK.INSERT, null, int.TRIGGER_AFTER, t, data_reg.int() - 2 - @as(i32, @intCast(t.cols.len)), on_error, end_of_loop.int());
    }

    // The bottom of the loop.
    aux.place(v, end_of_loop);
    if (use_temp_table) {
        _ = aux.emit(v, .Next, .{ src_tab.?, addr_cont });
        aux.landHere(v, addr_ins_top);
        _ = aux.emit(v, .Close, .{src_tab.?});
    } else if (sel != null) {
        _ = aux.emit(v, .Goto, .{ 0, addr_cont });
        aux.landHere(v, addr_ins_top);
    }

    if (p.nested == 0 and p.trigger_tab == null) autoincrementEnd(p);
    if (!row_count.isNone()) delete_mod.codeChangeCount(v, row_count.int(), "rows inserted");
    _ = &ins_reg;
    _ = &data_reg;
    _ = &rowid;
}

/// sqlite3_stricmp(), where a null string sorts first.
fn stricmpNull(a: ?[]const u8, b: ?[]const u8) i32 {
    const x = a orelse return if (b != null) -1 else 0;
    const y = b orelse return 1;
    return ctype.strICmp(x, y);
}

/// Port of xferCompatibleIndex(): index `src` can feed index `dest` in
/// the transfer optimization: same columns, sort orders, conflict
/// resolution, collations and WHERE clause.
fn xferCompatibleIndex(dest: *Index, src: *Index) bool {
    std.debug.assert(dest.table != src.table);
    if (dest.n_key_col != src.n_key_col or dest.n_column != src.n_column) return false;
    if (dest.on_error != src.on_error) return false;
    for (0..src.n_key_col) |i| {
        if (src.ai_column[i] != dest.ai_column[i]) return false;
        if (src.ai_column[i] == int.XN_EXPR) {
            if (expr_mod.compare(null, src.col_expr.?.at(i).expr, dest.col_expr.?.at(i).expr, -1) != 0) return false;
        }
        if (src.sort_order[i] != dest.sort_order[i]) return false;
        if (stricmpNull(src.coll[i], dest.coll[i]) != 0) return false;
    }
    if (expr_mod.compare(null, src.part_idx_where, dest.part_idx_where, -1) != 0) return false;
    return true;
}

/// Port of xferCheckRowid().
fn xferCheckRowid(w: *walker.Walker, e: *Expr) WRC {
    if (e.op == TK.COLUMN and e.i_column < 0) {
        w.e_code = 1;
        return WRC.Abort;
    }
    return WRC.Continue;
}

/// Port of xferCompatibleCheck(): the CHECK constraints are the same, and
/// none refers to the rowid unless `dest` has an INTEGER PRIMARY KEY.
fn xferCompatibleCheck(dest: *Table, src: *Table) bool {
    if (expr_mod.listCompare(src.check, dest.check, -1) != 0) return false;
    if (dest.i_pkey < 0) {
        var w: walker.Walker = .{ .expr_callback = xferCheckRowid };
        _ = walker.walkExprList(&w, dest.check);
        if (w.e_code != 0) return false;
    }
    return true;
}

/// Port of xferOptimization(): code INSERT INTO `dest` SELECT * FROM src
/// by copying the raw records of src and its indexes, if the two tables
/// are compatible. True if the transfer is certain to be used. When it
/// works only if `dest` is empty, the code tests that at run time and
/// falls through to the ordinary INSERT coded after it (false is
/// returned). VACUUM relies on this: its tables are always copied so.
fn xferOptimization(p: *Parse, dest: *Table, sel: *Select, on_error_arg: OE, i_db_dest: usize) bool {
    const db = p.db;
    if (p.with != null or sel.with != null) {
        // A CTE named after the source table would not be seen.
        return false;
    }
    if (dest.isVirtual()) return false;
    var on_error = on_error_arg;
    if (on_error == OE.Default) {
        if (dest.i_pkey >= 0) on_error = dest.key_conf;
        if (on_error == OE.Default) on_error = OE.Abort;
    }
    // Only SELECT * FROM one table, with nothing else.
    const src_list = sel.src.?;
    if (src_list.len() != 1) return false;
    if (src_list.at(0).fg.is_subquery) return false;
    if (sel.where != null or sel.order_by != null or sel.group_by != null or sel.limit != null or sel.prior != null) return false;
    if (sel.sel_flags.Distinct) return false;
    const elist = sel.e_list.?;
    if (elist.len() != 1) return false;
    if (elist.at(0).expr.?.op != TK.ASTERISK) return false;

    // The source must be a real table compatible with the destination.
    const item = src_list.at(0);
    const src = build.locateTableItem(p, 0, item) orelse return false;
    if (src.tnum == dest.tnum and src.schema == dest.schema) return false;
    if (dest.hasRowid() != src.hasRowid()) return false;
    if (!src.isOrdinary()) return false;
    if (dest.cols.len != src.cols.len) return false;
    if (dest.i_pkey != src.i_pkey) return false;
    if (dest.tab_flags.Strict) {
        if (!src.tab_flags.Strict) return false;
        for (dest.cols, src.cols) |dc, sc| {
            const dt = dc.e_ctype;
            const st = sc.e_ctype;
            if (dt == int.COLTYPE.ANY) continue;
            if (dt == st) continue;
            if (dt == int.COLTYPE.INT and st == int.COLTYPE.INTEGER) continue;
            if (dt == int.COLTYPE.INTEGER and st == int.COLTYPE.INT) continue;
            return false;
        }
    }
    for (dest.cols, src.cols, 0..) |*dc, *sc, i| {
        // Generated columns must be of the same kind with the same
        // expression. (INSERT INTO t2 SELECT * FROM t1 is then a bulk copy
        // even though the SELECT returns the generated values.)
        const dgen = dc.col_flags.int() & COLFLAG.GENERATED.int();
        if (dgen != sc.col_flags.int() & COLFLAG.GENERATED.int()) return false;
        if (dgen != 0) {
            if (expr_mod.compare(null, build.columnExpr(src, sc), build.columnExpr(dest, dc), -1) != 0) return false;
        }
        if (dc.affinity != sc.affinity) return false;
        if (stricmpNull(build.columnColl(dc), build.columnColl(sc)) != 0) return false;
        if (dc.not_null != OE.None and sc.not_null == OE.None) return false;
        // The defaults of the second and later columns must be the same.
        if (dgen == 0 and i > 0) {
            const de = build.columnExpr(dest, dc);
            const se = build.columnExpr(src, sc);
            if ((de == null) != (se == null) or
                (de != null and !std.mem.eql(u8, de.?.token(), se.?.token())))
            {
                return false;
            }
        }
    }
    var dest_has_unique_idx = false;
    var di = dest.index;
    while (di) |dest_idx| : (di = dest_idx.next) {
        if (dest_idx.isUnique()) dest_has_unique_idx = true;
        var si = src.index;
        const src_idx = while (si) |x| : (si = x.next) {
            if (xferCompatibleIndex(dest_idx, x)) break x;
        } else return false;
        // Two indexes on one b-tree: a corrupt schema.
        if (src_idx.tnum == dest_idx.tnum and src.schema == dest.schema) return false;
    }
    if (dest.check != null and !db.m_db_flags.Vacuum and !xferCompatibleCheck(dest, src)) return false;
    // The transfer would not check foreign keys (VACUUM turns them off).
    if (db.flags.ForeignKeys and dest.u.tab.fkey != null) return false;
    if (db.flags.CountRows) return false;
    if (db.auth != null) {
        const i_db_src: usize = @intCast(prepare.schemaToIndex(db, src.schema));
        if (auth.check(p, auth.Code.SELECT, null, null, null) != auth.OK) return false;
        for (src.cols) |*sc| {
            if (auth.readCol(p, src.name, sc.name(), i_db_src) != auth.OK) return false;
        }
    }

    // The transfer is possible, though perhaps only into an empty table.
    const i_db_src: usize = @intCast(prepare.schemaToIndex(db, src.schema));
    const v = build.getVdbe(p).?;
    build.codeVerifySchema(p, i_db_src);
    const src_cur: Cursor = .from(p.n_tab);
    p.n_tab += 1;
    const dest_cur: Cursor = .from(p.n_tab);
    p.n_tab += 1;
    const autoinc = autoIncBegin(p, i_db_dest, dest);
    const data: Reg = .from(expr_mod.getTempReg(p));
    _ = aux.emit(v, .Null, .{ 0, data });
    const rowid: Reg = .from(expr_mod.getTempReg(p));
    openTable(p, dest_cur.int(), i_db_dest, dest, OP.OpenWrite);
    std.debug.assert(dest.hasRowid() or dest_has_unique_idx);
    var empty_dest_test: ?Addr = null;
    var empty_src_test: ?Addr = null;
    const vacuum = db.m_db_flags.Vacuum;
    if (!vacuum and ((dest.i_pkey < 0 and dest.index != null) or dest_has_unique_idx or
        (on_error != OE.Abort and on_error != OE.Rollback)))
    {
        // The destination must be empty: (1) without an INTEGER PRIMARY
        // KEY the rowids in its index entries might have to change, (2)
        // uniqueness is not checked, (3) neither is the conflict
        // resolution. VACUUM's destination is always empty.
        const addr1 = aux.emit(v, .Rewind, .{ dest_cur, 0 });
        empty_dest_test = aux.emit(v, .Goto, .{});
        aux.landHere(v, addr1);
    }
    if (src.hasRowid()) {
        openTable(p, src_cur.int(), i_db_src, src, OP.OpenRead);
        empty_src_test = aux.emit(v, .Rewind, .{ src_cur, 0 });
        var addr1: Addr = undefined;
        if (dest.i_pkey >= 0) {
            addr1 = aux.emit(v, .Rowid, .{ src_cur, rowid });
            if (!vacuum) {
                const addr2 = aux.emit(v, .NotExists, .{ dest_cur, 0, rowid });
                build.rowidConstraint(p, on_error, dest, rowid.int());
                aux.landHere(v, addr2);
            }
            autoIncStep(p, autoinc, rowid);
        } else if (dest.index == null and !db.m_db_flags.VacuumInto) {
            addr1 = aux.emit(v, .NewRowid, .{ dest_cur, rowid });
        } else {
            addr1 = aux.emit(v, .Rowid, .{ src_cur, rowid });
            std.debug.assert(!dest.tab_flags.Autoincrement);
        }
        var ins_flags: u16 = undefined;
        if (vacuum) {
            _ = aux.emit(v, .SeekEnd, .{dest_cur});
            ins_flags = OPFLAG.APPEND | OPFLAG.USESEEKRESULT | OPFLAG.PREFORMAT;
        } else {
            ins_flags = OPFLAG.NCHANGE | OPFLAG.LASTROWID | OPFLAG.APPEND | OPFLAG.PREFORMAT;
        }
        _ = aux.emit(v, .RowCell, .{ dest_cur, src_cur, rowid });
        _ = aux.emit(v, .Insert, .{ dest_cur, data, rowid });
        if (!vacuum) aux.appendP4(v, .{ .table = dest });
        aux.changeP5(v, ins_flags);
        _ = aux.emit(v, .Next, .{ src_cur, addr1 });
        _ = aux.emit(v, .Close, .{ src_cur, 0 });
        _ = aux.emit(v, .Close, .{ dest_cur, 0 });
    } else {
        build.tableLock(p, i_db_dest, dest.tnum, true, dest.name);
        build.tableLock(p, i_db_src, src.tnum, false, src.name);
    }
    di = dest.index;
    while (di) |dest_idx| : (di = dest_idx.next) {
        var idx_ins_flags: u16 = 0;
        var si = src.index;
        const src_idx = while (si) |x| : (si = x.next) {
            if (xferCompatibleIndex(dest_idx, x)) break x;
        } else unreachable;
        _ = aux.emit(v, .OpenRead, .{ src_cur, src_idx.tnum, i_db_src });
        aux.setP4KeyInfo(p, src_idx);
        _ = aux.emit(v, .OpenWrite, .{ dest_cur, dest_idx.tnum, i_db_dest });
        aux.setP4KeyInfo(p, dest_idx);
        aux.changeP5(v, OPFLAG.BULKCSR);
        const addr1 = aux.emit(v, .Rewind, .{ src_cur, 0 });
        if (vacuum) {
            // The destination is empty, and if every column collates with
            // BINARY the keys come in sorted order: append each one at
            // the end instead of seeking. (A user-defined collation may
            // have changed since the index was built.)
            const all_binary = for (src_idx.coll[0..src_idx.n_column]) |zcoll| {
                if (ctype.strICmp(coll_mod.str_binary, zcoll) != 0) break false;
            } else true;
            if (all_binary) {
                idx_ins_flags = OPFLAG.USESEEKRESULT | OPFLAG.PREFORMAT;
                _ = aux.emit(v, .SeekEnd, .{dest_cur});
                _ = aux.emit(v, .RowCell, .{ dest_cur, src_cur });
            }
        } else if (!src.hasRowid() and dest_idx.isPrimaryKey()) {
            idx_ins_flags |= OPFLAG.NCHANGE;
        }
        if (idx_ins_flags != OPFLAG.USESEEKRESULT | OPFLAG.PREFORMAT) {
            _ = aux.emit(v, .RowData, .{ src_cur, data, 1 });
        }
        _ = aux.emit(v, .IdxInsert, .{ dest_cur, data });
        aux.changeP5(v, idx_ins_flags | OPFLAG.APPEND);
        _ = aux.emit(v, .Next, .{ src_cur, addr1.plus(1) });
        aux.landHere(v, addr1);
        _ = aux.emit(v, .Close, .{ src_cur, 0 });
        _ = aux.emit(v, .Close, .{ dest_cur, 0 });
    }
    if (empty_src_test) |addr| aux.landHere(v, addr);
    expr_mod.releaseTempReg(p, rowid.int());
    expr_mod.releaseTempReg(p, data.int());
    if (empty_dest_test) |addr| {
        autoincrementEnd(p);
        _ = aux.emit(v, .Halt, .{ RC.OK, 0 });
        aux.landHere(v, addr);
        _ = aux.emit(v, .Close, .{ dest_cur, 0 });
        return false;
    }
    return true;
}

/// sqlite3ExprReferencesUpdatedColumn() walker bits.
const CKCNSTRNT_COLUMN: u16 = 0x01;
const CKCNSTRNT_ROWID: u16 = 0x02;

pub const ChngCtx = struct { ai_chng: []const i32 };

fn checkConstraintExprNode(w: *walker.Walker, e: *Expr) WRC {
    if (e.op == TK.COLUMN) {
        const ctx = w.u.chng;
        if (e.i_column >= 0) {
            if (ctx.ai_chng[@intCast(e.i_column)] >= 0) w.e_code |= CKCNSTRNT_COLUMN;
        } else {
            w.e_code |= CKCNSTRNT_ROWID;
        }
    }
    return WRC.Continue;
}

/// Port of sqlite3ExprReferencesUpdatedColumn(): `e` uses a column
/// changed by an UPDATE (ai_chng[i] >= 0), or the rowid if `chng_rowid`.
pub fn exprReferencesUpdatedColumn(e: ?*Expr, ai_chng: []const i32, chng_rowid: bool) bool {
    var ctx: ChngCtx = .{ .ai_chng = ai_chng };
    var w: walker.Walker = .{ .expr_callback = checkConstraintExprNode, .u = .{ .chng = &ctx } };
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
    override_error_arg: OE,
    ignore_dest: i32,
    may_replace: *bool,
    ai_chng: ?[]const i32,
    upsert: ?*Upsert,
) void {
    generateConstraintChecksImpl(p, t, reg_idx, i_data_cur, i_idx_cur, reg_new_data, reg_old_data, pk_chng, override_error_arg, ignore_dest, may_replace, ai_chng, upsert) catch build.oomFault(p);
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
    override_error_arg: OE,
    ignore_dest: i32,
    may_replace: *bool,
    ai_chng: ?[]const i32,
    upsert_arg: ?*Upsert,
) Oom!void {
    var override_error = override_error_arg;
    var upsert = upsert_arg;
    const db = p.db;
    const v = p.vdbe.?;
    const data_cur: Cursor = .from(i_data_cur);
    const idx_cur: Cursor = .from(i_idx_cur);
    const new_data: Reg = .from(reg_new_data);
    const old_data: Reg = .from(reg_old_data);
    const ignore: Jump = .from(ignore_dest);
    const is_update = !old_data.isNone();
    var seen_replace = false;
    var b_affinity_done = false;

    // The PRIMARY KEY of a WITHOUT ROWID table, and the fields of the
    // true primary key.
    const pk: ?*Index = if (t.hasRowid()) null else build.primaryKeyIndex(t);
    const n_pk_field: i32 = if (pk) |k| k.n_key_col else 1;

    // NOT NULL. A second pass handles generated columns and the columns
    // that ON CONFLICT REPLACE gave a default.
    if (t.tab_flags.HasNotNull) {
        var b2nd_pass = false;
        var n_seen_replace: i32 = 0;
        var n_generated: i32 = 0;
        while (true) {
            for (t.cols, 0..) |*c, ii| {
                const i: i32 = @intCast(ii);
                var on_error: OE = c.not_null;
                if (on_error == OE.None) continue;
                if (i == t.i_pkey) continue;
                const is_generated = c.col_flags.intersects(COLFLAG.GENERATED);
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
                const col_reg = new_data.at(1).at(build.tableColumnToStorage(t, @intCast(i)));
                switch (on_error) {
                    OE.Replace => {
                        const addr1 = aux.emit(v, .NotNull, .{col_reg});
                        n_seen_replace += 1;
                        ec.codeCopy(p, build.columnExprAuth(t, c, p), col_reg.int());
                        aux.landHere(v, addr1);
                    },
                    OE.Abort, OE.Rollback, OE.Fail => {
                        if (dconstraint.notNull(p, t, c, is_update, reg_new_data)) |z| {
                            build.haltDialectConstraint(p, OP.HaltIfNull, RC.CONSTRAINT_NOTNULL, on_error, z, col_reg.int());
                            continue;
                        }
                        if (on_error == OE.Abort) main_mod.mayAbort(p);
                        const msg = try std.fmt.allocPrint(p.arena, "{s}.{s}", .{ t.name, c.name() });
                        _ = aux.emitStr(v, .HaltIfNull, .{ RC.CONSTRAINT_NOTNULL, on_error.int(), col_reg }, msg);
                        aux.changeP5(v, vi.P5_ConstraintNotNull);
                    },
                    else => {
                        _ = aux.emit(v, .IsNull, .{ col_reg, ignore });
                    },
                }
            }
            if (n_generated == 0 and n_seen_replace == 0) break;
            if (b2nd_pass) break;
            b2nd_pass = true;
            if (n_seen_replace > 0 and t.tab_flags.intersects(TF.HasGenerated)) computeGeneratedColumns(p, reg_new_data + 1, t);
        }
    }

    // CHECK.
    if (t.check) |checks| if (!db.flags.IgnoreChecks) {
        p.i_self_tab = -(reg_new_data + 1);
        var on_error: OE = if (override_error != OE.Default) override_error else OE.Abort;
        for (checks.slice()) |item| {
            const e = item.expr;
            if (ai_chng) |ac| if (!exprReferencesUpdatedColumn(e, ac, pk_chng)) continue;
            if (!b_affinity_done) {
                tableAffinity(p, t, reg_new_data + 1);
                b_affinity_done = true;
            }
            const all_ok = aux.newLabel(p);
            const copy = try expr_mod.exprDup(p.arena, e);
            if (!db.malloc_failed) ec.exprIfTrue(p, copy, all_ok.int(), vi.SQLITE_JUMPIFNULL);
            if (on_error == OE.Ignore) {
                _ = aux.emit(v, .Goto, .{ 0, ignore });
            } else {
                if (on_error == OE.Replace) on_error = OE.Abort;
                if (dconstraint.check(p, t, item.e_name, is_update, reg_new_data)) |z| {
                    build.haltDialectConstraint(p, OP.Halt, RC.CONSTRAINT_CHECK, on_error, z, 0);
                } else {
                    build.haltConstraint(p, RC.CONSTRAINT_CHECK, on_error, item.e_name, vi.P5_ConstraintCheck);
                }
            }
            aux.place(v, all_ok);
        }
        p.i_self_tab = 0;
    };

    // The order the UNIQUE constraints are checked in (IndexIterator): the
    // indexes as listed, except that those of ON CONFLICT clauses come
    // first, in the order of the clauses.
    var n_idx: usize = 0;
    var idx_it = t.index;
    while (idx_it) |ix| : (idx_it = ix.next) n_idx += 1;
    const order = try p.arena.alloc(IndexListTerm, n_idx);
    {
        var i: usize = 0;
        idx_it = t.index;
        while (idx_it) |ix| : (idx_it = ix.next) {
            order[i] = .{ .idx = ix, .ix = i };
            i += 1;
        }
    }
    if (upsert) |up| {
        if (up.target == null) {
            // One ON CONFLICT clause, without a target.
            std.debug.assert(up.next == null);
            if (!up.is_do_update) {
                // DO NOTHING: all are INSERT OR IGNORE.
                override_error = OE.Ignore;
                upsert = null;
            } else {
                override_error = OE.Update;
            }
        } else if (t.index != null) {
            const used = try p.arena.alloc(bool, n_idx);
            @memset(used, false);
            var i: usize = 0;
            var term: ?*Upsert = up;
            while (term) |tm| : (term = tm.next) {
                if (tm.target == null) break;
                // The clause of the INTEGER PRIMARY KEY.
                const tidx = tm.idx orelse continue;
                var jj: usize = 0;
                idx_it = t.index;
                while (idx_it != tidx) : (jj += 1) idx_it = idx_it.?.next;
                // A duplicate clause is ignored.
                if (used[jj]) continue;
                used[jj] = true;
                order[i] = .{ .idx = tidx, .ix = jj };
                i += 1;
            }
            var jj: usize = 0;
            idx_it = t.index;
            while (idx_it) |ix| : ({
                idx_it = ix.next;
                jj += 1;
            }) {
                if (used[jj]) continue;
                order[i] = .{ .idx = ix, .ix = jj };
                i += 1;
            }
            std.debug.assert(i == n_idx);
        }
    }

    // UNIQUE and PRIMARY KEY: (A) the rowid, (B) the indexes without
    // REPLACE, (C) those with REPLACE (createIndex() puts them last).
    //
    // Deletes by REPLACE may run "replace triggers" (DELETE triggers or
    // foreign key actions). If any did, every uniqueness constraint is
    // checked again afterwards, with ABORT: trig_cnt counts them, and
    // the rechecks are chained through lbl_recheck_ok from addr_recheck.
    var trig: ?*Trigger = null;
    var trig_cnt: Reg = .none;
    var addr_recheck: ?Label = null;
    var lbl_recheck_ok: ?Label = null;
    var n_replace_trig: i32 = 0;
    if (db.flags.intersects(.{ .RecTriggers = true, .ForeignKeys = true })) {
        if (db.flags.RecTriggers) trig = trigger.triggersExist(p, t, TK.DELETE, null, null);
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
            trig_cnt = .from(p.n_mem);
            _ = aux.emit(v, .Integer, .{ 0, trig_cnt });
            lbl_recheck_ok = aux.newLabel(p);
            addr_recheck = lbl_recheck_ok;
        }
    }

    var ipk_top: ?Addr = null;
    var ipk_bottom: ?Addr = null;
    // The ON CONFLICT clause of the constraint being checked.
    var upsert_clause: ?*Upsert = null;
    // When the first ON CONFLICT clause is not on the rowid, the rowid
    // check jumps (from upsert_ipk_delay) after the checks of the clauses
    // before it, and returns (upsert_ipk_return) to the checks after.
    var upsert_ipk_delay: ?Addr = null;
    var upsert_ipk_return: ?Addr = null;
    if (pk_chng and pk == null) {
        // The new rowid must not exist already.
        const rowid_ok = aux.newLabel(p);
        var on_error: OE = t.key_conf;
        if (override_error != OE.Default) {
            on_error = override_error;
        } else if (on_error == OE.Default) {
            on_error = OE.Abort;
        }

        if (upsert) |up| {
            upsert_clause = upsert_mod.ofIndex(up, null);
            if (upsert_clause) |uc| {
                // DO NOTHING is INSERT OR IGNORE.
                on_error = if (uc.is_do_update) OE.Update else OE.Ignore;
            }
            if (upsert_clause != up) upsert_ipk_delay = aux.emit(v, .Goto, .{});
        }

        // A REPLACE of the rowid waits until the other constraints, which
        // may FAIL or IGNORE, have been checked.
        if (on_error == OE.Replace and on_error != override_error and t.index != null) {
            if (upsert_ipk_delay) |delay| {
                ipk_top = delay.plus(1);
                upsert_ipk_delay = null;
            } else {
                ipk_top = aux.emit(v, .Goto, .{}).plus(1);
            }
        }

        // An UPDATE need not check an unchanged rowid.
        if (is_update) {
            _ = aux.emit(v, .Eq, .{ new_data, rowid_ok, old_data });
            aux.changeP5(v, vi.SQLITE_NOTNULL);
        }

        _ = aux.emit(v, .NotExists, .{ data_cur, rowid_ok, new_data });
        switch (on_error) {
            OE.Replace => {
                if (!trig_cnt.isNone()) {
                    // Delete the other row, running its triggers.
                    main_mod.multiWrite(p);
                    delete_mod.generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, reg_new_data, 1, false, OE.Replace, where_mod.ONEPASS.SINGLE, -1);
                    _ = aux.emit(v, .AddImm, .{ trig_cnt, 1 });
                    n_replace_trig += 1;
                } else if (t.index != null) {
                    // The index entries of the other row go; its record is
                    // overwritten by the new one.
                    main_mod.multiWrite(p);
                    delete_mod.generateRowIndexDelete(p, t, i_data_cur, i_idx_cur, null, -1);
                }
                seen_replace = true;
            },
            OE.Update => {
                try upsert_mod.doUpdate(p, upsert.?, t, null, i_data_cur);
                _ = aux.emit(v, .Goto, .{ 0, ignore });
            },
            OE.Ignore => _ = aux.emit(v, .Goto, .{ 0, ignore }),
            OE.Rollback, OE.Fail => build.rowidConstraint(p, on_error, t, reg_new_data),
            else => build.rowidConstraint(p, OE.Abort, t, reg_new_data),
        }
        aux.place(v, rowid_ok);
        if (ipk_top) |top| {
            ipk_bottom = aux.emit(v, .Goto, .{});
            aux.landHere(v, top.plus(-1));
        } else if (upsert != null and upsert_clause != upsert) {
            upsert_ipk_return = aux.emit(v, .Goto, .{});
        }
    }

    // UNIQUE indexes (and the PRIMARY KEY of a WITHOUT ROWID table):
    // build each new index entry and make sure it is not there already.
    for (order) |term| {
        const idx = term.idx;
        const ix = term.ix;
        if (reg_idx[ix] == 0) continue;
        const idx_rec: Reg = .from(reg_idx[ix]);
        if (upsert) |up| {
            upsert_clause = upsert_mod.ofIndex(up, idx);
            if (upsert_ipk_delay) |delay| if (upsert_clause == up) aux.landHere(v, delay);
        }
        const unique_ok = aux.newLabel(p);
        if (!b_affinity_done) {
            tableAffinity(p, t, reg_new_data + 1);
            b_affinity_done = true;
        }
        const this_cur = idx_cur.at(ix);

        // A partial index whose WHERE is false gets no entry.
        if (idx.part_idx_where) |w| {
            _ = aux.emit(v, .Null, .{ 0, idx_rec });
            p.i_self_tab = -(reg_new_data + 1);
            ec.exprIfFalseDup(p, w, unique_ok.int(), vi.SQLITE_JUMPIFNULL);
            p.i_self_tab = 0;
        }

        // The new index entry, to reg_idx[ix].
        const key_reg = idx_rec.at(1);
        for (0..idx.n_column) |ii| {
            const i: i32 = @intCast(ii);
            const i_field = idx.ai_column[ii];
            if (i_field == int.XN_EXPR) {
                p.i_self_tab = -(reg_new_data + 1);
                ec.codeCopy(p, idx.col_expr.?.at(ii).expr, key_reg.at(i).int());
                p.i_self_tab = 0;
            } else if (i_field == int.XN_ROWID or i_field == t.i_pkey) {
                _ = aux.emit(v, .IntCopy, .{ new_data, key_reg.at(i) });
            } else {
                const x = new_data.at(1).at(build.tableColumnToStorage(t, i_field));
                _ = aux.emit(v, .SCopy, .{ x, key_reg.at(i) });
            }
        }
        _ = aux.emit(v, .MakeRecord, .{ key_reg, idx.n_column, idx_rec });

        // The PRIMARY KEY of an UPDATE that does not change it cannot
        // collide.
        if (is_update and pk == idx and !pk_chng) {
            aux.place(v, unique_ok);
            continue;
        }

        var on_error: OE = idx.on_error;
        if (on_error == OE.None) {
            aux.place(v, unique_ok);
            continue;
        }
        if (override_error != OE.Default) {
            on_error = override_error;
        } else if (on_error == OE.Default) {
            on_error = OE.Abort;
        }
        if (upsert_clause) |uc| on_error = if (uc.is_do_update) OE.Update else OE.Ignore;

        // No collision check is needed for a REPLACE of the PRIMARY KEY of
        // a WITHOUT ROWID table without other indexes (the new entry
        // overwrites the old).
        if (ix == 0 and idx.next == null and pk == idx and on_error == OE.Replace and
            (!db.flags.RecTriggers or trigger.triggersExist(p, t, TK.DELETE, null, null) == null) and
            (!db.flags.ForeignKeys or (t.u.tab.fkey == null and fkey.fkReferences(t) == null)))
        {
            aux.place(v, unique_ok);
            continue;
        }

        // Is the new entry unique?
        var addr_conflict_ck = aux.emitInt(v, .NoConflict, .{ this_cur, unique_ok, key_reg }, idx.n_key_col);

        // On a collision, the key of the other row goes to other_key.
        const other_key: Reg = if (idx == pk) key_reg else .from(expr_mod.getTempRange(p, n_pk_field));
        if (is_update or on_error == OE.Replace) {
            if (t.hasRowid()) {
                _ = aux.emit(v, .IdxRowid, .{ this_cur, other_key });
                // No conflict with the row being updated.
                if (is_update) {
                    _ = aux.emit(v, .Eq, .{ other_key, unique_ok, old_data });
                    aux.changeP5(v, vi.SQLITE_NOTNULL);
                }
            } else {
                const k = pk.?;
                if (idx != k) {
                    for (0..k.n_key_col) |ii| {
                        const x = build.tableColumnToIndex(idx, k.ai_column[ii]);
                        _ = aux.emit(v, .Column, .{ this_cur, x, other_key.at(ii) });
                    }
                }
                if (is_update) {
                    // A conflict only if the PRIMARY KEY found differs from
                    // the old one.
                    var addr_jump: Jump = .from(aux.currentAddr(v) + k.n_key_col);
                    var op: OP = OP.Ne;
                    const cmp_reg = if (idx.isPrimaryKey()) key_reg else other_key;
                    for (0..k.n_key_col) |ii| {
                        const coll = @import("coll.zig").locateCollSeq(p, k.coll[ii]);
                        var x: i32 = k.ai_column[ii];
                        if (ii == k.n_key_col - 1) {
                            addr_jump = .of(unique_ok);
                            op = OP.Eq;
                        }
                        x = build.tableColumnToStorage(t, @intCast(x));
                        const cmp = aux.emitAny(v, op, .{ .reg, .jump, .reg }, .{ old_data.at(1 + x), addr_jump, cmp_reg.at(ii) });
                        aux.changeP4(v, cmp.int(), if (coll) |cl| .{ .collseq = cl } else .notused);
                        aux.changeP5(v, vi.SQLITE_NOTNULL);
                    }
                }
            }
        }

        const n_conflict_end = aux.here(v);
        switch (on_error) {
            OE.Rollback, OE.Abort, OE.Fail => build.uniqueConstraint(p, on_error, idx, key_reg.int()),
            OE.Update => {
                try upsert_mod.doUpdate(p, upsert.?, t, idx, this_cur.int());
                _ = aux.emit(v, .Goto, .{ 0, ignore });
            },
            OE.Ignore => _ = aux.emit(v, .Goto, .{ 0, ignore }),
            else => {
                // REPLACE: delete the other row.
                if (!trig_cnt.isNone()) {
                    main_mod.multiWrite(p);
                    n_replace_trig += 1;
                }
                if (trig != null and is_update) _ = aux.emit(v, .CursorLock, .{data_cur});
                delete_mod.generateRowDelete(p, t, trig, i_data_cur, i_idx_cur, other_key.int(), @intCast(n_pk_field), false, OE.Replace, if (idx == pk) where_mod.ONEPASS.SINGLE else where_mod.ONEPASS.OFF, this_cur.int());
                if (trig != null and is_update) _ = aux.emit(v, .CursorUnlock, .{data_cur});
                seen_replace = true;
            },
        }
        if (!trig_cnt.isNone()) {
            _ = aux.emit(v, .AddImm, .{ trig_cnt, 1 });
            const addr_bypass = aux.emit(v, .Goto, .{});

            // The recheck, run after all the constraint checks if a
            // replace trigger fired: the conflict check above again,
            // jumping on to the next recheck when it passes.
            aux.place(v, lbl_recheck_ok.?);
            const recheck_ok = aux.newLabel(p);
            lbl_recheck_ok = recheck_ok;
            if (idx.part_idx_where != null) _ = aux.emit(v, .IsNull, .{ key_reg.at(-1), recheck_ok });
            while (addr_conflict_ck.int() < n_conflict_end.int()) : (addr_conflict_ck = addr_conflict_ck.plus(1)) {
                const x = aux.getOp(v, addr_conflict_ck.int()).*;
                if (x.opcode != OP.IdxRowid or is_update) {
                    // A copy of an instruction of any opcode: its operands
                    // are numbers here.
                    const p2 = if (x.opcode.opflags() & vi.opcodes.OPFLG.JUMP != 0) recheck_ok.int() else x.p2;
                    _ = aux.addOp4(v, x.opcode, x.p1, p2, x.p3, x.getP4());
                    aux.changeP5(v, x.p5);
                }
            }
            build.uniqueConstraint(p, OE.Abort, idx, key_reg.int());
            aux.landHere(v, addr_bypass);
        }
        aux.place(v, unique_ok);
        if (other_key != key_reg) expr_mod.releaseTempRange(p, other_key.int(), n_pk_field);
        if (upsert_clause) |uc| if (upsert_ipk_return) |ret| if (upsert_mod.nextIsIpk(uc)) {
            _ = aux.emit(v, .Goto, .{ 0, upsert_ipk_delay.?.plus(1) });
            aux.landHere(v, ret);
            upsert_ipk_return = null;
        };
    }

    // The deferred REPLACE of the rowid.
    if (ipk_top) |top| {
        _ = aux.emit(v, .Goto, .{ 0, top });
        aux.landHere(v, ipk_bottom.?);
    }

    // Recheck the uniqueness constraints after replace triggers ran.
    if (n_replace_trig != 0) {
        _ = aux.emit(v, .IfNot, .{ trig_cnt, lbl_recheck_ok.? });
        if (pk == null) {
            if (is_update) {
                _ = aux.emit(v, .Eq, .{ new_data, addr_recheck.?, old_data });
                aux.changeP5(v, vi.SQLITE_NOTNULL);
            }
            _ = aux.emit(v, .NotExists, .{ data_cur, addr_recheck.?, new_data });
            build.rowidConstraint(p, OE.Abort, t, reg_new_data);
        } else {
            _ = aux.emit(v, .Goto, .{ 0, addr_recheck.? });
        }
    }
    if (!trig_cnt.isNone()) aux.place(v, lbl_recheck_ok.?);

    // The table record.
    if (t.hasRowid()) {
        const rec: Reg = .from(reg_idx[n_idx]);
        _ = aux.emit(v, .MakeRecord, .{ new_data.at(1), t.n_nv_col, rec });
        if (!b_affinity_done) tableAffinity(p, t, 0);
    }
    may_replace.* = seen_replace;
}

/// IndexListTerm: an index, and its position in Table.index.
const IndexListTerm = struct { idx: *Index, ix: usize };

/// Port of sqlite3CompleteInsertion(): write the index entries and the
/// record made by generateConstraintChecks(). `update_flags` is 0 for an
/// INSERT, else OPFLAG_ISUPDATE (and OPFLAG_SAVEPOSITION).
pub fn completeInsertion(p: *Parse, t: *Table, i_data_cur: i32, i_idx_cur: i32, reg_new_data: i32, reg_idx: []const i32, update_flags: u16, append_bias: bool, use_seek_result: bool) void {
    const v = p.vdbe.?;
    const data_cur: Cursor = .from(i_data_cur);
    const idx_cur: Cursor = .from(i_idx_cur);
    var i: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        i += 1;
    }) {
        if (reg_idx[i] == 0) continue;
        const rec: Reg = .from(reg_idx[i]);
        // A NULL record: no entry (partial indexes, and UPDATE of an index
        // on expressions).
        if (idx.part_idx_where != null or (update_flags != 0 and idx.has_expr)) {
            _ = aux.emit(v, .IsNull, .{ rec, aux.here(v).plus(2) });
        }
        var pik_flags: u16 = if (use_seek_result) OPFLAG.USESEEKRESULT else 0;
        if (idx.isPrimaryKey() and !t.hasRowid()) {
            pik_flags |= OPFLAG.NCHANGE;
            pik_flags |= update_flags & OPFLAG.SAVEPOSITION;
        }
        _ = aux.emitInt(v, .IdxInsert, .{ idx_cur.at(i), rec, rec.at(1) }, if (idx.uniq_not_null) idx.n_key_col else idx.n_column);
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
    _ = aux.emit(v, .Insert, .{ data_cur, Reg.from(reg_idx[i]), Reg.from(reg_new_data) });
    if (p.nested == 0) aux.appendP4(v, .{ .table = t });
    aux.changeP5(v, pik_flags);
}

/// Port of sqlite3OpenTableAndIndices(): open cursors on `t` and its
/// indexes from `i_base` (or the next free cursor if negative), those
/// with `to_open` set if given. Returns the number of indexes; the cursor
/// of the table (the PRIMARY KEY of a WITHOUT ROWID table) goes to
/// `data_cur` and that of the first index to `idx_cur`.
pub fn openTableAndIndices(p: *Parse, t: *Table, op: OP, p5_arg: u8, i_base_arg: i32, to_open: ?[]const bool, data_cur: *i32, idx_cur: *i32) usize {
    var p5 = p5_arg;
    if (t.e_tab_type == .vtab) {
        data_cur.* = -999;
        idx_cur.* = -999;
        return 0;
    }
    const i_db: usize = @intCast(prepare.schemaToIndex(p.db, t.schema));
    const v = p.vdbe.?;
    var base: Cursor = .from(if (i_base_arg < 0) p.n_tab else i_base_arg);
    const tab_cur = base;
    base = base.at(1);
    data_cur.* = tab_cur.int();
    if (t.hasRowid() and (to_open == null or to_open.?[0])) {
        openTable(p, tab_cur.int(), i_db, t, op);
    } else build.tableLock(p, i_db, t.tnum, op == OP.OpenWrite, t.name);
    idx_cur.* = base.int();
    var i: usize = 0;
    var idx_opt = t.index;
    while (idx_opt) |idx| : ({
        idx_opt = idx.next;
        i += 1;
    }) {
        const this_cur = base;
        base = base.at(1);
        if (idx.isPrimaryKey() and !t.hasRowid()) {
            data_cur.* = this_cur.int();
            p5 = 0;
        }
        if (to_open == null or to_open.?[i + 1]) {
            _ = aux.emitAny(v, op, open_shape, .{ this_cur, idx.tnum, i_db });
            aux.setP4KeyInfo(p, idx);
            aux.changeP5(v, p5);
        }
    }
    if (base.int() > p.n_tab) p.n_tab = base.int();
    return i;
}

/// xqlite: the DEFAULT of the INTEGER PRIMARY KEY of `t` when a statement
/// of a typed dialect (typing.active()) leaves the column out; null for
/// SQLite's dialect, whose bytecode gives a new rowid.
fn ipkDefault(p: *Parse, t: *Table) ?*Expr {
    if (!typing.active(p.db) or t.i_pkey < 0) return null;
    return build.columnExprAuth(t, &t.cols[@intCast(t.i_pkey)], p);
}
