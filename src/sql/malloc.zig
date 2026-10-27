//! Memory allocation (port of malloc.c, mem1.c and the lookaside parts of
//! main.c and status.c).
//!
//! SQLite allocates memory at two tiers, and so does this port:
//!
//! - sqlite3_malloc() and sqlite3_free(): the library-wide allocator, for
//!   whatever is not tied to a connection (the pager, b-trees, the page
//!   cache, sqlite3_value_dup(), RCStr strings, the connection object
//!   itself). `allocator` is this tier as a std.mem.Allocator; malloc(),
//!   free(), realloc() and mallocSize() are its C-style entry points.
//!   As in mem1.c built without SQLITE_MALLOCSIZE, every allocation is
//!   preceded by 8 bytes holding its size, so free() needs nothing but
//!   the pointer: it serves as a destructor (`fn (?*anyopaque) void`),
//!   and frees through `allocator` need not pass the exact length. The
//!   memory comes from the allocator set with configMalloc()
//!   (SQLITE_CONFIG_MALLOC): by default the C library's malloc(), or
//!   std.testing.allocator in tests, so every test is leak-checked.
//!
//! - sqlite3DbMallocRaw() and sqlite3DbFree(): per connection. They hand
//!   out the connection's lookaside slots when the request fits and one
//!   is free, and go to the tier above otherwise. dbAllocator(db), which
//!   is what `db.gpa` holds, is this tier as a std.mem.Allocator. Its free
//!   tells a lookaside slot by its address and passes anything else to
//!   free(), so it frees memory from either tier, as sqlite3DbFree() does.
//!
//! The usable size of an allocation (sqlite3DbMallocSize()) is known from
//! the pointer alone: the slot size for lookaside, the header otherwise.
//! A Mem or StrAccum that takes a buffer over records that size, and a
//! buffer is handed over without being trimmed to its content.

const std = @import("std");
const builtin = @import("builtin");
const int = @import("sqlite_int.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Sqlite3 = int.Sqlite3;
const Lookaside = int.Lookaside;
const LookasideSlot = int.LookasideSlot;
const RC = int.RC;

/// SQLITE_MAX_ALLOCATION_SIZE: larger requests to malloc() fail.
pub const max_allocation_size = 2147483391;

/// LOOKASIDE_SMALL: the size of the small lookaside slots.
pub const LOOKASIDE_SMALL = 128;

/// SQLITE_DEFAULT_LOOKASIDE: slot size and count of a new connection.
pub const default_lookaside_sz = 1200;
pub const default_lookaside_n = 40;

// ============================================================ configuration

/// The parts of sqlite3GlobalConfig about memory.
const Config = struct {
    /// What the allocations of the library come from (sqlite3GlobalConfig.m,
    /// which mem1.c fills with the system malloc()).
    backing: Allocator,
    /// Default lookaside slot size and count (szLookaside, nLookaside).
    sz_lookaside: i32 = default_lookaside_sz,
    n_lookaside: i32 = default_lookaside_n,
};

var config: Config = .{
    .backing = if (builtin.is_test)
        std.testing.allocator
    else if (builtin.link_libc)
        libc_allocator
    else
        std.heap.smp_allocator,
};

/// The system malloc(), free() and realloc() under the size header, as
/// mem1.c uses them (SQLITE_MALLOC() and friends); std.heap.c_allocator
/// would also ask malloc_size() on every resize.
const libc_allocator: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = Libc.alloc,
    .resize = Libc.resize,
    .remap = Libc.remap,
    .free = Libc.free,
} };

const Libc = struct {
    fn overAligned(a: Alignment) bool {
        return a.compare(.gt, .of(std.c.max_align_t));
    }

    fn alloc(_: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        if (overAligned(a)) return std.heap.c_allocator.rawAlloc(len, a, ra);
        return @ptrCast(std.c.malloc(len));
    }

    fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        return new_len <= memory.len;
    }

    fn remap(_: *anyopaque, memory: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if (overAligned(a)) return std.heap.c_allocator.rawRemap(memory, a, new_len, ra);
        return @ptrCast(std.c.realloc(memory.ptr, new_len));
    }

    fn free(_: *anyopaque, memory: []u8, a: Alignment, ra: usize) void {
        if (overAligned(a)) return std.heap.c_allocator.rawFree(memory, a, ra);
        std.c.free(memory.ptr);
    }
};

/// Port of sqlite3_config(SQLITE_CONFIG_MALLOC): take the memory of the
/// library from `a`. Like the C option it must be set before anything is
/// allocated, and not changed while any of it is still in use.
pub fn configMalloc(a: Allocator) void {
    config.backing = a;
}

/// The allocator behind the library, as set by configMalloc()
/// (SQLITE_CONFIG_GETMALLOC).
pub fn configGetMalloc() Allocator {
    return config.backing;
}

/// Port of sqlite3_config(SQLITE_CONFIG_LOOKASIDE): the lookaside slot
/// size and count of connections opened later.
pub fn configLookaside(sz: i32, n: i32) void {
    config.sz_lookaside = sz;
    config.n_lookaside = n;
}

/// The lookaside slot size and count of new connections.
pub fn configLookasideDefaults() struct { sz: i32, n: i32 } {
    return .{ .sz = config.sz_lookaside, .n = config.n_lookaside };
}

// ======================================== sqlite3_malloc() (mem1.c header)

/// The 8 bytes in front of an allocation. They hold its size, rounded up
/// to 8 (sqlite3MemRoundup()), and in the top byte log2 of its alignment:
/// with an alignment above 8 the header grows to the alignment, its size
/// word still last.
const size_mask: u64 = (1 << 56) - 1;

fn headerWord(p: [*]u8) *u64 {
    return @ptrCast(@alignCast(p - 8));
}

const Block = struct {
    /// The allocation of the backing allocator, header included.
    raw: []u8,
    alignment: Alignment,
    /// Usable bytes after the header.
    n: usize,
};

fn block(p: [*]u8) Block {
    const w = headerWord(p).*;
    const a: Alignment = @enumFromInt(@as(u6, @intCast(w >> 56)));
    const h = a.toByteUnits();
    const n: usize = @intCast(w & size_mask);
    return .{ .raw = (p - h)[0 .. h + n], .alignment = a, .n = n };
}

/// sqlite3MemRoundup(): ROUND8.
fn roundup(n: usize) ?usize {
    if (n > size_mask - 8) return null;
    return std.mem.alignForward(usize, n, 8);
}

/// Port of sqlite3MemMalloc(): `n` bytes after the size header.
fn memMalloc(n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    const a = alignment.max(.@"8");
    const h = a.toByteUnits();
    const full = roundup(n) orelse return null;
    const raw = config.backing.rawAlloc(h + full, a, ra) orelse return null;
    const p = raw + h;
    headerWord(p).* = full | (@as(u64, @intFromEnum(a)) << 56);
    return p;
}

/// Port of sqlite3MemFree().
fn memFree(p: [*]u8, ra: usize) void {
    const b = block(p);
    config.backing.rawFree(b.raw, b.alignment, ra);
}

/// Port of sqlite3MemSize().
fn memSize(p: [*]const u8) usize {
    return @intCast(headerWord(@constCast(p)).* & size_mask);
}

/// Resize in place; false if the backing allocator cannot.
fn memResize(p: [*]u8, n: usize, ra: usize) bool {
    const b = block(p);
    const full = roundup(n) orelse return false;
    if (full == b.n) return true;
    const h = b.alignment.toByteUnits();
    if (!config.backing.rawResize(b.raw, b.alignment, h + full, ra)) return false;
    headerWord(p).* = full | (@as(u64, @intFromEnum(b.alignment)) << 56);
    return true;
}

/// Port of sqlite3MemRealloc(): resize, maybe moving; null if the
/// backing allocator cannot (the block is unchanged).
fn memRealloc(p: [*]u8, n: usize, ra: usize) ?[*]u8 {
    const b = block(p);
    const full = roundup(n) orelse return null;
    if (full == b.n) return p;
    const h = b.alignment.toByteUnits();
    const raw = config.backing.rawRemap(b.raw, b.alignment, h + full, ra) orelse return null;
    const q = raw + h;
    headerWord(q).* = full | (@as(u64, @intFromEnum(b.alignment)) << 56);
    return q;
}

/// Port of sqlite3Malloc(): `n` bytes (8-byte aligned), or null for 0,
/// too much or OOM.
pub fn malloc(n: u64) ?[*]u8 {
    if (n == 0 or n > max_allocation_size) return null;
    return memMalloc(@intCast(n), .@"8", @returnAddress());
}

/// Port of sqlite3_free(): free memory from malloc() or `allocator`.
/// A null pointer is a no-op. Usable as a destructor.
pub fn free(p: ?*anyopaque) void {
    const z = p orelse return;
    memFree(@ptrCast(z), @returnAddress());
}

/// Port of sqlite3Realloc(): resize to `n` bytes, keeping the content.
/// Null `p` allocates; `n` 0 frees and returns null. On failure the old
/// allocation is unchanged and the result is null.
pub fn realloc(p: ?*anyopaque, n: u64) ?[*]u8 {
    const old: [*]u8 = @ptrCast(p orelse return malloc(n));
    if (n == 0) {
        free(old);
        return null;
    }
    if (n > max_allocation_size) return null;
    const new_n: usize = @intCast(n);
    if (memRealloc(old, new_n, @returnAddress())) |q| return q;
    // The backing allocator cannot remap: move it.
    const q = memMalloc(new_n, .@"8", @returnAddress()) orelse return null;
    const keep = @min(memSize(old), new_n);
    @memcpy(q[0..keep], old[0..keep]);
    memFree(old, @returnAddress());
    return q;
}

/// Port of sqlite3MallocSize() and sqlite3_msize(): the usable size of
/// an allocation from malloc() or `allocator`.
pub fn mallocSize(p: *const anyopaque) usize {
    return memSize(@ptrCast(p));
}

/// sqlite3_malloc() and friends as a std.mem.Allocator. Its free and
/// resize use the size in the header, not the length passed.
pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &global_vtable };

const global_vtable: Allocator.VTable = .{
    .alloc = globalAlloc,
    .resize = globalResize,
    .remap = globalRemap,
    .free = globalFree,
};

fn globalAlloc(_: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
    return memMalloc(len, alignment, ra);
}

fn globalResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, ra: usize) bool {
    return memResize(memory.ptr, new_len, ra);
}

fn globalRemap(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return memRealloc(memory.ptr, new_len, ra);
}

fn globalFree(_: *anyopaque, memory: []u8, _: Alignment, ra: usize) void {
    memFree(memory.ptr, ra);
}

// ============================================ per-connection allocations

/// DisableLookaside: no lookaside until the matching enableLookaside().
pub fn disableLookaside(db: *Sqlite3) void {
    db.lookaside.b_disable += 1;
    db.lookaside.sz = 0;
}

/// EnableLookaside: undo one disableLookaside().
pub fn enableLookaside(db: *Sqlite3) void {
    std.debug.assert(db.lookaside.b_disable > 0);
    db.lookaside.b_disable -= 1;
    db.lookaside.sz = if (db.lookaside.b_disable != 0) 0 else db.lookaside.sz_true;
}

/// Port of isLookaside().
fn isLookaside(db: *const Sqlite3, p: *const anyopaque) bool {
    const a = @intFromPtr(p);
    return a >= db.lookaside.start and a < db.lookaside.end;
}

/// Port of lookasideMallocSize().
fn lookasideMallocSize(db: *const Sqlite3, p: *const anyopaque) usize {
    return if (@intFromPtr(p) < db.lookaside.middle) db.lookaside.sz_true else LOOKASIDE_SMALL;
}

/// Port of sqlite3DbMallocSize(): the usable size of `p`, from the
/// lookaside of `db` or from malloc() (always the latter for a null db).
pub fn dbMallocSize(db: ?*const Sqlite3, p: *const anyopaque) usize {
    if (db) |d| {
        const a = @intFromPtr(p);
        if (a < d.lookaside.end) {
            if (a >= d.lookaside.middle) return LOOKASIDE_SMALL;
            if (a >= d.lookaside.start) return d.lookaside.sz_true;
        }
    }
    return mallocSize(p);
}

/// Port of sqlite3DbFreeNN(): free `p`, a lookaside slot of `db` or
/// memory from malloc().
pub fn dbFreeNN(db: *Sqlite3, p: *anyopaque) void {
    const la = &db.lookaside;
    const a = @intFromPtr(p);
    if (a < la.end) {
        if (a >= la.middle) {
            const buf: *LookasideSlot = @ptrCast(@alignCast(p));
            if (builtin.mode == .debug) @memset(@as([*]u8, @ptrCast(p))[0..LOOKASIDE_SMALL], 0xaa);
            buf.next = la.small_free;
            la.small_free = buf;
            return;
        }
        if (a >= la.start) {
            const buf: *LookasideSlot = @ptrCast(@alignCast(p));
            if (builtin.mode == .debug) @memset(@as([*]u8, @ptrCast(p))[0..la.sz_true], 0xaa);
            buf.next = la.free;
            la.free = buf;
            return;
        }
    }
    free(p);
}

/// Port of sqlite3DbFree().
pub fn dbFree(db: ?*Sqlite3, p: ?*anyopaque) void {
    const z = p orelse return;
    if (db) |d| dbFreeNN(d, z) else free(z);
}

/// Port of dbMallocRawFinish(): the slow path of dbMallocRawNN(), from
/// malloc().
fn dbMallocRawFinish(db: *Sqlite3, n: u64, alignment: Alignment) ?[*]u8 {
    const p = if (n > max_allocation_size) null else memMalloc(@intCast(n), alignment, @returnAddress());
    if (p == null) oomFault(db);
    return p;
}

/// Port of sqlite3DbMallocRawNN(): `n` bytes from a lookaside slot of
/// `db` if one fits and is free, else from malloc(). Once an allocation
/// has failed it keeps failing until oomClear().
pub fn dbMallocRawNN(db: *Sqlite3, n: u64) ?[*]u8 {
    const la = &db.lookaside;
    if (n > la.sz) {
        if (la.b_disable == 0) {
            la.an_stat[1] += 1;
        } else if (db.malloc_failed) {
            return null;
        }
        return dbMallocRawFinish(db, n, .@"8");
    }
    if (n <= LOOKASIDE_SMALL) {
        if (la.small_free) |buf| {
            la.small_free = buf.next;
            la.an_stat[0] += 1;
            return @ptrCast(buf);
        } else if (la.small_init) |buf| {
            la.small_init = buf.next;
            la.an_stat[0] += 1;
            return @ptrCast(buf);
        }
    }
    if (la.free) |buf| {
        la.free = buf.next;
        la.an_stat[0] += 1;
        return @ptrCast(buf);
    } else if (la.init) |buf| {
        la.init = buf.next;
        la.an_stat[0] += 1;
        return @ptrCast(buf);
    } else {
        la.an_stat[2] += 1;
    }
    return dbMallocRawFinish(db, n, .@"8");
}

/// Port of sqlite3DbRealloc(): resize `p` (from `db`) to `n` bytes. A
/// lookaside slot is kept while `n` fits in it; on failure `p` is
/// unchanged, the result null and the OOM recorded.
pub fn dbRealloc(db: *Sqlite3, p: ?*anyopaque, n: u64) ?[*]u8 {
    const old = p orelse return dbMallocRawNN(db, n);
    const a = @intFromPtr(old);
    const la = &db.lookaside;
    if (a < la.end) {
        if (a >= la.middle) {
            if (n <= LOOKASIDE_SMALL) return @ptrCast(old);
        } else if (a >= la.start) {
            if (n <= la.sz_true) return @ptrCast(old);
        }
    }
    return dbReallocFinish(db, old, n);
}

/// Port of dbReallocFinish().
fn dbReallocFinish(db: *Sqlite3, p: *anyopaque, n: u64) ?[*]u8 {
    if (db.malloc_failed) return null;
    if (isLookaside(db, p)) {
        const new = dbMallocRawNN(db, n) orelse return null;
        const old: [*]u8 = @ptrCast(p);
        const keep = @min(lookasideMallocSize(db, p), n);
        @memcpy(new[0..@intCast(keep)], old[0..@intCast(keep)]);
        dbFreeNN(db, p);
        return new;
    }
    const new = realloc(p, n);
    if (new == null) oomFault(db);
    return new;
}

/// The memory of connection `db` (sqlite3DbMalloc*() and sqlite3DbFree())
/// as a std.mem.Allocator: what `db.gpa` holds. Lookaside slots are
/// 8-byte aligned, so more aligned requests always go to malloc().
pub fn dbAllocator(db: *Sqlite3) Allocator {
    return .{ .ptr = db, .vtable = &db_vtable };
}

const db_vtable: Allocator.VTable = .{
    .alloc = dbAlloc,
    .resize = dbResize,
    .remap = dbRemap,
    .free = dbFreeVtable,
};

fn dbOf(ctx: *anyopaque) *Sqlite3 {
    return @ptrCast(@alignCast(ctx));
}

fn dbAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const db = dbOf(ctx);
    if (alignment.compare(.lte, .@"8")) return dbMallocRawNN(db, len);
    if (db.lookaside.b_disable == 0) {
        db.lookaside.an_stat[1] += 1;
    } else if (db.malloc_failed) {
        return null;
    }
    return dbMallocRawFinish(db, len, alignment);
}

/// sqlite3DbRealloc() in place: a lookaside slot resizes within its size
/// (growing past it needs a move); other memory as malloc() can.
fn dbResize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, ra: usize) bool {
    const db = dbOf(ctx);
    const a = @intFromPtr(memory.ptr);
    const la = &db.lookaside;
    if (a < la.end) {
        if (a >= la.middle) return new_len <= LOOKASIDE_SMALL;
        if (a >= la.start) return new_len <= la.sz_true;
    }
    if (db.malloc_failed) return false;
    return memResize(memory.ptr, new_len, ra);
}

/// sqlite3DbRealloc(): null when the allocation must move to grow, which
/// std.mem.Allocator.realloc() then does by allocating anew (perhaps
/// from lookaside), copying and freeing, as dbReallocFinish() does.
fn dbRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const db = dbOf(ctx);
    if (isLookaside(db, memory.ptr)) {
        return if (dbResize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }
    if (db.malloc_failed) return null;
    return memRealloc(memory.ptr, new_len, ra);
}

fn dbFreeVtable(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    dbFreeNN(dbOf(ctx), memory.ptr);
}

/// Whether `a` frees by pointer alone, needing no exact length: one of
/// the two tiers here. Allocations of other allocators must be freed
/// with the length they were made with.
pub fn freesByPointer(a: Allocator) bool {
    return a.vtable == &db_vtable or a.vtable == &global_vtable;
}

/// The usable size of `buf`, which `a` allocated: sqlite3DbMallocSize()
/// for the two tiers here, at least buf.len; for other allocators,
/// buf.len.
pub fn allocSize(a: Allocator, buf: []u8) usize {
    if (buf.len == 0) return 0;
    if (a.vtable == &db_vtable) return dbMallocSize(dbOf(a.ptr), buf.ptr);
    if (a.vtable == &global_vtable) return mallocSize(buf.ptr);
    return buf.len;
}

// ===================================================== allocation failure

/// Port of sqlite3OomFault(): record that an allocation failed and turn
/// lookaside off until oomClear(). (Running statements are not
/// interrupted, and the Parse is not told: callers report the error.)
pub fn oomFault(db: *Sqlite3) void {
    if (!db.malloc_failed) {
        db.malloc_failed = true;
        disableLookaside(db);
    }
}

/// Port of sqlite3OomClear(): forget an allocation failure once no
/// statement is running, turning lookaside back on.
pub fn oomClear(db: *Sqlite3) void {
    if (db.malloc_failed and db.n_vdbe_exec == 0) {
        db.malloc_failed = false;
        enableLookaside(db);
    }
}

// ============================================================== lookaside

/// Port of setupLookaside() (main.c): give the connection `cnt` lookaside
/// slots of `sz` bytes, in `buf` or in memory from malloc(); 0 for either
/// turns lookaside off. Slot sizes of 3 or 2 small slots and more are
/// split between full-size slots and LOOKASIDE_SMALL ones. BUSY if any
/// slot is in use.
pub fn setupLookaside(db: *Sqlite3, buf: ?[]align(8) u8, sz_arg: i32, cnt_arg: i32) i32 {
    const la = &db.lookaside;
    if (lookasideUsed(db, null) > 0) return RC.BUSY;
    // Free the old buffer first, so as not to need room for both.
    if (la.b_malloced) free(@ptrFromInt(la.start));
    // A slot must hold a pointer and its size a u16.
    var sz: i64 = sz_arg & ~@as(i32, 7);
    if (sz <= @sizeOf(*LookasideSlot)) sz = 0;
    if (sz > 65528) sz = 65528;
    // At least one slot, and no more than 0x7fff0000 bytes.
    var cnt: i64 = cnt_arg;
    if (cnt < 1) cnt = 0;
    if (sz > 0 and cnt > @divTrunc(0x7fff0000, sz)) cnt = @divTrunc(0x7fff0000, sz);
    var sz_alloc: i64 = sz * cnt;
    var start: ?[*]u8 = null;
    if (sz_alloc == 0) {
        sz = 0;
    } else if (buf) |b| {
        start = b.ptr;
        sz_alloc = @min(sz_alloc, @as(i64, @intCast(b.len)));
    } else {
        // A benign allocation: lookaside is optional.
        start = malloc(@intCast(sz_alloc));
        if (start) |s| sz_alloc = @intCast(mallocSize(s));
    }
    var n_big: i64 = 0;
    var n_sm: i64 = 0;
    if (sz >= LOOKASIDE_SMALL * 3) {
        n_big = @divTrunc(sz_alloc, 3 * LOOKASIDE_SMALL + sz);
        n_sm = @divTrunc(sz_alloc - sz * n_big, LOOKASIDE_SMALL);
    } else if (sz >= LOOKASIDE_SMALL * 2) {
        n_big = @divTrunc(sz_alloc, LOOKASIDE_SMALL + sz);
        n_sm = @divTrunc(sz_alloc - sz * n_big, LOOKASIDE_SMALL);
    } else if (sz > 0) {
        n_big = @divTrunc(sz_alloc, sz);
    }
    la.* = .{
        .b_disable = la.b_disable,
        .an_stat = la.an_stat,
        .sz = @intCast(sz),
        .sz_true = @intCast(sz),
    };
    if (start) |s| {
        std.debug.assert(sz > @sizeOf(*LookasideSlot));
        var p = s;
        var i: i64 = 0;
        while (i < n_big) : (i += 1) {
            const slot: *LookasideSlot = @ptrCast(@alignCast(p));
            slot.next = la.init;
            la.init = slot;
            p += @intCast(sz);
        }
        la.middle = @intFromPtr(p);
        i = 0;
        while (i < n_sm) : (i += 1) {
            const slot: *LookasideSlot = @ptrCast(@alignCast(p));
            slot.next = la.small_init;
            la.small_init = slot;
            p += LOOKASIDE_SMALL;
        }
        std.debug.assert(@intFromPtr(p) <= @intFromPtr(s) + @as(usize, @intCast(sz_alloc)));
        la.start = @intFromPtr(s);
        la.end = @intFromPtr(p);
        la.b_disable = 0;
        la.b_malloced = buf == null;
        la.n_slot = @intCast(n_big + n_sm);
    } else {
        la.b_disable = 1;
        la.sz = 0;
    }
    std.debug.assert(lookasideUsed(db, null) == 0);
    return RC.OK;
}

/// The end of setupLookaside()'s work, at sqlite3_close(): free the
/// lookaside buffer, which must have no slot in use.
pub fn freeLookaside(db: *Sqlite3) void {
    if (builtin.mode == .debug) std.debug.assert(lookasideUsed(db, null) == 0);
    if (db.lookaside.b_malloced) free(@ptrFromInt(db.lookaside.start));
    db.lookaside = .{};
}

/// Port of countLookasideSlots() (status.c).
fn countLookasideSlots(first: ?*LookasideSlot) u32 {
    var cnt: u32 = 0;
    var p = first;
    while (p) |s| : (p = s.next) cnt += 1;
    return cnt;
}

/// Port of sqlite3LookasideUsed() (status.c): the slots in use, and in
/// `highwater` how many were ever used.
pub fn lookasideUsed(db: *const Sqlite3, highwater: ?*i32) i32 {
    const la = &db.lookaside;
    const n_init = countLookasideSlots(la.init) + countLookasideSlots(la.small_init);
    const n_free = countLookasideSlots(la.free) + countLookasideSlots(la.small_free);
    std.debug.assert(la.n_slot >= n_init + n_free);
    if (highwater) |h| h.* = @intCast(la.n_slot - n_init);
    return @intCast(la.n_slot - (n_init + n_free));
}

/// The sqlite3_db_status() verbs ported (SQLITE_DBSTATUS_*).
pub const DbStatus = enum(i32) {
    lookaside_used = 0,
    lookaside_hit = 4,
    lookaside_miss_size = 5,
    lookaside_miss_full = 6,
};

/// Port of sqlite3_db_status64() (status.c) for the lookaside verbs:
/// the current value and the highwater mark, reset if `reset`.
pub fn dbStatus(db: *Sqlite3, op: DbStatus, current: *i64, highwater: *i64, reset: bool) i32 {
    const la = &db.lookaside;
    switch (op) {
        .lookaside_used => {
            var h: i32 = 0;
            current.* = lookasideUsed(db, &h);
            highwater.* = h;
            if (reset) {
                // Every free slot counts as never used again.
                if (la.free) |first| {
                    var p = first;
                    while (p.next) |n| p = n;
                    p.next = la.init;
                    la.init = la.free;
                    la.free = null;
                }
                if (la.small_free) |first| {
                    var p = first;
                    while (p.next) |n| p = n;
                    p.next = la.small_init;
                    la.small_init = la.small_free;
                    la.small_free = null;
                }
            }
        },
        .lookaside_hit, .lookaside_miss_size, .lookaside_miss_full => {
            const i: usize = @intCast(@intFromEnum(op) - @intFromEnum(DbStatus.lookaside_hit));
            current.* = 0;
            highwater.* = la.an_stat[i];
            if (reset) la.an_stat[i] = 0;
        },
    }
    return RC.OK;
}

// ================================================================== tests

const testing = std.testing;
const Conn = @import("sql_test.zig").Conn;

/// The value of a lookaside counter of `db`, after which it restarts.
fn takeStat(db: *Sqlite3, op: DbStatus) i64 {
    var cur: i64 = 0;
    var hi: i64 = 0;
    _ = dbStatus(db, op, &cur, &hi, true);
    return if (op == .lookaside_used) cur else hi;
}

test "malloc: sqlite3_malloc() frees by pointer" {
    const p = malloc(13).?;
    try testing.expectEqual(@as(usize, 16), mallocSize(p));
    @memcpy(p[0..13], "hello, world!");
    const q = realloc(p, 1000).?;
    try testing.expectEqualStrings("hello, world!", q[0..13]);
    try testing.expectEqual(@as(usize, 1000), mallocSize(q));
    free(q);
    try testing.expect(malloc(0) == null);
    try testing.expect(malloc(max_allocation_size + 1) == null);
    free(null);
    // Through the Allocator interface, a free need not know the length.
    const s = try allocator.alloc(u8, 40);
    allocator.free(s[0..3]);
    const wide = try allocator.alignedAlloc(u8, .@"16", 24);
    try testing.expect(std.mem.isAligned(@intFromPtr(wide.ptr), 16));
    free(wide.ptr);
}

test "lookaside: the default slots, hits and misses" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const db = c.db;
    const la = &db.lookaside;
    // SQLITE_DEFAULT_LOOKASIDE 1200,40: 48000 bytes as 30 slots of 1200
    // bytes and 93 of 128.
    try testing.expectEqual(@as(u16, 1200), la.sz_true);
    try testing.expectEqual(@as(u32, 30 + 93), la.n_slot);
    try testing.expectEqual(@as(u32, 0), la.b_disable);
    try testing.expectEqual(@as(i32, 0), lookasideUsed(db, null));
    _ = takeStat(db, .lookaside_hit);
    _ = takeStat(db, .lookaside_miss_size);
    _ = takeStat(db, .lookaside_miss_full);

    const small = try db.gpa.alloc(u8, 100);
    try testing.expectEqual(@as(usize, LOOKASIDE_SMALL), dbMallocSize(db, small.ptr));
    const big = try db.gpa.alloc(u8, 1000);
    try testing.expectEqual(@as(usize, 1200), dbMallocSize(db, big.ptr));
    try testing.expect(@intFromPtr(big.ptr) < la.middle and @intFromPtr(small.ptr) >= la.middle);
    const huge = try db.gpa.alloc(u8, 1201);
    try testing.expect(!isLookaside(db, huge.ptr));
    try testing.expectEqual(@as(usize, 1208), dbMallocSize(db, huge.ptr));
    try testing.expectEqual(@as(i64, 2), takeStat(db, .lookaside_hit));
    try testing.expectEqual(@as(i64, 1), takeStat(db, .lookaside_miss_size));
    try testing.expectEqual(@as(i32, 2), lookasideUsed(db, null));

    // Small requests take big slots once the small ones are gone, then
    // miss.
    var held: [123]*u64 = undefined;
    for (&held) |*h| h.* = try db.gpa.create(u64);
    try testing.expectEqual(@as(i64, 121), takeStat(db, .lookaside_hit));
    try testing.expectEqual(@as(i64, 2), takeStat(db, .lookaside_miss_full));
    for (held[0..121]) |h| try testing.expect(isLookaside(db, h));
    for (held[121..]) |h| try testing.expect(!isLookaside(db, h));
    var cur: i64 = 0;
    var hi: i64 = 0;
    _ = dbStatus(db, .lookaside_used, &cur, &hi, false);
    try testing.expectEqual(@as(i64, 123), cur);
    try testing.expectEqual(@as(i64, 123), hi);
    for (held) |h| db.gpa.destroy(h);
    db.gpa.free(small);
    db.gpa.free(big);
    db.gpa.free(huge);
    // Freed slots still count as used once, until a reset.
    _ = dbStatus(db, .lookaside_used, &cur, &hi, true);
    try testing.expectEqual(@as(i64, 0), cur);
    try testing.expectEqual(@as(i64, 123), hi);
    _ = dbStatus(db, .lookaside_used, &cur, &hi, false);
    try testing.expectEqual(@as(i64, 0), hi);
}

test "lookaside: growing out of a slot" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const db = c.db;
    const la = &db.lookaside;
    var buf = try db.gpa.alloc(u8, 100);
    for (buf, 0..) |*b, i| b.* = @truncate(i);
    const small = buf.ptr;
    // Within the small slot it stays put.
    buf = try db.gpa.realloc(buf, LOOKASIDE_SMALL);
    try testing.expectEqual(small, buf.ptr);
    // Past it, it moves to a big slot, then to the heap.
    buf = try db.gpa.realloc(buf, LOOKASIDE_SMALL + 1);
    try testing.expect(@intFromPtr(buf.ptr) >= la.start and @intFromPtr(buf.ptr) < la.middle);
    try testing.expect(!db.gpa.resize(buf, 1201));
    buf = try db.gpa.realloc(buf, 5000);
    try testing.expect(!isLookaside(db, buf.ptr));
    for (buf[0..100], 0..) |b, i| try testing.expectEqual(@as(u8, @truncate(i)), b);
    try testing.expectEqual(@as(i32, 0), lookasideUsed(db, null));
    db.gpa.free(buf);

    // The same through the pointer interface (sqlite3DbRealloc()).
    const p = dbMallocRawNN(db, 10).?;
    @memcpy(p[0..10], "0123456789");
    try testing.expectEqual(p, dbRealloc(db, p, 120).?);
    const q = dbRealloc(db, p, 2000).?;
    try testing.expectEqualStrings("0123456789", q[0..10]);
    try testing.expectEqual(@as(i32, 0), lookasideUsed(db, null));
    dbFree(db, q);

    // A Mem keeps the whole slot (szMalloc).
    var m: @import("../vdbe/vdbe_int.zig").Mem = .{ .db = db };
    defer @import("../vdbe/mem.zig").release(&m);
    try @import("../vdbe/mem.zig").grow(&m, 40, false);
    try testing.expectEqual(@as(usize, LOOKASIDE_SMALL), m.szMalloc());
}

test "lookaside: disabled while nested, during CREATE and after OOM" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const db = c.db;
    disableLookaside(db);
    disableLookaside(db);
    const a = try db.gpa.create(u64);
    try testing.expect(!isLookaside(db, a));
    enableLookaside(db);
    const b = try db.gpa.create(u64);
    try testing.expect(!isLookaside(db, b));
    enableLookaside(db);
    const d = try db.gpa.create(u64);
    try testing.expect(isLookaside(db, d));
    db.gpa.destroy(a);
    db.gpa.destroy(b);
    db.gpa.destroy(d);

    // Schema objects are made with lookaside off, so none is left in a
    // slot, and each statement turns it back on.
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT UNIQUE, c CHECK (c > 0))");
    try c.exec("CREATE INDEX tc ON t(c); CREATE VIEW v AS SELECT b FROM t");
    try c.exec("CREATE TABLE u(x REFERENCES t(a) ON DELETE CASCADE); PRAGMA foreign_keys=ON");
    try c.exec("INSERT INTO t VALUES(1, 'x', 2); INSERT INTO u VALUES(1); DELETE FROM t");
    try c.expectRows("SELECT * FROM v", "");
    try testing.expectEqual(@as(u32, 0), db.lookaside.b_disable);
    try testing.expectEqual(@as(i32, 0), lookasideUsed(db, null));
    try testing.expect(db.lookaside.an_stat[0] > 0);

    // A failed allocation turns lookaside off until it is cleared.
    oomFault(db);
    try testing.expectEqual(@as(u32, 1), db.lookaside.b_disable);
    try testing.expectError(error.OutOfMemory, db.gpa.create(u64));
    oomClear(db);
    try testing.expectEqual(@as(u32, 0), db.lookaside.b_disable);
    const e = try db.gpa.create(u64);
    try testing.expect(isLookaside(db, e));
    db.gpa.destroy(e);
}

test "lookaside: sqlite3_db_config(SQLITE_DBCONFIG_LOOKASIDE)" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const db = c.db;
    const main_mod = @import("main.zig");
    // Small slots only: no LOOKASIDE_SMALL split under 256 bytes.
    try testing.expectEqual(RC.OK, main_mod.dbConfigLookaside(db, null, 100, 10));
    try testing.expectEqual(@as(u16, 96), db.lookaside.sz_true);
    try testing.expectEqual(@as(u32, 10), db.lookaside.n_slot);
    try testing.expectEqual(db.lookaside.end, db.lookaside.middle);
    // Busy while a slot is in use.
    const held = try db.gpa.create(u64);
    try testing.expectEqual(RC.BUSY, main_mod.dbConfigLookaside(db, null, 0, 0));
    db.gpa.destroy(held);
    // A buffer of the application's: 256-byte slots, with small ones.
    var buf: [2048]u8 align(8) = undefined;
    try testing.expectEqual(RC.OK, main_mod.dbConfigLookaside(db, &buf, 256, 8));
    try testing.expect(!db.lookaside.b_malloced);
    try testing.expectEqual(@as(u32, 5 + 6), db.lookaside.n_slot);
    const x = try db.gpa.alloc(u8, 200);
    try testing.expect(@intFromPtr(x.ptr) >= @intFromPtr(&buf) and @intFromPtr(x.ptr) < @intFromPtr(&buf) + buf.len);
    try c.expectRows("SELECT printf('%d-%s', 7, 'seven')", "7-seven\n");
    db.gpa.free(x);
    // Off: everything comes from malloc().
    try testing.expectEqual(RC.OK, main_mod.dbConfigLookaside(db, null, 0, 0));
    try testing.expectEqual(@as(u32, 1), db.lookaside.b_disable);
    const y = try db.gpa.create(u64);
    try testing.expect(!isLookaside(db, y));
    db.gpa.destroy(y);
    try c.expectRows("SELECT printf('%d-%s', 7, 'seven')", "7-seven\n");
    try testing.expectEqual(RC.OK, main_mod.dbConfigLookaside(db, null, default_lookaside_sz, default_lookaside_n));
    try testing.expectEqual(@as(u32, 123), db.lookaside.n_slot);
}

test "lookaside: statements under allocation failures" {
    const saved = configGetMalloc();
    defer configMalloc(saved);
    var n_nomem: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 3) {
        var c: Conn = undefined;
        try c.open();
        defer c.close();
        try c.exec("CREATE TABLE t(a, b); INSERT INTO t VALUES(1, 'one'), (2, 'two')");
        var failing = std.testing.FailingAllocator.init(saved, .{ .fail_index = i });
        configMalloc(failing.allocator());
        var msg: ?[:0]u8 = null;
        const rc = @import("legacy.zig").exec(c.db, "SELECT printf('%d:%s', a, b), group_concat(b) FROM t; SELECT json_object('a', a) FROM t ORDER BY b", null, null, &msg);
        configMalloc(saved);
        if (msg) |m| free(m.ptr);
        try testing.expect(rc == RC.OK or rc == RC.NOMEM);
        if (rc == RC.NOMEM) n_nomem += 1;
        // The failure is forgotten and lookaside back on.
        try testing.expect(!c.db.malloc_failed);
        try testing.expectEqual(@as(u32, 0), c.db.lookaside.b_disable);
        try c.expectRows("SELECT printf('%d:%s', a, b) FROM t", "1:one\n2:two\n");
    }
    try testing.expect(n_nomem > 0);
}
