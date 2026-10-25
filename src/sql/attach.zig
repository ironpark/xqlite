//! ATTACH and DETACH (port of attach.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Attach().
pub fn attach(p: *Parse, file: ?*int.Expr, dbname: ?*int.Expr, key: ?*int.Expr) void {
    _ = .{ file, dbname, key };
    pending.notYet(p, "ATTACH");
}

/// Port of sqlite3Detach().
pub fn detach(p: *Parse, dbname: ?*int.Expr) void {
    _ = .{ dbname };
    pending.notYet(p, "DETACH");
}
