//! The text of a value as the dialect a client speaks (the viewer) shows
//! it, from the type of its column (types.zig): the core of the value
//! display layer, which the shell and the wire servers (api/display.zig,
//! server/pg/values.zig) and a dialect's messages
//! (postgres/constraints.zig) write values with. It needs only the
//! types and the BLOB forms (repr.zig), so it is outside the dialect
//! directories, in every build (-Ddialects).
//!
//! The engine stores values as SQLite does: a boolean is the integer 0 or
//! 1, a `numeric(10,2)` is a number without its trailing zeros, a
//! `timestamptz` is UTC text without an offset. text() writes them as
//! the viewer does (`t`, `1.50`, `2024-01-02 03:04:05+00`); null is
//! SQLite's text. pgText() is all of PostgreSQL's text of a value
//! (`100` for the double 100.0), write() either into a writer.

const std = @import("std");
const types = @import("../sql/types.zig");
const repr = @import("repr.zig");
const Dialect = @import("dialect.zig").Dialect;

const Type = types.Type;
const Allocator = std.mem.Allocator;

/// A value as the engine holds it (api.Value's shape).
pub const Cell = union(types.Kind) {
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null,
};

/// The longest text() writes into its buffer (an interval's text is up
/// to 70 bytes).
pub const max_len = repr.max_len;

/// `cell`, a value of a column of type `t`, as `viewer` shows it, if not
/// as SQLite does (in `buf` or static); null for SQLite's text.
pub fn text(viewer: Dialect, t: Type, cell: Cell, buf: *[max_len]u8) ?[]const u8 {
    // A BLOB of a dialect's form (a numeric key, a uuid's bytes, an
    // interval): repr.zig.
    if (cell == .blob) return repr.text(viewer, t, cell.blob, buf);
    switch (t.logical) {
        .boolean => {
            const b = switch (cell) {
                .integer => |v| v != 0,
                else => return null,
            };
            return switch (viewer) {
                .postgres => if (b) "t" else "f",
                // Oracle 23ai's BOOLEAN.
                .oracle => if (b) "TRUE" else "FALSE",
                // MariaDB's BOOLEAN is TINYINT(1) and SQL Server's bit
                // shows 0/1: as stored.
                .sqlite, .mariadb, .mssql => null,
            };
        },
        .numeric => {
            // A DECIMAL(p,s) shows its s digits; Oracle's NUMBER(p,s)
            // drops trailing zeros, as SQLite does.
            switch (viewer) {
                .postgres, .mariadb, .mssql => {},
                .sqlite, .oracle => return null,
            }
            const scale = t.scale orelse return null;
            return fixed(cell, scale, buf);
        },
        .timestamp_tz => {
            if (viewer != .postgres) return null;
            const z = switch (cell) {
                .text => |z| z,
                else => return null,
            };
            return utc(z, buf);
        },
        .char => {
            // PostgreSQL's character(n) is padded with spaces to n
            // characters; the value is kept without them.
            if (viewer != .postgres) return null;
            const n = t.length orelse return null;
            const z = switch (cell) {
                .text => |z| z,
                else => return null,
            };
            const have = std.unicode.utf8CountCodepoints(z) catch return null;
            if (have >= n or z.len + (n - have) > max_len) return null;
            @memcpy(buf[0..z.len], z);
            @memset(buf[z.len..][0 .. n - have], ' ');
            return buf[0 .. z.len + n - have];
        },
        // uuid, interval: the text of an older table's TEXT column as
        // stored.
        else => return null,
    }
}

/// The text of `cell` that needs memory of its own (in `gpa`, which the
/// caller frees it with), null for the others (text()), in every dialect
/// but SQLite's, which shows the blob: a jsonb value stored as SQLite's
/// JSONB is its JSON text with PostgreSQL's spacing (`{"a": 1}`); a
/// numeric key its digits (as text() writes them, of any length).
pub fn textAlloc(gpa: Allocator, viewer: Dialect, t: Type, cell: Cell) error{OutOfMemory}!?[]u8 {
    const b = switch (cell) {
        .blob => |b| b,
        else => return null,
    };
    return repr.textAlloc(gpa, viewer, t, b);
}

/// PostgreSQL's text of `cell` (not NULL), a value of a column of type
/// `t`, in `buf`, static or `cell`'s: text()'s, else a number's
/// (a double's shortest digits, floatText()), a text as stored. Null for
/// NULL, and for a blob no form writes (PostgreSQL's bytea text is
/// `\x` and hex digits; textAlloc() is asked first).
pub fn pgText(t: Type, cell: Cell, buf: *[max_len]u8) ?[]const u8 {
    if (text(.postgres, t, cell, buf)) |z| return z;
    return switch (cell) {
        .null, .blob => null,
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .float => |f| floatText(buf[0..64], f, t.logical == .float4),
        .text => |z| z,
    };
}

/// pgText() of `cell` into `w`, with textAlloc()'s text first (in `gpa`
/// while it is written); false, writing nothing, for a value without
/// one. `max`: at most that many bytes of the text, in whole
/// characters, then "..." (ExecBuildSlotValueDescription()); a stored
/// text is cut before it is copied.
pub fn writePg(gpa: Allocator, w: *std.Io.Writer, t: Type, cell: Cell, max: ?usize) error{ OutOfMemory, WriteFailed }!bool {
    if (try textAlloc(gpa, .postgres, t, cell)) |z| {
        defer gpa.free(z);
        try writeClipped(w, z, max);
        return true;
    }
    var buf: [max_len]u8 = undefined;
    try writeClipped(w, pgText(t, cell, &buf) orelse return false, max);
    return true;
}

fn writeClipped(w: *std.Io.Writer, z: []const u8, max: ?usize) std.Io.Writer.Error!void {
    const n = max orelse return w.writeAll(z);
    if (z.len <= n) return w.writeAll(z);
    // pg_mbcliplen(): whole characters.
    var end = n;
    while (end > 0 and z[end] & 0xc0 == 0x80) end -= 1;
    try w.writeAll(z[0..end]);
    try w.writeAll("...");
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

/// A number with `scale` digits after the point.
fn fixed(cell: Cell, scale: u8, buf: *[max_len]u8) ?[]const u8 {
    // Beyond the digits a double holds the text would show noise.
    if (scale > 15) return null;
    return switch (cell) {
        // As stored, without a point.
        .integer => |v| if (scale == 0) null else std.fmt.bufPrint(buf, "{d}.{s}", .{ v, "000000000000000"[0..scale] }) catch null,
        .float => |v| if (std.math.isFinite(v) and @abs(v) < 1e15) std.fmt.bufPrint(buf, "{d:.[1]}", .{ v, scale }) catch null else null,
        else => null,
    };
}

/// PostgreSQL's timestamptz text of a UTC timestamp without an offset
/// ("2024-01-02 03:04:05[.fff]"): the offset "+00" appended.
fn utc(z: []const u8, buf: *[max_len]u8) ?[]const u8 {
    // YYYY-MM-DD HH:MM:SS, then at most a fraction.
    if (z.len < 19 or z.len + 3 > buf.len or z[10] != ' ' or z[13] != ':') return null;
    const rest = z[19..];
    if (rest.len > 0 and (rest[0] != '.' or !allDigits(rest[1..]))) return null;
    @memcpy(buf[0..z.len], z);
    @memcpy(buf[z.len..][0..3], "+00");
    return buf[0 .. z.len + 3];
}

fn allDigits(z: []const u8) bool {
    for (z) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test writePg {
    const t = std.testing;
    var w: std.Io.Writer.Allocating = .init(t.allocator);
    defer w.deinit();
    const long: [70]u8 = @splat('x');
    try t.expect(try writePg(t.allocator, &w.writer, .{ .logical = .text }, .{ .text = &long }, 64));
    try t.expectEqualStrings(long[0..64] ++ "...", w.written());
    w.clearRetainingCapacity();
    // Whole characters: a 2-byte one across the limit is left out.
    try t.expect(try writePg(t.allocator, &w.writer, .{ .logical = .text }, .{ .text = long[0..63] ++ "é" }, 64));
    try t.expectEqualStrings(long[0..63] ++ "...", w.written());
    w.clearRetainingCapacity();
    try t.expect(try writePg(t.allocator, &w.writer, .{ .logical = .float8 }, .{ .float = 1e20 }, null));
    try t.expectEqualStrings("1e+20", w.written());
    w.clearRetainingCapacity();
    try t.expect(try writePg(t.allocator, &w.writer, .{ .logical = .boolean }, .{ .integer = 1 }, null));
    try t.expectEqualStrings("t", w.written());
    try t.expect(!try writePg(t.allocator, &w.writer, .{ .logical = .bytes }, .{ .blob = "\x01" }, null));
}
