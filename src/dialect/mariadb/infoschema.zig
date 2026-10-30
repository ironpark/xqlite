//! information_schema.TABLES, COLUMNS, SCHEMATA, VIEWS, STATISTICS: a FROM term
//! naming one is replaced by a subquery over SQLite's pragma functions
//! and xq_catalog (MariaDB text, parsed by a parser of its own), so they
//! exist only in the MariaDB dialect and need nothing in the database.
//! The databases are SQLite's schemas (main, attached ones; not temp)
//! and those of CREATE DATABASE (databases.zig): a main table "db.t" of
//! a registered database db is table t of db, not of main. Columns
//! xqlite cannot know (TABLE_ROWS, AUTO_INCREMENT, sizes, privileges
//! ...) are NULL.

const std = @import("std");
const tree = @import("../../ir/tree.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");
const databases = @import("databases.zig");

const Parser = parser.Parser;
const Error = parser.Error;

/// The view `name` of information_schema as a query (whose positions are
/// offsets of its own text, Select.src), null if xqlite does not have it.
pub fn select(s: *Parser, name: []const u8) Error!?*tree.Select {
    const text: [:0]const u8 = if (std.ascii.eqlIgnoreCase(name, "TABLES"))
        try tables(s)
    else if (std.ascii.eqlIgnoreCase(name, "COLUMNS"))
        try columns(s)
    else if (std.ascii.eqlIgnoreCase(name, "SCHEMATA"))
        try schemata(s)
    else if (std.ascii.eqlIgnoreCase(name, "VIEWS"))
        try views(s)
    else if (std.ascii.eqlIgnoreCase(name, "STATISTICS"))
        try statistics(s)
    else
        return null;
    var sub: Parser = .init(s.p, text, (state.SqlMode{}).with(.PIPES_AS_CONCAT));
    sub.raw_names = true;
    const sel = try sub.selectStmt();
    if (sub.tok.kind != .eof) return sub.syntaxError();
    sel.src = text;
    return sel;
}

/// The user tables and views as a FROM term `tl`: db and name (SQLite's),
/// type, sch and tname (MariaDB's database and name).
fn userTables(s: *Parser) []const u8 {
    const filter = "FROM pragma_table_list x WHERE x.`schema` <> 'temp' AND x.name NOT LIKE 'sqlite\\_%' AND x.name" ++ catalog.not_catalog_table;
    if (!catalog.exists(s.p.db, catalog.main_schema)) {
        return "(SELECT x.`schema` AS db, x.name AS name, x.type AS type, x.`schema` AS sch, x.name AS tname " ++ filter ++ ") tl";
    }
    const named = comptime "CASE WHEN x.`schema` = 'main' THEN (" ++ databases.namedOf("x.name", true, "xc.col") ++ ") END";
    return "(SELECT x.`schema` AS db, x.name AS name, x.type AS type, coalesce(" ++ named ++ ", x.`schema`) COLLATE utf8mb4_general_ci AS sch, " ++
        "CASE WHEN " ++ named ++ " IS NULL THEN x.name ELSE substr(x.name, instr(x.name, '.') + 1) END COLLATE utf8mb4_general_ci AS tname " ++ filter ++ ") tl";
}

fn tables(s: *Parser) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(s.a, "SELECT 'def' AS TABLE_CATALOG, tl.sch AS TABLE_SCHEMA, tl.tname AS TABLE_NAME, " ++
        "CASE tl.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS TABLE_TYPE, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'InnoDB' END AS ENGINE, 10 AS VERSION, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'Dynamic' END AS ROW_FORMAT, NULL AS TABLE_ROWS, " ++
        "NULL AS AVG_ROW_LENGTH, NULL AS DATA_LENGTH, NULL AS MAX_DATA_LENGTH, NULL AS INDEX_LENGTH, " ++
        "NULL AS DATA_FREE, NULL AS AUTO_INCREMENT, NULL AS CREATE_TIME, NULL AS UPDATE_TIME, NULL AS CHECK_TIME, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'utf8mb4_general_ci' END AS TABLE_COLLATION, NULL AS CHECKSUM, " ++
        "'' AS CREATE_OPTIONS, CASE tl.type WHEN 'view' THEN 'VIEW' ELSE '' END AS TABLE_COMMENT FROM {s}", .{userTables(s)}, 0);
}

fn columns(s: *Parser) Error![:0]const u8 {
    const has_cat = catalog.exists(s.p.db, "main");
    const ty = if (has_cat)
        "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.db = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = '" ++ catalog.Key.decl_type ++ "'), lower(ti.type))"
    else
        "lower(ti.type)";
    const dflt = if (has_cat)
        "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.db = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = '" ++ catalog.Key.default ++ "'), ti.dflt_value)"
    else
        "ti.dflt_value";
    const extra = if (has_cat)
        "trim(CASE WHEN EXISTS (SELECT 1 FROM main.xq_catalog c WHERE tl.db = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'mariadb.auto_increment') THEN 'auto_increment' ELSE '' END || " ++
            "CASE WHEN EXISTS (SELECT 1 FROM main.xq_catalog c WHERE tl.db = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'mariadb.on_update') THEN ' on update current_timestamp()' ELSE '' END || " ++
            "CASE ti.hidden WHEN 2 THEN ' VIRTUAL GENERATED' WHEN 3 THEN ' STORED GENERATED' ELSE '' END)"
    else
        "''";
    // SHOW COLUMNS' Key.
    const key = "CASE WHEN ti.pk THEN 'PRI' " ++
        "WHEN EXISTS (SELECT 1 FROM pragma_index_list(tl.name, tl.db) il WHERE il.`unique` AND (SELECT count(*) FROM pragma_index_info(il.name, tl.db)) = 1 AND (SELECT name FROM pragma_index_info(il.name, tl.db)) = ti.name) THEN 'UNI' " ++
        "WHEN EXISTS (SELECT 1 FROM pragma_index_list(tl.name, tl.db) il, pragma_index_info(il.name, tl.db) ii WHERE ii.seqno = 0 AND ii.name = ti.name) THEN 'MUL' ELSE '' END";
    return std.fmt.allocPrintSentinel(s.a, "SELECT 'def' AS TABLE_CATALOG, tl.sch AS TABLE_SCHEMA, tl.tname AS TABLE_NAME, " ++
        "ti.name COLLATE utf8mb4_general_ci AS COLUMN_NAME, ti.cid + 1 AS ORDINAL_POSITION, {s} AS COLUMN_DEFAULT, " ++
        "CASE WHEN ti.`notnull` OR ti.pk THEN 'NO' ELSE 'YES' END AS IS_NULLABLE, " ++
        "CASE WHEN instr({s}, '(') THEN substr({s}, 1, instr({s}, '(') - 1) WHEN instr({s}, ' ') THEN substr({s}, 1, instr({s}, ' ') - 1) ELSE {s} END AS DATA_TYPE, " ++
        "NULL AS CHARACTER_MAXIMUM_LENGTH, NULL AS NUMERIC_PRECISION, NULL AS NUMERIC_SCALE, " ++
        "{s} AS COLUMN_TYPE, {s} AS COLUMN_KEY, {s} AS EXTRA, '' AS COLUMN_COMMENT " ++
        "FROM {s} JOIN pragma_table_xinfo(tl.name, tl.db) ti " ++
        "WHERE ti.hidden IN (0, 2, 3)", .{ dflt, ty, ty, ty, ty, ty, ty, ty, ty, key, extra, userTables(s) }, 0);
}

fn schemata(s: *Parser) Error![:0]const u8 {
    const named = if (catalog.exists(s.p.db, catalog.main_schema))
        " UNION ALL SELECT x.col, coalesce((SELECT y.value FROM main.xq_catalog y WHERE y.tbl = '' AND y.col = x.col AND y.`key` = '" ++ catalog.Key.collation ++ "'), '" ++ databases.server_collation ++ "') " ++
            "FROM main.xq_catalog x WHERE x.tbl = '' AND x.`key` = '" ++ catalog.schemas.key ++ "'"
    else
        "";
    return std.fmt.allocPrintSentinel(s.a, "SELECT 'def' AS CATALOG_NAME, d.name COLLATE utf8mb4_general_ci AS SCHEMA_NAME, " ++
        "CASE WHEN instr(d.coll, '_') THEN substr(d.coll, 1, instr(d.coll, '_') - 1) ELSE d.coll END AS DEFAULT_CHARACTER_SET_NAME, " ++
        "d.coll AS DEFAULT_COLLATION_NAME, NULL AS SQL_PATH, NULL AS SCHEMA_COMMENT " ++
        "FROM (SELECT name, '" ++ databases.main_collation ++ "' AS coll FROM pragma_database_list WHERE name <> 'temp'{s}) d", .{named}, 0);
}

/// VIEW_DEFINITION is the SQLite text of the query of a view of main
/// (MariaDB shows its own rewriting of it), NULL in an attached database.
fn views(s: *Parser) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(s.a, "SELECT 'def' AS TABLE_CATALOG, tl.sch AS TABLE_SCHEMA, tl.tname AS TABLE_NAME, " ++
        "(SELECT substr(m.sql, instr(upper(m.sql), ' AS ') + 4) FROM main.sqlite_schema m WHERE tl.db = 'main' AND m.type = 'view' AND m.name = tl.name) AS VIEW_DEFINITION, " ++
        "'NONE' AS CHECK_OPTION, 'YES' AS IS_UPDATABLE, 'root@localhost' AS DEFINER, 'DEFINER' AS SECURITY_TYPE, " ++
        "'utf8mb4' AS CHARACTER_SET_CLIENT, 'utf8mb4_general_ci' AS COLLATION_CONNECTION, 'UNDEFINED' AS ALGORITHM " ++
        "FROM {s} WHERE tl.type = 'view'", .{userTables(s)}, 0);
}

/// The indexes as SHOW INDEX shows them: MariaDB index i of table t is
/// the SQLite index "t$i"; the rowid PRIMARY KEY has no index of its own.
fn statistics(s: *Parser) Error![:0]const u8 {
    const cols = "SELECT 'def' AS TABLE_CATALOG, tl.sch AS TABLE_SCHEMA, tl.tname AS TABLE_NAME, ";
    const rest = " 'A' AS COLLATION, NULL AS CARDINALITY, NULL AS SUB_PART, NULL AS PACKED, ";
    const tail = " 'BTREE' AS INDEX_TYPE, '' AS COMMENT, '' AS INDEX_COMMENT, 'NO' AS IGNORED ";
    const t = userTables(s);
    return std.fmt.allocPrintSentinel(s.a, cols ++
        "NOT il.`unique` AS NON_UNIQUE, tl.sch AS INDEX_SCHEMA, " ++
        "CASE WHEN il.origin = 'pk' THEN 'PRIMARY' WHEN substr(il.name, 1, length(tl.name) + 1) = tl.name || '$' THEN substr(il.name, length(tl.name) + 2) ELSE il.name END COLLATE utf8mb4_general_ci AS INDEX_NAME, " ++
        "ii.seqno + 1 AS SEQ_IN_INDEX, ii.name COLLATE utf8mb4_general_ci AS COLUMN_NAME," ++ rest ++
        "CASE WHEN ti.`notnull` OR ti.pk THEN '' ELSE 'YES' END AS NULLABLE," ++ tail ++
        "FROM {s} JOIN pragma_index_list(tl.name, tl.db) il JOIN pragma_index_info(il.name, tl.db) ii " ++
        "LEFT JOIN pragma_table_info(tl.name, tl.db) ti ON ti.name = ii.name WHERE tl.type = 'table' " ++
        "UNION ALL " ++ cols ++
        "0 AS NON_UNIQUE, tl.sch AS INDEX_SCHEMA, 'PRIMARY' COLLATE utf8mb4_general_ci AS INDEX_NAME, 1 AS SEQ_IN_INDEX, p.name COLLATE utf8mb4_general_ci AS COLUMN_NAME," ++ rest ++ "'' AS NULLABLE," ++ tail ++
        "FROM {s} JOIN pragma_table_info(tl.name, tl.db) p WHERE tl.type = 'table' AND p.pk = 1 " ++
        "AND NOT EXISTS (SELECT 1 FROM pragma_index_list(tl.name, tl.db) x WHERE x.origin = 'pk') " ++
        "AND (SELECT count(*) FROM pragma_table_info(tl.name, tl.db) y WHERE y.pk > 0) = 1", .{ t, t }, 0);
}
