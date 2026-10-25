//! VACUUM (port of vacuum.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Vacuum().
pub fn vacuum(p: *Parse, name: ?int.Token, into: ?*int.Expr) void {
    _ = .{ name, into };
    pending.notYet(p, "VACUUM");
}
