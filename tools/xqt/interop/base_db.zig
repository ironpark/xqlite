//! A database the checks of a module share as their starting point: the
//! first check to ask builds it in its own directory, the others wait and
//! get a copy of its bytes. The old scripts built one file and ran their
//! steps on it in turn; here each step is a check of its own, on its own
//! copy, and the build (seconds in a Debug xqlite) still runs once.
//!
//!     pub fn register(s: *xqt.Suite) !void {
//!         const base = try s.arena.allocator().create(BaseDb);
//!         base.* = .{ .build = build };
//!         try s.add("...", check, .{base});
//!     }
//!     fn check(c: *Check, base: *BaseDb) !void {
//!         try base.get(c, "pg.db");
//!         ...
//!     }

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

const BaseDb = @This();

/// Makes the database `db` in the check's directory.
build: *const fn (c: *Check, db: []const u8) anyerror!void,
mutex: std.Io.Mutex = .init,
state: enum { todo, built, failed } = .todo,
/// The built file, in the `keep` arena of the check that built it.
bytes: []const u8 = "",

/// Writes the database to `db` in the check's directory, building it
/// first if no check has. If the build failed, so does this check.
pub fn get(base: *BaseDb, c: *Check, db: []const u8) !void {
    base.mutex.lockUncancelable(c.io);
    defer base.mutex.unlock(c.io);
    switch (base.state) {
        .built => return c.writeFile(db, base.bytes),
        .failed => return c.abort("the database could not be built (see the check that built it)", .{}),
        .todo => {
            base.state = .failed;
            try base.build(c, db);
            base.bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, try c.path(db), c.keep, .unlimited);
            base.state = .built;
        },
    }
}
