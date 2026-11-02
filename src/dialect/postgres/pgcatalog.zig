//! PostgreSQL's system catalogs, made from the schema in memory: the rows
//! of pg_namespace, pg_class, pg_attribute, pg_type, pg_index,
//! pg_constraint, pg_attrdef, pg_proc, pg_sequence and pg_depend, as
//! PostgreSQL 16 would have them for the objects of the connection's
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
//!
//! The relations are engine table-valued functions (eponymous virtual
//! tables, Hooks.engine_modules) xq_pg_class ... whose columns are
//! PostgreSQL's; catalog_views.zig's view text over each gives the
//! columns their types (`relhasindex::boolean`). Nothing is stored:
//! a database stays SQLite's, and sqlite3 never sees these names.
//!
//! OIDs. The built-in objects have PostgreSQL's (int4 23, pg_catalog 11,
//! public 2200, the pg_class relation 1259). An object of a database is
//! numbered by a hash of what names it (its database and SQLite name, a
//! constraint's table and name ...) into [16384, 2^31): no catalog row
//! is written for it, whoever made it (sqlite3, another dialect), and it
//! keeps its number across connections, VACUUM (which renumbers
//! sqlite_schema's rowids), the creation and dropping of other objects
//! and restarts, unlike a numbering by position. Two keys of one catalog
//! that hash to one number are told apart in the order of their keys
//! (the later takes the next free number), so the numbering of a set of
//! objects is a function of that set. A renamed object takes a new
//! number (PostgreSQL keeps it), and a collision is resolved again when
//! a colliding object comes or goes.

const std = @import("std");
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
pub const oid_information_schema: u32 = 13183;
pub const oid_superuser: u32 = 10;
pub const oid_default_collation: u32 = 100;
pub const oid_c_collation: u32 = 950;
pub const first_user_oid: u32 = 16384;

/// The built-in relations a reg* cast knows by name ('pg_class'::regclass
/// is 1259), PostgreSQL's numbers.
pub const builtin_relations = [_]struct { u32, []const u8 }{
    .{ 1247, "pg_type" },                  .{ 1249, "pg_attribute" },    .{ 1255, "pg_proc" },
    .{ 1259, "pg_class" },                 .{ 1260, "pg_authid" },       .{ 1262, "pg_database" },
    .{ 1213, "pg_tablespace" },            .{ 2601, "pg_am" },           .{ 2604, "pg_attrdef" },
    .{ 2606, "pg_constraint" },            .{ 2608, "pg_depend" },       .{ 2609, "pg_description" },
    .{ 2610, "pg_index" },                 .{ 2611, "pg_inherits" },     .{ 2615, "pg_namespace" },
    .{ 2618, "pg_rewrite" },               .{ 2620, "pg_trigger" },      .{ 2224, "pg_sequence" },
    .{ 3256, "pg_policy" },                .{ 3456, "pg_collation" },    .{ 2396, "pg_shdescription" },
    .{ 3381, "pg_statistic_ext" },         .{ 6104, "pg_publication" },  .{ 6106, "pg_publication_rel" },
    .{ 6237, "pg_publication_namespace" }, .{ 2612, "pg_language" },     .{ 3079, "pg_extension" },
    .{ 3501, "pg_enum" },                  .{ 1261, "pg_auth_members" },
};

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
            .cat = 'A',
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
    for (builtin_types) |*t| if (t.oid == oid) return t;
    return null;
}

/// The type OID of `t` as the wire server describes it (keep with
/// src/server/pg/values.zig's ofType(), which a test compares).
pub fn oidOfLogical(t: ctypes.Type) u32 {
    return switch (t.logical) {
        .unknown, .text => 25,
        .boolean => 16,
        .int1, .int2 => 21,
        .int4 => 23,
        .int8 => 20,
        .float4 => 700,
        .float8 => 701,
        .numeric => 1700,
        .varchar => 1043,
        .char => 1042,
        .bytes => 17,
        .date => 1082,
        .time => 1083,
        .time_tz => 1266,
        .timestamp => 1114,
        .timestamp_tz => 1184,
        .interval => 1186,
        .uuid => 2950,
        .json => 114,
        .jsonb => 3802,
    };
}

/// The type modifier (atttypmod) of `t`, as the wire server's typeMod().
pub fn typmodOfLogical(t: ctypes.Type) i32 {
    return switch (t.logical) {
        .varchar, .char => if (t.length) |n| if (n < std.math.maxInt(i32) - 4) @as(i32, @intCast(n)) + 4 else -1 else -1,
        .numeric => if (t.precision) |p| ((@as(i32, p) << 16) | (t.scale orelse 0)) + 4 else -1,
        .time, .time_tz, .timestamp, .timestamp_tz => if (t.scale) |s| s else -1,
        else => -1,
    };
}

/// The type of a column declared `decl` in `d`: its OID and modifier.
pub fn columnType(d: dialect.Dialect, decl: []const u8) struct { u32, i32 } {
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, decl.len)], decl[0..@min(buf.len, decl.len)]);
    const trimmed = std.mem.trim(u8, lower, " ");
    // The names no types.Logical stands for.
    const named = [_]struct { []const u8, u32 }{
        .{ "oid", 26 },     .{ "name", 19 }, .{ "\"char\"", 18 }, .{ "regclass", 2205 }, .{ "regtype", 2206 },
        .{ "regproc", 24 }, .{ "xid", 28 },  .{ "inet", 869 },    .{ "money", 790 },     .{ "jsonpath", 4072 },
    };
    if (d == .postgres) for (named) |n| if (eql(n[0], trimmed)) return .{ n[1], -1 };
    const t = ctypes.parse(d, decl);
    return .{ oidOfLogical(t), typmodOfLogical(t) };
}

// ================================================================= OIDs

/// The number of `key` in catalog `cat` before collisions.
fn hashOid(cat: u8, key: []const u8) u32 {
    var h = std.hash.Wyhash.init(cat);
    h.update(key);
    const span: u64 = 0x7fffffff - first_user_oid;
    return @intCast(first_user_oid + h.final() % span);
}

/// The OIDs of `keys` in catalog `cat` (see the top of the file).
fn assign(a: Allocator, cat: u8, keys: []const []const u8) Oom![]u32 {
    const order = try a.alloc(u32, keys.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, keys, struct {
        fn lt(k: []const []const u8, x: u32, y: u32) bool {
            return std.mem.order(u8, k[x], k[y]) == .lt;
        }
    }.lt);
    const out = try a.alloc(u32, keys.len);
    var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (order) |i| {
        var o = hashOid(cat, keys[i]);
        while (used.contains(o)) o = if (o == 0x7ffffffe) first_user_oid else o + 1;
        try used.put(a, o, {});
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
    natts: i16 = 0,
    checks: i16 = 0,
    has_index: bool = false,
    has_triggers: bool = false,
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
    /// Each column's definition, as pg_get_indexdef(oid, n) gives it.
    coldefs: []const []const u8,
    /// The expressions (indexprs) and the predicate (indpred), as text.
    exprs: ?[]const u8 = null,
    pred: ?[]const u8 = null,
};

pub const Con = struct {
    oid: u32,
    name: []const u8,
    nsp: u32,
    /// 'p', 'u', 'f', 'c'.
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
    /// A CHECK's expression (conbin, as text).
    bin: ?[]const u8 = null,
};

pub const Def = struct { oid: u32, rel: u32, num: i16, bin: []const u8 };

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
    by_oid: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn rel(s: *const Snapshot, oid: u32) ?*const Rel {
        const i = s.by_oid.get(oid) orelse return null;
        return &s.rels[i];
    }

    pub fn nsp(s: *const Snapshot, oid: u32) ?*const Nsp {
        for (s.nsps) |*n| if (n.oid == oid) return n;
        return null;
    }

    pub fn nspByName(s: *const Snapshot, name: []const u8) ?*const Nsp {
        for (s.nsps) |*n| if (eql(n.name, name)) return n;
        return null;
    }

    pub fn relByName(s: *const Snapshot, nsp_oid: u32, name: []const u8) ?*const Rel {
        for (s.rels) |*r| if (r.nsp == nsp_oid and eql(r.name, name)) return r;
        return null;
    }

    pub fn con(s: *const Snapshot, oid: u32) ?*const Con {
        for (s.cons) |*c| if (c.oid == oid) return c;
        return null;
    }

    pub fn index(s: *const Snapshot, oid: u32) ?*const IndexRow {
        for (s.indexes) |*x| if (x.rel == oid) return x;
        return null;
    }

    /// The attribute `num` of relation `rel`.
    pub fn attr(s: *const Snapshot, rel_oid: u32, num: i16) ?*const Attr {
        for (s.attrs) |*x| if (x.rel == rel_oid and x.num == num) return x;
        return null;
    }

    pub fn def(s: *const Snapshot, rel_oid: u32, num: i16) ?*const Def {
        for (s.defs) |*x| if (x.rel == rel_oid and x.num == num) return x;
        return null;
    }

    /// The temporary schema, if there is one.
    pub fn tempNsp(s: *const Snapshot) ?*const Nsp {
        for (s.nsps) |*n| if (n.db) |d| if (eql(d, "temp")) return n;
        return null;
    }
};

pub const Error = Oom || error{Failed};

/// The cache of the connection: State.catalog.
pub fn release(db: *Sqlite3, s: *Snapshot) void {
    releaseGpa(db.gpa, s);
}

fn releaseGpa(gpa: Allocator, s: *Snapshot) void {
    s.refs -= 1;
    if (s.refs == 0) {
        s.arena.deinit();
        gpa.destroy(s);
    }
}

fn keyOf(db: *Sqlite3, a: Allocator) Oom![]usize {
    var k: std.ArrayList(usize) = .empty;
    try k.append(a, @bitCast(@as(isize, @intCast(db.n_total_change))));
    for (db.dbs.items) |d| {
        try k.append(a, @intFromPtr(d.schema));
        try k.append(a, @as(u32, @bitCast(d.schema.schema_cookie)));
        try k.append(a, @as(u32, @bitCast(d.schema.i_generation)));
        try k.append(a, @intFromBool(d.schema.schema_flags.SchemaLoaded));
    }
    return k.items;
}

/// The snapshot of the connection's catalogs: the one kept if nothing
/// changed since, else a new one (kept in its place). release() it.
pub fn acquire(db: *Sqlite3) Error!*Snapshot {
    var err: ?[:0]u8 = null;
    const rc = prepare.init(db, &err);
    if (err) |m| db.gpa.free(m);
    if (rc == int.RC.NOMEM) return error.OutOfMemory;
    if (rc != int.RC.OK) return error.Failed;
    const st = &db.xq.postgres;
    var tmp: std.heap.ArenaAllocator = .init(db.gpa);
    defer tmp.deinit();
    const key = try keyOf(db, tmp.allocator());
    if (st.catalog) |p| {
        const c: *Snapshot = @ptrCast(@alignCast(p));
        if (std.mem.eql(usize, c.key, key)) {
            c.refs += 1;
            return c;
        }
        st.catalog = null;
        release(db, c);
    }
    const s = try db.gpa.create(Snapshot);
    s.* = .{ .arena = .init(db.gpa) };
    errdefer {
        s.arena.deinit();
        db.gpa.destroy(s);
    }
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

// ============================================================= building

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
    /// The tables to describe once every relation has its OID.
    tables: std.ArrayList(TableWork) = .empty,
    registered: []const nsp_mod.Info = &.{},

    const TableWork = struct {
        rel: usize,
        db: []const u8,
        /// The index of the INTEGER PRIMARY KEY, if any.
        ipk: ?usize = null,
        /// The indexes of the table, by SQLite name, to their Rel.
        indexes: []const struct { name: []const u8, rel: usize } = &.{},
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
        var type_keys: std.ArrayList([]const u8) = .empty;
        var typed: std.ArrayList(usize) = .empty;
        for (b.rels.items, 0..) |r, i| {
            if (r.kind == 'i') continue;
            try type_keys.append(a, b.rel_keys.items[i]);
            try typed.append(a, i);
        }
        const toids = try assign(a, 't', type_keys.items);
        for (typed.items, toids) |i, o| b.rels.items[i].rowtype = o;

        for (b.tables.items) |w| try b.describe(w);
        const coids = try assign(a, 'c', b.con_keys.items);
        for (b.cons.items, coids) |*c, o| c.oid = o;
        const doids = try assign(a, 'd', b.def_keys.items);
        for (b.defs.items, doids) |*x, o| x.oid = o;

        // Ordered by schema and name, as a client lists them anyway.
        const Ctx = struct {
            fn lt(_: void, x: Rel, y: Rel) bool {
                if (x.nsp != y.nsp) return x.nsp < y.nsp;
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        };
        std.mem.sort(Rel, b.rels.items, {}, Ctx.lt);
        const s = b.s;
        s.nsps = b.nsps.items;
        s.rels = b.rels.items;
        s.attrs = b.attrs.items;
        s.indexes = b.indexes.items;
        s.cons = b.cons.items;
        s.defs = b.defs.items;
        s.deps = b.deps.items;
        s.descs = b.descs.items;
        for (s.rels, 0..) |r, i| try s.by_oid.put(a, r.oid, @intCast(i));
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

    fn relOf(b: *Builder, db_name: []const u8, sqlite_name: []const u8, kind: u8) ?*Rel {
        for (b.rels.items) |*r| if (r.kind == kind and eql(r.db, db_name) and std.ascii.eqlIgnoreCase(r.sqlite_name, sqlite_name)) return r;
        return null;
    }

    fn tableRel(b: *Builder, db_name: []const u8, sqlite_name: []const u8) ?*Rel {
        for (b.rels.items) |*r| if ((r.kind == 'r' or r.kind == 'v') and eql(r.db, db_name) and std.ascii.eqlIgnoreCase(r.sqlite_name, sqlite_name)) return r;
        return null;
    }

    /// The attributes, indexes, constraints and defaults of a table (or
    /// the attributes of a view).
    fn describe(b: *Builder, w: TableWork) Error!void {
        const a = b.a;
        const r = &b.rels.items[w.rel];
        const t = build.findTable(b.db, r.sqlite_name, if (eql(w.db, "temp")) "temp" else w.db) orelse return;
        if (t.isView()) {
            try b.viewColumns(w, r, t);
            const vm = catalog.meta(b.db, if (eql(w.db, "temp")) "temp" else w.db, t.name) catch |e| return mapErr(e);
            return b.comments(vm, r.oid);
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
        const pk = build.primaryKeyIndex(t);
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
                const text = std.mem.sliceTo(e.token(), 0);
                const bin = try defaultText(a, text, ty[0], generated, b.registered);
                at.hasdef = true;
                try b.defs.append(a, .{ .oid = 0, .rel = r.oid, .num = num, .bin = bin });
                try b.def_keys.append(a, try std.fmt.allocPrint(a, "{s}\x00{d}", .{ key, num }));
            };
            try b.attrs.append(a, at);
        }
        // The INTEGER PRIMARY KEY's index and constraint.
        if (w.ipk) |ii| {
            const ir = &b.rels.items[ii];
            const num: i16 = t.i_pkey + 1;
            ir.natts = 1;
            const col = try quoteIdent(a, t.cols[@intCast(t.i_pkey)].name());
            const ty = if (b.attrOf(r.oid, num)) |x| x.type_oid else 20;
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
            var exprs: std.ArrayList(u8) = .empty;
            for (0..n) |k| {
                const c = x.ai_column[k];
                desc[k] = k < x.sort_order.len and x.sort_order[k] != 0;
                var attname: []const u8 = undefined;
                var type_oid: u32 = 25;
                if (c >= 0) {
                    keys[k] = c + 1;
                    attname = t.cols[@intCast(c)].name();
                    coldefs[k] = try quoteIdent(a, attname);
                    if (b.attrOf(r.oid, keys[k])) |at| type_oid = at.type_oid;
                } else if (c == int.XN_ROWID) {
                    keys[k] = 0;
                    attname = "rowid";
                    coldefs[k] = "rowid";
                    type_oid = 20;
                } else {
                    keys[k] = 0;
                    const item = if (k < items.len) items[k] else "?";
                    const e = try pgText(a, stripParens(stripOrder(item)), b.registered);
                    attname = exprName(e);
                    coldefs[k] = if (looksLikeCall(e)) e else try std.fmt.allocPrint(a, "({s})", .{e});
                    if (exprs.items.len > 0) try exprs.appendSlice(a, ", ");
                    try exprs.appendSlice(a, e);
                }
                if (desc[k]) coldefs[k] = try std.fmt.allocPrint(a, "{s} DESC", .{coldefs[k]});
                try b.attrs.append(a, .{ .rel = ir.oid, .name = try a.dupe(u8, attname), .num = @intCast(k + 1), .type_oid = type_oid });
            }
            const pred: ?[]const u8 = if (ir.sql) |z| if (whereOf(z)) |wz| try pgText(a, stripParens(wz), b.registered) else null else null;
            try b.indexes.append(a, .{
                .rel = ir.oid,
                .table = r.oid,
                .unique = x.isUnique(),
                .primary = x.idx_type == .primarykey,
                .keys = keys,
                .desc = desc,
                .coldefs = coldefs,
                .exprs = if (exprs.items.len > 0) exprs.items else null,
                .pred = pred,
            });
            if (x.idx_type == .primarykey or x.idx_type == .unique) {
                try b.addCon(key, .{ .oid = 0, .name = ir.name, .nsp = r.nsp, .type = if (x.idx_type == .primarykey) 'p' else 'u', .rel = r.oid, .index = ir.oid, .keys = try a.dupe(i16, keys) });
            }
        }
        _ = pk;
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
        for (checks) |c| {
            try b.addCon(key, .{ .oid = 0, .name = c.name, .nsp = r.nsp, .type = 'c', .rel = r.oid, .bin = try pgText(a, c.text, b.registered) });
        }
        try b.comments(m, r.oid);
    }

    /// The comments of COMMENT ON on relation `rel_oid` and its columns.
    fn comments(b: *Builder, m: ?*const catalog.TableMeta, rel_oid: u32) Oom!void {
        const x = m orelse return;
        for (x.entries) |e| {
            if (!eql(e.key, comment_key)) continue;
            var subid: i32 = 0;
            if (e.col.len > 0) {
                subid = -1;
                for (b.attrs.items) |at| if (at.rel == rel_oid and std.ascii.eqlIgnoreCase(at.name, e.col)) {
                    subid = at.num;
                };
                if (subid < 0) continue;
            }
            try b.descs.append(b.a, .{ .obj = rel_oid, .subid = subid, .text = try b.a.dupe(u8, e.value) });
        }
    }

    fn attrOf(b: *Builder, rel_oid: u32, num: i16) ?*const Attr {
        for (b.attrs.items) |*x| if (x.rel == rel_oid and x.num == num) return x;
        return null;
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
            const ty = if (known) |k| .{ oidOfLogical(k), typmodOfLogical(k) } else if (decl.len == 0) .{ @as(u32, 25), @as(i32, -1) } else columnType(.postgres, decl);
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
const Tok = struct {
    kind: enum { word, quoted, string, number, punct, eof },
    text: []const u8,
    start: usize,
    end: usize,
};

const Scanner = struct {
    z: []const u8,
    i: usize = 0,

    fn next(s: *Scanner) Tok {
        const z = s.z;
        while (s.i < z.len) {
            if (std.ascii.isWhitespace(z[s.i])) {
                s.i += 1;
            } else if (z[s.i] == '-' and s.i + 1 < z.len and z[s.i + 1] == '-') {
                while (s.i < z.len and z[s.i] != '\n') s.i += 1;
            } else if (z[s.i] == '/' and s.i + 1 < z.len and z[s.i + 1] == '*') {
                s.i += 2;
                while (s.i + 1 < z.len and !(z[s.i] == '*' and z[s.i + 1] == '/')) s.i += 1;
                s.i = @min(z.len, s.i + 2);
            } else break;
        }
        const start = s.i;
        if (s.i >= z.len) return .{ .kind = .eof, .text = "", .start = start, .end = start };
        const c = z[s.i];
        switch (c) {
            '\'', '"', '`' => {
                s.i += 1;
                while (s.i < z.len) : (s.i += 1) {
                    if (z[s.i] == c) {
                        if (s.i + 1 < z.len and z[s.i + 1] == c) {
                            s.i += 1;
                            continue;
                        }
                        s.i += 1;
                        break;
                    }
                }
                return .{ .kind = if (c == '\'') .string else .quoted, .text = z[start..s.i], .start = start, .end = s.i };
            },
            '[' => {
                while (s.i < z.len and z[s.i] != ']') s.i += 1;
                s.i = @min(z.len, s.i + 1);
                return .{ .kind = .quoted, .text = z[start..s.i], .start = start, .end = s.i };
            },
            else => {},
        }
        if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) {
            while (s.i < z.len and (std.ascii.isAlphanumeric(z[s.i]) or z[s.i] == '_' or z[s.i] == '$' or z[s.i] >= 0x80)) s.i += 1;
            return .{ .kind = .word, .text = z[start..s.i], .start = start, .end = s.i };
        }
        if (std.ascii.isDigit(c)) {
            while (s.i < z.len and (std.ascii.isAlphanumeric(z[s.i]) or z[s.i] == '.')) s.i += 1;
            return .{ .kind = .number, .text = z[start..s.i], .start = start, .end = s.i };
        }
        s.i += 1;
        return .{ .kind = .punct, .text = z[start..s.i], .start = start, .end = s.i };
    }
};

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
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (z) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.items;
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
    var s: Scanner = .{ .z = z };
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

/// The text of a default (or generated column's) expression as
/// pg_get_expr() shows it: now() for SQLite's rendering of it, a string
/// constant cast to the column's type ('x'::text), a negative integer
/// quoted ('-1'::integer), nextval()'s argument a regclass.
fn defaultText(a: Allocator, text: []const u8, type_oid: u32, generated: bool, registered: []const nsp_mod.Info) Oom![]const u8 {
    const z = std.mem.trim(u8, text, " ");
    if (generated) return pgText(a, z, registered);
    if (eql(z, "strftime('%Y-%m-%d %H:%M:%f', 'now')") or std.ascii.eqlIgnoreCase(z, "CURRENT_TIMESTAMP")) return "now()";
    if (eql(z, "date('now')") or std.ascii.eqlIgnoreCase(z, "CURRENT_DATE")) return "CURRENT_DATE";
    if (std.mem.startsWith(u8, z, "nextval('") and std.mem.endsWith(u8, z, "')")) {
        return std.fmt.allocPrint(a, "{s}'::regclass)", .{z[0 .. z.len - 2]});
    }
    const tname: []const u8 = if (builtinType(type_oid)) |t| t.fmt else "text";
    if (z.len >= 2 and z[0] == '\'' and z[z.len - 1] == '\'') {
        // One string constant.
        var s: Scanner = .{ .z = z };
        const t = s.next();
        if (t.end == z.len) return std.fmt.allocPrint(a, "{s}::{s}", .{ z, tname });
    }
    if (z.len > 1 and z[0] == '-' and std.ascii.isDigit(z[1])) {
        var digits = true;
        for (z[1..]) |c| digits = digits and (std.ascii.isDigit(c) or c == '.');
        if (digits) return std.fmt.allocPrint(a, "'{s}'::{s}", .{ z, tname });
    }
    return pgText(a, z, registered);
}

const Check = struct { name: []const u8, text: []const u8 };

/// The CHECK constraints of CREATE TABLE text `sql` (table `table`): the
/// name of each (CONSTRAINT x, else PostgreSQL's <table>_<column>_check
/// for a column's, <table>_check for the table's) and its expression's
/// text.
fn tableChecks(a: Allocator, sql: []const u8, table: []const u8) Oom![]Check {
    var out: std.ArrayList(Check) = .empty;
    var s: Scanner = .{ .z = sql };
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
    var s: Scanner = .{ .z = sql };
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
fn whereOf(sql: []const u8) ?[]const u8 {
    var s: Scanner = .{ .z = sql };
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
fn looksLikeCall(e: []const u8) bool {
    var s: Scanner = .{ .z = e };
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
fn exprName(e: []const u8) []const u8 {
    if (!looksLikeCall(e)) return "expr";
    var s: Scanner = .{ .z = e };
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
};

/// A column of a catalog relation: its name and PostgreSQL type, which
/// catalog_views.zig's text casts it to.
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

    /// The SQLite type of the virtual table's column.
    pub fn sqlite(t: Type) []const u8 {
        return switch (t) {
            .name, .text, .char => "TEXT",
            .float4 => "REAL",
            else => "INTEGER",
        };
    }

    /// The cast of catalog_views.zig's text ("" for none).
    pub fn cast(t: Type) []const u8 {
        return switch (t) {
            .oid => "::oid",
            .name => "::name",
            .bool => "::boolean",
            .int2 => "::smallint",
            .int4 => "::integer",
            .int8 => "::bigint",
            .float4 => "::real",
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

fn vector(a: Allocator, xs: anytype, comptime braces: bool) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (braces) try out.append(a, '{');
    for (xs, 0..) |x, i| {
        if (i > 0) try out.append(a, if (braces) ',' else ' ');
        try out.print(a, "{d}", .{x});
    }
    if (braces) try out.append(a, '}');
    return out.items;
}

pub const Relation = struct {
    name: [:0]const u8,
    cols: []const Col,
    fill: *const fn (s: *const Snapshot, r: *Rows) Oom!void,
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
    for (s.rels) |x| try r.row(.{
        x.oid,       x.name, x.nsp,               x.rowtype,    0,       oid_superuser, relam(x.kind), x.oid,          0,     0,     @as(f64, -1), 0,    0,
        x.has_index, false,  char(x.persistence), char(x.kind), x.natts, x.checks,      false,         x.has_triggers, false, false, false,        true, char(if (x.kind == 'r') 'd' else 'n'),
        false,       0,      "0",                 "1",          null,    null,          null,
    });
}

fn fillAttribute(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.attrs) |x| {
        const t = builtinType(x.type_oid);
        try r.row(.{
            x.rel,                         x.name,                               x.type_oid,                          -1,          if (t) |b| b.len else -1, x.num,    0,     -1,               x.typmod,
            if (t) |b| b.byval else false, char(if (t) |b| b.@"align" else 'i'), char(if (t) |b| b.storage else 'x'), char(0),     x.notnull,                x.hasdef, false, char(x.identity), char(x.generated),
            false,                         true,                                 0,                                   x.collation, null,                     null,     null,  null,
        });
    }
}

fn procOf(a: Allocator, stem: []const u8, suffix: []const u8) Oom![]const u8 {
    if (stem.len == 0) return "-";
    if (stem[stem.len - 1] == '_') return std.fmt.allocPrint(a, "{s}{s}", .{ stem[0 .. stem.len - 1], if (eql(suffix, "in")) "_in" else if (eql(suffix, "out")) "_out" else if (eql(suffix, "recv")) "_recv" else "_send" });
    return std.fmt.allocPrint(a, "{s}{s}", .{ stem, suffix });
}

fn fillType(s: *const Snapshot, r: *Rows) Oom!void {
    const a = r.a;
    for (builtin_types) |t| {
        try r.row(.{
            t.oid,                                                                                  t.name, oid_pg_catalog, oid_superuser,             t.len,                      t.byval,                     char(t.typtype),             char(t.cat),                                                                  t.preferred,                                                                   true, ",",              0,
            if (t.cat == 'A' and t.elem != 0 and t.io.len == 6) "array_subscript_handler" else "-", t.elem, t.array,        try procOf(a, t.io, "in"), try procOf(a, t.io, "out"), try procOf(a, t.io, "recv"), try procOf(a, t.io, "send"), if (t.modin.len > 0) try std.fmt.allocPrint(a, "{s}in", .{t.modin}) else "-", if (t.modin.len > 0) try std.fmt.allocPrint(a, "{s}out", .{t.modin}) else "-", "-",  char(t.@"align"), char(t.storage),
            false,                                                                                  0,      -1,             0,                         t.coll,                     null,                        null,                        null,
        });
    }
    for (s.rels) |x| {
        if (x.rowtype == 0) continue;
        try r.row(.{
            x.rowtype,   x.name,       x.nsp,         oid_superuser, -1,  false, "c", "C", false, true,  ",", x.oid, "-", 0, 0,
            "record_in", "record_out", "record_recv", "record_send", "-", "-",   "-", "d", "x",   false, 0,   -1,    0,   0, null,
            null,        null,
        });
    }
}

fn fillIndex(s: *const Snapshot, r: *Rows) Oom!void {
    const a = r.a;
    for (s.indexes) |x| {
        const n = x.keys.len;
        const opts = try a.alloc(i16, n);
        for (opts, x.desc) |*o, d| o.* = if (d) 3 else 0;
        const colls = try a.alloc(u32, n);
        for (colls, x.keys) |*c, k| c.* = if (k > 0) (if (s.attr(x.table, k)) |at| at.collation else 0) else 0;
        const classes = try a.alloc(u32, n);
        @memset(classes, 0);
        try r.row(.{
            x.rel,                        x.table,                     n,                             n,                          x.unique, false,  x.primary, false, true, false, true, false, true, true, false,
            try vector(a, x.keys, false), try vector(a, colls, false), try vector(a, classes, false), try vector(a, opts, false), x.exprs,  x.pred,
        });
    }
}

fn fillConstraint(s: *const Snapshot, r: *Rows) Oom!void {
    const a = r.a;
    for (s.cons) |c| {
        try r.row(.{
            c.oid,       c.name,      c.nsp,                                 char(c.type), c.deferrable, c.deferred, true,                                                      c.rel,                                                       0,    c.index, 0,    c.frel,
            char(c.upd), char(c.del), char(if (c.type == 'f') 's' else ' '), true,         0,            false,      if (c.keys.len > 0) try vector(a, c.keys, true) else null, if (c.fkeys.len > 0) try vector(a, c.fkeys, true) else null, null, null,    null, null,
            null,        c.bin,
        });
    }
}

fn fillAttrdef(s: *const Snapshot, r: *Rows) Oom!void {
    for (s.defs) |d| try r.row(.{ d.oid, d.rel, d.num, d.bin });
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
    for (s.descs) |d| try r.row(.{ d.obj, 1259, d.subid, d.text });
}

fn fillProc(s: *const Snapshot, r: *Rows) Oom!void {
    _ = s;
    const a = r.a;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (builtin_types) |t| {
        for ([_][]const u8{ "in", "out", "recv", "send" }) |suffix| {
            const name = try procOf(a, t.io, suffix);
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
    return hashOid('p', name);
}

/// The name of a built-in function by its OID, for regproc's output.
pub fn procName(a: Allocator, oid: u32) Oom!?[]const u8 {
    for (builtin_types) |t| {
        for ([_][]const u8{ "in", "out", "recv", "send" }) |suffix| {
            const name = try procOf(a, t.io, suffix);
            if (procOid(name) == oid) return name;
        }
    }
    return null;
}

pub const relations = [_]Relation{
    .{ .name = "xq_pg_namespace", .fill = fillNamespace, .cols = &.{
        .{ "oid", .oid }, .{ "nspname", .name }, .{ "nspowner", .oid }, .{ "nspacl", .text },
    } },
    .{ .name = "xq_pg_class", .fill = fillClass, .cols = &.{
        .{ "oid", .oid },             .{ "relname", .name },        .{ "relnamespace", .oid },    .{ "reltype", .oid },
        .{ "reloftype", .oid },       .{ "relowner", .oid },        .{ "relam", .oid },           .{ "relfilenode", .oid },
        .{ "reltablespace", .oid },   .{ "relpages", .int4 },       .{ "reltuples", .float4 },    .{ "relallvisible", .int4 },
        .{ "reltoastrelid", .oid },   .{ "relhasindex", .bool },    .{ "relisshared", .bool },    .{ "relpersistence", .char },
        .{ "relkind", .char },        .{ "relnatts", .int2 },       .{ "relchecks", .int2 },      .{ "relhasrules", .bool },
        .{ "relhastriggers", .bool }, .{ "relhassubclass", .bool }, .{ "relrowsecurity", .bool }, .{ "relforcerowsecurity", .bool },
        .{ "relispopulated", .bool }, .{ "relreplident", .char },   .{ "relispartition", .bool }, .{ "relrewrite", .oid },
        .{ "relfrozenxid", .text },   .{ "relminmxid", .text },     .{ "relacl", .text },         .{ "reloptions", .text },
        .{ "relpartbound", .text },
    } },
    .{ .name = "xq_pg_attribute", .fill = fillAttribute, .cols = &.{
        .{ "attrelid", .oid },        .{ "attname", .name },       .{ "atttypid", .oid },      .{ "attstattarget", .int4 },
        .{ "attlen", .int2 },         .{ "attnum", .int2 },        .{ "attndims", .int4 },     .{ "attcacheoff", .int4 },
        .{ "atttypmod", .int4 },      .{ "attbyval", .bool },      .{ "attalign", .char },     .{ "attstorage", .char },
        .{ "attcompression", .char }, .{ "attnotnull", .bool },    .{ "atthasdef", .bool },    .{ "atthasmissing", .bool },
        .{ "attidentity", .char },    .{ "attgenerated", .char },  .{ "attisdropped", .bool }, .{ "attislocal", .bool },
        .{ "attinhcount", .int2 },    .{ "attcollation", .oid },   .{ "attacl", .text },       .{ "attoptions", .text },
        .{ "attfdwoptions", .text },  .{ "attmissingval", .text },
    } },
    .{ .name = "xq_pg_type", .fill = fillType, .cols = &.{
        .{ "oid", .oid },             .{ "typname", .name },       .{ "typnamespace", .oid }, .{ "typowner", .oid },
        .{ "typlen", .int2 },         .{ "typbyval", .bool },      .{ "typtype", .char },     .{ "typcategory", .char },
        .{ "typispreferred", .bool }, .{ "typisdefined", .bool },  .{ "typdelim", .char },    .{ "typrelid", .oid },
        .{ "typsubscript", .text },   .{ "typelem", .oid },        .{ "typarray", .oid },     .{ "typinput", .text },
        .{ "typoutput", .text },      .{ "typreceive", .text },    .{ "typsend", .text },     .{ "typmodin", .text },
        .{ "typmodout", .text },      .{ "typanalyze", .text },    .{ "typalign", .char },    .{ "typstorage", .char },
        .{ "typnotnull", .bool },     .{ "typbasetype", .oid },    .{ "typtypmod", .int4 },   .{ "typndims", .int4 },
        .{ "typcollation", .oid },    .{ "typdefaultbin", .text }, .{ "typdefault", .text },  .{ "typacl", .text },
    } },
    .{ .name = "xq_pg_index", .fill = fillIndex, .cols = &.{
        .{ "indexrelid", .oid },    .{ "indrelid", .oid },             .{ "indnatts", .int2 },       .{ "indnkeyatts", .int2 },
        .{ "indisunique", .bool },  .{ "indnullsnotdistinct", .bool }, .{ "indisprimary", .bool },   .{ "indisexclusion", .bool },
        .{ "indimmediate", .bool }, .{ "indisclustered", .bool },      .{ "indisvalid", .bool },     .{ "indcheckxmin", .bool },
        .{ "indisready", .bool },   .{ "indislive", .bool },           .{ "indisreplident", .bool }, .{ "indkey", .text },
        .{ "indcollation", .text }, .{ "indclass", .text },            .{ "indoption", .text },      .{ "indexprs", .text },
        .{ "indpred", .text },
    } },
    .{ .name = "xq_pg_constraint", .fill = fillConstraint, .cols = &.{
        .{ "oid", .oid },            .{ "conname", .name },      .{ "connamespace", .oid },   .{ "contype", .char },
        .{ "condeferrable", .bool }, .{ "condeferred", .bool },  .{ "convalidated", .bool },  .{ "conrelid", .oid },
        .{ "contypid", .oid },       .{ "conindid", .oid },      .{ "conparentid", .oid },    .{ "confrelid", .oid },
        .{ "confupdtype", .char },   .{ "confdeltype", .char },  .{ "confmatchtype", .char }, .{ "conislocal", .bool },
        .{ "coninhcount", .int2 },   .{ "connoinherit", .bool }, .{ "conkey", .text },        .{ "confkey", .text },
        .{ "conpfeqop", .text },     .{ "conppeqop", .text },    .{ "conffeqop", .text },     .{ "confdelsetcols", .text },
        .{ "conexclop", .text },     .{ "conbin", .text },
    } },
    .{ .name = "xq_pg_attrdef", .fill = fillAttrdef, .cols = &.{
        .{ "oid", .oid }, .{ "adrelid", .oid }, .{ "adnum", .int2 }, .{ "adbin", .text },
    } },
    .{ .name = "xq_pg_sequence", .fill = fillSequence, .cols = &.{
        .{ "seqrelid", .oid }, .{ "seqtypid", .oid }, .{ "seqstart", .int8 }, .{ "seqincrement", .int8 },
        .{ "seqmax", .int8 },  .{ "seqmin", .int8 },  .{ "seqcache", .int8 }, .{ "seqcycle", .bool },
    } },
    .{ .name = "xq_pg_depend", .fill = fillDepend, .cols = &.{
        .{ "classid", .oid },  .{ "objid", .oid },        .{ "objsubid", .int4 }, .{ "refclassid", .oid },
        .{ "refobjid", .oid }, .{ "refobjsubid", .int4 }, .{ "deptype", .char },
    } },
    .{ .name = "xq_pg_description", .fill = fillDescription, .cols = &.{
        .{ "objoid", .oid }, .{ "classoid", .oid }, .{ "objsubid", .int4 }, .{ "description", .text },
    } },
    .{ .name = "xq_pg_proc", .fill = fillProc, .cols = &.{
        .{ "oid", .oid },             .{ "proname", .name },         .{ "pronamespace", .oid }, .{ "proowner", .oid },
        .{ "prolang", .oid },         .{ "procost", .float4 },       .{ "prorows", .float4 },   .{ "provariadic", .oid },
        .{ "prosupport", .text },     .{ "prokind", .char },         .{ "prosecdef", .bool },   .{ "proleakproof", .bool },
        .{ "proisstrict", .bool },    .{ "proretset", .bool },       .{ "provolatile", .char }, .{ "proparallel", .char },
        .{ "pronargs", .int2 },       .{ "pronargdefaults", .int2 }, .{ "prorettype", .oid },   .{ "proargtypes", .text },
        .{ "proallargtypes", .text }, .{ "proargmodes", .text },     .{ "proargnames", .text }, .{ "proargdefaults", .text },
        .{ "protrftypes", .text },    .{ "prosrc", .text },          .{ "probin", .text },      .{ "prosqlbody", .text },
        .{ "proconfig", .text },      .{ "proacl", .text },
    } },
};

/// The view text of relation `pg_name` (pg_class ...): its columns cast
/// to their types, from the virtual table.
pub fn viewText(comptime rel: Relation) []const u8 {
    comptime {
        var z: []const u8 = "SELECT ";
        for (rel.cols, 0..) |c, i| {
            if (i > 0) z = z ++ ", ";
            z = z ++ c[0] ++ c[1].cast() ++ " AS " ++ c[0];
        }
        return z ++ " FROM " ++ rel.name;
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
    cells: []const Cell = &.{},
    ncol: usize = 1,
    i: usize = 0,

    fn of(cur: *vtab.VtabCursor) *Cursor {
        return @alignCast(@fieldParentPtr("base", cur));
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

        fn filter(cur: *vtab.VtabCursor, _: i32, _: ?[:0]const u8, _: []*vi.Mem) i32 {
            const c = Cursor.of(cur);
            if (c.snap) |s| release(c.db, s);
            c.snap = null;
            _ = c.arena.reset(.retain_capacity);
            c.i = 0;
            c.cells = &.{};
            c.ncol = rel.cols.len;
            const s = acquire(c.db) catch |err| return switch (err) {
                error.OutOfMemory => RC.NOMEM,
                error.Failed => blk: {
                    vtab.setErrMsg(c.db, cur.vtab, "xqlite: cannot read the catalog", .{});
                    break :blk RC.ERROR;
                },
            };
            c.snap = s;
            var rows: Rows = .{ .a = c.arena.allocator(), .ncol = rel.cols.len };
            rel.fill(s, &rows) catch return RC.NOMEM;
            c.cells = rows.cells.items;
            return RC.OK;
        }
    };
    return .{
        .i_version = 0,
        .x_connect = M.connect,
        .x_best_index = bestIndex,
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

fn bestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    info.estimated_cost = 1000;
    info.estimated_rows = 100;
    return RC.OK;
}

fn next(cur: *vtab.VtabCursor) i32 {
    Cursor.of(cur).i += 1;
    return RC.OK;
}

fn eof(cur: *vtab.VtabCursor) bool {
    const c = Cursor.of(cur);
    return c.i * c.ncol >= c.cells.len;
}

fn column(cur: *vtab.VtabCursor, ctx: *Context, i: i32) i32 {
    const c = Cursor.of(cur);
    switch (c.cells[c.i * c.ncol + @as(usize, @intCast(i))]) {
        .null => api.resultNull(ctx),
        .int => |v| api.resultInt64(ctx, v),
        .float => |v| api.resultDouble(ctx, v),
        .text => |z| api.resultText(ctx, z, .static),
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
    for (relations, 0..) |r, i| out[i] = .{ .name = r.name, .module = &module_list[i] };
    const final = out;
    break :blk final;
};

test "oids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try assign(a, 'r', &.{ "main\x00t", "main\x00u", "main\x00t" });
    try std.testing.expect(o[0] >= first_user_oid and o[0] < 0x7fffffff);
    try std.testing.expect(o[0] != o[2]);
    try std.testing.expectEqual(o[0], hashOid('r', "main\x00t"));
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
    try std.testing.expectEqualStrings("(\"a\" > 5)", whereOf("CREATE INDEX \"i\" ON \"t\"((lower(\"b\")), \"a\" DESC) WHERE (\"a\" > 5)").?);
    try std.testing.expect(looksLikeCall("lower(b)"));
    try std.testing.expect(!looksLikeCall("(a + 1)"));
}
