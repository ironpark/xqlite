//! Virtual tables from C: sqlite3_create_module*() registers a
//! sqlite3_module behind an engine Module whose methods call the C ones
//! (the engine's methods take Zig slices and its own objects). The C
//! module's sqlite3_vtab, sqlite3_vtab_cursor and sqlite3_index_info are
//! the structs of sqlite3.h; each engine object here holds the C one.

const std = @import("std");
const c = @import("common.zig");

const Handle = c.Handle;
const Mem = c.Mem;
const Context = c.Context;
const RC = c.RC;
const vtab = @import("../sql/vtab.zig");

// ============================================================ C structs

pub const CVtab = extern struct {
    pModule: ?*const CModule,
    nRef: c_int,
    zErrMsg: ?[*:0]u8,
};

pub const CCursor = extern struct {
    pVtab: ?*CVtab,
};

const CConstraint = extern struct { iColumn: c_int, op: u8, usable: u8, iTermOffset: c_int };
const COrderBy = extern struct { iColumn: c_int, desc: u8 };
const CUsage = extern struct { argvIndex: c_int, omit: u8 };

pub const CIndexInfo = extern struct {
    nConstraint: c_int,
    aConstraint: [*]CConstraint,
    nOrderBy: c_int,
    aOrderBy: [*]COrderBy,
    aConstraintUsage: [*]CUsage,
    idxNum: c_int,
    idxStr: ?[*:0]u8,
    needToFreeIdxStr: c_int,
    orderByConsumed: c_int,
    estimatedCost: f64,
    estimatedRows: i64,
    idxFlags: c_int,
    colUsed: u64,
};

const XConstruct = *const fn (?*Handle, ?*anyopaque, c_int, [*]const [*:0]const u8, *?*CVtab, *?[*:0]u8) callconv(.c) c_int;
const XVtab = *const fn (*CVtab) callconv(.c) c_int;
const XCursor = *const fn (*CCursor) callconv(.c) c_int;

pub const CModule = extern struct {
    iVersion: c_int,
    xCreate: ?XConstruct,
    xConnect: ?XConstruct,
    xBestIndex: ?*const fn (*CVtab, *CIndexInfo) callconv(.c) c_int,
    xDisconnect: ?XVtab,
    xDestroy: ?XVtab,
    xOpen: ?*const fn (*CVtab, *?*CCursor) callconv(.c) c_int,
    xClose: ?XCursor,
    xFilter: ?*const fn (*CCursor, c_int, ?[*:0]const u8, c_int, ?[*]*Mem) callconv(.c) c_int,
    xNext: ?XCursor,
    xEof: ?XCursor,
    xColumn: ?*const fn (*CCursor, *Context, c_int) callconv(.c) c_int,
    xRowid: ?*const fn (*CCursor, *i64) callconv(.c) c_int,
    xUpdate: ?*const fn (*CVtab, c_int, ?[*]*Mem, *i64) callconv(.c) c_int,
    xBegin: ?XVtab,
    xSync: ?XVtab,
    xCommit: ?XVtab,
    xRollback: ?XVtab,
    xFindFunction: ?*const anyopaque,
    xRename: ?*const fn (*CVtab, [*:0]const u8) callconv(.c) c_int,
    // iVersion 2
    xSavepoint: ?*const fn (*CVtab, c_int) callconv(.c) c_int,
    xRelease: ?*const fn (*CVtab, c_int) callconv(.c) c_int,
    xRollbackTo: ?*const fn (*CVtab, c_int) callconv(.c) c_int,
    // iVersion 3
    xShadowName: ?*const fn ([*:0]const u8) callconv(.c) c_int,
    // iVersion 4
    xIntegrity: ?*const fn (*CVtab, [*:0]const u8, [*:0]const u8, c_int, *?[*:0]u8) callconv(.c) c_int,
};

// ===================================================== the engine side

/// A C module registered on a connection: the engine Module and what it
/// calls.
const ModWrap = struct {
    module: vtab.Module,
    cmod: *const CModule,
    aux: ?*anyopaque,
    x_destroy: ?c.CDestructor,

    fn destroy(w: *ModWrap) void {
        if (w.x_destroy) |d| d(w.aux);
        c.gpa.destroy(w);
    }

    /// The C methods past version 1 exist only if iVersion says so.
    fn has(w: *const ModWrap, comptime version: c_int) bool {
        return w.cmod.iVersion >= version;
    }
};

/// The engine's virtual table object for a C one.
const Tab = struct {
    base: vtab.Vtab = .{},
    cvt: *CVtab,
    wrap: *ModWrap,
    db: *Handle,

    fn of(t: *vtab.Vtab) *Tab {
        return @fieldParentPtr("base", t);
    }

    /// Move the C error message (from sqlite3_malloc()) to the engine's
    /// vtab, which reports it.
    fn takeError(t: *Tab) void {
        const z = t.cvt.zErrMsg orelse return;
        t.cvt.zErrMsg = null;
        const copy = t.db.gpa.dupeSentinel(u8, std.mem.span(z), 0) catch null;
        c.malloc.free(z);
        vtab.setErrMsgOwned(t.db, &t.base, copy);
    }

    fn call(t: *Tab, rc: c_int) i32 {
        t.takeError();
        return rc;
    }
};

const Cursor = struct {
    base: vtab.VtabCursor = .{},
    cur: *CCursor,

    fn of(p: *vtab.VtabCursor) *Cursor {
        return @fieldParentPtr("base", p);
    }

    fn tab(cu: *Cursor) *Tab {
        return Tab.of(cu.base.vtab);
    }
};

fn wrapOf(aux: ?*anyopaque) *ModWrap {
    return @ptrCast(@alignCast(aux.?));
}

fn construct(comptime create: bool) vtab.Module.ConstructFn {
    return struct {
        fn f(db: *Handle, aux: ?*anyopaque, argv: []const [:0]const u8, out: *?*vtab.Vtab, err: *?[:0]u8) i32 {
            const w = wrapOf(aux);
            const x = (if (create) w.cmod.xCreate else w.cmod.xConnect) orelse return RC.ERROR;
            const az = c.gpa.alloc([*:0]const u8, argv.len) catch return RC.NOMEM;
            defer c.gpa.free(az);
            for (argv, az) |a, *z| z.* = a.ptr;
            var cvt: ?*CVtab = null;
            var zerr: ?[*:0]u8 = null;
            const rc = x(db, w.aux, @intCast(argv.len), az.ptr, &cvt, &zerr);
            if (zerr) |m| {
                err.* = db.gpa.dupeSentinel(u8, std.mem.span(m), 0) catch null;
                c.malloc.free(m);
            }
            if (rc != RC.OK) return rc;
            const v = cvt orelse return RC.ERROR;
            const t = c.gpa.create(Tab) catch return RC.NOMEM;
            v.pModule = w.cmod;
            v.nRef = 0;
            t.* = .{ .cvt = v, .wrap = w, .db = db };
            out.* = &t.base;
            return RC.OK;
        }
    }.f;
}

fn xBestIndex(base: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    const t = Tab.of(base);
    const f = t.wrap.cmod.xBestIndex orelse return RC.ERROR;
    var ii: IndexInfoWrap = undefined;
    const n_cons = info.constraints.len;
    const n_ob = info.order_by.len;
    const cons = c.gpa.alloc(CConstraint, n_cons) catch return RC.NOMEM;
    defer c.gpa.free(cons);
    const ob = c.gpa.alloc(COrderBy, n_ob) catch return RC.NOMEM;
    defer c.gpa.free(ob);
    const usage = c.gpa.alloc(CUsage, n_cons) catch return RC.NOMEM;
    defer c.gpa.free(usage);
    for (info.constraints, cons) |s, *d| d.* = .{ .iColumn = s.i_column, .op = s.op, .usable = @intFromBool(s.usable), .iTermOffset = s.i_term_offset };
    for (info.order_by, ob) |s, *d| d.* = .{ .iColumn = s.i_column, .desc = @intFromBool(s.desc) };
    for (info.usage, usage) |s, *d| d.* = .{ .argvIndex = s.argv_index, .omit = @intFromBool(s.omit) };
    ii = .{
        .info = .{
            .nConstraint = @intCast(n_cons),
            .aConstraint = cons.ptr,
            .nOrderBy = @intCast(n_ob),
            .aOrderBy = ob.ptr,
            .aConstraintUsage = usage.ptr,
            .idxNum = info.idx_num,
            .idxStr = null,
            .needToFreeIdxStr = 0,
            .orderByConsumed = @intFromBool(info.order_by_consumed),
            .estimatedCost = info.estimated_cost,
            .estimatedRows = info.estimated_rows,
            .idxFlags = info.idx_flags,
            .colUsed = info.col_used,
        },
        .engine = info,
    };
    const rc = t.call(f(t.cvt, &ii.info));
    for (info.usage, usage) |*d, s| d.* = .{ .argv_index = s.argvIndex, .omit = s.omit != 0 };
    info.idx_num = ii.info.idxNum;
    info.order_by_consumed = ii.info.orderByConsumed != 0;
    info.estimated_cost = ii.info.estimatedCost;
    info.estimated_rows = ii.info.estimatedRows;
    info.idx_flags = ii.info.idxFlags;
    if (ii.info.idxStr) |z| {
        // The engine frees idx_str from the connection's allocator.
        info.idx_str = t.db.gpa.dupeSentinel(u8, std.mem.span(z), 0) catch null;
        info.need_to_free_idx_str = info.idx_str != null;
        if (ii.info.needToFreeIdxStr != 0) c.malloc.free(z);
    }
    return rc;
}

fn xDisconnect(base: *vtab.Vtab) i32 {
    const t = Tab.of(base);
    const rc = if (t.wrap.cmod.xDisconnect) |f| f(t.cvt) else RC.OK;
    c.gpa.destroy(t);
    return rc;
}

fn xDestroy(base: *vtab.Vtab) i32 {
    const t = Tab.of(base);
    const f = t.wrap.cmod.xDestroy orelse t.wrap.cmod.xDisconnect orelse {
        c.gpa.destroy(t);
        return RC.OK;
    };
    const rc = f(t.cvt);
    if (rc == RC.OK) c.gpa.destroy(t);
    return rc;
}

fn xOpen(base: *vtab.Vtab, out: *?*vtab.VtabCursor) i32 {
    const t = Tab.of(base);
    var cur: ?*CCursor = null;
    const rc = t.call((t.wrap.cmod.xOpen orelse return RC.ERROR)(t.cvt, &cur));
    if (rc != RC.OK) return rc;
    const cc = cur orelse return RC.ERROR;
    cc.pVtab = t.cvt;
    const cu = c.gpa.create(Cursor) catch {
        if (t.wrap.cmod.xClose) |f| _ = f(cc);
        return RC.NOMEM;
    };
    cu.* = .{ .cur = cc };
    out.* = &cu.base;
    return RC.OK;
}

fn xClose(p: *vtab.VtabCursor) i32 {
    const cu = Cursor.of(p);
    const t = cu.tab();
    const rc = if (t.wrap.cmod.xClose) |f| f(cu.cur) else RC.OK;
    c.gpa.destroy(cu);
    return t.call(rc);
}

fn xFilter(p: *vtab.VtabCursor, idx_num: i32, idx_str: ?[:0]const u8, argv: []*Mem) i32 {
    const cu = Cursor.of(p);
    const t = cu.tab();
    const rc = t.wrap.cmod.xFilter.?(cu.cur, idx_num, if (idx_str) |s| s.ptr else null, @intCast(argv.len), if (argv.len == 0) null else argv.ptr);
    c.toUtf8(t.db, argv);
    return t.call(rc);
}

fn xNext(p: *vtab.VtabCursor) i32 {
    const cu = Cursor.of(p);
    return cu.tab().call(cu.tab().wrap.cmod.xNext.?(cu.cur));
}

fn xEof(p: *vtab.VtabCursor) bool {
    const cu = Cursor.of(p);
    return cu.tab().wrap.cmod.xEof.?(cu.cur) != 0;
}

fn xColumn(p: *vtab.VtabCursor, ctx: *Context, i: i32) i32 {
    const cu = Cursor.of(p);
    return cu.tab().call(cu.tab().wrap.cmod.xColumn.?(cu.cur, ctx, i));
}

fn xRowid(p: *vtab.VtabCursor, rowid: *i64) i32 {
    const cu = Cursor.of(p);
    const f = cu.tab().wrap.cmod.xRowid orelse return RC.ERROR;
    return cu.tab().call(f(cu.cur, rowid));
}

fn xUpdate(base: *vtab.Vtab, argv: []*Mem, rowid: *i64) i32 {
    const t = Tab.of(base);
    const rc = t.wrap.cmod.xUpdate.?(t.cvt, @intCast(argv.len), if (argv.len == 0) null else argv.ptr, rowid);
    c.toUtf8(t.db, argv);
    return t.call(rc);
}

fn vtabMethod(comptime field: []const u8) *const fn (*vtab.Vtab) i32 {
    return struct {
        fn f(base: *vtab.Vtab) i32 {
            const t = Tab.of(base);
            const m = @field(t.wrap.cmod, field) orelse return RC.OK;
            return t.call(m(t.cvt));
        }
    }.f;
}

fn savepointMethod(comptime field: []const u8) *const fn (*vtab.Vtab, i32) i32 {
    return struct {
        fn f(base: *vtab.Vtab, i: i32) i32 {
            const t = Tab.of(base);
            if (!t.wrap.has(2)) return RC.OK;
            const m = @field(t.wrap.cmod, field) orelse return RC.OK;
            return t.call(m(t.cvt, i));
        }
    }.f;
}

fn xRename(base: *vtab.Vtab, new_name: [:0]const u8) i32 {
    const t = Tab.of(base);
    return t.call(t.wrap.cmod.xRename.?(t.cvt, new_name.ptr));
}

fn xShadowName(aux: ?*anyopaque, name: []const u8) bool {
    const w = wrapOf(aux);
    const f = w.cmod.xShadowName.?;
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return false;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return f(@ptrCast(&buf)) != 0;
}

fn xIntegrity(base: *vtab.Vtab, schema: [:0]const u8, tab_name: [:0]const u8, flags: i32, err: *?[:0]u8) i32 {
    const t = Tab.of(base);
    var zerr: ?[*:0]u8 = null;
    const rc = t.wrap.cmod.xIntegrity.?(t.cvt, schema.ptr, tab_name.ptr, flags, &zerr);
    if (zerr) |m| {
        err.* = t.db.gpa.dupeSentinel(u8, std.mem.span(m), 0) catch null;
        c.malloc.free(m);
    }
    return t.call(rc);
}

const destroyWrap = c.int.destructor(ModWrap.destroy);

fn createModule(db_arg: ?*Handle, z_name: ?[*:0]const u8, p: ?*const CModule, aux: ?*anyopaque, x_destroy: ?c.CDestructor) c_int {
    const db = db_arg orelse return RC.MISUSE;
    const name = c.span(z_name) orelse return RC.MISUSE;
    const cm = p orelse {
        // A null module unregisters the name.
        if (x_destroy) |d| d(aux);
        return vtab.createModuleV2(db, name, null, null, null);
    };
    const w = c.gpa.create(ModWrap) catch {
        if (x_destroy) |d| d(aux);
        return RC.NOMEM;
    };
    w.* = .{ .module = .{}, .cmod = cm, .aux = aux, .x_destroy = x_destroy };
    const m = &w.module;
    m.i_version = @min(cm.iVersion, 4);
    // A module whose xCreate is its xConnect makes eponymous tables: the
    // engine sees that as the same method in both slots.
    m.x_connect = construct(false);
    m.x_create = if (cm.xCreate == null) null else if (cm.xCreate == cm.xConnect) m.x_connect else construct(true);
    m.x_best_index = xBestIndex;
    m.x_disconnect = xDisconnect;
    m.x_destroy = xDestroy;
    m.x_open = xOpen;
    m.x_close = xClose;
    m.x_filter = if (cm.xFilter != null) xFilter else null;
    m.x_next = if (cm.xNext != null) xNext else null;
    m.x_eof = if (cm.xEof != null) xEof else null;
    m.x_column = if (cm.xColumn != null) xColumn else null;
    m.x_rowid = xRowid;
    m.x_update = if (cm.xUpdate != null) xUpdate else null;
    m.x_begin = if (cm.xBegin != null) vtabMethod("xBegin") else null;
    m.x_sync = if (cm.xSync != null) vtabMethod("xSync") else null;
    m.x_commit = if (cm.xCommit != null) vtabMethod("xCommit") else null;
    m.x_rollback = if (cm.xRollback != null) vtabMethod("xRollback") else null;
    // xFindFunction: C would hand back C functions, which the engine
    // cannot call; functions are not overloaded.
    m.x_rename = if (cm.xRename != null) xRename else null;
    if (cm.iVersion >= 2) {
        m.x_savepoint = if (cm.xSavepoint != null) savepointMethod("xSavepoint") else null;
        m.x_release = if (cm.xRelease != null) savepointMethod("xRelease") else null;
        m.x_rollback_to = if (cm.xRollbackTo != null) savepointMethod("xRollbackTo") else null;
    }
    if (cm.iVersion >= 3 and cm.xShadowName != null) m.x_shadow_name = xShadowName;
    if (cm.iVersion >= 4 and cm.xIntegrity != null) m.x_integrity = xIntegrity;
    return vtab.createModuleV2(db, name, m, w, destroyWrap);
}

pub export fn sqlite3_create_module(db: ?*Handle, z_name: ?[*:0]const u8, p: ?*const CModule, aux: ?*anyopaque) callconv(.c) c_int {
    return createModule(db, z_name, p, aux, null);
}

pub export fn sqlite3_create_module_v2(db: ?*Handle, z_name: ?[*:0]const u8, p: ?*const CModule, aux: ?*anyopaque, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    return createModule(db, z_name, p, aux, c.cDestructor(x_destroy));
}

pub export fn sqlite3_drop_modules(db: ?*Handle, az_keep: ?[*]const ?[*:0]const u8) callconv(.c) c_int {
    const h = db orelse return RC.MISUSE;
    const keep = az_keep orelse return vtab.dropModules(h, null);
    var n: usize = 0;
    while (keep[n] != null) n += 1;
    const names = c.gpa.alloc([]const u8, n) catch return RC.NOMEM;
    defer c.gpa.free(names);
    for (names, 0..) |*s, i| s.* = std.mem.span(keep[i].?);
    return vtab.dropModules(h, names);
}

pub export fn sqlite3_declare_vtab(db: ?*Handle, z_sql: ?[*:0]const u8) callconv(.c) c_int {
    return vtab.declareVtab(db orelse return RC.MISUSE, std.mem.span(z_sql orelse return RC.MISUSE));
}

/// sqlite3_vtab_config() with its argument out of the varargs (C shim).
pub fn xq_vtab_config(db: ?*Handle, op: c_int, arg: c_int) callconv(.c) c_int {
    return vtab.config(db orelse return RC.MISUSE, op, arg);
}

pub export fn sqlite3_vtab_on_conflict(db: ?*Handle) callconv(.c) c_int {
    return vtab.onConflict(db orelse return RC.MISUSE);
}

/// The sqlite3_index_info passed to a C xBestIndex, with the engine's
/// IndexInfo it stands for (for sqlite3_vtab_collation() and friends).
const IndexInfoWrap = struct {
    info: CIndexInfo,
    engine: *vtab.IndexInfo,

    fn of(p: *CIndexInfo) *vtab.IndexInfo {
        const w: *IndexInfoWrap = @fieldParentPtr("info", p);
        return w.engine;
    }
};

pub export fn sqlite3_vtab_collation(p: ?*CIndexInfo, i: c_int) callconv(.c) ?[*:0]const u8 {
    return c.cStr(vtab.collation(IndexInfoWrap.of(p orelse return null), i));
}

pub export fn sqlite3_vtab_distinct(p: ?*CIndexInfo) callconv(.c) c_int {
    return vtab.distinct(IndexInfoWrap.of(p orelse return 0));
}

pub export fn sqlite3_vtab_in(p: ?*CIndexInfo, i: c_int, b_handle: c_int) callconv(.c) c_int {
    return @intFromBool(vtab.in(IndexInfoWrap.of(p orelse return 0), i, b_handle));
}

pub export fn sqlite3_vtab_rhs_value(p: ?*CIndexInfo, i: c_int, out: ?*?*Mem) callconv(.c) c_int {
    return vtab.rhsValue(IndexInfoWrap.of(p orelse return RC.MISUSE), i, out orelse return RC.MISUSE);
}

pub export fn sqlite3_vtab_in_first(v: ?*Mem, out: ?*?*Mem) callconv(.c) c_int {
    return vtab.inFirst(v, out orelse return RC.MISUSE);
}

pub export fn sqlite3_vtab_in_next(v: ?*Mem, out: ?*?*Mem) callconv(.c) c_int {
    return vtab.inNext(v, out orelse return RC.MISUSE);
}

// The xq_* functions are for capi/varargs.c only: hidden outside the library.
comptime {
    @export(&xq_vtab_config, .{ .name = "xq_vtab_config", .visibility = .hidden });
}
