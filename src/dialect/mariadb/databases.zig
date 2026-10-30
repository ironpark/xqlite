//! MariaDB's databases: CREATE/DROP DATABASE (SCHEMA), USE, SHOW
//! DATABASES, SHOW CREATE DATABASE, SHOW TABLES, and the SQL that the
//! catalog views use to show a table's database.
//!
//! The databases are:
//!  - main, the default (the current database of a new connection);
//!  - the SQLite databases of ATTACH (and temp, for temporary tables);
//!  - the databases of CREATE DATABASE: named schemas of
//!    src/catalog/schema.zig, inside main. Table t of database sales is
//!    the main table "sales.t", its index i "sales.t$i", its
//!    AUTO_INCREMENT counter the sqlite_sequence row "sales.t", its
//!    catalog entries those of "sales.t". sqlite3 reads it as
//!    "sales.t". The default character set and collation of the
//!    database are its xq_catalog entry (tbl '', col <db>, key
//!    'collation').
//!
//! Names are resolved when a statement is compiled (Parser.relation()),
//! so USE (and DROP DATABASE of the current database, which leaves none
//! selected, as in MariaDB) runs xq_maria_use() when the statement runs,
//! which expires the prepared statements: they are compiled again in
//! the new database when they next run.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const dfunc = @import("../func.zig");
const parser = @import("parser.zig");
const session = @import("session.zig");
const state = @import("state.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Q = session.Q;
const Id = session.Id;

/// The databases that are not SQLite's nor CREATE DATABASE's.
fn isSystem(name: []const u8) bool {
    for ([_][]const u8{ "information_schema", "mysql", "performance_schema", "sys" }) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

/// The default collation of character set `cs` (MariaDB 11's
/// character_set_collations), null if xqlite does not know it.
fn defaultCollation(cs: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "utf8mb4", "utf8mb4_uca1400_ai_ci" }, .{ "utf8mb3", "utf8mb3_uca1400_ai_ci" },
        .{ "utf8", "utf8mb3_uca1400_ai_ci" },    .{ "latin1", "latin1_swedish_ci" },
        .{ "ascii", "ascii_general_ci" },        .{ "binary", "binary" },
        .{ "ucs2", "ucs2_uca1400_ai_ci" },       .{ "utf16", "utf16_uca1400_ai_ci" },
        .{ "utf32", "utf32_uca1400_ai_ci" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(cs, m[0])) return m[1];
    return null;
}

/// The collation of a database without CHARACTER SET or COLLATE (the
/// server's, MariaDB 11's default).
pub const server_collation = "utf8mb4_uca1400_ai_ci";

/// The collation main and the attached databases report (the MariaDB
/// dialect's tables default to utf8mb4_general_ci).
pub const main_collation = "utf8mb4_general_ci";

/// [DEFAULT] {CHARACTER SET | CHARSET} [=] cs | [DEFAULT] COLLATE [=] c |
/// COMMENT [=] 'text' ...: the collation they ask for, null for none.
fn databaseOptions(s: *Parser) Error!?[]const u8 {
    var cs: ?[]const u8 = null;
    var coll: ?[]const u8 = null;
    while (!s.atStmtEnd()) {
        _ = s.eatKw("DEFAULT");
        if (s.eatKw("CHARACTER")) {
            try s.expectKw("SET");
            _ = s.eatOp("=");
            cs = try optionValue(s);
        } else if (s.eatKw("CHARSET")) {
            _ = s.eatOp("=");
            cs = try optionValue(s);
        } else if (s.eatKw("COLLATE")) {
            _ = s.eatOp("=");
            coll = try optionValue(s);
        } else if (s.eatKw("COMMENT")) {
            _ = s.eatOp("=");
            _ = try s.stringLiteral();
        } else return s.syntaxError();
    }
    if (coll) |c| {
        const lc = try std.ascii.allocLowerString(s.a, c);
        if (cs) |x| if (!std.ascii.startsWithIgnoreCase(lc, x) or (lc.len > x.len and lc[x.len] != '_')) {
            if (!(std.ascii.eqlIgnoreCase(x, "binary") and std.mem.eql(u8, lc, "binary"))) {
                return s.fail("COLLATION '{s}' is not valid for CHARACTER SET '{s}'", .{ c, x });
            }
        };
        return lc;
    }
    if (cs) |x| return defaultCollation(x) orelse s.fail("Unknown character set: '{s}'", .{x});
    return null;
}

fn optionValue(s: *Parser) Error![]const u8 {
    if (s.tok.kind == .string) return s.stringLiteral();
    return s.nameText(try s.anyName());
}

/// The character set of collation `c`.
fn charsetOf(c: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, c, '_') orelse return c;
    return c[0..i];
}

/// CREATE [OR REPLACE] {DATABASE | SCHEMA} [IF NOT EXISTS] db [options].
pub fn create(s: *Parser, or_replace: bool) Error!void {
    s.advance(); // DATABASE / SCHEMA
    const if_not_exists = try s.ifNotExists();
    const n = try s.nameOf(try s.anyName());
    const coll = (try databaseOptions(s)) orelse server_collation;
    const name = n.text;
    if (!nsp.validName(name) or name.len > 64 or std.mem.indexOfAny(u8, name, "/\\") != null) {
        return s.fail("Incorrect database name '{s}'", .{name});
    }
    if (isSystem(name)) return s.fail("Access denied for user 'root'@'localhost' to database '{s}'", .{name});
    const p = s.p;
    if (try s.database(name)) |d| {
        if (!or_replace) {
            if (!if_not_exists) return s.fail("Can't create database '{s}'; database exists", .{name});
            p.db.xq.mariadb.warn(.note, 1007, "Can't create database '{s}'; database exists", .{name});
            return session.emptyStatement(s);
        }
        const named = d.named orelse return s.fail("xqlite: database '{s}' is a SQLite database (main, temp or ATTACH) and cannot be replaced", .{d.shown});
        try codeDrop(s, named);
    }
    nsp.codeCreate(p, name, "root");
    catalog.codeExecFmt(p, catalog.main_schema, "INSERT INTO main.xq_catalog VALUES('',%Q,%Q,%Q)", &.{
        .{ .str = name }, .{ .str = catalog.Key.collation }, .{ .str = coll },
    });
    try s.check();
}

/// Drop database `name` (registered) with all its objects, when the
/// statement runs; the current database is then none if it was it.
fn codeDrop(s: *Parser, name: []const u8) Error!void {
    const p = s.p;
    const objs = nsp.objects(p.db, s.a, name) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(p.db)}),
    };
    nsp.codeDrop(p, name, objs) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.ParseFailed,
    };
    if (p.db.xq.mariadb.currentDatabase()) |cur| if (std.ascii.eqlIgnoreCase(cur, name)) {
        try session.codeEval(s, &.{try s.func(s.here(), "xq_maria_use", &.{try s.mk(s.here(), .null)})});
    };
}

/// DROP {DATABASE | SCHEMA} [IF EXISTS] db: the database and everything
/// in it (MariaDB has no RESTRICT).
pub fn drop(s: *Parser) Error!void {
    s.advance(); // DATABASE / SCHEMA
    const if_exists = try s.ifExists();
    const name = try s.nameText(try s.anyName());
    const d = (try s.database(name)) orelse {
        if (isSystem(name)) return s.fail("Access denied for user 'root'@'localhost' to database '{s}'", .{name});
        if (!if_exists) return s.fail("Can't drop database '{s}'; database doesn't exist", .{name});
        s.p.db.xq.mariadb.warn(.note, 1008, "Can't drop database '{s}'; database doesn't exist", .{name});
        return session.emptyStatement(s);
    };
    const named = d.named orelse {
        if (std.ascii.eqlIgnoreCase(d.sqlite, catalog.main_schema)) return s.fail("xqlite: database 'main' cannot be dropped", .{});
        return s.fail("xqlite: database '{s}' is a SQLite database (use DETACH)", .{d.shown});
    };
    try codeDrop(s, named);
}

/// USE db: the current database, when the statement runs.
pub fn use(s: *Parser) Error!void {
    try s.expectKw("USE");
    const name = try s.nameText(try s.anyName());
    const d = (try s.database(name)) orelse return s.fail("Unknown database '{s}'", .{name});
    if (std.mem.eql(u8, d.sqlite, "temp")) return s.fail("Unknown database '{s}'", .{name});
    const pos = s.here();
    try session.codeEval(s, &.{try s.func(pos, "xq_maria_use", &.{try s.str(pos, d.shown)})});
}

/// xq_maria_use(db): make `db` (NULL: none) the current database and
/// expire the prepared statements.
pub fn useFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    const name: ?[]const u8 = if (api.valueType(argv[0]) == vi.SQLITE_NULL) null else api.valueText(argv[0]) orelse "";
    db.xq.mariadb.setDatabase(db.gpa, name) catch return api.resultErrorNomem(ctx);
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
    api.resultNull(ctx);
}

// ================================================================= SHOW

/// SQLite text: the databases, a subquery with columns name and coll
/// (main, the attached databases and those of CREATE DATABASE).
fn databaseList(s: *Parser) []const u8 {
    if (!catalog.exists(s.p.db, catalog.main_schema)) {
        return "SELECT name, '" ++ main_collation ++ "' AS coll FROM pragma_database_list WHERE name<>'temp'";
    }
    return "SELECT name, '" ++ main_collation ++ "' AS coll FROM pragma_database_list WHERE name<>'temp' UNION ALL " ++
        "SELECT x.col, coalesce((SELECT y.value FROM main.xq_catalog y WHERE y.tbl='' AND y.col=x.col AND y.\"key\"='" ++ catalog.Key.collation ++ "'), '" ++ server_collation ++ "') " ++
        "FROM main.xq_catalog x WHERE x.tbl='' AND x.\"key\"='" ++ nsp.key ++ "'";
}

/// SHOW {DATABASES | SCHEMAS} [LIKE 'pattern'].
pub fn showDatabases(s: *Parser) Error!void {
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    var like: []const u8 = "";
    // MariaDB names the column after the pattern too.
    var col: []const u8 = "Database";
    if (s.eatKw("LIKE")) {
        const pattern = try s.stringLiteral();
        like = try std.fmt.allocPrint(s.a, " WHERE name LIKE {f}", .{Q{ .z = pattern }});
        col = try std.fmt.allocPrint(s.a, "Database ({s})", .{pattern});
    }
    if (s.isKw("WHERE")) return s.fail("xqlite: SHOW DATABASES WHERE is not supported", .{});
    const text = try std.fmt.allocPrintSentinel(s.a, "SELECT name AS {f} FROM (SELECT 'information_schema' AS name UNION ALL SELECT name FROM ({s})){s} ORDER BY name COLLATE BINARY", .{ Id{ .z = col }, databaseList(s), like }, 0);
    try session.lowerText(s, text);
}

/// SHOW CREATE {DATABASE | SCHEMA} [IF NOT EXISTS] db.
pub fn showCreateDatabase(s: *Parser) Error!void {
    const if_not_exists = try s.ifNotExists();
    const name = try s.nameText(try s.anyName());
    const d = (try s.database(name)) orelse return s.fail("Unknown database '{s}'", .{name});
    if (std.mem.eql(u8, d.sqlite, "temp")) return s.fail("Unknown database '{s}'", .{name});
    const coll: []const u8 = if (d.named) |n| try collationOf(s, n) else main_collation;
    const B = @import("../dialect.zig").Quoted('`');
    const text = try std.fmt.allocPrint(s.a, "CREATE DATABASE {s}{f} /*!40100 DEFAULT CHARACTER SET {s} COLLATE {s} */", .{
        if (if_not_exists) "/*!32312 IF NOT EXISTS*/ " else "", B{ .z = d.shown }, charsetOf(coll), coll,
    });
    try session.lowerText(s, try std.fmt.allocPrintSentinel(s.a, "SELECT {f} AS \"Database\", {f} AS \"Create Database\"", .{ Q{ .z = d.shown }, Q{ .z = text } }, 0));
}

/// The collation of database `name` (of CREATE DATABASE), read now.
fn collationOf(s: *Parser, name: []const u8) Error![]const u8 {
    var q = catalog.Query.initFmt(s.p.db, "SELECT value FROM main.xq_catalog WHERE tbl='' AND col=%Q AND key='" ++ catalog.Key.collation ++ "'", &.{.{ .str = name }}) catch
        return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)});
    defer q.deinit();
    if (q.step() catch false) return s.a.dupe(u8, api.columnText(q.v, 0) orelse server_collation);
    return server_collation;
}

/// SHOW [FULL] TABLES [{FROM | IN} db] [LIKE 'pattern'].
pub fn showTables(s: *Parser, full: bool) Error!void {
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const d = if (s.eatKw("FROM") or s.eatKw("IN")) blk: {
        const name = try s.nameText(try s.anyName());
        break :blk (try s.database(name)) orelse return s.fail("Unknown database '{s}'", .{name});
    } else try s.currentDb();
    var like: ?[]const u8 = null;
    if (s.eatKw("LIKE")) like = try s.stringLiteral();
    if (s.isKw("WHERE")) return s.fail("xqlite: SHOW TABLES WHERE is not supported", .{});
    const col = if (like) |l|
        try std.fmt.allocPrint(s.a, "Tables_in_{s} ({s})", .{ d.shown, l })
    else
        try std.fmt.allocPrint(s.a, "Tables_in_{s}", .{d.shown});
    const type_col = if (full) ", CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS Table_type" else "";
    const like_sql: []const u8 = if (like) |l| try std.fmt.allocPrint(s.a, " AND xname LIKE {f}", .{Q{ .z = l }}) else "";
    const text = if (d.named) |n| blk: {
        const prefix = try nsp.mangle(s.a, n, "");
        break :blk try std.fmt.allocPrintSentinel(s.a, "SELECT xname AS {f}{s} FROM (SELECT substr(name,{d}) AS xname, type FROM main.sqlite_schema WHERE type IN ('table','view') AND substr(name,1,{d})={f} COLLATE NOCASE) WHERE 1{s} ORDER BY xname COLLATE BINARY", .{
            Id{ .z = col }, type_col, prefix.len + 1, prefix.len, Q{ .z = prefix }, like_sql,
        }, 0);
    } else try std.fmt.allocPrintSentinel(s.a, "SELECT xname AS {f}{s} FROM (SELECT name AS xname, type FROM {f}.sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name" ++ catalog.not_catalog_table ++ "{s}) WHERE 1{s} ORDER BY xname COLLATE BINARY", .{
        Id{ .z = col }, type_col, Id{ .z = d.sqlite }, if (std.ascii.eqlIgnoreCase(d.sqlite, catalog.main_schema)) notNamed(s.p.db, "name", false) else "", like_sql,
    }, 0);
    try session.lowerText(s, text);
}

/// SQL (SQLite's, or MariaDB's with `maria`): " AND <name_expr> is not
/// an object of a database of CREATE DATABASE", for a main object; ""
/// if main has no catalog (so none).
pub fn notNamed(db: *int.Sqlite3, comptime name_expr: []const u8, comptime maria: bool) []const u8 {
    if (!catalog.exists(db, catalog.main_schema)) return "";
    return comptime " AND NOT EXISTS (" ++ namedOf(name_expr, maria, "1") ++ ")";
}

/// SQL: SELECT `what` (xc.col is the database) FROM the registry WHERE
/// xc.col is the database of mangled name `name_expr`.
pub fn namedOf(comptime name_expr: []const u8, comptime maria: bool, comptime what: []const u8) []const u8 {
    const k = if (maria) "`key`" else "\"key\"";
    return "SELECT " ++ what ++ " FROM main.xq_catalog xc WHERE xc.tbl='' AND xc." ++ k ++ "='" ++ nsp.key ++ "' AND xc.col=substr(" ++ name_expr ++ ",1,instr(" ++ name_expr ++ ",'.')-1) COLLATE NOCASE";
}
