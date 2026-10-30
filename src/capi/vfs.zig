//! sqlite3_vfs_find(), sqlite3_vfs_register() and sqlite3_vfs_unregister():
//! the VFS registry of the C ABI, with adapters both ways.
//!
//! - The default VFS, "unix" ("wasi" on wasm32-wasi), is the engine's OS
//!   VFS (vfs/unix.zig, vfs/wasi.zig).
//!   Its sqlite3_vfs (unix_c) calls it, so a C VFS that wraps the
//!   default one (a shim that delegates xOpen to sqlite3_vfs_find(0), as
//!   SQLite's appendvfs and test VFSes do) gets working files.
//! - A VFS registered from C becomes an engine Vfs (cVfs()) whose files
//!   call the sqlite3_io_methods the C xOpen installed.
//!
//! - "memdb" is the engine's memdb VFS (vfs/memdb.zig), registered as
//!   SQLite registers it (sqlite3MemdbInit()), after the default.
//!
//! Connections name a VFS with the zVfs argument of sqlite3_open_v2() or
//! a URI's vfs= parameter, and ATTACH with its URI's vfs= (the engine
//! asks find() through global.find_vfs).
//!
//! A C VFS receives the names the pager keeps in SQLite's filename layout
//! (Pager.names), URI parameters included, and in the slot before a
//! database name the bridge leaves the database's sqlite3_file for
//! sqlite3_database_file_object().

const std = @import("std");
const c = @import("common.zig");
const memdb = @import("../vfs/memdb.zig");

const RC = c.RC;
const Vfs = c.vfs.Vfs;
const File = c.vfs.File;
const Error = c.vfs.Error;

// ============================================================ C structs

pub const sqlite3_file = extern struct {
    pMethods: ?*const IoMethods,
};

pub const IoMethods = extern struct {
    iVersion: c_int,
    xClose: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    xRead: ?*const fn (*sqlite3_file, ?*anyopaque, c_int, i64) callconv(.c) c_int,
    xWrite: ?*const fn (*sqlite3_file, ?*const anyopaque, c_int, i64) callconv(.c) c_int,
    xTruncate: ?*const fn (*sqlite3_file, i64) callconv(.c) c_int,
    xSync: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xFileSize: ?*const fn (*sqlite3_file, *i64) callconv(.c) c_int,
    xLock: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xUnlock: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int,
    xCheckReservedLock: ?*const fn (*sqlite3_file, *c_int) callconv(.c) c_int,
    xFileControl: ?*const fn (*sqlite3_file, c_int, ?*anyopaque) callconv(.c) c_int,
    xSectorSize: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    xDeviceCharacteristics: ?*const fn (*sqlite3_file) callconv(.c) c_int,
    // iVersion 2
    xShmMap: ?*const fn (*sqlite3_file, c_int, c_int, c_int, *?*anyopaque) callconv(.c) c_int = null,
    xShmLock: ?*const fn (*sqlite3_file, c_int, c_int, c_int) callconv(.c) c_int = null,
    xShmBarrier: ?*const fn (*sqlite3_file) callconv(.c) void = null,
    xShmUnmap: ?*const fn (*sqlite3_file, c_int) callconv(.c) c_int = null,
    // iVersion 3
    xFetch: ?*const fn (*sqlite3_file, i64, c_int, *?*anyopaque) callconv(.c) c_int = null,
    xUnfetch: ?*const fn (*sqlite3_file, i64, ?*anyopaque) callconv(.c) c_int = null,
};

pub const sqlite3_vfs = extern struct {
    iVersion: c_int,
    szOsFile: c_int,
    mxPathname: c_int,
    pNext: ?*sqlite3_vfs,
    zName: ?[*:0]const u8,
    pAppData: ?*anyopaque,
    xOpen: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, *sqlite3_file, c_int, ?*c_int) callconv(.c) c_int,
    xDelete: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, c_int) callconv(.c) c_int,
    xAccess: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    xFullPathname: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, c_int, [*]u8) callconv(.c) c_int,
    xDlOpen: ?*const fn (*sqlite3_vfs, ?[*:0]const u8) callconv(.c) ?*anyopaque,
    xDlError: ?*const fn (*sqlite3_vfs, c_int, [*]u8) callconv(.c) void,
    xDlSym: ?*const fn (*sqlite3_vfs, ?*anyopaque, ?[*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void,
    xDlClose: ?*const fn (*sqlite3_vfs, ?*anyopaque) callconv(.c) void,
    xRandomness: ?*const fn (*sqlite3_vfs, c_int, [*]u8) callconv(.c) c_int,
    xSleep: ?*const fn (*sqlite3_vfs, c_int) callconv(.c) c_int,
    xCurrentTime: ?*const fn (*sqlite3_vfs, *f64) callconv(.c) c_int,
    xGetLastError: ?*const fn (*sqlite3_vfs, c_int, ?[*]u8) callconv(.c) c_int,
    // iVersion 2
    xCurrentTimeInt64: ?*const fn (*sqlite3_vfs, *i64) callconv(.c) c_int = null,
    // iVersion 3
    xSetSystemCall: ?*const fn (*sqlite3_vfs, ?[*:0]const u8, ?*const anyopaque) callconv(.c) c_int = null,
    xGetSystemCall: ?*const fn (*sqlite3_vfs, ?[*:0]const u8) callconv(.c) ?*const anyopaque = null,
    xNextSystemCall: ?*const fn (*sqlite3_vfs, ?[*:0]const u8) callconv(.c) ?[*:0]const u8 = null,
};

// SQLITE_OPEN_* bits of xOpen.
const OPEN_READONLY = 0x1;
const OPEN_READWRITE = 0x2;
const OPEN_CREATE = 0x4;
const OPEN_DELETEONCLOSE = 0x8;
const OPEN_EXCLUSIVE = 0x10;
const OPEN_MAIN_DB = 0x100;
const OPEN_TEMP_DB = 0x200;
const OPEN_TRANSIENT_DB = 0x400;
const OPEN_MAIN_JOURNAL = 0x800;
const OPEN_TEMP_JOURNAL = 0x1000;
const OPEN_SUBJOURNAL = 0x2000;
const OPEN_SUPER_JOURNAL = 0x4000;
const OPEN_WAL = 0x80000;
const OPEN_MEMORY = 0x80;

const kind_bits = [_]struct { c.vfs.FileKind, c_int }{
    .{ .main_db, OPEN_MAIN_DB },
    .{ .temp_db, OPEN_TEMP_DB },
    .{ .transient_db, OPEN_TRANSIENT_DB },
    .{ .main_journal, OPEN_MAIN_JOURNAL },
    .{ .temp_journal, OPEN_TEMP_JOURNAL },
    .{ .subjournal, OPEN_SUBJOURNAL },
    .{ .super_journal, OPEN_SUPER_JOURNAL },
    .{ .wal, OPEN_WAL },
};

fn toCFlags(f: c.vfs.OpenFlags) c_int {
    var b: c_int = if (f.read_write) OPEN_READWRITE else OPEN_READONLY;
    if (f.create) b |= OPEN_CREATE;
    if (f.exclusive) b |= OPEN_EXCLUSIVE;
    if (f.delete_on_close) b |= OPEN_DELETEONCLOSE;
    for (kind_bits) |k| if (k[0] == f.kind) {
        b |= k[1];
    };
    return b;
}

fn fromCFlags(b: c_int) c.vfs.OpenFlags {
    var f: c.vfs.OpenFlags = .{
        .read_write = b & OPEN_READWRITE != 0,
        .create = b & OPEN_CREATE != 0,
        .exclusive = b & OPEN_EXCLUSIVE != 0,
        .delete_on_close = b & OPEN_DELETEONCLOSE != 0,
    };
    for (kind_bits) |k| if (b & k[1] != 0) {
        f.kind = k[0];
    };
    if (!f.read_write) {
        f.create = false;
        f.exclusive = false;
    }
    if (!f.create) f.exclusive = false;
    return f;
}

const IOERR_NOMEM = RC.IOERR | (12 << 8);
const IOERR_DELETE_NOENT = RC.IOERR | (23 << 8);

/// The result code of a VFS error.
pub fn errCode(err: Error) c_int {
    return c.int.errorCode(err);
}

/// The VFS error of a result code from a C method.
fn codeErr(rc: c_int) Error {
    return switch (rc) {
        RC.IOERR_SHORT_READ => error.ShortRead,
        RC.IOERR_LOCK, RC.IOERR | (8 << 8), RC.IOERR | (9 << 8) => error.LockErr,
        RC.IOERR_SHMOPEN => error.ShmOpen,
        RC.IOERR_SHMSIZE => error.ShmSize,
        RC.IOERR_SHMMAP => error.ShmMap,
        RC.IOERR_SHMLOCK => error.ShmLock,
        IOERR_NOMEM => error.OutOfMemory,
        else => switch (rc & 0xff) {
            RC.BUSY, RC.LOCKED => error.Busy,
            RC.CANTOPEN => error.CantOpen,
            RC.FULL => error.DiskFull,
            RC.READONLY => error.ReadOnly,
            RC.NOMEM => error.OutOfMemory,
            else => error.IoErr,
        },
    };
}

fn check(rc: c_int) Error!void {
    if (rc != RC.OK) return codeErr(rc);
}

// ============================================================= registry

/// A registered VFS: the sqlite3_vfs C sees, and the engine Vfs that
/// connections open files with. Entries are never freed (a connection
/// keeps the one it opened with), as SQLite never frees a sqlite3_vfs.
pub const Entry = struct {
    cvfs: *sqlite3_vfs,
    engine: Vfs,
    next: ?*Entry = null,
    registered: bool = true,
};

var unix_vfs: c.OsVfs = undefined;
var unix_c: sqlite3_vfs = undefined;
var unix_entry: Entry = undefined;
var memdb_c: sqlite3_vfs = undefined;
var memdb_entry: Entry = undefined;
/// The first VFS of the list is the default.
var head: ?*Entry = null;

/// Set up the default VFS (from sqlite3_initialize(), under its lock).
pub fn initDefault() void {
    unix_vfs = c.OsVfs.init(c.gpa, c.io());
    unix_c = .{
        .iVersion = 3,
        .szOsFile = @sizeOf(ZigFile),
        .mxPathname = 1024,
        .pNext = null,
        .zName = if (@import("builtin").os.tag == .wasi) "wasi" else "unix",
        .pAppData = null,
        .xOpen = zOpen,
        .xDelete = zDelete,
        .xAccess = zAccess,
        .xFullPathname = zFullPathname,
        .xDlOpen = zDlOpen,
        .xDlError = zDlError,
        .xDlSym = zDlSym,
        .xDlClose = zDlClose,
        .xRandomness = zRandomness,
        .xSleep = zSleep,
        .xCurrentTime = zCurrentTime,
        .xGetLastError = zGetLastError,
        .xCurrentTimeInt64 = zCurrentTimeInt64,
        .xSetSystemCall = zSetSystemCall,
        .xGetSystemCall = zGetSystemCall,
        .xNextSystemCall = zNextSystemCall,
    };
    unix_entry = .{ .cvfs = &unix_c, .engine = unix_vfs.interface() };
    head = &unix_entry;

    // sqlite3MemdbInit(): memdb, borrowing the rest from the default.
    memdb.state.lower = unix_vfs.interface();
    memdb_c = .{
        .iVersion = 2,
        .szOsFile = @sizeOf(ZigFile),
        .mxPathname = 1024,
        .pNext = null,
        .zName = "memdb",
        .pAppData = &unix_c,
        .xOpen = mOpen,
        .xDelete = null,
        .xAccess = mAccess,
        .xFullPathname = mFullPathname,
        .xDlOpen = unix_c.xDlOpen,
        .xDlError = unix_c.xDlError,
        .xDlSym = unix_c.xDlSym,
        .xDlClose = unix_c.xDlClose,
        .xRandomness = zRandomness,
        .xSleep = zSleep,
        .xCurrentTime = null,
        .xGetLastError = zGetLastError,
        .xCurrentTimeInt64 = zCurrentTimeInt64,
    };
    memdb_entry = .{ .cvfs = &memdb_c, .engine = memdb.interface() };
    unix_entry.next = &memdb_entry;
    relink();
    @import("../sql/global.zig").find_vfs = findEngine;
}

/// The sqlite3_vfs of the engine VFS `v` (a database's pager has the
/// engine VFS it was opened with), registered or not; null if C never
/// saw it.
pub fn cVfsOf(v: Vfs) ?*sqlite3_vfs {
    c.state.lock.lock();
    defer c.state.lock.unlock();
    if (v.vtable == unix_entry.engine.vtable and v.ptr == unix_entry.engine.ptr) return &unix_c;
    if (memdb.isMemdb(v)) return &memdb_c;
    var all = all_entries;
    while (all) |x| : (all = x.all_next) {
        if (x.entry.engine.vtable == v.vtable and x.entry.engine.ptr == v.ptr) return x.entry.cvfs;
    }
    return null;
}

/// global.find_vfs: the engine VFS of a registered VFS.
fn findEngine(name: []const u8) ?Vfs {
    const e = find(name) orelse return null;
    return e.engine;
}

/// The default VFS (for files the engine opens without a connection).
pub fn defaultEngine() Vfs {
    return unix_vfs.interface();
}

fn relink() void {
    var e = head;
    while (e) |x| : (e = x.next) x.cvfs.pNext = if (x.next) |n| n.cvfs else null;
}

/// The VFS named `name` (the default if null), or null.
pub fn find(name: ?[]const u8) ?*Entry {
    c.ensureInit();
    c.state.lock.lock();
    defer c.state.lock.unlock();
    var e = head;
    while (e) |x| : (e = x.next) {
        const n = name orelse return x;
        if (std.mem.eql(u8, std.mem.span(x.cvfs.zName orelse continue), n)) return x;
    }
    return null;
}

pub export fn sqlite3_vfs_find(z_name: ?[*:0]const u8) callconv(.c) ?*sqlite3_vfs {
    const e = find(c.span(z_name)) orelse return null;
    return e.cvfs;
}

pub export fn sqlite3_vfs_register(p: ?*sqlite3_vfs, make_dflt: c_int) callconv(.c) c_int {
    const v = p orelse return RC.MISUSE;
    c.ensureInit();
    c.state.lock.lock();
    defer c.state.lock.unlock();
    // An entry already made for this sqlite3_vfs is reused.
    var found: ?*Entry = null;
    var all = all_entries;
    while (all) |x| : (all = x.all_next) {
        if (x.entry.cvfs == v) found = &x.entry;
    }
    if (v == &unix_c) found = &unix_entry;
    if (v == &memdb_c) found = &memdb_entry;
    const e = found orelse blk: {
        const a = c.gpa.create(CVfsEntry) catch return RC.NOMEM;
        a.* = .{ .entry = .{ .cvfs = v, .engine = .{ .ptr = undefined, .vtable = &c_vfs_vtable } }, .all_next = all_entries };
        a.entry.engine.ptr = v;
        all_entries = a;
        break :blk &a.entry;
    };
    unlinkLocked(e);
    if (make_dflt != 0 or head == null) {
        e.next = head;
        head = e;
    } else {
        e.next = head.?.next;
        head.?.next = e;
    }
    e.registered = true;
    relink();
    return RC.OK;
}

pub export fn sqlite3_vfs_unregister(p: ?*sqlite3_vfs) callconv(.c) c_int {
    const v = p orelse return RC.MISUSE;
    c.ensureInit();
    c.state.lock.lock();
    defer c.state.lock.unlock();
    var e = head;
    while (e) |x| : (e = x.next) {
        if (x.cvfs == v) {
            unlinkLocked(x);
            x.registered = false;
            relink();
            v.pNext = null;
            break;
        }
    }
    return RC.OK;
}

fn unlinkLocked(e: *Entry) void {
    if (head == e) {
        head = e.next;
    } else {
        var p = head;
        while (p) |x| : (p = x.next) {
            if (x.next == e) {
                x.next = e.next;
                break;
            }
        }
    }
    e.next = null;
}

/// The entries made for C VFSes, registered or not.
const CVfsEntry = struct { entry: Entry, all_next: ?*CVfsEntry };
var all_entries: ?*CVfsEntry = null;

// ================================================ the default VFS for C

/// The sqlite3_file of a file of the default VFS.
const ZigFile = extern struct {
    base: sqlite3_file,
    ptr: *anyopaque,
    vtable: *const anyopaque,

    fn of(p: *sqlite3_file) *ZigFile {
        return @fieldParentPtr("base", p);
    }

    fn file(z: *ZigFile) File {
        return .{ .ptr = z.ptr, .vtable = @ptrCast(@alignCast(z.vtable)) };
    }
};

fn zOpen(_: *sqlite3_vfs, z_name: ?[*:0]const u8, p: *sqlite3_file, flags: c_int, out_flags: ?*c_int) callconv(.c) c_int {
    p.pMethods = null;
    const f = unix_vfs.interface().open(c.span(z_name), fromCFlags(flags)) catch |err| return errCode(err);
    const z = ZigFile.of(p);
    z.ptr = f.ptr;
    z.vtable = f.vtable;
    p.pMethods = if (f.hasShm()) &zig_methods_shm else &zig_methods;
    if (out_flags) |o| {
        var b = flags;
        if (f.isReadOnly()) b = (b & ~@as(c_int, OPEN_READWRITE | OPEN_CREATE)) | OPEN_READONLY;
        o.* = b;
    }
    return RC.OK;
}

fn zDelete(_: *sqlite3_vfs, z_name: ?[*:0]const u8, sync_dir: c_int) callconv(.c) c_int {
    unix_vfs.interface().delete(c.span(z_name) orelse return RC.MISUSE, sync_dir != 0) catch |err| return errCode(err);
    return RC.OK;
}

fn zAccess(_: *sqlite3_vfs, z_name: ?[*:0]const u8, flags: c_int, out: *c_int) callconv(.c) c_int {
    const mode: c.vfs.AccessMode = switch (flags) {
        1 => .read_write,
        2 => .read,
        else => .exists,
    };
    const ok = unix_vfs.interface().access(c.span(z_name) orelse "", mode) catch |err| return errCode(err);
    out.* = @intFromBool(ok);
    return RC.OK;
}

fn zFullPathname(_: *sqlite3_vfs, z_name: ?[*:0]const u8, n_out: c_int, z_out: [*]u8) callconv(.c) c_int {
    if (n_out <= 0) return RC.CANTOPEN;
    const out = z_out[0..@intCast(n_out)];
    const name = c.span(z_name) orelse "";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const vt = unix_vfs.interface();
    const full = if (vt.vtable.fullPathname) |fp| fp(vt.ptr, name, &buf) catch |err| return errCode(err) else name;
    if (full.len + 1 > out.len) return RC.CANTOPEN;
    @memcpy(out[0..full.len], full);
    out[full.len] = 0;
    return RC.OK;
}

fn zDlOpen(_: *sqlite3_vfs, _: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}

fn zDlError(_: *sqlite3_vfs, n: c_int, z: [*]u8) callconv(.c) void {
    const msg = "loadable extensions are not supported by xqlite";
    if (n <= 0) return;
    const k = @min(msg.len, @as(usize, @intCast(n - 1)));
    @memcpy(z[0..k], msg[0..k]);
    z[k] = 0;
}

fn zDlSym(_: *sqlite3_vfs, _: ?*anyopaque, _: ?[*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return null;
}

fn zDlClose(_: *sqlite3_vfs, _: ?*anyopaque) callconv(.c) void {}

fn zRandomness(_: *sqlite3_vfs, n: c_int, z: [*]u8) callconv(.c) c_int {
    if (n <= 0) return 0;
    unix_vfs.interface().randomness(z[0..@intCast(n)]);
    return n;
}

fn zSleep(_: *sqlite3_vfs, us: c_int) callconv(.c) c_int {
    return @intCast(unix_vfs.interface().sleep(@intCast(@max(us, 0))));
}

fn zCurrentTime(_: *sqlite3_vfs, out: *f64) callconv(.c) c_int {
    out.* = @as(f64, @floatFromInt(c.api.osCurrentTimeInt64())) / 86400000.0;
    return RC.OK;
}

fn zCurrentTimeInt64(_: *sqlite3_vfs, out: *i64) callconv(.c) c_int {
    out.* = c.api.osCurrentTimeInt64();
    return RC.OK;
}

fn zGetLastError(_: *sqlite3_vfs, _: c_int, _: ?[*]u8) callconv(.c) c_int {
    return 0;
}

fn zSetSystemCall(_: *sqlite3_vfs, _: ?[*:0]const u8, _: ?*const anyopaque) callconv(.c) c_int {
    return RC.NOTFOUND;
}

fn zGetSystemCall(_: *sqlite3_vfs, _: ?[*:0]const u8) callconv(.c) ?*const anyopaque {
    return null;
}

fn zNextSystemCall(_: *sqlite3_vfs, _: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return null;
}

/// Port of memdbOpen() for C: an engine memdb file behind a ZigFile.
fn mOpen(_: *sqlite3_vfs, z_name: ?[*:0]const u8, p: *sqlite3_file, flags: c_int, out_flags: ?*c_int) callconv(.c) c_int {
    p.pMethods = null;
    const f = memdb.interface().open(c.span(z_name), fromCFlags(flags)) catch |err| return errCode(err);
    const z = ZigFile.of(p);
    z.ptr = f.ptr;
    z.vtable = f.vtable;
    p.pMethods = &zig_methods;
    if (out_flags) |o| o.* = flags | OPEN_MEMORY;
    return RC.OK;
}

/// Port of memdbAccess(): no file ever exists.
fn mAccess(_: *sqlite3_vfs, _: ?[*:0]const u8, _: c_int, out: *c_int) callconv(.c) c_int {
    out.* = 0;
    return RC.OK;
}

/// Port of memdbFullPathname(): the name as it is.
fn mFullPathname(_: *sqlite3_vfs, z_name: ?[*:0]const u8, n_out: c_int, z_out: [*]u8) callconv(.c) c_int {
    if (n_out <= 0) return RC.OK;
    const name = c.span(z_name) orelse "";
    const k = @min(name.len, @as(usize, @intCast(n_out - 1)));
    @memcpy(z_out[0..k], name[0..k]);
    z_out[k] = 0;
    return RC.OK;
}

const zig_methods: IoMethods = .{
    .iVersion = 1,
    .xClose = zfClose,
    .xRead = zfRead,
    .xWrite = zfWrite,
    .xTruncate = zfTruncate,
    .xSync = zfSync,
    .xFileSize = zfFileSize,
    .xLock = zfLock,
    .xUnlock = zfUnlock,
    .xCheckReservedLock = zfCheckReservedLock,
    .xFileControl = zfFileControl,
    .xSectorSize = zfSectorSize,
    .xDeviceCharacteristics = zfDeviceCharacteristics,
};

const zig_methods_shm: IoMethods = blk: {
    var m = zig_methods;
    m.iVersion = 3;
    m.xShmMap = zfShmMap;
    m.xShmLock = zfShmLock;
    m.xShmBarrier = zfShmBarrier;
    m.xShmUnmap = zfShmUnmap;
    m.xFetch = zfFetch;
    m.xUnfetch = zfUnfetch;
    break :blk m;
};

fn zf(p: *sqlite3_file) File {
    return ZigFile.of(p).file();
}

fn zfClose(p: *sqlite3_file) callconv(.c) c_int {
    if (p.pMethods == null) return RC.OK;
    zf(p).close();
    p.pMethods = null;
    return RC.OK;
}

fn zfRead(p: *sqlite3_file, buf: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    const b: [*]u8 = @ptrCast(buf orelse return RC.MISUSE);
    zf(p).read(b[0..@intCast(n)], @intCast(off)) catch |err| return errCode(err);
    return RC.OK;
}

fn zfWrite(p: *sqlite3_file, buf: ?*const anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    const b: [*]const u8 = @ptrCast(buf orelse return RC.MISUSE);
    zf(p).write(b[0..@intCast(n)], @intCast(off)) catch |err| return errCode(err);
    return RC.OK;
}

fn zfTruncate(p: *sqlite3_file, size: i64) callconv(.c) c_int {
    zf(p).truncate(@intCast(size)) catch |err| return errCode(err);
    return RC.OK;
}

fn zfSync(p: *sqlite3_file, flags: c_int) callconv(.c) c_int {
    zf(p).sync(.{ .full = flags & 0x0f == 3, .data_only = flags & 0x10 != 0 }) catch |err| return errCode(err);
    return RC.OK;
}

fn zfFileSize(p: *sqlite3_file, out: *i64) callconv(.c) c_int {
    out.* = @intCast(zf(p).fileSize() catch |err| return errCode(err));
    return RC.OK;
}

fn lockLevel(l: c_int) c.vfs.LockLevel {
    return switch (l) {
        0 => .none,
        1 => .shared,
        2 => .reserved,
        3 => .pending,
        else => .exclusive,
    };
}

fn zfLock(p: *sqlite3_file, l: c_int) callconv(.c) c_int {
    const level = lockLevel(l);
    if (level == .none) return RC.OK;
    zf(p).lock(if (level == .pending) .exclusive else level) catch |err| return errCode(err);
    return RC.OK;
}

fn zfUnlock(p: *sqlite3_file, l: c_int) callconv(.c) c_int {
    zf(p).unlock(if (l <= 0) .none else .shared) catch |err| return errCode(err);
    return RC.OK;
}

fn zfCheckReservedLock(p: *sqlite3_file, out: *c_int) callconv(.c) c_int {
    out.* = @intFromBool(zf(p).checkReservedLock() catch |err| return errCode(err));
    return RC.OK;
}

fn zfFileControl(p: *sqlite3_file, op: c_int, arg: ?*anyopaque) callconv(.c) c_int {
    return fileControl(zf(p), op, arg);
}

// SQLITE_FCNTL_* answered for the engine's files.
pub const FCNTL_VFSNAME = 12;
pub const FCNTL_SIZE_LIMIT = 36;

/// The file controls of the engine's files: those of memdb
/// (memdbFileControl()); the other files have none.
pub fn fileControl(f: File, op: c_int, arg: ?*anyopaque) c_int {
    const m = memdb.fileOf(f) orelse return RC.NOTFOUND;
    switch (op) {
        FCNTL_VFSNAME => {
            const d = memdb.describe(m);
            const out: *?[*:0]u8 = @ptrCast(@alignCast(arg orelse return RC.MISUSE));
            const z = std.fmt.allocPrintSentinel(c.gpa, "memdb(0x{x},{d})", .{ d.data, d.sz }, 0) catch return RC.NOMEM;
            out.* = z.ptr;
            return RC.OK;
        },
        FCNTL_SIZE_LIMIT => {
            const lim: *i64 = @ptrCast(@alignCast(arg orelse return RC.MISUSE));
            lim.* = memdb.sizeLimit(m, lim.*);
            return RC.OK;
        },
        else => return RC.NOTFOUND,
    }
}

/// The sqlite3_file of an engine file opened through a C VFS, or null.
pub fn cFileOf(f: File) ?*sqlite3_file {
    if (f.vtable != &c_file_vtable and f.vtable != &c_file_vtable_shm) return null;
    return cf(f.ptr).cfile();
}

fn zfSectorSize(p: *sqlite3_file) callconv(.c) c_int {
    return @intCast(zf(p).sectorSize());
}

fn zfDeviceCharacteristics(p: *sqlite3_file) callconv(.c) c_int {
    return @bitCast(zf(p).deviceCharacteristics());
}

fn zfShmMap(p: *sqlite3_file, region: c_int, size: c_int, extend: c_int, out: *?*anyopaque) callconv(.c) c_int {
    out.* = null;
    const r = zf(p).shmMap(@intCast(region), @intCast(size), extend != 0) catch |err| return errCode(err);
    out.* = @ptrCast(r.ptr);
    if (r.cant_init) return RC.READONLY_CANTINIT;
    if (r.read_only) return RC.READONLY;
    return RC.OK;
}

fn zfShmLock(p: *sqlite3_file, ofst: c_int, n: c_int, flags: c_int) callconv(.c) c_int {
    zf(p).shmLock(@intCast(ofst), @intCast(n), .{ .unlock = flags & 1 != 0, .exclusive = flags & 8 != 0 }) catch |err| return errCode(err);
    return RC.OK;
}

fn zfShmBarrier(p: *sqlite3_file) callconv(.c) void {
    zf(p).shmBarrier();
}

fn zfShmUnmap(p: *sqlite3_file, delete: c_int) callconv(.c) c_int {
    zf(p).shmUnmap(delete != 0);
    return RC.OK;
}

fn zfFetch(_: *sqlite3_file, _: i64, _: c_int, out: *?*anyopaque) callconv(.c) c_int {
    out.* = null;
    return RC.OK;
}

fn zfUnfetch(_: *sqlite3_file, _: i64, _: ?*anyopaque) callconv(.c) c_int {
    return RC.OK;
}

// ======================================== a C VFS as an engine Vfs

const c_vfs_vtable: Vfs.VTable = .{
    .open = cOpen,
    .delete = cDelete,
    .access = cAccess,
    .randomness = cRandomness,
    .sleep = cSleep,
    .fullPathname = cFullPathname,
};

fn cvfsOf(ptr: *anyopaque) *sqlite3_vfs {
    return @ptrCast(@alignCast(ptr));
}

/// An open file of a C VFS: the sqlite3_file the C xOpen filled (its
/// szOsFile bytes follow this header) and the name it was given, which
/// must live as long as the file: the pager's own (in SQLite's layout),
/// or a copy made in that layout.
const CFile = struct {
    name: ?[]u8,
    read_only: bool,
    file: []align(16) u8,

    fn cfile(f: *CFile) *sqlite3_file {
        return @ptrCast(f.file.ptr);
    }

    fn methods(f: *CFile) *const IoMethods {
        return f.cfile().pMethods.?;
    }
};

/// A name the pager did not lay out, in SQLite's filename layout: the
/// slot of sqlite3_database_file_object() and four zero bytes before it,
/// and after it an empty list of URI parameters, so that
/// sqlite3_uri_parameter() and sqlite3_filename_*() work on it.
const name_prefix = @sizeOf(usize) + 4;

fn makeName(path: []const u8) ?[]u8 {
    const b = c.gpa.alloc(u8, name_prefix + path.len + 4) catch return null;
    @memset(b, 0);
    @memcpy(b[name_prefix..][0..path.len], path);
    return b;
}

fn cOpen(ptr: *anyopaque, path: ?[]const u8, flags: c.vfs.OpenFlags) Error!File {
    const v = cvfsOf(ptr);
    const open_fn = v.xOpen orelse return error.CantOpen;
    const f = try c.gpa.create(CFile);
    errdefer c.gpa.destroy(f);
    f.name = if (path != null and !flags.sqlite_filename) makeName(path.?) orelse return error.OutOfMemory else null;
    errdefer if (f.name) |n| c.gpa.free(n);
    f.file = try c.gpa.alignedAlloc(u8, .@"16", @intCast(@max(v.szOsFile, @sizeOf(sqlite3_file))));
    errdefer c.gpa.free(f.file);
    @memset(f.file, 0);
    var out_flags: c_int = 0;
    const cflags = toCFlags(flags);
    const z: ?[*:0]const u8 = if (f.name) |n| @ptrCast(n[name_prefix..].ptr) else if (path) |p| @ptrCast(p.ptr) else null;
    const rc = open_fn(v, z, f.cfile(), cflags, &out_flags);
    if (rc != RC.OK) {
        if (f.cfile().pMethods) |m| if (m.xClose) |close| {
            _ = close(f.cfile());
        };
        return codeErr(rc);
    }
    if (f.cfile().pMethods == null) return error.CantOpen;
    f.read_only = out_flags & OPEN_READONLY != 0 or !flags.read_write;
    // sqlite3_database_file_object() finds the database's sqlite3_file in
    // the slot before its name (C keeps the Pager* there).
    if (flags.kind == .main_db and z != null) {
        const slot: *align(1) usize = @ptrCast(@constCast(z.? - name_prefix));
        slot.* = @intFromPtr(f.cfile());
    }
    const shm = f.methods().iVersion >= 2 and f.methods().xShmMap != null;
    return .{ .ptr = f, .vtable = if (shm) &c_file_vtable_shm else &c_file_vtable };
}

fn withZ(path: []const u8, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.CantOpen;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @call(.auto, f, .{@as([*:0]const u8, @ptrCast(&buf))} ++ args);
}

fn cDelete(ptr: *anyopaque, path: []const u8, sync_dir: bool) Error!void {
    const v = cvfsOf(ptr);
    const S = struct {
        fn f(z: [*:0]const u8, vv: *sqlite3_vfs, s: bool) Error!void {
            const rc = (vv.xDelete orelse return error.IoErr)(vv, z, @intFromBool(s));
            if (rc == IOERR_DELETE_NOENT) return;
            try check(rc);
        }
    };
    return withZ(path, S.f, .{ v, sync_dir });
}

fn cAccess(ptr: *anyopaque, path: []const u8, mode: c.vfs.AccessMode) Error!bool {
    const v = cvfsOf(ptr);
    const S = struct {
        fn f(z: [*:0]const u8, vv: *sqlite3_vfs, m: c.vfs.AccessMode) Error!bool {
            var out: c_int = 0;
            const flags: c_int = switch (m) {
                .exists => 0,
                .read_write => 1,
                .read => 2,
            };
            try check((vv.xAccess orelse return false)(vv, z, flags, &out));
            return out != 0;
        }
    };
    return withZ(path, S.f, .{ v, mode });
}

fn cRandomness(ptr: *anyopaque, buf: []u8) void {
    const v = cvfsOf(ptr);
    if (v.xRandomness) |f| {
        _ = f(v, @intCast(@min(buf.len, std.math.maxInt(c_int))), buf.ptr);
    } else @memset(buf, 0);
}

fn cSleep(ptr: *anyopaque, us: u32) u32 {
    const v = cvfsOf(ptr);
    const f = v.xSleep orelse return 0;
    return @intCast(@max(f(v, @intCast(@min(us, std.math.maxInt(c_int)))), 0));
}

fn cFullPathname(ptr: *anyopaque, path: []const u8, out: []u8) Error![]u8 {
    const v = cvfsOf(ptr);
    const S = struct {
        fn f(z: [*:0]const u8, vv: *sqlite3_vfs, o: []u8) Error![]u8 {
            const fp = vv.xFullPathname orelse return o[0..0];
            const n: c_int = @intCast(@min(o.len, @as(usize, @intCast(@max(vv.mxPathname, 1))) + 1));
            try check(fp(vv, z, n, o.ptr));
            return std.mem.sliceTo(o[0..@intCast(n)], 0);
        }
    };
    const r = try withZ(path, S.f, .{ v, out });
    if (r.len == 0) {
        if (path.len > out.len) return error.CantOpen;
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    return r;
}

const c_file_vtable: File.VTable = .{
    .close = cfClose,
    .read = cfRead,
    .write = cfWrite,
    .truncate = cfTruncate,
    .sync = cfSync,
    .fileSize = cfFileSize,
    .lock = cfLock,
    .unlock = cfUnlock,
    .checkReservedLock = cfCheckReservedLock,
    .sectorSize = cfSectorSize,
    .deviceCharacteristics = cfDeviceCharacteristics,
    .isReadOnly = cfIsReadOnly,
};

const c_file_vtable_shm: File.VTable = blk: {
    var t = c_file_vtable;
    t.shmMap = cfShmMap;
    t.shmLock = cfShmLock;
    t.shmBarrier = cfShmBarrier;
    t.shmUnmap = cfShmUnmap;
    break :blk t;
};

fn cf(ptr: *anyopaque) *CFile {
    return @ptrCast(@alignCast(ptr));
}

fn cfClose(ptr: *anyopaque) void {
    const f = cf(ptr);
    if (f.methods().xClose) |close| _ = close(f.cfile());
    if (f.name) |n| c.gpa.free(n);
    c.gpa.free(f.file);
    c.gpa.destroy(f);
}

fn cfRead(ptr: *anyopaque, buf: []u8, offset: u64) Error!usize {
    const f = cf(ptr);
    const rc = f.methods().xRead.?(f.cfile(), buf.ptr, @intCast(buf.len), @intCast(offset));
    if (rc == RC.IOERR_SHORT_READ) {
        // The C method zero-filled what it could not read but does not
        // say how much that was: count the trailing zeros as unread.
        var n = buf.len;
        while (n > 0 and buf[n - 1] == 0) n -= 1;
        return n;
    }
    try check(rc);
    return buf.len;
}

fn cfWrite(ptr: *anyopaque, buf: []const u8, offset: u64) Error!void {
    const f = cf(ptr);
    try check(f.methods().xWrite.?(f.cfile(), buf.ptr, @intCast(buf.len), @intCast(offset)));
}

fn cfTruncate(ptr: *anyopaque, size: u64) Error!void {
    const f = cf(ptr);
    try check(f.methods().xTruncate.?(f.cfile(), @intCast(size)));
}

fn cfSync(ptr: *anyopaque, flags: c.vfs.SyncFlags) Error!void {
    const f = cf(ptr);
    var b: c_int = if (flags.full) 3 else 2;
    if (flags.data_only) b |= 0x10;
    try check(f.methods().xSync.?(f.cfile(), b));
}

fn cfFileSize(ptr: *anyopaque) Error!u64 {
    const f = cf(ptr);
    var n: i64 = 0;
    try check(f.methods().xFileSize.?(f.cfile(), &n));
    return @intCast(@max(n, 0));
}

fn cfLock(ptr: *anyopaque, level: c.vfs.LockLevel) Error!void {
    const f = cf(ptr);
    try check(f.methods().xLock.?(f.cfile(), @backingInt(level)));
}

fn cfUnlock(ptr: *anyopaque, level: c.vfs.LockLevel) Error!void {
    const f = cf(ptr);
    try check(f.methods().xUnlock.?(f.cfile(), @backingInt(level)));
}

fn cfCheckReservedLock(ptr: *anyopaque) Error!bool {
    const f = cf(ptr);
    var out: c_int = 0;
    try check(f.methods().xCheckReservedLock.?(f.cfile(), &out));
    return out != 0;
}

fn cfSectorSize(ptr: *anyopaque) u32 {
    const f = cf(ptr);
    const s = if (f.methods().xSectorSize) |g| g(f.cfile()) else 0;
    return if (s > 0) @intCast(s) else c.vfs.default_sector_size;
}

fn cfDeviceCharacteristics(ptr: *anyopaque) c.vfs.DeviceCharacteristics {
    const f = cf(ptr);
    const d = if (f.methods().xDeviceCharacteristics) |g| g(f.cfile()) else 0;
    return @bitCast(@as(u32, @bitCast(d)) & 0xffff);
}

fn cfIsReadOnly(ptr: *anyopaque) bool {
    return cf(ptr).read_only;
}

fn cfShmMap(ptr: *anyopaque, region: u32, size: u32, extend: bool) Error!c.vfs.ShmRegion {
    const f = cf(ptr);
    var out: ?*anyopaque = null;
    const rc = f.methods().xShmMap.?(f.cfile(), @intCast(region), @intCast(size), @intFromBool(extend), &out);
    if (rc == RC.READONLY_CANTINIT) return .{ .ptr = null, .read_only = true, .cant_init = true };
    if (rc == RC.READONLY) return .{ .ptr = @ptrCast(@alignCast(out)), .read_only = true };
    try check(rc);
    return .{ .ptr = @ptrCast(@alignCast(out)) };
}

fn cfShmLock(ptr: *anyopaque, ofst: u32, n: u32, flags: c.vfs.ShmLockFlags) Error!void {
    const f = cf(ptr);
    var b: c_int = if (flags.unlock) 1 else 2;
    b |= if (flags.exclusive) 8 else 4;
    try check(f.methods().xShmLock.?(f.cfile(), @intCast(ofst), @intCast(n), b));
}

fn cfShmBarrier(ptr: *anyopaque) void {
    const f = cf(ptr);
    if (f.methods().xShmBarrier) |b| b(f.cfile());
}

fn cfShmUnmap(ptr: *anyopaque, delete: bool) void {
    const f = cf(ptr);
    if (f.methods().xShmUnmap) |u| _ = u(f.cfile(), @intFromBool(delete));
}
