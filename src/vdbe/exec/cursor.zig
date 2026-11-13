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
const btree = @import("xqlite_storage").btree;
const vtab_mod = @import("../../sql/vtab.zig");
const malloc = @import("../../sql/malloc.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Error = core.Error;
const OpOf = vi.OpOf;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const VdbeCursor = vi.VdbeCursor;
const Cursor = @import("../operand.zig").Cursor;
const RC = int.RC;

/// The opcodes this module runs, for the run loop (see exec.zig).
pub const handlers = .{
    .{ .ops = .{.ReopenIdx}, .f = opReopenIdx },
    .{ .ops = .{ .OpenRead, .OpenWrite }, .f = opOpen },
    .{ .ops = .{.OpenDup}, .f = opOpenDup },
    .{ .ops = .{ .OpenAutoindex, .OpenEphemeral }, .f = opOpenEphemeral },
    .{ .ops = .{.SorterOpen}, .f = opSorterOpen },
    .{ .ops = .{.SequenceTest}, .f = opSequenceTest },
    .{ .ops = .{.OpenPseudo}, .f = opOpenPseudo },
    .{ .ops = .{.Close}, .f = opClose },
    .{ .ops = .{ .SeekLT, .SeekLE, .SeekGE, .SeekGT }, .f = opSeek, .call = .always_inline },
    .{ .ops = .{.SeekScan}, .f = opSeekScan },
    .{ .ops = .{.SeekHit}, .f = opSeekHit },
    .{ .ops = .{.IfNoHope}, .f = opIfNoHope },
    .{ .ops = .{ .NoConflict, .NotFound, .Found }, .f = opFound, .call = .always_inline },
    .{ .ops = .{.SeekRowid}, .f = opSeekRowid, .call = .always_inline },
    .{ .ops = .{.NotExists}, .f = opNotExists, .call = .always_inline },
    .{ .ops = .{.Sequence}, .f = opSequence },
    .{ .ops = .{.Rowid}, .f = opRowid },
    .{ .ops = .{ .CursorLock, .CursorUnlock }, .f = opCursorLock },
    .{ .ops = .{.NullRow}, .f = opNullRow, .call = .always_inline },
    .{ .ops = .{ .SeekEnd, .Last }, .f = opLast },
    .{ .ops = .{.IfSizeBetween}, .f = opIfSizeBetween },
    .{ .ops = .{ .SorterSort, .Sort }, .f = opSort },
    .{ .ops = .{.Rewind}, .f = opRewind, .call = .always_inline },
    .{ .ops = .{.IfEmpty}, .f = opIfEmpty },
    .{ .ops = .{.SorterNext}, .f = opSorterNext },
    .{ .ops = .{.Prev}, .f = opPrev, .call = .always_inline },
    .{ .ops = .{.Next}, .f = opNext, .call = .always_inline },
    .{ .ops = .{ .DeferredSeek, .IdxRowid }, .f = opIdxRowid },
    .{ .ops = .{.FinishSeek}, .f = opFinishSeek },
    .{ .ops = .{ .IdxLE, .IdxGT, .IdxLT, .IdxGE }, .f = opIdxCompare, .call = .always_inline },
    .{ .ops = .{.IFindKey}, .f = opIFindKey },
};

/// BTREE_UNORDERED: an ephemeral table whose order does not matter.
const BTREE_UNORDERED: u16 = 8;

/// Port of allocateCursor(): a new cursor of `kind` in slot `i_cur`,
/// replacing any cursor there. A b-tree cursor is made, and opened, by
/// allocateBtreeCursor().
pub fn allocateCursor(e: *Exec, i_cur: Cursor, n_field: i32, kind: VdbeCursor.Kind) error{OutOfMemory}!*VdbeCursor {
    std.debug.assert(kind != .btree);
    freeSlot(e, i_cur);
    const gpa = e.db.gpa;
    const box = try gpa.create(vi.CursorBox);
    errdefer gpa.destroy(box);
    box.* = newBox(try allocCache(gpa, n_field), kind);
    e.csrSlot(i_cur).* = &box.vc;
    return &box.vc;
}

/// allocateCursor() of a cursor on page `root` of `bt`, a table if
/// `key_info` is null, with its b-tree cursor opened (sqlite3BtreeCursor())
/// for writing if `write`. If it cannot be opened, the slot is left
/// empty (C leaves a cursor whose b-tree cursor is not open).
fn allocateBtreeCursor(e: *Exec, i_cur: Cursor, n_field: i32, bt: *btree.Btree, root: int.Pgno, write: bool, key_info: ?*vi.KeyInfo) Error!*VdbeCursor {
    freeSlot(e, i_cur);
    const gpa = e.db.gpa;
    const box = try gpa.create(vi.BtreeCursorBox);
    errdefer gpa.destroy(box);
    const cache = try allocCache(gpa, n_field);
    errdefer gpa.free(cache);
    try bt.cursor(&box.bc, root, .{
        .write = write,
        .key_info = if (key_info) |ki| serial.btreeKeyInfo(ki) else null,
    });
    box.box = newBox(cache, .{ .btree = .{
        .cursor = &box.bc,
        .pgno_root = root,
        .is_table = key_info == null,
    } });
    box.box.vc.key_info = key_info;
    e.csrSlot(i_cur).* = &box.box.vc;
    return &box.box.vc;
}

fn freeSlot(e: *Exec, i_cur: Cursor) void {
    const slot = e.csrSlot(i_cur);
    if (slot.*) |old| {
        aux.freeCursorNN(e.v, old);
        slot.* = null;
    }
}

/// The arrays of the column cache of a cursor of `n_field` fields
/// (CursorBox.cache), zeroed.
fn allocCache(gpa: std.mem.Allocator, n_field: i32) error{OutOfMemory}![]u32 {
    const n: usize = @intCast(n_field);
    const buf = try gpa.alloc(u32, 2 * n + 1);
    @memset(buf, 0);
    return buf;
}

fn newBox(cache: []u32, kind: VdbeCursor.Kind) vi.CursorBox {
    const n = cache.len / 2;
    return .{
        .vc = .{
            .kind = kind,
            .i_db = 0,
            .n_field = @intCast(n),
            .types = cache[0..n],
            .offsets = cache[n..],
        },
        .cache = cache,
    };
}

// ================================================================ opening

pub fn opReopenIdx(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    if (e.csrIfOpen(op.p1)) |c| switch (c.kind) {
        .btree => |*b| if (b.pgno_root == @as(u32, @intCast(op.p2))) {
            // Already open on this index: the position is forgotten
            // (sqlite3BtreeClearCursor()), so that OP_SeekScan seeks.
            b.cursor.clear();
            b.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
            return .next;
        },
        else => {},
    };
    return opOpen(e, op, .OpenRead);
}

/// OP_OpenRead and OP_OpenWrite.
pub fn opOpen(e: *Exec, op: *OpOf(.{ .cursor, .int, .int }), comptime opc: OP) Error!Flow {
    const v = e.v;
    const db = e.db;
    if (v.expired == 1) return e.abort(RC.ABORT_ROLLBACK);
    var p2: u32 = @intCast(op.p2);
    const i_db = op.p3;
    const pdb = &db.dbs.items[@intCast(i_db)];
    const bt = pdb.bt.?;
    var write = false;
    if (opc == .OpenWrite) {
        write = true;
        if (pdb.schema.file_format < v.min_write_file_format) v.min_write_file_format = pdb.schema.file_format;
        if (op.p5 & vi.OPFLAG.P2ISREG != 0) {
            // OPFLAG_P2ISREG: P2 is the register of the root page.
            const in2 = e.reg(.from(op.p2));
            mem.integerify(in2);
            p2 = @intCast(in2.u.i);
        }
    }
    var key_info: ?*vi.KeyInfo = null;
    var n_field: i32 = 0;
    switch (op.p4type) {
        .keyinfo => {
            const ki = op.p4As(.keyinfo);
            key_info = ki;
            n_field = ki.n_all_field;
        },
        .int32 => n_field = op.p4As(.int32),
        else => {},
    }
    const c = try allocateBtreeCursor(e, op.p1, n_field, bt, p2, write, key_info);
    c.i_db = @intCast(i_db);
    c.null_row = true;
    c.is_ordered = true;
    const b = &c.kind.btree;
    b.seek_eq = op.p5 & vi.OPFLAG.SEEKEQ != 0;
    if (op.p5 & vi.OPFLAG.BULKCSR != 0) b.cursor.setBulkLoad(true);
    return .next;
}

pub fn opOpenDup(e: *Exec, op: *OpOf(.{ .cursor, .cursor, .int })) Error!Flow {
    const orig = e.csr(op.p2);
    std.debug.assert(orig.is_ephemeral);
    const ob = &orig.kind.btree;
    const c = try allocateBtreeCursor(e, op.p1, orig.n_field, ob.btx.?, ob.pgno_root, true, orig.key_info);
    c.null_row = true;
    c.is_ephemeral = true;
    c.is_ordered = orig.is_ordered;
    c.kind.btree.btx = ob.btx;
    c.no_reuse = true;
    orig.no_reuse = true;
    return .next;
}

/// OP_OpenEphemeral and OP_OpenAutoindex.
pub fn opOpenEphemeral(e: *Exec, op: *OpOf(.{ .cursor, .int, .reg })) Error!Flow {
    const db = e.db;
    if (op.p3 != .none) {
        // Make reg[P3] usable as zero-length data for OP_Insert.
        const r = e.reg(op.p3);
        r.n = 0;
        r.z = @constCast("".ptr);
    }
    if (e.csrIfOpen(op.p1)) |cx| {
        if (!cx.no_reuse and op.p2 <= cx.n_field) {
            // Erase the content of the open ephemeral table.
            cx.seq_count = 0;
            cx.cache_status = vi.cache_stale;
            const b = &cx.kind.btree;
            _ = try b.btx.?.clearTable(b.pgno_root);
            cx.null_row = true;
            return .next;
        }
    }
    const bt = try btree.Btree.open(malloc.allocator, db.vfs.?, null, .{
        // SQLITE_OPEN_TRANSIENT_DB, in memory with temp_store=MEMORY.
        .memory = @import("../sorter.zig").tempInMemory(db),
        .temp_kind = .transient_db,
        .mmap_size = db.sz_mmap,
        .conn = @import("../../sql/main.zig").btreeConn(db),
        .single = true,
        .journal_mode = .off,
        .synchronous = .off,
        .cell_size_check = db.flags.CellSizeCk,
        // No n_vdbe_read (C has db->nVdbeRead here too): the only
        // transaction end is the rollback of close(), where keeping a
        // read transaction would only skip unlockIfUnused() before the
        // pager closes.
    });
    const c = openEphemeralTable(e, op, bt) catch |err| {
        // Without a cursor the b-tree would never close itself.
        bt.close(.{});
        return err;
    };
    c.kind.btree.btx = bt;
    c.is_ephemeral = true;
    c.is_ordered = op.p5 != BTREE_UNORDERED;
    c.null_row = true;
    return .next;
}

/// The cursor of OP_OpenEphemeral on its new b-tree `bt`.
fn openEphemeralTable(e: *Exec, op: *OpOf(.{ .cursor, .int, .reg }), bt: *btree.Btree) Error!*VdbeCursor {
    try bt.beginTrans(.write, 0);
    if (op.p4type == .keyinfo) {
        // A transient index gets its own b-tree; a table uses page 1.
        const root = try bt.createTable(.blobkey);
        return allocateBtreeCursor(e, op.p1, op.p2, bt, root, true, op.p4As(.keyinfo));
    }
    return allocateBtreeCursor(e, op.p1, op.p2, bt, 1, true, null);
}

pub fn opSorterOpen(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    const ki = op.p4As(.keyinfo);
    const s = try sorter.init(e.db, op.p3, ki);
    const c = allocateCursor(e, op.p1, op.p2, .{ .sorter = s }) catch |err| {
        sorter.close(e.db, s);
        return err;
    };
    c.key_info = ki;
    return .next;
}

pub fn opSequenceTest(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Flow {
    const c = e.csr(op.p1);
    c.seq_count += 1;
    return if (c.seq_count - 1 == 0) .jump_p2 else .next;
}

pub fn opOpenPseudo(e: *Exec, op: *OpOf(.{ .cursor, .reg, .int })) Error!Flow {
    const c = try allocateCursor(e, op.p1, op.p3, .{ .pseudo = op.p2 });
    c.null_row = true;
    return .next;
}

pub fn opClose(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Flow {
    const slot = e.csrSlot(op.p1);
    aux.freeCursor(e.v, slot.*);
    slot.* = null;
    return .next;
}

// ================================================================ seeking

/// OP_SeekLT, OP_SeekLE, OP_SeekGE and OP_SeekGT.
pub fn opSeek(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg }), comptime opc: OP) Error!Flow {
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const cur = b.cursor;
    // A REAL key may change the comparison (see below).
    var oc = opc;
    var eq_only = false;
    c.null_row = false;
    b.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    // C's res: not 0, no entry is found (seek_not_found).
    const not_found: bool = not_found: {
        // How the entry the cursor is left at compares with the key.
        const order: std.math.Order = if (b.is_table) order: {
            // The key must become an integer.
            const in3 = e.reg(op.p3);
            const flags3 = in3.flags;
            if (flags3.only(.{ .Int = true, .Real = true, .IntReal = true, .Str = true }) == MEM{ .Str = true }) {
                mem.applyNumericAffinity(in3, false);
            }
            const i_key = mem.intValue(in3);
            const new_type = in3.flags;
            in3.flags = flags3;
            if (!new_type.intersects(.{ .Int = true, .IntReal = true })) {
                if (!new_type.Real) {
                    if (new_type.Null or oc.seekIsGeOrGt()) return .jump_p2;
                    break :not_found !try cur.last();
                }
                const cmp = serial.intFloatCompare(i_key, in3.u.r);
                if (cmp > 0) {
                    // (x > 4.9) -> (x >= 5); (x <= 4.9) -> (x < 5)
                    oc = switch (oc) {
                        .SeekGT => .SeekGE,
                        .SeekLE => .SeekLT,
                        else => oc,
                    };
                } else if (cmp < 0) {
                    // (x < 5.1) -> (x <= 5); (x >= 5.1) -> (x > 5)
                    oc = switch (oc) {
                        .SeekLT => .SeekLE,
                        .SeekGE => .SeekGT,
                        else => oc,
                    };
                }
            }
            const o = try cur.tableMoveto(i_key, false);
            b.moveto_target = i_key;
            break :order o;
        } else order: {
            if (b.seek_eq) eq_only = true;
            var r: vi.UnpackedRecord = .{
                .key_info = c.key_info.?,
                .mem = e.regsFrom(op.p3),
                .n_field = @intCast(op.p4As(.int32)),
                .default_rc = if (oc == .SeekLE or oc == .SeekGT) -1 else 1,
            };
            const o = try serial.indexMoveto(cur, &r);
            if (eq_only and !r.eq_seen) break :not_found true;
            break :order o;
        };
        if (oc.seekIsGeOrGt()) {
            // On an entry before the key, or on it for SeekGT: step on.
            if (order == .lt or (order == .eq and oc == OP.SeekGT)) break :not_found !try cur.next();
            break :not_found false;
        }
        // On an entry after the key, or on it for SeekLT: step back.
        if (order == .gt or (order == .eq and oc == OP.SeekLT)) break :not_found !try cur.previous();
        // `order` may be .lt because the table is empty.
        break :not_found cur.eof();
    };
    if (not_found) return .jump_p2;
    if (eq_only) {
        // Skip the OP_IdxLT or OP_IdxGT that follows.
        return .goto(e.pc + 2);
    }
    return .next;
}

pub fn opSeekScan(e: *Exec, op: *OpOf(.{ .int, .int, .int })) Error!Flow {
    const next_op = e.opAt(.SeekGE, e.pc + 1);
    const c = e.csr(next_op.p1);
    const cur = c.kind.btree.cursor;
    if (cur.eof()) return .next;
    var n_step = op.p1;
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regsFrom(next_op.p3),
        .n_field = @intCast(next_op.p4As(.int32)),
        .default_rc = 0,
    };
    while (true) {
        const res = try serial.idxKeyCompare(e.db, c, &r);
        if (res > 0 and op.p5 == 0) {
            // seekscan_search_fail: past the target; skip the SeekGE.
            return .goto(@intCast(next_op.p2.int()));
        }
        if (res >= 0) return .jump_p2;
        if (n_step <= 0) return .next;
        n_step -= 1;
        c.cache_status = vi.cache_stale;
        const more = try cur.next();
        if (!more) return .goto(@intCast(next_op.p2.int()));
    }
}

pub fn opSeekHit(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Flow {
    const c = e.csr(op.p1);
    if (c.seek_hit < op.p2) {
        c.seek_hit = @intCast(op.p2);
    } else if (c.seek_hit > op.p3) {
        c.seek_hit = @intCast(op.p3);
    }
    return .next;
}

pub fn opIfNoHope(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg })) Error!Flow {
    const c = e.csr(op.p1);
    if (c.seek_hit >= op.p4As(.int32)) return .next;
    return opFound(e, op, .IfNoHope);
}

/// OP_Found, OP_NotFound, OP_NoConflict, and OP_IfNoHope after its test.
pub fn opFound(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg }), comptime opc: OP) Error!Flow {
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const cur = b.cursor;
    const regs = e.regsFrom(op.p3);
    const n_field: u16 = @intCast(op.p4As(.int32));
    const order = if (n_field > 0) order: {
        // The key is n_field unpacked registers.
        var r: vi.UnpackedRecord = .{ .key_info = c.key_info.?, .mem = regs, .n_field = n_field, .default_rc = 0 };
        break :order try serial.indexMoveto(cur, &r);
    } else order: {
        // The key is a record in one register.
        const key = &regs[0];
        if (key.flags.Zero) try mem.expandBlob(key);
        const ki = c.key_info.?;
        break :order try serial.btreeKeyInfo(ki).call(.{ cur, key.bytes() });
    };
    b.seek_result = order;
    // C: alreadyExists = (seekResult==0).
    const exists = order == .eq;
    c.null_row = !exists;
    b.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    if (opc == .Found) {
        if (exists) return .jump_p2;
    } else {
        if (!exists) return .jump_p2;
        if (opc == .NoConflict) {
            // A key with a NULL never conflicts.
            for (regs[0..n_field]) |m| if (m.flags.Null) return .jump_p2;
        }
        if (opc == .IfNoHope) c.seek_hit = @intCast(op.p4As(.int32));
    }
    return .next;
}

pub fn opSeekRowid(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg })) Error!Flow {
    const in3 = e.reg(op.p3);
    if (!in3.flags.intersects(.{ .Int = true, .IntReal = true })) {
        // Convert a copy: the register must keep its type.
        var x: Mem = in3.*;
        x.flags.clear(.{ .Dyn = true, .Agg = true });
        if (x.flags.Str) mem.applyNumericAffinity(&x, true);
        var key: i64 = undefined;
        if (x.flags.Int) {
            key = x.u.i;
        } else {
            if (!x.flags.Real or x.u.r < -9223372036854775808.0 or x.u.r > 9223372036854774784.0) return .jump_p2;
            key = @import("xqlite_base").numeric.realToI64(x.u.r);
            if (@as(f64, @floatFromInt(key)) != x.u.r) return .jump_p2;
        }
        return notExists(e, op, key);
    }
    return notExists(e, op, in3.u.i);
}

pub fn opNotExists(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg })) Error!Flow {
    return notExists(e, op, e.reg(op.p3).u.i);
}

/// OP_NotExists, and OP_SeekRowid once the key is an integer.
fn notExists(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg }), key: i64) Error!Flow {
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const order = try b.cursor.tableMoveto(key, false);
    b.moveto_target = key;
    c.null_row = false;
    c.cache_status = vi.cache_stale;
    b.deferred_moveto = false;
    b.seek_result = order;
    if (order != .eq) {
        if (op.p2 == .none) return error.Corrupt;
        return .jump_p2;
    }
    return .next;
}

pub fn opSequence(e: *Exec, op: *OpOf(.{ .cursor, .reg, .int })) Flow {
    const c = e.csr(op.p1);
    e.out2Prerelease(op).u = .{ .i = c.seq_count };
    c.seq_count += 1;
    return .next;
}

// ================================================================ reading

pub fn opRowid(e: *Exec, op: *OpOf(.{ .cursor, .reg, .int })) Error!Flow {
    const out = e.out2Prerelease(op);
    const c = e.csr(op.p1);
    if (c.null_row) {
        out.flags = .{ .Null = true };
        return .next;
    }
    const rowid = switch (c.kind) {
        .vtab => |vc| blk: {
            const vtab = vc.vtab;
            var rowid: i64 = 0;
            const rc = vtab.module.x_rowid.?(vc, &rowid);
            vtab_mod.importErrmsg(e.v, vtab);
            try e.check(rc);
            break :blk rowid;
        },
        // C asserts a b-tree cursor (a pseudo or sorter cursor is on its
        // NULL row, above).
        else => blk: {
            const b = &c.kind.btree;
            if (b.deferred_moveto) break :blk b.moveto_target;
            try serial.cursorRestore(c);
            if (c.null_row) {
                out.flags = .{ .Null = true };
                return .next;
            }
            break :blk b.cursor.integerKey();
        },
    };
    out.u = .{ .i = rowid };
    return .next;
}

/// OP_CursorLock and OP_CursorUnlock: pin the b-tree cursor P1 to its
/// row, so that a trigger which would move it fails with
/// SQLITE_CONSTRAINT_PINNED, or release it.
pub fn opCursorLock(e: *Exec, op: *OpOf(.{ .cursor, .int, .int }), comptime opc: OP) Flow {
    const bc = e.csr(op.p1).kind.btree.cursor;
    if (opc == .CursorLock) bc.pin() else bc.unpin();
    return .next;
}

pub fn opNullRow(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    const c = e.csrIfOpen(op.p1) orelse blk: {
        // A NULL row for a cursor that was never opened.
        const cx = try allocateCursor(e, op.p1, 1, .{ .pseudo = .none });
        cx.no_reuse = true;
        break :blk cx;
    };
    c.null_row = op.p2 == 0;
    c.cache_status = vi.cache_stale;
    switch (c.kind) {
        .btree => |b| b.cursor.clear(),
        else => {},
    }
    return .next;
}

// =============================================================== stepping

/// OP_Last and OP_SeekEnd.
pub fn opLast(e: *Exec, op: anytype, comptime opc: OP) Error!Flow {
    const c = e.csr(op.p1);
    const b = &c.kind.btree;
    const cur = b.cursor;
    if (opc == .SeekEnd) {
        // C: seekResult = -1, for the OP_Insert or OP_IdxInsert with
        // OPFLAG_USESEEKRESULT that follows: the key goes after the
        // last entry.
        b.seek_result = .lt;
        if (!cur.eof()) return .next;
    }
    b.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
    const has_rows = cur.last() catch |err| {
        c.null_row = true;
        return err;
    };
    c.null_row = !has_rows;
    // OP_SeekEnd has no P2.
    if (opc == .Last and op.p2 != .none and c.null_row) return .jump_p2;
    return .next;
}

pub fn opIfSizeBetween(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const cur = e.csr(op.p1).kind.btree.cursor;
    const has_rows = try cur.first();
    var sz: i64 = -1;
    if (has_rows) {
        sz = util.logEst(@intCast(cur.rowCountEst()));
    }
    return if (sz >= op.p3 and sz <= op.p4As(.int32)) .jump_p2 else .next;
}

/// OP_Sort and OP_SorterSort.
pub fn opSort(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    e.v.counters[vi.STMTSTATUS.SORT] += 1;
    return opRewind(e, op);
}

pub fn opRewind(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const c = e.csr(op.p1);
    const empty = switch (c.kind) {
        .sorter => try sorter.rewind(c),
        else => blk: {
            const b = &c.kind.btree;
            b.deferred_moveto = false;
            c.cache_status = vi.cache_stale;
            break :blk !try b.cursor.first();
        },
    };
    c.null_row = empty;
    if (op.p2 != .none and empty) return .jump_p2;
    return .next;
}

pub fn opIfEmpty(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const cur = e.csr(op.p1).kind.btree.cursor;
    const empty = try cur.isEmpty();
    return if (empty) .jump_p2 else .next;
}

pub fn opSorterNext(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const c = e.csr(op.p1);
    const more = try sorter.next(e.db, c);
    return nextTail(e, op.p5, c, more);
}

pub fn opPrev(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const c = e.csr(op.p1);
    const more = try c.kind.btree.cursor.previous();
    return nextTail(e, op.p5, c, more);
}

pub fn opNext(e: *Exec, op: *OpOf(.{ .cursor, .jump, .int })) Error!Flow {
    const c = e.csr(op.p1);
    const more = try c.kind.btree.cursor.next();
    return nextTail(e, op.p5, c, more);
}

/// The next_tail of OP_Next, OP_Prev and OP_SorterNext, whose P5 is the
/// counter of sqlite3_stmt_status() a step adds to.
fn nextTail(e: *Exec, p5: u16, c: *VdbeCursor, more: bool) Flow {
    c.cache_status = vi.cache_stale;
    if (more) {
        c.null_row = false;
        e.v.counters[p5] +%= 1;
        return .jump_p2_check;
    }
    c.null_row = true;
    return .next_check;
}

// ========================================================== index cursors

/// OP_IdxRowid and OP_DeferredSeek.
pub fn opIdxRowid(e: *Exec, op: anytype, comptime opc: OP) Error!Flow {
    const c = e.csr(op.p1);
    try serial.cursorRestore(c);
    if (!c.null_row) {
        const rowid = try serial.idxRowid(e.db, c.kind.btree.cursor);
        if (opc == .DeferredSeek) {
            const tab_cur = e.csr(op.p3);
            const tb = &tab_cur.kind.btree;
            tab_cur.null_row = false;
            tb.moveto_target = rowid;
            tb.deferred_moveto = true;
            tab_cur.cache_status = vi.cache_stale;
            tb.alt_map = if (op.p4type == .intarray) op.p4IntArray() else null;
            tb.alt_cursor = c;
        } else {
            e.out2Prerelease(op).u = .{ .i = rowid };
        }
    } else if (opc == .IdxRowid) {
        mem.setNull(e.reg(op.p2));
    }
    // An OP_DeferredSeek on a NULL row: nothing to do (C asserts there
    // is none).
    return .next;
}

pub fn opFinishSeek(e: *Exec, op: *OpOf(.{ .cursor, .int, .int })) Error!Flow {
    const c = e.csr(op.p1);
    if (c.kind.btree.deferred_moveto) try serial.finishMoveto(c);
    return .next;
}

/// OP_IdxLE, OP_IdxGT, OP_IdxLT and OP_IdxGE.
pub fn opIdxCompare(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg }), comptime opc: OP) Error!Flow {
    const c = e.csr(op.p1);
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regsFrom(op.p3),
        .n_field = @intCast(op.p4As(.int32)),
        .default_rc = if (opc == .IdxLE or opc == .IdxGT) -1 else 0,
    };
    var res = try serial.idxKeyCompare(e.db, c, &r);
    if (opc == .IdxLE or opc == .IdxLT) {
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
pub fn opIFindKey(e: *Exec, op: *OpOf(.{ .cursor, .jump, .reg })) Flow {
    const c = e.csr(op.p1);
    std.debug.assert(!c.kind.btree.is_table);
    const idx = op.p4As(.index);
    var r: vi.UnpackedRecord = .{
        .key_info = c.key_info.?,
        .mem = e.regsFrom(op.p3),
        .n_field = idx.n_column,
    };
    const res = serial.findIndexKey(c.kind.btree.cursor, idx, &r, true) catch return .jump_p2;
    if (res != 0) return .jump_p2;
    c.null_row = false;
    return .next;
}
