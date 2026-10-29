//! xqt: the test tool of xqlite. It runs xqlite next to sqlite3 and
//! compares them; see tools/xqt/README.md and docs/testing.md.

const std = @import("std");
const Io = std.Io;
const xqt = @import("xqt");
const build_options = @import("build_options");

const interop = @import("interop.zig");
const planner = @import("planner.zig");

const usage =
    \\usage: xqt [options] <command> [args]
    \\
    \\commands:
    \\  interop [NAME...]        cross-checks against sqlite3 (all, or the modules named)
    \\  planner [FILE...]        results, query plans and bytecode against sqlite3
    \\  list                     the interop modules and planner case files
    \\  help [COMMAND]           this text, or the options of a command
    \\
++ xqt.Config.usage;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var rest: std.ArrayList([]const u8) = .empty;
    const cfg = xqt.Config.parse(arena, io, init.environ_map, build_options.root, args[1..], &rest) catch |err| switch (err) {
        error.Usage => return exit(out, 2, usage),
        else => |e| return e,
    };
    if (rest.items.len == 0) return exit(out, 2, usage);
    const cmd = rest.items[0];
    const cmd_args = rest.items[1..];
    const code: u8 = if (std.mem.eql(u8, cmd, "interop"))
        try interop.run(init.gpa, io, &cfg, out, cmd_args)
    else if (std.mem.eql(u8, cmd, "planner"))
        try planner.run(init.gpa, io, &cfg, out, cmd_args)
    else if (std.mem.eql(u8, cmd, "list"))
        try list(io, &cfg, out)
    else if (std.mem.eql(u8, cmd, "help")) blk: {
        const topic = if (cmd_args.len > 0) cmd_args[0] else "";
        try out.writeAll(if (std.mem.eql(u8, topic, "interop"))
            interop.usage
        else if (std.mem.eql(u8, topic, "planner"))
            planner.usage
        else
            usage);
        break :blk 0;
    } else return exit(out, 2, usage);
    try out.flush();
    std.process.exit(code);
}

fn exit(out: *Io.Writer, code: u8, text: []const u8) !void {
    try out.writeAll(text);
    try out.flush();
    std.process.exit(code);
}

fn list(io: Io, cfg: *const xqt.Config, out: *Io.Writer) !u8 {
    try out.writeAll("interop modules (xqt interop NAME):\n");
    try interop.list(out);
    try out.writeAll("planner case files (xqt planner; vtablog.txt only by name):\n");
    const dir_path = try std.fs.path.join(std.heap.page_allocator, &.{ cfg.root, "tools", "planner" });
    defer std.heap.page_allocator.free(dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| std.heap.page_allocator.free(n);
        names.deinit(std.heap.page_allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".txt"))
            try names.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f);
    for (names.items) |n| try out.print("  tools/planner/{s}\n", .{n});
    try out.print("binaries:\n  xq        {s}\n  sqlite3   {s}\n  sq        {s}\n  crashshim {s}\n", .{ cfg.xq, cfg.sqlite3, cfg.sq, cfg.crashshim });
    return 0;
}

test {
    _ = xqt;
    _ = planner;
    _ = interop;
}
