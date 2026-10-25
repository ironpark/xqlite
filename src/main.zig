const std = @import("std");
const Io = std.Io;

const xqlite = @import("xqlite");
const Header = xqlite.btree.header.Header;

const usage =
    \\usage: xqlite <command> [args]
    \\
    \\commands:
    \\  dbinfo <file>             print the database file header
    \\  recover <file>            open the database, rolling back a hot journal
    \\  crash-write <file> <byte> overwrite every page, then exit after commit
    \\                            phase one, leaving a hot journal (testing aid)
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
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "recover")) {
        try recover(arena, io, args[2], out);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "crash-write")) {
        const fill = try std.fmt.parseInt(u8, args[3], 0);
        try crashWrite(arena, io, args[2], fill);
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

/// Takes a read lock, which rolls back any hot journal, then adopts the page
/// size from the (recovered) header. The btree layer will own this later.
fn lockAndAdoptHeader(p: *xqlite.pager.Pager) !void {
    try p.sharedLock();
    var buf: [xqlite.btree.header.size]u8 = undefined;
    try p.readFileHeader(&buf);
    const h = try Header.parse(&buf);
    try p.setPageSize(h.page_size, h.reserved_space);
}

fn recover(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const v = unix.interface();
    const p = try xqlite.pager.Pager.open(gpa, v, path, .{ .create = false });
    defer p.close();

    const had_journal = try v.access(p.journal_path, .exists);
    try lockAndAdoptHeader(p);
    const p1 = try p.get(1, .{});
    defer p.unrefPageOne(p1);
    try out.print("pages {d}, page size {d}, journal {s}\n", .{
        p.pageCount(),
        p.page_size,
        if (!had_journal) "absent" else if (try v.access(p.journal_path, .exists)) "kept" else "rolled back",
    });
}

fn crashWrite(gpa: std.mem.Allocator, io: Io, path: []const u8, fill: u8) !void {
    var unix = xqlite.UnixVfs.init(gpa, io);
    const p = try xqlite.pager.Pager.open(gpa, unix.interface(), path, .{ .create = false });
    try lockAndAdoptHeader(p);
    const p1 = try p.get(1, .{});
    try p.begin(false);
    try p.write(p1);
    @memset(p1.data, fill);
    var pgno: xqlite.pager.Pgno = 2;
    while (pgno <= p.pageCount()) : (pgno += 1) {
        if (p.isLockPage(pgno)) continue;
        const pg = try p.get(pgno, .{});
        defer p.unref(pg);
        try p.write(pg);
        @memset(pg.data, fill);
    }
    try p.commitPhaseOne(false);
    // Simulated power loss: no phase two, no unlock. The OS drops the locks.
    std.process.exit(0);
}
