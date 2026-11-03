//! Values as the dialect a client speaks shows them.
//!
//! The engine stores values as SQLite does: a boolean is the integer 0 or
//! 1, a `numeric(10,2)` is a number without its trailing zeros, a
//! `timestamptz` is UTC text without an offset. A client of a dialect
//! expects that dialect's text: PostgreSQL's psql shows `t`, `1.50` and
//! `2024-01-02 03:04:05+00`. text() writes a value so, from the type of
//! its column (types.zig), for the shell and the wire protocols alike;
//! the values themselves, and what the C and Zig APIs return, stay
//! SQLite's. The text is dialect/valuetext.zig's, which a dialect's
//! messages (a constraint's DETAIL) write values with too.
//!
//! A value a dialect stores as a BLOB of its own form (a numeric's key, a
//! uuid's bytes, an interval, jsonb as JSONB) is written by the form's
//! entry in dialect/repr.zig: a numeric key as its digits by every dialect
//! but SQLite's, with the scale of its type, else the display scale the
//! key carries, else its own digits; textAlloc() writes one longer than
//! max_len.
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

/// The longest text() writes into its buffer (an interval's text is up
/// to 70 bytes).
pub const max_len = valuetext.max_len;

/// The core of the display, which a dialect's messages write values with
/// too (dialect/valuetext.zig).
const valuetext = @import("../dialect/valuetext.zig");
/// The values a dialect stores as a BLOB of its own form, and their text.
const repr = @import("../dialect/repr.zig");

/// `v` as the core holds it.
fn cell(v: Value) valuetext.Cell {
    return switch (v) {
        inline else => |x, tag| @unionInit(valuetext.Cell, @tagName(tag), x),
    };
}

/// What a connection's session changes in the text of values
/// (PostgreSQL's IntervalStyle: `SET IntervalStyle`); Db.displaySettings()
/// gives a connection's, `.{}` the defaults.
pub const Settings = valuetext.Settings;

/// `v`, a value of a column of type `t`, as `viewer` shows it in a
/// session of `settings` (an interval in its IntervalStyle), if not as
/// SQLite does (in `buf` or static); null for SQLite's text.
pub fn text(viewer: Dialect, settings: Settings, t: Type, v: Value, buf: *[max_len]u8) ?[]const u8 {
    return valuetext.text(viewer, settings, t, cell(v), buf);
}

/// The text of `v` that needs memory of its own (in `gpa`, which the
/// caller frees it with), null for the others (text()), in every dialect
/// but SQLite's, which shows the blob: a jsonb value stored as SQLite's
/// JSONB (a blob, dialect/jsonb.zig) is its JSON text with PostgreSQL's
/// spacing (`{"a": 1}`); a numeric key (dialect/decimal.zig) its digits
/// (as text() writes them, of any length); an interval[]'s elements in
/// the IntervalStyle of `settings`. dialect/repr.zig.
pub fn textAlloc(gpa: std.mem.Allocator, viewer: Dialect, settings: Settings, t: Type, v: Value) error{OutOfMemory}!?[]u8 {
    return valuetext.textAlloc(gpa, viewer, settings, t, cell(v));
}

/// PostgreSQL's text of `v` (not NULL), a value of a column of type `t`,
/// in a session of `settings` (valuetext.pgText()): text()'s, a double's
/// shortest digits, a text as stored; null for a blob no form writes.
pub fn pgText(settings: Settings, t: Type, v: Value, buf: *[max_len]u8) ?[]const u8 {
    return valuetext.pgText(settings, t, cell(v), buf);
}

/// PostgreSQL's text of a double (valuetext.floatText()).
pub const floatText = valuetext.floatText;

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
    try t.expectEqualStrings("t", text(.postgres, .{}, boolean, .{ .integer = 1 }, &buf).?);
    try t.expectEqualStrings("f", text(.postgres, .{}, boolean, .{ .integer = 0 }, &buf).?);
    try t.expectEqualStrings("FALSE", text(.oracle, .{}, boolean, .{ .integer = 0 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.mariadb, .{}, boolean, .{ .integer = 1 }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, boolean, .null, &buf));
    const money: Type = .{ .logical = .numeric, .precision = 10, .scale = 2 };
    try t.expectEqualStrings("1.50", text(.postgres, .{}, money, .{ .float = 1.5 }, &buf).?);
    try t.expectEqualStrings("220.00", text(.mariadb, .{}, money, .{ .integer = 220 }, &buf).?);
    try t.expectEqualStrings("-0.25", text(.mssql, .{}, money, .{ .float = -0.25 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.oracle, .{}, money, .{ .float = 1.5 }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, .{ .logical = .numeric }, .{ .float = 1.5 }, &buf));
    // A scale of 0: no point (1e3 is 1000 in PostgreSQL, SQLite's 1000.0).
    const whole: Type = .{ .logical = .numeric, .scale = 0 };
    try t.expectEqualStrings("1000", text(.postgres, .{}, whole, .{ .float = 1000.0 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, whole, .{ .integer = 3 }, &buf));
    // A numeric key, with the scale of its type or its own.
    const k15 = [_]u8{ 0x40, 0x81, 3, 100 };
    try t.expectEqualStrings("1.50", text(.postgres, .{}, money, .{ .blob = &k15 }, &buf).?);
    try t.expectEqualStrings("1.5", text(.postgres, .{}, .{ .logical = .numeric }, .{ .blob = &k15 }, &buf).?);
    try t.expectEqualStrings("1.5", text(.oracle, .{}, money, .{ .blob = &k15 }, &buf).?);
    const k150 = [_]u8{ 0x40, 0x81, 3, 100, 0, 3 };
    try t.expectEqualStrings("1.500", text(.postgres, .{}, .{ .logical = .numeric }, .{ .blob = &k150 }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.sqlite, .{}, money, .{ .blob = &k15 }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, money, .{ .blob = "x" }, &buf));
    const tz: Type = .{ .logical = .timestamp_tz };
    try t.expectEqualStrings("2024-01-02 03:04:05+00", text(.postgres, .{}, tz, .{ .text = "2024-01-02 03:04:05" }, &buf).?);
    try t.expectEqualStrings("2024-01-02 03:04:05.123+00", text(.postgres, .{}, tz, .{ .text = "2024-01-02 03:04:05.123" }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, tz, .{ .text = "2024-01-02 03:04:05+09:00" }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, tz, .{ .text = "2024-01-02" }, &buf));
    const uuid: Type = .{ .logical = .uuid };
    try t.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", text(.postgres, .{}, uuid, .{ .blob = "\xa0\xee\xbc\x99\x9c\x0b\x4e\xf8\xbb\x6d\x6b\xb9\xbd\x38\x0a\x11" }, &buf).?);
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, uuid, .{ .text = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" }, &buf));
    try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, uuid, .{ .blob = "\x01\x02" }, &buf));
    // interval BLOB: its text; an older database's TEXT as stored.
    if (comptime Dialect.postgres.built()) {
        const Interval = repr.Interval;
        const iv: Type = .{ .logical = .interval };
        const b = (Interval{ .months = 14, .days = -3, .time = 3_600_000_000 }).encode();
        try t.expectEqualStrings("1 year 2 mons -3 days +01:00:00", text(.postgres, .{}, iv, .{ .blob = &b }, &buf).?);
        const inf = Interval.neg_infinity.encode();
        try t.expectEqualStrings("-infinity", text(.postgres, .{}, iv, .{ .blob = &inf }, &buf).?);
        try t.expectEqual(@as(?[]const u8, null), text(.postgres, .{}, iv, .{ .text = "1 day" }, &buf));
        try t.expectEqual(@as(?[]const u8, null), text(.sqlite, .{}, iv, .{ .blob = &b }, &buf));
        try t.expectEqual(Interval{ .days = 1, .time = 7_200_000_000 }, repr.parseInterval("1 day 2 hours").?);
    }
}
