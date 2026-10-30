//! What the files of the C ABI share: the engine modules they call, the
//! C types of sqlite3.h, the state kept for each connection (Ext) and
//! the few process-wide variables of the C ABI (state).

const std = @import("std");
const builtin = @import("builtin");

pub const int = @import("../sql/sqlite_int.zig");
pub const main = @import("../sql/main.zig");
pub const malloc = @import("../sql/malloc.zig");
pub const api = @import("../vdbe/api.zig");
pub const vi = @import("../vdbe/vdbe_int.zig");
pub const mem = @import("../vdbe/mem.zig");
pub const printf = @import("../sql/printf.zig");
pub const util = @import("../sql/util.zig");
pub const ctype = @import("../util/ctype.zig");
pub const dialect = @import("../dialect/dialect.zig");
pub const vfs = @import("../vfs/vfs.zig");
/// The operating system's VFS: POSIX, or WASI on wasm32-wasi.
pub const OsVfs = vfs.OsVfs;

/// sqlite3, sqlite3_stmt, sqlite3_value and sqlite3_context are the
/// engine's own objects: C sees them as opaque pointers.
pub const Handle = int.Sqlite3;
pub const Vdbe = vi.Vdbe;
pub const Mem = vi.Mem;
pub const Context = vi.Context;
pub const RC = int.RC;

/// The library allocator (sqlite3_malloc()), for everything the C ABI
/// allocates outside a connection's own memory.
pub const gpa = malloc.allocator;

// ================================================================ C types

/// A destructor of sqlite3.h: void(*)(void*). The parameters that take
/// one are typed `?*const anyopaque`, since SQLITE_TRANSIENT is the
/// address -1, not a function.
pub const CDestructor = *const fn (?*anyopaque) callconv(.c) void;

pub const SQLITE_TRANSIENT: usize = std.math.maxInt(usize);

pub fn cDestructor(p: ?*const anyopaque) ?CDestructor {
    const x = p orelse return null;
    if (@intFromPtr(x) == SQLITE_TRANSIENT) return null;
    return @ptrCast(@alignCast(x));
}

/// What the engine makes of a destructor argument for a string or blob
/// of `len` bytes at `z`: SQLITE_STATIC and SQLITE_TRANSIENT as they
/// are, sqlite3_free() as the library's free(). Any other function is
/// not one the engine can call, so the value is copied and the function
/// called right away (after()), which SQLite also allows.
pub const Del = struct {
    engine: vi.Destructor,
    call_after: ?CDestructor = null,

    pub fn of(p: ?*const anyopaque) Del {
        const x = p orelse return .{ .engine = .static };
        if (@intFromPtr(x) == SQLITE_TRANSIENT) return .{ .engine = .transient };
        if (@intFromPtr(x) == @intFromPtr(&@import("library.zig").sqlite3_free)) return .{ .engine = .{ .func = malloc.free } };
        return .{ .engine = .transient, .call_after = @ptrCast(@alignCast(x)) };
    }

    pub fn after(d: Del, data: ?*const anyopaque) void {
        if (d.call_after) |f| f(@constCast(data));
    }
};

/// The C length convention: a negative `n` means up to the first NUL.
pub fn cSlice(z: [*]const u8, n: i64) []const u8 {
    if (n < 0) return std.mem.span(@as([*:0]const u8, @ptrCast(z)));
    return z[0..@intCast(n)];
}

/// As cSlice(), but a non-negative `n` stops at a NUL too (the SQL text
/// of sqlite3_prepare()).
pub fn cSliceZ(z: [*]const u8, n: i64) []const u8 {
    if (n < 0) return std.mem.span(@as([*:0]const u8, @ptrCast(z)));
    const s = z[0..@intCast(n)];
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

pub fn span(z: ?[*:0]const u8) ?[]const u8 {
    return if (z) |p| std.mem.span(p) else null;
}

/// A string as C returns it: a pointer to its first byte, or null.
pub fn cStr(s: ?[:0]const u8) ?[*:0]const u8 {
    return if (s) |x| x.ptr else null;
}

/// A copy of `s`, NUL-terminated, from sqlite3_malloc(); null on OOM.
pub fn dupZ(s: []const u8) ?[*:0]u8 {
    const z = gpa.dupeSentinel(u8, s, 0) catch return null;
    return z.ptr;
}

// ================================================================= UTF-16

/// UTF-16 text in native byte order (C's `const void*` of the *16
/// interfaces), or `n` bytes of it if `n` is not negative (an odd last
/// byte is dropped), stopping at a NUL character.
pub fn utf16Slice(z: *const anyopaque, n: i64) []const u16 {
    const p: [*]const u16 = @ptrCast(@alignCast(z));
    var len: usize = 0;
    if (n < 0) {
        while (p[len] != 0) len += 1;
    } else {
        const max: usize = @intCast(@divTrunc(n, 2));
        while (len < max and p[len] != 0) len += 1;
    }
    return p[0..len];
}

/// UTF-16 (little or big endian) to UTF-8, from sqlite3_malloc() and
/// NUL-terminated. Unpaired surrogates become U+FFFD, as in SQLite.
pub fn utf16ToUtf8(s: []const u16, big_endian: bool) ?[:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, s.len * 3 + 1) catch return null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var c: u21 = unit(s[i], big_endian);
        if (c >= 0xd800 and c < 0xdc00 and i + 1 < s.len) {
            const c2: u21 = unit(s[i + 1], big_endian);
            if (c2 >= 0xdc00 and c2 < 0xe000) {
                c = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
                i += 1;
            } else c = 0xfffd;
        } else if (c >= 0xd800 and c < 0xe000) c = 0xfffd;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..len]);
    }
    return out.toOwnedSliceSentinel(gpa, 0) catch null;
}

fn unit(u: u16, big_endian: bool) u21 {
    const native_big = builtin.cpu.arch.endian() == .big;
    return if (big_endian == native_big) u else @byteSwap(u);
}

/// UTF-8 to native UTF-16, NUL-terminated, from sqlite3_malloc().
/// Invalid bytes become U+FFFD.
pub fn utf8ToUtf16(s: []const u8) ?[:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, s.len + 1) catch return null;
    var i: usize = 0;
    while (i < s.len) {
        var c: u21 = 0xfffd;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |l| {
            if (i + l <= s.len) {
                if (std.unicode.utf8Decode(s[i..][0..l])) |d| {
                    c = d;
                    len = l;
                } else |_| {}
            }
        } else |_| {}
        i += len;
        if (c >= 0x10000) {
            out.append(gpa, @intCast(0xd800 + ((c - 0x10000) >> 10))) catch return null;
            out.append(gpa, @intCast(0xdc00 + ((c - 0x10000) & 0x3ff))) catch return null;
        } else {
            out.append(gpa, @intCast(c)) catch return null;
        }
    }
    return out.toOwnedSliceSentinel(gpa, 0) catch null;
}

/// How many bytes `s` takes in UTF-16 (sqlite3_value_bytes16()).
pub fn utf16Bytes(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (l == 4) 4 else 2;
        i += l;
    }
    return n;
}

// ========================================================== the C state

/// A C callback with its argument.
pub fn Hook(comptime F: type) type {
    return struct { f: ?F = null, arg: ?*anyopaque = null };
}

pub const CBusy = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
pub const CWal = *const fn (?*anyopaque, ?*Handle, ?[*:0]const u8, c_int) callconv(.c) c_int;
pub const CCommit = *const fn (?*anyopaque) callconv(.c) c_int;
pub const CRollback = *const fn (?*anyopaque) callconv(.c) void;
pub const CUpdate = *const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, i64) callconv(.c) void;
pub const CProgress = *const fn (?*anyopaque) callconv(.c) c_int;
pub const CTraceV2 = *const fn (c_uint, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
pub const CTrace = *const fn (?*anyopaque, ?[*:0]const u8) callconv(.c) void;
pub const CProfile = *const fn (?*anyopaque, ?[*:0]const u8, u64) callconv(.c) void;
pub const CAuth = *const fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
pub const CCollNeeded = *const fn (?*anyopaque, ?*Handle, c_int, ?*const anyopaque) callconv(.c) void;
pub const CAutovac = *const fn (?*anyopaque, ?[*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) c_uint;

/// SQLITE_TRACE_* bits.
pub const TRACE_STMT: u32 = 0x01;
pub const TRACE_PROFILE: u32 = 0x02;
pub const TRACE_ROW: u32 = 0x04;
pub const TRACE_CLOSE: u32 = 0x08;

/// The C ABI's part of a connection it opened (Handle.capi): what C
/// registers on it that the engine has no place for.
pub const Ext = struct {
    /// The VFS the connection opened its files with (its sqlite3_vfs).
    vfs: *@import("vfs.zig").Entry,
    busy: Hook(CBusy) = .{},
    wal: Hook(CWal) = .{},
    commit: Hook(CCommit) = .{},
    rollback: Hook(CRollback) = .{},
    update: Hook(CUpdate) = .{},
    progress: Hook(CProgress) = .{},
    n_progress_ops: c_int = 0,
    trace_mask: u32 = 0,
    trace: Hook(CTraceV2) = .{},
    /// The callbacks of the deprecated sqlite3_trace() and
    /// sqlite3_profile(), which trace_v2 hooks call.
    legacy_trace: Hook(CTrace) = .{},
    legacy_profile: Hook(CProfile) = .{},
    /// When each running statement started (SQLITE_TRACE_PROFILE).
    started: std.AutoHashMapUnmanaged(*Vdbe, i128) = .empty,
    authorizer: Hook(CAuth) = .{},
    coll_needed: Hook(CCollNeeded) = .{},
    autovac: Hook(CAutovac) = .{},
    autovac_destroy: ?CDestructor = null,
    /// The collations made by sqlite3_create_collation*().
    colls: std.ArrayList(*@import("func.zig").CollWrap) = .empty,
    clientdata: std.ArrayList(ClientData) = .empty,
    /// The buffer of sqlite3_errmsg16().
    errmsg16: ?[:0]u16 = null,
    /// sqlite3_close_v2() found the connection busy: it closes once the
    /// last statement or backup is gone (a zombie).
    zombie: bool = false,

    pub const ClientData = struct { name: [:0]u8, data: ?*anyopaque, x_destroy: ?CDestructor };
};

pub fn ext(db: *Handle) *Ext {
    return @ptrCast(@alignCast(db.capi.?));
}

pub fn extOf(db: ?*Handle) ?*Ext {
    const d = db orelse return null;
    return @ptrCast(@alignCast(d.capi orelse return null));
}

// =================================================== process-wide state

/// A lock for the registries of the C ABI (VFSes, auto extensions): they
/// change rarely and briefly, so a spin lock does.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(l: *SpinLock) void {
        while (l.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(l: *SpinLock) void {
        l.locked.store(false, .release);
    }
};

/// The process-wide state of the C ABI. As in SQLite (sqlite3GlobalConfig,
/// the VFS list, the auto extensions), these act on every connection.
pub const State = struct {
    lock: SpinLock = .{},
    initialized: bool = false,
    /// SQLITE_CONFIG_URI.
    uri: bool = false,
    /// SQLITE_CONFIG_MALLOC, and whether its xInit has run.
    mem_methods: ?@import("library.zig").MemMethods = null,
    mem_init: bool = false,
    /// SQLITE_CONFIG_LOG.
    log: Hook(*const fn (?*anyopaque, c_int, ?[*:0]const u8) callconv(.c) void) = .{},
    /// sqlite3_auto_extension().
    auto_ext: std.ArrayList(*const anyopaque) = .empty,
    /// Destructors of pointer values bound or returned by C (see
    /// func.zig): the engine's destructors take only the pointer.
    ptr_dtors: std.ArrayList(PtrDtor) = .empty,
    ptr_lock: SpinLock = .{},

    pub const PtrDtor = struct { p: ?*anyopaque, f: CDestructor };
};

pub var state: State = .{};

/// The std.Io of the default VFS: blocking calls, no event loop or
/// signal handlers installed in the host program.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// sqlite3_initialize(), which the interfaces that need it call.
pub fn ensureInit() void {
    if (@atomicLoad(bool, &state.initialized, .acquire)) return;
    state.lock.lock();
    defer state.lock.unlock();
    if (!state.initialized) {
        @import("vfs.zig").initDefault();
        @atomicStore(bool, &state.initialized, true, .release);
    }
}
