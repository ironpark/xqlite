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

/// Default sector size reported by files (SQLITE_DEFAULT_SECTOR_SIZE).
pub const default_sector_size: u32 = 4096;

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
        return @intFromEnum(a) >= @intFromEnum(b);
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
};

pub const Vfs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ptr: *anyopaque, path: ?[]const u8, flags: OpenFlags) Error!File,
        delete: *const fn (ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void,
        access: *const fn (ptr: *anyopaque, path: []const u8, mode: AccessMode) Error!bool,
    };

    /// Opens `path`. A null path asks for an anonymous temporary file; the
    /// backend picks the name and always receives create, exclusive and
    /// delete_on_close set.
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
};

test {
    _ = @import("mem.zig");
    _ = @import("unix.zig");
}
