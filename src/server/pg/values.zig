//! Types and values on the wire: the type OID of each `types.Logical`
//! (xqlite.pg_types), the text and binary forms of values as PostgreSQL writes them, and the
//! parameters a client binds (text, or binary for the common types).

const std = @import("std");
const xqlite = @import("xqlite");
const wire = @import("wire.zig");

const types = xqlite.types;
const Type = types.Type;
const Value = xqlite.Value;
const Out = wire.Out;

const pg_types = xqlite.pg_types;
const Oid = pg_types.Oid;
const oid = pg_types.oid;
const elementOf = pg_types.elementOf;
const ofType = pg_types.ofType;
const typeMod = pg_types.typeMod;

// ================================================================== output

/// The text of `v` (not NULL), a value of a column of type `t`, as
/// PostgreSQL writes it: display.text()'s for the types it knows (`t`/`f`,
/// a numeric's scale, timestamptz's offset), a double's shortest digits
/// (`100`, `1e+20`), a blob as `\x` and hex digits.
pub fn writeText(o: *Out, t: Type, v: Value) !void {
    // jsonb stored as JSONB: its JSON text; a numeric key its digits.
    if (try xqlite.display.textAlloc(o.gpa, .postgres, o.settings, t, v)) |z| {
        defer o.gpa.free(z);
        return o.field(z);
    }
    var buf: [xqlite.display.max_len]u8 = undefined;
    const z = xqlite.display.pgText(o.settings, t, v, &buf) orelse {
        // A blob: \x and two hex digits a byte.
        const b = v.blob;
        try o.int(i32, @intCast(2 + 2 * b.len));
        try o.bytes("\\x");
        xqlite.simd.hexEncode(try o.buf.addManyAsSlice(o.gpa, 2 * b.len), b, false);
        return;
    };
    try o.field(z);
}

/// The text of a value that is not a blob or NULL, in `buf` or `v`; null
/// for a blob (display.pgText()).
fn textOf(t: Type, v: Value, buf: *[xqlite.display.max_len]u8) ?[]const u8 {
    return xqlite.display.pgText(.{}, t, v, buf);
}

const floatText = xqlite.display.floatText;

/// Whether a column of OID `o` can be sent in the binary format (an
/// array if its elements can).
pub fn binaryOut(o: Oid) bool {
    if (elementOf(o)) |e| return binaryOut(e);
    return switch (o) {
        oid.bool, oid.int2, oid.int4, oid.int8, oid.float4, oid.float8, oid.bytea, oid.uuid, oid.jsonb, oid.interval, oid.numeric => true,
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
    if (elementOf(o_id)) |e| {
        const z = switch (v) {
            .text => |z| z,
            else => return error.Unencodable,
        };
        return writeArray(o, e, t.elementType(), z);
    }
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
        else => {
            if (formOf(o_id)) |f| return f.send(o, t, v);
            std.debug.assert(textual(o_id));
            try writeText(o, t, v);
        },
    }
}

// ============================================================ BLOB forms
//
// The binary form of the types a dialect stores as a BLOB of its own form
// (xqlite.repr: a numeric's key, a uuid's 16 bytes, an interval, jsonb as
// JSONB), each also as the text or number of an older table's column:
// one codec per type.

const Form = struct {
    oid: Oid,
    /// The binary form of `v` (not NULL), a value of type `t`.
    send: *const fn (o: *Out, t: Type, v: Value) error{ OutOfMemory, Unencodable }!void,
    /// The value of a parameter in the binary form.
    recv: *const fn (a: std.mem.Allocator, b: []const u8) DecodeError!Value,
};

const forms = [_]Form{
    .{ .oid = oid.numeric, .send = writeNumeric, .recv = decodeNumeric },
    .{ .oid = oid.uuid, .send = uuid_form.send, .recv = uuid_form.recv },
    .{ .oid = oid.interval, .send = interval_form.send, .recv = interval_form.recv },
    .{ .oid = oid.jsonb, .send = jsonb_form.send, .recv = jsonb_form.recv },
};

fn formOf(o: Oid) ?*const Form {
    for (&forms) |*f| if (f.oid == o) return f;
    return null;
}

const uuid_form = struct {
    /// Its 16 bytes, or the text of an older table's column.
    fn send(o: *Out, t: Type, v: Value) error{ OutOfMemory, Unencodable }!void {
        _ = t;
        const b: [16]u8 = switch (v) {
            .blob => |x| if (x.len == 16) x[0..16].* else return error.Unencodable,
            .text => |z| parseUuid(z) orelse return error.Unencodable,
            else => return error.Unencodable,
        };
        try o.field(&b);
    }

    /// The 16 bytes, as a uuid column keeps them (the statement reads
    /// them into an older table's text column: xq_pg_uuid_text()).
    fn recv(a: std.mem.Allocator, b: []const u8) DecodeError!Value {
        _ = a;
        return if (b.len == 16) .{ .blob = b } else error.InvalidBinary;
    }
};

const interval_form = struct {
    /// interval BLOB: PostgreSQL's interval_send(): the microseconds
    /// (int64), the days and the months (int32); an older database's
    /// TEXT read.
    fn send(o: *Out, t: Type, v: Value) error{ OutOfMemory, Unencodable }!void {
        _ = t;
        const iv = switch (v) {
            .blob => |b| repr.intervalOf(b) orelse return error.Unencodable,
            .text => |z| repr.parseInterval(z) orelse return error.Unencodable,
            else => return error.Unencodable,
        };
        try o.int(i32, 16);
        try o.int(i64, iv.time);
        try o.int(i32, iv.days);
        try o.int(i32, iv.months);
    }

    /// interval_recv()'s fields, as text (the input of a BLOB or an older
    /// database's TEXT column alike).
    fn recv(a: std.mem.Allocator, b: []const u8) DecodeError!Value {
        if (b.len != 16) return error.InvalidBinary;
        const iv: repr.Interval = .{
            .time = std.mem.readInt(i64, b[0..8], .big),
            .days = std.mem.readInt(i32, b[8..12], .big),
            .months = std.mem.readInt(i32, b[12..16], .big),
        };
        var buf: [repr.max_len]u8 = undefined;
        const z = repr.intervalText(iv, &buf);
        return .{ .text = try a.dupe(u8, z) };
    }
};

const jsonb_form = struct {
    /// Version 1 and the text; of JSONB, its JSON text.
    fn send(o: *Out, t: Type, v: Value) error{ OutOfMemory, Unencodable }!void {
        var buf: [xqlite.display.max_len]u8 = undefined;
        const owned = try xqlite.display.textAlloc(o.gpa, .postgres, .{}, t, v);
        defer if (owned) |z| o.gpa.free(z);
        const z = owned orelse textOf(t, v, &buf) orelse return error.Unencodable;
        try o.int(i32, @intCast(1 + z.len));
        try o.int(u8, 1);
        try o.bytes(z);
    }

    fn recv(a: std.mem.Allocator, b: []const u8) DecodeError!Value {
        _ = a;
        return if (b.len >= 1 and b[0] == 1) .{ .text = b[1..] } else error.InvalidBinary;
    }
};

const repr = xqlite.repr;

// numeric ---------------------------------------------------------------

const decimal = xqlite.decimal;

/// PostgreSQL's binary numeric (NBASE 10000 digits) of `v`: a key
/// (pkg/decimal) with the scale of its type, else the one it
/// carries; a number or a numeric's text.
fn writeNumeric(o: *Out, t: Type, v: Value) error{ OutOfMemory, Unencodable }!void {
    var arena: std.heap.ArenaAllocator = .init(o.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var d: decimal.Dec = switch (v) {
        .blob => |b| (decimal.decodeKey(a, b) catch return error.Unencodable).dec,
        .integer => |i| decimal.fromInt(a, i) catch return error.OutOfMemory,
        .float => |f| decimal.fromFloat(a, f) catch return error.Unencodable,
        .text => |z| decimal.parse(a, z) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unencodable,
        .null => return error.Unencodable,
    };
    if (t.scale) |s| if (d.kind == .finite) {
        d.dscale = @max(s, d.fracDigits());
    };
    const bin = decimal.toPgBinary(a, d) catch return error.Unencodable;
    try o.field(bin);
}

/// The text of a binary numeric parameter (its display scale's digits).
fn decodeNumeric(a: std.mem.Allocator, b: []const u8) DecodeError!Value {
    const d = decimal.fromPgBinary(a, b) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidBinary;
    return .{ .text = decimal.toText(a, d) catch return error.OutOfMemory };
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
    if (elementOf(o)) |e| return .{ .text = try decodeArray(a, e, b) };
    switch (o) {
        oid.bool => return if (b.len == 1) .{ .integer = @intFromBool(b[0] != 0) } else error.InvalidBinary,
        oid.int2 => return if (b.len == 2) .{ .integer = std.mem.readInt(i16, b[0..2], .big) } else error.InvalidBinary,
        oid.int4, oid.oid => return if (b.len == 4) .{ .integer = std.mem.readInt(i32, b[0..4], .big) } else error.InvalidBinary,
        oid.int8 => return if (b.len == 8) .{ .integer = std.mem.readInt(i64, b[0..8], .big) } else error.InvalidBinary,
        oid.float4 => return if (b.len == 4) .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .big))) } else error.InvalidBinary,
        oid.float8 => return if (b.len == 8) .{ .float = @bitCast(std.mem.readInt(u64, b[0..8], .big)) } else error.InvalidBinary,
        oid.bytea => return .{ .blob = b },
        // An unspecified type: as text, as libpq's clients send strings.
        0 => return .{ .text = b },
        else => {
            if (formOf(o)) |f| return f.recv(a, b);
            return if (textual(o)) .{ .text = b } else error.UnsupportedBinary;
        },
    }
}

// =================================================================== arrays

const pgarray = xqlite.pgtext.array;

/// The binary form of array `z` (its text), of elements of OID `elem`
/// and type `t`: the dimensions, then each element's binary form.
fn writeArray(o: *Out, elem: Oid, t: Type, z: []const u8) error{ OutOfMemory, Unencodable }!void {
    var arena: std.heap.ArenaAllocator = .init(o.gpa);
    defer arena.deinit();
    // Also an int2vector's or oidvector's `1 2` (from 0).
    const x = pgarray.parse(arena.allocator(), z, true) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unencodable;
    const at = o.buf.items.len;
    try o.int(i32, 0);
    try o.int(i32, x.ndim);
    var nulls = false;
    for (x.elems) |e| {
        if (e == null) nulls = true;
    }
    try o.int(i32, @intFromBool(nulls));
    try o.int(u32, elem);
    for (0..x.ndim) |d| {
        try o.int(i32, @intCast(x.dims[d]));
        try o.int(i32, x.lower[d]);
    }
    for (x.elems) |e| {
        if (e) |s| try writeBinary(o, elem, t, .{ .text = s }) else try o.int(i32, -1);
    }
    const len: i32 = @intCast(o.buf.items.len - at - 4);
    std.mem.writeInt(i32, o.buf.items[at..][0..4], len, .big);
}

/// The text of an array sent in the binary format, of elements of OID
/// `elem`.
fn decodeArray(a: std.mem.Allocator, elem: Oid, b: []const u8) DecodeError![]const u8 {
    var r: usize = 0;
    const Rd = struct {
        fn int(bytes: []const u8, at: *usize) DecodeError!i32 {
            if (at.* + 4 > bytes.len) return error.InvalidBinary;
            defer at.* += 4;
            return std.mem.readInt(i32, bytes[at.*..][0..4], .big);
        }
    };
    const ndim = try Rd.int(b, &r);
    _ = try Rd.int(b, &r);
    const elem_oid: Oid = @bitCast(try Rd.int(b, &r));
    if (ndim < 0 or ndim > 6) return error.InvalidBinary;
    const n: usize = @intCast(ndim);
    var dims: [6]i32 = undefined;
    var lower: [6]i32 = undefined;
    var count: usize = if (n == 0) 0 else 1;
    for (0..n) |d| {
        dims[d] = try Rd.int(b, &r);
        lower[d] = try Rd.int(b, &r);
        if (dims[d] < 0) return error.InvalidBinary;
        count = std.math.mul(usize, count, @intCast(dims[d])) catch return error.InvalidBinary;
    }
    // Each element has its length (4 bytes) at least.
    if (count > (b.len - r) / 4) return error.InvalidBinary;
    const eo = if (elem_oid != 0) elem_oid else elem;
    var x: pgarray.Array = .{ .ndim = @intCast(n), .elems = try a.alloc(?[]const u8, count) };
    for (0..n) |d| {
        x.dims[d] = @intCast(dims[d]);
        x.lower[d] = lower[d];
    }
    for (x.elems) |*e| {
        const len = try Rd.int(b, &r);
        if (len < 0) {
            e.* = null;
            continue;
        }
        const ul: usize = @intCast(len);
        if (r + ul > b.len) return error.InvalidBinary;
        const v = try decodeBinary(a, eo, b[r .. r + ul]);
        r += ul;
        var buf: [64]u8 = undefined;
        e.* = switch (v) {
            .integer => |i| if (eo == oid.bool) (if (i != 0) "t" else "f") else try std.fmt.allocPrint(a, "{d}", .{i}),
            .float => |f| try a.dupe(u8, floatText(&buf, f, eo == oid.float4)),
            .text => |z| z,
            .blob => |bl| if (eo == oid.uuid) try std.fmt.allocPrint(a, "{x}-{x}-{x}-{x}-{x}", .{ bl[0..4], bl[4..6], bl[6..8], bl[8..10], bl[10..16] }) else try std.fmt.allocPrint(a, "\\x{x}", .{bl}),
            .null => null,
        };
    }
    return pgarray.write(a, &x);
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
        try out.ensureTotalCapacity(a, z.len / 2);
        var i: usize = 2;
        while (i < z.len) {
            // Runs of digit pairs sixteen digits at a time.
            const used = xqlite.simd.hexDecodeBlocks(out.unusedCapacitySlice(), z[i..]);
            out.items.len += used / 2;
            i += used;
            if (i >= z.len) break;
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
    // Blocks of sixteen digits, whitespace between pairs, an odd tail.
    try t.expectEqualSlices(u8, "\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff\x01\x23", (try decodeText(a, .{ .logical = .bytes }, "\\x00112233445566778899AaBbCcDdEeFf 01 23")).blob);
    try t.expectError(error.InvalidText, decodeText(a, .{ .logical = .bytes }, "\\x00112233445566778899aabbccddeeff0"));
    try t.expectError(error.InvalidText, decodeText(a, .{ .logical = .bytes }, "\\x0011223344556677889g"));
    try t.expectEqualSlices(u8, "a\\\x07", (try decodeText(a, .{ .logical = .bytes }, "a\\\\\\007")).blob);
    try t.expectEqualStrings("1.50", (try decodeText(a, .{ .logical = .numeric }, "1.50")).text);
    try t.expectEqual(@as(i64, -2), (try decodeBinary(a, oid.int2, "\xff\xfe")).integer);
    try t.expectEqual(@as(f64, 1.5), (try decodeBinary(a, oid.float8, "\x3f\xf8\x00\x00\x00\x00\x00\x00")).float);
    try t.expectEqualSlices(u8, &parseUuid("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11").?, (try decodeBinary(a, oid.uuid, &parseUuid("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11").?)).blob);
    try t.expectError(error.InvalidBinary, decodeBinary(a, oid.numeric, "\x00"));
    // -12.50: two digits, weight 0, negative, dscale 2: 0012 5000.
    try t.expectEqualStrings("-12.50", (try decodeBinary(a, oid.numeric, "\x00\x02\x00\x00\x40\x00\x00\x02\x00\x0c\x13\x88")).text);
    try t.expectEqual(@as(?bool, null), parseBool("o"));
    try t.expectEqual(@as(?bool, true), parseBool("on"));
}

test "type modifiers" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 24), typeMod(.{ .logical = .varchar, .length = 20 }));
    try t.expectEqual(@as(i32, (10 << 16 | 2) + 4), typeMod(.{ .logical = .numeric, .precision = 10, .scale = 2 }));
    try t.expectEqual(@as(i32, -1), typeMod(.{ .logical = .text }));
    try t.expectEqual(oid.bpchar, ofType(.{ .logical = .char }));
    try t.expectEqual(@as(Oid, 1007), ofType(.{ .logical = .array, .element = .int4 }));
    try t.expectEqual(@as(Oid, 1009), ofType(.{ .logical = .array }));
    try t.expectEqual(@as(i32, 24), typeMod(.{ .logical = .array, .element = .varchar, .length = 20 }));
    try t.expectEqual(Type{ .logical = .array, .element = .int8 }, pg_types.typeOf(1016).?);
}

test "arrays in the binary format" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var o: Out = .{ .gpa = std.testing.allocator, .w = &sink.writer };
    defer o.deinit();
    try writeBinary(&o, 1007, .{ .logical = .array, .element = .int4 }, .{ .text = "{{1,2},{3,NULL}}" });
    const b = o.buf.items[4..];
    try t.expectEqual(@as(i32, @intCast(b.len)), std.mem.readInt(i32, o.buf.items[0..4], .big));
    try t.expectEqualStrings("{{1,2},{3,NULL}}", try decodeArray(a, oid.int4, b));
    o.buf.clearRetainingCapacity();
    try writeBinary(&o, 1009, .{ .logical = .array, .element = .text }, .{ .text = "{a,\"b c\",\"\"}" });
    try t.expectEqualStrings("{a,\"b c\",\"\"}", try decodeArray(a, oid.text, o.buf.items[4..]));
    o.buf.clearRetainingCapacity();
    try writeBinary(&o, 1000, .{ .logical = .array, .element = .boolean }, .{ .text = "[0:1]={t,f}" });
    try t.expectEqualStrings("[0:1]={t,f}", try decodeArray(a, oid.bool, o.buf.items[4..]));
    o.buf.clearRetainingCapacity();
    try writeBinary(&o, 1007, .{ .logical = .array, .element = .int4 }, .{ .text = "{}" });
    try t.expectEqualStrings("{}", try decodeArray(a, oid.int4, o.buf.items[4..]));
    try t.expect(binaryOut(1007));
    try t.expect(binaryOut(1231));
    try t.expect(binaryOut(oid.numeric));
}
