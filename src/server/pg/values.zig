//! Types and values on the wire: the type OID of each `types.Logical`,
//! the text and binary forms of values as PostgreSQL writes them, and the
//! parameters a client binds (text, or binary for the common types).

const std = @import("std");
const xqlite = @import("xqlite");
const wire = @import("wire.zig");

const types = xqlite.types;
const Type = types.Type;
const Value = xqlite.Value;
const Out = wire.Out;

pub const Oid = u32;

/// PostgreSQL's type OIDs (pg_type.dat).
pub const oid = struct {
    pub const @"bool": Oid = 16;
    pub const bytea: Oid = 17;
    pub const name: Oid = 19;
    pub const int8: Oid = 20;
    pub const int2: Oid = 21;
    pub const int4: Oid = 23;
    pub const text: Oid = 25;
    pub const oid: Oid = 26;
    pub const json: Oid = 114;
    pub const float4: Oid = 700;
    pub const float8: Oid = 701;
    pub const unknown: Oid = 705;
    pub const bpchar: Oid = 1042;
    pub const varchar: Oid = 1043;
    pub const date: Oid = 1082;
    pub const time: Oid = 1083;
    pub const timestamp: Oid = 1114;
    pub const timestamptz: Oid = 1184;
    pub const interval: Oid = 1186;
    pub const timetz: Oid = 1266;
    pub const numeric: Oid = 1700;
    pub const uuid: Oid = 2950;
    pub const jsonb: Oid = 3802;
};

/// The OID a column or parameter of type `t` is described with. A type
/// not known is text, as PostgreSQL resolves an unknown literal.
pub fn ofType(t: Type) Oid {
    return switch (t.logical) {
        .unknown, .text => oid.text,
        .boolean => oid.bool,
        .int1, .int2 => oid.int2,
        .int4 => oid.int4,
        .int8 => oid.int8,
        .float4 => oid.float4,
        .float8 => oid.float8,
        .numeric => oid.numeric,
        .varchar => oid.varchar,
        .char => oid.bpchar,
        .bytes => oid.bytea,
        .date => oid.date,
        .time => oid.time,
        .time_tz => oid.timetz,
        .timestamp => oid.timestamp,
        .timestamp_tz => oid.timestamptz,
        .interval => oid.interval,
        .uuid => oid.uuid,
        .json => oid.json,
        .jsonb => oid.jsonb,
    };
}

/// The type of a parameter the client gave OID `o`, for reading its value
/// (null: not one of ours, read as text).
pub fn typeOf(o: Oid) ?Type {
    return .{ .logical = switch (o) {
        oid.bool => .boolean,
        oid.int2 => .int2,
        oid.int4, oid.oid => .int4,
        oid.int8 => .int8,
        oid.float4 => .float4,
        oid.float8 => .float8,
        oid.numeric => .numeric,
        oid.text, oid.name, oid.unknown => .text,
        oid.varchar => .varchar,
        oid.bpchar => .char,
        oid.bytea => .bytes,
        oid.date => .date,
        oid.time => .time,
        oid.timetz => .time_tz,
        oid.timestamp => .timestamp,
        oid.timestamptz => .timestamp_tz,
        oid.interval => .interval,
        oid.uuid => .uuid,
        oid.json => .json,
        oid.jsonb => .jsonb,
        else => return null,
    } };
}

/// pg_type.typlen: the size of a fixed-size type, -1 for the others.
pub fn typeLen(o: Oid) i16 {
    return switch (o) {
        oid.bool => 1,
        oid.int2 => 2,
        oid.int4, oid.float4, oid.date, oid.oid => 4,
        oid.int8, oid.float8, oid.time, oid.timestamp, oid.timestamptz => 8,
        oid.timetz => 12,
        oid.interval, oid.uuid => 16,
        oid.name => 64,
        else => -1,
    };
}

/// The type modifier (atttypmod): a varchar(n)'s n + 4, a numeric(p,s)'s
/// (p << 16 | s) + 4, a time's or timestamp's fractional digits; -1 for
/// none.
pub fn typeMod(t: Type) i32 {
    return switch (t.logical) {
        .varchar, .char => if (t.length) |n| if (n < std.math.maxInt(i32) - 4) @as(i32, @intCast(n)) + 4 else -1 else -1,
        .numeric => if (t.precision) |p| ((@as(i32, p) << 16) | (t.scale orelse 0)) + 4 else -1,
        .time, .time_tz, .timestamp, .timestamp_tz => if (t.scale) |s| s else -1,
        else => -1,
    };
}

// ================================================================== output

/// The text of `v` (not NULL), a value of a column of type `t`, as
/// PostgreSQL writes it: display.text()'s for the types it knows (`t`/`f`,
/// a numeric's scale, timestamptz's offset), a double's shortest digits
/// (`100`, `1e+20`), a blob as `\x` and hex digits.
pub fn writeText(o: *Out, t: Type, v: Value) !void {
    var buf: [64]u8 = undefined;
    const z = textOf(t, v, &buf) orelse {
        // A blob: \x and two hex digits a byte.
        const b = v.blob;
        try o.int(i32, @intCast(2 + 2 * b.len));
        try o.bytes("\\x");
        try o.print("{x}", .{b});
        return;
    };
    try o.field(z);
}

/// The text of a value that is not a blob or NULL, in `buf` or `v`; null
/// for a blob.
fn textOf(t: Type, v: Value, buf: *[64]u8) ?[]const u8 {
    if (xqlite.display.text(.postgres, t, v, buf[0..xqlite.display.max_len])) |z| return z;
    return switch (v) {
        .null => unreachable,
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .float => |f| floatText(buf, f, t.logical == .float4),
        .text => |z| z,
        .blob => null,
    };
}

/// PostgreSQL's text of a double (of a real if `real`), with
/// extra_float_digits 1, its default: the shortest digits that read back
/// as the value, in fixed notation for a decimal exponent from -4 to 14
/// (`100`, `0.0001`, `123.5`), else as `1.5e+20`, `1e-05`.
pub fn floatText(buf: *[64]u8, v: f64, real: bool) []const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "Infinity" else "-Infinity";
    if (v == 0) return if (std.math.signbit(v)) "-0" else "0";
    var sci: [40]u8 = undefined;
    // The shortest digits and their exponent: "1.2345e17".
    const z = (if (real) std.fmt.bufPrint(&sci, "{e}", .{@as(f32, @floatCast(v))}) else std.fmt.bufPrint(&sci, "{e}", .{v})) catch return "0";
    const e_at = std.mem.indexOfScalar(u8, z, 'e') orelse return "0";
    const neg = z[0] == '-';
    var digits: [24]u8 = undefined;
    var n: usize = 0;
    for (z[@intFromBool(neg)..e_at]) |c| {
        if (c == '.') continue;
        digits[n] = c;
        n += 1;
    }
    while (n > 1 and digits[n - 1] == '0') n -= 1;
    const exp = std.fmt.parseInt(i32, z[e_at + 1 ..], 10) catch 0;
    const d = digits[0..n];
    var out: std.ArrayList(u8) = .initBuffer(buf);
    if (neg) out.appendAssumeCapacity('-');
    if (exp >= -4 and exp < 15) {
        if (exp < 0) {
            out.appendSliceAssumeCapacity("0.");
            out.appendNTimesAssumeCapacity('0', @intCast(-exp - 1));
            out.appendSliceAssumeCapacity(d);
        } else {
            const int_digits: usize = @intCast(exp + 1);
            if (n <= int_digits) {
                out.appendSliceAssumeCapacity(d);
                out.appendNTimesAssumeCapacity('0', int_digits - n);
            } else {
                out.appendSliceAssumeCapacity(d[0..int_digits]);
                out.appendAssumeCapacity('.');
                out.appendSliceAssumeCapacity(d[int_digits..]);
            }
        }
    } else {
        out.appendAssumeCapacity(d[0]);
        if (n > 1) {
            out.appendAssumeCapacity('.');
            out.appendSliceAssumeCapacity(d[1..]);
        }
        out.printAssumeCapacity("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
    }
    return out.items;
}

/// Whether a column of OID `o` can be sent in the binary format.
pub fn binaryOut(o: Oid) bool {
    return switch (o) {
        oid.bool, oid.int2, oid.int4, oid.int8, oid.float4, oid.float8, oid.bytea, oid.uuid, oid.jsonb => true,
        else => textual(o),
    };
}

/// The types whose binary form is their text.
fn textual(o: Oid) bool {
    return switch (o) {
        oid.text, oid.varchar, oid.bpchar, oid.name, oid.json, oid.unknown => true,
        else => false,
    };
}

/// The binary form of `v` (not NULL) as a column of OID `o` (binaryOut())
/// and type `t`. error.Unencodable: a value that is not of the type (SQLite
/// stores any value in any column).
pub fn writeBinary(o: *Out, o_id: Oid, t: Type, v: Value) !void {
    switch (o_id) {
        oid.bool => {
            const b: u8 = switch (v) {
                .integer => |i| @intFromBool(i != 0),
                .float => |f| @intFromBool(f != 0),
                .text => |z| if (parseBool(z)) |b| @intFromBool(b) else return error.Unencodable,
                else => return error.Unencodable,
            };
            try o.int(i32, 1);
            try o.int(u8, b);
        },
        oid.int2 => try writeInt(o, i16, v),
        oid.int4 => try writeInt(o, i32, v),
        oid.int8 => try writeInt(o, i64, v),
        oid.float4, oid.float8 => {
            const f: f64 = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                .text => |z| parseFloat(z) orelse return error.Unencodable,
                else => return error.Unencodable,
            };
            if (o_id == oid.float4) {
                try o.int(i32, 4);
                try o.int(u32, @bitCast(@as(f32, @floatCast(f))));
            } else {
                try o.int(i32, 8);
                try o.int(u64, @bitCast(f));
            }
        },
        oid.bytea => switch (v) {
            .blob => |b| try o.field(b),
            .text => |z| try o.field(z),
            else => return error.Unencodable,
        },
        oid.uuid => {
            const z = switch (v) {
                .text => |z| z,
                else => return error.Unencodable,
            };
            const b = parseUuid(z) orelse return error.Unencodable;
            try o.field(&b);
        },
        oid.jsonb => {
            var buf: [64]u8 = undefined;
            const z = textOf(t, v, &buf) orelse return error.Unencodable;
            try o.int(i32, @intCast(1 + z.len));
            try o.int(u8, 1);
            try o.bytes(z);
        },
        else => {
            std.debug.assert(textual(o_id));
            try writeText(o, t, v);
        },
    }
}

fn writeInt(o: *Out, comptime T: type, v: Value) !void {
    const i: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| if (@trunc(f) == f and @abs(f) < 9.2e18) @intFromFloat(f) else return error.Unencodable,
        .text => |z| std.fmt.parseInt(i64, std.mem.trim(u8, z, " "), 10) catch return error.Unencodable,
        else => return error.Unencodable,
    };
    const n = std.math.cast(T, i) orelse return error.Unencodable;
    try o.int(i32, @sizeOf(T));
    try o.int(T, n);
}

// =============================================================== parameters

pub const DecodeError = error{ InvalidText, InvalidBinary, UnsupportedBinary, OutOfMemory };

/// The value of a parameter sent as text, of type `t` (the client's OID,
/// else the statement's): an integer, a double, a boolean (0/1), a blob
/// for bytea (`\x` hex or the escape format); else the text, which the
/// statement reads as its type (a numeric or a date stays text). Slices
/// of `z` or of `a`.
pub fn decodeText(a: std.mem.Allocator, t: ?Type, z: []const u8) DecodeError!Value {
    const l = if (t) |x| x.logical else return .{ .text = z };
    switch (l) {
        .int1, .int2, .int4, .int8 => return .{ .integer = std.fmt.parseInt(i64, std.mem.trim(u8, z, " \t\r\n"), 10) catch return error.InvalidText },
        .float4, .float8 => return .{ .float = parseFloat(z) orelse return error.InvalidText },
        .boolean => return .{ .integer = @intFromBool(parseBool(z) orelse return error.InvalidText) },
        .bytes => return .{ .blob = try decodeBytea(a, z) },
        else => return .{ .text = z },
    }
}

/// The value of a parameter sent in the binary format, of OID `o`.
pub fn decodeBinary(a: std.mem.Allocator, o: Oid, b: []const u8) DecodeError!Value {
    switch (o) {
        oid.bool => return if (b.len == 1) .{ .integer = @intFromBool(b[0] != 0) } else error.InvalidBinary,
        oid.int2 => return if (b.len == 2) .{ .integer = std.mem.readInt(i16, b[0..2], .big) } else error.InvalidBinary,
        oid.int4, oid.oid => return if (b.len == 4) .{ .integer = std.mem.readInt(i32, b[0..4], .big) } else error.InvalidBinary,
        oid.int8 => return if (b.len == 8) .{ .integer = std.mem.readInt(i64, b[0..8], .big) } else error.InvalidBinary,
        oid.float4 => return if (b.len == 4) .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .big))) } else error.InvalidBinary,
        oid.float8 => return if (b.len == 8) .{ .float = @bitCast(std.mem.readInt(u64, b[0..8], .big)) } else error.InvalidBinary,
        oid.bytea => return .{ .blob = b },
        oid.uuid => {
            if (b.len != 16) return error.InvalidBinary;
            return .{ .text = try std.fmt.allocPrint(a, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) };
        },
        oid.jsonb => return if (b.len >= 1 and b[0] == 1) .{ .text = b[1..] } else error.InvalidBinary,
        // An unspecified type: as text, as libpq's clients send strings.
        0 => return .{ .text = b },
        else => return if (textual(o)) .{ .text = b } else error.UnsupportedBinary,
    }
}

/// PostgreSQL's boolean input: t, true, yes, on, 1 and f, false, no, off,
/// 0, and their unambiguous prefixes, any case, blanks around.
pub fn parseBool(z0: []const u8) ?bool {
    const z = std.mem.trim(u8, z0, " \t\r\n");
    if (z.len == 0) return null;
    const words = [_]struct { []const u8, bool, usize }{
        .{ "true", true, 1 }, .{ "false", false, 1 }, .{ "yes", true, 1 }, .{ "no", false, 1 },
        .{ "on", true, 2 },   .{ "off", false, 2 },   .{ "1", true, 1 },   .{ "0", false, 1 },
    };
    for (words) |w| {
        if (z.len >= w[2] and z.len <= w[0].len and std.ascii.eqlIgnoreCase(z, w[0][0..z.len])) return w[1];
    }
    return null;
}

fn parseFloat(z0: []const u8) ?f64 {
    const z = std.mem.trim(u8, z0, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(z, "nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(z, "infinity") or std.ascii.eqlIgnoreCase(z, "inf") or std.ascii.eqlIgnoreCase(z, "+infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(z, "-infinity") or std.ascii.eqlIgnoreCase(z, "-inf")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, z) catch null;
}

/// bytea's text input: `\x` and hex digits, else the escape format
/// (`\\` a backslash, `\ooo` an octal byte).
fn decodeBytea(a: std.mem.Allocator, z: []const u8) DecodeError![]const u8 {
    if (std.mem.startsWith(u8, z, "\\x")) {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 2;
        while (i < z.len) {
            if (std.ascii.isWhitespace(z[i])) {
                i += 1;
                continue;
            }
            if (i + 1 >= z.len) return error.InvalidText;
            const hi = std.fmt.charToDigit(z[i], 16) catch return error.InvalidText;
            const lo = std.fmt.charToDigit(z[i + 1], 16) catch return error.InvalidText;
            try out.append(a, hi * 16 + lo);
            i += 2;
        }
        return out.items;
    }
    if (std.mem.indexOfScalar(u8, z, '\\') == null) return z;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < z.len) {
        if (z[i] != '\\') {
            try out.append(a, z[i]);
            i += 1;
        } else if (i + 1 < z.len and z[i + 1] == '\\') {
            try out.append(a, '\\');
            i += 2;
        } else if (z.len - i >= 4) {
            const n = std.fmt.parseInt(u8, z[i + 1 .. i + 4], 8) catch return error.InvalidText;
            try out.append(a, n);
            i += 4;
        } else return error.InvalidText;
    }
    return out.items;
}

/// The 16 bytes of a uuid's text (hex digits, dashes and braces ignored).
fn parseUuid(z: []const u8) ?[16]u8 {
    var b: [16]u8 = undefined;
    var n: usize = 0;
    var half: ?u8 = null;
    for (z) |c| {
        if (c == '-' or c == '{' or c == '}') continue;
        const d = std.fmt.charToDigit(c, 16) catch return null;
        if (half) |h| {
            if (n == 16) return null;
            b[n] = h * 16 + d;
            n += 1;
            half = null;
        } else half = d;
    }
    return if (n == 16 and half == null) b else null;
}

test floatText {
    var buf: [64]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("100", floatText(&buf, 100, false));
    try t.expectEqualStrings("1.5", floatText(&buf, 1.5, false));
    try t.expectEqualStrings("0.0001", floatText(&buf, 0.0001, false));
    try t.expectEqualStrings("1e-05", floatText(&buf, 0.00001, false));
    try t.expectEqualStrings("1e+20", floatText(&buf, 1e20, false));
    try t.expectEqualStrings("-1.25e+15", floatText(&buf, -1.25e15, false));
    try t.expectEqualStrings("0.1", floatText(&buf, 0.1, false));
    try t.expectEqualStrings("0.1", floatText(&buf, @as(f32, 0.1), true));
    var tenth: f64 = 0.1;
    _ = &tenth;
    try t.expectEqualStrings("0.30000000000000004", floatText(&buf, tenth + 0.2, false));
    try t.expectEqualStrings("NaN", floatText(&buf, std.math.nan(f64), false));
    try t.expectEqualStrings("-Infinity", floatText(&buf, -std.math.inf(f64), false));
}

test "decode parameters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expectEqual(@as(i64, 42), (try decodeText(a, .{ .logical = .int4 }, " 42")).integer);
    try t.expectError(error.InvalidText, decodeText(a, .{ .logical = .int4 }, "x"));
    try t.expectEqual(@as(i64, 1), (try decodeText(a, .{ .logical = .boolean }, "yes")).integer);
    try t.expectEqual(@as(i64, 0), (try decodeText(a, .{ .logical = .boolean }, "F")).integer);
    try t.expectEqualSlices(u8, "\x01\xab", (try decodeText(a, .{ .logical = .bytes }, "\\x01AB")).blob);
    try t.expectEqualSlices(u8, "a\\\x07", (try decodeText(a, .{ .logical = .bytes }, "a\\\\\\007")).blob);
    try t.expectEqualStrings("1.50", (try decodeText(a, .{ .logical = .numeric }, "1.50")).text);
    try t.expectEqual(@as(i64, -2), (try decodeBinary(a, oid.int2, "\xff\xfe")).integer);
    try t.expectEqual(@as(f64, 1.5), (try decodeBinary(a, oid.float8, "\x3f\xf8\x00\x00\x00\x00\x00\x00")).float);
    try t.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", (try decodeBinary(a, oid.uuid, &parseUuid("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11").?)).text);
    try t.expectError(error.UnsupportedBinary, decodeBinary(a, oid.numeric, "\x00"));
    try t.expectEqual(@as(?bool, null), parseBool("o"));
    try t.expectEqual(@as(?bool, true), parseBool("on"));
}

test "type modifiers" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 24), typeMod(.{ .logical = .varchar, .length = 20 }));
    try t.expectEqual(@as(i32, (10 << 16 | 2) + 4), typeMod(.{ .logical = .numeric, .precision = 10, .scale = 2 }));
    try t.expectEqual(@as(i32, -1), typeMod(.{ .logical = .text }));
    try t.expectEqual(oid.bpchar, ofType(.{ .logical = .char }));
}
