//! Page cache (port of pcache.c with the default pcache1.c backend folded in).
//!
//! Every cached page is in the hash table. On top of that a page is in
//! exactly one of these states:
//!
//!   * referenced (`n_ref > 0`), clean or dirty
//!   * unreferenced and dirty: on the dirty list, waiting to be written
//!   * unreferenced and clean: on the LRU list, may be recycled
//!
//! The dirty list is ordered newest-first so the pager can pick the oldest
//! dirty page to spill. The pluggable sqlite3_pcache_methods2 interface and
//! non-purgeable (in-memory database) caches are not ported.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Pgno = u32;

pub const Flags = packed struct(u8) {
    /// On the dirty list (PGHDR_DIRTY; clear means PGHDR_CLEAN).
    dirty: bool = false,
    /// Journaled and safe to modify (PGHDR_WRITEABLE).
    writeable: bool = false,
    /// The journal must be synced before this page is written (PGHDR_NEED_SYNC).
    need_sync: bool = false,
    /// Content does not need to reach the disk (PGHDR_DONT_WRITE).
    dont_write: bool = false,
    _: u4 = 0,
};

pub const Page = struct {
    /// Page content. 8 zero bytes follow it so that cell parsers can run
    /// slightly past the end without faulting.
    data: []u8,
    /// Per-page space for the layer above (btree's MemPage). The first 8
    /// bytes are zeroed whenever the page is (re)initialized.
    extra: []align(8) u8,
    pgno: Pgno,
    flags: Flags = .{},
    n_ref: u32 = 0,
    /// Set by the owner once the content is loaded. Null means the page was
    /// just created or recycled and its content is garbage.
    owner: ?*anyopaque = null,
    cache: *PCache,

    /// Dirty list links (pDirtyNext/pDirtyPrev).
    dirty_next: ?*Page = null,
    dirty_prev: ?*Page = null,
    /// Singly linked list built by `PCache.dirtyList` (pDirty).
    dirty: ?*Page = null,

    /// LRU links, only meaningful while clean and unreferenced.
    lru_next: ?*Page = null,
    lru_prev: ?*Page = null,
    on_lru: bool = false,
};

/// Called to write out a dirty page so its slot can be reused (xStress).
/// Return `error.SpillFailed` to abort the fetch; the callback keeps the
/// real cause. Returning normally without cleaning the page is fine.
pub const Stress = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, page: *Page) error{SpillFailed}!void,
};

pub const FetchError = error{ OutOfMemory, SpillFailed };

pub const PCache = struct {
    gpa: Allocator,
    page_size: u32,
    extra_size: u32,
    stress: ?Stress,

    map: std.AutoHashMapUnmanaged(Pgno, *Page) = .empty,
    /// Largest page number that may be in the map.
    max_pgno: Pgno = 0,
    /// Unreferenced clean pages, newest at the head.
    lru_head: ?*Page = null,
    lru_tail: ?*Page = null,
    n_recyclable: u32 = 0,

    /// Dirty pages, newest at the head.
    dirty_head: ?*Page = null,
    dirty_tail: ?*Page = null,
    /// Oldest dirty page that probably does not need a journal sync.
    synced: ?*Page = null,
    /// Sum of `n_ref` over all pages.
    ref_sum: u64 = 0,
    /// PRAGMA cache_size: pages if positive, KiB if negative.
    cache_size: i32 = 100,
    /// Number of pages above which dirty pages may be spilled.
    spill_size: u32 = 1,
    /// `cache_size` in pages, and 90% of it (nMax, n90pct).
    max_pages: u32 = 0,
    max_pinned: u32 = 0,

    pub fn init(gpa: Allocator, page_size: u32, extra_size: u32, stress: ?Stress) PCache {
        std.debug.assert(extra_size >= 8 and extra_size % 8 == 0);
        var pc: PCache = .{ .gpa = gpa, .page_size = page_size, .extra_size = extra_size, .stress = stress };
        pc.updateLimits();
        return pc;
    }

    pub fn deinit(pc: *PCache) void {
        var it = pc.map.valueIterator();
        while (it.next()) |p| pc.freePage(p.*);
        pc.map.deinit(pc.gpa);
        pc.* = undefined;
    }

    /// Changes the page size. No page may be referenced or dirty.
    pub fn setPageSize(pc: *PCache, page_size: u32) void {
        std.debug.assert(pc.ref_sum == 0 and pc.dirty_head == null);
        pc.truncateBackend(0);
        pc.page_size = page_size;
        pc.updateLimits();
    }

    pub fn setCacheSize(pc: *PCache, n: i32) void {
        pc.cache_size = n;
        pc.updateLimits();
    }

    /// Sets the spill threshold (0 leaves it unchanged) and returns the
    /// effective value, which is never below the cache size.
    pub fn setSpillSize(pc: *PCache, n: i32) u32 {
        if (n != 0) pc.spill_size = pc.pagesFor(n);
        return @max(pc.max_pages, pc.spill_size);
    }

    /// Converts a cache_size-style value (pages, or KiB if negative).
    fn pagesFor(pc: *const PCache, n: i32) u32 {
        if (n >= 0) return @intCast(n);
        const pages = @divTrunc(-1024 * @as(i64, n), pc.page_size + pc.extra_size);
        return @intCast(@min(pages, 1_000_000_000));
    }

    fn updateLimits(pc: *PCache) void {
        pc.max_pages = pc.pagesFor(pc.cache_size);
        pc.max_pinned = pc.max_pages * 9 / 10;
    }

    pub fn pageCount(pc: *const PCache) u32 {
        return pc.map.count();
    }

    pub fn refCount(pc: *const PCache) u64 {
        return pc.ref_sum;
    }

    // ----------------------------------------------------------------- fetch

    /// Returns a referenced page if it is cached (sqlite3PcacheFetch with
    /// createFlag 0).
    pub fn lookup(pc: *PCache, pgno: Pgno) ?*Page {
        std.debug.assert(pgno > 0);
        const p = pc.map.get(pgno) orelse return null;
        return pc.finish(p);
    }

    /// Returns a referenced page, creating it if needed. A new page has a
    /// null `owner`. If the cache is too full to grow cheaply, one dirty
    /// page is spilled through the stress callback first. Port of
    /// sqlite3PcacheFetch() + sqlite3PcacheFetchStress() + FetchFinish().
    pub fn fetch(pc: *PCache, pgno: Pgno) FetchError!*Page {
        if (pc.lookup(pgno)) |p| return p;
        // With dirty pages around, only create "cheaply" (below 90% pinned)
        // before trying to spill one.
        if (pc.dirty_head != null and pc.map.count() - pc.n_recyclable >= pc.max_pinned) {
            try pc.spillOne();
        }
        return pc.finish(try pc.create(pgno));
    }

    /// Spills the oldest unreferenced dirty page, preferring one that needs
    /// no journal sync, if the cache is over its spill threshold.
    fn spillOne(pc: *PCache) error{SpillFailed}!void {
        if (pc.map.count() <= pc.spill_size) return;
        var p = pc.synced;
        while (p) |pg| : (p = pg.dirty_prev) {
            if (pg.n_ref == 0 and !pg.flags.need_sync) break;
        }
        pc.synced = p;
        if (p == null) {
            p = pc.dirty_tail;
            while (p) |pg| : (p = pg.dirty_prev) {
                if (pg.n_ref == 0) break;
            }
        }
        const victim = p orelse return;
        if (pc.stress) |s| try s.func(s.ctx, victim);
    }

    fn finish(pc: *PCache, p: *Page) *Page {
        if (p.on_lru) pc.lruRemove(p);
        pc.ref_sum += 1;
        p.n_ref += 1;
        return p;
    }

    /// pcache1FetchStage2(): recycle the oldest clean page if the cache is
    /// full, otherwise allocate.
    fn create(pc: *PCache, pgno: Pgno) error{OutOfMemory}!*Page {
        try pc.map.ensureUnusedCapacity(pc.gpa, 1);
        const p: *Page = if (pc.lru_tail != null and pc.map.count() + 1 >= pc.max_pages) blk: {
            const victim = pc.lru_tail.?;
            pc.lruRemove(victim);
            _ = pc.map.remove(victim.pgno);
            break :blk victim;
        } else try pc.allocPage();
        p.* = .{ .data = p.data, .extra = p.extra, .pgno = pgno, .cache = pc };
        @memset(p.extra[0..8], 0);
        pc.map.putAssumeCapacityNoClobber(pgno, p);
        pc.max_pgno = @max(pc.max_pgno, pgno);
        return p;
    }

    /// One block per page: the Page header, the data with its zero overrun,
    /// then the extra space (like pcache1's PgHdr1 + buffer + extra).
    const Layout = struct { data: usize, extra: usize, len: usize };

    fn layout(pc: *const PCache) Layout {
        const data = std.mem.alignForward(usize, @sizeOf(Page), 8);
        const extra = std.mem.alignForward(usize, data + pc.page_size + 8, 8);
        return .{ .data = data, .extra = extra, .len = extra + pc.extra_size };
    }

    fn allocPage(pc: *PCache) error{OutOfMemory}!*Page {
        const l = pc.layout();
        const block = try pc.gpa.alignedAlloc(u8, .of(Page), l.len);
        const p: *Page = @ptrCast(block.ptr);
        @memset(block[l.data + pc.page_size ..][0..8], 0);
        p.* = .{
            .data = block[l.data..][0..pc.page_size],
            .extra = @alignCast(block[l.extra..][0..pc.extra_size]),
            .pgno = 0,
            .cache = pc,
        };
        return p;
    }

    fn freePage(pc: *PCache, p: *Page) void {
        const block: [*]align(@alignOf(Page)) u8 = @ptrCast(p);
        pc.gpa.free(block[0..pc.layout().len]);
    }

    // ------------------------------------------------------- ref management

    /// Drops one reference. An unreferenced clean page becomes recyclable;
    /// an unreferenced dirty page moves to the front of the dirty list.
    pub fn release(pc: *PCache, p: *Page) void {
        std.debug.assert(p.n_ref > 0);
        pc.ref_sum -= 1;
        p.n_ref -= 1;
        if (p.n_ref == 0) {
            if (p.flags.dirty) pc.dirtyMoveToFront(p) else pc.unpin(p);
        }
    }

    pub fn ref(pc: *PCache, p: *Page) void {
        std.debug.assert(p.n_ref > 0);
        p.n_ref += 1;
        pc.ref_sum += 1;
    }

    /// Removes a page holding exactly one reference from the cache.
    pub fn drop(pc: *PCache, p: *Page) void {
        std.debug.assert(p.n_ref == 1);
        if (p.flags.dirty) pc.dirtyRemove(p);
        pc.ref_sum -= 1;
        _ = pc.map.remove(p.pgno);
        pc.freePage(p);
    }

    fn unpin(pc: *PCache, p: *Page) void {
        if (pc.map.count() > pc.max_pages) {
            _ = pc.map.remove(p.pgno);
            pc.freePage(p);
        } else {
            pc.lruPushFront(p);
        }
    }

    // ---------------------------------------------------------- dirty state

    pub fn makeDirty(pc: *PCache, p: *Page) void {
        std.debug.assert(p.n_ref > 0);
        p.flags.dont_write = false;
        if (!p.flags.dirty) {
            p.flags.dirty = true;
            pc.dirtyAdd(p);
        }
    }

    pub fn makeClean(pc: *PCache, p: *Page) void {
        std.debug.assert(p.flags.dirty);
        pc.dirtyRemove(p);
        p.flags.dirty = false;
        p.flags.need_sync = false;
        p.flags.writeable = false;
        if (p.n_ref == 0) pc.unpin(p);
    }

    pub fn cleanAll(pc: *PCache) void {
        while (pc.dirty_head) |p| pc.makeClean(p);
    }

    pub fn clearSyncFlags(pc: *PCache) void {
        var p = pc.dirty_head;
        while (p) |pg| : (p = pg.dirty_next) pg.flags.need_sync = false;
        pc.synced = pc.dirty_tail;
    }

    /// Changes the page number of a referenced page, evicting any
    /// unreferenced page already at `new_pgno`.
    pub fn move(pc: *PCache, p: *Page, new_pgno: Pgno) void {
        std.debug.assert(p.n_ref > 0 and new_pgno > 0);
        if (pc.map.get(new_pgno)) |other| {
            std.debug.assert(other.n_ref == 0);
            pc.drop(pc.finish(other));
        }
        _ = pc.map.remove(p.pgno);
        pc.map.putAssumeCapacity(new_pgno, p);
        p.pgno = new_pgno;
        pc.max_pgno = @max(pc.max_pgno, new_pgno);
        if (p.flags.dirty and p.flags.need_sync) pc.dirtyMoveToFront(p);
    }

    /// Drops every page numbered above `pgno`. Page 1 survives a `pgno` of 0
    /// if it is still referenced; its content is zeroed instead.
    pub fn truncate(pc: *PCache, pgno: Pgno) void {
        var p = pc.dirty_head;
        while (p) |pg| {
            p = pg.dirty_next;
            if (pg.pgno > pgno) pc.makeClean(pg);
        }
        var limit = pgno;
        if (pgno == 0 and pc.ref_sum != 0) {
            if (pc.map.get(1)) |p1| {
                @memset(p1.data, 0);
                limit = 1;
            }
        }
        pc.truncateBackend(limit + 1);
    }

    /// Discards the whole cache.
    pub fn clear(pc: *PCache) void {
        pc.truncate(0);
    }

    /// pcache1Truncate(): frees every page numbered `limit` or above.
    fn truncateBackend(pc: *PCache, limit: Pgno) void {
        if (limit > pc.max_pgno) return;
        // Removal only leaves a tombstone, so iterating while removing is safe.
        var it = pc.map.valueIterator();
        while (it.next()) |slot| {
            const p = slot.*;
            if (p.pgno < limit) continue;
            std.debug.assert(p.n_ref == 0 and !p.flags.dirty);
            if (p.on_lru) pc.lruRemove(p);
            _ = pc.map.remove(p.pgno);
            pc.freePage(p);
        }
        pc.max_pgno = limit -| 1;
    }

    /// Returns all dirty pages linked through `Page.dirty`, sorted by page
    /// number. Port of sqlite3PcacheDirtyList().
    pub fn dirtyList(pc: *PCache) ?*Page {
        var p = pc.dirty_head;
        while (p) |pg| : (p = pg.dirty_next) pg.dirty = pg.dirty_next;
        return sortDirtyList(pc.dirty_head);
    }

    // --------------------------------------------------------------- lists

    fn dirtyAdd(pc: *PCache, p: *Page) void {
        p.dirty_prev = null;
        p.dirty_next = pc.dirty_head;
        if (p.dirty_next) |n| n.dirty_prev = p else pc.dirty_tail = p;
        pc.dirty_head = p;
        if (pc.synced == null and !p.flags.need_sync) pc.synced = p;
    }

    fn dirtyRemove(pc: *PCache, p: *Page) void {
        if (pc.synced == p) pc.synced = p.dirty_prev;
        if (p.dirty_next) |n| n.dirty_prev = p.dirty_prev else pc.dirty_tail = p.dirty_prev;
        if (p.dirty_prev) |pv| pv.dirty_next = p.dirty_next else pc.dirty_head = p.dirty_next;
        p.dirty_next = null;
        p.dirty_prev = null;
    }

    fn dirtyMoveToFront(pc: *PCache, p: *Page) void {
        pc.dirtyRemove(p);
        pc.dirtyAdd(p);
    }

    fn lruPushFront(pc: *PCache, p: *Page) void {
        std.debug.assert(!p.on_lru);
        p.lru_prev = null;
        p.lru_next = pc.lru_head;
        if (p.lru_next) |n| n.lru_prev = p else pc.lru_tail = p;
        pc.lru_head = p;
        p.on_lru = true;
        pc.n_recyclable += 1;
    }

    fn lruRemove(pc: *PCache, p: *Page) void {
        std.debug.assert(p.on_lru);
        if (p.lru_next) |n| n.lru_prev = p.lru_prev else pc.lru_tail = p.lru_prev;
        if (p.lru_prev) |pv| pv.lru_next = p.lru_next else pc.lru_head = p.lru_next;
        p.lru_next = null;
        p.lru_prev = null;
        p.on_lru = false;
        pc.n_recyclable -= 1;
    }
};

/// Merges two pgno-sorted lists linked by `dirty`.
fn mergeDirtyList(a_in: *Page, b_in: *Page) *Page {
    var a: ?*Page = a_in;
    var b: ?*Page = b_in;
    var head: ?*Page = null;
    var tail: *?*Page = &head;
    while (a != null and b != null) {
        const take = if (a.?.pgno < b.?.pgno) &a else &b;
        const p = take.*.?;
        tail.* = p;
        tail = &p.dirty;
        take.* = p.dirty;
    }
    tail.* = a orelse b;
    return head.?;
}

/// Bottom-up merge sort over the `dirty` links (pcacheSortDirtyList).
fn sortDirtyList(in: ?*Page) ?*Page {
    const n_buckets = 32;
    var buckets: [n_buckets]?*Page = @splat(null);
    var rest = in;
    while (rest) |first| {
        rest = first.dirty;
        first.dirty = null;
        var p = first;
        var i: usize = 0;
        while (i < n_buckets - 1) : (i += 1) {
            if (buckets[i]) |b| {
                p = mergeDirtyList(b, p);
                buckets[i] = null;
            } else {
                buckets[i] = p;
                break;
            }
        } else {
            buckets[i] = mergeDirtyList(buckets[i].?, p);
        }
    }
    var result: ?*Page = null;
    for (buckets) |b| {
        const bb = b orelse continue;
        result = if (result) |r| mergeDirtyList(r, bb) else bb;
    }
    return result;
}

const testing = std.testing;

test "pcache: fetch, release, recycle" {
    var pc = PCache.init(testing.allocator, 512, 8, null);
    defer pc.deinit();
    pc.setCacheSize(3);

    try testing.expectEqual(@as(?*Page, null), pc.lookup(1));
    const p1 = try pc.fetch(1);
    try testing.expectEqual(@as(?*anyopaque, null), p1.owner);
    try testing.expect(!p1.flags.dirty);
    p1.owner = &pc;
    p1.data[0] = 0xab;
    pc.release(p1);

    // Still cached: same object, content intact.
    const again = pc.lookup(1).?;
    try testing.expectEqual(p1, again);
    try testing.expectEqual(@as(u8, 0xab), again.data[0]);
    try testing.expectEqual(@as(u8, 0), again.data.ptr[512]); // overrun zeroed
    pc.release(again);

    for (2..6) |i| pc.release(try pc.fetch(@intCast(i)));
    try testing.expect(pc.pageCount() <= 3);
    try testing.expectEqual(@as(u64, 0), pc.refCount());
}

test "pcache: dirty list ordering and sort" {
    var pc = PCache.init(testing.allocator, 512, 8, null);
    defer pc.deinit();

    var pages: [6]*Page = undefined;
    const order = [_]Pgno{ 5, 2, 9, 1, 7, 3 };
    for (order, 0..) |pgno, i| {
        pages[i] = try pc.fetch(pgno);
        pc.makeDirty(pages[i]);
    }
    try testing.expectEqual(@as(Pgno, 3), pc.dirty_head.?.pgno);
    try testing.expectEqual(@as(Pgno, 5), pc.dirty_tail.?.pgno);

    var p = pc.dirtyList();
    var prev: Pgno = 0;
    var n: usize = 0;
    while (p) |pg| : (p = pg.dirty) {
        try testing.expect(pg.pgno > prev);
        prev = pg.pgno;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 6), n);

    pc.makeClean(pages[2]);
    try testing.expect(!pages[2].flags.dirty);
    for (pages) |pg| pc.release(pg);
    pc.cleanAll();
    try testing.expectEqual(@as(?*Page, null), pc.dirty_head);
}

test "pcache: truncate keeps referenced page 1" {
    var pc = PCache.init(testing.allocator, 512, 8, null);
    defer pc.deinit();
    const p1 = try pc.fetch(1);
    p1.data[10] = 1;
    for (2..5) |i| pc.release(try pc.fetch(@intCast(i)));
    pc.truncate(0);
    try testing.expectEqual(@as(u32, 1), pc.pageCount());
    try testing.expectEqual(@as(u8, 0), p1.data[10]);
    pc.release(p1);
    pc.clear();
    try testing.expectEqual(@as(u32, 0), pc.pageCount());
}

test "pcache: stress spills the oldest synced dirty page" {
    const Ctx = struct {
        spilled: std.ArrayList(Pgno) = .empty,
        fn stress(ctx: *anyopaque, page: *Page) error{SpillFailed}!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.spilled.append(testing.allocator, page.pgno) catch return error.SpillFailed;
            page.cache.makeClean(page);
        }
    };
    var ctx: Ctx = .{};
    defer ctx.spilled.deinit(testing.allocator);
    var pc = PCache.init(testing.allocator, 512, 8, .{ .ctx = &ctx, .func = Ctx.stress });
    defer pc.deinit();
    pc.setCacheSize(2);

    for (1..4) |i| {
        const p = try pc.fetch(@intCast(i));
        pc.makeDirty(p);
        if (i == 1) p.flags.need_sync = true;
        pc.release(p);
    }
    pc.release(try pc.fetch(10));
    // Page 1 is oldest but needs a journal sync, so it is never chosen.
    try testing.expectEqualSlices(Pgno, &.{ 2, 3 }, ctx.spilled.items);
    pc.cleanAll();
}
