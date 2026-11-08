//! PostgreSQL's system catalogs, made from the schema in memory: the rows
//! of pg_namespace, pg_class, pg_attribute, pg_type, pg_index,
//! pg_constraint, pg_attrdef, pg_proc, pg_sequence and pg_depend, as
//! PostgreSQL 18 would have them for the objects of the connection's
//! databases (main and its CREATE SCHEMA schemas, temp as pg_temp_1, an
//! attached database as the schema of its name).
//!
//! A Snapshot is read from the Tables, Indexes and foreign keys of each
//! Schema, the dialect catalog (catalog.meta(): declared types, identity
//! columns, constraint names), xq_sequence and the SQL text of
//! sqlite_schema (CHECK constraints, index expressions, view queries),
//! all copied into its arena: it holds no pointer into the schema, which
//! may be read again while a statement uses the snapshot. The connection
//! keeps the last one (State.catalog) while no database's schema changed
//! and no row was written (Sqlite3.n_total_change), so the catalog
//! functions called once a row (pg_table_is_visible(), the reg* casts)
//! read it once a statement. Each user is counted (acquire()/release()).
//! As it is made again after each write, what costs is made when first
//! read and kept in it: the PostgreSQL texts of the expressions (Expr:
//! deparse.zig reads each once for both modes) and the rows of each
//! relation (rowsOf(), freed when only the cache holds the snapshot:
//! release()). What is looked up by name or OID is hashed, a relation's
//! rows by their range (Snapshot.ranges).
//!
//! The relations are engine table-valued functions (eponymous virtual
//! tables, Hooks.engine_modules) xq_pg_class ... whose columns are
//! PostgreSQL's; catalog_views.zig's view text over each gives the
//! columns their types (`relhasindex::boolean`). Nothing is stored:
//! a database stays SQLite's, and sqlite3 never sees these names.
//!
//! OIDs. The built-in objects have PostgreSQL's (int4 23, pg_catalog 11,
//! public 2200, the pg_class relation 1259), and the system relations
//! are in the catalogs as PostgreSQL 18 has them (system, syscatalog.zig).
//! An object of a database is numbered by a hash of what names it (its
//! database and SQLite name, a constraint's table and name ...) into
//! [16384, 100000), five digits as PostgreSQL's first OIDs: no catalog
//! row is written for it, whoever made it (sqlite3, another dialect),
//! and it keeps its number across connections, VACUUM (which renumbers
//! sqlite_schema's rowids), the creation and dropping of other objects
//! and restarts, unlike a numbering by position. Of keys of one catalog
//! that hash to one number the smallest keeps it, and the others take a
//! number of a second hash into [100000, 2^31) in the order of their
//! keys (assign()): the numbering of a set of objects is a function of
//! that set, and an object no other collides with has the number of its
//! key alone. A renamed object takes a new number (PostgreSQL keeps it),
//! and a collision is resolved again when a colliding object comes or
//! goes.

const std = @import("std");
const pg_types = @import("../../sql/pg_types.zig");
const int = @import("../../sql/sqlite_int.zig");
const build = @import("../../sql/build.zig");
const prepare = @import("../../sql/prepare.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const vtab = @import("../../sql/vtab.zig");
const ctypes = @import("../../sql/types.zig");
const catalog = @import("../../catalog/catalog.zig");
const dialect = @import("../dialect.zig");
const nsp_mod = catalog.schemas;
const state = @import("state.zig");
const parser = @import("parser.zig");
const deparse = @import("deparse.zig");

const Allocator = std.mem.Allocator;
const Sqlite3 = int.Sqlite3;
const Oom = error{OutOfMemory};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ============================================================ built-ins

pub const oid_pg_catalog: u32 = 11;
pub const oid_pg_toast: u32 = 99;
pub const oid_public: u32 = 2200;
pub const oid_information_schema: u32 = 13327;
pub const oid_superuser: u32 = 10;
pub const oid_default_collation: u32 = 100;
pub const oid_c_collation: u32 = 950;
pub const first_user_oid: u32 = 16384;

/// A built-in type: pg_type's row, as PostgreSQL 16 has it.
pub const BuiltinType = struct {
    oid: u32,
    name: []const u8,
    /// format_type()'s spelling.
    fmt: []const u8,
    len: i16,
    byval: bool,
    cat: u8,
    @"align": u8 = 'i',
    storage: u8 = 'p',
    /// The stem of its I/O functions: <io>in, <io>out, <io>recv, <io>send.
    io: []const u8,
    array: u32 = 0,
    elem: u32 = 0,
    coll: u32 = 0,
    typtype: u8 = 'b',
    preferred: bool = false,
    modin: []const u8 = "",
    /// A domain's (typtype 'd'): its schema, base type and modifier.
    nsp: u32 = oid_pg_catalog,
    basetype: u32 = 0,
    typmod: i32 = -1,
};

const base_types = [_]BuiltinType{
    .{ .oid = 16, .name = "bool", .fmt = "boolean", .len = 1, .byval = true, .cat = 'B', .@"align" = 'c', .io = "bool", .array = 1000, .preferred = true },
    .{ .oid = 17, .name = "bytea", .fmt = "bytea", .len = -1, .byval = false, .cat = 'U', .storage = 'x', .io = "bytea", .array = 1001 },
    .{ .oid = 18, .name = "char", .fmt = "\"char\"", .len = 1, .byval = true, .cat = 'Z', .@"align" = 'c', .io = "char", .array = 1002 },
    .{ .oid = 19, .name = "name", .fmt = "name", .len = 64, .byval = false, .cat = 'S', .@"align" = 'c', .io = "name", .array = 1003, .coll = oid_c_collation },
    .{ .oid = 20, .name = "int8", .fmt = "bigint", .len = 8, .byval = true, .cat = 'N', .@"align" = 'd', .io = "int8", .array = 1016 },
    .{ .oid = 21, .name = "int2", .fmt = "smallint", .len = 2, .byval = true, .cat = 'N', .@"align" = 's', .io = "int2", .array = 1005 },
    .{ .oid = 22, .name = "int2vector", .fmt = "int2vector", .len = -1, .byval = false, .cat = 'A', .io = "int2vector", .array = 1006, .elem = 21 },
    .{ .oid = 23, .name = "int4", .fmt = "integer", .len = 4, .byval = true, .cat = 'N', .io = "int4", .array = 1007 },
    .{ .oid = 24, .name = "regproc", .fmt = "regproc", .len = 4, .byval = true, .cat = 'N', .io = "regproc", .array = 1008 },
    .{ .oid = 25, .name = "text", .fmt = "text", .len = -1, .byval = false, .cat = 'S', .storage = 'x', .io = "text", .array = 1009, .coll = oid_default_collation, .preferred = true },
    .{ .oid = 26, .name = "oid", .fmt = "oid", .len = 4, .byval = true, .cat = 'N', .io = "oid", .array = 1028, .preferred = true },
    .{ .oid = 27, .name = "tid", .fmt = "tid", .len = 6, .byval = false, .cat = 'U', .@"align" = 's', .io = "tid", .array = 1010 },
    .{ .oid = 28, .name = "xid", .fmt = "xid", .len = 4, .byval = true, .cat = 'U', .io = "xid", .array = 1011 },
    .{ .oid = 29, .name = "cid", .fmt = "cid", .len = 4, .byval = true, .cat = 'U', .io = "cid", .array = 1012 },
    .{ .oid = 30, .name = "oidvector", .fmt = "oidvector", .len = -1, .byval = false, .cat = 'A', .io = "oidvector", .array = 1013, .elem = 26 },
    .{ .oid = 114, .name = "json", .fmt = "json", .len = -1, .byval = false, .cat = 'U', .storage = 'x', .io = "json_", .array = 199 },
    .{ .oid = 142, .name = "xml", .fmt = "xml", .len = -1, .byval = false, .cat = 'U', .storage = 'x', .io = "xml_", .array = 143 },
    .{ .oid = 194, .name = "pg_node_tree", .fmt = "pg_node_tree", .len = -1, .byval = false, .cat = 'Z', .storage = 'x', .io = "pg_node_tree_", .coll = oid_default_collation },
    .{ .oid = 700, .name = "float4", .fmt = "real", .len = 4, .byval = true, .cat = 'N', .io = "float4", .array = 1021 },
    .{ .oid = 701, .name = "float8", .fmt = "double precision", .len = 8, .byval = true, .cat = 'N', .@"align" = 'd', .io = "float8", .array = 1022, .preferred = true },
    .{ .oid = 705, .name = "unknown", .fmt = "unknown", .len = -2, .byval = false, .cat = 'X', .@"align" = 'c', .io = "unknown", .typtype = 'p' },
    .{ .oid = 790, .name = "money", .fmt = "money", .len = 8, .byval = true, .cat = 'N', .@"align" = 'd', .io = "cash_", .array = 791 },
    .{ .oid = 869, .name = "inet", .fmt = "inet", .len = -1, .byval = false, .cat = 'I', .storage = 'm', .io = "inet_", .array = 1041, .preferred = true },
    .{ .oid = 1033, .name = "aclitem", .fmt = "aclitem", .len = 16, .byval = false, .cat = 'U', .@"align" = 'd', .io = "aclitem", .array = 1034 },
    .{ .oid = 1042, .name = "bpchar", .fmt = "character", .len = -1, .byval = false, .cat = 'S', .storage = 'x', .io = "bpchar", .array = 1014, .coll = oid_default_collation, .modin = "bpchartypmod" },
    .{ .oid = 1043, .name = "varchar", .fmt = "character varying", .len = -1, .byval = false, .cat = 'S', .storage = 'x', .io = "varchar", .array = 1015, .coll = oid_default_collation, .modin = "varchartypmod" },
    .{ .oid = 1082, .name = "date", .fmt = "date", .len = 4, .byval = true, .cat = 'D', .io = "date_", .array = 1182 },
    .{ .oid = 1083, .name = "time", .fmt = "time without time zone", .len = 8, .byval = true, .cat = 'D', .@"align" = 'd', .io = "time_", .array = 1183, .modin = "timetypmod" },
    .{ .oid = 1114, .name = "timestamp", .fmt = "timestamp without time zone", .len = 8, .byval = true, .cat = 'D', .@"align" = 'd', .io = "timestamp_", .array = 1115, .modin = "timestamptypmod" },
    .{ .oid = 1184, .name = "timestamptz", .fmt = "timestamp with time zone", .len = 8, .byval = true, .cat = 'D', .@"align" = 'd', .io = "timestamptz_", .array = 1185, .preferred = true, .modin = "timestamptztypmod" },
    .{ .oid = 1186, .name = "interval", .fmt = "interval", .len = 16, .byval = false, .cat = 'T', .@"align" = 'd', .io = "interval_", .array = 1187, .preferred = true, .modin = "intervaltypmod" },
    .{ .oid = 1266, .name = "timetz", .fmt = "time with time zone", .len = 12, .byval = false, .cat = 'D', .@"align" = 'd', .io = "timetz_", .array = 1270, .modin = "timetztypmod" },
    .{ .oid = 1560, .name = "bit", .fmt = "bit", .len = -1, .byval = false, .cat = 'V', .storage = 'x', .io = "bit_", .array = 1561, .modin = "bittypmod" },
    .{ .oid = 1562, .name = "varbit", .fmt = "bit varying", .len = -1, .byval = false, .cat = 'V', .storage = 'x', .io = "varbit_", .array = 1563, .preferred = true, .modin = "varbittypmod" },
    .{ .oid = 1700, .name = "numeric", .fmt = "numeric", .len = -1, .byval = false, .cat = 'N', .storage = 'm', .io = "numeric_", .array = 1231, .modin = "numerictypmod" },
    .{ .oid = 2202, .name = "regprocedure", .fmt = "regprocedure", .len = 4, .byval = true, .cat = 'N', .io = "regprocedure", .array = 2207 },
    .{ .oid = 2205, .name = "regclass", .fmt = "regclass", .len = 4, .byval = true, .cat = 'N', .io = "regclass", .array = 2210 },
    .{ .oid = 2206, .name = "regtype", .fmt = "regtype", .len = 4, .byval = true, .cat = 'N', .io = "regtype", .array = 2211 },
    .{ .oid = 4089, .name = "regnamespace", .fmt = "regnamespace", .len = 4, .byval = true, .cat = 'N', .io = "regnamespace", .array = 4090 },
    .{ .oid = 4096, .name = "regrole", .fmt = "regrole", .len = 4, .byval = true, .cat = 'N', .io = "regrole", .array = 4097 },
    .{ .oid = 2249, .name = "record", .fmt = "record", .len = -1, .byval = false, .cat = 'P', .@"align" = 'd', .storage = 'x', .io = "record_", .array = 2287, .typtype = 'p' },
    .{ .oid = 2275, .name = "cstring", .fmt = "cstring", .len = -2, .byval = false, .cat = 'P', .@"align" = 'c', .io = "cstring_", .array = 1263, .typtype = 'p' },
    .{ .oid = 2276, .name = "any", .fmt = "\"any\"", .len = 4, .byval = true, .cat = 'P', .io = "any_", .typtype = 'p' },
    .{ .oid = 2277, .name = "anyarray", .fmt = "anyarray", .len = -1, .byval = false, .cat = 'P', .@"align" = 'd', .storage = 'x', .io = "anyarray_", .typtype = 'p' },
    .{ .oid = 2278, .name = "void", .fmt = "void", .len = 4, .byval = true, .cat = 'P', .io = "void_", .typtype = 'p' },
    .{ .oid = 2279, .name = "trigger", .fmt = "trigger", .len = 4, .byval = true, .cat = 'P', .io = "trigger_", .typtype = 'p' },
    .{ .oid = 2283, .name = "anyelement", .fmt = "anyelement", .len = 4, .byval = true, .cat = 'P', .io = "anyelement_", .typtype = 'p' },
    .{ .oid = 2950, .name = "uuid", .fmt = "uuid", .len = 16, .byval = false, .cat = 'U', .@"align" = 'c', .io = "uuid_", .array = 2951 },
    .{ .oid = 3802, .name = "jsonb", .fmt = "jsonb", .len = -1, .byval = false, .cat = 'U', .storage = 'x', .io = "jsonb_", .array = 3807 },
    .{ .oid = 4072, .name = "jsonpath", .fmt = "jsonpath", .len = -1, .byval = false, .cat = 'U', .storage = 'x', .io = "jsonpath_", .array = 4073 },
};

/// pg_opclass's rows, as PostgreSQL 18 has them (in their order on disk,
/// which a query without ORDER BY shows): oid, opcmethod (403 btree,
/// 405 hash ...), opcname, opcfamily, opcintype, opcdefault, opckeytype.
pub const OpClass = struct { u32, u32, []const u8, u32, u32, bool, u32 };

pub const opclasses = [_]OpClass{
    .{ 10000, 403, "array_ops", 397, 2277, true, 0 },                          .{ 10001, 405, "array_ops", 627, 2277, true, 0 },
    .{ 10002, 403, "bit_ops", 423, 1560, true, 0 },                            .{ 10003, 403, "bool_ops", 424, 16, true, 0 },
    .{ 10004, 403, "bpchar_ops", 426, 1042, true, 0 },                         .{ 10005, 405, "bpchar_ops", 427, 1042, true, 0 },
    .{ 10006, 403, "bytea_ops", 428, 17, true, 0 },                            .{ 10007, 403, "char_ops", 429, 18, true, 0 },
    .{ 10008, 405, "char_ops", 431, 18, true, 0 },                             .{ 10009, 403, "cidr_ops", 1974, 869, false, 0 },
    .{ 10010, 405, "cidr_ops", 1975, 869, false, 0 },                          .{ 3122, 403, "date_ops", 434, 1082, true, 0 },
    .{ 10011, 405, "date_ops", 435, 1082, true, 0 },                           .{ 10012, 403, "float4_ops", 1970, 700, true, 0 },
    .{ 10013, 405, "float4_ops", 1971, 700, true, 0 },                         .{ 3123, 403, "float8_ops", 1970, 701, true, 0 },
    .{ 10014, 405, "float8_ops", 1971, 701, true, 0 },                         .{ 10015, 403, "inet_ops", 1974, 869, true, 0 },
    .{ 10016, 405, "inet_ops", 1975, 869, true, 0 },                           .{ 10017, 783, "inet_ops", 3550, 869, false, 0 },
    .{ 10018, 4000, "inet_ops", 3794, 869, true, 0 },                          .{ 1979, 403, "int2_ops", 1976, 21, true, 0 },
    .{ 10019, 405, "int2_ops", 1977, 21, true, 0 },                            .{ 1978, 403, "int4_ops", 1976, 23, true, 0 },
    .{ 10020, 405, "int4_ops", 1977, 23, true, 0 },                            .{ 3124, 403, "int8_ops", 1976, 20, true, 0 },
    .{ 10021, 405, "int8_ops", 1977, 20, true, 0 },                            .{ 10022, 403, "interval_ops", 1982, 1186, true, 0 },
    .{ 10023, 405, "interval_ops", 1983, 1186, true, 0 },                      .{ 10024, 403, "macaddr_ops", 1984, 829, true, 0 },
    .{ 10025, 405, "macaddr_ops", 1985, 829, true, 0 },                        .{ 10026, 403, "macaddr8_ops", 3371, 774, true, 0 },
    .{ 10027, 405, "macaddr8_ops", 3372, 774, true, 0 },                       .{ 10028, 403, "name_ops", 1994, 19, true, 2275 },
    .{ 10029, 405, "name_ops", 1995, 19, true, 0 },                            .{ 3125, 403, "numeric_ops", 1988, 1700, true, 0 },
    .{ 10030, 405, "numeric_ops", 1998, 1700, true, 0 },                       .{ 1981, 403, "oid_ops", 1989, 26, true, 0 },
    .{ 10031, 405, "oid_ops", 1990, 26, true, 0 },                             .{ 10032, 403, "oidvector_ops", 1991, 30, true, 0 },
    .{ 10033, 405, "oidvector_ops", 1992, 30, true, 0 },                       .{ 10034, 403, "record_ops", 2994, 2249, true, 0 },
    .{ 10035, 405, "record_ops", 6194, 2249, true, 0 },                        .{ 10036, 403, "record_image_ops", 3194, 2249, false, 0 },
    .{ 3126, 403, "text_ops", 1994, 25, true, 0 },                             .{ 10037, 405, "text_ops", 1995, 25, true, 0 },
    .{ 10038, 403, "time_ops", 1996, 1083, true, 0 },                          .{ 10039, 405, "time_ops", 1997, 1083, true, 0 },
    .{ 3127, 403, "timestamptz_ops", 434, 1184, true, 0 },                     .{ 10040, 405, "timestamptz_ops", 1999, 1184, true, 0 },
    .{ 10041, 403, "timetz_ops", 2000, 1266, true, 0 },                        .{ 10042, 405, "timetz_ops", 2001, 1266, true, 0 },
    .{ 10043, 403, "varbit_ops", 2002, 1562, true, 0 },                        .{ 10044, 403, "varchar_ops", 1994, 25, false, 0 },
    .{ 10045, 405, "varchar_ops", 1995, 25, false, 0 },                        .{ 3128, 403, "timestamp_ops", 434, 1114, true, 0 },
    .{ 10046, 405, "timestamp_ops", 2040, 1114, true, 0 },                     .{ 4217, 403, "text_pattern_ops", 2095, 25, false, 0 },
    .{ 4218, 403, "varchar_pattern_ops", 2095, 25, false, 0 },                 .{ 4219, 403, "bpchar_pattern_ops", 2097, 1042, false, 0 },
    .{ 10047, 403, "money_ops", 2099, 790, true, 0 },                          .{ 10048, 405, "bool_ops", 2222, 16, true, 0 },
    .{ 10049, 405, "bytea_ops", 2223, 17, true, 0 },                           .{ 10050, 403, "tid_ops", 2789, 27, true, 0 },
    .{ 10051, 405, "xid_ops", 2225, 28, true, 0 },                             .{ 10052, 405, "xid8_ops", 5032, 5069, true, 0 },
    .{ 10053, 403, "xid8_ops", 5067, 5069, true, 0 },                          .{ 10054, 405, "cid_ops", 2226, 29, true, 0 },
    .{ 10055, 405, "tid_ops", 2227, 27, true, 0 },                             .{ 10056, 405, "text_pattern_ops", 2229, 25, false, 0 },
    .{ 10057, 405, "varchar_pattern_ops", 2229, 25, false, 0 },                .{ 10058, 405, "bpchar_pattern_ops", 2231, 1042, false, 0 },
    .{ 10059, 405, "aclitem_ops", 2235, 1033, true, 0 },                       .{ 10060, 783, "box_ops", 2593, 603, true, 0 },
    .{ 10061, 783, "point_ops", 1029, 600, true, 603 },                        .{ 10062, 783, "poly_ops", 2594, 604, true, 603 },
    .{ 10063, 783, "circle_ops", 2595, 718, true, 603 },                       .{ 10064, 2742, "array_ops", 2745, 2277, true, 2283 },
    .{ 10065, 403, "uuid_ops", 2968, 2950, true, 0 },                          .{ 10066, 405, "uuid_ops", 2969, 2950, true, 0 },
    .{ 10067, 403, "pg_lsn_ops", 3253, 3220, true, 0 },                        .{ 10068, 405, "pg_lsn_ops", 3254, 3220, true, 0 },
    .{ 10069, 403, "enum_ops", 3522, 3500, true, 0 },                          .{ 10070, 405, "enum_ops", 3523, 3500, true, 0 },
    .{ 10071, 403, "tsvector_ops", 3626, 3614, true, 0 },                      .{ 10072, 783, "tsvector_ops", 3655, 3614, true, 3642 },
    .{ 10073, 2742, "tsvector_ops", 3659, 3614, true, 25 },                    .{ 10074, 403, "tsquery_ops", 3683, 3615, true, 0 },
    .{ 10075, 783, "tsquery_ops", 3702, 3615, true, 20 },                      .{ 10076, 403, "range_ops", 3901, 3831, true, 0 },
    .{ 10077, 405, "range_ops", 3903, 3831, true, 0 },                         .{ 10078, 783, "range_ops", 3919, 3831, true, 0 },
    .{ 10079, 4000, "range_ops", 3474, 3831, true, 0 },                        .{ 10080, 403, "multirange_ops", 4199, 4537, true, 0 },
    .{ 10081, 405, "multirange_ops", 4225, 4537, true, 0 },                    .{ 10082, 783, "multirange_ops", 6158, 4537, true, 3831 },
    .{ 10083, 4000, "box_ops", 5000, 603, true, 0 },                           .{ 10084, 4000, "quad_point_ops", 4015, 600, true, 0 },
    .{ 10085, 4000, "kd_point_ops", 4016, 600, false, 0 },                     .{ 10086, 4000, "text_ops", 4017, 25, true, 0 },
    .{ 10087, 4000, "poly_ops", 5008, 604, true, 603 },                        .{ 10088, 403, "jsonb_ops", 4033, 3802, true, 0 },
    .{ 10089, 405, "jsonb_ops", 4034, 3802, true, 0 },                         .{ 10090, 2742, "jsonb_ops", 4036, 3802, true, 25 },
    .{ 10091, 2742, "jsonb_path_ops", 4037, 3802, false, 23 },                 .{ 10092, 3580, "bytea_minmax_ops", 4064, 17, true, 17 },
    .{ 10093, 3580, "bytea_bloom_ops", 4578, 17, false, 17 },                  .{ 10094, 3580, "char_minmax_ops", 4062, 18, true, 18 },
    .{ 10095, 3580, "char_bloom_ops", 4577, 18, false, 18 },                   .{ 10096, 3580, "name_minmax_ops", 4065, 19, true, 19 },
    .{ 10097, 3580, "name_bloom_ops", 4579, 19, false, 19 },                   .{ 10098, 3580, "int8_minmax_ops", 4054, 20, true, 20 },
    .{ 10099, 3580, "int8_minmax_multi_ops", 4602, 20, false, 20 },            .{ 10100, 3580, "int8_bloom_ops", 4572, 20, false, 20 },
    .{ 10101, 3580, "int2_minmax_ops", 4054, 21, true, 21 },                   .{ 10102, 3580, "int2_minmax_multi_ops", 4602, 21, false, 21 },
    .{ 10103, 3580, "int2_bloom_ops", 4572, 21, false, 21 },                   .{ 10104, 3580, "int4_minmax_ops", 4054, 23, true, 23 },
    .{ 10105, 3580, "int4_minmax_multi_ops", 4602, 23, false, 23 },            .{ 10106, 3580, "int4_bloom_ops", 4572, 23, false, 23 },
    .{ 10107, 3580, "text_minmax_ops", 4056, 25, true, 25 },                   .{ 10108, 3580, "text_bloom_ops", 4573, 25, false, 25 },
    .{ 10109, 3580, "oid_minmax_ops", 4068, 26, true, 26 },                    .{ 10110, 3580, "oid_minmax_multi_ops", 4606, 26, false, 26 },
    .{ 10111, 3580, "oid_bloom_ops", 4580, 26, false, 26 },                    .{ 10112, 3580, "tid_minmax_ops", 4069, 27, true, 27 },
    .{ 10113, 3580, "tid_bloom_ops", 4581, 27, false, 27 },                    .{ 10114, 3580, "tid_minmax_multi_ops", 4607, 27, false, 27 },
    .{ 10115, 3580, "float4_minmax_ops", 4070, 700, true, 700 },               .{ 10116, 3580, "float4_minmax_multi_ops", 4608, 700, false, 700 },
    .{ 10117, 3580, "float4_bloom_ops", 4582, 700, false, 700 },               .{ 10118, 3580, "float8_minmax_ops", 4070, 701, true, 701 },
    .{ 10119, 3580, "float8_minmax_multi_ops", 4608, 701, false, 701 },        .{ 10120, 3580, "float8_bloom_ops", 4582, 701, false, 701 },
    .{ 10121, 3580, "macaddr_minmax_ops", 4074, 829, true, 829 },              .{ 10122, 3580, "macaddr_minmax_multi_ops", 4609, 829, false, 829 },
    .{ 10123, 3580, "macaddr_bloom_ops", 4583, 829, false, 829 },              .{ 10124, 3580, "macaddr8_minmax_ops", 4109, 774, true, 774 },
    .{ 10125, 3580, "macaddr8_minmax_multi_ops", 4610, 774, false, 774 },      .{ 10126, 3580, "macaddr8_bloom_ops", 4584, 774, false, 774 },
    .{ 10127, 3580, "inet_minmax_ops", 4075, 869, false, 869 },                .{ 10128, 3580, "inet_minmax_multi_ops", 4611, 869, false, 869 },
    .{ 10129, 3580, "inet_bloom_ops", 4585, 869, false, 869 },                 .{ 10130, 3580, "inet_inclusion_ops", 4102, 869, true, 869 },
    .{ 10131, 3580, "bpchar_minmax_ops", 4076, 1042, true, 1042 },             .{ 10132, 3580, "bpchar_bloom_ops", 4586, 1042, false, 1042 },
    .{ 10133, 3580, "time_minmax_ops", 4077, 1083, true, 1083 },               .{ 10134, 3580, "time_minmax_multi_ops", 4612, 1083, false, 1083 },
    .{ 10135, 3580, "time_bloom_ops", 4587, 1083, false, 1083 },               .{ 10136, 3580, "date_minmax_ops", 4059, 1082, true, 1082 },
    .{ 10137, 3580, "date_minmax_multi_ops", 4605, 1082, false, 1082 },        .{ 10138, 3580, "date_bloom_ops", 4576, 1082, false, 1082 },
    .{ 10139, 3580, "timestamp_minmax_ops", 4059, 1114, true, 1114 },          .{ 10140, 3580, "timestamp_minmax_multi_ops", 4605, 1114, false, 1114 },
    .{ 10141, 3580, "timestamp_bloom_ops", 4576, 1114, false, 1114 },          .{ 10142, 3580, "timestamptz_minmax_ops", 4059, 1184, true, 1184 },
    .{ 10143, 3580, "timestamptz_minmax_multi_ops", 4605, 1184, false, 1184 }, .{ 10144, 3580, "timestamptz_bloom_ops", 4576, 1184, false, 1184 },
    .{ 10145, 3580, "interval_minmax_ops", 4078, 1186, true, 1186 },           .{ 10146, 3580, "interval_minmax_multi_ops", 4613, 1186, false, 1186 },
    .{ 10147, 3580, "interval_bloom_ops", 4588, 1186, false, 1186 },           .{ 10148, 3580, "timetz_minmax_ops", 4058, 1266, true, 1266 },
    .{ 10149, 3580, "timetz_minmax_multi_ops", 4604, 1266, false, 1266 },      .{ 10150, 3580, "timetz_bloom_ops", 4575, 1266, false, 1266 },
    .{ 10151, 3580, "bit_minmax_ops", 4079, 1560, true, 1560 },                .{ 10152, 3580, "varbit_minmax_ops", 4080, 1562, true, 1562 },
    .{ 10153, 3580, "numeric_minmax_ops", 4055, 1700, true, 1700 },            .{ 10154, 3580, "numeric_minmax_multi_ops", 4603, 1700, false, 1700 },
    .{ 10155, 3580, "numeric_bloom_ops", 4574, 1700, false, 1700 },            .{ 10156, 3580, "uuid_minmax_ops", 4081, 2950, true, 2950 },
    .{ 10157, 3580, "uuid_minmax_multi_ops", 4614, 2950, false, 2950 },        .{ 10158, 3580, "uuid_bloom_ops", 4589, 2950, false, 2950 },
    .{ 10159, 3580, "range_inclusion_ops", 4103, 3831, true, 3831 },           .{ 10160, 3580, "pg_lsn_minmax_ops", 4082, 3220, true, 3220 },
    .{ 10161, 3580, "pg_lsn_minmax_multi_ops", 4615, 3220, false, 3220 },      .{ 10162, 3580, "pg_lsn_bloom_ops", 4590, 3220, false, 3220 },
    .{ 10163, 3580, "box_inclusion_ops", 4104, 603, true, 603 },
};

/// pg_opfamily's rows (in their order on disk): oid, opfmethod, opfname.
pub const opfamilies = [_]struct { u32, u32, []const u8 }{
    .{ 397, 403, "array_ops" },                  .{ 627, 405, "array_ops" },                   .{ 423, 403, "bit_ops" },                     .{ 424, 403, "bool_ops" },                   .{ 426, 403, "bpchar_ops" },
    .{ 427, 405, "bpchar_ops" },                 .{ 428, 403, "bytea_ops" },                   .{ 429, 403, "char_ops" },                    .{ 431, 405, "char_ops" },                   .{ 434, 403, "datetime_ops" },
    .{ 435, 405, "date_ops" },                   .{ 1970, 403, "float_ops" },                  .{ 1971, 405, "float_ops" },                  .{ 1974, 403, "network_ops" },               .{ 1975, 405, "network_ops" },
    .{ 3550, 783, "network_ops" },               .{ 3794, 4000, "network_ops" },               .{ 1976, 403, "integer_ops" },                .{ 1977, 405, "integer_ops" },               .{ 1982, 403, "interval_ops" },
    .{ 1983, 405, "interval_ops" },              .{ 1984, 403, "macaddr_ops" },                .{ 1985, 405, "macaddr_ops" },                .{ 3371, 403, "macaddr8_ops" },              .{ 3372, 405, "macaddr8_ops" },
    .{ 1988, 403, "numeric_ops" },               .{ 1998, 405, "numeric_ops" },                .{ 1989, 403, "oid_ops" },                    .{ 1990, 405, "oid_ops" },                   .{ 1991, 403, "oidvector_ops" },
    .{ 1992, 405, "oidvector_ops" },             .{ 2994, 403, "record_ops" },                 .{ 6194, 405, "record_ops" },                 .{ 3194, 403, "record_image_ops" },          .{ 1994, 403, "text_ops" },
    .{ 1995, 405, "text_ops" },                  .{ 1996, 403, "time_ops" },                   .{ 1997, 405, "time_ops" },                   .{ 1999, 405, "timestamptz_ops" },           .{ 2000, 403, "timetz_ops" },
    .{ 2001, 405, "timetz_ops" },                .{ 2002, 403, "varbit_ops" },                 .{ 2040, 405, "timestamp_ops" },              .{ 2095, 403, "text_pattern_ops" },          .{ 2097, 403, "bpchar_pattern_ops" },
    .{ 2099, 403, "money_ops" },                 .{ 2222, 405, "bool_ops" },                   .{ 2223, 405, "bytea_ops" },                  .{ 2789, 403, "tid_ops" },                   .{ 2225, 405, "xid_ops" },
    .{ 5032, 405, "xid8_ops" },                  .{ 5067, 403, "xid8_ops" },                   .{ 2226, 405, "cid_ops" },                    .{ 2227, 405, "tid_ops" },                   .{ 2229, 405, "text_pattern_ops" },
    .{ 2231, 405, "bpchar_pattern_ops" },        .{ 2235, 405, "aclitem_ops" },                .{ 2593, 783, "box_ops" },                    .{ 2594, 783, "poly_ops" },                  .{ 2595, 783, "circle_ops" },
    .{ 1029, 783, "point_ops" },                 .{ 2745, 2742, "array_ops" },                 .{ 2968, 403, "uuid_ops" },                   .{ 2969, 405, "uuid_ops" },                  .{ 3253, 403, "pg_lsn_ops" },
    .{ 3254, 405, "pg_lsn_ops" },                .{ 3522, 403, "enum_ops" },                   .{ 3523, 405, "enum_ops" },                   .{ 3626, 403, "tsvector_ops" },              .{ 3655, 783, "tsvector_ops" },
    .{ 3659, 2742, "tsvector_ops" },             .{ 3683, 403, "tsquery_ops" },                .{ 3702, 783, "tsquery_ops" },                .{ 3901, 403, "range_ops" },                 .{ 3903, 405, "range_ops" },
    .{ 3919, 783, "range_ops" },                 .{ 3474, 4000, "range_ops" },                 .{ 4015, 4000, "quad_point_ops" },            .{ 4016, 4000, "kd_point_ops" },             .{ 4017, 4000, "text_ops" },
    .{ 4033, 403, "jsonb_ops" },                 .{ 4034, 405, "jsonb_ops" },                  .{ 4036, 2742, "jsonb_ops" },                 .{ 4037, 2742, "jsonb_path_ops" },           .{ 4054, 3580, "integer_minmax_ops" },
    .{ 4602, 3580, "integer_minmax_multi_ops" }, .{ 4572, 3580, "integer_bloom_ops" },         .{ 4055, 3580, "numeric_minmax_ops" },        .{ 4603, 3580, "numeric_minmax_multi_ops" }, .{ 4056, 3580, "text_minmax_ops" },
    .{ 4573, 3580, "text_bloom_ops" },           .{ 4574, 3580, "numeric_bloom_ops" },         .{ 4058, 3580, "timetz_minmax_ops" },         .{ 4604, 3580, "timetz_minmax_multi_ops" },  .{ 4575, 3580, "timetz_bloom_ops" },
    .{ 4059, 3580, "datetime_minmax_ops" },      .{ 4605, 3580, "datetime_minmax_multi_ops" }, .{ 4576, 3580, "datetime_bloom_ops" },        .{ 4062, 3580, "char_minmax_ops" },          .{ 4577, 3580, "char_bloom_ops" },
    .{ 4064, 3580, "bytea_minmax_ops" },         .{ 4578, 3580, "bytea_bloom_ops" },           .{ 4065, 3580, "name_minmax_ops" },           .{ 4579, 3580, "name_bloom_ops" },           .{ 4068, 3580, "oid_minmax_ops" },
    .{ 4606, 3580, "oid_minmax_multi_ops" },     .{ 4580, 3580, "oid_bloom_ops" },             .{ 4069, 3580, "tid_minmax_ops" },            .{ 4581, 3580, "tid_bloom_ops" },            .{ 4607, 3580, "tid_minmax_multi_ops" },
    .{ 4070, 3580, "float_minmax_ops" },         .{ 4608, 3580, "float_minmax_multi_ops" },    .{ 4582, 3580, "float_bloom_ops" },           .{ 4074, 3580, "macaddr_minmax_ops" },       .{ 4609, 3580, "macaddr_minmax_multi_ops" },
    .{ 4583, 3580, "macaddr_bloom_ops" },        .{ 4109, 3580, "macaddr8_minmax_ops" },       .{ 4610, 3580, "macaddr8_minmax_multi_ops" }, .{ 4584, 3580, "macaddr8_bloom_ops" },       .{ 4075, 3580, "network_minmax_ops" },
    .{ 4611, 3580, "network_minmax_multi_ops" }, .{ 4102, 3580, "network_inclusion_ops" },     .{ 4585, 3580, "network_bloom_ops" },         .{ 4076, 3580, "bpchar_minmax_ops" },        .{ 4586, 3580, "bpchar_bloom_ops" },
    .{ 4077, 3580, "time_minmax_ops" },          .{ 4612, 3580, "time_minmax_multi_ops" },     .{ 4587, 3580, "time_bloom_ops" },            .{ 4078, 3580, "interval_minmax_ops" },      .{ 4613, 3580, "interval_minmax_multi_ops" },
    .{ 4588, 3580, "interval_bloom_ops" },       .{ 4079, 3580, "bit_minmax_ops" },            .{ 4080, 3580, "varbit_minmax_ops" },         .{ 4081, 3580, "uuid_minmax_ops" },          .{ 4614, 3580, "uuid_minmax_multi_ops" },
    .{ 4589, 3580, "uuid_bloom_ops" },           .{ 4103, 3580, "range_inclusion_ops" },       .{ 4082, 3580, "pg_lsn_minmax_ops" },         .{ 4615, 3580, "pg_lsn_minmax_multi_ops" },  .{ 4590, 3580, "pg_lsn_bloom_ops" },
    .{ 4104, 3580, "box_inclusion_ops" },        .{ 5000, 4000, "box_ops" },                   .{ 5008, 4000, "poly_ops" },                  .{ 4199, 403, "multirange_ops" },            .{ 4225, 405, "multirange_ops" },
    .{ 6158, 783, "multirange_ops" },
};

/// The default btree operator class of a column of type `oid` (pg_index
/// .indclass): its type's, else text's for a string type (varchar's
/// text_ops), array_ops for an array, 0 for none.
pub fn defaultOpclass(oid: u32) u32 {
    return lookup(default_opclasses, oid) orelse 0;
}

/// A value by OID, in a table sorted by OID.
const ByOid = struct {
    oid: u32,
    v: u32,

    fn lt(_: void, x: ByOid, y: ByOid) bool {
        return x.oid < y.oid;
    }

    fn cmp(key: u32, x: ByOid) std.math.Order {
        return std.math.order(key, x.oid);
    }
};

fn lookup(table: []const ByOid, oid: u32) ?u32 {
    const i = std.sort.binarySearch(ByOid, table, oid, ByOid.cmp) orelse return null;
    return table[i].v;
}

/// `items` sorted by OID, the first of each OID kept.
fn firstByOid(comptime items: []const ByOid) []const ByOid {
    comptime {
        @setEvalBranchQuota(4_000);
        var sorted = items[0..items.len].*;
        // Stable: the first of an OID stays first.
        std.mem.sort(ByOid, &sorted, {}, ByOid.lt);
        var out: [items.len]ByOid = undefined;
        var n = 0;
        for (sorted) |x| {
            if (n > 0 and out[n - 1].oid == x.oid) continue;
            out[n] = x;
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

/// defaultOpclass() of each type that has one (its first default btree
/// class, else text_ops or array_ops by builtinType()'s category).
const default_opclasses = blk: {
    var out: []const ByOid = &.{};
    for (opclasses) |c| if (c[1] == 403 and c[5]) {
        out = out ++ .{ByOid{ .oid = c[4], .v = c[0] }};
    };
    for (type_index) |x| switch (builtin_types[x.v].cat) {
        'S' => out = out ++ .{ByOid{ .oid = x.oid, .v = 3126 }},
        'A' => out = out ++ .{ByOid{ .oid = x.oid, .v = 10000 }},
        else => {},
    };
    break :blk firstByOid(out);
};

/// Every built-in type: the base types and an array type of each that
/// has one (_int4, "integer[]").
pub const builtin_types: []const BuiltinType = blk: {
    @setEvalBranchQuota(20_000);
    var n = base_types.len;
    for (base_types) |t| {
        if (t.array != 0) n += 1;
    }
    var out: [n]BuiltinType = undefined;
    var i = 0;
    for (base_types) |t| {
        out[i] = t;
        i += 1;
    }
    for (base_types) |t| {
        if (t.array == 0) continue;
        out[i] = .{
            .oid = t.array,
            .name = "_" ++ t.name,
            .fmt = t.fmt ++ "[]",
            .len = -1,
            .byval = false,
            // record[] is a pseudo-type, as record is (cstring[] is not).
            .cat = if (t.oid == 2249) 'P' else 'A',
            .typtype = if (t.oid == 2249) 'p' else 'b',
            .@"align" = if (t.@"align" == 'd') 'd' else 'i',
            .storage = 'x',
            .io = "array_",
            .elem = t.oid,
            .coll = t.coll,
        };
        i += 1;
    }
    const final = out;
    break :blk &final;
};

pub fn builtinType(oid: u32) ?*const BuiltinType {
    return &builtin_types[lookup(type_index, oid) orelse return null];
}

/// The place in builtin_types of each OID (its first).
const type_index = blk: {
    var out: [builtin_types.len]ByOid = undefined;
    for (builtin_types, &out, 0..) |t, *o, i| o.* = .{ .oid = t.oid, .v = i };
    break :blk firstByOid(&out);
};

/// The domains of information_schema its views' columns are of, as
/// PostgreSQL 18 numbers them (format_type() writes them qualified).
pub const domain_types = [_]BuiltinType{
    .{ .oid = 13341, .name = "cardinal_number", .fmt = "information_schema.cardinal_number", .len = 4, .byval = true, .cat = 'N', .io = "int4", .typtype = 'd', .nsp = oid_information_schema, .basetype = 23 },
    .{ .oid = 13344, .name = "character_data", .fmt = "information_schema.character_data", .len = -1, .byval = false, .cat = 'S', .storage = 'x', .io = "varchar", .typtype = 'd', .nsp = oid_information_schema, .basetype = 1043, .coll = oid_c_collation },
    .{ .oid = 13346, .name = "sql_identifier", .fmt = "information_schema.sql_identifier", .len = 64, .byval = false, .cat = 'S', .@"align" = 'c', .io = "name", .typtype = 'd', .nsp = oid_information_schema, .basetype = 19, .coll = oid_c_collation },
    .{ .oid = 13352, .name = "time_stamp", .fmt = "information_schema.time_stamp", .len = 8, .byval = true, .cat = 'D', .@"align" = 'd', .io = "timestamptz_", .typtype = 'd', .nsp = oid_information_schema, .basetype = 1184, .typmod = 2 },
    .{ .oid = 13354, .name = "yes_or_no", .fmt = "information_schema.yes_or_no", .len = -1, .byval = false, .cat = 'S', .storage = 'x', .io = "varchar", .typtype = 'd', .nsp = oid_information_schema, .basetype = 1043, .typmod = 7, .coll = oid_c_collation },
};

/// A built-in type or a domain of domain_types.
pub fn typeInfo(oid: u32) ?*const BuiltinType {
    if (builtinType(oid)) |t| return t;
    for (&domain_types) |*t| if (t.oid == oid) return t;
    return null;
}

// ==================================================== system relations

const syscat = @import("syscatalog.zig");

/// PostgreSQL's system relations xqlite has (pg_class ...,
/// information_schema's views) and their indexes, with their columns and
/// constraints: PostgreSQL 18's rows (syscatalog.zig, generated). They
/// are the same for every database and in no snapshot: Snapshot's
/// lookups take them for an OID below first_user_oid (no object of a
/// database has one) or a name of pg_catalog or information_schema, and
/// their rows of pg_class and pg_attribute are made at compile time
/// (Relation.static), so a snapshot costs no more for them.
pub const system = struct {
    pub const rels: []const Rel = &syscat.rels;
    pub const attrs: []const Attr = &syscat.attrs;
    pub const indexes: []const IndexRow = &syscat.indexes;
    pub const cons: []const Con = &syscat.cons;
    pub const defs: []const Def = &.{};

    /// Places in rels, indexes and cons by OID (Snapshot.find()), and
    /// in rels by row type.
    const places = .{
        .rels = byOid(Rel, "oid", rels),
        .indexes = byOid(IndexRow, "rel", indexes),
        .cons = byOid(Con, "oid", cons),
    };
    const rowtypes = byOid(Rel, "rowtype", rels);

    fn byOid(comptime T: type, comptime field: []const u8, comptime xs: []const T) []const ByOid {
        comptime {
            @setEvalBranchQuota(100_000);
            var out: [xs.len]ByOid = undefined;
            for (xs, &out, 0..) |x, *o, i| o.* = .{ .oid = @field(x, field), .v = i };
            return firstByOid(&out);
        }
    }

    /// Each relation's rows (by its place in rels): attrs, cons and
    /// indexes are in the order of their relation.
    const ranges = blk: {
        @setEvalBranchQuota(200_000);
        var out: [rels.len]Snapshot.Ranges = @splat(.{});
        for (.{ .{ "attrs", attrs, "rel" }, .{ "cons", cons, "rel" }, .{ "indexes", indexes, "table" } }) |f| {
            var i = 0;
            while (i < f[1].len) {
                const oid = @field(f[1][i], f[2]);
                var j = i;
                while (j < f[1].len and @field(f[1][j], f[2]) == oid) j += 1;
                @field(out[lookup(places.rels, oid).?], f[0]) = .{ .lo = i, .hi = j };
                i = j;
            }
        }
        const final = out;
        break :blk final;
    };

    /// The row of OID `oid` of rels, indexes or cons (`field`).
    fn find(comptime field: []const u8, oid: u32) ?*const Elem(field) {
        return &@field(system, field)[lookup(@field(places, field), oid) orelse return null];
    }

    fn Elem(comptime field: []const u8) type {
        return std.meta.Elem(@TypeOf(@field(system, field)));
    }

    pub fn rel(oid: u32) ?*const Rel {
        return find("rels", oid);
    }

    /// The relation of row type `oid`.
    fn relByRowtype(oid: u32) ?*const Rel {
        if (oid == 0) return null;
        return &rels[lookup(rowtypes, oid) orelse return null];
    }

    /// The attribute `num` of relation `rel_oid`.
    fn attr(rel_oid: u32, num: i16) ?*const Attr {
        for (rowsOfRel("attrs", rel_oid)) |*x| if (x.num == num) return x;
        return null;
    }

    /// The rows of relation `rel_oid` of attrs, defs, cons or indexes
    /// (`field`).
    fn rowsOfRel(comptime field: []const u8, rel_oid: u32) []const Elem(field) {
        const r = @field(ranges[lookup(places.rels, rel_oid) orelse return &.{}], field);
        return @field(system, field)[r.lo..r.hi];
    }

    /// The relation `name` of schema `nsp` (rels are ordered by schema
    /// and name).
    pub fn relByName(nsp: u32, name: []const u8) ?*const Rel {
        const Key = struct { u32, []const u8 };
        const i = std.sort.binarySearch(Rel, rels, Key{ nsp, name }, struct {
            fn cmp(k: Key, r: Rel) std.math.Order {
                if (k[0] != r.nsp) return std.math.order(k[0], r.nsp);
                return std.mem.order(u8, k[1], r.name);
            }
        }.cmp) orelse return null;
        return &rels[i];
    }

    /// Whether a schema has only system relations.
    pub fn isSchema(nsp: u32) bool {
        return nsp == oid_pg_catalog or nsp == oid_information_schema;
    }
};

/// The type of a column declared `decl` in `d`: its OID and modifier.
/// The type OID and the type of a PostgreSQL declared type `decl` (an
/// empty one: text's, of no type).
pub fn columnTypeOf(decl: []const u8) struct { u32, ?ctypes.Type } {
    if (decl.len == 0) return .{ columnType(.sqlite, "")[0], null };
    return .{ columnType(.postgres, decl)[0], ctypes.parse(.postgres, decl) };
}

pub fn columnType(d: dialect.Dialect, decl: []const u8) struct { u32, i32 } {
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, decl.len)], decl[0..@min(buf.len, decl.len)]);
    const trimmed = std.mem.trim(u8, lower, " ");
    // The names no types.Logical stands for.
    const named = [_]struct { []const u8, u32 }{
        .{ "oid", 26 },        .{ "name", 19 },      .{ "\"char\"", 18 },     .{ "regclass", 2205 },  .{ "regtype", 2206 },
        .{ "regproc", 24 },    .{ "xid", 28 },       .{ "inet", 869 },        .{ "money", 790 },      .{ "jsonpath", 4072 },
        .{ "name[]", 1003 },   .{ "oid[]", 1028 },   .{ "\"char\"[]", 1002 }, .{ "regtype[]", 2211 }, .{ "regclass[]", 2210 },
        .{ "int2vector", 22 }, .{ "oidvector", 30 }, .{ "aclitem[]", 1034 },
    };
    if (d == .postgres) for (named) |n| if (eql(n[0], trimmed)) return .{ n[1], -1 };
    const t = ctypes.parse(d, decl);
    // numeric(p, s) of any p and s (Type's are bytes): PostgreSQL's
    // modifier, the scale in 11 bits.
    if (d == .postgres and t.logical == .numeric) if (@import("repr.zig").numeric.typmodOf(decl)) |m| {
        return .{ pg_types.ofType(t), ((m[0] << 16) | (m[1] & 0x7ff)) + 4 };
    };
    // interval year to month, interval(2): INTERVAL_TYPMOD().
    if (d == .postgres and t.logical == .interval) return .{ pg_types.ofType(t), @import("ivinput.zig").typmodOfDecl(decl) };
    return .{ pg_types.ofType(t), pg_types.typeMod(t) };
}

// ================================================================= OIDs

/// An object's number: five digits past first_user_oid, as PostgreSQL
/// gives the first objects of a database (a client lines up its columns
/// alike); a key whose number a smaller key of its catalog has takes
/// one of the numbers above them, up to 2^31.
const small_first: u32 = first_user_oid;
const small_span: u32 = 100_000 - first_user_oid;
const large_first: u32 = 100_000;
const large_span: u32 = 0x7fffffff - large_first;

/// The number of `key` in catalog `cat` before collisions, in
/// [first, first + span).
fn hashOid(cat: u8, key: []const u8, first: u32, span: u32) u32 {
    var h = std.hash.Wyhash.init(cat);
    h.update(key);
    return @intCast(first + h.final() % span);
}

/// The OIDs of `keys` in catalog `cat` (see the top of the file). Each
/// key has its five-digit number, but where keys share one: the
/// smallest keeps it (the first of equal keys) and the others take
/// theirs in the large span in the order of their keys (on a collision
/// there as well, the next free number), so only they depend on other
/// keys.
fn assign(a: Allocator, cat: u8, keys: []const []const u8) Oom![]u32 {
    const out = try a.alloc(u32, keys.len);
    // A number taken: the key holding it.
    var used: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try used.ensureTotalCapacity(a, @intCast(keys.len));
    var moved: std.ArrayList(u32) = .empty;
    for (keys, out, 0..) |k, *o, i| {
        o.* = hashOid(cat, k, small_first, small_span);
        const e = used.getOrPutAssumeCapacity(o.*);
        if (!e.found_existing) {
            e.value_ptr.* = @intCast(i);
        } else if (std.mem.lessThan(u8, k, keys[e.value_ptr.*])) {
            try moved.append(a, e.value_ptr.*);
            e.value_ptr.* = @intCast(i);
        } else try moved.append(a, @intCast(i));
    }
    if (moved.items.len == 0) return out;
    std.mem.sort(u32, moved.items, keys, struct {
        fn lt(k: []const []const u8, x: u32, y: u32) bool {
            return switch (std.mem.order(u8, k[x], k[y])) {
                .lt => true,
                .gt => false,
                .eq => x < y,
            };
        }
    }.lt);
    try used.ensureUnusedCapacity(a, @intCast(moved.items.len));
    for (moved.items) |i| {
        var o = hashOid(cat, keys[i], large_first, large_span);
        while (used.contains(o)) o = if (o == large_first + large_span - 1) large_first else o + 1;
        used.putAssumeCapacity(o, i);
        out[i] = o;
    }
    return out;
}

// ============================================================= snapshot

pub const Nsp = struct {
    oid: u32,
    name: []const u8,
    owner: u32 = oid_superuser,
    /// The SQLite database of its objects; null for the built-in ones
    /// without any (pg_catalog, information_schema, pg_toast).
    db: ?[]const u8 = null,
    /// A CREATE SCHEMA schema: its objects are main's "<name>.<object>".
    mangled: bool = false,
};

pub const Seq = struct {
    start: i64,
    increment: i64,
    min: i64,
    max: i64,
    cycle: bool,
    last: i64,
    is_called: bool,
};

pub const Rel = struct {
    oid: u32,
    /// PostgreSQL's name (without the schema).
    name: []const u8,
    nsp: u32,
    /// 'r' table, 'v' view, 'i' index, 'S' sequence.
    kind: u8,
    /// The database and the name there ("" for the index of an INTEGER
    /// PRIMARY KEY, which SQLite has not).
    db: []const u8,
    sqlite_name: []const u8,
    persistence: u8 = 'p',
    rowtype: u32 = 0,
    /// The array type of the row type (0: none of its own).
    rowarray: u32 = 0,
    natts: i16 = 0,
    checks: i16 = 0,
    has_index: bool = false,
    has_triggers: bool = false,
    /// A system relation's (system): relisshared, relacl.
    shared: bool = false,
    acl: ?[]const u8 = null,
    /// A view's SQLite text (CREATE VIEW ... AS <query>).
    sql: ?[]const u8 = null,
    seq: ?Seq = null,
};

pub const Attr = struct {
    rel: u32,
    name: []const u8,
    num: i16,
    type_oid: u32,
    typmod: i32 = -1,
    notnull: bool = false,
    hasdef: bool = false,
    identity: u8 = 0,
    generated: u8 = 0,
    collation: u32 = 0,
};

pub const IndexRow = struct {
    rel: u32,
    table: u32,
    unique: bool,
    primary: bool,
    /// The attribute numbers of the table, 0 for an expression.
    keys: []const i16,
    desc: []const bool,
    /// Each column's definition, as pg_get_indexdef(oid, n) gives it
    /// (and pretty).
    coldefs: []const []const u8,
    coldefs_pretty: ?[]const []const u8 = null,
    /// The expressions (indexprs), as text.
    exprs: ?[]const u8 = null,
    /// The predicate (indpred): its Expr in Snapshot.exprs.
    pred: ?u32 = null,
};

/// An expression of the schema (a DEFAULT, a generated column's, a
/// CHECK, an index's predicate) whose PostgreSQL text is made when it is
/// first read (Snapshot.expr()): most catalog queries read none of it,
/// and the snapshot is made again after each write.
pub const Expr = struct {
    /// Its SQLite text.
    src: []const u8,
    kind: Kind,
    /// The table it is over: its SQLite name and its columns in
    /// Snapshot.attrs.
    table: []const u8,
    attrs: u32,
    natts: u32,
    /// A default's or generated column's: the column's type.
    type_oid: u32 = 0,
    col_type: ?ctypes.Type = null,

    done: bool = false,
    /// conbin, adbin or indpred (deparse.zig's, else the older text),
    /// and pretty (null where deparse.zig has none).
    bin: []const u8 = "",
    pretty: ?[]const u8 = null,
    /// A CHECK's conkey, and its text (null for none).
    keys: []const i16 = &.{},
    keys_text: ?[]const u8 = null,

    pub const Kind = enum { default, generated, check, pred };
};

pub const Con = struct {
    oid: u32,
    name: []const u8,
    nsp: u32,
    /// 'p', 'u', 'f', 'c', 'n' (NOT NULL, a constraint since PostgreSQL 18).
    type: u8,
    rel: u32,
    index: u32 = 0,
    frel: u32 = 0,
    keys: []const i16 = &.{},
    fkeys: []const i16 = &.{},
    upd: u8 = ' ',
    del: u8 = ' ',
    deferrable: bool = false,
    deferred: bool = false,
    /// A CHECK's expression (conbin, its conkey): its Expr in
    /// Snapshot.exprs.
    check: ?u32 = null,
};

/// pg_attrdef's row; `expr`: its Expr in Snapshot.exprs (adbin).
pub const Def = struct { oid: u32, rel: u32, num: i16, expr: u32 };

/// The catalog key of a comment of COMMENT ON (session.zig), on the
/// table's entry or the column's.
pub const comment_key = "pg.comment";

/// pg_description's row: a comment on a relation (subid 0) or a column.
pub const Desc = struct { obj: u32, subid: i32, text: []const u8 };

/// pg_depend's row of a sequence an identity or serial column owns.
pub const Dep = struct { seq: u32, rel: u32, num: i16, type: u8 };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    refs: u32 = 1,
    /// What the snapshot was read from: each database's schema and its
    /// cookie and generation, and n_total_change.
    key: []const usize = &.{},
    nsps: []Nsp = &.{},
    rels: []Rel = &.{},
    attrs: []Attr = &.{},
    indexes: []IndexRow = &.{},
    cons: []Con = &.{},
    defs: []Def = &.{},
    deps: []Dep = &.{},
    descs: []Desc = &.{},
    /// The expressions of defs, cons and indexes, made on first reading.
    exprs: []Expr = &.{},
    /// The CREATE SCHEMA schemas (pgText()).
    registered: []const nsp_mod.Info = &.{},
    /// The places in rels, cons and indexes by OID (find()), and in rels
    /// by row type.
    places: struct { rels: OidMap = .empty, cons: OidMap = .empty, indexes: OidMap = .empty } = .{},
    rowtypes: OidMap = .empty,
    /// The places of a relation's rows (attrs, defs, cons, its indexes),
    /// which are next to each other (each table is described at once).
    ranges: std.AutoHashMapUnmanaged(u32, Ranges) = .empty,
    by_name: std.HashMapUnmanaged(NameKey, u32, NameKey.HashCtx, std.hash_map.default_max_load_percentage) = .empty,
    /// The tables, views and sequences by database and SQLite name
    /// (tableRel()).
    by_sqlite: std.HashMapUnmanaged(SqliteKey, u32, SqliteKey.HashCtx, std.hash_map.default_max_load_percentage) = .empty,
    /// What is made when first read, which a reader of a const snapshot
    /// changes: the snapshot is the connection's (no other thread reads
    /// it), and what is made is kept for every later reader.
    lazy: *Lazy,

    pub const Lazy = struct {
        /// The texts of Snapshot.exprs: the snapshot's arena.
        texts: Allocator,
        /// The rows of each relation read (rowsOf()), by its fill
        /// function, while a statement holds the snapshot: release()
        /// frees them when only the connection's cache does.
        rows: std.heap.ArenaAllocator,
        filled: std.AutoHashMapUnmanaged(usize, []const Cell) = .empty,

        fn idle(l: *Lazy) void {
            l.filled = .empty;
            _ = l.rows.reset(.free_all);
        }
    };

    pub const Range = struct {
        lo: u32 = 0,
        hi: u32 = 0,

        fn of(r: Range, comptime T: type, xs: []T) []T {
            return xs[r.lo..r.hi];
        }
    };

    const OidMap = std.AutoHashMapUnmanaged(u32, u32);

    pub const Ranges = struct { attrs: Range = .{}, defs: Range = .{}, cons: Range = .{}, indexes: Range = .{} };

    /// The key of by_sqlite: a SQLite name is told apart without its
    /// case (int.NoCaseContext).
    pub const SqliteKey = struct {
        /// 'T' a table or view, 'S' a sequence.
        kind: u8,
        db: []const u8,
        name: []const u8,

        pub const HashCtx = struct {
            pub fn hash(_: HashCtx, k: SqliteKey) u64 {
                var h = std.hash.Wyhash.init(int.NoCaseContext.hash(.{}, k.name));
                h.update(&.{k.kind});
                h.update(k.db);
                return h.final();
            }

            pub fn eql(_: HashCtx, x: SqliteKey, y: SqliteKey) bool {
                return x.kind == y.kind and std.mem.eql(u8, x.db, y.db) and int.NoCaseContext.eql(.{}, x.name, y.name);
            }
        };
    };

    pub const NameKey = struct {
        nsp: u32,
        name: []const u8,

        pub const HashCtx = struct {
            pub fn hash(_: HashCtx, k: NameKey) u64 {
                var h = std.hash.Wyhash.init(k.nsp);
                h.update(k.name);
                return h.final();
            }

            pub fn eql(_: HashCtx, x: NameKey, y: NameKey) bool {
                return x.nsp == y.nsp and std.mem.eql(u8, x.name, y.name);
            }
        };
    };

    /// The row of OID `oid` of rels, cons or indexes (`field`): a
    /// system relation's below first_user_oid (system), else the
    /// snapshot's.
    fn find(s: *const Snapshot, comptime field: []const u8, oid: u32) ?*const system.Elem(field) {
        if (oid < first_user_oid) return system.find(field, oid);
        return &@field(s, field)[@field(s.places, field).get(oid) orelse return null];
    }

    pub fn rel(s: *const Snapshot, oid: u32) ?*const Rel {
        return s.find("rels", oid);
    }

    /// The relation of row type `oid` (pg_type's row of a relation).
    pub fn relByRowtype(s: *const Snapshot, oid: u32) ?*const Rel {
        if (oid < first_user_oid) return system.relByRowtype(oid);
        return &s.rels[s.rowtypes.get(oid) orelse return null];
    }

    pub fn nsp(s: *const Snapshot, oid: u32) ?*const Nsp {
        for (s.nsps) |*n| if (n.oid == oid) return n;
        return null;
    }

    pub fn nspByName(s: *const Snapshot, name: []const u8) ?*const Nsp {
        for (s.nsps) |*n| if (eql(n.name, name)) return n;
        return null;
    }

    /// The table or view of SQLite name `name` of database `db_name`.
    pub fn tableRel(s: *const Snapshot, db_name: []const u8, name: []const u8) ?*const Rel {
        return &s.rels[s.by_sqlite.get(.{ .kind = 'T', .db = db_name, .name = name }) orelse return null];
    }

    pub fn relByName(s: *const Snapshot, nsp_oid: u32, name: []const u8) ?*const Rel {
        if (system.isSchema(nsp_oid)) return system.relByName(nsp_oid, name);
        const i = s.by_name.get(.{ .nsp = nsp_oid, .name = name }) orelse return null;
        return &s.rels[i];
    }

    pub fn con(s: *const Snapshot, oid: u32) ?*const Con {
        return s.find("cons", oid);
    }

    pub fn index(s: *const Snapshot, oid: u32) ?*const IndexRow {
        return s.find("indexes", oid);
    }

    fn rangesOf(s: *const Snapshot, rel_oid: u32) Ranges {
        return s.ranges.get(rel_oid) orelse .{};
    }

    /// The rows of relation `rel_oid` of attrs, defs, cons or indexes
    /// (`field`): a system relation's (system), else the snapshot's.
    fn rowsOfRel(s: *const Snapshot, comptime field: []const u8, rel_oid: u32) []const system.Elem(field) {
        if (rel_oid < first_user_oid) return system.rowsOfRel(field, rel_oid);
        const r = @field(s.rangesOf(rel_oid), field);
        return @field(s, field)[r.lo..r.hi];
    }

    /// The attributes of relation `rel_oid`, in their order.
    pub fn attrsOf(s: *const Snapshot, rel_oid: u32) []const Attr {
        return s.rowsOfRel("attrs", rel_oid);
    }

    /// The columns of relation `rel_oid` (its attributes of attnum > 0,
    /// which come first).
    pub fn columnsOf(s: *const Snapshot, rel_oid: u32) []const Attr {
        const all = s.attrsOf(rel_oid);
        var j: usize = 0;
        while (j < all.len and all[j].num > 0) j += 1;
        return all[0..j];
    }

    /// The defaults, constraints and indexes of table `rel_oid`.
    pub fn defsOf(s: *const Snapshot, rel_oid: u32) []const Def {
        return s.rowsOfRel("defs", rel_oid);
    }

    pub fn consOf(s: *const Snapshot, rel_oid: u32) []const Con {
        return s.rowsOfRel("cons", rel_oid);
    }

    pub fn indexesOf(s: *const Snapshot, rel_oid: u32) []const IndexRow {
        return s.rowsOfRel("indexes", rel_oid);
    }

    /// The attribute `num` of relation `rel`.
    pub fn attr(s: *const Snapshot, rel_oid: u32, num: i16) ?*const Attr {
        for (s.attrsOf(rel_oid)) |*x| if (x.num == num) return x;
        return null;
    }

    pub fn def(s: *const Snapshot, rel_oid: u32, num: i16) ?*const Def {
        for (s.defsOf(rel_oid)) |*x| if (x.num == num) return x;
        return null;
    }

    /// Expression `i`, its texts made if they are not yet (kept in it).
    pub fn expr(s: *const Snapshot, i: u32) Oom!*const Expr {
        const e = &s.exprs[i];
        if (!e.done) {
            try s.deparseExpr(e);
            e.done = true;
        }
        return e;
    }

    fn deparseExpr(s: *const Snapshot, e: *Expr) Oom!void {
        const a = s.lazy.texts;
        const own: deparse.Scope = .{ .items = &.{.{ .name = e.table, .attrs = s.attrs[e.attrs..][0..e.natts] }} };
        var as = own;
        as.as_type = e.type_oid;
        switch (e.kind) {
            .generated => {
                const t = try deparse.both(a, e.src, as);
                e.bin = t.plain orelse try pgText(a, e.src, s.registered);
                e.pretty = t.pretty;
            },
            .default => {
                const t = try defaultTexts(a, e.src, e.type_oid, s.registered, e.col_type, as);
                e.bin = t.plain;
                e.pretty = t.pretty;
            },
            .check => {
                const c = try deparse.check(a, e.src, own);
                e.keys = c.keys;
                if (c.keys.len > 0) {
                    var r: Rows = .{ .a = a, .ncol = 0 };
                    e.keys_text = try vector(&r, c.keys, true);
                }
                e.bin = c.texts.plain orelse try pgText(a, e.src, s.registered);
                e.pretty = if (c.texts.plain != null) c.texts.pretty else null;
            },
            .pred => {
                const t = try deparse.both(a, e.src, own);
                e.bin = t.plain orelse try pgText(a, stripParens(e.src), s.registered);
                e.pretty = t.pretty;
            },
        }
    }

    /// The rows of relation `r`, made once (a nested loop scans the
    /// relation again for each row of the outer one).
    pub fn rowsOf(s: *const Snapshot, comptime r: Relation) Oom![]const Cell {
        const l = s.lazy;
        const key = @intFromPtr(r.fill);
        if (l.filled.get(key)) |cells| return cells;
        var rows: Rows = .{ .a = l.rows.allocator(), .ncol = r.cols.len };
        try r.fill(s, &rows);
        try l.filled.put(l.rows.allocator(), key, rows.cells.items);
        return rows.cells.items;
    }

    /// The text of CHECK `c` (conbin), null for another constraint.
    pub fn checkText(s: *const Snapshot, c: *const Con) Oom!?*const Expr {
        return try s.expr(c.check orelse return null);
    }

    /// The temporary schema, if there is one.
    pub fn tempNsp(s: *const Snapshot) ?*const Nsp {
        for (s.nsps) |*n| if (n.db) |d| if (eql(d, "temp")) return n;
        return null;
    }
};

pub const Error = Oom || error{Failed};

/// Ends a use of `s` (acquire()). When only the connection's cache
/// (State.catalog) is left holding it, the rows read for the statements
/// are freed: the cache keeps the snapshot, not what was read of it.
pub fn release(db: *Sqlite3, s: *Snapshot) void {
    if (s.refs == 2 and db.xq.postgres.catalog == @as(?*anyopaque, s)) s.lazy.idle();
    releaseGpa(db.gpa, s);
}

fn releaseGpa(gpa: Allocator, s: *Snapshot) void {
    s.refs -= 1;
    if (s.refs == 0) {
        s.lazy.rows.deinit();
        s.arena.deinit();
        gpa.destroy(s);
    }
}

/// What a snapshot is read from (Snapshot.key), each item given to
/// `sink.put()`: n_total_change, then each database's schema, its cookie
/// and generation, and whether it is loaded.
fn writeKey(db: *Sqlite3, sink: anytype) void {
    sink.put(@bitCast(@as(isize, @intCast(db.n_total_change))));
    for (db.dbs.items) |d| {
        sink.put(@intFromPtr(d.schema));
        sink.put(@as(u32, @bitCast(d.schema.schema_cookie)));
        sink.put(@as(u32, @bitCast(d.schema.i_generation)));
        sink.put(@intFromBool(d.schema.schema_flags.SchemaLoaded));
    }
}

fn keyLen(db: *Sqlite3) usize {
    return 1 + 4 * db.dbs.items.len;
}

fn keyOf(db: *Sqlite3, a: Allocator) Oom![]usize {
    var w: struct {
        k: []usize,
        i: usize = 0,
        fn put(x: *@This(), v: usize) void {
            x.k[x.i] = v;
            x.i += 1;
        }
    } = .{ .k = try a.alloc(usize, keyLen(db)) };
    writeKey(db, &w);
    return w.k;
}

/// Whether keyOf() would give `key` (without making it).
fn sameKey(db: *Sqlite3, key: []const usize) bool {
    if (key.len != keyLen(db)) return false;
    var c: struct {
        k: []const usize,
        i: usize = 0,
        same: bool = true,
        fn put(x: *@This(), v: usize) void {
            x.same = x.same and x.k[x.i] == v;
            x.i += 1;
        }
    } = .{ .k = key };
    writeKey(db, &c);
    return c.same;
}

/// The schema of each database read, if it is not (what a snapshot is
/// made from).
fn loadSchema(db: *Sqlite3) Error!void {
    var err: ?[:0]u8 = null;
    const rc = prepare.init(db, &err);
    if (err) |m| db.gpa.free(m);
    if (rc == int.RC.NOMEM) return error.OutOfMemory;
    if (rc != int.RC.OK) return error.Failed;
}

/// The snapshot the connection keeps, if nothing changed since it was
/// made (after loadSchema()).
fn currentSnapshot(db: *Sqlite3) ?*Snapshot {
    const c: *Snapshot = @ptrCast(@alignCast(db.xq.postgres.catalog orelse return null));
    return if (sameKey(db, c.key)) c else null;
}

/// The snapshot of the connection's catalogs: the one kept if nothing
/// changed since, else a new one (kept in its place). release() it.
pub fn acquire(db: *Sqlite3) Error!*Snapshot {
    try loadSchema(db);
    return acquireLoaded(db);
}

fn acquireLoaded(db: *Sqlite3) Error!*Snapshot {
    if (currentSnapshot(db)) |c| {
        c.refs += 1;
        return c;
    }
    const st = &db.xq.postgres;
    if (st.catalog) |p| {
        st.catalog = null;
        release(db, @ptrCast(@alignCast(p)));
    }
    const s = try db.gpa.create(Snapshot);
    s.* = .{ .arena = .init(db.gpa), .lazy = undefined };
    errdefer {
        s.arena.deinit();
        db.gpa.destroy(s);
    }
    s.lazy = try s.arena.allocator().create(Snapshot.Lazy);
    s.lazy.* = .{ .texts = s.arena.allocator(), .rows = .init(db.gpa) };
    errdefer s.lazy.rows.deinit();
    var b: Builder = .{ .db = db, .a = s.arena.allocator(), .s = s };
    try b.run();
    // Reading may have read a schema again: the key is the one after.
    s.key = try keyOf(db, s.arena.allocator());
    s.refs = 2;
    st.catalog = s;
    st.catalog_free = &freeCache;
    return s;
}

fn freeCache(gpa: Allocator, p: *anyopaque) void {
    releaseGpa(gpa, @ptrCast(@alignCast(p)));
}

/// The place of each run of `items` of one `field` (a relation's OID),
/// by that value: the first, if a value had several (the builder adds
/// a relation's rows at once).
fn runs(a: Allocator, map: *std.AutoHashMapUnmanaged(u32, Snapshot.Range), comptime T: type, items: []const T, comptime field: []const u8) Oom!void {
    var i: usize = 0;
    while (i < items.len) {
        const k = @field(items[i], field);
        var j = i + 1;
        while (j < items.len and @field(items[j], field) == k) j += 1;
        const e = try map.getOrPut(a, k);
        if (!e.found_existing) e.value_ptr.* = .{ .lo = @intCast(i), .hi = @intCast(j) };
        i = j;
    }
}

// ============================================================= building

/// The relations a view's query reads, while building (deparse.zig's
/// viewSources()).
const ViewScope = struct {
    s: *const Snapshot,
    db: []const u8,

    fn resolve(c: ViewScope, name: []const u8) Oom!?deparse.Resolved {
        const r = c.s.tableRel(c.db, name) orelse return null;
        return .{ .shown = "", .attrs = c.s.attrsOf(r.oid) };
    }
};

const Builder = struct {
    db: *Sqlite3,
    a: Allocator,
    s: *Snapshot,
    nsps: std.ArrayList(Nsp) = .empty,
    rels: std.ArrayList(Rel) = .empty,
    rel_keys: std.ArrayList([]const u8) = .empty,
    attrs: std.ArrayList(Attr) = .empty,
    indexes: std.ArrayList(IndexRow) = .empty,
    cons: std.ArrayList(Con) = .empty,
    con_keys: std.ArrayList([]const u8) = .empty,
    defs: std.ArrayList(Def) = .empty,
    def_keys: std.ArrayList([]const u8) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    descs: std.ArrayList(Desc) = .empty,
    exprs: std.ArrayList(Expr) = .empty,
    /// The tables to describe once every relation has its OID.
    tables: std.ArrayList(TableWork) = .empty,
    registered: []const nsp_mod.Info = &.{},

    /// A table or view, by its place in rels.
    const TableWork = struct {
        rel: usize,
        db: []const u8,
        /// The index of the INTEGER PRIMARY KEY, if any.
        ipk: ?usize = null,
        /// The indexes of the table, by SQLite name, to their Rel.
        indexes: []struct { name: []const u8, rel: usize } = &.{},
    };

    fn run(b: *Builder) Error!void {
        const a = b.a;
        b.registered = nsp_mod.list(b.db, a) catch |e| return mapErr(e);
        try b.nsps.appendSlice(a, &.{
            .{ .oid = oid_pg_catalog, .name = "pg_catalog" },
            .{ .oid = oid_pg_toast, .name = "pg_toast" },
            .{ .oid = oid_public, .name = "public", .db = "main" },
            .{ .oid = oid_information_schema, .name = "information_schema" },
        });
        var nsp_keys: std.ArrayList([]const u8) = .empty;
        var extra: std.ArrayList(Nsp) = .empty;
        for (b.registered) |r| {
            try extra.append(a, .{ .oid = 0, .name = r.name, .db = "main", .mangled = true });
            try nsp_keys.append(a, try std.fmt.allocPrint(a, "s\x00{s}", .{r.name}));
        }
        for (b.db.dbs.items, 0..) |d, i| {
            if (i == 0) continue;
            if (i == 1) {
                var any = false;
                var it = d.schema.tbl_hash.valueIterator();
                while (it.next()) |t| any = any or userName(t.*.name);
                if (!any) continue;
                try extra.append(a, .{ .oid = 0, .name = "pg_temp_1", .db = "temp" });
            } else {
                try extra.append(a, .{ .oid = 0, .name = try a.dupe(u8, d.name), .db = try a.dupe(u8, d.name) });
            }
            try nsp_keys.append(a, try std.fmt.allocPrint(a, "d\x00{s}", .{d.name}));
        }
        const noids = try assign(a, 'n', nsp_keys.items);
        for (extra.items, noids) |*n, o| n.oid = o;
        try b.nsps.appendSlice(a, extra.items);

        for (b.db.dbs.items, 0..) |d, i| {
            const n: ?*const Nsp = if (i == 0) &b.nsps.items[2] else for (b.nsps.items) |*x| {
                if (x.db) |z| if (eql(z, if (i == 1) "temp" else d.name) and !x.mangled) break x;
            } else null;
            if (n == null) continue;
            try b.database(i);
        }
        try b.sequences();

        const roids = try assign(a, 'r', b.rel_keys.items);
        for (b.rels.items, roids) |*r, o| r.oid = o;
        // The row type of each relation, then its array (`[]` after
        // its key), numbered together. An index has none, nor has a
        // sequence (PostgreSQL's reltype 0).
        var type_keys: std.ArrayList([]const u8) = .empty;
        var typed: std.ArrayList(usize) = .empty;
        for (b.rels.items, 0..) |r, i| {
            if (r.kind == 'i' or r.kind == 'S') continue;
            try type_keys.append(a, b.rel_keys.items[i]);
            try typed.append(a, i);
        }
        const n_typed = typed.items.len;
        for (typed.items) |i| try type_keys.append(a, try std.mem.concat(a, u8, &.{ b.rel_keys.items[i], "[]" }));
        const toids = try assign(a, 't', type_keys.items);
        for (typed.items, toids[0..n_typed], toids[n_typed..]) |i, o, ao| {
            b.rels.items[i].rowtype = o;
            b.rels.items[i].rowarray = ao;
        }
        try b.sortRels();

        const s = b.s;
        s.nsps = b.nsps.items;
        s.rels = b.rels.items;
        s.registered = b.registered;
        const nrel: u32 = @intCast(s.rels.len);
        try s.places.rels.ensureTotalCapacity(a, nrel);
        try s.rowtypes.ensureTotalCapacity(a, nrel);
        try s.by_name.ensureTotalCapacity(a, nrel);
        try s.by_sqlite.ensureTotalCapacity(a, nrel);
        for (s.rels, 0..) |r, i| {
            s.places.rels.putAssumeCapacity(r.oid, @intCast(i));
            if (r.rowtype != 0) s.rowtypes.putAssumeCapacity(r.rowtype, @intCast(i));
            const e = s.by_name.getOrPutAssumeCapacity(.{ .nsp = r.nsp, .name = r.name });
            if (!e.found_existing) e.value_ptr.* = @intCast(i);
            const kind: u8 = switch (r.kind) {
                'r', 'v' => 'T',
                'S' => 'S',
                else => continue,
            };
            const t = s.by_sqlite.getOrPutAssumeCapacity(.{ .kind = kind, .db = r.db, .name = r.sqlite_name });
            if (!t.found_existing) t.value_ptr.* = @intCast(i);
        }

        for (b.tables.items) |w| try b.describe(w);
        s.attrs = b.attrs.items;
        s.indexes = b.indexes.items;
        s.cons = b.cons.items;
        s.defs = b.defs.items;
        s.deps = b.deps.items;
        s.descs = b.descs.items;
        s.exprs = b.exprs.items;
        // Each table's rows, to look them up by it.
        try s.ranges.ensureTotalCapacity(a, nrel);
        var r: std.AutoHashMapUnmanaged(u32, Snapshot.Range) = .empty;
        inline for (.{ .{ "attrs", Attr, "rel" }, .{ "defs", Def, "rel" }, .{ "cons", Con, "rel" }, .{ "indexes", IndexRow, "table" } }) |f| {
            r.clearRetainingCapacity();
            try runs(a, &r, f[1], @field(s, f[0]), f[2]);
            var it = r.iterator();
            while (it.next()) |e| {
                const g = try s.ranges.getOrPut(a, e.key_ptr.*);
                if (!g.found_existing) g.value_ptr.* = .{};
                @field(g.value_ptr.*, f[0]) = e.value_ptr.*;
            }
        }

        // A foreign key's conindid: the referenced table's unique index
        // of its columns (the first).
        var unique: std.StringHashMapUnmanaged(u32) = .empty;
        for (b.cons.items) |k| if (k.type == 'p' or k.type == 'u') {
            const e = try unique.getOrPut(a, try keysKey(a, k.rel, k.keys));
            if (!e.found_existing) e.value_ptr.* = k.index;
        };
        for (b.cons.items) |*f| if (f.type == 'f') {
            if (unique.get(try keysKey(a, f.frel, f.fkeys))) |x| f.index = x;
        };
        // A view's column that is a table's column has its type (the
        // core's type of it is its storage's: bigint, text, bytea).
        for (s.rels) |v| if (v.kind == 'v') if (v.sql) |sql| {
            const srcs = try deparse.viewSources(a, sql, ViewScope{ .s = s, .db = v.db }, ViewScope.resolve) orelse continue;
            for (s.rangesOf(v.oid).attrs.of(Attr, b.attrs.items), 0..) |*at, k| {
                if (k < srcs.len) if (srcs[k]) |src| {
                    at.type_oid = src.type_oid;
                    at.typmod = src.typmod;
                    at.collation = src.collation;
                };
            }
        };
        const coids = try assign(a, 'c', b.con_keys.items);
        for (b.cons.items, coids) |*c, o| c.oid = o;
        const doids = try assign(a, 'd', b.def_keys.items);
        for (b.defs.items, doids) |*x, o| x.oid = o;
        try s.places.cons.ensureTotalCapacity(a, @intCast(s.cons.len));
        try s.places.indexes.ensureTotalCapacity(a, @intCast(s.indexes.len));
        for (s.cons, 0..) |c, i| s.places.cons.putAssumeCapacity(c.oid, @intCast(i));
        for (s.indexes, 0..) |x, i| s.places.indexes.putAssumeCapacity(x.rel, @intCast(i));
    }

    /// The relations ordered by schema and name, as a client lists them
    /// anyway (equal ones in their order: std.mem.sort is stable), with
    /// their keys and the tables' work, which refer to them by place.
    fn sortRels(b: *Builder) Oom!void {
        const a = b.a;
        const n = b.rels.items.len;
        const order = try a.alloc(u32, n);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, @as([]const Rel, b.rels.items), struct {
            fn lt(rs: []const Rel, x: u32, y: u32) bool {
                if (rs[x].nsp != rs[y].nsp) return rs[x].nsp < rs[y].nsp;
                return std.mem.lessThan(u8, rs[x].name, rs[y].name);
            }
        }.lt);
        const rels = try a.dupe(Rel, b.rels.items);
        const keys = try a.dupe([]const u8, b.rel_keys.items);
        const moved = try a.alloc(usize, n);
        for (order, 0..) |old, new| {
            b.rels.items[new] = rels[old];
            b.rel_keys.items[new] = keys[old];
            moved[old] = new;
        }
        for (b.tables.items) |*w| {
            w.rel = moved[w.rel];
            if (w.ipk) |*x| x.* = moved[x.*];
            for (w.indexes) |*x| x.rel = moved[x.rel];
        }
    }

    /// A key of a relation and attribute numbers.
    fn keysKey(a: Allocator, rel_oid: u32, keys: []const i16) Oom![]const u8 {
        const k = try a.alloc(u8, 4 + 2 * keys.len);
        std.mem.writeInt(u32, k[0..4], rel_oid, .little);
        for (keys, 0..) |x, i| std.mem.writeInt(i16, k[4 + 2 * i ..][0..2], x, .little);
        return k;
    }

    fn mapErr(e: anyerror) Error {
        return if (e == error.OutOfMemory) error.OutOfMemory else error.Failed;
    }

    /// The schema a name of database `i` is in, and the name in it.
    fn place(b: *Builder, i: usize, name: []const u8) struct { u32, []const u8 } {
        if (i == 0) {
            if (nsp_mod.split(name)) |sp| if (nsp_mod.find(b.registered, sp.schema)) |r| {
                for (b.nsps.items) |n| if (n.mangled and std.ascii.eqlIgnoreCase(n.name, r.name)) return .{ n.oid, sp.name };
            };
            return .{ oid_public, name };
        }
        const dname = if (i == 1) "temp" else b.db.dbs.items[i].name;
        for (b.nsps.items) |n| if (n.db) |z| if (!n.mangled and eql(z, dname)) return .{ n.oid, name };
        return .{ oid_public, name };
    }

    fn userName(name: []const u8) bool {
        if (std.ascii.startsWithIgnoreCase(name, "sqlite_")) return false;
        return !eql(name, catalog.table_name) and !eql(name, catalog.sequence.table_name);
    }

    /// The relations of database `i`.
    fn database(b: *Builder, i: usize) Error!void {
        const a = b.a;
        const d = b.db.dbs.items[i];
        const dname: []const u8 = if (i == 1) "temp" else try a.dupe(u8, d.name);
        // The SQL text of each object, which the schema in memory lacks.
        var sql: std.StringHashMapUnmanaged([]const u8) = .empty;
        {
            var q = catalog.Query.initFmt(b.db, "SELECT name,sql FROM \"%w\".sqlite_schema WHERE sql IS NOT NULL", &.{.{ .str = d.name }}) catch |e| return mapErr(e);
            defer q.deinit();
            while (q.step() catch |e| return mapErr(e)) {
                const n = try a.dupe(u8, api.columnText(q.v, 0) orelse "");
                try sql.put(a, n, try a.dupe(u8, api.columnText(q.v, 1) orelse ""));
            }
        }
        var it = d.schema.tbl_hash.valueIterator();
        var tabs: std.ArrayList(*int.Table) = .empty;
        while (it.next()) |tp| {
            const t = tp.*;
            if (!userName(t.name) or t.isVirtual()) continue;
            try tabs.append(a, t);
        }
        for (tabs.items) |t| {
            const where = b.place(i, t.name);
            const ri = b.rels.items.len;
            try b.rels.append(a, .{
                .oid = 0,
                .name = try a.dupe(u8, where[1]),
                .nsp = where[0],
                .kind = if (t.isView()) 'v' else 'r',
                .db = dname,
                .sqlite_name = try a.dupe(u8, t.name),
                .persistence = if (i == 1) 't' else 'p',
                .sql = if (t.isView()) sql.get(t.name) else null,
            });
            try b.rel_keys.append(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ dname, t.name }));
            var w: TableWork = .{ .rel = ri, .db = dname };
            if (t.isView()) {
                try b.tables.append(a, w);
                continue;
            }
            var idx_rels: std.ArrayList(@typeInfo(@FieldType(TableWork, "indexes")).pointer.child) = .empty;
            const m = catalog.meta(b.db, d.name, t.name) catch |e| return mapErr(e);
            const bare = where[1];
            if (t.i_pkey >= 0 and t.hasRowid()) {
                const col = t.cols[@intCast(t.i_pkey)].name();
                const pname = recorded(m, "primary_key", &.{col}) orelse try std.fmt.allocPrint(a, "{s}_pkey", .{bare});
                w.ipk = b.rels.items.len;
                try b.rels.append(a, .{ .oid = 0, .name = try a.dupe(u8, pname), .nsp = where[0], .kind = 'i', .db = dname, .sqlite_name = "", .persistence = if (i == 1) 't' else 'p' });
                try b.rel_keys.append(a, try std.fmt.allocPrint(a, "{s}\x00{s}\x00pkey", .{ dname, t.name }));
            }
            var ix = t.index;
            while (ix) |x| : (ix = x.next) {
                const pname = try b.indexName(m, t, x, bare);
                try idx_rels.append(a, .{ .name = try a.dupe(u8, x.name), .rel = b.rels.items.len });
                try b.rels.append(a, .{ .oid = 0, .name = pname, .nsp = where[0], .kind = 'i', .db = dname, .sqlite_name = try a.dupe(u8, x.name), .persistence = if (i == 1) 't' else 'p', .sql = sql.get(x.name) });
                try b.rel_keys.append(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ dname, x.name }));
            }
            w.indexes = idx_rels.items;
            b.rels.items[ri].sql = sql.get(t.name);
            b.rels.items[ri].has_index = w.ipk != null or t.index != null;
            try b.tables.append(a, w);
        }
    }

    /// PostgreSQL's name of index `x` of `t`: an index of a PRIMARY KEY or
    /// UNIQUE constraint is named after the constraint.
    fn indexName(b: *Builder, m: ?*const catalog.TableMeta, t: *int.Table, x: *int.Index, bare: []const u8) Oom![]const u8 {
        const a = b.a;
        if (x.idx_type == .appdef) {
            if (nsp_mod.split(x.name)) |sp| if (nsp_mod.find(b.registered, sp.schema) != null) return a.dupe(u8, sp.name);
            return a.dupe(u8, x.name);
        }
        var cols: std.ArrayList([]const u8) = .empty;
        for (x.ai_column[0..x.n_key_col]) |c| try cols.append(a, if (c >= 0) t.cols[@intCast(c)].name() else if (c == int.XN_ROWID) "rowid" else "expr");
        const kind = if (x.idx_type == .primarykey) "primary_key" else "unique";
        if (recorded(m, kind, cols.items)) |n| return a.dupe(u8, n);
        if (x.idx_type == .primarykey) return std.fmt.allocPrint(a, "{s}_pkey", .{bare});
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, bare);
        for (cols.items) |c| {
            try out.append(a, '_');
            try out.appendSlice(a, c);
        }
        try out.appendSlice(a, "_key");
        return out.items;
    }

    fn sequences(b: *Builder) Error!void {
        const a = b.a;
        if (!catalog.sequence.exists(b.db, "main")) return;
        var q = catalog.Query.init(b.db, "SELECT name,last_value,start_value,increment,min_value,max_value,cycle,is_called FROM main.xq_sequence") catch |e| return mapErr(e);
        defer q.deinit();
        while (q.step() catch |e| return mapErr(e)) {
            const name = try a.dupe(u8, api.columnText(q.v, 0) orelse "");
            const where = b.place(0, name);
            const v = q.v;
            try b.rels.append(a, .{
                .oid = 0,
                .name = where[1],
                .nsp = where[0],
                .kind = 'S',
                .db = "main",
                .sqlite_name = name,
                .natts = 3,
                .seq = .{
                    .last = api.columnInt64(v, 1),
                    .start = api.columnInt64(v, 2),
                    .increment = api.columnInt64(v, 3),
                    .min = api.columnInt64(v, 4),
                    .max = api.columnInt64(v, 5),
                    .cycle = api.columnInt64(v, 6) != 0,
                    .is_called = api.columnInt64(v, 7) != 0,
                },
            });
            try b.rel_keys.append(a, try std.fmt.allocPrint(a, "S\x00{s}", .{name}));
        }
    }

    /// The relation of a SQLite name, kind 'T' (a table or view) or 'S'
    /// (a sequence), once all are listed.
    fn relOf(b: *Builder, db_name: []const u8, sqlite_name: []const u8, kind: u8) ?*Rel {
        return &b.rels.items[b.s.by_sqlite.get(.{ .kind = kind, .db = db_name, .name = sqlite_name }) orelse return null];
    }

    fn tableRel(b: *Builder, db_name: []const u8, sqlite_name: []const u8) ?*Rel {
        return b.relOf(db_name, sqlite_name, 'T');
    }

    /// The attributes, indexes, constraints and defaults of a table (or
    /// the attributes of a view).
    fn describe(b: *Builder, w: TableWork) Error!void {
        const a = b.a;
        const r = &b.rels.items[w.rel];
        const t = build.findTable(b.db, r.sqlite_name, if (eql(w.db, "temp")) "temp" else w.db) orelse return;
        if (t.isView()) {
            const first = b.attrs.items.len;
            try b.viewColumns(w, r, t);
            const vm = catalog.meta(b.db, if (eql(w.db, "temp")) "temp" else w.db, t.name) catch |e| return mapErr(e);
            return b.comments(vm, r.oid, first);
        }
        const m = catalog.meta(b.db, if (eql(w.db, "temp")) "temp" else w.db, t.name) catch |e| return mapErr(e);
        const d: dialect.Dialect = if (m) |x| x.dialect else .sqlite;
        r.natts = @intCast(t.cols.len);
        const key = b.rel_keys.items[w.rel];
        var checks = try tableChecks(a, r.sql orelse "", r.name);
        // The dialect's type checks are not constraints.
        var kept: std.ArrayList(Check) = .empty;
        for (checks) |c| if (dialect.checkState(c.name) == null) try kept.append(a, c);
        checks = kept.items;
        r.checks = @intCast(checks.len);
        const first_attr = b.attrs.items.len;
        // The generated columns' expressions (no span of the text: the
        // CREATE TABLE's), read once.
        var generated_texts: ?[]const Generated = null;
        for (t.cols, 0..) |*col, ci| {
            const num: i16 = @intCast(ci + 1);
            const cm: ?*const catalog.ColumnMeta = if (m) |x| x.column(col.name()) else null;
            const decl: []const u8 = if (cm) |c| c.decl_type orelse build.columnType(col, "") else build.columnType(col, "");
            const ty = columnType(if (cm != null and cm.?.decl_type != null) d else .sqlite, decl);
            const generated = col.col_flags.intersects(int.COLFLAG.GENERATED);
            var at: Attr = .{
                .rel = r.oid,
                .name = try a.dupe(u8, col.name()),
                .num = num,
                .type_oid = ty[0],
                .typmod = ty[1],
                .notnull = col.not_null != .None or col.col_flags.PRIMKEY,
                .generated = if (generated) 's' else 0,
                .collation = collationOf(ty[0], if (cm) |c| c.collation else build.columnColl(col)),
            };
            if (cm) |c| if (c.identity_kind) |k| {
                at.identity = if (eql(k, "always")) 'a' else 'd';
                if (c.identity) |seq| try b.ownedSequence(seq, r.oid, num, 'i');
            };
            if (cm) |c| if (c.identity != null and c.identity_kind == null) try b.ownedSequence(c.identity.?, r.oid, num, 'a');
            if (at.identity == 0) if (build.columnExpr(t, col)) |e| {
                const text = if (generated) blk: {
                    if (generated_texts == null) generated_texts = try generatedTexts(a, r.sql orelse "");
                    break :blk generatedOf(generated_texts.?, col.name());
                } else null;
                at.hasdef = true;
                // Its text is made when read, over the table's columns.
                try b.defs.append(a, .{ .oid = 0, .rel = r.oid, .num = num, .expr = @intCast(b.exprs.items.len) });
                try b.exprs.append(a, .{
                    .src = text orelse try a.dupe(u8, std.mem.sliceTo(e.token(), 0)),
                    .kind = if (generated) .generated else .default,
                    .table = r.sqlite_name,
                    .attrs = @intCast(first_attr),
                    .natts = @intCast(t.cols.len),
                    .type_oid = ty[0],
                    .col_type = if (cm) |c| c.type else null,
                });
                try b.def_keys.append(a, try std.fmt.allocPrint(a, "{s}\x00{d}", .{ key, num }));
            };
            try b.attrs.append(a, at);
            // PostgreSQL 18 makes a constraint of each NOT NULL (and of a
            // primary key's columns): <table>_<column>_not_null.
            if (at.notnull) try b.addCon(key, .{
                .oid = 0,
                .name = try std.fmt.allocPrint(a, "{s}_{s}_not_null", .{ r.name, at.name }),
                .nsp = r.nsp,
                .type = 'n',
                .rel = r.oid,
                .keys = try a.dupe(i16, &.{num}),
            });
        }
        // The CHECK constraints (PostgreSQL makes them before the keys),
        // their texts and columns made when read.
        for (checks) |c| {
            try b.addCon(key, .{
                .oid = 0,
                .name = c.name,
                .nsp = r.nsp,
                .type = 'c',
                .rel = r.oid,
                .check = @intCast(b.exprs.items.len),
            });
            try b.exprs.append(a, .{ .src = c.text, .kind = .check, .table = r.sqlite_name, .attrs = @intCast(first_attr), .natts = @intCast(t.cols.len) });
        }
        // The INTEGER PRIMARY KEY's index and constraint.
        if (w.ipk) |ii| {
            const ir = &b.rels.items[ii];
            const num: i16 = t.i_pkey + 1;
            ir.natts = 1;
            const col = try quoteIdent(a, t.cols[@intCast(t.i_pkey)].name());
            const ty = b.attrs.items[first_attr + @as(usize, @intCast(t.i_pkey))].type_oid;
            try b.attrs.append(a, .{ .rel = ir.oid, .name = try a.dupe(u8, t.cols[@intCast(t.i_pkey)].name()), .num = 1, .type_oid = ty });
            try b.indexes.append(a, .{ .rel = ir.oid, .table = r.oid, .unique = true, .primary = true, .keys = try a.dupe(i16, &.{num}), .desc = try a.dupe(bool, &.{false}), .coldefs = try a.dupe([]const u8, &.{col}) });
            try b.addCon(key, .{ .oid = 0, .name = ir.name, .nsp = r.nsp, .type = 'p', .rel = r.oid, .index = ir.oid, .keys = try a.dupe(i16, &.{num}) });
        }
        // The indexes, and the constraints of the autoindexes.
        var ix = t.index;
        while (ix) |x| : (ix = x.next) {
            const ir_i = for (w.indexes) |e| {
                if (eql(e.name, x.name)) break e.rel;
            } else continue;
            const ir = &b.rels.items[ir_i];
            const n: usize = x.n_key_col;
            ir.natts = @intCast(n);
            const items = indexItems(a, ir.sql orelse "") catch &.{};
            var keys = try a.alloc(i16, n);
            var desc = try a.alloc(bool, n);
            var coldefs = try a.alloc([]const u8, n);
            var coldefs_pretty = try a.alloc([]const u8, n);
            var exprs: std.ArrayList(u8) = .empty;
            for (0..n) |k| {
                const c = x.ai_column[k];
                desc[k] = k < x.sort_order.len and x.sort_order[k] != 0;
                var attname: []const u8 = undefined;
                var type_oid: u32 = 25;
                var typmod: i32 = -1;
                if (c >= 0) {
                    keys[k] = c + 1;
                    attname = t.cols[@intCast(c)].name();
                    coldefs[k] = try quoteIdent(a, attname);
                    coldefs_pretty[k] = coldefs[k];
                    const at = b.attrs.items[first_attr + @as(usize, @intCast(c))];
                    type_oid = at.type_oid;
                    typmod = at.typmod;
                } else if (c == int.XN_ROWID) {
                    keys[k] = 0;
                    attname = "rowid";
                    coldefs[k] = "rowid";
                    coldefs_pretty[k] = "rowid";
                    type_oid = 20;
                } else {
                    keys[k] = 0;
                    const item = if (k < items.len) items[k] else "?";
                    const src = stripParens(stripOrder(item));
                    // Its name is of its text: made now, once for its
                    // texts of both modes.
                    const tscope: deparse.Scope = .{ .items = &.{.{ .name = r.sqlite_name, .attrs = b.attrs.items[first_attr..][0..t.cols.len] }} };
                    const tx = try deparse.indexTexts(a, src, tscope);
                    // The older text where deparse.zig has none.
                    const old = if (tx.expr.plain == null or tx.column.plain == null) try pgText(a, src, b.registered) else "";
                    const e = tx.expr.plain orelse old;
                    attname = try exprName(a, e);
                    coldefs[k] = tx.column.plain orelse if (try looksLikeCall(a, old)) old else try std.fmt.allocPrint(a, "({s})", .{old});
                    coldefs_pretty[k] = tx.column.pretty orelse coldefs[k];
                    if (exprs.items.len > 0) try exprs.appendSlice(a, ", ");
                    try exprs.appendSlice(a, e);
                }
                if (desc[k]) {
                    coldefs[k] = try std.fmt.allocPrint(a, "{s} DESC", .{coldefs[k]});
                    coldefs_pretty[k] = try std.fmt.allocPrint(a, "{s} DESC", .{coldefs_pretty[k]});
                }
                try b.attrs.append(a, .{ .rel = ir.oid, .name = try a.dupe(u8, attname), .num = @intCast(k + 1), .type_oid = type_oid, .typmod = typmod });
            }
            // The predicate's text is made when read.
            var pred: ?u32 = null;
            if (if (ir.sql) |z| try whereOf(a, z) else null) |wz| {
                pred = @intCast(b.exprs.items.len);
                try b.exprs.append(a, .{ .src = wz, .kind = .pred, .table = r.sqlite_name, .attrs = @intCast(first_attr), .natts = @intCast(t.cols.len) });
            }
            try b.indexes.append(a, .{
                .rel = ir.oid,
                .table = r.oid,
                .unique = x.isUnique(),
                .primary = x.idx_type == .primarykey,
                .keys = keys,
                .desc = desc,
                .coldefs = coldefs,
                .coldefs_pretty = coldefs_pretty,
                .exprs = if (exprs.items.len > 0) exprs.items else null,
                .pred = pred,
            });
            if (x.idx_type == .primarykey or x.idx_type == .unique) {
                try b.addCon(key, .{ .oid = 0, .name = ir.name, .nsp = r.nsp, .type = if (x.idx_type == .primarykey) 'p' else 'u', .rel = r.oid, .index = ir.oid, .keys = try a.dupe(i16, keys) });
            }
        }
        // Foreign keys.
        var fk = t.u.tab.fkey;
        while (fk) |f| : (fk = f.next_from) {
            r.has_triggers = true;
            const parent = b.tableRel(w.db, f.to);
            if (parent) |p| p.has_triggers = true;
            var cols: std.ArrayList([]const u8) = .empty;
            const keys = try a.alloc(i16, f.cols.len);
            const fkeys = try a.alloc(i16, f.cols.len);
            const pt = build.findTable(b.db, f.to, if (eql(w.db, "temp")) "temp" else w.db);
            for (f.cols, 0..) |c, k| {
                keys[k] = @intCast(c.i_from + 1);
                try cols.append(a, t.cols[@intCast(c.i_from)].name());
                fkeys[k] = 0;
                if (pt) |ptab| {
                    if (c.col) |pc| {
                        for (ptab.cols, 0..) |*pcol, pi| if (std.ascii.eqlIgnoreCase(pcol.name(), pc)) {
                            fkeys[k] = @intCast(pi + 1);
                        };
                    } else if (ptab.i_pkey >= 0) {
                        fkeys[k] = ptab.i_pkey + 1;
                    } else if (build.primaryKeyIndex(ptab)) |ppk| {
                        if (k < ppk.n_key_col and ppk.ai_column[k] >= 0) fkeys[k] = ppk.ai_column[k] + 1;
                    }
                }
            }
            const name = recorded(m, "foreign_key", cols.items) orelse blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(a, r.name);
                for (cols.items) |c| {
                    try out.append(a, '_');
                    try out.appendSlice(a, c);
                }
                try out.appendSlice(a, "_fkey");
                break :blk out.items;
            };
            try b.addCon(key, .{
                .oid = 0,
                .name = try a.dupe(u8, name),
                .nsp = r.nsp,
                .type = 'f',
                .rel = r.oid,
                .frel = if (parent) |p| p.oid else 0,
                .keys = keys,
                .fkeys = fkeys,
                .upd = action(f.a_action[1]),
                .del = action(f.a_action[0]),
                .deferrable = f.is_deferred,
                .deferred = f.is_deferred,
            });
        }
        try b.comments(m, r.oid, first_attr);
    }

    /// The comments of COMMENT ON on relation `rel_oid` and its columns
    /// (its attributes from `first` of b.attrs on).
    fn comments(b: *Builder, m: ?*const catalog.TableMeta, rel_oid: u32, first: usize) Oom!void {
        const x = m orelse return;
        for (x.entries) |e| {
            if (!eql(e.key, comment_key)) continue;
            var subid: i32 = 0;
            if (e.col.len > 0) {
                subid = -1;
                for (b.attrs.items[first..]) |at| if (at.rel == rel_oid and std.ascii.eqlIgnoreCase(at.name, e.col)) {
                    subid = at.num;
                };
                if (subid < 0) continue;
            }
            try b.descs.append(b.a, .{ .obj = rel_oid, .subid = subid, .text = try b.a.dupe(u8, e.value) });
        }
    }

    fn addCon(b: *Builder, rel_key: []const u8, c: Con) Oom!void {
        try b.cons.append(b.a, c);
        try b.con_keys.append(b.a, try std.fmt.allocPrint(b.a, "{s}\x00{s}\x00{c}", .{ rel_key, c.name, c.type }));
    }

    fn ownedSequence(b: *Builder, seq: []const u8, rel_oid: u32, num: i16, kind: u8) Oom!void {
        const s = b.relOf("main", seq, 'S') orelse return;
        try b.deps.append(b.a, .{ .seq = s.oid, .rel = rel_oid, .num = num, .type = kind });
    }

    /// A view's columns, of the types its query has in this dialect.
    fn viewColumns(b: *Builder, w: TableWork, r: *Rel, t: *int.Table) Error!void {
        const a = b.a;
        _ = t;
        const sql = try std.fmt.allocPrint(a, "SELECT * FROM {s}.\"{s}\"", .{
            if (eql(w.db, "main")) "public" else if (eql(w.db, "temp")) "pg_temp" else w.db,
            try doubled(a, r.sqlite_name),
        });
        var stmt: ?*vi.Vdbe = null;
        const rc = prepare.prepareLang(b.db, sql, .of(.postgres), 0, &stmt, null);
        const v = stmt orelse {
            if (rc == int.RC.NOMEM) return error.OutOfMemory;
            return;
        };
        defer _ = api.finalize(v);
        const n = api.columnCount(v);
        r.natts = @intCast(n);
        for (0..n) |i| {
            const name = api.columnName(v, i) orelse "?column?";
            // The type the core gave the column, else its declared one.
            const decl: []const u8 = api.columnDecltype(v, i) orelse "";
            const known: ?ctypes.Type = if (i < v.xq_col_types.len and v.xq_col_types[i].logical != .unknown) v.xq_col_types[i] else null;
            const ty = if (known) |k| .{ pg_types.ofType(k), pg_types.typeMod(k) } else if (decl.len == 0) .{ pg_types.oid.text, @as(i32, -1) } else columnType(.postgres, decl);
            try b.attrs.append(a, .{ .rel = r.oid, .name = try a.dupe(u8, name), .num = @intCast(i + 1), .type_oid = ty[0], .typmod = ty[1], .collation = collationOf(ty[0], null) });
        }
    }
};

fn doubled(a: Allocator, z: []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (z) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    return out.items;
}

/// The name of a constraint CREATE TABLE recorded (dialect/constraint.zig
/// key()).
/// The columns of the PRIMARY KEY or UNIQUE constraint called `name` of
/// table `t` (`bare`: its name without a schema), as pg_constraint names
/// them: INSERT ... ON CONFLICT ON CONSTRAINT. Null if `t` has none of
/// that name (an index that is no constraint's is not one); an
/// expression's column is not given (null too).
pub fn constraintColumns(a: Allocator, db: *int.Sqlite3, t: *int.Table, bare: []const u8, name: []const u8) Oom!?[]const []const u8 {
    const m = catalog.metaOf(db, t) catch null;
    if (t.i_pkey >= 0 and t.hasRowid()) {
        const col = t.cols[@intCast(t.i_pkey)].name();
        const cols = try a.dupe([]const u8, &.{col});
        const pname = recorded(m, "primary_key", cols) orelse try std.fmt.allocPrint(a, "{s}_pkey", .{bare});
        if (std.mem.eql(u8, pname, name)) return cols;
    }
    var ix = t.index;
    while (ix) |x| : (ix = x.next) {
        if (x.idx_type != .primarykey and x.idx_type != .unique) continue;
        var cols: std.ArrayList([]const u8) = .empty;
        var expr = false;
        for (x.ai_column[0..x.n_key_col]) |c| {
            if (c >= 0) try cols.append(a, t.cols[@intCast(c)].name()) else expr = true;
        }
        const kind = if (x.idx_type == .primarykey) "primary_key" else "unique";
        const pname = recorded(m, kind, cols.items) orelse if (x.idx_type == .primarykey) try std.fmt.allocPrint(a, "{s}_pkey", .{bare}) else blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, bare);
            for (cols.items) |c| {
                try out.append(a, '_');
                try out.appendSlice(a, c);
            }
            try out.appendSlice(a, "_key");
            break :blk out.items;
        };
        if (std.mem.eql(u8, pname, name)) return if (expr) null else cols.items;
    }
    return null;
}

fn recorded(m: ?*const catalog.TableMeta, kind: []const u8, cols: []const []const u8) ?[]const u8 {
    const x = m orelse return null;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s}:{s}:", .{ catalog.Key.constraint, kind }) catch return null;
    for (cols, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return null;
        w.writeAll(c) catch return null;
    }
    const k = w.buffered();
    for (x.entries) |e| {
        if (e.col.len == 0 and std.ascii.eqlIgnoreCase(e.key, k)) return e.value;
    }
    return null;
}

fn action(oe: int.OE) u8 {
    return switch (oe) {
        .SetNull => 'n',
        .SetDflt => 'd',
        .Cascade => 'c',
        .Restrict => 'r',
        else => 'a',
    };
}

/// The collation of a column of type `type_oid`: C for COLLATE "C",
/// else the default one of a collatable type.
fn collationOf(type_oid: u32, declared: ?[]const u8) u32 {
    const t = builtinType(type_oid) orelse return 0;
    if (t.coll == 0) return 0;
    if (declared) |c| if (std.ascii.eqlIgnoreCase(c, "C") or std.ascii.eqlIgnoreCase(c, "BINARY") or std.ascii.eqlIgnoreCase(c, "POSIX")) {
        return if (t.coll == oid_c_collation) oid_c_collation else oid_c_collation;
    };
    return t.coll;
}

// ========================================================= SQLite text

/// A token of SQLite text (just enough to take a statement apart).
///
/// The text is SQLite's (sqlite_schema, or an expression the IR rendered),
/// so it is read with SQLite's rules of the sql/lexer package
/// (sqllex.sqlite: comments, quotes, words and the extent of a number),
/// which a test below checks against SQLite's tokenizer
/// (src/dialect/sqlite/lexer.zig). That tokenizer is not used: it reads
/// statements for the grammar (keywords, operators, TK_ codes), this
/// takes slices apart (an expression, a column's definition).
const Tok = struct {
    kind: enum { word, quoted, string, number, punct, eof },
    text: []const u8,
    start: usize,
    end: usize,
};

const sqllex = @import("sql/lexer");
const Sql = sqllex.Scanner(sqllex.sqlite);

pub const Scanner = struct {
    /// The text, with a NUL after it, where the scanners of sqllex stop:
    /// the slice it was made of, copied (Scanner.init()).
    z: [:0]const u8,
    i: usize = 0,

    /// A scanner of `z`, a slice of SQLite text.
    pub fn init(a: Allocator, z: []const u8) Oom!Scanner {
        return .{ .z = try a.dupeSentinel(u8, z, 0) };
    }

    pub fn next(s: *Scanner) Tok {
        const z = s.z;
        const start = Sql.skip(z, s.i).end;
        const c = z[start];
        if (c == 0) return .{ .kind = .eof, .text = "", .start = start, .end = start };
        var kind: @FieldType(Tok, "kind") = .punct;
        s.i = switch (c) {
            '\'', '"', '`' => blk: {
                kind = if (c == '\'') .string else .quoted;
                break :blk sqllex.quotedEnd(z, start, c, false).end;
            },
            // [name]: up to the first ] (no doubling).
            '[' => blk: {
                kind = .quoted;
                const e = sqllex.indexOfAnyOrNul(1, z, start + 1, .{']'});
                break :blk if (z[e] == 0) e else e + 1;
            },
            else => if (Sql.isIdentStart(c)) blk: {
                kind = .word;
                break :blk Sql.word(z, start);
            } else if (Sql.isDigit(c) or (c == '.' and Sql.isDigit(z[start + 1]))) blk: {
                kind = .number;
                break :blk numberEnd(z, start);
            } else start + 1,
        };
        return .{ .kind = kind, .text = z[start..s.i], .start = start, .end = s.i };
    }
};

/// The end of the number at `i` (a digit, or a `.` before one) as
/// sqlite3GetToken() scans it: `0x` and hex digits, else digits, a
/// fraction and an exponent; word characters after it belong to the
/// token (an illegal one to SQLite).
fn numberEnd(z: [:0]const u8, i: usize) usize {
    const end = if (Sql.radixPrefix(z, i) != null and std.ascii.isHex(z[i + 2]))
        sqllex.radixDigits(z, i + 2, 16, .any).end
    else
        Sql.number(z, i).end;
    return Sql.word(z, end);
}

/// The name a quoted or bare identifier token stands for.
fn identText(a: Allocator, t: Tok) Oom![]const u8 {
    if (t.kind != .quoted) return t.text;
    const q = t.text[0];
    const close: u8 = if (q == '[') ']' else q;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i + 1 < t.text.len) : (i += 1) {
        if (t.text[i] == close and i + 2 < t.text.len and t.text[i + 1] == close) i += 1;
        try out.append(a, t.text[i]);
    }
    return out.items;
}

/// PostgreSQL's quote_ident(): `z` bare if it is a lower-case word that
/// is no keyword, else quoted.
pub fn quoteIdent(a: Allocator, z: []const u8) Oom![]const u8 {
    if (safeIdent(z)) return a.dupe(u8, z);
    var out: std.Io.Writer.Allocating = try .initCapacity(a, z.len + 2);
    writeIdent(&out.writer, z) catch return error.OutOfMemory;
    return out.written();
}

/// quoteIdent() of `z`, written to `w`.
pub fn writeIdent(w: *std.Io.Writer, z: []const u8) std.Io.Writer.Error!void {
    if (safeIdent(z)) return w.writeAll(z);
    try w.writeByte('"');
    var start: usize = 0;
    for (z, 0..) |c, i| if (c == '"') {
        try w.writeAll(z[start .. i + 1]);
        start = i;
    };
    try w.writeAll(z[start..]);
    try w.writeByte('"');
}

fn safeIdent(z: []const u8) bool {
    if (z.len == 0) return false;
    if (!(std.ascii.isLower(z[0]) or z[0] == '_')) return false;
    for (z) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return !parser.isReserved(z);
}

/// SQLite text (an expression of the schema, as the IR rendered it) as
/// PostgreSQL would print it: identifiers quoted only where PostgreSQL
/// needs it (a name of a CREATE SCHEMA schema's object "s.t" is s.t),
/// TRUE and FALSE in lower case.
pub fn pgText(a: Allocator, z: []const u8, registered: []const nsp_mod.Info) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var s = try Scanner.init(a, z);
    var prev_end: usize = 0;
    while (true) {
        const t = s.next();
        if (t.kind == .eof) break;
        try out.appendSlice(a, z[prev_end..t.start]);
        prev_end = t.end;
        switch (t.kind) {
            .quoted => {
                const name = try identText(a, t);
                if (nsp_mod.split(name)) |sp| if (nsp_mod.find(registered, sp.schema) != null) {
                    try out.appendSlice(a, try quoteIdent(a, sp.schema));
                    try out.append(a, '.');
                    try out.appendSlice(a, try quoteIdent(a, sp.name));
                    continue;
                };
                try out.appendSlice(a, try quoteIdent(a, name));
            },
            .word => if (std.ascii.eqlIgnoreCase(t.text, "true") or std.ascii.eqlIgnoreCase(t.text, "false")) {
                for (t.text) |c| try out.append(a, std.ascii.toLower(c));
            } else try out.appendSlice(a, t.text),
            else => try out.appendSlice(a, t.text),
        }
    }
    try out.appendSlice(a, z[prev_end..]);
    return out.items;
}

/// The text of a default expression as pg_get_expr() shows it: now() for SQLite's rendering of it, a string
/// constant cast to the column's type ('x'::text), a negative integer
/// quoted ('-1'::integer), nextval()'s argument a regclass.
pub fn defaultText(a: Allocator, text: []const u8, type_oid: u32, registered: []const nsp_mod.Info, col_type: ?ctypes.Type) Oom![]const u8 {
    return (try defaultTexts(a, text, type_oid, registered, col_type, .{})).plain;
}

/// defaultText() of a column of the relation of `scope`, plain and
/// pretty (an expression's texts: deparse.zig's, its text read once).
pub const DefaultTexts = struct {
    plain: []const u8,
    pretty: []const u8,

    fn one(x: []const u8) DefaultTexts {
        return .{ .plain = x, .pretty = x };
    }
};

pub fn defaultTexts(a: Allocator, text: []const u8, type_oid: u32, registered: []const nsp_mod.Info, col_type: ?ctypes.Type, scope: deparse.Scope) Oom!DefaultTexts {
    const z = std.mem.trim(u8, text, " ");
    const one = DefaultTexts.one;
    if (col_type) |ty| if (try blobDefault(a, z, ty, type_oid)) |d| return one(d);
    // A DEFAULT stored as a function of the type's form (an interval's
    // xq_pg_iv('2 hours')): the constant.
    inline for (repr.all) |r| if (r.default_text) |f| if (try f(a, z)) |d| {
        const t = try deparse.both(a, z, scope);
        return .{ .plain = t.plain orelse d, .pretty = t.pretty orelse d };
    };
    if (eql(z, "strftime('%Y-%m-%d %H:%M:%f', 'now')") or std.ascii.eqlIgnoreCase(z, "CURRENT_TIMESTAMP")) return one("now()");
    if (eql(z, "date('now')") or std.ascii.eqlIgnoreCase(z, "CURRENT_DATE")) return one("CURRENT_DATE");
    if (std.mem.startsWith(u8, z, "nextval('") and std.mem.endsWith(u8, z, "')")) {
        return one(try std.fmt.allocPrint(a, "{s}'::regclass)", .{z[0 .. z.len - 2]}));
    }
    const tname: []const u8 = if (builtinType(type_oid)) |t| t.fmt else "text";
    if (z.len >= 2 and z[0] == '\'' and z[z.len - 1] == '\'') {
        // One string constant.
        var s = try Scanner.init(a, z);
        const t = s.next();
        if (t.end == z.len) return one(try std.fmt.allocPrint(a, "{s}::{s}", .{ z, tname }));
    }
    if (z.len > 1 and z[0] == '-' and std.ascii.isDigit(z[1])) {
        var digits = true;
        for (z[1..]) |c| digits = digits and (std.ascii.isDigit(c) or c == '.');
        if (digits) return one(try std.fmt.allocPrint(a, "'{s}'::{s}", .{ z, tname }));
    }
    const t = try deparse.both(a, z, scope);
    if (t.plain != null and t.pretty != null) return .{ .plain = t.plain.?, .pretty = t.pretty.? };
    const old = try pgText(a, z, registered);
    return .{ .plain = t.plain orelse old, .pretty = t.pretty orelse old };
}

/// A generated column's name and its expression's text (null where the
/// column has none that this reads).
const Generated = struct { name: []const u8, text: ?[]const u8 };

/// The expression of generated column `col` of generatedTexts().
fn generatedOf(gs: []const Generated, col: []const u8) ?[]const u8 {
    for (gs) |g| if (std.ascii.eqlIgnoreCase(g.name, col)) return g.text;
    return null;
}

/// The expressions of the generated columns in CREATE TABLE text `sql`
/// (GENERATED ALWAYS AS (...)), in one reading: of each column, the
/// first AS of its definition's own level.
fn generatedTexts(a: Allocator, sql: []const u8) Oom![]const Generated {
    var out: std.ArrayList(Generated) = .empty;
    var s = try Scanner.init(a, sql);
    while (true) {
        const t = s.next();
        if (t.kind == .eof) return out.items;
        if (t.kind == .punct and t.text[0] == '(') break;
    }
    var depth: usize = 1;
    var seg_start = true;
    var current: ?[]const u8 = null;
    while (depth > 0) {
        const t = s.next();
        if (t.kind == .eof) return out.items;
        if (t.kind == .punct) switch (t.text[0]) {
            '(' => {
                depth += 1;
                continue;
            },
            ')' => {
                depth -= 1;
                continue;
            },
            ',' => {
                if (depth == 1) seg_start = true;
                continue;
            },
            else => {},
        };
        if (depth != 1) continue;
        if (seg_start) {
            seg_start = false;
            current = try identText(a, t);
            continue;
        }
        if (t.kind == .word and std.ascii.eqlIgnoreCase(t.text, "as")) {
            const name = current orelse continue;
            // A later AS of the column (or of another of its name) is
            // not its.
            for (out.items) |g| {
                if (std.ascii.eqlIgnoreCase(g.name, name)) break;
            } else {
                var ahead = s;
                const open = ahead.next();
                if (open.kind != .punct or open.text[0] != '(') {
                    // None; what follows is read as the other columns'.
                    try out.append(a, .{ .name = name, .text = null });
                    continue;
                }
                // The parentheses, which leave the level as it was.
                s = ahead;
                var d: usize = 1;
                const text: ?[]const u8 = while (true) {
                    const x = s.next();
                    if (x.kind == .eof) break null;
                    if (x.kind == .punct and x.text[0] == '(') d += 1;
                    if (x.kind == .punct and x.text[0] == ')') {
                        d -= 1;
                        if (d == 0) break std.mem.trim(u8, sql[open.end..x.start], " ");
                    }
                };
                try out.append(a, .{ .name = name, .text = text });
                if (text == null) return out.items;
            }
        }
    }
    return out.items;
}

/// A constant DEFAULT the dialect stored as its column's BLOB (X'..': a
/// numeric's key, a uuid's 16 bytes, a jsonb's JSONB, an interval's
/// BLOB) as PostgreSQL shows the constant: a numeric as its digits (as
/// written, not in the column's scale: 0 for DEFAULT 0), another as its
/// text cast to the type ('…'::uuid). Null if `z` is no such literal.
fn blobDefault(a: Allocator, z: []const u8, t: ctypes.Type, type_oid: u32) Oom!?[]const u8 {
    if (z.len < 3 or (z[0] != 'X' and z[0] != 'x') or z[1] != '\'' or z[z.len - 1] != '\'') return null;
    const hex = z[2 .. z.len - 1];
    if (hex.len % 2 != 0) return null;
    const bytes = try a.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(bytes, hex) catch return null;
    const bare = if (repr.of(t.logical)) |r| r.default_bare else false;
    var shown = t;
    if (bare) shown.scale = null;
    var buf: [blob_forms.max_len]u8 = undefined;
    const owned = try blob_forms.textAlloc(a, .postgres, shown, bytes);
    const v = owned orelse blob_forms.text(.postgres, shown, bytes, &buf) orelse return null;
    if (bare) return try a.dupe(u8, v);
    const tname: []const u8 = if (builtinType(type_oid)) |bt| bt.fmt else "text";
    var q: std.ArrayList(u8) = .empty;
    try q.append(a, '\'');
    for (v) |c| {
        if (c == '\'') try q.append(a, '\'');
        try q.append(a, c);
    }
    try q.append(a, '\'');
    return try std.fmt.allocPrint(a, "{s}::{s}", .{ q.items, tname });
}

/// The text of the BLOB forms (src/dialect/repr.zig), and what PostgreSQL
/// does with them (repr.zig).
const blob_forms = @import("../repr.zig");
const repr = @import("repr.zig");

const Check = struct { name: []const u8, text: []const u8 };

/// The CHECK constraints of CREATE TABLE text `sql` (table `table`): the
/// name of each (CONSTRAINT x, else PostgreSQL's <table>_<column>_check
/// for a column's, <table>_check for the table's) and its expression's
/// text.
fn tableChecks(a: Allocator, sql: []const u8, table: []const u8) Oom![]Check {
    var out: std.ArrayList(Check) = .empty;
    var s = try Scanner.init(a, sql);
    // To the column list.
    while (true) {
        const t = s.next();
        if (t.kind == .eof) return out.items;
        if (t.kind == .punct and t.text[0] == '(') break;
    }
    var depth: usize = 1;
    var seg_start = true;
    var column_name: ?[]const u8 = null;
    var cname: ?[]const u8 = null;
    var after_constraint = false;
    var unnamed: usize = 0;
    while (depth > 0) {
        const t = s.next();
        if (t.kind == .eof) break;
        if (t.kind == .punct) switch (t.text[0]) {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' => if (depth == 1) {
                seg_start = true;
                column_name = null;
                cname = null;
                continue;
            },
            else => {},
        };
        if (depth != 1) continue;
        if (seg_start) {
            seg_start = false;
            const kw = [_][]const u8{ "constraint", "primary", "unique", "check", "foreign" };
            var is_kw = false;
            if (t.kind == .word) for (kw) |k| if (std.ascii.eqlIgnoreCase(t.text, k)) {
                is_kw = true;
            };
            if (!is_kw) {
                column_name = try identText(a, t);
                continue;
            }
        }
        if (after_constraint) {
            after_constraint = false;
            cname = try identText(a, t);
            continue;
        }
        if (t.kind == .word and std.ascii.eqlIgnoreCase(t.text, "constraint")) {
            after_constraint = true;
            continue;
        }
        if (t.kind == .word and std.ascii.eqlIgnoreCase(t.text, "check")) {
            const open = s.next();
            if (open.kind != .punct or open.text[0] != '(') continue;
            var d: usize = 1;
            var end = open.end;
            while (d > 0) {
                const x = s.next();
                if (x.kind == .eof) break;
                if (x.kind == .punct and x.text[0] == '(') d += 1;
                if (x.kind == .punct and x.text[0] == ')') {
                    d -= 1;
                    if (d == 0) {
                        end = x.start;
                        break;
                    }
                }
            }
            const text = std.mem.trim(u8, sql[open.end..end], " ");
            const name = cname orelse blk: {
                const base = if (column_name) |c| try std.fmt.allocPrint(a, "{s}_{s}_check", .{ table, c }) else try std.fmt.allocPrint(a, "{s}_check", .{table});
                var n = base;
                for (out.items) |o| if (eql(o.name, n)) {
                    unnamed += 1;
                    n = try std.fmt.allocPrint(a, "{s}{d}", .{ base, unnamed });
                };
                break :blk n;
            };
            try out.append(a, .{ .name = name, .text = text });
            cname = null;
        }
    }
    return out.items;
}

/// The items of the column list of CREATE INDEX text `sql`, as written.
fn indexItems(a: Allocator, sql: []const u8) Oom![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var s = try Scanner.init(a, sql);
    var seen_on = false;
    while (true) {
        const t = s.next();
        if (t.kind == .eof) return out.items;
        if (t.kind == .word and std.ascii.eqlIgnoreCase(t.text, "on")) seen_on = true;
        if (seen_on and t.kind == .punct and t.text[0] == '(') {
            var depth: usize = 1;
            var start = t.end;
            while (depth > 0) {
                const x = s.next();
                if (x.kind == .eof) break;
                if (x.kind != .punct) continue;
                switch (x.text[0]) {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if (depth == 0) try out.append(a, std.mem.trim(u8, sql[start..x.start], " "));
                    },
                    ',' => if (depth == 1) {
                        try out.append(a, std.mem.trim(u8, sql[start..x.start], " "));
                        start = x.end;
                    },
                    else => {},
                }
            }
            return out.items;
        }
    }
}

/// The predicate of CREATE INDEX text `sql` (after WHERE), if any.
fn whereOf(a: Allocator, sql: []const u8) Oom!?[]const u8 {
    var s = try Scanner.init(a, sql);
    var depth: usize = 0;
    while (true) {
        const t = s.next();
        if (t.kind == .eof) return null;
        if (t.kind == .punct and t.text[0] == '(') depth += 1;
        if (t.kind == .punct and t.text[0] == ')') depth -|= 1;
        if (depth == 0 and t.kind == .word and std.ascii.eqlIgnoreCase(t.text, "where")) return std.mem.trim(u8, sql[t.end..], " ");
    }
}

/// An index item without COLLATE and ASC/DESC after it.
fn stripOrder(item: []const u8) []const u8 {
    var z = std.mem.trim(u8, item, " ");
    inline for (.{ " DESC", " ASC", " desc", " asc" }) |w| {
        if (std.mem.endsWith(u8, z, w)) z = std.mem.trimEnd(u8, z[0 .. z.len - w.len], " ");
    }
    return z;
}

/// `z` without one pair of parentheses around all of it.
fn stripParens(z: []const u8) []const u8 {
    if (z.len < 2 or z[0] != '(' or z[z.len - 1] != ')') return z;
    var depth: usize = 0;
    for (z, 0..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0 and i != z.len - 1) return z;
        }
    }
    return z[1 .. z.len - 1];
}

/// Whether expression text `e` is a function call (PostgreSQL prints an
/// index expression that is one without parentheses).
fn looksLikeCall(a: Allocator, e: []const u8) Oom!bool {
    var s = try Scanner.init(a, e);
    const t = s.next();
    if (t.kind != .word and t.kind != .quoted) return false;
    const p = s.next();
    if (p.kind != .punct or p.text[0] != '(') return false;
    var depth: usize = 1;
    while (depth > 0) {
        const x = s.next();
        if (x.kind == .eof) return false;
        if (x.kind == .punct and x.text[0] == '(') depth += 1;
        if (x.kind == .punct and x.text[0] == ')') depth -= 1;
        if (depth == 0) return x.end == e.len;
    }
    return false;
}

/// The name of an index column that is an expression: the function's,
/// else "expr".
fn exprName(a: Allocator, e: []const u8) Oom![]const u8 {
    if (!try looksLikeCall(a, e)) return "expr";
    var s = try Scanner.init(a, e);
    return s.next().text;
}

// ===================================================== search_path

/// The schemas of search_path, in the order a name is looked up:
/// pg_temp (unless listed), pg_catalog (unless listed), then the path's.
pub fn path(db: *Sqlite3, s: *const Snapshot, a: Allocator) Oom![]u32 {
    var out: std.ArrayList(u32) = .empty;
    const names = try state.splitPath(a, db.xq.postgres.searchPath());
    var has_temp = false;
    var has_catalog = false;
    for (names) |n| {
        has_temp = has_temp or eql(n, "pg_temp");
        has_catalog = has_catalog or eql(n, "pg_catalog");
    }
    if (!has_temp) if (s.tempNsp()) |t| try out.append(a, t.oid);
    if (!has_catalog) try out.append(a, oid_pg_catalog);
    for (names) |n| {
        if (eql(n, "pg_temp")) {
            if (s.tempNsp()) |t| try out.append(a, t.oid);
            continue;
        }
        for (s.nsps) |x| if (std.ascii.eqlIgnoreCase(x.name, n) and (x.mangled or x.oid == oid_public or x.oid == oid_pg_catalog)) {
            try out.append(a, x.oid);
            break;
        };
    }
    return out.items;
}

/// Whether relation `r` is found by its name alone (pg_table_is_visible()).
pub fn visible(s: *const Snapshot, p: []const u32, r: *const Rel) bool {
    for (p) |n| {
        if (n == r.nsp) return true;
        if (s.relByName(n, r.name) != null) return false;
    }
    return false;
}

// ===================================================== the relations

pub const Cell = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
    /// Expression `expr` of the snapshot's texts, made when the column
    /// is read (SQLite reads only the columns a query uses, and those of
    /// the rows its conditions keep).
    lazy: struct { expr: u32, what: enum { bin, keys } },

    fn bin(i: u32) Cell {
        return .{ .lazy = .{ .expr = i, .what = .bin } };
    }
};

/// A column of a catalog relation: its name and PostgreSQL type, which
/// a reference to the column has (EngineModule.column_types).
pub const Col = struct { []const u8, Type };

pub const Type = enum {
    oid,
    name,
    text,
    char,
    bool,
    int2,
    int4,
    int8,
    float4,
    /// Arrays, their text (`{1,2}`; int2vector and oidvector `1 2`).
    int2_array,
    oid_array,
    text_array,
    char_array,
    acl_array,
    int2vector,
    oidvector,

    /// The SQLite type of the virtual table's column.
    pub fn sqlite(t: Type) []const u8 {
        return switch (t) {
            .name, .text, .char, .int2_array, .oid_array, .text_array, .char_array, .acl_array, .int2vector, .oidvector => "TEXT",
            .float4 => "REAL",
            else => "INTEGER",
        };
    }

    /// The spelling of the type of the column (EngineModule
    /// .column_types), as the parser spells cast()'s type; "" for none
    /// (text and "char" are of no type, as an unknown literal).
    pub fn spelling(comptime t: Type) [:0]const u8 {
        if (t == .char_array) return "char[]";
        const z = t.cast();
        return if (z.len == 0) "" else z[2..] ++ "";
    }

    /// The cast to the type ("" for none): catalog_views.zig's NULL of an
    /// empty relation's column.
    pub fn cast(t: Type) []const u8 {
        return switch (t) {
            .oid => "::oid",
            .name => "::name",
            .bool => "::boolean",
            .int2 => "::smallint",
            .int4 => "::integer",
            .int8 => "::bigint",
            .float4 => "::real",
            .int2_array => "::smallint[]",
            .oid_array => "::oid[]",
            .text_array => "::text[]",
            .char_array => "::\"char\"[]",
            .acl_array => "::aclitem[]",
            .int2vector => "::int2vector",
            .oidvector => "::oidvector",
            .text, .char => "",
        };
    }
};

const Rows = struct {
    a: Allocator,
    cells: std.ArrayList(Cell) = .empty,
    ncol: usize,

    fn row(r: *Rows, cells: anytype) Oom!void {
        const names = @typeInfo(@TypeOf(cells)).@"struct".field_names;
        std.debug.assert(names.len == r.ncol);
        inline for (names) |n| try r.cells.append(r.a, cell(@field(cells, n)));
    }

    /// A text of a row (StaticRows makes it at compile time).
    fn print(r: *Rows, comptime fmt: []const u8, args: anytype) Oom![]const u8 {
        return std.fmt.allocPrint(r.a, fmt, args);
    }

    /// The text of the numbers `at(ctx, i)` for i < n, as vector().
    fn join(r: *Rows, n: usize, comptime braces: bool, ctx: anytype, comptime at: fn (@TypeOf(ctx), usize) i64) Oom![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (braces) try out.append(r.a, '{');
        for (0..n) |i| {
            if (i > 0) try out.append(r.a, if (braces) ',' else ' ');
            try out.print(r.a, "{d}", .{at(ctx, i)});
        }
        if (braces) try out.append(r.a, '}');
        return out.items;
    }
};

fn cell(v: anytype) Cell {
    const T = @TypeOf(v);
    if (T == Cell) return v;
    if (T == @TypeOf(null)) return .null;
    if (T == bool) return .{ .int = @intFromBool(v) };
    if (T == comptime_int) return .{ .int = v };
    if (T == comptime_float) return .{ .float = v };
    switch (@typeInfo(T)) {
        .int => return .{ .int = @intCast(v) },
        .float => return .{ .float = v },
        .optional => return if (v) |x| cell(x) else .null,
        .pointer => |p| {
            if (p.size == .slice) return .{ .text = v };
            if (p.size == .one) return .{ .text = v };
        },
        else => {},
    }
    @compileError("not a cell: " ++ @typeName(T));
}

fn char(c: u8) Cell {
    if (c == 0) return .{ .text = "" };
    return .{ .text = chars[c..][0..1] };
}

const chars = blk: {
    var z: [256]u8 = undefined;
    for (&z, 0..) |*c, i| c.* = i;
    const final = z;
    break :blk final;
};

/// The text of `xs` (`{1,2}`, or `1 2` without braces) into `r` (Rows
/// or StaticRows).
fn vector(r: anytype, xs: []const i16, comptime braces: bool) ![]const u8 {
    return r.join(xs.len, braces, xs, struct {
        fn at(ys: []const i16, i: usize) i64 {
            return ys[i];
        }
    }.at);
}

pub const Relation = struct {
    name: [:0]const u8,
    cols: []const Col,
    fill: *const fn (s: *const Snapshot, r: *Rows) Oom!void,
    /// Whether the relation can have rows, known without a snapshot
    /// (false: none, and none is made).
    any: ?*const fn (db: *Sqlite3) bool = null,
    /// The rows that are the same for every snapshot (the system
    /// relations', the built-in types'), before the snapshot's: cells
    /// made at compile time (staticRows()).
    static: []const Cell = &.{},
    /// The columns of OIDs an equality picks the rows by (bestIndex():
    /// `attrelid = 16384`, a join's `a.attrelid = c.oid`), the better
    /// first.
    keys: []const Key = &.{},

    pub const Key = struct {
        col: u8,
        /// One row at most of a value (an OID column).
        unique: bool = false,
        /// The rows of a value, about (the estimate of bestIndex()).
        rows: u8 = 1,
    };
};

fn fillNamespace(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.nsps) |n| try r.row(.{ n.oid, n.name, n.owner, null });
}

fn relam(kind: u8) u32 {
    return switch (kind) {
        'r' => 2,
        'i' => 403,
        else => 0,
    };
}

fn fillClass(s: *const Snapshot, r: *Rows) Oom!void {
    try classRows(r, s.rels);
}

/// pg_class's rows of `rels` into `r` (Rows, or StaticRows at compile
/// time: the system relations').
fn classRows(r: anytype, rels: []const Rel) !void {
    for (rels) |*x| try classRow(r, x);
}

fn classRow(r: anytype, x: *const Rel) !void {
    const sys = x.oid < first_user_oid;
    try r.row(.{
        x.oid,       x.name,   x.nsp,               x.rowtype,    0,       oid_superuser, relam(x.kind), x.oid,          0,     @as(i32, if (x.kind == 'i') 1 else 0), @as(f64, if (x.kind == 'i') 0 else -1), 0,    0,                                              0,
        x.has_index, x.shared, char(x.persistence), char(x.kind), x.natts, x.checks,      false,         x.has_triggers, false, false,                                 false,                                  true, char(if (x.kind == 'r' and !sys) 'd' else 'n'), false,
        0,           "0",      "1",                 x.acl,        null,    null,
    });
}

fn fillAttribute(s: *const Snapshot, r: *Rows) Oom!void {
    try attributeRows(r, s, s.attrs);
}

/// pg_attribute's rows of `attrs` (each relation's together) into `r`
/// (Rows of a snapshot `cat`, or StaticRows of `system`).
fn attributeRows(r: anytype, cat: anytype, attrs: []const Attr) !void {
    for (attrs, 0..) |x, i| {
        try attrRow(r, x);
        // A table's system columns, after its own (attnum < 0).
        if (i + 1 < attrs.len and attrs[i + 1].rel == x.rel) continue;
        const rel = cat.rel(x.rel) orelse continue;
        if (rel.kind == 'r') try systemColumnRows(r, x.rel);
    }
}

/// pg_attribute's row of `x` into `r` (Rows, or StaticRows).
fn attrRow(r: anytype, x: Attr) !void {
    const t = typeInfo(x.type_oid);
    try r.row(.{
        x.rel,                                x.name,                              x.type_oid, if (t) |b| b.len else -1, x.num,    x.typmod, 0,                if (t) |b| b.byval else false,
        char(if (t) |b| b.@"align" else 'i'), char(if (t) |b| b.storage else 'x'), char(0),    x.notnull,                x.hasdef, false,    char(x.identity), char(x.generated),
        false,                                true,                                0,          x.collation,              null,     null,     null,             null,
        null,
    });
}

fn systemColumnRows(r: anytype, rel: u32) !void {
    for (system_columns) |c| try r.row(.{
        rel,        c[0],      c[1],    c[3], c[2],  -1,    0,       c[4],
        char(c[5]), char('p'), char(0), true, false, false, char(0), char(0),
        false,      true,      0,       0,    null,  null,  null,    null,
        null,
    });
}

/// PostgreSQL's system columns of a table: name, type, attnum, attlen,
/// attbyval, attalign.
const system_columns = [_]struct { []const u8, u32, i16, i16, bool, u8 }{
    .{ "ctid", 27, -1, 6, false, 's' }, .{ "xmin", 28, -2, 4, true, 'i' }, .{ "cmin", 29, -3, 4, true, 'i' },
    .{ "xmax", 28, -4, 4, true, 'i' },  .{ "cmax", 29, -5, 4, true, 'i' }, .{ "tableoid", 26, -6, 4, true, 'i' },
};

/// The name of a type's input function ... (`suffix` in, out, recv,
/// send) into `r` (Rows or StaticRows).
fn procOf(r: anytype, stem: []const u8, suffix: []const u8) ![]const u8 {
    if (stem.len == 0) return "-";
    if (stem[stem.len - 1] == '_') return r.print("{s}{s}", .{ stem[0 .. stem.len - 1], if (eql(suffix, "in")) "_in" else if (eql(suffix, "out")) "_out" else if (eql(suffix, "recv")) "_recv" else "_send" });
    return r.print("{s}{s}", .{ stem, suffix });
}

fn fillType(s: *const Snapshot, r: *Rows) Oom!void {
    try rowtypeRows(r, s.rels);
}

/// A row of PostgreSQL's pg_type (systypes.zig).
pub const SysType = struct {
    oid: u32,
    name: []const u8,
    nsp: u32,
    len: i16,
    byval: bool,
    typtype: u8,
    cat: u8,
    preferred: bool,
    relid: u32,
    subscript: []const u8,
    elem: u32,
    array: u32,
    input: []const u8,
    output: []const u8,
    recv: []const u8,
    send: []const u8,
    modin: []const u8,
    modout: []const u8,
    analyze: []const u8,
    @"align": u8,
    storage: u8,
    basetype: u32,
    typmod: i32,
    ndims: i32,
    coll: u32,
};

/// A row of PostgreSQL's pg_range (systypes.zig).
pub const SysRange = struct { typ: u32, subtype: u32, multi: u32, coll: u32, opc: u32, canonical: []const u8, subdiff: []const u8 };

const systypes = @import("systypes.zig");

/// The array type PostgreSQL has of type `oid` (systypes.zig), 0 if none.
fn sysArray(oid: u32) u32 {
    for (systypes.types) |t| if (t.oid == oid) return t.array;
    return 0;
}

/// Whether builtinTypeRows() makes type `oid` of its own data: a
/// built-in type, a domain, a system relation's row type.
fn madeType(oid: u32) bool {
    if (typeInfo(oid) != null) return true;
    for (system.rels) |x| if (x.rowtype == oid) return true;
    return false;
}

/// pg_type's rows of the built-in types and information_schema's
/// domains, then PostgreSQL's others (systypes.zig: the types xqlite
/// has not, the row types of the relations it has not, the arrays of
/// those of domains and relations) (StaticRows).
fn builtinTypeRows(r: anytype) !void {
    for (builtin_types) |t| {
        try r.row(.{
            t.oid,                                                                                  t.name, oid_pg_catalog, oid_superuser,             t.len,                      t.byval,                     char(t.typtype),             char(t.cat),                                                    t.preferred,                                                     true, ",",              0,
            if (t.cat == 'A' and t.elem != 0 and t.io.len == 6) "array_subscript_handler" else "-", t.elem, t.array,        try procOf(r, t.io, "in"), try procOf(r, t.io, "out"), try procOf(r, t.io, "recv"), try procOf(r, t.io, "send"), if (t.modin.len > 0) try r.print("{s}in", .{t.modin}) else "-", if (t.modin.len > 0) try r.print("{s}out", .{t.modin}) else "-", "-",  char(t.@"align"), char(t.storage),
            false,                                                                                  0,      -1,             0,                         t.coll,                     null,                        null,                        null,
        });
    }
    for (&domain_types) |t| {
        const base = builtinType(t.basetype).?;
        try r.row(.{
            t.oid, t.name,     t.nsp,           oid_superuser, t.len,                         t.byval,       char(t.typtype),                char(t.cat), false, true, ",",              0,
            "-",   0,          sysArray(t.oid), "domain_in",   try procOf(r, base.io, "out"), "domain_recv", try procOf(r, base.io, "send"), "-",         "-",   "-",  char(t.@"align"), char(t.storage),
            false, t.basetype, t.typmod,        0,             t.coll,                        null,          null,                           null,
        });
    }
    try rowtypeRows(r, system.rels);
    for (systypes.types) |t| {
        if (madeType(t.oid)) continue;
        try r.row(.{
            t.oid,       t.name,     t.nsp,    oid_superuser, t.len,    t.byval, char(t.typtype), char(t.cat), t.preferred, true,      ",",              t.relid,
            t.subscript, t.elem,     t.array,  t.input,       t.output, t.recv,  t.send,          t.modin,     t.modout,    t.analyze, char(t.@"align"), char(t.storage),
            false,       t.basetype, t.typmod, t.ndims,       t.coll,   null,    null,            null,
        });
    }
}

/// pg_type's rows of the row types of `rels` (Rows, or StaticRows), and
/// of their arrays where the Rel has one of its own (a relation of a
/// database: a system relation's is PostgreSQL's, in systypes.zig).
fn rowtypeRows(r: anytype, rels: []const Rel) !void {
    for (rels) |x| {
        if (x.rowtype == 0) continue;
        const array = if (x.rowarray != 0) x.rowarray else sysArray(x.rowtype);
        try r.row(.{
            x.rowtype,   x.name,       x.nsp,         oid_superuser, -1,  false, "c", "C", false, true,  ",", x.oid, "-", 0, array,
            "record_in", "record_out", "record_recv", "record_send", "-", "-",   "-", "d", "x",   false, 0,   -1,    0,   0, null,
            null,        null,
        });
        if (x.rowarray == 0) continue;
        try r.row(.{
            x.rowarray, try r.print("_{s}", .{x.name}), x.nsp,        oid_superuser, -1,  false, "b",                "A", false, true,  ",", 0,  "array_subscript_handler", x.rowtype, 0,
            "array_in", "array_out",                    "array_recv", "array_send",  "-", "-",   "array_typanalyze", "d", "x",   false, 0,   -1, 0,                         0,         null,
            null,       null,
        });
    }
}

fn fillIndex(s: *const Snapshot, r: *Rows) Oom!void {
    try indexRows(r, s, s.indexes);
}

/// pg_index's rows of `xs` into `r` (Rows of a snapshot `cat`, or
/// StaticRows of `system`).
fn indexRows(r: anytype, cat: anytype, xs: []const IndexRow) !void {
    const Of = struct {
        cat: @TypeOf(cat),
        x: *const IndexRow,

        fn opt(o: @This(), i: usize) i64 {
            return if (o.x.desc[i]) 3 else 0;
        }

        fn coll(o: @This(), i: usize) i64 {
            const k = o.x.keys[i];
            return if (k > 0) (if (o.cat.attr(o.x.table, k)) |at| at.collation else 0) else 0;
        }

        fn class(o: @This(), i: usize) i64 {
            return if (o.cat.attr(o.x.rel, @intCast(i + 1))) |at| defaultOpclass(at.type_oid) else 0;
        }
    };
    for (xs) |*x| {
        const n = x.keys.len;
        const o: Of = .{ .cat = cat, .x = x };
        try r.row(.{
            x.rel,                        x.table,                          n,                                 n,                               x.unique, false,                                             x.primary, false, true, false, true, false, true, true, false,
            try vector(r, x.keys, false), try r.join(n, false, o, Of.coll), try r.join(n, false, o, Of.class), try r.join(n, false, o, Of.opt), x.exprs,  if (x.pred) |p| Cell.bin(p) else @as(Cell, .null),
        });
    }
}

fn fillConstraint(s: *const Snapshot, r: *Rows) Oom!void {
    try constraintRows(r, s.cons);
}

/// pg_constraint's rows of `cs` into `r` (Rows, or StaticRows).
fn constraintRows(r: anytype, cs: []const Con) !void {
    for (cs) |c| {
        // A CHECK's conkey and conbin: its expression's.
        const keys: Cell = if (c.check) |e| .{ .lazy = .{ .expr = e, .what = .keys } } else if (c.keys.len > 0) .{ .text = try vector(r, c.keys, true) } else .null;
        const bin: Cell = if (c.check) |e| .bin(e) else .null;
        try r.row(.{
            c.oid,       c.name,      c.nsp,                                 char(c.type), c.deferrable, c.deferred, true,  true, c.rel,                                                       0,    c.index, 0,    c.frel,
            char(c.upd), char(c.del), char(if (c.type == 'f') 's' else ' '), true,         0,            false,      false, keys, if (c.fkeys.len > 0) try vector(r, c.fkeys, true) else null, null, null,    null, null,
            null,        bin,
        });
    }
}

fn fillAttrdef(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.defs) |d| try r.row(.{ d.oid, d.rel, d.num, Cell.bin(d.expr) });
}

/// The columns and their types of each view of main, a view by its name
/// in SQLite ("<schema>.<view>" but for public's views): what
/// information_schema.columns reads of views (catalog_views.zig, over
/// main's sqlite_schema), which xq_catalog has not, without reading
/// pg_class and pg_attribute.
fn fillViewColumns(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.rels) |v| {
        if (v.kind != 'v' or !eql(v.db, "main")) continue;
        for (s.columnsOf(v.oid)) |at| try r.row(.{ v.sqlite_name, at.name, at.type_oid, at.typmod });
    }
}

/// Whether main has a view (else fillViewColumns() has no row).
fn anyView(db: *Sqlite3) bool {
    var it = db.dbs.items[0].schema.tbl_hash.valueIterator();
    while (it.next()) |t| if (t.*.isView()) return true;
    return false;
}

fn fillSequence(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.rels) |x| if (x.seq) |q| {
        try r.row(.{ x.oid, 20, q.start, q.increment, q.max, q.min, 1, q.cycle });
    };
}

fn fillDepend(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.deps) |d| try r.row(.{ 1259, d.seq, 0, 1259, d.rel, d.num, char(d.type) });
}

fn fillDescription(s: *const Snapshot, r: *Rows) Oom!void {
    // pg_extension's plpgsql (catalog_views.zig), as PostgreSQL has it.
    try r.row(.{ 13603, 3079, 0, "PL/pgSQL procedural language" });
    for (s.descs) |d| try r.row(.{ d.obj, 1259, d.subid, d.text });
}

fn fillProc(s: *const Snapshot, r: *Rows) Oom!void {
    _ = s;
    const a = r.a;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (builtin_types) |t| {
        for ([_][]const u8{ "in", "out", "recv", "send" }) |suffix| {
            const name = try procOf(r, t.io, suffix);
            if (seen.contains(name)) continue;
            try seen.put(a, name, {});
            const ret: u32 = if (eql(suffix, "in") or eql(suffix, "recv")) t.oid else if (eql(suffix, "out")) 2275 else 17;
            const arg: u32 = if (eql(suffix, "in")) 2275 else if (eql(suffix, "recv")) 2281 else t.oid;
            try r.row(.{
                procOid(name), name, oid_pg_catalog, oid_superuser,                            12,   @as(f64, 1), @as(f64, 0), 0,    "-",  "f",  false, false, true, false, "i", "s",
                1,             0,    ret,            try std.fmt.allocPrint(a, "{d}", .{arg}), null, null,        null,        null, null, name, null,  null,  null, null,
            });
        }
    }
}

/// The OID of a built-in function of fillProc().
pub fn procOid(name: []const u8) u32 {
    // No collision is resolved among them: up to 2^31.
    return hashOid('p', name, first_user_oid, 0x7fffffff - first_user_oid);
}

/// The name of a built-in function by its OID, for regproc's output.
pub fn procName(a: Allocator, oid: u32) Oom!?[]const u8 {
    var r: Rows = .{ .a = a, .ncol = 0 };
    for (builtin_types) |t| {
        for ([_][]const u8{ "in", "out", "recv", "send" }) |suffix| {
            const name = try procOf(&r, t.io, suffix);
            if (procOid(name) == oid) return name;
        }
    }
    return null;
}

const class_cols = [_]Col{
    .{ "oid", .oid },                  .{ "relname", .name },        .{ "relnamespace", .oid },    .{ "reltype", .oid },
    .{ "reloftype", .oid },            .{ "relowner", .oid },        .{ "relam", .oid },           .{ "relfilenode", .oid },
    .{ "reltablespace", .oid },        .{ "relpages", .int4 },       .{ "reltuples", .float4 },    .{ "relallvisible", .int4 },
    .{ "relallfrozen", .int4 },        .{ "reltoastrelid", .oid },   .{ "relhasindex", .bool },    .{ "relisshared", .bool },
    .{ "relpersistence", .char },      .{ "relkind", .char },        .{ "relnatts", .int2 },       .{ "relchecks", .int2 },
    .{ "relhasrules", .bool },         .{ "relhastriggers", .bool }, .{ "relhassubclass", .bool }, .{ "relrowsecurity", .bool },
    .{ "relforcerowsecurity", .bool }, .{ "relispopulated", .bool }, .{ "relreplident", .char },   .{ "relispartition", .bool },
    .{ "relrewrite", .oid },           .{ "relfrozenxid", .text },   .{ "relminmxid", .text },     .{ "relacl", .acl_array },
    .{ "reloptions", .text_array },    .{ "relpartbound", .text },
};

const attribute_cols = [_]Col{
    .{ "attrelid", .oid },       .{ "attname", .name },       .{ "atttypid", .oid },          .{ "attlen", .int2 },
    .{ "attnum", .int2 },        .{ "atttypmod", .int4 },     .{ "attndims", .int2 },         .{ "attbyval", .bool },
    .{ "attalign", .char },      .{ "attstorage", .char },    .{ "attcompression", .char },   .{ "attnotnull", .bool },
    .{ "atthasdef", .bool },     .{ "atthasmissing", .bool }, .{ "attidentity", .char },      .{ "attgenerated", .char },
    .{ "attisdropped", .bool },  .{ "attislocal", .bool },    .{ "attinhcount", .int2 },      .{ "attcollation", .oid },
    .{ "attstattarget", .int2 }, .{ "attacl", .acl_array },   .{ "attoptions", .text_array }, .{ "attfdwoptions", .text_array },
    .{ "attmissingval", .text },
};

/// The rows of a relation that are the same for every snapshot, made at
/// compile time: Rows' cells, by classRows() and the like (n null:
/// only counted).
fn StaticRows(comptime ncol: usize, comptime n: ?usize) type {
    return struct {
        cells: [ncol * (n orelse 0)]Cell = undefined,
        /// The cells made (or counted).
        len: usize = 0,

        fn row(r: *@This(), cells: anytype) error{}!void {
            const names = @typeInfo(@TypeOf(cells)).@"struct".field_names;
            if (names.len != ncol) @compileError("not a row");
            if (n == null) {
                r.len += ncol;
                return;
            }
            inline for (names) |f| {
                r.cells[r.len] = cell(@field(cells, f));
                r.len += 1;
            }
        }

        fn print(_: *@This(), comptime fmt: []const u8, args: anytype) error{}![]const u8 {
            if (n == null) return "";
            return std.fmt.comptimePrint(fmt, args);
        }

        fn join(_: *@This(), len: usize, comptime braces: bool, ctx: anytype, comptime at: fn (@TypeOf(ctx), usize) i64) error{}![]const u8 {
            if (n == null) return "";
            var z: []const u8 = if (braces) "{" else "";
            for (0..len) |i| {
                if (i > 0) z = z ++ if (braces) "," else " ";
                z = z ++ std.fmt.comptimePrint("{d}", .{at(ctx, i)});
            }
            return if (braces) z ++ "}" else z;
        }
    };
}

/// The cells `fill` makes into a StaticRows of `ncol` columns: a
/// Relation's static.
fn staticRows(comptime ncol: usize, comptime fill: anytype) []const Cell {
    comptime {
        @setEvalBranchQuota(20_000_000);
        var count: StaticRows(ncol, null) = .{};
        fill(&count) catch unreachable;
        var r: StaticRows(ncol, count.len / ncol) = .{};
        fill(&r) catch unreachable;
        const final = r.cells;
        return &final;
    }
}

/// The system relations' rows, a table's system columns after its own
/// (pg_attribute); pg_type's: the built-in types' and the system
/// relations' row types.
const static_rows = struct {
    const class = staticRows(class_cols.len, struct {
        fn f(r: anytype) !void {
            try classRows(r, system.rels);
        }
    }.f);
    const attribute = staticRows(attribute_cols.len, struct {
        fn f(r: anytype) !void {
            try attributeRows(r, system, system.attrs);
        }
    }.f);
    const @"type" = staticRows(type_cols.len, builtinTypeRows);
    const index = staticRows(index_cols.len, struct {
        fn f(r: anytype) !void {
            try indexRows(r, system, system.indexes);
        }
    }.f);
    const constraint = staticRows(constraint_cols.len, struct {
        fn f(r: anytype) !void {
            try constraintRows(r, system.cons);
        }
    }.f);
};

const type_cols = [_]Col{
    .{ "oid", .oid },             .{ "typname", .name },       .{ "typnamespace", .oid }, .{ "typowner", .oid },
    .{ "typlen", .int2 },         .{ "typbyval", .bool },      .{ "typtype", .char },     .{ "typcategory", .char },
    .{ "typispreferred", .bool }, .{ "typisdefined", .bool },  .{ "typdelim", .char },    .{ "typrelid", .oid },
    .{ "typsubscript", .text },   .{ "typelem", .oid },        .{ "typarray", .oid },     .{ "typinput", .text },
    .{ "typoutput", .text },      .{ "typreceive", .text },    .{ "typsend", .text },     .{ "typmodin", .text },
    .{ "typmodout", .text },      .{ "typanalyze", .text },    .{ "typalign", .char },    .{ "typstorage", .char },
    .{ "typnotnull", .bool },     .{ "typbasetype", .oid },    .{ "typtypmod", .int4 },   .{ "typndims", .int4 },
    .{ "typcollation", .oid },    .{ "typdefaultbin", .text }, .{ "typdefault", .text },  .{ "typacl", .acl_array },
};

const index_cols = [_]Col{
    .{ "indexrelid", .oid },         .{ "indrelid", .oid },             .{ "indnatts", .int2 },        .{ "indnkeyatts", .int2 },
    .{ "indisunique", .bool },       .{ "indnullsnotdistinct", .bool }, .{ "indisprimary", .bool },    .{ "indisexclusion", .bool },
    .{ "indimmediate", .bool },      .{ "indisclustered", .bool },      .{ "indisvalid", .bool },      .{ "indcheckxmin", .bool },
    .{ "indisready", .bool },        .{ "indislive", .bool },           .{ "indisreplident", .bool },  .{ "indkey", .int2vector },
    .{ "indcollation", .oidvector }, .{ "indclass", .oidvector },       .{ "indoption", .int2vector }, .{ "indexprs", .text },
    .{ "indpred", .text },
};

const constraint_cols = [_]Col{
    .{ "oid", .oid },             .{ "conname", .name },              .{ "connamespace", .oid },    .{ "contype", .char },
    .{ "condeferrable", .bool },  .{ "condeferred", .bool },          .{ "conenforced", .bool },    .{ "convalidated", .bool },
    .{ "conrelid", .oid },        .{ "contypid", .oid },              .{ "conindid", .oid },        .{ "conparentid", .oid },
    .{ "confrelid", .oid },       .{ "confupdtype", .char },          .{ "confdeltype", .char },    .{ "confmatchtype", .char },
    .{ "conislocal", .bool },     .{ "coninhcount", .int2 },          .{ "connoinherit", .bool },   .{ "conperiod", .bool },
    .{ "conkey", .int2_array },   .{ "confkey", .int2_array },        .{ "conpfeqop", .oid_array }, .{ "conppeqop", .oid_array },
    .{ "conffeqop", .oid_array }, .{ "confdelsetcols", .int2_array }, .{ "conexclop", .oid_array }, .{ "conbin", .text },
};

/// The first column, an OID of one row each.
const oid_key: Relation.Key = .{ .col = 0, .unique = true };

pub const relations = [_]Relation{
    .{ .name = "xq_pg_namespace", .fill = fillNamespace, .keys = &.{oid_key}, .cols = &.{
        .{ "oid", .oid }, .{ "nspname", .name }, .{ "nspowner", .oid }, .{ "nspacl", .acl_array },
    } },
    .{ .name = "xq_pg_class", .fill = fillClass, .static = static_rows.class, .keys = &.{oid_key}, .cols = &class_cols },
    .{ .name = "xq_pg_attribute", .fill = fillAttribute, .static = static_rows.attribute, .keys = &.{.{ .col = 0, .rows = 10 }}, .cols = &attribute_cols },
    .{ .name = "xq_pg_type", .fill = fillType, .static = static_rows.type, .keys = &.{oid_key}, .cols = &type_cols },
    .{ .name = "xq_pg_index", .fill = fillIndex, .static = static_rows.index, .keys = &.{ oid_key, .{ .col = 1, .rows = 2 } }, .cols = &index_cols },
    .{ .name = "xq_pg_constraint", .fill = fillConstraint, .static = static_rows.constraint, .keys = &.{ oid_key, .{ .col = 8, .rows = 3 }, .{ .col = 12, .rows = 2 } }, .cols = &constraint_cols },
    .{ .name = "xq_pg_attrdef", .fill = fillAttrdef, .keys = &.{ oid_key, .{ .col = 1, .rows = 2 } }, .cols = &.{
        .{ "oid", .oid }, .{ "adrelid", .oid }, .{ "adnum", .int2 }, .{ "adbin", .text },
    } },
    .{ .name = "xq_pg_sequence", .fill = fillSequence, .keys = &.{oid_key}, .cols = &.{
        .{ "seqrelid", .oid }, .{ "seqtypid", .oid }, .{ "seqstart", .int8 }, .{ "seqincrement", .int8 },
        .{ "seqmax", .int8 },  .{ "seqmin", .int8 },  .{ "seqcache", .int8 }, .{ "seqcycle", .bool },
    } },
    .{ .name = "xq_pg_depend", .fill = fillDepend, .keys = &.{ .{ .col = 1, .rows = 2 }, .{ .col = 4, .rows = 2 } }, .cols = &.{
        .{ "classid", .oid },  .{ "objid", .oid },        .{ "objsubid", .int4 }, .{ "refclassid", .oid },
        .{ "refobjid", .oid }, .{ "refobjsubid", .int4 }, .{ "deptype", .char },
    } },
    .{ .name = "xq_pg_description", .fill = fillDescription, .keys = &.{.{ .col = 0, .rows = 2 }}, .cols = &.{
        .{ "objoid", .oid }, .{ "classoid", .oid }, .{ "objsubid", .int4 }, .{ "description", .text },
    } },
    .{ .name = "xq_pg_view_columns", .fill = fillViewColumns, .any = anyView, .cols = &.{
        .{ "tbl", .text }, .{ "col", .text }, .{ "typid", .oid }, .{ "typmod", .int4 },
    } },
    .{ .name = "xq_pg_proc", .fill = fillProc, .keys = &.{oid_key}, .cols = &.{
        .{ "oid", .oid },                  .{ "proname", .name },           .{ "pronamespace", .oid },       .{ "proowner", .oid },
        .{ "prolang", .oid },              .{ "procost", .float4 },         .{ "prorows", .float4 },         .{ "provariadic", .oid },
        .{ "prosupport", .text },          .{ "prokind", .char },           .{ "prosecdef", .bool },         .{ "proleakproof", .bool },
        .{ "proisstrict", .bool },         .{ "proretset", .bool },         .{ "provolatile", .char },       .{ "proparallel", .char },
        .{ "pronargs", .int2 },            .{ "pronargdefaults", .int2 },   .{ "prorettype", .oid },         .{ "proargtypes", .oidvector },
        .{ "proallargtypes", .oid_array }, .{ "proargmodes", .char_array }, .{ "proargnames", .text_array }, .{ "proargdefaults", .text },
        .{ "protrftypes", .oid_array },    .{ "prosrc", .text },            .{ "probin", .text },            .{ "prosqlbody", .text },
        .{ "proconfig", .text_array },     .{ "proacl", .acl_array },
    } },
};

/// The view text of relation `pg_name` (pg_class ...): the columns of
/// the virtual table, which are of their types (EngineModule
/// .column_types) without a cast, so that a condition on one (`attrelid
/// = 16384`, a join's `a.attrelid = c.oid`) is a constraint of
/// bestIndex().
pub fn viewText(comptime rel: Relation) []const u8 {
    comptime {
        var z: []const u8 = "SELECT ";
        for (rel.cols, 0..) |c, i| {
            if (i > 0) z = z ++ ", ";
            z = z ++ c[0];
        }
        return z ++ " FROM " ++ rel.name;
    }
}

/// The view text of relation `rel` as it was before its columns were
/// typed: each cast to its type (the test of column_types).
pub fn castViewText(comptime rel: Relation) []const u8 {
    comptime {
        var z: []const u8 = "SELECT ";
        for (rel.cols, 0..) |c, i| {
            if (i > 0) z = z ++ ", ";
            z = z ++ c[0] ++ c[1].cast() ++ " AS " ++ c[0];
        }
        return z ++ " FROM " ++ rel.name;
    }
}

fn columnTypes(comptime rel: Relation) []const [:0]const u8 {
    comptime {
        var out: [rel.cols.len][:0]const u8 = undefined;
        for (rel.cols, &out) |c, *o| o.* = c[1].spelling();
        const final = out;
        return &final;
    }
}

fn declText(comptime rel: Relation) [:0]const u8 {
    comptime {
        var z: []const u8 = "CREATE TABLE x(";
        for (rel.cols, 0..) |c, i| {
            if (i > 0) z = z ++ ",";
            z = z ++ c[0] ++ " " ++ c[1].sqlite();
        }
        return z ++ ")";
    }
}

// ================================================= the virtual tables

const RC = int.RC;
const Context = vi.Context;

const VTable = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
};

const Cursor = struct {
    base: vtab.VtabCursor = .{},
    db: *Sqlite3,
    snap: ?*Snapshot = null,
    arena: std.heap.ArenaAllocator,
    /// The relation's static rows, then the snapshot's.
    head: []const Cell = &.{},
    cells: []const Cell = &.{},
    ncol: usize = 1,
    i: usize = 0,
    /// The rows read: those whose column `col` is `value` (filter()'s
    /// equality), or all.
    key: ?struct { col: usize, value: i64 } = null,

    fn of(cur: *vtab.VtabCursor) *Cursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }

    fn eof(c: *const Cursor) bool {
        return c.i * c.ncol >= c.head.len + c.cells.len;
    }

    fn cellAt(c: *const Cursor, k: usize) Cell {
        return if (k < c.head.len) c.head[k] else c.cells[k - c.head.len];
    }

    /// From row `i` on, to the first row read (or the end).
    fn seek(c: *Cursor) void {
        const key = c.key orelse return;
        while (!c.eof()) : (c.i += 1) switch (c.cellAt(c.i * c.ncol + key.col)) {
            .int => |v| if (v == key.value) return,
            else => {},
        };
    }

    pub fn init(t: *VTable) Cursor {
        return .{ .db = t.db, .arena = .init(t.db.gpa) };
    }

    pub fn deinit(c: *Cursor, db: *Sqlite3) void {
        if (c.snap) |s| release(db, s);
        c.arena.deinit();
    }
};

const lifecycle = vtab.Lifecycle(VTable, Cursor);

fn moduleOf(comptime rel: Relation) vtab.Module {
    const M = struct {
        fn connect(db: *Sqlite3, _: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
            const rc = vtab.declareVtab(db, comptime declText(rel));
            if (rc != RC.OK) return rc;
            const t = db.gpa.create(VTable) catch return RC.NOMEM;
            t.* = .{ .db = db };
            pp_vtab.* = &t.base;
            _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
            return RC.OK;
        }

        fn filter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*vi.Mem) i32 {
            const c = Cursor.of(cur);
            // An equality on a key column (bestIndex()): of an integer,
            // the rows of that OID; of a value of another type, every
            // row (SQLite tests the condition on each, with the column's
            // affinity); NULL none.
            c.key = null;
            var none = false;
            if (idx_num > 0 and argv.len == 1) {
                const col: usize = @intCast(idx_num - 1);
                const m = argv[0];
                switch (api.valueType(m)) {
                    vi.SQLITE_INTEGER => c.key = .{ .col = col, .value = api.valueInt64(m) },
                    vi.SQLITE_FLOAT => {
                        const f = api.valueDouble(m);
                        if (@floor(f) == f and @abs(f) < 1e18) c.key = .{ .col = col, .value = @intFromFloat(f) } else if (!std.math.isNan(f)) none = true;
                    },
                    vi.SQLITE_NULL => none = true,
                    else => {},
                }
            }
            // The new snapshot taken before the old is let go: the rows
            // read stay while the statement holds one (release()), for
            // a nested loop's scans.
            const old = c.snap;
            defer if (old) |s| release(c.db, s);
            c.snap = null;
            _ = c.arena.reset(.retain_capacity);
            c.i = 0;
            c.cells = &.{};
            c.head = rel.static;
            c.ncol = rel.cols.len;
            if (none) {
                c.head = &.{};
                return RC.OK;
            }
            c.snap = get(c.db, rel.any) catch |err| return switch (err) {
                error.OutOfMemory => RC.NOMEM,
                error.Failed => blk: {
                    vtab.setErrMsg(c.db, cur.vtab, "xqlite: cannot read the catalog", .{});
                    break :blk RC.ERROR;
                },
            };
            if (c.snap) |s| c.cells = s.rowsOf(rel) catch return RC.NOMEM;
            c.seek();
            return RC.OK;
        }

        /// An equality on a key column (Relation.keys) picks the rows:
        /// its value is filter()'s argument (the condition still tested
        /// by SQLite). The estimates: the system rows and some.
        fn bestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
            const all: f64 = @floatFromInt(rel.static.len / rel.cols.len + 100);
            info.estimated_cost = all;
            info.estimated_rows = @intFromFloat(all);
            if (rel.keys.len == 0) return RC.OK;
            var best: ?usize = null;
            var best_key: usize = rel.keys.len;
            for (info.constraints, 0..) |cons, i| {
                if (!cons.usable or cons.op != vtab.INDEX_CONSTRAINT.EQ or cons.i_column < 0) continue;
                for (rel.keys, 0..) |k, j| if (k.col == cons.i_column and j < best_key) {
                    best = i;
                    best_key = j;
                };
            }
            const i = best orelse return RC.OK;
            const k = rel.keys[best_key];
            info.usage[i].argv_index = 1;
            info.idx_num = @as(i32, k.col) + 1;
            info.estimated_rows = k.rows;
            // Each row tested by the cursor, not by SQLite's loop.
            info.estimated_cost = @as(f64, @floatFromInt(k.rows)) + all / 50;
            if (k.unique) info.idx_flags |= vtab.INDEX_SCAN_UNIQUE;
            return RC.OK;
        }

        /// The snapshot, null where `any` says there is no row (and no
        /// current snapshot is kept, which would say it as well).
        fn get(db: *Sqlite3, any: ?*const fn (db: *Sqlite3) bool) Error!?*Snapshot {
            try loadSchema(db);
            if (any) |f| if (currentSnapshot(db) == null and !f(db)) return null;
            return try acquireLoaded(db);
        }
    };
    return .{
        .i_version = 0,
        .x_connect = M.connect,
        .x_best_index = M.bestIndex,
        .x_disconnect = lifecycle.disconnect,
        .x_open = lifecycle.open,
        .x_close = lifecycle.close,
        .x_filter = M.filter,
        .x_next = next,
        .x_eof = eof,
        .x_column = column,
        .x_rowid = rowid,
    };
}

fn next(cur: *vtab.VtabCursor) i32 {
    const c = Cursor.of(cur);
    c.i += 1;
    c.seek();
    return RC.OK;
}

fn eof(cur: *vtab.VtabCursor) bool {
    return Cursor.of(cur).eof();
}

fn column(cur: *vtab.VtabCursor, ctx: *Context, i: i32) i32 {
    const c = Cursor.of(cur);
    const k = c.i * c.ncol + @as(usize, @intCast(i));
    switch (c.cellAt(k)) {
        .null => api.resultNull(ctx),
        .int => |v| api.resultInt64(ctx, v),
        .float => |v| api.resultDouble(ctx, v),
        .text => |z| api.resultText(ctx, z, .static),
        .lazy => |l| {
            const e = c.snap.?.expr(l.expr) catch return RC.NOMEM;
            switch (l.what) {
                .bin => api.resultText(ctx, e.bin, .static),
                .keys => if (e.keys_text) |z| api.resultText(ctx, z, .static) else api.resultNull(ctx),
            }
        },
    }
    return RC.OK;
}

fn rowid(cur: *vtab.VtabCursor, id: *i64) i32 {
    id.* = @intCast(Cursor.of(cur).i + 1);
    return RC.OK;
}

const module_list = blk: {
    var ms: [relations.len]vtab.Module = undefined;
    for (relations, 0..) |r, i| ms[i] = moduleOf(r);
    const final = ms;
    break :blk final;
};

pub const modules = blk: {
    var out: [relations.len]dialect.EngineModule = undefined;
    for (relations, 0..) |r, i| out[i] = .{ .name = r.name, .module = &module_list[i], .column_types = columnTypes(r) };
    const final = out;
    break :blk final;
};

test "pg_types: each type and its array are the catalog's" {
    for (std.enums.values(ctypes.Logical)) |l| {
        if (l == .array) continue;
        const o = pg_types.ofType(.{ .logical = l });
        const bt = builtinType(o) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(bt.array, pg_types.arrayOf(o) orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(bt.array, pg_types.ofType(.{ .logical = .array, .element = l }));
    }
}

test "oids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try assign(a, 'r', &.{ "main\x00t", "main\x00u", "main\x00t" });
    // Five digits, as PostgreSQL's first OIDs.
    try std.testing.expect(o[0] >= first_user_oid and o[0] < 100_000);
    try std.testing.expect(o[0] != o[2]);
    try std.testing.expectEqual(o[0], hashOid('r', "main\x00t", small_first, small_span));
    try std.testing.expect(o[2] >= large_first);
    const checks = try tableChecks(a, "CREATE TABLE \"t\"(\"a\" INTEGER CONSTRAINT \"integer out of range\" CHECK((\"a\" > 0)), \"b\" TEXT CHECK(b<>''), CHECK(a < 9), CONSTRAINT \"ck\" CHECK((\"a\" <> 3)))", "t");
    try std.testing.expectEqual(@as(usize, 4), checks.len);
    try std.testing.expectEqualStrings("integer out of range", checks[0].name);
    try std.testing.expectEqualStrings("t_b_check", checks[1].name);
    try std.testing.expectEqualStrings("b<>''", checks[1].text);
    try std.testing.expectEqualStrings("t_check", checks[2].name);
    try std.testing.expectEqualStrings("ck", checks[3].name);
    try std.testing.expectEqualStrings("(a <> 3)", try pgText(a, checks[3].text, &.{}));
    try std.testing.expectEqualStrings("(\"Big\" = \"select\")", try pgText(a, "(\"Big\" = \"select\")", &.{}));
    const items = try indexItems(a, "CREATE INDEX \"i\" ON \"t\"((lower(\"b\")), \"a\" DESC) WHERE (\"a\" > 5)");
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("lower(\"b\")", stripParens(items[0]));
    try std.testing.expectEqualStrings("(\"a\" > 5)", (try whereOf(a, "CREATE INDEX \"i\" ON \"t\"((lower(\"b\")), \"a\" DESC) WHERE (\"a\" > 5)")).?);
    try std.testing.expect(try looksLikeCall(a, "lower(b)"));
    try std.testing.expect(!try looksLikeCall(a, "(a + 1)"));
    // Of each generated column, the first AS of its own definition.
    const gs = try generatedTexts(a, "CREATE TABLE t(a INT, \"B\" INT GENERATED ALWAYS AS ((a * 2)) STORED, c TEXT AS (lower(x)) VIRTUAL, d INT AS e, f INT AS ( g ))");
    try std.testing.expectEqualStrings("(a * 2)", generatedOf(gs, "b").?);
    try std.testing.expectEqualStrings("lower(x)", generatedOf(gs, "C").?);
    try std.testing.expect(generatedOf(gs, "d") == null);
    try std.testing.expectEqualStrings("g", generatedOf(gs, "f").?);
    try std.testing.expect(generatedOf(gs, "a") == null);
}

test "oids: only colliding keys move, by their order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    for (0..5000) |i| try keys.append(a, try std.fmt.allocPrint(a, "main\x00t{d}", .{4999 - i}));
    const o = try assign(a, 'r', keys.items);
    // Each number once; a key keeps its own number unless a smaller key
    // has it, and those that move are above the five digits.
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var moved: usize = 0;
    for (keys.items, o) |k, x| {
        try std.testing.expect(!(try seen.getOrPut(a, x)).found_existing);
        const own = hashOid('r', k, small_first, small_span);
        if (x == own) continue;
        moved += 1;
        try std.testing.expect(x >= large_first);
        const holder = for (keys.items, o) |k2, x2| {
            if (x2 == own) break k2;
        } else unreachable;
        try std.testing.expect(std.mem.lessThan(u8, holder, k));
    }
    try std.testing.expect(moved > 0 and moved < 500);
    // In any order of the keys, the same numbers.
    std.mem.reverse([]const u8, keys.items);
    const r = try assign(a, 'r', keys.items);
    for (o, 0..) |x, i| try std.testing.expectEqual(x, r[keys.items.len - 1 - i]);
    // A repeated key: the later moves, no other key does.
    try keys.append(a, keys.items[0]);
    const d = try assign(a, 'r', keys.items);
    try std.testing.expectEqualSlices(u32, r, d[0..r.len]);
    try std.testing.expect(d[r.len] >= large_first);
}

test "SQLite text: numbers end as SQLite's tokenizer ends them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const texts = [_][]const u8{ "1.5e-3", "2.5E+3", ".5", "1_000", "0x1F", "12", "3.", "1e", "1abc" };
    const ends = [_]usize{ 6, 6, 2, 5, 4, 2, 2, 2, 4 };
    for (texts, ends) |z, e| {
        var s = try Scanner.init(a, z);
        const t = s.next();
        try std.testing.expectEqual(.number, t.kind);
        try std.testing.expectEqual(e, t.end);
    }
    // Not an exponent: 1e is a (bad) number, then - and 3.
    var s = try Scanner.init(a, "1e-x");
    try std.testing.expectEqualStrings("1e", s.next().text);
    try std.testing.expectEqualStrings("-", s.next().text);
    // A bounded slice: the scan stops at its end.
    s = try Scanner.init(a, "12e+5"[0..3]);
    try std.testing.expectEqualStrings("12e", s.next().text);
    try std.testing.expectEqual(.eof, s.next().kind);
}

test "SQLite text: tokens end where SQLite's tokenizer ends them" {
    // Random text of the characters the rules are about; at each word,
    // quoted name, string and number the scanner reads, SQLite's
    // tokenizer (sqlite3GetToken()) started there ends at the same place.
    const getToken = @import("../sqlite/lexer.zig").getToken;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alphabet = [_][]const u8{ "a", "Z", "_", "$", "x", "e", "E", "0", "1", "9", ".", "_", "+", "-", " ", "\n", "'", "\"", "`", "[", "]", "(", "*", "/", "\xc3\xa9", "0x", "--", "/*", "*/", "''" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    for (0..20000) |_| {
        buf.clearRetainingCapacity();
        for (0..r.intRangeAtMost(usize, 1, 12)) |_| try buf.appendSlice(a, alphabet[r.uintLessThan(usize, alphabet.len)]);
        var s = try Scanner.init(a, buf.items);
        while (true) {
            const t = s.next();
            if (t.kind == .eof) break;
            if (t.kind == .punct) continue;
            // x'..' is a blob literal to SQLite, a word and a string here.
            if (t.kind == .word and t.text.len == 1 and (t.text[0] == 'x' or t.text[0] == 'X') and s.z[t.end] == '\'') continue;
            const n = getToken(s.z, t.start).len;
            if (n != t.end - t.start) {
                std.debug.print("{f}: {s} at {d}: SQLite {d}, here {d}\n", .{ std.zig.fmtString(buf.items), @tagName(t.kind), t.start, n, t.end - t.start });
                return error.TestExpectedEqual;
            }
        }
    }
}
