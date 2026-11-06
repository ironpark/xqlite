//! The SQLite dialect: SQLite's lexer (lexer.zig) and parser (parser.zig,
//! which lowers into the IR of src/ir/ir.zig), with no semantic hooks. This is the
//! reference frontend: it produces the same parse trees, and so the same
//! bytecode, as sqlite3.

const int = @import("../../sql/sqlite_int.zig");
const parser = @import("parser.zig");
const dialect = @import("../dialect.zig");

pub const frontend: dialect.Frontend = .{ .run = run };

/// SQLite changes nothing.
pub const hooks: dialect.Hooks = .{};

/// sqlite3RunParser().
pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return parser.runParser(p, sql);
}
