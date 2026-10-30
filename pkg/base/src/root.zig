//! xqlite_base: what every layer of xqlite shares and none owns, a
//! package of its own below xqlite_storage and the engine. It imports
//! only std. One file belongs to one module, so a helper the storage
//! package and the engine both use lives here and both import it.

/// Closures: a function and its context, for callbacks.
pub const thunk = @import("thunk.zig");
/// The status counters of the library (sqlite3_status()), which the page
/// cache and the engine's allocator update.
pub const status = @import("status.zig");
/// Helpers of the seeded fuzzers (src/fuzz_tests.zig and the b-tree
/// fuzzers of the storage package).
pub const fuzz = @import("fuzz.zig");

test {
    @import("std").testing.refAllDecls(@This());
    inline for (.{ thunk, status, fuzz }) |file| {
        @import("std").testing.refAllDecls(file);
    }
}
