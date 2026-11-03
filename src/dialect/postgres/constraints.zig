//! PostgreSQL's errors of failed constraints (Hooks.constraint): the
//! primary line of psql's ERROR and its DETAIL line, with the values the
//! program writes at dialect.value_mark when the constraint fails
//! (valueText(), with the value display's text): a duplicate key's (`Key (a)=(1) already exists.`), a
//! foreign key's (`Key (pid)=(9) is not present in table "p".`, `Key
//! (id)=(1) is still referenced from table "c".`) and the row of a NOT
//! NULL or CHECK (`Failing row contains (1, null).`). An unnamed
//! constraint has PostgreSQL's name: <table>_pkey, <table>_<columns>_key,
//! <table>_<columns>_fkey (CHECKs are named by the parser,
//! <table>_<column>_check and <table>_check).

const std = @import("std");
const dialect = @import("../dialect.zig");
const util = @import("../../sql/util.zig");
const types = @import("../../sql/types.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const api = @import("../../vdbe/api.zig");
const valuetext = @import("../valuetext.zig");

const Violation = dialect.Violation;
const Failure = dialect.Failure;
const Allocator = std.mem.Allocator;

pub const constraint: dialect.Constraint = .{
    .message = message,
    .foreign_key = .{ .msg = "insert or update violates foreign key constraint", .state = .of("23503") },
    .value_text = valueText,
};

fn message(a: Allocator, v: Violation) error{OutOfMemory}!Failure {
    const t = Violation.bare(v.table);
    return switch (v.kind) {
        .not_null => fields(a, .of("23502"), try std.fmt.allocPrint(a, "null value in column \"{s}\" of relation \"{s}\" violates not-null constraint", .{ v.columns[0], t }), try failingRow(a, v)),
        .unique, .primary_key, .unique_index => if (v.op == .create_index) .{
            .msg = try std.fmt.allocPrint(a, "could not create unique index \"{s}\"", .{try name(a, v)}),
            .state = .of("23505"),
        } else fields(a, .of("23505"), try std.fmt.allocPrint(a, "duplicate key value violates unique constraint \"{s}\"", .{try name(a, v)}), try keyDetail(a, v, v.columns, "already exists.", .{})),
        .check => fields(a, .of("23514"), try std.fmt.allocPrint(a, "new row for relation \"{s}\" violates check constraint \"{s}\"", .{ t, try name(a, v) }), try failingRow(a, v)),
        // ri_ReportViolation().
        .foreign_key => fields(a, .of("23503"), try std.fmt.allocPrint(a, "insert or update on table \"{s}\" violates foreign key constraint \"{s}\"", .{ t, try name(a, v) }), try keyDetail(a, v, v.columns, "is not present in table \"{s}\".", .{Violation.bare(v.parent)})),
        .referenced => fields(a, .of("23503"), try std.fmt.allocPrint(a, "update or delete on table \"{s}\" violates foreign key constraint \"{s}\" on table \"{s}\"", .{ Violation.bare(v.parent), try name(a, v), t }), try keyDetail(a, v, v.parent_columns, "is still referenced from table \"{s}\".", .{t})),
    };
}

/// The DETAIL of the key `cols` of `v`: `Key (a, b)=(values) ` and
/// `what`, if the message shows its values (Violation.has_value).
fn keyDetail(a: Allocator, v: Violation, cols: []const []const u8, comptime what: []const u8, args: anytype) error{OutOfMemory}!?[]const u8 {
    if (!v.has_value) return null;
    return try std.fmt.allocPrint(a, "Key ({s})=({c}) " ++ what, .{ try Violation.joined(a, cols, "{s}", ", "), dialect.value_mark } ++ args);
}

/// The DETAIL of the row of a NOT NULL or a CHECK, if the message shows
/// it (Violation.has_row; ExecBuildSlotValueDescription()).
fn failingRow(a: Allocator, v: Violation) error{OutOfMemory}!?[]const u8 {
    if (!v.has_row) return null;
    return try std.fmt.allocPrint(a, "Failing row contains ({c}).", .{dialect.value_mark});
}

/// The error `msg` with its DETAIL `detail` (at util.detail_mark).
fn fields(a: Allocator, state: @import("../../sql/sqlite_int.zig").ErrorState, msg: []const u8, detail: ?[]const u8) error{OutOfMemory}!Failure {
    const text, const st = try util.joinFields(a, state, .{ .message = msg, .detail = detail });
    return .{ .msg = text, .state = st };
}

/// Constraint.value_text: value `m` of a column of type `t` as PostgreSQL's
/// output function writes it (the value display, valuetext.writePg());
/// NULL is `null`. A value of a row is cut at 64 bytes, with "..."
/// (ExecBuildSlotValueDescription()). False for a value of a type not
/// known, a bytea, or a numeric stored as a double without a scale
/// (whose text would not be PostgreSQL's): its DETAIL is left out.
fn valueText(gpa: Allocator, out: *std.Io.Writer, t: ?types.Type, m: *vi.Mem, row: bool) error{ OutOfMemory, WriteFailed }!bool {
    const c: valuetext.Cell = switch (api.valueType(m)) {
        vi.SQLITE_NULL => {
            try out.writeAll("null");
            return true;
        },
        vi.SQLITE_INTEGER => .{ .integer = api.valueInt64(m) },
        vi.SQLITE_FLOAT => .{ .float = api.valueDouble(m) },
        vi.SQLITE_TEXT => .{ .text = api.valueText(m) orelse return error.OutOfMemory },
        else => .{ .blob = api.valueBlob(m) orelse "" },
    };
    const ty = t orelse return false;
    switch (ty.logical) {
        .unknown, .bytes => return false,
        .numeric => if (c == .float and ty.scale == null) return false,
        else => {},
    }
    // In the session's IntervalStyle, as PostgreSQL's output function.
    const settings: valuetext.Settings = if (m.db) |db| .of(db) else .{};
    return valuetext.writePg(gpa, out, settings, ty, c, if (row) 64 else null);
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
    f = try message(a, .{ .kind = .unique, .op = .insert, .database = "main", .table = "t", .columns = cols, .has_value = true });
    try t.expectEqualStrings("duplicate key value violates unique constraint \"t_a_key\"\nDETAIL:  Key (a)=(\x01) already exists.", f.msg);
    try t.expectEqualStrings("Key (a)=(\x01) already exists.", util.splitFields(f.msg, f.state.fields).detail.?);
    f = try message(a, .{ .kind = .primary_key, .op = .insert, .database = "main", .table = "s.t", .columns = cols });
    try t.expectEqualStrings("duplicate key value violates unique constraint \"t_pkey\"", f.msg);
    f = try message(a, .{ .kind = .referenced, .op = .delete, .database = "main", .table = "c", .columns = &.{"pid"}, .parent = "p", .parent_columns = cols });
    try t.expectEqualStrings("update or delete on table \"p\" violates foreign key constraint \"c_pid_fkey\" on table \"c\"", f.msg);
    f = try message(a, .{ .kind = .referenced, .op = .delete, .database = "main", .table = "c", .columns = &.{"pid"}, .parent = "p", .parent_columns = &.{"id"}, .has_value = true });
    try t.expectEqualStrings("update or delete on table \"p\" violates foreign key constraint \"c_pid_fkey\" on table \"c\"\nDETAIL:  Key (id)=(\x01) is still referenced from table \"c\".", f.msg);
    f = try message(a, .{ .kind = .check, .op = .insert, .database = "main", .table = "t", .name = "t_a_check", .has_row = true });
    try t.expectEqualStrings("new row for relation \"t\" violates check constraint \"t_a_check\"\nDETAIL:  Failing row contains (\x01).", f.msg);
}
