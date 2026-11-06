//! PostgreSQL's regular expressions, with no dependency but std.

/// The advanced regular expressions (AREs) of Henry Spencer's engine: the
/// `~` operators, SIMILAR TO and the regexp_*() functions.
pub const are = @import("are.zig");
/// The older, smaller engine (a Pike VM): xq_pg_regex() of older schemas
/// and jsonpath's like_regex.
pub const pike = @import("pike.zig");

test {
    _ = are;
    _ = pike;
}
