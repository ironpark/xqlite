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
//! pOp), and `.ret` leaves the run (vdbe_return). A handler that can fail
//! returns `Error!Flow`: the errors of the layers below are propagated
//! with `try`, and every error ends up in abortDueToError(), the one
//! place that turns it into the statement's result code (C's labels
//! no_mem, too_big, abort_due_to_interrupt and abort_due_to_error). An
//! extended code is recorded in Vdbe.rc next to its error (see abort()).

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const aux = @import("aux.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");

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

/// The errors that end a run.
pub const Error = int.Error;

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
    /// The result of a `.ret` flow: ROW, DONE, BUSY or an error code.
    rc: i32 = RC.OK,
    encoding: u8,
    /// Result of the last OP_Compare.
    i_compare: i32 = 0,
    /// Reset this schema (plus one) after an error.
    reset_schema_on_fault: u8 = 0,
    /// The run's nProgressLimit as of its last change, for vdbe_return
    /// (the run loop keeps its own copy in a local).
    progress_limit: u64 = std.math.maxInt(u64),

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

    /// abort_due_to_error with result code `rc` (C: `rc = X; goto
    /// abort_due_to_error`): the code is recorded in Vdbe.rc, where C's
    /// abort_due_to_error puts it, and its error is returned for the run
    /// loop, which then reports `rc` itself (see int.resultCode()).
    pub fn abort(e: *Exec, rc: i32) Error {
        e.v.rc = rc;
        return int.codeError(rc);
    }

    /// abort() unless `rc` (from a callback of an extension, or a
    /// function that returns a result code) is OK.
    pub fn check(e: *Exec, rc: i32) Error!void {
        if (rc != RC.OK) return e.abort(rc);
    }

    /// Port of out2Prerelease(): register P2, ready to take an integer.
    pub fn out2Prerelease(e: *Exec, op: *const Op) *Mem {
        const out = e.reg(op.p2);
        if (out.isDynamic()) mem.setNull(out);
        out.flags = .{ .Int = true };
        return out;
    }

    fn run(e: *Exec) i32 {
        const v = e.v;
        const db = e.db;
        if (v.rc == RC.NOMEM) return e.abortDueToError(error.OutOfMemory, 0);
        v.rc = RC.OK;
        v.i_current_time = 0;
        db.busy_handler.n_busy = 0;
        if (db.is_interrupted.load(.monotonic)) return e.abortDueToError(error.Interrupt, 0);
        // As in C, the address, the program and the step count are locals
        // (pOp, aOp, nVmStep) rather than memory the handlers may change:
        // the handlers see the address in e.pc and report a change with
        // .goto_pc.
        var ops = e.ops.ptr;
        var pc: usize = @intCast(e.pc);
        var n_vm_step: u64 = 0;
        // The progress handler runs every n_progress_ops instructions,
        // counted across the calls of sqlite3_step() (nProgressLimit).
        var progress_limit: u64 = std.math.maxInt(u64);
        if (db.progress != null and db.n_progress_ops > 0) {
            const prior: u64 = v.counters[vi.STMTSTATUS.VM_STEP];
            progress_limit = db.n_progress_ops - (prior % db.n_progress_ops);
            e.progress_limit = progress_limit;
        }
        while (true) {
            const op = &ops[pc];
            n_vm_step += 1;
            e.pc = @intCast(pc);
            // A handler that can fail has its error caught on its own arm,
            // so that the others yield a plain Flow: a catch after the
            // switch would test for an error after every instruction
            // (about 10% on tight loops).
            const flow: Flow = switch (op.opcode) {
                // Jumps, subroutines, co-routines and halting.
                OP.Goto => .jump_p2_check_interrupt,
                OP.Gosub => control.opGosub(e, op),
                OP.Return => control.opReturn(e, op),
                OP.InitCoroutine => control.opInitCoroutine(e, op),
                OP.EndCoroutine => control.opEndCoroutine(e, op),
                OP.Yield => control.opYield(e, op),
                OP.HaltIfNull => control.opHaltIfNull(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Halt => control.opHalt(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Constants and registers.
                OP.Integer => register.opInteger(e, op),
                OP.Int64 => register.opInt64(e, op),
                OP.Real => register.opReal(e, op),
                OP.String8 => register.opString8(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.String => register.opString(e, op),
                OP.BeginSubrtn, OP.Null => register.opNull(e, op),
                OP.SoftNull => register.opSoftNull(e, op),
                OP.Blob => register.opBlob(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Variable => register.opVariable(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Move => register.opMove(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Copy => register.opCopy(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SCopy => register.opSCopy(e, op),
                OP.IntCopy => register.opIntCopy(e, op),
                OP.FkCheck => register.opFkCheck(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ResultRow => register.opResultRow(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Arithmetic, comparisons and logic.
                OP.Concat => arith.opConcat(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Add, OP.Subtract, OP.Multiply, OP.Divide, OP.Remainder => arith.opArith(e, op),
                OP.CollSeq => arith.opCollSeq(e, op),
                OP.BitAnd, OP.BitOr, OP.ShiftLeft, OP.ShiftRight => arith.opBit(e, op),
                OP.AddImm => arith.opAddImm(e, op),
                OP.MustBeInt => arith.opMustBeInt(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.RealAffinity => arith.opRealAffinity(e, op),
                OP.Cast => arith.opCast(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Eq, OP.Ne, OP.Lt, OP.Le, OP.Gt, OP.Ge => arith.opCompareJump(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
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
                OP.Column => record.opColumn(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.TypeCheck => record.opTypeCheck(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Affinity => record.opAffinity(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.MakeRecord => record.opMakeRecord(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Count => btree_ops.opCount(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Transactions.
                OP.Savepoint => txn.opSavepoint(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.AutoCommit => txn.opAutoCommit(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Transaction => txn.opTransaction(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ReadCookie => txn.opReadCookie(e, op),
                OP.SetCookie => txn.opSetCookie(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Opening, positioning and stepping cursors.
                OP.ReopenIdx => cursor.opReopenIdx(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.OpenRead, OP.OpenWrite => cursor.opOpen(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.OpenDup => cursor.opOpenDup(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.OpenAutoindex, OP.OpenEphemeral => cursor.opOpenEphemeral(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SorterOpen => cursor.opSorterOpen(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SequenceTest => cursor.opSequenceTest(e, op),
                OP.OpenPseudo => cursor.opOpenPseudo(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Close => cursor.opClose(e, op),
                OP.SeekLT, OP.SeekLE, OP.SeekGE, OP.SeekGT => cursor.opSeek(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SeekScan => cursor.opSeekScan(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SeekHit => cursor.opSeekHit(e, op),
                OP.IfNoHope => cursor.opIfNoHope(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.NoConflict, OP.NotFound, OP.Found => cursor.opFound(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SeekRowid => cursor.opSeekRowid(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.NotExists => cursor.opNotExists(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Sequence => cursor.opSequence(e, op),

                // Writing and reading rows.
                OP.NewRowid => btree_ops.opNewRowid(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Insert => btree_ops.opInsert(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Delete => btree_ops.opDelete(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ResetCount => btree_ops.opResetCount(e, op),
                OP.SorterCompare => btree_ops.opSorterCompare(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SorterData => btree_ops.opSorterData(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.RowData => btree_ops.opRowData(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Rowid => cursor.opRowid(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.NullRow => cursor.opNullRow(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SeekEnd, OP.Last => cursor.opLast(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IfSizeBetween => cursor.opIfSizeBetween(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SorterSort, OP.Sort => cursor.opSort(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Rewind => cursor.opRewind(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IfEmpty => cursor.opIfEmpty(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SorterNext => cursor.opSorterNext(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Prev => cursor.opPrev(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Next => cursor.opNext(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IdxInsert => btree_ops.opIdxInsert(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SorterInsert => btree_ops.opSorterInsert(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IdxDelete => btree_ops.opIdxDelete(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.DeferredSeek, OP.IdxRowid => cursor.opIdxRowid(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.FinishSeek => cursor.opFinishSeek(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IdxLE, OP.IdxGT, OP.IdxLT, OP.IdxGE => cursor.opIdxCompare(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // The schema.
                OP.Destroy => txn.opDestroy(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Clear => txn.opClear(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ResetSorter => btree_ops.opResetSorter(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.CreateBtree => txn.opCreateBtree(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.SqlExec => txn.opSqlExec(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ParseSchema => txn.opParseSchema(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.LoadAnalysis => txn.opLoadAnalysis(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.DropTable => txn.opDropTable(e, op),
                OP.DropIndex => txn.opDropIndex(e, op),
                OP.DropTrigger => txn.opDropTrigger(e, op),
                OP.IntegrityCk => txn.opIntegrityCk(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Row sets.
                OP.RowSetAdd => misc.opRowSetAdd(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.RowSetRead => misc.opRowSetRead(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.RowSetTest => misc.opRowSetTest(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // Trigger programs and counters.
                OP.Program => control.opProgram(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Param => control.opParam(e, op),
                OP.FkCounter => control.opFkCounter(e, op),
                OP.FkIfZero => control.opFkIfZero(e, op),
                OP.MemMax => control.opMemMax(e, op),
                OP.IfPos => control.opIfPos(e, op),
                OP.OffsetLimit => control.opOffsetLimit(e, op),
                OP.IfNotZero => control.opIfNotZero(e, op),
                OP.DecrJumpZero => control.opDecrJumpZero(e, op),

                // Aggregates.
                OP.AggInverse, OP.AggStep, OP.AggStep1 => agg.opAggStep(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.AggValue, OP.AggFinal => agg.opAggFinal(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // The database files.
                OP.Checkpoint => txn.opCheckpoint(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.JournalMode => txn.opJournalMode(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.IncrVacuum => txn.opIncrVacuum(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Expire => txn.opExpire(e, op),
                // Cursor pinning only matters to the C b-tree's cell cache.
                OP.CursorLock, OP.CursorUnlock => .next,

                // Virtual tables.
                OP.VBegin => vtab_ops.opVBegin(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VCreate => vtab_ops.opVCreate(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VDestroy => vtab_ops.opVDestroy(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VOpen => vtab_ops.opVOpen(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VCheck => vtab_ops.opVCheck(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VInitIn => vtab_ops.opVInitIn(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VFilter => vtab_ops.opVFilter(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VColumn => vtab_ops.opVColumn(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VNext => vtab_ops.opVNext(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VRename => vtab_ops.opVRename(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.VUpdate => vtab_ops.opVUpdate(e, op) catch |err| return e.abortDueToError(err, n_vm_step),

                // The rest.
                OP.Pagecount => txn.opPagecount(e, op),
                OP.MaxPgcnt => txn.opMaxPgcnt(e, op),
                OP.PureFunc, OP.Function => agg.opFunction(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.ClrSubtype => register.opClrSubtype(e, op),
                OP.GetSubtype => register.opGetSubtype(e, op),
                OP.SetSubtype => register.opSetSubtype(e, op),
                OP.FilterAdd => misc.opFilterAdd(e, op),
                OP.Filter => misc.opFilter(e, op),
                OP.Trace, OP.Init => control.opInit(e, op),
                OP.IFindKey => cursor.opIFindKey(e, op),
                OP.Noop, OP.Explain, OP.CursorHint, OP.Abortable, OP.ReleaseReg => .next,
                OP.RowCell => btree_ops.opRowCell(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                OP.Vacuum => txn.opVacuum(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
                // Only with a shared cache (TableLock) or in C builds with
                // SQLITE_ENABLE_OFFSET_SQL_FUNC (Offset) or
                // SQLITE_ENABLE_COLUMN_USED_MASK (ColumnsUsed); never coded.
                OP.TableLock, OP.Offset, OP.ColumnsUsed => misc.opNotSupported(e, op) catch |err| return e.abortDueToError(err, n_vm_step),
            };
            switch (flow) {
                .next, .jump_p2, .check_interrupt, .jump_p2_check_interrupt => {
                    // A handler that moved the address must say so.
                    if (std.debug.runtime_safety) std.debug.assert(e.pc == pc and e.ops.ptr == ops);
                },
                .goto_pc, .goto_pc_check_interrupt, .ret => {},
            }
            switch (flow) {
                .next => pc += 1,
                .jump_p2 => pc = @intCast(op.p2),
                .check_interrupt => {
                    if (db.is_interrupted.load(.monotonic)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    if (n_vm_step >= progress_limit and e.progressInterrupts(&progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    pc += 1;
                },
                .jump_p2_check_interrupt => {
                    pc = @intCast(op.p2);
                    if (db.is_interrupted.load(.monotonic)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    if (n_vm_step >= progress_limit and e.progressInterrupts(&progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                },
                .goto_pc => {
                    ops = e.ops.ptr;
                    pc = @intCast(e.pc + 1);
                },
                .goto_pc_check_interrupt => {
                    ops = e.ops.ptr;
                    pc = @intCast(e.pc + 1);
                    if (db.is_interrupted.load(.monotonic)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    if (n_vm_step >= progress_limit and e.progressInterrupts(&progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                },
                .ret => return e.vdbeReturn(n_vm_step),
            }
        }
    }

    /// The tail of sqlite3VdbeExec() for an error: the labels too_big,
    /// no_mem, abort_due_to_interrupt and abort_due_to_error. The result
    /// code of `err` (with the extended code recorded in Vdbe.rc, if it
    /// is one of `err`) becomes that of the statement; the run returns
    /// ERROR. A TooBig or OutOfMemory of the VM or the layers below goes
    /// through too_big or no_mem, which set the message (and record the
    /// OOM); one whose code was recorded by abort() (a callback that
    /// returned SQLITE_NOMEM or SQLITE_TOOBIG) goes straight to
    /// abort_due_to_error, as in C, and keeps its message.
    fn abortDueToError(e: *Exec, err: Error, n_vm_step: u64) i32 {
        @branchHint(.cold);
        const v = e.v;
        const db = e.db;
        const recorded = v.rc != RC.OK and int.codeError(v.rc) == err;
        if (!recorded) switch (err) {
            error.TooBig => aux.vdbeError(v, "string or blob too big", .{}),
            error.OutOfMemory => {
                db.oomFault();
                aux.vdbeError(v, "out of memory", .{});
            },
            else => {},
        };
        var rc = int.resultCode(err, v.rc);
        if (db.malloc_failed) rc = RC.NOMEM;
        std.debug.assert(rc != 0);
        if (v.err_msg == null) aux.vdbeError(v, "{s}", .{util.errStr(rc)});
        v.rc = rc;
        if (v.e_vdbe_state == .run) aux.halt(v) catch {};
        if (rc == RC.CORRUPT and !db.auto_commit) db.flags.CorruptRdOnly = true;
        e.rc = RC.ERROR;
        if (e.reset_schema_on_fault > 0) {
            @import("../sql/build.zig").resetOneSchema(db, e.reset_schema_on_fault - 1);
        }
        return e.vdbeReturn(n_vm_step);
    }

    /// Call the progress handler, whose limit `limit` (the run loop's
    /// copy, or Exec.progress_limit itself) was reached; whether it asks
    /// to interrupt the statement.
    fn progressInterrupts(e: *Exec, limit: *u64) bool {
        @branchHint(.cold);
        const db = e.db;
        defer e.progress_limit = limit.*;
        const f = db.progress orelse {
            limit.* = std.math.maxInt(u64);
            return false;
        };
        limit.* +|= db.n_progress_ops;
        if (f(db.progress_arg) != 0) {
            limit.* = std.math.maxInt(u64);
            return true;
        }
        return false;
    }

    /// vdbe_return: leave the run with Exec.rc, after the progress
    /// handler calls the instructions since the last one are due.
    fn vdbeReturn(e: *Exec, n_vm_step: u64) i32 {
        while (n_vm_step >= e.progress_limit and e.db.progress != null) {
            if (e.progressInterrupts(&e.progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
        }
        e.v.counters[vi.STMTSTATUS.VM_STEP] +%= @truncate(n_vm_step);
        return e.rc;
    }
};
