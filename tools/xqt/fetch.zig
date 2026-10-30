//! `xqt fetch sqlite|slt [--dest DIR]`: downloads the reference sources
//! into ref/ (git-ignored).
//!
//! - sqlite: the canonical SQLite source tree used as the porting
//!   reference, from https://www.sqlite.org/YEAR/sqlite-src-VERSION.zip,
//!   into ref/sqlite, with the version in ref/sqlite/.xqlite-version.
//!   $SQLITE_VERSION and $SQLITE_YEAR choose another release. The download
//!   (std.http) and the unzipping (std.zip, then the Unix modes the
//!   archive stores, as unzip restores them) run in-process. (Was
//!   tools/fetch-sqlite.sh.)
//! - slt: the sqllogictest scripts (about 1.2 GB) and the source of the C
//!   runner, cloned with `git clone --depth 1` from the GitHub mirror of
//!   https://sqlite.org/sqllogictest (the fossil site asks browsers to
//!   verify themselves, so scripts cannot fetch it) into
//!   ref/sqllogictest; $SLT_REPO names another repository. git is the one
//!   program this runs. (Was tools/fetch-slt.sh.)
//!
//! The destination is replaced only once the new tree is complete.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");

pub const usage =
    \\usage: xqt fetch sqlite|slt [--dest DIR]
    \\
    \\  sqlite   SQLite's source tree into ref/sqlite ($SQLITE_VERSION, default
    \\           3540100; $SQLITE_YEAR, default 2026)
    \\  slt      the sqllogictest scripts (about 1.2 GB) into ref/sqllogictest,
    \\           with git clone --depth 1 ($SLT_REPO, default
    \\           https://github.com/gregrahn/sqllogictest.git)
    \\  --dest   another destination (the directory is replaced)
    \\
;

/// Keep in sync with sqlite_version_number in pkg/storage/src/root.zig.
const sqlite_version = "3540100";
const sqlite_year = "2026";
const slt_repo = "https://github.com/gregrahn/sqllogictest.git";

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var what: ?[]const u8 = null;
    var dest_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dest") and i + 1 < args.len) {
            i += 1;
            dest_flag = args[i];
        } else if (what == null and args[i].len > 0 and args[i][0] != '-') {
            what = args[i];
        } else return usageError(out);
    }
    const name = what orelse return usageError(out);
    if (std.mem.eql(u8, name, "sqlite")) {
        const dest = try absolute(arena, io, dest_flag orelse try std.fs.path.join(arena, &.{ cfg.root, "ref", "sqlite" }));
        return fetchSqlite(gpa, arena, io, cfg, out, dest);
    }
    if (std.mem.eql(u8, name, "slt")) {
        const dest = try absolute(arena, io, dest_flag orelse try std.fs.path.join(arena, &.{ cfg.root, "ref", "sqllogictest" }));
        return fetchSlt(arena, io, cfg, out, dest);
    }
    return usageError(out);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return std.fs.path.resolveAlloc(arena, &.{ buf[0..n], path });
}

/// A directory next to `dest` for the new tree, so that moving it into
/// place is a rename on the same file system.
fn stagingDir(arena: Allocator, io: Io, dest: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(dest) orelse ".";
    try Io.Dir.cwd().createDirPath(io, parent);
    const dir = try std.fmt.allocPrint(arena, "{s}/.xqt-fetch-{s}-{d}", .{ parent, std.fs.path.basename(dest), std.c.getpid() });
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// Replaces `dest` with `from`.
fn moveInto(io: Io, from: []const u8, dest: []const u8) !void {
    try Io.Dir.cwd().deleteTree(io, dest);
    try Io.Dir.cwd().rename(from, .cwd(), dest, io);
}

fn fetchSqlite(gpa: Allocator, arena: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, dest: []const u8) !u8 {
    const version = cfg.environ.get("SQLITE_VERSION") orelse sqlite_version;
    const year = cfg.environ.get("SQLITE_YEAR") orelse sqlite_year;
    const url = try std.fmt.allocPrint(arena, "https://www.sqlite.org/{s}/sqlite-src-{s}.zip", .{ year, version });
    try out.print("fetching {s}\n", .{url});
    try out.flush();

    const staging = try stagingDir(arena, io, dest);
    defer Io.Dir.cwd().deleteTree(io, staging) catch {};
    const zip_path = try std.fs.path.join(arena, &.{ staging, "src.zip" });
    download(gpa, io, url, zip_path) catch |err| {
        try out.print("xqt fetch: {s}: {t}\n", .{ url, err });
        return 1;
    };

    var stage = try Io.Dir.cwd().openDir(io, staging, .{});
    defer stage.close(io);
    {
        const zip = try stage.openFile(io, "src.zip", .{});
        defer zip.close(io);
        var buf: [16 << 10]u8 = undefined;
        var reader = zip.reader(io, &buf);
        try std.zip.extract(stage, &reader, .{});
        try restoreModes(gpa, io, &reader, stage);
    }

    const tree = try std.fmt.allocPrint(arena, "{s}/sqlite-src-{s}", .{ staging, version });
    try moveInto(io, tree, dest);
    const marker = try std.fmt.allocPrint(arena, "{s}\n", .{version});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dest, ".xqlite-version" }), .data = marker });
    try out.print("sqlite {s} -> {s}\n", .{ version, dest });
    return 0;
}

/// GET `url` into the file `path`; a status other than 200 is an error
/// (curl -f).
fn download(gpa: Allocator, io: Io, url: []const u8, path: []const u8) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 << 10]u8 = undefined;
    var fw = file.writer(io, &buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fw.interface,
    }) catch |err| switch (err) {
        error.WriteFailed => return fw.err orelse err,
        else => return err,
    };
    try fw.end();
    if (result.status != .ok) return error.HttpStatusNotOk;
}

/// Sets the Unix permission bits the zip's central directory stores (the
/// high half of each entry's external attributes) on what std.zip.extract
/// wrote, as unzip does; std.zip leaves the default modes.
fn restoreModes(gpa: Allocator, io: Io, reader: *Io.File.Reader, dest: Io.Dir) !void {
    const size = try reader.getSize();
    // The end of central directory record: the last 22 bytes, or before a
    // comment of up to 64 KiB.
    const tail_len: usize = @intCast(@min(size, 22 + 0xffff));
    const tail = try gpa.alloc(u8, tail_len);
    defer gpa.free(tail);
    try reader.seekTo(size - tail_len);
    try reader.interface.readSliceAll(tail);
    var eocd: usize = tail_len - 22;
    while (std.mem.readInt(u32, tail[eocd..][0..4], .little) != 0x06054b50) {
        if (eocd == 0) return error.ZipNoEndRecord;
        eocd -= 1;
    }
    const entries = std.mem.readInt(u16, tail[eocd + 10 ..][0..2], .little);
    const cd_size = std.mem.readInt(u32, tail[eocd + 12 ..][0..4], .little);
    const cd_offset = std.mem.readInt(u32, tail[eocd + 16 ..][0..4], .little);
    if (entries == 0xffff or cd_offset == 0xffffffff) return error.Zip64Unsupported;
    const cd = try gpa.alloc(u8, cd_size);
    defer gpa.free(cd);
    try reader.seekTo(cd_offset);
    try reader.interface.readSliceAll(cd);

    var p: usize = 0;
    for (0..entries) |_| {
        if (p + 46 > cd.len or std.mem.readInt(u32, cd[p..][0..4], .little) != 0x02014b50) return error.ZipBadCentralDirectory;
        const made_by_os = cd[p + 5];
        const name_len = std.mem.readInt(u16, cd[p + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, cd[p + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, cd[p + 32 ..][0..2], .little);
        const attrs = std.mem.readInt(u32, cd[p + 38 ..][0..4], .little);
        const name = std.mem.trimEnd(u8, cd[p + 46 ..][0..name_len], "/");
        p += 46 + name_len + extra_len + comment_len;
        // 3: made on Unix, so the high half holds st_mode.
        const mode = attrs >> 16;
        if (made_by_os != 3 or mode & 0o777 == 0 or name.len == 0) continue;
        // unzip drops setuid, setgid and sticky unless -K.
        try dest.setFilePermissions(io, name, @fromBackingInt(@intCast(mode & 0o777)), .{});
    }
}

fn fetchSlt(arena: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, dest: []const u8) !u8 {
    const url = cfg.environ.get("SLT_REPO") orelse slt_repo;
    const staging = try stagingDir(arena, io, dest);
    defer Io.Dir.cwd().deleteTree(io, staging) catch {};
    const clone = try std.fs.path.join(arena, &.{ staging, "clone" });
    try out.print("cloning {s}\n", .{url});
    try out.flush();
    // git prints its progress on the terminal.
    var child = try std.process.spawn(io, .{ .argv = &.{ "git", "clone", "--depth", "1", url, clone } });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        try out.print("xqt fetch: git clone {s}: {f}\n", .{ url, term });
        return 1;
    }
    try moveInto(io, clone, dest);
    try out.print("sqllogictest -> {s}\n", .{dest});
    return 0;
}
