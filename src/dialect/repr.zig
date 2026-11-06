//! The values a dialect stores as a BLOB of a form of its own, and their
//! text: a numeric's key (pkg/decimal), a uuid's 16 bytes, an interval's
//! key and fields (pkg/datetime/src/interval.zig), jsonb as SQLite's JSONB (pkg/json/src/jsonb.zig).
//! One entry per logical type (forms), which the display layer
//! (api/display.zig) and the wire servers read: a value is shown by the
//! dialect a client speaks (the viewer), whichever dialect stored it, so
//! the forms are outside the dialect directories, in every build
//! (-Ddialects); what needs a dialect's code (PostgreSQL's interval
//! text) is null without it.
//!
//! What a dialect does with the forms (how it stores, compares, groups
//! and casts them) is its own: PostgreSQL's postgres/repr.zig.

const std = @import("std");
const types = @import("../sql/types.zig");
const Dialect = @import("dialect.zig").Dialect;
const ivl = @import("datetime").interval;
const pgdt = @import("datetime").pg;

const Type = types.Type;
const Logical = types.Logical;
const Allocator = std.mem.Allocator;

/// The longest text() writes into its buffer (an interval's text is up
/// to 70 bytes).
pub const max_len = 96;

/// The BLOB form of the values of a logical type.
pub const Form = struct {
    logical: Logical,
    /// The text of BLOB `b` as `viewer` shows it, in `buf` or static;
    /// null for SQLite's (the blob) or a BLOB not of the form.
    text: ?*const fn (viewer: Dialect, t: Type, b: []const u8, buf: *[max_len]u8) ?[]const u8 = null,
    /// The text of BLOB `b` that needs memory of its own (in `gpa`, which
    /// the caller frees it with), null as text(). Asked before text().
    text_alloc: ?*const fn (gpa: Allocator, viewer: Dialect, t: Type, b: []const u8) Allocator.Error!?[]u8 = null,
};

pub const forms = [_]Form{
    .{ .logical = .numeric, .text = numericText, .text_alloc = numericTextAlloc },
    .{ .logical = .uuid, .text = uuidText },
    .{ .logical = .interval, .text = intervalBlobText },
    .{ .logical = .jsonb, .text_alloc = jsonbTextAlloc },
};

/// The BLOB form of type `l`, null if it has none.
pub fn of(l: Logical) ?*const Form {
    for (&forms) |*f| if (f.logical == l) return f;
    return null;
}

/// The text of BLOB `b`, a value of type `t`, as `viewer` shows it (in
/// `buf` or static); null for SQLite's text.
pub fn text(viewer: Dialect, t: Type, b: []const u8, buf: *[max_len]u8) ?[]const u8 {
    const f = (of(t.logical) orelse return null).text orelse return null;
    return f(viewer, t, b, buf);
}

/// The text of BLOB `b` that needs memory of its own (in `gpa`), null for
/// the others (text()) and in SQLite's dialect, which shows the blob.
pub fn textAlloc(gpa: Allocator, viewer: Dialect, t: Type, b: []const u8) Allocator.Error!?[]u8 {
    if (viewer == .sqlite) return null;
    const f = (of(t.logical) orelse return null).text_alloc orelse return null;
    return f(gpa, viewer, t, b);
}

// ============================================================ numeric
// A numeric key (pkg/decimal: a BLOB in the order of the numbers) is its
// digits in every dialect but SQLite's: with the scale of its type, else
// the display scale the key carries, else its own digits.

const decimal = @import("decimal");

/// The scale a numeric key of type `t` shows with in `viewer`: its type's
/// (Oracle's NUMBER(p,s) drops trailing zeros), else its own.
fn keyScale(viewer: Dialect, t: Type) ?u32 {
    return switch (viewer) {
        .postgres, .mariadb, .mssql => if (t.scale) |s| s else null,
        .sqlite, .oracle => null,
    };
}

/// The text of numeric key `k` in `buf`, null if it is no key or longer
/// than `buf` (numericTextAlloc()).
fn numericText(viewer: Dialect, t: Type, k: []const u8, buf: *[max_len]u8) ?[]const u8 {
    if (viewer == .sqlite) return null;
    var mem: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&mem);
    const z = decimal.keyText(fba.allocator(), k, keyScale(viewer, t)) catch return null;
    if (z.len > buf.len) return null;
    @memcpy(buf[0..z.len], z);
    return buf[0..z.len];
}

/// numericText() of any length.
fn numericTextAlloc(gpa: Allocator, viewer: Dialect, t: Type, k: []const u8) Allocator.Error!?[]u8 {
    return decimal.keyText(gpa, k, keyScale(viewer, t)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

// =============================================================== uuid
// PostgreSQL's uuid is 16 bytes (an older table's column, and SQL
// Server's uniqueidentifier, are text, shown as stored).

fn uuidText(viewer: Dialect, t: Type, b: []const u8, buf: *[max_len]u8) ?[]const u8 {
    _ = t;
    if (viewer == .sqlite or b.len != 16) return null;
    return std.fmt.bufPrint(buf, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] }) catch null;
}

// =========================================================== interval
// An interval BLOB (pkg/datetime/src/interval.zig) as PostgreSQL's clients see it: for the
// shell and the wire servers (their binary format, their parameters).

pub const Interval = ivl.Interval;

/// The interval BLOB `b` is, null if it is none.
pub fn intervalOf(b: []const u8) ?Interval {
    return ivl.decode(b);
}

/// The text of interval BLOB `b` in PostgreSQL; the text of an older
/// database's TEXT column is shown as stored.
fn intervalBlobText(viewer: Dialect, t: Type, b: []const u8, buf: *[max_len]u8) ?[]const u8 {
    _ = t;
    if (viewer != .postgres) return null;
    return intervalText(intervalOf(b) orelse return null, buf);
}

/// The interval of text `z` in PostgreSQL's input (an older database's
/// TEXT column, a parameter), null if it is none or PostgreSQL is not in
/// the build.
pub fn parseInterval(z: []const u8) ?Interval {
    if (comptime !Dialect.postgres.built()) return null;
    return @import("postgres/ivinput.zig").decode(z, -1) catch null;
}

/// The text of `iv` in PostgreSQL's default output style.
pub fn intervalText(iv: Interval, buf: *[max_len]u8) []const u8 {
    return intervalTextStyle(iv, .postgres, buf);
}

/// PostgreSQL's IntervalStyle (a session's: valuetext.Settings).
pub const IntervalStyle = pgdt.IntervalStyle;

/// The text of `iv` in IntervalStyle `style` (pkg/datetime's pg).
pub fn intervalTextStyle(iv: Interval, style: IntervalStyle, buf: *[max_len]u8) []const u8 {
    return pgdt.formatIntervalStyle(iv, style, buf);
}

/// The text of interval[] `z` (as stored: its elements in the default
/// style) with its elements in `style` (in `gpa`); null if it is no
/// array's text or PostgreSQL is not in the build.
pub fn intervalArrayText(gpa: Allocator, z: []const u8, style: IntervalStyle) Allocator.Error!?[]u8 {
    if (comptime !Dialect.postgres.built()) return null;
    return @import("postgres/array.zig").restyleIntervals(gpa, z, style);
}

// ============================================================== jsonb
// jsonb as SQLite's JSONB (pkg/json/src/jsonb.zig): its JSON text with PostgreSQL's
// spacing (`{"a": 1}`).

fn jsonbTextAlloc(gpa: Allocator, viewer: Dialect, t: Type, b: []const u8) Allocator.Error!?[]u8 {
    _ = viewer;
    _ = t;
    return @import("json").jsonb.text(gpa, b);
}
