//! Calling SQL functions from the VM (sqlite3_context and the callbacks
//! of FuncDef).

const vi = @import("vdbe_int.zig");
const int = @import("../sql/sqlite_int.zig");

/// Run the finalizer of an aggregate.
pub fn callFinalize(f: *const int.FuncDef, ctx: *vi.Context) void {
    f.x_finalize.?(ctx);
}

/// Run the xValue method of a window aggregate.
pub fn callValue(f: *const int.FuncDef, ctx: *vi.Context) void {
    f.x_value.?(ctx);
}
