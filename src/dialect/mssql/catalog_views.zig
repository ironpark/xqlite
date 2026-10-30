//! INFORMATION_SCHEMA.TABLES, COLUMNS and VIEWS, and sys.tables,
//! sys.views, sys.objects, sys.columns and sys.schemas: a FROM item
//! naming one is replaced by a subquery over SQLite's schema, its pragma
//! functions and xq_catalog (T-SQL text, parsed by a parser of its own),
//! so they exist only in the T-SQL dialect and need nothing in the
//! database.
//!
//! A database is SQLite's (main, an attached one; not temp, as #temp
//! tables live in tempdb); its schema is dbo. object_id is the rowid of
//! the table's row in sqlite_schema, as OBJECT_ID() says. Types come
//! from xq_catalog (the declared type), else from SQLite's.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;

/// The view `name` of `schema` (INFORMATION_SCHEMA or sys) as a query
/// (its positions are offsets of its own text, Select.src), null if
/// xqlite does not have it.
pub fn select(s: *Parser, schema: []const u8, name: []const u8) Error!?*tree.Select {
    const eq = std.ascii.eqlIgnoreCase;
    const has_cat = catalog.exists(s.p.db, "main");
    const text: [:0]const u8 = if (eq(schema, "INFORMATION_SCHEMA")) blk: {
        if (eq(name, "TABLES")) break :blk tables;
        if (eq(name, "COLUMNS")) break :blk if (has_cat) columns_cat else columns_plain;
        if (eq(name, "VIEWS")) break :blk views;
        if (eq(name, "SCHEMATA")) break :blk schemata;
        return null;
    } else blk: {
        if (eq(name, "tables")) break :blk sys_tables;
        if (eq(name, "views")) break :blk sys_views;
        if (eq(name, "objects")) break :blk sys_objects;
        if (eq(name, "columns")) break :blk if (has_cat) sys_columns_cat else sys_columns_plain;
        if (eq(name, "schemas")) break :blk sys_schemas;
        return null;
    };
    var sub: Parser = .init(s.p, text);
    sub.depth = 1;
    const sel = try sub.subSelect();
    if (sub.tok.kind != .eof) return sub.syntaxError();
    sel.src = text;
    return sel;
}

const user_tables = " substr(tl.name, 1, 7) <> 'sqlite_' AND tl.name NOT IN ('xq_catalog', 'xq_sequence') AND tl.[schema] <> 'temp'";

const tables =
    "SELECT tl.[schema] AS TABLE_CATALOG, 'dbo' AS TABLE_SCHEMA, tl.name AS TABLE_NAME, " ++
    "CASE tl.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS TABLE_TYPE " ++
    "FROM pragma_table_list tl WHERE tl.type IN ('table', 'view') AND" ++ user_tables;

const views =
    "SELECT tl.[schema] AS TABLE_CATALOG, 'dbo' AS TABLE_SCHEMA, tl.name AS TABLE_NAME, " ++
    "(SELECT m.sql FROM main.sqlite_schema m WHERE m.name = tl.name AND m.type = 'view') AS VIEW_DEFINITION, " ++
    "'NONE' AS CHECK_OPTION, 'NO' AS IS_UPDATABLE " ++
    "FROM pragma_table_list tl WHERE tl.type = 'view' AND" ++ user_tables;

const schemata =
    "SELECT name AS CATALOG_NAME, 'dbo' AS SCHEMA_NAME, 'dbo' AS SCHEMA_OWNER FROM pragma_database_list WHERE name <> 'temp'";

/// The declared type of column ti.name of table tl.name.
const decl_cat = "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.[schema] = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.[key] = 'type'), lower(ti.type))";
const decl_plain = "lower(ti.type)";

fn columnsText(comptime decl: []const u8) [:0]const u8 {
    return "SELECT tl.[schema] AS TABLE_CATALOG, 'dbo' AS TABLE_SCHEMA, tl.name AS TABLE_NAME, " ++
        "ti.name AS COLUMN_NAME, ti.cid + 1 AS ORDINAL_POSITION, ti.dflt_value AS COLUMN_DEFAULT, " ++
        "CASE WHEN ti.[notnull] = 1 OR ti.pk > 0 THEN 'NO' ELSE 'YES' END AS IS_NULLABLE, " ++
        "typeinfo(" ++ decl ++ ", 'name') AS DATA_TYPE, " ++
        "typeinfo(" ++ decl ++ ", 'length') AS CHARACTER_MAXIMUM_LENGTH, " ++
        "typeinfo(" ++ decl ++ ", 'precision') AS NUMERIC_PRECISION, " ++
        "typeinfo(" ++ decl ++ ", 'scale') AS NUMERIC_SCALE, " ++
        "typeinfo(" ++ decl ++ ", 'datetime_precision') AS DATETIME_PRECISION " ++
        "FROM pragma_table_list tl JOIN pragma_table_xinfo(tl.name, tl.[schema]) ti ON 1 = 1 " ++
        "WHERE ti.hidden IN (0, 2, 3) AND tl.type IN ('table', 'view') AND" ++ user_tables;
}

const columns_cat = columnsText(decl_cat);
const columns_plain = columnsText(decl_plain);

const sys_tables =
    "SELECT m.name AS name, m.rowid AS object_id, 1 AS schema_id, 'U' AS type, 'USER_TABLE' AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type = 'table' AND substr(m.name, 1, 7) <> 'sqlite_' AND m.name NOT IN ('xq_catalog', 'xq_sequence')";

const sys_views =
    "SELECT m.name AS name, m.rowid AS object_id, 1 AS schema_id, 'V' AS type, 'VIEW' AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type = 'view'";

const sys_objects =
    "SELECT m.name AS name, m.rowid AS object_id, 1 AS schema_id, " ++
    "CASE m.type WHEN 'view' THEN 'V' ELSE 'U' END AS type, CASE m.type WHEN 'view' THEN 'VIEW' ELSE 'USER_TABLE' END AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type IN ('table', 'view') AND substr(m.name, 1, 7) <> 'sqlite_' AND m.name NOT IN ('xq_catalog', 'xq_sequence')";

const sys_schemas = "SELECT 'dbo' AS name, 1 AS schema_id, 1 AS principal_id";

const sys_ident_cat = "CASE WHEN EXISTS (SELECT 1 FROM main.xq_catalog c WHERE c.tbl = m.name AND c.col = ti.name AND c.[key] = 'identity') THEN 1 ELSE 0 END";

fn sysColumnsText(comptime decl: []const u8, comptime ident: []const u8) [:0]const u8 {
    return "SELECT m.rowid AS object_id, ti.name AS name, ti.cid + 1 AS column_id, " ++
        "typeinfo(" ++ decl ++ ", 'name') AS type_name, " ++
        "typeinfo(" ++ decl ++ ", 'max_length') AS max_length, " ++
        "coalesce(typeinfo(" ++ decl ++ ", 'precision'), 0) AS precision, " ++
        "coalesce(typeinfo(" ++ decl ++ ", 'scale'), 0) AS scale, " ++
        "CASE WHEN ti.[notnull] = 1 OR ti.pk > 0 THEN 0 ELSE 1 END AS is_nullable, " ++
        ident ++ " AS is_identity, " ++
        "CASE WHEN ti.hidden IN (2, 3) THEN 1 ELSE 0 END AS is_computed " ++
        "FROM main.sqlite_schema m JOIN pragma_table_xinfo(m.name, 'main') ti ON 1 = 1 " ++
        "WHERE m.type IN ('table', 'view') AND ti.hidden IN (0, 2, 3) AND substr(m.name, 1, 7) <> 'sqlite_' AND m.name NOT IN ('xq_catalog', 'xq_sequence')";
}

const decl_m_cat = "coalesce((SELECT c.value FROM main.xq_catalog c WHERE c.tbl = m.name AND c.col = ti.name AND c.[key] = 'type'), lower(ti.type))";

const sys_columns_cat = sysColumnsText(decl_m_cat, sys_ident_cat);
const sys_columns_plain = sysColumnsText(decl_plain, "0");
