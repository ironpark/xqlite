//! The SQLite dialect: SQLite's tokenizer (src/parse/tokenize.zig) and
//! LALR(1) parser (src/parse/parser.zig, whose reduce actions lower into
//! the IR of src/ir/ir.zig), with no semantic hooks. This is the
//! reference frontend: it produces the same parse trees, and so the same
//! bytecode, as sqlite3.

const int = @import("../../sql/sqlite_int.zig");
const tokenize = @import("../../parse/tokenize.zig");
const dialect = @import("../dialect.zig");

pub const frontend: dialect.Frontend = .{ .name = "sqlite", .run = run };

/// SQLite changes nothing.
pub const hooks: dialect.Hooks = .{};

/// sqlite3RunParser().
pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return tokenize.runParser(p, sql);
}
