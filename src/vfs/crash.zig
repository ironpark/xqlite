//! A fault-injection VFS for crash tests. It wraps another VFS, counts the
//! writes to the files of one kind (the WAL, the main database or its
//! rollback journal), and at the Nth one ends the process at once, the way
//! a crash or power loss stops it: the files keep what was written, and
//! the locks go with the process. Optionally the Nth write is torn: only
//! its first half reaches the file.
//!
//! Only the `xqlite` command installs it, when $XQLITE_TEST_CRASH asks
//! for it (see `Spec.parse` and tools/interop-wal.sh); the library never
//! does.

const std = @import("std");
const vfs = @import("vfs.zig");

const Allocator = std.mem.Allocator;
const Error = vfs.Error;

/// Which writes count.
pub const Target = enum {
    /// The WAL (SQLITE_OPEN_WAL).
    wal,
    /// The main database file (SQLITE_OPEN_MAIN_DB).
    db,
    /// The main database's rollback journal (SQLITE_OPEN_MAIN_JOURNAL).
    journal,

    fn matches(t: Target, kind: vfs.FileKind) bool {
        return switch (t) {
            .wal => kind == .wal,
            .db => kind == .main_db,
            .journal => kind == .main_journal,
        };
    }
};

/// Where to crash.
pub const Spec = struct {
    target: Target,
    /// Crash at this write to a `target` file (1 for the first).
    at: u64,
    /// Write only the first half of that write before crashing.
    torn: bool = false,

    /// Parses "TARGET:N" or "TARGET:N:torn", TARGET being wal, db or
    /// journal; null if malformed.
    pub fn parse(text: []const u8) ?Spec {
        var it = std.mem.splitScalar(u8, text, ':');
        const target = std.meta.stringToEnum(Target, it.next().?) orelse return null;
        const at = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        if (at == 0) return null;
        var spec: Spec = .{ .target = target, .at = at };
        if (it.next()) |opt| {
            if (!std.mem.eql(u8, opt, "torn")) return null;
            spec.torn = true;
        }
        if (it.next() != null) return null;
        return spec;
    }
};

pub const CrashVfs = struct {
    gpa: Allocator,
    inner: vfs.Vfs,
    spec: Spec,
    /// Writes to `spec.target` files so far.
    count: u64 = 0,

    pub fn init(gpa: Allocator, inner: vfs.Vfs, spec: Spec) CrashVfs {
        return .{ .gpa = gpa, .inner = inner, .spec = spec };
    }

    pub fn interface(self: *CrashVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: vfs.Vfs.VTable = .{
        .open = open,
        .delete = delete,
        .access = access,
        .randomness = randomness,
        .sleep = sleep,
    };

    fn cast(ptr: *anyopaque) *CrashVfs {
        return @ptrCast(@alignCast(ptr));
    }

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const self = cast(ptr);
        const inner = try self.inner.open(path, flags);
        errdefer inner.close();
        const f = try self.gpa.create(CrashFile);
        f.* = .{ .owner = self, .inner = inner, .counted = self.spec.target.matches(flags.kind) };
        return .{ .ptr = f, .vtable = if (inner.hasShm()) &CrashFile.vtable else &CrashFile.vtable_no_shm };
    }

    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void {
        return cast(ptr).inner.delete(path, sync_dir);
    }

    fn access(ptr: *anyopaque, path: []const u8, mode: vfs.AccessMode) Error!bool {
        return cast(ptr).inner.access(path, mode);
    }

    fn randomness(ptr: *anyopaque, buf: []u8) void {
        cast(ptr).inner.randomness(buf);
    }

    fn sleep(ptr: *anyopaque, microseconds: u32) u32 {
        return cast(ptr).inner.sleep(microseconds);
    }
};

/// A file of the wrapped VFS; everything but `write` is passed through.
const CrashFile = struct {
    owner: *CrashVfs,
    inner: vfs.File,
    /// Writes to this file count.
    counted: bool,

    const vtable_no_shm: vfs.File.VTable = .{
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
    };

    const vtable: vfs.File.VTable = blk: {
        var t = vtable_no_shm;
        t.shmMap = shmMap;
        t.shmLock = shmLock;
        t.shmBarrier = shmBarrier;
        t.shmUnmap = shmUnmap;
        break :blk t;
    };

    fn cast(ptr: *anyopaque) *CrashFile {
        return @ptrCast(@alignCast(ptr));
    }

    fn fileOf(ptr: *anyopaque) vfs.File {
        return cast(ptr).inner;
    }

    fn close(ptr: *anyopaque) void {
        const f = cast(ptr);
        f.inner.close();
        f.owner.gpa.destroy(f);
    }

    fn read(ptr: *anyopaque, buf: []u8, offset: u64) Error!usize {
        const f = fileOf(ptr);
        return f.vtable.read(f.ptr, buf, offset);
    }

    fn write(ptr: *anyopaque, buf: []const u8, offset: u64) Error!void {
        const f = cast(ptr);
        if (!f.counted) return f.inner.write(buf, offset);
        const owner = f.owner;
        owner.count += 1;
        if (owner.count != owner.spec.at) return f.inner.write(buf, offset);
        if (owner.spec.torn) {
            try f.inner.write(buf[0 .. buf.len / 2], offset);
        } else {
            try f.inner.write(buf, offset);
        }
        std.process.exit(0);
    }

    fn truncate(ptr: *anyopaque, size: u64) Error!void {
        return fileOf(ptr).truncate(size);
    }

    fn sync(ptr: *anyopaque, flags: vfs.SyncFlags) Error!void {
        return fileOf(ptr).sync(flags);
    }

    fn fileSize(ptr: *anyopaque) Error!u64 {
        return fileOf(ptr).fileSize();
    }

    fn lock(ptr: *anyopaque, level: vfs.LockLevel) Error!void {
        return fileOf(ptr).lock(level);
    }

    fn unlock(ptr: *anyopaque, level: vfs.LockLevel) Error!void {
        return fileOf(ptr).unlock(level);
    }

    fn checkReservedLock(ptr: *anyopaque) Error!bool {
        return fileOf(ptr).checkReservedLock();
    }

    fn sectorSize(ptr: *anyopaque) u32 {
        return fileOf(ptr).sectorSize();
    }

    fn deviceCharacteristics(ptr: *anyopaque) vfs.DeviceCharacteristics {
        return fileOf(ptr).deviceCharacteristics();
    }

    fn isReadOnly(ptr: *anyopaque) bool {
        return fileOf(ptr).isReadOnly();
    }

    fn shmMap(ptr: *anyopaque, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        return fileOf(ptr).shmMap(region, size, extend);
    }

    fn shmLock(ptr: *anyopaque, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        return fileOf(ptr).shmLock(ofst, n, flags);
    }

    fn shmBarrier(ptr: *anyopaque) void {
        fileOf(ptr).shmBarrier();
    }

    fn shmUnmap(ptr: *anyopaque, delete: bool) void {
        fileOf(ptr).shmUnmap(delete);
    }
};

const testing = std.testing;

test "crash: spec parsing" {
    try testing.expectEqual(Spec{ .target = .wal, .at = 7 }, Spec.parse("wal:7").?);
    try testing.expectEqual(Spec{ .target = .db, .at = 1, .torn = true }, Spec.parse("db:1:torn").?);
    for ([_][]const u8{ "", "wal", "wal:", "wal:0", "frame:3", "db:x", "db:2:half", "db:2:torn:x" }) |bad| {
        try testing.expect(Spec.parse(bad) == null);
    }
}

test "crash: the Nth write to a file of the target kind crashes" {
    const MemVfs = @import("mem.zig").MemVfs;
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    // The crash itself ends the process, so only the writes before it
    // can be checked here; tools/interop-wal.sh crashes for real.
    var cv = CrashVfs.init(testing.allocator, mem.interface(), .{ .target = .wal, .at = 3 });
    const v = cv.interface();
    const db = try v.open("t.db", .{ .create = true });
    defer db.close();
    const wal = try v.open("t.db-wal", .{ .kind = .wal, .create = true });
    defer wal.close();
    // Writes to other kinds do not count.
    try db.write("abcd", 0);
    try db.write("abcd", 4);
    try wal.write("1", 0);
    try wal.write("2", 1);
    try testing.expectEqual(@as(u64, 2), cv.count);
    try testing.expect(!wal.isReadOnly());
}
