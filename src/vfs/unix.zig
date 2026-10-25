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
//! Not ported yet: mmap, shared memory (WAL index), proxy/dotfile/flock
//! locking styles, F_SETLKW timeouts.

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
    /// Where anonymous temporary files are created.
    temp_dir: []const u8 = "/tmp",

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
    };

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const self: *UnixVfs = @ptrCast(@alignCast(ptr));
        const io = self.io;

        // Vfs.open has already set create/exclusive/delete_on_close for
        // anonymous files; only the name is left to choose.
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name: []const u8 = path orelse blk: {
            var rand: [8]u8 = undefined;
            io.random(&rand);
            break :blk std.fmt.bufPrint(&name_buf, "{s}/etilqs_{x}", .{
                self.temp_dir, &rand,
            }) catch return error.CantOpen;
        };

        const file: Io.File = if (flags.create)
            self.dir.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = flags.exclusive,
                .permissions = .default_file,
            }) catch |err| return mapOpenError(err)
        else
            self.dir.openFile(io, name, .{
                .mode = if (flags.read_write) .read_write else .read_only,
                .allow_directory = false,
            }) catch |err| return mapOpenError(err);
        errdefer file.close(io);

        // Like os_unix.c: unlink right away and let the descriptor keep the
        // data alive until it is closed.
        if (flags.delete_on_close) self.dir.deleteFile(io, name) catch {};

        const inode = try InodeInfo.acquire(io, file);
        errdefer inode.release(io);
        const handle = try self.gpa.create(UnixFile);
        handle.* = .{
            .owner = self,
            .file = file,
            .inode = inode,
            .read_only = !flags.read_write,
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

/// Lock state shared by every handle on one inode (struct unixInodeInfo).
///
/// Mutex rules mirror os_unix.c: `big_lock` guards the table and `ref_count`;
/// `mutex` guards the lock fields. Never take `big_lock` while holding `mutex`.
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

    /// The table outlives any one VFS instance, so it uses a global allocator.
    const gpa = std.heap.smp_allocator;
    var big_lock: Io.Mutex = .init;
    var table: std.AutoHashMapUnmanaged(FileId, *InodeInfo) = .empty;

    /// Port of findInodeInfo().
    fn acquire(io: Io, file: Io.File) Error!*InodeInfo {
        const id = try FileId.of(file.handle);
        big_lock.lockUncancelable(io);
        defer big_lock.unlock(io);
        const gop = try table.getOrPut(gpa, id);
        if (!gop.found_existing) {
            const info = gpa.create(InodeInfo) catch |err| {
                table.removeByPtr(gop.key_ptr);
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
        big_lock.lockUncancelable(io);
        defer big_lock.unlock(io);
        info.ref_count -= 1;
        if (info.ref_count != 0) return;
        info.mutex.lockUncancelable(io);
        info.closePendingFds(io);
        info.mutex.unlock(io);
        info.unused.deinit(gpa);
        _ = table.remove(info.id);
        gpa.destroy(info);
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

const UnixFile = struct {
    owner: *UnixVfs,
    file: Io.File,
    inode: *InodeInfo,
    level: LockLevel = .none,
    read_only: bool,

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
        unlock(ptr, .none) catch {};
        const inode = f.inode;
        inode.mutex.lockUncancelable(io);
        if (inode.n_lock != 0) {
            // Closing now would release locks held through other handles.
            inode.unused.append(InodeInfo.gpa, f.file) catch {
                // Out of memory: leak the descriptor rather than break locks.
            };
        } else {
            f.file.close(io);
        }
        inode.mutex.unlock(io);
        inode.release(io);
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
