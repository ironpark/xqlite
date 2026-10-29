//! Seeded fuzzers of the b-tree layer, run by `zig build fuzz` (see
//! src/fuzz_tests.zig) and, with few events, by `zig build test`.
//!
//! - `model`: random inserts, replacements and deletes on a table and an
//!   index of the same rows, in transactions that commit or roll back,
//!   checked against a model after every transaction.
//! - `corrupt`: random bytes of a valid database overwritten, then the
//!   database read, checked and changed. Any error is fine; a crash, a
//!   failed assertion or a leak is not.

const std = @import("std");
const btree = @import("btree.zig");
const record = @import("../vdbe/record.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const fuzz = @import("../testing/fuzz.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Btree = btree.Btree;
const Cursor = btree.Cursor;
const Pgno = btree.Pgno;
const Value = record.Value;

const db_name = "fuzz.db";

/// Payload bytes for a rowid, so that reads can be checked.
pub fn fillPayload(buf: []u8, rowid: i64) void {
    const seed: u64 = @bitCast(rowid);
    for (buf, 0..) |*b, i| b.* = @truncate(seed *% 31 +% i);
    // The integrity check expects a record, whose header size is >= 2.
    if (buf.len > 0) buf[0] |= 2;
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) error{ModelMismatch}!void {
    if (ok) return;
    std.debug.print("btree fuzz: " ++ fmt ++ "\n", args);
    return error.ModelMismatch;
}

// =================================================================== model

pub const ModelConfig = struct {
    page_size: u32,
    /// Small caches make the pager spill pages mid-transaction.
    cache_size: i32,
    secure_delete: btree.SecureDelete,
    auto_vacuum: btree.AutoVacuum,
    /// Rowids are 1..n_keys: few keys mean more replacements and deletes.
    n_keys: u32,
    /// Out of 256: rows big enough to overflow, transactions rolled back.
    overflow_chance: u8,
    rollback_chance: u8,
    /// Operations in each transaction, and how often each kind comes up.
    transaction_size: u32,
    op_weights: std.enums.EnumArray(ModelOp, u32),

    fn random(rand: std.Random) ModelConfig {
        const page_sizes = [_]u32{ 512, 1024, 4096, 65536 };
        const n_keys = [_]u32{ 10, 400, 3000 };
        return .{
            .page_size = page_sizes[rand.uintLessThan(usize, page_sizes.len)],
            .cache_size = if (rand.boolean()) 10 else -2000,
            .secure_delete = rand.enumValue(btree.SecureDelete),
            .auto_vacuum = rand.enumValue(btree.AutoVacuum),
            .n_keys = n_keys[rand.uintLessThan(usize, n_keys.len)],
            .overflow_chance = rand.int(u8) / 2,
            .rollback_chance = rand.int(u8) / 2,
            .transaction_size = rand.intRangeAtMost(u32, 1, 200),
            .op_weights = opWeights(rand),
        };
    }
};

pub const ModelOp = enum { put, delete };

/// Swarm weights that keep `put` on: without inserts nothing happens.
fn opWeights(rand: std.Random) std.enums.EnumArray(ModelOp, u32) {
    var w = fuzz.randomEnumWeights(rand, ModelOp);
    if (w.get(.put) == 0) w.set(.put, rand.intRangeAtMost(u32, 1, 100));
    return w;
}

/// The `model` fuzzer with a configuration drawn from `seed`.
pub fn model(gpa: Allocator, io: Io, seed: u64, events_max: u32) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const config: ModelConfig = .random(prng.random());
    if (!@import("builtin").is_test) std.debug.print("model config: {any}\n", .{config});
    return modelWith(gpa, io, prng.random(), config, events_max);
}

pub fn modelWith(gpa: Allocator, io: Io, rand: std.Random, config: ModelConfig, events_max: u32) !void {
    var mem = MemVfs.init(gpa, io);
    defer mem.deinit();
    const bt = try Btree.open(gpa, mem.interface(), db_name, .{
        .page_size = config.page_size,
        .cache_size = config.cache_size,
        .secure_delete = config.secure_delete,
        .auto_vacuum = config.auto_vacuum,
    });
    defer bt.close(.{});
    const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };

    // The payload length of each rowid, or null if absent. The index holds
    // (length, rowid) for every row.
    const rows = try gpa.alloc(?u32, config.n_keys);
    defer gpa.free(rows);
    @memset(rows, null);
    const committed = try gpa.dupe(?u32, rows);
    defer gpa.free(committed);

    try bt.beginTrans(.write, 0);
    const t_root = try bt.createTable(.intkey);
    const i_root = try bt.createTable(.blobkey);
    try bt.commit();

    var buf: [6000]u8 = undefined;
    var events: u32 = 0;
    while (events < events_max) {
        try bt.beginTrans(.write, 0);
        {
            var tc: Cursor = undefined;
            try bt.cursor(&tc, t_root, .{ .write = true });
            defer tc.close();
            var ic: Cursor = undefined;
            try bt.cursor(&ic, i_root, .{ .write = true, .key_info = ki.btreeKeyInfo() });
            defer ic.close();

            for (0..config.transaction_size) |_| {
                events += 1;
                const k = rand.uintLessThan(u32, config.n_keys);
                const rowid: i64 = k + 1;
                const op = fuzz.chooseWeighted(rand, ModelOp, config.op_weights);
                if (rows[k]) |len| {
                    // Remove the index entry, then delete or replace the row.
                    const key: record.UnpackedRecord = .{ .info = &ki, .values = &.{ .{ .int = len }, .{ .int = rowid } } };
                    try check(try ic.indexMoveto(key.indexKey()) == .eq, "index entry of rowid {d} missing", .{rowid});
                    try ic.delete(.{});
                    try check(try tc.tableMoveto(rowid, false) == .eq, "rowid {d} missing", .{rowid});
                    if (op == .delete) {
                        try tc.delete(.{});
                        rows[k] = null;
                        continue;
                    }
                } else if (op == .delete) continue;
                const len: u32 = if (rand.int(u8) < config.overflow_chance)
                    rand.uintLessThan(u32, buf.len)
                else
                    rand.uintLessThan(u32, 200);
                fillPayload(buf[0..len], rowid);
                try tc.insert(.{ .rowid = rowid, .data = buf[0..len] }, .{});
                var key_buf: [32]u8 = undefined;
                const values = [_]Value{ .{ .int = len }, .{ .int = rowid } };
                try ic.insert(.{ .key = record.encodeBuf(&values, &key_buf) }, .{});
                rows[k] = len;
            }
        }
        if (config.auto_vacuum == .incremental) {
            for (0..rand.uintLessThan(u32, 20)) |_| _ = try bt.incrVacuum();
        }
        if (rand.int(u8) < config.rollback_chance) {
            try bt.rollback(null, false);
            @memcpy(rows, committed);
        } else {
            try bt.commit();
            @memcpy(committed, rows);
        }
        try verifyModel(gpa, bt, &ki, t_root, i_root, rows, config.auto_vacuum);
    }
}

/// Check the table and index against the model, in a read transaction.
fn verifyModel(gpa: Allocator, bt: *Btree, ki: *const record.KeyInfo, t_root: Pgno, i_root: Pgno, rows: []const ?u32, av: btree.AutoVacuum) !void {
    try bt.beginTrans(.read, 0);
    defer bt.commit() catch unreachable;
    var report = try bt.integrityCheck(gpa, &.{ 1, t_root, i_root }, 100);
    defer report.deinit(gpa);
    try check(report.n_err == 0, "integrity check:\n{s}", .{report.message});
    if (av == .full) try check(bt.getMeta(.free_page_count) == 0, "free pages left after a full auto-vacuum commit", .{});

    var tc: Cursor = undefined;
    try bt.cursor(&tc, t_root, .{});
    defer tc.close();
    var expected: i64 = 0;
    var want: [6000]u8 = undefined;
    var got: [6000]u8 = undefined;
    for (rows, 1..) |m, rowid| {
        const len = m orelse continue;
        expected += 1;
        try check(try tc.tableMoveto(@intCast(rowid), false) == .eq, "rowid {d} missing", .{rowid});
        try check(tc.payloadSize() == len, "rowid {d}: payload size {d}, want {d}", .{ rowid, tc.payloadSize(), len });
        try tc.payload(0, got[0..len]);
        fillPayload(want[0..len], @intCast(rowid));
        try check(std.mem.eql(u8, want[0..len], got[0..len]), "rowid {d}: wrong payload", .{rowid});
    }
    try check(try tc.count() == expected, "table count", .{});
    var ic: Cursor = undefined;
    try bt.cursor(&ic, i_root, .{ .key_info = ki.btreeKeyInfo() });
    defer ic.close();
    try check(try ic.count() == expected, "index count", .{});
}

// ================================================================= corrupt

/// The `corrupt` fuzzer: build a database, then for each event overwrite a
/// few random bytes of a copy and use it.
pub fn corrupt(gpa: Allocator, io: Io, seed: u64, events_max: u32) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const page_sizes = [_]u32{ 512, 1024, 4096 };
    const page_size = page_sizes[rand.uintLessThan(usize, page_sizes.len)];
    const av = rand.enumValue(btree.AutoVacuum);

    // A database with a table and an index, overflow chains and free pages.
    var image: []u8 = undefined;
    var roots: [2]Pgno = undefined;
    {
        var mem = MemVfs.init(gpa, io);
        defer mem.deinit();
        const bt = try Btree.open(gpa, mem.interface(), db_name, .{ .page_size = page_size, .auto_vacuum = av });
        defer bt.close(.{});
        try bt.beginTrans(.write, 0);
        roots = .{ try bt.createTable(.intkey), try bt.createTable(.blobkey) };
        const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };
        {
            var tc: Cursor = undefined;
            try bt.cursor(&tc, roots[0], .{ .write = true });
            defer tc.close();
            var ic: Cursor = undefined;
            try bt.cursor(&ic, roots[1], .{ .write = true, .key_info = ki.btreeKeyInfo() });
            defer ic.close();
            var buf: [3000]u8 = undefined;
            const n = rand.intRangeAtMost(u32, 1, 300);
            for (1..n + 1) |i| {
                const rowid: i64 = @intCast(i);
                const len = if (i % 9 == 0) rand.uintLessThan(u32, buf.len) else rand.uintLessThan(u32, 100);
                fillPayload(buf[0..len], rowid);
                try tc.insert(.{ .rowid = rowid, .data = buf[0..len] }, .{});
                var key_buf: [32]u8 = undefined;
                const values = [_]Value{ .{ .int = len }, .{ .int = rowid } };
                try ic.insert(.{ .key = record.encodeBuf(&values, &key_buf) }, .{});
            }
            // Free some pages.
            var ok = try tc.first();
            while (ok) {
                if (rand.uintLessThan(u8, 4) == 0) try tc.delete(.{ .save_position = true });
                ok = try tc.next();
            }
        }
        try bt.commit();
        const f = try mem.interface().open(db_name, .{});
        defer f.close();
        image = try gpa.alloc(u8, @intCast(try f.fileSize()));
        try f.read(image, 0);
    }
    defer gpa.free(image);

    const copy = try gpa.alloc(u8, image.len);
    defer gpa.free(copy);
    for (0..events_max) |_| {
        @memcpy(copy, image);
        damage(rand, copy, page_size);
        useDamaged(gpa, io, rand, copy, roots) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }
}

/// Overwrite a few bytes, mostly in the page headers and cell pointer
/// arrays, where a bad value leads furthest.
fn damage(rand: std.Random, bytes: []u8, page_size: u32) void {
    const n_page = bytes.len / page_size;
    for (0..rand.intRangeAtMost(u32, 1, 8)) |_| {
        const page = rand.uintLessThan(usize, n_page);
        const header: usize = if (page == 0) 100 else 0;
        const off = page * page_size + if (rand.boolean())
            header + rand.uintLessThan(usize, 24)
        else
            rand.uintLessThan(usize, page_size);
        bytes[off] = switch (rand.uintLessThan(u8, 4)) {
            0 => 0,
            1 => 0xff,
            2 => bytes[off] +% @as(u8, if (rand.boolean()) 1 else 255),
            else => rand.int(u8),
        };
    }
}

/// Open the damaged database and read, check and change it. Errors are
/// expected; everything opened must still be released.
fn useDamaged(gpa: Allocator, io: Io, rand: std.Random, bytes: []const u8, roots: [2]Pgno) !void {
    var mem = MemVfs.init(gpa, io);
    defer mem.deinit();
    {
        const f = try mem.interface().open(db_name, .{ .create = true });
        defer f.close();
        try f.write(bytes, 0);
    }
    const bt = try Btree.open(gpa, mem.interface(), db_name, .{ .cache_size = 10 });
    defer bt.close(.{});
    const ki: record.KeyInfo = .{ .gpa = gpa, .sort_orders = &.{ .asc, .asc } };

    {
        try bt.beginTrans(.read, 0);
        defer bt.commit() catch {};
        // A damaged pointer can name a page far past the end, which the
        // pager would create (a sparse file on disk, but real memory here).
        // Cap the size, as fuzzcheck.c does with SQLITE_FCNTL_SIZE_LIMIT.
        _ = bt.maxPageCount(2000);
        if (bt.integrityCheck(gpa, &.{ 1, roots[0], roots[1] }, 10)) |report| {
            var r = report;
            r.deinit(gpa);
        } else |err| if (err == error.OutOfMemory) return err;
        scan(bt, roots[0], null) catch {};
        scan(bt, roots[1], ki.btreeKeyInfo()) catch {};
    }

    try bt.beginTrans(.write, 0);
    defer bt.rollback(null, false) catch {};
    var tc: Cursor = undefined;
    try bt.cursor(&tc, roots[0], .{ .write = true });
    defer tc.close();
    var buf: [2000]u8 = undefined;
    for (0..20) |_| {
        const rowid: i64 = rand.intRangeAtMost(i64, 1, 400);
        if (rand.boolean()) {
            if (try tc.tableMoveto(rowid, false) == .eq) try tc.delete(.{});
        } else {
            const len = rand.uintLessThan(u32, buf.len);
            fillPayload(buf[0..len], rowid);
            try tc.insert(.{ .rowid = rowid, .data = buf[0..len] }, .{});
        }
    }
}

/// Walk a b-tree, reading every payload, for at most a bounded number of
/// steps (a damaged tree may hold more entries than it was given).
fn scan(bt: *Btree, root: Pgno, key_info: ?btree.KeyInfo) !void {
    var cur: Cursor = undefined;
    try bt.cursor(&cur, root, .{ .key_info = key_info });
    defer cur.close();
    var buf: [65536]u8 = undefined;
    var ok = try cur.first();
    var steps: u32 = 0;
    while (ok and steps < 10_000) : (steps += 1) {
        const n = @min(cur.payloadSize(), buf.len);
        try cur.payload(0, buf[0..n]);
        ok = try cur.next();
    }
}
