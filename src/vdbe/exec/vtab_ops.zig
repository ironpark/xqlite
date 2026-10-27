//! Opcodes of virtual tables (vdbe.c): OP_VBegin through OP_VUpdate,
//! which call the methods of the table's module.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const int = @import("../../sql/sqlite_int.zig");
const vtab_mod = @import("../../sql/vtab.zig");
const malloc = @import("../../sql/malloc.zig");
const cursor = @import("cursor.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const RC = int.RC;
const OE = int.OE;

pub fn opVBegin(e: *Exec, op: *Op) Flow {
    const vt: ?*int.VTable = if (op.p4type == .vtab) op.p4.vtab else null;
    e.rc = vtab_mod.begin(e.db, vt);
    if (vt) |t| if (t.vtab) |p| vtab_mod.importErrmsg(e.v, p);
    return if (e.rc != RC.OK) .abort else .next;
}

pub fn opVCreate(e: *Exec, op: *Op) Flow {
    const db = e.db;
    // P2 is a static string, so the copy cannot fail.
    var s_mem: Mem = .{ .db = db, .flags = MEM.Null };
    defer mem.release(&s_mem);
    mem.copy(&s_mem, e.reg(op.p2)) catch return .no_mem;
    const z = mem.valueText(&s_mem, vi.ENC.UTF8) catch return .no_mem;
    if (z) |tab_name| {
        e.rc = vtab_mod.callCreate(db, @intCast(op.p1), std.mem.span(tab_name), &e.v.err_msg);
    }
    return if (e.rc != RC.OK) .abort else .next;
}

pub fn opVDestroy(e: *Exec, op: *Op) Flow {
    const db = e.db;
    db.n_vdestroy += 1;
    e.rc = vtab_mod.callDestroy(db, @intCast(op.p1), std.mem.span(op.p4.z));
    db.n_vdestroy -= 1;
    return if (e.rc != RC.OK) .abort else .next;
}

pub fn opVOpen(e: *Exec, op: *Op) Flow {
    const v = e.v;
    std.debug.assert(v.is_reader);
    if (v.csr[@intCast(op.p1)]) |cur| {
        // Already open.
        if (cur.e_cur_type == .vtab and cur.uc.vtab.vtab == op.p4.vtab.vtab.?) return .next;
    }
    const vtab = op.p4.vtab.vtab orelse {
        e.rc = RC.LOCKED;
        return .abort;
    };
    const module = vtab.module;
    var vcur: ?*vtab_mod.VtabCursor = null;
    e.rc = module.x_open.?(vtab, &vcur);
    vtab_mod.importErrmsg(v, vtab);
    if (e.rc != RC.OK) return .abort;
    vcur.?.vtab = vtab;
    if (cursor.allocateCursor(e, op.p1, 0, .vtab)) |cur| {
        cur.uc = .{ .vtab = vcur.? };
        vtab.n_ref += 1;
    } else {
        _ = module.x_close.?(vcur.?);
        return .no_mem;
    }
    return .next;
}

pub fn opVCheck(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const out = e.reg(op.p2);
    mem.setNull(out);
    const t = op.p4.tableref;
    std.debug.assert(t.isVirtual());
    const vt = t.u.vtab.p orelse return .next;
    const vtab = vt.vtab.?;
    const module = vtab.module;
    std.debug.assert(module.i_version >= 4 and module.x_integrity != null);
    vtab_mod.lock(vt);
    var err: ?[:0]u8 = null;
    e.rc = module.x_integrity.?(vtab, db.dbs.items[@intCast(op.p1)].name, t.name, op.p3, &err);
    vtab_mod.unlock(vt);
    if (e.rc != RC.OK) {
        if (err) |m| db.gpa.free(m);
        return .abort;
    }
    if (err) |m| {
        // The register takes the message over (sqlite3_free as the
        // destructor). setTextZ() fails, with TooBig, only before.
        mem.setTextZ(out, m, .dynamic) catch {
            db.gpa.free(m);
            return .no_mem;
        };
    }
    return .next;
}

pub fn opVInitIn(e: *Exec, op: *Op) Flow {
    const c = e.csr(op.p1);
    const rhs = malloc.allocator.create(vtab_mod.ValueList) catch return .no_mem;
    rhs.* = .{ .csr = c.uc.cursor, .out = e.reg(op.p3) };
    const out = e.out2Prerelease(op);
    out.flags = MEM.Null;
    mem.setPointer(out, rhs, vtab_mod.value_list_type, vtab_mod.valueListFree);
    return .next;
}

pub fn opVFilter(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const query = e.reg(op.p3);
    const argc = e.reg(op.p3 + 1);
    const cur = e.csr(op.p1);
    std.debug.assert(cur.e_cur_type == .vtab);
    const vcur = cur.uc.vtab;
    const vtab = vcur.vtab;
    const module = vtab.module;
    std.debug.assert(query.flags & MEM.Int != 0 and argc.flags == MEM.Int);
    const n_arg: usize = @intCast(argc.u.i);
    const i_query: i32 = @truncate(query.u.i);
    const args = v.ap_arg[0..n_arg];
    for (args, 0..) |*a, i| a.* = e.reg(op.p3 + 2 + @as(i32, @intCast(i)));
    const idx_str: ?[:0]const u8 = switch (op.p4type) {
        .z => std.mem.span(op.p4.z),
        .dynamic => std.mem.span(op.p4.dynamic),
        else => null,
    };
    e.rc = module.x_filter.?(vcur, i_query, idx_str, args);
    vtab_mod.importErrmsg(v, vtab);
    if (e.rc != RC.OK) return .abort;
    const res = module.x_eof.?(vcur);
    cur.null_row = false;
    return if (res) .jump_p2 else .next;
}

pub fn opVColumn(e: *Exec, op: *Op) Flow {
    const cur = e.csr(op.p1);
    const dest = e.reg(op.p3);
    if (cur.null_row) {
        mem.setNull(dest);
        return .next;
    }
    std.debug.assert(cur.e_cur_type == .vtab);
    const vtab = cur.uc.vtab.vtab;
    const module = vtab.module;
    var null_func: int.FuncDef = .{ .n_arg = 0, .name = "", .func_flags = @import("../../sql/callback.zig").FUNC.RESULT_SUBTYPE };
    var ctx: vi.Context = .{ .out = dest, .func = &null_func, .enc = e.encoding, .argv = &.{} };
    std.debug.assert(op.p5 == vi.OPFLAG.NOCHNG or op.p5 == 0);
    if (op.p5 & vi.OPFLAG.NOCHNG != 0) {
        mem.setNull(dest);
        dest.flags = MEM.Null | MEM.Zero;
        dest.u = .{ .n_zero = 0 };
    } else {
        dest.setTypeFlag(MEM.Null);
    }
    e.rc = module.x_column.?(cur.uc.vtab, &ctx, op.p2);
    vtab_mod.importErrmsg(e.v, vtab);
    if (ctx.is_error > 0) {
        aux.vdbeErrorFromMem(e.v, dest);
        e.rc = ctx.is_error;
    }
    mem.changeEncoding(dest, e.encoding) catch return .no_mem;
    if (e.rc != RC.OK) return .abort;
    return .next;
}

pub fn opVNext(e: *Exec, op: *Op) Flow {
    const cur = e.csr(op.p1);
    std.debug.assert(cur.e_cur_type == .vtab);
    if (cur.null_row) return .next;
    const vtab = cur.uc.vtab.vtab;
    const module = vtab.module;
    // xNext reports errors on the next xColumn or other call.
    e.rc = module.x_next.?(cur.uc.vtab);
    vtab_mod.importErrmsg(e.v, vtab);
    if (e.rc != RC.OK) return .abort;
    const res = module.x_eof.?(cur.uc.vtab);
    return if (!res) .jump_p2_check_interrupt else .check_interrupt;
}

pub fn opVRename(e: *Exec, op: *Op) Flow {
    const db = e.db;
    const is_legacy = db.flags & int.DbFlag.LegacyAlter;
    db.flags |= int.DbFlag.LegacyAlter;
    const vtab = op.p4.vtab.vtab.?;
    const name = e.reg(op.p1);
    std.debug.assert(name.flags & MEM.Str != 0);
    mem.changeEncoding(name, vi.ENC.UTF8) catch return .no_mem;
    const z = mem.valueText(name, vi.ENC.UTF8) catch return .no_mem;
    e.rc = vtab.module.x_rename.?(vtab, std.mem.span(z.?));
    if (is_legacy == 0) db.flags &= ~int.DbFlag.LegacyAlter;
    vtab_mod.importErrmsg(e.v, vtab);
    e.v.expired = 0;
    if (e.rc != RC.OK) return .abort;
    return .next;
}

pub fn opVUpdate(e: *Exec, op: *Op) Flow {
    const v = e.v;
    const db = e.db;
    std.debug.assert(op.p2 == 1 or op.p5 == OE.Fail or op.p5 == OE.Rollback or
        op.p5 == OE.Abort or op.p5 == OE.Ignore or op.p5 == OE.Replace);
    std.debug.assert(!v.read_only);
    if (db.malloc_failed) return .no_mem;
    const vt = op.p4.vtab;
    const vtab = vt.vtab orelse {
        e.rc = RC.LOCKED;
        return .abort;
    };
    const module = vtab.module;
    const n_arg: usize = @intCast(op.p2);
    if (module.x_update) |x_update| {
        const vtab_on_conflict = db.vtab_on_conflict;
        const args = v.ap_arg[0..n_arg];
        for (args, 0..) |*a, i| a.* = e.reg(op.p3 + @as(i32, @intCast(i)));
        db.vtab_on_conflict = @intCast(op.p5);
        var rowid: i64 = 0;
        e.rc = x_update(vtab, args, &rowid);
        db.vtab_on_conflict = vtab_on_conflict;
        vtab_mod.importErrmsg(v, vtab);
        if (e.rc == RC.OK and op.p1 != 0) {
            std.debug.assert(n_arg > 1 and args[0].flags & MEM.Null != 0);
            db.last_rowid = rowid;
        }
        if (e.rc & 0xff == RC.CONSTRAINT and vt.b_constraint) {
            if (op.p5 == OE.Ignore) {
                e.rc = RC.OK;
            } else {
                v.error_action = if (op.p5 == OE.Replace) OE.Abort else @intCast(op.p5);
            }
        } else {
            v.n_change += 1;
        }
        if (e.rc != RC.OK) return .abort;
    }
    return .next;
}
