//! POSIX VFS (port of the "unix" VFS in os_unix.c, POSIX advisory locking only).
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
//! The shared memory of a WAL database (the wal-index) is the mmapped
//! "-shm" file next to it, locked with the same byte ranges as os_unix.c
//! (UNIX_SHM_BASE, UNIX_SHM_DMS), so the wal-index is shared with real
//! SQLite processes too. As in os_unix.c, each inode has at most one
//! `ShmNode` per process, shared by every handle that maps it.
//!
//! Not ported yet: mmap of the database file, proxy/dotfile/flock locking
//! styles, unix-excl (process-private locks), F_SETLKW timeouts.

const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("vfs.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;
const c = std.c;
const fd_t = std.posix.fd_t;

pub const UnixVfs = struct {
    gpa: Allocator,
    io: Io,
    /// Relative paths are resolved against this directory.
    dir: Io.Dir,
    /// Where anonymous temporary files are created; null for the first
    /// usable one of unixTempFileDir() (tempFileDir()).
    temp_dir: ?[]const u8 = null,

    pub fn init(gpa: Allocator, io: Io) UnixVfs {
        return .{ .gpa = gpa, .io = io, .dir = .cwd() };
    }

    pub fn interface(self: *UnixVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: vfs.Vfs.VTable = .{
        .open = open,
        .delete = delete,
        .access = access,
        .randomness = randomness,
        .sleep = sleep,
        .fullPathname = fullPathname,
    };

    /// Port of unixFullPathname(): `path` made absolute (against `dir`),
    /// with "." and ".." removed and symbolic links resolved.
    fn fullPathname(ptr: *anyopaque, path: []const u8, out: []u8) Error![]u8 {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        var p: DbPath = .{ .out = out };
        if (path.len == 0 or path[0] != '/') {
            var pwd: [std.fs.max_path_bytes]u8 = undefined;
            const n = self.dir.realPath(self.io, &pwd) catch return error.CantOpen;
            p.appendAll(pwd[0..n]);
        }
        p.appendAll(path);
        if (p.failed or p.used < 2) return error.CantOpen;
        return out[0..p.used];
    }

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        const io = self.io;

        // Vfs.open has already set create/exclusive/delete_on_close for
        // anonymous files; only the name is left to choose.
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name: []const u8 = path orelse blk: {
            var rand: [8]u8 = undefined;
            io.random(&rand);
            const dir = self.temp_dir orelse tempFileDir() orelse return error.CantOpen;
            break :blk std.fmt.bufPrint(&name_buf, "{s}/etilqs_{x}", .{
                dir, &rand,
            }) catch return error.CantOpen;
        };

        var read_only = !flags.read_write;
        const opened = if (flags.create)
            self.dir.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = flags.exclusive,
                .permissions = .default_file,
            })
        else
            self.dir.openFile(io, name, .{
                .mode = if (flags.read_write) .read_write else .read_only,
                .allow_directory = false,
            });
        const file: Io.File = opened catch |err| retry: {
            // Like unixOpen(): what cannot be opened read-write (a file
            // without write permission, say) is opened read-only, which
            // File.isReadOnly() reports. Not a directory, nor a file that
            // must be new.
            if (read_only or flags.exclusive or err == error.IsDir) return mapOpenError(err);
            read_only = true;
            break :retry self.dir.openFile(io, name, .{
                .mode = .read_only,
                .allow_directory = false,
            }) catch |e| return mapOpenError(e);
        };
        errdefer file.close(io);

        // Like os_unix.c: unlink right away and let the descriptor keep the
        // data alive until it is closed.
        if (flags.delete_on_close) self.dir.deleteFile(io, name) catch {};

        const inode = try InodeInfo.acquire(io, file);
        errdefer inode.release(io);
        // The name of a database is kept to derive the -shm file's.
        const path_copy: ?[]u8 = if (path != null and flags.kind == .main_db) try self.gpa.dupe(u8, name) else null;
        errdefer if (path_copy) |pc| self.gpa.free(pc);
        const handle = try self.gpa.create(UnixFile);
        handle.* = .{
            .owner = self,
            .file = file,
            .inode = inode,
            .read_only = read_only,
            .path = path_copy,
        };
        return .{ .ptr = handle, .vtable = &UnixFile.vtable };
    }

    fn mapOpenError(err: Io.File.OpenError) Error {
        return switch (err) {
            error.SystemResources => error.OutOfMemory,
            else => error.CantOpen,
        };
    }

    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        const io = self.io;
        self.dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.IoErr,
        };
        if (sync_dir) {
            const parent = std.fs.path.dirname(path) orelse ".";
            var d = self.dir.openDir(io, parent, .{}) catch return error.IoErr;
            defer d.close(io);
            // Some filesystems refuse to fsync a directory; os_unix.c ignores
            // that too.
            fsyncFd(d.handle, false) catch {};
        }
    }

    fn randomness(ptr: *anyopaque, buf: []u8) void {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        self.io.random(buf);
    }

    /// Port of unixSleep().
    fn sleep(ptr: *anyopaque, microseconds: u32) u32 {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        return vfs.ioSleep(self.io, microseconds);
    }

    fn access(ptr: *anyopaque, path: []const u8, mode: vfs.AccessMode) Error!bool {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        self.dir.access(self.io, path, .{
            .read = mode == .read,
            .write = mode == .read_write,
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => return false,
            else => return error.IoErr,
        };
        return true;
    }
};

/// A pathname under construction (DbPath).
/// Port of unixTempFileDir(): the directory of temporary files, the
/// first of sqlite3_temp_directory (global.temp_directory, also PRAGMA
/// temp_store_directory), $SQLITE_TMPDIR, $TMPDIR, /var/tmp, /usr/tmp,
/// /tmp and "." that is a directory the process can write and search.
fn tempFileDir() ?[]const u8 {
    const temp_directory = @import("../sql/global.zig").temp_directory;
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
        const dir = std.mem.span(z orelse continue);
        // A directory: "dir/." can be searched and written (osStat()'s
        // S_ISDIR and osAccess(zDir, 03)).
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const probe = std.fmt.bufPrintSentinel(&buf, "{s}/.", .{dir}, 0) catch continue;
        if (c.access(probe.ptr, 3) == 0) return dir;
    }
    return null;
}

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
        // C calls lstat() and then readlink() on a link; readlink() alone
        // tells both.
        p.out[p.used] = 0;
        var lnk: [std.fs.max_path_bytes + 2]u8 = undefined;
        const got = c.readlink(p.out[0..p.used :0], &lnk, lnk.len - 2);
        if (got < 0) {
            switch (c.errno(got)) {
                .INVAL, .NOENT => {},
                else => p.failed = true,
            }
            return;
        }
        p.n_symlink += 1;
        if (p.n_symlink > max_symlink + 1 or got == 0 or got >= lnk.len - 2) {
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

    fn of(fd: fd_t) Error!FileId {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var stx: linux.Statx = undefined;
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
            if (linux.errno(rc) != .SUCCESS) return error.IoErr;
            return .{
                .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
                .ino = stx.ino,
            };
        } else {
            var st: c.Stat = undefined;
            if (c.fstat(fd, &st) != 0) return error.IoErr;
            return .{ .dev = @bitCast(@as(i64, st.dev)), .ino = @intCast(st.ino) };
        }
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
    /// Descriptors whose close(2) is deferred until `n_lock` drops to zero.
    unused: std.ArrayList(Io.File) = .empty,
    ref_count: u32 = 0,
    /// The shared memory of this database, while any handle maps it
    /// (pShmNode). Created and destroyed under `inodes.big_lock`.
    shm_node: ?*ShmNode = null,

    /// Port of findInodeInfo().
    fn acquire(io: Io, file: Io.File) Error!*InodeInfo {
        const id = try FileId.of(file.handle);
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
        info.closePendingFds(io);
        info.mutex.unlock(io);
        info.unused.deinit(Inodes.gpa);
        _ = inodes.table.remove(info.id);
        Inodes.gpa.destroy(info);
    }

    /// Caller holds `mutex`.
    fn closePendingFds(info: *InodeInfo, io: Io) void {
        for (info.unused.items) |file| file.close(io);
        info.unused.clearRetainingCapacity();
    }
};

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

/// Applies a non-blocking POSIX advisory lock (osSetPosixAdvisoryLock).
fn posixLock(fd: fd_t, kind: LockType, start: u64, len: u64) error{ Busy, LockErr }!void {
    var fl = flock(kind, start, len);
    while (true) {
        const rc = c.fcntl(fd, c.F.SETLK, &fl);
        switch (c.errno(rc)) {
            .SUCCESS => return,
            // Port of sqliteErrorFromPosixError(): contention means BUSY.
            .AGAIN, .ACCES, .BUSY, .TIMEDOUT, .NOLCK => return error.Busy,
            .INTR => if (kind == .unlock) continue else return error.Busy,
            else => return error.LockErr,
        }
    }
}

/// Whether another process holds a lock that conflicts with a write lock on
/// the range.
fn posixTestWriteLock(fd: fd_t, start: u64, len: u64) Error!bool {
    var fl = flock(.write, start, len);
    if (c.fcntl(fd, c.F.GETLK, &fl) != 0) return error.LockErr;
    return fl.type != c.F.UNLCK;
}

fn fsyncFd(fd: fd_t, full: bool) Error!void {
    if (full and builtin.os.tag.isDarwin()) {
        // F_FULLFSYNC flushes the drive's write cache as well. Fall back to
        // fsync on filesystems that do not support it, as os_unix.c does.
        if (c.fcntl(fd, c.F.FULLFSYNC, @as(c_int, 0)) == 0) return;
    }
    while (true) {
        switch (c.errno(c.fsync(fd))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.IoErr,
        }
    }
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
    filename: []u8,
    /// The open -shm file (hShm).
    file: Io.File,
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

    fn fd(node: *const ShmNode) fd_t {
        return node.file.handle;
    }

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
/// `ofst`..`ofst+n-1` of the -shm file. Any failure is reported as Busy.
fn shmSystemLock(node: *ShmNode, kind: LockType, ofst: u64, n: u64) Error!void {
    std.debug.assert((ofst == shm_dms and n == 1) or (ofst >= shm_base and ofst + n <= shm_base + vfs.shm_nlock));
    std.debug.assert(n == 1 or kind != .read);
    posixLock(node.fd(), kind, ofst, n) catch return error.Busy;
}

/// Port of unixShmRegionPerMap(): how many 32 KiB regions one mapping
/// covers, so that each mapping is a whole number of system pages.
fn shmRegionPerMap() u32 {
    const shmsz = 32 * 1024;
    const pgsz = std.heap.pageSize();
    if (pgsz < shmsz) return 1;
    return @intCast(pgsz / shmsz);
}

/// Port of unixShmPurge(): free the inode's ShmNode once nothing refers to
/// it. Caller holds `inodes.big_lock`.
fn shmPurge(io: Io, inode: *InodeInfo) void {
    const node = inode.shm_node orelse return;
    if (node.n_ref != 0) return;
    const per_map = shmRegionPerMap();
    var i: usize = 0;
    while (i < node.regions.items.len) : (i += per_map) {
        const len = @as(usize, node.sz_region) * per_map;
        const base: [*]align(std.heap.page_size_min) u8 = @alignCast(node.regions.items[i]);
        std.posix.munmap(base[0..len]);
    }
    node.regions.deinit(Inodes.gpa);
    node.file.close(io);
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
    if (c.fcntl(node.fd(), c.F.GETLK, &fl) != 0) return error.LockErr;
    if (fl.type == c.F.UNLCK) {
        if (node.is_readonly) {
            node.is_unlocked = true;
            return true;
        }
        try shmSystemLock(node, .write, shm_dms, 1);
        // Truncated to 3 bytes rather than 0, as a debugging aid, like
        // os_unix.c: it tells a legitimate truncation from a rogue one.
        if (c.ftruncate(node.fd(), 3) != 0) return error.ShmOpen;
    } else if (fl.type == c.F.WRLCK) {
        return error.Busy;
    }
    try shmSystemLock(node, .read, shm_dms, 1);
    return false;
}

const UnixFile = struct {
    owner: *UnixVfs,
    file: Io.File,
    inode: *InodeInfo,
    level: LockLevel = .none,
    read_only: bool,
    /// The database name, for the -shm file (zPath). Null for other files.
    path: ?[]u8 = null,
    /// This handle's connection to the shared memory (pShm).
    shm: ?*Shm = null,

    const vtable: vfs.File.VTable = .{
        .close = close,
        .read = read,
        .write = write,
        .truncate = truncate,
        .sync = sync,
        .fileSize = fileSize,
        .lock = lock,
        .unlock = unlock,
        .checkReservedLock = checkReservedLock,
        .sectorSize = sectorSize,
        .deviceCharacteristics = deviceCharacteristics,
        .isReadOnly = isReadOnly,
        .shmMap = shmMap,
        .shmLock = shmLock,
        .shmBarrier = shmBarrier,
        .shmUnmap = shmUnmap,
    };

    fn cast(ptr: *anyopaque) *UnixFile {
        return @ptrCast(@alignCast(ptr));
    }

    fn fd(f: *UnixFile) fd_t {
        return f.file.handle;
    }

    /// Port of unixClose().
    fn close(ptr: *anyopaque) void {
        const f = cast(ptr);
        const io = f.owner.io;
        // The WAL unmaps the shared memory before the database closes.
        std.debug.assert(f.shm == null);
        if (f.shm != null) shmUnmap(ptr, false);
        unlock(ptr, .none) catch {};
        const inode = f.inode;
        inode.mutex.lockUncancelable(io);
        if (inode.n_lock != 0) {
            // Closing now would release locks held through other handles.
            inode.unused.append(Inodes.gpa, f.file) catch {
                // Out of memory: leak the descriptor rather than break locks.
            };
        } else {
            f.file.close(io);
        }
        inode.mutex.unlock(io);
        inode.release(io);
        if (f.path) |pth| f.owner.gpa.free(pth);
        f.owner.gpa.destroy(f);
    }

    fn read(ptr: *anyopaque, buf: []u8, offset: u64) Error!usize {
        const f = cast(ptr);
        return f.file.readPositionalAll(f.owner.io, buf, offset) catch error.IoErr;
    }

    fn write(ptr: *anyopaque, buf: []const u8, offset: u64) Error!void {
        const f = cast(ptr);
        if (f.read_only) return error.ReadOnly;
        f.file.writePositionalAll(f.owner.io, buf, offset) catch |err| return switch (err) {
            error.NoSpaceLeft, error.FileTooBig => error.DiskFull,
            else => error.IoErr,
        };
    }

    fn truncate(ptr: *anyopaque, size: u64) Error!void {
        const f = cast(ptr);
        if (f.read_only) return error.ReadOnly;
        f.file.setLength(f.owner.io, size) catch return error.IoErr;
    }

    fn sync(ptr: *anyopaque, flags: vfs.SyncFlags) Error!void {
        const f = cast(ptr);
        return fsyncFd(f.fd(), flags.full);
    }

    fn fileSize(ptr: *anyopaque) Error!u64 {
        const f = cast(ptr);
        return f.file.length(f.owner.io) catch error.IoErr;
    }

    /// Port of unixLock(). See vfs.LockLevel for the allowed transitions.
    fn lock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (f.level.atLeast(level)) return;

        const io = f.owner.io;
        const inode = f.inode;
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

        if (level == .shared) {
            // Read-lock PENDING while taking the shared range so that a
            // writer waiting for EXCLUSIVE is not starved, then drop it.
            try posixLock(f.fd(), .read, vfs.pending_byte, 1);
            const got = posixLock(f.fd(), .read, vfs.shared_first, vfs.shared_size);
            const dropped = posixLock(f.fd(), .unlock, vfs.pending_byte, 1);
            try got;
            dropped catch return error.LockErr;
            f.level = .shared;
            inode.level = .shared;
            inode.n_lock += 1;
            inode.n_shared = 1;
            return;
        }

        if (level == .exclusive and f.level == .reserved) {
            // PENDING blocks new readers while we wait for existing ones.
            try posixLock(f.fd(), .write, vfs.pending_byte, 1);
            f.level = .pending;
            inode.level = .pending;
        }

        if (level == .exclusive and inode.n_shared > 1) {
            // Another handle in this process still reads the database.
            return error.Busy;
        }

        if (level == .reserved) {
            try posixLock(f.fd(), .write, vfs.reserved_byte, 1);
        } else {
            try posixLock(f.fd(), .write, vfs.shared_first, vfs.shared_size);
        }
        f.level = level;
        inode.level = level;
    }

    /// Port of posixUnlock() without the NFS workaround.
    fn unlock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (!f.level.atLeast(level) or f.level == level) return;

        const io = f.owner.io;
        const inode = f.inode;
        inode.mutex.lockUncancelable(io);
        defer inode.mutex.unlock(io);

        if (f.level.atLeast(.reserved)) {
            if (level == .shared) {
                // Cannot fail against a well-behaved peer: we hold a write
                // lock on the range already.
                posixLock(f.fd(), .read, vfs.shared_first, vfs.shared_size) catch return error.LockErr;
            }
            // Releases PENDING and RESERVED together.
            posixLock(f.fd(), .unlock, vfs.pending_byte, 2) catch return error.LockErr;
            inode.level = .shared;
        }

        if (level == .none) {
            inode.n_shared -= 1;
            if (inode.n_shared == 0) {
                const rc = posixLock(f.fd(), .unlock, 0, 0);
                inode.level = .none;
                rc catch {
                    f.level = .none;
                    return error.LockErr;
                };
            }
            inode.n_lock -= 1;
            if (inode.n_lock == 0) inode.closePendingFds(io);
        }
        f.level = level;
    }

    /// Port of unixCheckReservedLock().
    fn checkReservedLock(ptr: *anyopaque) Error!bool {
        const f = cast(ptr);
        const io = f.owner.io;
        const inode = f.inode;
        inode.mutex.lockUncancelable(io);
        defer inode.mutex.unlock(io);
        if (inode.level.atLeast(.reserved)) return true;
        return posixTestWriteLock(f.fd(), vfs.reserved_byte, 1);
    }

    fn sectorSize(_: *anyopaque) u32 {
        return vfs.default_sector_size;
    }

    fn deviceCharacteristics(_: *anyopaque) vfs.DeviceCharacteristics {
        // SQLITE_POWERSAFE_OVERWRITE defaults to on in os_unix.c.
        return .{ .powersafe_overwrite = true };
    }

    fn isReadOnly(ptr: *anyopaque) bool {
        return cast(ptr).read_only;
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
        const p = try gpa.create(Shm);
        errdefer gpa.destroy(p);

        inodes.big_lock.lockUncancelable(io);
        defer inodes.big_lock.unlock(io);
        const inode = f.inode;
        var cant_init = false;
        const node = inode.shm_node orelse blk: {
            const base = f.path orelse return error.ShmOpen;
            const st = f.file.stat(io) catch return error.IoErr;
            const name = try std.mem.concat(gpa, u8, &.{ base, "-shm" });
            // Create it with the permissions of the database.
            const perm: Io.File.Permissions = @fromBackingInt(@backingInt(st.permissions) & 0o777);
            var read_only = false;
            const file = f.owner.dir.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .permissions = perm,
            }) catch open_ro: {
                read_only = true;
                break :open_ro f.owner.dir.openFile(io, name, .{ .mode = .read_only, .allow_directory = false }) catch {
                    gpa.free(name);
                    return error.CantOpen;
                };
            };
            const node = gpa.create(ShmNode) catch |err| {
                file.close(io);
                gpa.free(name);
                return err;
            };
            node.* = .{ .inode = inode, .filename = name, .file = file, .is_readonly = read_only };
            inode.shm_node = node;
            cant_init = shmLockSharedMemory(node) catch |err| {
                // Frees the node, which nothing refers to yet.
                shmPurge(io, inode);
                return err;
            };
            break :blk node;
        };
        p.* = .{ .node = node };
        node.n_ref += 1;
        f.shm = p;
        return cant_init;
    }

    /// Port of unixShmMap(): region `region` of the shared memory, each
    /// region `size` bytes, extending the -shm file if `extend`.
    fn shmMap(ptr: *anyopaque, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        const f = cast(ptr);
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
            const cur = node.file.length(io) catch return error.ShmSize;
            if (cur < n_byte) {
                if (!extend) break :map;
                // Write the last byte of every new 4 KiB page, so that the
                // OS allocates them now rather than raising SIGBUS later.
                const pgsz = 4096;
                var pg = cur / pgsz;
                while (pg < n_byte / pgsz) : (pg += 1) {
                    node.file.writePositionalAll(io, &.{0}, pg * pgsz + pgsz - 1) catch return error.ShmSize;
                }
            }
            try node.regions.ensureTotalCapacity(Inodes.gpa, n_req);
            while (node.regions.items.len < n_req) {
                const n_map = @as(usize, size) * per_map;
                const mem = std.posix.mmap(
                    null,
                    n_map,
                    if (node.is_readonly) .{ .READ = true } else .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .SHARED },
                    node.fd(),
                    @as(u64, size) * node.regions.items.len,
                ) catch return error.ShmMap;
                for (0..per_map) |i| node.regions.appendAssumeCapacity(@alignCast(mem.ptr + size * i));
            }
        }
        return .{
            .ptr = if (node.regions.items.len > region) node.regions.items[region] else null,
            .read_only = node.is_readonly,
        };
    }

    /// Port of unixShmLock(). Shared locks are counted per process, so
    /// the POSIX lock is only released with the last one.
    fn shmLock(ptr: *anyopaque, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        const f = cast(ptr);
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
    fn shmBarrier(ptr: *anyopaque) void {
        const f = cast(ptr);
        _ = @atomicRmw(u32, &inodes.barrier_word, .Add, 0, .seq_cst);
        inodes.big_lock.lockUncancelable(f.owner.io);
        inodes.big_lock.unlock(f.owner.io);
    }

    /// Port of unixShmUnmap(): disconnect this handle from the shared
    /// memory; the last one out deletes the -shm file if `delete`.
    fn shmUnmap(ptr: *anyopaque, delete_flag: bool) void {
        const f = cast(ptr);
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
            if (delete_flag) f.owner.dir.deleteFile(io, node.filename) catch {};
            shmPurge(io, f.inode);
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
    try v.delete("j", false);
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
    const global = @import("../sql/global.zig");
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
