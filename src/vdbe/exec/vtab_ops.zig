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
const Error = core.Error;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const RC = int.RC;
const OE = int.OE;

pub fn opVBegin(e: *Exec, op: *Op) Error!Flow {
    const vt: ?*int.VTable = if (op.p4type == .vtab) op.p4.vtab else null;
    const rc = vtab_mod.begin(e.db, vt);
    if (vt) |t| if (t.vtab) |p| vtab_mod.importErrmsg(e.v, p);
    try e.check(rc);
    return .next;
}

pub fn opVCreate(e: *Exec, op: *Op) Error!Flow {
    const db = e.db;
    // P2 is a static string, so the copy cannot fail.
    var s_mem: Mem = .{ .db = db, .flags = .{ .Null = true } };
    defer mem.release(&s_mem);
    try mem.copy(&s_mem, e.reg(op.p2));
    const z = try mem.valueText(&s_mem, vi.ENC.UTF8);
    if (z) |tab_name| {
        try e.check(vtab_mod.callCreate(db, @intCast(op.p1), std.mem.span(tab_name), &e.v.err_msg));
    }
    return .next;
}

pub fn opVDestroy(e: *Exec, op: *Op) Error!Flow {
    const db = e.db;
    db.n_vdestroy += 1;
    const rc = vtab_mod.callDestroy(db, @intCast(op.p1), std.mem.span(op.p4.z));
    db.n_vdestroy -= 1;
    try e.check(rc);
    return .next;
}

pub fn opVOpen(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    std.debug.assert(v.is_reader);
    if (v.csr[@intCast(op.p1)]) |cur| {
        // Already open.
        if (cur.e_cur_type == .vtab and cur.uc.vtab.vtab == op.p4.vtab.vtab.?) return .next;
    }
    const vtab = op.p4.vtab.vtab orelse return error.Locked;
    const module = vtab.module;
    var vcur: ?*vtab_mod.VtabCursor = null;
    const rc = module.x_open.?(vtab, &vcur);
    vtab_mod.importErrmsg(v, vtab);
    try e.check(rc);
    vcur.?.vtab = vtab;
    const cur = cursor.allocateCursor(e, op.p1, 0, .vtab) catch |err| {
        _ = module.x_close.?(vcur.?);
        return err;
    };
    cur.uc = .{ .vtab = vcur.? };
    vtab.n_ref += 1;
    return .next;
}

pub fn opVCheck(e: *Exec, op: *Op) Error!Flow {
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
    const rc = module.x_integrity.?(vtab, db.dbs.items[@intCast(op.p1)].name, t.name, op.p3, &err);
    vtab_mod.unlock(vt);
    if (rc != RC.OK) {
        if (err) |m| db.gpa.free(m);
        return e.abort(rc);
    }
    if (err) |m| {
        // The register takes the message over (sqlite3_free as the
        // destructor). setTextZ() fails, with TooBig, only before.
        mem.setTextZ(out, m, .dynamic) catch {
            db.gpa.free(m);
            return error.OutOfMemory;
        };
    }
    return .next;
}

pub fn opVInitIn(e: *Exec, op: *Op) Error!Flow {
    const c = e.csr(op.p1);
    const rhs = try malloc.allocator.create(vtab_mod.ValueList);
    rhs.* = .{ .csr = c.uc.cursor, .out = e.reg(op.p3) };
    const out = e.out2Prerelease(op);
    out.flags = .{ .Null = true };
    mem.setPointer(out, rhs, vtab_mod.value_list_type, int.destructor(vtab_mod.valueListFree));
    return .next;
}

pub fn opVFilter(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const query = e.reg(op.p3);
    const argc = e.reg(op.p3 + 1);
    const cur = e.csr(op.p1);
    std.debug.assert(cur.e_cur_type == .vtab);
    const vcur = cur.uc.vtab;
    const vtab = vcur.vtab;
    const module = vtab.module;
    std.debug.assert(query.flags.Int and argc.flags == MEM{ .Int = true });
    const n_arg: usize = @intCast(argc.u.i);
    const i_query: i32 = @truncate(query.u.i);
    const args = v.ap_arg[0..n_arg];
    for (args, 0..) |*a, i| a.* = e.reg(op.p3 + 2 + @as(i32, @intCast(i)));
    const idx_str: ?[:0]const u8 = switch (op.p4type) {
        .z => std.mem.span(op.p4.z),
        .dynamic => std.mem.span(op.p4.dynamic),
        else => null,
    };
    const rc = module.x_filter.?(vcur, i_query, idx_str, args);
    vtab_mod.importErrmsg(v, vtab);
    try e.check(rc);
    const res = module.x_eof.?(vcur);
    cur.null_row = false;
    return if (res) .jump_p2 else .next;
}

pub fn opVColumn(e: *Exec, op: *Op) Error!Flow {
    const cur = e.csr(op.p1);
    const dest = e.reg(op.p3);
    if (cur.null_row) {
        mem.setNull(dest);
        return .next;
    }
    std.debug.assert(cur.e_cur_type == .vtab);
    const vtab = cur.uc.vtab.vtab;
    const module = vtab.module;
    var null_func: int.FuncDef = .{ .n_arg = 0, .name = "", .func_flags = .{ .RESULT_SUBTYPE = true } };
    var ctx: vi.Context = .{ .out = dest, .func = &null_func, .enc = e.encoding, .argv = &.{} };
    std.debug.assert(op.p5 == vi.OPFLAG.NOCHNG or op.p5 == 0);
    if (op.p5 & vi.OPFLAG.NOCHNG != 0) {
        mem.setNull(dest);
        dest.flags = .{ .Null = true, .Zero = true };
        dest.u = .{ .n_zero = 0 };
    } else {
        dest.setTypeFlag(.{ .Null = true });
    }
    var rc = module.x_column.?(cur.uc.vtab, &ctx, op.p2);
    vtab_mod.importErrmsg(e.v, vtab);
    if (ctx.is_error > 0) {
        aux.vdbeErrorFromMem(e.v, dest);
        rc = ctx.is_error;
    }
    try mem.changeEncoding(dest, e.encoding);
    try e.check(rc);
    return .next;
}

pub fn opVNext(e: *Exec, op: *Op) Error!Flow {
    const cur = e.csr(op.p1);
    std.debug.assert(cur.e_cur_type == .vtab);
    if (cur.null_row) return .next;
    const vtab = cur.uc.vtab.vtab;
    const module = vtab.module;
    // xNext reports errors on the next xColumn or other call.
    const rc = module.x_next.?(cur.uc.vtab);
    vtab_mod.importErrmsg(e.v, vtab);
    try e.check(rc);
    const res = module.x_eof.?(cur.uc.vtab);
    return if (!res) .jump_p2_check_interrupt else .check_interrupt;
}

pub fn opVRename(e: *Exec, op: *Op) Error!Flow {
    const db = e.db;
    const is_legacy = db.flags.LegacyAlter;
    db.flags.LegacyAlter = true;
    const vtab = op.p4.vtab.vtab.?;
    const name = e.reg(op.p1);
    std.debug.assert(name.flags.Str);
    try mem.changeEncoding(name, vi.ENC.UTF8);
    const z = try mem.valueText(name, vi.ENC.UTF8);
    const rc = vtab.module.x_rename.?(vtab, std.mem.span(z.?));
    if (!is_legacy) db.flags.LegacyAlter = false;
    vtab_mod.importErrmsg(e.v, vtab);
    e.v.expired = 0;
    try e.check(rc);
    return .next;
}

pub fn opVUpdate(e: *Exec, op: *Op) Error!Flow {
    const v = e.v;
    const db = e.db;
    // P5 is the OE_ code of the statement.
    const on_conflict = OE.fromInt(op.p5);
    std.debug.assert(op.p2 == 1 or on_conflict == .Fail or on_conflict == .Rollback or
        on_conflict == .Abort or on_conflict == .Ignore or on_conflict == .Replace);
    std.debug.assert(!v.read_only);
    if (db.malloc_failed) return error.OutOfMemory;
    const vt = op.p4.vtab;
    const vtab = vt.vtab orelse return error.Locked;
    const module = vtab.module;
    const n_arg: usize = @intCast(op.p2);
    if (module.x_update) |x_update| {
        const vtab_on_conflict = db.vtab_on_conflict;
        const args = v.ap_arg[0..n_arg];
        for (args, 0..) |*a, i| a.* = e.reg(op.p3 + @as(i32, @intCast(i)));
        db.vtab_on_conflict = on_conflict;
        var rowid: i64 = 0;
        var rc = x_update(vtab, args, &rowid);
        db.vtab_on_conflict = vtab_on_conflict;
        vtab_mod.importErrmsg(v, vtab);
        if (rc == RC.OK and op.p1 != 0) {
            std.debug.assert(n_arg > 1 and args[0].flags.Null);
            db.last_rowid = rowid;
        }
        if (rc & 0xff == RC.CONSTRAINT and vt.b_constraint) {
            if (on_conflict == .Ignore) {
                rc = RC.OK;
            } else {
                v.error_action = if (on_conflict == .Replace) .Abort else on_conflict;
            }
        } else {
            v.n_change += 1;
        }
        try e.check(rc);
    }
    return .next;
}
