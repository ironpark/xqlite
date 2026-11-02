//! PostgreSQL's errors of failed constraints (Hooks.constraint): the
//! primary line of psql's ERROR, and for a duplicate key of integer and
//! text columns its DETAIL line (`Key (a)=(1) already exists.`; the
//! others are not kept). An unnamed constraint has PostgreSQL's name:
//! <table>_pkey, <table>_<columns>_key, <table>_<columns>_fkey (CHECKs
//! are named by the parser, <table>_<column>_check and <table>_check).

const std = @import("std");
const dialect = @import("../dialect.zig");

const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Allocator = std.mem.Allocator;

pub const constraint: dialect.Constraint = .{
    .message = message,
    .foreign_key = .{ .msg = "insert or update violates foreign key constraint", .state = .of("23503") },
};

fn message(a: Allocator, v: Violation) error{OutOfMemory}!Failure {
    const t = Violation.bare(v.table);
    return switch (v.kind) {
        .not_null => .{
            .msg = try std.fmt.allocPrint(a, "null value in column \"{s}\" of relation \"{s}\" violates not-null constraint", .{ v.columns[0], t }),
            .state = .of("23502"),
        },
        .unique, .primary_key, .unique_index => if (v.op == .create_index) .{
            .msg = try std.fmt.allocPrint(a, "could not create unique index \"{s}\"", .{try name(a, v)}),
            .state = .of("23505"),
        } else .{
            .msg = try std.fmt.allocPrint(a, "duplicate key value violates unique constraint \"{s}\"{s}", .{ try name(a, v), try keyDetail(a, v) }),
            .state = .of("23505"),
        },
        .check => .{
            .msg = try std.fmt.allocPrint(a, "new row for relation \"{s}\" violates check constraint \"{s}\"", .{ t, try name(a, v) }),
            .state = .of("23514"),
        },
        .foreign_key => .{
            .msg = try std.fmt.allocPrint(a, "insert or update on table \"{s}\" violates foreign key constraint \"{s}\"", .{ t, try name(a, v) }),
            .state = .of("23503"),
        },
        .referenced => .{
            .msg = try std.fmt.allocPrint(a, "update or delete on table \"{s}\" violates foreign key constraint \"{s}\" on table \"{s}\"", .{ Violation.bare(v.parent), try name(a, v), t }),
            .state = .of("23503"),
        },
    };
}

/// The DETAIL of a duplicate key, `Key (a, b)=(1, x) already exists.`,
/// its values written at dialect.value_mark: only of columns whose values
/// the engine prints as PostgreSQL does (integers, text), else "".
fn keyDetail(a: Allocator, v: Violation) error{OutOfMemory}![]const u8 {
    if (!v.has_value or v.value_types.len != v.columns.len) return "";
    for (v.value_types) |t| switch ((t orelse return "").logical) {
        .int2, .int4, .int8, .text, .varchar => {},
        else => return "",
    };
    const util = @import("../../sql/util.zig");
    return std.fmt.allocPrint(a, "{s}Key ({s})=({c}) already exists.", .{ util.detail_mark, try Violation.joined(a, v.columns, "{s}", ", "), dialect.value_mark });
}

/// The constraint's name: the user's, else PostgreSQL's.
fn name(a: Allocator, v: Violation) error{OutOfMemory}![]const u8 {
    if (v.name) |n| return Violation.bare(n);
    const t = Violation.bare(v.table);
    return switch (v.kind) {
        .primary_key => std.fmt.allocPrint(a, "{s}_pkey", .{t}),
        .check => std.fmt.allocPrint(a, "{s}_check", .{t}),
        .foreign_key, .referenced => std.fmt.allocPrint(a, "{s}_{s}_fkey", .{ t, try Violation.joined(a, v.columns, "{s}", "_") }),
        else => std.fmt.allocPrint(a, "{s}_{s}_key", .{ t, try Violation.joined(a, v.columns, "{s}", "_") }),
    };
}

test message {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cols: []const []const u8 = &.{"a"};
    var f = try message(a, .{ .kind = .unique, .op = .insert, .database = "main", .table = "t", .columns = cols });
    try t.expectEqualStrings("duplicate key value violates unique constraint \"t_a_key\"", f.msg);
    try t.expectEqualStrings("23505", &f.state.sqlstate);
    f = try message(a, .{ .kind = .unique, .op = .insert, .database = "main", .table = "t", .columns = cols, .has_value = true, .value_types = &.{.{ .logical = .text }} });
    try t.expectEqualStrings("duplicate key value violates unique constraint \"t_a_key\"\nDETAIL:  Key (a)=(\x01) already exists.", f.msg);
    f = try message(a, .{ .kind = .primary_key, .op = .insert, .database = "main", .table = "s.t", .columns = cols });
    try t.expectEqualStrings("duplicate key value violates unique constraint \"t_pkey\"", f.msg);
    f = try message(a, .{ .kind = .referenced, .op = .delete, .database = "main", .table = "c", .columns = &.{"pid"}, .parent = "p", .parent_columns = cols });
    try t.expectEqualStrings("update or delete on table \"p\" violates foreign key constraint \"c_pid_fkey\" on table \"c\"", f.msg);
}
