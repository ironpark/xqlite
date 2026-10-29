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

pub const sequence = @import("sequence.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const RC = int.RC;
const OP = vi.OP;

pub const Error = int.Error;

pub const table_name = "xq_catalog";

/// The CREATE TABLE of xq_catalog (%Q: the schema name).
pub const ddl = "CREATE TABLE IF NOT EXISTS %Q.xq_catalog(tbl TEXT NOT NULL,col TEXT NOT NULL,key TEXT NOT NULL,value,PRIMARY KEY(tbl,col,key))WITHOUT ROWID";

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

/// Remove every entry of `tbl` now.
pub fn deleteTable(db: *Sqlite3, schema: []const u8, tbl: []const u8) Error!void {
    if (!try tableExists(db, schema, table_name)) return;
    try execFmt(db, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = tbl } });
}

/// Whether `schema` has a table `name`, reading the schema first.
pub fn tableExists(db: *Sqlite3, schema: []const u8, name: []const u8) Error!bool {
    var q = try Query.initFmt(db, "SELECT 1 FROM %Q.sqlite_schema WHERE type='table' AND name=%Q", &.{ .{ .str = schema }, .{ .str = name } });
    defer q.deinit();
    return q.step();
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
