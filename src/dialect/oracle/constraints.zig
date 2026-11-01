//! Oracle's errors of failed constraints (Hooks.constraint): ORA-00001,
//! ORA-01400 (ORA-01407 for an UPDATE), ORA-02290, ORA-02291 and
//! ORA-02292, with the constraint as SCHEMA.NAME. Oracle names an
//! unnamed constraint SYS_Cnnnnnn after a counter of the database; here
//! the name is stable: SYS_C_<TABLE>_<COLUMNS> (SYS_C_<TABLE> for a CHECK).

const std = @import("std");
const dialect = @import("../dialect.zig");
const state = @import("state.zig");

const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Allocator = std.mem.Allocator;

pub const constraint: dialect.Constraint = .{
    .message = message,
    .foreign_key = .{ .msg = "ORA-02291: integrity constraint violated - parent key not found", .state = .numbered("23503", 2291) },
};

fn message(a: Allocator, v: Violation) error{OutOfMemory}!Failure {
    const t = Violation.bare(v.table);
    const schema = schemaOf(v);
    return switch (v.kind) {
        .not_null => if (v.op == .update) .{
            .msg = try std.fmt.allocPrint(a, "ORA-01407: cannot update (\"{s}\".\"{s}\".\"{s}\") to NULL", .{ schema, t, v.columns[0] }),
            .state = .numbered("23502", 1407),
        } else .{
            .msg = try std.fmt.allocPrint(a, "ORA-01400: cannot insert NULL into (\"{s}\".\"{s}\".\"{s}\")", .{ schema, t, v.columns[0] }),
            .state = .numbered("23502", 1400),
        },
        .unique, .primary_key, .unique_index => if (v.op == .create_index) .{
            .msg = "ORA-01452: cannot CREATE UNIQUE INDEX; duplicate keys found",
            .state = .numbered("23505", 1452),
        } else .{
            .msg = try std.fmt.allocPrint(a, "ORA-00001: unique constraint ({s}.{s}) violated", .{ schema, try name(a, v) }),
            .state = .numbered("23505", 1),
        },
        .check => .{
            .msg = try std.fmt.allocPrint(a, "ORA-02290: check constraint ({s}.{s}) violated", .{ schema, try name(a, v) }),
            .state = .numbered("23514", 2290),
        },
        .foreign_key => .{
            .msg = try std.fmt.allocPrint(a, "ORA-02291: integrity constraint ({s}.{s}) violated - parent key not found", .{ schema, try name(a, v) }),
            .state = .numbered("23503", 2291),
        },
        .referenced => .{
            .msg = try std.fmt.allocPrint(a, "ORA-02292: integrity constraint ({s}.{s}) violated - child record found", .{ schema, try name(a, v) }),
            .state = .numbered("23503", 2292),
        },
    };
}

/// The schema of the table: a named schema's, the user's for main.
fn schemaOf(v: Violation) []const u8 {
    if (Violation.schemaOf(v.table)) |s| return s;
    return if (std.ascii.eqlIgnoreCase(v.database, "main")) state.user else v.database;
}

/// The constraint's name: the user's (an index's), else a stable one.
fn name(a: Allocator, v: Violation) error{OutOfMemory}![]const u8 {
    if (v.name) |n| return Violation.bare(n);
    const t = Violation.bare(v.table);
    if (v.kind == .check or v.columns.len == 0) return std.fmt.allocPrint(a, "SYS_C_{s}", .{t});
    return std.fmt.allocPrint(a, "SYS_C_{s}_{s}", .{ t, try Violation.joined(a, v.columns, "{s}", "_") });
}

test message {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try message(a, .{ .kind = .primary_key, .op = .insert, .database = "main", .table = "P", .columns = &.{"ID"}, .name = "P_PK" });
    try t.expectEqualStrings("ORA-00001: unique constraint (MAIN.P_PK) violated", f.msg);
    try t.expectEqual(@as(u32, 1), f.state.number);
    f = try message(a, .{ .kind = .not_null, .op = .update, .database = "main", .table = "HR.T", .columns = &.{"A"} });
    try t.expectEqualStrings("ORA-01407: cannot update (\"HR\".\"T\".\"A\") to NULL", f.msg);
}
