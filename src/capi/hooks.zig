//! The commit, rollback, update and progress hooks.

const c = @import("common.zig");

/// Install (or remove) the engine's side of the hooks of `db` after C
/// changed them.
pub fn sync(db: *c.Handle) void {
    _ = db;
}
