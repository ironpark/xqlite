//! T-SQL schemas: CREATE SCHEMA, DROP SCHEMA, ALTER SCHEMA ... TRANSFER,
//! ALTER USER ... WITH DEFAULT_SCHEMA, and the functions over schemas
//! (SCHEMA_ID, SCHEMA_NAME, OBJECT_NAME, OBJECT_SCHEMA_NAME) that the
//! catalog views use too.
//!
//! A schema of CREATE SCHEMA is catalog/schema.zig's: its objects are
//! main objects named "<schema>.<name>" (parser.zig resolves s.t to
//! them), the registry is in xq_catalog. dbo is main's plain names.
//! SQL Server's schema_id of a schema is kept next to its registry entry
//!
//!     tbl = ''   col = <schema>   key = 'schema_id'   value = <id>
//!
//! the lowest free id from 5 on, as SQL Server gives them (dbo 1, guest
//! 2, INFORMATION_SCHEMA 3, sys 4 and the db_* role schemas are fixed).
//! codeDrop() deletes it with the schema's other entries.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const api = @import("../../vdbe/api.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const session = @import("session.zig");

const nsp = catalog.schemas;
const Parser = parser.Parser;
const Error = parser.Error;
const Name = tree.Name;
const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Sqlite3 = @import("../../sql/sqlite_int.zig").Sqlite3;

/// The xq_catalog key of a schema's schema_id.
pub const id_key = "schema_id";

/// The schemas every SQL Server database has: name and schema_id (also
/// their principal_id and owner).
pub const builtin = [_]struct { []const u8, i64 }{
    .{ "dbo", 1 },                   .{ "guest", 2 },              .{ "INFORMATION_SCHEMA", 3 },   .{ "sys", 4 },
    .{ "db_owner", 16384 },          .{ "db_accessadmin", 16385 }, .{ "db_securityadmin", 16386 }, .{ "db_ddladmin", 16387 },
    .{ "db_backupoperator", 16389 }, .{ "db_datareader", 16390 },  .{ "db_datawriter", 16391 },    .{ "db_denydatareader", 16392 },
    .{ "db_denydatawriter", 16393 },
};

pub fn builtinId(name: []const u8) ?i64 {
    for (builtin) |b| if (std.ascii.eqlIgnoreCase(b[0], name)) return b[1];
    return null;
}

/// Whether the statement at `s` is an element of CREATE SCHEMA: CREATE
/// TABLE, CREATE VIEW, GRANT, REVOKE or DENY.
pub fn isElement(s: *Parser) bool {
    if (s.isKw("CREATE")) return s.peek().isAnyKw(&.{ "TABLE", "VIEW" });
    return s.isAnyKw(&.{ "GRANT", "REVOKE", "DENY" });
}

// ======================================================= CREATE SCHEMA

/// CREATE SCHEMA s [AUTHORIZATION owner] [elements]: the elements (CREATE
/// TABLE, CREATE VIEW, GRANT ...) that follow up to the end of the
/// statement are compiled after it, in s (state.schema_element).
pub fn create(s: *Parser) Error!void {
    try s.expectKw("SCHEMA");
    const n = try s.nameOf(try s.anyName());
    var owner: []const u8 = "dbo";
    if (s.eatKw("AUTHORIZATION")) owner = try s.nameText(try s.anyName());
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (builtinId(n.text) != null) return s.noSchema(n.text);
    if (try s.findSchema(n.text) != null) return s.fail("There is already an object named '{s}' in the database.", .{n.text});
    if (!nsp.validName(n.text)) return s.fail("xqlite: a schema name cannot contain '.'", .{});
    if (try s.sqliteDb(n.text, n.pos) != null) return s.fail("xqlite: '{s}' names a database; it cannot name a schema", .{n.text});
    nsp.codeCreate(s.p, n.text, owner);
    // The lowest schema_id from 5 on that no schema has.
    catalog.codeExecFmt(s.p, catalog.main_schema, "INSERT INTO main.xq_catalog SELECT '',%Q,'" ++ id_key ++ "',min(x.id+1) FROM " ++
        "(SELECT 4 AS id UNION ALL SELECT value FROM main.xq_catalog WHERE tbl='' AND key='" ++ id_key ++ "') x " ++
        "WHERE x.id+1 NOT IN (SELECT value FROM main.xq_catalog WHERE tbl='' AND key='" ++ id_key ++ "')", &.{.{ .str = n.text }});
    if (isElement(s)) {
        const st = &s.p.db.xq.mssql;
        @TypeOf(st.*).setText(s.p.db.gpa, &st.schema_element, n.text) catch return error.OutOfMemory;
    }
}

/// GRANT/REVOKE/DENY as an element of CREATE SCHEMA: accepted and
/// ignored (xqlite has no permissions). Up to the principals after TO
/// (FROM) and WITH GRANT OPTION, CASCADE or AS principal.
pub fn skipPermission(s: *Parser) Error!void {
    s.advance(); // GRANT, REVOKE, DENY
    while (!(s.isKw("TO") or s.isKw("FROM"))) {
        if (s.tok.kind == .eof or s.isOp(";") or s.tok.kind == .go) return s.syntaxError();
        s.advance();
    }
    s.advance();
    while (true) {
        _ = try s.anyName();
        if (!s.eatOp(",")) break;
    }
    if (s.isKw("WITH") and s.peek().isKw("GRANT")) {
        s.advance();
        s.advance();
        try s.expectKw("OPTION");
    }
    _ = s.eatKw("CASCADE");
    if (s.eatKw("AS")) _ = try s.anyName();
    return session.emptyStatement(s);
}

// ========================================================= DROP SCHEMA

/// DROP SCHEMA [IF EXISTS] s: s must be empty (SQL Server has no
/// CASCADE).
pub fn drop(s: *Parser) Error!void {
    try s.expectKw("SCHEMA");
    const if_exists = try s.ifExists();
    const n = try s.nameOf(try s.anyName());
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (builtinId(n.text) != null) return s.fail("Cannot drop the schema '{s}'.", .{n.text});
    const info = (try s.findSchema(n.text)) orelse {
        if (if_exists) return session.emptyStatement(s);
        return s.fail("Cannot drop the schema '{s}', because it does not exist or you do not have permission.", .{n.text});
    };
    const objs = nsp.objects(s.p.db, s.a, info.name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
    };
    if (objs.len > 0) {
        // SQL Server names the first by name.
        var first = objs[0].bare();
        for (objs[1..]) |o| if (std.ascii.lessThanIgnoreCase(o.bare(), first)) {
            first = o.bare();
        };
        return s.fail("Cannot drop schema '{s}' because it is being referenced by object '{s}'.", .{ n.text, first });
    }
    nsp.codeDrop(s.p, info.name, &.{}) catch return error.ParseFailed;
}

// ======================================================= ALTER SCHEMA

/// ALTER SCHEMA s TRANSFER [OBJECT::]x.t: the table moves to s (renamed
/// "s.t", or t for dbo). Its indexes keep their names; a view, or a
/// table with an IDENTITY column (whose sequence is named after its
/// schema), is not supported.
pub fn transfer(s: *Parser) Error!void {
    try s.expectKw("SCHEMA");
    const to = try s.nameOf(try s.anyName());
    try s.expectKw("TRANSFER");
    if (s.isKw("OBJECT") and s.peek().is("::")) {
        s.advance();
        s.advance();
    } else if (s.peek().is("::")) return s.fail("xqlite: ALTER SCHEMA ... TRANSFER {s}:: is not supported", .{s.tok.text});
    const q = try s.qualifiedName();
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    var prefix: []const u8 = "";
    if (!std.ascii.eqlIgnoreCase(to.text, "dbo")) {
        const info = (try s.findSchema(to.text)) orelse
            return s.fail("Cannot alter the schema '{s}', because it does not exist or you do not have permission.", .{to.text});
        prefix = try nsp.mangle(s.a, info.name, "");
    }
    const bare = try s.bareName(q.name.text);
    const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse
        return s.fail("Cannot find the object '{s}', because it does not exist or you do not have permission.", .{bare});
    if (!std.mem.eql(u8, catalog.schemaName(s.p.db, tab), catalog.main_schema)) return s.fail("xqlite: ALTER SCHEMA ... TRANSFER of an object of another database is not supported", .{});
    if (tab.isView()) return s.fail("xqlite: ALTER SCHEMA ... TRANSFER of a view is not supported", .{});
    const t = try s.target(q);
    if (t.identity() != null) return s.fail("xqlite: ALTER SCHEMA ... TRANSFER of a table with an IDENTITY column is not supported", .{});
    const new = try std.fmt.allocPrint(s.a, "{s}{s}", .{ prefix, bare });
    if (std.ascii.eqlIgnoreCase(new, tab.name)) return session.emptyStatement(s);
    if (build.findTable(s.p.db, new, catalog.main_schema) != null) return s.fail("The object with name \"{s}\" already exists.", .{bare});
    const at = try s.new(tree.AlterTable, .{
        .name = .{ .schema = .{ .text = catalog.main_schema }, .name = .{ .text = try s.a.dupe(u8, tab.name), .pos = q.name.pos } },
        .action = .{ .rename_to = .{ .text = new, .pos = q.name.pos } },
    });
    return s.lowerStmt(.{ .alter_table = at });
}

// ========================================================= ALTER USER

/// ALTER USER u WITH DEFAULT_SCHEMA = s | NULL: unqualified names resolve
/// in s (then dbo) and are created there, for the session (xqlite has no
/// users: whatever u is).
pub fn alterUser(s: *Parser) Error!void {
    try s.expectKw("USER");
    _ = try s.anyName();
    try s.expectKw("WITH");
    const pos = s.here();
    var value: ?*tree.Expr = null;
    while (true) {
        if (!s.eatKw("DEFAULT_SCHEMA")) return s.fail("xqlite: ALTER USER ... WITH {s} is not supported", .{s.tok.text});
        try s.expectOp("=");
        if (s.eatKw("NULL")) {
            value = try s.mk(pos, .null);
        } else {
            const n = try s.nameText(try s.anyName());
            value = if (std.ascii.eqlIgnoreCase(n, "dbo")) try s.mk(pos, .null) else try s.str(pos, n);
        }
        if (!s.eatOp(",")) break;
    }
    return session.codeEval(s, &.{try s.func(pos, "xq_tsql_default_schema", &.{value.?})});
}

// ============================================================ runtime

const Entry = struct { name: []const u8, id: i64 };

/// The schemas of CREATE SCHEMA with their schema_id (one another dialect
/// made has none: 65536 on).
fn registry(db: *Sqlite3, a: std.mem.Allocator) catalog.Error![]Entry {
    if (!catalog.exists(db, catalog.main_schema)) return &.{};
    var q = try catalog.Query.init(db, "SELECT c.col, i.value FROM main.xq_catalog c LEFT JOIN main.xq_catalog i ON i.tbl='' AND i.col=c.col AND i.key='" ++ id_key ++ "' WHERE c.tbl='' AND c.key='" ++ nsp.key ++ "' ORDER BY c.col");
    defer q.deinit();
    var out: std.ArrayList(Entry) = .empty;
    var n: i64 = 0;
    while (try q.step()) {
        const name = a.dupe(u8, api.columnText(q.v, 0) orelse "") catch return error.OutOfMemory;
        const id: i64 = if (api.columnType(q.v, 1) == 5) 65536 + n else api.columnInt64(q.v, 1);
        n += 1;
        out.append(a, .{ .name = name, .id = id }) catch return error.OutOfMemory;
    }
    return out.items;
}

fn idOf(reg: []const Entry, name: []const u8) ?i64 {
    if (builtinId(name)) |i| return i;
    for (reg) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e.id;
    return null;
}

fn nameOf(reg: []const Entry, id: i64) ?[]const u8 {
    for (builtin) |b| if (b[1] == id) return b[0];
    for (reg) |e| if (e.id == id) return e.name;
    return null;
}

/// The schema and the name within it of main object `z`.
fn splitName(reg: []const Entry, z: []const u8) struct { []const u8, []const u8 } {
    if (nsp.split(z)) |sp| for (reg) |e| if (std.ascii.eqlIgnoreCase(e.name, sp.schema)) return .{ e.name, sp.name };
    return .{ "dbo", z };
}

/// The session's default schema (ALTER USER), dbo if none or gone.
fn defaultSchema(db: *Sqlite3, reg: []const Entry) []const u8 {
    const d = db.xq.mssql.default_schema orelse return "dbo";
    for (reg) |e| if (std.ascii.eqlIgnoreCase(e.name, d)) return e.name;
    return "dbo";
}

fn failed(ctx: *Context, db: *Sqlite3, err: catalog.Error) void {
    if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
    api.resultError(ctx, @import("../../sql/main.zig").errmsg(db));
}

fn resultCopy(ctx: *Context, z: []const u8) void {
    api.resultText(ctx, z, .transient);
}

/// xq_tsql_default_schema(s): ALTER USER ... WITH DEFAULT_SCHEMA (NULL:
/// dbo).
pub fn defaultSchemaFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const st = &db.xq.mssql;
    @TypeOf(st.*).setText(db.gpa, &st.default_schema, api.valueText(argv[0])) catch return api.resultErrorNomem(ctx);
    api.resultNull(ctx);
}

/// SCHEMA_ID([name]): the schema_id of a schema, the default schema's
/// without an argument.
pub fn schemaIdFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 1 and dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const db = api.contextDbHandle(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const reg = registry(db, arena.allocator()) catch |err| return failed(ctx, db, err);
    const name = if (argv.len == 1) (api.valueText(argv[0]) orelse "") else defaultSchema(db, reg);
    const id = idOf(reg, name) orelse return api.resultNull(ctx);
    api.resultInt64(ctx, id);
}

/// SCHEMA_NAME([id]): the name of the schema of that schema_id, the
/// default schema's without an argument.
pub fn schemaNameFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len == 1 and dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const db = api.contextDbHandle(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const reg = registry(db, arena.allocator()) catch |err| return failed(ctx, db, err);
    if (argv.len == 0) return resultCopy(ctx, defaultSchema(db, reg));
    const name = nameOf(reg, api.valueInt64(argv[0])) orelse return api.resultNull(ctx);
    resultCopy(ctx, name);
}

/// The main object of rowid `id` (OBJECT_ID()), its name in sqlite_schema.
fn objectById(db: *Sqlite3, a: std.mem.Allocator, id: i64) catalog.Error!?[]const u8 {
    var q = try catalog.Query.init(db, "SELECT name FROM main.sqlite_schema WHERE rowid=?1 AND type IN ('table','view')");
    defer q.deinit();
    try q.bindInt(1, id);
    if (!try q.step()) return null;
    return a.dupe(u8, api.columnText(q.v, 0) orelse "") catch error.OutOfMemory;
}

/// OBJECT_NAME(id) (which = 1) and OBJECT_SCHEMA_NAME(id) (which = 0) of
/// a main table or view.
fn objectPart(ctx: *Context, argv: []*Mem, which: usize) void {
    if (dfunc.isNull(argv[0])) return api.resultNull(ctx);
    const db = api.contextDbHandle(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const reg = registry(db, a) catch |err| return failed(ctx, db, err);
    const z = (objectById(db, a, api.valueInt64(argv[0])) catch |err| return failed(ctx, db, err)) orelse return api.resultNull(ctx);
    const parts = splitName(reg, z);
    resultCopy(ctx, if (which == 0) parts[0] else parts[1]);
}

pub fn objectNameFunc(ctx: *Context, argv: []*Mem) void {
    objectPart(ctx, argv, 1);
}

pub fn objectSchemaNameFunc(ctx: *Context, argv: []*Mem) void {
    objectPart(ctx, argv, 0);
}

/// xq_tsql_schema_of(name) and xq_tsql_bare_name(name): the schema of a
/// main object named `name` and its name in it (catalog views).
fn namePart(ctx: *Context, argv: []*Mem, which: usize) void {
    const z = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    if (nsp.split(z) == null) return resultCopy(ctx, if (which == 0) "dbo" else z);
    const db = api.contextDbHandle(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const reg = registry(db, arena.allocator()) catch |err| return failed(ctx, db, err);
    const parts = splitName(reg, z);
    resultCopy(ctx, if (which == 0) parts[0] else parts[1]);
}

pub fn schemaOfFunc(ctx: *Context, argv: []*Mem) void {
    namePart(ctx, argv, 0);
}

pub fn bareNameFunc(ctx: *Context, argv: []*Mem) void {
    namePart(ctx, argv, 1);
}
