//! The dialect catalog of a database read into memory: what xq_catalog
//! says of each table (catalog.meta()), so that compiling a statement
//! does not query it. See "The catalog in memory" in catalog.zig for when
//! it is read and dropped.
//!
//! One Cache per Schema (Schema.xq_meta), made of one read of all of the
//! database's xq_catalog: the catalog is small (a few rows per column of
//! the dialects' tables), every statement of a dialect that touches a
//! table wants its entry, and one scan also answers "no entry" for the
//! tables of SQLite's dialect without a query per table.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const build = @import("../sql/build.zig");
const types = @import("../sql/types.zig");
const api = @import("../vdbe/api.zig");
const catalog = @import("catalog.zig");
const Dialect = @import("../dialect/dialect.zig").Dialect;

const Sqlite3 = int.Sqlite3;
const Key = catalog.Key;
const Entry = catalog.Entry;

pub const Error = int.Error;

/// What the catalog says of a column of a table.
pub const ColumnMeta = struct {
    /// As the catalog spells it (the column of its first entry).
    name: []const u8,
    /// Key.decl_type: the declared type as written in the table's dialect.
    decl_type: ?[]const u8 = null,
    /// decl_type read in the table's dialect (types.parse()); unknown
    /// without one.
    type: types.Type = .{ .logical = .unknown },
    /// Key.identity: the sequence of an identity column.
    identity: ?[]const u8 = null,
    /// Key.identity_kind: "always" or "by default".
    identity_kind: ?[]const u8 = null,
    /// Key.collation, as named in the dialect.
    collation: ?[]const u8 = null,
    /// Key.default, as written in the dialect.
    default: ?[]const u8 = null,

    /// Whether the column is GENERATED ALWAYS AS IDENTITY.
    pub fn always(c: *const ColumnMeta) bool {
        return if (c.identity_kind) |k| std.mem.eql(u8, k, "always") else false;
    }
};

/// What the catalog says of a table: its entries other than the
/// columns', its columns, and all its entries as stored (a dialect's own
/// keys, "pg.xxx", "mariadb.xxx", are found with value()).
pub const TableMeta = struct {
    /// The table's name as stored (`tbl`).
    name: []const u8,
    /// Key.dialect as stored, null without one.
    dialect_name: ?[]const u8 = null,
    /// The dialect of dialect_name (Dialect.fromName()), .sqlite without
    /// one or for a name this build does not know.
    dialect: Dialect = .sqlite,
    /// Key.collation of the table: the default of its columns.
    collation: ?[]const u8 = null,
    /// The columns with an entry, in the order of their first entry.
    columns: []const ColumnMeta = &.{},
    /// Every entry of the table (`col` '' for the table's own), in the
    /// order of xq_catalog's key (col, key).
    entries: []const Entry = &.{},

    /// The column called `name` (case-insensitive, as SQLite's names).
    pub fn column(m: *const TableMeta, name: []const u8) ?*const ColumnMeta {
        for (m.columns) |*c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        return null;
    }

    /// The declared type of column `name` (Key.decl_type), if recorded.
    pub fn declType(m: *const TableMeta, name: []const u8) ?[]const u8 {
        return if (m.column(name)) |c| c.decl_type else null;
    }

    /// The value of entry `key` of column `col` ('' for the table; the
    /// column's name is case-insensitive), null if there is none.
    pub fn value(m: *const TableMeta, col: []const u8, key: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (m.entries) |e| {
            if (std.mem.eql(u8, e.key, key) and std.ascii.eqlIgnoreCase(e.col, col)) found = e.value;
        }
        return found;
    }
};

/// The catalog of one database in memory.
pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    /// By table name, as stored (`tbl`, compared as xq_catalog's key is).
    tables: std.StringHashMapUnmanaged(TableMeta) = .empty,
    /// The schema cookie of the database (Schema.schema_cookie) when the
    /// catalog was read.
    cookie: i32 = 0,
};

/// catalog.meta(): the entry of table `tbl` of database `schema` ("main",
/// "temp" or an attached name), null if the catalog has none (or there is
/// no catalog). Reads the catalog of the database if it is not in memory.
/// The result is valid until the catalog of the database is dropped (see
/// catalog.zig): do not keep it across running a statement.
pub fn get(db: *Sqlite3, schema: []const u8, tbl: []const u8) Error!?*const TableMeta {
    if (!try catalog.tableExists(db, schema, catalog.table_name)) return null;
    const i_db = build.findDbName(db, schema) orelse return null;
    const c = try cacheOf(db, i_db, schema);
    return c.tables.getPtr(tbl);
}

/// Read the catalog of every database into memory (each that has one and
/// is not in memory): before a statement of a dialect is compiled, so
/// that name resolution knows the types of the columns of its tables
/// (cached()), those of the views it reads included.
pub fn readAll(db: *Sqlite3) Error!void {
    var i: usize = 0;
    while (i < db.dbs.items.len) : (i += 1) {
        if (current(db.dbs.items[i].schema) != null) continue;
        const name = db.dbs.items[i].name;
        if (!try catalog.tableExists(db, name, catalog.table_name)) continue;
        _ = try cacheOf(db, i, name);
    }
}

/// get() of table `t` of the schema in memory.
pub fn of(db: *Sqlite3, t: *const int.Table) Error!?*const TableMeta {
    return get(db, catalog.schemaName(db, t), t.name);
}

/// of() of table `t` (of the schema in memory) only if the catalog of its
/// database is in memory: no query, no reading of the schema, so it may
/// be called anywhere in compiling a statement (name resolution). Null
/// if the catalog is not in memory, or has no entry for the table.
pub fn cached(t: *const int.Table) ?*const TableMeta {
    const s = t.schema orelse return null;
    const c = current(s) orelse return null;
    return c.tables.getPtr(t.name);
}

fn current(s: *const int.Schema) ?*Cache {
    const p = s.xq_meta orelse return null;
    const c: *Cache = @ptrCast(@alignCast(p));
    return if (c.cookie == s.schema_cookie) c else null;
}

fn cacheOf(db: *Sqlite3, i_db: usize, schema: []const u8) Error!*Cache {
    if (current(db.dbs.items[i_db].schema)) |c| return c;
    drop(db, db.dbs.items[i_db].schema);
    const c = try load(db, schema);
    // The query may have read the schema again (another connection
    // changed it): the catalog read is that of the schema now in memory.
    const s = db.dbs.items[i_db].schema;
    drop(db, s);
    c.cookie = s.schema_cookie;
    s.xq_meta = c;
    return c;
}

fn load(db: *Sqlite3, schema: []const u8) Error!*Cache {
    const c = db.gpa.create(Cache) catch return oom(db);
    c.* = .{ .arena = .init(db.gpa) };
    errdefer free(db, c);
    const a = c.arena.allocator();
    var tbls: std.ArrayList([]const u8) = .empty;
    var all: std.ArrayList(Entry) = .empty;
    {
        // In the order of the key, so a table's entries are together.
        var q = try catalog.Query.initFmt(db, "SELECT tbl,col,key,value FROM %Q.xq_catalog WHERE tbl<>'' ORDER BY tbl,col,key", &.{.{ .str = schema }});
        defer q.deinit();
        while (try q.step()) {
            tbls.append(a, try text(db, a, q, 0)) catch return oom(db);
            all.append(a, .{ .col = try text(db, a, q, 1), .key = try text(db, a, q, 2), .value = try text(db, a, q, 3) }) catch return oom(db);
        }
    }
    var i: usize = 0;
    while (i < all.items.len) {
        var j = i + 1;
        while (j < all.items.len and std.mem.eql(u8, tbls.items[j], tbls.items[i])) j += 1;
        const m = try table(db, a, tbls.items[i], all.items[i..j]);
        c.tables.put(a, m.name, m) catch return oom(db);
        i = j;
    }
    return c;
}

/// The TableMeta of the entries `list` of table `name`.
fn table(db: *Sqlite3, a: std.mem.Allocator, name: []const u8, list: []const Entry) Error!TableMeta {
    var m: TableMeta = .{ .name = name, .entries = list };
    var cols: std.ArrayList(ColumnMeta) = .empty;
    for (list) |e| {
        if (e.col.len == 0) {
            if (std.mem.eql(u8, e.key, Key.dialect)) m.dialect_name = e.value;
            if (std.mem.eql(u8, e.key, Key.collation)) m.collation = e.value;
            continue;
        }
        // A later entry of a column (of another spelling too) wins, as it
        // did when each reader scanned the entries.
        const c: *ColumnMeta = for (cols.items) |*x| {
            if (std.ascii.eqlIgnoreCase(x.name, e.col)) break x;
        } else blk: {
            const x = cols.addOne(a) catch return oom(db);
            x.* = .{ .name = e.col };
            break :blk x;
        };
        const field: ?*?[]const u8 = if (std.mem.eql(u8, e.key, Key.decl_type))
            &c.decl_type
        else if (std.mem.eql(u8, e.key, Key.identity))
            &c.identity
        else if (std.mem.eql(u8, e.key, Key.identity_kind))
            &c.identity_kind
        else if (std.mem.eql(u8, e.key, Key.collation))
            &c.collation
        else if (std.mem.eql(u8, e.key, Key.default))
            &c.default
        else
            null;
        if (field) |f| f.* = e.value;
    }
    if (m.dialect_name) |z| m.dialect = Dialect.fromName(z) orelse .sqlite;
    for (cols.items) |*c| {
        if (c.decl_type) |t| c.type = types.parse(m.dialect, t);
    }
    m.columns = cols.items;
    return m;
}

fn text(db: *Sqlite3, a: std.mem.Allocator, q: catalog.Query, i: usize) Error![]const u8 {
    return a.dupe(u8, api.columnText(q.v, i) orelse "") catch return oom(db);
}

fn oom(db: *Sqlite3) error{OutOfMemory} {
    _ = db;
    return error.OutOfMemory;
}

fn free(db: *Sqlite3, c: *Cache) void {
    c.arena.deinit();
    db.gpa.destroy(c);
}

// ======================================================== invalidation

/// Forget the catalog of schema `s` read into memory (with the rest of
/// the schema: build.schemaClear()).
pub fn drop(db: *Sqlite3, s: *int.Schema) void {
    const p = s.xq_meta orelse return;
    s.xq_meta = null;
    free(db, @ptrCast(@alignCast(p)));
}

/// Forget the catalog of every database read into memory.
pub fn dropAll(db: *Sqlite3) void {
    for (db.dbs.items) |d| drop(db, d.schema);
}

/// The connection writes xq_catalog (OP_SqlExec, catalog.set() ...):
/// drop what was read, and drop it again if the transaction, or the part
/// of it that wrote, is rolled back.
pub fn written(db: *Sqlite3) void {
    dropAll(db);
    db.xq.catalog_written = true;
}

/// The transaction was rolled back to a savepoint, or a statement's
/// changes were: drop what may have been read of the catalog it wrote.
pub fn rolledBack(db: *Sqlite3) void {
    if (db.xq.catalog_written) dropAll(db);
}

/// The transaction ended: rolled back (`committed` false) or committed.
pub fn ended(db: *Sqlite3, committed: bool) void {
    if (!committed) rolledBack(db);
    db.xq.catalog_written = false;
}
