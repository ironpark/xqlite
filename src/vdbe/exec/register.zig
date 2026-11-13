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
const OpOf = vi.OpOf;
const MEM = vi.MEM;
const OP = vi.OP;
const ENC = vi.ENC;
const RC = int.RC;

/// The opcodes this module runs, for the run loop (see exec.zig).
pub const handlers = .{
    .{ .ops = .{.Integer}, .f = opInteger, .call = .always_inline },
    .{ .ops = .{.Int64}, .f = opInt64 },
    .{ .ops = .{.Real}, .f = opReal },
    .{ .ops = .{.String8}, .f = opString8 },
    .{ .ops = .{.String}, .f = opString },
    .{ .ops = .{ .BeginSubrtn, .Null }, .f = opNull },
    .{ .ops = .{.SoftNull}, .f = opSoftNull },
    .{ .ops = .{.Blob}, .f = opBlob },
    .{ .ops = .{.Variable}, .f = opVariable },
    .{ .ops = .{.Move}, .f = opMove },
    .{ .ops = .{.Copy}, .f = opCopy, .call = .always_inline },
    .{ .ops = .{.SCopy}, .f = opSCopy, .call = .always_inline },
    .{ .ops = .{.IntCopy}, .f = opIntCopy },
    .{ .ops = .{.FkCheck}, .f = opFkCheck },
    .{ .ops = .{.ResultRow}, .f = opResultRow, .call = .always_inline },
    .{ .ops = .{.ClrSubtype}, .f = opClrSubtype },
    .{ .ops = .{.GetSubtype}, .f = opGetSubtype },
    .{ .ops = .{.SetSubtype}, .f = opSetSubtype },
};

/// INT32_TO_64(): P1 is the low half, P3 the high half.
fn int32To64(lo: i32, hi: i32) i64 {
    return @bitCast(@as(u64, @as(u32, @bitCast(hi))) << 32 | @as(u32, @bitCast(lo)));
}

pub fn opInteger(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Flow {
    e.out2Prerelease(op).u = .{ .i = op.p1 };
    return .next;
}

pub fn opInt64(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Flow {
    e.out2Prerelease(op).u = .{ .i = int32To64(op.p1, op.p3) };
    return .next;
}

pub fn opReal(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Flow {
    const out = e.out2Prerelease(op);
    out.flags = .{ .Real = true };
    out.u = .{ .r = @bitCast(int32To64(op.p1, op.p3)) };
    return .next;
}

/// OP_String8 becomes OP_String, with the length in P1, on its first run.
/// In a UTF-16 database the string is first converted, once, into a
/// buffer of the program that becomes P4.
pub fn opString8(e: *Exec, op: *OpOf(.{ .int, .reg, .reg })) Error!Flow {
    _ = e.out2Prerelease(op);
    op.p1 = @intCast(std.mem.len(op.p4As(.z)));
    if (e.encoding != ENC.UTF8) try string8ToUtf16(e, op.raw());
    if (op.p1 > e.db.limit(.length)) return error.TooBig;
    op.opcode = OP.String;
    return opString(e, op);
}

fn string8ToUtf16(e: *Exec, op: *Op) Error!void {
    @branchHint(.cold);
    if (op.p1 > e.db.limit(.length)) return error.TooBig;
    const utf = @import("../utf.zig");
    const in = op.p4As(.z)[0..@intCast(op.p1)];
    // Aligned for a C reader of sqlite3_value_text16() (C: a malloc).
    const buf = try e.v.alloc().alignedAlloc(u8, .@"8", utf.maxLen(in.len, e.encoding));
    const n = utf.translate(in, ENC.UTF8, e.encoding, buf);
    // The program's arena owns the buffer (C: P4_DYNAMIC).
    op.p4 = .{ .z = @ptrCast(buf.ptr) };
    op.p1 = @intCast(n);
}

pub fn opString(e: *Exec, op: *OpOf(.{ .int, .reg, .reg })) Flow {
    const out = e.out2Prerelease(op);
    out.flags = .{ .Str = true, .Static = true, .Term = true };
    out.z = @constCast(op.p4As(.z));
    out.n = op.p1;
    out.enc = e.encoding;
    if (op.p3 != .none) {
        const in3 = e.reg(op.p3);
        std.debug.assert(in3.flags.Int);
        if (in3.u.i == op.p5) out.flags = .{ .Blob = true, .Static = true, .Term = true };
    }
    return .next;
}

/// OP_Null and OP_BeginSubrtn.
pub fn opNull(e: *Exec, op: *OpOf(.{ .int, .reg, .reg })) Flow {
    const out = e.out2Prerelease(op);
    const null_flag: MEM = if (op.p1 != 0) .{ .Null = true, .Cleared = true } else .{ .Null = true };
    out.flags = null_flag;
    out.n = 0;
    // The registers after P2 through P3 (none if P3 is not after P2).
    const cnt = op.p3.int() - op.p2.int();
    if (cnt > 0) for (e.regRange(op.p2.at(1), @intCast(cnt))) |*m| {
        mem.setNull(m);
        m.flags = null_flag;
        m.n = 0;
    };
    return .next;
}

pub fn opSoftNull(e: *Exec, op: *OpOf(.{ .reg, .int, .int })) Flow {
    const out = e.reg(op.p1);
    out.flags = out.flags.without(MEM.Undefined.with(MEM.AffMask)).with(.{ .Null = true });
    return .next;
}

pub fn opBlob(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Error!Flow {
    const out = e.out2Prerelease(op);
    if (op.p4type != .z) {
        mem.setZeroBlob(out, op.p1);
        try mem.expandBlob(out);
    } else {
        mem.setStr(out, op.p4As(.z)[0..@intCast(op.p1)], 0, .static) catch {};
    }
    out.enc = e.encoding;
    return .next;
}

pub fn opVariable(e: *Exec, op: *OpOf(.{ .int, .reg, .int })) Error!Flow {
    const v = e.v;
    std.debug.assert(op.p1 > 0 and op.p1 <= v.vars.len);
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

pub fn opMove(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Error!Flow {
    const n: usize = @intCast(op.p3);
    std.debug.assert(n > 0 and op.p1 != .none and op.p2 != .none);
    const from = e.regRange(op.p1, n);
    const to = e.regRange(op.p2, n);
    std.debug.assert(op.p1.at(n).int() <= op.p2.int() or op.p2.at(n).int() <= op.p1.int());
    for (to, from) |*out, *in| {
        mem.move(out, in);
        if (out.flags.Ephem) try mem.makeWriteable(out);
    }
    return .next;
}

pub fn opCopy(e: *Exec, op: *vi.OpWithP5(.{ .reg, .reg, .int }, vi.CopyP5)) Error!Flow {
    // P3+1 registers (P3 is the number after the first).
    const n: usize = @as(usize, @intCast(op.p3)) + 1;
    std.debug.assert(op.p1 != op.p2);
    for (e.regRange(op.p2, n), e.regRange(op.p1, n)) |*out, *in| {
        mem.shallowCopy(out, in, .{ .Ephem = true });
        if (out.flags.Ephem) try mem.makeWriteable(out);
        if (out.flags.Subtype and op.p5.clear_subtype) out.flags.Subtype = false;
    }
    return .next;
}

pub fn opSCopy(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Flow {
    std.debug.assert(op.p1 != op.p2);
    mem.shallowCopy(e.reg(op.p2), e.reg(op.p1), .{ .Ephem = true });
    return .next;
}

pub fn opIntCopy(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Flow {
    const in1 = e.reg(op.p1);
    std.debug.assert(in1.flags.Int);
    mem.setInt64(e.reg(op.p2), in1.u.i);
    return .next;
}

pub fn opFkCheck(e: *Exec, op: *OpOf(.{ .int, .int, .int })) Error!Flow {
    _ = op;
    try aux.checkFkImmediate(e.v);
    return .next;
}

pub fn opResultRow(e: *Exec, op: *OpOf(.{ .reg, .int, .int })) Error!Flow {
    const v = e.v;
    std.debug.assert(v.n_res_column == op.p2);
    v.cache_ctr = (v.cache_ctr + 2) | 1;
    v.result_row = e.regRange(op.p1, v.n_res_column);
    if (e.db.malloc_failed) return error.OutOfMemory;
    if (e.db.m_trace & int.TRACE.ROW != 0) _ = e.db.trace_v2.?(int.TRACE.ROW, e.db.trace_arg, v, null);
    v.pc = @intCast(e.pc + 1);
    e.rc = RC.ROW;
    return .ret;
}

pub fn opClrSubtype(e: *Exec, op: *OpOf(.{ .reg, .int, .int })) Flow {
    e.reg(op.p1).flags.Subtype = false;
    return .next;
}

pub fn opGetSubtype(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Flow {
    const in1 = e.reg(op.p1);
    const out = e.reg(op.p2);
    if (in1.flags.Subtype) {
        mem.setInt64(out, in1.e_subtype);
    } else {
        mem.setNull(out);
    }
    return .next;
}

pub fn opSetSubtype(e: *Exec, op: *OpOf(.{ .reg, .reg, .int })) Flow {
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
