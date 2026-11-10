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
//! - tcl: the Tcl 8.6 that SQLite's TCL test suite needs (macOS ships
//!   Tcl 8.5), for `xqt tcl`. The source release (tcl-core, without the
//!   bundled packages) comes from SourceForge, where tcl-lang.org keeps
//!   its downloads, and must have the SHA-256 pinned below (checked
//!   against the MD5 SourceForge publishes for the file). It is unpacked
//!   into DEST/src and built with the system C compiler: `sh configure
//!   --prefix=DEST --disable-shared`, `make`, `make install` in
//!   DEST/src/tcl8.6.N/unix. DEST (default ref/tcl) then has
//!   bin/tclsh8.6, lib/libtcl8.6.a, lib/tclConfig.sh and include/tcl.h.
//!   $CC chooses the compiler (default cc).
//!
//! The destination is replaced only once the new tree is complete (tcl:
//! once the build has succeeded, then `make install` fills it).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");

pub const usage =
    \\usage: xqt fetch sqlite|slt|tcl [--dest DIR]
    \\
    \\  sqlite   SQLite's source tree into ref/sqlite ($SQLITE_VERSION, default
    \\           3540100; $SQLITE_YEAR, default 2026)
    \\  slt      the sqllogictest scripts (about 1.2 GB) into ref/sqllogictest,
    \\           with git clone --depth 1 ($SLT_REPO, default
    \\           https://github.com/gregrahn/sqllogictest.git)
    \\  tcl      Tcl 8.6.17 (source checked against a pinned SHA-256), built
    \\           with the system C compiler ($CC, default cc) into ref/tcl,
    \\           for xqt tcl
    \\  --dest   another destination (the directory is replaced)
    \\
;

/// Keep in sync with sqlite_version_number in pkg/storage/src/root.zig.
const sqlite_version = "3540100";
const sqlite_year = "2026";
const slt_repo = "https://github.com/gregrahn/sqllogictest.git";

const tcl_version = "8.6.17";
const tcl_url = "https://prdownloads.sourceforge.net/tcl/tcl-core" ++ tcl_version ++ "-src.tar.gz";
/// SHA-256 of tcl-core8.6.17-src.tar.gz (MD5 509597025ee2e4395f369a334b9089fd,
/// as SourceForge lists it).
const tcl_sha256 = "a1d8cbe44b38beaa29fc2130c4e7b79b8bf02e2bcc028ffefd7a25a2122202a0";

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
    if (std.mem.eql(u8, name, "tcl")) {
        const dest = try absolute(arena, io, dest_flag orelse try std.fs.path.join(arena, &.{ cfg.root, "ref", "tcl" }));
        return fetchTcl(gpa, arena, io, cfg, out, dest);
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
    // createDirPath fails on a symbolic link to a directory (a worktree's
    // ref/ links to the main checkout's, AGENTS.md).
    if (Io.Dir.cwd().openDir(io, parent, .{})) |d| d.close(io) else |_| try Io.Dir.cwd().createDirPath(io, parent);
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
        // SourceForge sends a download through two or three redirects.
        .redirect_behavior = @fromBackingInt(8),
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

fn fetchTcl(gpa: Allocator, arena: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, dest_arg: []const u8) !u8 {
    try out.print("fetching {s}\n", .{tcl_url});
    try out.flush();
    const staging = try stagingDir(arena, io, dest_arg);
    // The prefix is compiled into tclsh: the real path, not one through a
    // worktree's link to ref/ (xqt tcl sets $TCL_LIBRARY anyway).
    const dest = try std.fs.path.join(arena, &.{
        try Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(dest_arg).?, arena),
        std.fs.path.basename(dest_arg),
    });
    defer Io.Dir.cwd().deleteTree(io, staging) catch {};
    const tarball = try std.fs.path.join(arena, &.{ staging, "tcl.tar.gz" });
    download(gpa, io, tcl_url, tarball) catch |err| {
        try out.print("xqt fetch: {s}: {t}\n", .{ tcl_url, err });
        return 1;
    };

    // The pinned checksum, before anything of the archive is used.
    const got = try sha256File(io, tarball);
    if (!std.mem.eql(u8, &got, tcl_sha256)) {
        try out.print("xqt fetch: {s}: SHA-256 {s}, want {s}\n", .{ tcl_url, &got, tcl_sha256 });
        return 1;
    }

    const src = try std.fs.path.join(arena, &.{ staging, "src" });
    try Io.Dir.cwd().createDirPath(io, src);
    {
        var src_dir = try Io.Dir.cwd().openDir(io, src, .{});
        defer src_dir.close(io);
        const file = try Io.Dir.cwd().openFile(io, tarball, .{});
        defer file.close(io);
        var buf: [16 << 10]u8 = undefined;
        var reader = file.reader(io, &buf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gz: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
        try std.tar.extract(io, src_dir, &gz.reader, .{ .mode_mode = .executable_bit_only });
    }

    // Built in the staging directory with the final prefix (tclsh finds
    // its script library there), installed under INSTALL_ROOT, and then
    // moved into place.
    const unix = try std.fmt.allocPrint(arena, "{s}/tcl{s}/unix", .{ src, tcl_version });
    const prefix = try std.fmt.allocPrint(arena, "--prefix={s}", .{dest});
    const jobs = try std.fmt.allocPrint(arena, "-j{d}", .{@min(cfg.jobs, 8)});
    const root = try std.fs.path.join(arena, &.{ staging, "install" });
    const install_root = try std.fmt.allocPrint(arena, "INSTALL_ROOT={s}", .{root});
    const cc = try std.fmt.allocPrint(arena, "CC={s}", .{cfg.environ.get("CC") orelse "cc"});
    const steps = [_][]const []const u8{
        &.{ "sh", "configure", prefix, "--disable-shared", cc },
        &.{ "make", jobs },
        &.{ "make", install_root, "install" },
    };
    for (steps) |argv| {
        try out.print("tcl: {s}\n", .{try std.mem.join(arena, " ", argv)});
        try out.flush();
        // configure and make print their progress on the terminal.
        var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .path = unix } });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            try out.print("xqt fetch: {s} in {s}: {f}\n", .{ argv[0], unix, term });
            return 1;
        }
    }
    const installed = try std.fs.path.join(arena, &.{ root, dest });
    try moveInto(io, installed, dest);
    try out.print("tcl {s} -> {s} (tclsh: {s}/bin/tclsh8.6)\n", .{ tcl_version, dest, dest });
    return 0;
}

/// The SHA-256 of a file, in lower-case hex.
fn sha256File(io: Io, path: []const u8) ![64]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &buf);
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        h.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}
