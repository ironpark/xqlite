//! Users (schemas) and the session of the Oracle dialect:
//!
//!  - CREATE USER [IF NOT EXISTS] u IDENTIFIED ... [options]: registers
//!    schema U (catalog/schema.zig); the password and the options
//!    (tablespaces, quotas, profile, account state) are ignored;
//!  - DROP USER [IF EXISTS] u [CASCADE]: the schema, with its objects
//!    when CASCADE is given (else ORA-01922 if it has any);
//!  - ALTER USER u ...: checks that the user exists, nothing else;
//!  - ALTER SESSION SET CURRENT_SCHEMA = u: the schema unqualified names
//!    resolve in (state.zig), set when the statement runs by the
//!    dialect function set_current_schema(), which expires the prepared
//!    statements (names are resolved when a statement is compiled); the
//!    other ALTER SESSION statements are accepted and ignored;
//!  - SYS_CONTEXT('USERENV', p): CURRENT_SCHEMA, CURRENT_USER,
//!    SESSION_USER ...
//!
//! A user is a schema: its objects are the main objects named "U.T"
//! (parser.zig resolves names into them). The connected user is MAIN
//! (state.user), whose schema is main itself.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const tree = @import("../../ir/tree.zig");
const lower = @import("../../ir/lower.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");

const Parser = parser.Parser;
const Name = tree.Name;

pub const Error = parser.Error || lower.Error;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Compile the statement if it is one of this file's; false if not.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.peek();
    if (t.isKw("create") and ps.isKwAt(1, "user")) {
        try createUser(ps);
        return true;
    }
    if (t.isKw("drop") and ps.isKwAt(1, "user")) {
        try dropUser(ps);
        return true;
    }
    if (t.isKw("alter") and ps.isKwAt(1, "user")) {
        try alterUser(ps);
        return true;
    }
    if (t.isKw("alter") and ps.isKwAt(1, "session") and ps.isKwAt(2, "set")) {
        return alterSession(ps);
    }
    return false;
}

/// Users Oracle always has (and the roles a user name may not take).
fn isSystemUser(name: []const u8) bool {
    const names = [_][]const u8{ state.user, "SYS", "SYSTEM", "PUBLIC", "DBA", "CONNECT", "RESOURCE" };
    for (names) |n| if (eq(n, name)) return true;
    return false;
}

/// A statement that does nothing.
fn emptyStatement(p: *int.Parse) Error!void {
    _ = build.getVdbe(p) orelse return error.Failed;
}

fn userNotFound(ps: *Parser, n: Name) parser.Error {
    return ps.fail(n.pos, "ORA-01918: user '{s}' does not exist", .{n.text});
}

fn createUser(ps: *Parser) Error!void {
    _ = ps.advance(); // CREATE
    _ = ps.advance(); // USER
    const if_not_exists = try ps.ifNotExists();
    const name = try ps.colId();
    // IDENTIFIED BY password | EXTERNALLY | GLOBALLY ..., NO
    // AUTHENTICATION, DEFAULT TABLESPACE, QUOTA ...: ignored.
    while (ps.peek().kind != .eof) _ = ps.advance();
    const n = name.text;
    if (!nsp.validName(n)) return ps.fail(name.pos, "xqlite: a user name cannot contain \".\"", .{});
    const p = ps.p.?;
    try ps.readSchema();
    const taken = isSystemUser(n) or nsp.find(try ps.registered(), n) != null or build.findDbName(p.db, n) != null;
    if (taken) {
        if (if_not_exists) return emptyStatement(p);
        return ps.fail(name.pos, "ORA-01920: user name '{s}' conflicts with another user or role name", .{n});
    }
    nsp.codeCreate(p, n, state.user);
    if (p.n_err > 0) return error.Failed;
}

fn dropUser(ps: *Parser) Error!void {
    _ = ps.advance(); // DROP
    _ = ps.advance(); // USER
    const if_exists = try ps.ifExists();
    const name = try ps.colId();
    const cascade = ps.eatKw("cascade");
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const p = ps.p.?;
    try ps.readSchema();
    const s = nsp.find(try ps.registered(), name.text) orelse {
        if (eq(name.text, state.user)) return ps.fail(name.pos, "ORA-01940: cannot drop a user that is currently connected", .{});
        if (isSystemUser(name.text)) return ps.fail(name.pos, "ORA-01031: insufficient privileges", .{});
        if (if_exists) return emptyStatement(p);
        return userNotFound(ps, name);
    };
    const objs = nsp.objects(p.db, ps.arena, s.name) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return ps.fail(name.pos, "{s}", .{@import("../../sql/main.zig").errmsg(p.db)}),
    };
    // The user's indexes on other users' tables (those on its own tables
    // go with them).
    const prefix = try nsp.mangle(ps.arena, s.name, "");
    var indexes: std.ArrayList([]const u8) = .empty;
    var it = p.db.dbs.items[0].schema.idx_hash.valueIterator();
    while (it.next()) |idx| {
        const ix = idx.*;
        if (!std.ascii.startsWithIgnoreCase(ix.name, prefix)) continue;
        if (std.ascii.startsWithIgnoreCase(ix.table.name, prefix)) continue;
        try indexes.append(ps.arena, ix.name);
    }
    if ((objs.len > 0 or indexes.items.len > 0) and !cascade) {
        return ps.fail(name.pos, "ORA-01922: CASCADE must be specified to drop '{s}'", .{s.name});
    }
    var l: lower.Lowerer = .init(p, "");
    for (indexes.items) |x| {
        const d: tree.Drop = .{ .kind = .index, .name = .{ .schema = .{ .text = catalog.main_schema }, .name = .{ .text = x } } };
        try l.drop(&d);
    }
    nsp.codeDrop(p, s.name, objs) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed, error.AutoVacuum => return error.Failed,
    };
}

fn alterUser(ps: *Parser) Error!void {
    _ = ps.advance(); // ALTER
    _ = ps.advance(); // USER
    const name = try ps.colId();
    while (ps.peek().kind != .eof) _ = ps.advance();
    const p = ps.p.?;
    try ps.readSchema();
    if (!eq(name.text, state.user) and !isSystemUser(name.text) and nsp.find(try ps.registered(), name.text) == null) {
        return userNotFound(ps, name);
    }
    return emptyStatement(p);
}

/// ALTER SESSION SET p = v ...: CURRENT_SCHEMA = u is a query that calls
/// set_current_schema('U') and returns no row; the others are ignored.
/// False when there is no CURRENT_SCHEMA (stmt.zig takes it).
fn alterSession(ps: *Parser) Error!bool {
    var k: usize = 3;
    var schema: ?Name = null;
    while (ps.peekAt(k).kind != .eof) : (k += 1) {
        const t = ps.peekAt(k);
        if (t.kind == .ident and eq(t.text, "CURRENT_SCHEMA") and ps.peekAt(k + 1).isOp("=")) {
            const v = ps.peekAt(k + 2);
            if (v.kind != .ident and v.kind != .qident) {
                ps.i += k + 2;
                return ps.missing("ORA-02248: invalid option for ALTER SESSION");
            }
            schema = .{ .text = v.text, .pos = v.start };
        }
    }
    const s = schema orelse return false;
    while (ps.peek().kind != .eof) _ = ps.advance();
    const pos = s.pos;
    // SELECT 1 WHERE set_current_schema('U') IS NULL (it never is).
    const call = try ps.call(pos, "set_current_schema", .oracle, &.{try ps.stringAt(pos, s.text)});
    const where = try ps.expr(pos, .{ .is_null = .{ .e = call, .not = false } });
    const cols = try ps.arena.alloc(tree.ResultCol, 1);
    cols[0] = .{ .expr = .{ .e = try ps.expr(pos, .{ .integer = "1" }) } };
    const core = try ps.new(tree.Core, .{ .cols = cols, .where = where, .pos = pos });
    const sel = try ps.new(tree.Select, .{ .body = try ps.new(tree.Body, .{ .core = core }), .pos = pos });
    var l: lower.Lowerer = .init(ps.p.?, ps.src);
    try l.statement(.{ .select = sel });
    return true;
}

// ============================================================ functions

const Context = dfunc.Context;
const Mem = dfunc.Mem;

pub const functions = [_]int.FuncDef{
    dfunc.scalar("set_current_schema", 1, .{ .unsafe = true }, setCurrentSchemaFunc),
    dfunc.scalar("sys_context", 2, .{}, sysContextFunc),
    dfunc.scalar("sys_context", 3, .{}, sysContextFunc),
};

/// set_current_schema(name): make user `name` (MAIN or a registered
/// one) the current schema, and expire the prepared statements; returns
/// the name.
fn setCurrentSchemaFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultError(ctx, "ORA-01435: user does not exist");
    const st = &db.xq.oracle;
    if (eq(name, state.user)) {
        st.setCurrentSchema(db.gpa, null) catch return api.resultErrorNomem(ctx);
    } else {
        var arena: std.heap.ArenaAllocator = .init(db.gpa);
        defer arena.deinit();
        const schemas = nsp.list(db, arena.allocator()) catch |err| {
            if (err == error.OutOfMemory) return api.resultErrorNomem(ctx);
            return api.resultError(ctx, "xqlite: cannot read the users");
        };
        const s = nsp.find(schemas, name) orelse return api.resultError(ctx, "ORA-01435: user does not exist");
        st.setCurrentSchema(db.gpa, s.name) catch return api.resultErrorNomem(ctx);
    }
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
    api.resultText(ctx, st.currentSchema(), .transient);
}

/// SYS_CONTEXT(namespace, parameter [, length]): of namespace USERENV
/// the current schema and the user; NULL for other namespaces (no
/// application context is set).
fn sysContextFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    if (api.valueType(argv[0]) == vi.SQLITE_NULL or api.valueType(argv[1]) == vi.SQLITE_NULL) return api.resultNull(ctx);
    const ns = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const param = api.valueText(argv[1]) orelse return api.resultNull(ctx);
    if (!eq(ns, "USERENV")) return api.resultNull(ctx);
    const user_params = [_][]const u8{ "CURRENT_USER", "SESSION_USER", "AUTHENTICATED_IDENTITY", "CURRENT_SCHEMA", "PROXY_USER" };
    for (user_params) |u| if (eq(param, u)) {
        if (eq(u, "PROXY_USER")) return api.resultNull(ctx);
        const v = if (eq(u, "CURRENT_SCHEMA")) db.xq.oracle.currentSchema() else state.user;
        return api.resultText(ctx, v, .transient);
    };
    if (eq(param, "DB_NAME") or eq(param, "CON_NAME") or eq(param, "INSTANCE_NAME")) return api.resultText(ctx, "XQLITE", .static);
    if (eq(param, "LANG")) return api.resultText(ctx, "US", .static);
    if (eq(param, "LANGUAGE")) return api.resultText(ctx, "AMERICAN_AMERICA.AL32UTF8", .static);
    api.resultError(ctx, "ORA-02003: invalid USERENV parameter");
}
