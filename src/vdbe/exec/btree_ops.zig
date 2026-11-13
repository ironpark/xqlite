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
const btree = @import("xqlite_storage").btree;

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const OpOf = vi.OpOf;
const Mem = vi.Mem;
const MEM = vi.MEM;
const RC = int.RC;

/// The opcodes this module runs, for the run loop (see exec.zig).
pub const handlers = .{
    .{ .ops = .{.Count}, .f = opCount },
    .{ .ops = .{.NewRowid}, .f = opNewRowid, .call = .always_inline },
    .{ .ops = .{.Insert}, .f = opInsert, .call = .always_inline },
    .{ .ops = .{.RowCell}, .f = opRowCell },
    .{ .ops = .{.Delete}, .f = opDelete },
    .{ .ops = .{.ResetCount}, .f = opResetCount },
    .{ .ops = .{.RowData}, .f = opRowData, .call = .always_inline },
    .{ .ops = .{.IdxInsert}, .f = opIdxInsert },
    .{ .ops = .{.IdxDelete}, .f = opIdxDelete },
    .{ .ops = .{.SorterCompare}, .f = opSorterCompare },
    .{ .ops = .{.SorterData}, .f = opSorterData },
    .{ .ops = .{.SorterInsert}, .f = opSorterInsert },
    .{ .ops = .{.ResetSorter}, .f = opResetSorter },
};

/// The largest rowid (MAX_ROWID).
const max_rowid: i64 = std.math.maxInt(i64);

/// The b-tree cursor's seek result for Cursor.insert, if
/// OPFLAG_USESEEKRESULT says to use it. C passes seekResult, where 0 is
/// both "no seek" and "on the entry": the b-tree then seeks itself, so
/// .eq is passed as null.
fn insertSeekResult(p5: u16, b: *const vi.OnBtree) ?std.math.Order {
    if (p5 & vi.OPFLAG.USESEEKRESULT == 0) return null;
    const order = b.seek_result orelse return null;
    return if (order == .eq) null else order;
}

pub fn opCount(e: *Exec, op: *OpOf(.{ .cursor, .reg, .int })) Error!Flow {
    const cur = e.csr(op.p1).kind.btree.cursor;
    const n = try if (op.p3 != 0) cur.rowCountEst() else cur.count();
    e.out2Prerelease(op).u = .{ .i = n };
    return .next_check;
}

pub fn opNewRowid(e: *Exec, op: *OpOf(.{ .cursor, .reg, .reg })) Error!Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const cur = b.cursor;
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
    if (op.p3 != .none) {
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
            @import("../../sql/func/func.zig").randomness(e.db, &buf);
            rowid = @bitCast(std.mem.readInt(u64, &buf, .little) & @as(u64, @intCast(max_rowid >> 1)));
            rowid += 1;
            const order = try cur.tableMoveto(rowid, false);
            found = order == .eq;
        }
        if (found) return error.DiskFull;
    }
    b.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    out.u = .{ .i = rowid };
    return .next;
}

pub fn opInsert(e: *Exec, op: *OpOf(.{ .cursor, .reg, .reg })) Error!Flow {
    const v = e.v;
    const data = e.reg(op.p2);
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
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
    const seek_result = insertSeekResult(op.p5, b);
    // Whether the insert fails or not (the b-tree does not read them).
    b.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    try b.cursor.insert(x, .{
        .append = op.p5 & vi.OPFLAG.APPEND != 0,
        .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
        .seek_result = seek_result,
        .preformat = op.p5 & vi.OPFLAG.PREFORMAT != 0,
    });
    if (e.db.update_hook) |f| if (op.p4type == .table) {
        const op_code: i32 = if (op.p5 & vi.OPFLAG.ISUPDATE != 0) update_op else insert_op;
        f(e.db.update_arg, op_code, e.db.dbs.items[@intCast(c.i_db)].name, op.p4As(.table).name, rowid);
    };
    return .next;
}

/// SQLITE_INSERT, SQLITE_UPDATE and SQLITE_DELETE, the operations the
/// update hook reports.
const insert_op = 18;
const update_op = 23;
const delete_op = 9;

/// OP_RowCell: build the cell for the entry of cursor P2 in cursor P1,
/// with the rowid in register P3 for tables, for the OP_Insert or
/// OP_IdxInsert with OPFLAG_PREFORMAT that follows.
pub fn opRowCell(e: *Exec, op: *OpOf(.{ .cursor, .cursor, .reg })) Error!Flow {
    if (std.debug.runtime_safety) {
        const next = e.ops[e.pc + 1];
        std.debug.assert(next.opcode == .Insert or next.opcode == .IdxInsert);
        std.debug.assert(next.p5 & vi.OPFLAG.PREFORMAT != 0);
    }
    const dest = e.csr(op.p1).kind.btree.cursor;
    const src = e.csr(op.p2).kind.btree.cursor;
    const key: i64 = if (op.p3 != .none) e.reg(op.p3).u.i else 0;
    try dest.transferRow(src, key);
    return .next;
}

pub fn opDelete(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    const v = e.v;
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    // The rowid, for the update hook (C's movetoTarget).
    const hook_tab: ?*const int.Table = if (e.db.update_hook != null and op.p4type == .table) op.p4As(.table) else null;
    const rowid: i64 = if (hook_tab != null and b.is_table) b.cursor.integerKey() else 0;
    // Whether the delete fails or not (the b-tree does not read them).
    c.cache_status = vi.cache_stale;
    // C: seekResult = 0.
    b.seek_result = null;
    try b.cursor.delete(.{ .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0 });
    if (op.p2 & vi.OPFLAG.NCHANGE != 0) {
        v.n_change += 1;
        if (hook_tab) |t| if (t.hasRowid()) {
            e.db.update_hook.?(e.db.update_arg, delete_op, e.db.dbs.items[@intCast(c.i_db)].name, t.name, rowid);
        };
    }
    return .next;
}

pub fn opResetCount(e: *Exec, op: *OpOf(.{ .int, .int, .int })) Flow {
    _ = op;
    aux.setChanges(e.db, e.v.n_change);
    e.v.n_change = 0;
    return .next;
}

pub fn opRowData(e: *Exec, op: *OpOf(.{ .cursor, .reg, .int })) Error!Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    const cur = c.kind.btree.cursor;
    const n = cur.payloadSize();
    if (n > e.db.limit(.length)) return error.TooBig;
    try mem.fromBtreeZeroOffset(cur, n, out);
    if (op.p3 == 0 and out.flags.Ephem) try mem.makeWriteable(out);
    return .next;
}

pub fn opIdxInsert(e: *Exec, op: *OpOf(.{ .cursor, .reg, .reg })) Error!Flow {
    const v = e.v;
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const in2 = e.reg(op.p2);
    if (op.p5 & vi.OPFLAG.NCHANGE != 0) v.n_change += 1;
    if (in2.flags.Zero) try mem.expandBlob(in2);
    // Seek by the first P4 fields, unpacked in P3.. (BtreePayload.aMem).
    var r: vi.UnpackedRecord = undefined;
    var kc: serial.IndexKeyCtx = undefined;
    var seek: ?btree.IndexKey = null;
    if (op.p4type == .int32 and op.p4As(.int32) > 0) {
        r = .{
            .key_info = c.key_info.?,
            .mem = e.regsFrom(op.p3),
            .n_field = @intCast(op.p4As(.int32)),
            .default_rc = 0,
        };
        kc = .{ .r = &r, .cmp = serial.findCompare(&r) };
        seek = kc.indexKey();
    }
    // Whether the insert fails or not (the b-tree does not read it).
    c.cache_status = vi.cache_stale;
    try b.cursor.insert(.{ .key = in2.bytes(), .seek = seek }, .{
        .append = op.p5 & vi.OPFLAG.APPEND != 0,
        .save_position = op.p5 & vi.OPFLAG.SAVEPOSITION != 0,
        .seek_result = insertSeekResult(op.p5, b),
        .preformat = op.p5 & vi.OPFLAG.PREFORMAT != 0,
    });
    return .next;
}

pub fn opIdxDelete(e: *Exec, op: *OpOf(.{ .cursor, .reg, .reg })) Error!Flow {
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const cur = b.cursor;
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regsFrom(op.p2),
        .n_field = op.p5,
        .default_rc = 0,
    };
    const order = try serial.indexMoveto(cur, &r);
    // Not found: an entry whose expression fields differ (the EIIB bug,
    // a REAL that came out a few ULPs off) may still be the one
    // (sqlite3VdbeFindIndexKey()).
    if (order != .eq and try serial.findIndexKey(cur, op.p4As(.index), &r, false) != 0) {
        if (!e.db.flags.WriteSchema or e.db.flags.Defensive) {
            // SQLITE_CORRUPT_INDEX_BKPT: logged, no message of its own.
            @import("../../sql/util.zig").reportError(RC.CORRUPT_INDEX, @src(), "index corruption");
            return e.abort(RC.CORRUPT_INDEX);
        }
        c.cache_status = vi.cache_stale;
        // C: seekResult = 0.
        b.seek_result = null;
        return .next;
    }
    if (op.p3 != .none) {
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
    // C: seekResult = 0.
    b.seek_result = null;
    return .next;
}

// ================================================================ sorters

pub fn opSorterCompare(e: *Exec, op: *OpOf(.{ .cursor, .addr, .reg })) Error!Flow {
    const c = e.csr(op.p1);
    const res = try sorter.compare(c, e.reg(op.p3), op.p4As(.int32));
    return if (res != 0) .jump_p2 else .next;
}

pub fn opSorterData(e: *Exec, op: *OpOf(.{ .cursor, .reg, .cursor })) Error!Flow {
    const c = e.csr(op.p1);
    try sorter.rowkey(c, e.reg(op.p2));
    e.csr(op.p3).cache_status = vi.cache_stale;
    return .next;
}

pub fn opSorterInsert(e: *Exec, op: *OpOf(.{ .cursor, .reg, .reg })) Error!Flow {
    const c = e.csr(op.p1);
    const in2 = e.reg(op.p2);
    if (in2.flags.Zero) try mem.expandBlob(in2);
    try sorter.write(c, in2);
    return .next;
}

pub fn opResetSorter(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    const c = e.csr(op.p1);
    switch (c.kind) {
        .sorter => sorter.reset(e.db, c),
        else => {
            const b = &c.kind.btree;
            _ = try b.cursor.bt.clearTable(b.pgno_root);
        },
    }
    return .next;
}
