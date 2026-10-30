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
