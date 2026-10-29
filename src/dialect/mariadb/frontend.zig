//! The MariaDB dialect (Phase 6).
//!
//! The parser is not written yet: `run` only accepts blank text. What is
//! here already is the engine side: the function table, with functions
//! MariaDB adds (version()) and one it changes: CONCAT() is NULL if
//! an argument is NULL (SQLite's concat() skips NULLs), an example of a
//! dialect function shadowing a built-in.
//!
//! Where to start: replace `run` with a tokenizer and parser for
//! MariaDB that lowers each statement through src/ir/ir.zig, following
//! the contract of dialect.Frontend. Comparisons
//! without a collation are case-insensitive (Hooks.default_collation is
//! NOCASE); DDL should name the collation of each text column (COLLATE
//! NOCASE, or BINARY for a _bin collation) so that indexes agree.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");

pub const frontend: dialect.Frontend = .{ .name = "mariadb", .run = run };

pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return dialect.notImplemented(p, sql, "mariadb");
}

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    // utf8mb4_general_ci and the like: case-insensitive.
    .default_collation = "NOCASE",
};

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
    dfunc.scalar("concat", -1, .{ .deterministic = true }, concatFunc),
};

comptime {
    dfunc.checkTable(&functions);
}

/// The version string of MariaDB's VERSION().
pub const version = "11.8.0-MariaDB-xqlite-" ++ @import("../../sql/func.zig").sqlite_version;

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

/// CONCAT(str, ...): the arguments as text, NULL if any is NULL.
fn concatFunc(ctx: *dfunc.Context, argv: []*dfunc.Mem) void {
    const db = api.contextDbHandle(ctx);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(db.gpa);
    for (argv) |m| {
        if (api.valueType(m) == vi.SQLITE_NULL) return api.resultNull(ctx);
        const z = api.valueText(m) orelse return api.resultErrorNomem(ctx);
        out.appendSlice(db.gpa, z) catch return api.resultErrorNomem(ctx);
    }
    api.resultText(ctx, out.items, .transient);
}
