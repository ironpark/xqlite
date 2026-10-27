//! Opcodes of cursors (vdbe.c): opening and closing them, seeking,
//! stepping (OP_Rewind, OP_Next and the like), and reading keys and
//! rowids.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const serial = @import("../serial.zig");
const sorter = @import("../sorter.zig");
const int = @import("../../sql/sqlite_int.zig");
const util = @import("../../sql/util.zig");
const btree = @import("../../btree/btree.zig");
const vtab_mod = @import("../../sql/vtab.zig");
const malloc = @import("../../sql/malloc.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const VdbeCursor = vi.VdbeCursor;
const RC = int.RC;

/// BTREE_UNORDERED: an ephemeral table whose order does not matter.
const BTREE_UNORDERED: u16 = 8;

/// Port of allocateCursor(): a new cursor in slot `i_cur`, replacing any
/// cursor there. The b-tree cursor (`CursorBox.bc`) is not opened.
pub fn allocateCursor(e: *Exec, i_cur: i32, n_field: i32, cur_type: vi.CurType) ?*VdbeCursor {
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

// ================================================================ opening

pub fn opReopenIdx(e: *Exec, op: *Op) Flow {
    if (e.v.csr[@intCast(op.p1)]) |c| {
        if (c.pgno_root == @as(u32, @intCast(op.p2))) {
            // Already open on this index.
            c.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
            return .next;
        }
    }
    return opOpen(e, op);
}

/// OP_OpenRead and OP_OpenWrite.
pub fn opOpen(e: *Exec, op: *Op) Flow {
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
    switch (op.p4type) {
        .keyinfo => {
            const ki = op.p4.keyinfo;
            key_info = ki;
            n_field = ki.n_all_field;
        },
        .int32 => n_field = op.p4.int32,
        else => {},
    }
    const c = allocateCursor(e, op.p1, n_field, .btree) orelse return .no_mem;
    c.i_db = @intCast(i_db);
    c.null_row = true;
    c.is_ordered = true;
    c.pgno_root = p2;
    c.key_info = key_info;
    c.is_table = op.p4type != .keyinfo;
    c.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
    openBtreeCursor(c, bt, p2, write, key_info) catch |err| return e.fail(err);
    if (op.p5 & vi.OPFLAG.BULKCSR != 0) c.uc.cursor.setBulkLoad(true);
    return .next;
}

pub fn opOpenDup(e: *Exec, op: *Op) Flow {
    const orig = e.csr(op.p2);
    std.debug.assert(orig.is_ephemeral);
    const c = allocateCursor(e, op.p1, orig.n_field, .btree) orelse return .no_mem;
    c.null_row = true;
    c.is_ephemeral = true;
    c.key_info = orig.key_info;
    c.is_table = orig.is_table;
    c.pgno_root = orig.pgno_root;
    c.is_ordered = orig.is_ordered;
    c.btx = orig.btx;
    c.no_reuse = true;
    orig.no_reuse = true;
    openBtreeCursor(c, orig.btx.?, c.pgno_root, true, c.key_info) catch |err| return e.fail(err);
    return .next;
}

/// OP_OpenEphemeral and OP_OpenAutoindex.
pub fn opOpenEphemeral(e: *Exec, op: *Op) Flow {
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
    const bt = btree.Btree.open(malloc.allocator, db.vfs.?, null, .{
        .single = true,
        .journal_mode = .off,
        .synchronous = .off,
        .cell_size_check = db.flags & int.DbFlag.CellSizeCk != 0,
        // No n_vdbe_read (C has db->nVdbeRead here too): the only
        // transaction end is the rollback of close(), where keeping a
        // read transaction would only skip unlockIfUnused() before the
        // pager closes.
    }) catch |err| return e.fail(err);
    c.btx = bt;
    openEphemeralTable(c, bt, op) catch |err| {
        // Without a cursor the b-tree would never close itself.
        if (c.uc != .cursor) {
            bt.close(.{});
            c.btx = null;
        }
        return e.fail(err);
    };
    c.is_ordered = op.p5 != BTREE_UNORDERED;
    c.null_row = true;
    return .next;
}

fn openEphemeralTable(c: *VdbeCursor, bt: *btree.Btree, op: *Op) btree.Error!void {
    try bt.beginTrans(.write, 0);
    if (op.p4type == .keyinfo) {
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

pub fn opSorterOpen(e: *Exec, op: *Op) Flow {
    const c = allocateCursor(e, op.p1, op.p2, .sorter) orelse return .no_mem;
    c.key_info = op.p4.keyinfo;
    sorter.init(e.db, op.p3, c) catch |err| return e.fail(err);
    return .next;
}

pub fn opSequenceTest(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    c.seq_count += 1;
    return if (c.seq_count - 1 == 0) .jump_p2 else .next;
}

pub fn opOpenPseudo(e: *Exec, op: *Op) Flow {
    const c = allocateCursor(e, op.p1, op.p3, .pseudo) orelse return .no_mem;
    c.null_row = true;
    c.seek_result = op.p2;
    c.is_table = true;
    c.uc = .pseudo;
    return .next;
}

pub fn opClose(e: *Exec, op: *Op) Flow {
    const slot = &e.v.csr[@intCast(op.p1)];
    aux.freeCursor(e.v, slot.*);
    slot.* = null;
    return .next;
}

// ================================================================ seeking

/// OP_SeekLT, OP_SeekLE, OP_SeekGE and OP_SeekGT.
pub fn opSeek(e: *Exec, op: *Op) Flow {
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
    if (eq_only) {
        // Skip the OP_IdxLT or OP_IdxGT that follows.
        e.pc += 1;
        return .goto_pc;
    }
    return .next;
}

pub fn opSeekScan(e: *Exec, op: *Op) Flow {
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
            return .goto_pc;
        }
        if (res >= 0) return .jump_p2;
        if (n_step <= 0) return .next;
        n_step -= 1;
        c.cache_status = vi.cache_stale;
        const more = cur.next() catch |err| return e.fail(err);
        if (!more) {
            e.pc = next_op.p2 - 1;
            return .goto_pc;
        }
    }
}

pub fn opSeekHit(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    if (c.seek_hit < op.p2) {
        c.seek_hit = @intCast(op.p2);
    } else if (c.seek_hit > op.p3) {
        c.seek_hit = @intCast(op.p3);
    }
    return .next;
}

pub fn opIfNoHope(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    if (c.seek_hit >= op.p4.int32) return .next;
    return opFound(e, op);
}

/// OP_Found, OP_NotFound, OP_NoConflict, and OP_IfNoHope after its test.
pub fn opFound(e: *Exec, op: *Op) Flow {
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

pub fn opSeekRowid(e: *Exec, op: *Op) Flow {
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
            key = @import("../../sql/numeric.zig").realToI64(x.u.r);
            if (@as(f64, @floatFromInt(key)) != x.u.r) return .jump_p2;
        }
        return notExists(e, op, key);
    }
    return notExists(e, op, in3.u.i);
}

pub fn opNotExists(e: *Exec, op: *Op) Flow {
    return notExists(e, op, e.reg(op.p3).u.i);
}

/// OP_NotExists, and OP_SeekRowid once the key is an integer.
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

pub fn opSequence(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    e.out2Prerelease(op).u = .{ .i = c.seq_count };
    c.seq_count += 1;
    return .next;
}

// ================================================================ reading

pub fn opRowid(e: *Exec, op: *Op) Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    var rowid: i64 = undefined;
    if (c.null_row) {
        out.flags = MEM.Null;
        return .next;
    } else if (c.deferred_moveto) {
        rowid = c.moveto_target;
    } else if (c.e_cur_type == .vtab) {
        const vc = c.uc.vtab;
        const vtab = vc.vtab;
        e.rc = vtab.module.x_rowid.?(vc, &rowid);
        vtab_mod.importErrmsg(e.v, vtab);
        if (e.rc != RC.OK) return .abort;
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

pub fn opNullRow(e: *Exec, op: *Op) Flow {
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

// =============================================================== stepping

/// OP_Last and OP_SeekEnd.
pub fn opLast(e: *Exec, op: *Op) Flow {
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

pub fn opIfSizeBetween(e: *Exec, op: *Op) Flow {
    const cur = e.csr(op.p1).uc.cursor;
    const has_rows = cur.first() catch |err| return e.fail(err);
    var sz: i64 = -1;
    if (has_rows) {
        sz = util.logEst(@intCast(cur.rowCountEst()));
    }
    return if (sz >= op.p3 and sz <= op.p4.int32) .jump_p2 else .next;
}

/// OP_Sort and OP_SorterSort.
pub fn opSort(e: *Exec, op: *Op) Flow {
    e.v.counters[vi.STMTSTATUS.SORT] += 1;
    return opRewind(e, op);
}

pub fn opRewind(e: *Exec, op: *Op) Flow {
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

pub fn opIfEmpty(e: *Exec, op: *Op) Flow {
    const cur = e.csr(op.p1).uc.cursor;
    const empty = cur.isEmpty() catch |err| return e.fail(err);
    return if (empty) .jump_p2 else .next;
}

pub fn opSorterNext(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    const more = sorter.next(e.db, c) catch |err| return e.fail(err);
    return nextTail(e, op, c, more);
}

pub fn opPrev(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    const more = c.uc.cursor.previous() catch |err| return e.fail(err);
    return nextTail(e, op, c, more);
}

pub fn opNext(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    const more = c.uc.cursor.next() catch |err| return e.fail(err);
    return nextTail(e, op, c, more);
}

/// The next_tail of OP_Next, OP_Prev and OP_SorterNext.
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

// ========================================================== index cursors

/// OP_IdxRowid and OP_DeferredSeek.
pub fn opIdxRowid(e: *Exec, op: *Op) Flow {
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
            tab_cur.alt_map = if (op.p4type == .intarray) op.p4.intarray else null;
            tab_cur.alt_cursor = c;
        } else {
            e.out2Prerelease(op).u = .{ .i = rowid };
        }
    } else {
        mem.setNull(e.reg(op.p2));
    }
    return .next;
}

pub fn opFinishSeek(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    if (c.deferred_moveto) serial.finishMoveto(c) catch |err| return e.fail(err);
    return .next;
}

/// OP_IdxLE, OP_IdxGT, OP_IdxLT and OP_IdxGE.
pub fn opIdxCompare(e: *Exec, op: *Op) Flow {
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

/// OP_IFindKey: after an OP_Found on the same cursor and key missed,
/// look near the cursor for an entry of index P4 whose REAL fields
/// from expressions differ by a few ULPs (sqlite3VdbeFindIndexKey());
/// jump to P2 if there is none.
pub fn opIFindKey(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    std.debug.assert(c.e_cur_type == .btree and !c.is_table);
    const idx = op.p4.index;
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regs.ptr + @as(usize, @intCast(op.p3)),
        .n_field = idx.n_column,
    };
    const res = serial.findIndexKey(c.uc.cursor, idx, &r, true) catch return .jump_p2;
    if (res != 0) return .jump_p2;
    c.null_row = false;
    return .next;
}
