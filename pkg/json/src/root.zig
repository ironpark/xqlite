//! JSON the dialects share, with no dependency but std.

/// JSON string escaping, the options chosen at compile time.
pub const text = @import("text.zig");
/// SQLite's JSONB: reading, validating and writing its nodes.
pub const jsonb = @import("jsonb.zig");

test {
    _ = text;
    _ = jsonb;
}
