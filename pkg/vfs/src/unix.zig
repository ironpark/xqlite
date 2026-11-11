//! POSIX VFS (port of the "unix", "unix-excl", "unix-none", "unix-dotfile"
//! and "unix-flock" VFSes of os_unix.c).
//!
//! Locks use the same byte ranges as SQLite, so xqlite and real SQLite
//! processes can safely share a database file.
//!
//! POSIX locks are owned by the process, not the file descriptor, and closing
//! *any* descriptor on a file drops *all* of the process's locks on it. As in
//! os_unix.c, every open file is therefore mapped to a process-wide
//! `InodeInfo` that tracks lock state across handles, and closing a handle
//! while other handles still hold locks defers the close(2).
//!
//! "unix-excl" (`UnixVfs.excl`) takes, with the first lock of a file
//! opened read-write, an exclusive POSIX lock on the whole shared range
//! and keeps it until the last handle of the process closes: connections
//! of this process still exclude each other in memory, other processes
//! are shut out, and the wal-index of a WAL database is heap memory with
//! no -shm file (bProcessLock).
//!
//! The shared memory of a WAL database (the wal-index) is the mmapped
//! "-shm" file next to it, locked with the same byte ranges as os_unix.c
//! (UNIX_SHM_BASE, UNIX_SHM_DMS), so the wal-index is shared with real
//! SQLite processes too. As in os_unix.c, each inode has at most one
//! `ShmNode` per process, shared by every handle that maps it. With the
//! URI parameter readonly_shm=1 the -shm file is opened read-only.
//!
//! Memory-mapped I/O (PRAGMA mmap_size, xFetch/xUnfetch) maps the
//! database file read-only and shared, as os_unix.c does without
//! SQLITE_MMAP_READWRITE: reads within the mapping are copied out of it
//! and the pager may use mapped pages in place; writes still go through
//! pwrite(2).
//!
//! Every system call goes through a table that can be overridden, as
//! aSyscall[] of os_unix.c (xSetSystemCall(), xGetSystemCall(),
//! xNextSystemCall(): setSystemCall() ...), with the same names and C
//! signatures, so a test harness can inject faults.
//!
//! Not ported: proxy/afp locking styles, F_SETLKW timeouts.

const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("vfs.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;
const c = std.c;
const fd_t = c_int;
const off_t = i64;
const mode_t = c.mode_t;

// ===================================================== system calls

/// `struct stat` of the C library, as the stat family of the system call
/// table fills it. On Linux, where std.c has none, the layout of the
/// kernel's (which glibc and musl use on 64-bit targets), filled from
/// statx(2) by the default functions.
pub const Stat = if (builtin.os.tag == .linux) LinuxStat else c.Stat;

const LinuxStat = if (builtin.cpu.arch == .x86_64) extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    __pad0: u32 = 0,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    times: [6]i64,
    __unused: [3]i64 = @splat(0),
} else extern struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    __pad1: u64 = 0,
    size: i64,
    blksize: i32,
    __pad2: i32 = 0,
    blocks: i64,
    times: [6]i64,
    __unused: [2]u32 = @splat(0),
};

fn isReg(m: anytype) bool {
    return @as(u32, m) & 0o170000 == 0o100000;
}
fn isDir(m: anytype) bool {
    return @as(u32, m) & 0o170000 == 0o040000;
}
fn isLnk(m: anytype) bool {
    return @as(u32, m) & 0o170000 == 0o120000;
}

/// The overridable system calls, in the order of aSyscall[] (the
/// numbers are its indexes).
const Sys = enum {
    open,
    close,
    access,
    getcwd,
    stat,
    fstat,
    ftruncate,
    fcntl,
    read,
    pread,
    pread64,
    write,
    pwrite,
    pwrite64,
    fchmod,
    fallocate,
    unlink,
    openDirectory,
    mkdir,
    rmdir,
    fchown,
    geteuid,
    mmap,
    munmap,
    mremap,
    getpagesize,
    readlink,
    lstat,
    ioctl,
};

/// The C type of each system call (the casts of the osXxx macros).
fn SysFn(comptime s: Sys) type {
    return *const switch (s) {
        .open => fn ([*:0]const u8, c_int, c_int) callconv(.c) c_int,
        .close => fn (c_int) callconv(.c) c_int,
        .access => fn ([*:0]const u8, c_int) callconv(.c) c_int,
        .getcwd => fn ([*]u8, usize) callconv(.c) ?[*]u8,
        .stat, .lstat => fn ([*:0]const u8, *Stat) callconv(.c) c_int,
        .fstat => fn (c_int, *Stat) callconv(.c) c_int,
        .ftruncate => fn (c_int, off_t) callconv(.c) c_int,
        .fcntl => fn (c_int, c_int, ...) callconv(.c) c_int,
        .read => fn (c_int, [*]u8, usize) callconv(.c) isize,
        .pread, .pread64 => fn (c_int, [*]u8, usize, off_t) callconv(.c) isize,
        .write => fn (c_int, [*]const u8, usize) callconv(.c) isize,
        .pwrite, .pwrite64 => fn (c_int, [*]const u8, usize, off_t) callconv(.c) isize,
        .fchmod => fn (c_int, mode_t) callconv(.c) c_int,
        .fallocate => fn (c_int, off_t, off_t) callconv(.c) c_int,
        .unlink, .rmdir => fn ([*:0]const u8) callconv(.c) c_int,
        .openDirectory => fn ([*:0]const u8, *c_int) callconv(.c) c_int,
        .mkdir => fn ([*:0]const u8, mode_t) callconv(.c) c_int,
        .fchown => fn (c_int, c.uid_t, c.gid_t) callconv(.c) c_int,
        .geteuid => fn () callconv(.c) c.uid_t,
        .mmap => fn (?*anyopaque, usize, c_int, c_int, c_int, off_t) callconv(.c) ?*anyopaque,
        .munmap => fn (?*anyopaque, usize) callconv(.c) c_int,
        .mremap => fn (?*anyopaque, usize, usize, c_int, ...) callconv(.c) ?*anyopaque,
        .getpagesize => fn () callconv(.c) c_int,
        .readlink => fn ([*:0]const u8, [*]u8, usize) callconv(.c) isize,
        .ioctl => fn (c_int, c_ulong, ...) callconv(.c) c_int,
    };
}

/// The default implementations, where os_unix.c has one: the C library's
/// function, or a wrapper with the same C signature.
const defaults = struct {
    fn open(z: [*:0]const u8, f: c_int, m: c_int) callconv(.c) c_int {
        return c.open(z, @bitCast(f), @as(c_uint, @intCast(m)));
    }
    fn close(fd: c_int) callconv(.c) c_int {
        return c.close(fd);
    }
    fn access(z: [*:0]const u8, m: c_int) callconv(.c) c_int {
        return c.access(z, @intCast(m));
    }
    fn getcwd(b: [*]u8, n: usize) callconv(.c) ?[*]u8 {
        return c.getcwd(b, n);
    }
    fn stat(z: [*:0]const u8, st: *Stat) callconv(.c) c_int {
        if (builtin.os.tag == .linux) return linuxStat(c.AT.FDCWD, z, 0, st);
        return c.stat(z, st);
    }
    fn fstat(fd: c_int, st: *Stat) callconv(.c) c_int {
        if (builtin.os.tag == .linux) return linuxStat(fd, "", std.os.linux.AT.EMPTY_PATH, st);
        return c.fstat(fd, st);
    }
    fn lstat(z: [*:0]const u8, st: *Stat) callconv(.c) c_int {
        if (builtin.os.tag == .linux) return linuxStat(c.AT.FDCWD, z, c.AT.SYMLINK_NOFOLLOW, st);
        return c.fstatat(c.AT.FDCWD, z, st, c.AT.SYMLINK_NOFOLLOW);
    }
    fn ftruncate(fd: c_int, n: off_t) callconv(.c) c_int {
        return c.ftruncate(fd, @intCast(n));
    }
    fn read(fd: c_int, b: [*]u8, n: usize) callconv(.c) isize {
        return c.read(fd, b, n);
    }
    fn pread(fd: c_int, b: [*]u8, n: usize, off: off_t) callconv(.c) isize {
        return c.pread(fd, b, n, @intCast(off));
    }
    fn write(fd: c_int, b: [*]const u8, n: usize) callconv(.c) isize {
        return c.write(fd, b, n);
    }
    fn pwrite(fd: c_int, b: [*]const u8, n: usize, off: off_t) callconv(.c) isize {
        return c.pwrite(fd, b, n, @intCast(off));
    }
    fn fchmod(fd: c_int, m: mode_t) callconv(.c) c_int {
        return c.fchmod(fd, m);
    }
    fn unlink(z: [*:0]const u8) callconv(.c) c_int {
        return c.unlink(z);
    }
    fn mkdir(z: [*:0]const u8, m: mode_t) callconv(.c) c_int {
        return c.mkdir(z, m);
    }
    fn rmdir(z: [*:0]const u8) callconv(.c) c_int {
        return c.rmdir(z);
    }
    fn fchown(fd: c_int, u: c.uid_t, g: c.gid_t) callconv(.c) c_int {
        return c.fchown(fd, u, g);
    }
    fn geteuid() callconv(.c) c.uid_t {
        return c.geteuid();
    }
    fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: off_t) callconv(.c) ?*anyopaque {
        return c.mmap(@ptrCast(@alignCast(addr)), len, @bitCast(@as(u32, @bitCast(prot))), @bitCast(@as(u32, @bitCast(flags))), fd, @intCast(off));
    }
    fn munmap(addr: ?*anyopaque, len: usize) callconv(.c) c_int {
        return c.munmap(@ptrCast(@alignCast(addr orelse return -1)), len);
    }
    fn mremap(addr: ?*anyopaque, old: usize, new: usize, flags: c_int, ...) callconv(.c) ?*anyopaque {
        const linux = std.os.linux;
        const rc = linux.mremap(@ptrCast(addr), old, new, @bitCast(@as(u32, @bitCast(flags))), null);
        if (linux.errno(rc) != .SUCCESS) {
            c._errno().* = @intCast(@backingInt(linux.errno(rc)));
            return c.MAP_FAILED;
        }
        return @ptrFromInt(rc);
    }
    fn getpagesize() callconv(.c) c_int {
        return @intCast(std.heap.pageSize());
    }
    fn readlink(z: [*:0]const u8, b: [*]u8, n: usize) callconv(.c) isize {
        return c.readlink(z, b, n);
    }

    /// The stat family on Linux: statx(2) into `Stat`, errno set on failure.
    fn linuxStat(dirfd: c_int, z: [*:0]const u8, flags: u32, st: *Stat) c_int {
        if (builtin.os.tag != .linux) unreachable;
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(dirfd, z, flags, .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .INO = true, .SIZE = true, .BLOCKS = true }, &stx);
        const e = linux.errno(rc);
        if (e != .SUCCESS) {
            c._errno().* = @intCast(@backingInt(e));
            return -1;
        }
        st.* = std.mem.zeroes(Stat);
        st.dev = (@as(u64, stx.dev_major) << 8) | stx.dev_minor;
        st.ino = stx.ino;
        st.mode = stx.mode;
        st.nlink = @intCast(stx.nlink);
        st.uid = stx.uid;
        st.gid = stx.gid;
        st.size = @intCast(stx.size);
        st.blksize = @intCast(stx.blksize);
        st.blocks = @intCast(stx.blocks);
        return 0;
    }
};

const Syscall = struct {
    name: [:0]const u8,
    /// The function in use (pCurrent); null if the platform has none.
    current: ?*const anyopaque,
    /// The original, once overridden (pDefault).
    default: ?*const anyopaque = null,
};

fn entry(comptime name: [:0]const u8, comptime f: anytype) Syscall {
    return .{ .name = name, .current = if (@TypeOf(f) == @TypeOf(null)) null else @ptrCast(f) };
}

const is_linux = builtin.os.tag == .linux;

/// aSyscall[]: process-wide, as in C.
var syscalls = syscalls_init;

const syscalls_init = [_]Syscall{
    entry("open", &defaults.open),
    entry("close", &defaults.close),
    entry("access", &defaults.access),
    entry("getcwd", &defaults.getcwd),
    entry("stat", &defaults.stat),
    entry("fstat", &defaults.fstat),
    entry("ftruncate", &defaults.ftruncate),
    entry("fcntl", &c.fcntl),
    entry("read", &defaults.read),
    entry("pread", &defaults.pread),
    entry("pread64", null),
    entry("write", &defaults.write),
    entry("pwrite", &defaults.pwrite),
    entry("pwrite64", null),
    entry("fchmod", &defaults.fchmod),
    entry("fallocate", null),
    entry("unlink", &defaults.unlink),
    entry("openDirectory", &openDirectory),
    entry("mkdir", &defaults.mkdir),
    entry("rmdir", &defaults.rmdir),
    entry("fchown", &defaults.fchown),
    entry("geteuid", &defaults.geteuid),
    entry("mmap", &defaults.mmap),
    entry("munmap", &defaults.munmap),
    if (is_linux) entry("mremap", &defaults.mremap) else entry("mremap", null),
    entry("getpagesize", &defaults.getpagesize),
    entry("readlink", &defaults.readlink),
    entry("lstat", &defaults.lstat),
    entry("ioctl", null),
};

comptime {
    for (@typeInfo(Sys).@"enum".field_names, 0..) |name, i| {
        if (!std.mem.eql(u8, name, syscalls_init[i].name)) @compileError("syscalls[] out of order at " ++ name);
    }
}

/// The current function of system call `s` (osOpen, osClose ...).
fn os(comptime s: Sys) SysFn(s) {
    return @ptrCast(@alignCast(syscalls[@backingInt(s)].current.?));
}

/// Port of unixSetSystemCall(): make `ptr` the function of system call
/// `name`, or its original if `ptr` is null; with a null `name`, restore
/// every original. False if there is no system call `name`
/// (SQLITE_NOTFOUND).
pub fn setSystemCall(name: ?[]const u8, ptr: ?*const anyopaque) bool {
    const n = name orelse {
        for (&syscalls) |*s| {
            if (s.default) |d| s.current = d;
        }
        return true;
    };
    for (&syscalls) |*s| {
        if (std.mem.eql(u8, n, s.name)) {
            if (s.default == null) s.default = s.current;
            s.current = ptr orelse s.default;
            return true;
        }
    }
    return false;
}

/// Port of unixGetSystemCall(): the function of system call `name` in
/// use, or null.
pub fn getSystemCall(name: []const u8) ?*const anyopaque {
    for (syscalls) |s| {
        if (std.mem.eql(u8, name, s.name)) return s.current;
    }
    return null;
}

/// Port of unixNextSystemCall(): the name of the first system call the
/// platform has after `name` (the first of all if null), or null.
pub fn nextSystemCall(name: ?[]const u8) ?[:0]const u8 {
    var i: usize = 0;
    if (name) |n| {
        while (i < syscalls.len - 1) : (i += 1) {
            if (std.mem.eql(u8, n, syscalls[i].name)) break;
        }
        i += 1;
    }
    while (i < syscalls.len) : (i += 1) {
        if (syscalls[i].current != null) return syscalls[i].name;
    }
    return null;
}

extern "c" fn strerror(c_int) [*:0]const u8;

fn errno() c_int {
    return c._errno().*;
}

fn eno(e: c.E) c_int {
    return @intCast(@backingInt(e));
}

fn oflags(o: c.O) c_int {
    return @bitCast(o);
}

/// SQLITE_DEFAULT_FILE_PERMISSIONS.
const default_file_permissions: mode_t = 0o644;

/// Port of robust_open(): open(2) through the table, retried on EINTR,
/// never returning a descriptor below 3 (which a stray write to stdout
/// or stderr could corrupt), close-on-exec, and with the permissions `m`
/// even under a umask if the file is new.
fn robustOpen(z: [*:0]const u8, f: c_int, m: mode_t) c_int {
    const m2: mode_t = if (m != 0) m else default_file_permissions;
    const cloexec = oflags(.{ .CLOEXEC = true });
    var fd: c_int = -1;
    while (true) {
        fd = os(.open)(z, f | cloexec, @intCast(m2));
        if (fd < 0) {
            if (errno() == eno(.INTR)) continue;
            break;
        }
        if (fd >= 3) break;
        if (f & oflags(.{ .EXCL = true, .CREAT = true }) == oflags(.{ .EXCL = true, .CREAT = true })) {
            _ = os(.unlink)(z);
        }
        _ = os(.close)(fd);
        vfs.log(sqlite_warning, "attempt to open \"{s}\" as file descriptor {d}", .{ std.mem.span(z), fd });
        fd = -1;
        if (os(.open)("/dev/null", oflags(.{}), @intCast(m)) < 0) break;
    }
    if (fd >= 0 and m != 0) {
        var st: Stat = undefined;
        if (os(.fstat)(fd, &st) == 0 and st.size == 0 and (@as(u32, st.mode) & 0o777) != m) {
            _ = os(.fchmod)(fd, m);
        }
    }
    return fd;
}

/// Port of robust_ftruncate().
fn robustFtruncate(h: c_int, sz: i64) c_int {
    while (true) {
        const rc = os(.ftruncate)(h, sz);
        if (rc < 0 and errno() == eno(.INTR)) continue;
        return rc;
    }
}

/// Port of robustFchown(): only root changes the owner.
fn robustFchown(fd: c_int, uid: c.uid_t, gid: c.gid_t) void {
    if (os(.geteuid)() == 0) _ = os(.fchown)(fd, uid, gid);
}

// SQLITE_* codes for sqlite3_log() (unixLogErrorAtLine()).
const sqlite_warning = 28;
const sqlite_cantopen = 14;
const ioerr = 10;
const ioerr_close = ioerr | (16 << 8);
const ioerr_fsync = ioerr | (4 << 8);
const ioerr_truncate = ioerr | (6 << 8);
const ioerr_delete = ioerr | (10 << 8);
const ioerr_dir_fsync = ioerr | (5 << 8);
const ioerr_shmsize = ioerr | (19 << 8);
const ioerr_shmmap = ioerr | (21 << 8);
const ioerr_shmopen = ioerr | (18 << 8);

/// Port of unixLogErrorAtLine(): report the failure of system call
/// `func` on `path` through sqlite3_log(), with errno and its message,
/// in os_unix.c's format.
fn logError(code: i32, func: []const u8, path: ?[]const u8, line: u32) void {
    const e = errno();
    const msg = std.mem.span(strerror(e));
    vfs.log(code, "os_unix.c:{d}: ({d}) {s}({s}) - {s}", .{ line, e, func, path orelse "", msg });
}

/// Port of openDirectory(): open the directory of `z_filename` for an
/// fsync; SQLITE_OK or SQLITE_CANTOPEN (it is system call "openDirectory").
fn openDirectory(z_filename: [*:0]const u8, out: *c_int) callconv(.c) c_int {
    var dir: [vfs.max_path_bytes + 1]u8 = undefined;
    const name = std.mem.span(z_filename);
    const n = @min(name.len, dir.len - 2);
    @memcpy(dir[0..n], name[0..n]);
    var ii = n;
    while (ii > 0 and dir[ii] != '/') ii -= 1;
    if (ii > 0) {
        dir[ii] = 0;
    } else {
        if (dir[0] != '/') dir[0] = '.';
        dir[1] = 0;
    }
    const z: [*:0]const u8 = @ptrCast(&dir);
    const fd = robustOpen(z, oflags(.{}), 0);
    out.* = fd;
    if (fd >= 0) return 0;
    logError(sqlite_cantopen, "openDirectory", std.mem.span(z), @src().line);
    return sqlite_cantopen;
}

/// Port of full_fsync(): F_FULLFSYNC where asked for and available
/// (fsync() where that fails), else fsync() (fdatasync() on Linux).
fn fullFsync(fd: c_int, full: bool) c_int {
    if (builtin.os.tag.isDarwin()) {
        var rc: c_int = 1;
        if (full) rc = os(.fcntl)(fd, c.F.FULLFSYNC, @as(c_int, 0));
        if (rc != 0) rc = c.fsync(fd);
        return rc;
    }
    if (builtin.os.tag == .linux) return c.fdatasync(fd);
    return c.fsync(fd);
}

pub const UnixVfs = struct {
    gpa: Allocator,
    io: Io,
    /// Relative paths are resolved against this directory.
    dir: Io.Dir,
    /// Where anonymous temporary files are created; null for the first
    /// usable one of unixTempFileDir() (tempFileDir()).
    temp_dir: ?[]const u8 = null,
    /// "unix-excl": files opened read-write take an exclusive lock for
    /// the process (UNIXFILE_EXCL).
    excl: bool = false,
    /// How databases are locked. Only POSIX advisory locks come with
    /// shared memory, so WAL needs exclusive locking mode in the others.
    style: LockStyle = .posix,

    pub const LockStyle = enum {
        posix,
        /// "unix-none" (nolockIoMethods): no locks. Also every file
        /// that is not a database.
        none,
        /// dotlockIoMethods: a directory "<db>.lock" is the lock.
        dotfile,
        /// flockIoMethods: flock(2), always exclusive.
        flock,
    };

    pub fn init(gpa: Allocator, io: Io) UnixVfs {
        return .{ .gpa = gpa, .io = io, .dir = .cwd() };
    }

    pub fn interface(self: *UnixVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = vtable };
    }

    /// The methods named after those of vfs.Vfs.VTable implement it
    /// (vfs.VfsImpl()).
    const vtable = &vfs.VfsImpl(UnixVfs).vtable;

    /// `name` as the system calls take it: NUL-terminated, and absolute
    /// if `dir` is not the working directory and it is relative.
    fn resolve(self: *UnixVfs, name: []const u8, buf: *[vfs.max_path_bytes + 1]u8) Error![:0]const u8 {
        var n: usize = 0;
        if (name.len == 0 or name[0] != '/') {
            if (self.dir.handle != Io.Dir.cwd().handle) {
                n = self.dir.realPath(self.io, buf[0 .. buf.len - 1]) catch return error.CantOpen;
                if (n + 1 >= buf.len) return error.CantOpen;
                buf[n] = '/';
                n += 1;
            }
        }
        if (n + name.len >= buf.len) return error.CantOpen;
        @memcpy(buf[n..][0..name.len], name);
        buf[n + name.len] = 0;
        return buf[0 .. n + name.len :0];
    }

    /// Port of unixFullPathname(): `path` made absolute (against `dir`),
    /// with "." and ".." removed and symbolic links resolved.
    pub fn fullPathname(self: *UnixVfs, path: []const u8, out: []u8, symlink: *bool) Error![]u8 {
        var p: DbPath = .{ .out = out };
        if (path.len == 0 or path[0] != '/') {
            var pwd: [vfs.max_path_bytes + 2]u8 = undefined;
            if (self.dir.handle != Io.Dir.cwd().handle) {
                const n = self.dir.realPath(self.io, &pwd) catch return error.CantOpen;
                p.appendAll(pwd[0..n]);
            } else {
                const r = os(.getcwd)(&pwd, pwd.len - 2) orelse {
                    logError(sqlite_cantopen, "getcwd", path, @src().line);
                    return error.CantOpen;
                };
                p.appendAll(std.mem.sliceTo(@as([*:0]u8, @ptrCast(r)), 0));
            }
        }
        p.appendAll(path);
        if (p.failed or p.used < 2) return error.CantOpen;
        symlink.* = p.n_symlink > 0;
        return out[0..p.used];
    }

    /// Port of unixGetTempname(): a name for a temporary file that does
    /// not exist yet, in tempFileDir().
    pub fn tempName(self: *UnixVfs, buf: []u8) Error![:0]u8 {
        const dir = self.temp_dir orelse tempFileDir() orelse return error.IoErr;
        var limit: u32 = 0;
        while (true) {
            var r: u64 = undefined;
            self.io.random(std.mem.asBytes(&r));
            const z = std.fmt.bufPrintSentinel(buf, "{s}/etilqs_{x}", .{ dir, r }, 0) catch return error.CantOpen;
            if (os(.access)(z.ptr, 0) != 0) return z;
            limit += 1;
            if (limit > 10) return error.CantOpen;
        }
    }

    /// Port of unixOpen().
    pub fn open(self: *UnixVfs, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        var name_buf: [vfs.max_path_bytes + 1]u8 = undefined;
        // Vfs.open has already set create/exclusive/delete_on_close for
        // anonymous files; only the name is left to choose.
        const name: [:0]const u8 = if (path) |p| try self.resolve(p, &name_buf) else try self.tempName(&name_buf);

        const is_new_jrnl = flags.create and switch (flags.kind) {
            .super_journal, .main_journal, .wal => true,
            else => false,
        };
        var read_only = !flags.read_write;
        var open_flags: c.O = .{ .ACCMODE = if (flags.read_write) .RDWR else .RDONLY, .NOFOLLOW = true };
        if (flags.create) open_flags.CREAT = true;
        if (flags.exclusive) open_flags.EXCL = true;

        // Port of findCreateFileMode(): a journal or WAL gets the
        // permissions and owner of its database; a file deleted on close
        // 0600; a database with a URI's modeof= those of that file.
        var mode: mode_t = 0;
        var uid: c.uid_t = 0;
        var gid: c.gid_t = 0;
        if (flags.kind == .wal or flags.kind == .main_journal) {
            var i = name.len -| 1;
            while (i > 0 and name[i] != '.') : (i -= 1) {
                if (name[i] == '-') {
                    var db: [vfs.max_path_bytes + 1]u8 = undefined;
                    @memcpy(db[0..i], name[0..i]);
                    db[i] = 0;
                    var st: Stat = undefined;
                    if (os(.stat)(@ptrCast(&db), &st) != 0) return error.IoErr;
                    mode = @intCast(@as(u32, st.mode) & 0o777);
                    uid = st.uid;
                    gid = st.gid;
                    break;
                }
            }
        } else if (flags.delete_on_close) {
            mode = 0o600;
        } else if (flags.uri and path != null) {
            if (vfs.uriParameter(path.?, "modeof")) |z| {
                var st: Stat = undefined;
                if (os(.stat)(z.ptr, &st) != 0) return error.IoErr;
                mode = @intCast(@as(u32, st.mode) & 0o777);
                uid = st.uid;
                gid = st.gid;
            }
        }

        // A database takes a descriptor a closed handle left, if any.
        const main_db = flags.kind == .main_db and path != null;
        var fd = (if (main_db) findReusableFd(self.io, name, flags.read_write) else null) orelse
            robustOpen(name.ptr, oflags(open_flags), mode);
        if (fd < 0) {
            const e = errno();
            if (is_new_jrnl and e == eno(.ACCES) and os(.access)(name.ptr, 0) != 0) {
                // The directory is not writable (SQLITE_READONLY_DIRECTORY).
                return error.ReadOnly;
            } else if (e != eno(.ISDIR) and flags.read_write and !flags.exclusive) {
                // Like unixOpen(): what cannot be opened read-write (a
                // file without write permission, say) is opened
                // read-only, which File.isReadOnly() reports. Not a file
                // that must be new (C would open an existing one
                // read-only).
                open_flags.ACCMODE = .RDONLY;
                open_flags.CREAT = false;
                read_only = true;
                fd = (if (main_db) findReusableFd(self.io, name, false) else null) orelse
                    robustOpen(name.ptr, oflags(open_flags), mode);
            }
            if (fd < 0) {
                logError(sqlite_cantopen, "open", name, @src().line);
                return error.CantOpen;
            }
        }
        if (mode != 0 and (flags.kind == .wal or flags.kind == .main_journal)) robustFchown(fd, uid, gid);
        errdefer _ = os(.close)(fd);

        // Like os_unix.c: unlink right away and let the descriptor keep the
        // data alive until it is closed.
        if (flags.delete_on_close) _ = os(.unlink)(name.ptr);

        // fillInUnixFile(): only a database is locked, and only POSIX
        // locks need the inode.
        const style: LockStyle = if (flags.kind != .main_db) .none else self.style;
        const path_copy = try self.gpa.dupeSentinel(u8, name, 0);
        errdefer self.gpa.free(path_copy);
        const lock_path: ?[:0]u8 = if (style == .dotfile) try std.fmt.allocPrintSentinel(self.gpa, "{s}.lock", .{name}, 0) else null;
        errdefer if (lock_path) |l| self.gpa.free(l);
        const inode: ?*InodeInfo = if (style == .posix) try InodeInfo.acquire(self.io, fd) else null;
        errdefer if (inode) |i| i.release(self.io);
        const handle = try self.gpa.create(UnixFile);
        handle.* = .{
            .owner = self,
            .h = fd,
            .inode = inode,
            .ctrl = .{
                .excl = self.excl,
                .rdonly = read_only,
                .dirsync = is_new_jrnl,
                .psow = if (flags.uri and path != null) vfs.uriBoolean(path.?, "psow", true) else true,
            },
            .path = path_copy,
            .style = style,
            .lock_path = lock_path,
            .main_path = if (flags.kind == .main_db and (flags.uri or flags.sqlite_filename)) path else null,
            .mmap_size_max = vfs.mmap_config.default_size,
        };
        return .{ .ptr = handle, .vtable = if (self.style == .posix) UnixFile.vtable else UnixFile.vtable_nolock };
    }

    /// Port of unixDelete().
    pub fn delete(self: *UnixVfs, path: []const u8, sync_dir: bool) Error!void {
        var buf: [vfs.max_path_bytes + 1]u8 = undefined;
        const z = try self.resolve(path, &buf);
        if (os(.unlink)(z.ptr) == -1) {
            if (errno() == eno(.NOENT)) return error.DeleteNoEnt;
            logError(ioerr_delete, "unlink", z, @src().line);
            return error.IoErr;
        }
        if (sync_dir) {
            var dfd: c_int = -1;
            if (os(.openDirectory)(z.ptr, &dfd) == 0) {
                defer closeFd(dfd, null);
                if (fullFsync(dfd, false) != 0) {
                    logError(ioerr_dir_fsync, "fsync", z, @src().line);
                    return error.IoErr;
                }
            }
        }
    }

    pub fn randomness(self: *UnixVfs, buf: []u8) void {
        self.io.random(buf);
    }

    /// Port of unixGetLastError(): errno.
    pub fn lastError(_: *UnixVfs) i32 {
        return errno();
    }

    /// Port of unixSleep().
    pub fn sleep(self: *UnixVfs, microseconds: u32) u32 {
        return vfs.ioSleep(self.io, microseconds);
    }

    /// Port of unixAccess(): a file "exists" if stat() finds it and it is
    /// not an empty regular file; otherwise (SQLITE_ACCESS_READWRITE, and
    /// SQLITE_ACCESS_READ, which C treats the same) whether it can be
    /// read and written.
    pub fn access(self: *UnixVfs, path: []const u8, mode: vfs.AccessMode) Error!bool {
        var buf: [vfs.max_path_bytes + 1]u8 = undefined;
        const z = try self.resolve(path, &buf);
        if (mode == .exists) {
            var st: Stat = undefined;
            return os(.stat)(z.ptr, &st) == 0 and (!isReg(st.mode) or st.size > 0);
        }
        return os(.access)(z.ptr, 6) == 0;
    }
};

/// Port of robust_close(): close(2) through the table, a failure logged.
fn closeFd(h: c_int, path: ?[]const u8) void {
    if (os(.close)(h) != 0) logError(ioerr_close, "close", path, @src().line);
}

/// Port of unixTempFileDir(): the directory of temporary files, the
/// first of sqlite3_temp_directory (root.zig's temp_directory, which
/// PRAGMA temp_store_directory sets), $SQLITE_TMPDIR, $TMPDIR, /var/tmp,
/// /usr/tmp, /tmp and "." that is a directory the process can write and
/// search.
fn tempFileDir() ?[]const u8 {
    const temp_directory = @import("root.zig").temp_directory;
    for (0..7) |i| {
        const z: ?[*:0]const u8 = switch (i) {
            0 => temp_directory,
            1 => c.getenv("SQLITE_TMPDIR"),
            2 => c.getenv("TMPDIR"),
            3 => "/var/tmp",
            4 => "/usr/tmp",
            5 => "/tmp",
            else => ".",
        };
        const dir = z orelse continue;
        var st: Stat = undefined;
        if (os(.stat)(dir, &st) == 0 and isDir(st.mode) and os(.access)(dir, 3) == 0) return std.mem.span(dir);
    }
    return null;
}

/// A pathname under construction (DbPath).
const DbPath = struct {
    out: []u8,
    used: usize = 0,
    /// Symbolic links resolved (nSymlink).
    n_symlink: u32 = 0,
    failed: bool = false,

    /// SQLITE_MAX_SYMLINK (os.h).
    const max_symlink = 200;

    /// Port of appendOnePathElement().
    fn appendOne(p: *DbPath, name: []const u8) void {
        std.debug.assert(name.len > 0);
        if (name[0] == '.') {
            if (name.len == 1) return;
            if (name[1] == '.' and name.len == 2) {
                if (p.used > 1) {
                    std.debug.assert(p.out[0] == '/');
                    p.used -= 1;
                    while (p.out[p.used] != '/') p.used -= 1;
                }
                return;
            }
        }
        if (p.used + name.len + 2 >= p.out.len) {
            p.failed = true;
            return;
        }
        p.out[p.used] = '/';
        p.used += 1;
        @memcpy(p.out[p.used..][0..name.len], name);
        p.used += name.len;
        if (p.failed) return;
        p.out[p.used] = 0;
        const z: [*:0]const u8 = @ptrCast(p.out.ptr);
        var st: Stat = undefined;
        if (os(.lstat)(z, &st) != 0) {
            if (errno() != eno(.NOENT)) {
                logError(sqlite_cantopen, "lstat", p.out[0..p.used], @src().line);
                p.failed = true;
            }
            return;
        }
        if (!isLnk(st.mode)) return;
        if (p.n_symlink > max_symlink) {
            p.failed = true;
            return;
        }
        p.n_symlink += 1;
        var lnk: [vfs.max_path_bytes + 2]u8 = undefined;
        const got = os(.readlink)(z, &lnk, lnk.len - 2);
        if (got <= 0 or got >= lnk.len - 2) {
            logError(sqlite_cantopen, "readlink", p.out[0..p.used], @src().line);
            p.failed = true;
            return;
        }
        const target = lnk[0..@intCast(got)];
        if (target[0] == '/') {
            p.used = 0;
        } else {
            p.used -= name.len + 1;
        }
        p.appendAll(target);
    }

    /// Port of appendAllPathElements().
    fn appendAll(p: *DbPath, path: []const u8) void {
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |name| {
            if (name.len > 0) p.appendOne(name);
        }
    }
};

/// Process-wide identity of a file (struct unixFileId).
const FileId = struct {
    dev: u64,
    ino: u64,

    fn of(st: *const Stat) FileId {
        const D = @TypeOf(st.dev);
        const dev: u64 = if (@typeInfo(D).int.signedness == .signed) @bitCast(@as(i64, st.dev)) else st.dev;
        return .{ .dev = dev, .ino = @intCast(st.ino) };
    }
};

/// The process-wide state of this VFS (unixBigLock and inodeList of
/// os_unix.c): POSIX locks belong to the process, so every handle on a
/// file, whatever connection or Vfs it comes from, has to share one
/// InodeInfo.
var inodes: Inodes = .{};

const Inodes = struct {
    /// unixBigLock: guards `table`, InodeInfo.ref_count and the ShmNodes.
    big_lock: Io.Mutex = .init,
    table: std.AutoHashMapUnmanaged(FileId, *InodeInfo) = .empty,
    /// What the full memory barrier of shmBarrier() is an atomic on.
    barrier_word: u32 = 0,

    /// The table outlives any one VFS instance, so it uses a global allocator.
    const gpa = std.heap.smp_allocator;
};

/// Lock state shared by every handle on one inode (struct unixInodeInfo).
///
/// Mutex rules mirror os_unix.c: `inodes.big_lock` guards the table and
/// `ref_count`; `mutex` guards the lock fields. Never take
/// `inodes.big_lock` while holding `mutex`.
const InodeInfo = struct {
    id: FileId,
    mutex: Io.Mutex = .init,
    /// Number of handles holding SHARED or stronger.
    n_shared: u32 = 0,
    /// Number of handles holding any OS-level lock.
    n_lock: u32 = 0,
    /// Strongest lock held through any handle.
    level: LockLevel = .none,
    /// The process holds an exclusive lock on the file ("unix-excl",
    /// bProcessLock): no more OS locks are taken or released.
    process_lock: bool = false,
    /// Descriptors whose close(2) is deferred until `n_lock` drops to zero
    /// (pUnused), and whether each was opened read-write.
    unused: std.ArrayList(UnusedFd) = .empty,
    ref_count: u32 = 0,
    /// The shared memory of this database, while any handle maps it
    /// (pShmNode). Created and destroyed under `inodes.big_lock`.
    shm_node: ?*ShmNode = null,

    /// Port of findInodeInfo().
    fn acquire(io: Io, fd: c_int) Error!*InodeInfo {
        var st: Stat = undefined;
        if (os(.fstat)(fd, &st) != 0) return error.IoErr;
        const id: FileId = .of(&st);
        inodes.big_lock.lockUncancelable(io);
        defer inodes.big_lock.unlock(io);
        const gop = try inodes.table.getOrPut(Inodes.gpa, id);
        if (!gop.found_existing) {
            const info = Inodes.gpa.create(InodeInfo) catch |err| {
                inodes.table.removeByPtr(gop.key_ptr);
                return err;
            };
            info.* = .{ .id = id };
            gop.value_ptr.* = info;
        }
        gop.value_ptr.*.ref_count += 1;
        return gop.value_ptr.*;
    }

    /// Port of releaseInodeInfo().
    fn release(info: *InodeInfo, io: Io) void {
        inodes.big_lock.lockUncancelable(io);
        defer inodes.big_lock.unlock(io);
        info.ref_count -= 1;
        if (info.ref_count != 0) return;
        info.mutex.lockUncancelable(io);
        info.closePendingFds();
        info.mutex.unlock(io);
        info.unused.deinit(Inodes.gpa);
        _ = inodes.table.remove(info.id);
        Inodes.gpa.destroy(info);
    }

    /// Caller holds `mutex`.
    fn closePendingFds(info: *InodeInfo) void {
        for (info.unused.items) |u| closeFd(u.fd, null);
        info.unused.clearRetainingCapacity();
    }
};

/// A descriptor kept open for a closed handle (UnixUnusedFd).
const UnusedFd = struct { fd: c_int, read_write: bool };

/// Port of findReusableFd(): a descriptor of database `name`, opened
/// read-write or read-only as asked, that a closed handle left for
/// close(2) while other handles hold locks: opening the database again
/// takes it instead of a new one, so that a connection opened and closed
/// many times while another holds a lock does not run out of them.
fn findReusableFd(io: Io, name: [:0]const u8, read_write: bool) ?c_int {
    inodes.big_lock.lockUncancelable(io);
    defer inodes.big_lock.unlock(io);
    if (inodes.table.count() == 0) return null;
    var st: Stat = undefined;
    if (os(.stat)(name.ptr, &st) != 0) return null;
    const info = inodes.table.get(.of(&st)) orelse return null;
    info.mutex.lockUncancelable(io);
    defer info.mutex.unlock(io);
    for (info.unused.items, 0..) |u, i| {
        if (u.read_write == read_write) {
            _ = info.unused.swapRemove(i);
            return u.fd;
        }
    }
    return null;
}

const LockType = enum { read, write, unlock };

fn flock(kind: LockType, start: u64, len: u64) c.Flock {
    var fl = std.mem.zeroes(c.Flock);
    fl.type = switch (kind) {
        .read => c.F.RDLCK,
        .write => c.F.WRLCK,
        .unlock => c.F.UNLCK,
    };
    fl.whence = std.posix.SEEK.SET;
    fl.start = @intCast(start);
    fl.len = @intCast(len);
    return fl;
}

/// Port of osSetPosixAdvisoryLock(): a non-blocking POSIX advisory lock
/// through the table. Null on success, else errno.
fn setPosixLock(fd: fd_t, kind: LockType, start: u64, len: u64) ?c_int {
    var fl = flock(kind, start, len);
    if (os(.fcntl)(fd, c.F.SETLK, &fl) == 0) return null;
    return errno();
}

const sysFlock = @extern(*const fn (c_int, c_int) callconv(.c) c_int, .{ .name = "flock" });

/// Port of robust_flock(): flock(2), retried on EINTR.
fn robustFlock(fd: c_int, op: c_int) c_int {
    while (true) {
        const rc = sysFlock(fd, op);
        if (rc < 0 and errno() == eno(.INTR)) continue;
        return rc;
    }
}

/// Port of sqliteErrorFromPosixError(): contention means BUSY, anything
/// else `other` (SQLITE_IOERR_LOCK and the like).
/// A failed lock: Busy, or LockErr with errno `e` kept for xGetLastError.
fn lockFailed(f: *UnixFile, e: c_int) Error {
    const err = lockError(e, error.LockErr);
    if (err != error.Busy) f.last_errno = e;
    return err;
}

fn lockError(e: c_int, other: Error) Error {
    if (e == eno(.ACCES) or e == eno(.AGAIN) or e == eno(.TIMEDOUT) or e == eno(.BUSY) or e == eno(.INTR) or e == eno(.NOLCK)) return error.Busy;
    return other;
}

// ======================================================== shared memory

/// UNIX_SHM_BASE: the first lock byte of the -shm file, which is the
/// WalCkptInfo.aLock[] array of the wal-index header.
const shm_base: u64 = (22 + vfs.shm_nlock) * 4;
/// UNIX_SHM_DMS: the dead-man switch. Every process using the -shm file
/// holds a shared lock on it; the first one to arrive (no lock held)
/// truncates the file, as its content may be left over from a crash.
const shm_dms: u64 = shm_base + vfs.shm_nlock;

/// The shared memory of one database, shared by every handle in this
/// process that maps it (struct unixShmNode).
///
/// `inodes.big_lock` guards creation, destruction and `n_ref`;
/// `mutex` guards everything else.
const ShmNode = struct {
    inode: *InodeInfo,
    mutex: Io.Mutex = .init,
    /// Name of the -shm file (zFilename).
    filename: [:0]u8,
    /// The open -shm file (hShm), or -1 if the process holds an
    /// exclusive lock on the database ("unix-excl"): the regions are
    /// then heap memory.
    h_shm: c_int,
    /// Size of each region (szRegion).
    sz_region: u32 = 0,
    /// The mapped regions (apRegion). A mapping covers `regionPerMap()`
    /// consecutive regions and is unmapped through its first one.
    regions: std.ArrayList([*]align(8) u8) = .empty,
    /// The -shm file could only be opened read-only (isReadonly).
    is_readonly: bool = false,
    /// The DMS lock is not held yet (isUnlocked).
    is_unlocked: bool = false,
    /// Handles connected to this node (nRef).
    n_ref: u32 = 0,
    /// Locks held by this process on each slot (aLock).
    locks: vfs.ShmLockTable = .{},

    /// The file lock of ShmLockTable.apply(): unixShmSystemLock() on
    /// the slots.
    pub fn lock(node: *ShmNode, kind: vfs.ShmLockTable.FileLock, ofst: u32, n: u32) Error!void {
        const k: LockType = switch (kind) {
            .read => .read,
            .write => .write,
            .unlock => .unlock,
        };
        return shmSystemLock(node, k, ofst + shm_base, n);
    }
};

/// One handle's connection to a `ShmNode` (struct unixShm).
const Shm = struct {
    node: *ShmNode,
    /// Locks held by this connection (sharedMask, exclMask).
    held: vfs.ShmLockTable.Held = .{},
};

/// Port of unixShmSystemLock(): apply a POSIX lock to bytes
/// `ofst`..`ofst+n-1` of the -shm file (none for heap memory). Any
/// failure is reported as Busy.
fn shmSystemLock(node: *ShmNode, kind: LockType, ofst: u64, n: u64) Error!void {
    std.debug.assert((ofst == shm_dms and n == 1) or (ofst >= shm_base and ofst + n <= shm_base + vfs.shm_nlock));
    std.debug.assert(n == 1 or kind != .read);
    if (node.h_shm < 0) return;
    if (setPosixLock(node.h_shm, kind, ofst, n) != null) return error.Busy;
}

/// Port of unixShmRegionPerMap(): how many 32 KiB regions one mapping
/// covers, so that each mapping is a whole number of system pages.
fn shmRegionPerMap() u32 {
    const shmsz = 32 * 1024;
    const pgsz: u32 = @intCast(os(.getpagesize)());
    if (pgsz < shmsz) return 1;
    return pgsz / shmsz;
}

/// Port of unixShmPurge(): free the inode's ShmNode once nothing refers to
/// it. Caller holds `inodes.big_lock`.
fn shmPurge(inode: *InodeInfo) void {
    const node = inode.shm_node orelse return;
    if (node.n_ref != 0) return;
    const per_map = shmRegionPerMap();
    var i: usize = 0;
    while (i < node.regions.items.len) : (i += per_map) {
        const len = @as(usize, node.sz_region) * per_map;
        if (node.h_shm >= 0) {
            _ = os(.munmap)(node.regions.items[i], len);
        } else {
            Inodes.gpa.free(node.regions.items[i][0..len]);
        }
    }
    node.regions.deinit(Inodes.gpa);
    if (node.h_shm >= 0) closeFd(node.h_shm, node.filename);
    Inodes.gpa.free(node.filename);
    inode.shm_node = null;
    Inodes.gpa.destroy(node);
}

/// Port of unixLockSharedMemory(): take the shared DMS lock, first
/// truncating the -shm file if no other process uses it. Returns true
/// (SQLITE_READONLY_CANTINIT) instead if the -shm file is read-only and
/// no other process uses it, leaving the node unlocked.
fn shmLockSharedMemory(node: *ShmNode) Error!bool {
    var fl = flock(.write, shm_dms, 1);
    if (os(.fcntl)(node.h_shm, c.F.GETLK, &fl) != 0) return error.LockErr;
    if (fl.type == c.F.UNLCK) {
        if (node.is_readonly) {
            node.is_unlocked = true;
            return true;
        }
        try shmSystemLock(node, .write, shm_dms, 1);
        // Truncated to 3 bytes rather than 0, as a debugging aid, like
        // os_unix.c: it tells a legitimate truncation from a rogue one.
        if (robustFtruncate(node.h_shm, 3) != 0) {
            logError(ioerr_shmopen, "ftruncate", node.filename, @src().line);
            return error.ShmOpen;
        }
    } else if (fl.type == c.F.WRLCK) {
        return error.Busy;
    }
    try shmSystemLock(node, .read, shm_dms, 1);
    return false;
}

const UnixFile = struct {
    owner: *UnixVfs,
    /// The descriptor (h).
    h: c_int,
    /// Null for a file that is not a database (UNIXFILE_NOLOCK).
    inode: ?*InodeInfo,
    level: LockLevel = .none,
    ctrl: Ctrl,
    /// errno of the last failed system call (lastErrno).
    last_errno: c_int = 0,
    /// The name the file was opened with (zPath).
    path: [:0]u8,
    /// How the file is locked (its io methods).
    style: UnixVfs.LockStyle,
    /// "unix-dotfile": the directory that is the lock (lockingContext).
    lock_path: ?[:0]u8 = null,
    /// The database's name in SQLite's filename layout, as the pager
    /// passed it, for its URI parameters (readonly_shm). Null for other
    /// files, and for a name not in that layout.
    main_path: ?[]const u8 = null,
    /// SQLITE_FCNTL_CHUNK_SIZE (szChunk).
    sz_chunk: i32 = 0,
    /// This handle's connection to the shared memory (pShm).
    shm: ?*Shm = null,
    /// The memory map of the file (pMapRegion, mmapSizeActual bytes),
    /// its usable size (mmapSize, which a truncation may lower below the
    /// size mapped), the largest size to map (mmapSizeMax) and the
    /// pointers into it handed out by fetch() (nFetchOut).
    map_region: ?[*]const u8 = null,
    mmap_size_actual: u64 = 0,
    mmap_size: u64 = 0,
    mmap_size_max: i64 = 0,
    n_fetch_out: u32 = 0,
    /// The embedder's handle on the file (File.foreign).
    foreign_slot: vfs.ForeignSlot = @splat(0),

    /// The UNIXFILE_* bits (ctrlFlags).
    const Ctrl = packed struct {
        excl: bool = false,
        rdonly: bool = false,
        persist_wal: bool = false,
        dirsync: bool = false,
        psow: bool = false,
    };

    /// The methods named after those of vfs.File.VTable implement it
    /// (vfs.FileImpl()).
    const vtable = &vfs.FileImpl(UnixFile).vtable;
    /// Port of dotlockCheckReservedLock().
    fn dotlockCheckReservedLock(f: *UnixFile) Error!bool {
        if (f.level.atLeast(.shared)) return false;
        return os(.access)(f.lock_path.?.ptr, 0) == 0;
    }

    /// Port of dotlockLock(): any lock is the directory; a lock held is
    /// only raised.
    fn dotlockLock(f: *UnixFile, level: LockLevel) Error!void {
        if (f.level != .none) {
            f.level = level;
            return;
        }
        if (os(.mkdir)(f.lock_path.?.ptr, 0o777) < 0) {
            const e = errno();
            if (e == eno(.EXIST)) return error.Busy;
            return lockFailed(f, e);
        }
        f.level = level;
    }

    /// Port of dotlockUnlock().
    fn dotlockUnlock(f: *UnixFile, level: LockLevel) Error!void {
        if (f.level == level) return;
        if (level == .shared) {
            f.level = .shared;
            return;
        }
        if (os(.rmdir)(f.lock_path.?.ptr) < 0) {
            const e = errno();
            if (e == eno(.NOENT)) return;
            f.last_errno = e;
            return error.LockErr;
        }
        f.level = .none;
    }

    /// Port of flockCheckReservedLock(): flock locks are exclusive, so
    /// no other connection can hold RESERVED while we hold anything,
    /// and without a lock we let the caller try for EXCLUSIVE.
    fn flockCheckReservedLock(_: *UnixFile) Error!bool {
        return false;
    }

    /// Port of flockLock(): every lock is an exclusive flock().
    fn flockLock(f: *UnixFile, level: LockLevel) Error!void {
        if (f.level != .none) {
            f.level = level;
            return;
        }
        if (robustFlock(f.h, c.LOCK.EX | c.LOCK.NB) != 0) return lockFailed(f, errno());
        f.level = level;
    }

    /// Port of flockUnlock().
    fn flockUnlock(f: *UnixFile, level: LockLevel) Error!void {
        if (f.level == level) return;
        if (level == .shared) {
            f.level = .shared;
            return;
        }
        if (robustFlock(f.h, c.LOCK.UN) != 0) return error.LockErr;
        f.level = .none;
    }

    /// The methods of the styles without shared memory (nolockIoMethods,
    /// dotlockIoMethods, flockIoMethods); lock() and the like go by
    /// `style`.
    const vtable_nolock = &nolock_methods;
    const nolock_methods: vfs.File.VTable = blk: {
        var t = vfs.FileImpl(UnixFile).vtable;
        t.shmMap = null;
        t.shmLock = null;
        t.shmBarrier = null;
        t.shmUnmap = null;
        const r = t;
        break :blk r;
    };

    /// Port of unixClose() and closeUnixFile().
    pub fn close(f: *UnixFile) void {
        const io = f.owner.io;
        // The WAL unmaps the shared memory before the database closes.
        std.debug.assert(f.shm == null);
        if (f.shm != null) shmUnmap(f, false);
        unlock(f, .none) catch {};
        if (f.lock_path) |l| f.owner.gpa.free(l);
        f.unmapFile();
        if (f.inode) |inode| {
            inode.mutex.lockUncancelable(io);
            if (inode.n_lock != 0) {
                // Closing now would release locks held through other
                // handles (setPendingFd()).
                inode.unused.append(Inodes.gpa, .{ .fd = f.h, .read_write = !f.ctrl.rdonly }) catch {
                    // Out of memory: leak the descriptor rather than
                    // break locks.
                };
                f.h = -1;
            }
            inode.mutex.unlock(io);
            inode.release(io);
        }
        if (f.h >= 0) closeFd(f.h, f.path);
        f.owner.gpa.free(f.path);
        f.owner.gpa.destroy(f);
    }

    /// Port of seekAndRead(): pread() until `buf` is full, the end of the
    /// file, or an error (-1, errno in last_errno).
    fn seekAndRead(f: *UnixFile, buf_arg: []u8, offset_arg: u64) isize {
        var buf = buf_arg;
        var offset = offset_arg;
        var prior: isize = 0;
        while (true) {
            const got = os(.pread)(f.h, buf.ptr, buf.len, @intCast(offset));
            if (got == buf.len) return prior + got;
            if (got < 0) {
                if (errno() == eno(.INTR)) continue;
                f.last_errno = errno();
                return -1;
            }
            if (got == 0) return prior;
            buf = buf[@intCast(got)..];
            offset += @intCast(got);
            prior += got;
        }
    }

    /// Port of unixRead().
    pub fn read(f: *UnixFile, buf_arg: []u8, offset_arg: u64) Error!usize {
        var buf = buf_arg;
        var offset = offset_arg;
        // As much as the memory map holds is copied out of it.
        if (offset < f.mmap_size) {
            const map = f.map_region.?;
            if (offset + buf.len <= f.mmap_size) {
                @memcpy(buf, map[@intCast(offset)..][0..buf.len]);
                return buf.len;
            }
            const n: usize = @intCast(f.mmap_size - offset);
            @memcpy(buf[0..n], map[@intCast(offset)..][0..n]);
            buf = buf[n..];
            offset += n;
        }
        const got = f.seekAndRead(buf, offset);
        if (got < 0) return error.IoErr;
        if (got < buf.len) f.last_errno = 0;
        return buf_arg.len - buf.len + @as(usize, @intCast(got));
    }

    /// Port of seekAndWriteFd(): one pwrite(), retried on EINTR.
    fn seekAndWriteFd(fd: c_int, offset: u64, buf: []const u8, err: *c_int) isize {
        while (true) {
            const rc = os(.pwrite)(fd, buf.ptr, buf.len, @intCast(offset));
            if (rc < 0 and errno() == eno(.INTR)) continue;
            if (rc < 0) err.* = errno();
            return rc;
        }
    }

    /// Port of unixWrite().
    pub fn write(f: *UnixFile, buf_arg: []const u8, offset_arg: u64) Error!void {
        if (f.ctrl.rdonly) return error.ReadOnly;
        var buf = buf_arg;
        var offset = offset_arg;
        var wrote: isize = 0;
        while (buf.len > 0) {
            wrote = seekAndWriteFd(f.h, offset, buf, &f.last_errno);
            if (wrote <= 0) break;
            buf = buf[@intCast(wrote)..];
            offset += @intCast(wrote);
        }
        if (buf.len > 0) {
            if (wrote < 0 and f.last_errno != eno(.NOSPC)) return error.IoErr;
            f.last_errno = 0;
            return error.DiskFull;
        }
    }

    /// Port of unixTruncate(): to `size` rounded up to the chunk size.
    pub fn truncate(f: *UnixFile, size_arg: u64) Error!void {
        if (f.ctrl.rdonly) return error.ReadOnly;
        var size: i64 = @intCast(size_arg);
        if (f.sz_chunk > 0) size = @divTrunc(size + f.sz_chunk - 1, f.sz_chunk) * f.sz_chunk;
        if (robustFtruncate(f.h, size) != 0) {
            f.last_errno = errno();
            logError(ioerr_truncate, "ftruncate", f.path, @src().line);
            return error.IoErr;
        }
        // Past the new end, read() and write() are used from now on.
        if (size < f.mmap_size) f.mmap_size = @intCast(size);
    }

    /// Port of unixSync(), with the directory of a new journal synced
    /// the first time (UNIXFILE_DIRSYNC).
    pub fn sync(f: *UnixFile, flags: vfs.SyncFlags) Error!void {
        if (fullFsync(f.h, flags.full) != 0) {
            f.last_errno = errno();
            logError(ioerr_fsync, "full_fsync", f.path, @src().line);
            return error.IoErr;
        }
        if (f.ctrl.dirsync) {
            var dfd: c_int = -1;
            if (os(.openDirectory)(f.path.ptr, &dfd) == 0) {
                _ = fullFsync(dfd, false);
                closeFd(dfd, f.path);
            }
            f.ctrl.dirsync = false;
        }
    }

    /// Port of unixFileSize(): a file of one byte counts as empty (the
    /// one byte an msdos filesystem workaround of C may leave).
    pub fn fileSize(f: *UnixFile) Error!u64 {
        var st: Stat = undefined;
        if (os(.fstat)(f.h, &st) != 0) {
            f.last_errno = errno();
            return error.IoErr;
        }
        const n: u64 = @intCast(st.size);
        return if (n == 1) 0 else n;
    }

    /// Port of unixFileLock(): a lock on the file, unless this is a
    /// read-write "unix-excl" file: then the first call takes an
    /// exclusive lock on the shared range for the process, and the
    /// others do nothing. Null on success, else errno.
    fn fileLock(f: *UnixFile, kind: LockType, start: u64, len: u64) ?c_int {
        const inode = f.inode.?;
        if (f.ctrl.excl and !f.ctrl.rdonly) {
            if (!inode.process_lock) {
                if (setPosixLock(f.h, .write, vfs.sharedFirst(), vfs.shared_size)) |e| return e;
                inode.process_lock = true;
                inode.n_lock += 1;
            }
            return null;
        }
        return setPosixLock(f.h, kind, start, len);
    }

    /// Port of unixLock(). See vfs.LockLevel for the allowed transitions.
    pub fn lock(f: *UnixFile, level: LockLevel) Error!void {
        switch (f.style) {
            .posix => {},
            // nolockLock().
            .none => return,
            .dotfile => return dotlockLock(f, level),
            .flock => return flockLock(f, level),
        }
        if (f.level.atLeast(level)) return;
        const inode = f.inode.?;

        const io = f.owner.io;
        inode.mutex.lockUncancelable(io);
        defer inode.mutex.unlock(io);

        // Another handle in this process holds a lock that precludes ours.
        if (f.level != inode.level and
            (inode.level.atLeast(.pending) or level.atLeast(.reserved)))
        {
            return error.Busy;
        }

        // Piggy-back on a SHARED/RESERVED lock already held by this process.
        if (level == .shared and (inode.level == .shared or inode.level == .reserved)) {
            f.level = .shared;
            inode.n_shared += 1;
            inode.n_lock += 1;
            return;
        }

        // PENDING: read-locked while taking the shared range so that a
        // writer waiting for EXCLUSIVE is not starved, then dropped; or
        // write-locked to block new readers while we wait for existing
        // ones.
        if (level == .shared or (level == .exclusive and f.level == .reserved)) {
            if (f.fileLock(if (level == .shared) .read else .write, vfs.pending_byte, 1)) |e| return lockFailed(f, e);
            if (level == .exclusive) {
                f.level = .pending;
                inode.level = .pending;
            }
        }

        if (level == .shared) {
            std.debug.assert(inode.n_shared == 0 and inode.level == .none);
            var rc: Error!void = {};
            var t_errno: c_int = 0;
            if (f.fileLock(.read, vfs.sharedFirst(), vfs.shared_size)) |e| {
                t_errno = e;
                rc = lockError(e, error.LockErr);
            }
            if (f.fileLock(.unlock, vfs.pending_byte, 1)) |e| {
                if (rc) |_| {
                    t_errno = e;
                    rc = error.LockErr;
                } else |_| {}
            }
            rc catch |err| {
                if (err != error.Busy) f.last_errno = t_errno;
                return err;
            };
            f.level = .shared;
            inode.n_lock += 1;
            inode.n_shared = 1;
        } else if (level == .exclusive and inode.n_shared > 1) {
            // Another handle in this process still reads the database.
            return error.Busy;
        } else if (f.isSharingShmNode()) {
            // Locks of another process on the -shm file: database locks
            // have been broken (a rogue close(open(db)), say).
            return error.Busy;
        } else {
            const e = if (level == .reserved)
                f.fileLock(.write, vfs.reservedByte(), 1)
            else
                f.fileLock(.write, vfs.sharedFirst(), vfs.shared_size);
            if (e) |x| return lockFailed(f, x);
        }
        f.level = level;
        inode.level = level;
    }

    /// Port of posixUnlock() without the NFS workaround.
    pub fn unlock(f: *UnixFile, level: LockLevel) Error!void {
        switch (f.style) {
            .posix => {},
            // nolockUnlock().
            .none => return,
            .dotfile => return dotlockUnlock(f, level),
            .flock => return flockUnlock(f, level),
        }
        if (!f.level.atLeast(level) or f.level == level) return;
        const inode = f.inode.?;

        const io = f.owner.io;
        inode.mutex.lockUncancelable(io);
        defer inode.mutex.unlock(io);

        if (f.level.atLeast(.reserved)) {
            if (level == .shared) {
                if (f.fileLock(.read, vfs.sharedFirst(), vfs.shared_size)) |e| {
                    f.last_errno = e;
                    return error.LockErr;
                }
            }
            // Releases PENDING and RESERVED together.
            if (f.fileLock(.unlock, vfs.pending_byte, 2)) |e| {
                f.last_errno = e;
                return error.LockErr;
            }
            inode.level = .shared;
        }

        var rc: Error!void = {};
        if (level == .none) {
            inode.n_shared -= 1;
            if (inode.n_shared == 0) {
                if (f.fileLock(.unlock, 0, 0)) |e| {
                    rc = error.LockErr;
                    f.last_errno = e;
                    f.level = .none;
                }
                inode.level = .none;
            }
            inode.n_lock -= 1;
            if (inode.n_lock == 0) inode.closePendingFds();
        }
        try rc;
        f.level = level;
    }

    /// Port of unixCheckReservedLock().
    pub fn checkReservedLock(f: *UnixFile) Error!bool {
        switch (f.style) {
            .posix => {},
            .none => return false,
            .dotfile => return dotlockCheckReservedLock(f),
            .flock => return flockCheckReservedLock(f),
        }
        const inode = f.inode.?;
        const io = f.owner.io;
        inode.mutex.lockUncancelable(io);
        defer inode.mutex.unlock(io);
        if (inode.level.atLeast(.reserved)) return true;
        if (inode.process_lock) return false;
        var fl = flock(.write, vfs.reservedByte(), 1);
        if (os(.fcntl)(f.h, c.F.GETLK, &fl) != 0) {
            f.last_errno = errno();
            return error.IoErr;
        }
        return fl.type != c.F.UNLCK;
    }

    /// Port of unixIsSharingShmNode(): whether another process holds the
    /// DMS lock of the -shm file this handle maps.
    fn isSharingShmNode(f: *UnixFile) bool {
        const p = f.shm orelse return false;
        if (f.ctrl.excl) return false;
        var fl = flock(.write, shm_dms, 1);
        _ = os(.fcntl)(p.node.h_shm, c.F.GETLK, &fl);
        return fl.type != c.F.UNLCK;
    }

    pub fn sectorSize(_: *UnixFile) u32 {
        return vfs.default_sector_size;
    }

    /// Port of unixDeviceCharacteristics() (setDeviceCharacteristics()):
    /// powersafe overwrite unless the URI parameter psow=0 or
    /// SQLITE_FCNTL_POWERSAFE_OVERWRITE turned it off, and sub-page
    /// reads.
    pub fn deviceCharacteristics(f: *UnixFile) vfs.DeviceCharacteristics {
        return .{ .powersafe_overwrite = f.ctrl.psow, .subpage_read = true };
    }

    pub fn isReadOnly(f: *UnixFile) bool {
        return f.ctrl.rdonly;
    }

    pub fn foreign(f: *UnixFile) *vfs.ForeignSlot {
        return &f.foreign_slot;
    }

    /// Port of fileHasMoved(): whether the name the file was opened by
    /// names another file now, or none.
    fn hasMoved(f: *UnixFile) bool {
        const inode = f.inode orelse return false;
        var st: Stat = undefined;
        return os(.stat)(f.path.ptr, &st) != 0 or @as(u64, @intCast(st.ino)) != inode.id.ino;
    }

    /// Port of unixModeBit().
    fn modeBit(bit: *bool, arg: *i32) void {
        if (arg.* < 0) {
            arg.* = @intFromBool(bit.*);
        } else {
            bit.* = arg.* != 0;
        }
    }

    /// Port of unixFileControl() (but SQLITE_FCNTL_MMAP_SIZE: mmapSize(),
    /// and those the C ABI answers: VFSNAME, TEMPFILENAME).
    pub fn fileControl(f: *UnixFile, op: vfs.FileControl) Error!bool {
        switch (op) {
            .lockstate => |out| out.* = f.level,
            .last_errno => |out| out.* = f.last_errno,
            .chunk_size => |n| f.sz_chunk = n,
            .size_hint => |n| try f.sizeHint(n),
            .persist_wal => |arg| {
                var b = f.ctrl.persist_wal;
                modeBit(&b, arg);
                f.ctrl.persist_wal = b;
            },
            .powersafe_overwrite => |arg| {
                var b = f.ctrl.psow;
                modeBit(&b, arg);
                f.ctrl.psow = b;
            },
            .has_moved => |out| out.* = f.hasMoved(),
            .external_reader => |out| out.* = try f.externalReader(),
            .vfsname => |out| out.* = if (f.owner.excl) "unix-excl" else "unix",
        }
        return true;
    }

    /// Port of fcntlSizeHint(): with a chunk size, grow the file to a
    /// multiple of it that holds `n_byte` bytes, writing a byte per
    /// filesystem block (C uses posix_fallocate() where configured); then
    /// map that much if memory maps are on.
    fn sizeHint(f: *UnixFile, n_byte: i64) Error!void {
        if (f.sz_chunk > 0) {
            var st: Stat = undefined;
            if (os(.fstat)(f.h, &st) != 0) return error.IoErr;
            const n_size = @divTrunc(n_byte + f.sz_chunk - 1, f.sz_chunk) * f.sz_chunk;
            if (n_size > st.size) {
                const n_blk: i64 = @intCast(st.blksize);
                var i_write = @divTrunc(@as(i64, @intCast(st.size)), n_blk) * n_blk + n_blk - 1;
                while (i_write < n_size + n_blk - 1) : (i_write += n_blk) {
                    if (i_write >= n_size) i_write = n_size - 1;
                    if (seekAndWriteFd(f.h, @intCast(i_write), &.{0}, &f.last_errno) != 1) return error.IoErr;
                }
            }
        }
        if (f.mmap_size_max > 0 and n_byte > f.mmap_size) {
            if (f.sz_chunk <= 0) {
                if (robustFtruncate(f.h, n_byte) != 0) {
                    f.last_errno = errno();
                    logError(ioerr_truncate, "ftruncate", f.path, @src().line);
                    return error.IoErr;
                }
            }
            try f.mapFile(@intCast(n_byte));
        }
    }

    /// Port of unixFcntlExternalReader(): whether another process holds a
    /// read lock of the wal-index (slots 3 and up).
    fn externalReader(f: *UnixFile) Error!bool {
        const p = f.shm orelse return false;
        const node = p.node;
        const io = f.owner.io;
        var fl = flock(.write, shm_base + 3, vfs.shm_nlock - 3);
        node.mutex.lockUncancelable(io);
        defer node.mutex.unlock(io);
        if (os(.fcntl)(node.h_shm, c.F.GETLK, &fl) < 0) return error.LockErr;
        return fl.type != c.F.UNLCK;
    }

    /// Port of unixOpenSharedMemory(): connect this handle to the inode's
    /// ShmNode, creating it (and opening the -shm file) if this is the
    /// first handle in the process. Returns true (SQLITE_READONLY_CANTINIT)
    /// if a new node could not be locked because it is read-only and has
    /// no other user; the handle is connected all the same.
    fn openSharedMemory(f: *UnixFile) Error!bool {
        std.debug.assert(f.shm == null);
        const io = f.owner.io;
        const gpa = Inodes.gpa;
        const inode = f.inode orelse return error.ShmOpen;
        const p = try gpa.create(Shm);
        errdefer gpa.destroy(p);

        inodes.big_lock.lockUncancelable(io);
        defer inodes.big_lock.unlock(io);
        var cant_init = false;
        const node = inode.shm_node orelse blk: {
            var st: Stat = undefined;
            if (os(.fstat)(f.h, &st) != 0) return error.IoErr;
            const name = try std.mem.concatWithSentinel(gpa, u8, &.{ f.path, "-shm" }, 0);
            const node = gpa.create(ShmNode) catch |err| {
                gpa.free(name);
                return err;
            };
            node.* = .{ .inode = inode, .filename = name, .h_shm = -1 };
            inode.shm_node = node;
            if (!inode.process_lock) {
                // Create it with the permissions of the database.
                const perm: mode_t = @intCast(@as(u32, st.mode) & 0o777);
                const readonly_shm = if (f.main_path) |mp| vfs.uriBoolean(mp, "readonly_shm", false) else false;
                if (!readonly_shm) {
                    node.h_shm = robustOpen(name.ptr, oflags(.{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }), perm);
                }
                if (node.h_shm < 0) {
                    node.h_shm = robustOpen(name.ptr, oflags(.{ .NOFOLLOW = true }), perm);
                    if (node.h_shm < 0) {
                        logError(sqlite_cantopen, "open", name, @src().line);
                        shmPurge(inode);
                        return error.CantOpen;
                    }
                    node.is_readonly = true;
                }
                // If this process runs as root, the owner of the database
                // keeps access to the -shm file.
                robustFchown(node.h_shm, st.uid, st.gid);
                cant_init = shmLockSharedMemory(node) catch |err| {
                    // Frees the node, which nothing refers to yet.
                    shmPurge(inode);
                    return err;
                };
            }
            break :blk node;
        };
        p.* = .{ .node = node };
        node.n_ref += 1;
        f.shm = p;
        return cant_init;
    }

    // ========================================================= memory map

    /// Port of unixUnmapfile().
    fn unmapFile(f: *UnixFile) void {
        std.debug.assert(f.n_fetch_out == 0);
        if (f.map_region) |r| {
            _ = os(.munmap)(@ptrCast(@constCast(r)), f.mmap_size_actual);
            f.map_region = null;
            f.mmap_size = 0;
            f.mmap_size_actual = 0;
        }
    }

    /// Port of unixRemapfile(): map the first `n_new` bytes of the file.
    /// A failure leaves the file unmapped and turns memory maps off for
    /// it, as C assumes later attempts would fail too. Growing a mapping
    /// extends it in place where the system allows (mremap() on Linux).
    fn remapFile(f: *UnixFile, n_new_arg: u64) void {
        std.debug.assert(f.n_fetch_out == 0 and n_new_arg > 0);
        var n_new = n_new_arg;
        const prot: c_int = 1; // PROT_READ
        const map_shared: c_int = 1;
        var err_name: []const u8 = "mmap";
        var p_new: ?*anyopaque = null;
        if (f.map_region) |orig_c| {
            const orig: [*]u8 = @constCast(orig_c);
            const pgsz: u64 = @intCast(os(.getpagesize)());
            const n_reuse = f.mmap_size & ~(pgsz - 1);
            if (n_reuse < f.mmap_size_actual) _ = os(.munmap)(orig + n_reuse, f.mmap_size_actual - n_reuse);
            if (n_reuse > 0) {
                if (is_linux) {
                    p_new = os(.mremap)(orig, n_reuse, n_new, 1); // MREMAP_MAYMOVE
                    err_name = "mremap";
                } else {
                    p_new = os(.mmap)(orig + n_reuse, n_new - n_reuse, prot, map_shared, f.h, @intCast(n_reuse));
                    if (p_new != c.MAP_FAILED) {
                        if (p_new != @as(?*anyopaque, orig + n_reuse)) {
                            _ = os(.munmap)(p_new, n_new - n_reuse);
                            p_new = null;
                        } else {
                            p_new = orig;
                        }
                    }
                }
                if (p_new == c.MAP_FAILED or p_new == null) _ = os(.munmap)(orig, n_reuse);
            }
        }
        if (p_new == null) p_new = os(.mmap)(null, n_new, prot, map_shared, f.h, 0);
        if (p_new == c.MAP_FAILED) {
            p_new = null;
            n_new = 0;
            logError(0, err_name, f.path, @src().line);
            f.mmap_size_max = 0;
        }
        f.map_region = @ptrCast(p_new);
        f.mmap_size = n_new;
        f.mmap_size_actual = n_new;
    }

    /// Port of unixMapfile(): map the file, up to `n_map` bytes or its
    /// size if `n_map` is null, but no more than `mmap_size_max`. Nothing
    /// changes while pointers into the map are out.
    fn mapFile(f: *UnixFile, n_map_arg: ?u64) Error!void {
        if (f.n_fetch_out > 0) return;
        var n_map = n_map_arg orelse blk: {
            var st: Stat = undefined;
            if (os(.fstat)(f.h, &st) != 0) return error.IoErr;
            break :blk @as(u64, @intCast(st.size));
        };
        if (n_map > @as(u64, @intCast(f.mmap_size_max))) n_map = @intCast(f.mmap_size_max);
        if (n_map == f.mmap_size) return;
        if (n_map == 0) return f.unmapFile();
        f.remapFile(n_map);
    }

    /// Port of unixFetch(): a pointer to `amt` bytes at `offset` in the
    /// map, if 256 more bytes after them are mapped too (a corrupt page
    /// may be overread by a few bytes); else null.
    pub fn fetch(f: *UnixFile, offset: u64, amt: u32) Error!?[*]const u8 {
        if (f.mmap_size_max <= 0) return null;
        const eof_buffer = 256;
        if (f.map_region == null) try f.mapFile(null);
        if (f.mmap_size >= offset + amt + eof_buffer) {
            f.n_fetch_out += 1;
            return f.map_region.? + @as(usize, @intCast(offset));
        }
        return null;
    }

    /// Port of unixUnfetch().
    pub fn unfetch(f: *UnixFile, offset: u64, p: ?[*]const u8) void {
        _ = offset;
        if (p != null) {
            f.n_fetch_out -= 1;
        } else {
            f.unmapFile();
        }
    }

    /// SQLITE_FCNTL_MMAP_SIZE of unixFileControl().
    pub fn mmapSize(f: *UnixFile, new_limit_arg: i64) Error!?i64 {
        var new_limit = new_limit_arg;
        if (new_limit > vfs.mmap_config.max_size) new_limit = vfs.mmap_config.max_size;
        // mmap() takes a size_t: at most 2 GiB where it is 32 bits.
        if (new_limit > 0 and @sizeOf(usize) < 8) new_limit &= 0x7fffffff;
        const old = f.mmap_size_max;
        if (new_limit >= 0 and new_limit != f.mmap_size_max and f.n_fetch_out == 0) {
            f.mmap_size_max = new_limit;
            if (f.mmap_size > 0) {
                f.unmapFile();
                try f.mapFile(null);
            }
        }
        return old;
    }

    /// Port of unixShmMap(): region `region` of the shared memory, each
    /// region `size` bytes, extending the -shm file if `extend`.
    pub fn shmMap(f: *UnixFile, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        const io = f.owner.io;
        const cant_init: vfs.ShmRegion = .{ .ptr = null, .read_only = true, .cant_init = true };
        if (f.shm == null) {
            if (try f.openSharedMemory()) return cant_init;
        }
        const node = f.shm.?.node;
        node.mutex.lockUncancelable(io);
        defer node.mutex.unlock(io);
        if (node.is_unlocked) {
            if (try shmLockSharedMemory(node)) return cant_init;
            node.is_unlocked = false;
        }
        std.debug.assert(size == node.sz_region or node.regions.items.len == 0);

        const per_map = shmRegionPerMap();
        const n_req = ((region + per_map) / per_map) * per_map;
        if (node.regions.items.len < n_req) map: {
            node.sz_region = size;
            const n_byte = @as(u64, n_req) * size;
            if (node.h_shm >= 0) {
                var st: Stat = undefined;
                if (os(.fstat)(node.h_shm, &st) != 0) return error.ShmSize;
                const cur: u64 = @intCast(st.size);
                if (cur < n_byte) {
                    if (!extend) break :map;
                    // Write the last byte of every new 4 KiB page, so that
                    // the OS allocates them now rather than raising SIGBUS
                    // later.
                    const pgsz = 4096;
                    var pg = cur / pgsz;
                    while (pg < n_byte / pgsz) : (pg += 1) {
                        var x: c_int = 0;
                        if (seekAndWriteFd(node.h_shm, pg * pgsz + pgsz - 1, &.{0}, &x) != 1) {
                            logError(ioerr_shmsize, "write", node.filename, @src().line);
                            return error.ShmSize;
                        }
                    }
                }
            }
            try node.regions.ensureTotalCapacity(Inodes.gpa, n_req);
            while (node.regions.items.len < n_req) {
                const n_map = @as(usize, size) * per_map;
                const mem: [*]align(8) u8 = if (node.h_shm >= 0) m: {
                    const prot: c_int = if (node.is_readonly) 1 else 3;
                    const m = os(.mmap)(null, n_map, prot, 1, node.h_shm, @intCast(@as(u64, size) * node.regions.items.len));
                    if (m == c.MAP_FAILED or m == null) {
                        logError(ioerr_shmmap, "mmap", node.filename, @src().line);
                        return error.ShmMap;
                    }
                    break :m @ptrCast(@alignCast(m.?));
                } else m: {
                    const m = try Inodes.gpa.alignedAlloc(u8, .@"8", n_map);
                    @memset(m, 0);
                    break :m m.ptr;
                };
                for (0..per_map) |i| node.regions.appendAssumeCapacity(@alignCast(mem + size * i));
            }
        }
        return .{
            .ptr = if (node.regions.items.len > region) node.regions.items[region] else null,
            .read_only = node.is_readonly,
        };
    }

    /// Port of unixShmLock(). Shared locks are counted per process, so
    /// the POSIX lock is only released with the last one.
    pub fn shmLock(f: *UnixFile, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        const p = f.shm orelse return error.ShmLock;
        if (!vfs.ShmLockTable.needed(p.held, ofst, n, flags)) return;
        const node = p.node;
        const io = f.owner.io;
        node.mutex.lockUncancelable(io);
        defer node.mutex.unlock(io);
        return node.locks.apply(&p.held, ofst, n, flags, node);
    }

    /// Port of unixShmBarrier(): a full memory barrier, plus the global
    /// mutex for redundancy, as in os_unix.c.
    pub fn shmBarrier(f: *UnixFile) void {
        _ = @atomicRmw(u32, &inodes.barrier_word, .Add, 0, .seq_cst);
        inodes.big_lock.lockUncancelable(f.owner.io);
        inodes.big_lock.unlock(f.owner.io);
    }

    /// Port of unixShmUnmap(): disconnect this handle from the shared
    /// memory; the last one out deletes the -shm file if `delete`.
    pub fn shmUnmap(f: *UnixFile, delete_flag: bool) void {
        const p = f.shm orelse return;
        const node = p.node;
        const io = f.owner.io;
        Inodes.gpa.destroy(p);
        f.shm = null;

        inodes.big_lock.lockUncancelable(io);
        defer inodes.big_lock.unlock(io);
        std.debug.assert(node.n_ref > 0);
        node.n_ref -= 1;
        if (node.n_ref == 0) {
            if (delete_flag and node.h_shm >= 0) _ = os(.unlink)(node.filename.ptr);
            shmPurge(f.inode.?);
        }
    }
};

const testing = std.testing;

fn testVfs(tmp: *testing.TmpDir) UnixVfs {
    var u = UnixVfs.init(testing.allocator, testing.io);
    u.dir = tmp.dir;
    return u;
}

test "unix: read/write/short read/truncate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();

    try testing.expectError(error.CantOpen, v.open("a.db", .{}));
    const f = try v.open("a.db", .{ .create = true });
    defer f.close();
    try f.write("hello", 10);
    try testing.expectEqual(@as(u64, 15), try f.fileSize());

    var buf: [8]u8 = undefined;
    @memset(&buf, 0xaa);
    try testing.expectError(error.ShortRead, f.read(&buf, 12));
    try testing.expectEqualSlices(u8, "llo\x00\x00\x00\x00\x00", &buf);

    try f.truncate(3);
    try testing.expectEqual(@as(u64, 3), try f.fileSize());
    try f.sync(.{});
    try f.sync(.{ .full = true });

    try testing.expect(try v.access("a.db", .exists));
    try testing.expectError(error.CantOpen, v.open("a.db", .{ .create = true, .exclusive = true }));
}

test "unix: a file without write permission opens read-only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();

    const f = try v.open("ro", .{ .create = true });
    try testing.expect(!f.isReadOnly());
    try f.write("data", 0);
    f.close();
    if (std.c.fchmodat(tmp.dir.handle, "ro", 0o444, 0) != 0) return error.SkipZigTest;
    const g = try v.open("ro", .{ .create = true });
    defer g.close();
    // Permissions do not bind root.
    if (!g.isReadOnly()) return error.SkipZigTest;
    try testing.expectError(error.ReadOnly, g.write("x", 0));
    var buf: [4]u8 = undefined;
    try g.read(&buf, 0);
    try testing.expectEqualStrings("data", &buf);
    // No fallback for a directory, or for a file that must be new.
    try testing.expectError(error.CantOpen, v.open("ro", .{ .create = true, .exclusive = true }));
    try tmp.dir.createDir(testing.io, "d", .default_dir);
    try testing.expectError(error.CantOpen, v.open("d", .{}));
}

test "unix: delete and temp files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();

    const f = try v.open("j", .{ .create = true });
    f.close();
    try v.delete("j", true);
    try testing.expectError(error.DeleteNoEnt, v.delete("j", false));
    try testing.expect(!try v.access("j", .exists));

    const d = try v.open("doc", .{ .create = true, .delete_on_close = true });
    try testing.expect(!try v.access("doc", .exists));
    try d.write("x", 0);
    d.close();

    const t = try v.open(null, .{ .create = true });
    try t.write("temp", 0);
    var buf: [4]u8 = undefined;
    try t.read(&buf, 0);
    try testing.expectEqualStrings("temp", &buf);
    t.close();
}

test "unix: the directory of temporary files" {
    const global = @import("root.zig");
    const saved = global.temp_directory;
    defer global.temp_directory = saved;
    // sqlite3_temp_directory comes first, if it is a writable directory.
    var missing = "/nonexistent-xqlite-dir".*;
    global.temp_directory = &missing;
    try testing.expect(!std.mem.eql(u8, tempFileDir().?, "/nonexistent-xqlite-dir"));
    var dot = ".".*;
    global.temp_directory = &dot;
    try testing.expectEqualStrings(".", tempFileDir().?);
}

test "unix: in-process locking protocol" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();

    const a = try v.open("db", .{ .create = true });
    defer a.close();
    const b = try v.open("db", .{});

    try a.lock(.shared);
    try b.lock(.shared);
    try a.lock(.reserved);
    try testing.expectError(error.Busy, b.lock(.reserved));
    try testing.expectError(error.Busy, a.lock(.exclusive));

    // Closing b while a holds locks must not drop a's POSIX locks.
    try b.unlock(.none);
    b.close();
    try a.lock(.exclusive);
    try a.unlock(.shared);
    try a.unlock(.none);

    const c2 = try v.open("db", .{});
    defer c2.close();
    try c2.lock(.shared);
    try c2.lock(.reserved);
    try c2.lock(.exclusive);
    try testing.expectError(error.Busy, a.lock(.shared));
    try c2.unlock(.none);
    try a.lock(.shared);
    try a.unlock(.none);
}

test "unix: file controls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();
    const f = try v.open("fc.db", .{ .create = true });
    defer f.close();

    // PERSIST_WAL and POWERSAFE_OVERWRITE: -1 asks, 0 and 1 set.
    var x: i32 = -1;
    try testing.expect(try f.fileControl(.{ .persist_wal = &x }));
    try testing.expectEqual(@as(i32, 0), x);
    x = 1;
    _ = try f.fileControl(.{ .persist_wal = &x });
    x = -1;
    _ = try f.fileControl(.{ .persist_wal = &x });
    try testing.expectEqual(@as(i32, 1), x);
    try testing.expect(f.deviceCharacteristics().powersafe_overwrite);
    x = 0;
    _ = try f.fileControl(.{ .powersafe_overwrite = &x });
    try testing.expect(!f.deviceCharacteristics().powersafe_overwrite);

    // CHUNK_SIZE rounds truncations and size hints up.
    _ = try f.fileControl(.{ .chunk_size = 16 });
    try f.write("abc", 0);
    try f.truncate(5);
    try testing.expectEqual(@as(u64, 16), try f.fileSize());
    _ = try f.fileControl(.{ .size_hint = 45 });
    try testing.expectEqual(@as(u64, 48), try f.fileSize());

    var level: vfs.LockLevel = .exclusive;
    _ = try f.fileControl(.{ .lockstate = &level });
    try testing.expectEqual(vfs.LockLevel.none, level);
    var name: []const u8 = "";
    _ = try f.fileControl(.{ .vfsname = &name });
    try testing.expectEqualStrings("unix", name);

    // HAS_MOVED: the name no longer leads to the file.
    var moved = true;
    _ = try f.fileControl(.{ .has_moved = &moved });
    try testing.expect(!moved);
    try tmp.dir.rename("fc.db", tmp.dir, "fc2.db", testing.io);
    _ = try f.fileControl(.{ .has_moved = &moved });
    try testing.expect(moved);
    try testing.expect(f.foreign() != null);
}

test "unix: URI parameters psow and readonly_shm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();
    {
        const f = try v.open("u.db", .{ .create = true });
        defer f.close();
        try f.write(&(@as([4096]u8, @splat(1))), 0);
        const shm = try v.open("u.db-shm", .{ .create = true, .kind = .wal });
        shm.close();
    }
    // The name in SQLite's filename layout, parameters after it.
    const layout = "\x00\x00\x00\x00u.db\x00psow\x000\x00readonly_shm\x001\x00\x00";
    const name = layout[4..8];
    const f = try v.open(name, .{ .uri = true, .sqlite_filename = true });
    defer f.close();
    try testing.expect(!f.deviceCharacteristics().powersafe_overwrite);
    try f.lock(.shared);
    defer f.unlock(.none) catch {};
    // No other connection: the read-only -shm file cannot be trusted.
    const r = try f.shmMap(0, 32768, true);
    defer f.shmUnmap(false);
    try testing.expect(r.read_only and r.cant_init);
}

fn failOpen(_: [*:0]const u8, _: c_int, _: c_int) callconv(.c) c_int {
    c._errno().* = eno(.ACCES);
    return -1;
}

test "unix: overriding system calls" {
    try testing.expectEqualStrings("open", nextSystemCall(null).?);
    try testing.expectEqualStrings("close", nextSystemCall("open").?);
    try testing.expect(getSystemCall("nosuchcall") == null);
    try testing.expect(!setSystemCall("nosuchcall", null));
    // Every name listed has a function.
    var it = nextSystemCall(null);
    while (it) |n| : (it = nextSystemCall(n)) try testing.expect(getSystemCall(n) != null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    const v = u.interface();
    const orig = getSystemCall("open").?;
    try testing.expect(setSystemCall("open", @ptrCast(&failOpen)));
    try testing.expectError(error.CantOpen, v.open("s.db", .{ .create = true }));
    // Null restores the original; a null name all of them.
    try testing.expect(setSystemCall("open", null));
    try testing.expect(getSystemCall("open") == orig);
    try testing.expect(setSystemCall("open", @ptrCast(&failOpen)));
    try testing.expect(setSystemCall(null, null));
    const f = try v.open("s.db", .{ .create = true });
    f.close();
}

test "unix-excl: the process locks the file, the wal-index is heap memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = testVfs(&tmp);
    u.excl = true;
    const v = u.interface();
    const a = try v.open("x.db", .{ .create = true });
    defer a.close();
    const b = try v.open("x.db", .{});
    defer b.close();
    try a.lock(.shared);
    try b.lock(.shared);
    try a.lock(.reserved);
    // Connections of the process still exclude each other.
    try testing.expectError(error.Busy, b.lock(.reserved));
    try testing.expect(try a.checkReservedLock());
    const r = try a.shmMap(0, 32768, true);
    try testing.expect(r.ptr != null and !r.read_only);
    try testing.expect(!try v.access("x.db-shm", .exists));
    a.shmUnmap(true);
    try a.unlock(.none);
    try b.unlock(.none);
    var name: []const u8 = "";
    _ = try a.fileControl(.{ .vfsname = &name });
    try testing.expectEqualStrings("unix-excl", name);
}
