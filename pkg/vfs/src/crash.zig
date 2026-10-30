//! A fault-injection VFS for crash tests. It wraps another VFS, counts the
//! writes to the files of one kind (the WAL, the main database or its
//! rollback journal), and at the Nth one ends the process at once, the way
//! a crash or power loss stops it: the files keep what was written, and
//! the locks go with the process. Optionally the Nth write is torn: only
//! its first half reaches the file.
//!
//! Only the `xqlite` command installs it, when $XQLITE_TEST_CRASH asks
//! for it (see `Spec.parse` and `xqt interop wal`); the library never
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
        return .{ .ptr = self, .vtable = vtable };
    }

    /// The methods named after those of vfs.Vfs.VTable implement it
    /// (vfs.VfsImpl()).
    const vtable = &vfs.VfsImpl(CrashVfs).vtable;

    pub fn open(self: *CrashVfs, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const inner = try self.inner.open(path, flags);
        errdefer inner.close();
        const f = try self.gpa.create(CrashFile);
        f.* = .{ .owner = self, .inner = inner, .counted = self.spec.target.matches(flags.kind) };
        return .{ .ptr = f, .vtable = if (inner.hasShm()) CrashFile.vtable else CrashFile.vtable_no_shm };
    }

    pub fn delete(self: *CrashVfs, path: []const u8, sync_dir: bool) Error!void {
        return self.inner.delete(path, sync_dir);
    }

    pub fn access(self: *CrashVfs, path: []const u8, mode: vfs.AccessMode) Error!bool {
        return self.inner.access(path, mode);
    }

    pub fn randomness(self: *CrashVfs, buf: []u8) void {
        self.inner.randomness(buf);
    }

    pub fn sleep(self: *CrashVfs, microseconds: u32) u32 {
        return self.inner.sleep(microseconds);
    }

    pub fn fullPathname(self: *CrashVfs, path: []const u8, out: []u8) Error![]u8 {
        const inner = self.inner;
        const f = inner.vtable.fullPathname orelse {
            if (path.len > out.len) return error.CantOpen;
            @memcpy(out[0..path.len], path);
            return out[0..path.len];
        };
        return f(inner.ptr, path, out);
    }
};

/// A file of the wrapped VFS; everything but `write` is passed through.
const CrashFile = struct {
    owner: *CrashVfs,
    inner: vfs.File,
    /// Writes to this file count.
    counted: bool,

    /// The methods named after those of vfs.File.VTable implement it
    /// (vfs.FileImpl()); without the shm methods for a wrapped file that
    /// has no shared memory.
    const vtable = &vfs.FileImpl(CrashFile).vtable;
    const vtable_no_shm = &vfs.FileImplWithout(CrashFile, &.{ "shmMap", "shmLock", "shmBarrier", "shmUnmap" }).vtable;

    pub fn close(f: *CrashFile) void {
        f.inner.close();
        f.owner.gpa.destroy(f);
    }

    pub fn read(f: *CrashFile, buf: []u8, offset: u64) Error!usize {
        const inner = f.inner;
        return inner.vtable.read(inner.ptr, buf, offset);
    }

    pub fn write(f: *CrashFile, buf: []const u8, offset: u64) Error!void {
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

    pub fn truncate(f: *CrashFile, size: u64) Error!void {
        return f.inner.truncate(size);
    }

    pub fn sync(f: *CrashFile, flags: vfs.SyncFlags) Error!void {
        return f.inner.sync(flags);
    }

    pub fn fileSize(f: *CrashFile) Error!u64 {
        return f.inner.fileSize();
    }

    pub fn lock(f: *CrashFile, level: vfs.LockLevel) Error!void {
        return f.inner.lock(level);
    }

    pub fn unlock(f: *CrashFile, level: vfs.LockLevel) Error!void {
        return f.inner.unlock(level);
    }

    pub fn checkReservedLock(f: *CrashFile) Error!bool {
        return f.inner.checkReservedLock();
    }

    pub fn sectorSize(f: *CrashFile) u32 {
        return f.inner.sectorSize();
    }

    pub fn deviceCharacteristics(f: *CrashFile) vfs.DeviceCharacteristics {
        return f.inner.deviceCharacteristics();
    }

    pub fn isReadOnly(f: *CrashFile) bool {
        return f.inner.isReadOnly();
    }

    pub fn shmMap(f: *CrashFile, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        return f.inner.shmMap(region, size, extend);
    }

    pub fn shmLock(f: *CrashFile, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        return f.inner.shmLock(ofst, n, flags);
    }

    pub fn shmBarrier(f: *CrashFile) void {
        f.inner.shmBarrier();
    }

    pub fn shmUnmap(f: *CrashFile, delete: bool) void {
        f.inner.shmUnmap(delete);
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
    // can be checked here; `xqt interop wal` crashes for real.
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
    // MemVfs has shared memory, so its files keep the shm methods.
    try testing.expect(db.vtable == wal.vtable and wal.hasShm());
}

test "crash: the table without shared memory" {
    const with = CrashFile.vtable;
    const without = CrashFile.vtable_no_shm;
    try testing.expect(with != without);
    try testing.expect(with.shmMap != null and with.shmUnmap != null);
    try testing.expect(without.shmMap == null and without.shmLock == null);
    try testing.expect(without.shmBarrier == null and without.shmUnmap == null);
    try testing.expect(with.isMemory == null and without.isMemory == null);
    try testing.expect(with.read == without.read and with.write == without.write);
}
