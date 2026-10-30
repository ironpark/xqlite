//! INFORMATION_SCHEMA.TABLES, COLUMNS, VIEWS and SCHEMATA, and
//! sys.tables, sys.views, sys.objects, sys.columns, sys.schemas and
//! sys.sequences: a FROM item
//! naming one is replaced by a subquery over SQLite's schema, its pragma
//! functions and xq_catalog (T-SQL text, parsed by a parser of its own),
//! so they exist only in the T-SQL dialect and need nothing in the
//! database.
//!
//! A database is SQLite's (main, an attached one; not temp, as #temp
//! tables live in tempdb); its schema is dbo, and in main the schemas of
//! CREATE SCHEMA too: an object "s.t" of main is t of schema s
//! (schemas.zig's xq_tsql_schema_of() and xq_tsql_bare_name() split the
//! name, xq_tsql_schema_id() gives the schema_id). object_id is the rowid
//! of the table's row in sqlite_schema, as OBJECT_ID() says. Types come
//! from xq_catalog (the declared type), else from SQLite's.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const schemas = @import("schemas.zig");

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
        if (eq(name, "SCHEMATA")) break :blk if (has_cat) schemata_cat else schemata_plain;
        return null;
    } else blk: {
        if (eq(name, "tables")) break :blk sys_tables;
        if (eq(name, "views")) break :blk sys_views;
        if (eq(name, "objects")) break :blk sys_objects;
        if (eq(name, "columns")) break :blk if (has_cat) sys_columns_cat else sys_columns_plain;
        if (eq(name, "schemas")) break :blk if (has_cat) sys_schemas_cat else sys_schemas_plain;
        if (eq(name, "sequences")) break :blk if (!catalog.sequence.exists(s.p.db, "main")) sys_sequences_none else if (has_cat) sys_sequences_cat else sys_sequences_plain;
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

/// The schema and the name within it of table tl.name of
/// pragma_table_list (a schema of CREATE SCHEMA is main's).
const tl_schema = "CASE WHEN tl.[schema] = 'main' THEN xq_tsql_schema_of(tl.name) ELSE 'dbo' END";
const tl_name = "CASE WHEN tl.[schema] = 'main' THEN xq_tsql_bare_name(tl.name) ELSE tl.name END";

const tables =
    "SELECT tl.[schema] AS TABLE_CATALOG, " ++ tl_schema ++ " AS TABLE_SCHEMA, " ++ tl_name ++ " AS TABLE_NAME, " ++
    "CASE tl.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS TABLE_TYPE " ++
    "FROM pragma_table_list tl WHERE tl.type IN ('table', 'view') AND" ++ user_tables;

const views =
    "SELECT tl.[schema] AS TABLE_CATALOG, " ++ tl_schema ++ " AS TABLE_SCHEMA, " ++ tl_name ++ " AS TABLE_NAME, " ++
    "(SELECT m.sql FROM main.sqlite_schema m WHERE m.name = tl.name AND m.type = 'view') AS VIEW_DEFINITION, " ++
    "'NONE' AS CHECK_OPTION, 'NO' AS IS_UPDATABLE " ++
    "FROM pragma_table_list tl WHERE tl.type = 'view' AND" ++ user_tables;

/// SQL Server's schemas of every database: name, schema_id, owner.
const builtin_schemas = blk: {
    @setEvalBranchQuota(100_000);
    var t: []const u8 = "";
    for (schemas.builtin, 0..) |b, i| {
        t = t ++ (if (i == 0) "SELECT " else " UNION ALL SELECT ") ++ "'" ++ b[0] ++ "' AS name, " ++
            std.fmt.comptimePrint("{d}", .{b[1]}) ++ " AS schema_id, " ++ std.fmt.comptimePrint("{d}", .{b[1]}) ++ " AS principal_id, '" ++ b[0] ++ "' AS owner";
    }
    break :blk t;
};

/// ... and those of CREATE SCHEMA (owned by dbo, principal 1).
const user_schemas = " UNION ALL SELECT c.col, xq_tsql_schema_id(c.col), 1, c.value FROM main.xq_catalog c WHERE c.tbl = '' AND c.[key] = 'schema'";

fn schemataText(comptime list: []const u8) [:0]const u8 {
    return "SELECT 'main' AS CATALOG_NAME, x.name AS SCHEMA_NAME, x.owner AS SCHEMA_OWNER, NULL AS DEFAULT_CHARACTER_SET_CATALOG, " ++
        "NULL AS DEFAULT_CHARACTER_SET_SCHEMA, 'iso_1' AS DEFAULT_CHARACTER_SET_NAME FROM (" ++ list ++ ") x " ++
        "UNION ALL SELECT name, 'dbo', 'dbo', NULL, NULL, 'iso_1' FROM pragma_database_list WHERE name NOT IN ('main', 'temp')";
}

const schemata_cat = schemataText(builtin_schemas ++ user_schemas);
const schemata_plain = schemataText(builtin_schemas);

/// The declared type of column ti.name of table tl.name.
const decl_cat = "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.[schema] = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.[key] = 'type'), lower(ti.type))";
const decl_plain = "lower(ti.type)";

fn columnsText(comptime decl: []const u8) [:0]const u8 {
    return "SELECT tl.[schema] AS TABLE_CATALOG, " ++ tl_schema ++ " AS TABLE_SCHEMA, " ++ tl_name ++ " AS TABLE_NAME, " ++
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

/// The name within its schema and the schema_id of main object m.name.
const m_name = "xq_tsql_bare_name(m.name)";
const m_schema_id = "xq_tsql_schema_id(xq_tsql_schema_of(m.name))";

const sys_tables =
    "SELECT " ++ m_name ++ " AS name, m.rowid AS object_id, " ++ m_schema_id ++ " AS schema_id, 'U' AS type, 'USER_TABLE' AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type = 'table' AND substr(m.name, 1, 7) <> 'sqlite_' AND m.name NOT IN ('xq_catalog', 'xq_sequence')";

const sys_views =
    "SELECT " ++ m_name ++ " AS name, m.rowid AS object_id, " ++ m_schema_id ++ " AS schema_id, 'V' AS type, 'VIEW' AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type = 'view'";

const sys_objects =
    "SELECT " ++ m_name ++ " AS name, m.rowid AS object_id, " ++ m_schema_id ++ " AS schema_id, " ++
    "CASE m.type WHEN 'view' THEN 'V' ELSE 'U' END AS type, CASE m.type WHEN 'view' THEN 'VIEW' ELSE 'USER_TABLE' END AS type_desc " ++
    "FROM main.sqlite_schema m WHERE m.type IN ('table', 'view') AND substr(m.name, 1, 7) <> 'sqlite_' AND m.name NOT IN ('xq_catalog', 'xq_sequence')";

fn sysSchemasText(comptime list: []const u8) [:0]const u8 {
    return "SELECT x.name AS name, x.schema_id AS schema_id, x.principal_id AS principal_id FROM (" ++ list ++ ") x";
}

const sys_schemas_cat = sysSchemasText(builtin_schemas ++ user_schemas);
const sys_schemas_plain = sysSchemasText(builtin_schemas);

/// The sequences of CREATE SEQUENCE (not those of identity columns).
fn sysSequencesText(comptime owned: []const u8) [:0]const u8 {
    return "SELECT xq_tsql_bare_name(q.name) AS name, xq_tsql_schema_id(xq_tsql_schema_of(q.name)) AS schema_id, " ++
        "q.start_value AS start_value, q.increment AS increment, q.min_value AS minimum_value, q.max_value AS maximum_value, " ++
        "q.cycle AS is_cycling, CASE WHEN q.is_called = 1 THEN q.last_value END AS current_value FROM main.xq_sequence q" ++ owned;
}

const sys_sequences_cat = sysSequencesText(" WHERE q.name NOT IN (SELECT c.value FROM main.xq_catalog c WHERE c.[key] = 'identity')");
const sys_sequences_plain = sysSequencesText("");
const sys_sequences_none = "SELECT CAST(NULL AS SYSNAME) AS name, 0 AS schema_id, 0 AS start_value, 0 AS increment, 0 AS minimum_value, " ++
    "0 AS maximum_value, 0 AS is_cycling, 0 AS current_value WHERE 1 = 0";

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
