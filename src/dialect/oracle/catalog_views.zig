//! The data dictionary views of the Oracle dialect: queries over
//! sqlite_schema, pragma_table_xinfo() and the dialect catalog
//! (xq_catalog, xq_sequence), written in Oracle SQL and parsed by this
//! frontend, which a FROM item naming the view becomes (they exist only
//! while compiling in this dialect, nothing is stored).
//!
//!  - USER_TABLES, ALL_TABLES, USER_TAB_COLUMNS, ALL_TAB_COLUMNS
//!    (declared types from the catalog), USER_VIEWS, ALL_VIEWS,
//!    USER_SEQUENCES, ALL_SEQUENCES, USER_INDEXES, USER_TAB_COMMENTS,
//!    USER_COL_COMMENTS.
//!
//! Every table belongs to the current user, whose schema is main and
//! whose name (OWNER, USER) is MAIN; xqlite's own tables (sqlite_*,
//! xq_*) are left out.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const catalog = @import("../../catalog/catalog.zig");

const user_objects = " m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND m.name" ++ catalog.not_catalog_table;

const tables =
    \\SELECT {owner} m.name AS table_name, 'USERS' AS tablespace_name, 'VALID' AS status,
    \\  'N' AS temporary, NULL AS num_rows, 'YES' AS logging
    \\FROM sqlite_schema m WHERE m.type = 'table' AND
++ user_objects;

const tab_columns =
    \\SELECT {owner} m.name AS table_name, c.name AS column_name,
    \\  xq_ora_data_type(k.value, c.type) AS data_type,
    \\  xq_ora_data_length(k.value, c.type) AS data_length,
    \\  xq_ora_data_precision(k.value, c.type) AS data_precision,
    \\  xq_ora_data_scale(k.value, c.type) AS data_scale,
    \\  CASE WHEN c."notnull" <> 0 OR c.pk <> 0 THEN 'N' ELSE 'Y' END AS nullable,
    \\  c.cid + 1 AS column_id, c.dflt_value AS data_default,
    \\  CASE WHEN i.value IS NULL THEN 'NO' ELSE 'YES' END AS identity_column,
    \\  CASE WHEN c.hidden IN (2, 3) THEN 'YES' ELSE 'NO' END AS virtual_column
    \\FROM sqlite_schema m, pragma_table_xinfo(m.name) c
    \\  LEFT JOIN {cat} k ON k.tbl = m.name AND k.col = c.name AND k.key = 'type'
    \\  LEFT JOIN {cat} i ON i.tbl = m.name AND i.col = c.name AND i.key = 'identity'
    \\WHERE m.type IN ('table', 'view') AND c.hidden <> 1 AND
++ user_objects;

const views_ =
    \\SELECT {owner} m.name AS view_name, length(m.sql) AS text_length, m.sql AS text
    \\FROM sqlite_schema m WHERE m.type = 'view' AND
++ user_objects;

const sequences =
    \\SELECT {seq_owner} s.name AS sequence_name, coalesce(s.min_value, 1) AS min_value,
    \\  coalesce(s.max_value, 9999999999999999999999999999) AS max_value,
    \\  s.increment AS increment_by, CASE WHEN s.cycle <> 0 THEN 'Y' ELSE 'N' END AS cycle_flag,
    \\  'N' AS order_flag, 0 AS cache_size,
    \\  CASE WHEN s.is_called <> 0 THEN s.last_value + s.increment ELSE s.last_value END AS last_number
    \\FROM {seq} s
;

const indexes =
    \\SELECT m.name AS index_name, 'NORMAL' AS index_type, m.tbl_name AS table_name,
    \\  CASE WHEN (SELECT l."unique" FROM pragma_index_list(m.tbl_name) l WHERE l.name = m.name) = 1
    \\    THEN 'UNIQUE' ELSE 'NONUNIQUE' END AS uniqueness, 'VALID' AS status
    \\FROM sqlite_schema m WHERE m.type = 'index' AND m.tbl_name NOT LIKE 'sqlite\_%' ESCAPE '\' AND m.tbl_name
++ catalog.not_catalog_table;

const tab_comments =
    \\SELECT m.name AS table_name, CASE m.type WHEN 'view' THEN 'VIEW' ELSE 'TABLE' END AS table_type,
    \\  (SELECT k.value FROM {cat} k WHERE k.tbl = m.name AND coalesce(length(k.col), 0) = 0 AND k.key = 'oracle.comment') AS comments
    \\FROM sqlite_schema m WHERE m.type IN ('table', 'view') AND
++ user_objects;

const col_comments =
    \\SELECT m.name AS table_name, c.name AS column_name,
    \\  (SELECT k.value FROM {cat} k WHERE k.tbl = m.name AND k.col = c.name AND k.key = 'oracle.comment') AS comments
    \\FROM sqlite_schema m, pragma_table_xinfo(m.name) c
    \\WHERE m.type IN ('table', 'view') AND c.hidden <> 1 AND
++ user_objects;

const empty_catalog = "(SELECT NULL AS tbl, NULL AS col, NULL AS key, NULL AS value FROM dual WHERE 1 = 0)";
const empty_sequence = "(SELECT NULL AS name, NULL AS last_value, NULL AS start_value, NULL AS increment, NULL AS min_value, NULL AS max_value, NULL AS cycle, NULL AS is_called FROM dual WHERE 1 = 0)";

const Def = struct { name: []const u8, text: []const u8, all: bool = false };

const defs = [_]Def{
    .{ .name = "USER_TABLES", .text = tables },
    .{ .name = "ALL_TABLES", .text = tables, .all = true },
    .{ .name = "USER_TAB_COLUMNS", .text = tab_columns },
    .{ .name = "ALL_TAB_COLUMNS", .text = tab_columns, .all = true },
    .{ .name = "USER_VIEWS", .text = views_ },
    .{ .name = "ALL_VIEWS", .text = views_, .all = true },
    .{ .name = "USER_SEQUENCES", .text = sequences },
    .{ .name = "ALL_SEQUENCES", .text = sequences, .all = true },
    .{ .name = "USER_INDEXES", .text = indexes },
    .{ .name = "USER_TAB_COMMENTS", .text = tab_comments },
    .{ .name = "USER_COL_COMMENTS", .text = col_comments },
};

/// The Oracle text of data dictionary view `name`, allocated in the
/// statement's arena; null if there is no such view.
pub fn definition(p: *int.Parse, name: []const u8) error{OutOfMemory}!?[:0]const u8 {
    for (defs) |d| {
        if (!std.ascii.eqlIgnoreCase(d.name, name)) continue;
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
            } else if (std.mem.eql(u8, key, "seq")) {
                try out.appendSlice(p.arena, if (has_sequences) "xq_sequence" else empty_sequence);
            } else if (std.mem.eql(u8, key, "owner")) {
                if (d.all) try out.appendSlice(p.arena, "'MAIN' AS owner,");
            } else if (std.mem.eql(u8, key, "seq_owner")) {
                if (d.all) try out.appendSlice(p.arena, "'MAIN' AS sequence_owner,");
            }
            rest = rest[end + 1 ..];
        }
        try out.appendSlice(p.arena, rest);
        return try p.arena.dupeSentinel(u8, out.items, 0);
    }
    return null;
}
