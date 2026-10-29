//! The other opcodes (vdbe.c): row sets (OP_RowSetAdd, OP_RowSetRead,
//! OP_RowSetTest), Bloom filters (OP_FilterAdd, OP_Filter), and the
//! opcodes this port does not run yet.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const rowset = @import("../rowset.zig");
const int = @import("../../sql/sqlite_int.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const RC = int.RC;

// ================================================================ row sets

pub fn opRowSetAdd(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    if (!in1.flags.Blob) try rowset.memSetRowSet(in1, e.db.gpa);
    try rowset.fromMem(in1).insert(e.reg(op.p2).u.i);
    return .next;
}

pub fn opRowSetRead(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    const val: ?i64 = if (!in1.flags.Blob)
        null
    else
        try rowset.fromMem(in1).next();
    if (val) |x| {
        mem.setInt64(e.reg(op.p3), x);
        return .check_interrupt;
    }
    mem.setNull(in1);
    return .jump_p2_check_interrupt;
}

pub fn opRowSetTest(e: *Exec, op: *Op) Error!Flow {
    const in1 = e.reg(op.p1);
    const in3 = e.reg(op.p3);
    const i_set = op.p4.int32;
    if (!in1.flags.Blob) try rowset.memSetRowSet(in1, e.db.gpa);
    const rs = rowset.fromMem(in1);
    if (i_set != 0) {
        const exists = try rs.testBatch(i_set, in3.u.i);
        if (exists) return .jump_p2;
    }
    if (i_set >= 0) try rs.insert(in3.u.i);
    return .next;
}

// =========================================================== Bloom filters

/// Port of filterHash(): the Bloom filter hash of P4 registers from P3.
fn filterHash(regs: []Mem, op: *const Op) u64 {
    var h: u64 = 0;
    var i: usize = @intCast(op.p3);
    const end = i + @as(usize, @intCast(op.p4.int32));
    while (i < end) : (i += 1) {
        const m = &regs[i];
        if (m.flags.intersects(.{ .Int = true, .IntReal = true })) {
            h +%= @bitCast(m.u.i);
        } else if (m.flags.Real) {
            h +%= @bitCast(mem.intValue(m));
        } else if (m.flags.Str) {
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
        } else if (m.flags.Blob) {
            const z = m.bytes();
            if (z.len != 0) {
                var x: [8]u8 = @splat(0);
                const k = @min(z.len, 8);
                @memcpy(x[0..k], z[0..k]);
                h +%= std.mem.readInt(u64, &x, .little);
            }
            h +%= @intCast(z.len);
            if (m.flags.Zero) h +%= @intCast(m.u.n_zero);
        }
    }
    return h;
}

pub fn opFilterAdd(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    var h = filterHash(e.regs, op);
    h %= @as(u64, @intCast(in1.n)) * 8;
    in1.z.?[h / 8] |= @as(u8, 1) << @intCast(h & 7);
    return .next;
}

pub fn opFilter(e: *Exec, op: *Op) Flow {
    const in1 = e.reg(op.p1);
    var h = filterHash(e.regs, op);
    h %= @as(u64, @intCast(in1.n)) * 8;
    if (in1.z.?[h / 8] & (@as(u8, 1) << @intCast(h & 7)) == 0) {
        e.v.counters[vi.STMTSTATUS.FILTER_HIT] += 1;
        return .jump_p2;
    }
    e.v.counters[vi.STMTSTATUS.FILTER_MISS] += 1;
    return .next;
}

// ============================================================ not ported

/// Vacuum (not ported yet), TableLock (shared cache only), Offset and
/// ColumnsUsed (not in the C build either).
pub fn opNotSupported(e: *Exec, op: *Op) Error!Flow {
    aux.vdbeError(e.v, "not supported yet: OP_{s}", .{op.opcode.name()});
    return error.Error;
}
