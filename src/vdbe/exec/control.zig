//! Opcodes of control flow (vdbe.c): subroutines, co-routines, OP_Halt,
//! OP_Once and OP_Init, trigger programs (OP_Program, OP_Param) and the
//! counters that LIMIT, OFFSET and foreign keys use.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../../dialect/dialect.zig");
const constraint = @import("../../dialect/constraint.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const Op = vi.Op;
const OpOf = vi.OpOf;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const ENC = vi.ENC;
const VdbeCursor = vi.VdbeCursor;
const RC = int.RC;
const OE = int.OE;

/// The opcodes this module runs, for the run loop (see exec.zig).
pub const handlers = .{
    .{ .ops = .{.Goto}, .f = opGoto },
    .{ .ops = .{.Gosub}, .f = opGosub },
    .{ .ops = .{.Return}, .f = opReturn },
    .{ .ops = .{.InitCoroutine}, .f = opInitCoroutine },
    .{ .ops = .{.EndCoroutine}, .f = opEndCoroutine },
    .{ .ops = .{.Yield}, .f = opYield, .call = .always_inline },
    .{ .ops = .{.HaltIfNull}, .f = opHaltIfNull },
    .{ .ops = .{.Halt}, .f = opHalt },
    .{ .ops = .{.Once}, .f = opOnce },
    .{ .ops = .{ .Trace, .Init }, .f = opInit },
    .{ .ops = .{.Program}, .f = opProgram },
    .{ .ops = .{.Param}, .f = opParam },
    .{ .ops = .{.FkCounter}, .f = opFkCounter },
    .{ .ops = .{.FkIfZero}, .f = opFkIfZero },
    .{ .ops = .{.MemMax}, .f = opMemMax },
    .{ .ops = .{.IfPos}, .f = opIfPos },
    .{ .ops = .{.OffsetLimit}, .f = opOffsetLimit },
    .{ .ops = .{.IfNotZero}, .f = opIfNotZero },
    .{ .ops = .{.DecrJumpZero}, .f = opDecrJumpZero },
};

pub fn opGoto(e: *Exec, op: *OpOf(.{ .int, .jump, .int })) Flow {
    _ = e;
    _ = op;
    return .jump_p2_check;
}

pub fn opGosub(e: *Exec, op: *OpOf(.{ .reg, .jump, .int })) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(!in1.isDynamic());
    in1.flags = .{ .Int = true };
    in1.u = .{ .i = e.pc };
    return .jump_p2_check;
}

pub fn opReturn(e: *Exec, op: *OpOf(.{ .reg, .addr, .int })) Flow {
    const in1 = e.reg(op.p1);
    // The address of the OP_Gosub: continue after it.
    if (in1.flags.Int) return .goto(@intCast(in1.u.i + 1));
    std.debug.assert(op.p3 != 0);
    return .next;
}

pub fn opInitCoroutine(e: *Exec, op: *OpOf(.{ .reg, .jump, .addr })) Flow {
    const out = e.reg(op.p1);
    std.debug.assert(!out.isDynamic());
    out.u = .{ .i = op.p3.int() - 1 };
    out.flags = .{ .Int = true };
    if (op.p2 == .none) return .next;
    return .jump_p2;
}

pub fn opEndCoroutine(e: *Exec, op: *OpOf(.{ .reg, .int, .int })) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(in1.flags == MEM{ .Int = true });
    const caller = e.opAt(.Yield, @intCast(in1.u.i));
    in1.u = .{ .i = @as(i64, e.pc) - 1 };
    return .goto(@intCast(caller.p2.int()));
}

pub fn opYield(e: *Exec, op: *OpOf(.{ .reg, .jump, .int })) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(!in1.isDynamic());
    in1.flags = .{ .Int = true };
    // The register holds the address of the other side's OP_Yield (or
    // one before its entry): continue after it, and leave ours.
    const dest = in1.u.i;
    in1.u = .{ .i = e.pc };
    return .goto(@intCast(dest + 1));
}

pub fn opHaltIfNull(e: *Exec, op: *OpOf(.{ .int, .int, .reg })) Error!Flow {
    if (!e.reg(op.p3).flags.Null) return .next;
    return opHalt(e, op);
}

pub fn opHalt(e: *Exec, op: *OpOf(.{ .int, .int, .reg })) Error!Flow {
    const v = e.v;
    const db = e.db;
    std.debug.assert(op.p1 != RC.INTERNAL);
    if (v.frame != null and op.p1 == RC.OK) {
        // Return from a trigger program to its caller.
        const frame = v.frame.?;
        v.frame = frame.parent;
        v.n_frame -= 1;
        aux.setChanges(db, v.n_change);
        const caller = aux.frameRestore(frame);
        e.ops = v.prog;
        e.regs = v.mem;
        // After the calling OP_Program, or for RAISE(IGNORE) at its P2.
        if (op.p2 == OE.Ignore.int()) return .frame(@intCast(e.opAt(.Program, caller).p2.int()));
        return .frame(caller + 1);
    }
    v.rc = op.p1;
    v.error_action = .fromInt(op.p2);
    std.debug.assert(op.p5 <= 4 or op.p5 & vi.P5_ConstraintDialect != 0);
    if (v.rc != 0) {
        if (op.p3 != .none and op.p4type == .notused) {
            const z = try mem.valueText(e.reg(op.p3), ENC.UTF8);
            aux.vdbeError(v, "{s}", .{if (z) |s| std.mem.span(s) else ""});
        } else if (op.p5 & vi.P5_ConstraintDialect != 0) {
            try dialectConstraintError(e, op.raw());
        } else if (op.p5 != 0) {
            const types = [_][]const u8{ "NOT NULL", "UNIQUE", "CHECK", "FOREIGN KEY" };
            if (op.p4type == .z) {
                const name = std.mem.span(op.p4As(.z));
                aux.vdbeError(v, "{s} constraint failed: {s}", .{ types[op.p5 - 1], name });
                // P5_ConstraintCheck: a dialect's type check.
                if (op.p5 == 3) if (dialect.checkState(name)) |st| {
                    v.err_state = st;
                };
            } else {
                aux.vdbeError(v, "{s} constraint failed", .{types[op.p5 - 1]});
            }
        } else {
            aux.vdbeError(v, "{s}", .{if (op.p4type == .z) std.mem.span(op.p4As(.z)) else ""});
        }
        e.logAbort(op.p1);
    }
    if (aux.halt(v)) |_| {
        e.rc = if (v.rc != 0) RC.ERROR else RC.DONE;
    } else |_| {
        v.rc = RC.BUSY;
        e.rc = RC.BUSY;
    }
    return .ret;
}

/// The error of a constraint in the words of the dialect the statement
/// was compiled in (P5_ConstraintDialect): P4, with the values of the
/// key or the row at dialect.value_mark (constraint.render()).
fn dialectConstraintError(e: *Exec, op: *const Op) Error!void {
    @branchHint(.cold);
    const v = e.v;
    const d = constraint.decode(std.mem.span(op.p4As(.z)));
    const msg, const state = try constraint.render(e.db.gpa, v.xq_lang.dialect, d, e);
    defer e.db.gpa.free(msg);
    aux.vdbeErrorState(v, state, "{s}", .{msg});
}

pub fn opOnce(e: *Exec, op: *OpOf(.{ .int, .jump, .int })) Flow {
    const v = e.v;
    std.debug.assert(e.ops[0].opcode == OP.Init);
    if (v.frame) |frame| {
        const addr = e.pc;
        const bit: u8 = @as(u8, 1) << @intCast(addr & 7);
        if (frame.once[addr / 8] & bit != 0) return .jump_p2;
        frame.once[addr / 8] |= bit;
    } else {
        if (e.ops[0].p1 == op.p1) return .jump_p2;
    }
    op.p1 = e.ops[0].p1;
    return .next;
}

/// OP_Init and OP_Trace.
pub fn opInit(e: *Exec, op: anytype, comptime opc: OP) Flow {
    if (e.db.m_trace & (int.TRACE.STMT | int.TRACE.LEGACY) != 0 and e.v.min_write_file_format != 254) traceStmt(e, op.raw());
    if (op.p1 >= @import("../../sql/global.zig").testctrl.once_reset_threshold) {
        if (opc == .Trace) return .next;
        for (e.ops[1..]) |*o| {
            if (o.opcode == OP.Once) o.p1 = 0;
        }
        op.p1 = 0;
    }
    op.p1 += 1;
    e.v.counters[vi.STMTSTATUS.RUN] += 1;
    return .jump_p2;
}

/// The SQLITE_TRACE_STMT of OP_Init (the statement's SQL) and OP_Trace
/// (the "-- " comment of a trigger or one of its statements). A
/// statement run by another (from a function) is traced as a comment.
noinline fn traceStmt(e: *Exec, op: *Op) void {
    const db = e.db;
    const v = e.v;
    const z: [*:0]const u8 = if (op.p4type == .z) op.p4As(.z) else if (v.sql) |s| s.ptr else return;
    if (db.m_trace & int.TRACE.LEGACY != 0) {
        db.trace_legacy.?(db.trace_arg, v, z);
    } else if (db.n_vdbe_exec > 1) {
        const c = std.fmt.allocPrintSentinel(db.gpa, "-- {s}", .{std.mem.span(z)}, 0) catch return db.oomFault();
        defer db.gpa.free(c);
        _ = db.trace_v2.?(int.TRACE.STMT, db.trace_arg, v, @ptrCast(@constCast(c.ptr)));
    } else {
        _ = db.trace_v2.?(int.TRACE.STMT, db.trace_arg, v, @ptrCast(@constCast(z)));
    }
}

// ========================================================= trigger programs

/// sqlite3VdbeFrameMemDel(): the destructor of the register holding a
/// trigger frame; the frame is freed when the statement halts.
fn frameMemDel(frame: *vi.VdbeFrame) void {
    frame.parent = frame.v.del_frame;
    frame.v.del_frame = frame;
}

/// The frame of a trigger program: its registers, cursors and OP_Once
/// flags.
fn allocFrame(e: *Exec, program: *vi.SubProgram) error{OutOfMemory}!*vi.VdbeFrame {
    const v = e.v;
    const gpa = e.db.gpa;
    var n_mem: usize = @intCast(program.n_mem + program.n_csr);
    if (program.n_csr == 0) n_mem += 1;
    const frame = try gpa.create(vi.VdbeFrame);
    errdefer gpa.destroy(frame);
    const child_mem = try gpa.alloc(Mem, n_mem);
    errdefer gpa.free(child_mem);
    const child_csr = try gpa.alloc(?*VdbeCursor, @intCast(program.n_csr));
    errdefer gpa.free(child_csr);
    const once = try gpa.alloc(u8, (program.ops.len + 7) / 8);
    aux.initMemArray(child_mem, e.db, MEM.Undefined);
    @memset(child_csr, null);
    frame.* = .{
        .v = v,
        .parent = null,
        .ops = v.prog,
        .mem = v.mem,
        .csr = v.csr,
        .once = once,
        .token = program.token,
        .last_rowid = 0,
        .aux_data = null,
        .pc = e.pc,
        .n_change = 0,
        .n_db_change = 0,
        .child_mem = child_mem,
        .child_csr = child_csr,
    };
    return frame;
}

pub fn opProgram(e: *Exec, op: *OpOf(.{ .reg, .jump, .reg })) Error!Flow {
    const v = e.v;
    const db = e.db;
    const program = op.p4As(.subprogram);
    const rt = e.reg(op.p3);
    if (op.p5 != 0) {
        // Recursive triggers are off: skip if already running.
        var f = v.frame;
        while (f) |frame| : (f = frame.parent) {
            if (frame.token == program.token) return .next;
        }
    }
    if (v.n_frame >= db.limit(.trigger_depth)) {
        aux.vdbeError(v, "triggers nested too deep", .{});
        return error.Error;
    }
    // The frame is made on the first run and kept in register P3.
    const frame = if (rt.flags.Blob) mem.dynObject(rt, frameMemDel).? else blk: {
        const f = try allocFrame(e, program);
        mem.release(rt);
        rt.flags = .{ .Blob = true, .Dyn = true };
        rt.z = @ptrCast(f);
        rt.n = @sizeOf(vi.VdbeFrame);
        rt.x_del = int.destructor(frameMemDel);
        break :blk f;
    };
    v.n_frame += 1;
    frame.parent = v.frame;
    frame.last_rowid = db.last_rowid;
    frame.n_change = v.n_change;
    frame.n_db_change = db.n_change;
    frame.aux_data = v.aux_data;
    v.aux_data = null;
    v.n_change = 0;
    v.frame = frame;
    v.mem = frame.child_mem;
    v.csr = frame.child_csr;
    @memset(frame.once, 0);
    v.prog = program.ops;
    e.ops = program.ops;
    e.regs = v.mem;
    return .frameCheck(0);
}

pub fn opParam(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Flow {
    const out = e.out2Prerelease(op);
    const frame = e.v.frame.?;
    // Register P1 of those of the trigger's arguments in the calling
    // frame, which start at P1 of its OP_Program.
    const caller = vi.opAs(&frame.ops[frame.pc], .Program);
    const in_ = &frame.mem[@intCast(caller.p1.at(op.p1).int())];
    mem.shallowCopy(out, in_, .{ .Ephem = true });
    return .next;
}

pub fn opFkCounter(e: *Exec, op: *OpOf(.{ .int, .int, .int })) Error!Flow {
    const counter: *i64 = if (op.p1 != 0)
        &e.db.n_deferred_cons
    else if (e.db.flags.DeferFKs)
        &e.db.n_deferred_imm_cons
    else
        &e.v.n_fk_constraint;
    // xqlite: P4 is the dialect's error of the violation counted, with
    // the values of its key now (Vdbe.xq_fk_owned).
    if (op.p4type == .z) try fkCounted(e, op.raw(), counter.*);
    counter.* += op.p2;
    return .next;
}

/// Make P4 of OP_FkCounter `op` the error of the foreign key, written
/// with the values of the registers it lists if it lists any
/// (constraint.render()). Only for the violation that makes the count
/// (`count` before it) not zero, or the first of the statement: while
/// the count is not zero, that violation is the error, as PostgreSQL
/// reports the first row that fails.
fn fkCounted(e: *Exec, op: *const Op, count: i64) error{OutOfMemory}!void {
    const v = e.v;
    if (op.p2 <= 0 or (count != 0 and v.xq_fk_error != null)) return;
    const z = std.mem.span(op.p4As(.z));
    const d = constraint.decode(z);
    if (d.values.len == 0) {
        v.xq_fk_error = op.p4As(.z);
        return;
    }
    const gpa = e.db.gpa;
    const msg, const state = try constraint.render(gpa, v.xq_lang.dialect, d, e);
    defer gpa.free(msg);
    const owned = try constraint.encodeError(gpa, state, msg);
    if (v.xq_fk_owned) |old| gpa.free(old);
    v.xq_fk_owned = owned;
    v.xq_fk_error = owned.ptr;
}

pub fn opFkIfZero(e: *Exec, op: *OpOf(.{ .int, .jump, .int })) Flow {
    const db = e.db;
    const zero = if (op.p1 != 0)
        db.n_deferred_cons == 0 and db.n_deferred_imm_cons == 0
    else
        e.v.n_fk_constraint == 0 and db.n_deferred_imm_cons == 0;
    return if (zero) .jump_p2 else .next;
}

pub fn opMemMax(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Flow {
    const in1 = e.rootReg(op.p1);
    mem.integerify(in1);
    const in2 = e.reg(op.p2);
    mem.integerify(in2);
    if (in1.u.i < in2.u.i) in1.u = .{ .i = in2.u.i };
    return .next;
}

pub fn opIfPos(e: *Exec, op: *OpOf(.{ .reg, .jump, .int })) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i > 0) {
        in1.u.i -= op.p3;
        return .jump_p2;
    }
    return .next;
}

pub fn opOffsetLimit(e: *Exec, op: *OpOf(.{ .reg, .reg, .reg })) Flow {
    const in1 = e.reg(op.p1);
    const in3 = e.reg(op.p3);
    const out = e.out2Prerelease(op);
    const x = in1.u.i;
    const r = @addWithOverflow(x, if (in3.u.i > 0) in3.u.i else 0);
    out.u = .{ .i = if (x <= 0 or r[1] != 0) -1 else r[0] };
    return .next;
}

pub fn opIfNotZero(e: *Exec, op: *OpOf(.{ .reg, .jump, .int })) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i != 0) {
        if (in1.u.i > 0) in1.u.i -= 1;
        return .jump_p2;
    }
    return .next;
}

pub fn opDecrJumpZero(e: *Exec, op: *OpOf(.{ .reg, .jump, .int })) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i > std.math.minInt(i64)) in1.u.i -= 1;
    return if (in1.u.i == 0) .jump_p2 else .next;
}
