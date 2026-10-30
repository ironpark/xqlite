//! Schemas and session parameters of the PostgreSQL dialect:
//!
//!  - CREATE SCHEMA [IF NOT EXISTS] name [AUTHORIZATION role],
//!    CREATE SCHEMA AUTHORIZATION role, DROP SCHEMA [IF EXISTS] a [, b]
//!    [CASCADE | RESTRICT]: the registry and mangled objects of
//!    src/catalog/schema.zig (the parser resolves names into them);
//!  - SET [SESSION] name {TO | =} value [, ...] | DEFAULT, SET SCHEMA
//!    'x', SET TIME ZONE x, RESET name | ALL, SHOW name: the parameters
//!    of state.zig, read and written when the statement runs by the
//!    functions set_config() and current_setting(), which SET and SHOW
//!    are rewritten into;
//!  - current_schema(), current_schemas(bool): the first existing schema
//!    of search_path, all of them.
//!
//! search_path decides where an unqualified name is looked up and where
//! DDL creates. Names are resolved when a statement is compiled, so
//! changing search_path expires the prepared statements (they are
//! compiled again when they next run).

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const lower = @import("../../ir/lower.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");

const Parser = parser.Parser;
const Name = @import("../../ir/tree.zig").Name;
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const Error = parser.Error || lower.Error;

/// Compile the statement if it is one of this file's; false if not.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.peek();
    if (t.isKw("create") and ps.isKwAt(1, "schema")) {
        try createSchema(ps);
        return true;
    }
    if (t.isKw("drop") and ps.isKwAt(1, "schema")) {
        try dropSchema(ps);
        return true;
    }
    if (t.isKw("set") or t.isKw("reset")) {
        try set(ps);
        return true;
    }
    if (t.isKw("show")) {
        try show(ps);
        return true;
    }
    return false;
}

// ============================================================== schemas

/// Schemas PostgreSQL always has.
fn isSystemSchema(name: []const u8) bool {
    return eql(name, "public") or eql(name, "pg_catalog") or eql(name, "information_schema") or eql(name, "pg_toast") or eql(name, "pg_temp");
}

/// A role: the only one is current_user's.
fn role(ps: *Parser) parser.Error![]const u8 {
    const t = ps.peek();
    if (t.isAnyKw(&.{ "current_user", "current_role", "session_user" })) {
        _ = ps.advance();
        return state.user;
    }
    const n = try ps.anyName();
    if (!eql(n.text, state.user)) return ps.fail(n.pos, "role \"{s}\" does not exist", .{n.text});
    return n.text;
}

fn createSchema(ps: *Parser) Error!void {
    _ = ps.advance(); // CREATE
    _ = ps.advance(); // SCHEMA
    const if_not_exists = try ps.ifNotExists();
    var name: Name = undefined;
    var owner: []const u8 = state.user;
    if (ps.isKw("authorization")) {
        _ = ps.advance();
        const at = ps.peek().start;
        owner = try role(ps);
        name = .{ .text = owner, .pos = at };
    } else {
        name = try ps.colId();
        if (ps.isKw("authorization")) {
            _ = ps.advance();
            owner = try role(ps);
        }
    }
    if (ps.peek().kind != .eof) {
        if (ps.isKw("create") or ps.isKw("grant")) {
            if (if_not_exists) return ps.fail(ps.peek().start, "CREATE SCHEMA IF NOT EXISTS cannot include schema elements", .{});
            return ps.fail(ps.peek().start, "xqlite: CREATE SCHEMA with schema elements is not supported", .{});
        }
        return ps.syntaxError();
    }
    const n = name.text;
    if (std.mem.startsWith(u8, n, "pg_")) return ps.fail(name.pos, "unacceptable schema name \"{s}\"", .{n});
    if (!nsp.validName(n)) return ps.fail(name.pos, "xqlite: a schema name cannot contain \".\"", .{});
    const p = ps.p.?;
    try ps.readSchema();
    const taken = isSystemSchema(n) or nsp.find(try ps.registered(), n) != null or
        @import("../../sql/build.zig").findDbName(p.db, n) != null;
    if (taken) {
        if (if_not_exists) return emptyStatement(p);
        return ps.fail(name.pos, "schema \"{s}\" already exists", .{n});
    }
    nsp.codeCreate(p, n, owner);
    if (p.n_err > 0) return error.Failed;
}

fn dropSchema(ps: *Parser) Error!void {
    _ = ps.advance(); // DROP
    _ = ps.advance(); // SCHEMA
    const if_exists = try ps.ifExists();
    var names: std.ArrayList(Name) = .empty;
    while (true) {
        try names.append(ps.arena, try ps.colId());
        if (!ps.eat(.comma)) break;
    }
    var cascade = false;
    if (ps.eatKw("cascade")) cascade = true else _ = ps.eatKw("restrict");
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const p = ps.p.?;
    try ps.readSchema();
    const schemas = try ps.registered();
    var drops: std.ArrayList(struct { name: []const u8, objs: []const nsp.Object }) = .empty;
    for (names.items) |n| {
        const s = nsp.find(schemas, n.text) orelse {
            if (eql(n.text, "pg_catalog") or eql(n.text, "information_schema") or eql(n.text, "pg_toast")) {
                return ps.fail(n.pos, "cannot drop schema {s} because it is required by the database system", .{n.text});
            }
            if (eql(n.text, "public")) return ps.fail(n.pos, "xqlite: schema public cannot be dropped", .{});
            if (@import("../../sql/build.zig").findDbName(p.db, n.text) != null) {
                return ps.fail(n.pos, "xqlite: schema \"{s}\" is an attached database (use DETACH)", .{n.text});
            }
            if (if_exists) continue;
            return ps.fail(n.pos, "schema \"{s}\" does not exist", .{n.text});
        };
        const objs = nsp.objects(p.db, ps.arena, s.name) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return ps.fail(n.pos, "{s}", .{@import("../../sql/main.zig").errmsg(p.db)}),
        };
        if (objs.len > 0 and !cascade) {
            if (names.items.len > 1) return ps.fail(n.pos, "cannot drop desired object(s) because other objects depend on them", .{});
            return ps.fail(n.pos, "cannot drop schema {s} because other objects depend on it", .{s.name});
        }
        try drops.append(ps.arena, .{ .name = s.name, .objs = objs });
    }
    if (drops.items.len == 0) return emptyStatement(p);
    for (drops.items) |d| nsp.codeDrop(p, d.name, d.objs) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed, error.AutoVacuum => return error.Failed,
    };
}

/// A statement that does nothing.
fn emptyStatement(p: *int.Parse) Error!void {
    _ = @import("../../sql/build.zig").getVdbe(p) orelse return error.Failed;
}

// =========================================================== parameters

const Param = struct {
    name: []const u8,
    default: []const u8,
    /// A list of names (search_path): each value is an identifier, quoted
    /// as needed.
    list: bool = false,
};

/// The parameters SET and SHOW know; SET of the others is accepted and
/// changes nothing but what SHOW prints.
const params = [_]Param{
    .{ .name = "search_path", .default = state.default_search_path, .list = true },
    .{ .name = "application_name", .default = "" },
    .{ .name = "client_encoding", .default = "UTF8" },
    .{ .name = "client_min_messages", .default = "notice" },
    .{ .name = "datestyle", .default = "ISO, MDY" },
    .{ .name = "intervalstyle", .default = "postgres" },
    .{ .name = "timezone", .default = "UTC" },
    .{ .name = "standard_conforming_strings", .default = "on" },
    .{ .name = "statement_timeout", .default = "0" },
    .{ .name = "lock_timeout", .default = "0" },
    .{ .name = "idle_in_transaction_session_timeout", .default = "0" },
    .{ .name = "extra_float_digits", .default = "1" },
    .{ .name = "bytea_output", .default = "hex" },
    .{ .name = "default_transaction_isolation", .default = "serializable" },
    .{ .name = "transaction_isolation", .default = "serializable" },
};

fn findParam(name: []const u8) ?*const Param {
    for (&params) |*x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x;
    return null;
}

/// PostgreSQL's quote_identifier(): quoted unless a lower-case word that
/// is not a keyword.
fn quoteIdent(out: *std.ArrayList(u8), a: std.mem.Allocator, z: []const u8) !void {
    var safe = z.len > 0 and (std.ascii.isLower(z[0]) or z[0] == '_');
    for (z) |c| safe = safe and (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_');
    if (safe and parser.isReserved(z)) safe = false;
    if (safe) return out.appendSlice(a, z);
    try out.append(a, '"');
    for (z) |c| {
        if (c == '"') try out.append(a, '"');
        try out.append(a, c);
    }
    try out.append(a, '"');
}

/// A PostgreSQL string literal of `z`.
fn literal(out: *std.ArrayList(u8), a: std.mem.Allocator, z: []const u8) !void {
    try out.append(a, '\'');
    for (z) |c| {
        if (c == '\'') try out.append(a, '\'');
        try out.append(a, c);
    }
    try out.append(a, '\'');
}

/// SET ..., RESET ...: a query that calls set_config() and returns no
/// row.
fn set(ps: *Parser) Error!void {
    const a = ps.arena;
    const reset = ps.advance().isKw("reset");
    var name: []const u8 = undefined;
    var value: ?[]const u8 = null;
    if (reset) {
        if (ps.eatKw("all")) {
            if (ps.peek().kind != .eof) return ps.syntaxError();
            return lowerPg(ps, "SELECT 1 WHERE set_config('all', NULL, false) IS NOT NULL");
        }
        name = (try ps.anyName()).text;
        if (eql(name, "time") and ps.eatKw("zone")) name = "timezone";
    } else {
        if (ps.isKw("local")) return ps.fail(ps.peek().start, "xqlite: SET LOCAL is not supported", .{});
        _ = ps.eatKw("session");
        if (ps.isKw("transaction") or (ps.isKw("session") and ps.isKwAt(1, "characteristics"))) {
            // Isolation levels: parsed, nothing to do (SQLite is serializable).
            while (ps.peek().kind != .eof) _ = ps.advance();
            return emptyStatement(ps.p.?);
        }
        if (ps.eatKw("schema")) {
            const t = ps.peek();
            if (t.kind != .string) return ps.syntaxError();
            _ = ps.advance();
            name = "search_path";
            var out: std.ArrayList(u8) = .empty;
            try quoteIdent(&out, a, t.text);
            value = out.items;
        } else {
            name = (try ps.anyName()).text;
            if (eql(name, "time") and ps.eatKw("zone")) {
                name = "timezone";
            } else if (!ps.eatKw("to") and !ps.eatOp("=")) return ps.syntaxError();
            if (ps.eatKw("default")) {} else {
                const p_ = findParam(name);
                var out: std.ArrayList(u8) = .empty;
                var n: usize = 0;
                while (true) : (n += 1) {
                    const t = ps.peek();
                    if (n > 0) try out.appendSlice(a, ", ");
                    switch (t.kind) {
                        .ident, .qident => if (p_ != null and p_.?.list) try quoteIdent(&out, a, t.text) else try out.appendSlice(a, t.text),
                        .string => if (p_ != null and p_.?.list) try quoteIdent(&out, a, t.text) else try out.appendSlice(a, t.text),
                        .integer, .float => try out.appendSlice(a, t.text),
                        .op => if (eql(t.text, "-") and (ps.peekAt(1).kind == .integer or ps.peekAt(1).kind == .float)) {
                            _ = ps.advance();
                            try out.append(a, '-');
                            try out.appendSlice(a, ps.peek().text);
                        } else return ps.syntaxError(),
                        else => return ps.syntaxError(),
                    }
                    _ = ps.advance();
                    if (!ps.eat(.comma)) break;
                }
                if (n > 0 and !(p_ != null and p_.?.list)) return ps.fail(ps.peek().start, "SET {s} takes only one argument", .{name});
                value = out.items;
            }
        }
    }
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const prm = findParam(name) orelse return ps.fail(0, "unrecognized configuration parameter \"{s}\"", .{name});
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "SELECT 1 WHERE set_config(");
    try literal(&q, a, prm.name);
    try q.appendSlice(a, ", ");
    if (value) |v| try literal(&q, a, v) else try q.appendSlice(a, "NULL");
    // set_config() returns the value, never NULL: no row.
    try q.appendSlice(a, ", false) IS NULL");
    try lowerPg(ps, try a.dupeSentinel(u8, q.items, 0));
}

/// SHOW name: the query of current_setting(name), its column named after
/// the parameter.
fn show(ps: *Parser) Error!void {
    const a = ps.arena;
    _ = ps.advance(); // SHOW
    var name = (try ps.anyName()).text;
    if (eql(name, "time") and ps.eatKw("zone")) name = "timezone";
    if (eql(name, "all")) return ps.fail(0, "xqlite: SHOW ALL is not supported", .{});
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const prm = findParam(name) orelse return ps.fail(0, "unrecognized configuration parameter \"{s}\"", .{name});
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "SELECT current_setting(");
    try literal(&q, a, prm.name);
    try q.appendSlice(a, ") AS ");
    try q.appendSlice(a, if (eql(prm.name, "timezone")) "\"TimeZone\"" else if (eql(prm.name, "datestyle")) "\"DateStyle\"" else if (eql(prm.name, "intervalstyle")) "\"IntervalStyle\"" else prm.name);
    try lowerPg(ps, try a.dupeSentinel(u8, q.items, 0));
}

/// Compile PostgreSQL text `text` (a SELECT) as this statement.
fn lowerPg(ps: *Parser, text: [:0]const u8) Error!void {
    var sub = Parser.init(ps.arena, text, 0, null) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => unreachable,
    };
    sub.p = ps.p;
    const stmt = sub.statement() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => return ps.fail(0, "{s}", .{sub.err_msg}),
    };
    var l: lower.Lowerer = .init(ps.p.?, text);
    try l.statement(stmt);
}

// ============================================================ functions

const Context = dfunc.Context;
const Mem = dfunc.Mem;

pub const functions = [_]int.FuncDef{
    dfunc.scalar("set_config", 3, .{ .unsafe = true }, setConfigFunc),
    dfunc.scalar("current_setting", 1, .{}, currentSettingFunc),
    dfunc.scalar("current_setting", 2, .{}, currentSettingFunc),
    dfunc.scalar("current_schema", 0, .{}, currentSchemaFunc),
    dfunc.scalar("current_schemas", 1, .{}, currentSchemasFunc),
};

fn expire(db: *int.Sqlite3) void {
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
}

/// set_config(name, value, is_local): set a parameter (NULL: its
/// default; name 'all' with NULL: every one) and return its value.
fn setConfigFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultError(ctx, "NULL value not allowed for parameter name");
    if (api.valueType(argv[2]) != vi.SQLITE_NULL and api.valueInt64(argv[2]) != 0) {
        return api.resultError(ctx, "xqlite: SET LOCAL is not supported");
    }
    const value: ?[]const u8 = if (api.valueType(argv[1]) == vi.SQLITE_NULL) null else api.valueText(argv[1]) orelse "";
    const st = &db.xq.postgres;
    if (std.ascii.eqlIgnoreCase(name, "all") and value == null) {
        st.deinit(db.gpa);
        expire(db);
        return api.resultNull(ctx);
    }
    const prm = findParam(name) orelse {
        var buf: [200]u8 = undefined;
        return api.resultError(ctx, std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
    };
    st.set(db.gpa, prm.name, value) catch return api.resultErrorNomem(ctx);
    if (prm.list) expire(db);
    const shown = st.get(prm.name) orelse prm.default;
    api.resultText(ctx, shown, .transient);
}

/// current_setting(name [, missing_ok]).
fn currentSettingFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const prm = findParam(name) orelse {
        if (argv.len > 1 and api.valueInt64(argv[1]) != 0) return api.resultNull(ctx);
        var buf: [200]u8 = undefined;
        return api.resultError(ctx, std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
    };
    api.resultText(ctx, db.xq.postgres.get(prm.name) orelse prm.default, .transient);
}

/// The schemas of search_path that exist, in order (in `a`).
fn existingPath(db: *int.Sqlite3, a: std.mem.Allocator) catalog.Error![]const []const u8 {
    const registered = try nsp.list(db, a);
    var out: std.ArrayList([]const u8) = .empty;
    for (try state.splitPath(a, db.xq.postgres.searchPath())) |e| {
        if (eql(e, "public")) {
            try out.append(a, "public");
        } else if (nsp.find(registered, e)) |s| try out.append(a, s.name);
    }
    return out.items;
}

fn currentSchemaFunc(ctx: *Context, _: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const path = existingPath(db, arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
        return api.resultError(ctx, "xqlite: cannot read the schemas");
    };
    if (path.len == 0) return api.resultNull(ctx);
    api.resultText(ctx, path[0], .transient);
}

/// current_schemas(include_implicit): '{pg_catalog,public}' (an array,
/// as text).
fn currentSchemasFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_NULL) return api.resultNull(ctx);
    var arena: std.heap.ArenaAllocator = .init(db.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = existingPath(db, a) catch |err| {
        if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
        return api.resultError(ctx, "xqlite: cannot read the schemas");
    };
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '{') catch return api.resultErrorNomem(ctx);
    var first = true;
    const implicit = api.valueInt64(argv[0]) != 0;
    var has_catalog = false;
    for (path) |e| has_catalog = has_catalog or eql(e, "pg_catalog");
    if (implicit and !has_catalog) {
        out.appendSlice(a, "pg_catalog") catch return api.resultErrorNomem(ctx);
        first = false;
    }
    for (path) |e| {
        if (!first) out.append(a, ',') catch return api.resultErrorNomem(ctx);
        first = false;
        out.appendSlice(a, e) catch return api.resultErrorNomem(ctx);
    }
    out.append(a, '}') catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}
