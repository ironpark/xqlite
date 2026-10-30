//! Named schemas (namespaces) that are not SQLite databases, shared by
//! the dialects: PostgreSQL's CREATE SCHEMA, and the schemas of T-SQL,
//! Oracle and MariaDB.
//!
//! A named schema lives INSIDE the main database. Its objects are main
//! objects named `<schema>.<name>` ("mangled"): the table sales.orders
//! is the SQLite table "sales.orders" of main, its indexes, triggers and
//! sequences are mangled the same way. One file, one transaction, and
//! sqlite3 reads the table as "sales.orders".
//!
//! The registry is a row of xq_catalog (catalog.zig) per schema:
//!
//!     tbl = ''   col = <schema>   key = 'schema'    value = <owner>
//!     tbl = ''   col = <schema>   key = 'dialect'   value = <dialect>
//!
//! tbl '' is no table's name (no dialect accepts a zero-length name), so
//! the entries of a table (catalog.codeDeleteTable() ...) never touch a
//! schema's. A schema name never contains '.' (validName()): the mangled
//! name splits at its first dot. Names compare without case, as SQLite
//! compares object names.
//!
//! The dialect keeps what is its own: the name of its default schema
//! (PostgreSQL public, T-SQL dbo, Oracle the user, MariaDB the database),
//! whose objects are plain main objects, its temp schema, its
//! per-connection default (search_path, USE, CURRENT_SCHEMA) and its
//! error messages. This file only answers questions:
//!
//!   validName(name) bool                      can name a schema
//!   mangle(a, schema, name) ![]u8             "<schema>.<name>"
//!   split(mangled) ?Split                     at the first '.' (no lookup)
//!   list(db, a) Error![]Info                  the registry, by name
//!   find(schemas, name) ?Info                 lookup in a list (no case)
//!   exists(db, name) Error!bool               list() + find()
//!   codeCreate(p, name, owner)                register, when p runs
//!   objects(db, a, name) Error![]Object       what DROP SCHEMA drops
//!   codeDrop(p, name, objs) DropError!void    drop them and the entry
//!   resolve(db, schemas, cfg, schema, name)   QName -> SQLite (db, name)
//!
//! list() and objects() run statements of their own (catalog.Query):
//! a frontend calls them while compiling, after readSchema(), and keeps
//! the list for the statement. codeCreate() and codeDrop() add to the
//! statement being compiled (its transaction, as catalog.code*() do).

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const build = @import("../sql/build.zig");
const api = @import("../vdbe/api.zig");
const catalog = @import("catalog.zig");
const sequence = @import("sequence.zig");
const tree = @import("../ir/tree.zig");
const lower = @import("../ir/lower.zig");

const Sqlite3 = int.Sqlite3;
const Parse = int.Parse;
const Allocator = std.mem.Allocator;
pub const Error = catalog.Error;

/// The xq_catalog key of a schema's entry (tbl '', col the schema).
pub const key = "schema";

/// The separator of a mangled name.
pub const sep = '.';

/// A registered schema (slices in the allocator of list()).
pub const Info = struct { name: []const u8, owner: []const u8 };

/// Whether `name` can name a schema: not empty, no '.'.
pub fn validName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, sep) == null;
}

/// The SQLite name of object `name` of schema `schema`: "schema.name".
pub fn mangle(a: Allocator, schema: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{s}{c}{s}", .{ schema, sep, name });
}

pub const Split = struct { schema: []const u8, name: []const u8 };

/// A mangled name split at its first '.', null if it has none. It does
/// not ask whether the schema exists (a main object may have a dot in
/// its name): find() it in list().
pub fn split(mangled: []const u8) ?Split {
    const i = std.mem.indexOfScalar(u8, mangled, sep) orelse return null;
    if (i == 0 or i + 1 == mangled.len) return null;
    return .{ .schema = mangled[0..i], .name = mangled[i + 1 ..] };
}

/// The registered schemas, ordered by name, copied with `a`; none if
/// main has no catalog.
pub fn list(db: *Sqlite3, a: Allocator) Error![]Info {
    if (!try catalog.tableExists(db, catalog.main_schema, catalog.table_name)) return &.{};
    var q = try catalog.Query.init(db, "SELECT col,value FROM main.xq_catalog WHERE tbl='' AND key='" ++ key ++ "' ORDER BY col");
    defer q.deinit();
    var out: std.ArrayList(Info) = .empty;
    while (try q.step()) {
        const name = a.dupe(u8, api.columnText(q.v, 0) orelse "") catch return error.OutOfMemory;
        const owner = a.dupe(u8, api.columnText(q.v, 1) orelse "") catch return error.OutOfMemory;
        out.append(a, .{ .name = name, .owner = owner }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

/// The schema of `schemas` called `name` (without case), or null.
pub fn find(schemas: []const Info, name: []const u8) ?Info {
    for (schemas) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
    return null;
}

/// Whether schema `name` is registered (a query, now).
pub fn exists(db: *Sqlite3, name: []const u8) Error!bool {
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    return find(try list(db, arena.allocator()), name) != null;
}

/// Register schema `name` (owner `owner`, the connection's dialect) when
/// the statement being compiled runs. The caller checks first that it
/// does not exist (else the statement fails on xq_catalog's key).
pub fn codeCreate(p: *Parse, name: []const u8, owner: []const u8) void {
    catalog.codeExecFmt(p, catalog.main_schema, catalog.ddl ++ ";INSERT INTO main.xq_catalog VALUES('',%Q,'" ++ key ++ "',%Q),('',%Q,%Q,%Q)", &.{
        .{ .str = catalog.main_schema }, .{ .str = name },                .{ .str = owner },
        .{ .str = name },                .{ .str = catalog.Key.dialect }, .{ .str = p.db.xq.lang.dialect.name() },
    });
}

/// An object of a schema, as DROP SCHEMA drops it.
pub const Object = struct {
    kind: Kind,
    /// The SQLite (mangled) name.
    name: []const u8,

    pub const Kind = enum {
        table,
        view,
        /// A sequence no table's identity column owns.
        sequence,

        pub fn word(k: Kind) []const u8 {
            return @tagName(k);
        }
    };

    /// The name within the schema.
    pub fn bare(o: Object) []const u8 {
        return (split(o.name) orelse return o.name).name;
    }
};

/// The objects of schema `name` in main: its views, tables (with their
/// indexes and triggers) and the sequences no table owns, in the order
/// codeDrop() drops them. Copied with `a`.
pub fn objects(db: *Sqlite3, a: Allocator, name: []const u8) Error![]Object {
    const prefix = mangle(a, name, "") catch return error.OutOfMemory;
    var out: std.ArrayList(Object) = .empty;
    const s = db.dbs.items[0].schema;
    inline for (.{ Object.Kind.view, Object.Kind.table }) |kind| {
        var it = s.tbl_hash.valueIterator();
        while (it.next()) |t| {
            if ((kind == .view) != t.*.isView()) continue;
            if (!std.ascii.startsWithIgnoreCase(t.*.name, prefix)) continue;
            out.append(a, .{ .kind = kind, .name = a.dupe(u8, t.*.name) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        }
    }
    if (try catalog.tableExists(db, catalog.main_schema, sequence.table_name)) {
        const owned = if (catalog.exists(db, catalog.main_schema))
            " AND name NOT IN (SELECT value FROM main.xq_catalog WHERE key='identity')"
        else
            "";
        var q = try catalog.Query.initFmt(db, "SELECT name FROM main.xq_sequence WHERE substr(name,1,%d)=%Q COLLATE NOCASE%s ORDER BY name", &.{
            .{ .int = @intCast(prefix.len) }, .{ .str = prefix }, .{ .str = owned },
        });
        defer q.deinit();
        while (try q.step()) {
            const z = a.dupe(u8, api.columnText(q.v, 0) orelse "") catch return error.OutOfMemory;
            out.append(a, .{ .kind = .sequence, .name = z }) catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

pub const DropError = lower.Error || error{
    /// Several tables in an auto_vacuum database: their root pages would
    /// move between the drops of one statement (the message is in `p`).
    AutoVacuum,
};

/// Drop the objects `objs` (from objects()) of schema `name`, every
/// sequence and catalog entry left with its prefix, and the registry
/// entry, when the statement being compiled runs.
pub fn codeDrop(p: *Parse, name: []const u8, objs: []const Object) DropError!void {
    var tables: usize = 0;
    for (objs) |o| tables += @intFromBool(o.kind == .table);
    if (tables > 1) if (p.db.dbs.items[0].bt) |bt| if (bt.isAutoVacuum()) {
        @import("../sql/util.zig").errorMsg(p, "xqlite: dropping several tables in one statement is not supported in an auto_vacuum database", .{});
        return error.AutoVacuum;
    };
    var l: lower.Lowerer = .init(p, "");
    for (objs) |o| {
        const kind: tree.ObjectKind = switch (o.kind) {
            .table => .table,
            .view => .view,
            .sequence => continue,
        };
        const d: tree.Drop = .{ .kind = kind, .name = .{ .schema = .{ .text = catalog.main_schema }, .name = .{ .text = o.name } } };
        try l.drop(&d);
    }
    const prefix = try mangle(p.arena, name, "");
    if (sequence.exists(p.db, catalog.main_schema)) {
        catalog.codeExecFmt(p, catalog.main_schema, "DELETE FROM main.xq_sequence WHERE substr(name,1,%d)=%Q COLLATE NOCASE", &.{
            .{ .int = @intCast(prefix.len) }, .{ .str = prefix },
        });
    }
    catalog.codeExecFmt(p, catalog.main_schema, "DELETE FROM main.xq_catalog WHERE (substr(tbl,1,%d)=%Q COLLATE NOCASE) OR (tbl='' AND col=%Q COLLATE NOCASE)", &.{
        .{ .int = @intCast(prefix.len) }, .{ .str = prefix }, .{ .str = name },
    });
    if (p.n_err > 0) return error.Failed;
}

// ============================================================ resolving

/// What the dialect calls its schemas.
pub const Config = struct {
    /// The default schema: its objects are plain main objects (public,
    /// dbo ...); null for none.
    default_schema: ?[]const u8 = null,
    /// The schema of temporary objects (pg_temp), SQLite's temp; null
    /// for none.
    temp_schema: ?[]const u8 = null,
};

/// A name resolved to SQLite: the database (main, temp or an attached
/// one) and the name in it.
pub const Target = struct {
    db: []const u8,
    name: []const u8,
    /// The name is mangled (the object is in a named schema): a FROM item
    /// or DML target naming it takes `bare` as its alias, so that the
    /// dialect's `t.col` finds it.
    mangled: bool = false,
    bare: []const u8,
};

pub const ResolveError = Allocator.Error || error{
    /// No such schema (the dialect's "schema does not exist").
    NoSuchSchema,
};

/// The SQLite object of `schema.name` (case already folded by the
/// dialect): the default schema is main, the temp schema temp, a SQLite
/// database (main, temp, attached) itself, a registered schema
/// (`schemas`, from list()) main with the mangled name. Names are copied
/// into `a` when mangled. It does not ask whether the object exists.
pub fn resolve(db: *Sqlite3, a: Allocator, schemas: []const Info, cfg: Config, schema: []const u8, name: []const u8) ResolveError!Target {
    if (cfg.default_schema) |d| if (std.ascii.eqlIgnoreCase(schema, d)) return .{ .db = catalog.main_schema, .name = name, .bare = name };
    if (cfg.temp_schema) |t| if (std.ascii.eqlIgnoreCase(schema, t)) return .{ .db = "temp", .name = name, .bare = name };
    if (build.findDbName(db, schema)) |i| return .{ .db = db.dbs.items[i].name, .name = name, .bare = name };
    if (find(schemas, schema)) |s| return .{ .db = catalog.main_schema, .name = try mangle(a, s.name, name), .mangled = true, .bare = name };
    return error.NoSuchSchema;
}

test "mangle and split" {
    const a = std.testing.allocator;
    const m = try mangle(a, "sales", "orders");
    defer a.free(m);
    try std.testing.expectEqualStrings("sales.orders", m);
    const s = split(m).?;
    try std.testing.expectEqualStrings("sales", s.schema);
    try std.testing.expectEqualStrings("orders", s.name);
    try std.testing.expectEqualStrings("a.b", split("s.a.b").?.name);
    try std.testing.expect(split("plain") == null);
    try std.testing.expect(split(".x") == null);
    try std.testing.expect(validName("sales"));
    try std.testing.expect(!validName("a.b"));
    try std.testing.expect(!validName(""));
    const list_ = [_]Info{ .{ .name = "sales", .owner = "x" }, .{ .name = "hr", .owner = "y" } };
    try std.testing.expectEqualStrings("hr", find(&list_, "HR").?.name);
    try std.testing.expect(find(&list_, "nope") == null);
}
