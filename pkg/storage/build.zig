//! xqlite_storage, the storage layer of xqlite (pager, page cache, WAL,
//! b-tree), as a package of its own: the module `xqlite_storage`
//! (src/root.zig) and its tests.
//!
//! It imports `xqlite_vfs` and `xqlite_base`, from the path dependencies
//! ../vfs and ../base. The root build (../../build.zig) takes this
//! package as a path dependency too, once per target, with `target` and
//! `optimize` as arguments, the same as its own dependencies on the other
//! two: the build system then shares one xqlite_vfs and one xqlite_base
//! between them. The module's optimization mode is the
//! importing compilation's; `optimize` only picks that of the tests here.
//! `zig build test` in this directory runs the tests alone.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this text") orelse &.{};

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "xqlite_vfs", .module = b.dependency("xqlite_vfs", .{ .target = target, .optimize = optimize }).module("xqlite_vfs") },
        .{ .name = "xqlite_base", .module = b.dependency("xqlite_base", .{ .target = target, .optimize = optimize }).module("xqlite_base") },
    };
    _ = b.addModule("xqlite_storage", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = imports,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
        .filters = test_filters,
    });
    const test_step = b.step("test", "Run the storage tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The journal's checksums once more, optimized: Zig 0.17 compiled one
    // of them wrong in optimized builds only (see superNameChecksum() in
    // src/pager/journal.zig), which Debug tests cannot see. The root
    // build runs that test too.
    const journal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pager/journal.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(journal_tests).step);
}
