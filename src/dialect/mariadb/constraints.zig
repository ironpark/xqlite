//! MariaDB's errors of failed constraints (Hooks.constraint), with
//! MariaDB's numbers (1062, 1048, 4025, 1452, 1451) and the SQLSTATE in
//! PostgreSQL's code space, as the other errors of the dialect (MariaDB
//! itself says 23000 for all of them). A key is named as MariaDB names
//! it: PRIMARY, the index (`t$name` is the key `name` of t), an unnamed
//! foreign key <table>_ibfk_<n>.

const std = @import("std");
const dialect = @import("../dialect.zig");

const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Allocator = std.mem.Allocator;
const B = dialect.Quoted('`');

pub const constraint: dialect.Constraint = .{
    .message = message,
    .foreign_key = .{ .msg = "Cannot add or update a child row: a foreign key constraint fails", .state = .numbered("23503", 1452) },
    .value_separator = "-",
};

fn message(a: Allocator, v: Violation) error{OutOfMemory}!Failure {
    const t = Violation.bare(v.table);
    const db = Violation.schemaOf(v.table) orelse v.database;
    return switch (v.kind) {
        .not_null => .{
            .msg = try std.fmt.allocPrint(a, "Column '{s}' cannot be null", .{v.columns[0]}),
            .state = .numbered("23502", 1048),
        },
        .unique, .primary_key, .unique_index => .{
            .msg = if (v.has_value)
                try std.fmt.allocPrint(a, "Duplicate entry '{c}' for key '{s}'", .{ dialect.value_mark, keyName(v) })
            else
                try std.fmt.allocPrint(a, "Duplicate entry for key '{s}'", .{keyName(v)}),
            .state = .numbered("23505", 1062),
        },
        .check => .{
            .msg = try std.fmt.allocPrint(a, "CONSTRAINT {f} failed for {f}.{f}", .{ B{ .z = v.name orelse "CONSTRAINT_1" }, B{ .z = db }, B{ .z = t } }),
            .state = .numbered("23514", 4025),
        },
        .foreign_key, .referenced => .{
            .msg = try std.fmt.allocPrint(a, "{s}: a foreign key constraint fails ({f}.{f}, CONSTRAINT {f} FOREIGN KEY ({s}) REFERENCES {f} ({s}))", .{
                if (v.kind == .foreign_key) "Cannot add or update a child row" else "Cannot delete or update a parent row",
                B{ .z = db },
                B{ .z = t },
                B{ .z = if (v.name) |n| n else try std.fmt.allocPrint(a, "{s}_ibfk_{d}", .{ t, v.ordinal }) },
                try Violation.joined(a, v.columns, "`{s}`", ", "),
                B{ .z = Violation.bare(v.parent) },
                try Violation.joined(a, v.parent_columns, "`{s}`", ", "),
            }),
            .state = .numbered("23503", if (v.kind == .foreign_key) 1452 else 1451),
        },
    };
}

/// The name of the key: PRIMARY, the index's (after its table's `t$`),
/// the user's, else its first column's.
fn keyName(v: Violation) []const u8 {
    if (v.kind == .primary_key) return "PRIMARY";
    if (v.name) |n| {
        const b = Violation.bare(n);
        return if (std.mem.indexOfScalar(u8, b, '$')) |i| b[i + 1 ..] else b;
    }
    return if (v.columns.len > 0) v.columns[0] else "";
}

test message {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try message(a, .{ .kind = .unique_index, .op = .insert, .database = "main", .table = "t", .columns = &.{"a"}, .name = "t$ua", .has_value = true });
    try t.expectEqualStrings("Duplicate entry '\x01' for key 'ua'", f.msg);
    try t.expectEqual(@as(u32, 1062), f.state.number);
    f = try message(a, .{ .kind = .foreign_key, .op = .insert, .database = "main", .table = "c", .columns = &.{"pid"}, .parent = "p", .parent_columns = &.{"id"}, .ordinal = 1 });
    try t.expectEqualStrings("Cannot add or update a child row: a foreign key constraint fails (`main`.`c`, CONSTRAINT `c_ibfk_1` FOREIGN KEY (`pid`) REFERENCES `p` (`id`))", f.msg);
}
