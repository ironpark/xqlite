//! xqlite_vfs: the OS abstraction layer of xqlite (sqlite3_vfs and
//! sqlite3_io_methods), a package of its own. It depends on nothing of
//! the engine; the engine hands it what it needs: the heap of the memdb
//! VFS (memdb.Memdb()) and the directory of temporary files
//! (temp_directory).
//!
//! `vfs` is the interface (Vfs, File, Error, LockLevel, ...); the rest
//! are its implementations.

const builtin = @import("builtin");

/// The interface every VFS implements, and OsVfs.
pub const vfs = @import("vfs.zig");
/// A VFS in memory, for tests and private databases.
pub const mem = @import("mem.zig");
/// The memdb VFS (sqlite3_deserialize()), generic over its heap.
pub const memdb = @import("memdb.zig");
/// The in-process lock tables of the VFSes without system locks.
pub const inproc = @import("inproc.zig");
/// A VFS wrapper that crashes the process at a chosen write (testing aid).
pub const crash = @import("crash.zig");
/// The POSIX VFS; an empty namespace on WebAssembly.
pub const unix = switch (builtin.os.tag) {
    .wasi, .freestanding => struct {},
    else => @import("unix.zig"),
};
/// The WASI VFS; an empty namespace but on wasm32-wasi.
pub const wasi = if (builtin.os.tag == .wasi) @import("wasi.zig") else struct {};
/// The host VFS of wasm32-freestanding; an empty namespace elsewhere.
pub const host = if (builtin.os.tag == .freestanding) @import("host.zig") else struct {};

pub const Vfs = vfs.Vfs;
pub const File = vfs.File;
pub const Error = vfs.Error;
pub const MemVfs = mem.MemVfs;
/// The file-system VFS of the target: unix.UnixVfs, wasi.WasiVfs or
/// host.HostVfs.
pub const OsVfs = vfs.OsVfs;

/// sqlite3_temp_directory: the first directory the POSIX VFS tries for
/// temporary files, if set (unix.zig, tempFileDir()). The package only
/// reads it; its owner sets it and owns its memory: in xqlite, PRAGMA
/// temp_store_directory (memory from sqlite3_malloc()), and C programs
/// through the variable the C ABI exports under that name.
pub var temp_directory: ?[*:0]u8 = null;

test {
    _ = vfs;
}
