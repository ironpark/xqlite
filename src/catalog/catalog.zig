//! The dialect catalog: metadata that SQLite's schema cannot hold (the
//! dialect a table was created in, declared types such as varchar(20) or
//! numeric(10,2), identity columns, dialect collations ...) kept in
//! ordinary tables of the database, so that sqlite3 still opens, reads
//! and checks a file xqlite wrote:
//!
//!     CREATE TABLE xq_catalog(
//!       tbl TEXT NOT NULL,   -- table (or other object) name
//!       col TEXT NOT NULL,   -- column name, '' for the table itself
//!       key TEXT NOT NULL,   -- Key below, or a dialect's own ("pg.xxx")
//!       value,               -- text
//!       PRIMARY KEY(tbl, col, key)
//!     ) WITHOUT ROWID
//!
//! and the sequences of sequence.zig in xq_sequence. Both are created on
//! demand, the first time a dialect feature writes to them: a database
//! that never uses one stays byte for byte what SQLite would write.
//!
//! There are two ways to write, both inside the current transaction:
//!  - code*() functions add to the statement being compiled (a *Parse):
//!    the change happens when the statement runs, atomically with it, as
//!    the sqlite_schema and sqlite_sequence updates of CREATE TABLE do.
//!    This is what a frontend lowering DDL uses.
//!  - the other functions act now on a connection (*Sqlite3), running
//!    SQL statements of their own: in the open transaction if there is
//!    one, else each in its own. They may be called while a statement
//!    runs (from an SQL function, as nextval() does).
//!
//! Object names are stored as given: folding case is the frontend's job.
//! All statements are SQLite text, compiled with Lang.sqlite.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const build = @import("../sql/build.zig");
const prepare = @import("../sql/prepare.zig");
const printf = @import("../sql/printf.zig");
const main_mod = @import("../sql/main.zig");
const api = @import("../vdbe/api.zig");
const aux = @import("../vdbe/aux.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const Quoted = @import("../dialect/dialect.zig").Quoted;

pub const sequence = @import("sequence.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;
const OP = vi.OP;

pub const Error = int.Error;

pub const table_name = "xq_catalog";

/// The CREATE TABLE of xq_catalog (%Q: the schema name).
pub const ddl = "CREATE TABLE IF NOT EXISTS %Q" ++ ddl_rest;
const ddl_rest = ".xq_catalog(tbl TEXT NOT NULL,col TEXT NOT NULL,key TEXT NOT NULL,value,PRIMARY KEY(tbl,col,key))WITHOUT ROWID";

/// A condition on a table name, true for all but xqlite's own tables
/// (xq_catalog, xq_sequence), to put after the name in SQLite,
/// PostgreSQL or MariaDB text: `"name" ++ not_catalog_table`.
pub const not_catalog_table = " NOT IN ('" ++ table_name ++ "','" ++ sequence.table_name ++ "')";

/// The keys xqlite defines. A dialect may add its own, prefixed with its
/// name and a dot ("pg.", "mariadb.").
pub const Key = struct {
    /// Table: the dialect that created it (Dialect.name()).
    pub const dialect = "dialect";
    /// Column: the declared type as written in the dialect
    /// ("varchar(20)", "numeric(10,2)"); the SQLite schema holds the
    /// storage type the frontend chose (see ir.ddl.strictStorageType()).
    pub const decl_type = "type";
    /// Column: the sequence (sequence.zig) that numbers an identity,
    /// SERIAL or AUTO_INCREMENT column.
    pub const identity = "identity";
    /// Column: "always" or "by default" for an identity column.
    pub const identity_kind = "identity_kind";
    /// Column (or table, as the default of its columns): the collation
    /// as named in the dialect; the SQLite schema holds the built-in
    /// collation it maps to.
    pub const collation = "collation";
    /// Column: the default expression as written in the dialect.
    pub const default = "default";
};

/// The name of the main database, the default schema of these
/// functions.
pub const main_schema = "main";

/// One entry: the `key` of column `col` ('' for the table itself).
pub const Entry = struct { col: []const u8, key: []const u8, value: []const u8 };

/// The name of the schema ("main", "temp" or an attached name) of table
/// `t`.
pub fn schemaName(db: *Sqlite3, t: *const int.Table) []const u8 {
    const i = prepare.schemaToIndex(db, t.schema);
    return if (i < 0) main_schema else db.dbs.items[@intCast(i)].name;
}

// ===================================================== code generation

/// Run `sql` (SQLite text, any number of statements) when the statement
/// being compiled runs, in its transaction, as a write to schema `i_db`
/// (C: the OP_SqlExec of ALTER TABLE). Errors stop the statement.
pub fn codeExec(p: *Parse, i_db: usize, sql: [:0]const u8) void {
    const v = build.getVdbe(p) orelse return;
    build.beginWriteOperation(p, false, i_db);
    _ = aux.addOp4Str(v, OP.SqlExec, 0x0001, 0, 0, sql);
}

/// codeExec() of SQL formatted by SQLite's printf (%Q, %w ...).
pub fn codeExecFmt(p: *Parse, schema: []const u8, fmt: []const u8, args: []const printf.Arg) void {
    const i_db = schemaIndex(p, schema) orelse return;
    const sql = build.mprintf(p, fmt, args) catch return build.oomFault(p);
    codeExec(p, i_db, sql);
}

/// The index of schema `schema` ("main", "temp" or an attached name), or
/// null with an error left in `p`.
pub fn schemaIndex(p: *Parse, schema: []const u8) ?usize {
    if (build.findDbName(p.db, schema)) |i| return i;
    @import("../sql/util.zig").errorMsg(p, "unknown database {s}", .{schema});
    return null;
}

/// Set (or with a null value, remove) the entry `key` of column `col`
/// ('' for the table) of `tbl`, when the statement runs.
pub fn codeSet(p: *Parse, schema: []const u8, tbl: []const u8, col: []const u8, key: []const u8, value: ?[]const u8) void {
    if (value) |z| {
        codeExecFmt(p, schema, ddl ++ ";INSERT OR REPLACE INTO %Q.xq_catalog VALUES(%Q,%Q,%Q,%Q)", &.{
            .{ .str = schema }, .{ .str = schema }, .{ .str = tbl }, .{ .str = col }, .{ .str = key }, .{ .str = z },
        });
    } else {
        codeExecFmt(p, schema, ddl ++ ";DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q AND key=%Q", &.{
            .{ .str = schema }, .{ .str = schema }, .{ .str = tbl }, .{ .str = col }, .{ .str = key },
        });
    }
}

/// SQL text that creates the catalog of `schema` if needed and sets the
/// entries `list` of `tbl`, for a frontend that runs it with other SQL of
/// its own (codeSetAll() runs it alone).
pub fn writeSetAll(w: *std.Io.Writer, schema: []const u8, tbl: []const u8, list: []const Entry) std.Io.Writer.Error!void {
    const S = Quoted('\'');
    try w.print("CREATE TABLE IF NOT EXISTS {f}" ++ ddl_rest, .{S{ .z = schema }});
    if (list.len == 0) return;
    try w.print(";INSERT OR REPLACE INTO {f}.xq_catalog VALUES", .{S{ .z = schema }});
    for (list, 0..) |e, i| {
        try w.print("{s}({f},{f},{f},{f})", .{ if (i > 0) "," else "", S{ .z = tbl }, S{ .z = e.col }, S{ .z = e.key }, S{ .z = e.value } });
    }
}

/// codeSet() of the entries `list` of `tbl` (one INSERT).
pub fn codeSetAll(p: *Parse, schema: []const u8, tbl: []const u8, list: []const Entry) void {
    const i_db = schemaIndex(p, schema) orelse return;
    var out: std.Io.Writer.Allocating = .init(p.arena);
    writeSetAll(&out.writer, schema, tbl, list) catch return build.oomFault(p);
    const sql = out.toOwnedSliceSentinel(0) catch return build.oomFault(p);
    codeExec(p, i_db, sql);
}

/// Remove every entry of `tbl` (after DROP TABLE), when the statement
/// runs. Codes nothing if there is no catalog.
pub fn codeDeleteTable(p: *Parse, schema: []const u8, tbl: []const u8) void {
    if (!exists(p.db, schema)) return;
    codeExecFmt(p, schema, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = tbl } });
}

/// Move the entries of `old` to `new` (after ALTER TABLE RENAME), when
/// the statement runs. Codes nothing if there is no catalog.
pub fn codeRenameTable(p: *Parse, schema: []const u8, old: []const u8, new: []const u8) void {
    if (!exists(p.db, schema)) return;
    codeExecFmt(p, schema, "UPDATE %Q.xq_catalog SET tbl=%Q WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = new }, .{ .str = old } });
}

/// Move the entries of column `old` of `tbl` to `new` (after ALTER TABLE
/// RENAME COLUMN), when the statement runs. Codes nothing if there is no
/// catalog.
pub fn codeRenameColumn(p: *Parse, schema: []const u8, tbl: []const u8, old: []const u8, new: []const u8) void {
    if (!exists(p.db, schema)) return;
    codeExecFmt(p, schema, "UPDATE %Q.xq_catalog SET col=%Q WHERE tbl=%Q AND col=%Q", &.{ .{ .str = schema }, .{ .str = new }, .{ .str = tbl }, .{ .str = old } });
}

/// Remove the entries of column `col` of `tbl` (after ALTER TABLE DROP
/// COLUMN), when the statement runs. Codes nothing if there is no
/// catalog.
pub fn codeDeleteColumn(p: *Parse, schema: []const u8, tbl: []const u8, col: []const u8) void {
    if (!exists(p.db, schema)) return;
    codeExecFmt(p, schema, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q", &.{ .{ .str = schema }, .{ .str = tbl }, .{ .str = col } });
}

/// Whether schema `schema` has the catalog table (as far as the schema
/// read so far knows).
pub fn exists(db: *Sqlite3, schema: []const u8) bool {
    return build.findTable(db, table_name, schema) != null;
}

// ============================================================== runtime

/// Set (or with a null value, remove) an entry now.
pub fn set(db: *Sqlite3, schema: []const u8, tbl: []const u8, col: []const u8, key: []const u8, value: ?[]const u8) Error!void {
    try execFmt(db, ddl, &.{.{ .str = schema }});
    if (value) |z| {
        try execFmt(db, "INSERT OR REPLACE INTO %Q.xq_catalog VALUES(%Q,%Q,%Q,%Q)", &.{
            .{ .str = schema }, .{ .str = tbl }, .{ .str = col }, .{ .str = key }, .{ .str = z },
        });
    } else {
        try execFmt(db, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q AND key=%Q", &.{
            .{ .str = schema }, .{ .str = tbl }, .{ .str = col }, .{ .str = key },
        });
    }
}

/// The value of an entry, copied with `gpa`; null if there is none (or
/// no catalog).
pub fn get(db: *Sqlite3, gpa: std.mem.Allocator, schema: []const u8, tbl: []const u8, col: []const u8, key: []const u8) Error!?[]u8 {
    if (!try tableExists(db, schema, table_name)) return null;
    var q = try Query.initFmt(db, "SELECT value FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q AND key=%Q", &.{
        .{ .str = schema }, .{ .str = tbl }, .{ .str = col }, .{ .str = key },
    });
    defer q.deinit();
    if (!try q.step()) return null;
    const z = api.columnText(q.v, 0) orelse return null;
    return gpa.dupe(u8, z) catch error.OutOfMemory;
}

/// All the entries of `tbl` (col, key, value), copied with `gpa`; none if
/// there is no catalog.
pub fn entries(db: *Sqlite3, gpa: std.mem.Allocator, schema: []const u8, tbl: []const u8) Error![]Entry {
    if (!try tableExists(db, schema, table_name)) return &.{};
    var q = try Query.initFmt(db, "SELECT col,key,value FROM %Q.xq_catalog WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = tbl } });
    defer q.deinit();
    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.col);
            gpa.free(e.key);
            gpa.free(e.value);
        }
        list.deinit(gpa);
    }
    while (try q.step()) {
        const col = try dupeColumn(gpa, q, 0);
        errdefer gpa.free(col);
        const key = try dupeColumn(gpa, q, 1);
        errdefer gpa.free(key);
        const value = try dupeColumn(gpa, q, 2);
        errdefer gpa.free(value);
        list.append(gpa, .{ .col = col, .key = key, .value = value }) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(gpa) catch error.OutOfMemory;
}

fn dupeColumn(gpa: std.mem.Allocator, q: Query, i: usize) Error![]u8 {
    return gpa.dupe(u8, api.columnText(q.v, i) orelse "") catch error.OutOfMemory;
}

/// Remove every entry of `tbl` now.
pub fn deleteTable(db: *Sqlite3, schema: []const u8, tbl: []const u8) Error!void {
    if (!try tableExists(db, schema, table_name)) return;
    try execFmt(db, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = tbl } });
}

/// Whether `schema` has a table `name` (in the schema in memory, read
/// first if it was not).
pub fn tableExists(db: *Sqlite3, schema: []const u8, name: []const u8) Error!bool {
    if (!db.init.busy) {
        var msg: ?[:0]u8 = null;
        const rc = prepare.init(db, &msg);
        if (msg) |m| {
            defer db.gpa.free(m);
            if (rc != RC.OK) main_mod.errorWithMsg(db, rc, "{s}", .{m});
        }
        try int.check(rc);
    }
    return build.findTable(db, name, schema) != null;
}

// =============================================== statements of the catalog

/// Run SQL formatted by SQLite's printf, ignoring rows.
pub fn execFmt(db: *Sqlite3, fmt: []const u8, args: []const printf.Arg) Error!void {
    var q = try Query.initFmt(db, fmt, args);
    defer q.deinit();
    while (try q.step()) {}
}

/// One statement of the catalog, compiled with Lang.sqlite. Its errors
/// are the connection's (main.errmsg()).
pub const Query = struct {
    v: *vi.Vdbe,

    pub fn init(db: *Sqlite3, sql: []const u8) Error!Query {
        var stmt: ?*vi.Vdbe = null;
        try int.check(prepare.prepareLang(db, sql, .sqlite, 0, &stmt, null));
        return .{ .v = stmt orelse return error.Misuse };
    }

    pub fn initFmt(db: *Sqlite3, fmt: []const u8, args: []const printf.Arg) Error!Query {
        const sql = printf.mprintf(db.gpa, fmt, args) catch {
            db.oomFault();
            return error.OutOfMemory;
        };
        defer db.gpa.free(sql);
        return init(db, sql);
    }

    pub fn bindInt(q: Query, i: usize, value: i64) Error!void {
        try int.check(api.bindInt64(q.v, i, value));
    }

    pub fn bindText(q: Query, i: usize, value: []const u8) Error!void {
        try int.check(api.bindText(q.v, i, value));
    }

    /// Step: true for a row, false when done.
    pub fn step(q: Query) Error!bool {
        const rc = api.step(q.v);
        if (rc == RC.ROW) return true;
        if (rc == RC.DONE) return false;
        return int.codeError(rc);
    }

    pub fn deinit(q: Query) void {
        _ = api.finalize(q.v);
    }
};

test {
    _ = sequence;
}
