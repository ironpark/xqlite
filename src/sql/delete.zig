//! DELETE statements (port of delete.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3DeleteFrom().
pub fn deleteFrom(p: *Parse, tab_list: ?*int.SrcList, where: ?*int.Expr, order_by: ?*int.ExprList, limit: ?*int.Expr) void {
    _ = .{ tab_list, where, order_by, limit };
    pending.notYet(p, "DELETE");
}
