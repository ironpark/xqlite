//! information_schema and pg_catalog views of the PostgreSQL dialect:
//! queries over sqlite_schema, pragma_table_xinfo() and the dialect
//! catalog (xq_catalog, xq_sequence), written in PostgreSQL and parsed
//! by this frontend, which a FROM item naming the view becomes (they
//! exist only while compiling in this dialect, nothing is stored).
//!
//!  - information_schema: tables, columns (declared types from the
//!    catalog), views, schemata, sequences;
//!  - pg_catalog (also without the schema, as in PostgreSQL's
//!    search_path): the relations of pgcatalog.zig (pg_class,
//!    pg_attribute, pg_type, pg_index, pg_constraint ...) through their
//!    engine table-valued functions, the views PostgreSQL defines over
//!    them (pg_tables, pg_views, pg_indexes), pg_sequences, pg_settings
//!    of session.zig's parameters, constant ones (pg_database, pg_roles,
//!    pg_am ...) and empty ones of what xqlite has not (pg_trigger,
//!    pg_policy, pg_inherits ...).
//!
//! The objects of main are in catalog "main": those of a schema of
//! CREATE SCHEMA (catalog/schema.zig, named "s.t" in SQLite) in schema s
//! under their own name, the others in "public". xqlite's own tables
//! (sqlite_*, xq_*) are left out. The OIDs are pgcatalog.zig's.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const catalog = @import("../../catalog/catalog.zig");
const template = @import("../template.zig");
const pgc = @import("pgcatalog.zig");
const session = @import("session.zig");

const user_tables = " m.name NOT LIKE 'sqlite\\_%' AND m.name" ++ catalog.not_catalog_table;

/// The schema `n` (from {ns}) of a mangled name `x`, joined.
fn nsJoin(comptime x: []const u8) []const u8 {
    return " LEFT JOIN {ns} n ON n.nspname = substr(" ++ x ++ ", 1, strpos(" ++ x ++ ", '.') - 1)";
}
/// The schema of the name nsJoin() split.
const schema_of = "coalesce(n.nspname, 'public')";
/// The name `x` without its schema.
fn bare(comptime x: []const u8) []const u8 {
    return "CASE WHEN n.nspname IS NULL THEN " ++ x ++ " ELSE substr(" ++ x ++ ", length(n.nspname) + 2) END";
}

// `{cat}`, `{seq}` and `{ns}` stand for xq_catalog, xq_sequence and the
// registered schemas (nspname, nspowner, oid), or for an empty query of
// the same columns when the database has none.

const tables =
    \\SELECT current_database() AS table_catalog,
++ " " ++ schema_of ++ " AS table_schema, " ++ bare("m.name") ++ " AS table_name," ++
    \\  CASE m.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS table_type,
    \\  NULL AS self_referencing_column_name, NULL AS reference_generation,
    \\  NULL AS user_defined_type_catalog, NULL AS user_defined_type_schema, NULL AS user_defined_type_name,
    \\  CASE m.type WHEN 'view' THEN 'NO' ELSE 'YES' END AS is_insertable_into,
    \\  'NO' AS is_typed, NULL AS commit_action
    \\FROM sqlite_schema m
++ nsJoin("m.name") ++ " WHERE m.type IN ('table', 'view') AND" ++ user_tables;

const columns =
    \\SELECT current_database() AS table_catalog,
++ " " ++ schema_of ++ " AS table_schema, " ++ bare("m.name") ++ " AS table_name," ++
    \\  c.name AS column_name, (c.cid + 1)::integer AS ordinal_position, c.dflt_value AS column_default,
    \\  CASE WHEN c."notnull" <> 0 OR c.pk <> 0 THEN 'NO' ELSE 'YES' END AS is_nullable,
    \\  xq_pg_data_type(k.value, c.type) AS data_type,
    \\  xq_pg_char_max(k.value, c.type)::integer AS character_maximum_length,
    \\  CASE WHEN xq_pg_data_type(k.value, c.type) IN ('text', 'character varying', 'character') THEN coalesce(xq_pg_char_max(k.value, c.type) * 4, 1073741824) END::integer AS character_octet_length,
    \\  xq_pg_num_precision(k.value, c.type)::integer AS numeric_precision,
    \\  CASE WHEN xq_pg_num_precision(k.value, c.type) IS NULL THEN NULL WHEN xq_pg_data_type(k.value, c.type) = 'numeric' THEN 10 ELSE 2 END::integer AS numeric_precision_radix,
    \\  xq_pg_num_scale(k.value, c.type)::integer AS numeric_scale,
    \\  CASE WHEN xq_pg_data_type(k.value, c.type) LIKE 'time%' THEN coalesce(xq_pg_dt_precision(k.value, c.type), 6) WHEN xq_pg_data_type(k.value, c.type) IN ('date', 'interval') THEN 0 END::integer AS datetime_precision,
    \\  NULL AS interval_type, NULL::integer AS interval_precision,
    \\  NULL AS character_set_catalog, NULL AS character_set_schema, NULL AS character_set_name,
    \\  NULL AS collation_catalog, NULL AS collation_schema, NULL AS collation_name,
    \\  NULL AS domain_catalog, NULL AS domain_schema, NULL AS domain_name,
    \\  current_database() AS udt_catalog, 'pg_catalog' AS udt_schema,
    \\  xq_pg_udt_name(k.value, c.type) AS udt_name,
    \\  NULL AS scope_catalog, NULL AS scope_schema, NULL AS scope_name,
    \\  NULL::integer AS maximum_cardinality, (c.cid + 1)::integer AS dtd_identifier, 'NO' AS is_self_referencing,
    \\  CASE WHEN i.value IS NULL THEN 'NO' ELSE 'YES' END AS is_identity,
    \\  CASE i.value WHEN 'always' THEN 'ALWAYS' WHEN 'by default' THEN 'BY DEFAULT' END AS identity_generation,
    \\  NULL AS identity_start, NULL AS identity_increment, NULL AS identity_maximum, NULL AS identity_minimum, NULL AS identity_cycle,
    \\  CASE WHEN c.hidden IN (2, 3) THEN 'ALWAYS' ELSE 'NEVER' END AS is_generated,
    \\  NULL AS generation_expression,
    \\  CASE WHEN m.type = 'view' THEN 'NO' ELSE 'YES' END AS is_updatable
    \\FROM sqlite_schema m, pragma_table_xinfo(m.name) c
    \\  LEFT JOIN {cat} k ON k.tbl = m.name AND k.col = c.name AND k.key = 'type'
    \\  LEFT JOIN {cat} i ON i.tbl = m.name AND i.col = c.name AND i.key = 'identity_kind'
++ nsJoin("m.name") ++
    \\
    \\WHERE m.type IN ('table', 'view') AND c.hidden <> 1 AND
++ user_tables;

const views_ =
    \\SELECT current_database() AS table_catalog,
++ " " ++ schema_of ++ " AS table_schema, " ++ bare("m.name") ++ " AS table_name," ++
    \\  m.sql AS view_definition, 'NONE' AS check_option, 'NO' AS is_updatable, 'NO' AS is_insertable_into
    \\FROM sqlite_schema m
++ nsJoin("m.name") ++ " WHERE m.type = 'view' AND" ++ user_tables;

const schemata =
    \\SELECT current_database() AS catalog_name, s AS schema_name, 'postgres' AS schema_owner,
    \\  NULL AS default_character_set_catalog, NULL AS default_character_set_schema, NULL AS default_character_set_name, NULL AS sql_path
    \\FROM (VALUES ('public'), ('information_schema'), ('pg_catalog')) AS x(s)
    \\UNION ALL SELECT current_database(), n.nspname, n.nspowner, NULL, NULL, NULL, NULL FROM {ns} n
;

const sequences =
    \\SELECT current_database() AS sequence_catalog,
++ " " ++ schema_of ++ " AS sequence_schema, " ++ bare("s.name") ++ " AS sequence_name," ++
    \\  'bigint' AS data_type, 64 AS numeric_precision, 2 AS numeric_precision_radix, 0 AS numeric_scale,
    \\  s.start_value::text AS start_value, s.min_value::text AS minimum_value,
    \\  s.max_value::text AS maximum_value, s.increment::text AS increment,
    \\  CASE WHEN s.cycle <> 0 THEN 'YES' ELSE 'NO' END AS cycle_option
    \\FROM {seq} s
++ nsJoin("s.name");

const pg_tables =
    \\SELECT n.nspname AS schemaname, c.relname AS tablename, pg_get_userbyid(c.relowner) AS tableowner,
    \\  NULL::name AS tablespace, c.relhasindex AS hasindexes, c.relhasrules AS hasrules,
    \\  c.relhastriggers AS hastriggers, c.relrowsecurity AS rowsecurity
    \\FROM pg_class c LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
    \\WHERE c.relkind IN ('r', 'p')
;

const pg_views =
    \\SELECT n.nspname AS schemaname, c.relname AS viewname, pg_get_userbyid(c.relowner) AS viewowner,
    \\  pg_get_viewdef(c.oid) AS definition
    \\FROM pg_class c LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
    \\WHERE c.relkind = 'v'
;

const pg_indexes =
    \\SELECT n.nspname AS schemaname, c.relname AS tablename, i.relname AS indexname,
    \\  NULL::name AS tablespace, pg_get_indexdef(i.oid) AS indexdef
    \\FROM pg_index x JOIN pg_class c ON c.oid = x.indrelid JOIN pg_class i ON i.oid = x.indexrelid
    \\  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
    \\WHERE c.relkind IN ('r', 'm', 'p') AND i.relkind IN ('i', 'I')
;

const pg_sequences =
    \\SELECT
++ " " ++ schema_of ++ " AS schemaname, " ++ bare("s.name") ++ " AS sequencename," ++
    \\  'postgres' AS sequenceowner,
    \\  'bigint' AS data_type, s.start_value, s.min_value, s.max_value, s.increment AS increment_by,
    \\  s.cycle <> 0 AS cycle, 1 AS cache_size,
    \\  CASE WHEN s.is_called <> 0 THEN s.last_value END AS last_value
    \\FROM {seq} s
++ nsJoin("s.name");

/// information_schema.table_constraints: PRIMARY KEY, UNIQUE, FOREIGN
/// KEY and CHECK constraints of pg_constraint.
const table_constraints =
    \\SELECT current_database() AS constraint_catalog, n.nspname AS constraint_schema, c.conname AS constraint_name,
    \\  current_database() AS table_catalog, n.nspname AS table_schema, r.relname AS table_name,
    \\  CASE c.contype WHEN 'c' THEN 'CHECK' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' END AS constraint_type,
    \\  CASE WHEN c.condeferrable THEN 'YES' ELSE 'NO' END AS is_deferrable,
    \\  CASE WHEN c.condeferred THEN 'YES' ELSE 'NO' END AS initially_deferred,
    \\  'YES' AS enforced, CASE WHEN c.contype = 'u' THEN 'YES' END AS nulls_distinct
    \\FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid LEFT JOIN pg_namespace n ON n.oid = c.connamespace
;

/// information_schema.key_column_usage: the columns of the keys, one row
/// a column (xq_pg_array_position(): its place in conkey).
const key_column_usage =
    \\SELECT current_database() AS constraint_catalog, n.nspname AS constraint_schema, c.conname AS constraint_name,
    \\  current_database() AS table_catalog, n.nspname AS table_schema, r.relname AS table_name,
    \\  a.attname AS column_name, xq_pg_array_position(c.conkey, a.attnum)::integer AS ordinal_position,
    \\  CASE WHEN c.contype = 'f' THEN xq_pg_array_position(c.conkey, a.attnum) END::integer AS position_in_unique_constraint
    \\FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid LEFT JOIN pg_namespace n ON n.oid = c.connamespace
    \\  JOIN pg_attribute a ON a.attrelid = c.conrelid AND xq_pg_array_position(c.conkey, a.attnum) IS NOT NULL
    \\WHERE c.contype IN ('p', 'u', 'f')
;

/// information_schema.referential_constraints.
const referential_constraints =
    \\SELECT current_database() AS constraint_catalog, n.nspname AS constraint_schema, c.conname AS constraint_name,
    \\  current_database() AS unique_constraint_catalog, pn.nspname AS unique_constraint_schema, pk.conname AS unique_constraint_name,
    \\  'NONE' AS match_option,
    \\  CASE c.confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END AS update_rule,
    \\  CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END AS delete_rule
    \\FROM pg_constraint c LEFT JOIN pg_namespace n ON n.oid = c.connamespace
    \\  LEFT JOIN pg_constraint pk ON pk.conrelid = c.confrelid AND pk.contype IN ('p', 'u') AND pk.conkey = c.confkey
    \\  LEFT JOIN pg_namespace pn ON pn.oid = pk.connamespace
    \\WHERE c.contype = 'f'
;

/// information_schema.check_constraints.
const check_constraints =
    \\SELECT current_database() AS constraint_catalog, n.nspname AS constraint_schema, c.conname AS constraint_name,
    \\  pg_get_constraintdef(c.oid) AS check_clause
    \\FROM pg_constraint c LEFT JOIN pg_namespace n ON n.oid = c.connamespace
    \\WHERE c.contype = 'c'
;

const pg_database =
    \\SELECT 5::oid AS oid, current_database()::name AS datname, 10::oid AS datdba, 6 AS encoding,
    \\  'c' AS datlocprovider, false AS datistemplate, true AS datallowconn, -1 AS datconnlimit,
    \\  '722' AS datfrozenxid, '1' AS datminmxid, 1663::oid AS dattablespace, 'C' AS datcollate, 'C' AS datctype,
    \\  NULL AS daticulocale, NULL AS daticurules, NULL AS datcollversion, NULL AS datacl
;

const pg_roles =
    \\SELECT 'postgres'::name AS rolname, true AS rolsuper, true AS rolinherit, true AS rolcreaterole,
    \\  true AS rolcreatedb, true AS rolcanlogin, true AS rolreplication, -1 AS rolconnlimit,
    \\  '********' AS rolpassword, NULL::timestamptz AS rolvaliduntil, true AS rolbypassrls,
    \\  NULL AS rolconfig, 10::oid AS oid
;

const pg_authid =
    \\SELECT 10::oid AS oid, 'postgres'::name AS rolname, true AS rolsuper, true AS rolinherit, true AS rolcreaterole,
    \\  true AS rolcreatedb, true AS rolcanlogin, true AS rolreplication, true AS rolbypassrls, -1 AS rolconnlimit,
    \\  NULL AS rolpassword, NULL::timestamptz AS rolvaliduntil
;

const pg_user =
    \\SELECT 'postgres'::name AS usename, 10::oid AS usesysid, true AS usecreatedb, true AS usesuper,
    \\  true AS userepl, true AS usebypassrls, '********' AS passwd, NULL::timestamptz AS valuntil, NULL AS useconfig
;

const pg_am =
    \\SELECT o::oid AS oid, n::name AS amname, h AS amhandler, t AS amtype
    \\FROM (VALUES (2, 'heap', 'heap_tableam_handler', 't'), (403, 'btree', 'bthandler', 'i'), (405, 'hash', 'hashhandler', 'i'),
    \\  (783, 'gist', 'gisthandler', 'i'), (2742, 'gin', 'ginhandler', 'i'), (4000, 'spgist', 'spghandler', 'i'),
    \\  (3580, 'brin', 'brinhandler', 'i')) AS x(o, n, h, t)
;

const pg_tablespace =
    \\SELECT o::oid AS oid, n::name AS spcname, 10::oid AS spcowner, NULL AS spcacl, NULL AS spcoptions
    \\FROM (VALUES (1663, 'pg_default'), (1664, 'pg_global')) AS x(o, n)
;

const pg_collation =
    \\SELECT o::oid AS oid, n::name AS collname, 11::oid AS collnamespace, 10::oid AS collowner, p AS collprovider,
    \\  true AS collisdeterministic, e AS collencoding, c AS collcollate, c AS collctype,
    \\  NULL AS colliculocale, NULL AS collicurules, NULL AS collversion
    \\FROM (VALUES (100, 'default', 'd', -1, NULL), (950, 'C', 'c', -1, 'C'), (951, 'POSIX', 'c', -1, 'POSIX')) AS x(o, n, p, e, c)
;

const pg_language =
    \\SELECT o::oid AS oid, n::name AS lanname, 10::oid AS lanowner, false AS lanispl, t AS lanpltrusted,
    \\  0::oid AS lanplcallfoid, 0::oid AS laninline, 0::oid AS lanvalidator, NULL AS lanacl
    \\FROM (VALUES (12, 'internal', false), (13, 'c', false), (14, 'sql', true)) AS x(o, n, t)
;

const pg_settings = blk: {
    var z: []const u8 =
        \\SELECT n AS name, current_setting(n) AS setting, u AS unit, cat AS category, d AS short_desc,
        \\  NULL AS extra_desc, ctx AS context, vt AS vartype,
        \\  CASE WHEN current_setting(n) = b THEN 'default' ELSE 'session' END AS source,
        \\  NULL AS min_val, NULL AS max_val, NULL AS enumvals, b AS boot_val, b AS reset_val,
        \\  NULL AS sourcefile, NULL::integer AS sourceline, false AS pending_restart
        \\FROM (VALUES
    ;
    @setEvalBranchQuota(100_000);
    var first = true;
    for (session.params) |prm| {
        if (prm.hidden) continue;
        if (!first) z = z ++ ", ";
        first = false;
        z = z ++ "(" ++ lit(prm.shown()) ++ ", " ++ (if (prm.unit) |u| lit(u) else "NULL") ++ ", " ++ lit(prm.category) ++ ", " ++
            lit(prm.desc) ++ ", " ++ lit(prm.context()) ++ ", " ++ lit(prm.vartype) ++ ", " ++ lit(prm.default) ++ ")";
    }
    break :blk z ++ ") AS x(n, u, cat, d, ctx, vt, b)";
};

/// A PostgreSQL string literal of `z` (comptime).
fn lit(comptime z: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "'";
        for (z) |c| out = out ++ (if (c == '\'') "''" else &[_]u8{c});
        return out ++ "'";
    }
}

/// An empty relation of columns `cols` (what xqlite has none of).
fn empty(comptime cols: []const pgc.Col) []const u8 {
    comptime {
        var z: []const u8 = "SELECT ";
        for (cols, 0..) |c, i| {
            if (i > 0) z = z ++ ", ";
            z = z ++ "NULL" ++ (if (c[1].cast().len == 0) "::text" else c[1].cast()) ++ " AS " ++ c[0];
        }
        return z ++ " WHERE false";
    }
}

fn rel(comptime name: []const u8) []const u8 {
    for (pgc.relations) |r| if (std.mem.eql(u8, r.name, "xq_" ++ name)) return pgc.viewText(r);
    @compileError("no relation " ++ name);
}

const empty_catalog = "(SELECT NULL AS tbl, NULL AS col, NULL AS key, NULL AS value WHERE false)";
const empty_sequence = "(SELECT NULL AS name, NULL AS last_value, NULL AS start_value, NULL AS increment, NULL AS min_value, NULL AS max_value, NULL AS cycle, NULL AS is_called WHERE false)";
const namespaces = "(SELECT col AS nspname, value AS nspowner, 16383 + row_number() OVER (ORDER BY col) AS oid FROM xq_catalog WHERE tbl = '' AND key = '" ++ catalog.schemas.key ++ "')";
const empty_namespaces = "(SELECT NULL AS nspname, NULL AS nspowner, NULL AS oid WHERE false)";

const Def = struct { schema: []const u8, name: []const u8, text: []const u8 };

const defs = [_]Def{
    .{ .schema = "information_schema", .name = "tables", .text = tables },
    .{ .schema = "information_schema", .name = "columns", .text = columns },
    .{ .schema = "information_schema", .name = "views", .text = views_ },
    .{ .schema = "information_schema", .name = "schemata", .text = schemata },
    .{ .schema = "information_schema", .name = "sequences", .text = sequences },
    .{ .schema = "information_schema", .name = "table_constraints", .text = table_constraints },
    .{ .schema = "information_schema", .name = "key_column_usage", .text = key_column_usage },
    .{ .schema = "information_schema", .name = "referential_constraints", .text = referential_constraints },
    .{ .schema = "information_schema", .name = "check_constraints", .text = check_constraints },
    .{ .schema = "pg_catalog", .name = "pg_tables", .text = pg_tables },
    .{ .schema = "pg_catalog", .name = "pg_views", .text = pg_views },
    .{ .schema = "pg_catalog", .name = "pg_indexes", .text = pg_indexes },
    .{ .schema = "pg_catalog", .name = "pg_sequences", .text = pg_sequences },
    .{ .schema = "pg_catalog", .name = "pg_namespace", .text = rel("pg_namespace") },
    .{ .schema = "pg_catalog", .name = "pg_class", .text = rel("pg_class") },
    .{ .schema = "pg_catalog", .name = "pg_attribute", .text = rel("pg_attribute") },
    .{ .schema = "pg_catalog", .name = "pg_type", .text = rel("pg_type") },
    .{ .schema = "pg_catalog", .name = "pg_index", .text = rel("pg_index") },
    .{ .schema = "pg_catalog", .name = "pg_constraint", .text = rel("pg_constraint") },
    .{ .schema = "pg_catalog", .name = "pg_attrdef", .text = rel("pg_attrdef") },
    .{ .schema = "pg_catalog", .name = "pg_sequence", .text = rel("pg_sequence") },
    .{ .schema = "pg_catalog", .name = "pg_depend", .text = rel("pg_depend") },
    .{ .schema = "pg_catalog", .name = "pg_proc", .text = rel("pg_proc") },
    .{ .schema = "pg_catalog", .name = "pg_database", .text = pg_database },
    .{ .schema = "pg_catalog", .name = "pg_roles", .text = pg_roles },
    .{ .schema = "pg_catalog", .name = "pg_authid", .text = pg_authid },
    .{ .schema = "pg_catalog", .name = "pg_user", .text = pg_user },
    .{ .schema = "pg_catalog", .name = "pg_am", .text = pg_am },
    .{ .schema = "pg_catalog", .name = "pg_tablespace", .text = pg_tablespace },
    .{ .schema = "pg_catalog", .name = "pg_collation", .text = pg_collation },
    .{ .schema = "pg_catalog", .name = "pg_language", .text = pg_language },
    .{ .schema = "pg_catalog", .name = "pg_settings", .text = pg_settings },
    .{ .schema = "pg_catalog", .name = "pg_description", .text = rel("pg_description") },
    .{ .schema = "pg_catalog", .name = "pg_shdescription", .text = empty(&.{ .{ "objoid", .oid }, .{ "classoid", .oid }, .{ "description", .text } }) },
    .{ .schema = "pg_catalog", .name = "pg_inherits", .text = empty(&.{ .{ "inhrelid", .oid }, .{ "inhparent", .oid }, .{ "inhseqno", .int4 }, .{ "inhdetachpending", .bool } }) },
    .{ .schema = "pg_catalog", .name = "pg_trigger", .text = empty(&.{
        .{ "oid", .oid },          .{ "tgrelid", .oid },       .{ "tgparentid", .oid },      .{ "tgname", .name },       .{ "tgfoid", .oid },
        .{ "tgtype", .int2 },      .{ "tgenabled", .char },    .{ "tgisinternal", .bool },   .{ "tgconstrrelid", .oid }, .{ "tgconstrindid", .oid },
        .{ "tgconstraint", .oid }, .{ "tgdeferrable", .bool }, .{ "tginitdeferred", .bool }, .{ "tgnargs", .int2 },      .{ "tgattr", .text },
        .{ "tgargs", .text },      .{ "tgqual", .text },       .{ "tgoldtable", .name },     .{ "tgnewtable", .name },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_policy", .text = empty(&.{
        .{ "oid", .oid },       .{ "polname", .name }, .{ "polrelid", .oid },      .{ "polcmd", .char }, .{ "polpermissive", .bool },
        .{ "polroles", .text }, .{ "polqual", .text }, .{ "polwithcheck", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_rewrite", .text = empty(&.{
        .{ "oid", .oid },         .{ "rulename", .name }, .{ "ev_class", .oid },   .{ "ev_type", .char }, .{ "ev_enabled", .char },
        .{ "is_instead", .bool }, .{ "ev_qual", .text },  .{ "ev_action", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_statistic_ext", .text = empty(&.{
        .{ "oid", .oid },            .{ "stxrelid", .oid }, .{ "stxname", .name }, .{ "stxnamespace", .oid }, .{ "stxowner", .oid },
        .{ "stxstattarget", .int4 }, .{ "stxkeys", .text }, .{ "stxkind", .text }, .{ "stxexprs", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_publication", .text = empty(&.{
        .{ "oid", .oid },        .{ "pubname", .name },   .{ "pubowner", .oid },     .{ "puballtables", .bool }, .{ "pubinsert", .bool },
        .{ "pubupdate", .bool }, .{ "pubdelete", .bool }, .{ "pubtruncate", .bool }, .{ "pubviaroot", .bool },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_publication_rel", .text = empty(&.{ .{ "oid", .oid }, .{ "prpubid", .oid }, .{ "prrelid", .oid }, .{ "prqual", .text }, .{ "prattrs", .text } }) },
    .{ .schema = "pg_catalog", .name = "pg_publication_namespace", .text = empty(&.{ .{ "oid", .oid }, .{ "pnpubid", .oid }, .{ "pnnspid", .oid } }) },
    .{ .schema = "pg_catalog", .name = "pg_enum", .text = empty(&.{ .{ "oid", .oid }, .{ "enumtypid", .oid }, .{ "enumsortorder", .float4 }, .{ "enumlabel", .name } }) },
    .{ .schema = "pg_catalog", .name = "pg_extension", .text = empty(&.{
        .{ "oid", .oid },         .{ "extname", .name },   .{ "extowner", .oid },      .{ "extnamespace", .oid }, .{ "extrelocatable", .bool },
        .{ "extversion", .text }, .{ "extconfig", .text }, .{ "extcondition", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_auth_members", .text = empty(&.{ .{ "oid", .oid }, .{ "roleid", .oid }, .{ "member", .oid }, .{ "grantor", .oid }, .{ "admin_option", .bool }, .{ "inherit_option", .bool }, .{ "set_option", .bool } }) },
    .{ .schema = "pg_catalog", .name = "pg_partitioned_table", .text = empty(&.{
        .{ "partrelid", .oid },  .{ "partstrat", .char },     .{ "partnatts", .int2 }, .{ "partdefid", .oid }, .{ "partattrs", .text },
        .{ "partclass", .text }, .{ "partcollation", .text }, .{ "partexprs", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_foreign_table", .text = empty(&.{ .{ "ftrelid", .oid }, .{ "ftserver", .oid }, .{ "ftoptions", .text } }) },
    .{ .schema = "pg_catalog", .name = "pg_matviews", .text = empty(&.{
        .{ "schemaname", .name }, .{ "matviewname", .name }, .{ "matviewowner", .name }, .{ "tablespace", .name },
        .{ "hasindexes", .bool }, .{ "ispopulated", .bool }, .{ "definition", .text },
    }) },
    .{ .schema = "pg_catalog", .name = "pg_range", .text = empty(&.{ .{ "rngtypid", .oid }, .{ "rngsubtype", .oid }, .{ "rngmultitypid", .oid }, .{ "rngcollation", .oid }, .{ "rngsubopc", .oid }, .{ "rngcanonical", .text }, .{ "rngsubdiff", .text } }) },
    .{ .schema = "pg_catalog", .name = "pg_event_trigger", .text = empty(&.{ .{ "oid", .oid }, .{ "evtname", .name }, .{ "evtevent", .name }, .{ "evtowner", .oid }, .{ "evtfoid", .oid }, .{ "evtenabled", .char }, .{ "evttags", .text } }) },
};

/// The PostgreSQL text of view `name` of `schema` (null: pg_catalog's
/// views, which are on the search path), allocated in the statement's
/// arena; null if there is no such view.
pub fn definition(p: *int.Parse, schema: ?[]const u8, name: []const u8) error{OutOfMemory}!?[:0]const u8 {
    for (defs) |d| {
        if (!std.mem.eql(u8, d.name, name)) continue;
        if (schema) |s| {
            if (!std.mem.eql(u8, s, d.schema)) continue;
        } else if (!std.mem.eql(u8, d.schema, "pg_catalog")) continue;
        const has_catalog = catalog.exists(p.db, catalog.main_schema);
        const has_sequences = catalog.sequence.exists(p.db, catalog.main_schema);
        return try template.expand(Key, p.arena, d.text, .init(.{
            .cat = if (has_catalog) catalog.table_name else empty_catalog,
            .ns = if (has_catalog) namespaces else empty_namespaces,
            .seq = if (has_sequences) catalog.sequence.table_name else empty_sequence,
        }));
    }
    return null;
}

/// The holes of the view texts: xq_catalog, the namespaces it lists, and
/// xq_sequence, or empty tables of the same columns without them.
const Key = enum { cat, ns, seq };

comptime {
    for (defs) |d| template.check(Key, d.text);
}
