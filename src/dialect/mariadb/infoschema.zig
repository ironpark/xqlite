//! information_schema.TABLES and information_schema.COLUMNS: a FROM term
//! naming one is replaced by a subquery over SQLite's pragma functions
//! and xq_catalog (MariaDB text, parsed by a parser of its own), so they
//! exist only in the MariaDB dialect and need nothing in the database.
//! The databases are SQLite's schemas (main, attached ones; not temp);
//! columns xqlite cannot know (TABLE_ROWS, AUTO_INCREMENT, sizes,
//! privileges ...) are NULL.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");

const Parser = parser.Parser;
const Error = parser.Error;

/// The view `name` of information_schema as a Select, null if xqlite
/// does not have it.
pub fn select(s: *Parser, name: []const u8) Error!?*int.Select {
    const text: [:0]const u8 = if (std.ascii.eqlIgnoreCase(name, "TABLES"))
        try tables(s)
    else if (std.ascii.eqlIgnoreCase(name, "COLUMNS"))
        try columns(s)
    else if (std.ascii.eqlIgnoreCase(name, "SCHEMATA"))
        schemata
    else
        return null;
    var sub: Parser = .init(s.p, text, (state.SqlMode{}).with(.PIPES_AS_CONCAT));
    const sel = try sub.selectStmt();
    if (sub.tok.kind != .eof) return sub.syntaxError();
    return sel;
}

const user_tables =
    \\FROM pragma_table_list tl WHERE tl.`schema` <> 'temp' AND tl.name NOT LIKE 'sqlite\_%' AND tl.name NOT IN ('xq_catalog', 'xq_sequence')
;

fn tables(s: *Parser) Error![:0]const u8 {
    _ = s;
    return "SELECT 'def' AS TABLE_CATALOG, tl.`schema` AS TABLE_SCHEMA, tl.name AS TABLE_NAME, " ++
        "CASE tl.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS TABLE_TYPE, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'InnoDB' END AS ENGINE, 10 AS VERSION, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'Dynamic' END AS ROW_FORMAT, NULL AS TABLE_ROWS, " ++
        "NULL AS AVG_ROW_LENGTH, NULL AS DATA_LENGTH, NULL AS MAX_DATA_LENGTH, NULL AS INDEX_LENGTH, " ++
        "NULL AS DATA_FREE, NULL AS AUTO_INCREMENT, NULL AS CREATE_TIME, NULL AS UPDATE_TIME, NULL AS CHECK_TIME, " ++
        "CASE tl.type WHEN 'view' THEN NULL ELSE 'utf8mb4_general_ci' END AS TABLE_COLLATION, NULL AS CHECKSUM, " ++
        "'' AS CREATE_OPTIONS, CASE tl.type WHEN 'view' THEN 'VIEW' ELSE '' END AS TABLE_COMMENT " ++ user_tables;
}

fn columns(s: *Parser) Error![:0]const u8 {
    const has_cat = catalog.exists(s.p.db, "main");
    const ty = if (has_cat)
        "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.`schema` = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'type'), lower(ti.type))"
    else
        "lower(ti.type)";
    const dflt = if (has_cat)
        "coalesce((SELECT c.value FROM main.xq_catalog c WHERE tl.`schema` = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'default'), ti.dflt_value)"
    else
        "ti.dflt_value";
    const extra = if (has_cat)
        "trim(CASE WHEN EXISTS (SELECT 1 FROM main.xq_catalog c WHERE tl.`schema` = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'mariadb.auto_increment') THEN 'auto_increment' ELSE '' END || " ++
            "CASE WHEN EXISTS (SELECT 1 FROM main.xq_catalog c WHERE tl.`schema` = 'main' AND c.tbl = tl.name AND c.col = ti.name AND c.`key` = 'mariadb.on_update') THEN ' on update current_timestamp()' ELSE '' END || " ++
            "CASE ti.hidden WHEN 2 THEN ' VIRTUAL GENERATED' WHEN 3 THEN ' STORED GENERATED' ELSE '' END)"
    else
        "''";
    // SHOW COLUMNS' Key.
    const key = "CASE WHEN ti.pk THEN 'PRI' " ++
        "WHEN EXISTS (SELECT 1 FROM pragma_index_list(tl.name, tl.`schema`) il WHERE il.`unique` AND (SELECT count(*) FROM pragma_index_info(il.name, tl.`schema`)) = 1 AND (SELECT name FROM pragma_index_info(il.name, tl.`schema`)) = ti.name) THEN 'UNI' " ++
        "WHEN EXISTS (SELECT 1 FROM pragma_index_list(tl.name, tl.`schema`) il, pragma_index_info(il.name, tl.`schema`) ii WHERE ii.seqno = 0 AND ii.name = ti.name) THEN 'MUL' ELSE '' END";
    return std.fmt.allocPrintSentinel(s.a, "SELECT 'def' AS TABLE_CATALOG, tl.`schema` AS TABLE_SCHEMA, tl.name AS TABLE_NAME, " ++
        "ti.name AS COLUMN_NAME, ti.cid + 1 AS ORDINAL_POSITION, {s} AS COLUMN_DEFAULT, " ++
        "CASE WHEN ti.`notnull` OR ti.pk THEN 'NO' ELSE 'YES' END AS IS_NULLABLE, " ++
        "CASE WHEN instr({s}, '(') THEN substr({s}, 1, instr({s}, '(') - 1) WHEN instr({s}, ' ') THEN substr({s}, 1, instr({s}, ' ') - 1) ELSE {s} END AS DATA_TYPE, " ++
        "NULL AS CHARACTER_MAXIMUM_LENGTH, NULL AS NUMERIC_PRECISION, NULL AS NUMERIC_SCALE, " ++
        "{s} AS COLUMN_TYPE, {s} AS COLUMN_KEY, {s} AS EXTRA, '' AS COLUMN_COMMENT " ++
        "FROM pragma_table_list tl JOIN pragma_table_xinfo(tl.name, tl.`schema`) ti " ++
        "WHERE ti.hidden IN (0, 2, 3) AND tl.`schema` <> 'temp' AND tl.name NOT LIKE 'sqlite\\_%' AND tl.name NOT IN ('xq_catalog', 'xq_sequence')", .{ dflt, ty, ty, ty, ty, ty, ty, ty, ty, key, extra }, 0);
}

const schemata = "SELECT 'def' AS CATALOG_NAME, name AS SCHEMA_NAME, 'utf8mb4' AS DEFAULT_CHARACTER_SET_NAME, " ++
    "'utf8mb4_general_ci' AS DEFAULT_COLLATION_NAME, NULL AS SQL_PATH, NULL AS SCHEMA_COMMENT " ++
    "FROM pragma_database_list WHERE name <> 'temp'";
