//! In-memory VFS. Files live in a name-keyed table owned by the `MemVfs`, so
//! several handles to the same name share contents and locks, which lets the
//! pager and its journal behave exactly as they would on disk. Intended for
//! tests and `:memory:`-style databases.

const std = @import("std");
const vfs = @import("vfs.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;

pub const MemVfs = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    files: std.StringHashMapUnmanaged(*Node) = .empty,

    /// Shared state of one named (or anonymous) file.
    const Node = struct {
        data: std.ArrayList(u8) = .empty,
        /// Owned copy of the name, null for anonymous files or after delete.
        name: ?[]u8,
        ref_count: u32 = 0,
        delete_on_close: bool = false,
        /// Number of handles holding SHARED or stronger.
        n_shared: u32 = 0,
        /// Some handle holds RESERVED or stronger.
        reserved: bool = false,
        /// Some handle holds PENDING or stronger.
        pending: bool = false,
    };

    pub fn init(gpa: Allocator, io: Io) MemVfs {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees every remaining file. All handles must already be closed.
    pub fn deinit(self: *MemVfs) void {
        var it = self.files.valueIterator();
        while (it.next()) |node| {
            std.debug.assert(node.*.ref_count == 0);
            self.destroyNode(node.*);
        }
        self.files.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn interface(self: *MemVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: vfs.Vfs.VTable = .{
        .open = open,
        .delete = delete,
        .access = access,
    };

    fn destroyNode(self: *MemVfs, node: *Node) void {
        node.data.deinit(self.gpa);
        if (node.name) |n| self.gpa.free(n);
        self.gpa.destroy(node);
    }

    fn open(ptr: *anyopaque, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const self: *MemVfs = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const handle = try self.gpa.create(MemFile);
        errdefer self.gpa.destroy(handle);

        const node: *Node = if (path) |p| blk: {
            if (self.files.get(p)) |existing| {
                if (flags.exclusive) return error.CantOpen;
                break :blk existing;
            }
            if (!flags.create) return error.CantOpen;
            const node = try self.gpa.create(Node);
            errdefer self.gpa.destroy(node);
            const name = try self.gpa.dupe(u8, p);
            errdefer self.gpa.free(name);
            node.* = .{ .name = name };
            try self.files.put(self.gpa, name, node);
            break :blk node;
        } else blk: {
            const node = try self.gpa.create(Node);
            node.* = .{ .name = null };
            break :blk node;
        };

        node.ref_count += 1;
        if (flags.delete_on_close) node.delete_on_close = true;
        handle.* = .{ .owner = self, .node = node, .read_only = !flags.read_write };
        return .{ .ptr = handle, .vtable = &MemFile.vtable };
    }

    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void {
        _ = sync_dir;
        const self: *MemVfs = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.unlinkLocked(path);
    }

    fn unlinkLocked(self: *MemVfs, path: []const u8) void {
        const kv = self.files.fetchRemove(path) orelse return;
        const node = kv.value;
        // The map key is node.name, so free it only after removal.
        self.gpa.free(node.name.?);
        node.name = null;
        if (node.ref_count == 0) {
            self.destroyNode(node);
        } else {
            // Like unlink(2): open handles keep the data alive.
            node.delete_on_close = true;
        }
    }

    fn access(ptr: *anyopaque, path: []const u8, mode: vfs.AccessMode) Error!bool {
        _ = mode;
        const self: *MemVfs = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.files.contains(path);
    }
};

const MemFile = struct {
    owner: *MemVfs,
    node: *MemVfs.Node,
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

    fn cast(ptr: *anyopaque) *MemFile {
        return @ptrCast(@alignCast(ptr));
    }

    fn enter(f: *MemFile) void {
        f.owner.mutex.lockUncancelable(f.owner.io);
    }

    fn leave(f: *MemFile) void {
        f.owner.mutex.unlock(f.owner.io);
    }

    fn close(ptr: *anyopaque) void {
        const f = cast(ptr);
        unlock(ptr, .none) catch unreachable;
        const owner = f.owner;
        f.enter();
        const node = f.node;
        node.ref_count -= 1;
        if (node.ref_count == 0 and node.delete_on_close) {
            if (node.name) |n| owner.unlinkLocked(n) else owner.destroyNode(node);
        }
        f.leave();
        owner.gpa.destroy(f);
    }

    fn read(ptr: *anyopaque, buf: []u8, offset: u64) Error!usize {
        const f = cast(ptr);
        f.enter();
        defer f.leave();
        const data = f.node.data.items;
        const start = @min(offset, data.len);
        const n = @min(buf.len, data.len - start);
        @memcpy(buf[0..n], data[start..][0..n]);
        return n;
    }

    fn write(ptr: *anyopaque, buf: []const u8, offset: u64) Error!void {
        const f = cast(ptr);
        if (f.read_only) return error.ReadOnly;
        f.enter();
        defer f.leave();
        const end = std.math.add(u64, offset, buf.len) catch return error.IoErr;
        const list = &f.node.data;
        if (end > list.items.len) {
            const old_len = list.items.len;
            try list.resize(f.owner.gpa, @intCast(end));
            // Writing past EOF leaves a hole that reads back as zeros.
            if (offset > old_len) @memset(list.items[old_len..@intCast(offset)], 0);
        }
        @memcpy(list.items[@intCast(offset)..][0..buf.len], buf);
    }

    fn truncate(ptr: *anyopaque, size: u64) Error!void {
        const f = cast(ptr);
        if (f.read_only) return error.ReadOnly;
        f.enter();
        defer f.leave();
        const list = &f.node.data;
        if (size < list.items.len) list.shrinkRetainingCapacity(@intCast(size));
    }

    fn sync(_: *anyopaque, _: vfs.SyncFlags) Error!void {}

    fn fileSize(ptr: *anyopaque) Error!u64 {
        const f = cast(ptr);
        f.enter();
        defer f.leave();
        return f.node.data.items.len;
    }

    /// In-process arbitration only. Follows the same transition rules as the
    /// unix VFS (vfs.LockLevel) but tracks them with per-file flags.
    fn lock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (f.level.atLeast(level)) return;
        f.enter();
        defer f.leave();
        const node = f.node;
        switch (level) {
            .shared => {
                std.debug.assert(f.level == .none);
                if (node.pending) return error.Busy;
                node.n_shared += 1;
                f.level = .shared;
            },
            .reserved => {
                std.debug.assert(f.level == .shared);
                if (node.reserved) return error.Busy;
                node.reserved = true;
                f.level = .reserved;
            },
            .exclusive => {
                std.debug.assert(f.level.atLeast(.shared));
                if (f.level == .shared) {
                    // SHARED -> EXCLUSIVE directly (hot-journal rollback).
                    if (node.reserved) return error.Busy;
                    if (node.n_shared > 1) return error.Busy;
                    node.reserved = true;
                    node.pending = true;
                } else if (f.level == .reserved) {
                    node.pending = true;
                    f.level = .pending;
                }
                if (node.n_shared > 1) return error.Busy;
                f.level = .exclusive;
            },
            .none, .pending => unreachable,
        }
    }

    fn unlock(ptr: *anyopaque, level: LockLevel) Error!void {
        const f = cast(ptr);
        if (!f.level.atLeast(level) or f.level == level) return;
        f.enter();
        defer f.leave();
        const node = f.node;
        if (f.level.atLeast(.reserved)) node.reserved = false;
        if (f.level.atLeast(.pending)) node.pending = false;
        if (level == .none) node.n_shared -= 1;
        f.level = level;
    }

    fn checkReservedLock(ptr: *anyopaque) Error!bool {
        const f = cast(ptr);
        f.enter();
        defer f.leave();
        return f.node.reserved;
    }

    fn sectorSize(_: *anyopaque) u32 {
        return vfs.default_sector_size;
    }

    fn deviceCharacteristics(_: *anyopaque) vfs.DeviceCharacteristics {
        return .{
            .atomic = true,
            .safe_append = true,
            .sequential = true,
            .powersafe_overwrite = true,
            .subpage_read = true,
        };
    }
};

const testing = std.testing;

test "mem: read/write/short read/truncate" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    try testing.expectError(error.CantOpen, v.open("a.db", .{}));
    const f = try v.open("a.db", .{ .create = true });
    defer f.close();

    try f.write("hello", 10);
    try testing.expectEqual(@as(u64, 15), try f.fileSize());

    var buf: [8]u8 = undefined;
    try f.read(buf[0..5], 10);
    try testing.expectEqualStrings("hello", buf[0..5]);
    try f.read(buf[0..4], 0);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buf[0..4]);

    @memset(&buf, 0xaa);
    try testing.expectError(error.ShortRead, f.read(&buf, 12));
    try testing.expectEqualSlices(u8, "llo\x00\x00\x00\x00\x00", &buf);

    try f.truncate(3);
    try testing.expectEqual(@as(u64, 3), try f.fileSize());
}

test "mem: handles share contents, delete semantics" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    const a = try v.open("x", .{ .create = true });
    const b = try v.open("x", .{});
    try a.write("abc", 0);
    var buf: [3]u8 = undefined;
    try b.read(&buf, 0);
    try testing.expectEqualStrings("abc", &buf);

    try testing.expectError(error.CantOpen, v.open("x", .{ .create = true, .exclusive = true }));

    try v.delete("x", false);
    try testing.expect(!try v.access("x", .exists));
    // Open handles still see the data after unlink.
    try b.read(&buf, 0);
    try testing.expectEqualStrings("abc", &buf);
    a.close();
    b.close();

    const t = try v.open(null, .{ .create = true });
    try t.write("tmp", 0);
    t.close();

    const r = try v.open("ro", .{ .create = true });
    r.close();
    const ro = try v.open("ro", .{ .read_write = false });
    defer ro.close();
    try testing.expectError(error.ReadOnly, ro.write("x", 0));
}

test "mem: locking protocol" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    const a = try v.open("db", .{ .create = true });
    defer a.close();
    const b = try v.open("db", .{});
    defer b.close();

    try a.lock(.shared);
    try b.lock(.shared);
    try a.lock(.reserved);
    try testing.expect(try b.checkReservedLock());
    try testing.expectError(error.Busy, b.lock(.reserved));

    // b still holds SHARED, so a stalls at PENDING.
    try testing.expectError(error.Busy, a.lock(.exclusive));
    // PENDING blocks new readers.
    const c = try v.open("db", .{});
    defer c.close();
    try testing.expectError(error.Busy, c.lock(.shared));

    try b.unlock(.none);
    try a.lock(.exclusive);
    try a.unlock(.shared);
    try testing.expect(!try b.checkReservedLock());
    try c.lock(.shared);
    try b.lock(.shared);
    try a.unlock(.none);
    try b.lock(.reserved);
}
