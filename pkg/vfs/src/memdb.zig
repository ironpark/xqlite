//! The memdb VFS (port of the VFS half of memdb.c): a database held as
//! one contiguous block of memory. sqlite3_deserialize() reopens a
//! database on it (sql/serialize.zig), and the C ABI registers it as
//! "memdb", so `file:/name?vfs=memdb` opens it by URI.
//!
//! A store is separate or shared. A shared store has a name that starts
//! with "/" (or "\\"): every connection of the process that opens that
//! name gets the same store, which lives until the last of them closes
//! it. Any other name, or none, makes a store private to the handle.
//! A shared store has a lock of its own; the list of shared stores has
//! one too (SQLITE_MUTEX_STATIC_VFS1).
//!
//! The memory of a store comes from the heap the VFS is instantiated
//! with (Memdb()): in xqlite, the library allocator (sqlite3_malloc()),
//! since sqlite3_deserialize() hands over a buffer from it with
//! SQLITE_DESERIALIZE_FREEONCLOSE. The files have no shared
//! memory, so WAL mode is refused, and they report themselves as
//! in-memory (File.isMemory()), so the pager keeps its rollback journal
//! in memory (journal_mode=MEMORY), here in a private memdb store.

const std = @import("std");
const vfs = @import("vfs.zig");

const LockLevel = vfs.LockLevel;
const Error = vfs.Error;

/// SQLITE_DESERIALIZE_* flags of a store.
pub const FREEONCLOSE: u32 = 1;
pub const RESIZEABLE: u32 = 2;
pub const READONLY: u32 = 4;

/// A lock for the short critical sections of the shared stores; on
/// wasm32 there is a single thread.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(l: *SpinLock) void {
        while (l.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(l: *SpinLock) void {
        l.locked.store(false, .release);
    }
};

/// The memdb VFS on `heap`, which provides the memory of its stores
/// and handles: `allocator` (a std.mem.Allocator), and `realloc(p, n)`
/// and `free(p)` on a pointer alone, as sqlite3_realloc() and
/// sqlite3_free() take one (sqlite3_deserialize() hands over a buffer
/// from sqlite3_malloc() to resize and free). xqlite instantiates it once
/// with its library allocator (sql/memdb.zig), so that the stores count
/// in sqlite3_status() and toward the heap limit; each instance has its
/// own shared stores and settings.
pub fn Memdb(comptime heap: type) type {
    return struct {
        /// Port of MemStore: the content of a memdb file.
        pub const Store = struct {
            /// Size of the file.
            sz: i64 = 0,
            /// Space allocated to `data`.
            sz_alloc: i64 = 0,
            /// Largest allowed size of the file.
            sz_max: i64,
            data: ?[*]u8 = null,
            /// SQLITE_DESERIALIZE_* flags.
            flags: u32 = RESIZEABLE | FREEONCLOSE,
            n_rd_lock: i32 = 0,
            /// Writers: 0 or 1.
            n_wr_lock: i32 = 0,
            /// Handles open on the store.
            n_ref: i32 = 1,
            /// The name of a shared store (from the library allocator), null for
            /// a separate one.
            name: ?[]u8 = null,
            /// Used by shared stores only.
            mutex: SpinLock = .{},

            fn enter(p: *Store) void {
                if (p.name != null) p.mutex.lock();
            }

            fn leave(p: *Store) void {
                if (p.name != null) p.mutex.unlock();
            }

            /// The content of the file.
            pub fn bytes(p: *Store) []u8 {
                const d = p.data orelse return &.{};
                return d[0..@intCast(p.sz)];
            }

            /// Port of memdbEnlarge(): grow the allocation to hold at least
            /// `new_sz` bytes.
            fn enlarge(p: *Store, new_sz_arg: i64) Error!void {
                if (p.flags & RESIZEABLE == 0) return error.DiskFull;
                if (new_sz_arg > p.sz_max) return error.DiskFull;
                var new_sz = new_sz_arg * 2;
                if (new_sz > p.sz_max) new_sz = p.sz_max;
                const q = heap.realloc(p.data, @intCast(new_sz)) orelse return error.OutOfMemory;
                p.data = q;
                p.sz_alloc = new_sz;
            }

            fn destroy(p: *Store) void {
                if (p.flags & FREEONCLOSE != 0) heap.free(p.data);
                if (p.name) |n| heap.allocator.free(n);
                heap.allocator.destroy(p);
            }
        };

        /// The process-wide state of memdb.
        pub var state: struct {
            /// memdb_g: the shared stores, under `lock`
            /// (SQLITE_MUTEX_STATIC_VFS1).
            lock: SpinLock = .{},
            stores: std.ArrayList(*Store) = .empty,
            /// The VFS whose randomness and sleep memdb borrows (ORIGVFS():
            /// pAppData, the default VFS when it was registered). Set once,
            /// before use, by whoever registers it (the C ABI); without one,
            /// randomness is zeros and sleep does not sleep.
            lower: ?vfs.Vfs = null,
            /// sqlite3GlobalConfig.mxMemdbSize (SQLITE_CONFIG_MEMDB_MAXSIZE):
            /// the default largest size of a store
            /// (SQLITE_MEMDB_DEFAULT_MAXSIZE).
            default_max_size: i64 = 1073741824,
        } = .{};

        const shared = &state;

        const instance: u8 = 0;

        /// The memdb VFS.
        pub fn interface() vfs.Vfs {
            return .{ .ptr = @constCast(&instance), .vtable = vtable };
        }

        /// Port of sqlite3IsMemdb().
        pub fn isMemdb(v: vfs.Vfs) bool {
            return v.vtable == vtable;
        }

        /// The methods below named after those of vfs.Vfs.VTable (on
        /// `instance`, which they ignore) and vfs.File.VTable (on a
        /// MemFile) implement them (vfs.VfsImpl(), vfs.FileImpl()).
        const vtable = &vfs.VfsImpl(@This()).vtable;
        const file_vtable = &vfs.FileImpl(@This()).vtable;

        /// Port of memdbOpen().
        pub fn open(_: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
            const a = heap.allocator;
            const f = try a.create(MemFile);
            errdefer a.destroy(f);
            const name = path orelse "";
            var p: *Store = undefined;
            if (name.len > 1 and (name[0] == '/' or name[0] == '\\')) {
                shared.lock.lock();
                defer shared.lock.unlock();
                const found = for (shared.stores.items) |s| {
                    if (std.mem.eql(u8, s.name.?, name)) break s;
                } else null;
                if (found) |s| {
                    s.enter();
                    s.n_ref += 1;
                    s.leave();
                    p = s;
                } else {
                    p = try a.create(Store);
                    errdefer a.destroy(p);
                    const n = try a.dupe(u8, name);
                    errdefer a.free(n);
                    try shared.stores.append(a, p);
                    p.* = .{ .sz_max = state.default_max_size, .name = n };
                }
            } else {
                p = try a.create(Store);
                p.* = .{ .sz_max = state.default_max_size };
            }
            f.* = .{ .store = p, .read_only = !flags.read_write };
            return .{ .ptr = f, .vtable = file_vtable };
        }

        /// memdb has no xDelete: the journal is never a file of its own. A
        /// journal the pager was told to keep in a named store is gone with its
        /// last handle.
        pub fn delete(_: *anyopaque, _: []const u8, _: bool) Error!void {}

        /// Port of memdbAccess(): no file ever exists on disk.
        pub fn access(_: *anyopaque, _: []const u8, _: vfs.AccessMode) Error!bool {
            return false;
        }

        pub fn randomness(_: *anyopaque, buf: []u8) void {
            if (state.lower) |l| return l.randomness(buf);
            @memset(buf, 0);
        }

        pub fn sleep(_: *anyopaque, us: u32) u32 {
            if (state.lower) |l| return l.sleep(us);
            return 0;
        }

        /// Port of MemFile: an open handle on a store.
        pub const MemFile = struct {
            store: *Store,
            /// Most recent lock against this file (eLock).
            level: LockLevel = .none,
            read_only: bool,

            fn of(ptr: *anyopaque) *MemFile {
                return @ptrCast(@alignCast(ptr));
            }
        };

        /// The handle behind `f` if it is a memdb file.
        pub fn fileOf(f: vfs.File) ?*MemFile {
            if (f.vtable != file_vtable) return null;
            return MemFile.of(f.ptr);
        }

        /// Port of memdbClose(): the store is freed with its last handle.
        pub fn close(f: *MemFile) void {
            const p = f.store;
            var last = false;
            if (p.name != null) {
                shared.lock.lock();
                defer shared.lock.unlock();
                p.enter();
                if (p.n_ref == 1) {
                    for (shared.stores.items, 0..) |s, i| if (s == p) {
                        _ = shared.stores.swapRemove(i);
                        break;
                    };
                    if (shared.stores.items.len == 0) shared.stores.clearAndFree(heap.allocator);
                }
                p.n_ref -= 1;
                last = p.n_ref <= 0;
                p.leave();
            } else {
                p.n_ref -= 1;
                last = p.n_ref <= 0;
            }
            if (last) p.destroy();
            heap.allocator.destroy(f);
        }

        /// Port of memdbRead().
        pub fn read(f: *MemFile, buf: []u8, offset: u64) Error!usize {
            const p = f.store;
            p.enter();
            defer p.leave();
            const sz: u64 = @intCast(p.sz);
            if (offset + buf.len > sz) {
                if (offset >= sz) return 0;
                const n: usize = @intCast(sz - offset);
                @memcpy(buf[0..n], p.data.?[@intCast(offset)..][0..n]);
                return n;
            }
            @memcpy(buf, p.data.?[@intCast(offset)..][0..buf.len]);
            return buf.len;
        }

        /// Port of memdbWrite().
        pub fn write(f: *MemFile, buf: []const u8, offset_u: u64) Error!void {
            const p = f.store;
            p.enter();
            defer p.leave();
            // memdbLock() refuses a write lock first.
            if (p.flags & READONLY != 0) return error.IoErr;
            const offset: i64 = @intCast(offset_u);
            const end = offset + @as(i64, @intCast(buf.len));
            if (end > p.sz) {
                if (end > p.sz_alloc) try p.enlarge(end);
                if (offset > p.sz) @memset(p.data.?[@intCast(p.sz)..@intCast(offset)], 0);
                p.sz = end;
            }
            @memcpy(p.data.?[@intCast(offset)..][0..buf.len], buf);
        }

        /// Port of memdbTruncate(): only ever shrinks (growing is a corrupt WAL
        /// database, which memdb cannot hold).
        pub fn truncate(f: *MemFile, size: u64) Error!void {
            const p = f.store;
            p.enter();
            defer p.leave();
            if (@as(i64, @intCast(size)) > p.sz) return error.IoErr;
            p.sz = @intCast(size);
        }

        pub fn sync(_: *MemFile, _: vfs.SyncFlags) Error!void {}

        pub fn fileSize(f: *MemFile) Error!u64 {
            const p = f.store;
            p.enter();
            defer p.leave();
            return @intCast(p.sz);
        }

        /// Port of memdbLock().
        pub fn lock(f: *MemFile, level: LockLevel) Error!void {
            const p = f.store;
            if (f.level.atLeast(level)) return;
            p.enter();
            defer p.leave();
            if (level.atLeast(.reserved) and p.flags & READONLY != 0) return error.ReadOnly;
            switch (level) {
                .shared => {
                    if (p.n_wr_lock > 0) return error.Busy;
                    p.n_rd_lock += 1;
                },
                .reserved, .pending => {
                    if (f.level == .shared) {
                        if (p.n_wr_lock > 0) return error.Busy;
                        p.n_wr_lock = 1;
                    }
                },
                .exclusive => {
                    if (p.n_rd_lock > 1) return error.Busy;
                    if (f.level == .shared) p.n_wr_lock = 1;
                },
                .none => unreachable,
            }
            f.level = level;
        }

        /// Port of memdbUnlock().
        pub fn unlock(f: *MemFile, level: LockLevel) Error!void {
            const p = f.store;
            if (level.atLeast(f.level)) return;
            p.enter();
            defer p.leave();
            if (level == .shared) {
                if (f.level.atLeast(.reserved)) p.n_wr_lock -= 1;
            } else {
                if (f.level.atLeast(.reserved)) p.n_wr_lock -= 1;
                p.n_rd_lock -= 1;
            }
            f.level = level;
        }

        /// Only used for crash recovery, which an in-memory database never
        /// needs (memdb has no xCheckReservedLock).
        pub fn checkReservedLock(_: *MemFile) Error!bool {
            return false;
        }

        /// No xSectorSize: SQLITE_DEFAULT_SECTOR_SIZE.
        pub fn sectorSize(_: *MemFile) u32 {
            return vfs.default_sector_size;
        }

        /// Port of memdbDeviceCharacteristics().
        pub fn deviceCharacteristics(_: *MemFile) vfs.DeviceCharacteristics {
            return .{ .atomic = true, .powersafe_overwrite = true, .safe_append = true, .sequential = true };
        }

        pub fn isReadOnly(f: *MemFile) bool {
            return f.read_only;
        }

        pub fn isMemory(_: *MemFile) bool {
            return true;
        }

        /// Port of memdbFileControl(SQLITE_FCNTL_SIZE_LIMIT): set the largest
        /// size of the store to `limit` (but not below its size; negative only
        /// asks) and return it.
        pub fn sizeLimit(f: *MemFile, limit_arg: i64) i64 {
            const p = f.store;
            p.enter();
            defer p.leave();
            var limit = limit_arg;
            if (limit < p.sz) limit = if (limit < 0) p.sz_max else p.sz;
            p.sz_max = limit;
            return limit;
        }

        /// For memdbFileControl(SQLITE_FCNTL_VFSNAME): the address and size of
        /// the content.
        pub fn describe(f: *MemFile) struct { data: usize, sz: i64 } {
            const p = f.store;
            p.enter();
            defer p.leave();
            return .{ .data = @intFromPtr(p.data), .sz = p.sz };
        }

        /// The store of a separate memdb file (memdbFromDbSchema(): null for a
        /// shared one, whose content other connections change).
        pub fn separateStore(f: *MemFile) ?*Store {
            const p = f.store;
            if (p.name != null) return null;
            return p;
        }
    };
}

const testing = std.testing;

/// The heap of the tests: the C library's, whose realloc() and free()
/// take a pointer alone.
const test_heap = struct {
    const allocator = std.heap.c_allocator;

    fn realloc(p: ?*anyopaque, n: u64) ?[*]u8 {
        return @ptrCast(std.c.realloc(p, @intCast(n)));
    }

    fn free(p: ?*anyopaque) void {
        std.c.free(p);
    }
};

test "memdb: separate and shared stores" {
    const M = Memdb(test_heap);
    const v = M.interface();
    const a = try v.open("x", .{ .create = true });
    const b = try v.open("x", .{ .create = true });
    try a.write("hello", 0);
    try testing.expectEqual(@as(u64, 5), try a.fileSize());
    // Separate: "x" twice is two stores.
    try testing.expectEqual(@as(u64, 0), try b.fileSize());
    a.close();
    b.close();

    const s1 = try v.open("/shared", .{ .create = true });
    const s2 = try v.open("/shared", .{ .create = true });
    try s1.write("abc", 2);
    var buf: [8]u8 = undefined;
    try testing.expectError(error.ShortRead, s2.read(&buf, 0));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 'a', 'b', 'c', 0, 0, 0 }, &buf);
    try s1.lock(.shared);
    try s2.lock(.shared);
    try s1.lock(.reserved);
    try testing.expectError(error.Busy, s2.lock(.reserved));
    try testing.expectError(error.Busy, s1.lock(.exclusive));
    try s2.unlock(.none);
    try s1.lock(.exclusive);
    try s1.unlock(.none);
    s1.close();
    try testing.expectEqual(@as(u64, 5), try s2.fileSize());
    s2.close();
    // The last handle freed it.
    const s3 = try v.open("/shared", .{ .create = true });
    try testing.expectEqual(@as(u64, 0), try s3.fileSize());
    try testing.expect(s3.isMemory());
    const mf = M.fileOf(s3).?;
    try testing.expectEqual(@as(i64, 4096), M.sizeLimit(mf, 4096));
    try testing.expectError(error.DiskFull, s3.write(&@as([8]u8, @splat(1)), 4092));
    try testing.expectEqual(@as(i64, 4096), M.sizeLimit(mf, -1));
    s3.close();
}
