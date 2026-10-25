//! Virtual tables (port of vtab.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3VtabBeginParse().
pub fn beginParse(p: *Parse, name1: int.Token, name2: int.Token, module_name: int.Token, if_not_exists: bool) void {
    _ = .{ name1, name2, module_name, if_not_exists };
    pending.notYet(p, "CREATE VIRTUAL TABLE");
}

/// Port of sqlite3VtabFinishParse().
pub fn finishParse(p: *Parse, end: ?int.Token) void {
    _ = .{ p, end };
}

/// Port of sqlite3VtabArgInit().
pub fn argInit(p: *Parse) void {
    _ = .{ p };
}

/// Port of sqlite3VtabArgExtend().
pub fn argExtend(p: *Parse, t: int.Token) void {
    _ = .{ p, t };
}
