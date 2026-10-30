//! Checks that src/ and tools/xqt/ have no hidden global state: a mutable
//! container-level variable (a `var` at the top of a file or among the
//! declarations of a struct, which lives as long as the process) must be
//! one that `allowed` lists. Tests (test declarations and *_test.zig files) may keep state of
//! their own. Run by `zig build test`, from the build root.

const std = @import("std");
const Ast = std.zig.Ast;

/// The process-wide variables there are, by file and name.
const allowed = [_]struct { []const u8, []const u8 }{
    // sqlite3GlobalConfig, mem0 and sqlite3Prng.
    .{ "src/sql/global.zig", "config" },
    .{ "src/sql/global.zig", "heap_limit" },
    .{ "src/sql/global.zig", "prng" },
    // The C ABI's VFS registry, for ATTACH's vfs= parameter.
    .{ "src/sql/global.zig", "find_vfs" },
    // The shared stores of the memdb VFS (memdb_g) and its settings.
    .{ "src/vfs/memdb.zig", "state" },
    // The POSIX lock table, which every connection has to share.
    .{ "src/vfs/unix.zig", "inodes" },
    // The C ABI's process-wide state (sqlite3_config(), the auto
    // extensions), its VFS list, the sqlite3_str of a failed
    // sqlite3_str_new() and the variables sqlite3.h declares.
    .{ "src/capi/common.zig", "state" },
    .{ "src/capi/vfs.zig", "unix_vfs" },
    .{ "src/capi/vfs.zig", "unix_c" },
    .{ "src/capi/vfs.zig", "unix_entry" },
    .{ "src/capi/vfs.zig", "head" },
    .{ "src/capi/vfs.zig", "all_entries" },
    .{ "src/capi/printf.zig", "oom_str" },
    .{ "src/capi/library.zig", "sqlite3_temp_directory" },
    .{ "src/capi/library.zig", "sqlite3_data_directory" },
    // The in-process lock tables of the WASI and host VFSes, for the same
    // reason (WASI has no locks the system arbitrates).
    .{ "src/vfs/wasi.zig", "files" },
    .{ "src/vfs/host.zig", "files" },
    // The file systems the connections of the wasm module share.
    .{ "src/wasm/api.zig", "mem_vfs" },
    .{ "src/wasm/api.zig", "host_vfs" },
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
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .test_decl) try tests.append(gpa, .{ tree.firstToken(node), tree.lastToken(node) });
    }
    for (0..tree.nodes.len) |i| {
        var buf: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, @fromBackingInt(@intCast(i))) orelse continue;
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
    var found: std.ArrayList(u8) = .empty;
    defer found.deinit(gpa);
    try std.testing.expect(try scan(gpa, "src", &found) > 50);
    // The test tool, which runs its checks on threads.
    try std.testing.expect(try scan(gpa, "tools/xqt", &found) > 5);
    if (found.items.len > 0) {
        std.debug.print("mutable globals not in tools/globals_test.zig:\n{s}", .{found.items});
        return error.HiddenGlobalState;
    }
}

/// Checks the .zig files under `root`; returns how many.
fn scan(gpa: std.mem.Allocator, root: []const u8, found: *std.ArrayList(u8)) !usize {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var n_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
        const text = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(text);
        var tree = try Ast.parse(gpa, text, .{});
        defer tree.deinit(gpa);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.path });
        defer gpa.free(path);
        try check(gpa, found, path, &tree);
        n_files += 1;
    }
    return n_files;
}
