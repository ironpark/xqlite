//! The few things the engine asks of the platform outside the VFS: the
//! clock, the environment, the local time zone and 64-bit atomics. Each is
//! a comptime choice of the target, so a native build compiles to what it
//! did before (the C library), and WebAssembly gets what it has:
//!
//! - wasm32-wasi links wasi-libc, which has clock_gettime(), getenv() and
//!   localtime_r() (always UTC: WASI has no time zones).
//! - wasm32-freestanding has no C library: the clock is the host's
//!   (`xq_host_now_ms`, an import of module "env"), there is no
//!   environment, and local time is UTC.
//! - wasm32 cannot do 64-bit atomic operations without the atomics
//!   feature; single-threaded builds use plain loads and stores.

const std = @import("std");
const builtin = @import("builtin");

/// A WebAssembly target (wasm32 or wasm64).
pub const is_wasm = builtin.cpu.arch.isWasm();
/// No operating system and no C library: wasm32-freestanding, a browser
/// or another embedder supplies the host functions (src/wasm.zig).
pub const freestanding = builtin.os.tag == .freestanding;
/// Whether the C library is linked (the clock, the environment, localtime_r()).
pub const has_libc = builtin.link_libc;

/// The host's clock, milliseconds since 1970-01-01 UTC (Date.now() in
/// JavaScript). Only freestanding builds import it.
extern "env" fn xq_host_now_ms() f64;

/// The current time, as seconds and nanoseconds since 1970-01-01 UTC
/// (clock_gettime(CLOCK_REALTIME)).
pub fn now() struct { sec: i64, nsec: i64 } {
    if (has_libc) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
    }
    if (freestanding) {
        const ms: i64 = @intFromFloat(@floor(xq_host_now_ms()));
        return .{ .sec = @divFloor(ms, 1000), .nsec = @mod(ms, 1000) * std.time.ns_per_ms };
    }
    @compileError("xqlite: no clock on this target without the C library");
}

/// getenv(): null where there is no environment (freestanding).
pub fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
    if (has_libc) return std.c.getenv(name);
    return null;
}

/// Whether `std.atomic.Value(T)` works on this target: wasm32 has no
/// 64-bit atomics unless built with the atomics feature.
fn hasAtomic(comptime T: type) bool {
    return !(is_wasm and @bitSizeOf(T) > @bitSizeOf(usize) and builtin.single_threaded);
}

/// `std.atomic.Value(T)`, or, where the target cannot do atomic
/// operations on `T` and the build is single-threaded, a plain variable
/// with the same methods.
pub fn Atomic(comptime T: type) type {
    if (hasAtomic(T)) return std.atomic.Value(T);
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }

        pub fn load(self: *const Self, comptime _: std.builtin.AtomicOrder) T {
            return self.raw;
        }

        pub fn store(self: *Self, v: T, comptime _: std.builtin.AtomicOrder) void {
            self.raw = v;
        }
    };
}

test Atomic {
    var a: Atomic(i64) = .init(5);
    a.store(7, .monotonic);
    try std.testing.expectEqual(7, a.load(.monotonic));
}
