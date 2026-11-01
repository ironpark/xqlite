//! Result columns in the MySQL protocol: the column definition
//! (ColumnDefinition41) of a column's type, and its values in text rows
//! (COM_QUERY) and binary rows (COM_STMT_EXECUTE).
//!
//! The type comes from the session's Column: types.Logical, and the
//! declared type's text for what Logical does not tell apart (UNSIGNED,
//! MEDIUMINT, YEAR, BIT, ENUM, SET, the byte strings). A column whose
//! type is not known (an expression without one) is a VAR_STRING, its
//! values as SQLite writes them.

const std = @import("std");
const xqlite = @import("xqlite");
const c = @import("consts.zig");
const packet = @import("packet.zig");

const Allocator = std.mem.Allocator;
const Value = xqlite.Value;
const types = xqlite.types;

/// What the protocol says of a column, and how its values are written.
pub const Field = struct {
    type: c.Type,
    flags: u16 = 0,
    decimals: u8 = 0,
    charset: u16 = c.Charset.utf8mb4,
    /// The display length in bytes (characters × 4 for utf8mb4).
    length: u32 = 0,
    /// The column's type, for display.text().
    t: types.Type = .{ .logical = .unknown },
    /// The bytes of a BIT(n) value.
    bit_bytes: u8 = 8,
};

/// The field of a column of type `t`, declared as `name` (null for an
/// expression of no declared type).
pub fn field(t_in: types.Type, name: ?[]const u8) Field {
    const words: Words = .init(name orelse "");
    // MariaDB's attributes after the type ("int(10) unsigned"), which
    // types.parse() does not read.
    var buf: [64]u8 = undefined;
    const t = if (t_in.logical == .unknown and name != null) types.parse(.mariadb, words.withoutAttributes(&buf)) else t_in;
    const unsigned: u16 = if (words.has("unsigned")) c.Flag.unsigned else 0;
    const zerofill: u16 = if (words.has("zerofill")) c.Flag.zerofill | c.Flag.unsigned else 0;
    const num = c.Flag.num | c.Flag.binary | unsigned | zerofill;
    const base = words.base();
    // What Logical does not tell apart.
    if (eq(base, "year")) return .{ .type = .year, .flags = num | c.Flag.unsigned, .charset = c.Charset.binary, .length = 4, .t = t };
    if (eq(base, "bit")) {
        const bits: u32 = if (words.arg) |n| @intCast(std.math.clamp(n, 1, 64)) else 1;
        return .{ .type = .bit, .flags = c.Flag.unsigned, .charset = c.Charset.binary, .length = bits, .t = t, .bit_bytes = @intCast((bits + 7) / 8) };
    }
    if (eq(base, "enum")) return .{ .type = .string, .flags = c.Flag.@"enum", .length = 4 * 255, .t = t };
    if (eq(base, "set")) return .{ .type = .string, .flags = c.Flag.set, .length = 4 * 255, .t = t };
    if (eq(base, "mediumint")) return .{ .type = .int24, .flags = num, .charset = c.Charset.binary, .length = if (unsigned != 0) 8 else 9, .t = t };
    const signed: u32 = if (unsigned != 0) 0 else 1;
    return switch (t.logical) {
        .unknown, .interval => .{ .type = .var_string, .t = t },
        .boolean => .{ .type = .tiny, .flags = num, .charset = c.Charset.binary, .length = 1, .t = t },
        .int1 => .{ .type = .tiny, .flags = num, .charset = c.Charset.binary, .length = 3 + signed, .t = t },
        .int2 => .{ .type = .short, .flags = num, .charset = c.Charset.binary, .length = 5 + signed, .t = t },
        .int4 => .{ .type = .long, .flags = num, .charset = c.Charset.binary, .length = 10 + signed, .t = t },
        .int8 => .{ .type = .longlong, .flags = num, .charset = c.Charset.binary, .length = 20, .t = t },
        .float4 => .{ .type = .float, .flags = num, .charset = c.Charset.binary, .length = 12, .decimals = c.not_fixed_dec, .t = t },
        .float8 => .{ .type = .double, .flags = num, .charset = c.Charset.binary, .length = 22, .decimals = c.not_fixed_dec, .t = t },
        .numeric => blk: {
            const p: u32 = t.precision orelse 65;
            const s: u8 = t.scale orelse 0;
            break :blk .{ .type = .newdecimal, .flags = num, .charset = c.Charset.binary, .decimals = s, .length = p + @intFromBool(s > 0) + signed, .t = t };
        },
        .varchar => .{ .type = .var_string, .length = 4 *| (t.length orelse 65535), .t = t },
        .char, .uuid => .{ .type = .string, .length = 4 *| (t.length orelse @as(u32, if (t.logical == .uuid) 36 else 1)), .t = t },
        // A string expression (of no declared type) is a VAR_STRING, as
        // in MariaDB; a TEXT column a BLOB of utf8mb4.
        .text, .json, .jsonb => if (name == null)
            .{ .type = .var_string, .t = t }
        else
            .{ .type = .blob, .flags = c.Flag.blob, .length = textLength(base), .t = t },
        .bytes => if (name == null or eq(base, "varbinary"))
            .{ .type = .var_string, .flags = c.Flag.binary, .charset = c.Charset.binary, .length = t.length orelse 65535, .t = t }
        else if (eq(base, "binary"))
            .{ .type = .string, .flags = c.Flag.binary, .charset = c.Charset.binary, .length = t.length orelse 1, .t = t }
        else
            .{ .type = .blob, .flags = c.Flag.blob | c.Flag.binary, .charset = c.Charset.binary, .length = textLength(base), .t = t },
        .date => .{ .type = .date, .flags = c.Flag.binary, .charset = c.Charset.binary, .length = 10, .t = t },
        .time, .time_tz => .{ .type = .time, .flags = c.Flag.binary, .charset = c.Charset.binary, .decimals = t.scale orelse 0, .length = 10 + fraction(t), .t = t },
        .timestamp, .timestamp_tz => .{
            .type = if (eq(base, "timestamp") or t.logical == .timestamp_tz) .timestamp else .datetime,
            .flags = c.Flag.binary,
            .charset = c.Charset.binary,
            .decimals = t.scale orelse 0,
            .length = 19 + fraction(t),
            .t = t,
        },
    };
}

/// `f` with the flags of a table column's constraints.
pub fn withConstraints(f: Field, cc: ?xqlite.ColumnConstraints) Field {
    const k = cc orelse return f;
    var g = f;
    if (k.not_null or k.primary_key) g.flags |= c.Flag.not_null;
    if (k.primary_key) g.flags |= c.Flag.pri_key;
    if (k.autoincrement) g.flags |= c.Flag.auto_increment;
    if (k.unique) g.flags |= c.Flag.unique_key;
    if (k.indexed) g.flags |= c.Flag.multiple_key;
    return g;
}

fn fraction(t: types.Type) u32 {
    const s = t.scale orelse 0;
    return if (s > 0) @as(u32, s) + 1 else 0;
}

fn textLength(base: []const u8) u32 {
    if (std.mem.startsWith(u8, base, "tiny")) return 255;
    if (std.mem.startsWith(u8, base, "medium")) return 16777215;
    if (eq(base, "text") or eq(base, "blob")) return 65535;
    return std.math.maxInt(u32);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The words of a declared type: its first word and argument, and
/// whether a word follows ("int(10) unsigned zerofill").
const Words = struct {
    text: []const u8,
    arg: ?i64,

    fn init(name: []const u8) Words {
        const open = std.mem.indexOfScalar(u8, name, '(');
        var arg: ?i64 = null;
        if (open) |o| {
            const close = std.mem.indexOfScalarPos(u8, name, o, ')') orelse name.len;
            var it = std.mem.splitScalar(u8, name[o + 1 .. close], ',');
            arg = std.fmt.parseInt(i64, std.mem.trim(u8, it.first(), " \t"), 10) catch null;
        }
        return .{ .text = name, .arg = arg };
    }

    fn base(w: *const Words) []const u8 {
        const end = std.mem.indexOfAny(u8, w.text, "( \t") orelse w.text.len;
        return w.text[0..end];
    }

    /// The text without UNSIGNED, SIGNED and ZEROFILL.
    fn withoutAttributes(w: *const Words, buf: []u8) []const u8 {
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, w.text, " \t");
        while (it.next()) |x| {
            if (eq(x, "unsigned") or eq(x, "signed") or eq(x, "zerofill")) continue;
            if (n + x.len + 1 > buf.len) break;
            if (n > 0) {
                buf[n] = ' ';
                n += 1;
            }
            @memcpy(buf[n..][0..x.len], x);
            n += x.len;
        }
        return buf[0..n];
    }

    fn has(w: *const Words, word: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, w.text, " \t()");
        while (it.next()) |x| if (eq(x, word)) return true;
        return false;
    }
};

/// Where a result column comes from, as the column definition says.
pub const Source = struct {
    /// The database (schema): MariaDB's name of the table's database.
    schema: []const u8 = "",
    table: []const u8 = "",
    org_table: []const u8 = "",
    name: []const u8,
    org_name: []const u8 = "",
};

/// The source of a column that reads table column `o` (null for an
/// expression). A table of a database of CREATE DATABASE is the main
/// table "db.t" (docs/mariadb.md, Databases).
pub fn source(name: []const u8, origin: ?xqlite.Origin) Source {
    const o = origin orelse return .{ .name = name };
    var schema = o.database;
    var table = o.table;
    if (std.ascii.eqlIgnoreCase(schema, "main")) {
        if (std.mem.indexOfScalar(u8, table, '.')) |dot| {
            schema = table[0..dot];
            table = table[dot + 1 ..];
        }
    }
    return .{ .schema = schema, .table = table, .org_table = table, .name = name, .org_name = o.column };
}

/// A ColumnDefinition41 payload. `default` (COM_FIELD_LIST only) adds
/// the default value, here always NULL.
pub fn writeDefinition(gpa: Allocator, b: *std.ArrayList(u8), src: Source, f: Field, default: bool) !void {
    try packet.lenencStr(gpa, b, "def");
    try packet.lenencStr(gpa, b, src.schema);
    try packet.lenencStr(gpa, b, src.table);
    try packet.lenencStr(gpa, b, src.org_table);
    try packet.lenencStr(gpa, b, src.name);
    try packet.lenencStr(gpa, b, src.org_name);
    // The length of the fixed fields.
    try packet.lenenc(gpa, b, 0x0C);
    try packet.int2(gpa, b, f.charset);
    try packet.int4(gpa, b, f.length);
    try packet.int1(gpa, b, @backingInt(f.type));
    try packet.int2(gpa, b, f.flags);
    try packet.int1(gpa, b, f.decimals);
    try packet.int2(gpa, b, 0);
    if (default) try packet.int1(gpa, b, c.null_value);
}

// ================================================================== values

/// How a value reads as text where SQLite's text is needed (a float), as
/// the statement converts it (Stmt.column([]const u8, i)).
pub const Cell = struct {
    stmt: *xqlite.Stmt,
    i: usize,

    pub fn value(cell: Cell) !Value {
        return cell.stmt.column(Value, cell.i);
    }

    pub fn sqliteText(cell: Cell) ![]const u8 {
        return cell.stmt.column([]const u8, cell.i);
    }
};

/// Write `cell`, a value of a column of field `f`, in a text row.
pub fn writeText(gpa: Allocator, b: *std.ArrayList(u8), viewer: xqlite.Dialect, f: Field, cell: Cell) !void {
    const v = try cell.value();
    switch (v) {
        .null => return packet.int1(gpa, b, c.null_value),
        .blob => |x| return packet.lenencStr(gpa, b, x),
        else => {},
    }
    if (f.type == .bit) {
        var bytes: [8]u8 = undefined;
        return packet.lenencStr(gpa, b, bitBytes(f, v, &bytes));
    }
    var buf: [xqlite.display.max_len]u8 = undefined;
    if (xqlite.display.text(viewer, f.t, v, &buf)) |t| return packet.lenencStr(gpa, b, t);
    switch (v) {
        .integer => |x| {
            const t = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
            try packet.lenencStr(gpa, b, t);
        },
        .text => |x| try packet.lenencStr(gpa, b, x),
        .float => try packet.lenencStr(gpa, b, try cell.sqliteText()),
        .null, .blob => unreachable,
    }
}

/// The big-endian bytes of a BIT(n) value.
fn bitBytes(f: Field, v: Value, buf: *[8]u8) []const u8 {
    const x: u64 = @bitCast(asInt(v));
    std.mem.writeInt(u64, buf, x, .big);
    return buf[8 - f.bit_bytes ..];
}

/// The integer of a value of an integer column.
fn asInt(v: Value) i64 {
    return switch (v) {
        .integer => |x| x,
        .float => |x| if (std.math.isFinite(x)) std.math.lossyCast(i64, @round(x)) else 0,
        .text, .blob => |x| std.fmt.parseInt(i64, std.mem.trim(u8, x, " "), 10) catch
            if (std.fmt.parseFloat(f64, std.mem.trim(u8, x, " "))) |d| std.math.lossyCast(i64, @round(d)) else |_| 0,
        .null => 0,
    };
}

fn asFloat(v: Value) f64 {
    return switch (v) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        .text, .blob => |x| std.fmt.parseFloat(f64, std.mem.trim(u8, x, " ")) catch 0,
        .null => 0,
    };
}

/// Whether column `i` is NULL in a binary row (the null bitmap).
pub fn isNull(cell: Cell) bool {
    return cell.stmt.columnKind(cell.i) == .null;
}

/// Write `cell`, not NULL, in a binary row (the binary protocol value
/// of the field's type).
pub fn writeBinary(gpa: Allocator, b: *std.ArrayList(u8), viewer: xqlite.Dialect, f: Field, cell: Cell) !void {
    const v = try cell.value();
    switch (f.type) {
        .tiny => try packet.int1(gpa, b, @truncate(@as(u64, @bitCast(asInt(v))))),
        .short, .year => try packet.int2(gpa, b, @truncate(@as(u64, @bitCast(asInt(v))))),
        .long, .int24 => try packet.int4(gpa, b, @truncate(@as(u64, @bitCast(asInt(v))))),
        .longlong => try packet.int8(gpa, b, @bitCast(asInt(v))),
        .float => try packet.int4(gpa, b, @bitCast(@as(f32, @floatCast(asFloat(v))))),
        .double => try packet.int8(gpa, b, @bitCast(asFloat(v))),
        .date, .datetime, .timestamp => {
            const d = parseDateTime(textOf(v)) orelse DateTime{};
            try writeDateTime(gpa, b, d, f.type == .date);
        },
        .time => {
            const t = parseTime(textOf(v)) orelse Time{};
            try writeTime(gpa, b, t);
        },
        else => try writeText(gpa, b, viewer, f, cell),
    }
}

fn textOf(v: Value) []const u8 {
    return switch (v) {
        .text, .blob => |x| x,
        else => "",
    };
}

pub const DateTime = struct {
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    micro: u32 = 0,
};

pub const Time = struct {
    negative: bool = false,
    /// Hours past 24 are days.
    hours: u32 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    micro: u32 = 0,
};

/// "YYYY-MM-DD[ HH:MM:SS[.ffffff]]" ('T' for the space too).
pub fn parseDateTime(z: []const u8) ?DateTime {
    const s = std.mem.trim(u8, z, " ");
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    var d: DateTime = .{
        .year = digits(u16, s[0..4]) orelse return null,
        .month = digits(u8, s[5..7]) orelse return null,
        .day = digits(u8, s[8..10]) orelse return null,
    };
    if (s.len == 10) return d;
    if (s[10] != ' ' and s[10] != 'T') return null;
    const t = parseTime(s[11..]) orelse return null;
    if (t.negative or t.hours > 23) return null;
    d.hour = @intCast(t.hours);
    d.minute = t.minute;
    d.second = t.second;
    d.micro = t.micro;
    return d;
}

/// "[-]H+:MM[:SS[.ffffff]]".
pub fn parseTime(z: []const u8) ?Time {
    var s = std.mem.trim(u8, z, " ");
    var t: Time = .{};
    if (s.len > 0 and s[0] == '-') {
        t.negative = true;
        s = s[1..];
    }
    const c1 = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    t.hours = digits(u32, s[0..c1]) orelse return null;
    s = s[c1 + 1 ..];
    if (s.len < 2) return null;
    t.minute = digits(u8, s[0..2]) orelse return null;
    s = s[2..];
    if (s.len == 0) return t;
    if (s[0] != ':' or s.len < 3) return null;
    t.second = digits(u8, s[1..3]) orelse return null;
    s = s[3..];
    if (s.len == 0) return t;
    if (s[0] != '.') return null;
    const frac = s[1..];
    if (frac.len == 0 or frac.len > 9) return null;
    var micro: u32 = 0;
    for (0..6) |k| micro = micro * 10 + if (k < frac.len) (std.fmt.charToDigit(frac[k], 10) catch return null) else 0;
    t.micro = micro;
    return t;
}

fn digits(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// The binary DATE/DATETIME/TIMESTAMP value: a length (0, 4, 7 or 11),
/// then what is not zero.
pub fn writeDateTime(gpa: Allocator, b: *std.ArrayList(u8), d: DateTime, date_only: bool) !void {
    const n: u8 = if (d.micro != 0 and !date_only)
        11
    else if ((d.hour != 0 or d.minute != 0 or d.second != 0) and !date_only)
        7
    else if (d.year != 0 or d.month != 0 or d.day != 0)
        4
    else
        0;
    try packet.int1(gpa, b, n);
    if (n == 0) return;
    try packet.int2(gpa, b, d.year);
    try packet.int1(gpa, b, d.month);
    try packet.int1(gpa, b, d.day);
    if (n == 4) return;
    try packet.int1(gpa, b, d.hour);
    try packet.int1(gpa, b, d.minute);
    try packet.int1(gpa, b, d.second);
    if (n == 11) try packet.int4(gpa, b, d.micro);
}

/// The binary TIME value: a length (0, 8 or 12), the sign, days, hours,
/// minutes, seconds and microseconds.
pub fn writeTime(gpa: Allocator, b: *std.ArrayList(u8), t: Time) !void {
    const n: u8 = if (t.micro != 0) 12 else if (t.hours != 0 or t.minute != 0 or t.second != 0) 8 else 0;
    try packet.int1(gpa, b, n);
    if (n == 0) return;
    try packet.int1(gpa, b, @intFromBool(t.negative));
    try packet.int4(gpa, b, t.hours / 24);
    try packet.int1(gpa, b, @intCast(t.hours % 24));
    try packet.int1(gpa, b, t.minute);
    try packet.int1(gpa, b, t.second);
    if (n == 12) try packet.int4(gpa, b, t.micro);
}

test field {
    const T = std.testing;
    // types.parse() does not read "unsigned".
    const f2 = field(types.parse(.mariadb, "int(10) unsigned"), "int(10) unsigned");
    try T.expectEqual(c.Type.long, f2.type);
    try T.expect(f2.flags & c.Flag.unsigned != 0);
    const f3 = field(.{ .logical = .unknown }, "bit(3)");
    try T.expectEqual(c.Type.bit, f3.type);
    try T.expectEqual(@as(u8, 1), f3.bit_bytes);
    const f4 = field(.{ .logical = .numeric, .precision = 10, .scale = 2 }, "decimal(10,2)");
    try T.expectEqual(c.Type.newdecimal, f4.type);
    try T.expectEqual(@as(u8, 2), f4.decimals);
    try T.expectEqual(@as(u32, 12), f4.length);
    try T.expectEqual(c.Type.blob, field(.{ .logical = .text }, "longtext").type);
    try T.expectEqual(c.Type.var_string, field(.{ .logical = .unknown }, null).type);
    try T.expectEqual(c.Type.string, field(.{ .logical = .unknown }, "enum('a','b')").type);
    try T.expectEqual(c.Type.datetime, field(.{ .logical = .timestamp, .scale = 3 }, "datetime(3)").type);
    try T.expectEqual(c.Type.timestamp, field(.{ .logical = .timestamp }, "timestamp").type);
    const f5 = field(.{ .logical = .unknown }, "bigint(20) unsigned zerofill");
    try T.expectEqual(c.Type.longlong, f5.type);
    try T.expect(f5.flags & c.Flag.zerofill != 0);
}

test "date and time text" {
    const T = std.testing;
    try T.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .micro = 500000 }, parseDateTime("2024-01-02 03:04:05.5").?);
    try T.expectEqual(DateTime{ .year = 2024, .month = 1, .day = 2 }, parseDateTime("2024-01-02").?);
    try T.expectEqual(@as(?DateTime, null), parseDateTime("2024-01-02x"));
    try T.expectEqual(Time{ .negative = true, .hours = 838, .minute = 59, .second = 59 }, parseTime("-838:59:59").?);
    try T.expectEqual(Time{ .hours = 1, .minute = 2, .second = 3, .micro = 4 }, parseTime("01:02:03.000004").?);
}
