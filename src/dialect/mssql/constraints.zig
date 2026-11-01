//! SQL Server's errors of failed constraints (Hooks.constraint), with
//! its numbers (2627, 2601, 515, 547). SQL Server names an unnamed
//! constraint with a random suffix (PK__t__3213E83F0AD2A005); here the
//! name is stable and without it: PK__<table>, UQ__<table>__<columns>,
//! FK__<table>__<columns>, CK__<table>. The CHECK error does not name the
//! column of a column CHECK, and the informational "The statement has
//! been terminated." that follows the error is not kept.

const std = @import("std");
const dialect = @import("../dialect.zig");

const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Allocator = std.mem.Allocator;

pub const constraint: dialect.Constraint = .{
    .message = message,
    .foreign_key = .{ .msg = "The statement conflicted with a FOREIGN KEY constraint.", .state = .numbered("23503", 547) },
    .value_separator = ", ",
};

fn message(a: Allocator, v: Violation) error{OutOfMemory}!Failure {
    const t = Violation.bare(v.table);
    const schema = Violation.schemaOf(v.table) orelse "dbo";
    const stmt: []const u8 = switch (v.op) {
        .insert => "INSERT",
        .update => "UPDATE",
        .delete => "DELETE",
        .create_index => "CREATE UNIQUE INDEX",
    };
    const dup: []const u8 = if (v.has_value) try std.fmt.allocPrint(a, " The duplicate key value is ({c}).", .{dialect.value_mark}) else "";
    if (v.op == .create_index) return .{
        .msg = try std.fmt.allocPrint(a, "The CREATE UNIQUE INDEX statement terminated because a duplicate key was found for the object name '{s}.{s}' and the index name '{s}'.", .{ schema, t, try name(a, v) }),
        .state = .numbered("23505", 1505),
    };
    return switch (v.kind) {
        .not_null => .{
            .msg = try std.fmt.allocPrint(a, "Cannot insert the value NULL into column '{s}', table '{s}.{s}.{s}'; column does not allow nulls. {s} fails.", .{ v.columns[0], v.database, schema, t, stmt }),
            .state = .numbered("23502", 515),
        },
        .primary_key, .unique => .{
            .msg = try std.fmt.allocPrint(a, "Violation of {s} constraint '{s}'. Cannot insert duplicate key in object '{s}.{s}'.{s}", .{ if (v.kind == .primary_key) "PRIMARY KEY" else "UNIQUE KEY", try name(a, v), schema, t, dup }),
            .state = .numbered("23505", 2627),
        },
        .unique_index => .{
            .msg = try std.fmt.allocPrint(a, "Cannot insert duplicate key row in object '{s}.{s}' with unique index '{s}'.{s}", .{ schema, t, try name(a, v), dup }),
            .state = .numbered("23505", 2601),
        },
        .check => .{
            .msg = try std.fmt.allocPrint(a, "The {s} statement conflicted with the CHECK constraint \"{s}\". The conflict occurred in database \"{s}\", table \"{s}.{s}\".", .{ stmt, try name(a, v), v.database, schema, t }),
            .state = .numbered("23514", 547),
        },
        .foreign_key => .{
            .msg = try std.fmt.allocPrint(a, "The {s} statement conflicted with the FOREIGN KEY constraint \"{s}\". The conflict occurred in database \"{s}\", table \"{s}.{s}\"{s}.", .{
                stmt,                                      try name(a, v),           v.database,
                Violation.schemaOf(v.parent) orelse "dbo", Violation.bare(v.parent), try column(a, v.parent_columns),
            }),
            .state = .numbered("23503", 547),
        },
        .referenced => .{
            .msg = try std.fmt.allocPrint(a, "The {s} statement conflicted with the REFERENCE constraint \"{s}\". The conflict occurred in database \"{s}\", table \"{s}.{s}\"{s}.", .{
                stmt, try name(a, v), v.database, schema, t, try column(a, v.columns),
            }),
            .state = .numbered("23503", 547),
        },
    };
}

/// ", column 'c'" for a key of one column.
fn column(a: Allocator, cols: []const []const u8) error{OutOfMemory}![]const u8 {
    if (cols.len != 1) return "";
    return std.fmt.allocPrint(a, ", column '{s}'", .{cols[0]});
}

/// The constraint's name: the user's (an index's), else a stable one.
fn name(a: Allocator, v: Violation) error{OutOfMemory}![]const u8 {
    if (v.name) |n| return Violation.bare(n);
    const t = Violation.bare(v.table);
    return switch (v.kind) {
        .primary_key => std.fmt.allocPrint(a, "PK__{s}", .{t}),
        .check => std.fmt.allocPrint(a, "CK__{s}", .{t}),
        .foreign_key, .referenced => std.fmt.allocPrint(a, "FK__{s}__{s}", .{ t, try Violation.joined(a, v.columns, "{s}", "_") }),
        else => std.fmt.allocPrint(a, "UQ__{s}__{s}", .{ t, try Violation.joined(a, v.columns, "{s}", "_") }),
    };
}

test message {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try message(a, .{ .kind = .primary_key, .op = .insert, .database = "main", .table = "t", .columns = &.{"id"}, .has_value = true });
    try t.expectEqualStrings("Violation of PRIMARY KEY constraint 'PK__t'. Cannot insert duplicate key in object 'dbo.t'. The duplicate key value is (\x01).", f.msg);
    try t.expectEqual(@as(u32, 2627), f.state.number);
    f = try message(a, .{ .kind = .not_null, .op = .update, .database = "main", .table = "t", .columns = &.{"a"} });
    try t.expectEqualStrings("Cannot insert the value NULL into column 'a', table 'main.dbo.t'; column does not allow nulls. UPDATE fails.", f.msg);
}
