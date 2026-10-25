const std = @import("std");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const btree = @import("btree.zig");
const record = @import("../vdbe/record.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Btree = btree.Btree;
const Cursor = btree.Cursor;
const Pgno = btree.Pgno;
const Value = record.Value;

const db_name = "test.db";

/// An in-memory file system holding one database.
const Env = struct {
    mem: MemVfs,

    fn init() Env {
        return .{ .mem = MemVfs.init(gpa, testing.io) };
    }

    fn deinit(e: *Env) void {
        e.mem.deinit();
    }

    fn open(e: *Env, opts: btree.Options) !*Btree {
        return Btree.open(gpa, e.mem.interface(), db_name, opts);
    }

    /// Makes `bytes` the content of the database file.
    fn load(e: *Env, bytes: []const u8) !void {
        const f = try e.mem.interface().open(db_name, .{ .create = true });
        defer f.close();
        try f.write(bytes, 0);
    }
};

// ============================================================== payloads

/// Payload length for a rowid. Every 13th row overflows onto several pages.
fn payloadLen(rowid: i64) usize {
    const r: usize = @intCast(rowid);
    if (r % 13 == 0) return 3000 + (r % 7) * 1000;
    return r % 100;
}

fn fillPayload(buf: []u8, rowid: i64) void {
    const seed: u64 = @bitCast(rowid);
    for (buf, 0..) |*b, i| b.* = @truncate(seed *% 31 +% i);
    // The integrity check expects a record, whose header size is >= 2.
    if (buf.len > 0) buf[0] |= 2;
}

fn insertRow(cur: *Cursor, rowid: i64) !void {
    var buf: [10000]u8 = undefined;
    const data = buf[0..payloadLen(rowid)];
    fillPayload(data, rowid);
    try cur.insert(.{ .rowid = rowid, .data = data }, .{});
}

fn expectRow(cur: *Cursor, rowid: i64) !void {
    try testing.expectEqual(rowid, cur.integerKey());
    const len = payloadLen(rowid);
    try testing.expectEqual(len, cur.payloadSize());
    var got: [10000]u8 = undefined;
    var want: [10000]u8 = undefined;
    try cur.payload(0, got[0..len]);
    fillPayload(want[0..len], rowid);
    try testing.expectEqualSlices(u8, want[0..len], got[0..len]);
    // A read starting inside the overflow chain.
    if (len > 2000) {
        try cur.payload(1500, got[0..100]);
        try testing.expectEqualSlices(u8, want[1500..1600], got[0..100]);
    }
}

fn shuffled(comptime n: usize, seed: u64) [n]i64 {
    var keys: [n]i64 = undefined;
    for (&keys, 1..) |*k, i| k.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(i64, &keys);
    return keys;
}

/// Runs the integrity check over `roots` (plus page 1) and fails with the
/// report if anything is wrong.
fn expectIntact(bt: *Btree, roots: []const Pgno) !void {
    var all: [8]Pgno = undefined;
    all[0] = 1;
    @memcpy(all[1..][0..roots.len], roots);
    var report = try bt.integrityCheck(gpa, all[0 .. roots.len + 1], 100);
    defer report.deinit(gpa);
    if (report.n_err != 0) {
        std.debug.print("integrity check:\n{s}\n", .{report.message});
        return error.TestUnexpectedResult;
    }
}

/// Checks that table `root` holds exactly the rows marked in `present`
/// (indexed by rowid).
fn expectTable(bt: *Btree, root: Pgno, present: []const bool) !void {
    var cur: Cursor = undefined;
    try bt.cursor(&cur, root, .{});
    defer cur.close();
    var n: i64 = 0;
    var ok = try cur.first();
    var expect: i64 = 0;
    while (ok) : (ok = try cur.next()) {
        expect += 1;
        while (!present[@intCast(expect)]) expect += 1;
        try expectRow(&cur, expect);
        n += 1;
    }
    var total: i64 = 0;
    for (present) |p| total += @intFromBool(p);
    try testing.expectEqual(total, n);
    try testing.expectEqual(total, try cur.count());
}

// ================================================================= tables

test "btree: rows inserted in random order read back in order" {
    inline for (.{ 512, 1024, 4096, 65536 }) |page_size| {
        var env = Env.init();
        defer env.deinit();
        const bt = try env.open(.{ .page_size = page_size });
        defer bt.close();

        const n = 1200;
        try bt.beginTrans(.write);
        const root = try bt.createTable(.intkey);
        {
            var cur: Cursor = undefined;
            try bt.cursor(&cur, root, .{ .write = true });
            defer cur.close();
            for (shuffled(n, page_size)) |k| try insertRow(&cur, k);
        }
        try bt.commit();

        try bt.beginTrans(.read);
        defer bt.commit() catch unreachable;
        var present: [n + 2]bool = @splat(true);
        present[0] = false;
        present[n + 1] = false;
        try expectTable(bt, root, &present);
        try expectIntact(bt, &.{root});

        var cur: Cursor = undefined;
        try bt.cursor(&cur, root, .{});
        defer cur.close();
        for (shuffled(n, 7)[0..100]) |k| {
            try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(k, false));
            try expectRow(&cur, k);
        }
        try testing.expectEqual(std.math.Order.lt, try cur.tableMoveto(n + 10, false));
        try testing.expectEqual(@as(i64, n), cur.integerKey());
        try testing.expectEqual(std.math.Order.gt, try cur.tableMoveto(0, false));
        try testing.expectEqual(@as(i64, 1), cur.integerKey());
        try testing.expect(try cur.last());
        try testing.expectEqual(@as(i64, n), cur.integerKey());
        try testing.expect(try cur.previous());
        try testing.expectEqual(@as(i64, n - 1), cur.integerKey());
    }
}

test "btree: deletes shrink the tree and recycle pages" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 512 });
    defer bt.close();

    const n = 1500;
    var present: [n + 2]bool = @splat(false);
    try bt.beginTrans(.write);
    const root = try bt.createTable(.intkey);
    var cur: Cursor = undefined;
    try bt.cursor(&cur, root, .{ .write = true });
    for (shuffled(n, 1)) |k| {
        try insertRow(&cur, k);
        present[@intCast(k)] = true;
    }

    // Delete in random order, checking the tree along the way.
    for (shuffled(n, 2), 0..) |k, i| {
        try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(k, false));
        try cur.delete(.{});
        present[@intCast(k)] = false;
        if (i % 300 == 299) {
            cur.close();
            try expectTable(bt, root, &present);
            try expectIntact(bt, &.{root});
            try bt.cursor(&cur, root, .{ .write = true });
        }
    }
    try testing.expect(try cur.isEmpty());
    const pages = bt.lastPage();
    try testing.expect(bt.getMeta(.free_page_count) > pages / 2);

    // Inserting again reuses the freelist instead of growing the file.
    for (shuffled(n, 3)) |k| try insertRow(&cur, k);
    cur.close();
    // A different insertion order may need a few more pages.
    try testing.expectEqual(@as(u32, 0), bt.getMeta(.free_page_count));
    try testing.expect(bt.lastPage() <= pages + pages / 50);
    try expectIntact(bt, &.{root});
    try bt.commit();
}

test "btree: delete with save_position while scanning" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 1024 });
    defer bt.close();

    const n = 800;
    var present: [n + 2]bool = @splat(false);
    try bt.beginTrans(.write);
    const root = try bt.createTable(.intkey);
    var cur: Cursor = undefined;
    try bt.cursor(&cur, root, .{ .write = true });
    for (1..n + 1) |k| {
        try insertRow(&cur, @intCast(k));
        present[k] = true;
    }

    // Delete every row whose rowid is not a multiple of 3, stepping forward
    // after each delete as a DELETE statement would.
    var ok = try cur.first();
    while (ok) {
        const k = cur.integerKey();
        if (@mod(k, 3) != 0) {
            try cur.delete(.{ .save_position = true });
            present[@intCast(k)] = false;
        }
        ok = try cur.next();
    }
    cur.close();
    try expectTable(bt, root, &present);
    try expectIntact(bt, &.{root});
    try bt.commit();
}

test "btree: rollback restores pages and cursor positions" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 512 });
    defer bt.close();

    const n = 600;
    var present: [n + 2]bool = @splat(false);
    try bt.beginTrans(.write);
    const root = try bt.createTable(.intkey);
    {
        var cur: Cursor = undefined;
        try bt.cursor(&cur, root, .{ .write = true });
        defer cur.close();
        for (shuffled(n, 4)) |k| {
            try insertRow(&cur, k);
            present[@intCast(k)] = true;
        }
    }
    try bt.commit();
    const pages = bt.lastPage();

    try bt.beginTrans(.write);
    var reader: Cursor = undefined;
    try bt.cursor(&reader, root, .{});
    try testing.expectEqual(std.math.Order.eq, try reader.tableMoveto(300, false));
    {
        var cur: Cursor = undefined;
        try bt.cursor(&cur, root, .{ .write = true });
        defer cur.close();
        for (shuffled(n, 5)[0..400]) |k| {
            _ = try cur.tableMoveto(k, false);
            try cur.delete(.{});
        }
        for (n + 1..n + 300) |k| try insertRow(&cur, @intCast(k));
    }
    // The reader was saved before the first change and survives.
    try testing.expect(reader.hasMoved());
    try bt.rollback(null, false);
    try bt.beginTrans(.read);
    try testing.expect(!try reader.restore());
    try expectRow(&reader, 300);
    reader.close();

    try expectTable(bt, root, &present);
    try expectIntact(bt, &.{root});
    try testing.expectEqual(pages, bt.lastPage());
    try bt.commit();
}

test "btree: replacing rows, in place and resized" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 1024 });
    defer bt.close();

    try bt.beginTrans(.write);
    const root = try bt.createTable(.intkey);
    var cur: Cursor = undefined;
    try bt.cursor(&cur, root, .{ .write = true });
    defer cur.close();
    for (1..200) |k| try insertRow(&cur, @intCast(k));

    // Same size: overwritten in place, also across overflow pages.
    var buf: [10000]u8 = undefined;
    for ([_]i64{ 26, 50 }) |k| {
        const len = payloadLen(k);
        @memset(buf[0..len], 0xab);
        try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(k, false));
        try cur.insert(.{ .rowid = k, .data = buf[0 .. len - 10], .n_zero = 10 }, .{});
        try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(k, false));
        var got: [10000]u8 = undefined;
        try cur.payload(0, got[0..len]);
        try testing.expect(std.mem.allEqual(u8, got[0 .. len - 10], 0xab));
        try testing.expect(std.mem.allEqual(u8, got[len - 10 .. len], 0));
    }
    // A different size: the cell is replaced.
    try cur.insert(.{ .rowid = 60, .data = "short" }, .{});
    try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(60, false));
    try testing.expectEqualStrings("short", cur.payloadFetch());
    try testing.expectEqual(@as(i64, 199), try cur.count());
    try expectIntact(bt, &.{root});
    try bt.rollback(null, false);
}

test "btree: two cursors on one table" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 512 });
    defer bt.close();

    try bt.beginTrans(.write);
    const root = try bt.createTable(.intkey);
    var writer: Cursor = undefined;
    try bt.cursor(&writer, root, .{ .write = true });
    defer writer.close();
    var reader: Cursor = undefined;
    try bt.cursor(&reader, root, .{});
    defer reader.close();

    for (1..300) |k| try insertRow(&writer, @intCast(2 * k));
    try testing.expectEqual(std.math.Order.eq, try reader.tableMoveto(100, false));
    // Inserting through one cursor saves the other's position.
    for (1..300) |k| try insertRow(&writer, @intCast(2 * k + 1));
    try testing.expect(reader.hasMoved());
    try testing.expect(try reader.next());
    try expectRow(&reader, 101);
    // Deleting the row the reader is on moves it to a neighbour.
    try testing.expectEqual(std.math.Order.eq, try writer.tableMoveto(101, false));
    try writer.delete(.{});
    try testing.expect(try reader.restore());
    try bt.rollback(null, false);
}

test "btree: clear and drop tables, meta values" {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 512 });
    defer bt.close();

    try bt.beginTrans(.write);
    const t1 = try bt.createTable(.intkey);
    const t2 = try bt.createTable(.intkey);
    inline for (.{ t1, t2 }) |root| {
        var cur: Cursor = undefined;
        try bt.cursor(&cur, root, .{ .write = true });
        defer cur.close();
        for (1..400) |k| try insertRow(&cur, @intCast(k));
    }
    try testing.expectEqual(@as(i64, 399), try bt.clearTable(t1));
    try bt.dropTable(t2);
    try expectIntact(bt, &.{t1});
    try bt.updateMeta(.user_version, 42);
    try bt.updateMeta(.schema_version, 7);
    try bt.commit();

    try bt.beginTrans(.read);
    try testing.expectEqual(@as(u32, 42), bt.getMeta(.user_version));
    try testing.expectEqual(@as(u32, 7), bt.getMeta(.schema_version));
    try testing.expect(bt.getMeta(.free_page_count) > 10);
    const version = bt.getMeta(.data_version);
    try bt.commit();
    // Our own commits do not change the data version.
    try bt.beginTrans(.read);
    try testing.expectEqual(version, bt.getMeta(.data_version));
    try bt.commit();
}

// ================================================================ indexes

fn indexKeyText(buf: []u8, i: usize, wide: bool) []const u8 {
    // Wide keys do not fit on a 512-byte page and overflow.
    const pad: usize = if (wide and i % 4 == 0) 300 else 0;
    const head = std.fmt.bufPrint(buf, "key-{d:0>6}-", .{(i * 7919) % 100000}) catch unreachable;
    @memset(buf[head.len..][0..pad], 'z');
    return buf[0 .. head.len + pad];
}

test "btree: index b-tree with record keys" {
    inline for (.{ false, true }) |wide| {
        var env = Env.init();
        defer env.deinit();
        const bt = try env.open(.{ .page_size = 512 });
        defer bt.close();
        const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };

        const n = 700;
        try bt.beginTrans(.write);
        const root = try bt.createTable(.blobkey);
        var cur: Cursor = undefined;
        try bt.cursor(&cur, root, .{ .write = true, .key_info = ki.btreeKeyInfo() });
        var cur_open = true;
        defer if (cur_open) cur.close();
        var text_buf: [400]u8 = undefined;
        for (shuffled(n, 9)) |k| {
            const i: usize = @intCast(k);
            const key = try record.encodeAlloc(gpa, &.{ .{ .text = indexKeyText(&text_buf, i, wide) }, .{ .int = k } });
            defer gpa.free(key);
            try cur.insert(.{ .key = key }, .{});
        }
        try expectIntact(bt, &.{root});

        // A scan returns the keys in order.
        var prev: ?[]u8 = null;
        defer if (prev) |p| gpa.free(p);
        var count: usize = 0;
        var ok = try cur.first();
        while (ok) : (ok = try cur.next()) {
            const key = try gpa.alloc(u8, cur.payloadSize());
            try cur.payload(0, key);
            if (prev) |p| {
                const r: record.UnpackedRecord = .{ .info = &ki, .values = &try decodeKey(p) };
                try testing.expectEqual(std.math.Order.gt, try r.compare(key));
                gpa.free(p);
            }
            prev = key;
            count += 1;
        }
        try testing.expectEqual(@as(usize, n), count);

        // Seek by the text column alone and delete half the entries.
        for (shuffled(n, 10)[0 .. n / 2]) |k| {
            const i: usize = @intCast(k);
            const search: record.UnpackedRecord = .{ .info = &ki, .values = &.{.{ .text = indexKeyText(&text_buf, i, wide) }} };
            try testing.expectEqual(std.math.Order.eq, try cur.indexMoveto(search.indexKey()));
            var key_buf: [600]u8 = undefined;
            const key = key_buf[0..cur.payloadSize()];
            try cur.payload(0, key);
            try testing.expectEqual(k, (try decodeKey(key))[1].int);
            try cur.delete(.{});
        }
        try testing.expectEqual(@as(i64, n / 2), try cur.count());
        cur.close();
        cur_open = false;
        try expectIntact(bt, &.{root});
        try bt.commit();
    }
}

fn decodeKey(key: []const u8) ![2]Value {
    var v: [2]Value = undefined;
    try testing.expectEqual(@as(usize, 2), try record.decode(key, &v));
    return v;
}

// =============================================================== fixtures

const Schema = struct { table: Pgno, index: Pgno };

/// Reads the root pages of t and t_b from sqlite_schema.
fn readSchema(bt: *Btree) !Schema {
    var s: Schema = .{ .table = 0, .index = 0 };
    var cur: Cursor = undefined;
    try bt.cursor(&cur, 1, .{});
    defer cur.close();
    var ok = try cur.first();
    while (ok) : (ok = try cur.next()) {
        var v: [5]Value = undefined;
        try testing.expectEqual(@as(usize, 5), try record.decode(cur.payloadFetch(), &v));
        const r: Pgno = @intCast(v[3].int);
        if (std.mem.eql(u8, v[1].text, "t")) s.table = r;
        if (std.mem.eql(u8, v[1].text, "t_b")) s.index = r;
    }
    return s;
}

/// Checks one row of the fixture table against tools/gen-fixtures.sh.
fn expectFixtureRow(cur: *Cursor, i: i64) !void {
    try testing.expectEqual(i, cur.integerKey());
    const data = try gpa.alloc(u8, cur.payloadSize());
    defer gpa.free(data);
    try cur.payload(0, data);
    var v: [4]Value = undefined;
    try testing.expectEqual(@as(usize, 4), try record.decode(data, &v));
    // The INTEGER PRIMARY KEY is stored as NULL.
    try testing.expectEqual(Value.null, v[0]);
    var buf: [16]u8 = undefined;
    const b = try std.fmt.bufPrint(&buf, "row-{d:0>5}", .{@as(u64, @intCast(@mod(i * 7919, 1000)))});
    try testing.expectEqualStrings(b, v[1].text);
    if (@mod(i, 97) == 0) {
        const len: usize = @intCast(2000 + i);
        try testing.expectEqual(len, v[2].blob.len);
        const ch: u8 = @intCast(65 + @mod(i, 26));
        try testing.expect(std.mem.allEqual(u8, v[2].blob, ch));
    } else {
        const s = try std.fmt.bufPrint(&buf, "{d}", .{i * i});
        try testing.expectEqualStrings(s, v[2].text);
    }
    // REAL values that are whole numbers are stored as integers.
    const d: f64 = switch (v[3]) {
        .real => |r| r,
        .int => |n| @floatFromInt(n),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(f64, @floatFromInt(i)) * 0.5, d);
}

fn fixtureRowExists(i: i64) bool {
    return i >= 1 and i <= 1000 and @mod(i, 5) != 0 and !(i >= 300 and i <= 420);
}

test "btree: reads a database written by sqlite3" {
    var env = Env.init();
    defer env.deinit();
    try env.load(@embedFile("../testdata/btree.db"));
    const bt = try env.open(.{});
    defer bt.close();

    try bt.beginTrans(.read);
    // Runs after the cursors below are closed.
    defer bt.commit() catch unreachable;
    try testing.expectEqual(@as(u32, 1024), bt.getPageSize());
    const s = try readSchema(bt);
    try expectIntact(bt, &.{ s.table, s.index });

    var cur: Cursor = undefined;
    try bt.cursor(&cur, s.table, .{});
    defer cur.close();
    var expect: i64 = 0;
    var ok = try cur.first();
    while (ok) : (ok = try cur.next()) {
        expect += 1;
        while (!fixtureRowExists(expect)) expect += 1;
        try expectFixtureRow(&cur, expect);
    }
    try testing.expectEqual(@as(i64, 999), expect);
    try testing.expectEqual(@as(i64, 704), try cur.count());

    // Look a row up through the index on b.
    const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };
    var idx: Cursor = undefined;
    try bt.cursor(&idx, s.index, .{ .key_info = ki.btreeKeyInfo() });
    defer idx.close();
    const search: record.UnpackedRecord = .{ .info = &ki, .values = &.{.{ .text = "row-00042" }} };
    try testing.expectEqual(std.math.Order.eq, try idx.indexMoveto(search.indexKey()));
    const key = try decodeKey(idx.payloadFetch());
    // 7919*i = 42 (mod 1000) for i = 518.
    try testing.expectEqual(@as(i64, 518), key[1].int);
    try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(key[1].int, false));
    try expectFixtureRow(&cur, 518);
}

test "btree: modifies a database written by sqlite3" {
    var env = Env.init();
    defer env.deinit();
    try env.load(@embedFile("../testdata/btree.db"));
    const bt = try env.open(.{});
    defer bt.close();

    try bt.beginTrans(.write);
    const s = try readSchema(bt);
    var cur: Cursor = undefined;
    try bt.cursor(&cur, s.table, .{ .write = true });
    // Delete every third row, then add rows past the end.
    var ok = try cur.first();
    while (ok) {
        if (@mod(cur.integerKey(), 3) == 0) try cur.delete(.{ .save_position = true });
        ok = try cur.next();
    }
    var buf: [100]u8 = undefined;
    for (1001..1300) |i| {
        const values = [_]Value{ .null, .{ .int = @intCast(i) } };
        try cur.insert(.{ .rowid = @intCast(i), .data = record.encodeBuf(&values, &buf) }, .{ .append = true });
    }
    cur.close();
    try expectIntact(bt, &.{ s.table, s.index });
    try bt.commit();
}

test "btree: auto-vacuum databases open read-only" {
    var env = Env.init();
    defer env.deinit();
    try env.load(@embedFile("../testdata/autovacuum.db"));
    const bt = try env.open(.{});
    defer bt.close();

    try bt.beginTrans(.read);
    const s = try readSchema(bt);
    // The pointer map is checked too.
    try expectIntact(bt, &.{ s.table, s.index });
    var cur: Cursor = undefined;
    try bt.cursor(&cur, s.table, .{});
    try testing.expectEqual(@as(i64, 704), try cur.count());
    cur.close();
    try bt.commit();
    try testing.expectError(error.ReadOnly, bt.beginTrans(.write));
}

test "btree: corrupt pages are reported, not trusted" {
    var env = Env.init();
    defer env.deinit();
    const fixture = @embedFile("../testdata/btree.db");
    var bytes = try gpa.dupe(u8, fixture);
    defer gpa.free(bytes);
    // Page 2 (the table root): claim a cell pointer past the page end.
    const off = 1024 + 8 + 4; // interior header, first cell pointer
    std.mem.writeInt(u16, bytes[off..][0..2], 1030, .big);
    try env.load(bytes);
    const bt = try env.open(.{});
    defer bt.close();

    try bt.beginTrans(.read);
    var report = try bt.integrityCheck(gpa, &.{ 1, 2, 3 }, 10);
    defer report.deinit(gpa);
    try testing.expect(report.n_err > 0);
    try testing.expect(std.mem.indexOf(u8, report.message, "Tree 2 page 2 cell 0: Offset 1030 out of range") != null);
    try bt.commit();
}

// ================================================================ stress

/// Random inserts, replacements and deletes on a table and an index of the
/// same rows, checked against a model. Commits and rollbacks are mixed in,
/// and a tiny cache forces the pager to spill pages mid-transaction.
fn randomOps(page_size: u32, secure_delete: btree.SecureDelete, seed: u64) !void {
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = page_size, .cache_size = 10, .secure_delete = secure_delete });
    defer bt.close();
    const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };

    const n_keys = 400;
    // Model: the payload length of each rowid, or null if absent. The index
    // holds (length, rowid) for every row.
    var model: [n_keys]?u32 = @splat(null);
    var committed = model;

    try bt.beginTrans(.write);
    const t_root = try bt.createTable(.intkey);
    const i_root = try bt.createTable(.blobkey);
    try bt.commit();

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var buf: [6000]u8 = undefined;
    for (0..30) |round| {
        try bt.beginTrans(.write);
        {
            var tc: Cursor = undefined;
            try bt.cursor(&tc, t_root, .{ .write = true });
            defer tc.close();
            var ic: Cursor = undefined;
            try bt.cursor(&ic, i_root, .{ .write = true, .key_info = ki.btreeKeyInfo() });
            defer ic.close();

            for (0..60) |_| {
                const k = rand.uintLessThan(u32, n_keys);
                const rowid: i64 = k + 1;
                if (model[k]) |len| {
                    // Remove the index entry, then delete or replace the row.
                    const key: record.UnpackedRecord = .{ .info = &ki, .values = &.{ .{ .int = len }, .{ .int = rowid } } };
                    try testing.expectEqual(std.math.Order.eq, try ic.indexMoveto(key.indexKey()));
                    try ic.delete(.{});
                    try testing.expectEqual(std.math.Order.eq, try tc.tableMoveto(rowid, false));
                    if (rand.boolean()) {
                        try tc.delete(.{});
                        model[k] = null;
                        continue;
                    }
                }
                const len: u32 = if (rand.uintLessThan(u32, 8) == 0) rand.uintLessThan(u32, 6000) else rand.uintLessThan(u32, 200);
                fillPayload(buf[0..len], rowid);
                try tc.insert(.{ .rowid = rowid, .data = buf[0..len] }, .{});
                var key_buf: [32]u8 = undefined;
                const values = [_]Value{ .{ .int = len }, .{ .int = rowid } };
                try ic.insert(.{ .key = record.encodeBuf(&values, &key_buf) }, .{});
                model[k] = len;
            }
        }
        if (round % 4 == 3) {
            try bt.rollback(null, false);
            model = committed;
        } else {
            try bt.commit();
            committed = model;
        }

        try bt.beginTrans(.read);
        defer bt.commit() catch unreachable;
        try expectIntact(bt, &.{ t_root, i_root });
        var tc: Cursor = undefined;
        try bt.cursor(&tc, t_root, .{});
        defer tc.close();
        var expected: i64 = 0;
        for (model, 1..) |m, rowid| {
            if (m) |len| {
                expected += 1;
                try testing.expectEqual(std.math.Order.eq, try tc.tableMoveto(@intCast(rowid), false));
                try testing.expectEqual(len, tc.payloadSize());
                var got: [6000]u8 = undefined;
                try tc.payload(0, got[0..len]);
                fillPayload(buf[0..len], @intCast(rowid));
                try testing.expectEqualSlices(u8, buf[0..len], got[0..len]);
            }
        }
        try testing.expectEqual(expected, try tc.count());
        var ic: Cursor = undefined;
        try bt.cursor(&ic, i_root, .{ .key_info = ki.btreeKeyInfo() });
        defer ic.close();
        try testing.expectEqual(expected, try ic.count());
    }
}

test "btree: random operations match a model" {
    try randomOps(512, .off, 1);
    try randomOps(1024, .on, 2);
    try randomOps(4096, .fast, 3);
}

test "btree: page 1 as a table root grows and shrinks" {
    // Page 1 starts with the 100-byte file header, so it holds less than
    // its children; growing it pushes content down, and shrinking must copy
    // a child back only if it fits (else page 1 stays a "virtual root").
    var env = Env.init();
    defer env.deinit();
    const bt = try env.open(.{ .page_size = 512 });
    defer bt.close();

    const n = 500;
    var present: [n + 2]bool = @splat(false);
    try bt.beginTrans(.write);
    var cur: Cursor = undefined;
    try bt.cursor(&cur, 1, .{ .write = true });
    for (shuffled(n, 11)) |k| {
        try insertRow(&cur, k);
        present[@intCast(k)] = true;
    }
    cur.close();
    try expectIntact(bt, &.{});
    try expectTable(bt, 1, &present);

    try bt.cursor(&cur, 1, .{ .write = true });
    for (shuffled(n, 12), 0..) |k, i| {
        try testing.expectEqual(std.math.Order.eq, try cur.tableMoveto(k, false));
        try cur.delete(.{});
        present[@intCast(k)] = false;
        if (i % 50 == 49 or n - i < 10) {
            cur.close();
            try expectIntact(bt, &.{});
            try expectTable(bt, 1, &present);
            try bt.cursor(&cur, 1, .{ .write = true });
        }
    }
    try testing.expect(try cur.isEmpty());
    cur.close();
    try bt.commit();
}
