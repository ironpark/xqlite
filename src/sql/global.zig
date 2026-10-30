//! The process-wide state of the library (global.c): what C keeps in
//! sqlite3GlobalConfig, mem0 and sqlite3Prng. These are process-wide in
//! SQLite too: sqlite3_config(), the heap limits and sqlite3_randomness()
//! act on every connection at once. Everything else belongs to a
//! connection or is read-only (the built-in functions are a compile-time
//! table, callback.builtins); tools/globals_test.zig lists the few other
//! process-wide variables, such as the POSIX lock table of the unix VFS.

const std = @import("std");
const malloc = @import("malloc.zig");
const func = @import("func.zig");
const Atomic = @import("../util/platform.zig").Atomic;

// Separate variables, not one struct: a program that never calls
// sqlite3_config() never writes `config`, so the compiler can treat the
// allocator as a constant and call malloc() and free() directly.

/// The memory settings of sqlite3GlobalConfig (sqlite3_config()).
pub var config: malloc.Config = .{};

/// mem0.alarmThreshold and mem0.hardLimit (main.softHeapLimit64()). Memory
/// comes from the application's allocator, so they are only recorded, not
/// enforced.
pub var heap_limit: struct {
    soft: Atomic(i64) = .init(0),
    hard: Atomic(i64) = .init(0),
} = .{};

/// sqlite3Prng: the generator behind sqlite3_randomness().
pub var prng: func.Prng = .{};

// sqlite3_temp_directory is the VFS package's (temp_directory of
// vfs/root.zig), which PRAGMA temp_store_directory and the C ABI set.

/// sqlite3_data_directory: in SQLite, the base of relative file names on
/// Windows only (and PRAGMA data_store_directory, also Windows only).
/// Exported by the C ABI; nothing reads it on the systems xqlite runs on.
pub var data_directory: ?[*:0]u8 = null;

/// The knobs of sqlite3_test_control() that act on the engine (C: the
/// test fields of sqlite3GlobalConfig, and sqlite3SavedPrng).
pub var testctrl: TestCtrl = .{};

pub const TestCtrl = struct {
    /// SQLITE_TESTCTRL_LOCALTIME_FAULT: nonzero makes localtime() fail,
    /// or (2) call `alt_localtime` instead (bLocaltimeFault,
    /// xAltLocaltime).
    localtime_fault: i32 = 0,
    alt_localtime: ?*const fn (t: *const anyopaque, tm: *anyopaque) callconv(.c) c_int = null,
    /// SQLITE_TESTCTRL_ONCE_RESET_THRESHOLD (iOnceResetThreshold).
    once_reset_threshold: i32 = 0x7ffffffe,
    /// SQLITE_TESTCTRL_PRNG_SEED (iPrngSeed): seeds the PRNG instead of
    /// the VFS when nonzero.
    prng_seed: u32 = 0,
    /// SQLITE_TESTCTRL_PRNG_SAVE (sqlite3SavedPrng).
    saved_s: [16]u32 = @splat(0),
    saved_out: [64]u8 = @splat(0),
    saved_n: u8 = 0,
};
/// The VFS registry of the C ABI (sqlite3_vfs_find()), which resolves a
/// URI's "vfs" parameter in ATTACH (OpenFlags.vfs_resolved). Null without
/// a registry: ATTACH uses the connection's VFS.
pub var find_vfs: ?*const fn (name: []const u8) ?@import("../vfs/vfs.zig").Vfs = null;

/// How the load_extension() SQL function loads a library: set by the C
/// ABI (sqlite3LoadExtension(), which needs the C VFS's xDlOpen and the
/// sqlite3_api_routines table). Null without it: the function then
/// fails. Returns null on success, else the error message (from
/// sqlite3_malloc()).
pub var load_extension: ?*const fn (db: *@import("sqlite_int.zig").Sqlite3, file: [:0]const u8, proc: ?[:0]const u8) ?[*:0]u8 = null;
