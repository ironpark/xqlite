//! The process-wide state of the library (global.c): what C keeps in
//! sqlite3GlobalConfig, mem0 and sqlite3Prng. These are process-wide in
//! SQLite too: sqlite3_config(), the heap limits and sqlite3_randomness()
//! act on every connection at once. Everything else belongs to a
//! connection or is read-only (the built-in functions are a compile-time
//! table, callback.builtins); tools/globals_test.zig lists the few other
//! process-wide variables, such as the POSIX lock table of vfs/unix.zig.

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
