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
//! A handler takes its instruction as a vi.OpOf(): P1, P2 and P3 with the
//! types OP.kinds() gives them (operand.Reg, operand.Cursor, a jump
//! or an address, or a number), checked at compile time against the
//! opcodes it runs (see `modules`). Registers and cursors are reached
//! through them, `e.reg(op.p3)`, `e.csr(op.p1)`, `e.regsFrom(op.p2)`,
//! so that a handler that reads a cursor where the opcode has a register
//! does not compile, as aux.emit() does not let the code generator pass
//! one for the other. A number that is a register only under a flag of
//! P5 (OP_OpenWrite's P2 with OpenP5.p2_is_reg) is `.int` in the table and
//! converted with `.from()` where the handler tests the flag. P5 is a
//! number, or for the opcodes whose P5 is a set of flags the packed
//! struct of their family (vi.OpWithP5(), p5.zig).
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

/// The modules of handlers. Each declares `handlers`, a tuple of entries
/// `.{ .ops = .{ .Add, .Subtract, ... }, .f = opArith }` naming the
/// opcodes a function runs, with `.call = .always_inline` where the run
/// loop is to inline it. The function is `fn (*Exec, *OpOf(shape)) Flow`
/// (or `Error!Flow`), or takes a third parameter `comptime opc: OP`, the
/// opcode it runs, if it runs several and tells them apart.
///
/// The second parameter is the instruction with its operands typed (see
/// vi.OpOf()). `shape` is what the handler takes P1, P2 and P3 to be,
/// `.{ .reg, .jump, .int }` and the like, and must be OP.kinds() of
/// every opcode it runs: the handler of OP_Gosub cannot read its P1 as a
/// cursor, and an entry of the kinds table that does not say what the
/// handler reads does not compile. A handler of opcodes whose operands
/// differ (OP_Last and OP_SeekEnd) takes `op: anytype` with the opcode,
/// and gets the shape of each opcode in its copy for that opcode; one
/// that reads no operand takes `*OpOf(null)`. An opcode whose P5 is a set
/// of flags (OP.P5(), p5.zig) has a handler that takes
/// `*OpWithP5(shape, ItsP5)`, so that it cannot read another family's
/// flags.
///
/// Inlined are the handlers of the opcodes of inner loops (stepping and
/// seeking cursors, OP_Column, register copies, arithmetic, comparisons,
/// jumps, co-routines, aggregate steps and functions, building and
/// inserting rows): measured with `xqt bench`, 15% on cte and 6-7% on
/// insert, scan and pklookup; inlining only the small ones of them gave
/// about half of that.
const modules = .{ control, register, arith, record, txn, cursor, btree_ops, agg, vtab_ops, misc };

const HandlerAt = struct { module: usize, entry: usize };

/// For each opcode (by value), the module and entry of its handler. An
/// opcode with no handler or with two is a compile error.
const handler_index: [256]?HandlerAt = blk: {
    @setEvalBranchQuota(100_000);
    var index: [256]?HandlerAt = @splat(null);
    for (modules, 0..) |m, mi| {
        for (m.handlers, 0..) |h, hi| {
            for (h.ops) |o| {
                const opc: OP = o;
                if (index[@backingInt(opc)] != null) @compileError("two handlers for OP_" ++ @tagName(opc));
                index[@backingInt(opc)] = .{ .module = mi, .entry = hi };
            }
        }
    }
    const info = @typeInfo(OP).@"enum";
    for (info.field_names, info.field_values) |name, value| {
        if (index[value] == null) @compileError("no handler for OP_" ++ name);
    }
    break :blk index;
};

/// The handler of opcode `opc` and how the run loop calls it.
fn handler(comptime opc: OP) type {
    const at = handler_index[@backingInt(opc)].?;
    const entry = modules[at.module].handlers[at.entry];
    const params = @typeInfo(@TypeOf(entry.f)).@"fn".param_types;
    const name = "the handler of OP_" ++ @tagName(opc);
    return struct {
        const f = entry.f;
        const call: std.builtin.CallModifier = if (@hasField(@TypeOf(entry), "call")) entry.call else .auto;
        const takes_opc = params.len == 3;
        /// The type of the instruction it takes: its own, which must
        /// fit the opcode, or the opcode's for `op: anytype`.
        const Ins = if (params[1]) |P| blk: {
            const pointer = switch (@typeInfo(P)) {
                .pointer => |p| p,
                else => @compileError(name ++ " takes " ++ @typeName(P) ++ ", not *OpOf(shape)"),
            };
            const V = pointer.child;
            if (!@hasDecl(V, "kinds") or !@hasDecl(V, "P5Type") or V != vi.OpWithP5(V.kinds, V.P5Type)) @compileError(name ++ " takes " ++ @typeName(P) ++ ", not *OpOf(shape)");
            if (V.kinds) |k| if (!std.meta.eql(k, opc.kinds())) {
                @compileError(name ++ " takes its operands to be " ++ shapeName(k) ++ ", OP.kinds() says " ++ shapeName(opc.kinds()));
            };
            if (V.P5Type != opc.P5()) @compileError(name ++ " takes P5 as " ++ @typeName(V.P5Type) ++ ", OP.P5() says " ++ @typeName(opc.P5()));
            break :blk P;
        } else blk: {
            if (!takes_opc) @compileError(name ++ " takes `op: anytype` without the opcode");
            break :blk *vi.OpFor(opc);
        };
    };
}

fn shapeName(comptime k: [3]operand.Kind) []const u8 {
    return ".{ ." ++ @tagName(k[0]) ++ ", ." ++ @tagName(k[1]) ++ ", ." ++ @tagName(k[2]) ++ " }";
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

    // The registers and cursors that operands name. A handler passes an
    // operand of its OpOf() (`e.reg(op.p1)`), which has the type the
    // kinds table gives it, or the register after one
    // (`e.reg(op.p2.at(i))`). A number that is a register only in some
    // uses of the opcode (`.int` in the table) is converted where the
    // handler knows it is one, with `Reg.from()` (OP_OpenWrite's P2 under
    // OpenP5.p2_is_reg), as is an operand of another instruction than the
    // handler's own if it is not read through opAt().

    pub fn reg(e: *Exec, r: Reg) *Mem {
        return &e.regs[@intCast(r.int())];
    }

    /// The registers from `r` on, as an UnpackedRecord takes them.
    pub fn regsFrom(e: *Exec, r: Reg) [*]Mem {
        return e.regs[@intCast(r.int())..].ptr;
    }

    /// The `n` registers from `r` on.
    pub fn regRange(e: *Exec, r: Reg, n: usize) []Mem {
        return e.regs[@intCast(r.int())..][0..n];
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
