//! PostgreSQL's text forms that the PostgreSQL dialect and the wire
//! server share, with no dependency but std.

/// Arrays: array_in()'s syntax read, array_out()'s written.
pub const array = @import("array.zig");

test {
    _ = array;
}
