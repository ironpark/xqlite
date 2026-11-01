//! Values as the dialect a client speaks shows them.
//!
//! The engine stores values as SQLite does: a boolean is the integer 0 or
//! 1, a `numeric(10,2)` is a number without its trailing zeros, a
//! `timestamptz` is UTC text without an offset. A client of a dialect
//! expects that dialect's text: PostgreSQL's psql shows `t`, `1.50` and
//! `2024-01-02 03:04:05+00`. text() writes a value so, from the type of
//! its column (types.zig), for the shell and the wire protocols alike;
//! the values themselves, and what the C and Zig APIs return, stay
//! SQLite's.
//!
//! Columns gives the type: a table column's from the catalog, an
//! expression's as the statement knows it (sql/typing.zig: a comparison
//! is a boolean, a cast of its target type, a column of a subquery of the
//! subquery's); an expression of no known type is written as SQLite
//! writes it.

const std = @import("std");
const engine = @import("engine.zig");
const types = @import("../sql/types.zig");
const Value = @import("value.zig").Value;
const Stmt = @import("Stmt.zig");

const Dialect = engine.Dialect;
const Type = types.Type;

/// The longest text() writes into its buffer.
pub const max_len = 64;

/// `cell`, a value of a column of type `t`, as `viewer` shows it, if not
/// as SQLite does (in `buf` or static); null for SQLite's text.
pub fn text(viewer: Dialect, t: Type, cell: Value, buf: *[max_len]u8) ?[]const u8 {
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
        else => return null,
    }
}

/// A number with `scale` digits after the point.
fn fixed(cell: Value, scale: u8, buf: *[max_len]u8) ?[]const u8 {
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

/// The types of a connection's result columns: a table column's from the
/// catalog the connection keeps in memory (catalog.meta(), read once per
/// schema version), an expression's from its frontend. Holds no state of
/// its own; init() and deinit() remain for its users.
pub const Columns = struct {
    pub const Entry = struct {
        type: Type,
        /// The declared type, as written in `dialect`: the connection's
        /// catalog in memory owns it (valid until the connection's schema
        /// or catalog next changes), or the statement for a declared type
        /// of SQLite's.
        name: []const u8,
        dialect: Dialect,
    };

    pub fn init(gpa: std.mem.Allocator) Columns {
        _ = gpa;
        return .{};
    }

    pub fn deinit(c: *Columns) void {
        c.* = undefined;
    }

    /// The declared type of result column `i` of `v`: the catalog's when
    /// it reads a table column, else SQLite's declared type; for an
    /// expression, the type the statement gave it (engine.resultType(),
    /// Expr.xq_type: a comparison is a boolean, a cast of its target
    /// type) under the spelling of its declared type, else null. Faster
    /// if `h` records column metadata (engine.setColumnMetadata());
    /// otherwise the statement is compiled again for it.
    pub fn get(c: *Columns, h: *engine.Handle, v: *engine.Vm, i: usize) error{OutOfMemory}!?Entry {
        _ = c;
        // An expression: the type its frontend gave it, in the dialect of
        // the statement.
        const o = engine.columnOrigin(v, i) orelse return declared(v, i, engine.statementDialect(v));
        const t = engine.catalogType(h, o.database, o.table, o.column) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return declared(v, i, .sqlite),
        } orelse return declared(v, i, .sqlite);
        return .{ .type = t.type, .name = t.name, .dialect = t.dialect };
    }

    /// get() of result column `i` of a statement of the Zig API.
    pub fn ofStmt(c: *Columns, s: *Stmt, i: usize) error{OutOfMemory}!?Entry {
        return c.get(s.conn.h, s.vm, i);
    }

    fn declared(v: *engine.Vm, i: usize, d: Dialect) ?Entry {
        const name = engine.columnDecltype(v, i) orelse return null;
        // The type the statement knows, else the declared type read.
        const t = engine.resultType(v, i) orelse types.parse(d, name);
        return .{ .type = t, .name = name, .dialect = d };
    }
};

test text {
    var buf: [max_len]u8 = undefined;
    const t = std.testing;
    const boolean: Type = .{ .logical = .boolean };
    try t.expectEqualStrings("t", text(.postgres, boolean, .{ .integer = 1 }, &buf).?);
    try t.expectEqualStrings("f", text(.postgres, boolean, .{ .integer = 0 }, &buf).?);
    try t.expectEqualStrings("FALSE", text(.oracle, boolean, .{ .integer = 0 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.mariadb, boolean, .{ .integer = 1 }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, boolean, .null, &buf));
    const money: Type = .{ .logical = .numeric, .precision = 10, .scale = 2 };
    try t.expectEqualStrings("1.50", text(.postgres, money, .{ .float = 1.5 }, &buf).?);
    try t.expectEqualStrings("220.00", text(.mariadb, money, .{ .integer = 220 }, &buf).?);
    try t.expectEqualStrings("-0.25", text(.mssql, money, .{ .float = -0.25 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.oracle, money, .{ .float = 1.5 }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{ .logical = .numeric }, .{ .float = 1.5 }, &buf));
    // A scale of 0: no point (1e3 is 1000 in PostgreSQL, SQLite's 1000.0).
    const whole: Type = .{ .logical = .numeric, .scale = 0 };
    try t.expectEqualStrings("1000", text(.postgres, whole, .{ .float = 1000.0 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, whole, .{ .integer = 3 }, &buf));
    const tz: Type = .{ .logical = .timestamp_tz };
    try t.expectEqualStrings("2024-01-02 03:04:05+00", text(.postgres, tz, .{ .text = "2024-01-02 03:04:05" }, &buf).?);
    try t.expectEqualStrings("2024-01-02 03:04:05.123+00", text(.postgres, tz, .{ .text = "2024-01-02 03:04:05.123" }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, tz, .{ .text = "2024-01-02 03:04:05+09:00" }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, tz, .{ .text = "2024-01-02" }, &buf));
}
