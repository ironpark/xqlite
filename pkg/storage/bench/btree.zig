//! B-tree cursor benchmark: inserts, seeks, scans and deletes on a table
//! and an index b-tree, through the cursor API alone (no VDBE, no SQL),
//! on an in-memory file system with a cache that holds the whole
//! database, so that what it measures is the b-tree and the page cache.
//!
//!   btree-bench [-n ROWS] [-page-size BYTES]
//!
//! `zig build bench` in pkg/storage (or `zig build bench-btree` at the
//! root) builds it ReleaseFast and runs it. Each line is the best of a
//! few runs, with the time per operation and a checksum of what was read,
//! so that two builds can be compared for both speed and results.

const std = @import("std");
const storage = @import("xqlite_storage");
const MemVfs = @import("xqlite_vfs").mem.MemVfs;

const btree = storage.btree;
const record = storage.record;
const Btree = btree.Btree;
const Cursor = btree.Cursor;
const Pgno = btree.Pgno;
const Io = std.Io;

const reps = 3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var n: usize = 200_000;
    var page_size: u32 = 4096;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            n = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "-page-size") and i + 1 < args.len) {
            i += 1;
            page_size = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            std.debug.print("usage: btree-bench [-n ROWS] [-page-size BYTES]\n", .{});
            std.process.exit(1);
        }
    }

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    try w.print("# b-tree, {d} rows, {d}-byte pages\n", .{ n, page_size });

    // The keys in a random order, the same every run.
    const keys = try gpa.alloc(i64, n);
    defer gpa.free(keys);
    for (keys, 1..) |*k, j| k.* = @intCast(j);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().shuffle(i64, keys);

    var best: [names.len]u64 = @splat(std.math.maxInt(u64));
    var sums: [names.len]u64 = @splat(0);
    for (0..reps) |_| {
        var mem = MemVfs.init(gpa, io);
        defer mem.deinit();
        const bt = try Btree.open(gpa, mem.interface(), "bench.db", .{
            .page_size = page_size,
            .journal_mode = .off,
            .synchronous = .off,
            // KiB: enough for every page.
            .cache_size = -1024 * 1024,
        });
        defer bt.close(.{});
        var b: Bench = .{ .io = io, .bt = bt, .keys = keys, .best = &best, .sums = &sums };
        try b.runAll(gpa);
    }
    for (names, best, sums) |name, ns, sum| {
        const ms = @as(f64, @floatFromInt(ns)) / 1e6;
        const per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
        try w.print("{s:<22} {d:>8.1} ms {d:>7.1} ns/op  {x:0>16}\n", .{ name, ms, per_op, sum });
    }
    try w.flush();
}

const names = [_][]const u8{
    "table insert seq",
    "table insert random",
    "table seek random",
    "table scan",
    "table scan backwards",
    "table delete half",
    "index insert random",
    "index seek random",
    "index scan",
    "index delete half",
};

const Bench = struct {
    io: Io,
    bt: *Btree,
    keys: []const i64,
    best: *[names.len]u64,
    sums: *[names.len]u64,
    i_bench: usize = 0,
    start: Io.Timestamp = undefined,

    fn begin(b: *Bench) void {
        b.start = Io.Clock.awake.now(b.io);
    }

    /// End the current benchmark, keeping its best time and its checksum.
    fn end(b: *Bench, sum: u64) void {
        const ns: u64 = @intCast(b.start.durationTo(Io.Clock.awake.now(b.io)).toNanoseconds());
        b.best[b.i_bench] = @min(b.best[b.i_bench], ns);
        b.sums[b.i_bench] = sum;
        b.i_bench += 1;
    }

    fn runAll(b: *Bench, gpa: std.mem.Allocator) !void {
        const bt = b.bt;
        const n = b.keys.len;
        var data: [100]u8 = undefined;
        try bt.beginTrans(.write, 0);

        // Tables: rows of 20 to 100 bytes.
        const seq_root = try bt.createTable(.intkey);
        const root = try bt.createTable(.intkey);
        var cur: Cursor = undefined;
        {
            try bt.cursor(&cur, seq_root, .{ .write = true });
            defer cur.close();
            b.begin();
            for (1..n + 1) |k| {
                const row = rowData(&data, @intCast(k));
                try cur.insert(.{ .rowid = @intCast(k), .data = row }, .{ .append = true });
            }
            b.end(n);
        }
        try bt.cursor(&cur, root, .{ .write = true });
        defer cur.close();
        b.begin();
        for (b.keys) |k| try cur.insert(.{ .rowid = k, .data = rowData(&data, k) }, .{});
        b.end(n);

        b.begin();
        var sum: u64 = 0;
        for (b.keys) |k| {
            if (try cur.tableMoveto(k, false) != .eq) return error.Missing;
            sum +%= cur.payloadSize();
        }
        b.end(sum);

        b.begin();
        sum = try scan(&cur, .forward);
        b.end(sum);
        b.begin();
        sum = try scan(&cur, .backward);
        b.end(sum);

        b.begin();
        for (b.keys[0 .. n / 2]) |k| {
            if (try cur.tableMoveto(k, false) != .eq) return error.Missing;
            try cur.delete(.{});
        }
        b.end(@intCast(try cur.count()));

        // An index of (text, integer) keys, as CREATE INDEX on a text
        // column makes.
        const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };
        const idx_root = try bt.createTable(.blobkey);
        var icur: Cursor = undefined;
        try bt.cursor(&icur, idx_root, .{ .write = true, .key_info = ki.btreeKeyInfo() });
        defer icur.close();
        var text_buf: [32]u8 = undefined;
        var key_buf: [64]u8 = undefined;
        b.begin();
        for (b.keys) |k| {
            const values = [_]record.Value{ .{ .text = indexText(&text_buf, k) }, .{ .int = k } };
            try icur.insert(.{ .key = record.encodeBuf(&values, &key_buf) }, .{});
        }
        b.end(n);

        b.begin();
        sum = 0;
        for (b.keys) |k| {
            const values = [_]record.Value{ .{ .text = indexText(&text_buf, k) }, .{ .int = k } };
            const search: record.UnpackedRecord = .{ .info = &ki, .values = &values };
            if (try icur.indexMoveto(search.indexKey()) != .eq) return error.Missing;
            sum +%= icur.payloadSize();
        }
        b.end(sum);

        b.begin();
        sum = try scan(&icur, .forward);
        b.end(sum);

        b.begin();
        for (b.keys[0 .. n / 2]) |k| {
            const values = [_]record.Value{ .{ .text = indexText(&text_buf, k) }, .{ .int = k } };
            const search: record.UnpackedRecord = .{ .info = &ki, .values = &values };
            if (try icur.indexMoveto(search.indexKey()) != .eq) return error.Missing;
            try icur.delete(.{});
        }
        b.end(@intCast(try icur.count()));

        try bt.commit();
    }
};

/// Read every entry of `cur` in one direction, hashing the start of each.
fn scan(cur: *Cursor, dir: enum { forward, backward }) !u64 {
    var h: u64 = 0xcbf29ce484222325;
    var buf: [8]u8 = undefined;
    var ok = if (dir == .forward) try cur.first() else try cur.last();
    while (ok) : (ok = if (dir == .forward) try cur.next() else try cur.previous()) {
        const len = @min(cur.payloadSize(), buf.len);
        try cur.payload(0, buf[0..len]);
        for (buf[0..len]) |c| h = (h ^ c) *% 0x100000001b3;
    }
    return h;
}

/// The row of rowid `k`: 20 to 100 bytes that depend on it.
fn rowData(buf: *[100]u8, k: i64) []const u8 {
    const u: u64 = @bitCast(k);
    const len = 20 + u % 81;
    for (buf[0..len], 0..) |*c, j| c.* = @truncate(u *% 31 +% j);
    return buf[0..len];
}

/// The text column of the index key of `k`: in a different order than k.
fn indexText(buf: *[32]u8, k: i64) []const u8 {
    const u: u64 = @bitCast(k);
    return std.fmt.bufPrint(buf, "key-{x:0>8}", .{(u *% 0x9e3779b1) & 0xffffffff}) catch unreachable;
}
