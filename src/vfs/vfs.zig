//! OS abstraction layer (port of sqlite3_vfs / sqlite3_io_methods, os.h, os.c).
//!
//! `Vfs` opens, deletes and probes files. `File` is an open handle with
//! positional I/O and the five-level SQLite locking protocol. Both are
//! type-erased interfaces in the style of `std.mem.Allocator`.

const std = @import("std");

/// Byte offsets of the lock region shared by every SQLite implementation.
/// Changing these breaks interoperability with real SQLite processes.
pub const pending_byte: u64 = 0x40000000;
pub const reserved_byte: u64 = pending_byte + 1;
pub const shared_first: u64 = pending_byte + 2;
pub const shared_size: u64 = 510;

/// The longest file name (PATH_MAX); wasm32-freestanding, which has
/// none, gets 4096.
pub const max_path_bytes = if (@import("builtin").os.tag == .freestanding) 4096 else std.fs.max_path_bytes;

/// Default sector size reported by files (SQLITE_DEFAULT_SECTOR_SIZE).
pub const default_sector_size: u32 = 4096;

/// Number of shared-memory locks (SQLITE_SHM_NLOCK). The WAL uses lock 0
/// for the writer, 1 for the checkpointer, 2 for recovery and 3..7 for
/// readers.
pub const shm_nlock: u32 = 8;

/// What `File.shmLock` does (the SQLITE_SHM_LOCK, SQLITE_SHM_UNLOCK,
/// SQLITE_SHM_SHARED and SQLITE_SHM_EXCLUSIVE flags).
pub const ShmLockFlags = struct {
    unlock: bool = false,
    exclusive: bool = false,
};

/// A region of shared memory returned by `File.shmMap`.
pub const ShmRegion = struct {
    /// Null if the region does not exist yet and `extend` was false, or
    /// with `cant_init`.
    ptr: ?[*]align(8) u8,
    /// The memory can only be read (SQLITE_READONLY from xShmMap).
    read_only: bool = false,
    /// The memory is read-only and no connection that could initialize
    /// it is attached, so its content cannot be trusted; nothing was
    /// mapped (SQLITE_READONLY_CANTINIT from xShmMap). Implies
    /// `read_only`. The next call checks again.
    cant_init: bool = false,
};

/// The in-process half of shared-memory locking (from unixShmLock()):
/// every connection to one shared memory in this process shares a table
/// of the locks held on each slot, and the backend's lock on the
/// underlying file (if any) is only taken by the first lock of the
/// process on a slot and released with the last. The caller serializes
/// access to the table.
pub const ShmLockTable = struct {
    /// Per slot, the number of shared locks held in this process, or -1
    /// for an exclusive one (aLock).
    slots: [shm_nlock]i32 = @splat(0),

    /// The locks held by one connection (sharedMask, exclMask).
    pub const Held = struct {
        shared: u16 = 0,
        excl: u16 = 0,
    };

    /// What `apply` asks of the backend's lock on the file.
    pub const FileLock = enum { read, write, unlock };

    fn mask(ofst: u32, n: u32) u16 {
        return @intCast((@as(u32, 1) << @intCast(ofst + n)) - (@as(u32, 1) << @intCast(ofst)));
    }

    /// Whether `flags` on slots `ofst`..`ofst+n-1` would change anything
    /// for `held`: an unlock of locks held, or a lock not held yet. Asked
    /// before taking the mutex that guards the table.
    pub fn needed(held: Held, ofst: u32, n: u32, flags: ShmLockFlags) bool {
        const m = mask(ofst, n);
        std.debug.assert(flags.unlock or !flags.exclusive or held.excl & m == 0);
        if (flags.unlock) return (held.excl | held.shared) & m != 0;
        if (!flags.exclusive) return held.shared & m == 0;
        return true;
    }

    /// Take or release locks for the connection `held` (see
    /// `File.shmLock`), which `needed` said would change something.
    /// `file.lock(kind, ofst, n)` takes or releases the backend's lock on
    /// the slots; it returns `Error!void`. Fails with Busy when another
    /// connection holds a conflicting lock.
    pub fn apply(t: *ShmLockTable, held: *Held, ofst: u32, n: u32, flags: ShmLockFlags, file: anytype) Error!void {
        const m = mask(ofst, n);
        const slots = &t.slots;
        if (flags.unlock) {
            // Other connections in this process may hold the same shared
            // lock: keep the file lock for them.
            if (!flags.exclusive) {
                std.debug.assert(n == 1 and slots[ofst] >= 1);
                if (slots[ofst] > 1) {
                    slots[ofst] -= 1;
                    held.shared &= ~m;
                    return;
                }
            }
            try file.lock(.unlock, ofst, n);
            @memset(slots[ofst..][0..n], 0);
            held.shared &= ~m;
            held.excl &= ~m;
        } else if (!flags.exclusive) {
            if (slots[ofst] < 0) return error.Busy;
            if (slots[ofst] == 0) try file.lock(.read, ofst, n);
            held.shared |= m;
            slots[ofst] += 1;
        } else {
            std.debug.assert(held.shared & m == 0 and held.excl & m == 0);
            // A sibling connection holding any of the locks blocks us.
            for (slots[ofst..][0..n]) |l| if (l != 0) return error.Busy;
            try file.lock(.write, ofst, n);
            held.excl |= m;
            @memset(slots[ofst..][0..n], -1);
        }
    }
};

/// SQLite file lock levels. Ordering matters: a higher value is a stronger lock.
///
///     NONE -> SHARED
///     SHARED -> RESERVED
///     SHARED -> EXCLUSIVE
///     RESERVED -> (PENDING) -> EXCLUSIVE
///     PENDING -> EXCLUSIVE
///
/// PENDING is never requested directly; it is an intermediate state that
/// `lock(.exclusive)` may leave behind when it fails with `error.Busy`.
pub const LockLevel = enum(u8) {
    none = 0,
    shared = 1,
    reserved = 2,
    pending = 3,
    exclusive = 4,

    pub fn atLeast(a: LockLevel, b: LockLevel) bool {
        return @backingInt(a) >= @backingInt(b);
    }
};

/// What a file is used for (SQLITE_OPEN_MAIN_DB etc.).
pub const FileKind = enum {
    main_db,
    main_journal,
    temp_db,
    temp_journal,
    transient_db,
    subjournal,
    super_journal,
    wal,
};

pub const OpenFlags = struct {
    kind: FileKind = .main_db,
    /// Open read-write. When false the file is opened read-only.
    read_write: bool = true,
    /// Create the file if it does not exist. Requires `read_write`.
    create: bool = false,
    /// Fail if the file already exists. Requires `create`.
    exclusive: bool = false,
    /// Delete the file when the last handle is closed.
    delete_on_close: bool = false,
    /// The path is a name of the pager's, in SQLite's filename layout
    /// (see Pager.names): NUL-terminated, followed by the URI parameters
    /// of the database and the journal and WAL names, so that a C VFS
    /// can read them with sqlite3_uri_parameter() and
    /// sqlite3_filename_*(). Before the four zero bytes in front of the
    /// database name is a pointer-sized slot for the database's
    /// sqlite3_file (sqlite3_database_file_object()).
    sqlite_filename: bool = false,
};

pub const SyncFlags = struct {
    /// Use the strongest durability the platform offers (F_FULLFSYNC on Darwin).
    full: bool = false,
    /// Only file data needs to reach the disk, not metadata such as size.
    data_only: bool = false,
};

/// SQLITE_IOCAP_* bits.
pub const DeviceCharacteristics = packed struct(u32) {
    atomic: bool = false,
    atomic512: bool = false,
    atomic1k: bool = false,
    atomic2k: bool = false,
    atomic4k: bool = false,
    atomic8k: bool = false,
    atomic16k: bool = false,
    atomic32k: bool = false,
    atomic64k: bool = false,
    safe_append: bool = false,
    sequential: bool = false,
    undeletable_when_open: bool = false,
    powersafe_overwrite: bool = false,
    immutable: bool = false,
    batch_atomic: bool = false,
    subpage_read: bool = false,
    _: u16 = 0,
};

pub const AccessMode = enum {
    exists,
    read_write,
    read,
};

pub const Error = error{
    /// Another connection holds a conflicting lock (SQLITE_BUSY).
    Busy,
    /// The file could not be opened (SQLITE_CANTOPEN).
    CantOpen,
    /// A read returned fewer bytes than requested. The unread tail of the
    /// buffer has been zero-filled (SQLITE_IOERR_SHORT_READ).
    ShortRead,
    /// The disk is full (SQLITE_FULL).
    DiskFull,
    /// Attempt to write a read-only file (SQLITE_READONLY).
    ReadOnly,
    /// Generic I/O failure (SQLITE_IOERR and most extended codes).
    IoErr,
    /// Failure while acquiring or releasing a lock (SQLITE_IOERR_LOCK/UNLOCK).
    LockErr,
    /// The shared-memory file could not be opened or initialized
    /// (SQLITE_IOERR_SHMOPEN).
    ShmOpen,
    /// The shared-memory file could not be sized (SQLITE_IOERR_SHMSIZE).
    ShmSize,
    /// The shared-memory file could not be mapped (SQLITE_IOERR_SHMMAP).
    ShmMap,
    /// A shared-memory lock was used without shared memory
    /// (SQLITE_IOERR_SHMLOCK).
    ShmLock,
    OutOfMemory,
};

pub const File = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (ptr: *anyopaque) void,
        /// Returns the number of bytes read; fewer than `buf.len` means EOF.
        read: *const fn (ptr: *anyopaque, buf: []u8, offset: u64) Error!usize,
        write: *const fn (ptr: *anyopaque, buf: []const u8, offset: u64) Error!void,
        truncate: *const fn (ptr: *anyopaque, size: u64) Error!void,
        sync: *const fn (ptr: *anyopaque, flags: SyncFlags) Error!void,
        fileSize: *const fn (ptr: *anyopaque) Error!u64,
        lock: *const fn (ptr: *anyopaque, level: LockLevel) Error!void,
        unlock: *const fn (ptr: *anyopaque, level: LockLevel) Error!void,
        checkReservedLock: *const fn (ptr: *anyopaque) Error!bool,
        sectorSize: *const fn (ptr: *anyopaque) u32,
        deviceCharacteristics: *const fn (ptr: *anyopaque) DeviceCharacteristics,
        /// Whether the file was opened read-only, also when read-write
        /// was asked for (SQLITE_OPEN_READONLY in xOpen's pOutFlags).
        isReadOnly: *const fn (ptr: *anyopaque) bool,
        /// The shared-memory methods (xShmMap, xShmLock, xShmBarrier,
        /// xShmUnmap). Null in a backend without shared memory, where WAL
        /// needs exclusive locking mode (heap-memory wal-index).
        shmMap: ?*const fn (ptr: *anyopaque, region: u32, size: u32, extend: bool) Error!ShmRegion = null,
        shmLock: ?*const fn (ptr: *anyopaque, ofst: u32, n: u32, flags: ShmLockFlags) Error!void = null,
        shmBarrier: ?*const fn (ptr: *anyopaque) void = null,
        shmUnmap: ?*const fn (ptr: *anyopaque, delete: bool) void = null,
        /// Whether the file lives in memory (SQLITE_OPEN_MEMORY in
        /// xOpen's pOutFlags): the pager then keeps its journal in memory
        /// too (memVfs). Null means no.
        isMemory: ?*const fn (ptr: *anyopaque) bool = null,
    };

    /// Closes the handle, dropping any lock it holds.
    pub fn close(f: File) void {
        f.vtable.close(f.ptr);
    }

    /// Reads exactly `buf.len` bytes at `offset`. On a short read the
    /// remainder of `buf` is zero-filled and `error.ShortRead` is returned.
    pub fn read(f: File, buf: []u8, offset: u64) Error!void {
        const n = try f.vtable.read(f.ptr, buf, offset);
        if (n < buf.len) {
            @memset(buf[n..], 0);
            return error.ShortRead;
        }
    }

    pub fn write(f: File, buf: []const u8, offset: u64) Error!void {
        return f.vtable.write(f.ptr, buf, offset);
    }

    pub fn truncate(f: File, size: u64) Error!void {
        return f.vtable.truncate(f.ptr, size);
    }

    pub fn sync(f: File, flags: SyncFlags) Error!void {
        return f.vtable.sync(f.ptr, flags);
    }

    pub fn fileSize(f: File) Error!u64 {
        return f.vtable.fileSize(f.ptr);
    }

    /// Raises the lock to `level`. A no-op if the lock is already at least `level`.
    pub fn lock(f: File, level: LockLevel) Error!void {
        std.debug.assert(level != .none and level != .pending);
        return f.vtable.lock(f.ptr, level);
    }

    /// Lowers the lock to `level`, which must be `.none` or `.shared`.
    pub fn unlock(f: File, level: LockLevel) Error!void {
        std.debug.assert(level == .none or level == .shared);
        return f.vtable.unlock(f.ptr, level);
    }

    /// Whether any connection holds a RESERVED or stronger lock.
    pub fn checkReservedLock(f: File) Error!bool {
        return f.vtable.checkReservedLock(f.ptr);
    }

    pub fn sectorSize(f: File) u32 {
        return f.vtable.sectorSize(f.ptr);
    }

    pub fn deviceCharacteristics(f: File) DeviceCharacteristics {
        return f.vtable.deviceCharacteristics(f.ptr);
    }

    /// Whether the file is open read-only: asked for, or the fallback when
    /// it could not be opened read-write (as unixOpen() reports it in
    /// pOutFlags).
    pub fn isReadOnly(f: File) bool {
        return f.vtable.isReadOnly(f.ptr);
    }

    /// Whether the file is a VFS-implemented in-memory database (the
    /// memdb VFS), as SQLITE_OPEN_MEMORY in pOutFlags tells the pager.
    pub fn isMemory(f: File) bool {
        const m = f.vtable.isMemory orelse return false;
        return m(f.ptr);
    }

    /// Whether the backend implements shared memory (xShmMap != 0).
    pub fn hasShm(f: File) bool {
        return f.vtable.shmMap != null;
    }

    /// Port of sqlite3OsShmMap(): region `region` (each `size` bytes) of
    /// the shared memory of the database file, created if `extend` and it
    /// does not exist yet. The shared memory is opened on first use.
    pub fn shmMap(f: File, region: u32, size: u32, extend: bool) Error!ShmRegion {
        return f.vtable.shmMap.?(f.ptr, region, size, extend);
    }

    /// Port of sqlite3OsShmLock(): take or release shared-memory locks
    /// `ofst`..`ofst+n-1`. Shared locks are one at a time. Fails with
    /// Busy when another connection holds a conflicting lock.
    pub fn shmLock(f: File, ofst: u32, n: u32, flags: ShmLockFlags) Error!void {
        std.debug.assert(n >= 1 and ofst + n <= shm_nlock);
        std.debug.assert(n == 1 or flags.exclusive);
        return f.vtable.shmLock.?(f.ptr, ofst, n, flags);
    }

    /// Port of sqlite3OsShmBarrier(): a full memory barrier.
    pub fn shmBarrier(f: File) void {
        f.vtable.shmBarrier.?(f.ptr);
    }

    /// Port of sqlite3OsShmUnmap(): drop this handle's connection to the
    /// shared memory, deleting it with `delete` if no other remains.
    pub fn shmUnmap(f: File, delete: bool) void {
        if (f.vtable.shmUnmap) |unmap| unmap(f.ptr, delete);
    }
};

pub const Vfs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque, path: ?[]const u8, flags: OpenFlags) Error!File,
        delete: *const fn (ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void,
        access: *const fn (ptr: *anyopaque, path: []const u8, mode: AccessMode) Error!bool,
        randomness: *const fn (ptr: *anyopaque, buf: []u8) void,
        /// Sleeps for at least `microseconds` and returns the time slept
        /// (xSleep).
        sleep: *const fn (ptr: *anyopaque, microseconds: u32) u32,
        /// Writes the canonical, absolute name of `path` into `out` and
        /// returns it (xFullPathname). Null for a backend whose names are
        /// already canonical: the name is used as given.
        fullPathname: ?*const fn (ptr: *anyopaque, path: []const u8, out: []u8) Error![]u8 = null,
    };

    /// Opens `path`. A null path asks for an anonymous temporary file; the
    /// backend picks the name and always receives create, exclusive and
    /// delete_on_close set. A backend may open a file read-only when it
    /// cannot be opened read-write; `File.isReadOnly` tells.
    pub fn open(v: Vfs, path: ?[]const u8, flags: OpenFlags) Error!File {
        std.debug.assert(!flags.create or flags.read_write);
        std.debug.assert(!flags.exclusive or flags.create);
        var fl = flags;
        if (path == null) {
            fl.read_write = true;
            fl.create = true;
            fl.exclusive = true;
            fl.delete_on_close = true;
        }
        return v.vtable.open(v.ptr, path, fl);
    }

    /// Deletes `path`. Deleting a file that does not exist is not an error.
    /// With `sync_dir`, the containing directory is synced afterwards so the
    /// deletion survives a power loss.
    pub fn delete(v: Vfs, path: []const u8, sync_dir: bool) Error!void {
        return v.vtable.delete(v.ptr, path, sync_dir);
    }

    pub fn access(v: Vfs, path: []const u8, mode: AccessMode) Error!bool {
        return v.vtable.access(v.ptr, path, mode);
    }

    /// Fills `buf` with random bytes (xRandomness).
    pub fn randomness(v: Vfs, buf: []u8) void {
        v.vtable.randomness(v.ptr, buf);
    }

    /// Port of sqlite3OsSleep().
    pub fn sleep(v: Vfs, microseconds: u32) u32 {
        return v.vtable.sleep(v.ptr, microseconds);
    }

    /// Port of sqlite3OsFullPathname(): the canonical name of `path`,
    /// allocated with `gpa`. The pager names a database by it, and its
    /// journal and WAL after it, as SQLite does: a super-journal records
    /// the journals by these names.
    pub fn fullPathname(v: Vfs, gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
        const f = v.vtable.fullPathname orelse return gpa.dupe(u8, path);
        var buf: [max_path_bytes]u8 = undefined;
        return gpa.dupe(u8, try f(v.ptr, path, &buf));
    }
};

/// xSleep for the backends on `std.Io` (unixSleep()).
pub fn ioSleep(io: std.Io, microseconds: u32) u32 {
    io.sleep(.fromMicroseconds(microseconds), .awake) catch {};
    return microseconds;
}

/// The file-system VFS of the target, chosen at compile time: the POSIX
/// VFS (vfs/unix.zig), the WASI VFS on wasm32-wasi (vfs/wasi.zig) and the
/// host VFS on wasm32-freestanding (vfs/host.zig). Each has
/// `init(gpa, io)` and `interface()`.
pub const OsVfs = switch (@import("builtin").os.tag) {
    .wasi => @import("wasi.zig").WasiVfs,
    .freestanding => @import("host.zig").HostVfs,
    else => @import("unix.zig").UnixVfs,
};

test {
    _ = @import("mem.zig");
    _ = @import("memdb.zig");
    _ = @import("inproc.zig");
    switch (@import("builtin").os.tag) {
        .wasi => _ = @import("wasi.zig"),
        .freestanding => {},
        else => _ = @import("unix.zig"),
    }
    _ = @import("crash.zig");
}
