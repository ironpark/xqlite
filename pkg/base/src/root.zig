//! xqlite_base: what every layer of xqlite shares and none owns, a
//! package of its own below xqlite_storage and the engine. It imports
//! only std. One file belongs to one module, so a helper the storage
//! package and the engine both use lives here and both import it, as do
//! the engine's helpers that need nothing of the engine (character
//! classes, number conversions), so that a package can use them too.

/// Closures: a function and its context, for callbacks.
pub const thunk = @import("thunk.zig");
/// The status counters of the library (sqlite3_status()), which the page
/// cache and the engine's allocator update.
pub const status = @import("status.zig");
/// Helpers of the seeded fuzzers (src/fuzz_tests.zig and the b-tree
/// fuzzers of the storage package).
pub const fuzz = @import("fuzz.zig");
/// SQLite's locale-independent character classes (sqlite3CtypeMap).
pub const ctype = @import("ctype.zig");
/// Conversions between numbers and text (util.c's sqlite3AtoF() and
/// friends).
pub const numeric = @import("numeric.zig");
/// The element order of SQLite's Hash (hash.c).
pub const hash = @import("hash.zig");
/// Operations shared by the bit-flag sets (packed structs of bools).
pub const flags = @import("flags.zig");
/// Narrowing casts that work around a Zig 0.17 miscompilation.
pub const cast = @import("cast.zig");

test {
    @import("std").testing.refAllDecls(@This());
    inline for (.{ thunk, status, fuzz, ctype, numeric, hash, flags, cast }) |file| {
        @import("std").testing.refAllDecls(file);
    }
}
