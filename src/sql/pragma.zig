//! PRAGMA statements (port of pragma.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Pragma().
pub fn pragma(p: *Parse, id1: int.Token, id2: int.Token, value: ?int.Token, minus: bool) void {
    _ = .{ id1, id2, value, minus };
    pending.notYet(p, "PRAGMA");
}
