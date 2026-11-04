//! sqlparse, what the dialects' SQL parsers share below the syntax tree
//! (token sources, the cursor, the error record, sets of words) as a
//! package of its own: the module `sqlparse` (src/root.zig) and its
//! tests. It depends on std and sqllex (../sqllex).
//!
//! The root build (../../build.zig) takes it as a path dependency, once
//! per target, with `target` and `optimize` as arguments, as it takes
//! sqllex, so that both use the same sqllex module. `zig build test` in
//! this directory runs the tests alone.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this text") orelse &.{};
    const sqllex = b.dependency("sqllex", .{ .target = target, .optimize = optimize }).module("sqllex");

    _ = b.addModule("sqlparse", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "sqllex", .module = sqllex }},
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sqllex", .module = sqllex }},
        }),
        .filters = test_filters,
    });
    b.step("test", "Run the sqlparse tests").dependOn(&b.addRunArtifact(tests).step);
}
