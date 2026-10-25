//! Statement code generation that is not ported yet. Builders reached by
//! the parser call `notYet`, which fails the statement unless the parse
//! only checks syntax.

const int = @import("sqlite_int.zig");
const util = @import("util.zig");

pub fn notYet(p: *int.Parse, what: []const u8) void {
    if (p.syntax_only or p.n_err != 0) return;
    util.errorMsg(p, "not supported yet: {s}", .{what});
}
