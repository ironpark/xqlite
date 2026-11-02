//! PostgreSQL types: how a declared type is stored in a STRICT table,
//! what checks it adds, how the catalog spells it (format_type()), and
//! what a cast to it does.
//!
//! | PostgreSQL                          | storage | check                                  |
//! |-------------------------------------|---------|----------------------------------------|
//! | smallint, integer (smallserial, serial) | INTEGER | range ("smallint/integer out of range") |
//! | bigint, bigserial                   | INTEGER |                                        |
//! | real, double precision, float(p)    | REAL    |                                        |
//! | numeric(p,s), decimal               | BLOB    | a key of decimal.zig (xq_dec_valid())  |
//! | boolean                             | INTEGER | 0 or 1                                 |
//! | text, varchar(n), char(n)           | TEXT    | length <= n                            |
//! | bytea                               | BLOB    |                                        |
//! | date, time, timestamp[tz]           | TEXT    |                                        |
//! | interval                            | BLOB    | xq_pg_iv_valid(): src/dialect/interval.zig's BLOB (TEXT in older databases) |
//! | uuid                                | BLOB    | 16 bytes (uuid.zig); TEXT in older tables |
//! | json                                | TEXT    | json_valid()                           |
//! | jsonb                               | BLOB    | json_valid(x, 8): JSONB, canonical (TEXT in older tables) |
//! | integer[], text[] ... (any T[])     | TEXT    | an array literal (array.zig); stored canonical |
//!
//! A numeric is stored as decimal.zig's key, a BLOB in the order of the
//! numbers (decimal_sql.zig's xq_dec_*() compute with it); a numeric
//! column of a table made before (storage ANY) keeps numbers.
//!
//! A check is a named CHECK constraint whose name is PostgreSQL's
//! message (Hooks.check_errors), so that a violation in the dialect
//! reads "integer out of range" (in SQLite's: "CHECK constraint failed:
//! integer out of range").

const std = @import("std");
const integer = @import("integer.zig");

/// A type as PostgreSQL names it: `name` is the canonical spelling
/// ("integer", "character varying", "timestamp with time zone" ...),
/// `mods` the modifiers in parentheses.
pub const TypeName = struct {
    name: []const u8,
    mods: []const i64 = &.{},
    /// The fields of an interval type ("year to month", "second"; the
    /// precision of `second(3)` is mods[0]).
    fields: []const u8 = "",
    array: bool = false,
    pos: u32,
};

pub const Check = enum {
    none,
    smallint_range,
    integer_range,
    numeric,
    boolean,
    length,
    json,
    /// A JSONB blob (json_valid(x, 8)).
    jsonb,
    /// An array literal (xq_pg_array_valid()).
    array,
    /// A uuid's 16 bytes (uuid.zig).
    uuid,
    /// An interval's BLOB (xq_pg_iv_valid()).
    interval,
};

pub const Info = struct {
    /// The STRICT storage type.
    storage: [:0]const u8,
    check: Check = .none,
    /// smallserial, serial, bigserial: an identity numbered by a
    /// sequence.
    serial: bool = false,
};

pub const Error = error{ UnknownType, Array };

/// The storage of declared type `ty`.
pub fn info(ty: TypeName) Error!Info {
    if (ty.array) {
        // An array of a type there is (serial[] is none).
        var el = ty;
        el.array = false;
        const e = info(el) catch |err| return if (err == error.UnknownType and arrayOnly(ty.name)) .{ .storage = "TEXT", .check = .array } else err;
        if (e.serial) return error.Array;
        return .{ .storage = "TEXT", .check = .array };
    }
    const n = ty.name;
    const table = [_]struct { []const u8, Info }{
        .{ "smallint", .{ .storage = "INTEGER", .check = .smallint_range } },
        .{ "integer", .{ .storage = "INTEGER", .check = .integer_range } },
        .{ "bigint", .{ .storage = "INTEGER" } },
        .{ "smallserial", .{ .storage = "INTEGER", .check = .smallint_range, .serial = true } },
        .{ "serial", .{ .storage = "INTEGER", .check = .integer_range, .serial = true } },
        .{ "bigserial", .{ .storage = "INTEGER", .serial = true } },
        .{ "real", .{ .storage = "REAL" } },
        .{ "double precision", .{ .storage = "REAL" } },
        .{ "numeric", .{ .storage = "BLOB", .check = .numeric } },
        .{ "boolean", .{ .storage = "INTEGER", .check = .boolean } },
        .{ "text", .{ .storage = "TEXT" } },
        .{ "character varying", .{ .storage = "TEXT", .check = .length } },
        .{ "character", .{ .storage = "TEXT", .check = .length } },
        .{ "name", .{ .storage = "TEXT" } },
        .{ "bytea", .{ .storage = "BLOB" } },
        .{ "date", .{ .storage = "TEXT" } },
        .{ "time without time zone", .{ .storage = "TEXT" } },
        .{ "time with time zone", .{ .storage = "TEXT" } },
        .{ "timestamp without time zone", .{ .storage = "TEXT" } },
        .{ "timestamp with time zone", .{ .storage = "TEXT" } },
        // The columns of older databases are TEXT (and compare in the
        // collation xq_pg_interval): they keep it.
        .{ "interval", .{ .storage = "BLOB", .check = .interval } },
        .{ "uuid", .{ .storage = "BLOB", .check = .uuid } },
        .{ "json", .{ .storage = "TEXT", .check = .json } },
        // jsonb is SQLite's JSONB (postgres/json.zig), a table made before
        // that keeps TEXT (jtype.zig reads the column's storage).
        .{ "jsonb", .{ .storage = "BLOB", .check = .jsonb } },
        .{ "oid", .{ .storage = "INTEGER" } },
        // The catalog's vectors (`1 2`).
        .{ "int2vector", .{ .storage = "TEXT" } },
        .{ "oidvector", .{ .storage = "TEXT" } },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], n)) {
        var r = e[1];
        // varchar without a length has none; char without one is char(1).
        if (r.check == .length and ty.mods.len == 0 and std.mem.eql(u8, n, "character varying")) r.check = .none;
        return r;
    };
    return error.UnknownType;
}

/// The element types of no column type of their own that an array may be
/// of (name[] of the catalog's columns).
fn arrayOnly(name: []const u8) bool {
    const names = [_][]const u8{ "name", "regclass", "regtype", "regproc", "char", "aclitem" };
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// The length limit of varchar(n)/char(n) (char is char(1)).
pub fn maxLength(ty: TypeName) ?i64 {
    if (ty.mods.len > 0) return ty.mods[0];
    if (std.mem.eql(u8, ty.name, "character")) return 1;
    return null;
}

/// The type of a serial column: what the catalog records.
pub fn serialBase(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "smallserial")) return "smallint";
    if (std.mem.eql(u8, name, "bigserial")) return "bigint";
    return "integer";
}

/// format_type(): "character varying(20)", "numeric(10,2)",
/// "timestamp(3) without time zone", "integer" for serial ...
pub fn format(a: std.mem.Allocator, ty: TypeName) ![]const u8 {
    if (ty.array) {
        var el = ty;
        el.array = false;
        return std.mem.concat(a, u8, &.{ try format(a, el), "[]" });
    }
    var n = if (std.mem.endsWith(u8, ty.name, "serial")) serialBase(ty.name) else ty.name;
    if (ty.fields.len > 0) n = try std.mem.concat(a, u8, &.{ n, " ", ty.fields });
    if (std.mem.eql(u8, n, "character") and ty.mods.len == 0) return "character(1)";
    if (ty.mods.len == 0) return n;
    var mods: std.ArrayList(u8) = .empty;
    try mods.append(a, '(');
    for (ty.mods, 0..) |m, i| {
        if (i > 0) try mods.append(a, ',');
        try mods.print(a, "{d}", .{m});
    }
    try mods.append(a, ')');
    // The precision of time types goes before "with/without time zone".
    if (std.mem.indexOf(u8, n, " with")) |sp| {
        return std.mem.concat(a, u8, &.{ n[0..sp], mods.items, n[sp..] });
    }
    return std.mem.concat(a, u8, &.{ n, mods.items });
}

/// Whether `name[]` may be cast to: an array of a type there is.
pub fn arrayElement(ty: TypeName) bool {
    var el = ty;
    el.array = true;
    _ = info(el) catch return false;
    return true;
}

/// Whether `name` (an array's element) is a number type.
pub fn isNumeric(name: []const u8) bool {
    const names = [_][]const u8{ "integer", "smallint", "bigint", "numeric", "real", "double precision" };
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// The internal name of a type (int4, varchar, timestamptz ...): the
/// name of a column that is a cast of a constant.
pub fn internalName(name: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "smallint", "int2" },              .{ "integer", "int4" },                          .{ "bigint", "int8" },
        .{ "real", "float4" },                .{ "double precision", "float8" },               .{ "boolean", "bool" },
        .{ "character varying", "varchar" },  .{ "character", "bpchar" },                      .{ "time without time zone", "time" },
        .{ "time with time zone", "timetz" }, .{ "timestamp without time zone", "timestamp" }, .{ "timestamp with time zone", "timestamptz" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return name;
}

/// The output function of a reg* type whose values are OIDs (regclass
/// ...): what turns one into its text (catalog_funcs.zig); null for
/// another type.
pub fn regOutput(name: []const u8) ?[:0]const u8 {
    const map = [_]struct { []const u8, [:0]const u8 }{
        .{ "regclass", "xq_pg_regclass_out" },         .{ "regtype", "xq_pg_regtype_out" },
        .{ "regnamespace", "xq_pg_regnamespace_out" }, .{ "regrole", "xq_pg_regrole_out" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return null;
}

fn regInput(name: []const u8) [:0]const u8 {
    if (std.mem.eql(u8, name, "regclass")) return "xq_pg_regclass";
    if (std.mem.eql(u8, name, "regtype")) return "xq_pg_regtype";
    if (std.mem.eql(u8, name, "regnamespace")) return "xq_pg_regnamespace";
    return "xq_pg_regrole";
}

/// What a cast to a type does.
pub const CastPlan = union(enum) {
    /// CAST(x AS type)
    sqlite: [:0]const u8,
    /// f(x)
    func: [:0]const u8,
    /// substr(CAST(x AS TEXT), 1, n)
    truncate: i64,
    /// round(x, s) as NUMERIC
    round: i64,
    /// xq_dec(x, p, s): numeric(p, s)
    numeric: [2]i64,
    /// xq_pg_iv_in(x, typmod): an interval of the type modifier
    /// (intervalTypmod(), -1 for none).
    interval: i64,
};

/// The type modifier of interval type `ty` (ivinput.zig: PostgreSQL's
/// INTERVAL_TYPMOD() of its fields and precision), -1 for none.
pub fn intervalTypmod(ty: TypeName) i32 {
    const ivinput = @import("ivinput.zig");
    const range = ivinput.rangeOfText(ty.fields) orelse ivinput.full_range;
    return ivinput.typmodOf(range, if (ty.mods.len > 0) ty.mods[0] else null);
}

pub fn castPlan(ty: TypeName) Error!CastPlan {
    if (ty.array) return error.Array;
    const n = ty.name;
    const eql = std.mem.eql;
    if (regOutput(n)) |_| return .{ .func = regInput(n) };
    if (eql(u8, n, "regproc") or eql(u8, n, "regprocedure")) return .{ .func = "xq_pg_regproc" };
    if (eql(u8, n, "jsonpath") or eql(u8, n, "text") or eql(u8, n, "name") or eql(u8, n, "int2vector") or eql(u8, n, "oidvector")) return .{ .sqlite = "TEXT" };
    if (eql(u8, n, "character varying") or eql(u8, n, "character")) {
        if (maxLength(ty)) |len| return .{ .truncate = len };
        return .{ .sqlite = "TEXT" };
    }
    // A key of decimal.zig with its display scale.
    if (eql(u8, n, "numeric")) {
        if (ty.mods.len == 2) return .{ .numeric = .{ ty.mods[0], ty.mods[1] } };
        if (ty.mods.len == 1) return .{ .numeric = .{ ty.mods[0], 0 } };
        return .{ .func = "xq_dec" };
    }
    if (eql(u8, n, "boolean")) return .{ .func = "xq_pg_bool" };
    // int2in() ... (integer.zig): 0x1F, 1_000; a real rounds to even.
    if (integer.Width.named(n)) |w| return .{ .func = integer.castName(w) };
    // PostgreSQL's input and output of the value (datetime.zig: an
    // error for what it does not read, the fraction of a second kept, a
    // timestamptz in UTC, '90 minutes' as '01:30:00').
    if (eql(u8, n, "date")) return .{ .func = "xq_pg_date" };
    if (eql(u8, n, "interval")) return .{ .interval = intervalTypmod(ty) };
    if (eql(u8, n, "time without time zone")) return .{ .func = "xq_pg_time" };
    if (eql(u8, n, "time with time zone")) return .{ .func = "time" };
    if (eql(u8, n, "timestamp without time zone")) return .{ .func = "xq_pg_timestamp" };
    if (eql(u8, n, "timestamp with time zone")) return .{ .func = "xq_pg_timestamptz" };
    // json is checked and kept as written, jsonb normalized (json.zig).
    if (eql(u8, n, "json")) return .{ .func = "xq_pg_json" };
    if (eql(u8, n, "jsonb")) return .{ .func = "xq_pg_jsonb" };
    // uuid_in(): the 16 bytes (uuid.zig).
    if (eql(u8, n, "uuid")) return .{ .func = "xq_pg_uuid" };
    const i = try info(ty);
    if (i.serial) return error.UnknownType;
    return .{ .sqlite = i.storage };
}
