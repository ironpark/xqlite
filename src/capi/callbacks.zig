//! The callbacks the engine calls while it compiles and runs statements:
//! the authorizer, the collation-needed callback and the autovacuum-pages
//! callback. As for the other hooks (hooks.zig), the engine calls a Zig
//! function with the connection's Ext as its argument, and that calls
//! the C callback.

const std = @import("std");
const c = @import("common.zig");
const auth = @import("../sql/auth.zig");

const Handle = c.Handle;
const RC = c.RC;

fn extOf(arg: ?*anyopaque) *c.Ext {
    return @ptrCast(@alignCast(arg.?));
}

// ============================================================ authorizer

fn authThunk(arg: ?*anyopaque, code: i32, a1: ?[*:0]const u8, a2: ?[*:0]const u8, a3: ?[*:0]const u8, context: ?[*:0]const u8) i32 {
    const e = extOf(arg);
    return e.authorizer.f.?(e.authorizer.arg, code, a1, a2, a3, context);
}

/// The authorizer: statements prepared from now on are checked against
/// it, and those prepared before are expired (recompiled on their next
/// step).
pub export fn sqlite3_set_authorizer(db_arg: ?*Handle, f: ?c.CAuth, arg: ?*anyopaque) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const e = c.ext(db);
    e.authorizer = .{ .f = f, .arg = arg };
    auth.setAuthorizer(db, if (f != null) authThunk else null, e);
    return RC.OK;
}

// ===================================================== collation needed

fn collNeededThunk(arg: ?*anyopaque, db: *Handle, name: [:0]const u8) void {
    const e = extOf(arg);
    const f = e.coll_needed.f.?;
    if (!e.coll_needed16) return f(e.coll_needed.arg, db, ENC_UTF8, name.ptr);
    const z = c.utf8ToUtf16(name) orelse return db.oomFault();
    defer c.gpa.free(z);
    // The encoding is the database's (UTF-8), as in SQLite.
    f(e.coll_needed.arg, db, ENC_UTF8, z.ptr);
}

const ENC_UTF8: c_int = 1;

fn setCollNeeded(db_arg: ?*Handle, arg: ?*anyopaque, f: ?*const anyopaque, utf16: bool) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const e = c.ext(db);
    e.coll_needed = .{ .f = @ptrCast(@alignCast(f)), .arg = arg };
    e.coll_needed16 = utf16;
    db.coll_needed = if (f != null) collNeededThunk else null;
    db.coll_needed_arg = e;
    return RC.OK;
}

/// The callback that defines collations on demand: called with the name
/// of a collation a statement uses that is not defined.
pub export fn sqlite3_collation_needed(db: ?*Handle, arg: ?*anyopaque, f: ?*const anyopaque) callconv(.c) c_int {
    return setCollNeeded(db, arg, f, false);
}

/// sqlite3_collation_needed() with the name in native UTF-16.
pub export fn sqlite3_collation_needed16(db: ?*Handle, arg: ?*anyopaque, f: ?*const anyopaque) callconv(.c) c_int {
    return setCollNeeded(db, arg, f, true);
}

// ====================================================== autovacuum pages

fn autovacThunk(arg: ?*anyopaque, name: [:0]const u8, n_orig: u32, n_free: u32, page_size: u32) u32 {
    const e = extOf(arg);
    return e.autovac.f.?(e.autovac.arg, name.ptr, n_orig, n_free, page_size);
}

/// The callback that decides how many free pages a full auto-vacuum
/// commit gives back. The destructor of the previous argument runs now,
/// that of the last one when the connection closes.
pub export fn sqlite3_autovacuum_pages(db_arg: ?*Handle, f: ?c.CAutovac, arg: ?*anyopaque, x_destroy: ?*const anyopaque) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const e = c.ext(db);
    if (e.autovac_destroy) |d| d(e.autovac.arg);
    e.autovac = .{ .f = f, .arg = arg };
    e.autovac_destroy = c.cDestructor(x_destroy);
    db.autovac_pages = if (f != null) autovacThunk else null;
    db.autovac_pages_arg = e;
    return RC.OK;
}

// ================================================================= trace

fn traceV2Thunk(mask: u32, arg: ?*anyopaque, p: ?*anyopaque, x: ?*anyopaque) i32 {
    const e = extOf(arg);
    return e.trace.f.?(mask, e.trace.arg, p, x);
}

fn traceLegacyThunk(arg: ?*anyopaque, v: *anyopaque, sql: [*:0]const u8) void {
    const e = extOf(arg);
    const z = @import("stmt.zig").expandSql(@ptrCast(@alignCast(v)), std.mem.span(sql));
    defer if (z) |p| c.malloc.free(p);
    e.legacy_trace.f.?(e.legacy_trace.arg, z orelse sql);
}

fn profileThunk(arg: ?*anyopaque, sql: [*:0]const u8, ns: u64) void {
    const e = extOf(arg);
    e.legacy_profile.f.?(e.legacy_profile.arg, sql, ns);
}

/// The trace callback: the engine calls it for the events of `mask`
/// (SQLITE_TRACE_STMT from OP_Init and OP_Trace, ROW from OP_ResultRow,
/// PROFILE when a run ends, CLOSE on sqlite3_close()). It replaces a
/// callback of sqlite3_trace().
pub export fn sqlite3_trace_v2(db_arg: ?*Handle, mask_arg: c_uint, f_arg: ?c.CTraceV2, arg: ?*anyopaque) callconv(.c) c_int {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return RC.MISUSE;
    const e = c.ext(db);
    var mask = mask_arg;
    var f = f_arg;
    if (mask == 0) f = null;
    if (f == null) mask = 0;
    db.m_trace = @truncate(mask);
    e.trace = .{ .f = f, .arg = arg };
    e.legacy_trace = .{};
    db.trace_v2 = if (f != null) traceV2Thunk else null;
    db.trace_legacy = null;
    db.trace_arg = e;
    e.trace_arg = arg;
    return RC.OK;
}

/// The deprecated trace callback: the SQL of each statement, with its
/// parameters expanded. It replaces a callback of sqlite3_trace_v2().
pub export fn sqlite3_trace(db_arg: ?*Handle, f: ?c.CTrace, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return null;
    const e = c.ext(db);
    const old = e.trace_arg;
    db.m_trace = if (f != null) TRACE_LEGACY else 0;
    e.legacy_trace = .{ .f = f, .arg = arg };
    e.trace = .{};
    db.trace_legacy = if (f != null) traceLegacyThunk else null;
    db.trace_v2 = null;
    db.trace_arg = e;
    e.trace_arg = arg;
    return old;
}

/// The deprecated profile callback: the SQL and running time of each
/// statement that ends.
pub export fn sqlite3_profile(db_arg: ?*Handle, f: ?c.CProfile, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const lk = c.lock(db_arg);
    defer lk.unlock();
    const db = db_arg orelse return null;
    const e = c.ext(db);
    const old = e.legacy_profile.arg;
    e.legacy_profile = .{ .f = f, .arg = arg };
    db.profile = if (f != null) profileThunk else null;
    db.profile_arg = e;
    db.m_trace &= TRACE_NONLEGACY_MASK;
    if (f != null) db.m_trace |= TRACE_XPROFILE;
    return old;
}

const TRACE_LEGACY: u8 = 0x40;
const TRACE_XPROFILE: u8 = 0x80;
const TRACE_NONLEGACY_MASK: u8 = 0x0f;
