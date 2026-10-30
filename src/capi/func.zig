//! Application-defined functions and collations, sqlite3_value_*() and
//! sqlite3_result_*().
//!
//! The engine calls functions with a Zig signature (a context and a
//! slice of values); a C function is registered behind a trampoline
//! whose user data (FuncWrap) holds the C callbacks and pApp, so
//! sqlite3_user_data() answers pApp. Collations likewise (CollWrap).

const std = @import("std");
const c = @import("common.zig");

const Handle = c.Handle;
const Context = c.Context;
const Mem = c.Mem;
const RC = c.RC;
const callback = @import("../sql/callback.zig");
const coll = @import("../sql/coll.zig");
const vtab = @import("../sql/vtab.zig");

pub const XFunc = *const fn (?*Context, c_int, ?[*]*Mem) callconv(.c) void;
pub const XFinal = *const fn (?*Context) callconv(.c) void;

// ============================================================= functions

pub const FuncWrap = struct {
    x_func: ?XFunc,
    x_step: ?XFunc,
    x_final: ?XFinal,
    x_value: ?XFinal,
    x_inverse: ?XFunc,
    p_app: ?*anyopaque,
    x_destroy: ?c.CDestructor,

    fn of(ctx: *Context) *FuncWrap {
        return @ptrCast(@alignCast(c.api.userData(ctx).?));
    }

    fn destroy(w: *FuncWrap) void {
        if (w.x_destroy) |d| d(w.p_app);
        c.gpa.destroy(w);
    }
};

fn argvPtr(argv: []*Mem) ?[*]*Mem {
    return if (argv.len == 0) null else argv.ptr;
}

pub fn scalarThunk(ctx: *Context, argv: []*Mem) void {
    const w = FuncWrap.of(ctx);
    w.x_func.?(ctx, @intCast(argv.len), argvPtr(argv));
}

fn stepThunk(ctx: *Context, argv: []*Mem) void {
    const w = FuncWrap.of(ctx);
    w.x_step.?(ctx, @intCast(argv.len), argvPtr(argv));
}

fn finalThunk(ctx: *Context) void {
    FuncWrap.of(ctx).x_final.?(ctx);
}

fn valueThunk(ctx: *Context) void {
    FuncWrap.of(ctx).x_value.?(ctx);
}

fn inverseThunk(ctx: *Context, argv: []*Mem) void {
    const w = FuncWrap.of(ctx);
    w.x_inverse.?(ctx, @intCast(argv.len), argvPtr(argv));
}

const destroyWrap = c.int.destructor(FuncWrap.destroy);

/// sqlite3_create_function_v2() and sqlite3_create_window_function().
fn createFunction(
    db_arg: ?*Handle,
    name: ?[]const u8,
    n_arg: c_int,
    e_text_rep: c_int,
    p_app: ?*anyopaque,
    x_func: ?XFunc,
    x_step: ?XFunc,
    x_final: ?XFinal,
    x_value: ?XFinal,
    x_inverse: ?XFunc,
    x_destroy: ?c.CDestructor,
) c_int {
    const db = db_arg orelse return RC.MISUSE;
    // The combinations sqlite3CreateFunc() refuses.
    if (name == null or
        (x_func != null and (x_final != null or x_step != null)) or
        (x_func == null and x_final != null and x_step == null) or
        (x_func == null and x_final == null and x_step != null) or
        ((x_value == null) != (x_inverse == null)))
    {
        return RC.MISUSE;
    }
    const deleting = x_func == null and x_step == null;
    var wrap: ?*FuncWrap = null;
    if (!deleting or x_destroy != null) {
        const w = c.gpa.create(FuncWrap) catch {
            if (x_destroy) |d| d(p_app);
            return RC.NOMEM;
        };
        w.* = .{ .x_func = x_func, .x_step = x_step, .x_final = x_final, .x_value = x_value, .x_inverse = x_inverse, .p_app = p_app, .x_destroy = x_destroy };
        wrap = w;
    }
    const flags: u32 = @bitCast(e_text_rep);
    const enc = (flags & 0x7) | (flags & callback.FNFLAG.mask.int());
    return callback.createFunctionV2(
        db,
        name,
        n_arg,
        enc,
        wrap,
        if (x_func != null) scalarThunk else if (x_step != null) stepThunk else null,
        if (x_final != null) finalThunk else null,
        if (x_value != null) valueThunk else null,
        if (x_inverse != null) inverseThunk else null,
        if (wrap != null) destroyWrap else null,
    );
}

pub export fn sqlite3_create_function(db: ?*Handle, z_name: ?[*:0]const u8, n_arg: c_int, e_text_rep: c_int, p_app: ?*anyopaque, x_func: ?XFunc, x_step: ?XFunc, x_final: ?XFinal) callconv(.c) c_int {
    return createFunction(db, c.span(z_name), n_arg, e_text_rep, p_app, x_func, x_step, x_final, null, null, null);
}

pub export fn sqlite3_create_function_v2(db: ?*Handle, z_name: ?[*:0]const u8, n_arg: c_int, e_text_rep: c_int, p_app: ?*anyopaque, x_func: ?XFunc, x_step: ?XFunc, x_final: ?XFinal, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    return createFunction(db, c.span(z_name), n_arg, e_text_rep, p_app, x_func, x_step, x_final, null, null, c.cDestructor(x_destroy));
}

pub export fn sqlite3_create_window_function(db: ?*Handle, z_name: ?[*:0]const u8, n_arg: c_int, e_text_rep: c_int, p_app: ?*anyopaque, x_step: ?XFunc, x_final: ?XFinal, x_value: ?XFinal, x_inverse: ?XFunc, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    return createFunction(db, c.span(z_name), n_arg, e_text_rep, p_app, null, x_step, x_final, x_value, x_inverse, c.cDestructor(x_destroy));
}

pub export fn sqlite3_create_function16(db: ?*Handle, z_name: ?*const anyopaque, n_arg: c_int, e_text_rep: c_int, p_app: ?*anyopaque, x_func: ?XFunc, x_step: ?XFunc, x_final: ?XFinal) callconv(.c) c_int {
    const name = c.utf16ToUtf8(c.utf16Slice(z_name orelse return RC.MISUSE, -1), false) orelse return RC.NOMEM;
    defer c.gpa.free(name);
    return createFunction(db, name, n_arg, e_text_rep, p_app, x_func, x_step, x_final, null, null, null);
}

pub export fn sqlite3_overload_function(db: ?*Handle, z_name: ?[*:0]const u8, n_arg: c_int) callconv(.c) c_int {
    const h = db orelse return RC.MISUSE;
    const name = c.span(z_name) orelse return RC.MISUSE;
    if (n_arg < -2) return RC.MISUSE;
    return c.main.apiExit(h, callback.overloadFunction(h, name, n_arg));
}

pub export fn sqlite3_user_data(ctx: ?*Context) callconv(.c) ?*anyopaque {
    const cx = ctx orelse return null;
    const p = c.api.userData(cx) orelse return null;
    // Only C functions are called with a C context.
    const w: *FuncWrap = @ptrCast(@alignCast(p));
    return w.p_app;
}

pub export fn sqlite3_context_db_handle(ctx: ?*Context) callconv(.c) ?*Handle {
    return c.api.contextDbHandle(ctx orelse return null);
}

pub export fn sqlite3_aggregate_context(ctx: ?*Context, n: c_int) callconv(.c) ?*anyopaque {
    const b = c.api.aggregateContext(ctx orelse return null, @intCast(@max(n, 0))) orelse return null;
    return b.ptr;
}

pub export fn sqlite3_aggregate_count(_: ?*Context) callconv(.c) c_int {
    // Deprecated; no count is kept.
    return 0;
}

/// Auxiliary data with a C destructor, which the engine's destructor
/// (taking the pointer only) calls through this box.
const AuxBox = struct {
    p: ?*anyopaque,
    del: ?c.CDestructor,

    fn destroy(b: *AuxBox) void {
        if (b.del) |d| d(b.p);
        c.gpa.destroy(b);
    }
};

pub export fn sqlite3_get_auxdata(ctx: ?*Context, n: c_int) callconv(.c) ?*anyopaque {
    const b = c.api.getAuxdataTyped(ctx orelse return null, n, AuxBox.destroy) orelse return null;
    return b.p;
}

pub export fn sqlite3_set_auxdata(ctx: ?*Context, n: c_int, p: ?*anyopaque, del: ?*const anyopaque) callconv(.c) void {
    const d = c.cDestructor(del);
    const cx = ctx orelse {
        if (d) |f| f(p);
        return;
    };
    const b = c.gpa.create(AuxBox) catch {
        if (d) |f| f(p);
        return;
    };
    b.* = .{ .p = p, .del = d };
    c.api.setAuxdataTyped(cx, n, AuxBox.destroy, b);
}

// ======================================================== pointer values

/// The engine destructor of a pointer value whose C destructor is `del`
/// (sqlite3_bind_pointer(), sqlite3_result_pointer()). The engine passes
/// a destructor the pointer only, so the C function is looked up in a
/// process-wide table by the pointer.
pub fn pointerDestructor(p: ?*anyopaque, del: ?*const anyopaque) ?c.int.DestructorFn {
    const f = c.cDestructor(del) orelse return null;
    c.state.ptr_lock.lock();
    defer c.state.ptr_lock.unlock();
    c.state.ptr_dtors.append(c.gpa, .{ .p = p, .f = f }) catch {
        f(p);
        return null;
    };
    return runPointerDestructor;
}

fn runPointerDestructor(p: ?*anyopaque) void {
    const f = blk: {
        c.state.ptr_lock.lock();
        defer c.state.ptr_lock.unlock();
        const list = &c.state.ptr_dtors;
        var i = list.items.len;
        while (i > 0) {
            i -= 1;
            if (list.items[i].p == p) break :blk list.swapRemove(i).f;
        }
        return;
    };
    f(p);
}

// ================================================================ values

pub export fn sqlite3_value_type(v: ?*Mem) callconv(.c) c_int {
    return c.api.valueType(v orelse return c.vi.SQLITE_NULL);
}

pub export fn sqlite3_value_numeric_type(v: ?*Mem) callconv(.c) c_int {
    return c.api.valueNumericType(v orelse return c.vi.SQLITE_NULL);
}

pub export fn sqlite3_value_int(v: ?*Mem) callconv(.c) c_int {
    return c.api.valueInt(v orelse return 0);
}

pub export fn sqlite3_value_int64(v: ?*Mem) callconv(.c) i64 {
    return c.api.valueInt64(v orelse return 0);
}

pub export fn sqlite3_value_double(v: ?*Mem) callconv(.c) f64 {
    return c.api.valueDouble(v orelse return 0);
}

pub export fn sqlite3_value_text(v: ?*Mem) callconv(.c) ?[*:0]const u8 {
    return c.cStr(c.api.valueText(v orelse return null));
}

pub export fn sqlite3_value_blob(v: ?*Mem) callconv(.c) ?*const anyopaque {
    const b = c.api.valueBlob(v orelse return null) orelse return null;
    return b.ptr;
}

pub export fn sqlite3_value_bytes(v: ?*Mem) callconv(.c) c_int {
    return @intCast(c.api.valueBytes(v orelse return 0));
}

pub export fn sqlite3_value_bytes16(v: ?*Mem) callconv(.c) c_int {
    const t = c.api.valueText(v orelse return 0) orelse return 0;
    return @intCast(c.utf16Bytes(t));
}

// UTF-16 results are not supported (see stmt.zig).

pub export fn sqlite3_value_text16(_: ?*Mem) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_value_text16le(_: ?*Mem) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_value_text16be(_: ?*Mem) callconv(.c) ?*const anyopaque {
    return null;
}

pub export fn sqlite3_value_pointer(v: ?*Mem, z_type: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    return c.api.valuePointer(v orelse return null, std.mem.span(z_type orelse return null));
}

pub export fn sqlite3_value_subtype(v: ?*Mem) callconv(.c) c_uint {
    return c.api.valueSubtype(v orelse return 0);
}

pub export fn sqlite3_value_nochange(v: ?*Mem) callconv(.c) c_int {
    return @intFromBool(c.api.valueNochange(v orelse return 0));
}

pub export fn sqlite3_value_frombind(v: ?*Mem) callconv(.c) c_int {
    return @intFromBool(c.api.valueFrombind(v orelse return 0));
}

pub export fn sqlite3_value_encoding(_: ?*Mem) callconv(.c) c_int {
    return 1;
}

pub export fn sqlite3_value_dup(v: ?*const Mem) callconv(.c) ?*Mem {
    return c.api.valueDup(v);
}

pub export fn sqlite3_value_free(v: ?*Mem) callconv(.c) void {
    c.api.valueFree(v);
}

// =============================================================== results

pub export fn sqlite3_result_null(ctx: ?*Context) callconv(.c) void {
    c.api.resultNull(ctx orelse return);
}

pub export fn sqlite3_result_int(ctx: ?*Context, x: c_int) callconv(.c) void {
    c.api.resultInt64(ctx orelse return, x);
}

pub export fn sqlite3_result_int64(ctx: ?*Context, x: i64) callconv(.c) void {
    c.api.resultInt64(ctx orelse return, x);
}

pub export fn sqlite3_result_double(ctx: ?*Context, x: f64) callconv(.c) void {
    c.api.resultDouble(ctx orelse return, x);
}

fn resultText(ctx_arg: ?*Context, z: ?*const anyopaque, n: i64, del_arg: ?*const anyopaque, enc: u8) void {
    const del = c.Del.of(del_arg);
    const ctx = ctx_arg orelse return del.after(z);
    const p = z orelse {
        c.api.resultNull(ctx);
        return;
    };
    switch (enc) {
        2, 3, 4 => {
            defer if (c.cDestructor(del_arg)) |f| f(@constCast(p));
            const s8 = c.utf16ToUtf8(c.utf16Slice(p, n), enc == 3) orelse return c.api.resultErrorNomem(ctx);
            defer c.gpa.free(s8);
            c.api.resultText(ctx, s8, .transient);
        },
        else => {
            const s = c.cSlice(@ptrCast(p), n);
            c.api.resultText64(ctx, s, del.engine);
            del.after(p);
        },
    }
}

pub export fn sqlite3_result_text(ctx: ?*Context, z: ?[*]const u8, n: c_int, del: ?*const anyopaque) callconv(.c) void {
    resultText(ctx, z, n, del, 1);
}

pub export fn sqlite3_result_text64(ctx: ?*Context, z: ?[*]const u8, n: u64, del: ?*const anyopaque, enc: u8) callconv(.c) void {
    const len: i64 = if (n > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(n);
    resultText(ctx, z, len, del, enc);
}

pub export fn sqlite3_result_text16(ctx: ?*Context, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) void {
    resultText(ctx, z, n, del, 4);
}

pub export fn sqlite3_result_text16le(ctx: ?*Context, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) void {
    resultText(ctx, z, n, del, 2);
}

pub export fn sqlite3_result_text16be(ctx: ?*Context, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) void {
    resultText(ctx, z, n, del, 3);
}

fn resultBlob(ctx_arg: ?*Context, z: ?*const anyopaque, n: u64, del_arg: ?*const anyopaque) void {
    const del = c.Del.of(del_arg);
    const ctx = ctx_arg orelse return del.after(z);
    const p: [*]const u8 = @ptrCast(z orelse {
        c.api.resultNull(ctx);
        return;
    });
    if (n > std.math.maxInt(c_int)) {
        c.api.resultErrorTooBig(ctx);
        if (c.cDestructor(del_arg)) |f| f(@constCast(z));
        return;
    }
    c.api.resultBlob(ctx, p[0..@intCast(n)], del.engine);
    del.after(z);
}

pub export fn sqlite3_result_blob(ctx: ?*Context, z: ?*const anyopaque, n: c_int, del: ?*const anyopaque) callconv(.c) void {
    resultBlob(ctx, z, @intCast(@max(n, 0)), del);
}

pub export fn sqlite3_result_blob64(ctx: ?*Context, z: ?*const anyopaque, n: u64, del: ?*const anyopaque) callconv(.c) void {
    resultBlob(ctx, z, n, del);
}

pub export fn sqlite3_result_zeroblob(ctx: ?*Context, n: c_int) callconv(.c) void {
    c.api.resultZeroblob(ctx orelse return, @intCast(@max(n, 0)));
}

pub export fn sqlite3_result_zeroblob64(ctx: ?*Context, n: u64) callconv(.c) c_int {
    return c.api.resultZeroblob64(ctx orelse return RC.MISUSE, n);
}

pub export fn sqlite3_result_value(ctx: ?*Context, v: ?*Mem) callconv(.c) void {
    const cx = ctx orelse return;
    c.api.resultValue(cx, v orelse return c.api.resultNull(cx));
}

pub export fn sqlite3_result_pointer(ctx_arg: ?*Context, p: ?*anyopaque, z_type: ?[*:0]const u8, del: ?*const anyopaque) callconv(.c) void {
    const ctx = ctx_arg orelse {
        if (c.cDestructor(del)) |f| f(p);
        return;
    };
    c.mem.setNull(ctx.out);
    c.mem.setPointer(ctx.out, p, z_type, pointerDestructor(p, del));
}

pub export fn sqlite3_result_subtype(ctx: ?*Context, subtype: c_uint) callconv(.c) void {
    c.api.resultSubtype(ctx orelse return, subtype);
}

pub export fn sqlite3_result_error(ctx: ?*Context, z: ?[*]const u8, n: c_int) callconv(.c) void {
    c.api.resultError(ctx orelse return, if (z) |p| c.cSlice(p, n) else "");
}

pub export fn sqlite3_result_error16(ctx: ?*Context, z: ?*const anyopaque, n: c_int) callconv(.c) void {
    const cx = ctx orelse return;
    const s = c.utf16ToUtf8(c.utf16Slice(z orelse return c.api.resultError(cx, ""), n), false) orelse return c.api.resultErrorNomem(cx);
    defer c.gpa.free(s);
    c.api.resultError(cx, s);
}

pub export fn sqlite3_result_error_code(ctx: ?*Context, code: c_int) callconv(.c) void {
    c.api.resultErrorCode(ctx orelse return, code);
}

pub export fn sqlite3_result_error_toobig(ctx: ?*Context) callconv(.c) void {
    c.api.resultErrorTooBig(ctx orelse return);
}

pub export fn sqlite3_result_error_nomem(ctx: ?*Context) callconv(.c) void {
    c.api.resultErrorNomem(ctx orelse return);
}

pub export fn sqlite3_vtab_nochange(ctx: ?*Context) callconv(.c) c_int {
    return @intFromBool(vtab.nochange(ctx orelse return 0));
}

// ============================================================ collations

pub const CCompare = *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int;

/// A collation registered from C (kept in Ext.colls by name).
pub const CollWrap = struct {
    name: [:0]u8,
    x_compare: CCompare,
    p_arg: ?*anyopaque,
    x_destroy: ?c.CDestructor,

    pub fn destroy(w: *CollWrap) void {
        if (w.x_destroy) |d| d(w.p_arg);
        c.gpa.free(w.name);
        c.gpa.destroy(w);
    }
};

fn compareThunk(user: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    const w: *CollWrap = @ptrCast(@alignCast(user.?));
    const r = w.x_compare(w.p_arg, @intCast(a.len), a.ptr, @intCast(b.len), b.ptr);
    return std.math.order(r, 0);
}

fn createCollation(db_arg: ?*Handle, name: ?[]const u8, p_arg: ?*anyopaque, x_compare: ?CCompare, x_destroy: ?c.CDestructor) c_int {
    const db = db_arg orelse return RC.MISUSE;
    const z = name orelse return RC.MISUSE;
    const e = c.ext(db);
    var rc: c_int = RC.OK;
    var new: ?*CollWrap = null;
    if (x_compare) |cmp| {
        const w = c.gpa.create(CollWrap) catch return RC.NOMEM;
        w.* = .{ .name = c.gpa.dupeSentinel(u8, z, 0) catch {
            c.gpa.destroy(w);
            return RC.NOMEM;
        }, .x_compare = cmp, .p_arg = p_arg, .x_destroy = x_destroy };
        rc = c.main.apiExit(db, coll.createCollation(db, z, w, compareThunk));
        if (rc != RC.OK) {
            // As in SQLite, xDestroy is not called when this fails.
            w.x_destroy = null;
            w.destroy();
            return rc;
        }
        new = w;
    } else {
        // Delete the collation: it becomes "named but not defined".
        if (db.n_vdbe_active != 0) {
            c.main.errorWithMsg(db, RC.BUSY, "unable to delete/modify collation sequence due to active statements", .{});
            return RC.BUSY;
        }
        if (db.colls.get(z)) |cs| {
            @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
            cs.cmp = null;
            cs.user = null;
        }
    }
    // The collation it replaces, if registered from C, is gone.
    var i: usize = 0;
    while (i < e.colls.items.len) {
        const w = e.colls.items[i];
        if (c.ctype.eqlNoCase(w.name, z)) {
            _ = e.colls.orderedRemove(i);
            w.destroy();
        } else i += 1;
    }
    if (new) |w| e.colls.append(c.gpa, w) catch {};
    return RC.OK;
}

pub export fn sqlite3_create_collation(db: ?*Handle, z_name: ?[*:0]const u8, _: c_int, p_arg: ?*anyopaque, x_compare: ?CCompare) callconv(.c) c_int {
    return createCollation(db, c.span(z_name), p_arg, x_compare, null);
}

pub export fn sqlite3_create_collation_v2(db: ?*Handle, z_name: ?[*:0]const u8, _: c_int, p_arg: ?*anyopaque, x_compare: ?CCompare, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    return createCollation(db, c.span(z_name), p_arg, x_compare, c.cDestructor(x_destroy));
}

pub export fn sqlite3_create_collation16(db: ?*Handle, z_name: ?*const anyopaque, _: c_int, p_arg: ?*anyopaque, x_compare: ?CCompare) callconv(.c) c_int {
    const name = c.utf16ToUtf8(c.utf16Slice(z_name orelse return RC.MISUSE, -1), false) orelse return RC.NOMEM;
    defer c.gpa.free(name);
    return createCollation(db, name, p_arg, x_compare, null);
}
