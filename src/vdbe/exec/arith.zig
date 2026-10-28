//! Opcodes of expressions (vdbe.c): concatenation, arithmetic, bit
//! operations, casts and affinities, comparisons, and logic and NULL
//! tests.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const serial = @import("../serial.zig");
const int = @import("../../sql/sqlite_int.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const RC = int.RC;
const Aff = int.Aff;

pub fn opConcat(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    const in2 = e.reg(op.p2);
    const out = e.reg(op.p3);
    std.debug.assert(in1 != out);
    var flags1 = in1.flags;
    if (flags1.with(in2.flags).Null) {
        mem.setNull(out);
        return .next;
    }
    if (!flags1.intersects(.{ .Str = true, .Blob = true })) {
        try mem.stringify(in1, e.encoding, false);
        flags1 = in1.flags.without(.{ .Str = true });
    } else if (flags1.Zero) {
        try mem.expandBlob(in1);
        flags1 = in1.flags.without(.{ .Str = true });
    }
    var flags2 = in2.flags;
    if (!flags2.intersects(.{ .Str = true, .Blob = true })) {
        try mem.stringify(in2, e.encoding, false);
        flags2 = in2.flags.without(.{ .Str = true });
    } else if (flags2.Zero) {
        try mem.expandBlob(in2);
        flags2 = in2.flags.without(.{ .Str = true });
    }
    const n_byte: i64 = @as(i64, in1.n) + in2.n;
    if (n_byte > e.db.limit(.length)) return error.TooBig;
    if (n_byte > 2147483645) return error.TooBig;
    try mem.grow(out, @intCast(n_byte + 2), out == in2);
    out.setTypeFlag(.{ .Str = true });
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
    out.flags.Term = true;
    out.n = @intCast(n_byte);
    out.enc = e.encoding;
    return .next;
}

/// OP_Add, OP_Subtract, OP_Multiply, OP_Divide and OP_Remainder.
pub fn opArith(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const in2 = e.reg(op.p2);
    const out = e.reg(op.p3);
    var type1 = in1.flags;
    var type2 = in2.flags;
    if (!type1.only(type2).Int) {
        if (type1.with(type2).Null) {
            mem.setNull(out);
            return .next;
        }
        type1 = mem.numericType(in1);
        type2 = mem.numericType(in2);
    }
    if (type1.only(type2).Int) int_math: {
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
        out.setTypeFlag(.{ .Int = true });
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
    out.setTypeFlag(.{ .Real = true });
    return .next;
}

pub fn opCollSeq(e: *Exec, op: *Op) Flow {
    if (op.p1 != 0) mem.setInt64(e.reg(op.p1), 0);
    return .next;
}

/// OP_BitAnd, OP_BitOr, OP_ShiftLeft and OP_ShiftRight.
pub fn opBit(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const in2 = e.reg(op.p2);
    const out = e.reg(op.p3);
    if (in1.flags.with(in2.flags).Null) {
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
            opc = if (opc == .ShiftLeft) .ShiftRight else .ShiftLeft;
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
    out.setTypeFlag(.{ .Int = true });
    return .next;
}

pub fn opAddImm(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    mem.integerify(in1);
    in1.u = .{ .i = in1.u.i +% op.p2 };
    return .next;
}

pub fn opMustBeInt(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    if (!in1.flags.Int) {
        if (in1.flags.Real) {
            const r = in1.u.r;
            if (r >= -9223372036854775808.0 and r < 9223372036854775808.0) {
                const ix = @import("../../sql/numeric.zig").realToI64(r);
                if (@as(f64, @floatFromInt(ix)) == r) {
                    in1.u = .{ .i = ix };
                    in1.setTypeFlag(.{ .Int = true });
                }
            }
        } else {
            try mem.applyAffinity(in1, Aff.numeric, e.encoding);
        }
        if (!in1.flags.Int) {
            if (op.p2 == 0) return error.Mismatch;
            return .jump_p2;
        }
    }
    in1.setTypeFlag(.{ .Int = true });
    return .next;
}

pub fn opRealAffinity(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    if (in1.flags.intersects(.{ .Int = true, .IntReal = true })) mem.realify(in1);
    return .next;
}

pub fn opCast(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    if (in1.flags.Zero) try mem.expandBlob(in1);
    try mem.cast(in1, @intCast(op.p2), e.encoding);
    return .next;
}

// ============================================================ comparisons

/// sqlite3aLTb, sqlite3aEQb, sqlite3aGTb: whether OP_Ne..OP_Ge jump when
/// the comparison is less than, equal to or greater than zero.
const cmp_lt = [6]bool{ true, false, false, true, true, false };
const cmp_eq = [6]bool{ false, true, false, true, false, true };
const cmp_gt = [6]bool{ true, false, true, false, false, true };

/// OP_Eq, OP_Ne, OP_Lt, OP_Le, OP_Gt and OP_Ge.
pub fn opCompareJump(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    const in3 = e.reg(op.p3);
    var flags1 = in1.flags;
    var flags3 = in3.flags;
    const k = op.opcode.compareIndex();
    if (flags1.only(flags3).Int) {
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
    if (flags1.with(flags3).Null) {
        if (op.p5 & vi.SQLITE_NULLEQ != 0) {
            // Only for OP_Eq and OP_Ne: equal if both are NULL.
            if (flags1.only(flags3).Null and !flags3.Cleared) {
                res = 0;
            } else {
                res = if (flags3.Null) -1 else 1;
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
            if (flags1.with(flags3).Str) {
                if (flags1.only(.{ .Int = true, .IntReal = true, .Real = true, .Str = true }) == MEM{ .Str = true }) {
                    mem.applyNumericAffinity(in1, false);
                    flags3 = in3.flags;
                }
                if (flags3.only(.{ .Int = true, .IntReal = true, .Real = true, .Str = true }) == MEM{ .Str = true }) {
                    mem.applyNumericAffinity(in3, false);
                }
            }
        } else if (affinity == Aff.text and flags1.with(flags3).Str) {
            if (flags1.Str) {
                in1.flags.clear(.{ .Int = true, .Real = true, .IntReal = true });
            } else if (flags1.intersects(.{ .Int = true, .Real = true, .IntReal = true })) {
                try mem.stringify(in1, e.encoding, true);
                flags1 = in1.flags.without(MEM.TypeMask).with(flags1.only(MEM.TypeMask));
                if (in1 == in3) flags3 = flags1.with(.{ .Str = true });
            }
            if (flags3.Str) {
                in3.flags.clear(.{ .Int = true, .Real = true, .IntReal = true });
            } else if (flags3.intersects(.{ .Int = true, .Real = true, .IntReal = true })) {
                try mem.stringify(in3, e.encoding, true);
                flags3 = in3.flags.without(MEM.TypeMask).with(flags3.only(MEM.TypeMask));
            }
        }
        const coll: ?*const int.CollSeq = if (op.p4type == .collseq) op.p4.collseq else null;
        res = serial.memCompare(in3, in1, coll);
    }
    const res2 = if (res < 0) cmp_lt[k] else if (res == 0) cmp_eq[k] else cmp_gt[k];
    e.i_compare = res;
    // Undo the affinity changes to the inputs.
    in3.flags = flags3;
    in1.flags = flags1;
    return if (res2) .jump_p2 else .next;
}

pub fn opElseEq(e: *Exec, op: *Op) Flow {
    _ = op;
    return if (e.i_compare == 0) .jump_p2 else .next;
}

pub fn opCompare(e: *Exec, op: *Op) Flow {
    // The OP_Permutation before, if P5 says so, orders the fields.
    const permute: ?[*]u32 = if (op.p5 & vi.OPFLAG.PERMUTE != 0) e.ops[@intCast(e.pc - 1)].p4.intarray + 1 else null;
    const n: usize = @intCast(op.p3);
    const ki = op.p4.keyinfo;
    for (0..n) |i| {
        const idx: i32 = @intCast(if (permute) |pa| pa[i] else i);
        const m1 = e.reg(op.p1 + idx);
        const m2 = e.reg(op.p2 + idx);
        const coll: ?*const int.CollSeq = ki.coll[i];
        e.i_compare = serial.memCompare(m1, m2, coll);
        if (e.i_compare != 0) {
            if (ki.sort_flags[i] & int.KeyInfoOrder.bignull != 0 and (m1.flags.Null or m2.flags.Null)) {
                e.i_compare = -e.i_compare;
            }
            if (ki.sort_flags[i] & int.KeyInfoOrder.desc != 0) e.i_compare = -e.i_compare;
            break;
        }
    }
    return .next;
}

pub fn opJump(e: *Exec, op: *Op) Flow {
    if (e.i_compare < 0) {
        e.pc = op.p1 - 1;
    } else if (e.i_compare == 0) {
        e.pc = op.p2 - 1;
    } else {
        e.pc = op.p3 - 1;
    }
    return .goto_pc;
}

// ================================================================== logic

const and_logic = [9]u8{ 0, 0, 0, 0, 1, 2, 0, 2, 2 };
const or_logic = [9]u8{ 0, 1, 2, 1, 1, 1, 2, 1, 2 };

/// sqlite3VdbeBooleanValue(p, 2): 0 false, 1 true, 2 NULL.
fn boolOrNull(m: *Mem) usize {
    if (m.flags.Null) return 2;
    return @intFromBool(mem.booleanValue(m, false));
}

/// OP_And and OP_Or.
pub fn opAndOr(e: *Exec, op: *Op) Flow {
    const v1 = boolOrNull(e.reg(op.p1));
    const v2 = boolOrNull(e.reg(op.p2));
    const r = if (op.opcode == OP.And) and_logic[v1 * 3 + v2] else or_logic[v1 * 3 + v2];
    const out = e.reg(op.p3);
    if (r == 2) {
        out.setTypeFlag(.{ .Null = true });
    } else {
        out.u = .{ .i = r };
        out.setTypeFlag(.{ .Int = true });
    }
    return .next;
}

pub fn opIsTrue(e: *Exec, op: *Op) Flow {
    mem.setInt64(e.reg(op.p2), @intFromBool(mem.booleanValue(e.reg(op.p1), op.p3 != 0)) ^ op.p4.int32);
    return .next;
}

pub fn opNot(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const out = e.reg(op.p2);
    if (!in1.flags.Null) {
        mem.setInt64(out, @intFromBool(!mem.booleanValue(in1, false)));
    } else {
        mem.setNull(out);
    }
    return .next;
}

pub fn opBitNot(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const out = e.reg(op.p2);
    mem.setNull(out);
    if (!in1.flags.Null) {
        out.flags = .{ .Int = true };
        out.u = .{ .i = ~mem.intValue(in1) };
    }
    return .next;
}

pub fn opIf(e: *Exec, op: *Op) Flow {
    return if (mem.booleanValue(e.reg(op.p1), op.p3 != 0)) .jump_p2 else .next;
}

pub fn opIfNot(e: *Exec, op: *Op) Flow {
    return if (!mem.booleanValue(e.reg(op.p1), op.p3 == 0)) .jump_p2 else .next;
}

pub fn opIsNull(e: *Exec, op: *Op) Flow {
    return if (e.reg(op.p1).flags.Null) .jump_p2 else .next;
}

pub fn opZeroOrNull(e: *Exec, op: *Op) Flow {
    if (e.reg(op.p1).flags.Null or e.reg(op.p3).flags.Null) {
        mem.setNull(e.reg(op.p2));
    } else {
        mem.setInt64(e.reg(op.p2), 0);
    }
    return .next;
}

pub fn opNotNull(e: *Exec, op: *Op) Flow {
    return if (!e.reg(op.p1).flags.Null) .jump_p2 else .next;
}

pub fn opIfNullRow(e: *Exec, op: *Op) Flow {
    if (e.v.csr[@intCast(op.p1)]) |c| if (c.null_row) {
        mem.setNull(e.reg(op.p3));
        return .jump_p2;
    };
    return .next;
}
