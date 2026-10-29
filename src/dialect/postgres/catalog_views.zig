//! information_schema and pg_catalog views of the PostgreSQL dialect:
//! queries over sqlite_schema, pragma_table_xinfo() and the dialect
//! catalog (xq_catalog, xq_sequence), written in PostgreSQL and parsed
//! by this frontend, which a FROM item naming the view becomes (they
//! exist only while compiling in this dialect, nothing is stored).
//!
//!  - information_schema: tables, columns (declared types from the
//!    catalog), views, schemata, sequences;
//!  - pg_catalog (also without the schema, as in PostgreSQL's
//!    search_path): pg_tables, pg_views, pg_indexes, pg_sequences.
//!
//! Every table is in schema "public" of catalog "main"; xqlite's own
//! tables (sqlite_*, xq_*) are left out.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const catalog = @import("../../catalog/catalog.zig");

const user_tables = " m.name NOT LIKE 'sqlite\\_%' AND m.name" ++ catalog.not_catalog_table;

/// `{cat}` and `{seq}` stand for xq_catalog and xq_sequence, or for an
/// empty query of the same columns when the database has none.
const tables =
    \\SELECT 'main' AS table_catalog, 'public' AS table_schema, m.name AS table_name,
    \\  CASE m.type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS table_type,
    \\  NULL AS self_referencing_column_name, NULL AS reference_generation,
    \\  NULL AS user_defined_type_catalog, NULL AS user_defined_type_schema, NULL AS user_defined_type_name,
    \\  CASE m.type WHEN 'view' THEN 'NO' ELSE 'YES' END AS is_insertable_into,
    \\  'NO' AS is_typed, NULL AS commit_action
    \\FROM sqlite_schema m WHERE m.type IN ('table', 'view') AND
++ user_tables;

const columns =
    \\SELECT 'main' AS table_catalog, 'public' AS table_schema, m.name AS table_name,
    \\  c.name AS column_name, c.cid + 1 AS ordinal_position, c.dflt_value AS column_default,
    \\  CASE WHEN c."notnull" <> 0 OR c.pk <> 0 THEN 'NO' ELSE 'YES' END AS is_nullable,
    \\  xq_pg_data_type(k.value, c.type) AS data_type,
    \\  xq_pg_char_max(k.value, c.type) AS character_maximum_length,
    \\  xq_pg_num_precision(k.value, c.type) AS numeric_precision,
    \\  xq_pg_num_scale(k.value, c.type) AS numeric_scale,
    \\  'main' AS udt_catalog, 'pg_catalog' AS udt_schema,
    \\  xq_pg_udt_name(k.value, c.type) AS udt_name,
    \\  CASE WHEN i.value IS NULL THEN 'NO' ELSE 'YES' END AS is_identity,
    \\  CASE i.value WHEN 'always' THEN 'ALWAYS' WHEN 'by default' THEN 'BY DEFAULT' END AS identity_generation,
    \\  CASE WHEN c.hidden IN (2, 3) THEN 'ALWAYS' ELSE 'NEVER' END AS is_generated,
    \\  CASE WHEN m.type = 'view' THEN 'NO' ELSE 'YES' END AS is_updatable
    \\FROM sqlite_schema m, pragma_table_xinfo(m.name) c
    \\  LEFT JOIN {cat} k ON k.tbl = m.name AND k.col = c.name AND k.key = 'type'
    \\  LEFT JOIN {cat} i ON i.tbl = m.name AND i.col = c.name AND i.key = 'identity_kind'
    \\WHERE m.type IN ('table', 'view') AND c.hidden <> 1 AND
++ user_tables;

const views_ =
    \\SELECT 'main' AS table_catalog, 'public' AS table_schema, m.name AS table_name,
    \\  m.sql AS view_definition, 'NONE' AS check_option, 'NO' AS is_updatable, 'NO' AS is_insertable_into
    \\FROM sqlite_schema m WHERE m.type = 'view' AND
++ user_tables;

const schemata =
    \\SELECT 'main' AS catalog_name, s AS schema_name, 'postgres' AS schema_owner
    \\FROM (VALUES ('public'), ('information_schema'), ('pg_catalog')) AS x(s)
;

const sequences =
    \\SELECT 'main' AS sequence_catalog, 'public' AS sequence_schema, s.name AS sequence_name,
    \\  'bigint' AS data_type, 64 AS numeric_precision, 2 AS numeric_precision_radix, 0 AS numeric_scale,
    \\  s.start_value::text AS start_value, s.min_value::text AS minimum_value,
    \\  s.max_value::text AS maximum_value, s.increment::text AS increment,
    \\  CASE WHEN s.cycle <> 0 THEN 'YES' ELSE 'NO' END AS cycle_option
    \\FROM {seq} s
;

const pg_tables =
    \\SELECT 'public' AS schemaname, m.name AS tablename, 'postgres' AS tableowner, NULL AS tablespace,
    \\  EXISTS (SELECT 1 FROM sqlite_schema x WHERE x.type = 'index' AND x.tbl_name = m.name) AS hasindexes,
    \\  false AS hasrules,
    \\  EXISTS (SELECT 1 FROM sqlite_schema x WHERE x.type = 'trigger' AND x.tbl_name = m.name) AS hastriggers,
    \\  false AS rowsecurity
    \\FROM sqlite_schema m WHERE m.type = 'table' AND
++ user_tables;

const pg_views =
    \\SELECT 'public' AS schemaname, m.name AS viewname, 'postgres' AS viewowner, m.sql AS definition
    \\FROM sqlite_schema m WHERE m.type = 'view' AND
++ user_tables;

const pg_indexes =
    \\SELECT 'public' AS schemaname, m.tbl_name AS tablename,
    \\  CASE WHEN m.name LIKE 'sqlite\_autoindex\_%' THEN m.tbl_name || CASE
    \\    (SELECT l.origin FROM pragma_index_list(m.tbl_name) l WHERE l.name = m.name)
    \\    WHEN 'pk' THEN '_pkey'
    \\    ELSE '_' || (SELECT string_agg(i.name, '_') FROM pragma_index_info(m.name) i) || '_key' END
    \\  ELSE m.name END AS indexname,
    \\  NULL AS tablespace, m.sql AS indexdef
    \\FROM sqlite_schema m WHERE m.type = 'index' AND m.tbl_name NOT LIKE 'sqlite\_%' AND m.tbl_name
++ catalog.not_catalog_table;

const pg_sequences =
    \\SELECT 'public' AS schemaname, s.name AS sequencename, 'postgres' AS sequenceowner,
    \\  'bigint' AS data_type, s.start_value, s.min_value, s.max_value, s.increment AS increment_by,
    \\  s.cycle <> 0 AS cycle, 1 AS cache_size,
    \\  CASE WHEN s.is_called <> 0 THEN s.last_value END AS last_value
    \\FROM {seq} s
;

const empty_catalog = "(SELECT NULL AS tbl, NULL AS col, NULL AS key, NULL AS value WHERE false)";
const empty_sequence = "(SELECT NULL AS name, NULL AS last_value, NULL AS start_value, NULL AS increment, NULL AS min_value, NULL AS max_value, NULL AS cycle, NULL AS is_called WHERE false)";

const Def = struct { schema: []const u8, name: []const u8, text: []const u8 };

const defs = [_]Def{
    .{ .schema = "information_schema", .name = "tables", .text = tables },
    .{ .schema = "information_schema", .name = "columns", .text = columns },
    .{ .schema = "information_schema", .name = "views", .text = views_ },
    .{ .schema = "information_schema", .name = "schemata", .text = schemata },
    .{ .schema = "information_schema", .name = "sequences", .text = sequences },
    .{ .schema = "pg_catalog", .name = "pg_tables", .text = pg_tables },
    .{ .schema = "pg_catalog", .name = "pg_views", .text = pg_views },
    .{ .schema = "pg_catalog", .name = "pg_indexes", .text = pg_indexes },
    .{ .schema = "pg_catalog", .name = "pg_sequences", .text = pg_sequences },
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
        var out: std.ArrayList(u8) = .empty;
        var rest: []const u8 = d.text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |i| {
            try out.appendSlice(p.arena, rest[0..i]);
            const end = std.mem.indexOfScalarPos(u8, rest, i, '}').?;
            const key = rest[i + 1 .. end];
            if (std.mem.eql(u8, key, "cat")) {
                try out.appendSlice(p.arena, if (has_catalog) "xq_catalog" else empty_catalog);
            } else {
                try out.appendSlice(p.arena, if (has_sequences) "xq_sequence" else empty_sequence);
            }
            rest = rest[end + 1 ..];
        }
        try out.appendSlice(p.arena, rest);
        return try p.arena.dupeSentinel(u8, out.items, 0);
    }
    return null;
}
