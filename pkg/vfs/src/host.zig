//! Host VFS (wasm32-freestanding): the files are the embedder's. Every
//! file operation is a function the host supplies as an import of module
//! "env" (`xq_host_*` below), so JavaScript can keep the database in the
//! Origin Private File System, IndexedDB, a Node file or an ArrayBuffer.
//! examples/wasm/xqlite.mjs implements them; docs/wasm.md documents
//! the contract.
//!
//! Locks are arbitrated in this instance (inproc.zig, by file name),
//! and then offered to the host (`xq_host_lock`), which may refuse a
//! stronger lock with Busy to exclude other tabs or workers; the default
//! glue accepts everything. The wal-index of a WAL database is heap
//! memory of this instance, as in the WASI VFS. Anonymous temporary files
//! live in memory.
//!
//! Offsets and sizes cross the boundary as f64 (exact to 2^53), which a
//! JavaScript host reads as plain numbers.

const std = @import("std");
const builtin = @import("builtin");
const vfs = @import("vfs.zig");
const inproc = @import("inproc.zig");
const MemVfs = @import("mem.zig").MemVfs;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;

/// The imports. Results below zero are errors (see `hostError`).
pub const imports = struct {
    /// Open `path`; `flags` is `OpenBits`. Returns a handle (>= 0).
    pub extern "env" fn xq_host_open(path: [*]const u8, path_len: usize, flags: u32) i32;
    pub extern "env" fn xq_host_close(h: i32) void;
    /// Read up to `len` bytes at `offset`; returns the number read (fewer
    /// at the end of the file).
    pub extern "env" fn xq_host_read(h: i32, buf: [*]u8, len: usize, offset: f64) i32;
    /// Write all of `buf` at `offset`, extending the file. Returns 0.
    pub extern "env" fn xq_host_write(h: i32, buf: [*]const u8, len: usize, offset: f64) i32;
    pub extern "env" fn xq_host_truncate(h: i32, size: f64) i32;
    /// `flags`: 1 for a full sync (PRAGMA fullfsync), 2 for data only.
    pub extern "env" fn xq_host_sync(h: i32, flags: u32) i32;
    /// The size of the file, or a negative error.
    pub extern "env" fn xq_host_size(h: i32) f64;
    /// Delete `path`; a missing file is not an error.
    pub extern "env" fn xq_host_delete(path: [*]const u8, path_len: usize) i32;
    /// 1 if `path` exists (mode 0), is writable (1) or readable (2), else 0.
    pub extern "env" fn xq_host_access(path: [*]const u8, path_len: usize, mode: u32) i32;
    /// The handle's lock moves to `level` (0 none, 1 shared, 2 reserved,
    /// 4 exclusive). Return 0, or 5 (SQLITE_BUSY) to refuse a stronger
    /// lock. Lowering it cannot fail.
    pub extern "env" fn xq_host_lock(h: i32, level: u32) i32;
};

/// The `flags` of xq_host_open.
pub const OpenBits = packed struct(u32) {
    read_write: bool,
    create: bool,
    exclusive: bool,
    delete_on_close: bool,
    _: u4 = 0,
    /// vfs.FileKind: 0 main db, 1 main journal, ... 7 WAL.
    kind: u8,
    _1: u16 = 0,
};

/// Errors the host returns: -1 I/O error, -2 cannot open, -3 read-only,
/// -4 disk full, -5 busy.
fn hostError(rc: i32) Error {
    return switch (rc) {
        -2 => error.CantOpen,
        -3 => error.ReadOnly,
        -4 => error.DiskFull,
        -5 => error.Busy,
        else => error.IoErr,
    };
}

pub const HostVfs = struct {
    gpa: Allocator,
    io: Io,
    /// Where anonymous temporary files live.
    mem: MemVfs,

    pub fn init(gpa: Allocator, io: Io) HostVfs {
        return .{ .gpa = gpa, .io = io, .mem = .init(gpa, io) };
    }

    pub fn interface(self: *HostVfs) vfs.Vfs {
        return .{ .ptr = self, .vtable = vtable };
    }

    /// The methods named after those of vfs.Vfs.VTable implement it
    /// (vfs.VfsImpl()).
    const vtable = &vfs.VfsImpl(HostVfs).vtable;

    pub fn open(self: *HostVfs, path: ?[]const u8, flags: vfs.OpenFlags) Error!vfs.File {
        const name = path orelse return self.mem.interface().open(null, flags);
        const h = imports.xq_host_open(name.ptr, name.len, @bitCast(OpenBits{
            .read_write = flags.read_write,
            .create = flags.create,
            .exclusive = flags.exclusive,
            .delete_on_close = flags.delete_on_close,
            .kind = @backingInt(flags.kind),
        }));
        if (h < 0) return error.CantOpen;
        errdefer imports.xq_host_close(h);
        const node = try Node.acquire(self.io, name);
        errdefer node.release(self.io);
        const handle = try self.gpa.create(HostFile);
        handle.* = .{ .owner = self, .h = h, .node = node, .read_only = !flags.read_write };
        return .{ .ptr = handle, .vtable = HostFile.vtable };
    }

    pub fn delete(_: *HostVfs, path: []const u8, _: bool) Error!void {
        const rc = imports.xq_host_delete(path.ptr, path.len);
        if (rc < 0) return hostError(rc);
    }

    pub fn access(_: *HostVfs, path: []const u8, mode: vfs.AccessMode) Error!bool {
        const rc = imports.xq_host_access(path.ptr, path.len, switch (mode) {
            .exists => 0,
            .read_write => 1,
            .read => 2,
        });
        if (rc < 0) return hostError(rc);
        return rc != 0;
    }

    pub fn randomness(self: *HostVfs, buf: []u8) void {
        self.io.random(buf);
    }

    pub fn sleep(self: *HostVfs, microseconds: u32) u32 {
        return vfs.ioSleep(self.io, microseconds);
    }
};

/// The lock table of this instance, by file name: every handle on a
/// file, whatever connection or HostVfs it comes from, shares one Node.
var files: Files = .{};

const Files = struct {
    mutex: Io.Mutex = .init,
    table: std.StringHashMapUnmanaged(*Node) = .empty,

    /// The table outlives any one VFS instance.
    const gpa = if (builtin.link_libc)
        std.heap.c_allocator
    else if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.smp_allocator;
};

const Node = struct {
    name: []u8,
    ref_count: u32 = 0,
    locks: inproc.Locks = .{},
    shm: inproc.Shm = .{},

    fn acquire(io: Io, name: []const u8) Error!*Node {
        files.mutex.lockUncancelable(io);
        defer files.mutex.unlock(io);
        const gop = try files.table.getOrPut(Files.gpa, name);
        if (!gop.found_existing) {
            errdefer files.table.removeByPtr(gop.key_ptr);
            const node = try Files.gpa.create(Node);
            errdefer Files.gpa.destroy(node);
            node.* = .{ .name = try Files.gpa.dupe(u8, name) };
            gop.key_ptr.* = node.name;
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
        _ = files.table.remove(node.name);
        Files.gpa.free(node.name);
        Files.gpa.destroy(node);
    }
};

const HostFile = struct {
    owner: *HostVfs,
    h: i32,
    node: *Node,
    level: LockLevel = .none,
    read_only: bool,
    shm: inproc.Shm.Conn = .{},

    /// The methods named after those of vfs.File.VTable implement it
    /// (vfs.FileImpl()).
    const vtable = &vfs.FileImpl(HostFile).vtable;

    fn enter(f: *HostFile) void {
        files.mutex.lockUncancelable(f.owner.io);
    }

    fn leave(f: *HostFile) void {
        files.mutex.unlock(f.owner.io);
    }

    pub fn close(f: *HostFile) void {
        const owner = f.owner;
        std.debug.assert(!f.shm.on);
        shmUnmap(f, false);
        unlock(f, .none) catch {};
        imports.xq_host_close(f.h);
        f.node.release(owner.io);
        owner.gpa.destroy(f);
    }

    pub fn read(f: *HostFile, buf: []u8, offset: u64) Error!usize {
        const n = imports.xq_host_read(f.h, buf.ptr, buf.len, @floatFromInt(offset));
        if (n < 0) return hostError(n);
        return @intCast(n);
    }

    pub fn write(f: *HostFile, buf: []const u8, offset: u64) Error!void {
        if (f.read_only) return error.ReadOnly;
        const rc = imports.xq_host_write(f.h, buf.ptr, buf.len, @floatFromInt(offset));
        if (rc < 0) return hostError(rc);
    }

    pub fn truncate(f: *HostFile, size: u64) Error!void {
        if (f.read_only) return error.ReadOnly;
        const rc = imports.xq_host_truncate(f.h, @floatFromInt(size));
        if (rc < 0) return hostError(rc);
    }

    pub fn sync(f: *HostFile, flags: vfs.SyncFlags) Error!void {
        const rc = imports.xq_host_sync(f.h, @as(u32, @intFromBool(flags.full)) | @as(u32, @intFromBool(flags.data_only)) << 1);
        if (rc < 0) return hostError(rc);
    }

    pub fn fileSize(f: *HostFile) Error!u64 {
        const size = imports.xq_host_size(f.h);
        if (size < 0) return hostError(@intFromFloat(size));
        return @intFromFloat(size);
    }

    /// The in-process arbitration first; then the host may refuse.
    pub fn lock(f: *HostFile, level: LockLevel) Error!void {
        if (f.level.atLeast(level)) return;
        f.enter();
        defer f.leave();
        const before = .{ f.node.locks, f.level };
        try f.node.locks.lock(&f.level, level);
        if (imports.xq_host_lock(f.h, @backingInt(f.level)) != 0) {
            f.node.locks, f.level = before;
            return error.Busy;
        }
    }

    pub fn unlock(f: *HostFile, level: LockLevel) Error!void {
        if (!f.level.atLeast(level) or f.level == level) return;
        f.enter();
        defer f.leave();
        f.node.locks.unlock(&f.level, level);
        _ = imports.xq_host_lock(f.h, @backingInt(level));
    }

    pub fn checkReservedLock(f: *HostFile) Error!bool {
        f.enter();
        defer f.leave();
        return f.node.locks.reserved;
    }

    pub fn sectorSize(_: *HostFile) u32 {
        return vfs.default_sector_size;
    }

    pub fn deviceCharacteristics(_: *HostFile) vfs.DeviceCharacteristics {
        return .{ .powersafe_overwrite = true };
    }

    pub fn isReadOnly(f: *HostFile) bool {
        return f.read_only;
    }

    pub fn shmMap(f: *HostFile, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        f.enter();
        defer f.leave();
        return f.node.shm.map(Files.gpa, &f.shm, region, size, extend);
    }

    pub fn shmLock(f: *HostFile, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        if (!try inproc.Shm.lockNeeded(&f.shm, ofst, n, flags)) return;
        f.enter();
        defer f.leave();
        return f.node.shm.lock(&f.shm, ofst, n, flags);
    }

    pub fn shmBarrier(f: *HostFile) void {
        f.enter();
        f.leave();
    }

    pub fn shmUnmap(f: *HostFile, _: bool) void {
        if (!f.shm.on) return;
        f.enter();
        defer f.leave();
        f.node.shm.unmap(Files.gpa, &f.shm);
    }
};
