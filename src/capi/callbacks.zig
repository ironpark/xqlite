//! The callbacks the engine calls while it compiles and runs statements:
//! the authorizer, the collation-needed callback and the autovacuum-pages
//! callback. As for the other hooks (hooks.zig), the engine calls a Zig
//! function with the connection's Ext as its argument, and that calls
//! the C callback.

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
