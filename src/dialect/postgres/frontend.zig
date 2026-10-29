//! The PostgreSQL dialect (Phase 5).
//!
//! The frontend reads one statement (lexer.zig, parser.zig into the tree
//! of ast.zig) and lowers it: queries, DML and transaction control into
//! the common IR (lower.zig), DDL as SQLite text with catalog entries
//! (ddl.zig, render.zig). ANALYZE is passed to SQLite's grammar as
//! written, as are PRAGMA, VACUUM and the other SQLite commands of
//! dialect.runParser(). Errors use PostgreSQL's wording where it is cheap
//! (`syntax error at or near "x"`, `relation "t" does not exist`).
//!
//! The engine side: the function table (version(), the sequence
//! functions of src/catalog/sequence.zig and funcs.zig).
//!
//! What is supported and what is not: README.md, "PostgreSQL 방언".

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const sequence = @import("../../catalog/sequence.zig");
const api = @import("../../vdbe/api.zig");
const ir = @import("../../ir/ir.zig");
const parser = @import("parser.zig");
const lower = @import("lower.zig");
const ddl = @import("ddl.zig");
const funcs = @import("funcs.zig");

const RC = int.RC;

pub const frontend: dialect.Frontend = .{ .run = run };

pub fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    var lex_error: parser.LexError = .{};
    var ps = parser.Parser.init(p.arena, sql, 0, &lex_error) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => {
            ir.stmt.errorMsgAt(p, sql.ptr + lex_error.pos, "{s}", .{lex_error.msg});
            p.tail = sql[sql.len..];
            return error.ParseFailed;
        },
    };
    const rest = sql[ps.end..];
    if (ps.isEmpty()) {
        p.tail = rest;
        return;
    }
    compile(p, sql, &ps) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed => {},
    };
    if (p.n_err == 0 and p.rc == RC.OK) ir.stmt.finishCoding(p);
    p.tail = rest;
    // dialect.runParser() fails the statement.
    try translateError(p);
}

fn compile(p: *int.Parse, sql: [:0]const u8, ps: *parser.Parser) lower.Error!void {
    // ANALYZE, as written (PostgreSQL's takes the same arguments).
    const first = ps.toks[0];
    if (first.isKw("analyze")) {
        var last = first;
        for (ps.toks) |t| {
            if (t.kind == .eof) break;
            last = t;
        }
        const text = try p.arena.dupeSentinel(u8, sql[first.start..last.end], 0);
        try ir.stmt.lowerSqliteText(p, text);
        return;
    }
    const stmt = ps.statement() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => {
            const z: ?[*]const u8 = if (ps.err_pos < sql.len) sql.ptr + ps.err_pos else null;
            ir.stmt.errorMsgAt(p, z, "{s}", .{ps.err_msg});
            return error.Failed;
        },
    };
    switch (stmt) {
        .create_table, .create_index, .create_view, .create_sequence, .alter_table, .drop => {
            var d: ddl.Ddl = .{ .p = p, .src = sql };
            return d.statement(stmt);
        },
        .explain => |inner| switch (inner.*) {
            .select, .insert, .update, .delete => {},
            else => {
                ir.stmt.errorMsgAt(p, sql.ptr, "EXPLAIN of this statement is not supported", .{});
                return error.Failed;
            },
        },
        else => {},
    }
    var l: lower.Lowerer = .{ .p = p, .src = sql };
    try l.statement(stmt);
}

/// SQLite's messages for common failures in PostgreSQL's words.
fn translateError(p: *int.Parse) int.Oom!void {
    const m: []const u8 = p.err_msg orelse return;
    const rules = [_]struct { []const u8, []const u8, []const u8 }{
        // prefix, before the name, after it
        .{ "no such table: ", "relation \"", "\" does not exist" },
        .{ "no such column: ", "column \"", "\" does not exist" },
        .{ "no such function: ", "function ", "() does not exist" },
        .{ "no such index: ", "index \"", "\" does not exist" },
        .{ "no such view: ", "view \"", "\" does not exist" },
        .{ "ambiguous column name: ", "column reference \"", "\" is ambiguous" },
        .{ "no such collation sequence: ", "collation \"", "\" for encoding \"UTF8\" does not exist" },
    };
    for (rules) |r| if (std.mem.startsWith(u8, m, r[0])) {
        var name = m[r[0].len..];
        if (std.mem.startsWith(u8, name, "main.")) name = name[5..];
        p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "{s}{s}{s}", .{ r[1], name, r[2] }, 0);
        return;
    };
    // "table t already exists", "index i already exists"
    inline for (.{ "table ", "index ", "view " }) |kind| {
        if (std.mem.startsWith(u8, m, kind) and std.mem.endsWith(u8, m, " already exists")) {
            var name = m[kind.len .. m.len - " already exists".len];
            if (std.mem.startsWith(u8, name, "main.")) name = name[5..];
            if (name.len > 1 and name[0] == '"') name = name[1 .. name.len - 1];
            p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "relation \"{s}\" already exists", .{name}, 0);
            return;
        }
    }
}

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    .engine_functions = &funcs.engine_functions,
};

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
} ++ sequence.functions ++ funcs.functions;

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&funcs.engine_functions);
}

/// The version string of PostgreSQL's version().
pub const version = "PostgreSQL 17.0 (xqlite " ++ @import("../../sql/func.zig").sqlite_version ++ ")";

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

test {
    _ = @import("lexer.zig");
    _ = @import("funcs.zig");
    _ = @import("test.zig");
}
