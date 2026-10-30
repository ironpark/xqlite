//! The programs a run of xqt uses and the options every command shares.
//! Each program is resolved here and nowhere else: the command-line flag,
//! else the environment variable, else the default.
//!
//! | field       | flag          | variable          | default                                          |
//! | ----------- | ------------- | ----------------- | ------------------------------------------------ |
//! | `xq`        | `--xq`        | `XQ`              | ROOT/zig-out/bin/xqlite                          |
//! | `sqlite3`   | `--sqlite3`   | `SQLITE3`         | /tmp/xq-sqlite-build/sqlite3 if it exists, else `sqlite3` (PATH) |
//! | `sq`        | `--sq`        | `SQ`              | `sqlite3` (PATH)                                 |
//! | `crashshim` | `--crashshim` | `XQT_CRASHSHIM`   | ROOT/zig-out/lib/libcrashshim.{dylib,so}         |

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const Config = @This();

/// The repository root, absolute.
root: []const u8,
/// The xqlite binary under test.
xq: []const u8,
/// The reference sqlite3 shell (3.54.1).
sqlite3: []const u8,
/// The planner's reference shell: 3.54.1 without SQLITE_ENABLE_EXPLAIN_COMMENTS.
sq: []const u8,
/// The preload library of tools/crashshim.c (see crash.zig).
crashshim: []const u8,
/// Checks to run at once (-j N, default: the CPU count).
jobs: usize,
/// -v: print the log of every check, not only of failed ones.
verbose: bool = false,
/// --keep: keep the temporary directory of a failed check.
keep: bool = false,
/// The directory under which each check gets its own; this run's.
tmp: []const u8,
/// The environment xqt was started with.
environ: *const Environ.Map,

pub const usage =
    \\global options (anywhere before "--"):
    \\  -j N             checks to run at once (default: CPU count)
    \\  -v               print the log of every check
    \\  --keep           keep the temporary directory of a failed check
    \\  --xq PATH        xqlite under test     ($XQ, default ROOT/zig-out/bin/xqlite)
    \\  --sqlite3 PATH   reference sqlite3     ($SQLITE3, default /tmp/xq-sqlite-build/sqlite3
    \\                                          if it exists, else sqlite3 on PATH)
    \\  --sq PATH        planner reference     ($SQ, default sqlite3 on PATH)
    \\  --crashshim PATH tools/crashshim.c built as a preload library
    \\                                         ($XQT_CRASHSHIM, default ROOT/zig-out/lib/)
    \\
;

pub const ParseError = error{ Usage, OutOfMemory };

/// Takes the global options out of `args` (those before a "--") and
/// returns the rest in order, for the command to parse. `root` is the
/// repository root.
pub fn parse(arena: Allocator, io: Io, environ: *const Environ.Map, root: []const u8, args: []const []const u8, rest: *std.ArrayList([]const u8)) ParseError!Config {
    var xq_flag: ?[]const u8 = null;
    var sqlite3_flag: ?[]const u8 = null;
    var sq_flag: ?[]const u8 = null;
    var shim_flag: ?[]const u8 = null;
    var jobs: ?usize = null;
    var verbose = false;
    var keep = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            try rest.appendSlice(arena, args[i..]);
            break;
        }
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--keep")) {
            keep = true;
        } else if (std.mem.eql(u8, a, "-j") and has_value) {
            i += 1;
            jobs = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.Usage;
            if (jobs == 0) return error.Usage;
        } else if (std.mem.eql(u8, a, "--xq") and has_value) {
            i += 1;
            xq_flag = args[i];
        } else if (std.mem.eql(u8, a, "--sqlite3") and has_value) {
            i += 1;
            sqlite3_flag = args[i];
        } else if (std.mem.eql(u8, a, "--sq") and has_value) {
            i += 1;
            sq_flag = args[i];
        } else if (std.mem.eql(u8, a, "--crashshim") and has_value) {
            i += 1;
            shim_flag = args[i];
        } else {
            try rest.append(arena, a);
        }
    }

    const tmp_base = environ.get("TMPDIR") orelse "/tmp";
    return .{
        .root = root,
        .xq = try absolute(arena, io, xq_flag orelse environ.get("XQ") orelse
            try std.fs.path.join(arena, &.{ root, "zig-out", "bin", "xqlite" })),
        .sqlite3 = try absolute(arena, io, sqlite3_flag orelse environ.get("SQLITE3") orelse
            if (exists(io, reference_sqlite3)) reference_sqlite3 else "sqlite3"),
        .sq = try absolute(arena, io, sq_flag orelse environ.get("SQ") orelse "sqlite3"),
        .crashshim = try absolute(arena, io, shim_flag orelse environ.get("XQT_CRASHSHIM") orelse
            try std.fs.path.join(arena, &.{ root, "zig-out", "lib", shim_name })),
        .jobs = jobs orelse std.Thread.getCpuCount() catch 4,
        .verbose = verbose,
        .keep = keep,
        .tmp = try std.fmt.allocPrint(arena, "{s}/xqt-{d}", .{ std.mem.trimEnd(u8, tmp_base, "/"), std.c.getpid() }),
        .environ = environ,
    };
}

/// The 3.54.1 build docs/testing.md describes.
pub const reference_sqlite3 = "/tmp/xq-sqlite-build/sqlite3";

pub const shim_name = if (builtin.os.tag.isDarwin()) "libcrashshim.dylib" else "libcrashshim.so";

/// A path with a slash in it, made absolute (checks run in directories of
/// their own); a bare name stays, for a PATH lookup.
pub fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null or std.fs.path.isAbsolute(path)) return path;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(io, &buf) catch return path;
    return std.fs.path.resolveAlloc(arena, &.{ buf[0..n], path });
}

pub fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
