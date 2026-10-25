//! The bytecode interpreter (port of vdbe.c, sqlite3VdbeExec).
//!
//! Each opcode is a method of `Exec` returning a `Flow`, which stands in
//! for the gotos of the C code: `.next` continues, `.jump_p2` goes to P2,
//! and the error flows end the run. As in C, a handler may set `pc` to the
//! instruction before the one to run next.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const aux = @import("aux.zig");
const serial = @import("serial.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const main_mod = @import("../sql/main.zig");
const btree = @import("../btree/btree.zig");
const varint = @import("../util/varint.zig");
const sorter = @import("sorter.zig");
const rowset = @import("rowset.zig");

const Vdbe = vi.Vdbe;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const ENC = vi.ENC;
const VdbeCursor = vi.VdbeCursor;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;
const OE = int.OE;
const Aff = int.Aff;

const Flow = enum {
    next,
    /// Check for an interrupt, then continue.
    check_interrupt,
    jump_p2,
    jump_p2_check_interrupt,
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

const Exec = struct {
    v: *Vdbe,
    db: *Sqlite3,
    /// The program and registers of the current frame (aOp, aMem).
    ops: []Op,
    regs: []Mem,
    /// Address of the current instruction.
    pc: isize,
    rc: i32 = RC.OK,
    encoding: u8,
    /// Result of the last OP_Compare.
    i_compare: i32 = 0,
    n_vm_step: u64 = 0,
    /// Reset this schema (plus one) after an error.
    reset_schema_on_fault: u8 = 0,

    fn reg(e: *Exec, i: i32) *Mem {
        return &e.regs[@intCast(i)];
    }

    /// Register `i` of the main program, even inside a trigger.
    fn rootReg(e: *Exec, i: i32) *Mem {
        const frame = vi.rootFrame(e.v.frame orelse return e.reg(i));
        return &frame.mem[@intCast(i)];
    }

    /// Cursor `i`, which must be open.
    fn csr(e: *Exec, i: i32) *VdbeCursor {
        return e.v.csr[@intCast(i)].?;
    }

    /// The flow for a failure of a lower layer.
    fn fail(e: *Exec, err: anyerror) Flow {
        e.rc = main_mod.errorCode(err);
        return .abort;
    }

    fn run(e: *Exec) i32 {
        const v = e.v;
        const db = e.db;
        if (v.rc == RC.NOMEM) return e.finish(.no_mem);
        v.rc = RC.OK;
        v.i_current_time = 0;
        if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt);
        while (true) {
            const op = &e.ops[@intCast(e.pc)];
            e.n_vm_step += 1;
            const flow = e.dispatch(op);
            switch (flow) {
                .next => {},
                .jump_p2 => e.pc = op.p2 - 1,
                .check_interrupt => if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt),
                .jump_p2_check_interrupt => {
                    e.pc = op.p2 - 1;
                    if (db.is_interrupted.load(.monotonic)) return e.finish(.interrupt);
                },
                else => return e.finish(flow),
            }
            e.pc += 1;
        }
    }

    /// The tail of sqlite3VdbeExec(): too_big, no_mem,
    /// abort_due_to_interrupt, abort_due_to_error and vdbe_return.
    fn finish(e: *Exec, flow_arg: Flow) i32 {
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
                db.malloc_failed = true;
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
        v.counters[vi.STMTSTATUS.VM_STEP] +%= @truncate(e.n_vm_step);
        return e.rc;
    }

    /// Port of out2Prerelease(): register P2, ready to take an integer.
    fn out2Prerelease(e: *Exec, op: *const Op) *Mem {
        const out = e.reg(op.p2);
        if (out.isDynamic()) mem.setNull(out);
        out.flags = MEM.Int;
        return out;
    }

    /// The Part structs only group the handlers: their switches are inlined
    /// so that, as in C, one switch dispatches every opcode.
    inline fn dispatch(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.Goto => .jump_p2_check_interrupt,
            OP.Gosub => e.opGosub(op),
            OP.Return => e.opReturn(op),
            OP.InitCoroutine => e.opInitCoroutine(op),
            OP.EndCoroutine => e.opEndCoroutine(op),
            OP.Yield => e.opYield(op),
            OP.HaltIfNull => e.opHaltIfNull(op),
            OP.Halt => e.opHalt(op),
            OP.Integer => e.opInteger(op),
            OP.Int64 => e.opInt64(op),
            OP.Real => e.opReal(op),
            OP.String8 => e.opString8(op),
            OP.String => e.opString(op),
            else => Part2.dispatch2(e, op),
        };
    }

    // ============================================================ control

    fn opGosub(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        std.debug.assert(!in1.isDynamic());
        in1.flags = MEM.Int;
        in1.u = .{ .i = e.pc };
        return .jump_p2_check_interrupt;
    }

    fn opReturn(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        if (in1.flags & MEM.Int != 0) {
            e.pc = @intCast(in1.u.i);
        } else {
            std.debug.assert(op.p3 != 0);
        }
        return .next;
    }

    fn opInitCoroutine(e: *Exec, op: *Op) Flow {
        const out = e.reg(op.p1);
        std.debug.assert(!out.isDynamic());
        out.u = .{ .i = op.p3 - 1 };
        out.flags = MEM.Int;
        if (op.p2 == 0) return .next;
        return .jump_p2;
    }

    fn opEndCoroutine(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        std.debug.assert(in1.flags == MEM.Int);
        const caller = &e.ops[@intCast(in1.u.i)];
        std.debug.assert(caller.opcode == OP.Yield);
        in1.u = .{ .i = e.pc - 1 };
        e.pc = caller.p2 - 1;
        return .next;
    }

    fn opYield(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        std.debug.assert(!in1.isDynamic());
        in1.flags = MEM.Int;
        const dest = in1.u.i;
        in1.u = .{ .i = e.pc };
        e.pc = @intCast(dest);
        return .next;
    }

    fn opHaltIfNull(e: *Exec, op: *Op) Flow {
        if (e.reg(op.p3).flags & MEM.Null == 0) return .next;
        return e.opHalt(op);
    }

    fn opHalt(e: *Exec, op: *Op) Flow {
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
            if (op.p2 == OE.Ignore) {
                // RAISE(IGNORE): continue at P2 of the calling OP_Program.
                pcx = v.ops.items[@intCast(pcx)].p2 - 1;
            }
            e.ops = v.ops.items;
            e.regs = v.mem;
            e.pc = pcx;
            return .next;
        }
        v.rc = op.p1;
        v.error_action = @intCast(op.p2);
        std.debug.assert(op.p5 <= 4);
        if (v.rc != 0) {
            if (op.p3 > 0 and op.p4 == .notused) {
                const z = mem.valueText(e.reg(op.p3), ENC.UTF8) catch return .no_mem;
                aux.vdbeError(v, "{s}", .{if (z) |s| std.mem.span(s) else ""});
            } else if (op.p5 != 0) {
                const types = [_][]const u8{ "NOT NULL", "UNIQUE", "CHECK", "FOREIGN KEY" };
                if (op.p4 == .z) {
                    aux.vdbeError(v, "{s} constraint failed: {s}", .{ types[op.p5 - 1], op.p4.z });
                } else {
                    aux.vdbeError(v, "{s} constraint failed", .{types[op.p5 - 1]});
                }
            } else {
                aux.vdbeError(v, "{s}", .{if (op.p4 == .z) op.p4.z else ""});
            }
        }
        const rc = aux.halt(v);
        std.debug.assert(rc == RC.BUSY or rc == RC.OK or rc == RC.ERROR);
        if (rc == RC.BUSY) {
            v.rc = RC.BUSY;
            e.rc = RC.BUSY;
        } else {
            e.rc = if (v.rc != 0) RC.ERROR else RC.DONE;
        }
        return .ret;
    }

    // ========================================================== constants

    fn opInteger(e: *Exec, op: *Op) Flow {
        e.out2Prerelease(op).u = .{ .i = op.p1 };
        return .next;
    }

    fn opInt64(e: *Exec, op: *Op) Flow {
        e.out2Prerelease(op).u = .{ .i = int32To64(op.p1, op.p3) };
        return .next;
    }

    fn opReal(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        out.flags = MEM.Real;
        out.u = .{ .r = @bitCast(int32To64(op.p1, op.p3)) };
        return .next;
    }

    fn opString8(e: *Exec, op: *Op) Flow {
        _ = e.out2Prerelease(op);
        op.p1 = @intCast(op.p4.z.len);
        std.debug.assert(e.encoding == ENC.UTF8);
        if (op.p1 > e.db.limit(.length)) return .too_big;
        op.opcode = OP.String;
        return e.opString(op);
    }

    fn opString(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        out.flags = MEM.Str | MEM.Static | MEM.Term;
        out.z = @constCast(op.p4.z.ptr);
        out.n = op.p1;
        out.enc = e.encoding;
        if (op.p3 > 0) {
            const in3 = e.reg(op.p3);
            std.debug.assert(in3.flags & MEM.Int != 0);
            if (in3.u.i == op.p5) out.flags = MEM.Blob | MEM.Static | MEM.Term;
        }
        return .next;
    }
};

// ===================================================================
// Part 2: registers, results and arithmetic.

const Part2 = struct {
    inline fn dispatch2(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.BeginSubrtn, OP.Null => opNull(e, op),
            OP.SoftNull => opSoftNull(e, op),
            OP.Blob => opBlob(e, op),
            OP.Variable => opVariable(e, op),
            OP.Move => opMove(e, op),
            OP.Copy => opCopy(e, op),
            OP.SCopy => opSCopy(e, op),
            OP.IntCopy => opIntCopy(e, op),
            OP.FkCheck => opFkCheck(e, op),
            OP.ResultRow => opResultRow(e, op),
            OP.Concat => opConcat(e, op),
            OP.Add, OP.Subtract, OP.Multiply, OP.Divide, OP.Remainder => opArith(e, op),
            OP.CollSeq => opCollSeq(e, op),
            else => Part3.dispatch3(e, op),
        };
    }

    fn opNull(e: *Exec, op: *Op) Flow {
        var out = e.out2Prerelease(op);
        var cnt = op.p3 - op.p2;
        const null_flag: u16 = if (op.p1 != 0) MEM.Null | MEM.Cleared else MEM.Null;
        out.flags = null_flag;
        out.n = 0;
        var i = op.p2;
        while (cnt > 0) : (cnt -= 1) {
            i += 1;
            out = e.reg(i);
            mem.setNull(out);
            out.flags = null_flag;
            out.n = 0;
        }
        return .next;
    }

    fn opSoftNull(e: *Exec, op: *Op) Flow {
        const out = e.reg(op.p1);
        out.flags = (out.flags & ~(MEM.Undefined | MEM.AffMask)) | MEM.Null;
        return .next;
    }

    fn opBlob(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        if (op.p4 != .z) {
            mem.setZeroBlob(out, op.p1);
            mem.expandBlob(out) catch return .no_mem;
        } else {
            mem.setStr(out, op.p4.z[0..@intCast(op.p1)], 0, .static) catch {};
        }
        out.enc = e.encoding;
        return .next;
    }

    fn opVariable(e: *Exec, op: *Op) Flow {
        const v = e.v;
        std.debug.assert(op.p1 > 0 and op.p1 <= v.n_var);
        const var_ = &v.vars[@intCast(op.p1 - 1)];
        if (mem.tooBig(var_)) return .too_big;
        const out = e.reg(op.p2);
        if (out.isDynamic()) mem.setNull(out);
        out.u = var_.u;
        out.z = var_.z;
        out.n = var_.n;
        out.flags = var_.flags;
        out.enc = var_.enc;
        out.e_subtype = var_.e_subtype;
        out.flags &= ~(MEM.Dyn | MEM.Ephem);
        out.flags |= MEM.Static | MEM.FromBind;
        return .next;
    }

    fn opMove(e: *Exec, op: *Op) Flow {
        var n = op.p3;
        var p1 = op.p1;
        var p2 = op.p2;
        std.debug.assert(n > 0 and p1 > 0 and p2 > 0);
        std.debug.assert(p1 + n <= p2 or p2 + n <= p1);
        while (n > 0) : (n -= 1) {
            const out = e.reg(p2);
            mem.move(out, e.reg(p1));
            if (out.flags & MEM.Ephem != 0) mem.makeWriteable(out) catch return .no_mem;
            p1 += 1;
            p2 += 1;
        }
        return .next;
    }

    fn opCopy(e: *Exec, op: *Op) Flow {
        var n = op.p3;
        var in1 = op.p1;
        var outr = op.p2;
        std.debug.assert(in1 != outr);
        while (true) {
            const out = e.reg(outr);
            mem.shallowCopy(out, e.reg(in1), MEM.Ephem);
            if (out.flags & MEM.Ephem != 0) mem.makeWriteable(out) catch return .no_mem;
            if (out.flags & MEM.Subtype != 0 and op.p5 & 0x0002 != 0) out.flags &= ~MEM.Subtype;
            if (n == 0) break;
            n -= 1;
            outr += 1;
            in1 += 1;
        }
        return .next;
    }

    fn opSCopy(e: *Exec, op: *Op) Flow {
        std.debug.assert(op.p1 != op.p2);
        mem.shallowCopy(e.reg(op.p2), e.reg(op.p1), MEM.Ephem);
        return .next;
    }

    fn opIntCopy(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        std.debug.assert(in1.flags & MEM.Int != 0);
        mem.setInt64(e.reg(op.p2), in1.u.i);
        return .next;
    }

    fn opFkCheck(e: *Exec, op: *Op) Flow {
        _ = op;
        e.rc = aux.checkFkImmediate(e.v);
        if (e.rc != RC.OK) return .abort;
        return .next;
    }

    fn opResultRow(e: *Exec, op: *Op) Flow {
        const v = e.v;
        std.debug.assert(v.n_res_column == op.p2);
        v.cache_ctr = (v.cache_ctr + 2) | 1;
        v.result_row = e.regs.ptr + @as(usize, @intCast(op.p1));
        if (e.db.malloc_failed) return .no_mem;
        v.pc = @intCast(e.pc + 1);
        e.rc = RC.ROW;
        return .ret;
    }

    fn opConcat(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        const in2 = e.reg(op.p2);
        const out = e.reg(op.p3);
        std.debug.assert(in1 != out);
        var flags1 = in1.flags;
        if ((flags1 | in2.flags) & MEM.Null != 0) {
            mem.setNull(out);
            return .next;
        }
        if (flags1 & (MEM.Str | MEM.Blob) == 0) {
            mem.stringify(in1, e.encoding, false) catch return .no_mem;
            flags1 = in1.flags & ~MEM.Str;
        } else if (flags1 & MEM.Zero != 0) {
            mem.expandBlob(in1) catch return .no_mem;
            flags1 = in1.flags & ~MEM.Str;
        }
        var flags2 = in2.flags;
        if (flags2 & (MEM.Str | MEM.Blob) == 0) {
            mem.stringify(in2, e.encoding, false) catch return .no_mem;
            flags2 = in2.flags & ~MEM.Str;
        } else if (flags2 & MEM.Zero != 0) {
            mem.expandBlob(in2) catch return .no_mem;
            flags2 = in2.flags & ~MEM.Str;
        }
        const n_byte: i64 = @as(i64, in1.n) + in2.n;
        if (n_byte > e.db.limit(.length)) return .too_big;
        if (n_byte > 2147483645) return .too_big;
        mem.grow(out, @intCast(n_byte + 2), out == in2) catch return .no_mem;
        out.setTypeFlag(MEM.Str);
        const n2: usize = @intCast(in2.n);
        if (out != in2) {
            @memcpy(out.z.?[0..n2], in2.bytes());
            in2.flags = flags2;
        }
        @memcpy(out.z.?[n2..][0..@intCast(in1.n)], in1.bytes());
        in1.flags = flags1;
        const nb: usize = @intCast(n_byte);
        out.z.?[nb] = 0;
        out.z.?[nb + 1] = 0;
        out.flags |= MEM.Term;
        out.n = @intCast(n_byte);
        out.enc = e.encoding;
        return .next;
    }

    fn opArith(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        const in2 = e.reg(op.p2);
        const out = e.reg(op.p3);
        var type1 = in1.flags;
        var type2 = in2.flags;
        if (type1 & type2 & MEM.Int == 0) {
            if ((type1 | type2) & MEM.Null != 0) {
                mem.setNull(out);
                return .next;
            }
            type1 = mem.numericType(in1);
            type2 = mem.numericType(in2);
        }
        if (type1 & type2 & MEM.Int != 0) int_math: {
            const ia = in1.u.i;
            var ib = in2.u.i;
            switch (op.opcode) {
                OP.Add => {
                    const r = @addWithOverflow(ib, ia);
                    if (r[1] != 0) break :int_math;
                    ib = r[0];
                },
                OP.Subtract => {
                    const r = @subWithOverflow(ib, ia);
                    if (r[1] != 0) break :int_math;
                    ib = r[0];
                },
                OP.Multiply => {
                    const r = @mulWithOverflow(ib, ia);
                    if (r[1] != 0) break :int_math;
                    ib = r[0];
                },
                OP.Divide => {
                    if (ia == 0) {
                        mem.setNull(out);
                        return .next;
                    }
                    if (ia == -1 and ib == std.math.minInt(i64)) break :int_math;
                    ib = @divTrunc(ib, ia);
                },
                else => {
                    if (ia == 0) {
                        mem.setNull(out);
                        return .next;
                    }
                    ib = @rem(ib, if (ia == -1) 1 else ia);
                },
            }
            out.u = .{ .i = ib };
            out.setTypeFlag(MEM.Int);
            return .next;
        }
        // fp_math:
        const ra = mem.realValue(in1);
        var rb = mem.realValue(in2);
        switch (op.opcode) {
            OP.Add => rb += ra,
            OP.Subtract => rb -= ra,
            OP.Multiply => rb *= ra,
            OP.Divide => {
                if (ra == 0.0) {
                    mem.setNull(out);
                    return .next;
                }
                rb /= ra;
            },
            else => {
                var ia = mem.intValue(in1);
                const ib = mem.intValue(in2);
                if (ia == 0) {
                    mem.setNull(out);
                    return .next;
                }
                if (ia == -1) ia = 1;
                rb = @floatFromInt(@rem(ib, ia));
            },
        }
        if (std.math.isNan(rb)) {
            mem.setNull(out);
            return .next;
        }
        out.u = .{ .r = rb };
        out.setTypeFlag(MEM.Real);
        return .next;
    }

    fn opCollSeq(e: *Exec, op: *Op) Flow {
        if (op.p1 != 0) mem.setInt64(e.reg(op.p1), 0);
        return .next;
    }
};

// ===================================================================
// Part 3: bit operations, affinity and comparisons.

/// sqlite3aLTb, sqlite3aEQb, sqlite3aGTb: whether OP_Ne..OP_Ge jump when
/// the comparison is less than, equal to or greater than zero.
const cmp_lt = [6]bool{ true, false, false, true, true, false };
const cmp_eq = [6]bool{ false, true, false, true, false, true };
const cmp_gt = [6]bool{ true, false, true, false, false, true };

fn cmpIndex(opcode: u8) usize {
    return opcode - OP.Ne;
}

const Part3 = struct {
    inline fn dispatch3(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.BitAnd, OP.BitOr, OP.ShiftLeft, OP.ShiftRight => opBit(e, op),
            OP.AddImm => opAddImm(e, op),
            OP.MustBeInt => opMustBeInt(e, op),
            OP.RealAffinity => opRealAffinity(e, op),
            OP.Cast => opCast(e, op),
            OP.Eq, OP.Ne, OP.Lt, OP.Le, OP.Gt, OP.Ge => opCompareJump(e, op),
            OP.ElseEq => if (e.i_compare == 0) .jump_p2 else .next,
            OP.Permutation => .next,
            OP.Compare => opCompare(e, op),
            OP.Jump => opJump(e, op),
            else => Part4.dispatch4(e, op),
        };
    }

    fn opBit(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        const in2 = e.reg(op.p2);
        const out = e.reg(op.p3);
        if ((in1.flags | in2.flags) & MEM.Null != 0) {
            mem.setNull(out);
            return .next;
        }
        var ia = mem.intValue(in2);
        var ib = mem.intValue(in1);
        var opc = op.opcode;
        if (opc == OP.BitAnd) {
            ia &= ib;
        } else if (opc == OP.BitOr) {
            ia |= ib;
        } else if (ib != 0) {
            // A negative shift goes the other way.
            if (ib < 0) {
                opc = 2 * OP.ShiftLeft + 1 - opc;
                ib = if (ib > -64) -ib else 64;
            }
            if (ib >= 64) {
                ia = if (ia >= 0 or opc == OP.ShiftLeft) 0 else -1;
            } else {
                var ua: u64 = @bitCast(ia);
                const sh: u6 = @intCast(ib);
                if (opc == OP.ShiftLeft) {
                    ua <<= sh;
                } else {
                    ua >>= sh;
                    if (ia < 0) ua |= ~@as(u64, 0) << @intCast(64 - ib);
                }
                ia = @bitCast(ua);
            }
        }
        out.u = .{ .i = ia };
        out.setTypeFlag(MEM.Int);
        return .next;
    }

    fn opAddImm(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        mem.integerify(in1);
        in1.u = .{ .i = in1.u.i +% op.p2 };
        return .next;
    }

    fn opMustBeInt(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        if (in1.flags & MEM.Int == 0) {
            if (in1.flags & MEM.Real != 0) {
                const r = in1.u.r;
                if (r >= -9223372036854775808.0 and r < 9223372036854775808.0) {
                    const ix = @import("../sql/numeric.zig").realToI64(r);
                    if (@as(f64, @floatFromInt(ix)) == r) {
                        in1.u = .{ .i = ix };
                        in1.setTypeFlag(MEM.Int);
                    }
                }
            } else {
                mem.applyAffinity(in1, Aff.numeric, e.encoding) catch return .no_mem;
            }
            if (in1.flags & MEM.Int == 0) {
                if (op.p2 == 0) {
                    e.rc = RC.MISMATCH;
                    return .abort;
                }
                return .jump_p2;
            }
        }
        in1.setTypeFlag(MEM.Int);
        return .next;
    }

    fn opRealAffinity(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        if (in1.flags & (MEM.Int | MEM.IntReal) != 0) mem.realify(in1);
        return .next;
    }

    fn opCast(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        if (in1.flags & MEM.Zero != 0) mem.expandBlob(in1) catch return .no_mem;
        mem.cast(in1, @intCast(op.p2), e.encoding) catch |err| return e.fail(err);
        return .next;
    }

    fn opCompareJump(e: *Exec, op: *Op) Flow {
        const in1 = e.reg(op.p1);
        const in3 = e.reg(op.p3);
        var flags1 = in1.flags;
        var flags3 = in3.flags;
        const k = cmpIndex(op.opcode);
        if (flags1 & flags3 & MEM.Int != 0) {
            // The common case of two integers.
            if (in3.u.i > in1.u.i) {
                if (cmp_gt[k]) return .jump_p2;
                e.i_compare = 1;
            } else if (in3.u.i < in1.u.i) {
                if (cmp_lt[k]) return .jump_p2;
                e.i_compare = -1;
            } else {
                if (cmp_eq[k]) return .jump_p2;
                e.i_compare = 0;
            }
            return .next;
        }
        var res: i32 = undefined;
        if ((flags1 | flags3) & MEM.Null != 0) {
            if (op.p5 & vi.SQLITE_NULLEQ != 0) {
                // Only for OP_Eq and OP_Ne: equal if both are NULL.
                if (flags1 & flags3 & MEM.Null != 0 and flags3 & MEM.Cleared == 0) {
                    res = 0;
                } else {
                    res = if (flags3 & MEM.Null != 0) -1 else 1;
                }
            } else {
                // The result is NULL; jump if SQLITE_JUMPIFNULL.
                if (op.p5 & vi.SQLITE_JUMPIFNULL != 0) return .jump_p2;
                e.i_compare = 1;
                return .next;
            }
        } else {
            const affinity: u8 = @intCast(op.p5 & Aff.mask);
            if (affinity >= Aff.numeric) {
                if ((flags1 | flags3) & MEM.Str != 0) {
                    if (flags1 & (MEM.Int | MEM.IntReal | MEM.Real | MEM.Str) == MEM.Str) {
                        mem.applyNumericAffinity(in1, false);
                        flags3 = in3.flags;
                    }
                    if (flags3 & (MEM.Int | MEM.IntReal | MEM.Real | MEM.Str) == MEM.Str) {
                        mem.applyNumericAffinity(in3, false);
                    }
                }
            } else if (affinity == Aff.text and (flags1 | flags3) & MEM.Str != 0) {
                if (flags1 & MEM.Str != 0) {
                    in1.flags &= ~(MEM.Int | MEM.Real | MEM.IntReal);
                } else if (flags1 & (MEM.Int | MEM.Real | MEM.IntReal) != 0) {
                    mem.stringify(in1, e.encoding, true) catch return .no_mem;
                    flags1 = (in1.flags & ~MEM.TypeMask) | (flags1 & MEM.TypeMask);
                    if (in1 == in3) flags3 = flags1 | MEM.Str;
                }
                if (flags3 & MEM.Str != 0) {
                    in3.flags &= ~(MEM.Int | MEM.Real | MEM.IntReal);
                } else if (flags3 & (MEM.Int | MEM.Real | MEM.IntReal) != 0) {
                    mem.stringify(in3, e.encoding, true) catch return .no_mem;
                    flags3 = (in3.flags & ~MEM.TypeMask) | (flags3 & MEM.TypeMask);
                }
            }
            const coll: ?*const int.CollSeq = if (op.p4 == .collseq) op.p4.collseq else null;
            res = serial.memCompare(in3, in1, coll);
        }
        const res2 = if (res < 0) cmp_lt[k] else if (res == 0) cmp_eq[k] else cmp_gt[k];
        e.i_compare = res;
        // Undo the affinity changes to the inputs.
        in3.flags = flags3;
        in1.flags = flags1;
        return if (res2) .jump_p2 else .next;
    }

    fn opCompare(e: *Exec, op: *Op) Flow {
        const permute: ?[]u32 = if (op.p5 & vi.OPFLAG.PERMUTE != 0) e.ops[@intCast(e.pc - 1)].p4.intarray[1..] else null;
        const n: usize = @intCast(op.p3);
        const ki = op.p4.keyinfo;
        for (0..n) |i| {
            const idx: i32 = @intCast(if (permute) |pa| pa[i] else i);
            const m1 = e.reg(op.p1 + idx);
            const m2 = e.reg(op.p2 + idx);
            const coll: ?*const int.CollSeq = ki.coll[i];
            e.i_compare = serial.memCompare(m1, m2, coll);
            if (e.i_compare != 0) {
                if (ki.sort_flags[i] & int.KeyInfoOrder.bignull != 0 and (m1.flags & MEM.Null != 0 or m2.flags & MEM.Null != 0)) {
                    e.i_compare = -e.i_compare;
                }
                if (ki.sort_flags[i] & int.KeyInfoOrder.desc != 0) e.i_compare = -e.i_compare;
                break;
            }
        }
        return .next;
    }

    fn opJump(e: *Exec, op: *Op) Flow {
        if (e.i_compare < 0) {
            e.pc = op.p1 - 1;
        } else if (e.i_compare == 0) {
            e.pc = op.p2 - 1;
        } else {
            e.pc = op.p3 - 1;
        }
        return .next;
    }
};

// ===================================================================
// Part 4: logic, NULL tests, and reading and building records.

const and_logic = [9]u8{ 0, 0, 0, 0, 1, 2, 0, 2, 2 };
const or_logic = [9]u8{ 0, 1, 2, 1, 1, 1, 2, 1, 2 };

/// sqlite3VdbeBooleanValue(p, 2): 0 false, 1 true, 2 NULL.
fn boolOrNull(m: *Mem) usize {
    if (m.flags & MEM.Null != 0) return 2;
    return @intFromBool(mem.booleanValue(m, false));
}

/// vdbeMemTypeName().
fn memTypeName(m: *const Mem) []const u8 {
    const names = [_][]const u8{ "INT", "REAL", "TEXT", "BLOB", "NULL" };
    return names[@intCast(mem.valueType(m) - 1)];
}

/// sqlite3StdType.
pub const std_type = [_][]const u8{ "ANY", "BLOB", "INT", "INTEGER", "REAL", "TEXT" };

const Part4 = struct {
    inline fn dispatch4(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.And, OP.Or => opAndOr(e, op),
            OP.IsTrue => blk: {
                mem.setInt64(e.reg(op.p2), @intFromBool(mem.booleanValue(e.reg(op.p1), op.p3 != 0)) ^ op.p4.int32);
                break :blk .next;
            },
            OP.Not => blk: {
                const in1 = e.reg(op.p1);
                const out = e.reg(op.p2);
                if (in1.flags & MEM.Null == 0) {
                    mem.setInt64(out, @intFromBool(!mem.booleanValue(in1, false)));
                } else {
                    mem.setNull(out);
                }
                break :blk .next;
            },
            OP.BitNot => blk: {
                const in1 = e.reg(op.p1);
                const out = e.reg(op.p2);
                mem.setNull(out);
                if (in1.flags & MEM.Null == 0) {
                    out.flags = MEM.Int;
                    out.u = .{ .i = ~mem.intValue(in1) };
                }
                break :blk .next;
            },
            OP.Once => opOnce(e, op),
            OP.If => if (mem.booleanValue(e.reg(op.p1), op.p3 != 0)) .jump_p2 else .next,
            OP.IfNot => if (!mem.booleanValue(e.reg(op.p1), op.p3 == 0)) .jump_p2 else .next,
            OP.IsNull => if (e.reg(op.p1).flags & MEM.Null != 0) .jump_p2 else .next,
            OP.IsType => opIsType(e, op),
            OP.ZeroOrNull => blk: {
                if (e.reg(op.p1).flags & MEM.Null != 0 or e.reg(op.p3).flags & MEM.Null != 0) {
                    mem.setNull(e.reg(op.p2));
                } else {
                    mem.setInt64(e.reg(op.p2), 0);
                }
                break :blk .next;
            },
            OP.NotNull => if (e.reg(op.p1).flags & MEM.Null == 0) .jump_p2 else .next,
            OP.IfNullRow => blk: {
                if (e.v.csr[@intCast(op.p1)]) |c| if (c.null_row) {
                    mem.setNull(e.reg(op.p3));
                    break :blk .jump_p2;
                };
                break :blk .next;
            },
            OP.Column => opColumn(e, op),
            OP.TypeCheck => opTypeCheck(e, op),
            OP.Affinity => opAffinity(e, op),
            else => Part5.dispatch5(e, op),
        };
    }

    fn opAndOr(e: *Exec, op: *Op) Flow {
        const v1 = boolOrNull(e.reg(op.p1));
        const v2 = boolOrNull(e.reg(op.p2));
        const r = if (op.opcode == OP.And) and_logic[v1 * 3 + v2] else or_logic[v1 * 3 + v2];
        const out = e.reg(op.p3);
        if (r == 2) {
            out.setTypeFlag(MEM.Null);
        } else {
            out.u = .{ .i = r };
            out.setTypeFlag(MEM.Int);
        }
        return .next;
    }

    fn opOnce(e: *Exec, op: *Op) Flow {
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

    fn opIsType(e: *Exec, op: *Op) Flow {
        var type_mask: u16 = undefined;
        if (op.p1 >= 0) {
            const c = e.csr(op.p1);
            if (op.p3 < c.n_hdr_parsed) {
                const st = c.types[@intCast(op.p3)];
                if (st >= 12) {
                    type_mask = if (st & 1 != 0) 0x04 else 0x08;
                } else {
                    const masks = [_]u16{ 0x10, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x2, 0x01, 0x01, 0x10, 0x10 };
                    type_mask = masks[st];
                }
            } else {
                type_mask = @as(u16, 1) << @intCast(op.p4.int32 - 1);
            }
        } else {
            type_mask = @as(u16, 1) << @intCast(mem.valueType(e.reg(op.p3)) - 1);
        }
        return if (type_mask & op.p5 != 0) .jump_p2 else .next;
    }

    /// The op_column_corrupt exit.
    fn columnCorrupt(e: *Exec) Flow {
        if (e.ops[0].p3 > 0) {
            e.pc = e.ops[0].p3 - 1;
            return .next;
        }
        e.rc = RC.CORRUPT;
        return .abort;
    }

    fn opColumn(e: *Exec, op: *Op) Flow {
        const v = e.v;
        var c = e.csr(op.p1);
        var p2: u32 = @intCast(op.p2);
        var s_mem: Mem = .{ .db = e.db, .flags = 0 };
        restart: while (true) {
            const offsets = c.offsets;
            var z_data: []const u8 = undefined;
            var skip_checks = false;
            if (c.cache_status != v.cache_ctr) {
                if (c.null_row) {
                    if (c.e_cur_type == .pseudo and c.seek_result > 0) {
                        // The register of a pseudo cursor holds the record.
                        const preg = e.reg(c.seek_result);
                        c.payload_size = @intCast(preg.n);
                        c.sz_row = @intCast(preg.n);
                        c.row = preg.z;
                    } else {
                        mem.setNull(e.reg(op.p3));
                        return .next;
                    }
                } else {
                    const cur = c.uc.cursor;
                    if (c.deferred_moveto) {
                        if (c.alt_map) |map| {
                            const i_map = map[1 + p2];
                            if (i_map > 0) {
                                c = c.alt_cursor.?;
                                p2 = i_map - 1;
                                continue :restart;
                            }
                        }
                        serial.finishMoveto(c) catch |err| return e.fail(err);
                    } else if (cur.hasMoved()) {
                        serial.handleMovedCursor(c) catch |err| return e.fail(err);
                        continue :restart;
                    }
                    c.payload_size = cur.payloadSize();
                    const fetched = cur.payloadFetch();
                    c.row = fetched.ptr;
                    c.sz_row = @intCast(fetched.len);
                }
                c.cache_status = v.cache_ctr;
                const row0 = c.row.?[0..c.sz_row];
                const hd = serial.getVarint32(row0, 0);
                offsets[0] = hd.value;
                c.i_hdr_offset = hd.len;
                c.n_hdr_parsed = 0;
                if (c.sz_row < offsets[0]) {
                    // The header is not all on the page.
                    c.row = null;
                    c.sz_row = 0;
                    if (offsets[0] > 98307 or offsets[0] > c.payload_size) return columnCorrupt(e);
                } else {
                    z_data = row0;
                    skip_checks = true;
                }
            } else if (c.e_cur_type == .btree and c.uc.cursor.hasMoved()) {
                serial.handleMovedCursor(c) catch |err| return e.fail(err);
                continue :restart;
            }

            if (skip_checks or c.n_hdr_parsed <= p2) {
                if (skip_checks or c.i_hdr_offset < offsets[0]) {
                    if (!skip_checks) {
                        if (c.row) |row| {
                            z_data = row[0..c.sz_row];
                        } else {
                            s_mem = .{ .db = e.db, .flags = 0 };
                            mem.fromBtreeZeroOffset(c.uc.cursor, offsets[0], &s_mem) catch |err| return e.fail(err);
                            z_data = s_mem.bytes();
                        }
                    }
                    // op_column_read_header:
                    var i: u32 = c.n_hdr_parsed;
                    var offset64: u64 = offsets[i];
                    var hdr: u32 = c.i_hdr_offset;
                    const end_hdr: u32 = offsets[0];
                    while (true) {
                        const d = serial.getVarint32(z_data, hdr);
                        c.types[i] = d.value;
                        hdr += d.len;
                        offset64 += serial.serialTypeLen(d.value);
                        i += 1;
                        offsets[i] = @truncate(offset64);
                        if (!(i <= p2 and hdr < end_hdr)) break;
                    }
                    if ((hdr >= end_hdr and (hdr > end_hdr or offset64 != c.payload_size)) or
                        offset64 > c.payload_size)
                    {
                        if (offsets[0] == 0) {
                            i = 0;
                            hdr = end_hdr;
                        } else {
                            if (c.row == null) mem.release(&s_mem);
                            return columnCorrupt(e);
                        }
                    }
                    c.n_hdr_parsed = @intCast(i);
                    c.i_hdr_offset = hdr;
                    if (c.row == null) mem.release(&s_mem);
                }
                if (c.n_hdr_parsed <= p2) {
                    // Fewer columns than p2: the default value or NULL.
                    const dest = e.reg(op.p3);
                    if (op.p4 == .mem) {
                        mem.shallowCopy(dest, op.p4.mem, MEM.Static);
                    } else {
                        mem.setNull(dest);
                    }
                    return .next;
                }
            }
            break;
        }
        const t = c.types[p2];
        const offsets = c.offsets;
        const dest = e.reg(op.p3);
        if (dest.isDynamic()) mem.setNull(dest);
        if (c.sz_row >= offsets[p2 + 1]) {
            // The content is on the page.
            const row = c.row.?[0..c.sz_row];
            if (t < 12) {
                serial.serialGet(row, offsets[p2], t, dest);
            } else {
                const len: u32 = (t - 12) / 2;
                dest.n = @intCast(len);
                dest.enc = e.encoding;
                if (dest.szMalloc() < len + 2) {
                    if (len > e.db.limit(.length)) return .too_big;
                    dest.flags = MEM.Null;
                    mem.grow(dest, len + 2, false) catch return .no_mem;
                } else {
                    dest.z = dest.z_malloc.ptr;
                }
                const z = dest.z.?;
                @memcpy(z[0..len], row[offsets[p2]..][0..len]);
                z[len] = 0;
                z[len + 1] = 0;
                dest.flags = if (t & 1 != 0) MEM.Str | MEM.Term else MEM.Blob;
            }
        } else {
            dest.enc = e.encoding;
            const p5 = op.p5 & vi.OPFLAG.BYTELENARG;
            if ((p5 != 0 and (p5 == vi.OPFLAG.TYPEOFARG or (t >= 12 and (t & 1 == 0 or p5 == vi.OPFLAG.BYTELENARG)))) or
                serial.serialTypeLen(t) == 0)
            {
                // The content does not matter; use zeros.
                const zeros: [16]u8 = @splat(0);
                serial.serialGet(&zeros, 0, t, dest);
                if (t >= 12) {
                    dest.z = null;
                    dest.flags &= ~MEM.Ephem;
                    dest.flags |= MEM.Static;
                }
            } else {
                columnFromOverflow(e, c, t, offsets[p2], dest) catch |err| switch (err) {
                    error.OutOfMemory => return .no_mem,
                    error.TooBig => return .too_big,
                    else => return e.fail(err),
                };
            }
        }
        return .next;
    }

    /// Port of vdbeColumnFromOverflow() (without the large-value cache).
    fn columnFromOverflow(e: *Exec, c: *VdbeCursor, t: u32, offset: u32, dest: *Mem) !void {
        const len = serial.serialTypeLen(t);
        if (len > e.db.limit(.length)) return error.TooBig;
        try mem.fromBtree(c.uc.cursor, offset, len, dest);
        serial.serialGet(dest.z.?[0..len], 0, t, dest);
        if (t & 1 != 0 and dest.enc == ENC.UTF8) {
            dest.z.?[len] = 0;
            dest.flags |= MEM.Term;
        }
        dest.flags &= ~MEM.Ephem;
    }

    fn opTypeCheck(e: *Exec, op: *Op) Flow {
        const tab = op.p4.table;
        const cols = tab.cols;
        var in1: i32 = op.p1;
        var i: usize = undefined;
        var n_col: usize = undefined;
        if (op.p3 < 2) {
            i = 0;
            n_col = cols.len;
        } else {
            i = @intCast(op.p3 - 2);
            n_col = i + 1;
        }
        while (i < n_col) : (i += 1) {
            const col = &cols[i];
            if (col.col_flags & int.COLFLAG.GENERATED != 0 and op.p3 < 2) {
                if (col.col_flags & int.COLFLAG.VIRTUAL != 0) continue;
                if (op.p3 != 0) {
                    in1 += 1;
                    continue;
                }
            }
            const m = e.reg(in1);
            mem.applyAffinity(m, col.affinity, e.encoding) catch return .no_mem;
            if (m.flags & MEM.Null == 0) {
                const ok = switch (col.e_ctype) {
                    int.COLTYPE.BLOB => m.flags & MEM.Blob != 0,
                    int.COLTYPE.INTEGER, int.COLTYPE.INT => m.flags & MEM.Int != 0,
                    int.COLTYPE.TEXT => m.flags & MEM.Str != 0,
                    int.COLTYPE.REAL => blk: {
                        if (m.flags & MEM.Int != 0) {
                            // Keep a small integer exact, but typed REAL.
                            if (m.u.i <= 140737488355327 and m.u.i >= -140737488355328) {
                                m.flags |= MEM.IntReal;
                                m.flags &= ~MEM.Int;
                            } else {
                                m.u = .{ .r = @floatFromInt(m.u.i) };
                                m.flags |= MEM.Real;
                                m.flags &= ~MEM.Int;
                            }
                            break :blk true;
                        }
                        break :blk m.flags & (MEM.Real | MEM.IntReal) != 0;
                    },
                    else => true,
                };
                if (!ok) {
                    aux.vdbeError(e.v, "cannot store {s} value in {s} column {s}.{s}", .{
                        memTypeName(m), std_type[col.e_ctype - 1], tab.name, col.name(),
                    });
                    e.rc = RC.CONSTRAINT_DATATYPE;
                    return .abort;
                }
            }
            in1 += 1;
        }
        return .next;
    }

    fn opAffinity(e: *Exec, op: *Op) Flow {
        const aff = op.p4.z;
        var in1 = op.p1;
        for (aff) |a| {
            const m = e.reg(in1);
            mem.applyAffinity(m, a, e.encoding) catch return .no_mem;
            if (a == Aff.real and m.flags & MEM.Int != 0) {
                m.u = .{ .r = @floatFromInt(m.u.i) };
                m.flags |= MEM.Real;
                m.flags &= ~(MEM.Int | MEM.Str);
            }
            in1 += 1;
        }
        return .next;
    }
};

// ===================================================================
// Part 5: records, transactions, and opening and positioning cursors.

/// BTREE_UNORDERED: an ephemeral table whose order does not matter.
const BTREE_UNORDERED: u16 = 8;

/// Port of allocateCursor(): a new cursor in slot `i_cur`, replacing any
/// cursor there. The b-tree cursor (`CursorBox.bc`) is not opened.
fn allocateCursor(e: *Exec, i_cur: i32, n_field: i32, cur_type: vi.CurType) ?*VdbeCursor {
    const v = e.v;
    const slot = &v.csr[@intCast(i_cur)];
    if (slot.*) |old| {
        aux.freeCursorNN(v, old);
        slot.* = null;
    }
    const gpa = e.db.gpa;
    const n: usize = @intCast(n_field);
    const box = gpa.create(vi.CursorBox) catch return null;
    const buf = gpa.alloc(u32, 2 * n + 1) catch {
        gpa.destroy(box);
        return null;
    };
    @memset(buf, 0);
    box.* = .{
        .vc = .{
            .e_cur_type = cur_type,
            .i_db = 0,
            .n_field = @intCast(n_field),
            .types = buf[0..n],
            .offsets = buf[n..],
        },
    };
    slot.* = &box.vc;
    return &box.vc;
}

/// Opens the b-tree cursor of a cursor made by allocateCursor().
fn openBtreeCursor(c: *VdbeCursor, bt: *btree.Btree, root: int.Pgno, write: bool, key_info: ?*vi.KeyInfo) btree.Error!void {
    const box: *vi.CursorBox = @fieldParentPtr("vc", c);
    try bt.cursor(&box.bc, root, .{
        .write = write,
        .key_info = if (key_info) |ki| serial.btreeKeyInfo(ki) else null,
    });
    c.uc = .{ .cursor = &box.bc };
}

const Part5 = struct {
    inline fn dispatch5(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.MakeRecord => opMakeRecord(e, op),
            OP.Count => opCount(e, op),
            OP.AutoCommit => opAutoCommit(e, op),
            OP.Transaction => opTransaction(e, op),
            OP.ReadCookie => blk: {
                const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
                const meta = bt.getMeta(@enumFromInt(op.p3));
                e.out2Prerelease(op).u = .{ .i = @as(i32, @bitCast(meta)) };
                break :blk .next;
            },
            OP.SetCookie => opSetCookie(e, op),
            OP.ReopenIdx => opReopenIdx(e, op),
            OP.OpenRead, OP.OpenWrite => opOpen(e, op),
            OP.OpenDup => opOpenDup(e, op),
            OP.OpenAutoindex, OP.OpenEphemeral => opOpenEphemeral(e, op),
            OP.SorterOpen => blk: {
                const c = allocateCursor(e, op.p1, op.p2, .sorter) orelse break :blk .no_mem;
                c.key_info = op.p4.keyinfo;
                sorter.init(e.db, op.p3, c) catch |err| break :blk e.fail(err);
                break :blk .next;
            },
            OP.SequenceTest => blk: {
                const c = e.csr(op.p1);
                c.seq_count += 1;
                break :blk if (c.seq_count - 1 == 0) .jump_p2 else .next;
            },
            OP.OpenPseudo => blk: {
                const c = allocateCursor(e, op.p1, op.p3, .pseudo) orelse break :blk .no_mem;
                c.null_row = true;
                c.seek_result = op.p2;
                c.is_table = true;
                c.uc = .pseudo;
                break :blk .next;
            },
            OP.Close => blk: {
                const slot = &e.v.csr[@intCast(op.p1)];
                aux.freeCursor(e.v, slot.*);
                slot.* = null;
                break :blk .next;
            },
            OP.SeekLT, OP.SeekLE, OP.SeekGE, OP.SeekGT => opSeek(e, op),
            else => Part6.dispatch6(e, op),
        };
    }

    fn opMakeRecord(e: *Exec, op: *Op) Flow {
        const n_field: usize = @intCast(op.p2);
        const data0: usize = @intCast(op.p1);
        const recs = e.regs[data0..][0..n_field];
        const out = e.reg(op.p3);
        if (op.p4 == .z) {
            for (op.p4.z, 0..) |a, i| {
                const rec = &recs[i];
                mem.applyAffinity(rec, a, e.encoding) catch return .no_mem;
                if (a == Aff.real and rec.flags & MEM.Int != 0) {
                    rec.flags |= MEM.IntReal;
                    rec.flags &= ~MEM.Int;
                }
            }
        }

        // Pick the serial type of each field and size the record.
        var n_data: u64 = 0;
        var n_hdr: u64 = 0;
        var n_zero: i64 = 0;
        var k = n_field;
        while (k > 0) {
            k -= 1;
            const rec = &recs[k];
            if (rec.flags & MEM.Null != 0) {
                rec.u_temp = if (rec.flags & MEM.Zero != 0) 10 else 0;
                n_hdr += 1;
            } else if (rec.flags & (MEM.Int | MEM.IntReal) != 0) {
                const i = rec.u.i;
                const uu: u64 = if (i < 0) @bitCast(~i) else @bitCast(i);
                n_hdr += 1;
                if (uu <= 127) {
                    if (i & 1 == i and e.v.min_write_file_format >= 4) {
                        rec.u_temp = 8 + @as(u32, @intCast(uu));
                    } else {
                        n_data += 1;
                        rec.u_temp = 1;
                    }
                } else if (uu <= 32767) {
                    n_data += 2;
                    rec.u_temp = 2;
                } else if (uu <= 8388607) {
                    n_data += 3;
                    rec.u_temp = 3;
                } else if (uu <= 2147483647) {
                    n_data += 4;
                    rec.u_temp = 4;
                } else if (uu <= 140737488355327) {
                    n_data += 6;
                    rec.u_temp = 5;
                } else {
                    n_data += 8;
                    if (rec.flags & MEM.IntReal != 0) {
                        // An 8-byte integer might as well be a real.
                        rec.u = .{ .r = @floatFromInt(rec.u.i) };
                        rec.flags &= ~MEM.IntReal;
                        rec.flags |= MEM.Real;
                        rec.u_temp = 7;
                    } else {
                        rec.u_temp = 6;
                    }
                }
            } else if (rec.flags & MEM.Real != 0) {
                n_hdr += 1;
                n_data += 8;
                rec.u_temp = 7;
            } else {
                var len: u64 = @intCast(rec.n);
                var serial_type: u64 = len * 2 + 12 + @intFromBool(rec.flags & MEM.Str != 0);
                if (rec.flags & MEM.Zero != 0) {
                    serial_type += @as(u64, @intCast(rec.u.n_zero)) * 2;
                    if (n_data != 0) {
                        mem.expandBlob(rec) catch return .no_mem;
                        len = @intCast(rec.n);
                    } else {
                        n_zero += rec.u.n_zero;
                    }
                }
                n_data += len;
                n_hdr += varint.len(serial_type);
                rec.u_temp = @intCast(serial_type);
            }
        }
        if (n_hdr <= 126) {
            n_hdr += 1;
        } else {
            const n_varint = varint.len(n_hdr);
            n_hdr += n_varint;
            if (n_varint < varint.len(n_hdr)) n_hdr += 1;
        }
        const n_byte = n_hdr + n_data;
        if (n_byte + @as(u64, @intCast(n_zero)) <= out.szMalloc()) {
            out.z = out.z_malloc.ptr;
        } else {
            if (n_byte + @as(u64, @intCast(n_zero)) > @as(u64, @intCast(e.db.limit(.length)))) return .too_big;
            mem.clearAndResize(out, @intCast(n_byte)) catch return .no_mem;
        }
        out.n = @intCast(n_byte);
        out.flags = MEM.Blob;
        if (n_zero != 0) {
            out.u = .{ .n_zero = @intCast(n_zero) };
            out.flags |= MEM.Zero;
        }
        const z = out.z.?[0..@intCast(n_byte)];
        var hdr: usize = varint.put(z, n_hdr);
        var payload: usize = @intCast(n_hdr);
        for (recs) |*rec| {
            const st = rec.u_temp;
            hdr += varint.put(z[hdr..], st);
            if (st >= 1 and st <= 7) {
                const bits: u64 = if (st == 7) @bitCast(rec.u.r) else @bitCast(rec.u.i);
                const len = serial.small_type_sizes[st];
                var j: usize = len;
                var x = bits;
                while (j > 0) {
                    j -= 1;
                    z[payload + j] = @truncate(x);
                    x >>= 8;
                }
                payload += len;
            } else if (st >= 12 and rec.n > 0) {
                const n: usize = @intCast(rec.n);
                @memcpy(z[payload..][0..n], rec.z.?[0..n]);
                payload += n;
            }
        }
        std.debug.assert(hdr == n_hdr and payload == n_byte);
        return .next;
    }

    fn opCount(e: *Exec, op: *Op) Flow {
        const cur = e.csr(op.p1).uc.cursor;
        const n = cur.count() catch |err| return e.fail(err);
        e.out2Prerelease(op).u = .{ .i = n };
        return .check_interrupt;
    }

    fn opAutoCommit(e: *Exec, op: *Op) Flow {
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

    fn opTransaction(e: *Exec, op: *Op) Flow {
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
            bt.beginTrans(mode) catch |err| {
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
            i_meta = bt.getMeta(.schema_version);
            // Statement transactions are not supported yet: an error in a
            // statement inside BEGIN...COMMIT does not undo the statement's
            // earlier changes.
        }
        if (op.p5 != 0 and (@as(i32, @bitCast(i_meta)) != op.p3 or pdb.schema.i_generation != op.p4.int32)) {
            v.err_msg = null;
            aux.vdbeError(v, "database schema has changed", .{});
            if (pdb.schema.schema_cookie != @as(i32, @bitCast(i_meta))) {
                @import("../sql/build.zig").resetOneSchema(db, @intCast(op.p1));
            }
            v.expired = 1;
            v.change_cnt_on = false;
            e.rc = RC.SCHEMA;
            return .abort;
        }
        return .next;
    }

    fn opSetCookie(e: *Exec, op: *Op) Flow {
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

    fn opReopenIdx(e: *Exec, op: *Op) Flow {
        if (e.v.csr[@intCast(op.p1)]) |c| {
            if (c.pgno_root == @as(u32, @intCast(op.p2))) {
                // Already open on this index.
                c.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
                return .next;
            }
        }
        return opOpen(e, op);
    }

    fn opOpen(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const db = e.db;
        if (v.expired == 1) {
            e.rc = RC.ABORT_ROLLBACK;
            return .abort;
        }
        var p2: u32 = @intCast(op.p2);
        const i_db = op.p3;
        const pdb = &db.dbs.items[@intCast(i_db)];
        const bt = pdb.bt.?;
        var write = false;
        if (op.opcode == OP.OpenWrite) {
            write = true;
            if (pdb.schema.file_format < v.min_write_file_format) v.min_write_file_format = pdb.schema.file_format;
            if (op.p5 & vi.OPFLAG.P2ISREG != 0) {
                const in2 = e.reg(@intCast(p2));
                mem.integerify(in2);
                p2 = @intCast(in2.u.i);
            }
        }
        var key_info: ?*vi.KeyInfo = null;
        var n_field: i32 = 0;
        switch (op.p4) {
            .keyinfo => |ki| {
                key_info = ki;
                n_field = ki.n_all_field;
            },
            .int32 => |n| n_field = n,
            else => {},
        }
        const c = allocateCursor(e, op.p1, n_field, .btree) orelse return .no_mem;
        c.i_db = @intCast(i_db);
        c.null_row = true;
        c.is_ordered = true;
        c.pgno_root = p2;
        c.key_info = key_info;
        c.is_table = op.p4 != .keyinfo;
        c.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
        openBtreeCursor(c, bt, p2, write, key_info) catch |err| return e.fail(err);
        if (op.p5 & vi.OPFLAG.BULKCSR != 0) c.uc.cursor.setBulkLoad(true);
        return .next;
    }

    fn opOpenDup(e: *Exec, op: *Op) Flow {
        const orig = e.csr(op.p2);
        std.debug.assert(orig.is_ephemeral);
        const c = allocateCursor(e, op.p1, orig.n_field, .btree) orelse return .no_mem;
        c.null_row = true;
        c.is_ephemeral = true;
        c.key_info = orig.key_info;
        c.is_table = orig.is_table;
        c.pgno_root = orig.pgno_root;
        c.is_ordered = orig.is_ordered;
        // The original cursor owns the ephemeral database (c.btx stays null).
        c.no_reuse = true;
        orig.no_reuse = true;
        openBtreeCursor(c, orig.btx.?, c.pgno_root, true, c.key_info) catch |err| return e.fail(err);
        return .next;
    }

    fn opOpenEphemeral(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const db = e.db;
        if (op.p3 > 0) {
            // Make reg[P3] usable as zero-length data for OP_Insert.
            const r = e.reg(op.p3);
            r.n = 0;
            r.z = @constCast("".ptr);
        }
        if (v.csr[@intCast(op.p1)]) |cx| {
            if (!cx.no_reuse and op.p2 <= cx.n_field) {
                // Erase the content of the open ephemeral table.
                cx.seq_count = 0;
                cx.cache_status = vi.cache_stale;
                _ = cx.btx.?.clearTable(cx.pgno_root) catch |err| return e.fail(err);
                cx.null_row = true;
                return .next;
            }
        }
        const c = allocateCursor(e, op.p1, op.p2, .btree) orelse return .no_mem;
        c.is_ephemeral = true;
        const bt = btree.Btree.open(db.gpa, db.vfs.?, "", .{
            .temp = true,
            .journal_mode = .off,
            .synchronous = .off,
        }) catch |err| return e.fail(err);
        c.btx = bt;
        openEphemeralTable(c, bt, op) catch |err| return e.fail(err);
        c.is_ordered = op.p5 != BTREE_UNORDERED;
        c.null_row = true;
        return .next;
    }

    fn openEphemeralTable(c: *VdbeCursor, bt: *btree.Btree, op: *Op) btree.Error!void {
        try bt.beginTrans(.write);
        if (op.p4 == .keyinfo) {
            // A transient index gets its own b-tree; a table uses page 1.
            c.key_info = op.p4.keyinfo;
            c.pgno_root = try bt.createTable(.blobkey);
            try openBtreeCursor(c, bt, c.pgno_root, true, c.key_info);
            c.is_table = false;
        } else {
            c.pgno_root = 1;
            try openBtreeCursor(c, bt, 1, true, null);
            c.is_table = true;
        }
    }

    fn opSeek(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        var oc = op.opcode;
        var eq_only = false;
        c.null_row = false;
        c.deferred_moveto = false;
        c.cache_status = vi.cache_stale;
        var res: i32 = 0;
        not_found: {
            if (c.is_table) {
                // The key must become an integer.
                const in3 = e.reg(op.p3);
                const flags3 = in3.flags;
                if (flags3 & (MEM.Int | MEM.Real | MEM.IntReal | MEM.Str) == MEM.Str) {
                    mem.applyNumericAffinity(in3, false);
                }
                const i_key = mem.intValue(in3);
                const new_type = in3.flags;
                in3.flags = flags3;
                if (new_type & (MEM.Int | MEM.IntReal) == 0) {
                    if (new_type & MEM.Real == 0) {
                        if (new_type & MEM.Null != 0 or oc >= OP.SeekGE) return .jump_p2;
                        res = @intFromBool(!(cur.last() catch |err| return e.fail(err)));
                        break :not_found;
                    }
                    const cmp = serial.intFloatCompare(i_key, in3.u.r);
                    if (cmp > 0) {
                        // (x > 4.9) -> (x >= 5); (x <= 4.9) -> (x < 5)
                        if (oc & 1 == OP.SeekGT & 1) oc -= 1;
                    } else if (cmp < 0) {
                        // (x < 5.1) -> (x <= 5); (x >= 5.1) -> (x > 5)
                        if (oc & 1 == OP.SeekLT & 1) oc += 1;
                    }
                }
                const order = cur.tableMoveto(i_key, false) catch |err| return e.fail(err);
                res = btree.orderToInt(order);
                c.moveto_target = i_key;
            } else {
                if (c.seek_eq) eq_only = true;
                var r: vi.UnpackedRecord = .{
                    .key_info = c.key_info.?,
                    .mem = e.regs.ptr + @as(usize, @intCast(op.p3)),
                    .n_field = @intCast(op.p4.int32),
                    .default_rc = if ((oc - OP.SeekLT) & 1 != 0) -1 else 1,
                };
                const order = serial.indexMoveto(cur, &r) catch |err| return e.fail(err);
                res = btree.orderToInt(order);
                if (eq_only and !r.eq_seen) {
                    res = 1;
                    break :not_found;
                }
            }
            if (oc >= OP.SeekGE) {
                if (res < 0 or (res == 0 and oc == OP.SeekGT)) {
                    res = @intFromBool(!(cur.next() catch |err| return e.fail(err)));
                } else {
                    res = 0;
                }
            } else {
                if (res > 0 or (res == 0 and oc == OP.SeekLT)) {
                    res = @intFromBool(!(cur.previous() catch |err| return e.fail(err)));
                } else {
                    // res may be negative because the table is empty.
                    res = @intFromBool(cur.eof());
                }
            }
        }
        if (res != 0) return .jump_p2;
        // Skip the OP_IdxLT or OP_IdxGT that follows.
        if (eq_only) e.pc += 1;
        return .next;
    }
};


// ===================================================================
// Part 6: finding, reading, writing and stepping rows.

/// The largest rowid (MAX_ROWID).
const max_rowid: i64 = std.math.maxInt(i64);

const Part6 = struct {
    inline fn dispatch6(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.SeekScan => opSeekScan(e, op),
            OP.SeekHit => blk: {
                const c = e.csr(op.p1);
                if (c.seek_hit < op.p2) {
                    c.seek_hit = @intCast(op.p2);
                } else if (c.seek_hit > op.p3) {
                    c.seek_hit = @intCast(op.p3);
                }
                break :blk .next;
            },
            OP.IfNoHope => blk: {
                const c = e.csr(op.p1);
                if (c.seek_hit >= op.p4.int32) break :blk .next;
                break :blk opFound(e, op);
            },
            OP.NoConflict, OP.NotFound, OP.Found => opFound(e, op),
            OP.SeekRowid => opSeekRowid(e, op),
            OP.NotExists => notExists(e, op, e.reg(op.p3).u.i),
            OP.Sequence => blk: {
                const c = e.csr(op.p1);
                e.out2Prerelease(op).u = .{ .i = c.seq_count };
                c.seq_count += 1;
                break :blk .next;
            },
            OP.NewRowid => opNewRowid(e, op),
            OP.Insert => opInsert(e, op),
            OP.Delete => opDelete(e, op),
            OP.ResetCount => blk: {
                aux.setChanges(e.db, e.v.n_change);
                e.v.n_change = 0;
                break :blk .next;
            },
            OP.SorterCompare => blk: {
                const c = e.csr(op.p1);
                const res = sorter.compare(c, e.reg(op.p3), op.p4.int32) catch |err| break :blk e.fail(err);
                break :blk if (res != 0) .jump_p2 else .next;
            },
            OP.SorterData => blk: {
                const c = e.csr(op.p1);
                sorter.rowkey(c, e.reg(op.p2)) catch |err| break :blk e.fail(err);
                e.csr(op.p3).cache_status = vi.cache_stale;
                break :blk .next;
            },
            OP.RowData => opRowData(e, op),
            OP.Rowid => opRowid(e, op),
            OP.NullRow => opNullRow(e, op),
            OP.SeekEnd, OP.Last => opLast(e, op),
            OP.IfSizeBetween => opIfSizeBetween(e, op),
            OP.SorterSort, OP.Sort => blk: {
                e.v.counters[vi.STMTSTATUS.SORT] += 1;
                break :blk opRewind(e, op);
            },
            OP.Rewind => opRewind(e, op),
            OP.IfEmpty => blk: {
                const cur = e.csr(op.p1).uc.cursor;
                const empty = cur.isEmpty() catch |err| break :blk e.fail(err);
                break :blk if (empty) .jump_p2 else .next;
            },
            OP.SorterNext => blk: {
                const c = e.csr(op.p1);
                const more = sorter.next(e.db, c) catch |err| break :blk e.fail(err);
                break :blk nextTail(e, op, c, more);
            },
            OP.Prev => blk: {
                const c = e.csr(op.p1);
                const more = c.uc.cursor.previous() catch |err| break :blk e.fail(err);
                break :blk nextTail(e, op, c, more);
            },
            OP.Next => blk: {
                const c = e.csr(op.p1);
                const more = c.uc.cursor.next() catch |err| break :blk e.fail(err);
                break :blk nextTail(e, op, c, more);
            },
            OP.IdxInsert => opIdxInsert(e, op),
            OP.SorterInsert => blk: {
                const c = e.csr(op.p1);
                const in2 = e.reg(op.p2);
                if (in2.flags & MEM.Zero != 0) mem.expandBlob(in2) catch break :blk .no_mem;
                sorter.write(c, in2) catch |err| break :blk e.fail(err);
                break :blk .next;
            },
            OP.IdxDelete => opIdxDelete(e, op),
            OP.DeferredSeek, OP.IdxRowid => opIdxRowid(e, op),
            OP.FinishSeek => blk: {
                const c = e.csr(op.p1);
                if (c.deferred_moveto) serial.finishMoveto(c) catch |err| break :blk e.fail(err);
                break :blk .next;
            },
            OP.IdxLE, OP.IdxGT, OP.IdxLT, OP.IdxGE => opIdxCompare(e, op),
            else => Part7.dispatch7(e, op),
        };
    }

    fn opSeekScan(e: *Exec, op: *Op) Flow {
        const next_op = &e.ops[@intCast(e.pc + 1)];
        std.debug.assert(next_op.opcode == OP.SeekGE);
        const c = e.csr(next_op.p1);
        const cur = c.uc.cursor;
        if (cur.eof()) return .next;
        var n_step = op.p1;
        var r: vi.UnpackedRecord = .{
            .key_info = c.key_info.?,
            .mem = e.regs.ptr + @as(usize, @intCast(next_op.p3)),
            .n_field = @intCast(next_op.p4.int32),
            .default_rc = 0,
        };
        while (true) {
            const res = serial.idxKeyCompare(e.db, c, &r) catch |err| return e.fail(err);
            if (res > 0 and op.p5 == 0) {
                // seekscan_search_fail: past the target; skip the SeekGE.
                e.pc = next_op.p2 - 1;
                return .next;
            }
            if (res >= 0) return .jump_p2;
            if (n_step <= 0) return .next;
            n_step -= 1;
            c.cache_status = vi.cache_stale;
            const more = cur.next() catch |err| return e.fail(err);
            if (!more) {
                e.pc = next_op.p2 - 1;
                return .next;
            }
        }
    }

    fn opFound(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        const regs = e.regs.ptr + @as(usize, @intCast(op.p3));
        const n_field: u16 = @intCast(op.p4.int32);
        if (n_field > 0) {
            // The key is n_field unpacked registers.
            var r: vi.UnpackedRecord = .{ .key_info = c.key_info.?, .mem = regs, .n_field = n_field, .default_rc = 0 };
            c.seek_result = btree.orderToInt(serial.indexMoveto(cur, &r) catch |err| return e.fail(err));
        } else {
            // The key is a record in one register.
            const key = &regs[0];
            if (key.flags & MEM.Zero != 0) mem.expandBlob(key) catch return .no_mem;
            const ki = c.key_info.?;
            const order = serial.btreeKeyInfo(ki).seek(ki, cur, key.bytes()) catch |err| return e.fail(err);
            c.seek_result = btree.orderToInt(order);
        }
        const exists = c.seek_result == 0;
        c.null_row = !exists;
        c.deferred_moveto = false;
        c.cache_status = vi.cache_stale;
        if (op.opcode == OP.Found) {
            if (exists) return .jump_p2;
        } else {
            if (!exists) return .jump_p2;
            if (op.opcode == OP.NoConflict) {
                // A key with a NULL never conflicts.
                for (regs[0..n_field]) |m| if (m.flags & MEM.Null != 0) return .jump_p2;
            }
            if (op.opcode == OP.IfNoHope) c.seek_hit = @intCast(op.p4.int32);
        }
        return .next;
    }

    fn opSeekRowid(e: *Exec, op: *Op) Flow {
        const in3 = e.reg(op.p3);
        if (in3.flags & (MEM.Int | MEM.IntReal) == 0) {
            // Convert a copy: the register must keep its type.
            var x: Mem = in3.*;
            x.flags &= ~(MEM.Dyn | MEM.Agg);
            if (x.flags & MEM.Str != 0) mem.applyNumericAffinity(&x, true);
            var key: i64 = undefined;
            if (x.flags & MEM.Int != 0) {
                key = x.u.i;
            } else {
                if (x.flags & MEM.Real == 0 or x.u.r < -9223372036854775808.0 or x.u.r > 9223372036854774784.0) return .jump_p2;
                key = @import("../sql/numeric.zig").realToI64(x.u.r);
                if (@as(f64, @floatFromInt(key)) != x.u.r) return .jump_p2;
            }
            return notExists(e, op, key);
        }
        return notExists(e, op, in3.u.i);
    }

    fn notExists(e: *Exec, op: *Op, key: i64) Flow {
        const c = e.csr(op.p1);
        const order = c.uc.cursor.tableMoveto(key, false) catch |err| return e.fail(err);
        const res = btree.orderToInt(order);
        c.moveto_target = key;
        c.null_row = false;
        c.cache_status = vi.cache_stale;
        c.deferred_moveto = false;
        c.seek_result = res;
        if (res != 0) {
            if (op.p2 == 0) {
                e.rc = RC.CORRUPT;
                return .abort;
            }
            return .jump_p2;
        }
        return .next;
    }

    fn opNewRowid(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        var rowid: i64 = 0;
        if (!c.use_random_rowid) {
            const has_last = cur.last() catch |err| return e.fail(err);
            if (!has_last) {
                rowid = 1;
            } else {
                rowid = cur.integerKey();
                if (rowid >= max_rowid) {
                    c.use_random_rowid = true;
                } else {
                    rowid += 1;
                }
            }
        }
        if (op.p3 != 0) {
            // AUTOINCREMENT: the largest rowid ever is in register P3 of
            // the root frame.
            const m = e.rootReg(op.p3);
            mem.integerify(m);
            if (m.u.i == max_rowid or c.use_random_rowid) {
                e.rc = RC.FULL;
                return .abort;
            }
            if (rowid < m.u.i + 1) rowid = m.u.i + 1;
            m.u = .{ .i = rowid };
        }
        if (c.use_random_rowid) {
            var cnt: u32 = 0;
            var found = true;
            while (found and cnt < 100) : (cnt += 1) {
                var buf: [8]u8 = undefined;
                e.db.vfs.?.vtable.randomness(e.db.vfs.?.ptr, &buf);
                rowid = @bitCast(std.mem.readInt(u64, &buf, .little) & @as(u64, @intCast(max_rowid >> 1)));
                rowid += 1;
                const order = cur.tableMoveto(rowid, false) catch |err| return e.fail(err);
                found = order == .eq;
            }
            if (found) {
                e.rc = RC.FULL;
                return .abort;
            }
        }
        c.deferred_moveto = false;
        c.cache_status = vi.cache_stale;
        out.u = .{ .i = rowid };
        return .next;
    }

    fn opInsert(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const data = e.reg(op.p2);
        const c = e.csr(op.p1);
        const key = e.reg(op.p3);
        const rowid = key.u.i;
        if (op.p5 & vi.OPFLAG.NCHANGE != 0) {
            v.n_change += 1;
            if (op.p5 & vi.OPFLAG.LASTROWID != 0) e.db.last_rowid = rowid;
        }
        const seek_result = if (op.p5 & vi.OPFLAG.USESEEKRESULT != 0) c.seek_result else 0;
        const x: btree.Payload = .{
            .rowid = rowid,
            .data = data.bytes(),
            .n_zero = if (data.flags & MEM.Zero != 0) @intCast(data.u.n_zero) else 0,
        };
        const res = c.uc.cursor.insert(x, .{
            .append = op.p5 & vi.OPFLAG.APPEND != 0,
            .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
            .seek_result = seek_result,
        });
        c.deferred_moveto = false;
        c.cache_status = vi.cache_stale;
        res catch |err| return e.fail(err);
        return .next;
    }

    fn opDelete(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const c = e.csr(op.p1);
        const res = c.uc.cursor.delete(.{ .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0 });
        c.cache_status = vi.cache_stale;
        c.seek_result = 0;
        res catch |err| return e.fail(err);
        if (op.p2 & vi.OPFLAG.NCHANGE != 0) v.n_change += 1;
        return .next;
    }

    fn opRowData(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        const n = cur.payloadSize();
        if (n > e.db.limit(.length)) return .too_big;
        mem.fromBtreeZeroOffset(cur, n, out) catch |err| return e.fail(err);
        if (op.p3 == 0 and out.flags & MEM.Ephem != 0) mem.makeWriteable(out) catch return .no_mem;
        return .next;
    }

    fn opRowid(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        const c = e.csr(op.p1);
        var rowid: i64 = undefined;
        if (c.null_row) {
            out.flags = MEM.Null;
            return .next;
        } else if (c.deferred_moveto) {
            rowid = c.moveto_target;
        } else {
            serial.cursorRestore(c) catch |err| return e.fail(err);
            if (c.null_row) {
                out.flags = MEM.Null;
                return .next;
            }
            rowid = c.uc.cursor.integerKey();
        }
        out.u = .{ .i = rowid };
        return .next;
    }

    fn opNullRow(e: *Exec, op: *Op) Flow {
        var c: *VdbeCursor = undefined;
        if (e.v.csr[@intCast(op.p1)]) |cx| {
            c = cx;
        } else {
            // A NULL row for a cursor that was never opened.
            c = allocateCursor(e, op.p1, 1, .pseudo) orelse return .no_mem;
            c.seek_result = 0;
            c.is_table = true;
            c.no_reuse = true;
            c.uc = .pseudo;
        }
        c.null_row = op.p2 == 0;
        c.cache_status = vi.cache_stale;
        if (c.uc == .cursor) c.uc.cursor.clear();
        return .next;
    }

    fn opLast(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        if (op.opcode == OP.SeekEnd) {
            c.seek_result = -1;
            if (!cur.eof()) return .next;
        }
        const res = cur.last();
        c.null_row = !(res catch false);
        c.deferred_moveto = false;
        c.cache_status = vi.cache_stale;
        _ = res catch |err| return e.fail(err);
        if (op.p2 > 0 and c.null_row) return .jump_p2;
        return .next;
    }

    fn opIfSizeBetween(e: *Exec, op: *Op) Flow {
        const cur = e.csr(op.p1).uc.cursor;
        const has_rows = cur.first() catch |err| return e.fail(err);
        var sz: i64 = -1;
        if (has_rows) {
            // An exact count stands in for sqlite3BtreeRowCountEst().
            const n = cur.count() catch |err| return e.fail(err);
            sz = util.logEst(@intCast(n));
        }
        return if (sz >= op.p3 and sz <= op.p4.int32) .jump_p2 else .next;
    }

    fn opRewind(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        var empty: bool = undefined;
        if (c.e_cur_type == .sorter) {
            empty = sorter.rewind(c) catch |err| return e.fail(err);
        } else {
            const cur = c.uc.cursor;
            const r = cur.first();
            c.deferred_moveto = false;
            c.cache_status = vi.cache_stale;
            empty = !(r catch |err| return e.fail(err));
        }
        c.null_row = empty;
        if (op.p2 > 0 and empty) return .jump_p2;
        return .next;
    }

    fn nextTail(e: *Exec, op: *Op, c: *VdbeCursor, more: bool) Flow {
        c.cache_status = vi.cache_stale;
        if (more) {
            c.null_row = false;
            e.v.counters[op.p5] +%= 1;
            return .jump_p2_check_interrupt;
        }
        c.null_row = true;
        return .check_interrupt;
    }

    fn opIdxInsert(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const c = e.csr(op.p1);
        const in2 = e.reg(op.p2);
        if (op.p5 & vi.OPFLAG.NCHANGE != 0) v.n_change += 1;
        if (in2.flags & MEM.Zero != 0) mem.expandBlob(in2) catch |err| return e.fail(err);
        const res = c.uc.cursor.insert(.{ .key = in2.bytes() }, .{
            .append = op.p5 & vi.OPFLAG.APPEND != 0,
            .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
            .seek_result = if (op.p5 & vi.OPFLAG.USESEEKRESULT != 0) c.seek_result else 0,
        });
        c.cache_status = vi.cache_stale;
        res catch |err| return e.fail(err);
        return .next;
    }

    fn opIdxDelete(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        const cur = c.uc.cursor;
        var r: vi.UnpackedRecord = .{
            .key_info = c.key_info.?,
            .mem = e.regs.ptr + @as(usize, @intCast(op.p2)),
            .n_field = op.p5,
            .default_rc = 0,
        };
        const order = serial.indexMoveto(cur, &r) catch |err| return e.fail(err);
        if (order != .eq) {
            if (e.db.flags & (int.DbFlag.WriteSchema | int.DbFlag.Defensive) != int.DbFlag.WriteSchema) {
                aux.vdbeError(e.v, "index corruption", .{});
                e.rc = RC.CORRUPT_INDEX;
                return .abort;
            }
            c.cache_status = vi.cache_stale;
            c.seek_result = 0;
            return .next;
        }
        if (op.p3 != 0) {
            // Skip the delete if the entry is the record in P3.
            const m = e.reg(op.p3);
            const n_key = cur.payloadSize();
            if (n_key == @as(u32, @intCast(m.n)) and m.flags & MEM.Blob != 0) {
                var t: Mem = .{ .db = e.db, .flags = 0 };
                mem.fromBtreeZeroOffset(cur, n_key, &t) catch |err| return e.fail(err);
                const same = std.mem.eql(u8, m.bytes(), t.bytes());
                mem.releaseMalloc(&t);
                if (same) {
                    mem.setNull(m);
                    return .next;
                }
            }
        }
        cur.delete(.{}) catch |err| return e.fail(err);
        c.cache_status = vi.cache_stale;
        c.seek_result = 0;
        return .next;
    }

    fn opIdxRowid(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        serial.cursorRestore(c) catch |err| return e.fail(err);
        if (!c.null_row) {
            const rowid = serial.idxRowid(e.db, c.uc.cursor) catch |err| return e.fail(err);
            if (op.opcode == OP.DeferredSeek) {
                const tab_cur = e.csr(op.p3);
                tab_cur.null_row = false;
                tab_cur.moveto_target = rowid;
                tab_cur.deferred_moveto = true;
                tab_cur.cache_status = vi.cache_stale;
                tab_cur.alt_map = if (op.p4 == .intarray) op.p4.intarray else null;
                tab_cur.alt_cursor = c;
            } else {
                e.out2Prerelease(op).u = .{ .i = rowid };
            }
        } else {
            mem.setNull(e.reg(op.p2));
        }
        return .next;
    }

    fn opIdxCompare(e: *Exec, op: *Op) Flow {
        const c = e.csr(op.p1);
        var r: vi.UnpackedRecord = .{
            .key_info = c.key_info.?,
            .mem = e.regs.ptr + @as(usize, @intCast(op.p3)),
            .n_field = @intCast(op.p4.int32),
            .default_rc = if (op.opcode < OP.IdxLT) -1 else 0,
        };
        var res = serial.idxKeyCompare(e.db, c, &r) catch |err| return e.fail(err);
        if (op.opcode & 1 == OP.IdxLT & 1) {
            res = -res;
        } else {
            res += 1;
        }
        return if (res > 0) .jump_p2 else .next;
    }
};

// ===================================================================
// Part 7: schema changes, row sets, triggers, counters and aggregates.

/// sqlite3VdbeFrameMemDel(): the destructor of the register holding a
/// trigger frame; the frame is freed when the statement halts.
fn frameMemDel(p: ?*anyopaque) void {
    const frame: *vi.VdbeFrame = @ptrCast(@alignCast(p.?));
    frame.parent = frame.v.del_frame;
    frame.v.del_frame = frame;
}

const Part7 = struct {
    inline fn dispatch7(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.Destroy => opDestroy(e, op),
            OP.Clear => opClear(e, op),
            OP.ResetSorter => blk: {
                const c = e.csr(op.p1);
                if (c.e_cur_type == .sorter) {
                    sorter.reset(e.db, c);
                } else {
                    _ = c.uc.cursor.bt.clearTable(c.pgno_root) catch |err| break :blk e.fail(err);
                }
                break :blk .next;
            },
            OP.CreateBtree => blk: {
                const out = e.out2Prerelease(op);
                const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
                const kind: btree.TableKind = if (op.p3 == 1) .intkey else .blobkey;
                const pgno = bt.createTable(kind) catch |err| break :blk e.fail(err);
                out.u = .{ .i = pgno };
                break :blk .next;
            },
            OP.SqlExec => blk: {
                var err_msg: ?[:0]u8 = null;
                const rc = @import("../sql/legacy.zig").execNoCallback(e.db, op.p4.z, &err_msg);
                if (err_msg != null or rc != RC.OK) {
                    aux.vdbeError(e.v, "{s}", .{err_msg orelse ""});
                    if (err_msg) |m| e.db.gpa.free(m);
                    if (rc == RC.NOMEM) break :blk .no_mem;
                    e.rc = if (rc != RC.OK) rc else RC.ERROR;
                    break :blk .abort;
                }
                break :blk .next;
            },
            OP.ParseSchema => opParseSchema(e, op),
            OP.LoadAnalysis => blk: {
                e.rc = @import("../sql/analyze.zig").analysisLoad(e.db, @intCast(op.p1));
                break :blk if (e.rc != RC.OK) .abort else .next;
            },
            OP.DropTable => blk: {
                @import("../sql/build.zig").unlinkAndDeleteTable(e.db, @intCast(op.p1), op.p4.z);
                break :blk .next;
            },
            OP.DropIndex => blk: {
                @import("../sql/build.zig").unlinkAndDeleteIndex(e.db, @intCast(op.p1), op.p4.z);
                break :blk .next;
            },
            OP.DropTrigger => blk: {
                @import("../sql/trigger.zig").unlinkAndDeleteTrigger(e.db, @intCast(op.p1), op.p4.z);
                break :blk .next;
            },
            OP.IntegrityCk => opIntegrityCk(e, op),
            OP.RowSetAdd => blk: {
                const in1 = e.reg(op.p1);
                if (in1.flags & MEM.Blob == 0) rowset.memSetRowSet(in1, e.db.gpa) catch break :blk .no_mem;
                rowset.fromMem(in1).insert(e.reg(op.p2).u.i) catch break :blk .no_mem;
                break :blk .next;
            },
            OP.RowSetRead => blk: {
                const in1 = e.reg(op.p1);
                const val: ?i64 = if (in1.flags & MEM.Blob == 0)
                    null
                else
                    rowset.fromMem(in1).next() catch break :blk .no_mem;
                if (val) |x| {
                    mem.setInt64(e.reg(op.p3), x);
                    break :blk .check_interrupt;
                }
                mem.setNull(in1);
                break :blk .jump_p2_check_interrupt;
            },
            OP.RowSetTest => blk: {
                const in1 = e.reg(op.p1);
                const in3 = e.reg(op.p3);
                const i_set = op.p4.int32;
                if (in1.flags & MEM.Blob == 0) rowset.memSetRowSet(in1, e.db.gpa) catch break :blk .no_mem;
                const rs = rowset.fromMem(in1);
                if (i_set != 0) {
                    const exists = rs.testBatch(i_set, in3.u.i) catch break :blk .no_mem;
                    if (exists) break :blk .jump_p2;
                }
                if (i_set >= 0) rs.insert(in3.u.i) catch break :blk .no_mem;
                break :blk .next;
            },
            OP.Program => opProgram(e, op),
            OP.Param => blk: {
                const out = e.out2Prerelease(op);
                const frame = e.v.frame.?;
                const in_ = &frame.mem[@intCast(op.p1 + frame.ops[@intCast(frame.pc)].p1)];
                mem.shallowCopy(out, in_, MEM.Ephem);
                break :blk .next;
            },
            OP.FkCounter => blk: {
                if (op.p1 != 0) {
                    e.db.n_deferred_cons += op.p2;
                } else if (e.db.flags & int.DbFlag.DeferFKs != 0) {
                    e.db.n_deferred_imm_cons += op.p2;
                } else {
                    e.v.n_fk_constraint += op.p2;
                }
                break :blk .next;
            },
            OP.FkIfZero => blk: {
                const db = e.db;
                const zero = if (op.p1 != 0)
                    db.n_deferred_cons == 0 and db.n_deferred_imm_cons == 0
                else
                    e.v.n_fk_constraint == 0 and db.n_deferred_imm_cons == 0;
                break :blk if (zero) .jump_p2 else .next;
            },
            OP.MemMax => blk: {
                const in1 = e.rootReg(op.p1);
                mem.integerify(in1);
                const in2 = e.reg(op.p2);
                mem.integerify(in2);
                if (in1.u.i < in2.u.i) in1.u = .{ .i = in2.u.i };
                break :blk .next;
            },
            OP.IfPos => blk: {
                const in1 = e.reg(op.p1);
                if (in1.u.i > 0) {
                    in1.u.i -= op.p3;
                    break :blk .jump_p2;
                }
                break :blk .next;
            },
            OP.OffsetLimit => blk: {
                const in1 = e.reg(op.p1);
                const in3 = e.reg(op.p3);
                const out = e.out2Prerelease(op);
                const x = in1.u.i;
                const r = @addWithOverflow(x, if (in3.u.i > 0) in3.u.i else 0);
                out.u = .{ .i = if (x <= 0 or r[1] != 0) -1 else r[0] };
                break :blk .next;
            },
            OP.IfNotZero => blk: {
                const in1 = e.reg(op.p1);
                if (in1.u.i != 0) {
                    if (in1.u.i > 0) in1.u.i -= 1;
                    break :blk .jump_p2;
                }
                break :blk .next;
            },
            OP.DecrJumpZero => blk: {
                const in1 = e.reg(op.p1);
                if (in1.u.i > std.math.minInt(i64)) in1.u.i -= 1;
                break :blk if (in1.u.i == 0) .jump_p2 else .next;
            },
            OP.AggInverse, OP.AggStep => opAggStep(e, op),
            OP.AggStep1 => opAggStep1(e, op),
            OP.AggValue, OP.AggFinal => opAggFinal(e, op),
            else => Part8.dispatch8(e, op),
        };
    }

    fn opDestroy(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const db = e.db;
        const out = e.out2Prerelease(op);
        out.flags = MEM.Null;
        if (db.n_vdbe_read > 1) {
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
            @import("../sql/build.zig").rootPageMoved(db, i_db, moved, @intCast(op.p1));
            e.reset_schema_on_fault = @intCast(i_db + 1);
        }
        return .next;
    }

    fn opClear(e: *Exec, op: *Op) Flow {
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

    fn opParseSchema(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const db = e.db;
        const prepare = @import("../sql/prepare.zig");
        const i_db: usize = @intCast(op.p1);
        var err_msg: ?[:0]u8 = null;
        var rc: i32 = undefined;
        if (op.p4 != .z) {
            // Reread the whole schema (after ALTER TABLE).
            schemaClear(db, i_db);
            db.m_db_flags &= ~int.DBFLAG.SchemaKnownOk;
            rc = prepare.initOne(db, i_db, &err_msg, op.p5);
            db.m_db_flags |= int.DBFLAG.SchemaChange;
            v.expired = 0;
        } else {
            db.init.busy = true;
            rc = prepare.parseSchemaWhere(db, i_db, op.p4.z, &err_msg);
            db.init.busy = false;
        }
        if (err_msg) |m| {
            v.err_msg = null;
            aux.vdbeError(v, "{s}", .{m});
            db.gpa.free(m);
        }
        if (rc != RC.OK) {
            @import("../sql/build.zig").resetAllSchemasOfConnection(db);
            if (rc == RC.NOMEM) return .no_mem;
            e.rc = rc;
            return .abort;
        }
        return .next;
    }

    fn schemaClear(db: *Sqlite3, i_db: usize) void {
        // sqlite3SchemaClear() comes with schema loading.
        @import("../sql/build.zig").resetOneSchema(db, i_db);
    }

    fn opIntegrityCk(e: *Exec, op: *Op) Flow {
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

    fn opProgram(e: *Exec, op: *Op) Flow {
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
            e.rc = RC.ERROR;
            return .abort;
        }
        var frame: *vi.VdbeFrame = undefined;
        if (rt.flags & MEM.Blob == 0) {
            frame = allocFrame(e, program) catch return .no_mem;
            mem.release(rt);
            rt.flags = MEM.Blob | MEM.Dyn;
            rt.z = @ptrCast(frame);
            rt.n = @sizeOf(vi.VdbeFrame);
            rt.x_del = frameMemDel;
        } else {
            frame = @ptrCast(@alignCast(rt.z.?));
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
        return .check_interrupt;
    }

    fn opAggStep(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const n: usize = op.p5;
        const a = v.alloc();
        const ctx = a.create(vi.Context) catch return .no_mem;
        const out = a.create(Mem) catch return .no_mem;
        const argv = a.alloc(*Mem, n) catch return .no_mem;
        out.* = .{ .db = e.db, .flags = MEM.Null };
        ctx.* = .{
            .out = out,
            .func = op.p4.funcdef,
            .mem = null,
            .vdbe = v,
            .i_op = @intCast(e.pc),
            .enc = e.encoding,
            .argc = @intCast(n),
            .argv = argv,
        };
        op.p4 = .{ .funcctx = ctx };
        op.opcode = OP.AggStep1;
        return opAggStep1(e, op);
    }

    fn opAggStep1(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const ctx = op.p4.funcctx;
        const m = e.reg(op.p3);
        if (ctx.mem != m) {
            ctx.mem = m;
            for (ctx.argv, 0..) |*arg, i| arg.* = e.reg(op.p2 + @as(i32, @intCast(i)));
        }
        m.n += 1;
        if (op.p1 != 0) {
            ctx.func.x_inverse.?(ctx, ctx.argv);
        } else {
            ctx.func.x_sfunc.?(ctx, ctx.argv);
        }
        if (ctx.is_error != 0) {
            if (ctx.is_error > 0) {
                aux.vdbeErrorFromMem(v, ctx.out);
                e.rc = ctx.is_error;
            }
            if (ctx.skip_flag) {
                const i = e.ops[@intCast(e.pc - 1)].p1;
                if (i != 0) mem.setInt64(e.reg(i), 1);
                ctx.skip_flag = false;
            }
            mem.release(ctx.out);
            ctx.out.flags = MEM.Null;
            ctx.is_error = 0;
            if (e.rc != RC.OK) return .abort;
        }
        return .next;
    }

    fn opAggFinal(e: *Exec, op: *Op) Flow {
        var m = e.reg(op.p1);
        var rc: i32 = undefined;
        if (op.p3 != 0) {
            rc = mem.aggValue(m, e.reg(op.p3), op.p4.funcdef);
            m = e.reg(op.p3);
        } else {
            rc = mem.finalize(m, op.p4.funcdef);
        }
        if (rc != 0) {
            aux.vdbeErrorFromMem(e.v, m);
            e.rc = rc;
            return .abort;
        }
        mem.changeEncoding(m, e.encoding) catch return .no_mem;
        return .next;
    }
};

// ===================================================================
// Part 8: pragmas, functions, Bloom filters and the rest.

/// PAGER_JOURNALMODE_* values and their names (sqlite3JournalModename).
const journal_mode_names = [_][:0]const u8{ "delete", "persist", "off", "truncate", "memory", "wal" };

/// iOnceResetThreshold of sqlite3GlobalConfig.
const once_reset_threshold: i32 = 0x7ffffffe;

/// Port of filterHash(): the Bloom filter hash of P4 registers from P3.
fn filterHash(regs: []Mem, op: *const Op) u64 {
    var h: u64 = 0;
    var i: usize = @intCast(op.p3);
    const end = i + @as(usize, @intCast(op.p4.int32));
    while (i < end) : (i += 1) {
        const m = &regs[i];
        if (m.flags & (MEM.Int | MEM.IntReal) != 0) {
            h +%= @bitCast(m.u.i);
        } else if (m.flags & MEM.Real != 0) {
            h +%= @bitCast(mem.intValue(m));
        } else if (m.flags & MEM.Str != 0) {
            const z = m.bytes();
            h +%= @intCast(z.len);
            if (z.len >= 8) {
                h +%= std.mem.readInt(u64, z[0..8], .little);
                h +%= std.mem.readInt(u64, z[z.len - 8 ..][0..8], .little);
            } else {
                var x: [8]u8 = @splat(0);
                @memcpy(x[0..z.len], z);
                h +%= std.mem.readInt(u64, &x, .little);
            }
        } else if (m.flags & MEM.Blob != 0) {
            const z = m.bytes();
            if (z.len != 0) {
                var x: [8]u8 = @splat(0);
                const k = @min(z.len, 8);
                @memcpy(x[0..k], z[0..k]);
                h +%= std.mem.readInt(u64, &x, .little);
            }
            h +%= @intCast(z.len);
            if (m.flags & MEM.Zero != 0) h +%= @intCast(m.u.n_zero);
        }
    }
    return h;
}

const Part8 = struct {
    inline fn dispatch8(e: *Exec, op: *Op) Flow {
        return switch (op.opcode) {
            OP.JournalMode => opJournalMode(e, op),
            OP.IncrVacuum => blk: {
                const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
                const more = bt.incrVacuum() catch |err| break :blk e.fail(err);
                break :blk if (more) .next else .jump_p2;
            },
            OP.Expire => blk: {
                if (op.p1 == 0) {
                    aux.expirePreparedStatements(e.db, @intCast(op.p2));
                } else {
                    e.v.expired = @intCast(op.p2 + 1);
                }
                break :blk .next;
            },
            // Cursor pinning only matters to the C b-tree's cell cache.
            OP.CursorLock, OP.CursorUnlock => .next,
            OP.Pagecount => blk: {
                const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
                e.out2Prerelease(op).u = .{ .i = bt.lastPage() };
                break :blk .next;
            },
            OP.PureFunc, OP.Function => opFunction(e, op),
            OP.ClrSubtype => blk: {
                e.reg(op.p1).flags &= ~MEM.Subtype;
                break :blk .next;
            },
            OP.GetSubtype => blk: {
                const in1 = e.reg(op.p1);
                const out = e.reg(op.p2);
                if (in1.flags & MEM.Subtype != 0) {
                    mem.setInt64(out, in1.e_subtype);
                } else {
                    mem.setNull(out);
                }
                break :blk .next;
            },
            OP.SetSubtype => blk: {
                const in1 = e.reg(op.p1);
                const out = e.reg(op.p2);
                if (in1.flags & MEM.Null != 0) {
                    out.flags &= ~MEM.Subtype;
                } else {
                    out.flags |= MEM.Subtype;
                    out.e_subtype = @truncate(@as(u64, @bitCast(in1.u.i)));
                }
                break :blk .next;
            },
            OP.FilterAdd => blk: {
                const in1 = e.reg(op.p1);
                var h = filterHash(e.regs, op);
                h %= @as(u64, @intCast(in1.n)) * 8;
                in1.z.?[h / 8] |= @as(u8, 1) << @intCast(h & 7);
                break :blk .next;
            },
            OP.Filter => blk: {
                const in1 = e.reg(op.p1);
                var h = filterHash(e.regs, op);
                h %= @as(u64, @intCast(in1.n)) * 8;
                if (in1.z.?[h / 8] & (@as(u8, 1) << @intCast(h & 7)) == 0) {
                    e.v.counters[vi.STMTSTATUS.FILTER_HIT] += 1;
                    break :blk .jump_p2;
                }
                e.v.counters[vi.STMTSTATUS.FILTER_MISS] += 1;
                break :blk .next;
            },
            OP.Trace, OP.Init => blk: {
                if (op.p1 >= once_reset_threshold) {
                    if (op.opcode == OP.Trace) break :blk .next;
                    for (e.ops[1..]) |*o| {
                        if (o.opcode == OP.Once) o.p1 = 0;
                    }
                    op.p1 = 0;
                }
                op.p1 += 1;
                e.v.counters[vi.STMTSTATUS.RUN] += 1;
                break :blk .jump_p2;
            },
            OP.Noop, OP.Explain, OP.CursorHint, OP.Abortable, OP.ReleaseReg => .next,
            else => blk: {
                // Savepoint, RowCell, IFindKey, Checkpoint, Vacuum, MaxPgcnt,
                // TableLock and the virtual table opcodes: not ported yet.
                const name = if (op.opcode < vi.opcodes.names.len) vi.opcodes.names[op.opcode].name else "?";
                aux.vdbeError(e.v, "not supported yet: OP_{s}", .{name});
                e.rc = RC.ERROR;
                break :blk .abort;
            },
        };
    }

    fn opJournalMode(e: *Exec, op: *Op) Flow {
        const out = e.out2Prerelease(op);
        const bt = e.db.dbs.items[@intCast(op.p1)].bt.?;
        const pager = bt.pager;
        const old: usize = switch (pager.journal_mode) {
            .delete => 0,
            .persist => 1,
            .off => 2,
            .truncate => 3,
        };
        var new: usize = if (op.p3 < 0) old else @intCast(op.p3);
        // MEMORY and WAL journals are not supported, and the mode cannot
        // change while writing.
        if (new >= 4 or bt.in_trans == .write) new = old;
        pager.setJournalMode(switch (new) {
            0 => .delete,
            1 => .persist,
            2 => .off,
            else => .truncate,
        });
        const name = journal_mode_names[new];
        out.flags = MEM.Str | MEM.Static | MEM.Term;
        out.z = @constCast(name.ptr);
        out.n = @intCast(name.len);
        out.enc = ENC.UTF8;
        return .next;
    }

    fn opFunction(e: *Exec, op: *Op) Flow {
        const v = e.v;
        const ctx = op.p4.funcctx;
        const out = e.reg(op.p3);
        if (ctx.out != out) {
            ctx.vdbe = v;
            ctx.out = out;
            ctx.enc = e.encoding;
            for (ctx.argv, 0..) |*arg, i| arg.* = e.reg(op.p2 + @as(i32, @intCast(i)));
        }
        out.setTypeFlag(MEM.Null);
        ctx.func.x_sfunc.?(ctx, ctx.argv);
        if (ctx.is_error != 0) {
            if (ctx.is_error > 0) {
                aux.vdbeErrorFromMem(v, out);
                e.rc = ctx.is_error;
            }
            aux.deleteAuxData(e.db, &v.aux_data, ctx.i_op, @bitCast(op.p1));
            ctx.is_error = 0;
            if (e.rc != RC.OK) return .abort;
        }
        return .next;
    }
};

/// INT32_TO_64(): P1 is the low half, P3 the high half.
fn int32To64(lo: i32, hi: i32) i64 {
    return @bitCast(@as(u64, @as(u32, @bitCast(hi))) << 32 | @as(u32, @bitCast(lo)));
}
