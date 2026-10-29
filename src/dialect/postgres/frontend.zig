//! The PostgreSQL dialect (Phase 5).
//!
//! The parser is not written yet: `run` only accepts blank text. What is
//! here already is the engine side: the function table (version()).
//!
//! Where to start: replace `run` with a tokenizer and parser for
//! PostgreSQL that lowers each statement through src/ir/ir.zig, following
//! the contract of dialect.Frontend (one statement, p.tail, errors in the
//! Parse, ir.stmt.finishCoding()). DDL goes through
//! ir.stmt.lowerSqliteText() with SQLite text (types mapped with
//! ir.ddl.strictStorageType() and STRICT). Identifiers are folded to
//! lower case by the frontend.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");

pub const frontend: dialect.Frontend = .{ .name = "postgres", .run = run };

pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    return dialect.notImplemented(p, sql, "postgres");
}

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
};

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
};

comptime {
    dfunc.checkTable(&functions);
}

/// The version string of PostgreSQL's version().
pub const version = "PostgreSQL 17.0 (xqlite " ++ @import("../../sql/func.zig").sqlite_version ++ ")";

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}
