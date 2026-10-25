//! UPDATE statements (port of update.c).

const int = @import("sqlite_int.zig");
const pending = @import("pending.zig");

const Parse = int.Parse;

/// Port of sqlite3Update().
pub fn update(p: *Parse, tab_list: ?*int.SrcList, changes: ?*int.ExprList, where: ?*int.Expr, on_error: i32, order_by: ?*int.ExprList, limit: ?*int.Expr, upsert: ?*int.Upsert) void {
    _ = .{ tab_list, changes, where, on_error, order_by, limit, upsert };
    pending.notYet(p, "UPDATE");
}
