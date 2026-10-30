//! SQL Server data types: how a declared type is stored in a STRICT
//! table, the CHECK it adds, how the catalog spells it, and the text the
//! conversion functions take (xq_tsql_cast() & co., runtime.zig).
//!
//! | SQL Server                                   | storage | check                      |
//! |----------------------------------------------|---------|----------------------------|
//! | bigint                                       | INTEGER |                            |
//! | int, smallint, tinyint                       | INTEGER | the type's range           |
//! | bit                                          | INTEGER | 0 or 1                     |
//! | decimal/numeric(p,s), money, smallmoney      | REAL    |                            |
//! | float, real                                  | REAL    |                            |
//! | [n]char(n), [n]varchar(n)                    | TEXT    | length <= n                |
//! | [n]varchar(max), [n]text, xml, sql_variant   | TEXT    |                            |
//! | binary(n), varbinary(n)                      | BLOB    | length <= n                |
//! | varbinary(max), image                        | BLOB    |                            |
//! | date, time, datetime, datetime2, smalldatetime, datetimeoffset | TEXT |          |
//! | uniqueidentifier                             | TEXT    |                            |
//!
//! The canonical spelling (format()) is lower case, as SQL Server's
//! INFORMATION_SCHEMA writes types: "int", "varchar(20)", "nvarchar(max)",
//! "decimal(10,2)", "datetime2(7)". It is what xq_catalog records and
//! what the runtime conversion parses again (parseText()).

const std = @import("std");

pub const Base = enum {
    bigint,
    int,
    smallint,
    tinyint,
    bit,
    decimal,
    numeric,
    money,
    smallmoney,
    float,
    real,
    char,
    varchar,
    nchar,
    nvarchar,
    text,
    ntext,
    binary,
    varbinary,
    image,
    date,
    time,
    datetime,
    datetime2,
    smalldatetime,
    datetimeoffset,
    uniqueidentifier,
    xml,
    sql_variant,
};

/// `max` as a length.
pub const max_len: i64 = -1;

pub const Type = struct {
    base: Base,
    /// The length of a character/binary type (max_len for MAX), the
    /// precision of decimal/numeric/float, the fractional digits of
    /// time/datetime2/datetimeoffset; null if not written.
    len: ?i64 = null,
    /// The scale of decimal/numeric.
    scale: ?i64 = null,

    pub fn isInteger(t: Type) bool {
        return switch (t.base) {
            .bigint, .int, .smallint, .tinyint, .bit => true,
            else => false,
        };
    }

    pub fn isExactNumeric(t: Type) bool {
        return switch (t.base) {
            .decimal, .numeric, .money, .smallmoney => true,
            else => false,
        };
    }

    pub fn isNumber(t: Type) bool {
        return switch (t.base) {
            .bigint, .int, .smallint, .tinyint, .bit, .decimal, .numeric, .money, .smallmoney, .float, .real => true,
            else => false,
        };
    }

    /// A character string type (compared with the column's collation).
    pub fn isChar(t: Type) bool {
        return switch (t.base) {
            .char, .varchar, .nchar, .nvarchar, .text, .ntext => true,
            else => false,
        };
    }

    pub fn isBinary(t: Type) bool {
        return switch (t.base) {
            .binary, .varbinary, .image => true,
            else => false,
        };
    }

    pub fn isTemporal(t: Type) bool {
        return switch (t.base) {
            .date, .time, .datetime, .datetime2, .smalldatetime, .datetimeoffset => true,
            else => false,
        };
    }

    /// The precision of decimal/numeric (18 by default).
    pub fn precision(t: Type) i64 {
        return switch (t.base) {
            .money => 19,
            .smallmoney => 10,
            else => t.len orelse 18,
        };
    }

    /// The scale of decimal/numeric/money.
    pub fn scaleOf(t: Type) i64 {
        return switch (t.base) {
            .money, .smallmoney => 4,
            else => t.scale orelse 0,
        };
    }

    /// The length limit of a character or binary type: n, 1 if not
    /// written (char, varchar, binary, varbinary in a column definition),
    /// null for MAX and the unlimited types.
    pub fn maxLength(t: Type) ?i64 {
        if (!(t.isChar() or t.isBinary())) return null;
        switch (t.base) {
            .text, .ntext, .image => return null,
            else => {},
        }
        const n = t.len orelse 1;
        if (n == max_len) return null;
        return n;
    }

    /// The STRICT storage type.
    pub fn storage(t: Type) [:0]const u8 {
        if (t.isInteger()) return "INTEGER";
        if (t.isNumber()) return "REAL";
        if (t.isBinary()) return "BLOB";
        if (t.base == .sql_variant) return "ANY";
        return "TEXT";
    }

    /// The integer range of an integer type with a CHECK.
    pub fn range(t: Type) ?struct { i64, i64 } {
        return switch (t.base) {
            .int => .{ -2147483648, 2147483647 },
            .smallint => .{ -32768, 32767 },
            .tinyint => .{ 0, 255 },
            .bit => .{ 0, 1 },
            else => null,
        };
    }

    /// The fractional seconds digits of a time type (7 by default).
    pub fn fracDigits(t: Type) u8 {
        return switch (t.base) {
            .datetime => 3,
            .smalldatetime, .date => 0,
            else => @intCast(std.math.clamp(t.len orelse 7, 0, 7)),
        };
    }
};

const names = [_]struct { []const u8, Base }{
    .{ "bigint", .bigint },               .{ "int", .int },                       .{ "integer", .int },
    .{ "smallint", .smallint },           .{ "tinyint", .tinyint },               .{ "bit", .bit },
    .{ "decimal", .decimal },             .{ "dec", .decimal },                   .{ "numeric", .numeric },
    .{ "money", .money },                 .{ "smallmoney", .smallmoney },         .{ "float", .float },
    .{ "real", .real },                   .{ "char", .char },                     .{ "character", .char },
    .{ "varchar", .varchar },             .{ "nchar", .nchar },                   .{ "nvarchar", .nvarchar },
    .{ "text", .text },                   .{ "ntext", .ntext },                   .{ "binary", .binary },
    .{ "varbinary", .varbinary },         .{ "image", .image },                   .{ "date", .date },
    .{ "time", .time },                   .{ "datetime", .datetime },             .{ "datetime2", .datetime2 },
    .{ "smalldatetime", .smalldatetime }, .{ "datetimeoffset", .datetimeoffset }, .{ "uniqueidentifier", .uniqueidentifier },
    .{ "xml", .xml },                     .{ "sql_variant", .sql_variant },       .{ "sysname", .nvarchar },
    .{ "rowversion", .binary },           .{ "timestamp", .binary },
};

/// The base type called `name` (case-insensitive), null if unknown.
pub fn baseByName(name: []const u8) ?Base {
    for (names) |n| if (std.ascii.eqlIgnoreCase(n[0], name)) return n[1];
    return null;
}

/// The defaults SQL Server gives types written without modifiers in a
/// column definition (sysname is nvarchar(128), timestamp binary(8)).
pub fn columnDefaults(name: []const u8, t: Type) Type {
    var x = t;
    if (std.ascii.eqlIgnoreCase(name, "sysname") and x.len == null) x.len = 128;
    if ((std.ascii.eqlIgnoreCase(name, "rowversion") or std.ascii.eqlIgnoreCase(name, "timestamp")) and x.len == null) x.len = 8;
    if (x.base == .float and x.len != null and x.len.? <= 24) return .{ .base = .real };
    if (x.base == .float) x.len = null;
    return x;
}

/// The canonical spelling: "int", "varchar(20)", "nvarchar(max)",
/// "decimal(10,2)", "datetime2(7)".
pub fn format(a: std.mem.Allocator, t: Type) error{OutOfMemory}![]const u8 {
    const n = @tagName(t.base);
    switch (t.base) {
        .decimal, .numeric => return std.fmt.allocPrint(a, "{s}({d},{d})", .{ n, t.precision(), t.scale orelse 0 }),
        .char, .varchar, .nchar, .nvarchar, .binary, .varbinary => {
            const len = t.len orelse 1;
            if (len == max_len) return std.fmt.allocPrint(a, "{s}(max)", .{n});
            return std.fmt.allocPrint(a, "{s}({d})", .{ n, len });
        },
        .time, .datetime2, .datetimeoffset => return std.fmt.allocPrint(a, "{s}({d})", .{ n, t.fracDigits() }),
        else => return n,
    }
}

/// The type a canonical spelling (or any spelling: "VARCHAR ( 10 )",
/// "nvarchar(MAX)", "decimal(10, 2)") stands for, null if none.
pub fn parseText(z_in: []const u8) ?Type {
    const z = std.mem.trim(u8, z_in, " ");
    const paren = std.mem.indexOfScalar(u8, z, '(');
    const name = std.mem.trimEnd(u8, z[0 .. paren orelse z.len], " ");
    var t: Type = .{ .base = baseByName(name) orelse return null };
    if (paren) |i| {
        const close = std.mem.lastIndexOfScalar(u8, z, ')') orelse return null;
        if (close < i) return null;
        var it = std.mem.splitScalar(u8, z[i + 1 .. close], ',');
        const first = std.mem.trim(u8, it.next() orelse return null, " ");
        t.len = if (std.ascii.eqlIgnoreCase(first, "max")) max_len else std.fmt.parseInt(i64, first, 10) catch return null;
        if (it.next()) |second| t.scale = std.fmt.parseInt(i64, std.mem.trim(u8, second, " "), 10) catch return null;
    }
    return columnDefaults(name, t);
}

test "types: spellings and storage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "INT", "int", "INTEGER" },
        .{ "varchar(20)", "varchar(20)", "TEXT" },
        .{ "NVARCHAR(MAX)", "nvarchar(max)", "TEXT" },
        .{ "decimal(10, 2)", "decimal(10,2)", "REAL" },
        .{ "numeric(9)", "numeric(9,0)", "REAL" },
        .{ "decimal", "decimal(18,0)", "REAL" },
        .{ "float(10)", "real", "REAL" },
        .{ "datetime2", "datetime2(7)", "TEXT" },
        .{ "varbinary(16)", "varbinary(16)", "BLOB" },
        .{ "sysname", "nvarchar(128)", "TEXT" },
    };
    for (cases) |c| {
        const t = parseText(c[0]).?;
        try std.testing.expectEqualStrings(c[1], try format(a, t));
        try std.testing.expectEqualStrings(c[2], t.storage());
    }
    try std.testing.expect(parseText("nope") == null);
    try std.testing.expectEqual(@as(?i64, 1), parseText("char").?.maxLength());
    try std.testing.expectEqual(@as(?i64, null), parseText("varchar(max)").?.maxLength());
}
