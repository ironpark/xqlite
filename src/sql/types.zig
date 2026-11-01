//! The type of a column or an expression, independent of the dialect
//! that declared it. The engine's own: the catalog keeps the parsed
//! declared type of every column it describes (catalog.ColumnMeta), the
//! dialect frontends and the public API use it (xqlite.types is this
//! file).
//!
//! The engine keeps a table column's type in the dialect that made the
//! table (xq_catalog, `Stmt.columnTypeAlloc()`: `character varying(20)`,
//! `DATETIME2(3)`, `NUMBER(10,2)`); `parse()` reads it into a `Type`. The
//! wire protocols map it to their own codes (PostgreSQL's RowDescription
//! type OID, MySQL's column definition, TDS's COLMETADATA), and
//! api/display.zig writes values as the dialect a client speaks shows
//! them (a boolean that SQLite stores as 0/1 is `t`/`f` in PostgreSQL).
//! An expression has no declared type, so it is described by the storage
//! class of its value (`ofKind()`).
//!
//! Depends on nothing but std and the Dialect enum, so that src/sql,
//! src/catalog and src/dialect use it without the public API.

const std = @import("std");

const Dialect = @import("../dialect/dialect.zig").Dialect;

/// The fundamental datatypes of SQLite (sqlite3_column_type()): the
/// storage class of a value (xqlite.Kind).
pub const Kind = enum { integer, float, text, blob, null };

/// The types the protocols tell apart. Each protocol maps every one to a
/// code of its own (the nearest, where it has no exact one).
pub const Logical = enum {
    /// No type known (an expression whose value is NULL): sent as text.
    unknown,
    boolean,
    /// Integers by width in bytes (TINYINT, SMALLINT, INT, BIGINT).
    int1,
    int2,
    int4,
    int8,
    float4,
    float8,
    /// Exact decimals (NUMERIC, DECIMAL, NUMBER, MONEY).
    numeric,
    text,
    /// Character strings with a maximum length (`Type.length`).
    varchar,
    /// Blank-padded character strings of a fixed length.
    char,
    bytes,
    date,
    time,
    time_tz,
    timestamp,
    timestamp_tz,
    interval,
    uuid,
    json,
    /// PostgreSQL's binary JSON (its text form on the wire).
    jsonb,
};

pub const Type = struct {
    logical: Logical,
    /// The maximum length of a `varchar` or `char` (characters), or of
    /// `bytes` of a declared size.
    length: ?u32 = null,
    /// The precision and scale of a `numeric`; the fractional second
    /// digits of a time or timestamp in `scale`.
    precision: ?u8 = null,
    scale: ?u8 = null,
};

/// The type of a column declared as `name` in `dialect` (the text of
/// Stmt.columnTypeAlloc()). Names are case-insensitive; an unknown name
/// is `.unknown`, which protocols send as text.
pub fn parse(dialect: Dialect, name: []const u8) Type {
    var buf: [64]u8 = undefined;
    const base, const a0, const a1 = split(name, &buf);
    const l = lookup(dialect, base);
    var t: Type = .{ .logical = l };
    switch (l) {
        .varchar, .char, .bytes => t.length = if (a0) |n| std.math.cast(u32, n) else null,
        .numeric => {
            t.precision = if (a0) |n| std.math.cast(u8, n) else null;
            t.scale = if (a1) |n| std.math.cast(u8, n) else if (a0 != null) 0 else null;
            // Oracle's NUMBER(p) and NUMBER(p, 0) of few digits are
            // integers.
            if (dialect == .oracle and t.scale == 0) {
                if (t.precision) |p| t.logical = if (p <= 4) .int2 else if (p <= 9) .int4 else if (p <= 18) .int8 else .numeric;
            }
        },
        .time, .time_tz, .timestamp, .timestamp_tz => t.scale = if (a0) |n| std.math.cast(u8, n) else null,
        else => {},
    }
    return t;
}

/// The type of an expression from the storage class of its value.
pub fn ofKind(kind: Kind) Type {
    return .{ .logical = switch (kind) {
        .integer => .int8,
        .float => .float8,
        .text => .text,
        .blob => .bytes,
        .null => .unknown,
    } };
}

/// The words of the name lower case, one space apart, without the
/// arguments ("TIMESTAMP (3) WITH TIME ZONE" is "timestamp with time
/// zone"), and the first two arguments if they are integers ("max" is
/// not).
fn split(name: []const u8, buf: []u8) struct { []const u8, ?i64, ?i64 } {
    const open = std.mem.indexOfScalar(u8, name, '(') orelse name.len;
    const close = std.mem.indexOfScalarPos(u8, name, open, ')');
    var n: usize = 0;
    for ([_][]const u8{ name[0..open], if (close) |c| name[c + 1 ..] else "" }) |part| {
        var words = std.mem.tokenizeAny(u8, part, " \t");
        while (words.next()) |w| {
            if (n + 1 + w.len > buf.len) break;
            if (n > 0) {
                buf[n] = ' ';
                n += 1;
            }
            n += std.ascii.lowerString(buf[n..], w).len;
        }
    }
    var args: [2]?i64 = .{ null, null };
    if (open < name.len) {
        var it = std.mem.splitScalar(u8, name[open + 1 .. close orelse name.len], ',');
        for (&args) |*a| a.* = std.fmt.parseInt(i64, std.mem.trim(u8, it.next() orelse break, " \t"), 10) catch null;
    }
    return .{ buf[0..n], args[0], args[1] };
}

const Entry = struct { []const u8, Logical };

/// Names whose type is the same in every dialect that has them.
const common = std.StaticStringMap(Logical).initComptime([_]Entry{
    .{ "bool", .boolean },
    .{ "boolean", .boolean },
    .{ "smallint", .int2 },
    .{ "int2", .int2 },
    .{ "integer", .int4 },
    .{ "int", .int4 },
    .{ "int4", .int4 },
    .{ "mediumint", .int4 },
    .{ "bigint", .int8 },
    .{ "int8", .int8 },
    .{ "smallserial", .int2 },
    .{ "serial", .int4 },
    .{ "bigserial", .int8 },
    .{ "real", .float4 },
    .{ "float4", .float4 },
    .{ "binary_float", .float4 },
    .{ "double", .float8 },
    .{ "double precision", .float8 },
    .{ "float8", .float8 },
    .{ "binary_double", .float8 },
    .{ "numeric", .numeric },
    .{ "decimal", .numeric },
    .{ "dec", .numeric },
    .{ "number", .numeric },
    .{ "money", .numeric },
    .{ "smallmoney", .numeric },
    .{ "text", .text },
    .{ "tinytext", .text },
    .{ "mediumtext", .text },
    .{ "longtext", .text },
    .{ "ntext", .text },
    .{ "clob", .text },
    .{ "nclob", .text },
    .{ "long", .text },
    .{ "varchar", .varchar },
    .{ "character varying", .varchar },
    .{ "char varying", .varchar },
    .{ "nvarchar", .varchar },
    .{ "national character varying", .varchar },
    .{ "varchar2", .varchar },
    .{ "nvarchar2", .varchar },
    .{ "char", .char },
    .{ "character", .char },
    .{ "nchar", .char },
    .{ "national character", .char },
    .{ "bpchar", .char },
    .{ "bytea", .bytes },
    .{ "blob", .bytes },
    .{ "tinyblob", .bytes },
    .{ "mediumblob", .bytes },
    .{ "longblob", .bytes },
    .{ "binary", .bytes },
    .{ "varbinary", .bytes },
    .{ "image", .bytes },
    .{ "raw", .bytes },
    .{ "long raw", .bytes },
    .{ "date", .date },
    .{ "time", .time },
    .{ "time without time zone", .time },
    .{ "time with time zone", .time_tz },
    .{ "timetz", .time_tz },
    .{ "timestamp", .timestamp },
    .{ "timestamp without time zone", .timestamp },
    .{ "datetime", .timestamp },
    .{ "datetime2", .timestamp },
    .{ "smalldatetime", .timestamp },
    .{ "timestamp with time zone", .timestamp_tz },
    .{ "timestamptz", .timestamp_tz },
    .{ "timestamp with local time zone", .timestamp_tz },
    .{ "datetimeoffset", .timestamp_tz },
    .{ "interval", .interval },
    .{ "uuid", .uuid },
    .{ "uniqueidentifier", .uuid },
    .{ "json", .json },
    .{ "jsonb", .jsonb },
});

/// The type of `base` (lower case, without arguments) in `dialect`.
fn lookup(dialect: Dialect, base: []const u8) Logical {
    // Where the dialects differ.
    switch (dialect) {
        // SQLite's integers and reals are 64-bit, whatever the name.
        .sqlite => {
            if (std.mem.indexOf(u8, base, "int") != null) return .int8;
            if (std.mem.eql(u8, base, "real") or std.mem.eql(u8, base, "float")) return .float8;
        },
        .mariadb => {
            if (std.mem.eql(u8, base, "tinyint")) return .int1;
            if (std.mem.eql(u8, base, "float")) return .float4;
        },
        .mssql => {
            if (std.mem.eql(u8, base, "tinyint")) return .int1;
            if (std.mem.eql(u8, base, "bit")) return .boolean;
            if (std.mem.eql(u8, base, "float")) return .float8;
        },
        // Oracle's DATE has a time of day.
        .oracle => {
            if (std.mem.eql(u8, base, "date")) return .timestamp;
            if (std.mem.eql(u8, base, "float")) return .numeric;
        },
        .postgres => {
            if (std.mem.eql(u8, base, "float")) return .float8;
        },
    }
    if (std.mem.startsWith(u8, base, "interval")) return .interval;
    return common.get(base) orelse .unknown;
}

test "parse: the declared types of each dialect" {
    const T = struct {
        fn expect(d: Dialect, name: []const u8, want: Type) !void {
            try std.testing.expectEqual(want, parse(d, name));
        }
    };
    try T.expect(.postgres, "character varying(20)", .{ .logical = .varchar, .length = 20 });
    try T.expect(.postgres, "timestamp(3) with time zone", .{ .logical = .timestamp_tz, .scale = 3 });
    try T.expect(.postgres, "numeric(10,2)", .{ .logical = .numeric, .precision = 10, .scale = 2 });
    try T.expect(.postgres, "integer", .{ .logical = .int4 });
    try T.expect(.postgres, "interval day to second", .{ .logical = .interval });
    try T.expect(.postgres, "jsonb", .{ .logical = .jsonb });
    try T.expect(.mariadb, "TINYINT(1)", .{ .logical = .int1 });
    try T.expect(.mariadb, "VARCHAR(255)", .{ .logical = .varchar, .length = 255 });
    try T.expect(.mssql, "NVARCHAR(max)", .{ .logical = .varchar });
    try T.expect(.mssql, "BIT", .{ .logical = .boolean });
    try T.expect(.mssql, "DATETIME2(7)", .{ .logical = .timestamp, .scale = 7 });
    try T.expect(.oracle, "NUMBER(5)", .{ .logical = .int4, .precision = 5, .scale = 0 });
    try T.expect(.oracle, "NUMBER(10,2)", .{ .logical = .numeric, .precision = 10, .scale = 2 });
    try T.expect(.oracle, "DATE", .{ .logical = .timestamp });
    try T.expect(.sqlite, "INTEGER", .{ .logical = .int8 });
    try T.expect(.sqlite, "VARCHAR(20)", .{ .logical = .varchar, .length = 20 });
    try T.expect(.sqlite, "whatever", .{ .logical = .unknown });
    try T.expect(.postgres, "  Character   Varying ( 8 ) ", .{ .logical = .varchar, .length = 8 });
}
