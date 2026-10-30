//! The commit, rollback and update hooks and the progress handler: the
//! engine calls Zig functions (Sqlite3.commit_hook ...) with the
//! connection's Ext as their argument, and these call the C callbacks.

const c = @import("common.zig");

fn extOf(arg: ?*anyopaque) *c.Ext {
    return @ptrCast(@alignCast(arg.?));
}

fn commitThunk(arg: ?*anyopaque) i32 {
    const e = extOf(arg);
    return e.commit.f.?(e.commit.arg);
}

fn rollbackThunk(arg: ?*anyopaque) void {
    const e = extOf(arg);
    e.rollback.f.?(e.rollback.arg);
}

fn updateThunk(arg: ?*anyopaque, op: i32, db_name: [:0]const u8, table: [:0]const u8, rowid: i64) void {
    const e = extOf(arg);
    e.update.f.?(e.update.arg, op, db_name.ptr, table.ptr, rowid);
}

fn progressThunk(arg: ?*anyopaque) i32 {
    const e = extOf(arg);
    return e.progress.f.?(e.progress.arg);
}

/// Install (or remove) the engine's side of the hooks of `db` after C
/// changed them.
pub fn sync(db: *c.Handle) void {
    const e = c.ext(db);
    db.commit_hook = if (e.commit.f != null) commitThunk else null;
    db.commit_arg = e;
    db.rollback_hook = if (e.rollback.f != null) rollbackThunk else null;
    db.rollback_arg = e;
    db.update_hook = if (e.update.f != null) updateThunk else null;
    db.update_arg = e;
    db.progress = if (e.progress.f != null) progressThunk else null;
    db.progress_arg = e;
    db.n_progress_ops = @intCast(@max(e.n_progress_ops, 0));
}
