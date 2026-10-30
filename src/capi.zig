//! The sqlite3-compatible C ABI: the root of libxqlite3 (`zig build`,
//! see docs/c-api.md). It exports the sqlite3_* functions of SQLite
//! 3.54.1's sqlite3.h (include/sqlite3.h) with C calling convention, on
//! the engine's own SQLite-shaped interfaces (sql/main.zig,
//! vdbe/api.zig ...). The variadic functions and sqlite3_mutex_*() are
//! in src/capi/varargs.c, which the build compiles with it.
//!
//! A sqlite3* is the engine's connection, sqlite3_stmt* its statement,
//! sqlite3_value* and sqlite3_context* its Mem and Context; the C ABI's
//! own state for a connection hangs off Sqlite3.capi (capi/common.zig).

comptime {
    _ = @import("capi/library.zig");
    _ = @import("capi/conn.zig");
    _ = @import("capi/stmt.zig");
    _ = @import("capi/func.zig");
    _ = @import("capi/printf.zig");
    _ = @import("capi/vtab.zig");
    _ = @import("capi/vfs.zig");
    _ = @import("capi/filename.zig");
    _ = @import("capi/blob.zig");
    _ = @import("capi/loadext.zig");
    _ = @import("capi/carray.zig");
}
