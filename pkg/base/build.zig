//! xqlite_base, the helpers every layer of xqlite shares (closures, the
//! status counters, fuzzing helpers), as a package of its own: the module
//! `xqlite_base` (src/root.zig) and its tests.
//!
//! The storage package and the root build (../../build.zig) take it as a
//! path dependency, once per target, with `target` and `optimize` as
//! arguments, so that they share one module. `optimize` only picks the
//! optimization mode of the tests here. `zig build test` in this
//! directory runs the tests alone.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this text") orelse &.{};

    _ = b.addModule("xqlite_base", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    b.step("test", "Run the base tests").dependOn(&b.addRunArtifact(tests).step);
}
