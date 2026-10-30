//! Opcodes of control flow (vdbe.c): subroutines, co-routines, OP_Halt,
//! OP_Once and OP_Init, trigger programs (OP_Program, OP_Param) and the
//! counters that LIMIT, OFFSET and foreign keys use.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const int = @import("../../sql/sqlite_int.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const ENC = vi.ENC;
const VdbeCursor = vi.VdbeCursor;
const RC = int.RC;
const OE = int.OE;

pub fn opGosub(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(!in1.isDynamic());
    in1.flags = .{ .Int = true };
    in1.u = .{ .i = e.pc };
    return .jump_p2_check_interrupt;
}

pub fn opReturn(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    if (in1.flags.Int) {
        e.pc = @intCast(in1.u.i);
        return .goto_pc;
    }
    std.debug.assert(op.p3 != 0);
    return .next;
}

pub fn opInitCoroutine(e: *Exec, op: *Op) Flow {
    const out = e.reg(op.p1);
    std.debug.assert(!out.isDynamic());
    out.u = .{ .i = op.p3 - 1 };
    out.flags = .{ .Int = true };
    if (op.p2 == 0) return .next;
    return .jump_p2;
}

pub fn opEndCoroutine(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(in1.flags == MEM{ .Int = true });
    const caller = &e.ops[@intCast(in1.u.i)];
    std.debug.assert(caller.opcode == OP.Yield);
    in1.u = .{ .i = e.pc - 1 };
    e.pc = caller.p2 - 1;
    return .goto_pc;
}

pub fn opYield(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(!in1.isDynamic());
    in1.flags = .{ .Int = true };
    const dest = in1.u.i;
    in1.u = .{ .i = e.pc };
    e.pc = @intCast(dest);
    return .goto_pc;
}

pub fn opHaltIfNull(e: *Exec, op: *Op) Error!Flow {
    if (!e.reg(op.p3).flags.Null) return .next;
    return opHalt(e, op);
}

pub fn opHalt(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const db = e.db;
    std.debug.assert(op.p1 != RC.INTERNAL);
    if (v.frame != null and op.p1 == RC.OK) {
        // Return from a trigger program to its caller.
        const frame = v.frame.?;
        v.frame = frame.parent;
        v.n_frame -= 1;
        aux.setChanges(db, v.n_change);
        var pcx = aux.frameRestore(frame);
        if (op.p2 == OE.Ignore.int()) {
            // RAISE(IGNORE): continue at P2 of the calling OP_Program.
            pcx = v.ops.items[@intCast(pcx)].p2 - 1;
        }
        e.ops = v.ops.items;
        e.regs = v.mem;
        e.pc = pcx;
        return .goto_pc;
    }
    v.rc = op.p1;
    v.error_action = .fromInt(op.p2);
    std.debug.assert(op.p5 <= 4);
    if (v.rc != 0) {
        if (op.p3 > 0 and op.p4type == .notused) {
            const z = try mem.valueText(e.reg(op.p3), ENC.UTF8);
            aux.vdbeError(v, "{s}", .{if (z) |s| std.mem.span(s) else ""});
        } else if (op.p5 != 0) {
            const types = [_][]const u8{ "NOT NULL", "UNIQUE", "CHECK", "FOREIGN KEY" };
            if (op.p4type == .z) {
                aux.vdbeError(v, "{s} constraint failed: {s}", .{ types[op.p5 - 1], std.mem.span(op.p4.z) });
            } else {
                aux.vdbeError(v, "{s} constraint failed", .{types[op.p5 - 1]});
            }
        } else {
            aux.vdbeError(v, "{s}", .{if (op.p4type == .z) std.mem.span(op.p4.z) else ""});
        }
    }
    if (aux.halt(v)) |_| {
        e.rc = if (v.rc != 0) RC.ERROR else RC.DONE;
    } else |_| {
        v.rc = RC.BUSY;
        e.rc = RC.BUSY;
    }
    return .ret;
}

pub fn opOnce(e: *Exec, op: *Op) Flow {
    const v = e.v;
    std.debug.assert(e.ops[0].opcode == OP.Init);
    if (v.frame) |frame| {
        const addr: usize = @intCast(e.pc);
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
pub fn opInit(e: *Exec, op: *Op) Flow {
    if (op.p1 >= @import("../../sql/global.zig").testctrl.once_reset_threshold) {
        if (op.opcode == OP.Trace) return .next;
        for (e.ops[1..]) |*o| {
            if (o.opcode == OP.Once) o.p1 = 0;
        }
        op.p1 = 0;
    }
    op.p1 += 1;
    e.v.counters[vi.STMTSTATUS.RUN] += 1;
    return .jump_p2;
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
        .ops = v.ops.items,
        .mem = v.mem,
        .csr = v.csr,
        .once = once,
        .token = program.token,
        .last_rowid = 0,
        .aux_data = null,
        .pc = @intCast(e.pc),
        .n_change = 0,
        .n_db_change = 0,
        .child_mem = child_mem,
        .child_csr = child_csr,
    };
    return frame;
}

pub fn opProgram(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const db = e.db;
    const program = op.p4.subprogram;
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
    var frame: *vi.VdbeFrame = undefined;
    if (!rt.flags.Blob) {
        frame = try allocFrame(e, program);
        mem.release(rt);
        rt.flags = .{ .Blob = true, .Dyn = true };
        rt.z = @ptrCast(frame);
        rt.n = @sizeOf(vi.VdbeFrame);
        rt.x_del = int.destructor(frameMemDel);
    } else {
        frame = mem.dynObject(rt, frameMemDel).?;
    }
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
    v.ops.items = program.ops;
    e.ops = program.ops;
    e.regs = v.mem;
    e.pc = -1;
    return .goto_pc_check_interrupt;
}

pub fn opParam(e: *Exec, op: *Op) Flow {
    const out = e.out2Prerelease(op);
    const frame = e.v.frame.?;
    const in_ = &frame.mem[@intCast(op.p1 + frame.ops[@intCast(frame.pc)].p1)];
    mem.shallowCopy(out, in_, .{ .Ephem = true });
    return .next;
}

pub fn opFkCounter(e: *Exec, op: *Op) Flow {
    if (op.p1 != 0) {
        e.db.n_deferred_cons += op.p2;
    } else if (e.db.flags.DeferFKs) {
        e.db.n_deferred_imm_cons += op.p2;
    } else {
        e.v.n_fk_constraint += op.p2;
    }
    return .next;
}

pub fn opFkIfZero(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const zero = if (op.p1 != 0)
        db.n_deferred_cons == 0 and db.n_deferred_imm_cons == 0
    else
        e.v.n_fk_constraint == 0 and db.n_deferred_imm_cons == 0;
    return if (zero) .jump_p2 else .next;
}

pub fn opMemMax(e: *Exec, op: *Op) Flow {
    const in1 = e.rootReg(op.p1);
    mem.integerify(in1);
    const in2 = e.reg(op.p2);
    mem.integerify(in2);
    if (in1.u.i < in2.u.i) in1.u = .{ .i = in2.u.i };
    return .next;
}

pub fn opIfPos(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i > 0) {
        in1.u.i -= op.p3;
        return .jump_p2;
    }
    return .next;
}

pub fn opOffsetLimit(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const in3 = e.reg(op.p3);
    const out = e.out2Prerelease(op);
    const x = in1.u.i;
    const r = @addWithOverflow(x, if (in3.u.i > 0) in3.u.i else 0);
    out.u = .{ .i = if (x <= 0 or r[1] != 0) -1 else r[0] };
    return .next;
}

pub fn opIfNotZero(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i != 0) {
        if (in1.u.i > 0) in1.u.i -= 1;
        return .jump_p2;
    }
    return .next;
}

pub fn opDecrJumpZero(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    if (in1.u.i > std.math.minInt(i64)) in1.u.i -= 1;
    return if (in1.u.i == 0) .jump_p2 else .next;
}
