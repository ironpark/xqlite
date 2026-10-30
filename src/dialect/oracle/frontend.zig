//! The Oracle Database dialect. Not written yet: every statement but a blank one
//! fails. See docs/architecture.md for what a frontend does (parse into
//! the IR tree of src/ir/tree.zig, lower and render it with src/ir).

const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const ir = @import("../../ir/ir.zig");

pub const frontend: dialect.Frontend = .{ .run = run };

pub const hooks: dialect.Hooks = .{};

pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    var i: usize = 0;
    while (i < sql.len and (sql[i] == ' ' or sql[i] == '\t' or sql[i] == '\n' or sql[i] == '\r' or sql[i] == ';')) i += 1;
    if (i == sql.len) {
        p.tail = sql[sql.len..];
        return;
    }
    ir.stmt.errorMsg(p, "oracle dialect: parser not implemented", .{});
    return error.ParseFailed;
}
