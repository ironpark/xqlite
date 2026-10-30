//! sqlite3_serialize() and sqlite3_deserialize() (port of the API half of
//! memdb.c; the memdb VFS itself is vfs/memdb.zig).
//!
//! serialize() copies a database into one block of memory: the content
//! of a memdb database as it is, any other database page by page through
//! its pager. deserialize() reopens a database of the connection (main or
//! an attached one) on a separate memdb store holding the given bytes,
//! as SQLite does: by running "ATTACH x AS name" with
//! db.init.reopen_memdb set (attach.zig).
//!
//! The memory handed in and out comes from the library allocator
//! (sqlite3_malloc()).

const std = @import("std");
const int = @import("sqlite_int.zig");
const malloc = @import("malloc.zig");
const build = @import("build.zig");
const prepare = @import("prepare.zig");
const legacy = @import("legacy.zig");
const api = @import("../vdbe/api.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const memdb = @import("../vfs/memdb.zig");

const Sqlite3 = int.Sqlite3;
const RC = int.RC;

/// SQLITE_SERIALIZE_NOCOPY.
pub const SERIALIZE_NOCOPY: u32 = 1;
/// SQLITE_DESERIALIZE_FREEONCLOSE, _RESIZEABLE and _READONLY.
pub const DESERIALIZE_FREEONCLOSE = memdb.FREEONCLOSE;
pub const DESERIALIZE_RESIZEABLE = memdb.RESIZEABLE;
pub const DESERIALIZE_READONLY = memdb.READONLY;

/// Port of memdbFromDbSchema(): the store of database `schema` if it is
/// a separate memdb database.
pub fn memdbStore(db: *Sqlite3, schema: []const u8) ?*memdb.Store {
    const i_db = build.findDbName(db, schema) orelse return null;
    const bt = db.dbs.items[i_db].bt orelse return null;
    const f = memdb.fileOf(bt.pager.fd) orelse return null;
    return memdb.separateStore(f);
}

/// The result of serialize(): the bytes (null on failure, or with
/// NOCOPY when they cannot be had without a copy) and the size of the
/// database (-1 if there is no such database).
pub const Serialized = struct {
    data: ?[*]u8 = null,
    size: i64 = -1,
};

/// Port of sqlite3_serialize(): the content of database `schema` (main
/// if null). Unless `flags` has SERIALIZE_NOCOPY, the bytes are a copy
/// the caller frees with malloc.free(); with it, they are the memdb
/// store itself, or null for any other database.
pub fn serialize(db: *Sqlite3, schema_arg: ?[]const u8, flags: u32) Serialized {
    const schema = schema_arg orelse db.dbs.items[0].name;
    var out: Serialized = .{};
    const store = memdbStore(db, schema);
    const i_db = build.findDbName(db, schema) orelse return out;
    if (store) |p| {
        out.size = p.sz;
        if (flags & SERIALIZE_NOCOPY != 0) {
            out.data = p.data;
        } else {
            out.data = malloc.malloc(@intCast(p.sz));
            if (out.data) |d| @memcpy(d[0..@intCast(p.sz)], p.bytes());
        }
        return out;
    }
    const bt = db.dbs.items[i_db].bt orelse return out;
    const sz_page: i64 = bt.getPageSize();
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(malloc.allocator);
    quoted(&sql, "PRAGMA \"", schema, '"', "\".page_count") catch return out;
    var stmt: ?*vi.Vdbe = null;
    if (prepare.prepareV2(db, sql.items, &stmt, null) != RC.OK) return out;
    const v = stmt orelse return out;
    defer _ = api.finalize(v);
    if (api.step(v) != RC.ROW) return out;
    var n_page = api.columnInt64(v, 0);
    var sz = n_page * sz_page;
    if (sz == 0) {
        // An empty file: make SQLite write the first page.
        _ = api.reset(v);
        _ = legacy.exec(db, "BEGIN IMMEDIATE; COMMIT;", null, null, null);
        if (api.step(v) == RC.ROW) {
            n_page = api.columnInt64(v, 0);
            sz = n_page * sz_page;
        }
    }
    out.size = sz;
    if (flags & SERIALIZE_NOCOPY != 0) return out;
    const buf = malloc.malloc(@intCast(sz)) orelse return out;
    out.data = buf;
    // The statement holds a read transaction while it is on its row.
    const pager = bt.pager;
    const page_size: usize = @intCast(sz_page);
    var pgno: u32 = 1;
    while (pgno <= n_page) : (pgno += 1) {
        const to = buf[page_size * (pgno - 1) ..][0..page_size];
        if (pager.get(pgno, .{})) |pg| {
            @memcpy(to, pg.data[0..page_size]);
            pager.unref(pg);
        } else |_| @memset(to, 0);
    }
    return out;
}

/// Port of sqlite3_deserialize(): reopen database `schema` (main if null;
/// not TEMP) as a separate memdb database holding the first `sz_db`
/// bytes of `data`, a buffer of `sz_buf` bytes from the library
/// allocator, with the DESERIALIZE_* `flags`. With FREEONCLOSE the
/// buffer is the database's from now on, and is freed here on failure.
pub fn deserialize(db: *Sqlite3, schema_arg: ?[]const u8, data_arg: ?[*]u8, sz_db: i64, sz_buf: i64, flags: u32) i32 {
    var data = data_arg;
    defer if (data) |d| if (flags & DESERIALIZE_FREEONCLOSE != 0) malloc.free(d);
    const schema = schema_arg orelse db.dbs.items[0].name;
    const i_db = build.findDbName(db, schema);
    if (i_db == null or (i_db.? < 2 and i_db.? != 0)) return RC.ERROR;
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(malloc.allocator);
    quoted(&sql, "ATTACH x AS '", schema, '\'', "'") catch return RC.NOMEM;
    var stmt: ?*vi.Vdbe = null;
    var rc = prepare.prepareV2(db, sql.items, &stmt, null);
    if (rc != RC.OK) return rc;
    db.init.i_db = @intCast(i_db.?);
    db.init.reopen_memdb = true;
    _ = api.step(stmt.?);
    db.init.reopen_memdb = false;
    rc = api.finalize(stmt.?);
    if (rc != RC.OK) return rc;
    const p = memdbStore(db, schema) orelse return RC.ERROR;
    p.data = data;
    data = null;
    p.sz = sz_db;
    p.sz_alloc = sz_buf;
    p.sz_max = @max(sz_buf, memdb.state.default_max_size);
    p.flags = flags;
    return RC.OK;
}

/// `pre`, `name` with each `q` doubled (%w, %q), then `post`.
fn quoted(out: *std.ArrayList(u8), pre: []const u8, name: []const u8, q: u8, post: []const u8) !void {
    const a = malloc.allocator;
    try out.appendSlice(a, pre);
    for (name) |ch| {
        if (ch == q) try out.append(a, q);
        try out.append(a, ch);
    }
    try out.appendSlice(a, post);
}

const testing = std.testing;
const main = @import("main.zig");

fn testOpen() !*Sqlite3 {
    var h: ?*Sqlite3 = null;
    try testing.expectEqual(RC.OK, main.open(memdb.interface(), "x", .{}, &h));
    return h.?;
}

fn count(db: *Sqlite3, sql: []const u8) !i64 {
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(db, sql, &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    return api.columnInt64(stmt.?, 0);
}

test "serialize: round trip through deserialize" {
    var mem = @import("../vfs/mem.zig").MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    var h: ?*Sqlite3 = null;
    try testing.expectEqual(RC.OK, main.open(mem.interface(), "file.db", .{}, &h));
    const db = h.?;
    defer _ = main.close(db);
    try testing.expectEqual(RC.OK, legacy.exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3)", null, null, null));
    const s = serialize(db, null, 0);
    try testing.expect(s.data != null and s.size == 8192);
    try testing.expectEqual(@as(?[*]u8, null), serialize(db, "nosuch", 0).data);
    try testing.expectEqual(@as(i64, -1), serialize(db, "nosuch", 0).size);

    const db2 = try testOpen();
    defer _ = main.close(db2);
    try testing.expectEqual(RC.ERROR, deserialize(db2, "temp", null, 0, 0, 0));
    try testing.expectEqual(RC.OK, deserialize(db2, "main", s.data, s.size, s.size, DESERIALIZE_FREEONCLOSE | DESERIALIZE_RESIZEABLE));
    try testing.expectEqual(@as(i64, 6), try count(db2, "SELECT sum(x) FROM t"));
    try testing.expectEqual(RC.OK, legacy.exec(db2, "INSERT INTO t SELECT x FROM t; BEGIN; DELETE FROM t; ROLLBACK", null, null, null));
    try testing.expectEqual(@as(i64, 12), try count(db2, "SELECT sum(x) FROM t"));
    // NOCOPY of a memdb database is its store.
    const n = serialize(db2, "main", SERIALIZE_NOCOPY);
    try testing.expect(n.data != null and n.size == 8192);
}
