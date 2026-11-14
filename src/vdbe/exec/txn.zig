//! Opcodes of transactions and the schema (vdbe.c): OP_AutoCommit,
//! OP_Savepoint, OP_Transaction and the cookies; creating, clearing and
//! dropping b-trees and rereading the schema; OP_IntegrityCk; and the
//! database files (journal mode, checkpoints, vacuum, page counts).

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const int = @import("../../sql/sqlite_int.zig");
const main_mod = @import("../../sql/main.zig");
const btree = @import("xqlite_storage").btree;
const vtab_mod = @import("../../sql/vtab.zig");
const cast = @import("xqlite_base").cast;

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const OpFor = vi.OpFor;
const MEM = vi.MEM;
const ENC = vi.ENC;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;
const OE = int.OE;

/// The functions that run several opcodes, and what the run loop inlines
/// (see `modules` in exec.zig).
pub const handlers = .{};

// ============================================================ transactions

pub fn opAutoCommit(e: *Exec, op: *OpFor(.AutoCommit)) Error!Flow {
    const v = e.v;
    const db = e.db;
    const desired = op.p1 != 0;
    const rollback = op.p2 != 0;
    // xqlite: P3, a COMMIT or ROLLBACK AND CHAIN of PostgreSQL's dialect
    // (never SQLite's): the next transaction begins at once.
    const chain = op.p3 != 0;
    if (desired != db.auto_commit) {
        if (rollback) {
            main_mod.rollbackAll(db, error.AbortRollback);
            db.auto_commit = true;
        } else if (desired and db.n_vdbe_write > 0) {
            aux.vdbeError(v, "cannot commit transaction - SQL statements in progress", .{});
            return error.Busy;
        } else {
            aux.checkFkDeferred(v) catch |err| return fkReturn(e, err);
            db.auto_commit = desired;
        }
        aux.halt(v) catch {
            v.pc = @intCast(e.pc);
            db.auto_commit = !desired;
            v.rc = RC.BUSY;
            e.rc = RC.BUSY;
            return .ret;
        };
        main_mod.closeSavepoints(db);
        if (chain and v.rc == RC.OK) db.auto_commit = false;
        e.rc = if (v.rc == RC.OK) RC.DONE else RC.ERROR;
        return .ret;
    }
    if (chain) {
        aux.vdbeErrorState(v, .of("25P01"), "{s} AND CHAIN can only be used in transaction blocks", .{if (rollback) "ROLLBACK" else "COMMIT"});
        return error.Error;
    }
    // active_sql_transaction, no_active_sql_transaction.
    aux.vdbeErrorState(v, if (!desired) .of("25001") else .of("25P01"), "{s}", .{if (!desired)
        "cannot start a transaction within a transaction"
    else if (rollback)
        "cannot rollback - no transaction is active"
    else
        "cannot commit - no transaction is active"});
    return error.Error;
}

/// A deferred foreign key constraint failed at a commit: unlike other
/// errors, it leaves the run with its code (goto vdbe_return), so that
/// the transaction stays open.
fn fkReturn(e: *Exec, err: aux.FkError) Flow {
    e.rc = int.resultCode(err, e.v.rc);
    return .ret;
}

/// Port of OP_Savepoint: open (P1 SAVEPOINT_BEGIN), release or roll
/// back to the savepoint named by P4.
pub fn opSavepoint(e: *Exec, op: *OpFor(.Savepoint)) Error!Flow {
    const v = e.v;
    const db = e.db;
    const p1: aux.SAVEPOINT = @fromBackingInt(@intCast(op.p1));
    const name: []const u8 = std.mem.span(op.p4As(.z));
    std.debug.assert(db.savepoint == null or !db.auto_commit);
    std.debug.assert(db.savepoint != null or !db.is_transaction_savepoint);
    if (p1 == .BEGIN) {
        if (db.n_vdbe_write > 0) {
            // Not with active write statements (open blob handles).
            aux.vdbeError(v, "cannot open savepoint - SQL statements in progress", .{});
            return error.Busy;
        }
        // Fine for a transaction savepoint too: then db.a_vtrans is
        // empty.
        std.debug.assert(!db.auto_commit or db.n_vtrans == 0);
        try e.check(vtab_mod.savepoint(db, .BEGIN, db.n_statement + db.n_savepoint));
        const sp = try db.gpa.create(int.Savepoint);
        errdefer db.gpa.destroy(sp);
        sp.* = .{
            .name = try db.gpa.dupeSentinel(u8, name, 0),
            .n_deferred_cons = db.n_deferred_cons,
            .n_deferred_imm_cons = db.n_deferred_imm_cons,
            .next = db.savepoint,
        };
        // Outside a transaction it starts one: a "transaction
        // savepoint".
        if (db.auto_commit) {
            db.auto_commit = false;
            db.is_transaction_savepoint = true;
        } else {
            db.n_savepoint += 1;
        }
        db.savepoint = sp;
    } else {
        // Find the named savepoint.
        var i_savepoint: i32 = 0;
        var it = db.savepoint;
        while (it) |sp| : (it = sp.next) {
            if (std.ascii.eqlIgnoreCase(sp.name, name)) break;
            i_savepoint += 1;
        }
        const sp = it orelse {
            aux.vdbeErrorState(v, .of("3B001"), "no such savepoint: {s}", .{name});
            return error.Error;
        };
        if (db.n_vdbe_write > 0 and p1 == .RELEASE) {
            aux.vdbeError(v, "cannot release savepoint - SQL statements in progress", .{});
            return error.Busy;
        }
        // Releasing the transaction savepoint commits.
        const is_transaction = sp.next == null and db.is_transaction_savepoint;
        var i_sp_vtab: i32 = i_savepoint;
        if (is_transaction and p1 == .RELEASE) {
            aux.checkFkDeferred(v) catch |err| return fkReturn(e, err);
            db.auto_commit = true;
            aux.halt(v) catch {
                v.pc = @intCast(e.pc);
                db.auto_commit = false;
                v.rc = RC.BUSY;
                e.rc = RC.BUSY;
                return .ret;
            };
            if (v.rc != RC.OK) {
                db.auto_commit = false;
                return e.abort(v.rc);
            }
            db.is_transaction_savepoint = false;
        } else {
            i_savepoint = db.n_savepoint - i_savepoint - 1;
            i_sp_vtab = i_savepoint;
            var is_schema_change = false;
            if (p1 == .ROLLBACK) {
                is_schema_change = db.m_db_flags.SchemaChange;
                for (db.dbs.items) |d| {
                    const bt = d.bt orelse continue;
                    try bt.tripAllCursors(error.AbortRollback, !is_schema_change);
                }
            }
            for (db.dbs.items) |d| {
                const bt = d.bt orelse continue;
                try bt.savepoint(if (p1 == .RELEASE) .release else .rollback, i_savepoint);
            }
            if (is_schema_change) {
                aux.expirePreparedStatements(db, .now);
                @import("../../sql/build.zig").resetAllSchemasOfConnection(db);
                db.m_db_flags.SchemaChange = true;
            }
            // xqlite: likewise the dialect catalog read into memory.
            if (p1 == .ROLLBACK) @import("../../catalog/meta.zig").rolledBack(db);
        }

        // Savepoints nested in this one go either way.
        while (db.savepoint != sp) {
            const tmp = db.savepoint.?;
            db.savepoint = tmp.next;
            main_mod.freeSavepoint(db, tmp);
            db.n_savepoint -= 1;
        }
        // A RELEASE drops this one too; a ROLLBACK TO keeps it open
        // and restores its count of deferred constraint violations.
        if (p1 == .RELEASE) {
            db.savepoint = sp.next;
            main_mod.freeSavepoint(db, sp);
            if (!is_transaction) db.n_savepoint -= 1;
        } else {
            db.n_deferred_cons = sp.n_deferred_cons;
            db.n_deferred_imm_cons = sp.n_deferred_imm_cons;
        }
        // xqlite: the dialects' session state of savepoints.
        @import("../../dialect/dialect.zig").savepointEnded(db, p1 == .ROLLBACK);
        if (!is_transaction or p1 == .ROLLBACK) {
            try e.check(vtab_mod.savepoint(db, p1, i_sp_vtab));
        }
    }
    if (v.e_vdbe_state == .halt) {
        e.rc = RC.DONE;
        return .ret;
    }
    return .next;
}

pub fn opTransaction(e: *Exec, op: *OpFor(.Transaction)) Error!Flow {
    const v = e.v;
    const db = e.db;
    if (op.p2 != 0 and db.flags.intersects(.{ .QueryOnly = true, .CorruptRdOnly = true })) {
        return if (db.flags.QueryOnly) error.ReadOnly else error.Corrupt;
    }
    const pdb = &db.dbs.items[@intCast(op.p1)];
    var i_meta: u32 = 0;
    if (pdb.bt) |bt| {
        const mode: btree.TransMode = switch (op.p2) {
            0 => .read,
            1 => .write,
            else => .exclusive,
        };
        bt.beginTrans(mode, @intCast(db.n_savepoint)) catch |err| {
            const rc = int.errorCode(err);
            if (rc & 0xff == RC.BUSY) {
                v.pc = @intCast(e.pc);
                v.rc = rc;
                e.rc = rc;
                return .ret;
            }
            return err;
        };
        // A statement that may fail midway inside a transaction (or
        // while other statements read) gets a statement transaction,
        // so that its changes can be undone alone.
        if (op.p2 != 0 and v.uses_stmt_journal and (!db.auto_commit or db.n_vdbe_read > 1)) {
            if (v.i_statement == 0) {
                db.n_statement += 1;
                v.i_statement = db.n_savepoint + db.n_statement;
            }
            try e.check(vtab_mod.savepoint(db, .BEGIN, v.i_statement - 1));
            try bt.beginStmt(@intCast(v.i_statement));
            v.n_stmt_def_cons = db.n_deferred_cons;
            v.n_stmt_def_imm_cons = db.n_deferred_imm_cons;
        }
        i_meta = bt.getMeta(.schema_version);
    }
    if (op.p5 != 0 and (@as(i32, @bitCast(i_meta)) != op.p3 or pdb.schema.i_generation != op.p4As(.int32))) {
        aux.vdbeError(v, "database schema has changed", .{});
        if (pdb.schema.schema_cookie != @as(i32, @bitCast(i_meta))) {
            @import("../../sql/build.zig").resetOneSchema(db, @intCast(op.p1));
        }
        v.expired = .now;
        v.change_cnt_on = false;
        return error.Schema;
    }
    return .next;
}

pub fn opReadCookie(e: *Exec, op: *OpFor(.ReadCookie)) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const meta = bt.getMeta(cast.enumFromInt(btree.Meta, op.p3));
    e.out2Prerelease(op).u = .{ .i = @as(i32, @bitCast(meta)) };
    return .next;
}

pub fn opSetCookie(e: *Exec, op: *OpFor(.SetCookie)) Error!Flow {
    const db = e.db;
    const pdb = &db.dbs.items[@intCast(op.p1)];
    const rc_err = pdb.bt.?.updateMeta(cast.enumFromInt(btree.Meta, op.p2), @bitCast(op.p3));
    if (op.p2 == @backingInt(btree.Meta.schema_version)) {
        pdb.schema.schema_cookie = op.p3 - op.p5;
        db.m_db_flags.SchemaChange = true;
    } else if (op.p2 == @backingInt(btree.Meta.file_format)) {
        pdb.schema.file_format = @intCast(op.p3);
    }
    if (op.p1 == 1) {
        aux.expirePreparedStatements(db, .now);
        e.v.expired = .no;
    }
    try rc_err;
    return .next;
}

// ================================================================= schema

pub fn opDestroy(e: *Exec, op: *OpFor(.Destroy)) Error!Flow {
    const v = e.v;
    const db = e.db;
    const out = e.out2Prerelease(op);
    out.flags = .{ .Null = true };
    if (db.n_vdbe_read > db.n_vdestroy + 1) {
        // Other statements may be reading the b-tree.
        v.error_action = OE.Abort;
        return error.Locked;
    }
    const i_db: usize = @intCast(op.p3);
    const moved = try db.dbs.items[i_db].bt.?.dropTable(@intCast(op.p1));
    out.flags = .{ .Int = true };
    out.u = .{ .i = moved };
    if (moved != 0) {
        @import("../../sql/build.zig").rootPageMoved(db, i_db, moved, @intCast(op.p1));
        e.reset_schema_on_fault = @intCast(i_db);
    }
    return .next;
}

pub fn opClear(e: *Exec, op: *OpFor(.Clear)) Error!Flow {
    const v = e.v;
    const n_change = try e.db.dbs.items[@intCast(op.p2)].bt.?.clearTable(@intCast(op.p1));
    if (op.p5.nchange) v.n_change += n_change;
    if (op.p3 != .none) e.reg(op.p3).u.i += n_change;
    return .next;
}

pub fn opCreateBtree(e: *Exec, op: *OpFor(.CreateBtree)) Error!Flow {
    const out = e.out2Prerelease(op);
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const kind: btree.TableKind = if (op.p3 == 1) .intkey else .blobkey;
    const pgno = try bt.createTable(kind);
    out.u = .{ .i = pgno };
    return .next;
}

pub fn opSqlExec(e: *Exec, op: *OpFor(.SqlExec)) Error!Flow {
    var err_msg: ?[:0]u8 = null;
    e.db.n_sql_exec += 1;
    const x_auth = e.db.auth;
    const m_trace = e.db.m_trace;
    const saved_analysis_limit = e.db.n_analysis_limit;
    if (op.p1 & 0x0001 != 0) {
        e.db.auth = null;
        e.db.m_trace = 0;
    }
    if (op.p1 & 0x0002 != 0) e.db.n_analysis_limit = op.p2;
    // xqlite: the SQL is the engine's, SQLite text in any dialect. It is
    // how a statement writes the dialect catalog (catalog.codeExec()), so
    // the catalog read into memory goes (catalog.zig). With 0x0004 it is
    // statements of the connection's dialect (catalog.codeExecDialect()),
    // whose errors keep their state, run in a savepoint (all or none: the
    // statement itself has no transaction, so that they may drop a
    // b-tree, which OP_Destroy refuses while another statement reads).
    const dialect = @import("../../dialect/dialect.zig");
    const meta = @import("../../catalog/meta.zig");
    const sql = std.mem.span(op.p4As(.z));
    meta.written(e.db);
    const saved_lang = dialect.swapLang(e.db, .sqlite);
    var state: ?int.ErrorState = null;
    // With 0x0008 (no frontend of SQLite's codes it) it is the steps of
    // a statement of the dialect (dialect.runSteps(): PostgreSQL's MERGE
    // and data-modifying WITH), run in it, in the statement's own
    // statement transaction.
    const rc = if (op.p1 & 0x0008 != 0) blk: {
        _ = dialect.swapLang(e.db, saved_lang);
        defer _ = dialect.swapLang(e.db, .sqlite);
        break :blk dialect.runSteps(saved_lang.dialect, e.db, e.v, sql, &err_msg, &state);
    } else if (op.p1 & 0x0004 != 0)
        execDialect(e.db, sql, saved_lang, &err_msg, &state)
    else
        legacy.execNoCallback(e.db, sql, &err_msg);
    _ = dialect.swapLang(e.db, saved_lang);
    meta.dropAll(e.db);
    e.db.n_sql_exec -= 1;
    e.db.auth = x_auth;
    e.db.m_trace = m_trace;
    e.db.n_analysis_limit = saved_analysis_limit;
    if (err_msg != null or rc != RC.OK) {
        aux.vdbeError(e.v, "{s}", .{err_msg orelse ""});
        if (state) |st| e.v.err_state = st;
        if (err_msg) |m| e.db.gpa.free(m);
        return e.abort(if (rc != RC.OK) rc else RC.ERROR);
    }
    return .next;
}

const legacy = @import("../../sql/legacy.zig");

/// xqlite: OP_SqlExec's 0x0004: `sql` in dialect `lang`, all or none (a
/// savepoint), and the state of its error in `state`.
fn execDialect(db: *int.Sqlite3, sql: [:0]const u8, lang: @import("../../dialect/dialect.zig").Lang, err_msg: *?[:0]u8, state: *?int.ErrorState) i32 {
    const dialect = @import("../../dialect/dialect.zig");
    var rc = legacy.execNoCallback(db, "SAVEPOINT xq_steps", err_msg);
    if (rc != RC.OK) return rc;
    _ = dialect.swapLang(db, lang);
    rc = legacy.execNoCallback(db, sql, err_msg);
    _ = dialect.swapLang(db, .sqlite);
    if (rc != RC.OK) state.* = db.err_state;
    var ignored: ?[:0]u8 = null;
    if (rc != RC.OK) _ = legacy.execNoCallback(db, "ROLLBACK TO xq_steps", &ignored);
    _ = legacy.execNoCallback(db, "RELEASE xq_steps", &ignored);
    if (ignored) |m| db.gpa.free(m);
    return rc;
}

pub fn opParseSchema(e: *Exec, op: *OpFor(.ParseSchema)) Error!Flow {
    const v = e.v;
    const db = e.db;
    const prepare = @import("../../sql/prepare.zig");
    const i_db: usize = @intCast(op.p1);
    var err_msg: ?[:0]u8 = null;
    var rc: i32 = undefined;
    if (op.p4type != .z) {
        // Reread the whole schema (after ALTER TABLE).
        schemaClear(db, i_db);
        db.m_db_flags.SchemaKnownOk = false;
        rc = prepare.initOne(db, i_db, &err_msg, op.p5);
        db.m_db_flags.SchemaChange = true;
        v.expired = .no;
    } else {
        db.init.busy = true;
        rc = prepare.parseSchemaWhere(db, i_db, std.mem.span(op.p4As(.z)), &err_msg);
        db.init.busy = false;
    }
    if (err_msg) |m| aux.setErrMsg(v, m);
    if (rc != RC.OK) {
        @import("../../sql/build.zig").resetAllSchemasOfConnection(db);
        return e.abort(rc);
    }
    return .next;
}

fn schemaClear(db: *Sqlite3, i_db: usize) void {
    @import("../../sql/build.zig").schemaClear(db, db.dbs.items[i_db].schema);
}

pub fn opLoadAnalysis(e: *Exec, op: *OpFor(.LoadAnalysis)) Error!Flow {
    try e.check(@import("../../sql/analyze.zig").analysisLoad(e.db, @intCast(op.p1)));
    return .next;
}

pub fn opDropTable(e: *Exec, op: *OpFor(.DropTable)) Flow {
    @import("../../sql/build.zig").unlinkAndDeleteTable(e.db, @intCast(op.p1), std.mem.span(op.p4As(.z)));
    return .next;
}

pub fn opDropIndex(e: *Exec, op: *OpFor(.DropIndex)) Flow {
    @import("../../sql/build.zig").unlinkAndDeleteIndex(e.db, @intCast(op.p1), std.mem.span(op.p4As(.z)));
    return .next;
}

pub fn opDropTrigger(e: *Exec, op: *OpFor(.DropTrigger)) Flow {
    @import("../../sql/trigger.zig").unlinkAndDeleteTrigger(e.db, @intCast(op.p1), std.mem.span(op.p4As(.z)));
    return .next;
}

pub fn opIntegrityCk(e: *Exec, op: *OpFor(.IntegrityCk)) Error!Flow {
    const db = e.db;
    const n_root: usize = @intCast(op.p2);
    const roots = op.p4IntArray();
    std.debug.assert(roots.len == n_root);
    const n_err_reg = e.reg(op.p1);
    const in1 = e.reg(op.p1.at(1));
    const bt = db.dbs.items[op.p5].bt.?;
    var report = try bt.integrityCheck(db.gpa, roots, @intCast(n_err_reg.u.i + 1));
    defer report.deinit(db.gpa);
    for (report.row_counts, e.regRange(op.p3, report.row_counts.len)) |n, *m| mem.setInt64(m, n);
    mem.setNull(in1);
    if (report.n_err != 0) {
        n_err_reg.u.i -= @as(i64, report.n_err) - 1;
        try mem.setStr(in1, report.message, ENC.UTF8, .transient);
    }
    try mem.changeEncoding(in1, e.encoding);
    return .next_check;
}

// ========================================================= database files

/// OP_Checkpoint: checkpoint database P1 (MAX_DB: all of them) in
/// mode P2, writing to registers P3..P3+2 the busy flag, the WAL size
/// and the frames checkpointed (-1 if not in WAL mode).
/// OP_Vacuum: vacuum database P1, or write a vacuumed copy of it to the
/// file named in register P2 if P2 is not 0 (VACUUM INTO).
pub fn opVacuum(e: *Exec, op: *OpFor(.Vacuum)) Error!Flow {
    std.debug.assert(!e.v.read_only);
    const out: ?*vi.Mem = if (op.p2 != .none) e.reg(op.p2) else null;
    const rc = @import("../../sql/vacuum.zig").runVacuum(e.v, e.db, @intCast(op.p1), out);
    if (rc != RC.OK) return e.abort(rc);
    return .next;
}

pub fn opCheckpoint(e: *Exec, op: *OpFor(.Checkpoint)) Error!Flow {
    var res = [3]i32{ 0, -1, -1 };
    main_mod.checkpoint(e.db, op.p1, @fromBackingInt(@intCast(op.p2)), &res[1], &res[2]) catch |err| switch (err) {
        error.Busy => res[0] = 1,
        else => |other| return other,
    };
    for (res, e.regRange(op.p3, res.len)) |x, *m| mem.setInt64(m, x);
    return .next;
}

/// OP_JournalMode: set the journal mode of database P1 to P3 (-1
/// only queries), storing the mode in effect in register P2. Moving
/// into or out of WAL mode also rewrites the file format versions in
/// the header, in a rollback-journal transaction.
pub fn opJournalMode(e: *Exec, op: *OpFor(.JournalMode)) Error!Flow {
    const db = e.db;
    const out = e.out2Prerelease(op);
    const bt = db.dbs.items[@intCast(op.p1)].bt.?;
    const pager = bt.pager;
    const old = pager.journal_mode;
    var new: @TypeOf(old) = if (op.p3 < 0) old else cast.enumFromInt(@TypeOf(old), op.p3);
    if (!pager.okToChangeJournalMode()) new = old;

    // No WAL for a temporary or in-memory database or without shared
    // memory (sqlite3PagerFilename(pPager, 1)).
    if (new == .wal and (pager.filename().len == 0 or !pager.walSupported())) new = old;

    var failure: ?Error = null;
    if (new != old and (old == .wal or new == .wal)) {
        if (!db.auto_commit or db.n_vdbe_read > 1) {
            aux.vdbeError(e.v, "cannot change {s} wal mode from within a transaction", .{
                if (new == .wal) "into" else "out of",
            });
            return error.Error;
        }
        if (old == .wal) {
            // Checkpoint and delete the WAL; the EXCLUSIVE lock this
            // takes may still be held afterwards.
            if (pager.closeWal(main_mod.pagerConn(db))) |_| {
                _ = pager.setJournalMode(new);
            } else |err| failure = err;
        } else if (old == .memory) {
            // No direct way from MEMORY to WAL: go through OFF.
            _ = pager.setJournalMode(.off);
        }
        // Whatever the mode, this transaction uses a rollback journal.
        std.debug.assert(bt.txnState() != .write);
        if (failure == null) {
            bt.setVersion(if (new == .wal) 2 else 1) catch |err| {
                failure = err;
            };
        }
    }

    if (failure != null) new = old;
    const name = pager.setJournalMode(new).name();
    out.flags = .{ .Str = true, .Static = true, .Term = true };
    out.z = @constCast(name.ptr);
    out.n = @intCast(name.len);
    out.enc = ENC.UTF8;
    try mem.changeEncoding(out, e.encoding);
    if (failure) |err| return err;
    return .next;
}

pub fn opIncrVacuum(e: *Exec, op: *OpFor(.IncrVacuum)) Error!Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const more = try bt.incrVacuum();
    return if (more) .next else .jump_p2;
}

/// Port of OP_TableLock: lock table P2 of database P1 for reading (P3 0)
/// or writing in the shared cache. Read locks are skipped with PRAGMA
/// read_uncommitted.
pub fn opTableLock(e: *Exec, op: *OpFor(.TableLock)) Error!Flow {
    const write = op.p3 != 0;
    if (write or !e.db.flags.ReadUncommit) {
        const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
        bt.lockTable(@intCast(op.p2), write) catch |err| {
            if (err == error.LockedSharedCache) aux.vdbeError(e.v, "database table is locked: {s}", .{std.mem.span(op.p4As(.z))});
            return err;
        };
    }
    return .next;
}

pub fn opExpire(e: *Exec, op: *OpFor(.Expire)) Flow {
    // P2 0 expires now, 1 when convenient.
    const how: vi.Expired = if (op.p2 == 0) .now else .when_convenient;
    if (op.p1 == 0) {
        aux.expirePreparedStatements(e.db, how);
    } else {
        e.v.expired = how;
    }
    return .next;
}

pub fn opPagecount(e: *Exec, op: *OpFor(.Pagecount)) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    e.out2Prerelease(op).u = .{ .i = bt.lastPage() };
    return .next;
}

pub fn opMaxPgcnt(e: *Exec, op: *OpFor(.MaxPgcnt)) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    var new_max: u32 = 0;
    if (op.p3 != 0) {
        new_max = @max(bt.lastPage(), @as(u32, @bitCast(op.p3)));
    }
    e.out2Prerelease(op).u = .{ .i = bt.maxPageCount(new_max) };
    return .next;
}
