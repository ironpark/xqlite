//! Opcodes that read and change b-tree content (vdbe.c): new rowids,
//! inserting and deleting rows and index entries, whole rows
//! (OP_RowData), counting, and the sorter's writes and reads.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const serial = @import("../serial.zig");
const sorter = @import("../sorter.zig");
const int = @import("../../sql/sqlite_int.zig");
const btree = @import("../../btree/btree.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const RC = int.RC;

/// The largest rowid (MAX_ROWID).
const max_rowid: i64 = std.math.maxInt(i64);

/// The cursor's seek result for Cursor.insert, if OPFLAG_USESEEKRESULT
/// says to use it (0 there means no seek was made).
fn insertSeekResult(op: *const Op, c: *const vi.VdbeCursor) ?std.math.Order {
    if (op.p5 & vi.OPFLAG.USESEEKRESULT == 0 or c.seek_result == 0) return null;
    return std.math.order(c.seek_result, 0);
}

pub fn opCount(e: *Exec, op: *Op) Error!Flow {
    const cur = e.csr(op.p1).uc.cursor;
    const n = try if (op.p3 != 0) cur.rowCountEst() else cur.count();
    e.out2Prerelease(op).u = .{ .i = n };
    return .check_interrupt;
}

pub fn opNewRowid(e: *Exec, op: *Op) Error!Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    const cur = c.uc.cursor;
    var rowid: i64 = 0;
    if (!c.use_random_rowid) {
        const has_last = try cur.last();
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
        // SQLITE_FULL: no rowid left.
        if (m.u.i == max_rowid or c.use_random_rowid) return error.DiskFull;
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
            const order = try cur.tableMoveto(rowid, false);
            found = order == .eq;
        }
        if (found) return error.DiskFull;
    }
    c.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    out.u = .{ .i = rowid };
    return .next;
}

pub fn opInsert(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const data = e.reg(op.p2);
    const c = e.csr(op.p1);
    const key = e.reg(op.p3);
    const rowid = key.u.i;
    if (op.p5 & vi.OPFLAG.NCHANGE != 0) {
        v.n_change += 1;
        if (op.p5 & vi.OPFLAG.LASTROWID != 0) e.db.last_rowid = rowid;
    }
    const x: btree.Payload = .{
        .rowid = rowid,
        .data = data.bytes(),
        .n_zero = if (data.flags.Zero) @intCast(data.u.n_zero) else 0,
    };
    const res = c.uc.cursor.insert(x, .{
        .append = op.p5 & vi.OPFLAG.APPEND != 0,
        .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
        .seek_result = insertSeekResult(op, c),
        .preformat = op.p5 & vi.OPFLAG.PREFORMAT != 0,
    });
    c.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    try res;
    return .next;
}

/// OP_RowCell: build the cell for the entry of cursor P2 in cursor P1,
/// with the rowid in register P3 for tables, for the OP_Insert or
/// OP_IdxInsert with OPFLAG_PREFORMAT that follows.
pub fn opRowCell(e: *Exec, op: *Op) Error!Flow {
    if (std.debug.runtime_safety) {
        const next = e.ops[@intCast(e.pc + 1)];
        std.debug.assert(next.opcode == .Insert or next.opcode == .IdxInsert);
        std.debug.assert(next.p5 & vi.OPFLAG.PREFORMAT != 0);
    }
    const dest = e.csr(op.p1).uc.cursor;
    const src = e.csr(op.p2).uc.cursor;
    const key: i64 = if (op.p3 != 0) e.reg(op.p3).u.i else 0;
    try dest.transferRow(src, key);
    return .next;
}

pub fn opDelete(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const c = e.csr(op.p1);
    const res = c.uc.cursor.delete(.{ .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0 });
    c.cache_status = vi.cache_stale;
    c.seek_result = 0;
    try res;
    if (op.p2 & vi.OPFLAG.NCHANGE != 0) v.n_change += 1;
    return .next;
}

pub fn opResetCount(e: *Exec, op: *Op) Flow {
    _ = op;
    aux.setChanges(e.db, e.v.n_change);
    e.v.n_change = 0;
    return .next;
}

pub fn opRowData(e: *Exec, op: *Op) Error!Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    const cur = c.uc.cursor;
    const n = cur.payloadSize();
    if (n > e.db.limit(.length)) return error.TooBig;
    try mem.fromBtreeZeroOffset(cur, n, out);
    if (op.p3 == 0 and out.flags.Ephem) try mem.makeWriteable(out);
    return .next;
}

pub fn opIdxInsert(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const c = e.csr(op.p1);
    const in2 = e.reg(op.p2);
    if (op.p5 & vi.OPFLAG.NCHANGE != 0) v.n_change += 1;
    if (in2.flags.Zero) try mem.expandBlob(in2);
    // Seek by the first P4 fields, unpacked in P3.. (BtreePayload.aMem).
    var r: vi.UnpackedRecord = undefined;
    var kc: serial.IndexKeyCtx = undefined;
    var seek: ?btree.IndexKey = null;
    if (op.p4type == .int32 and op.p4.int32 > 0) {
        r = .{
            .key_info = c.key_info.?,
            .mem = e.regs.ptr + @as(usize, @intCast(op.p3)),
            .n_field = @intCast(op.p4.int32),
            .default_rc = 0,
        };
        kc = .{ .r = &r, .cmp = serial.findCompare(&r) };
        seek = kc.indexKey();
    }
    const res = c.uc.cursor.insert(.{ .key = in2.bytes(), .seek = seek }, .{
        .append = op.p5 & vi.OPFLAG.APPEND != 0,
        .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
        .seek_result = insertSeekResult(op, c),
        .preformat = op.p5 & vi.OPFLAG.PREFORMAT != 0,
    });
    c.cache_status = vi.cache_stale;
    try res;
    return .next;
}

pub fn opIdxDelete(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    const cur = c.uc.cursor;
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regs.ptr + @as(usize, @intCast(op.p2)),
        .n_field = op.p5,
        .default_rc = 0,
    };
    const order = try serial.indexMoveto(cur, &r);
    if (order != .eq) {
        if (!e.db.flags.WriteSchema or e.db.flags.Defensive) {
            aux.vdbeError(e.v, "index corruption", .{});
            return e.abort(RC.CORRUPT_INDEX);
        }
        c.cache_status = vi.cache_stale;
        c.seek_result = 0;
        return .next;
    }
    if (op.p3 != 0) {
        // Skip the delete if the entry is the record in P3.
        const m = e.reg(op.p3);
        const n_key = cur.payloadSize();
        if (n_key == @as(u32, @intCast(m.n)) and m.flags.Blob) {
            var t: Mem = .{ .db = e.db, .flags = .{} };
            try mem.fromBtreeZeroOffset(cur, n_key, &t);
            const same = std.mem.eql(u8, m.bytes(), t.bytes());
            mem.releaseMalloc(&t);
            if (same) {
                mem.setNull(m);
                return .next;
            }
        }
    }
    try cur.delete(.{});
    c.cache_status = vi.cache_stale;
    c.seek_result = 0;
    return .next;
}

// ================================================================ sorters

pub fn opSorterCompare(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    const res = try sorter.compare(c, e.reg(op.p3), op.p4.int32);
    return if (res != 0) .jump_p2 else .next;
}

pub fn opSorterData(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    try sorter.rowkey(c, e.reg(op.p2));
    e.csr(op.p3).cache_status = vi.cache_stale;
    return .next;
}

pub fn opSorterInsert(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    const in2 = e.reg(op.p2);
    if (in2.flags.Zero) try mem.expandBlob(in2);
    try sorter.write(c, in2);
    return .next;
}

pub fn opResetSorter(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    if (c.e_cur_type == .sorter) {
        sorter.reset(e.db, c);
    } else {
        _ = try c.uc.cursor.bt.clearTable(c.pgno_root);
    }
    return .next;
}
