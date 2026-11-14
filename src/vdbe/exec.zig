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
//! Each module lists the opcodes it runs in `handlers` (see `modules`),
//! and the run loop switches on the opcode with an arm per opcode, made
//! at compile time from those lists: an opcode without a handler, or
//! with two, does not compile. A handler that runs several opcodes and
//! tells them apart takes the opcode as a comptime parameter, so that
//! each arm gets its own copy without the test.
//!
//! A handler takes its instruction with its operands typed as the
//! opcode's (see operand.zig and `modules`).
//!
//! Each handler returns a `Flow`, which stands in for the gotos of the C
//! code: `.next` continues, `.jump_p2` goes to P2, `.goto` to the address
//! it carries, `.frame` to an address of the program the handler
//! switched to (in and out of trigger programs), the `_check` variants
//! after a check for an interrupt, and `.ret` leaves the run
//! (vdbe_return). Handlers read the address of their instruction in
//! `Exec.pc` but never change it. A handler that can fail returns
//! `Error!Flow`: the errors of the layers below are propagated with
//! `try`, and every error ends up in abortDueToError(), the one place
//! that turns it into the statement's result code (C's labels no_mem,
//! too_big, abort_due_to_interrupt and abort_due_to_error). An extended
//! code is recorded in Vdbe.rc next to its error (see abort()).

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const aux = @import("aux.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const operand = @import("operand.zig");

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
const Reg = operand.Reg;
const Cursor = operand.Cursor;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;

/// The errors that end a run.
pub const Error = int.Error;

/// What a handler tells the run loop to do next. A packed struct (an
/// integer to LLVM) rather than a tagged union: with the union the loop
/// was about 4% slower on cte. Handlers write `.next`, `.jump_p2`, ...
/// and `.goto(address)` (decl literals).
pub const Flow = packed struct(u64) {
    kind: Kind,
    /// The address of `.goto`, `.frame` and `.frame_check`.
    to: u32 = 0,
    _: u24 = 0,

    pub const Kind = enum(u8) {
        /// Continue with the next instruction.
        next,
        /// Check for an interrupt (and call the progress handler if it
        /// is due), then continue with the next instruction.
        next_check,
        /// Continue at P2.
        jump_p2,
        /// Continue at P2 after the check of `.next_check`.
        jump_p2_check,
        /// Continue at `to` in the same program.
        goto,
        /// Continue at `to` in the program the handler switched to
        /// (Exec.ops and Exec.regs): returning from a trigger program.
        frame,
        /// `.frame` after the check of `.next_check`: entering one.
        frame_check,
        /// vdbe_return: leave with Exec.rc.
        ret,
    };

    pub const next: Flow = .{ .kind = .next };
    pub const next_check: Flow = .{ .kind = .next_check };
    pub const jump_p2: Flow = .{ .kind = .jump_p2 };
    pub const jump_p2_check: Flow = .{ .kind = .jump_p2_check };
    pub const ret: Flow = .{ .kind = .ret };

    pub fn goto(to: u32) Flow {
        return .{ .kind = .goto, .to = to };
    }

    pub fn frame(to: u32) Flow {
        return .{ .kind = .frame, .to = to };
    }

    pub fn frameCheck(to: u32) Flow {
        return .{ .kind = .frame_check, .to = to };
    }
};

/// The modules of handlers. The handler of OP_X is the function `opX` of
/// one of them, unless a module lists it in its `handlers`, a tuple of
/// entries `.{ .ops = .{ .Add, .Subtract, ... }, .f = opArith }` for the
/// functions that run several opcodes. The run loop inlines the handlers
/// of the opcodes in a module's `inlined`, and of the entries with
/// `.call = .always_inline`. An opcode with no handler, or with two, does
/// not compile.
///
/// A handler is `fn (e: *Exec, op: *OpFor(.X)) Flow` (or `Error!Flow`),
/// with a third parameter `comptime opc: OP`, the opcode it runs, if it
/// runs several and tells them apart. `op` is the instruction with its
/// operands typed as those of the opcode (vi.OpFor(), operand.zig), and
/// its type must be that of every opcode the handler runs. A handler of
/// opcodes whose operands differ (OP_Last and OP_SeekEnd), or that reads
/// none, takes `op: anytype` and gets the type of each opcode in its copy
/// for that opcode.
///
/// Inlined are the handlers of the opcodes of inner loops (stepping and
/// seeking cursors, OP_Column, register copies, arithmetic, comparisons,
/// jumps, co-routines, aggregate steps and functions, building and
/// inserting rows): measured with `xqt bench`, 15% on cte and 6-7% on
/// insert, scan and pklookup; inlining only the small ones of them gave
/// about half of that.
const modules = .{ control, register, arith, record, txn, cursor, btree_ops, agg, vtab_ops, misc };

/// Where the handler of an opcode is: entry `entry` of the `handlers` of
/// module `module`, or (null) its function named after the opcode.
const HandlerAt = struct { module: usize, entry: ?usize };

const handler_at: std.enums.EnumArray(OP, HandlerAt) = blk: {
    @setEvalBranchQuota(200_000);
    var at: std.enums.EnumArray(OP, ?HandlerAt) = .initFill(null);
    for (modules, 0..) |m, mi| {
        for (m.handlers, 0..) |h, hi| {
            for (h.ops) |o| {
                if (at.get(o) != null) @compileError("two handlers for OP_" ++ @tagName(@as(OP, o)));
                at.set(o, .{ .module = mi, .entry = hi });
            }
        }
    }
    for (std.enums.values(OP)) |opc| {
        for (modules, 0..) |m, mi| {
            if (!@hasDecl(m, "op" ++ @tagName(opc))) continue;
            if (at.get(opc)) |x| {
                // The function of the entry that lists the opcode.
                if (x.entry != null and x.module == mi) continue;
                @compileError("two handlers for OP_" ++ @tagName(opc));
            }
            at.set(opc, .{ .module = mi, .entry = null });
        }
        if (at.get(opc) == null) @compileError("no handler for OP_" ++ @tagName(opc));
    }
    var out: std.enums.EnumArray(OP, HandlerAt) = undefined;
    for (std.enums.values(OP)) |opc| out.set(opc, at.get(opc).?);
    for (modules, 0..) |m, mi| if (@hasDecl(m, "inlined")) for (m.inlined) |o| {
        const x = out.get(o);
        if (x.module != mi or x.entry != null) @compileError("inlined: OP_" ++ @tagName(@as(OP, o)) ++ " is not run by op" ++ @tagName(@as(OP, o)) ++ " of the module");
    };
    break :blk out;
};

/// The handler of opcode `opc` and how the run loop calls it.
fn handler(comptime opc: OP) type {
    const at = handler_at.get(opc);
    const m = modules[at.module];
    const name = "the handler of OP_" ++ @tagName(opc);
    return struct {
        const f = if (at.entry) |i| m.handlers[i].f else @field(m, "op" ++ @tagName(opc));
        const call: std.builtin.CallModifier = if (at.entry) |i|
            (if (@hasField(@TypeOf(m.handlers[i]), "call")) m.handlers[i].call else .auto)
        else if (isInlined(m, opc)) .always_inline else .auto;
        const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
        const takes_opc = params.len == 3;
        /// The type of the instruction it takes: that of the opcode,
        /// which a handler of several opcodes must fit to all of them.
        const Ins = *vi.OpFor(opc);
        comptime {
            if (params[1]) |P| if (P != Ins) {
                @compileError(name ++ " takes " ++ @typeName(P) ++ ", not *OpFor(." ++ @tagName(opc) ++ "), which is " ++ @typeName(vi.OpFor(opc)));
            };
        }
    };
}

fn isInlined(comptime m: anytype, comptime opc: OP) bool {
    if (!@hasDecl(m, "inlined")) return false;
    for (m.inlined) |o| if (o == opc) return true;
    return false;
}

/// Port of sqlite3VdbeExec(): run the program until it produces a row
/// (RC.ROW), finishes (RC.DONE) or fails (RC.ERROR and others).
pub fn exec(v: *Vdbe) i32 {
    std.debug.assert(v.e_vdbe_state == .run);
    var e: Exec = .{
        .v = v,
        .db = v.db,
        .ops = v.prog,
        .regs = v.mem,
        .pc = @intCast(v.pc),
        .encoding = v.db.enc,
    };
    aux.vdbeEnter(v);
    defer aux.vdbeLeave(v);
    // A statement compiled for sqlite3_stmt_scanstatus() counts the runs
    // and cycles of its instructions, in its own copy of the loop, so
    // that other statements do not test for it.
    if (v.op_stats.len > 0) return e.run(true);
    return e.run(false);
}

/// sqlite3Hwtime(): a cycle counter (the time-stamp counter on x86, the
/// virtual counter on ARM64; 0 elsewhere, as in C).
inline fn hwtime() u64 {
    switch (@import("builtin").cpu.arch) {
        .x86_64, .x86 => {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            return @as(u64, hi) << 32 | lo;
        },
        .aarch64 => return asm volatile ("mrs %[r], cntvct_el0"
            : [r] "=r" (-> u64),
        ),
        else => return 0,
    }
}

/// The state of a run that the handlers share (the locals of
/// sqlite3VdbeExec()).
pub const Exec = struct {
    v: *Vdbe,
    db: *Sqlite3,
    /// The program and registers of the current frame (aOp, aMem).
    ops: []Op,
    regs: []Mem,
    /// Address of the current instruction (handlers read it; the Flow
    /// they return says where to continue).
    pc: u32,
    /// The result of a `.ret` flow: ROW, DONE, BUSY or an error code.
    rc: i32 = RC.OK,
    encoding: u8,
    /// Result of the last OP_Compare.
    i_compare: i32 = 0,
    /// Reset this schema after an error (OP_Destroy moved a root page).
    reset_schema_on_fault: ?u8 = null,
    /// The run's nProgressLimit as of its last change, for vdbe_return
    /// (the run loop keeps its own copy in a local).
    progress_limit: u64 = std.math.maxInt(u64),

    // The registers and cursors that typed operands name (operand.zig).

    pub fn reg(e: *Exec, r: Reg) *Mem {
        return &e.regs[@intCast(r.int())];
    }

    /// The `n` registers from `r` on.
    pub fn regRange(e: *Exec, r: Reg, n: usize) []Mem {
        return e.regs[@intCast(r.int())..][0..n];
    }

    /// Take the program and registers of the Vdbe's current frame
    /// (Vdbe.prog, Vdbe.mem), which a handler that enters or leaves a
    /// trigger program has switched; it then returns a `.frame` flow.
    pub fn syncFrame(e: *Exec) void {
        e.ops = e.v.prog;
        e.regs = e.v.mem;
    }

    /// Register `r` of the main program, even inside a trigger.
    pub fn rootReg(e: *Exec, r: Reg) *Mem {
        const frame = vi.rootFrame(e.v.frame orelse return e.reg(r));
        return &frame.mem[@intCast(r.int())];
    }

    /// Cursor `c`, which must be open.
    pub fn csr(e: *Exec, c: Cursor) *VdbeCursor {
        return e.v.csr[@intCast(c.int())].?;
    }

    /// Cursor `c`, or null if it is not open.
    pub fn csrIfOpen(e: *Exec, c: Cursor) ?*VdbeCursor {
        return e.v.csr[@intCast(c.int())];
    }

    /// The slot of cursor `c`, open or not.
    pub fn csrSlot(e: *Exec, c: Cursor) *?*VdbeCursor {
        return &e.v.csr[@intCast(c.int())];
    }

    /// The instruction at `addr` of the current program, which is an
    /// `opc` (a handler that reads the instruction before or after its
    /// own), with its operands typed as that opcode's.
    pub fn opAt(e: *Exec, comptime opc: OP, addr: usize) *vi.OpFor(opc) {
        return vi.opAs(&e.ops[addr], opc);
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
    pub fn out2Prerelease(e: *Exec, op: anytype) *Mem {
        const out = e.reg(op.p2);
        if (out.isDynamic()) mem.setNull(out);
        out.flags = .{ .Int = true };
        return out;
    }

    fn run(e: *Exec, comptime scan: bool) i32 {
        // The switch below has an arm for each opcode (inline else).
        @setEvalBranchQuota(10_000);
        const v = e.v;
        const db = e.db;
        if (v.rc == RC.NOMEM) return e.abortDueToError(error.OutOfMemory, 0);
        v.rc = RC.OK;
        v.i_current_time = 0;
        db.busy_handler.n_busy = 0;
        if (db.is_interrupted.load(.monotonic)) return e.abortDueToError(error.Interrupt, 0);
        // As in C, the address, the program and the step count are locals
        // (pOp, aOp, nVmStep): the handlers see the address in e.pc and
        // return the one to continue at in their Flow. The address is a
        // usize here: as a u32 (the type of Exec.pc) LLVM kept it on the
        // stack, in the chain of every dispatch (6-10% on cte, pklookup).
        var ops = e.ops.ptr;
        var pc: usize = e.pc;
        var n_vm_step: u64 = 0;
        // The progress handler runs every n_progress_ops instructions,
        // counted across the calls of sqlite3_step() (nProgressLimit).
        var progress_limit: u64 = std.math.maxInt(u64);
        if (db.progress != null and db.n_progress_ops > 0) {
            const prior: u64 = v.counters.get(.vm_step);
            progress_limit = db.n_progress_ops - (prior % db.n_progress_ops);
            e.progress_limit = progress_limit;
        }
        const main_ops = v.ops.items.ptr;
        // Each arm ends in its own dispatch of the next instruction
        // (continue :dispatch), so that each opcode has its own indirect
        // branch, which the CPU predicts from that opcode (8-12% on scan
        // and cte against one shared dispatch at the top of a loop).
        dispatch: switch (ops[pc].opcode) {
            // Every opcode has its own arm, which calls its handler (with
            // the opcode as a comptime argument if it takes one) and, only
            // if the handler can fail, catches its error: a catch after
            // the call of any handler would test for an error after every
            // instruction (about 10% on tight loops).
            inline else => |opc| {
                const op = &ops[pc];
                n_vm_step += 1;
                e.pc = @intCast(pc);
                // pOp->nExec and pOp->nCycle, for the main program.
                var stat: ?*vi.OpStat = null;
                var t0: u64 = 0;
                if (scan and ops == main_ops) {
                    stat = &v.op_stats[pc];
                    stat.?.n_exec += 1;
                    t0 = hwtime();
                }
                const h = handler(opc);
                const ins: h.Ins = @ptrCast(op);
                const r = if (h.takes_opc)
                    @call(h.call, h.f, .{ e, ins, opc })
                else
                    @call(h.call, h.f, .{ e, ins });
                const flow: Flow = if (@typeInfo(@TypeOf(r)) == .error_union)
                    r catch |err| return e.abortDueToError(err, n_vm_step)
                else
                    r;
                if (scan) if (stat) |st| {
                    st.n_cycle +%= hwtime() -% t0;
                };
                switch (flow.kind) {
                    .next => pc += 1,
                    .jump_p2 => pc = @intCast(op.p2),
                    .goto => pc = flow.to,
                    .frame => {
                        ops = e.ops.ptr;
                        pc = flow.to;
                    },
                    .next_check => {
                        pc += 1;
                        if (e.interrupted(n_vm_step, &progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    },
                    .jump_p2_check => {
                        pc = @intCast(op.p2);
                        if (e.interrupted(n_vm_step, &progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    },
                    .frame_check => {
                        ops = e.ops.ptr;
                        pc = flow.to;
                        if (e.interrupted(n_vm_step, &progress_limit)) return e.abortDueToError(error.Interrupt, n_vm_step);
                    },
                    .ret => return e.vdbeReturn(n_vm_step),
                }
                continue :dispatch ops[pc].opcode;
            },
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
        if (v.err_msg == null and rc != RC.IOERR_NOMEM) aux.vdbeError(v, "{s}", .{util.errStr(rc)});
        v.rc = rc;
        e.logAbort(rc);
        if (v.e_vdbe_state == .run) aux.halt(v) catch {};
        if (rc == RC.CORRUPT and !db.auto_commit) db.flags.CorruptRdOnly = true;
        e.rc = RC.ERROR;
        if (e.reset_schema_on_fault) |i_db| @import("../sql/build.zig").resetOneSchema(db, i_db);
        return e.vdbeReturn(n_vm_step);
    }

    /// Port of sqlite3VdbeLogAbort(): the "statement aborts" message of
    /// the error log, for the instruction at `e.pc`.
    pub fn logAbort(e: *Exec, rc: i32) void {
        @branchHint(.cold);
        if (!util.logging()) return;
        const v = e.v;
        var extra: [100]u8 = undefined;
        var prefix: []const u8 = "";
        if (v.frame != null) {
            // The name of the trigger, from the "-- NAME" of its OP_Init.
            const init = e.ops[0];
            prefix = if (init.p4type == .z)
                std.fmt.bufPrint(&extra, "/* {s} */ ", .{std.mem.span(init.p4As(.z))[3..]}) catch extra[0..]
            else
                "/* unknown trigger */ ";
        }
        util.log(rc, "statement aborts at {d}: {s}; [{s}{s}]", .{
            e.pc,
            if (v.err_msg) |m| @as([]const u8, m) else "(null)",
            prefix,
            if (v.sql) |s| @as([]const u8, s) else "(null)",
        });
    }

    /// check_for_interrupt: whether the statement was interrupted, or the
    /// progress handler, if it is due (`limit` is the run loop's copy of
    /// the limit), asks to interrupt it.
    inline fn interrupted(e: *Exec, n_vm_step: u64, limit: *u64) bool {
        if (e.db.is_interrupted.load(.monotonic)) return true;
        return n_vm_step >= limit.* and e.progressInterrupts(limit);
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
        e.v.counters.getPtr(.vm_step).* +%= @truncate(n_vm_step);
        return e.rc;
    }
};
