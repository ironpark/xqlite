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
//! What is supported and what is not: docs/postgres/README.md.

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
const driver = @import("../driver.zig");
const ddl = @import("ddl.zig");
const funcs = @import("funcs.zig");
const session = @import("session.zig");
const jtype = @import("jtype.zig");
const ddltype = @import("ddltype.zig");
const jfuncs = @import("jfuncs.zig");
const catalog_funcs = @import("catalog_funcs.zig");
const datetime = @import("datetime.zig");
const ivinput = @import("ivinput.zig");
const array = @import("array.zig");
const uuid = @import("uuid.zig");
const integer = @import("integer.zig");
const catalog = @import("../../catalog/catalog.zig");
const util = @import("../../sql/util.zig");

const RC = int.RC;

pub const frontend: dialect.Frontend = .{ .run = run };

pub const run = driver.run(parser, compile, translateError);

fn compile(p: *int.Parse, sql: [:0]const u8, ps: *parser.Parser) driver.CompileError!void {
    // ANALYZE [VERBOSE] [[schema.]name], as written (SQLite's takes the
    // same arguments). VERBOSE does nothing; schema public is main and
    // pg_temp temp.
    const toks = ps.c.src.toks;
    const first = toks[0];
    if (first.isKw("analyze")) {
        var i: usize = 1;
        if (toks[i].isKw("verbose")) i += 1;
        var schema: ?[]const u8 = null;
        if (toks[i].kind == .word and i + 1 < toks.len and toks[i + 1].kind == .dot) {
            if (toks[i].isKw("public")) schema = "main";
            if (toks[i].isKw("pg_temp")) schema = "temp";
            if (schema != null) i += 2;
            // A table of a schema of CREATE SCHEMA: main."s.t".
            if (schema == null and i + 3 == toks.len and (toks[i + 2].kind == .word or toks[i + 2].kind == .quoted_ident)) {
                ps.p = p;
                const n = toks[i + 2];
                const t = try ps.qualified(.{ .text = ps.val(toks[i]), .pos = toks[i].start }, .{ .text = ps.val(n), .pos = n.start });
                if (t.mangled) {
                    const text = try std.fmt.allocPrintSentinel(p.arena, "ANALYZE main.{f}", .{dialect.Quoted('"'){ .z = t.name }}, 0);
                    return ir.stmt.lowerSqliteText(p, text);
                }
            }
        }
        var end = toks[i].start;
        for (toks[i..]) |t| {
            if (t.kind == .eof) break;
            end = t.end;
        }
        const rest = sql[toks[i].start..@max(end, toks[i].start)];
        const text = if (schema) |s|
            try std.fmt.allocPrintSentinel(p.arena, "ANALYZE {s}.{s}", .{ s, rest }, 0)
        else
            try std.fmt.allocPrintSentinel(p.arena, "ANALYZE {s}", .{rest}, 0);
        try ir.stmt.lowerSqliteText(p, text);
        return;
    }
    ps.p = p;
    // CREATE/DROP SCHEMA, SET, RESET, SHOW.
    const done = try session.statement(ps);
    if (done) return;
    const stmt = try ps.statement();
    try ps.regOutputs(stmt);
    // The types of the columns of the tables, for the typing of names
    // resolved (sql/typing.zig, overload.zig).
    catalog.readAll(p.db) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {},
    };
    try jtype.statement(ps, stmt);
    try ddltype.statement(ps, stmt);
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

/// The HINT of a function call no function matches.
pub const function_hint = "No function matches the given name and argument types. You might need to add explicit type casts.";

/// PostgreSQL's error of a call of `name` no function matches
/// (ParseFuncOrColumn()): `function f(integer, unknown) does not exist`
/// and its HINT, of the arguments as `args` show them (the type,
/// "a => type" for a named one).
pub fn functionNotExist(a: std.mem.Allocator, name: []const u8, args: []const []const u8) error{OutOfMemory}!util.ErrorFields {
    const sig = try std.mem.join(a, ", ", args);
    return .{ .message = try std.fmt.allocPrint(a, "function {s}({s}) does not exist", .{ name, sig }), .hint = function_hint };
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
        const hint: ?[]const u8 = if (std.mem.eql(u8, r[0], "no such function: ")) function_hint else null;
        return util.rewordError(p, .{ .message = try std.fmt.allocPrint(p.arena, "{s}{s}{s}", .{ r[1], name, r[2] }), .hint = hint });
    };
    // A function of another number of arguments: PostgreSQL finds none.
    const wrong = "wrong number of arguments to function ";
    if (std.mem.startsWith(u8, m, wrong) and std.mem.endsWith(u8, m, "()")) {
        return util.rewordError(p, .{ .message = try std.fmt.allocPrint(p.arena, "function {s} does not exist", .{m[wrong.len..]}), .hint = function_hint });
    }
    // A value for a GENERATED ALWAYS identity column (lower.zig's
    // checkAlways()): PostgreSQL's DETAIL and HINT (generated_always).
    const always = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "cannot insert a non-DEFAULT value into column \"", "\"", "Use OVERRIDING SYSTEM VALUE to override." },
        .{ "column \"", "\" can only be updated to DEFAULT", null },
    };
    for (always) |r| if (std.mem.startsWith(u8, m, r[0]) and std.mem.endsWith(u8, m, r[1]) and m.len >= r[0].len + r[1].len) {
        const col = m[r[0].len .. m.len - r[1].len];
        p.err_state = .of("428C9");
        return util.rewordError(p, .{
            .message = m,
            .detail = try std.fmt.allocPrint(p.arena, "Column \"{s}\" is an identity column defined as GENERATED ALWAYS.", .{col}),
            .hint = r[2],
        });
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
            return util.rewordError(p, .{ .message = try std.fmt.allocPrint(p.arena, "relation \"{s}\" already exists", .{name}) });
        }
    }
}

pub const hooks: dialect.Hooks = .{
    .foreign_keys = true,
    .count_create_as = true,
    .notice_level = session.noticeLevel,
    .constraint = @import("constraints.zig").constraint,
    .arith = .{
        .div_zero = .{ .msg = "division by zero", .state = .of("22012") },
        .int_overflow = .{ .msg = "bigint out of range", .state = .of("22003") },
        .int2 = .{ .min = std.math.minInt(i16), .max = std.math.maxInt(i16), .failure = .{ .msg = "smallint out of range", .state = .of("22003") } },
        .int4 = .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32), .failure = .{ .msg = "integer out of range", .state = .of("22003") } },
    },
    .typing = &@import("typing.zig").rules,
    .functions = &functions,
    .engine_functions = &engine_functions,
    .engine_modules = &@import("pgcatalog.zig").modules,
    .collations = &.{
        .{ .name = "xq_pg_jsonb", .cmp = jfuncs.collate },
        .{ .name = "xq_pg_interval", .cmp = datetime.collateInterval },
        .{ .name = array.collation_text, .cmp = array.collateText },
        .{ .name = array.collation_number, .cmp = array.collateNumber },
    },
    // The names of the type checks (parser.zig's typeCheck()).
    .check_errors = &.{
        .{ .prefix = "smallint out of range", .state = .of("22003") },
        .{ .prefix = "integer out of range", .state = .of("22003") },
        .{ .prefix = "invalid input syntax for type ", .state = .of("22P02") },
        .{ .prefix = "value too long for type ", .state = .of("22001") },
        .{ .prefix = "malformed array literal", .state = .of("22P02") },
    },
};

const functions = [_]int.FuncDef{
    dfunc.scalar("version", 0, .{}, versionFunc),
} ++ sequence.functions ++ funcs.functions ++ session.functions ++ jfuncs.functions ++ catalog_funcs.functions ++ array.functions ++ uuid.functions ++ datetime.functions ++ ivinput.functions ++
    formatting.functions ++ builtins.functions ++ inputinfo.functions ++ dtfuncs.functions ++ regexp.functions;

const engine_functions = funcs.engine_functions ++ integer.engine_functions ++ jfuncs.engine_functions ++ catalog_funcs.engine_functions ++ datetime.engine_functions ++ array.engine_functions ++ uuid.engine_functions ++ ivinput.engine_functions ++
    formatting.engine_functions ++ builtins.engine_functions ++ inputinfo.engine_functions ++ dtfuncs.engine_functions ++ regexp.engine_functions;

// to_char(), gcd(), pg_input_is_valid(), date_trunc() ...
const formatting = @import("formatting.zig");
const builtins = @import("builtins.zig");
const inputinfo = @import("inputinfo.zig");
const dtfuncs = @import("dtfuncs.zig");
const regexp = @import("regexp.zig");

comptime {
    dfunc.checkTable(&functions);
    dfunc.checkTable(&engine_functions);
}

/// The version string of PostgreSQL's version().
pub const version = "PostgreSQL " ++ @import("state.zig").release ++ " (xqlite " ++ @import("../../sql/func/func.zig").sqlite_version ++ ")";

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultText(ctx, version, .static);
}

test {
    _ = @import("lexer.zig");
    _ = @import("funcs.zig");
    _ = @import("json.zig");
    _ = @import("jsonpath.zig");
    _ = @import("regex.zig");
    _ = @import("are.zig");
    _ = @import("regexp.zig");
    _ = @import("datetime.zig");
    _ = @import("operators.zig");
    _ = @import("state.zig");
    _ = @import("test.zig");
    _ = @import("constraints.zig");
    _ = @import("pgcatalog.zig");
    _ = @import("catalog_funcs.zig");
    _ = @import("deparse.zig");
    _ = @import("array.zig");
    _ = @import("uuid.zig");
    _ = @import("integer.zig");
    _ = @import("numformat.zig");
    _ = @import("dtformat.zig");
    _ = @import("builtins.zig");
    _ = @import("dtfuncs.zig");
}
