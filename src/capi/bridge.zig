//! The C ABI's loader for connections it did not open: those of the Zig
//! API (Db.loadExtension()) and of the shell (`.load`).
//!
//! An extension calls back through sqlite3_api_routines, which is the C
//! ABI, and the C ABI keeps state of its own for each connection
//! (Sqlite3.capi, common.zig's Ext: the libraries loaded, the collations
//! C registered ...). The first load gives the connection that state
//! (with the default VFS's dl methods), and release() frees it once the
//! engine has closed the connection, as sqlite3_close() would.
//!
//! Using this file compiles the C ABI into the program: the sqlite3_*
//! exports the table points at. The build links the C part of the C ABI
//! (varargs.c, loadext.c) into every engine module as a static library,
//! whose objects are used only then.

const std = @import("std");
const c = @import("common.zig");

comptime {
    _ = @import("../capi.zig");
}

const RC = c.RC;

/// sqlite3_load_extension() of `file` (and the entry point `proc`, null
/// for the default one) into `db`, which need not have been opened by the
/// C ABI. The call is the authorization: it loads whether or not
/// extension loading is on (sqlite3_enable_load_extension()), which stays
/// as it was. On failure the message is the connection's error
/// (sqlite3_errmsg()), unlike sqlite3_load_extension(), which hands it to
/// the caller.
pub fn load(db: *c.Handle, file: [:0]const u8, proc: ?[:0]const u8) i32 {
    if (c.ensureInit()) |rc| return rc;
    if (db.capi == null) {
        const e = c.gpa.create(c.Ext) catch return nomem(db);
        e.* = .{ .vfs = @import("vfs.zig").find(null).? };
        db.capi = e;
    }
    const was_on = db.flags.LoadExtension;
    db.flags.LoadExtension = true;
    defer db.flags.LoadExtension = was_on;
    var err: ?[*:0]u8 = null;
    const rc = @import("loadext.zig").loadExtension(db, file.ptr, if (proc) |p| p.ptr else null, &err);
    if (rc == RC.OK) {
        c.main.errorClear(db);
        return rc;
    }
    defer if (err) |m| c.malloc.free(m);
    if (rc == RC.NOMEM) return nomem(db);
    c.main.errorWithMsg(db, rc, "{s}", .{std.mem.span(err orelse "unable to load extension")});
    return rc;
}

fn nomem(db: *c.Handle) i32 {
    db.oomFault();
    return RC.NOMEM;
}

/// Free the C ABI's state `ext` of a connection (Sqlite3.capi, which
/// load() set) after the engine has closed it: the libraries it loaded
/// are closed last, as sqlite3_close() closes them.
pub fn release(ext: *anyopaque) void {
    @import("conn.zig").freeExt(@ptrCast(@alignCast(ext)));
}

/// Close `db` (sql.main.close()), then release() its C ABI state, if a
/// load gave it some. Returns sql.main.close()'s result code; on
/// SQLITE_BUSY the connection and its state stay.
pub fn close(db: *c.Handle) i32 {
    const ext = db.capi;
    const rc = c.main.close(db);
    if (rc == RC.OK) if (ext) |e| release(e);
    return rc;
}
