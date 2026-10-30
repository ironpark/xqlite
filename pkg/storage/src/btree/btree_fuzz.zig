//! Seeded fuzzers of the b-tree layer, run by `zig build fuzz` (see
//! src/fuzz_tests.zig) and, with few events, by `zig build test`.
//!
//! - `model`: random inserts, replacements and deletes on a table and an
//!   index of the same rows, with seeks, read cursors left open across the
//!   changes, rows copied by transferRow(), statement savepoints and
//!   clearTable(), in transactions that commit or roll back, checked
//!   against a model as it goes and after every transaction.
//! - `corrupt`: random bytes of a valid database overwritten, then the
//!   database read, checked and changed. Any error is fine; a crash, a
//!   failed assertion or a leak is not.

const std = @import("std");
const btree = @import("btree.zig");
const record = @import("../record.zig");
const MemVfs = @import("xqlite_vfs").mem.MemVfs;
const fuzz = @import("xqlite_base").fuzz;
const corrupt_mod = @import("../corrupt.zig");
const varint = @import("../varint.zig");

const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const Io = std.Io;
const Btree = btree.Btree;
const Cursor = btree.Cursor;
const Pgno = btree.Pgno;
const Value = record.Value;

const db_name = "fuzz.db";

/// Payload bytes for a rowid, so that reads can be checked: from 2 bytes
/// on, a record of one blob, which SQLite's own checks can read (its
/// quick_check reads a column of every row).
pub fn fillPayload(buf: []u8, rowid: i64) void {
    const seed: u64 = @bitCast(rowid);
    for (buf, 0..) |*b, i| b.* = @truncate(seed *% 31 +% i);
    switch (buf.len) {
        0 => {},
        // Too short for a record; the integrity check wants a header
        // size of at least 2.
        1 => buf[0] |= 2,
        else => {
            // The header: its size, NULLs to pad it, then the serial type
            // of an n-byte blob (12 + 2n), whose varint shrinks n as it
            // grows.
            var h: usize = 2;
            while (1 + varint.len(12 + 2 * (buf.len - h)) > h) h += 1;
            const st_len = varint.len(12 + 2 * (buf.len - h));
            buf[0] = @intCast(h);
            @memset(buf[1 .. h - st_len], 0);
            _ = varint.put(buf[h - st_len ..], 12 + 2 * (buf.len - h));
        },
    }
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) error{ModelMismatch}!void {
    if (ok) return;
    std.debug.print("btree fuzz: " ++ fmt ++ "\n", args);
    return error.ModelMismatch;
}

fn printCorrupt(loc: corrupt_mod.Location) void {
    var buf: [160]u8 = undefined;
    std.debug.print("btree fuzz: {s}\n", .{corrupt_mod.format(loc, &buf)});
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

pub const ModelOp = enum {
    put,
    delete,
    /// Seek the table or the index to a random key, present or not.
    seek,
    /// Step a read cursor left open across the changes.
    read,
    /// Copy a row to a third table with transferRow().
    copy,
    /// Open, release or roll back a statement savepoint.
    savepoint,
    /// Empty the table and the index, rarely.
    clear,
};

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

/// What the b-trees should hold: the payload length of each rowid, or null
/// if absent, in the table (whose index holds (length, rowid) for every
/// row) and in the table of copies.
const Rows = struct {
    rows: []?u32,
    copies: []?u32,

    fn init(gpa: Allocator, n: u32) !Rows {
        const both = try gpa.alloc(?u32, 2 * n);
        @memset(both, null);
        return .{ .rows = both[0..n], .copies = both[n..] };
    }

    fn deinit(m: Rows, gpa: Allocator) void {
        gpa.free(m.rows.ptr[0 .. 2 * m.rows.len]);
    }

    fn all(m: Rows) []?u32 {
        return m.rows.ptr[0 .. 2 * m.rows.len];
    }

    fn copyFrom(m: Rows, from: Rows) void {
        @memcpy(m.all(), from.all());
    }
};

/// The key of a table entry (rowid, 0) or of an index entry (length,
/// rowid), ordered as the b-tree orders them.
const Key = struct {
    a: i64,
    b: i64,

    fn order(x: Key, y: Key) Order {
        const o = std.math.order(x.a, y.a);
        return if (o != .eq) o else std.math.order(x.b, y.b);
    }
};

const Tree = enum { table, index };

/// The model's key next to `at` in direction `dir`: the smallest key
/// greater than it (.gt) or the largest smaller (.lt). A null `at` stands
/// before the first key (.gt) or after the last (.lt).
fn neighbor(rows: []const ?u32, tree: Tree, at: ?Key, dir: Order) ?Key {
    var best: ?Key = null;
    for (rows, 1..) |m, rowid| {
        const len = m orelse continue;
        const k: Key = if (tree == .table) .{ .a = @intCast(rowid), .b = 0 } else .{ .a = len, .b = @intCast(rowid) };
        if (at) |x| if (k.order(x) != dir) continue;
        if (best) |b| if (k.order(b) != dir.invert()) continue;
        best = k;
    }
    return best;
}

/// The key of the entry `cur` is on.
fn currentKey(cur: *Cursor, tree: Tree) !Key {
    if (tree == .table) return .{ .a = cur.integerKey(), .b = 0 };
    var buf: [32]u8 = undefined;
    const n = cur.payloadSize();
    try check(n <= buf.len, "index entry of {d} bytes", .{n});
    try cur.payload(0, buf[0..n]);
    var values: [2]Value = undefined;
    try check(try record.decode(buf[0..n], &values) == 2, "index entry of other than 2 values", .{});
    return .{ .a = values[0].int, .b = values[1].int };
}

/// A cursor left open while the write cursors change its b-tree, which
/// must save its position and restore it: stepping from the key it was
/// on goes to that key's neighbor in the model, whatever happened to the
/// key itself.
const Reader = struct {
    cur: Cursor = undefined,
    tree: Tree,
    /// The key the cursor is on, null if not on an entry.
    at: ?Key = null,

    fn step(r: *Reader, rand: std.Random, rows: []const ?u32) !void {
        const dir: Order = if (rand.boolean()) .gt else .lt;
        const ok = if (r.at == null)
            (if (dir == .gt) try r.cur.first() else try r.cur.last())
        else if (dir == .gt) try r.cur.next() else try r.cur.previous();
        const want = neighbor(rows, r.tree, r.at, dir);
        try check(ok == (want != null), "{t} reader: stepped {t} from {any}: on an entry {}, want {any}", .{ r.tree, dir, r.at, ok, want });
        if (want) |w| {
            const got = try currentKey(&r.cur, r.tree);
            try check(got.order(w) == .eq, "{t} reader: stepped {t} from {any} to {any}, want {any}", .{ r.tree, dir, r.at, got, w });
        }
        r.at = want;
    }
};

/// Seek `cur` to a random key, present or not, and check the result: .eq
/// on the key itself, otherwise on its neighbor on the side it says.
fn seekCheck(rand: std.Random, cur: *Cursor, tree: Tree, ki: *const record.KeyInfo, rows: []const ?u32) !void {
    const n: i64 = @intCast(rows.len);
    const key: Key = .{ .a = rand.intRangeAtMost(i64, 0, if (tree == .table) n + 1 else 260), .b = if (tree == .table) 0 else rand.intRangeAtMost(i64, 0, n + 1) };
    const o = if (tree == .table)
        try cur.tableMoveto(key.a, rand.boolean())
    else o: {
        const search: record.UnpackedRecord = .{ .info = ki, .values = &.{ .{ .int = key.a }, .{ .int = key.b } } };
        break :o try cur.indexMoveto(search.indexKey());
    };
    const before = neighbor(rows, tree, key, .lt);
    const after = neighbor(rows, tree, key, .gt);
    const present = for (rows, 1..) |m, rowid| {
        const len = m orelse continue;
        const k: Key = if (tree == .table) .{ .a = @intCast(rowid), .b = 0 } else .{ .a = len, .b = @intCast(rowid) };
        if (k.order(key) == .eq) break true;
    } else false;
    if (!present and before == null and after == null) {
        try check(o == .lt and cur.eof(), "{t} seek {any} in an empty tree: {t}", .{ tree, key, o });
        return;
    }
    const got = try currentKey(cur, tree);
    const want: Key = switch (o) {
        .eq => key,
        .lt => before orelse return check(false, "{t} seek {any}: .lt with nothing smaller", .{ tree, key }),
        .gt => after orelse return check(false, "{t} seek {any}: .gt with nothing larger", .{ tree, key }),
    };
    try check(present == (o == .eq), "{t} seek {any}: {t}, present {}", .{ tree, key, o, present });
    try check(got.order(want) == .eq, "{t} seek {any}: {t} on {any}, want {any}", .{ tree, key, o, got, want });
}

pub fn modelWith(gpa: Allocator, io: Io, rand: std.Random, config: ModelConfig, events_max: u32) !void {
    return modelRun(gpa, io, rand, config, events_max, null);
}

/// The `model` fuzzer with a configuration drawn from `seed`, returning
/// the database it leaves, for a check by SQLite itself. Its b-trees are
/// in sqlite_schema; the rows of its tables are not records.
pub fn modelDatabase(gpa: Allocator, io: Io, seed: u64, events_max: u32) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const config: ModelConfig = .random(prng.random());
    var image: []u8 = &.{};
    try modelRun(gpa, io, prng.random(), config, events_max, &image);
    return image;
}

fn modelRun(gpa: Allocator, io: Io, rand: std.Random, config: ModelConfig, events_max: u32, image: ?*[]u8) !void {
    // A valid database is never corrupt: say which check thought it was,
    // and run the checks that assume it.
    const old_hook = corrupt_mod.hook;
    const old_never = corrupt_mod.never_corrupt;
    corrupt_mod.hook = printCorrupt;
    corrupt_mod.never_corrupt = true;
    defer {
        corrupt_mod.hook = old_hook;
        corrupt_mod.never_corrupt = old_never;
    }

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

    const m: Rows = try .init(gpa, config.n_keys);
    defer m.deinit(gpa);
    const committed: Rows = try .init(gpa, config.n_keys);
    defer committed.deinit(gpa);
    // The model at each open statement savepoint.
    const max_savepoints = 4;
    var saved: [max_savepoints]Rows = undefined;
    for (&saved, 0..) |*s, i| s.* = Rows.init(gpa, config.n_keys) catch |err| {
        for (saved[0..i]) |x| x.deinit(gpa);
        return err;
    };
    defer for (saved) |s| s.deinit(gpa);

    try bt.beginTrans(.write, 0);
    const t_root = try bt.createTable(.intkey);
    const i_root = try bt.createTable(.blobkey);
    const c_root = try bt.createTable(.intkey);
    try writeSchema(bt, .{ t_root, i_root, c_root });
    try bt.commit();

    var buf: [6000]u8 = undefined;
    var events: u32 = 0;
    while (events < events_max) {
        try bt.beginTrans(.write, 0);
        var n_savepoint: u32 = 0;
        {
            var tc: Cursor = undefined;
            try bt.cursor(&tc, t_root, .{ .write = true });
            defer tc.close();
            var ic: Cursor = undefined;
            try bt.cursor(&ic, i_root, .{ .write = true, .key_info = ki.btreeKeyInfo() });
            defer ic.close();
            var cc: Cursor = undefined;
            try bt.cursor(&cc, c_root, .{ .write = true });
            defer cc.close();
            var readers = [_]Reader{ .{ .tree = .table }, .{ .tree = .index } };
            try bt.cursor(&readers[0].cur, t_root, .{});
            defer readers[0].cur.close();
            try bt.cursor(&readers[1].cur, i_root, .{ .key_info = ki.btreeKeyInfo() });
            defer readers[1].cur.close();

            for (0..config.transaction_size) |_| {
                events += 1;
                const k = rand.uintLessThan(u32, config.n_keys);
                const rowid: i64 = k + 1;
                const op = fuzz.chooseWeighted(rand, ModelOp, config.op_weights);
                switch (op) {
                    .put, .delete => {},
                    .seek => {
                        if (rand.boolean())
                            try seekCheck(rand, &tc, .table, &ki, m.rows)
                        else
                            try seekCheck(rand, &ic, .index, &ki, m.rows);
                        continue;
                    },
                    .read => {
                        const r = &readers[rand.uintLessThan(usize, readers.len)];
                        try r.step(rand, m.rows);
                        continue;
                    },
                    .copy => {
                        if (m.rows[k] == null) continue;
                        // As INSERT INTO ... SELECT copies rows (xferOptimization):
                        // only to a rowid not there (OP_NotExists).
                        if (m.copies[k] != null) {
                            try check(try cc.tableMoveto(rowid, false) == .eq, "copy of rowid {d} missing", .{rowid});
                            try cc.delete(.{});
                        }
                        try check(try tc.tableMoveto(rowid, false) == .eq, "rowid {d} missing", .{rowid});
                        const o = try cc.tableMoveto(rowid, false);
                        try cc.transferRow(&tc, rowid);
                        try cc.insert(.{ .rowid = rowid }, .{ .preformat = true, .seek_result = o });
                        m.copies[k] = m.rows[k];
                        continue;
                    },
                    .savepoint => {
                        // Open one, or release or roll back to a random one
                        // (-1: the start of the transaction).
                        if (n_savepoint < max_savepoints and rand.boolean()) {
                            saved[n_savepoint].copyFrom(m);
                            n_savepoint += 1;
                            try bt.beginStmt(n_savepoint);
                        } else if (rand.boolean()) {
                            if (n_savepoint == 0) continue;
                            const i = rand.uintLessThan(u32, n_savepoint);
                            try bt.savepoint(.release, @intCast(i));
                            n_savepoint = i;
                        } else {
                            const i = rand.intRangeLessThan(i32, -1, @intCast(n_savepoint));
                            try bt.savepoint(.rollback, i);
                            if (i < 0) {
                                m.copyFrom(committed);
                                n_savepoint = 0;
                            } else {
                                m.copyFrom(saved[@intCast(i)]);
                                n_savepoint = @intCast(i + 1);
                            }
                        }
                        continue;
                    },
                    .clear => {
                        if (rand.uintLessThan(u32, 16) != 0) continue;
                        _ = try bt.clearTable(t_root);
                        _ = try bt.clearTable(i_root);
                        @memset(m.rows, null);
                        continue;
                    },
                }
                if (m.rows[k]) |len| {
                    // Remove the index entry, then delete or replace the row.
                    const key: record.UnpackedRecord = .{ .info = &ki, .values = &.{ .{ .int = len }, .{ .int = rowid } } };
                    try check(try ic.indexMoveto(key.indexKey()) == .eq, "index entry of rowid {d} missing", .{rowid});
                    try ic.delete(.{});
                    try check(try tc.tableMoveto(rowid, false) == .eq, "rowid {d} missing", .{rowid});
                    if (op == .delete) {
                        try tc.delete(.{});
                        m.rows[k] = null;
                        continue;
                    }
                } else if (op == .delete) continue;
                const len: u32 = if (rand.int(u8) < config.overflow_chance)
                    rand.intRangeLessThan(u32, 2, buf.len)
                else
                    rand.intRangeLessThan(u32, 2, 200);
                fillPayload(buf[0..len], rowid);
                try tc.insert(.{ .rowid = rowid, .data = buf[0..len] }, .{});
                var key_buf: [32]u8 = undefined;
                const values = [_]Value{ .{ .int = len }, .{ .int = rowid } };
                try ic.insert(.{ .key = record.encodeBuf(&values, &key_buf) }, .{});
                m.rows[k] = len;
            }
        }
        if (config.auto_vacuum == .incremental) {
            for (0..rand.uintLessThan(u32, 20)) |_| _ = try bt.incrVacuum();
        }
        if (rand.int(u8) < config.rollback_chance) {
            try bt.rollback(null, false);
            m.copyFrom(committed);
        } else {
            try bt.commit();
            committed.copyFrom(m);
        }
        try verifyModel(gpa, bt, &ki, .{ t_root, i_root, c_root }, m, config.auto_vacuum);
    }
    if (image) |out| {
        const f = try mem.interface().open(db_name, .{});
        defer f.close();
        out.* = try gpa.alloc(u8, @intCast(try f.fileSize()));
        errdefer gpa.free(out.*);
        try f.read(out.*, 0);
    }
}

/// Describe the model's b-trees in sqlite_schema, so that SQLite counts
/// their pages as used: the table t and its index i, and the table of
/// copies c.
fn writeSchema(bt: *Btree, roots: [3]Pgno) !void {
    const entries = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "table", "t", "t", "CREATE TABLE t(a)" },
        .{ "index", "i", "t", "CREATE INDEX i ON t(a)" },
        .{ "table", "c", "c", "CREATE TABLE c(a)" },
    };
    var cur: Cursor = undefined;
    try bt.cursor(&cur, 1, .{ .write = true });
    defer cur.close();
    for (entries, roots, 1..) |e, root, rowid| {
        const values = [_]Value{ .{ .text = e[0] }, .{ .text = e[1] }, .{ .text = e[2] }, .{ .int = root }, .{ .text = e[3] } };
        var buf: [128]u8 = undefined;
        try cur.insert(.{ .rowid = @intCast(rowid), .data = record.encodeBuf(&values, &buf) }, .{});
    }
    // A schema cookie, the schema format (BTREE_FILE_FORMAT) and UTF-8.
    try bt.updateMeta(.schema_version, 1);
    try bt.updateMeta(.file_format, 4);
    try bt.updateMeta(.text_encoding, 1);
}

/// Check the tables and the index against the model, in a read
/// transaction: every row, then every entry in both directions.
fn verifyModel(gpa: Allocator, bt: *Btree, ki: *const record.KeyInfo, roots: [3]Pgno, m: Rows, av: btree.AutoVacuum) !void {
    try bt.beginTrans(.read, 0);
    defer bt.commit() catch unreachable;
    var report = try bt.integrityCheck(gpa, &.{ 1, roots[0], roots[1], roots[2] }, 100);
    defer report.deinit(gpa);
    try check(report.n_err == 0, "integrity check:\n{s}", .{report.message});
    if (av == .full) try check(bt.getMeta(.free_page_count) == 0, "free pages left after a full auto-vacuum commit", .{});

    for ([_]Pgno{ roots[0], roots[2] }, [_][]const ?u32{ m.rows, m.copies }) |root, rows| {
        var tc: Cursor = undefined;
        try bt.cursor(&tc, root, .{});
        defer tc.close();
        var want: [6000]u8 = undefined;
        var got: [6000]u8 = undefined;
        for (rows, 1..) |r, rowid| {
            const len = r orelse continue;
            try check(try tc.tableMoveto(@intCast(rowid), false) == .eq, "table {d}: rowid {d} missing", .{ root, rowid });
            try check(tc.payloadSize() == len, "table {d}: rowid {d}: payload size {d}, want {d}", .{ root, rowid, tc.payloadSize(), len });
            try tc.payload(0, got[0..len]);
            fillPayload(want[0..len], @intCast(rowid));
            try check(std.mem.eql(u8, want[0..len], got[0..len]), "table {d}: rowid {d}: wrong payload", .{ root, rowid });
        }
        try scanCheck(&tc, .table, rows);
    }
    var ic: Cursor = undefined;
    try bt.cursor(&ic, roots[1], .{ .key_info = ki.btreeKeyInfo() });
    defer ic.close();
    try scanCheck(&ic, .index, m.rows);
}

/// Walk `cur` forward and then backward, comparing each key with the
/// model's.
fn scanCheck(cur: *Cursor, tree: Tree, rows: []const ?u32) !void {
    for ([_]Order{ .gt, .lt }) |dir| {
        var want = neighbor(rows, tree, null, dir);
        var ok = if (dir == .gt) try cur.first() else try cur.last();
        while (ok) : (ok = if (dir == .gt) try cur.next() else try cur.previous()) {
            const w = want orelse return check(false, "{t} scan {t}: an entry past the last", .{ tree, dir });
            const got = try currentKey(cur, tree);
            try check(got.order(w) == .eq, "{t} scan {t}: {any}, want {any}", .{ tree, dir, got, w });
            want = neighbor(rows, tree, w, dir);
        }
        try check(want == null, "{t} scan {t}: ended before {any}", .{ tree, dir, want });
    }
}

// ================================================================= corrupt

/// The `corrupt` fuzzer: build a database, then for each event overwrite a
/// few random bytes of a copy and use it.
pub fn corrupt(gpa: Allocator, io: Io, seed: u64, events_max: u32) !void {
    const old_never = corrupt_mod.never_corrupt;
    corrupt_mod.never_corrupt = false;
    defer corrupt_mod.never_corrupt = old_never;
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
