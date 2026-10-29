//! Checks that src/ has no hidden global state: a mutable container-level
//! variable (a `var` at the top of a file or among the declarations of a
//! struct, which lives as long as the process) must be one that `allowed`
//! lists. Tests (test declarations and *_test.zig files) may keep state of
//! their own. Run by `zig build test`, from the build root.

const std = @import("std");
const Ast = std.zig.Ast;

/// The process-wide variables there are, by file and name.
const allowed = [_]struct { []const u8, []const u8 }{
    // sqlite3GlobalConfig, mem0 and sqlite3Prng.
    .{ "src/sql/global.zig", "config" },
    .{ "src/sql/global.zig", "heap_limit" },
    .{ "src/sql/global.zig", "prng" },
    // The POSIX lock table, which every connection has to share.
    .{ "src/vfs/unix.zig", "inodes" },
    // typeId(): an address per type, never read or written (a `const`
    // could be merged with another).
    .{ "src/api/Stmt.zig", "id" },
    // The fuzz case running, for the panic handler of `xqlite fuzzcheck`.
    .{ "src/fuzzcheck.zig", "current" },
};

fn isAllowed(path: []const u8, name: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a[0], path) and std.mem.eql(u8, a[1], name)) return true;
    }
    return false;
}

/// Appends a line to `out` for each container-level `var` of `tree`
/// outside a test that `allowed` does not list.
fn check(gpa: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, tree: *const Ast) !void {
    // The tokens of each test declaration.
    var tests: std.ArrayList([2]Ast.TokenIndex) = .empty;
    defer tests.deinit(gpa);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) == .test_decl) try tests.append(gpa, .{ tree.firstToken(node), tree.lastToken(node) });
    }
    for (0..tree.nodes.len) |i| {
        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, @enumFromInt(i)) orelse continue;
        for (container.ast.members) |member| {
            const v = tree.fullVarDecl(member) orelse continue;
            if (tree.tokenTag(v.ast.mut_token) != .keyword_var) continue;
            const in_test = for (tests.items) |t| {
                if (v.ast.mut_token >= t[0] and v.ast.mut_token <= t[1]) break true;
            } else false;
            if (in_test) continue;
            const name = tree.tokenSlice(v.ast.mut_token + 1);
            if (isAllowed(path, name)) continue;
            const loc = tree.tokenLocation(0, v.ast.mut_token);
            try out.print(gpa, "{s}:{d}: var {s}\n", .{ path, loc.line + 1, name });
        }
    }
}

test "no hidden global state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    var found: std.ArrayList(u8) = .empty;
    defer found.deinit(gpa);
    var n_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
        const text = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(text);
        var tree = try Ast.parse(gpa, text, .{});
        defer tree.deinit(gpa);
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        try check(gpa, &found, path, &tree);
        n_files += 1;
    }
    try std.testing.expect(n_files > 50);
    if (found.items.len > 0) {
        std.debug.print("mutable globals not in tools/globals_test.zig:\n{s}", .{found.items});
        return error.HiddenGlobalState;
    }
}
