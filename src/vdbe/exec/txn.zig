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
const btree = @import("../../btree/btree.zig");
const vtab_mod = @import("../../sql/vtab.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Op = vi.Op;
const MEM = vi.MEM;
const ENC = vi.ENC;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;
const OE = int.OE;

// ============================================================ transactions

pub fn opAutoCommit(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    const desired = op.p1 != 0;
    const rollback = op.p2 != 0;
    if (desired != db.auto_commit) {
        if (rollback) {
            main_mod.rollbackAll(db, RC.ABORT_ROLLBACK);
            db.auto_commit = true;
        } else if (desired and db.n_vdbe_write > 0) {
            aux.vdbeError(v, "cannot commit transaction - SQL statements in progress", .{});
            e.rc = RC.BUSY;
            return .abort;
        } else {
            e.rc = aux.checkFkDeferred(v);
            if (e.rc != RC.OK) return .ret;
            db.auto_commit = desired;
        }
        if (aux.halt(v) == RC.BUSY) {
            v.pc = @intCast(e.pc);
            db.auto_commit = !desired;
            v.rc = RC.BUSY;
            e.rc = RC.BUSY;
            return .ret;
        }
        main_mod.closeSavepoints(db);
        e.rc = if (v.rc == RC.OK) RC.DONE else RC.ERROR;
        return .ret;
    }
    aux.vdbeError(v, "{s}", .{if (!desired)
        "cannot start a transaction within a transaction"
    else if (rollback)
        "cannot rollback - no transaction is active"
    else
        "cannot commit - no transaction is active"});
    e.rc = RC.ERROR;
    return .abort;
}

/// Port of OP_Savepoint: open (P1 SAVEPOINT_BEGIN), release or roll
/// back to the savepoint named by P4.
pub fn opSavepoint(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    const p1 = op.p1;
    const name: []const u8 = std.mem.span(op.p4.z);
    std.debug.assert(db.savepoint == null or !db.auto_commit);
    std.debug.assert(db.savepoint != null or !db.is_transaction_savepoint);
    if (p1 == aux.SAVEPOINT_BEGIN) {
        if (db.n_vdbe_write > 0) {
            // Not with active write statements (open blob handles).
            aux.vdbeError(v, "cannot open savepoint - SQL statements in progress", .{});
            e.rc = RC.BUSY;
            return .abort;
        }
        // Fine for a transaction savepoint too: then db.a_vtrans is
        // empty.
        std.debug.assert(!db.auto_commit or db.n_vtrans == 0);
        e.rc = vtab_mod.savepoint(db, aux.SAVEPOINT_BEGIN, db.n_statement + db.n_savepoint);
        if (e.rc != RC.OK) return .abort;
        const sp = db.gpa.create(int.Savepoint) catch return .no_mem;
        sp.* = .{
            .name = db.gpa.dupeSentinel(u8, name, 0) catch {
                db.gpa.destroy(sp);
                return .no_mem;
            },
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
            aux.vdbeError(v, "no such savepoint: {s}", .{name});
            e.rc = RC.ERROR;
            return .abort;
        };
        if (db.n_vdbe_write > 0 and p1 == aux.SAVEPOINT_RELEASE) {
            aux.vdbeError(v, "cannot release savepoint - SQL statements in progress", .{});
            e.rc = RC.BUSY;
            return .abort;
        }
        // Releasing the transaction savepoint commits.
        const is_transaction = sp.next == null and db.is_transaction_savepoint;
        var i_sp_vtab: i32 = i_savepoint;
        if (is_transaction and p1 == aux.SAVEPOINT_RELEASE) {
            e.rc = aux.checkFkDeferred(v);
            if (e.rc != RC.OK) return .ret;
            db.auto_commit = true;
            if (aux.halt(v) == RC.BUSY) {
                v.pc = @intCast(e.pc);
                db.auto_commit = false;
                v.rc = RC.BUSY;
                e.rc = RC.BUSY;
                return .ret;
            }
            e.rc = v.rc;
            if (e.rc != RC.OK) {
                db.auto_commit = false;
            } else {
                db.is_transaction_savepoint = false;
            }
        } else {
            i_savepoint = db.n_savepoint - i_savepoint - 1;
            i_sp_vtab = i_savepoint;
            var is_schema_change = false;
            if (p1 == aux.SAVEPOINT_ROLLBACK) {
                is_schema_change = db.m_db_flags & int.DBFLAG.SchemaChange != 0;
                for (db.dbs.items) |d| {
                    const bt = d.bt orelse continue;
                    bt.tripAllCursors(main_mod.tripError(RC.ABORT_ROLLBACK).?, !is_schema_change) catch |err| return e.fail(err);
                }
            }
            for (db.dbs.items) |d| {
                const bt = d.bt orelse continue;
                bt.savepoint(if (p1 == aux.SAVEPOINT_RELEASE) .release else .rollback, i_savepoint) catch |err| return e.fail(err);
            }
            if (is_schema_change) {
                aux.expirePreparedStatements(db, 0);
                @import("../../sql/build.zig").resetAllSchemasOfConnection(db);
                db.m_db_flags |= int.DBFLAG.SchemaChange;
            }
        }
        if (e.rc != RC.OK) return .abort;

        // Savepoints nested in this one go either way.
        while (db.savepoint != sp) {
            const tmp = db.savepoint.?;
            db.savepoint = tmp.next;
            main_mod.freeSavepoint(db, tmp);
            db.n_savepoint -= 1;
        }
        // A RELEASE drops this one too; a ROLLBACK TO keeps it open
        // and restores its count of deferred constraint violations.
        if (p1 == aux.SAVEPOINT_RELEASE) {
            db.savepoint = sp.next;
            main_mod.freeSavepoint(db, sp);
            if (!is_transaction) db.n_savepoint -= 1;
        } else {
            db.n_deferred_cons = sp.n_deferred_cons;
            db.n_deferred_imm_cons = sp.n_deferred_imm_cons;
        }
        if (!is_transaction or p1 == aux.SAVEPOINT_ROLLBACK) {
            e.rc = vtab_mod.savepoint(db, p1, i_sp_vtab);
            if (e.rc != RC.OK) return .abort;
        }
    }
    if (v.e_vdbe_state == .halt) {
        e.rc = RC.DONE;
        return .ret;
    }
    return .next;
}

pub fn opTransaction(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    if (op.p2 != 0 and db.flags & (int.DbFlag.QueryOnly | int.DbFlag.CorruptRdOnly) != 0) {
        e.rc = if (db.flags & int.DbFlag.QueryOnly != 0) RC.READONLY else RC.CORRUPT;
        return .abort;
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
            const rc = main_mod.errorCode(err);
            if (rc & 0xff == RC.BUSY) {
                v.pc = @intCast(e.pc);
                v.rc = rc;
                e.rc = rc;
                return .ret;
            }
            e.rc = rc;
            return .abort;
        };
        // A statement that may fail midway inside a transaction (or
        // while other statements read) gets a statement transaction,
        // so that its changes can be undone alone.
        if (op.p2 != 0 and v.uses_stmt_journal and (!db.auto_commit or db.n_vdbe_read > 1)) {
            if (v.i_statement == 0) {
                db.n_statement += 1;
                v.i_statement = db.n_savepoint + db.n_statement;
            }
            e.rc = vtab_mod.savepoint(db, aux.SAVEPOINT_BEGIN, v.i_statement - 1);
            if (e.rc != RC.OK) return .abort;
            bt.beginStmt(@intCast(v.i_statement)) catch |err| return e.fail(err);
            v.n_stmt_def_cons = db.n_deferred_cons;
            v.n_stmt_def_imm_cons = db.n_deferred_imm_cons;
        }
        i_meta = bt.getMeta(.schema_version);
    }
    if (op.p5 != 0 and (@as(i32, @bitCast(i_meta)) != op.p3 or pdb.schema.i_generation != op.p4.int32)) {
        aux.vdbeError(v, "database schema has changed", .{});
        if (pdb.schema.schema_cookie != @as(i32, @bitCast(i_meta))) {
            @import("../../sql/build.zig").resetOneSchema(db, @intCast(op.p1));
        }
        v.expired = 1;
        v.change_cnt_on = false;
        e.rc = RC.SCHEMA;
        return .abort;
    }
    return .next;
}

pub fn opReadCookie(e: *Exec, op: *Op) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const meta = bt.getMeta(@enumFromInt(op.p3));
    e.out2Prerelease(op).u = .{ .i = @as(i32, @bitCast(meta)) };
    return .next;
}

pub fn opSetCookie(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const pdb = &db.dbs.items[@intCast(op.p1)];
    const rc_err = pdb.bt.?.updateMeta(@enumFromInt(op.p2), @bitCast(op.p3));
    if (op.p2 == @intFromEnum(btree.Meta.schema_version)) {
        pdb.schema.schema_cookie = op.p3 - op.p5;
        db.m_db_flags |= int.DBFLAG.SchemaChange;
    } else if (op.p2 == @intFromEnum(btree.Meta.file_format)) {
        pdb.schema.file_format = @intCast(op.p3);
    }
    if (op.p1 == 1) {
        aux.expirePreparedStatements(db, 0);
        e.v.expired = 0;
    }
    rc_err catch |err| return e.fail(err);
    return .next;
}

// ================================================================= schema

pub fn opDestroy(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    const out = e.out2Prerelease(op);
    out.flags = MEM.Null;
    if (db.n_vdbe_read > db.n_vdestroy + 1) {
        // Other statements may be reading the b-tree.
        e.rc = RC.LOCKED;
        v.error_action = OE.Abort;
        return .abort;
    }
    const i_db: usize = @intCast(op.p3);
    const moved = db.dbs.items[i_db].bt.?.dropTable(@intCast(op.p1)) catch |err| return e.fail(err);
    out.flags = MEM.Int;
    out.u = .{ .i = moved };
    if (moved != 0) {
        @import("../../sql/build.zig").rootPageMoved(db, i_db, moved, @intCast(op.p1));
        e.reset_schema_on_fault = @intCast(i_db + 1);
    }
    return .next;
}

pub fn opClear(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const res = e.db.dbs.items[@intCast(op.p2)].bt.?.clearTable(@intCast(op.p1));
    const n_change = res catch 0;
    if (op.p3 != 0) {
        v.n_change += n_change;
        if (op.p3 > 0) e.reg(op.p3).u.i += n_change;
    }
    _ = res catch |err| return e.fail(err);
    return .next;
}

pub fn opCreateBtree(e: *Exec, op: *Op) Flow {
    const out = e.out2Prerelease(op);
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const kind: btree.TableKind = if (op.p3 == 1) .intkey else .blobkey;
    const pgno = bt.createTable(kind) catch |err| return e.fail(err);
    out.u = .{ .i = pgno };
    return .next;
}

pub fn opSqlExec(e: *Exec, op: *Op) Flow {
    var err_msg: ?[:0]u8 = null;
    const rc = @import("../../sql/legacy.zig").execNoCallback(e.db, std.mem.span(op.p4.z), &err_msg);
    if (err_msg != null or rc != RC.OK) {
        aux.vdbeError(e.v, "{s}", .{err_msg orelse ""});
        if (err_msg) |m| e.db.gpa.free(m);
        if (rc == RC.NOMEM) return .no_mem;
        e.rc = if (rc != RC.OK) rc else RC.ERROR;
        return .abort;
    }
    return .next;
}

pub fn opParseSchema(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    const prepare = @import("../../sql/prepare.zig");
    const i_db: usize = @intCast(op.p1);
    var err_msg: ?[:0]u8 = null;
    var rc: i32 = undefined;
    if (op.p4type != .z) {
        // Reread the whole schema (after ALTER TABLE).
        schemaClear(db, i_db);
        db.m_db_flags &= ~int.DBFLAG.SchemaKnownOk;
        rc = prepare.initOne(db, i_db, &err_msg, op.p5);
        db.m_db_flags |= int.DBFLAG.SchemaChange;
        v.expired = 0;
    } else {
        db.init.busy = true;
        rc = prepare.parseSchemaWhere(db, i_db, std.mem.span(op.p4.z), &err_msg);
        db.init.busy = false;
    }
    if (err_msg) |m| aux.setErrMsg(v, m);
    if (rc != RC.OK) {
        @import("../../sql/build.zig").resetAllSchemasOfConnection(db);
        if (rc == RC.NOMEM) return .no_mem;
        e.rc = rc;
        return .abort;
    }
    return .next;
}

fn schemaClear(db: *Sqlite3, i_db: usize) void {
    @import("../../sql/build.zig").schemaClear(db, db.dbs.items[i_db].schema);
}

pub fn opLoadAnalysis(e: *Exec, op: *Op) Flow {
    e.rc = @import("../../sql/analyze.zig").analysisLoad(e.db, @intCast(op.p1));
    return if (e.rc != RC.OK) .abort else .next;
}

pub fn opDropTable(e: *Exec, op: *Op) Flow {
    @import("../../sql/build.zig").unlinkAndDeleteTable(e.db, @intCast(op.p1), std.mem.span(op.p4.z));
    return .next;
}

pub fn opDropIndex(e: *Exec, op: *Op) Flow {
    @import("../../sql/build.zig").unlinkAndDeleteIndex(e.db, @intCast(op.p1), std.mem.span(op.p4.z));
    return .next;
}

pub fn opDropTrigger(e: *Exec, op: *Op) Flow {
    @import("../../sql/trigger.zig").unlinkAndDeleteTrigger(e.db, @intCast(op.p1), std.mem.span(op.p4.z));
    return .next;
}

pub fn opIntegrityCk(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const n_root: usize = @intCast(op.p2);
    const roots = op.p4.intarray[1..][0..n_root];
    const n_err_reg = e.reg(op.p1);
    const in1 = e.reg(op.p1 + 1);
    const bt = db.dbs.items[op.p5].bt.?;
    var report = bt.integrityCheck(db.gpa, roots, @intCast(n_err_reg.u.i + 1)) catch |err| return e.fail(err);
    defer report.deinit(db.gpa);
    for (report.row_counts, 0..) |n, i| mem.setInt64(e.reg(op.p3 + @as(i32, @intCast(i))), n);
    mem.setNull(in1);
    if (report.n_err != 0) {
        n_err_reg.u.i -= @as(i64, report.n_err) - 1;
        mem.setStr(in1, report.message, ENC.UTF8, .transient) catch return .no_mem;
    }
    return .check_interrupt;
}

// ========================================================= database files

/// OP_Checkpoint: checkpoint database P1 (MAX_DB: all of them) in
/// mode P2, writing to registers P3..P3+2 the busy flag, the WAL size
/// and the frames checkpointed (-1 if not in WAL mode).
pub fn opCheckpoint(e: *Exec, op: *Op) Flow {
    var res = [3]i32{ 0, -1, -1 };
    const rc = main_mod.checkpoint(e.db, op.p1, @enumFromInt(op.p2), &res[1], &res[2]);
    if (rc != RC.OK) {
        if (rc != RC.BUSY) {
            e.rc = rc;
            return .abort;
        }
        res[0] = 1;
    }
    for (res, 0..) |x, i| mem.setInt64(e.reg(op.p3 + @as(i32, @intCast(i))), x);
    return .next;
}

/// OP_JournalMode: set the journal mode of database P1 to P3 (-1
/// only queries), storing the mode in effect in register P2. Moving
/// into or out of WAL mode also rewrites the file format versions in
/// the header, in a rollback-journal transaction.
pub fn opJournalMode(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const out = e.out2Prerelease(op);
    const bt = db.dbs.items[@intCast(op.p1)].bt.?;
    const pager = bt.pager;
    const old = pager.journal_mode;
    var new: @TypeOf(old) = if (op.p3 < 0) old else @enumFromInt(op.p3);
    if (!pager.okToChangeJournalMode()) new = old;

    // No WAL for a temporary database or without shared memory.
    if (new == .wal and (pager.path.len == 0 or !pager.walSupported())) new = old;

    var rc: i32 = RC.OK;
    if (new != old and (old == .wal or new == .wal)) {
        if (!db.auto_commit or db.n_vdbe_read > 1) {
            aux.vdbeError(e.v, "cannot change {s} wal mode from within a transaction", .{
                if (new == .wal) "into" else "out of",
            });
            e.rc = RC.ERROR;
            return .abort;
        }
        if (old == .wal) {
            // Checkpoint and delete the WAL; the EXCLUSIVE lock this
            // takes may still be held afterwards.
            if (pager.closeWal(main_mod.pagerConn(db))) |_| {
                _ = pager.setJournalMode(new);
            } else |err| rc = main_mod.errorCode(err);
        } else if (old == .memory) {
            // No direct way from MEMORY to WAL: go through OFF.
            _ = pager.setJournalMode(.off);
        }
        // Whatever the mode, this transaction uses a rollback journal.
        std.debug.assert(bt.txnState() != .write);
        if (rc == RC.OK) {
            bt.setVersion(if (new == .wal) 2 else 1) catch |err| {
                rc = main_mod.errorCode(err);
            };
        }
    }

    if (rc != RC.OK) new = old;
    const name = pager.setJournalMode(new).name();
    out.flags = MEM.Str | MEM.Static | MEM.Term;
    out.z = @constCast(name.ptr);
    out.n = @intCast(name.len);
    out.enc = ENC.UTF8;
    if (rc != RC.OK) {
        e.rc = rc;
        return .abort;
    }
    return .next;
}

pub fn opIncrVacuum(e: *Exec, op: *Op) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    const more = bt.incrVacuum() catch |err| return e.fail(err);
    return if (more) .next else .jump_p2;
}

pub fn opExpire(e: *Exec, op: *Op) Flow {
    if (op.p1 == 0) {
        aux.expirePreparedStatements(e.db, @intCast(op.p2));
    } else {
        e.v.expired = @intCast(op.p2 + 1);
    }
    return .next;
}

pub fn opPagecount(e: *Exec, op: *Op) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    e.out2Prerelease(op).u = .{ .i = bt.lastPage() };
    return .next;
}

pub fn opMaxPgcnt(e: *Exec, op: *Op) Flow {
    const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
    var new_max: u32 = 0;
    if (op.p3 != 0) {
        new_max = @max(bt.lastPage(), @as(u32, @bitCast(op.p3)));
    }
    e.out2Prerelease(op).u = .{ .i = bt.maxPageCount(new_max) };
    return .next;
}
