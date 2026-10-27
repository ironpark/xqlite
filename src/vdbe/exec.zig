//! The bytecode interpreter (port of vdbe.c, sqlite3VdbeExec): the state
//! of a run, the loop and its one switch over the opcodes. The opcode
//! handlers are in exec/, grouped as vdbe.c orders them:
//!
//!   control.zig    jumps, subroutines, co-routines, OP_Halt, OP_Init and
//!                  trigger programs and their counters
//!   register.zig   constants, register copies, OP_ResultRow, subtypes
//!   arith.zig      arithmetic, casts, comparisons and logic
//!   record.zig     reading (OP_Column) and building (OP_MakeRecord)
//!                  records, affinities and type checks
//!   txn.zig        transactions, savepoints, the schema and the files
//!   cursor.zig     opening, positioning and stepping cursors
//!   btree_ops.zig  writing and reading rows and index entries, sorters
//!   agg.zig        function calls and aggregates
//!   vtab_ops.zig   virtual tables
//!   misc.zig       row sets, Bloom filters, unsupported opcodes
//!
//! Each handler returns a `Flow`, which stands in for the gotos of the C
//! code: `.next` continues, `.jump_p2` goes to P2, `.goto_pc` goes on
//! after the instruction the handler set `Exec.pc` to (as C handlers set
//! pOp), and the error flows end the run.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const aux = @import("aux.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const main_mod = @import("../sql/main.zig");

const control = @import("exec/control.zig");
const register = @import("exec/register.zig");
const arith = @import("exec/arith.zig");
const record = @import("exec/record.zig");
const txn = @import("exec/txn.zig");
const cursor = @import("exec/cursor.zig");
const btree_ops = @import("exec/btree_ops.zig");
const agg = @import("exec/agg.zig");
const vtab_ops = @import("exec/vtab_ops.zig");
const misc = @import("exec/misc.zig");

const Vdbe = vi.Vdbe;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const VdbeCursor = vi.VdbeCursor;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;

pub const Flow = enum {
    next,
    /// Check for an interrupt, then continue.
    check_interrupt,
    jump_p2,
    jump_p2_check_interrupt,
    /// Continue after the instruction at Exec.pc, which the handler set
    /// (possibly in another program, Exec.ops).
    goto_pc,
    goto_pc_check_interrupt,
    /// abort_due_to_error with Exec.rc set.
    abort,
    no_mem,
    too_big,
    interrupt,
    /// vdbe_return: leave with Exec.rc.
    ret,
};

/// Port of sqlite3VdbeExec(): run the program until it produces a row
/// (RC.ROW), finishes (RC.DONE) or fails (RC.ERROR and others).
pub fn exec(v: *Vdbe) i32 {
    std.debug.assert(v.e_vdbe_state == .run);
    var e: Exec = .{
        .v = v,
        .db = v.db,
        .ops = v.ops.items,
        .regs = v.mem,
        .pc = v.pc,
        .encoding = v.db.enc,
    };
    return e.run();
}

/// The state of a run that the handlers share (the locals of
/// sqlite3VdbeExec()).
pub const Exec = struct {
    v: *Vdbe,
    db: *Sqlite3,
    /// The program and registers of the current frame (aOp, aMem).
    ops: []Op,
    regs: []Mem,
    /// Address of the current instruction. A handler that changes it
    /// returns `.goto_pc`.
    pc: isize,
    rc: i32 = RC.OK,
    encoding: u8,
    /// Result of the last OP_Compare.
    i_compare: i32 = 0,
    /// Reset this schema (plus one) after an error.
    reset_schema_on_fault: u8 = 0,

    pub fn reg(e: *Exec, i: i32) *Mem {
        return &e.regs[@intCast(i)];
    }

    /// Register `i` of the main program, even inside a trigger.
    pub fn rootReg(e: *Exec, i: i32) *Mem {
        const frame = vi.rootFrame(e.v.frame orelse return e.reg(i));
        return &frame.mem[@intCast(i)];
    }

    /// Cursor `i`, which must be open.
    pub fn csr(e: *Exec, i: i32) *VdbeCursor {
        return e.v.csr[@intCast(i)].?;
    }

    /// The flow for a failure of a lower layer.
    pub fn fail(e: *Exec, err: main_mod.Error) Flow {
        e.rc = main_mod.errorCode(err);
        return .abort;
    }

    /// Port of out2Prerelease(): register P2, ready to take an integer.
    pub fn out2Prerelease(e: *Exec, op: *const Op) *Mem {
        const out = e.reg(op.p2);
        if (out.isDynamic()) mem.setNull(out);
        out.flags = MEM.Int;
        return out;
    }

    fn run(e: *Exec) i32 {
        const v = e.v;
        const db = e.db;
        if (v.rc == RC.NOMEM) return e.finish(.no_mem, 0);
        v.rc = RC.OK;
        v.i_current_time = 0;
        db.busy_handler.n_busy = 0;
        if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt, 0);
        // As in C, the address, the program and the step count are locals
        // (pOp, aOp, nVmStep) rather than memory the handlers may change:
        // the handlers see the address in e.pc and report a change with
        // .goto_pc.
        var ops = e.ops.ptr;
        var pc: usize = @intCast(e.pc);
        var n_vm_step: u64 = 0;
        while (true) {
            const op = &ops[pc];
            n_vm_step += 1;
            e.pc = @intCast(pc);
            const flow: Flow = switch (op.opcode) {
                // Jumps, subroutines, co-routines and halting.
                OP.Goto => .jump_p2_check_interrupt,
                OP.Gosub => control.opGosub(e, op),
                OP.Return => control.opReturn(e, op),
                OP.InitCoroutine => control.opInitCoroutine(e, op),
                OP.EndCoroutine => control.opEndCoroutine(e, op),
                OP.Yield => control.opYield(e, op),
                OP.HaltIfNull => control.opHaltIfNull(e, op),
                OP.Halt => control.opHalt(e, op),

                // Constants and registers.
                OP.Integer => register.opInteger(e, op),
                OP.Int64 => register.opInt64(e, op),
                OP.Real => register.opReal(e, op),
                OP.String8 => register.opString8(e, op),
                OP.String => register.opString(e, op),
                OP.BeginSubrtn, OP.Null => register.opNull(e, op),
                OP.SoftNull => register.opSoftNull(e, op),
                OP.Blob => register.opBlob(e, op),
                OP.Variable => register.opVariable(e, op),
                OP.Move => register.opMove(e, op),
                OP.Copy => register.opCopy(e, op),
                OP.SCopy => register.opSCopy(e, op),
                OP.IntCopy => register.opIntCopy(e, op),
                OP.FkCheck => register.opFkCheck(e, op),
                OP.ResultRow => register.opResultRow(e, op),

                // Arithmetic, comparisons and logic.
                OP.Concat => arith.opConcat(e, op),
                OP.Add, OP.Subtract, OP.Multiply, OP.Divide, OP.Remainder => arith.opArith(e, op),
                OP.CollSeq => arith.opCollSeq(e, op),
                OP.BitAnd, OP.BitOr, OP.ShiftLeft, OP.ShiftRight => arith.opBit(e, op),
                OP.AddImm => arith.opAddImm(e, op),
                OP.MustBeInt => arith.opMustBeInt(e, op),
                OP.RealAffinity => arith.opRealAffinity(e, op),
                OP.Cast => arith.opCast(e, op),
                OP.Eq, OP.Ne, OP.Lt, OP.Le, OP.Gt, OP.Ge => arith.opCompareJump(e, op),
                OP.ElseEq => arith.opElseEq(e, op),
                // Only marks the OP_Compare that follows (P4_INTARRAY).
                OP.Permutation => .next,
                OP.Compare => arith.opCompare(e, op),
                OP.Jump => arith.opJump(e, op),
                OP.And, OP.Or => arith.opAndOr(e, op),
                OP.IsTrue => arith.opIsTrue(e, op),
                OP.Not => arith.opNot(e, op),
                OP.BitNot => arith.opBitNot(e, op),
                OP.Once => control.opOnce(e, op),
                OP.If => arith.opIf(e, op),
                OP.IfNot => arith.opIfNot(e, op),
                OP.IsNull => arith.opIsNull(e, op),
                OP.IsType => record.opIsType(e, op),
                OP.ZeroOrNull => arith.opZeroOrNull(e, op),
                OP.NotNull => arith.opNotNull(e, op),
                OP.IfNullRow => arith.opIfNullRow(e, op),

                // Records.
                OP.Column => record.opColumn(e, op),
                OP.TypeCheck => record.opTypeCheck(e, op),
                OP.Affinity => record.opAffinity(e, op),
                OP.MakeRecord => record.opMakeRecord(e, op),
                OP.Count => btree_ops.opCount(e, op),

                // Transactions.
                OP.Savepoint => txn.opSavepoint(e, op),
                OP.AutoCommit => txn.opAutoCommit(e, op),
                OP.Transaction => txn.opTransaction(e, op),
                OP.ReadCookie => txn.opReadCookie(e, op),
                OP.SetCookie => txn.opSetCookie(e, op),

                // Opening, positioning and stepping cursors.
                OP.ReopenIdx => cursor.opReopenIdx(e, op),
                OP.OpenRead, OP.OpenWrite => cursor.opOpen(e, op),
                OP.OpenDup => cursor.opOpenDup(e, op),
                OP.OpenAutoindex, OP.OpenEphemeral => cursor.opOpenEphemeral(e, op),
                OP.SorterOpen => cursor.opSorterOpen(e, op),
                OP.SequenceTest => cursor.opSequenceTest(e, op),
                OP.OpenPseudo => cursor.opOpenPseudo(e, op),
                OP.Close => cursor.opClose(e, op),
                OP.SeekLT, OP.SeekLE, OP.SeekGE, OP.SeekGT => cursor.opSeek(e, op),
                OP.SeekScan => cursor.opSeekScan(e, op),
                OP.SeekHit => cursor.opSeekHit(e, op),
                OP.IfNoHope => cursor.opIfNoHope(e, op),
                OP.NoConflict, OP.NotFound, OP.Found => cursor.opFound(e, op),
                OP.SeekRowid => cursor.opSeekRowid(e, op),
                OP.NotExists => cursor.opNotExists(e, op),
                OP.Sequence => cursor.opSequence(e, op),

                // Writing and reading rows.
                OP.NewRowid => btree_ops.opNewRowid(e, op),
                OP.Insert => btree_ops.opInsert(e, op),
                OP.Delete => btree_ops.opDelete(e, op),
                OP.ResetCount => btree_ops.opResetCount(e, op),
                OP.SorterCompare => btree_ops.opSorterCompare(e, op),
                OP.SorterData => btree_ops.opSorterData(e, op),
                OP.RowData => btree_ops.opRowData(e, op),
                OP.Rowid => cursor.opRowid(e, op),
                OP.NullRow => cursor.opNullRow(e, op),
                OP.SeekEnd, OP.Last => cursor.opLast(e, op),
                OP.IfSizeBetween => cursor.opIfSizeBetween(e, op),
                OP.SorterSort, OP.Sort => cursor.opSort(e, op),
                OP.Rewind => cursor.opRewind(e, op),
                OP.IfEmpty => cursor.opIfEmpty(e, op),
                OP.SorterNext => cursor.opSorterNext(e, op),
                OP.Prev => cursor.opPrev(e, op),
                OP.Next => cursor.opNext(e, op),
                OP.IdxInsert => btree_ops.opIdxInsert(e, op),
                OP.SorterInsert => btree_ops.opSorterInsert(e, op),
                OP.IdxDelete => btree_ops.opIdxDelete(e, op),
                OP.DeferredSeek, OP.IdxRowid => cursor.opIdxRowid(e, op),
                OP.FinishSeek => cursor.opFinishSeek(e, op),
                OP.IdxLE, OP.IdxGT, OP.IdxLT, OP.IdxGE => cursor.opIdxCompare(e, op),

                // The schema.
                OP.Destroy => txn.opDestroy(e, op),
                OP.Clear => txn.opClear(e, op),
                OP.ResetSorter => btree_ops.opResetSorter(e, op),
                OP.CreateBtree => txn.opCreateBtree(e, op),
                OP.SqlExec => txn.opSqlExec(e, op),
                OP.ParseSchema => txn.opParseSchema(e, op),
                OP.LoadAnalysis => txn.opLoadAnalysis(e, op),
                OP.DropTable => txn.opDropTable(e, op),
                OP.DropIndex => txn.opDropIndex(e, op),
                OP.DropTrigger => txn.opDropTrigger(e, op),
                OP.IntegrityCk => txn.opIntegrityCk(e, op),

                // Row sets.
                OP.RowSetAdd => misc.opRowSetAdd(e, op),
                OP.RowSetRead => misc.opRowSetRead(e, op),
                OP.RowSetTest => misc.opRowSetTest(e, op),

                // Trigger programs and counters.
                OP.Program => control.opProgram(e, op),
                OP.Param => control.opParam(e, op),
                OP.FkCounter => control.opFkCounter(e, op),
                OP.FkIfZero => control.opFkIfZero(e, op),
                OP.MemMax => control.opMemMax(e, op),
                OP.IfPos => control.opIfPos(e, op),
                OP.OffsetLimit => control.opOffsetLimit(e, op),
                OP.IfNotZero => control.opIfNotZero(e, op),
                OP.DecrJumpZero => control.opDecrJumpZero(e, op),

                // Aggregates.
                OP.AggInverse, OP.AggStep, OP.AggStep1 => agg.opAggStep(e, op),
                OP.AggValue, OP.AggFinal => agg.opAggFinal(e, op),

                // The database files.
                OP.Checkpoint => txn.opCheckpoint(e, op),
                OP.JournalMode => txn.opJournalMode(e, op),
                OP.IncrVacuum => txn.opIncrVacuum(e, op),
                OP.Expire => txn.opExpire(e, op),
                // Cursor pinning only matters to the C b-tree's cell cache.
                OP.CursorLock, OP.CursorUnlock => .next,

                // Virtual tables.
                OP.VBegin => vtab_ops.opVBegin(e, op),
                OP.VCreate => vtab_ops.opVCreate(e, op),
                OP.VDestroy => vtab_ops.opVDestroy(e, op),
                OP.VOpen => vtab_ops.opVOpen(e, op),
                OP.VCheck => vtab_ops.opVCheck(e, op),
                OP.VInitIn => vtab_ops.opVInitIn(e, op),
                OP.VFilter => vtab_ops.opVFilter(e, op),
                OP.VColumn => vtab_ops.opVColumn(e, op),
                OP.VNext => vtab_ops.opVNext(e, op),
                OP.VRename => vtab_ops.opVRename(e, op),
                OP.VUpdate => vtab_ops.opVUpdate(e, op),

                // The rest.
                OP.Pagecount => txn.opPagecount(e, op),
                OP.MaxPgcnt => txn.opMaxPgcnt(e, op),
                OP.PureFunc, OP.Function => agg.opFunction(e, op),
                OP.ClrSubtype => register.opClrSubtype(e, op),
                OP.GetSubtype => register.opGetSubtype(e, op),
                OP.SetSubtype => register.opSetSubtype(e, op),
                OP.FilterAdd => misc.opFilterAdd(e, op),
                OP.Filter => misc.opFilter(e, op),
                OP.Trace, OP.Init => control.opInit(e, op),
                OP.IFindKey => cursor.opIFindKey(e, op),
                OP.Noop, OP.Explain, OP.CursorHint, OP.Abortable, OP.ReleaseReg => .next,
                else => misc.opNotSupported(e, op),
            };
            switch (flow) {
                .next, .jump_p2, .check_interrupt, .jump_p2_check_interrupt => {
                    // A handler that moved the address must say so.
                    if (std.debug.runtime_safety) std.debug.assert(e.pc == pc and e.ops.ptr == ops);
                },
                else => {},
            }
            switch (flow) {
                .next => pc += 1,
                .jump_p2 => pc = @intCast(op.p2),
                .check_interrupt => {
                    if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt, n_vm_step);
                    pc += 1;
                },
                .jump_p2_check_interrupt => {
                    pc = @intCast(op.p2);
                    if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt, n_vm_step);
                },
                .goto_pc => {
                    ops = e.ops.ptr;
                    pc = @intCast(e.pc + 1);
                },
                .goto_pc_check_interrupt => {
                    ops = e.ops.ptr;
                    pc = @intCast(e.pc + 1);
                    if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt, n_vm_step);
                },
                else => return e.finish(flow, n_vm_step),
            }
        }
    }

    /// The tail of sqlite3VdbeExec(): too_big, no_mem,
    /// abort_due_to_interrupt, abort_due_to_error and vdbe_return.
    fn finish(e: *Exec, flow_arg: Flow, n_vm_step: u64) i32 {
        const v = e.v;
        const db = e.db;
        var flow = flow_arg;
        switch (flow) {
            .too_big => {
                aux.vdbeError(v, "string or blob too big", .{});
                e.rc = RC.TOOBIG;
                flow = .abort;
            },
            .no_mem => {
                db.oomFault();
                aux.vdbeError(v, "out of memory", .{});
                e.rc = RC.NOMEM;
                flow = .abort;
            },
            .interrupt => {
                e.rc = RC.INTERRUPT;
                flow = .abort;
            },
            else => {},
        }
        if (flow == .abort) {
            if (db.malloc_failed) e.rc = RC.NOMEM;
            std.debug.assert(e.rc != 0);
            if (v.err_msg == null) aux.vdbeError(v, "{s}", .{util.errStr(e.rc)});
            v.rc = e.rc;
            if (v.e_vdbe_state == .run) _ = aux.halt(v);
            if (e.rc == RC.CORRUPT and !db.auto_commit) db.flags |= int.DbFlag.CorruptRdOnly;
            e.rc = RC.ERROR;
            if (e.reset_schema_on_fault > 0) {
                @import("../sql/build.zig").resetOneSchema(db, e.reset_schema_on_fault - 1);
            }
        }
        v.counters[vi.STMTSTATUS.VM_STEP] +%= @truncate(n_vm_step);
        return e.rc;
    }
};
