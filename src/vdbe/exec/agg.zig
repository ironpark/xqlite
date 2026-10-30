//! Opcodes that call SQL functions (vdbe.c): OP_Function and
//! OP_PureFunc, and the aggregate steps and results.

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
const RC = int.RC;

/// OP_Function and OP_PureFunc.
pub fn opFunction(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const ctx = op.p4.funcctx;
    const out = e.reg(op.p3);
    // The first run (ctx.vdbe still null; C starts with pOut == 0), or
    // the registers moved: point the arguments at them. ctx.out is
    // undefined until then, and may well equal `out` by chance.
    if (ctx.vdbe == null or ctx.out != out) {
        ctx.vdbe = v;
        ctx.out = out;
        ctx.enc = e.encoding;
        for (ctx.argv, 0..) |*arg, i| arg.* = e.reg(op.p2 + @as(i32, @intCast(i)));
    }
    out.setTypeFlag(.{ .Null = true });
    ctx.func.x_sfunc.?(ctx, ctx.argv);
    if (ctx.is_error != 0) {
        // The function's result code, converted inward.
        var rc: i32 = RC.OK;
        if (ctx.is_error > 0) {
            aux.vdbeErrorFromMem(v, out);
            rc = ctx.is_error;
        }
        aux.deleteAuxData(e.db, &v.aux_data, ctx.i_op, @bitCast(op.p1));
        ctx.is_error = 0;
        try e.check(rc);
    }
    return .next;
}

/// The first run of an OP_AggStep or OP_AggInverse: make the context of
/// the calls and become OP_AggStep1.
fn aggStepInit(e: *Exec, op: *Op) error{OutOfMemory}!void {
    const v = e.v;
    const n: usize = op.p5;
    const a = v.alloc();
    const ctx = try a.create(vi.Context);
    const out = try a.create(Mem);
    const argv = try a.alloc(*Mem, n);
    out.* = .{ .db = e.db, .flags = .{ .Null = true } };
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
    op.setP4(.{ .funcctx = ctx });
    op.opcode = OP.AggStep1;
}

/// OP_AggStep, OP_AggInverse and OP_AggStep1: as in C, where the first
/// two fall through into the last once they have become it.
pub fn opAggStep(e: *Exec, op: *Op) Error!Flow {
    if (op.opcode != OP.AggStep1) try aggStepInit(e, op);
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
        var rc: i32 = RC.OK;
        if (ctx.is_error > 0) {
            aux.vdbeErrorFromMem(v, ctx.out);
            rc = ctx.is_error;
        }
        if (ctx.skip_flag) {
            const i = e.ops[@intCast(e.pc - 1)].p1;
            if (i != 0) mem.setInt64(e.reg(i), 1);
            ctx.skip_flag = false;
        }
        mem.release(ctx.out);
        ctx.out.flags = .{ .Null = true };
        ctx.is_error = 0;
        try e.check(rc);
    }
    return .next;
}

/// OP_AggFinal and OP_AggValue.
pub fn opAggFinal(e: *Exec, op: *Op) Error!Flow {
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
        return e.abort(rc);
    }
    try mem.changeEncoding(m, e.encoding);
    return .next;
}
