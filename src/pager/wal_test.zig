const std = @import("std");
const vfs = @import("../vfs/vfs.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const UnixVfs = @import("../vfs/unix.zig").UnixVfs;
const pcache = @import("pcache.zig");
const wal_mod = @import("wal.zig");
const fileSize = @import("pager_test.zig").fileSize;

const testing = std.testing;
const Wal = wal_mod.Wal;
const Page = pcache.Page;

const page_size = 1024;
/// SQLITE_SYNC_FULL (3) for both WAL commits (low two bits) and
/// checkpoints (next two), as wal.walSyncFlags() and ckptSyncFlags() read
/// them.
const sync_full: u8 = 0x0f;

/// A stand-alone set of pages for frames(), linked through `dirty`.
const Pages = struct {
    bufs: [8][page_size]u8 = undefined,
    pages: [8]Page = undefined,

    fn list(self: *Pages, pgnos: []const u32, fill: u8) *Page {
        for (pgnos, 0..) |pgno, i| {
            @memset(&self.bufs[i], fill +% @as(u8, @intCast(pgno)));
            self.pages[i] = .{ .data = &self.bufs[i], .extra = &.{}, .pgno = pgno, .cache = undefined };
            self.pages[i].dirty = if (i + 1 < pgnos.len) &self.pages[i + 1] else null;
        }
        return &self.pages[0];
    }
};

/// Opens a database file and its WAL, holding a SHARED lock as the pager
/// would.
fn openWal(v: vfs.Vfs) !struct { db: vfs.File, w: *Wal } {
    const db = try v.open("w.db", .{ .create = true });
    errdefer db.close();
    try db.lock(.shared);
    const w = try Wal.open(testing.allocator, v, db, "w.db-wal", -1);
    return .{ .db = db, .w = w };
}

fn commit(w: *Wal, ps: *Pages, pgnos: []const u32, fill: u8, n_page: u32) !void {
    _ = try w.beginReadTransaction();
    defer w.endReadTransaction();
    try w.beginWriteTransaction();
    try w.frames(page_size, ps.list(pgnos, fill), n_page, true, sync_full);
    w.endWriteTransaction();
}

fn expectPage(w: *Wal, pgno: u32, fill: ?u8) !void {
    const frame = try w.findFrame(pgno);
    if (fill) |f| {
        try testing.expect(frame != 0);
        var buf: [page_size]u8 = undefined;
        try w.readFrame(frame, &buf);
        for (buf) |b| try testing.expectEqual(f +% @as(u8, @intCast(pgno)), b);
    } else {
        try testing.expectEqual(@as(u32, 0), frame);
    }
}

test "wal: checksums match the reference algorithm" {
    // s0 += x[i] + s1; s1 += x[i+1] + s0, over words of either byte order,
    // starting from a running checksum.
    var data: [24]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i * 7 + 1);
    const start: [2]u32 = .{ 0x12345678, 0x9abcdef0 };
    for ([_]std.builtin.Endian{ .big, .little }) |endian| {
        var w0 = start[0];
        var w1 = start[1];
        var i: usize = 0;
        while (i < data.len) : (i += 8) {
            w0 +%= std.mem.readInt(u32, data[i..][0..4], endian) +% w1;
            w1 +%= std.mem.readInt(u32, data[i + 4 ..][0..4], endian) +% w0;
        }
        try testing.expectEqual([2]u32{ w0, w1 }, wal_mod.checksumBytes(endian, &data, start));
    }
    // The header of a WAL written by sqlite3 3.54.1 on a little-endian
    // machine (magic 0x377f0682: little-endian checksums) and its checksum.
    const hdr = [24]u8{
        0x37, 0x7f, 0x06, 0x82, 0x00, 0x2d, 0xe2, 0x18, 0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x68, 0x84, 0x46, 0x90, 0x5e, 0x86, 0x5d, 0xd8,
    };
    try testing.expectEqual([2]u32{ 0x652d877b, 0xf572e57e }, wal_mod.checksumBytes(.little, &hdr, .{ 0, 0 }));
    try testing.expectEqual(@as(u32, 0x377f0682), wal_mod.magic);
    try testing.expectEqual(@as(u64, 32), wal_mod.frameOffset(1, 1024));
    try testing.expectEqual(@as(u64, 32 + 1048), wal_mod.frameOffset(2, 1024));
}

test "wal: write, read back and recover" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    var ps: Pages = .{};
    {
        const o = try openWal(v);
        defer o.db.close();
        try commit(o.w, &ps, &.{ 1, 2, 3 }, 0x10, 3);
        try commit(o.w, &ps, &.{ 2, 4 }, 0x20, 4);

        _ = try o.w.beginReadTransaction();
        try testing.expectEqual(@as(u32, 4), o.w.dbsize());
        try expectPage(o.w, 1, 0x10);
        try expectPage(o.w, 2, 0x20);
        try expectPage(o.w, 3, 0x10);
        try expectPage(o.w, 4, 0x20);
        try expectPage(o.w, 5, null);
        o.w.endReadTransaction();
        // Close without checkpointing: the WAL stays.
        try o.w.close(null, sync_full, null);
    }
    try testing.expect(try v.access("w.db-wal", .exists));
    {
        // The shared memory went with the last connection, so this one
        // rebuilds the index from the WAL.
        const o = try openWal(v);
        defer o.db.close();
        try testing.expect(try o.w.beginReadTransaction());
        try testing.expectEqual(@as(u32, 4), o.w.dbsize());
        try expectPage(o.w, 2, 0x20);
        try expectPage(o.w, 3, 0x10);
        o.w.endReadTransaction();

        // Checkpoint on close copies everything and deletes the WAL.
        var buf: [page_size]u8 = undefined;
        try o.w.close(null, sync_full, &buf);
    }
    try testing.expect(!try v.access("w.db-wal", .exists));
    const db = try v.open("w.db", .{});
    defer db.close();
    try testing.expectEqual(@as(u64, 4 * page_size), try db.fileSize());
    var buf: [page_size]u8 = undefined;
    try db.read(&buf, 1 * page_size);
    try testing.expectEqual(@as(u8, 0x22), buf[0]);
}

test "wal: uncommitted frames are invisible and ignored by recovery" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    var ps: Pages = .{};
    const o = try openWal(v);
    try commit(o.w, &ps, &.{ 1, 2 }, 0x30, 2);
    // A spill: frames without a commit marker.
    _ = try o.w.beginReadTransaction();
    try o.w.beginWriteTransaction();
    try o.w.frames(page_size, ps.list(&.{2}, 0x40), 0, false, sync_full);
    try o.w.frames(page_size, ps.list(&.{3}, 0x40), 0, false, sync_full);
    // Abandon the transaction, like a crash: the WAL keeps the frames.
    o.w.endWriteTransaction();
    o.w.endReadTransaction();
    try o.w.close(null, sync_full, null);
    o.db.close();

    const o2 = try openWal(v);
    defer o2.db.close();
    _ = try o2.w.beginReadTransaction();
    try testing.expectEqual(@as(u32, 2), o2.w.dbsize());
    try expectPage(o2.w, 2, 0x30);
    try expectPage(o2.w, 3, null);
    o2.w.endReadTransaction();
    // The next transaction overwrites the dead frames.
    try commit(o2.w, &ps, &.{2}, 0x50, 2);
    _ = try o2.w.beginReadTransaction();
    try expectPage(o2.w, 2, 0x50);
    o2.w.endReadTransaction();
    try o2.w.close(null, sync_full, null);
}

test "wal: readers keep their snapshot; checkpoint respects them" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    var ps: Pages = .{};
    const a = try openWal(v);
    const b = try openWal(v);
    defer b.db.close();
    var buf: [page_size]u8 = undefined;

    try commit(a.w, &ps, &.{ 1, 2 }, 0x01, 2);
    // b reads the first snapshot.
    _ = try b.w.beginReadTransaction();
    try expectPage(b.w, 2, 0x01);

    try commit(a.w, &ps, &.{2}, 0x02, 2);
    try expectPage(b.w, 2, 0x01);
    // b cannot write from an old snapshot.
    try testing.expectError(error.BusySnapshot, b.w.beginWriteTransaction());

    // A checkpoint cannot go past b's read mark; RESTART needs b gone.
    var n_log: i32 = -1;
    var n_ckpt: i32 = -1;
    try a.w.checkpoint(null, .passive, null, sync_full, &buf, &n_log, &n_ckpt);
    try testing.expectEqual(@as(i32, 3), n_log);
    try testing.expectEqual(@as(i32, 2), n_ckpt);
    try testing.expectError(error.Busy, a.w.checkpoint(null, .restart, null, sync_full, &buf, &n_log, &n_ckpt));
    b.w.endReadTransaction();

    try a.w.checkpoint(null, .truncate, null, sync_full, &buf, &n_log, &n_ckpt);
    try testing.expectEqual(@as(i32, 0), n_log);
    try testing.expectEqual(@as(i32, 0), n_ckpt);
    try testing.expectEqual(@as(u64, 0), try fileSize(v, "w.db-wal"));

    // After TRUNCATE the next writer starts over.
    try commit(b.w, &ps, &.{1}, 0x03, 2);
    _ = try a.w.beginReadTransaction();
    try expectPage(a.w, 1, 0x03);
    try testing.expectEqual(@as(u32, 0), try a.w.findFrame(2));
    a.w.endReadTransaction();

    // With a still connected, b cannot take the EXCLUSIVE lock needed to
    // checkpoint and delete the WAL on close.
    try a.w.close(null, sync_full, null);
    try testing.expectError(error.Busy, b.w.close(null, sync_full, &buf));
    a.db.close();
    try testing.expect(try v.access("w.db-wal", .exists));
}

test "wal: savepoint undo and overwritten frames" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    var ps: Pages = .{};
    const o = try openWal(v);
    defer o.db.close();
    try commit(o.w, &ps, &.{ 1, 2, 3 }, 0x01, 3);

    _ = try o.w.beginReadTransaction();
    try o.w.beginWriteTransaction();
    try o.w.frames(page_size, ps.list(&.{2}, 0x10), 0, false, sync_full);
    var sp: wal_mod.SavepointData = undefined;
    o.w.savepoint(&sp);
    try o.w.frames(page_size, ps.list(&.{3}, 0x10), 0, false, sync_full);
    try o.w.savepointUndo(&sp);
    // Page 2 is overwritten in place, and the commit rewrites checksums.
    try o.w.frames(page_size, ps.list(&.{ 1, 2 }, 0x20), 3, true, sync_full);
    o.w.endWriteTransaction();
    o.w.endReadTransaction();
    try o.w.close(null, sync_full, null);

    const o2 = try openWal(v);
    defer o2.db.close();
    _ = try o2.w.beginReadTransaction();
    try expectPage(o2.w, 1, 0x20);
    try expectPage(o2.w, 2, 0x20);
    try expectPage(o2.w, 3, 0x01);
    o2.w.endReadTransaction();
    try o2.w.close(null, sync_full, null);
}

test "wal: many frames span several wal-index pages" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    const v = mem.interface();
    var ps: Pages = .{};
    const o = try openWal(v);
    // 5000 single-page commits fill two hash tables.
    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        const pgno = 1 + i % 7;
        try commit(o.w, &ps, &.{pgno}, @truncate(i), 7);
    }
    _ = try o.w.beginReadTransaction();
    i = 5000 - 7;
    while (i < 5000) : (i += 1) try expectPage(o.w, 1 + i % 7, @truncate(i));
    o.w.endReadTransaction();
    try o.w.close(null, sync_full, null);
    o.db.close();

    // Recovery rebuilds both pages.
    const o2 = try openWal(v);
    defer o2.db.close();
    _ = try o2.w.beginReadTransaction();
    i = 5000 - 7;
    while (i < 5000) : (i += 1) try expectPage(o2.w, 1 + i % 7, @truncate(i));
    o2.w.endReadTransaction();
    var buf: [page_size]u8 = undefined;
    try o2.w.close(null, sync_full, &buf);
    const db = try v.open("w.db", .{});
    defer db.close();
    try db.read(&buf, 2 * page_size);
    try testing.expectEqual(@as(u8, @truncate(4993)) +% 3, buf[0]);
}

test "wal: shared memory on disk (unix)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = UnixVfs.init(testing.allocator, testing.io);
    u.dir = tmp.dir;
    const v = u.interface();
    var ps: Pages = .{};
    const a = try openWal(v);
    const b = try openWal(v);
    defer b.db.close();
    try commit(a.w, &ps, &.{ 1, 2 }, 0x01, 2);
    try testing.expect(try v.access("w.db-shm", .exists));
    _ = try b.w.beginReadTransaction();
    try expectPage(b.w, 2, 0x01);
    // Only one writer at a time.
    _ = try a.w.beginReadTransaction();
    try a.w.beginWriteTransaction();
    try testing.expectError(error.Busy, b.w.beginWriteTransaction());
    a.w.endWriteTransaction();
    a.w.endReadTransaction();
    b.w.endReadTransaction();
    try a.w.close(null, sync_full, null);
    a.db.close();
    var buf: [page_size]u8 = undefined;
    try b.w.close(null, sync_full, &buf);
    try testing.expect(!try v.access("w.db-wal", .exists));
    try testing.expect(!try v.access("w.db-shm", .exists));
}

test "wal: read-only shared memory falls back to a heap wal-index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = UnixVfs.init(testing.allocator, testing.io);
    u.dir = tmp.dir;
    const v = u.interface();
    var ps: Pages = .{};
    {
        const o = try openWal(v);
        defer o.db.close();
        try commit(o.w, &ps, &.{ 1, 2 }, 0x01, 2);
        try commit(o.w, &ps, &.{2}, 0x02, 2);
        // Close without a checkpoint: the WAL and -shm file stay.
        try o.w.close(null, sync_full, null);
    }
    try testing.expect(try v.access("w.db-shm", .exists));
    // Nobody can initialize the shared memory now (SQLITE_READONLY_CANTINIT):
    // the reader builds its own index from the WAL.
    if (std.c.fchmodat(tmp.dir.handle, "w.db-shm", 0o444, 0) != 0) return error.SkipZigTest;
    const o = try openWal(v);
    defer o.db.close();
    try testing.expect(try o.w.beginReadTransaction());
    try testing.expectEqual(@as(u32, 2), o.w.dbsize());
    try expectPage(o.w, 1, 0x01);
    try expectPage(o.w, 2, 0x02);
    try testing.expectError(error.ReadOnly, o.w.beginWriteTransaction());
    o.w.endReadTransaction();
    var buf: [page_size]u8 = undefined;
    try testing.expectError(error.ReadOnly, o.w.checkpoint(null, .passive, null, sync_full, &buf, null, null));
    try o.w.close(null, sync_full, null);
}
