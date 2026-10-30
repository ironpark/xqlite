//! In-process locking and shared memory, for the backends that have no
//! lock the operating system arbitrates: the WASI VFS (WASI has no
//! advisory locks) and the host VFS of wasm32-freestanding. Several
//! connections of one process (one WebAssembly instance) still see each
//! other's locks, as with the memory VFS; another process does not.
//!
//! The caller keeps one `Locks` and one `Shm` per file (by identity, not
//! per handle) and serializes the calls with its own mutex.

const std = @import("std");
const vfs = @import("vfs.zig");

const Allocator = std.mem.Allocator;
const LockLevel = vfs.LockLevel;
const Error = vfs.Error;

/// The five-level lock of one file, shared by its handles. Follows the
/// transitions of vfs.LockLevel with counters instead of byte ranges
/// (the same arbitration as the memory VFS).
pub const Locks = struct {
    /// Handles holding SHARED or stronger.
    n_shared: u32 = 0,
    /// Some handle holds RESERVED or stronger.
    reserved: bool = false,
    /// Some handle holds PENDING or stronger.
    pending: bool = false,

    /// Raise `held`, one handle's lock, to `level`.
    pub fn lock(s: *Locks, held: *LockLevel, level: LockLevel) Error!void {
        if (held.atLeast(level)) return;
        switch (level) {
            .shared => {
                std.debug.assert(held.* == .none);
                if (s.pending) return error.Busy;
                s.n_shared += 1;
                held.* = .shared;
            },
            .reserved => {
                std.debug.assert(held.* == .shared);
                if (s.reserved) return error.Busy;
                s.reserved = true;
                held.* = .reserved;
            },
            .exclusive => {
                std.debug.assert(held.atLeast(.shared));
                if (held.* == .shared) {
                    // SHARED -> EXCLUSIVE directly (hot-journal rollback).
                    if (s.reserved or s.n_shared > 1) return error.Busy;
                    s.reserved = true;
                    s.pending = true;
                } else if (held.* == .reserved) {
                    s.pending = true;
                    held.* = .pending;
                }
                if (s.n_shared > 1) return error.Busy;
                held.* = .exclusive;
            },
            .none, .pending => unreachable,
        }
    }

    /// Lower `held` to `level` (.none or .shared).
    pub fn unlock(s: *Locks, held: *LockLevel, level: LockLevel) void {
        if (!held.atLeast(level) or held.* == level) return;
        if (held.atLeast(.reserved)) s.reserved = false;
        if (held.atLeast(.pending)) s.pending = false;
        if (level == .none) s.n_shared -= 1;
        held.* = level;
    }
};

/// The wal-index of one database in heap memory: what the -shm file is
/// to the unix VFS, without the file. It lives while some handle maps it,
/// so a WAL database reopened later rebuilds it from the WAL file, as
/// after a crash.
pub const Shm = struct {
    regions: std.ArrayList([]align(8) u8) = .empty,
    /// Handles that have mapped it.
    n_ref: u32 = 0,
    locks: vfs.ShmLockTable = .{},

    /// One handle's connection to the shared memory.
    pub const Conn = struct {
        on: bool = false,
        held: vfs.ShmLockTable.Held = .{},
    };

    pub fn map(s: *Shm, gpa: Allocator, c: *Conn, region: u32, size: u32, extend: bool) Error!vfs.ShmRegion {
        if (!c.on) {
            c.on = true;
            s.n_ref += 1;
        }
        if (s.regions.items.len <= region) {
            if (!extend) return .{ .ptr = null };
            try s.regions.ensureTotalCapacity(gpa, region + 1);
            while (s.regions.items.len <= region) {
                const r = try gpa.alignedAlloc(u8, .@"8", size);
                @memset(r, 0);
                s.regions.appendAssumeCapacity(r);
            }
        }
        std.debug.assert(s.regions.items[region].len == size);
        return .{ .ptr = s.regions.items[region].ptr };
    }

    /// Whether `lock` would change anything (asked before taking the
    /// caller's mutex).
    pub fn lockNeeded(c: *const Conn, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!bool {
        if (!c.on) return error.ShmLock;
        return vfs.ShmLockTable.needed(c.held, ofst, n, flags);
    }

    pub fn lock(s: *Shm, c: *Conn, ofst: u32, n: u32, flags: vfs.ShmLockFlags) Error!void {
        const no_file: struct {
            pub fn lock(_: @This(), _: vfs.ShmLockTable.FileLock, _: u32, _: u32) Error!void {}
        } = .{};
        return s.locks.apply(&c.held, ofst, n, flags, no_file);
    }

    /// Drop `c`'s connection, with any lock it still holds; the memory is
    /// freed with the last one.
    pub fn unmap(s: *Shm, gpa: Allocator, c: *Conn) void {
        if (!c.on) return;
        for (&s.locks.slots, 0..) |*l, i| {
            const bit = @as(u16, 1) << @intCast(i);
            if (c.held.excl & bit != 0) l.* = 0;
            if (c.held.shared & bit != 0) l.* -= 1;
        }
        c.* = .{};
        s.n_ref -= 1;
        if (s.n_ref == 0) s.deinit(gpa);
    }

    pub fn deinit(s: *Shm, gpa: Allocator) void {
        for (s.regions.items) |r| gpa.free(r);
        s.regions.deinit(gpa);
        s.* = .{};
    }
};

const testing = std.testing;

test "inproc: lock arbitration" {
    var s: Locks = .{};
    var a: LockLevel = .none;
    var b: LockLevel = .none;
    try s.lock(&a, .shared);
    try s.lock(&b, .shared);
    try s.lock(&a, .reserved);
    try testing.expectError(error.Busy, s.lock(&b, .reserved));
    try testing.expectError(error.Busy, s.lock(&a, .exclusive));
    try testing.expectEqual(LockLevel.pending, a);
    s.unlock(&b, .none);
    try s.lock(&a, .exclusive);
    try testing.expectError(error.Busy, s.lock(&b, .shared));
    s.unlock(&a, .shared);
    try s.lock(&b, .shared);
    s.unlock(&a, .none);
    s.unlock(&b, .none);
    try testing.expectEqual(@as(u32, 0), s.n_shared);
}

test "inproc: shared memory" {
    const gpa = testing.allocator;
    var s: Shm = .{};
    var a: Shm.Conn = .{};
    var b: Shm.Conn = .{};
    const r = try s.map(gpa, &a, 0, 32768, true);
    try testing.expect(r.ptr != null);
    try testing.expectEqual(r.ptr, (try s.map(gpa, &b, 0, 32768, false)).ptr);
    try testing.expect((try s.map(gpa, &b, 1, 32768, false)).ptr == null);
    try s.lock(&a, 0, 1, .{ .exclusive = true });
    try testing.expectError(error.Busy, s.lock(&b, 0, 1, .{}));
    s.unmap(gpa, &a);
    try s.lock(&b, 0, 1, .{});
    s.unmap(gpa, &b);
    try testing.expectEqual(@as(usize, 0), s.regions.items.len);
}
