//! PostgreSQL types: how a declared type is stored in a STRICT table,
//! what checks it adds, how the catalog spells it (format_type()), and
//! what a cast to it does.
//!
//! | PostgreSQL                          | storage | check                                  |
//! |-------------------------------------|---------|----------------------------------------|
//! | smallint, integer (smallserial, serial) | INTEGER | range ("smallint/integer out of range") |
//! | bigint, bigserial                   | INTEGER |                                        |
//! | real, double precision, float(p)    | REAL    |                                        |
//! | numeric(p,s), decimal               | ANY     | a number                               |
//! | boolean                             | INTEGER | 0 or 1                                 |
//! | text, varchar(n), char(n)           | TEXT    | length <= n                            |
//! | bytea                               | BLOB    |                                        |
//! | date, time, timestamp[tz], interval | TEXT    |                                        |
//! | uuid                                | TEXT    |                                        |
//! | json, jsonb                         | TEXT    | json_valid(); jsonb stored normalized  |
//!
//! A check is a named CHECK constraint whose name is PostgreSQL's
//! message, so that a violation reads "CHECK constraint failed: integer
//! out of range".

const std = @import("std");

/// A type as PostgreSQL names it: `name` is the canonical spelling
/// ("integer", "character varying", "timestamp with time zone" ...),
/// `mods` the modifiers in parentheses.
pub const TypeName = struct {
    name: []const u8,
    mods: []const i64 = &.{},
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
    if (ty.array) return error.Array;
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
        .{ "numeric", .{ .storage = "ANY", .check = .numeric } },
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
        .{ "interval", .{ .storage = "TEXT" } },
        .{ "uuid", .{ .storage = "TEXT" } },
        .{ "json", .{ .storage = "TEXT", .check = .json } },
        .{ "jsonb", .{ .storage = "TEXT", .check = .json } },
        .{ "oid", .{ .storage = "INTEGER" } },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], n)) {
        var r = e[1];
        // varchar without a length has none; char without one is char(1).
        if (r.check == .length and ty.mods.len == 0 and std.mem.eql(u8, n, "character varying")) r.check = .none;
        return r;
    };
    return error.UnknownType;
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
    const n = if (std.mem.endsWith(u8, ty.name, "serial")) serialBase(ty.name) else ty.name;
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

/// Whether `name[]` may be cast to: an array of these is its text literal
/// ('{a,b}'), which the JSON operators and functions read (arrays are no
/// column type).
pub fn arrayElement(name: []const u8) bool {
    const names = [_][]const u8{ "text", "character varying", "character", "name", "integer", "smallint", "bigint", "numeric", "real", "double precision" };
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
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
};

pub fn castPlan(ty: TypeName) Error!CastPlan {
    if (ty.array) return error.Array;
    const n = ty.name;
    const eql = std.mem.eql;
    if (eql(u8, n, "regclass") or eql(u8, n, "jsonpath") or eql(u8, n, "text") or eql(u8, n, "name") or eql(u8, n, "uuid") or eql(u8, n, "interval")) return .{ .sqlite = "TEXT" };
    if (eql(u8, n, "character varying") or eql(u8, n, "character")) {
        if (maxLength(ty)) |len| return .{ .truncate = len };
        return .{ .sqlite = "TEXT" };
    }
    if (eql(u8, n, "numeric")) {
        if (ty.mods.len == 2) return .{ .round = ty.mods[1] };
        if (ty.mods.len == 1) return .{ .round = 0 };
        return .{ .sqlite = "NUMERIC" };
    }
    if (eql(u8, n, "boolean")) return .{ .func = "xq_pg_bool" };
    if (eql(u8, n, "smallint")) return .{ .func = "xq_pg_int2" };
    if (eql(u8, n, "integer")) return .{ .func = "xq_pg_int4" };
    if (eql(u8, n, "bigint")) return .{ .func = "xq_pg_int8" };
    if (eql(u8, n, "date")) return .{ .func = "date" };
    if (eql(u8, n, "time without time zone") or eql(u8, n, "time with time zone")) return .{ .func = "time" };
    if (eql(u8, n, "timestamp without time zone") or eql(u8, n, "timestamp with time zone")) return .{ .func = "datetime" };
    // json is checked and kept as written, jsonb normalized (json.zig).
    if (eql(u8, n, "json")) return .{ .func = "xq_pg_json" };
    if (eql(u8, n, "jsonb")) return .{ .func = "xq_pg_jsonb" };
    const i = try info(ty);
    if (i.serial) return error.UnknownType;
    return .{ .sqlite = i.storage };
}
