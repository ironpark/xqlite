const std = @import("std");
const vfs = @import("../vfs/vfs.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const UnixVfs = @import("../vfs/unix.zig").UnixVfs;
const pager_mod = @import("pager.zig");
const root = @import("../root.zig");

const testing = std.testing;
const Pager = pager_mod.Pager;
const Page = pager_mod.Page;
const Pgno = pager_mod.Pgno;

const page_size = 1024;
const db_name = "test.db";
const journal_name = "test.db-journal";

fn openPager(v: vfs.Vfs, opts: pager_mod.Options) !*Pager {
    var o = opts;
    o.page_size = page_size;
    return Pager.open(testing.allocator, v, db_name, o);
}

/// Bytes the pager owns on page 1 (change counter, version) are skipped.
fn expectFilled(pg: *const Page, fill: u8) !void {
    for (pg.data, 0..) |b, i| {
        if (pg.pgno == 1 and ((i >= 24 and i < 28) or i >= 92 and i < 100)) continue;
        if (b != fill) {
            std.debug.print("page {d} byte {d}: {d} != {d}\n", .{ pg.pgno, i, b, fill });
            return error.TestUnexpectedResult;
        }
    }
}

/// Takes a read lock and starts a write transaction, returning page 1,
/// which the caller releases with `unrefPageOne` to end the transaction.
fn beginWrite(p: *Pager) !*Page {
    try p.sharedLock();
    const p1 = try p.get(1, .{});
    errdefer p.unrefPageOne(p1);
    try p.begin(false);
    return p1;
}

/// Inside a write transaction, fills page 1 (held by the caller) and the
/// listed pages.
fn fillPages(p: *Pager, p1: *Page, pages: []const Pgno, fill: u8) !void {
    try p.write(p1);
    @memset(p1.data, fill);
    for (pages) |pgno| {
        const pg = try p.get(pgno, .{});
        defer p.unref(pg);
        try p.write(pg);
        @memset(pg.data, fill);
    }
}

/// Page numbers first..last (empty if last < first).
fn range(comptime first: Pgno, comptime last: Pgno) [last + 1 - first]Pgno {
    var r: [last + 1 - first]Pgno = undefined;
    for (&r, first..) |*x, i| x.* = @intCast(i);
    return r;
}

/// Writes `fill` over pages 1..n_pages in one committed transaction.
fn commitFill(p: *Pager, comptime n_pages: Pgno, fill: u8) !void {
    const p1 = try beginWrite(p);
    defer p.unrefPageOne(p1);
    try fillPages(p, p1, &range(2, n_pages), fill);
    try p.commitPhaseOne(false);
    try p.commitPhaseTwo();
}

fn expectDb(p: *Pager, n_pages: Pgno, fill: u8) !void {
    try p.sharedLock();
    const p1 = try p.get(1, .{});
    defer p.unrefPageOne(p1);
    try testing.expectEqual(n_pages, p.pageCount());
    try expectFilled(p1, fill);
    var pgno: Pgno = 2;
    while (pgno <= n_pages) : (pgno += 1) {
        const pg = try p.get(pgno, .{});
        defer p.unref(pg);
        try expectFilled(pg, fill);
    }
}

fn copyFile(src: vfs.Vfs, dst: vfs.Vfs, name: []const u8) !void {
    const f = try src.open(name, .{ .read_write = false });
    defer f.close();
    const buf = try testing.allocator.alloc(u8, @intCast(try f.fileSize()));
    defer testing.allocator.free(buf);
    try f.read(buf, 0);
    const g = try dst.open(name, .{ .create = true });
    defer g.close();
    try g.write(buf, 0);
}

/// Copies the database and its journal, as a power loss would leave them.
fn snapshot(src: vfs.Vfs, dst: vfs.Vfs) !void {
    try copyFile(src, dst, db_name);
    try copyFile(src, dst, journal_name);
}

pub fn fileSize(v: vfs.Vfs, name: []const u8) !u64 {
    const f = try v.open(name, .{ .read_write = false });
    defer f.close();
    return f.fileSize();
}

test "pager: create, commit, reopen" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    {
        const p = try openPager(v, .{});
        defer p.close(.{});
        try commitFill(p, 4, 0x11);
        try testing.expect(!try v.access(journal_name, .exists));
        try testing.expectEqual(@as(u64, 4 * page_size), try fileSize(v, db_name));
    }
    {
        const p = try openPager(v, .{});
        defer p.close(.{});
        try expectDb(p, 4, 0x11);
        try p.sharedLock();
        const p1 = try p.get(1, .{});
        defer p.unrefPageOne(p1);
        try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, p1.data[24..28], .big));
        try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, p1.data[92..96], .big));
        try testing.expectEqual(@as(u32, root.sqlite_version_number), std.mem.readInt(u32, p1.data[96..100], .big));
    }
}

test "pager: rollback restores cache, file and size" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    const p = try openPager(v, .{});
    defer p.close(.{});
    try commitFill(p, 3, 0x22);

    inline for (.{ false, true }) |spill| {
        const p1 = try beginWrite(p);
        try fillPages(p, p1, &.{ 2, 5 }, 0x99);
        try testing.expectEqual(@as(Pgno, 5), p.pageCount());
        // Force unreferenced dirty pages into the database file so the
        // rollback has to restore the file, not just the cache.
        if (spill) {
            try p.flush();
            try testing.expect(try fileSize(v, db_name) > 3 * page_size);
        }
        try p.rollback();
        try expectFilled(p1, 0x22);
        try testing.expectEqual(@as(Pgno, 3), p.pageCount());
        p.unrefPageOne(p1);

        try testing.expectEqual(@as(u64, 3 * page_size), try fileSize(v, db_name));
        try testing.expect(!try v.access(journal_name, .exists));
        try expectDb(p, 3, 0x22);
    }
}

fn expectPage(p: *Pager, pgno: Pgno, fill: u8) !void {
    const pg = try p.get(pgno, .{});
    defer p.unref(pg);
    try expectFilled(pg, fill);
}

test "pager: savepoints roll back to their own state" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    const p = try openPager(v, .{});
    defer p.close(.{});
    try commitFill(p, 3, 0x22);

    inline for (.{ false, true }) |spill| {
        const p1 = try beginWrite(p);
        // Changed before any savepoint: only in the main journal.
        try fillPages(p, p1, &.{2}, 0x33);
        try p.openSavepoint(1);
        try fillPages(p, p1, &.{ 2, 3, 5 }, 0x44);
        try p.openSavepoint(2);
        try fillPages(p, p1, &.{ 3, 6 }, 0x55);
        try testing.expectEqual(@as(Pgno, 6), p.pageCount());
        // With the pages in the file, rollbacks must restore the file too.
        if (spill) try p.flush();

        try p.savepoint(.rollback, 1);
        try testing.expectEqual(@as(Pgno, 5), p.pageCount());
        try expectFilled(p1, 0x44);
        for ([_]Pgno{ 2, 3, 5 }) |pgno| try expectPage(p, pgno, 0x44);

        // Savepoint 0 stays open after a rollback to it, and can be rolled
        // back to again.
        try fillPages(p, p1, &.{2}, 0x66);
        try p.savepoint(.rollback, 0);
        try p.savepoint(.rollback, 0);
        try testing.expectEqual(@as(Pgno, 3), p.pageCount());
        try expectFilled(p1, 0x33);
        try expectPage(p, 2, 0x33);
        try expectPage(p, 3, 0x22);

        try fillPages(p, p1, &.{3}, 0x77);
        try p.savepoint(.release, 0);
        try p.commitPhaseOne(false);
        try p.commitPhaseTwo();
        p.unrefPageOne(p1);

        {
            try p.sharedLock();
            const q1 = try p.get(1, .{});
            defer p.unrefPageOne(q1);
            try testing.expectEqual(@as(Pgno, 3), p.pageCount());
            try expectFilled(q1, 0x77);
            try expectPage(p, 2, 0x33);
            try expectPage(p, 3, 0x77);
        }
        try testing.expectEqual(@as(u64, 3 * page_size), try fileSize(v, db_name));
        try commitFill(p, 3, 0x22);
    }
}

test "pager: hot journal from a crash between commit phases is rolled back" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    var crashed = MemVfs.init(testing.allocator, testing.io);
    defer crashed.deinit();

    {
        const p = try openPager(mem.interface(), .{});
        defer p.close(.{});
        try commitFill(p, 3, 0x33);

        const p1 = try beginWrite(p);
        defer p.unrefPageOne(p1);
        try fillPages(p, p1, &.{ 3, 4 }, 0x44);
        try p.commitPhaseOne(false);
        // "Power loss": the database is fully written, the journal exists.
        try snapshot(mem.interface(), crashed.interface());
        try p.commitPhaseTwo();
    }

    const v = crashed.interface();
    {
        // A read-only connection cannot recover.
        const ro = try openPager(v, .{ .read_only = true });
        defer ro.close(.{});
        try testing.expectError(error.ReadOnlyRollback, ro.sharedLock());
    }
    const p = try openPager(v, .{});
    defer p.close(.{});
    try expectDb(p, 3, 0x33);
    try testing.expect(!try v.access(journal_name, .exists));
    try testing.expectEqual(@as(u64, 3 * page_size), try fileSize(v, db_name));
}

test "pager: a database without write permission opens read-only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = UnixVfs.init(testing.allocator, testing.io);
    u.dir = tmp.dir;
    const v = u.interface();
    {
        const p = try openPager(v, .{});
        defer p.close(.{});
        try commitFill(p, 3, 0x21);
    }
    if (std.c.fchmodat(tmp.dir.handle, db_name, 0o444, 0) != 0) return error.SkipZigTest;
    // Like unixOpen(), the VFS falls back to read-only and says so.
    const p = try openPager(v, .{});
    defer p.close(.{});
    // Permissions do not bind root.
    if (!p.fd.isReadOnly()) return error.SkipZigTest;
    try testing.expect(p.isReadOnly());
    try expectDb(p, 3, 0x21);
    try p.sharedLock();
    const p1 = try p.get(1, .{});
    defer p.unrefPageOne(p1);
    try testing.expectError(error.ReadOnly, p.begin(false));
}

test "pager: crash before the journal is synced leaves the database intact" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    var crashed = MemVfs.init(testing.allocator, testing.io);
    defer crashed.deinit();
    {
        const p = try openPager(mem.interface(), .{});
        defer p.close(.{});
        try commitFill(p, 2, 0x55);
        const p1 = try beginWrite(p);
        defer p.unrefPageOne(p1);
        try fillPages(p, p1, &.{}, 0x66);
        try snapshot(mem.interface(), crashed.interface());
        try p.rollback();
    }
    const p = try openPager(crashed.interface(), .{});
    defer p.close(.{});
    try expectDb(p, 2, 0x55);
}

test "pager: writer waits for readers; readers see the commit" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    const a = try openPager(v, .{});
    defer a.close(.{});
    try commitFill(a, 2, 0x10);
    const b = try openPager(v, .{});
    defer b.close(.{});

    // a reads (and caches) the database and keeps its SHARED lock.
    try a.sharedLock();
    const a1 = try a.get(1, .{});
    try expectFilled(a1, 0x10);

    const b1 = try beginWrite(b);
    try fillPages(b, b1, &.{2}, 0x20);
    // EXCLUSIVE is needed to write the file; b stalls at PENDING.
    try testing.expectError(error.Busy, b.commitPhaseOne(false));

    // PENDING keeps new readers out.
    const c = try openPager(v, .{});
    defer c.close(.{});
    try testing.expectError(error.Busy, c.sharedLock());

    a.unrefPageOne(a1);
    try b.commitPhaseOne(false);
    try b.commitPhaseTwo();
    b.unrefPageOne(b1);

    // a's cached pages are stale; the change counter tells it so.
    try expectDb(a, 2, 0x20);
}

test "pager: busy handler retries" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();

    const a = try openPager(v, .{});
    defer a.close(.{});
    try commitFill(a, 1, 0x01);

    const Ctx = struct {
        holder: *Pager,
        page: ?*Page,
        calls: u32 = 0,
        fn busy(self: *@This()) bool {
            self.calls += 1;
            // Release the reader on the first retry.
            if (self.calls == 1) {
                self.holder.unrefPageOne(self.page.?);
                self.page = null;
            }
            return self.calls <= 3;
        }
    };
    try a.sharedLock();
    var ctx: Ctx = .{ .holder = a, .page = try a.get(1, .{}) };
    const b = try openPager(v, .{ .busy_handler = .init(&ctx, Ctx.busy) });
    defer b.close(.{});
    try commitFill(b, 1, 0x02);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try expectDb(a, 1, 0x02);
}

test "pager: truncate and persist journal modes" {
    inline for (.{ pager_mod.JournalMode.truncate, pager_mod.JournalMode.persist }) |mode| {
        var mem = MemVfs.init(testing.allocator, testing.io);
        defer mem.deinit();
        var crashed = MemVfs.init(testing.allocator, testing.io);
        defer crashed.deinit();
        const v = mem.interface();
        {
            const p = try openPager(v, .{ .journal_mode = mode });
            defer p.close(.{});
            try commitFill(p, 3, 0x70);
            try commitFill(p, 3, 0x71);
            try testing.expect(try v.access(journal_name, .exists));
            const jsize = try fileSize(v, journal_name);
            switch (mode) {
                .truncate => try testing.expectEqual(@as(u64, 0), jsize),
                .persist => {
                    try testing.expect(jsize > 0);
                    const j = try v.open(journal_name, .{ .read_write = false });
                    defer j.close();
                    var hdr: [28]u8 = undefined;
                    try j.read(&hdr, 0);
                    try testing.expectEqualSlices(u8, &@as([28]u8, @splat(0)), &hdr);
                },
                else => unreachable,
            }

            // A crash mid-commit on top of a leftover persistent journal.
            const p1 = try beginWrite(p);
            defer p.unrefPageOne(p1);
            try fillPages(p, p1, &.{ 2, 3 }, 0x72);
            try p.commitPhaseOne(false);
            try snapshot(v, crashed.interface());
            try p.commitPhaseTwo();
        }
        // A finalized journal is not hot.
        {
            const p = try openPager(v, .{ .journal_mode = mode });
            defer p.close(.{});
            try expectDb(p, 3, 0x72);
        }
        const p = try openPager(crashed.interface(), .{ .journal_mode = mode });
        defer p.close(.{});
        try expectDb(p, 3, 0x71);
    }
}

test "pager: journal_mode=off cannot roll back" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const p = try openPager(mem.interface(), .{ .journal_mode = .off });
    defer p.close(.{});
    try commitFill(p, 2, 0x01);
    try testing.expect(!try mem.interface().access(journal_name, .exists));

    const p1 = try beginWrite(p);
    try p.write(p1);
    try p.rollback();
    try testing.expectError(error.Abort, p.get(2, .{}));
    p.unrefPageOne(p1);
    // Unlocking clears the error and the cache.
    try expectDb(p, 2, 0x01);
}

test "pager: lock-byte page and page 0 are rejected" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const p = try openPager(mem.interface(), .{});
    defer p.close(.{});
    try commitFill(p, 1, 0);
    try p.sharedLock();
    const p1 = try p.get(1, .{});
    defer p.unrefPageOne(p1);
    try testing.expectError(error.Corrupt, p.get(0, .{}));
    try testing.expectError(error.Corrupt, p.get(p.lck_pgno, .{}));
}

test "pager: pages sharing a sector are journaled together" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    // An old disk: 4096-byte sectors, no POWERSAFE_OVERWRITE or SAFE_APPEND.
    // Exercises the multi-page-sector and nRec-update paths.
    mem.sector_size = 4096;
    mem.device_characteristics = .{};
    var crashed = MemVfs.init(testing.allocator, testing.io);
    defer crashed.deinit();

    {
        const p = try openPager(mem.interface(), .{});
        defer p.close(.{});
        try testing.expectEqual(@as(u32, 4096), p.sector_size);
        try commitFill(p, 8, 0x80);

        const p1 = try beginWrite(p);
        defer p.unrefPageOne(p1);
        // Page 6 shares a 4096-byte sector with pages 5, 7 and 8.
        const pg = try p.get(6, .{});
        try p.write(pg);
        @memset(pg.data, 0x81);
        p.unref(pg);
        for ([_]Pgno{ 5, 7, 8 }) |pgno| {
            const other = p.lookup(pgno).?;
            defer p.unref(other);
            try testing.expect(other.flags.need_sync);
        }
        try testing.expectEqual(@as(u32, 4), p.n_rec);
        try p.commitPhaseOne(false);
        try snapshot(mem.interface(), crashed.interface());
        try p.commitPhaseTwo();
    }

    const p = try openPager(crashed.interface(), .{});
    defer p.close(.{});
    try expectDb(p, 8, 0x80);
}

// ================================================================= WAL

const wal_name = "test.db-wal";

/// Switches `p` (holding no reference) to WAL mode, as lockBtree() does
/// when the header asks for it.
fn enterWal(p: *Pager) !void {
    try p.sharedLock();
    const p1 = try p.get(1, .{});
    try testing.expect(!try p.openWal());
    p.unrefPageOne(p1);
    try testing.expect(p.useWal());
}

test "pager: WAL commit, readers through the WAL, checkpoint on close" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    {
        const p = try openPager(v, .{});
        defer p.close(.{});
        try commitFill(p, 3, 0x11);
        try enterWal(p);
        try commitFill(p, 5, 0x22);
        // The database file is untouched; the pages are in the WAL.
        try testing.expectEqual(@as(u64, 3 * page_size), try fileSize(v, db_name));
        try testing.expect(try v.access(wal_name, .exists));
        try expectDb(p, 5, 0x22);

        // A second connection finds the WAL and reads through it.
        const q = try openPager(v, .{});
        defer q.close(.{});
        try expectDb(q, 5, 0x22);
        try commitFill(q, 5, 0x33);
        try testing.expect(q.useWal());
        // The first one sees the new snapshot.
        try expectDb(p, 5, 0x33);

        var n_log: i32 = -1;
        var n_ckpt: i32 = -1;
        try p.checkpoint(.{}, .passive, &n_log, &n_ckpt);
        try testing.expect(n_log > 0);
        try testing.expectEqual(n_log, n_ckpt);
        try testing.expectEqual(@as(u64, 5 * page_size), try fileSize(v, db_name));
    }
    // The last connection checkpointed and deleted the WAL.
    try testing.expect(!try v.access(wal_name, .exists));
    const p = try openPager(v, .{});
    defer p.close(.{});
    try expectDb(p, 5, 0x33);
    try testing.expect(!p.useWal());
}

test "pager: WAL rollback, savepoints and spilled frames" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    const p = try openPager(v, .{});
    defer p.close(.{});
    try commitFill(p, 3, 0x22);
    try enterWal(p);

    inline for (.{ false, true }) |spill| {
        const p1 = try beginWrite(p);
        try fillPages(p, p1, &.{2}, 0x33);
        try p.openSavepoint(1);
        try fillPages(p, p1, &.{ 2, 3, 5 }, 0x44);
        try p.openSavepoint(2);
        try fillPages(p, p1, &.{ 3, 6 }, 0x55);
        // Spilled pages go to the WAL as frames without a commit mark.
        if (spill) try p.flush();

        try p.savepoint(.rollback, 1);
        try testing.expectEqual(@as(Pgno, 5), p.pageCount());
        try expectFilled(p1, 0x44);
        for ([_]Pgno{ 2, 3, 5 }) |pgno| try expectPage(p, pgno, 0x44);

        try fillPages(p, p1, &.{2}, 0x66);
        if (spill) try p.flush();
        try p.savepoint(.rollback, 0);
        try testing.expectEqual(@as(Pgno, 3), p.pageCount());
        try expectFilled(p1, 0x33);
        try expectPage(p, 2, 0x33);
        try expectPage(p, 3, 0x22);

        try fillPages(p, p1, &.{3}, 0x77);
        try p.savepoint(.release, 0);
        try p.commitPhaseOne(false);
        try p.commitPhaseTwo();
        p.unrefPageOne(p1);

        {
            try p.sharedLock();
            const q1 = try p.get(1, .{});
            defer p.unrefPageOne(q1);
            try testing.expectEqual(@as(Pgno, 3), p.pageCount());
            try expectFilled(q1, 0x77);
            try expectPage(p, 2, 0x33);
            try expectPage(p, 3, 0x77);
        }
        // A whole-transaction rollback forgets spilled frames.
        {
            const p1b = try beginWrite(p);
            try fillPages(p, p1b, &.{ 2, 3, 4 }, 0x88);
            if (spill) try p.flush();
            try p.rollback();
            try expectFilled(p1b, 0x77);
            p.unrefPageOne(p1b);
        }
        {
            try p.sharedLock();
            const q1 = try p.get(1, .{});
            defer p.unrefPageOne(q1);
            try testing.expectEqual(@as(Pgno, 3), p.pageCount());
            try expectPage(p, 2, 0x33);
            try expectPage(p, 3, 0x77);
        }
        try commitFill(p, 3, 0x22);
    }
}

test "pager: WAL snapshot isolation and writer exclusion" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    const a = try openPager(v, .{});
    defer a.close(.{});
    try commitFill(a, 2, 0x01);
    try enterWal(a);
    try commitFill(a, 2, 0x02);

    const b = try openPager(v, .{});
    defer b.close(.{});
    // b holds a snapshot while a commits twice.
    try b.sharedLock();
    const b1 = try b.get(1, .{});
    try expectFilled(b1, 0x02);
    try commitFill(a, 2, 0x03);
    try commitFill(a, 3, 0x04);
    try expectPage(b, 2, 0x02);
    try testing.expectEqual(@as(Pgno, 2), b.pageCount());
    // A writer with an old snapshot is refused.
    try testing.expectError(error.BusySnapshot, b.begin(false));
    // Checkpoints cannot complete past b's snapshot.
    try testing.expectError(error.Busy, a.checkpoint(.{}, .restart, null, null));
    b.unrefPageOne(b1);
    try expectDb(b, 3, 0x04);

    // Only one writer at a time.
    const a1 = try beginWrite(a);
    try b.sharedLock();
    const c1 = try b.get(1, .{});
    try testing.expectError(error.Busy, b.begin(false));
    b.unrefPageOne(c1);
    try a.rollback();
    a.unrefPageOne(a1);

    var n_log: i32 = -1;
    var n_ckpt: i32 = -1;
    try a.checkpoint(.{}, .truncate, &n_log, &n_ckpt);
    try testing.expectEqual(@as(i32, 0), n_log);
    try testing.expectEqual(@as(u64, 0), try fileSize(v, wal_name));
    try expectDb(b, 3, 0x04);
    try commitFill(b, 3, 0x05);
    try expectDb(a, 3, 0x05);
}

test "pager: leaving WAL mode checkpoints and deletes the WAL" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    const p = try openPager(v, .{});
    defer p.close(.{});
    try commitFill(p, 2, 0x01);
    try enterWal(p);
    try commitFill(p, 4, 0x02);
    {
        // Another connection holds the database: no exclusive lock.
        const q = try openPager(v, .{});
        defer q.close(.{});
        try expectDb(q, 4, 0x02);
        try testing.expectError(error.Busy, p.closeWal(.{}));
        try testing.expect(p.useWal());
    }
    try p.closeWal(.{});
    _ = p.setJournalMode(.delete);
    try testing.expect(!p.useWal());
    try testing.expect(!try v.access(wal_name, .exists));
    // The EXCLUSIVE lock is kept until the next read transaction.
    try expectDb(p, 4, 0x02);
    try testing.expectEqual(@as(u64, 4 * page_size), try fileSize(v, db_name));
}
