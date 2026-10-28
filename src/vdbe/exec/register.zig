//! Opcodes of constants and registers (vdbe.c): loading values, copying
//! and moving registers, OP_ResultRow and subtypes.

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
const MEM = vi.MEM;
const OP = vi.OP;
const ENC = vi.ENC;
const RC = int.RC;

/// INT32_TO_64(): P1 is the low half, P3 the high half.
fn int32To64(lo: i32, hi: i32) i64 {
    return @bitCast(@as(u64, @as(u32, @bitCast(hi))) << 32 | @as(u32, @bitCast(lo)));
}

pub fn opInteger(e: *Exec, op: *Op) Flow {
    e.out2Prerelease(op).u = .{ .i = op.p1 };
    return .next;
}

pub fn opInt64(e: *Exec, op: *Op) Flow {
    e.out2Prerelease(op).u = .{ .i = int32To64(op.p1, op.p3) };
    return .next;
}

pub fn opReal(e: *Exec, op: *Op) Flow {
    const out = e.out2Prerelease(op);
    out.flags = .{ .Real = true };
    out.u = .{ .r = @bitCast(int32To64(op.p1, op.p3)) };
    return .next;
}

/// OP_String8 becomes OP_String, with the length in P1, on its first run.
pub fn opString8(e: *Exec, op: *Op) Error!Flow {
    _ = e.out2Prerelease(op);
    op.p1 = @intCast(std.mem.len(op.p4.z));
    std.debug.assert(e.encoding == ENC.UTF8);
    if (op.p1 > e.db.limit(.length)) return error.TooBig;
    op.opcode = OP.String;
    return opString(e, op);
}

pub fn opString(e: *Exec, op: *Op) Flow {
    const out = e.out2Prerelease(op);
    out.flags = .{ .Str = true, .Static = true, .Term = true };
    out.z = @constCast(op.p4.z);
    out.n = op.p1;
    out.enc = e.encoding;
    if (op.p3 > 0) {
        const in3 = e.reg(op.p3);
        std.debug.assert(in3.flags.Int);
        if (in3.u.i == op.p5) out.flags = .{ .Blob = true, .Static = true, .Term = true };
    }
    return .next;
}

/// OP_Null and OP_BeginSubrtn.
pub fn opNull(e: *Exec, op: *Op) Flow {
    var out = e.out2Prerelease(op);
    var cnt = op.p3 - op.p2;
    const null_flag: MEM = if (op.p1 != 0) .{ .Null = true, .Cleared = true } else .{ .Null = true };
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

pub fn opSoftNull(e: *Exec, op: *Op) Flow {
    const out = e.reg(op.p1);
    out.flags = out.flags.without(MEM.Undefined.with(MEM.AffMask)).with(.{ .Null = true });
    return .next;
}

pub fn opBlob(e: *Exec, op: *Op) Error!Flow {
    const out = e.out2Prerelease(op);
    if (op.p4type != .z) {
        mem.setZeroBlob(out, op.p1);
        try mem.expandBlob(out);
    } else {
        mem.setStr(out, op.p4.z[0..@intCast(op.p1)], 0, .static) catch {};
    }
    out.enc = e.encoding;
    return .next;
}

pub fn opVariable(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    std.debug.assert(op.p1 > 0 and op.p1 <= v.n_var);
    const var_ = &v.vars[@intCast(op.p1 - 1)];
    if (mem.tooBig(var_)) return error.TooBig;
    const out = e.reg(op.p2);
    if (out.isDynamic()) mem.setNull(out);
    out.u = var_.u;
    out.z = var_.z;
    out.n = var_.n;
    out.flags = var_.flags;
    out.enc = var_.enc;
    out.e_subtype = var_.e_subtype;
    out.flags.clear(.{ .Dyn = true, .Ephem = true });
    out.flags.set(.{ .Static = true, .FromBind = true });
    return .next;
}

pub fn opMove(e: *Exec, op: *Op) Error!Flow {
    var n = op.p3;
    var p1 = op.p1;
    var p2 = op.p2;
    std.debug.assert(n > 0 and p1 > 0 and p2 > 0);
    std.debug.assert(p1 + n <= p2 or p2 + n <= p1);
    while (n > 0) : (n -= 1) {
        const out = e.reg(p2);
        mem.move(out, e.reg(p1));
        if (out.flags.Ephem) try mem.makeWriteable(out);
        p1 += 1;
        p2 += 1;
    }
    return .next;
}

pub fn opCopy(e: *Exec, op: *Op) Error!Flow {
    var n = op.p3;
    var in1 = op.p1;
    var outr = op.p2;
    std.debug.assert(in1 != outr);
    while (true) {
        const out = e.reg(outr);
        mem.shallowCopy(out, e.reg(in1), .{ .Ephem = true });
        if (out.flags.Ephem) try mem.makeWriteable(out);
        if (out.flags.Subtype and op.p5 & 0x0002 != 0) out.flags.Subtype = false;
        if (n == 0) break;
        n -= 1;
        outr += 1;
        in1 += 1;
    }
    return .next;
}

pub fn opSCopy(e: *Exec, op: *Op) Flow {
    std.debug.assert(op.p1 != op.p2);
    mem.shallowCopy(e.reg(op.p2), e.reg(op.p1), .{ .Ephem = true });
    return .next;
}

pub fn opIntCopy(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(in1.flags.Int);
    mem.setInt64(e.reg(op.p2), in1.u.i);
    return .next;
}

pub fn opFkCheck(e: *Exec, op: *Op) Error!Flow {
    _ = op;
    try aux.checkFkImmediate(e.v);
    return .next;
}

pub fn opResultRow(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    std.debug.assert(v.n_res_column == op.p2);
    v.cache_ctr = (v.cache_ctr + 2) | 1;
    v.result_row = e.regs.ptr + @as(usize, @intCast(op.p1));
    if (e.db.malloc_failed) return error.OutOfMemory;
    v.pc = @intCast(e.pc + 1);
    e.rc = RC.ROW;
    return .ret;
}

pub fn opClrSubtype(e: *Exec, op: *Op) Flow {
    e.reg(op.p1).flags.Subtype = false;
    return .next;
}

pub fn opGetSubtype(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const out = e.reg(op.p2);
    if (in1.flags.Subtype) {
        mem.setInt64(out, in1.e_subtype);
    } else {
        mem.setNull(out);
    }
    return .next;
}

pub fn opSetSubtype(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    const out = e.reg(op.p2);
    if (in1.flags.Null) {
        out.flags.Subtype = false;
    } else {
        out.flags.Subtype = true;
        out.e_subtype = @truncate(@as(u64, @bitCast(in1.u.i)));
    }
    return .next;
}
