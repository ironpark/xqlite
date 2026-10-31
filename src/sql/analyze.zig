//! ANALYZE (port of analyze.c) and PRAGMA optimize (pragma.c).
//!
//! Only sqlite_stat1 is ported. The reference sqlite3 builds leave
//! SQLITE_ENABLE_STAT4 off, so sqlite_stat4 is neither written nor read;
//! as in C, ANALYZE only deletes its rows if the table exists.
//!
//! For each index, the stat_init(), stat_push() and stat_get() SQL
//! functions (reachable only from the bytecode ANALYZE codes) count the
//! distinct key prefixes in one pass over the index; the "stat" column is
//! "N a1 a2 ...", the rows and the average rows per value of each prefix.
//! OP_LoadAnalysis reads sqlite_stat1 back into Index.ai_row_log_est.
//!
//! The tables are visited in the order of C's tblHash (hash.zig), so the
//! bytecode and the rowids of the sqlite_stat1 rows are sqlite3's.

const std = @import("std");
const int = @import("sqlite_int.zig");
const build = @import("build.zig");
const legacy = @import("legacy.zig");
const util = @import("util.zig");
const printf = @import("printf.zig");
const prepare = @import("prepare.zig");
const auth = @import("auth.zig");
const insert = @import("insert.zig");
const expr = @import("expr.zig");
const coll = @import("coll.zig");
const func = @import("func/func.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const aux = @import("../vdbe/aux.zig");
const api = @import("../vdbe/api.zig");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const Table = int.Table;
const Index = int.Index;
const Token = int.Token;
const LogEst = int.LogEst;
const Oom = int.Oom;
const Vdbe = vi.Vdbe;
const Mem = vi.Mem;
const Context = vi.Context;
const OP = vi.OP;
const OPFLAG = vi.OPFLAG;

/// SQLITE_Stat4 of SQLITE_TESTCTRL_OPTIMIZATIONS: OP_Count estimates the
/// rows when it is off.
const opt_stat4: u32 = 0x00000800;

/// SQLITE_DEFAULT_OPTIMIZE_LIMIT (pragma.c).
const default_optimize_limit = 2000;

/// The estimated number of rows of a table or index (tRowcnt).
const RowCnt = u64;

/// Port of openStatTable(): create sqlite_stat1 in database `i_db` if it
/// does not exist, delete its rows (and those of sqlite_stat4 and
/// sqlite_stat3) about `where` (all if null), a table or index name as
/// `where_type` says, and open it for writing on cursor `i_stat_cur`.
fn openStatTable(p: *Parse, i_db: usize, i_stat_cur: i32, where: ?[]const u8, where_type: []const u8) void {
    const Stat = struct { name: []const u8, cols: ?[]const u8 };
    const tables = [_]Stat{
        .{ .name = "sqlite_stat1", .cols = "tbl,idx,stat" },
        .{ .name = "sqlite_stat4", .cols = null },
        .{ .name = "sqlite_stat3", .cols = null },
    };
    const n_to_open = 1;
    const db = p.db;
    const v = build.getVdbe(p) orelse return;
    const pdb = &db.dbs.items[i_db];
    var roots: [tables.len]u32 = @splat(0);
    var create_tbl: [tables.len]u16 = @splat(0);

    // Create new statistic tables if they do not exist, or clear them if
    // they do already exist.
    for (tables, 0..) |st, i| {
        if (build.findTable(db, st.name, pdb.name)) |stat| {
            // The table already exists. If `where` is not null, delete all
            // entries associated with the table `where`. If it is null,
            // delete the entire contents of the table.
            roots[i] = stat.tnum;
            if (where) |w| {
                build.nestedParse(p, "DELETE FROM %Q.%s WHERE %s=%Q", &.{
                    .{ .str = pdb.name }, .{ .str = st.name }, .{ .str = where_type }, .{ .str = w },
                });
            } else {
                _ = aux.addOp2(v, OP.Clear, @intCast(roots[i]), @intCast(i_db));
            }
        } else if (i < n_to_open) {
            // The sqlite_statN table does not exist. Create it. A side
            // effect of CREATE TABLE is to leave the root page of the new
            // table in register u1.cr.reg_root, for the OpenWrite below.
            build.nestedParse(p, "CREATE TABLE %Q.%s(%s)", &.{ .{ .str = pdb.name }, .{ .str = st.name }, .{ .str = st.cols } });
            roots[i] = @bitCast(p.u1.cr.reg_root);
            create_tbl[i] = OPFLAG.P2ISREG;
        }
    }

    // Open the sqlite_stat1 table for writing.
    for (0..n_to_open) |i| {
        _ = aux.addOp4Int(v, OP.OpenWrite, i_stat_cur + @as(i32, @intCast(i)), @bitCast(roots[i]), @intCast(i_db), 3);
        aux.changeP5(v, create_tbl[i]);
    }
}

/// The state shared by stat_init(), stat_push() and stat_get()
/// (StatAccum, without the STAT4 samples).
const StatAccum = struct {
    db: *Sqlite3,
    /// Estimated number of rows.
    n_est: RowCnt,
    /// Number of rows visited so far.
    n_row: RowCnt = 0,
    /// Analysis row-scan limit.
    n_limit: i32,
    /// Number of columns in the index + pk/rowid.
    n_col: i32,
    /// Number of index columns without the pk/rowid.
    n_key_col: i32,
    /// Number of times of skip-ahead.
    n_skip_ahead: u8 = 0,
    /// The distinct values of each prefix so far, less one
    /// (current.anDLt).
    an_dlt: []RowCnt,
};

/// Port of statAccumDestructor().
fn statAccumDestructor(p: *StatAccum) void {
    p.db.gpa.free(p.an_dlt);
    p.db.gpa.destroy(p);
}

/// The StatAccum a stat_init() result points at.
fn statAccumOf(m: *Mem) *StatAccum {
    const b = api.valueBlob(m).?;
    return @ptrCast(@alignCast(@constCast(b.ptr)));
}

/// Port of statInit(): stat_init(N,K,C,L) with
///   N: the number of columns in the index including the rowid/pk (for
///      the covering index of a WITHOUT ROWID table, the number of
///      PRIMARY KEY columns),
///   K: the number of columns in the index excluding the rowid/pk,
///   C: the estimated number of rows in the index,
///   L: a limit on the number of rows to scan, or 0 for no limit.
/// The result is a blob that is really a pointer to the StatAccum.
fn statInit(ctx: *Context, argv: []*Mem) void {
    const db = ctx.out.db.?;
    const n_col = api.valueInt(argv[0]);
    std.debug.assert(n_col > 0);
    const n_key_col = api.valueInt(argv[1]);
    std.debug.assert(n_key_col <= n_col);
    std.debug.assert(n_key_col > 0);

    const an_dlt = db.gpa.alloc(RowCnt, @intCast(n_col)) catch return api.resultErrorNomem(ctx);
    @memset(an_dlt, 0);
    const p = db.gpa.create(StatAccum) catch {
        db.gpa.free(an_dlt);
        return api.resultErrorNomem(ctx);
    };
    p.* = .{
        .db = db,
        .n_est = @bitCast(api.valueInt64(argv[2])),
        .n_limit = api.valueInt(argv[3]),
        .n_col = n_col,
        .n_key_col = n_key_col,
        .an_dlt = an_dlt,
    };
    // Only the pointer matters; the size can be any positive value.
    api.resultBlob(ctx, std.mem.asBytes(p), .{ .func = int.destructor(statAccumDestructor) });
}

const stat_init_funcdef: int.FuncDef = .{
    .n_arg = 4,
    .func_flags = .{ .enc = 1 },
    .x_sfunc = statInit,
    .name = "stat_init",
};

/// Port of statPush(): stat_push(P,C) with P the StatAccum and C the
/// index of the left-most column to differ from the previous row. The
/// result is NULL, or with an analysis limit an integer when the scan
/// should skip ahead.
fn statPush(ctx: *Context, argv: []*Mem) void {
    const p = statAccumOf(argv[0]);
    const i_chng = api.valueInt(argv[1]);
    std.debug.assert(p.n_col > 0);
    std.debug.assert(i_chng < p.n_col);

    if (p.n_row != 0) {
        // Second and subsequent calls: count the new distinct prefixes.
        var i: usize = @intCast(i_chng);
        while (i < @as(usize, @intCast(p.n_col))) : (i += 1) p.an_dlt[i] +%= 1;
    }

    p.n_row +%= 1;
    if (p.n_limit != 0 and p.n_row > @as(RowCnt, @intCast(p.n_limit)) *% (@as(RowCnt, p.n_skip_ahead) + 1)) {
        p.n_skip_ahead +%= 1;
        api.resultInt(ctx, @intFromBool(p.an_dlt[0] > 0));
    }
}

const stat_push_funcdef: int.FuncDef = .{
    .n_arg = 2,
    .func_flags = .{ .enc = 1 },
    .x_sfunc = statPush,
    .name = "stat_push",
};

/// Port of statGet(): stat_get(P), the "stat" column of the sqlite_stat1
/// row of the index: the number of entries, then for each key prefix the
/// average number of rows with one value of it, K/D rounded up, except
/// that a value just above 1.0 (up to 1.1) counts as 1.
fn statGet(ctx: *Context, argv: []*Mem) void {
    const p = statAccumOf(argv[0]);
    const db = p.db;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(db.gpa);
    const w = struct {
        fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) bool {
            list.print(gpa, fmt, args) catch return false;
            return true;
        }
    };
    if (!w.append(&out, db.gpa, "{d}", .{if (p.n_skip_ahead != 0) p.n_est else p.n_row})) return api.resultErrorNomem(ctx);
    for (0..@intCast(p.n_key_col)) |i| {
        const n_distinct: u64 = p.an_dlt[i] +% 1;
        var i_val: u64 = (p.n_row +% n_distinct -% 1) / n_distinct;
        if (i_val == 2 and p.n_row *% 10 <= n_distinct *% 11) i_val = 1;
        if (!w.append(&out, db.gpa, " {d}", .{i_val})) return api.resultErrorNomem(ctx);
    }
    api.resultText(ctx, out.items, .transient);
}

const stat_get_funcdef: int.FuncDef = .{
    .n_arg = 1,
    .func_flags = .{ .enc = 1 },
    .x_sfunc = statGet,
    .name = "stat_get",
};

/// Port of callStatGet().
fn callStatGet(p: *Parse, reg_stat: i32, reg_out: i32) void {
    std.debug.assert(reg_out != reg_stat and reg_out != reg_stat + 1);
    _ = aux.addFunctionCall(p, 0, reg_stat, reg_out, 1, &stat_get_funcdef, 0);
}

/// Port of analyzeOneTable(): code the analysis of the indexes of `t`
/// (only `only_idx` if not null) into sqlite_stat1 on cursor
/// `i_stat_cur`, using registers from `i_mem_arg` and cursors from
/// `i_tab_arg` on.
fn analyzeOneTable(p: *Parse, t: *Table, only_idx: ?*Index, i_stat_cur: i32, i_mem_arg: i32, i_tab_arg: i32) Oom!void {
    const db = p.db;
    var i_mem = i_mem_arg;
    var i_tab = i_tab_arg;
    var need_table_cnt = true;
    const reg_new_rowid = i_mem; // Rowid for the inserted record
    i_mem += 1;
    const reg_stat = i_mem; // Register to hold the StatAccum object
    i_mem += 1;
    const reg_chng = i_mem; // Index of changed index field
    i_mem += 1;
    const reg_rowid = i_mem; // Rowid argument passed to stat_push()
    i_mem += 1;
    const reg_temp = i_mem; // Temporary use register
    i_mem += 1;
    const reg_temp2 = i_mem; // Second temporary use register
    i_mem += 1;
    const reg_tabname = i_mem; // Register containing the table name
    i_mem += 1;
    const reg_idxname = i_mem; // Register containing the index name
    i_mem += 1;
    const reg_stat1 = i_mem; // Value for the stat column of sqlite_stat1
    i_mem += 1;
    const reg_prev = i_mem; // MUST BE LAST (see below)

    expr.touchRegister(p, i_mem);
    const v = build.getVdbe(p) orelse return;
    // Do not gather statistics on views or virtual tables, nor on system
    // tables.
    if (!t.isOrdinary()) return;
    if (func.strlike("sqlite\\_%", t.name.ptr, '\\') == 0) return;
    const i_db: usize = @intCast(prepare.schemaToIndex(db, t.schema));
    if (auth.check(p, auth.Code.ANALYZE, t.name, null, db.dbs.items[i_db].name) != auth.OK) return;

    // Open a read-only cursor on the table. Also allocate a cursor number
    // to use for scanning indexes (i_idx_cur). No index cursor is opened
    // at this time though.
    const i_tab_cur = i_tab;
    i_tab += 1;
    const i_idx_cur = i_tab;
    i_tab += 1;
    p.n_tab = @max(p.n_tab, i_tab);
    insert.openTable(p, i_tab_cur, i_db, t, OP.OpenRead);
    _ = aux.loadString(v, reg_tabname, t.name);

    var idx_opt = t.index;
    while (idx_opt) |idx| : (idx_opt = idx.next) {
        if (only_idx != null and only_idx != idx) continue;
        if (idx.part_idx_where == null) need_table_cnt = false;
        var n_col: i32 = undefined; // Number of columns in idx. "N"
        var idx_name: []const u8 = undefined;
        var n_col_test: i32 = undefined; // Number of columns to test for changes
        if (!t.hasRowid() and idx.isPrimaryKey()) {
            n_col = idx.n_key_col;
            idx_name = t.name;
            n_col_test = n_col - 1;
        } else {
            n_col = idx.n_column;
            idx_name = idx.name;
            n_col_test = if (idx.uniq_not_null) @as(i32, idx.n_key_col) - 1 else n_col - 1;
        }

        // Populate the register containing the index name.
        _ = aux.loadString(v, reg_idxname, idx_name);

        // Pseudo-code for the loop that calls stat_push():
        //
        //   regChng = 0
        //   Rewind csr
        //   if eof(csr){
        //      stat_init() with count = 0;
        //      goto end_of_scan;
        //   }
        //   count()
        //   stat_init()
        //   goto chng_addr_0;
        //
        //  next_row:
        //   regChng = 0
        //   if( idx(0) != regPrev(0) ) goto chng_addr_0
        //   regChng = 1
        //   if( idx(1) != regPrev(1) ) goto chng_addr_1
        //   ...
        //   regChng = N
        //   goto chng_addr_N
        //
        //  chng_addr_0:
        //   regPrev(0) = idx(0)
        //  chng_addr_1:
        //   regPrev(1) = idx(1)
        //  ...
        //
        //  endDistinctTest:
        //   stat_push(P, regChng)
        //   Next csr
        //   if !eof(csr) goto next_row;
        //
        //  end_of_scan:

        // Make sure there are enough memory cells for the regPrev array.
        expr.touchRegister(p, reg_prev + n_col_test);

        // Open a read-only cursor on the index being analyzed.
        _ = aux.addOp3(v, OP.OpenRead, i_idx_cur, @intCast(idx.tnum), @intCast(i_db));
        aux.setP4KeyInfo(p, idx);

        std.debug.assert(reg_temp2 == reg_stat + 4);
        _ = aux.addOp2(v, OP.Integer, db.n_analysis_limit, reg_temp2);

        // Arguments to stat_init(): the number of columns in the index
        // including the rowid (or for a WITHOUT ROWID table, the number of
        // PK columns), the number of columns in the key without the
        // rowid/pk, and the estimated number of rows in the index.
        _ = aux.addOp2(v, OP.Integer, n_col, reg_stat + 1);
        std.debug.assert(reg_rowid == reg_stat + 2);
        _ = aux.addOp2(v, OP.Integer, idx.n_key_col, reg_rowid);
        _ = aux.addOp3(v, OP.Count, i_idx_cur, reg_temp, @intFromBool(db.optDisabled(opt_stat4)));
        _ = aux.addFunctionCall(p, 0, reg_stat + 1, reg_stat, 4, &stat_init_funcdef, 0);
        var addr_goto_end = aux.addOp1(v, OP.Rewind, i_idx_cur);

        _ = aux.addOp2(v, OP.Integer, 0, reg_chng);
        var addr_next_row = aux.currentAddr(v);

        if (n_col_test > 0) {
            const end_distinct_test = aux.makeLabel(p);
            const goto_chng = try p.arena.alloc(i32, @intCast(n_col_test));

            //  next_row:
            //   regChng = 0
            //   if( idx(0) != regPrev(0) ) goto chng_addr_0
            //   regChng = 1
            //   if( idx(1) != regPrev(1) ) goto chng_addr_1
            //   ...
            //   regChng = N
            //   goto endDistinctTest
            _ = aux.addOp0(v, OP.Goto);
            addr_next_row = aux.currentAddr(v);
            if (n_col_test == 1 and idx.n_key_col == 1 and idx.isUnique()) {
                // For a single-column UNIQUE index, once a non-NULL row is
                // found all the rest are distinct: skip the tests.
                _ = aux.addOp2(v, OP.NotNull, reg_prev, end_distinct_test);
            }
            for (goto_chng, 0..) |*g, ii| {
                const i: i32 = @intCast(ii);
                const cs = coll.locateCollSeq(p, idx.coll[ii]);
                _ = aux.addOp2(v, OP.Integer, i, reg_chng);
                _ = aux.addOp3(v, OP.Column, i_idx_cur, i, reg_temp);
                g.* = aux.addOp4(v, OP.Ne, reg_temp, 0, reg_prev + i, if (cs) |c| .{ .collseq = c } else .notused);
                aux.changeP5(v, vi.SQLITE_NULLEQ);
            }
            _ = aux.addOp2(v, OP.Integer, n_col_test, reg_chng);
            _ = aux.goto_(v, end_distinct_test);

            //  chng_addr_0:
            //   regPrev(0) = idx(0)
            //  chng_addr_1:
            //   regPrev(1) = idx(1)
            //  ...
            aux.jumpHere(v, addr_next_row - 1);
            for (goto_chng, 0..) |g, ii| {
                const i: i32 = @intCast(ii);
                aux.jumpHere(v, g);
                _ = aux.addOp3(v, OP.Column, i_idx_cur, i, reg_prev + i);
            }
            aux.resolveLabel(v, end_distinct_test);
        }

        //  chng_addr_N:
        //   stat_push(P, regChng)
        //   Next csr
        //   if !eof(csr) goto next_row;
        std.debug.assert(reg_chng == reg_stat + 1);
        _ = aux.addFunctionCall(p, 1, reg_stat, reg_temp, 2, &stat_push_funcdef, 0);
        if (db.n_analysis_limit != 0) {
            const j1 = aux.addOp1(v, OP.IsNull, reg_temp);
            const j2 = aux.addOp1(v, OP.If, reg_temp);
            const j3 = aux.addOp4Int(v, OP.SeekGT, i_idx_cur, 0, reg_prev, 1);
            aux.jumpHere(v, j1);
            _ = aux.addOp2(v, OP.Next, i_idx_cur, addr_next_row);
            aux.jumpHere(v, j2);
            aux.jumpHere(v, j3);
        } else {
            _ = aux.addOp2(v, OP.Next, i_idx_cur, addr_next_row);
        }

        // Add the entry to the stat1 table.
        if (idx.part_idx_where != null) {
            // Partial indexes might get a zero-entry in sqlite_stat1. But
            // an empty table is omitted from sqlite_stat1.
            aux.jumpHere(v, addr_goto_end);
            addr_goto_end = 0;
        }
        callStatGet(p, reg_stat, reg_stat1);
        _ = aux.addOp4Str(v, OP.MakeRecord, reg_tabname, 3, reg_temp, "BBB");
        _ = aux.addOp2(v, OP.NewRowid, i_stat_cur, reg_new_rowid);
        _ = aux.addOp3(v, OP.Insert, i_stat_cur, reg_temp, reg_new_rowid);
        aux.changeP5(v, OPFLAG.APPEND);

        // End of analysis.
        if (addr_goto_end != 0) aux.jumpHere(v, addr_goto_end);
    }

    // A single sqlite_stat1 entry with NULL as the index name and the row
    // count as the content.
    if (only_idx == null and need_table_cnt) {
        _ = aux.addOp2(v, OP.Count, i_tab_cur, reg_stat1);
        const j_zero_rows = aux.addOp1(v, OP.IfNot, reg_stat1);
        _ = aux.addOp2(v, OP.Null, 0, reg_idxname);
        _ = aux.addOp4Str(v, OP.MakeRecord, reg_tabname, 3, reg_temp, "BBB");
        _ = aux.addOp2(v, OP.NewRowid, i_stat_cur, reg_new_rowid);
        _ = aux.addOp3(v, OP.Insert, i_stat_cur, reg_temp, reg_new_rowid);
        aux.changeP5(v, OPFLAG.APPEND);
        aux.jumpHere(v, j_zero_rows);
    }
}

/// Port of loadAnalysis(): code the reload of the statistics of `i_db`
/// into the schema.
fn loadAnalysis(p: *Parse, i_db: usize) void {
    const v = build.getVdbe(p) orelse return;
    _ = aux.addOp1(v, OP.LoadAnalysis, @intCast(i_db));
}

/// Port of analyzeDatabase(): code the analysis of every table of `i_db`.
fn analyzeDatabase(p: *Parse, i_db: usize) Oom!void {
    const db = p.db;
    build.beginWriteOperation(p, false, i_db);
    const i_stat_cur = p.n_tab;
    p.n_tab += 3;
    openStatTable(p, i_db, i_stat_cur, null, "");
    const i_mem = p.n_mem + 1;
    const i_tab = p.n_tab;
    var it = db.dbs.items[i_db].schema.tbl_order.iterator();
    while (it.next()) |t| try analyzeOneTable(p, t, null, i_stat_cur, i_mem, i_tab);
    loadAnalysis(p, i_db);
}

/// Port of analyzeTable(): code the analysis of table `t`, or of its
/// index `only_idx` if not null.
fn analyzeTable(p: *Parse, t: *Table, only_idx: ?*Index) Oom!void {
    const i_db: usize = @intCast(prepare.schemaToIndex(p.db, t.schema));
    build.beginWriteOperation(p, false, i_db);
    const i_stat_cur = p.n_tab;
    p.n_tab += 3;
    if (only_idx) |ix| {
        openStatTable(p, i_db, i_stat_cur, ix.name, "idx");
    } else {
        openStatTable(p, i_db, i_stat_cur, t.name, "tbl");
    }
    try analyzeOneTable(p, t, only_idx, i_stat_cur, p.n_mem + 1, p.n_tab);
    loadAnalysis(p, i_db);
}

/// xqlite: code the analysis of several tables in one statement (MariaDB's
/// ANALYZE TABLE t, u), as analyzeTable() codes one: per database, the
/// rows about each table are deleted and sqlite_stat1 is created (at
/// most once) and opened once, as in analyzeDatabase(); then one
/// OP_Expire at the end, which would expire the running program if it
/// came before the next table's analysis.
pub fn analyzeTables(p: *Parse, tables: []const *Table) void {
    analyzeTablesImpl(p, tables) catch build.oomFault(p);
}

fn analyzeTablesImpl(p: *Parse, tables: []const *Table) Oom!void {
    const db = p.db;
    for (tables, 0..) |first, i| {
        const i_db: usize = @intCast(prepare.schemaToIndex(db, first.schema));
        // Each database once, at its first table.
        const seen = for (tables[0..i]) |t| {
            if (t.schema == first.schema) break true;
        } else false;
        if (seen) continue;
        build.beginWriteOperation(p, false, i_db);
        const pdb = &db.dbs.items[i_db];
        for (tables[i + 1 ..]) |t| {
            if (t.schema != first.schema) continue;
            for ([_][]const u8{ "sqlite_stat1", "sqlite_stat4", "sqlite_stat3" }) |name| {
                if (build.findTable(db, name, pdb.name) == null) continue;
                build.nestedParse(p, "DELETE FROM %Q.%s WHERE tbl=%Q", &.{ .{ .str = pdb.name }, .{ .str = name }, .{ .str = t.name } });
            }
        }
        const i_stat_cur = p.n_tab;
        p.n_tab += 3;
        openStatTable(p, i_db, i_stat_cur, first.name, "tbl");
        const i_mem = p.n_mem + 1;
        const i_tab = p.n_tab;
        for (tables[i..]) |t| {
            if (t.schema == first.schema) try analyzeOneTable(p, t, null, i_stat_cur, i_mem, i_tab);
        }
        loadAnalysis(p, i_db);
    }
    expireAll(p);
}

/// Port of sqlite3Analyze(): the ANALYZE command.
///
///   ANALYZE                            -- 1
///   ANALYZE  <database>                -- 2
///   ANALYZE  ?<database>.?<tablename>  -- 3
///
/// Form 1 analyzes all indices of all attached databases but TEMP, form 2
/// those of the database named, form 3 those of the table named, or the
/// index named.
pub fn analyze(p: *Parse, name1: ?Token, name2: ?Token) void {
    analyzeImpl(p, name1, name2) catch build.oomFault(p);
}

fn analyzeImpl(p: *Parse, name1_opt: ?Token, name2_opt: ?Token) Oom!void {
    const db = p.db;
    if (p.syntax_only) return;
    // Read the schema. On error, the message is in `p`.
    prepare.readSchema(p) catch return;

    if (name1_opt) |name1| {
        const name2 = name2_opt.?;
        if (name2.n == 0) if (build.findDb(p, name1)) |i_db| {
            // Form 2: analyze the schema named as the argument.
            try analyzeDatabase(p, i_db);
            return expireAll(p);
        };
        // Form 3: analyze the table or index named as an argument.
        var table_name: *const Token = undefined;
        if (build.twoPartName(p, &name1, &name2, &table_name)) |i_db| {
            const zdb: ?[]const u8 = if (name2.n > 0) db.dbs.items[i_db].name else null;
            if (try build.nameFromToken(p.arena, table_name.*)) |z| {
                if (build.findIndex(db, z, zdb)) |idx| {
                    try analyzeTable(p, idx.table, idx);
                } else if (build.locateTable(p, 0, z, zdb)) |t| {
                    try analyzeTable(p, t, null);
                }
            }
        }
    } else {
        // Form 1: analyze everything but the TEMP database.
        for (0..db.dbs.items.len) |i| {
            if (i == 1) continue;
            try analyzeDatabase(p, i);
        }
    }
    expireAll(p);
}

/// The end of sqlite3Analyze(): unless run by OP_SqlExec, expire the
/// prepared statements, whose plans may change with the statistics.
fn expireAll(p: *Parse) void {
    if (p.db.n_sql_exec == 0) if (build.getVdbe(p)) |v| {
        _ = aux.addOp0(v, OP.Expire);
    };
}

/// PRAGMA [schema.]optimize[(MASK)] (the PragTyp_OPTIMIZE case of
/// sqlite3Pragma()): code an ANALYZE of each table that might benefit.
/// `i_db_arg` is the database named, or 0 with `all_dbs`. `right` is the
/// MASK argument.
///
/// MASK (default 0xfffe):
///   0x00001  debugging: return the ANALYZE statements instead of running
///            them
///   0x00002  run ANALYZE on tables that might benefit
///   0x00010  limit each ANALYZE to SQLITE_DEFAULT_OPTIMIZE_LIMIT rows
///            (or the lower PRAGMA analysis_limit)
///   0x10000  check tables for a 10-fold size change even if they were
///            not queried by the connection
///
/// A table is analyzed if it is an ordinary table not named "sqlite_*"
/// and either some index of it lacks statistics, or (it was queried with
/// statistics by this connection, or 0x10000 is set) and its size changed
/// 10-fold since its last analysis.
pub fn optimize(p: *Parse, v: *Vdbe, i_db_arg: usize, all_dbs: bool, right: ?[]const u8) Oom!void {
    const db = p.db;
    var op_mask: u32 = undefined;
    if (right) |z| {
        op_mask = @bitCast(util.getInt32(z) orelse 0);
        if (op_mask & 0x02 == 0) return;
    } else {
        op_mask = 0xfffe;
    }
    var n_limit: i32 = undefined; // Analysis limit to use
    if (op_mask & 0x10 == 0) {
        n_limit = 0;
    } else if (db.n_analysis_limit > 0 and db.n_analysis_limit < default_optimize_limit) {
        n_limit = 0;
    } else {
        n_limit = default_optimize_limit;
    }
    const i_tab_cur = p.n_tab; // Cursor for a table whose size needs checking
    p.n_tab += 1;
    var n_check: i32 = 0; // Number of tables to be optimized
    var n_btree: i32 = 0; // Number of btrees to scan
    var i_db = i_db_arg;
    const i_db_last = if (all_dbs) db.dbs.items.len - 1 else i_db;
    while (i_db <= i_db_last) : (i_db += 1) {
        if (i_db == 1) continue;
        build.codeVerifySchema(p, i_db);
        var it = db.dbs.items[i_db].schema.tbl_order.iterator();
        while (it.next()) |t| {
            // This only works for ordinary tables; system tables are not
            // scanned.
            if (!t.isOrdinary()) continue;
            if (t.name.len >= 7 and std.ascii.eqlIgnoreCase(t.name[0..7], "sqlite_")) continue;

            // The size of the table as last recorded in sqlite_stat1, or
            // -1 if any index is unanalyzed.
            var sz_threshold: LogEst = t.n_row_log_est;
            var n_index: i32 = 0;
            var idx_opt = t.index;
            while (idx_opt) |idx| : (idx_opt = idx.next) {
                n_index += 1;
                if (!idx.has_stat1) sz_threshold = -1;
            }

            // Skip a table not used in a way that would benefit from
            // statistics during this session, unless 0x10000 is set or it
            // has unanalyzed indexes.
            if (t.tab_flags.MaybeReanalyze) {
                // Check for size change if stat1 has been used for a query.
            } else if (op_mask & 0x10000 != 0) {
                // Check for size change if 0x10000 is set.
            } else if (t.index != null and sz_threshold < 0) {
                // Do analysis if unanalyzed indexes exist.
            } else {
                continue;
            }

            n_check += 1;
            if (n_check == 2) {
                // If ANALYZE might be invoked two or more times, hold a
                // write transaction for efficiency.
                build.beginWriteOperation(p, false, i_db);
            }
            n_btree += n_index + 1;

            // Reanalyze if the table is 10 times larger or smaller than at
            // the last analysis; unconditionally if there are unanalyzed
            // indexes.
            insert.openTable(p, i_tab_cur, i_db, t, OP.OpenRead);
            const skip: i32 = @intCast(op_mask & 1);
            if (sz_threshold >= 0) {
                const i_range: LogEst = 33; // 10x size change
                _ = aux.addOp4Int(v, OP.IfSizeBetween, i_tab_cur, aux.currentAddr(v) + 2 + skip, if (sz_threshold >= i_range) sz_threshold - i_range else -1, sz_threshold + i_range);
            } else {
                _ = aux.addOp2(v, OP.Rewind, i_tab_cur, aux.currentAddr(v) + 2 + skip);
            }
            const sub_sql = try build.mprintf(p, "ANALYZE \"%w\".\"%w\"", &.{ .{ .str = db.dbs.items[i_db].name }, .{ .str = t.name } });
            if (op_mask & 0x01 != 0) {
                const r1 = expr.getTempReg(p);
                _ = aux.addOp4Str(v, OP.String8, 0, r1, 0, sub_sql);
                _ = aux.addOp2(v, OP.ResultRow, r1, 1);
            } else {
                _ = aux.addOp4Str(v, OP.SqlExec, if (n_limit != 0) 0x02 else 0, n_limit, 0, sub_sql);
            }
        }
    }
    _ = aux.addOp0(v, OP.Expire);

    // In a schema with a large number of tables and indexes, scale back
    // the analysis_limit to avoid excess run-time in the worst case.
    if (!db.malloc_failed and n_limit > 0 and n_btree > 100) {
        n_limit = @max(@divTrunc(100 * n_limit, n_btree), 100);
        for (v.ops.items) |*op| {
            if (op.opcode == OP.SqlExec) op.p2 = n_limit;
        }
    }
}

/// Port of decodeIntArray() (without STAT4): the first aLog.len integers
/// of the space-separated list `z` into `a_log` as LogEst, then the
/// "unordered", "sz=N" and "noskipscan" keywords into `idx`.
fn decodeIntArray(z_arg: []const u8, a_log: []LogEst, idx: *Index) void {
    var z = z_arg;
    var i: usize = 0;
    while (z.len > 0 and i < a_log.len) : (i += 1) {
        var v: u64 = 0;
        while (z.len > 0 and z[0] >= '0' and z[0] <= '9') : (z = z[1..]) v = v *% 10 +% (z[0] - '0');
        a_log[i] = util.logEst(v);
        if (z.len > 0 and z[0] == ' ') z = z[1..];
    }
    idx.unordered = false;
    idx.no_skip_scan = false;
    while (z.len > 0) {
        if (std.mem.startsWith(u8, z, "unordered")) {
            idx.unordered = true;
        } else if (std.mem.startsWith(u8, z, "sz=") and z.len > 3 and z[3] >= '0' and z[3] <= '9') {
            const sz = util.getInt32(z[3..]) orelse 0;
            idx.sz_idx_row = util.logEst(@intCast(@max(sz, 2)));
        } else if (std.mem.startsWith(u8, z, "noskipscan")) {
            idx.no_skip_scan = true;
        }
        while (z.len > 0 and z[0] != ' ') z = z[1..];
        while (z.len > 0 and z[0] == ' ') z = z[1..];
    }
}

const LoadInfo = struct {
    db: *int.Sqlite3,
    database: []const u8,
};

/// Port of analysisLoader(): one row (tbl, idx, stat) of sqlite_stat1.
fn analysisLoader(info: *LoadInfo, values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
    if (values.len < 3) return false;
    const tbl = std.mem.span(values[0] orelse return false);
    const stat = std.mem.span(values[2] orelse return false);
    const t = build.findTable(info.db, tbl, info.database) orelse return false;
    const idx: ?*Index = if (values[1]) |iname| blk: {
        const name = std.mem.span(iname);
        if (std.ascii.eqlIgnoreCase(tbl, name)) break :blk build.primaryKeyIndex(t);
        break :blk build.findIndex(info.db, name, info.database);
    } else null;
    if (idx) |ix| {
        ix.unordered = false;
        decodeIntArray(stat, ix.ai_row_log_est[0 .. @as(usize, ix.n_key_col) + 1], ix);
        ix.has_stat1 = true;
        if (ix.part_idx_where == null) {
            t.n_row_log_est = ix.ai_row_log_est[0];
            t.tab_flags.HasStat1 = true;
        }
    } else {
        var fake: Index = .{ .name = undefined, .table = t, .sz_idx_row = t.sz_tab_row };
        decodeIntArray(stat, (&t.n_row_log_est)[0..1], &fake);
        t.sz_tab_row = fake.sz_idx_row;
        t.tab_flags.HasStat1 = true;
    }
    return false;
}

/// Port of sqlite3AnalysisLoad(): read sqlite_stat1 of database `i_db`
/// into the row estimates of its tables and indexes, and give the
/// default estimates to indexes without statistics.
pub fn analysisLoad(db: *int.Sqlite3, i_db: usize) i32 {
    const schema = db.dbs.items[i_db].schema;
    var rc: i32 = int.RC.OK;

    // Clear any prior statistics.
    var tit = schema.tbl_hash.valueIterator();
    while (tit.next()) |t| t.*.tab_flags.HasStat1 = false;
    var iit = schema.idx_hash.valueIterator();
    while (iit.next()) |ix| ix.*.has_stat1 = false;

    // Load new statistics out of the sqlite_stat1 table.
    var info: LoadInfo = .{ .db = db, .database = db.dbs.items[i_db].name };
    if (build.findTable(db, "sqlite_stat1", info.database)) |stat1| if (stat1.isOrdinary()) {
        const sql = printf.mprintf(db.gpa, "SELECT tbl,idx,stat FROM %Q.sqlite_stat1", &.{.{ .str = info.database }}) catch {
            db.oomFault();
            return int.RC.NOMEM;
        };
        defer db.gpa.free(sql);
        // xqlite: SQLite text, whatever the dialect.
        const dialect = @import("../dialect/dialect.zig");
        const saved_lang = dialect.swapLang(db, .sqlite);
        rc = legacy.execWith(db, sql, &info, analysisLoader, null);
        _ = dialect.swapLang(db, saved_lang);
    };

    // Set appropriate defaults on all indexes not in sqlite_stat1.
    iit = schema.idx_hash.valueIterator();
    while (iit.next()) |ix| if (!ix.*.has_stat1) build.defaultRowEst(ix.*);

    if (rc == int.RC.NOMEM) db.oomFault();
    return rc;
}
