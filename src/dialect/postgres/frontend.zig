//! The PostgreSQL dialect (Phase 5).
//!
//! The frontend reads one statement (lexer.zig, parser.zig into the
//! syntax tree IR of src/ir/tree.zig, PostgreSQL's semantics resolved)
//! and lowers it with src/ir/lower.zig, DDL after the checks of ddl.zig
//! (the IR renders it as SQLite text with its catalog entries). ANALYZE
//! is passed to SQLite's grammar (with public as main), as are PRAGMA,
//! VACUUM and the other SQLite commands of dialect.runParser(). Errors
//! use PostgreSQL's wording where it is cheap (`syntax error at or near
//! "x"`, `relation "t" does not exist`).
//!
//! The engine side: the function table (version(), the sequence
//! functions of src/catalog/sequence.zig and funcs.zig).
//!
//! What is supported and what is not: docs/postgres.md.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const dialect = @import("../dialect.zig");
const dfunc = @import("../func.zig");
const sequence = @import("../../catalog/sequence.zig");
const nsp = @import("../../catalog/schema.zig");
const api = @import("../../vdbe/api.zig");
const ir = @import("../../ir/ir.zig");
const lower = @import("../../ir/lower.zig");
const parser = @import("parser.zig");
const ddl = @import("ddl.zig");
const funcs = @import("funcs.zig");
const session = @import("session.zig");
const jtype = @import("jtype.zig");
const jfuncs = @import("jfuncs.zig");

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
    // ANALYZE [VERBOSE] [[schema.]name], as written (SQLite's takes the
    // same arguments). VERBOSE does nothing; schema public is main and
    // pg_temp temp.
    const first = ps.toks[0];
    if (first.isKw("analyze")) {
        var i: usize = 1;
        if (ps.toks[i].isKw("verbose")) i += 1;
        var schema: ?[]const u8 = null;
        if (ps.toks[i].kind == .ident and i + 1 < ps.toks.len and ps.toks[i + 1].kind == .dot) {
            if (ps.toks[i].isKw("public")) schema = "main";
            if (ps.toks[i].isKw("pg_temp")) schema = "temp";
            if (schema != null) i += 2;
            // A table of a schema of CREATE SCHEMA: main."s.t".
            if (schema == null and i + 3 == ps.toks.len and (ps.toks[i + 2].kind == .ident or ps.toks[i + 2].kind == .qident)) {
                ps.p = p;
                const n = ps.toks[i + 2];
                const t = ps.qualified(.{ .text = ps.toks[i].text, .pos = ps.toks[i].start }, .{ .text = n.text, .pos = n.start }) catch |err| return parseFailed(p, sql, ps, err);
                if (t.mangled) {
                    const text = try std.fmt.allocPrintSentinel(p.arena, "ANALYZE main.{f}", .{dialect.Quoted('"'){ .z = t.name }}, 0);
                    return ir.stmt.lowerSqliteText(p, text);
                }
            }
        }
        var end = ps.toks[i].start;
        for (ps.toks[i..]) |t| {
            if (t.kind == .eof) break;
            end = t.end;
        }
        const rest = sql[ps.toks[i].start..@max(end, ps.toks[i].start)];
        const text = if (schema) |s|
            try std.fmt.allocPrintSentinel(p.arena, "ANALYZE {s}.{s}", .{ s, rest }, 0)
        else
            try std.fmt.allocPrintSentinel(p.arena, "ANALYZE {s}", .{rest}, 0);
        try ir.stmt.lowerSqliteText(p, text);
        return;
    }
    ps.p = p;
    // CREATE/DROP SCHEMA, SET, RESET, SHOW.
    const done = session.statement(ps) catch |err| switch (err) {
        error.OutOfMemory, error.ParseFailed => |e| return parseFailed(p, sql, ps, e),
        error.Failed => return error.Failed,
    };
    if (done) return;
    const stmt = ps.statement() catch |err| return parseFailed(p, sql, ps, err);
    jtype.statement(ps, stmt) catch |err| return parseFailed(p, sql, ps, err);
    switch (stmt) {
        .create_table, .create_index, .create_view, .create_sequence, .alter_table, .drop => {
            var d: ddl.Ddl = .init(p, sql);
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
    var l: lower.Lowerer = .init(p, sql);
    try l.statement(stmt);
}

/// The error of the parser, left in `p`.
fn parseFailed(p: *int.Parse, sql: [:0]const u8, ps: *const parser.Parser, err: parser.Error) lower.Error {
    switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => {
            // The schema could not be read: its error is in `p`.
            if (ps.err_in_parse) return error.Failed;
            const z: ?[*]const u8 = if (ps.err_pos < sql.len) sql.ptr + ps.err_pos else null;
            ir.stmt.errorMsgAt(p, z, "{s}", .{ps.err_msg});
            return error.Failed;
        },
    }
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
            // PostgreSQL names the relation without its schema.
            if (nsp.split(name)) |s| if (nsp.exists(p.db, s.schema) catch false) {
                name = s.name;
            };
            p.err_msg = try std.fmt.allocPrintSentinel(p.arena, "relation \"{s}\" already exists", .{name}, 0);
            return;
        }
    }
}

pub const hooks: dialect.Hooks = .{
    .functions = &functions,
    .engine_functions = &engine_functions,
    .collations = &.{.{ .name = "xq_pg_jsonb", .cmp = jfuncs.collate }},
};

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
} ++ sequence.functions ++ funcs.functions ++ session.functions ++ jfuncs.functions;

const engine_functions = funcs.engine_functions ++ jfuncs.engine_functions;

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}

/// The version string of PostgreSQL's version().
pub const version = "PostgreSQL 17.0 (xqlite " ++ @import("../../sql/func.zig").sqlite_version ++ ")";

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

test {
    _ = @import("lexer.zig");
    _ = @import("funcs.zig");
    _ = @import("json.zig");
    _ = @import("jsonpath.zig");
    _ = @import("regex.zig");
    _ = @import("state.zig");
    _ = @import("test.zig");
}
