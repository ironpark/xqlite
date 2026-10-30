//! The data dictionary views of the Oracle dialect: queries over
//! sqlite_schema, pragma_table_xinfo() and the dialect catalog
//! (xq_catalog, xq_sequence), written in Oracle SQL and parsed by this
//! frontend, which a FROM item naming the view becomes (they exist only
//! while compiling in this dialect, nothing is stored).
//!
//!  - USER_TABLES, ALL_TABLES, USER_TAB_COLUMNS, ALL_TAB_COLUMNS
//!    (declared types from the catalog), USER_VIEWS, ALL_VIEWS,
//!    USER_SEQUENCES, ALL_SEQUENCES, USER_INDEXES, ALL_INDEXES,
//!    USER_TAB_COMMENTS, ALL_TAB_COMMENTS, USER_COL_COMMENTS,
//!    ALL_COL_COMMENTS (DBA_* as ALL_*), and ALL_USERS, DBA_USERS,
//!    USER_USERS.
//!
//! The objects of main belong to the connected user MAIN (state.user),
//! except those of a user of CREATE USER (catalog/schema.zig), named
//! "U.T" in SQLite, which belong to U under their own name T. USER_*
//! views show MAIN's (as in Oracle, whatever the current schema is),
//! ALL_* views every user's with OWNER. xqlite's own tables (sqlite_*,
//! xq_*) are left out.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const catalog = @import("../../catalog/catalog.zig");
const state = @import("state.zig");

// `{cat}`, `{seq}` and `{users}` stand for xq_catalog, xq_sequence and
// the registered users (col), or for an empty query of the same columns
// when the database has none. `{owner}` is "o.owner AS owner," in an
// ALL_* view, `{mine}` "AND o.owner = 'MAIN'" in a USER_* view.

/// The user `n` of a mangled name `x`, joined.
fn userJoin(comptime n: []const u8, comptime x: []const u8) []const u8 {
    return " LEFT JOIN {users} " ++ n ++ " ON instr(" ++ x ++ ", '.') = length(" ++ n ++ ".col) + 1 AND substr(" ++ x ++ ", 1, length(" ++ n ++ ".col)) = " ++ n ++ ".col";
}
/// The owner of the name userJoin() split.
fn ownerOf(comptime n: []const u8) []const u8 {
    return "coalesce(" ++ n ++ ".col, '" ++ state.user ++ "')";
}
/// The name `x` without its user.
fn bare(comptime n: []const u8, comptime x: []const u8) []const u8 {
    return "CASE WHEN " ++ n ++ ".col IS NULL THEN " ++ x ++ " ELSE substr(" ++ x ++ ", length(" ++ n ++ ".col) + 2) END";
}

/// The objects of main (tables, views, indexes) with their owner and
/// name, the owner and name of their table, and the SQLite names
/// (sqlname, sqltbl).
const objects = "(SELECT m.type AS type, " ++ ownerOf("s") ++ " AS owner, " ++ bare("s", "m.name") ++ " AS name, " ++
    ownerOf("u") ++ " AS tbl_owner, " ++ bare("u", "m.tbl_name") ++ " AS tbl_name, m.sql AS sql, m.name AS sqlname, m.tbl_name AS sqltbl" ++
    " FROM sqlite_schema m" ++ userJoin("s", "m.name") ++ userJoin("u", "m.tbl_name") ++
    " WHERE m.tbl_name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND m.tbl_name" ++ catalog.not_catalog_table ++ ")";

const tables =
    \\SELECT {owner} o.name AS table_name, 'USERS' AS tablespace_name, 'VALID' AS status,
    \\  'N' AS temporary, NULL AS num_rows, 'YES' AS logging
    \\FROM {objects} o WHERE o.type = 'table' {mine}
;

const tab_columns =
    \\SELECT {owner} o.name AS table_name, c.name AS column_name,
    \\  xq_ora_data_type(k.value, c.type) AS data_type,
    \\  xq_ora_data_length(k.value, c.type) AS data_length,
    \\  xq_ora_data_precision(k.value, c.type) AS data_precision,
    \\  xq_ora_data_scale(k.value, c.type) AS data_scale,
    \\  CASE WHEN c."notnull" <> 0 OR c.pk <> 0 THEN 'N' ELSE 'Y' END AS nullable,
    \\  c.cid + 1 AS column_id, c.dflt_value AS data_default,
    \\  CASE WHEN i.value IS NULL THEN 'NO' ELSE 'YES' END AS identity_column,
    \\  CASE WHEN c.hidden IN (2, 3) THEN 'YES' ELSE 'NO' END AS virtual_column
    \\FROM {objects} o, pragma_table_xinfo(o.sqlname) c
    \\  LEFT JOIN {cat} k ON k.tbl = o.sqlname AND k.col = c.name AND k.key = 'type'
    \\  LEFT JOIN {cat} i ON i.tbl = o.sqlname AND i.col = c.name AND i.key = 'identity'
    \\WHERE o.type IN ('table', 'view') AND c.hidden <> 1 {mine}
;

const views_ =
    \\SELECT {owner} o.name AS view_name, length(o.sql) AS text_length, o.sql AS text
    \\FROM {objects} o WHERE o.type = 'view' {mine}
;

const sequences = "SELECT {seq_owner} " ++ bare("u", "s.name") ++ " AS sequence_name," ++
    \\  coalesce(s.min_value, 1) AS min_value,
    \\  coalesce(s.max_value, 9999999999999999999999999999) AS max_value,
    \\  s.increment AS increment_by, CASE WHEN s.cycle <> 0 THEN 'Y' ELSE 'N' END AS cycle_flag,
    \\  'N' AS order_flag, 0 AS cache_size,
    \\  CASE WHEN s.is_called <> 0 THEN s.last_value + s.increment ELSE s.last_value END AS last_number
    \\FROM {seq} s
++ userJoin("u", "s.name") ++ " WHERE 1 = 1 {seq_mine}";

const indexes =
    \\SELECT {owner} o.name AS index_name, 'NORMAL' AS index_type, o.tbl_owner AS table_owner, o.tbl_name AS table_name,
    \\  CASE WHEN (SELECT l."unique" FROM pragma_index_list(o.sqltbl) l WHERE l.name = o.sqlname) = 1
    \\    THEN 'UNIQUE' ELSE 'NONUNIQUE' END AS uniqueness, 'VALID' AS status
    \\FROM {objects} o WHERE o.type = 'index' {mine}
;

const tab_comments =
    \\SELECT {owner} o.name AS table_name, CASE o.type WHEN 'view' THEN 'VIEW' ELSE 'TABLE' END AS table_type,
    \\  (SELECT k.value FROM {cat} k WHERE k.tbl = o.sqlname AND coalesce(length(k.col), 0) = 0 AND k.key = 'oracle.comment') AS comments
    \\FROM {objects} o WHERE o.type IN ('table', 'view') {mine}
;

const col_comments =
    \\SELECT {owner} o.name AS table_name, c.name AS column_name,
    \\  (SELECT k.value FROM {cat} k WHERE k.tbl = o.sqlname AND k.col = c.name AND k.key = 'oracle.comment') AS comments
    \\FROM {objects} o, pragma_table_xinfo(o.sqlname) c
    \\WHERE o.type IN ('table', 'view') AND c.hidden <> 1 {mine}
;

/// The users: MAIN (id 100), then the registered ones by name.
const users_ =
    \\SELECT x.username, x.user_id, 'OPEN' AS account_status, 'USERS' AS default_tablespace,
    \\  'TEMP' AS temporary_tablespace, NULL AS created, 'DEFAULT' AS profile,
    \\  'PASSWORD' AS authentication_type, 'NO' AS common, 'N' AS oracle_maintained
    \\FROM (SELECT 'MAIN' AS username, 100 AS user_id FROM dual
    \\  UNION ALL SELECT u.col, 100 + (SELECT count(*) FROM {users} v WHERE v.col <= u.col) FROM {users} u) x
    \\WHERE 1 = 1 {user_mine}
;

const empty_catalog = "(SELECT NULL AS tbl, NULL AS col, NULL AS key, NULL AS value FROM dual WHERE 1 = 0)";
const empty_sequence = "(SELECT NULL AS name, NULL AS last_value, NULL AS start_value, NULL AS increment, NULL AS min_value, NULL AS max_value, NULL AS cycle, NULL AS is_called FROM dual WHERE 1 = 0)";
const registered = "(SELECT col FROM xq_catalog WHERE key = '" ++ catalog.schemas.key ++ "')";
const empty_users = "(SELECT NULL AS col FROM dual WHERE 1 = 0)";

const seq_owner = ownerOf("u") ++ " AS sequence_owner,";

const Scope = enum { user, all };

const Def = struct { name: []const u8, text: []const u8, scope: Scope };

const defs = [_]Def{
    .{ .name = "USER_TABLES", .text = tables, .scope = .user },
    .{ .name = "ALL_TABLES", .text = tables, .scope = .all },
    .{ .name = "DBA_TABLES", .text = tables, .scope = .all },
    .{ .name = "USER_TAB_COLUMNS", .text = tab_columns, .scope = .user },
    .{ .name = "ALL_TAB_COLUMNS", .text = tab_columns, .scope = .all },
    .{ .name = "DBA_TAB_COLUMNS", .text = tab_columns, .scope = .all },
    .{ .name = "USER_VIEWS", .text = views_, .scope = .user },
    .{ .name = "ALL_VIEWS", .text = views_, .scope = .all },
    .{ .name = "DBA_VIEWS", .text = views_, .scope = .all },
    .{ .name = "USER_SEQUENCES", .text = sequences, .scope = .user },
    .{ .name = "ALL_SEQUENCES", .text = sequences, .scope = .all },
    .{ .name = "DBA_SEQUENCES", .text = sequences, .scope = .all },
    .{ .name = "USER_INDEXES", .text = indexes, .scope = .user },
    .{ .name = "ALL_INDEXES", .text = indexes, .scope = .all },
    .{ .name = "DBA_INDEXES", .text = indexes, .scope = .all },
    .{ .name = "USER_TAB_COMMENTS", .text = tab_comments, .scope = .user },
    .{ .name = "ALL_TAB_COMMENTS", .text = tab_comments, .scope = .all },
    .{ .name = "USER_COL_COMMENTS", .text = col_comments, .scope = .user },
    .{ .name = "ALL_COL_COMMENTS", .text = col_comments, .scope = .all },
    .{ .name = "USER_USERS", .text = users_, .scope = .user },
    .{ .name = "ALL_USERS", .text = users_, .scope = .all },
    .{ .name = "DBA_USERS", .text = users_, .scope = .all },
};

/// The Oracle text of data dictionary view `name`, allocated in the
/// statement's arena; null if there is no such view.
pub fn definition(p: *int.Parse, name: []const u8) error{OutOfMemory}!?[:0]const u8 {
    for (defs) |d| {
        if (!std.ascii.eqlIgnoreCase(d.name, name)) continue;
        const has_catalog = catalog.exists(p.db, catalog.main_schema);
        const has_sequences = catalog.sequence.exists(p.db, catalog.main_schema);
        const all = d.scope == .all;
        var out: std.ArrayList(u8) = .empty;
        var rest: []const u8 = d.text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |i| {
            try out.appendSlice(p.arena, rest[0..i]);
            const end = std.mem.indexOfScalarPos(u8, rest, i, '}').?;
            const key = rest[i + 1 .. end];
            const Sub = struct { []const u8, []const u8 };
            const subs = [_]Sub{
                .{ "cat", if (has_catalog) "xq_catalog" else empty_catalog },
                .{ "seq", if (has_sequences) "xq_sequence" else empty_sequence },
                .{ "users", if (has_catalog) registered else empty_users },
                .{ "objects", objects },
                .{ "owner", if (all) "o.owner AS owner," else "" },
                .{ "mine", if (all) "" else "AND o.owner = '" ++ state.user ++ "'" },
                .{ "seq_owner", if (all) seq_owner else "" },
                .{ "seq_mine", if (all) "" else "AND u.col IS NULL" },
                .{ "user_mine", if (all) "" else "AND x.username = '" ++ state.user ++ "'" },
            };
            var found = false;
            for (subs) |sub| if (std.mem.eql(u8, key, sub[0])) {
                // {objects} has {users} in it.
                if (std.mem.indexOfScalar(u8, sub[1], '{') != null) {
                    rest = try std.mem.concat(p.arena, u8, &.{ sub[1], rest[end + 1 ..] });
                } else {
                    try out.appendSlice(p.arena, sub[1]);
                    rest = rest[end + 1 ..];
                }
                found = true;
                break;
            };
            std.debug.assert(found);
        }
        try out.appendSlice(p.arena, rest);
        return try p.arena.dupeSentinel(u8, out.items, 0);
    }
    return null;
}
