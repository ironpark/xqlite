//! The library of xqt, the test tool of xqlite (tools/xqt/README.md):
//! checks that run xqlite and sqlite3 side by side on a work pool.
//! Commands and modules import it as `@import("xqt")`.

pub const Config = @import("Config.zig");
pub const Suite = @import("Suite.zig");
pub const Check = @import("Check.zig");
pub const proc = @import("proc.zig");
pub const diff = @import("diff.zig");
pub const pool = @import("pool.zig");
pub const crash = @import("crash.zig");

test {
    _ = diff;
    _ = pool;
}
