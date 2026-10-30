//! Oracle types: how a declared type is stored in a STRICT table, what
//! checks it adds, how the catalog spells it (the spelling
//! xq_ora_coerce() and xq_ora_cast() read back at run time), and its
//! family, which says what a value stored into it becomes.
//!
//! | Oracle                                   | storage | check                     |
//! |------------------------------------------|---------|---------------------------|
//! | NUMBER, NUMBER(p,s) (s > 0), FLOAT(b)    | ANY     | a number; the precision   |
//! | NUMBER(p), NUMBER(p,0) (p <= 18), INTEGER | INTEGER | the precision             |
//! | BINARY_FLOAT, BINARY_DOUBLE              | REAL    |                           |
//! | VARCHAR2(n [BYTE|CHAR]), NVARCHAR2(n)    | TEXT    | the length                |
//! | CHAR(n), NCHAR(n)                        | TEXT    | the length                |
//! | CLOB, NCLOB, LONG                        | TEXT    |                           |
//! | DATE, TIMESTAMP[(p)] [WITH [LOCAL] TIME ZONE], INTERVAL | TEXT |             |
//! | BLOB, RAW(n), LONG RAW                   | BLOB    | the length (RAW)          |
//! | BOOLEAN                                  | INTEGER | 0 or 1                    |
//!
//! A check is a named CHECK constraint whose name is Oracle's message
//! ("ORA-12899: value too large for column (maximum: 20)").

const std = @import("std");

pub const Family = enum {
    number,
    binary_float,
    varchar,
    char,
    clob,
    date,
    timestamp,
    interval,
    blob,
    raw,
    boolean,
    rowid,
};

/// A type as Oracle names it: `name` canonical upper case (NUMBER,
/// VARCHAR2, TIMESTAMP WITH TIME ZONE ...).
pub const TypeName = struct {
    name: []const u8,
    /// NUMBER(p), VARCHAR2(n), RAW(n), TIMESTAMP(p), FLOAT(b).
    precision: ?i64 = null,
    /// NUMBER(p, s); NUMBER(*, 0) has a scale without a precision.
    scale: ?i64 = null,
    /// VARCHAR2(n CHAR) (or NVARCHAR2, NCHAR): the length counts
    /// characters, not bytes.
    char_semantics: bool = false,
    pos: u32 = 0,
};

pub const Check = enum { none, number, precision, length, boolean };

pub const Info = struct {
    family: Family,
    /// The STRICT storage type.
    storage: [:0]const u8,
    /// A number (ANY): typeof() integer or real.
    numeric: bool = false,
    /// NUMBER(p[,s]): |x| < 10^(p-s).
    precision: bool = false,
    /// VARCHAR2(n), CHAR(n), RAW(n): length <= n.
    length: bool = false,
    boolean: bool = false,
};

pub const Error = error{UnknownType};

const families = [_]struct { []const u8, Family }{
    .{ "NUMBER", .number },
    .{ "FLOAT", .number },
    .{ "BINARY_FLOAT", .binary_float },
    .{ "BINARY_DOUBLE", .binary_float },
    .{ "VARCHAR2", .varchar },
    .{ "NVARCHAR2", .varchar },
    .{ "CHAR", .char },
    .{ "NCHAR", .char },
    .{ "CLOB", .clob },
    .{ "NCLOB", .clob },
    .{ "LONG", .clob },
    .{ "DATE", .date },
    .{ "TIMESTAMP", .timestamp },
    .{ "TIMESTAMP WITH TIME ZONE", .timestamp },
    .{ "TIMESTAMP WITH LOCAL TIME ZONE", .timestamp },
    .{ "INTERVAL YEAR TO MONTH", .interval },
    .{ "INTERVAL DAY TO SECOND", .interval },
    .{ "BLOB", .blob },
    .{ "LONG RAW", .blob },
    .{ "RAW", .raw },
    .{ "BOOLEAN", .boolean },
    .{ "ROWID", .rowid },
    .{ "UROWID", .rowid },
};

pub fn family(name: []const u8) ?Family {
    for (families) |f| if (std.ascii.eqlIgnoreCase(f[0], name)) return f[1];
    return null;
}

/// The storage and checks of declared type `ty`.
pub fn info(ty: TypeName) Error!Info {
    const f = family(ty.name) orelse return error.UnknownType;
    return switch (f) {
        .number => blk: {
            if (std.mem.eql(u8, ty.name, "NUMBER") and ty.scale != null and ty.scale.? <= 0 and (ty.precision orelse 0) <= 18) {
                break :blk .{ .family = f, .storage = "INTEGER", .precision = ty.precision != null };
            }
            if (std.mem.eql(u8, ty.name, "NUMBER") and ty.precision != null and ty.scale == null and ty.precision.? <= 18) {
                break :blk .{ .family = f, .storage = "INTEGER", .precision = true };
            }
            break :blk .{ .family = f, .storage = "ANY", .numeric = true, .precision = std.mem.eql(u8, ty.name, "NUMBER") and ty.precision != null };
        },
        .binary_float => .{ .family = f, .storage = "REAL" },
        .varchar, .char => .{ .family = f, .storage = "TEXT", .length = ty.precision != null },
        .clob, .date, .timestamp, .interval, .rowid => .{ .family = f, .storage = "TEXT" },
        .blob => .{ .family = f, .storage = "BLOB" },
        .raw => .{ .family = f, .storage = "BLOB", .length = ty.precision != null },
        .boolean => .{ .family = f, .storage = "INTEGER", .boolean = true },
    };
}

/// The precision of NUMBER(p, s) as a bound: |x| < 10^(p - s); null when
/// it is too large to matter.
pub fn precisionBound(ty: TypeName) ?f64 {
    const p = ty.precision orelse return null;
    const s = ty.scale orelse 0;
    const digits = p - s;
    if (digits > 30) return null;
    return std.math.pow(f64, 10, @floatFromInt(digits));
}

/// The catalog spelling of a type: NUMBER(10,2), NUMBER(*,0) (INTEGER),
/// VARCHAR2(20), VARCHAR2(20 CHAR), TIMESTAMP(6) WITH TIME ZONE, FLOAT(126)
/// ... (what xq_ora_coerce() reads back: parse()).
pub fn format(a: std.mem.Allocator, ty: TypeName) error{OutOfMemory}![]const u8 {
    const n = ty.name;
    if (std.mem.startsWith(u8, n, "TIMESTAMP")) {
        const p = ty.precision orelse 6;
        return std.fmt.allocPrint(a, "TIMESTAMP({d}){s}", .{ p, n["TIMESTAMP".len..] });
    }
    if (ty.precision == null and ty.scale == null) {
        if (std.mem.eql(u8, n, "FLOAT")) return "FLOAT(126)";
        if (std.mem.eql(u8, n, "CHAR") or std.mem.eql(u8, n, "NCHAR")) return std.fmt.allocPrint(a, "{s}(1)", .{n});
        return n;
    }
    if (std.mem.eql(u8, n, "NUMBER")) {
        if (ty.precision) |p| {
            if (ty.scale) |s| if (s != 0) return std.fmt.allocPrint(a, "NUMBER({d},{d})", .{ p, s });
            return std.fmt.allocPrint(a, "NUMBER({d})", .{p});
        }
        return std.fmt.allocPrint(a, "NUMBER(*,{d})", .{ty.scale.?});
    }
    if (ty.char_semantics and (std.mem.eql(u8, n, "VARCHAR2") or std.mem.eql(u8, n, "CHAR"))) {
        return std.fmt.allocPrint(a, "{s}({d} CHAR)", .{ n, ty.precision.? });
    }
    return std.fmt.allocPrint(a, "{s}({d})", .{ n, ty.precision.? });
}

/// The type a catalog spelling (format()) or a CAST target names.
pub fn parse(spelling: []const u8) ?TypeName {
    var ty: TypeName = .{ .name = spelling };
    const open = std.mem.indexOfScalar(u8, spelling, '(') orelse return if (family(spelling) != null) ty else null;
    const close = std.mem.indexOfScalarPos(u8, spelling, open, ')') orelse return null;
    ty.name = spelling[0..open];
    const rest = std.mem.trim(u8, spelling[close + 1 ..], " ");
    if (rest.len > 0) {
        // TIMESTAMP(6) WITH TIME ZONE
        if (std.ascii.eqlIgnoreCase(rest, "WITH TIME ZONE")) ty.name = "TIMESTAMP WITH TIME ZONE";
        if (std.ascii.eqlIgnoreCase(rest, "WITH LOCAL TIME ZONE")) ty.name = "TIMESTAMP WITH LOCAL TIME ZONE";
    }
    var mods = std.mem.splitScalar(u8, spelling[open + 1 .. close], ',');
    const first = std.mem.trim(u8, mods.next() orelse "", " ");
    var first_num = first;
    if (std.mem.endsWith(u8, first, " CHAR")) {
        ty.char_semantics = true;
        first_num = first[0 .. first.len - 5];
    } else if (std.mem.endsWith(u8, first, " BYTE")) {
        first_num = first[0 .. first.len - 5];
    }
    if (!std.mem.eql(u8, first_num, "*")) ty.precision = std.fmt.parseInt(i64, first_num, 10) catch return null;
    if (mods.next()) |s| ty.scale = std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch return null;
    if (std.mem.eql(u8, ty.name, "NCHAR") or std.mem.eql(u8, ty.name, "NVARCHAR2")) ty.char_semantics = true;
    if (family(ty.name) == null) return null;
    return ty;
}

/// The fractional digits of a TIMESTAMP(p) (6 by default).
pub fn fractionDigits(ty: TypeName) u32 {
    return @intCast(std.math.clamp(ty.precision orelse 6, 0, 9));
}

/// USER_TAB_COLUMNS.DATA_TYPE of a catalog spelling: NUMBER, VARCHAR2,
/// TIMESTAMP(6) WITH TIME ZONE ...
pub fn dataTypeName(a: std.mem.Allocator, ty: TypeName) error{OutOfMemory}![]const u8 {
    if (std.mem.startsWith(u8, ty.name, "TIMESTAMP")) {
        return std.fmt.allocPrint(a, "TIMESTAMP({d}){s}", .{ fractionDigits(ty), ty.name["TIMESTAMP".len..] });
    }
    return ty.name;
}

/// USER_TAB_COLUMNS.DATA_LENGTH.
pub fn dataLength(ty: TypeName) i64 {
    const f = family(ty.name) orelse return 0;
    return switch (f) {
        .number => 22,
        .binary_float => if (std.mem.eql(u8, ty.name, "BINARY_FLOAT")) 4 else 8,
        .varchar, .char => blk: {
            const n = ty.precision orelse 1;
            const wide = std.mem.startsWith(u8, ty.name, "N");
            break :blk if (wide) n * 2 else if (ty.char_semantics) n * 4 else n;
        },
        .clob, .blob => 4000,
        .date => 7,
        .timestamp => if (std.mem.eql(u8, ty.name, "TIMESTAMP WITH TIME ZONE")) 13 else 11,
        .interval => 11,
        .raw => ty.precision orelse 2000,
        .boolean => 1,
        .rowid => 10,
    };
}

test "oracle types: spelling round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { TypeName, []const u8 }{
        .{ .{ .name = "NUMBER", .precision = 10, .scale = 2 }, "NUMBER(10,2)" },
        .{ .{ .name = "NUMBER", .scale = 0 }, "NUMBER(*,0)" },
        .{ .{ .name = "NUMBER", .precision = 5 }, "NUMBER(5)" },
        .{ .{ .name = "NUMBER" }, "NUMBER" },
        .{ .{ .name = "VARCHAR2", .precision = 20 }, "VARCHAR2(20)" },
        .{ .{ .name = "VARCHAR2", .precision = 20, .char_semantics = true }, "VARCHAR2(20 CHAR)" },
        .{ .{ .name = "TIMESTAMP WITH TIME ZONE", .precision = 3 }, "TIMESTAMP(3) WITH TIME ZONE" },
        .{ .{ .name = "CHAR" }, "CHAR(1)" },
        .{ .{ .name = "DATE" }, "DATE" },
    };
    for (cases) |c| {
        const s = try format(a, c[0]);
        try std.testing.expectEqualStrings(c[1], s);
        const back = parse(s).?;
        try std.testing.expectEqualStrings(try format(a, back), s);
    }
    try std.testing.expectEqualStrings("INTEGER", (try info(.{ .name = "NUMBER", .scale = 0 })).storage);
    try std.testing.expectEqualStrings("ANY", (try info(.{ .name = "NUMBER", .precision = 10, .scale = 2 })).storage);
    try std.testing.expect(parse("NUMBER(*,0)").?.precision == null);
}
