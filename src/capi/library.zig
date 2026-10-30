//! The library as a whole: versions, sqlite3_initialize() and
//! sqlite3_config(), memory, randomness, and the string utilities.

const std = @import("std");
const c = @import("common.zig");

const RC = c.RC;
const func_mod = @import("../sql/func.zig");
const complete_mod = @import("../sql/complete.zig");
const tokenize = @import("../parse/tokenize.zig");
const grammar = @import("../parse/grammar.zig");

pub const version = "3.54.1";
pub const version_number = 3054001;
/// SQLITE_SOURCE_ID of the sqlite3.h this library implements: programs
/// such as the sqlite3 shell compare it with the header they were built
/// with.
pub const source_id = "2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76";

pub export const sqlite3_version: [version.len:0]u8 = version.*;

// sqlite3_temp_directory is the VFS package's (the unix VFS creates
// temporary files there), sqlite3_data_directory the engine's
// (global.zig).
comptime {
    const global = @import("../sql/global.zig");
    @export(&@import("xqlite_vfs").temp_directory, .{ .name = "sqlite3_temp_directory" });
    @export(&global.data_directory, .{ .name = "sqlite3_data_directory" });
}

pub export fn sqlite3_libversion() callconv(.c) [*:0]const u8 {
    return version;
}

pub export fn sqlite3_sourceid() callconv(.c) [*:0]const u8 {
    return source_id;
}

pub export fn sqlite3_libversion_number() callconv(.c) c_int {
    return version_number;
}

/// SQLITE_THREADSAFE=2: the library has mutexes and connections are
/// multi-thread by default; a connection is serialized (it has a mutex
/// of its own) when sqlite3_config() or sqlite3_open_v2()'s flags ask
/// (docs/c-api.md). Single-threaded WebAssembly has none (0).
pub const threadsafe: c_int = if (c.have_threads) 2 else 0;

pub export fn sqlite3_threadsafe() callconv(.c) c_int {
    return threadsafe;
}

/// The engine's options (PRAGMA compile_options), with the threading
/// mode of the C ABI.
fn compileOption(n: c_int) ?[]const u8 {
    const o = func_mod.compileoptionGet(n) orelse return null;
    if (std.mem.startsWith(u8, o, "THREADSAFE=")) return if (c.have_threads) "THREADSAFE=2" else "THREADSAFE=0";
    return o;
}

pub export fn sqlite3_compileoption_get(n: c_int) callconv(.c) ?[*:0]const u8 {
    const o = compileOption(n) orelse return null;
    return @ptrCast(o.ptr);
}

pub export fn sqlite3_compileoption_used(z_opt: ?[*:0]const u8) callconv(.c) c_int {
    var z = c.span(z_opt) orelse return 0;
    if (z.len >= 7 and c.ctype.eqlNoCase(z[0..7], "SQLITE_")) z = z[7..];
    var i: c_int = 0;
    while (compileOption(i)) |o| : (i += 1) {
        if (o.len >= z.len and c.ctype.eqlNoCase(o[0..z.len], z) and
            (o.len == z.len or !c.ctype.isIdChar(o[z.len])))
        {
            return 1;
        }
    }
    return 0;
}

// ======================================================= init and config

pub export fn sqlite3_initialize() callconv(.c) c_int {
    c.ensureInit();
    if (c.state.mem_methods) |m| if (m.xInit) |f| {
        if (!c.state.mem_init) {
            c.state.mem_init = true;
            return f(m.pAppData);
        }
    };
    return RC.OK;
}

pub export fn sqlite3_shutdown() callconv(.c) c_int {
    // The default VFS and the registries stay; connections must all be
    // closed, as in SQLite.
    @atomicStore(bool, &c.state.initialized, false, .release);
    if (c.state.mem_methods) |m| if (m.xShutdown) |f| {
        if (c.state.mem_init) f(m.pAppData);
        c.state.mem_init = false;
    };
    return RC.OK;
}

pub export fn sqlite3_os_init() callconv(.c) c_int {
    return RC.OK;
}

pub export fn sqlite3_os_end() callconv(.c) c_int {
    return RC.OK;
}

/// sqlite3_mem_methods.
pub const MemMethods = extern struct {
    xMalloc: ?*const fn (c_int) callconv(.c) ?*anyopaque,
    xFree: ?*const fn (?*anyopaque) callconv(.c) void,
    xRealloc: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque,
    xSize: ?*const fn (?*anyopaque) callconv(.c) c_int,
    xRoundup: ?*const fn (c_int) callconv(.c) c_int,
    xInit: ?*const fn (?*anyopaque) callconv(.c) c_int,
    xShutdown: ?*const fn (?*anyopaque) callconv(.c) void,
    pAppData: ?*anyopaque,
};

/// The allocator over SQLITE_CONFIG_MALLOC's methods: the library puts
/// its size header in front of each block, so only malloc, realloc and
/// free are needed (and 8-byte alignment, which they give).
const c_mem_vtable: std.mem.Allocator.VTable = .{
    .alloc = cmAlloc,
    .resize = cmResize,
    .remap = cmRemap,
    .free = cmFree,
};

fn cmAlloc(_: *anyopaque, len: usize, a: std.mem.Alignment, _: usize) ?[*]u8 {
    if (a.toByteUnits() > 8 or len > std.math.maxInt(c_int)) return null;
    return @ptrCast(c.state.mem_methods.?.xMalloc.?(@intCast(len)));
}

fn cmResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len <= memory.len;
}

fn cmRemap(_: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (a.toByteUnits() > 8 or new_len > std.math.maxInt(c_int)) return null;
    return @ptrCast(c.state.mem_methods.?.xRealloc.?(memory.ptr, @intCast(new_len)));
}

fn cmFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    c.state.mem_methods.?.xFree.?(memory.ptr);
}

// The sqlite3_mem_methods of SQLITE_CONFIG_GETMALLOC: the library's.

fn gmMalloc(n: c_int) callconv(.c) ?*anyopaque {
    return sqlite3_malloc(n);
}

fn gmRealloc(p: ?*anyopaque, n: c_int) callconv(.c) ?*anyopaque {
    return sqlite3_realloc(p, n);
}

fn gmSize(p: ?*anyopaque) callconv(.c) c_int {
    return @intCast(sqlite3_msize(p));
}

fn gmRoundup(n: c_int) callconv(.c) c_int {
    return (n + 7) & ~@as(c_int, 7);
}

fn gmInit(_: ?*anyopaque) callconv(.c) c_int {
    return RC.OK;
}

fn gmShutdown(_: ?*anyopaque) callconv(.c) void {}

/// sqlite3_config() with its arguments taken out of the varargs by the
/// C shim (capi/varargs.c): `a` and `b` the integers, `p` and `q` the
/// pointers, as the option takes them.
pub fn xq_config(op: c_int, a: i64, b: i64, p: ?*anyopaque, q: ?*anyopaque) callconv(.c) c_int {
    // SQLITE_CONFIG_LOG and SQLITE_CONFIG_PCACHE_HDRSZ may be set at any
    // time; the others only before sqlite3_initialize().
    if (@atomicLoad(bool, &c.state.initialized, .acquire) and op != 16 and op != 24) return RC.MISUSE;
    switch (op) {
        // SINGLETHREAD, MULTITHREAD and SERIALIZED: the mode of the
        // connections opened from now on (bCoreMutex, bFullMutex).
        1 => {
            c.state.core_mutex = false;
            c.state.full_mutex = false;
            return RC.OK;
        },
        2 => {
            c.state.core_mutex = c.have_threads;
            c.state.full_mutex = false;
            return RC.OK;
        },
        3 => {
            if (!c.have_threads) return RC.ERROR;
            c.state.core_mutex = true;
            c.state.full_mutex = true;
            return RC.OK;
        },
        4 => {
            const m: *const MemMethods = @ptrCast(@alignCast(p orelse return RC.MISUSE));
            if (m.xMalloc == null or m.xFree == null or m.xRealloc == null) return RC.MISUSE;
            c.state.mem_methods = m.*;
            c.malloc.configMalloc(.{ .ptr = undefined, .vtable = &c_mem_vtable });
            return RC.OK;
        },
        5 => {
            const m: *MemMethods = @ptrCast(@alignCast(p orelse return RC.MISUSE));
            m.* = c.state.mem_methods orelse .{
                .xMalloc = gmMalloc,
                .xFree = sqlite3_free,
                .xRealloc = gmRealloc,
                .xSize = gmSize,
                .xRoundup = gmRoundup,
                .xInit = gmInit,
                .xShutdown = gmShutdown,
                .pAppData = null,
            };
            return RC.OK;
        },
        13 => {
            c.malloc.configLookaside(@intCast(a), @intCast(b));
            return RC.OK;
        },
        16 => {
            c.state.log = .{ .f = @ptrCast(@alignCast(p)), .arg = q };
            return RC.OK;
        },
        17 => {
            c.state.uri = a != 0;
            return RC.OK;
        },
        24 => {
            const out: *c_int = @ptrCast(@alignCast(p orelse return RC.MISUSE));
            out.* = 0;
            return RC.OK;
        },
        30 => {
            if (p) |x| @as(*c_int, @ptrCast(@alignCast(x))).* = 0;
            return RC.OK;
        },
        // GETMUTEX, GETPCACHE, GETPCACHE2: the engine has neither
        // pluggable mutexes nor a pluggable page cache to describe.
        11, 15, 19 => return RC.ERROR,
        // MEMSTATUS: whether sqlite3_initialize() turns on the status
        // counters (on by default, as in SQLite).
        9 => {
            c.state.memstat = a != 0;
            return RC.OK;
        },
        // MEMDB_MAXSIZE: the default largest size of a memdb database.
        29 => {
            @import("../sql/memdb.zig").state.default_max_size = a;
            return RC.OK;
        },
        // Accepted and ignored: SCRATCH, PAGECACHE, HEAP, MUTEX, PCACHE,
        // PCACHE2, COVERING_INDEX_SCAN, SQLLOG, MMAP_SIZE,
        // WIN32_HEAPSIZE, PMASZ, STMTJRNL_SPILL, SMALL_MALLOC,
        // SORTERREF_SIZE.
        6, 7, 8, 10, 14, 18, 20, 21, 22, 23, 25, 26, 27, 28 => return RC.OK,
        else => return RC.ERROR,
    }
}

// ================================================================ memory

pub export fn sqlite3_malloc(n: c_int) callconv(.c) ?*anyopaque {
    c.ensureInit();
    if (n <= 0) return null;
    return c.malloc.malloc(@intCast(n));
}

pub export fn sqlite3_malloc64(n: u64) callconv(.c) ?*anyopaque {
    c.ensureInit();
    return c.malloc.malloc(n);
}

pub export fn sqlite3_realloc(p: ?*anyopaque, n: c_int) callconv(.c) ?*anyopaque {
    c.ensureInit();
    return c.malloc.realloc(p, @intCast(@max(n, 0)));
}

pub export fn sqlite3_realloc64(p: ?*anyopaque, n: u64) callconv(.c) ?*anyopaque {
    c.ensureInit();
    return c.malloc.realloc(p, n);
}

pub export fn sqlite3_free(p: ?*anyopaque) callconv(.c) void {
    c.malloc.free(p);
}

pub export fn sqlite3_msize(p: ?*anyopaque) callconv(.c) u64 {
    return c.malloc.mallocSize(p orelse return 0);
}

// The status counters (the storage package's status.zig), on unless SQLITE_CONFIG_MEMSTATUS
// turned them off before sqlite3_initialize().

const status = @import("xqlite_storage").status;

/// Port of sqlite3_memory_used().
pub export fn sqlite3_memory_used() callconv(.c) i64 {
    var cur: i64 = 0;
    var hw: i64 = 0;
    status.status64(.memory_used, &cur, &hw, false);
    return cur;
}

/// Port of sqlite3_memory_highwater().
pub export fn sqlite3_memory_highwater(reset: c_int) callconv(.c) i64 {
    var cur: i64 = 0;
    var hw: i64 = 0;
    status.status64(.memory_used, &cur, &hw, reset != 0);
    return hw;
}

/// Port of sqlite3_status64().
pub export fn sqlite3_status64(op: c_int, p_cur: ?*i64, p_hiwtr: ?*i64, reset: c_int) callconv(.c) c_int {
    if (op < 0 or op > 9) return RC.MISUSE;
    const cur = p_cur orelse return RC.MISUSE;
    const hw = p_hiwtr orelse return RC.MISUSE;
    status.status64(@fromBackingInt(@intCast(op)), cur, hw, reset != 0);
    return RC.OK;
}

/// Port of sqlite3_status().
pub export fn sqlite3_status(op: c_int, p_cur: ?*c_int, p_hiwtr: ?*c_int, reset: c_int) callconv(.c) c_int {
    var cur: i64 = 0;
    var hw: i64 = 0;
    const rc = sqlite3_status64(op, &cur, &hw, reset);
    if (rc == RC.OK) {
        (p_cur orelse return RC.MISUSE).* = @truncate(cur);
        (p_hiwtr orelse return RC.MISUSE).* = @truncate(hw);
    }
    return rc;
}

pub export fn sqlite3_release_memory(_: c_int) callconv(.c) c_int {
    return 0;
}

pub export fn sqlite3_soft_heap_limit64(n: i64) callconv(.c) i64 {
    return c.main.softHeapLimit64(n);
}

pub export fn sqlite3_hard_heap_limit64(n: i64) callconv(.c) i64 {
    return c.main.hardHeapLimit64(n);
}

pub export fn sqlite3_soft_heap_limit(n: c_int) callconv(.c) void {
    _ = c.main.softHeapLimit64(@max(n, 0));
}

pub export fn sqlite3_memory_alarm(_: ?*const anyopaque, _: ?*anyopaque, _: i64) callconv(.c) c_int {
    return RC.OK;
}

pub export fn sqlite3_enable_shared_cache(_: c_int) callconv(.c) c_int {
    // There is no shared cache; enabling it is accepted, as SQLite
    // (which deprecates it) does.
    return RC.OK;
}

pub export fn sqlite3_global_recover() callconv(.c) c_int {
    return RC.OK;
}

pub export fn sqlite3_thread_cleanup() callconv(.c) void {}

// =========================================================== misc utils

pub export fn sqlite3_randomness(n: c_int, p: ?*anyopaque) callconv(.c) void {
    if (n <= 0 or p == null) return func_mod.randomness(null, &.{});
    const b: [*]u8 = @ptrCast(p.?);
    func_mod.randomness(null, b[0..@intCast(n)]);
}

pub export fn sqlite3_sleep(ms: c_int) callconv(.c) c_int {
    c.ensureInit();
    const us: u32 = @intCast(@as(i64, @max(ms, 0)) * 1000);
    return @intCast(@import("vfs.zig").defaultEngine().sleep(us) / 1000);
}

pub export fn sqlite3_complete(sql: ?[*:0]const u8) callconv(.c) c_int {
    return @intFromBool(complete_mod.complete(c.span(sql) orelse return 0));
}

pub export fn sqlite3_complete16(sql: ?*const anyopaque) callconv(.c) c_int {
    const z = c.utf16ToUtf8(c.utf16Slice(sql orelse return 0, -1), false) orelse return RC.NOMEM;
    defer c.gpa.free(z);
    return @intFromBool(complete_mod.complete(z));
}

pub export fn sqlite3_incomplete(sql: ?[*:0]const u8) callconv(.c) i64 {
    return complete_mod.incomplete(c.span(sql) orelse return 0);
}

pub export fn sqlite3_keyword_count() callconv(.c) c_int {
    return grammar.keywords.len;
}

pub export fn sqlite3_keyword_name(i: c_int, pz: ?*?[*]const u8, pn: ?*c_int) callconv(.c) c_int {
    if (i < 0 or i >= grammar.keywords.len) return RC.ERROR;
    const k = grammar.keywords[@intCast(i)].name;
    if (pz) |p| p.* = k.ptr;
    if (pn) |p| p.* = @intCast(k.len);
    return RC.OK;
}

pub export fn sqlite3_keyword_check(z: ?[*]const u8, n: c_int) callconv(.c) c_int {
    if (n <= 0) return 0;
    return @intFromBool(tokenize.keywordCode((z orelse return 0)[0..@intCast(n)]) != grammar.TK.ID);
}

pub export fn sqlite3_stricmp(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) c_int {
    const x = c.span(a) orelse return if (b != null) -1 else 0;
    const y = c.span(b) orelse return 1;
    return c.ctype.strICmp(x, y);
}

pub export fn sqlite3_strnicmp(a: ?[*:0]const u8, b: ?[*:0]const u8, n: c_int) callconv(.c) c_int {
    const x = c.span(a) orelse return if (b != null) -1 else 0;
    const y = c.span(b) orelse return 1;
    if (n <= 0) return 0;
    return c.ctype.strNICmp(x, y, @intCast(n));
}

pub export fn sqlite3_strglob(pattern: ?[*:0]const u8, str: ?[*:0]const u8) callconv(.c) c_int {
    return func_mod.strglob(pattern, str);
}

pub export fn sqlite3_strlike(pattern: ?[*:0]const u8, str: ?[*:0]const u8, esc: c_uint) callconv(.c) c_int {
    return func_mod.strlike(pattern, str, esc);
}

pub export fn sqlite3_activate_cerod(_: ?[*:0]const u8) callconv(.c) void {}

// The xq_* functions are for capi/varargs.c only: hidden outside the library.
comptime {
    @export(&xq_config, .{ .name = "xq_config", .visibility = .hidden });
}
