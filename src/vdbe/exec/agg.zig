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
const OpOf = vi.OpOf;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const RC = int.RC;

/// The opcodes this module runs, for the run loop (see exec.zig).
pub const handlers = .{
    .{ .ops = .{ .PureFunc, .Function }, .f = opFunction, .call = .always_inline },
    .{ .ops = .{ .AggInverse, .AggStep, .AggStep1 }, .f = opAggStep, .call = .always_inline },
    .{ .ops = .{ .AggValue, .AggFinal }, .f = opAggFinal },
};

/// OP_Function and OP_PureFunc.
pub fn opFunction(e: *Exec, op: *OpOf(.{ .int, .reg, .reg })) Error!Flow {
    const v = e.v;
    const ctx = op.p4As(.funcctx);
    const out = e.reg(op.p3);
    // The first run (ctx.vdbe still null; C starts with pOut == 0), or
    // the registers moved: point the arguments at them. ctx.out is
    // undefined until then, and may well equal `out` by chance.
    if (ctx.vdbe == null or ctx.out != out) {
        ctx.vdbe = v;
        ctx.out = out;
        ctx.enc = e.encoding;
        for (ctx.argv, e.regRange(op.p2, ctx.argv.len)) |*arg, *m| arg.* = m;
    }
    out.setTypeFlag(.{ .Null = true });
    ctx.func.x_sfunc.?(ctx, ctx.argv);
    // A UTF-16 database: the result in its encoding (C's
    // setResultStrOrError() converts to Context.enc).
    if (e.encoding != vi.ENC.UTF8) try resultToEnc(e, out);
    if (ctx.is_error != 0) {
        // The function's result code, converted inward.
        var rc: i32 = RC.OK;
        if (ctx.is_error > 0) {
            aux.vdbeErrorFromMem(v, out);
            v.err_state = ctx.err_state;
            rc = ctx.is_error;
        }
        aux.deleteAuxData(e.db, &v.aux_data, ctx.i_op, @bitCast(op.p1));
        ctx.is_error = 0;
        ctx.err_state = null;
        try e.check(rc);
    }
    return .next;
}

fn resultToEnc(e: *Exec, out: *Mem) error{OutOfMemory}!void {
    @branchHint(.cold);
    try mem.changeEncoding(out, e.encoding);
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
        .func = op.p4As(.funcdef),
        .mem = null,
        .vdbe = v,
        .i_op = @intCast(e.pc),
        .enc = e.encoding,
        .argv = argv,
    };
    op.setP4(.{ .funcctx = ctx });
    op.opcode = OP.AggStep1;
}

/// OP_AggStep, OP_AggInverse and OP_AggStep1: as in C, where the first
/// two fall through into the last once they have become it.
pub fn opAggStep(e: *Exec, op: *OpOf(.{ .int, .reg, .reg }), comptime opc: OP) Error!Flow {
    if (opc != .AggStep1) try aggStepInit(e, op.raw());
    const v = e.v;
    const ctx = op.p4As(.funcctx);
    const m = e.reg(op.p3);
    if (ctx.mem != m) {
        ctx.mem = m;
        for (ctx.argv, e.regRange(op.p2, ctx.argv.len)) |*arg, *m2| arg.* = m2;
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
            v.err_state = ctx.err_state;
            rc = ctx.is_error;
        }
        ctx.err_state = null;
        if (ctx.skip_flag) {
            // The register of the OP_CollSeq before.
            const i = e.opAt(.CollSeq, e.pc - 1).p1;
            if (i != .none) mem.setInt64(e.reg(i), 1);
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
pub fn opAggFinal(e: *Exec, op: *OpOf(.{ .reg, .int, .reg })) Error!Flow {
    var m = e.reg(op.p1);
    var r: mem.AggResult = undefined;
    if (op.p3 != .none) {
        r = mem.aggValue(m, e.reg(op.p3), op.p4As(.funcdef));
        m = e.reg(op.p3);
    } else {
        r = mem.finalize(m, op.p4As(.funcdef));
    }
    if (r.rc != 0) {
        aux.vdbeErrorFromMem(e.v, m);
        e.v.err_state = r.state;
        return e.abort(r.rc);
    }
    try mem.changeEncoding(m, e.encoding);
    return .next;
}
