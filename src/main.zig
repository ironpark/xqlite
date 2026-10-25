const std = @import("std");
const Io = std.Io;

const xqlite = @import("xqlite");
const Header = xqlite.btree.header.Header;

const usage =
    \\usage: xqlite <command> [args]
    \\
    \\commands:
    \\  dbinfo <file>   print the database file header
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len == 3 and std.mem.eql(u8, args[1], "dbinfo")) {
        try dbinfo(arena, io, args[2], out);
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
}

fn dbinfo(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const vfs = unix.interface();
    const file = try vfs.open(path, .{ .read_write = false });
    defer file.close();

    try file.lock(.shared);

    var buf: [xqlite.btree.header.size]u8 = undefined;
    try file.read(&buf, 0);
    const h = try Header.parse(&buf);
    const file_size = try file.fileSize();

    const fields = .{
        .{ "page size", h.page_size },
        .{ "write format", @intFromEnum(h.write_version) },
        .{ "read format", @intFromEnum(h.read_version) },
        .{ "reserved bytes", h.reserved_space },
        .{ "file change counter", h.file_change_counter },
        .{ "database page count", h.database_size },
        .{ "freelist page count", h.freelist_count },
        .{ "schema cookie", h.schema_cookie },
        .{ "schema format", h.schema_format },
        .{ "default cache size", h.default_cache_size },
        .{ "autovacuum top root", h.largest_root_page },
        .{ "incremental vacuum", h.incremental_vacuum },
        .{ "text encoding", @intFromEnum(h.text_encoding) },
        .{ "user version", h.user_version },
        .{ "application id", h.application_id },
        .{ "software version", h.sqlite_version },
    };
    inline for (fields) |f| try out.print("{s:<20} {d}\n", .{ f[0], f[1] });
    try out.print("{s:<20} {d}\n", .{ "file size", file_size });
}
