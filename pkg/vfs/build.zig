//! xqlite_vfs, the OS abstraction layer of xqlite, as a package of its
//! own: the module `xqlite_vfs` (src/root.zig) and its tests.
//!
//! The root build (../../build.zig) takes it as a path dependency, once
//! per target, with `target` and `optimize` as arguments. The module's
//! optimization mode is the importing compilation's; `optimize` only
//! picks that of the tests here. `zig build test` in this directory runs
//! the tests alone.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this text") orelse &.{};

    const mod = b.addModule("xqlite_vfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // libc provides fcntl() byte-range locks for the unix VFS (and
        // wasi-libc the clock on wasm32-wasi); wasm32-freestanding has
        // none (the host VFS calls its imports instead).
        .link_libc = target.result.os.tag != .freestanding,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = mod.link_libc,
        }),
        .filters = test_filters,
    });
    b.step("test", "Run the VFS tests").dependOn(&b.addRunArtifact(tests).step);
}
