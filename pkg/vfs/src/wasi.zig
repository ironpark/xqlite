//! WASI VFS (wasm32-wasi, WASI preview 1): database files through the
//! runtime's preopened directories, with `std.Io`.
//!
//! WASI has no advisory locks (no fcntl(F_SETLK), no flock), so locks
//! are arbitrated in this process only, by file identity (device and
//! inode, as the unix VFS's inode table): connections of one WebAssembly
//! instance exclude each other as they would on unix, but nothing stops
//! another process (another instance, or a native sqlite3) from writing
//! the same file at the same time. Only one process may use a database
//! file at a time.
//!
//! The wal-index of a WAL database is heap memory shared by the handles
//! of this process (inproc.zig), not a -shm file: WAL works between
//! connections of one instance, and a database left in WAL mode is
//! recovered from its WAL file by the next opener, xqlite or sqlite3.
//!
//! Anonymous temporary files (temp databases, sub-journals, sorter
//! spills) live in memory: a WASI program may not have a writable
//! temporary directory.
//!
//! Names are used as given (no xFullPathname): WASI resolves relative
//! names against the preopened directories, and has no canonical form.

const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("vfs.zig");
const inproc = @import("inproc.zig");
const MemVfs = @import("mem.zig").MemVfs;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;
const wasi = std.os.wasi;

pub const WasiVfs = struct {
    gpa: Allocator,
    io: Io,
    /// Relative paths are resolved against this directory.
    dir: Io.Dir,
    /// Where anonymous temporary files live.
    mem: MemVfs,

    pub fn init(gpa: Allocator, io: Io) WasiVfs {
        return .{ .gpa = gpa, .io = io, .dir = .cwd(), .mem = .init(gpa, io) };
    }

    pub fn interface(self: *WasiVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: vfs.Vfs.VTable = .{
        .open = open,
        .delete = delete,
        .access = access,
        .randomness = randomness,
        .sleep = sleep,
    };

    fn cast(ptr: *anyopaque) *WasiVfs {
        return @ptrCast(@alignCast(ptr));
    }

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const self = cast(ptr);
        const io = self.io;
        const name = path orelse return self.mem.interface().open(null, flags);

        var read_only = !flags.read_write;
        const opened = if (flags.create)
            self.dir.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = flags.exclusive,
            })
        else
            self.dir.openFile(io, name, .{
                .mode = if (flags.read_write) .read_write else .read_only,
                .allow_directory = false,
            });
        const file: Io.File = opened catch |err| retry: {
            // As the unix VFS: fall back to read-only.
            if (read_only or flags.exclusive or err == error.IsDir) return mapOpenError(err);
            read_only = true;
            break :retry self.dir.openFile(io, name, .{
                .mode = .read_only,
                .allow_directory = false,
            }) catch |e| return mapOpenError(e);
        };
        errdefer file.close(io);

        const id = try FileId.of(file);
        const node = try Node.acquire(io, id);
        errdefer node.release(io);
        // Delete-on-close: unlink at close, since not every WASI host can
        // unlink an open file.
        const keep_name: ?[]u8 = if (flags.delete_on_close) try self.gpa.dupe(u8, name) else null;
        errdefer if (keep_name) |n| self.gpa.free(n);
        const handle = try self.gpa.create(WasiFile);
        handle.* = .{ .owner = self, .file = file, .node = node, .read_only = read_only, .delete_name = keep_name };
        return .{ .ptr = handle, .vtable = &WasiFile.vtable };
    }

    fn mapOpenError(err: Io.File.OpenError) Error {
        return switch (err) {
            error.SystemResources => error.OutOfMemory,
            else => error.CantOpen,
        };
    }

    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void {
        _ = sync_dir;
        const self = cast(ptr);
        self.dir.deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.IoErr,
        };
    }

    fn randomness(ptr: *anyopaque, buf: []u8) void {
        cast(ptr).io.random(buf);
    }

    fn sleep(ptr: *anyopaque, microseconds: u32) u32 {
        return vfs.ioSleep(cast(ptr).io, microseconds);
    }

    fn access(ptr: *anyopaque, path: []const u8, mode: vfs.AccessMode) Error!bool {
        const self = cast(ptr);
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

/// Process-wide identity of a file (fd_filestat_get()).
const FileId = struct {
    dev: u64,
    ino: u64,

    fn of(file: Io.File) Error!FileId {
        var st: wasi.filestat_t = undefined;
        if (wasi.fd_filestat_get(file.handle, &st) != .SUCCESS) return error.IoErr;
        return .{ .dev = st.dev, .ino = st.ino };
    }
};

/// The lock table of this process (the unix VFS's inode table): every
/// handle on a file, whatever connection or WasiVfs it comes from, shares
/// one Node.
var files: Files = .{};

const Files = struct {
    mutex: Io.Mutex = .init,
    table: std.AutoHashMapUnmanaged(FileId, *Node) = .empty,

    /// The table outlives any one VFS instance.
    const gpa = if (builtin.link_libc) std.heap.c_allocator else std.heap.wasm_allocator;
};

/// What the handles on one file share. `files.mutex` guards all of it.
const Node = struct {
    id: FileId,
    ref_count: u32 = 0,
    locks: inproc.Locks = .{},
    shm: inproc.Shm = .{},

    fn acquire(io: Io, id: FileId) Error!*Node {
        files.mutex.lockUncancelable(io);
        defer files.mutex.unlock(io);
        const gop = try files.table.getOrPut(Files.gpa, id);
        if (!gop.found_existing) {
            const node = Files.gpa.create(Node) catch |err| {
                files.table.removeByPtr(gop.key_ptr);
                return err;
            };
            node.* = .{ .id = id };
            gop.value_ptr.* = node;
        }
        gop.value_ptr.*.ref_count += 1;
        return gop.value_ptr.*;
    }

    fn release(node: *Node, io: Io) void {
        files.mutex.lockUncancelable(io);
        defer files.mutex.unlock(io);
        node.ref_count -= 1;
        if (node.ref_count != 0) return;
        node.shm.deinit(Files.gpa);
        _ = files.table.remove(node.id);
        Files.gpa.destroy(node);
    }
};

const WasiFile = struct {
    owner: *WasiVfs,
    file: Io.File,
    node: *Node,
    level: LockLevel = .none,
    read_only: bool,
    /// The name to delete at close (delete_on_close).
    delete_name: ?[]u8 = null,
    shm: inproc.Shm.Conn = .{},

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

    fn cast(ptr: *anyopaque) *WasiFile {
        return @ptrCast(@alignCast(ptr));
    }

    fn enter(f: *WasiFile) void {
        files.mutex.lockUncancelable(f.owner.io);
    }

    fn leave(f: *WasiFile) void {
        files.mutex.unlock(f.owner.io);
    }

    fn close(ptr: *anyopaque) void {
        const f = cast(ptr);
        const owner = f.owner;
        std.debug.assert(!f.shm.on);
        shmUnmap(ptr, false);
        unlock(ptr, .none) catch {};
        f.file.close(owner.io);
        f.node.release(owner.io);
        if (f.delete_name) |n| {
            owner.dir.deleteFile(owner.io, n) catch {};
            owner.gpa.free(n);
        }
        owner.gpa.destroy(f);
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

    fn sync(ptr: *anyopaque, _: vfs.SyncFlags) Error!void {
        const f = cast(ptr);
        f.file.sync(f.owner.io) catch return error.IoErr;
    }

    fn fileSize(ptr: *anyopaque) Error!u64 {
        const f = cast(ptr);
        return f.file.length(f.owner.io) catch error.IoErr;
    }

    fn lock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (f.level.atLeast(level)) return;
        f.enter();
        defer f.leave();
        return f.node.locks.lock(&f.level, level);
    }

    fn unlock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (!f.level.atLeast(level) or f.level == level) return;
        f.enter();
        defer f.leave();
        f.node.locks.unlock(&f.level, level);
    }

    fn checkReservedLock(ptr: *anyopaque) Error!bool {
        const f = cast(ptr);
        f.enter();
        defer f.leave();
        return f.node.locks.reserved;
    }

    fn sectorSize(_: *anyopaque) u32 {
        return vfs.default_sector_size;
    }

    fn deviceCharacteristics(_: *anyopaque) vfs.DeviceCharacteristics {
        return .{ .powersafe_overwrite = true };
    }

    fn isReadOnly(ptr: *anyopaque) bool {
        return cast(ptr).read_only;
    }

    fn shmMap(ptr: *anyopaque, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        const f = cast(ptr);
        f.enter();
        defer f.leave();
        return f.node.shm.map(Files.gpa, &f.shm, region, size, extend);
    }

    fn shmLock(ptr: *anyopaque, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        const f = cast(ptr);
        if (!try inproc.Shm.lockNeeded(&f.shm, ofst, n, flags)) return;
        f.enter();
        defer f.leave();
        return f.node.shm.lock(&f.shm, ofst, n, flags);
    }

    fn shmBarrier(ptr: *anyopaque) void {
        const f = cast(ptr);
        f.enter();
        f.leave();
    }

    fn shmUnmap(ptr: *anyopaque, _: bool) void {
        const f = cast(ptr);
        if (!f.shm.on) return;
        f.enter();
        defer f.leave();
        f.node.shm.unmap(Files.gpa, &f.shm);
    }
};

const testing = std.testing;

fn testVfs(tmp: *testing.TmpDir) WasiVfs {
    var w = WasiVfs.init(testing.allocator, testing.io);
    w.dir = tmp.dir;
    return w;
}

test "wasi: read/write/short read/truncate/delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var w = testVfs(&tmp);
    const v = w.interface();

    try testing.expectError(error.CantOpen, v.open("a.db", .{}));
    const f = try v.open("a.db", .{ .create = true });
    try f.write("hello", 10);
    try testing.expectEqual(@as(u64, 15), try f.fileSize());
    var buf: [8]u8 = undefined;
    try testing.expectError(error.ShortRead, f.read(&buf, 12));
    try testing.expectEqualSlices(u8, "llo\x00\x00\x00\x00\x00", &buf);
    try f.truncate(3);
    try testing.expectEqual(@as(u64, 3), try f.fileSize());
    try f.sync(.{});
    try testing.expect(try v.access("a.db", .exists));
    try testing.expectError(error.CantOpen, v.open("a.db", .{ .create = true, .exclusive = true }));
    f.close();
    try v.delete("a.db", true);
    try testing.expect(!try v.access("a.db", .exists));
    try v.delete("a.db", false);

    // Anonymous files live in memory.
    const t = try v.open(null, .{ .kind = .temp_db });
    defer t.close();
    try t.write("tmp", 0);
    try testing.expectEqual(@as(u64, 3), try t.fileSize());
}

test "wasi: handles of two VFS objects lock each other out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var w1 = testVfs(&tmp);
    var w2 = testVfs(&tmp);
    const a = try w1.interface().open("x.db", .{ .create = true });
    defer a.close();
    const b = try w2.interface().open("x.db", .{});
    defer b.close();

    try a.lock(.shared);
    try b.lock(.shared);
    try a.lock(.reserved);
    try testing.expect(try b.checkReservedLock());
    try testing.expectError(error.Busy, b.lock(.reserved));
    try testing.expectError(error.Busy, a.lock(.exclusive));
    try b.unlock(.none);
    try a.lock(.exclusive);
    try testing.expectError(error.Busy, b.lock(.shared));
    try a.unlock(.none);
    try b.lock(.shared);
    try b.unlock(.none);
}

test "wasi: shared memory is shared by the handles of a file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var w = testVfs(&tmp);
    const v = w.interface();
    const a = try v.open("x.db", .{ .create = true });
    defer a.close();
    const b = try v.open("x.db", .{});
    defer b.close();
    try testing.expect(a.hasShm());

    const ra = try a.shmMap(0, 32768, true);
    ra.ptr.?[100] = 42;
    const rb = try b.shmMap(0, 32768, false);
    try testing.expectEqual(@as(u8, 42), rb.ptr.?[100]);
    try a.shmLock(0, 1, .{ .exclusive = true });
    try testing.expectError(error.Busy, b.shmLock(0, 1, .{}));
    try a.shmLock(0, 1, .{ .unlock = true, .exclusive = true });
    try b.shmLock(3, 1, .{});
    a.shmBarrier();
    a.shmUnmap(false);
    b.shmUnmap(true);
}
