//! Schemas and session parameters of the PostgreSQL dialect:
//!
//!  - CREATE SCHEMA [IF NOT EXISTS] name [AUTHORIZATION role],
//!    CREATE SCHEMA AUTHORIZATION role, DROP SCHEMA [IF EXISTS] a [, b]
//!    [CASCADE | RESTRICT]: the registry and mangled objects of
//!    src/catalog/schema.zig (the parser resolves names into them);
//!  - SET [SESSION] name {TO | =} value [, ...] | DEFAULT, SET SCHEMA
//!    'x', SET TIME ZONE x, RESET name | ALL, SHOW name | ALL (and SHOW
//!    TRANSACTION ISOLATION LEVEL, SESSION AUTHORIZATION): the parameters
//!    of state.zig, read and written when the statement runs by the
//!    functions set_config() and current_setting(), which SET and SHOW
//!    are rewritten into;
//!  - current_schema(), current_schemas(bool): the first existing schema
//!    of search_path, all of them;
//!  - COMMENT ON TABLE/VIEW/COLUMN: the catalog entry pg_description
//!    reads.
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
    if (t.isKw("comment") and ps.isKwAt(1, "on")) {
        try comment(ps);
        return true;
    }
    return false;
}

// ============================================================ COMMENT ON

/// COMMENT ON {TABLE | VIEW} name IS 'text' | NULL, COMMENT ON COLUMN
/// [schema.]table.column IS ...: an entry of the dialect catalog
/// (pgcatalog.comment_key) that pg_description, obj_description() and
/// col_description() read.
fn comment(ps: *Parser) Error!void {
    _ = ps.advance(); // COMMENT
    _ = ps.advance(); // ON
    const kind = ps.peek();
    const is_column = kind.isKw("column");
    if (!(is_column or kind.isKw("table") or kind.isKw("view"))) {
        return ps.fail(kind.start, "xqlite: COMMENT ON {s} is not supported", .{kind.text});
    }
    _ = ps.advance();
    var names: std.ArrayList(Name) = .empty;
    try names.append(ps.arena, try ps.colId());
    while (ps.eat(.dot)) try names.append(ps.arena, try ps.anyName());
    const n = names.items;
    var col: []const u8 = "";
    var q: parser.QName = undefined;
    if (is_column) {
        if (n.len < 2 or n.len > 3) return ps.syntaxError();
        col = n[n.len - 1].text;
        q = if (n.len == 3) .{ .schema = n[0], .name = n[1] } else .{ .name = n[0] };
    } else {
        if (n.len > 2) return ps.syntaxError();
        q = if (n.len == 2) .{ .schema = n[0], .name = n[1] } else .{ .name = n[0] };
    }
    try ps.expectKw("is");
    var value: ?[]const u8 = null;
    const v = ps.peek();
    if (v.kind == .string) {
        value = v.text;
        _ = ps.advance();
    } else if (!ps.eatKw("null")) return ps.syntaxError();
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const p = ps.p.?;
    try ps.readSchema();
    const r = try ps.lookup(q, .relation);
    const db_name: ?[]const u8 = if (r.q.schema) |sc| sc.text else null;
    const tab = @import("../../sql/build.zig").findTable(p.db, r.q.name.text, db_name) orelse
        return ps.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
    if (is_column) {
        const found = for (tab.cols) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name(), col)) break c.name();
        } else return ps.failState(n[n.len - 1].pos, .of("42703"), "column \"{s}\" of relation \"{s}\" does not exist", .{ col, q.name.text });
        col = found;
    }
    if (value) |z| if (z.len == 0) {
        value = null;
    };
    catalog.codeSet(p, catalog.schemaName(p.db, tab), tab.name, col, @import("pgcatalog.zig").comment_key, value);
    if (p.n_err > 0) return error.Failed;
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
    if (!eql(n.text, state.user)) return ps.failState(n.pos, .of("42704"), "role \"{s}\" does not exist", .{n.text});
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
            if (if_not_exists) return ps.failState(ps.peek().start, .of("0A000"), "CREATE SCHEMA IF NOT EXISTS cannot include schema elements", .{});
            return ps.fail(ps.peek().start, "xqlite: CREATE SCHEMA with schema elements is not supported", .{});
        }
        return ps.syntaxError();
    }
    const n = name.text;
    if (std.mem.startsWith(u8, n, "pg_")) return ps.failState(name.pos, .of("42939"), "unacceptable schema name \"{s}\"", .{n});
    if (!nsp.validName(n)) return ps.fail(name.pos, "xqlite: a schema name cannot contain \".\"", .{});
    const p = ps.p.?;
    try ps.readSchema();
    const taken = isSystemSchema(n) or nsp.find(try ps.registered(), n) != null or
        @import("../../sql/build.zig").findDbName(p.db, n) != null;
    if (taken) {
        if (if_not_exists) return emptyStatement(p);
        return ps.failState(name.pos, .of("42P06"), "schema \"{s}\" already exists", .{n});
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
                return ps.failState(n.pos, .of("2BP01"), "cannot drop schema {s} because it is required by the database system", .{n.text});
            }
            if (eql(n.text, "public")) return ps.fail(n.pos, "xqlite: schema public cannot be dropped", .{});
            if (@import("../../sql/build.zig").findDbName(p.db, n.text) != null) {
                return ps.fail(n.pos, "xqlite: schema \"{s}\" is an attached database (use DETACH)", .{n.text});
            }
            if (if_exists) continue;
            return ps.failState(n.pos, .of("3F000"), "schema \"{s}\" does not exist", .{n.text});
        };
        const objs = nsp.objects(p.db, ps.arena, s.name) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return ps.failFrom(n.pos, p.db),
        };
        if (objs.len > 0 and !cascade) {
            if (names.items.len > 1) return ps.failState(n.pos, .of("2BP01"), "cannot drop desired object(s) because other objects depend on them", .{});
            return ps.failState(n.pos, .of("2BP01"), "cannot drop schema {s} because other objects depend on it", .{s.name});
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

pub const Param = struct {
    name: []const u8,
    default: []const u8,
    /// A list of names (search_path): each value is an identifier, quoted
    /// as needed.
    list: bool = false,
    /// SET fails ("cannot be changed"): fixed when the server starts.
    read_only: bool = false,
    /// What pg_settings says of it.
    vartype: []const u8 = "string",
    unit: ?[]const u8 = null,
    category: []const u8 = "Client Connection Defaults / Locale and Formatting",
    desc: []const u8 = "",
    /// The name as PostgreSQL spells it (SHOW's column, pg_settings).
    display: ?[]const u8 = null,
    /// Not in pg_settings (xqlite's own).
    hidden: bool = false,

    pub fn shown(p: *const Param) []const u8 {
        return p.display orelse p.name;
    }

    pub fn context(p: *const Param) []const u8 {
        return if (p.read_only) "internal" else "user";
    }
};

const preset = "Preset Options";
const stmt_defaults = "Client Connection Defaults / Statement Behavior";
const compat = "Version and Platform Compatibility / Previous PostgreSQL Versions";

/// The parameters SET and SHOW know (the ones drivers set or read when
/// they connect, and the read-only ones the server reports); SET of the
/// others is accepted and changes nothing but what SHOW prints.
pub const params = [_]Param{
    .{ .name = "search_path", .default = state.default_search_path, .list = true, .category = stmt_defaults, .desc = "Sets the schema search order for names that are not schema-qualified." },
    .{ .name = "application_name", .default = "", .category = "Reporting and Logging / What to Log", .desc = "Sets the application name to be reported in statistics and logs." },
    .{ .name = "client_encoding", .default = "UTF8", .desc = "Sets the client's character set encoding." },
    .{ .name = "client_min_messages", .default = "notice", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the message levels that are sent to the client." },
    .{ .name = "datestyle", .default = "ISO, MDY", .display = "DateStyle", .desc = "Sets the display format for date and time values." },
    .{ .name = "intervalstyle", .default = "postgres", .display = "IntervalStyle", .vartype = "enum", .desc = "Sets the display format for interval values." },
    .{ .name = "timezone", .default = "UTC", .display = "TimeZone", .desc = "Sets the time zone for displaying and interpreting time stamps." },
    .{ .name = "timezone_abbreviations", .default = "Default", .desc = "Selects a file of time zone abbreviations." },
    .{ .name = "extra_float_digits", .default = "1", .vartype = "integer", .desc = "Sets the number of digits displayed for floating-point values." },
    .{ .name = "lc_messages", .default = "C", .desc = "Sets the language in which messages are displayed." },
    .{ .name = "lc_monetary", .default = "C", .desc = "Sets the locale for formatting monetary amounts." },
    .{ .name = "lc_numeric", .default = "C", .desc = "Sets the locale for formatting numbers." },
    .{ .name = "lc_time", .default = "C", .desc = "Sets the locale for formatting date and time values." },
    .{ .name = "bytea_output", .default = "hex", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the output format for bytea." },
    .{ .name = "xmloption", .default = "content", .vartype = "enum", .category = stmt_defaults, .desc = "Sets whether XML data in implicit parsing and serialization operations is to be considered as documents or content fragments." },
    .{ .name = "statement_timeout", .default = "0", .vartype = "integer", .unit = "ms", .category = stmt_defaults, .desc = "Sets the maximum allowed duration of any statement." },
    .{ .name = "lock_timeout", .default = "0", .vartype = "integer", .unit = "ms", .category = stmt_defaults, .desc = "Sets the maximum allowed duration of any wait for a lock." },
    .{ .name = "idle_in_transaction_session_timeout", .default = "0", .vartype = "integer", .unit = "ms", .category = stmt_defaults, .desc = "Sets the maximum allowed idle time between queries, when in a transaction." },
    .{ .name = "idle_session_timeout", .default = "0", .vartype = "integer", .unit = "ms", .category = stmt_defaults, .desc = "Sets the maximum allowed idle time between queries, when not in a transaction." },
    .{ .name = "default_transaction_isolation", .default = "read committed", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the transaction isolation level of each new transaction." },
    .{ .name = "transaction_isolation", .default = "read committed", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the current transaction's isolation level." },
    .{ .name = "default_transaction_read_only", .default = "off", .vartype = "bool", .category = stmt_defaults, .desc = "Sets the default read-only status of new transactions." },
    .{ .name = "transaction_read_only", .default = "off", .vartype = "bool", .category = stmt_defaults, .desc = "Sets the current transaction's read-only status." },
    .{ .name = "default_transaction_deferrable", .default = "off", .vartype = "bool", .category = stmt_defaults, .desc = "Sets the default deferrable status of new transactions." },
    .{ .name = "transaction_deferrable", .default = "off", .vartype = "bool", .category = stmt_defaults, .desc = "Whether to defer a read-only serializable transaction until it can be executed with no possible serialization failures." },
    .{ .name = "check_function_bodies", .default = "on", .vartype = "bool", .category = stmt_defaults, .desc = "Check routine bodies during CREATE FUNCTION and CREATE PROCEDURE." },
    .{ .name = "row_security", .default = "on", .vartype = "bool", .category = stmt_defaults, .desc = "Enable row security." },
    .{ .name = "default_tablespace", .default = "", .category = stmt_defaults, .desc = "Sets the default tablespace to create tables and indexes in." },
    .{ .name = "temp_tablespaces", .default = "", .category = stmt_defaults, .desc = "Sets the tablespace(s) to use for temporary tables and sort files." },
    .{ .name = "session_replication_role", .default = "origin", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the session's behavior for triggers and rewrite rules." },
    .{ .name = "standard_conforming_strings", .default = "on", .vartype = "bool", .category = compat, .desc = "Causes '...' strings to treat backslashes literally." },
    .{ .name = "escape_string_warning", .default = "on", .vartype = "bool", .category = compat, .desc = "Warn about backslash escapes in ordinary string literals." },
    .{ .name = "array_nulls", .default = "on", .vartype = "bool", .category = compat, .desc = "Enable input of NULL elements in arrays." },
    .{ .name = "backslash_quote", .default = "safe_encoding", .vartype = "enum", .category = compat, .desc = "Sets whether \"\\'\" is allowed in string literals." },
    .{ .name = "quote_all_identifiers", .default = "off", .vartype = "bool", .category = compat, .desc = "When generating SQL fragments, quote all identifiers." },
    .{ .name = "synchronous_commit", .default = "on", .vartype = "enum", .category = "Write-Ahead Log / Settings", .desc = "Sets the current transaction's synchronization level." },
    .{ .name = "work_mem", .default = "4MB", .vartype = "integer", .unit = "kB", .category = "Resource Usage / Memory", .desc = "Sets the maximum memory to be used for query workspaces." },
    .{ .name = "maintenance_work_mem", .default = "64MB", .vartype = "integer", .unit = "kB", .category = "Resource Usage / Memory", .desc = "Sets the maximum memory to be used for maintenance operations." },
    .{ .name = "jit", .default = "off", .vartype = "bool", .category = "Query Tuning / Other Planner Options", .desc = "Allow JIT compilation." },
    .{ .name = "session_authorization", .default = state.user, .category = preset, .desc = "Sets the session user name." },
    .{ .name = "role", .default = "none", .category = preset, .desc = "Sets the current role." },
    // current_database(): the database name the client connected with
    // (the wire server sets it), else postgres.
    .{ .name = "xqlite.database", .default = "postgres", .hidden = true, .desc = "The name current_database() returns." },
    // Fixed (PostgreSQL's preset options and others a client cannot set).
    .{ .name = "server_version", .default = state.server_version, .read_only = true, .category = preset, .desc = "Shows the server version." },
    .{ .name = "server_version_num", .default = state.server_version_num, .read_only = true, .vartype = "integer", .category = preset, .desc = "Shows the server version as an integer." },
    .{ .name = "server_encoding", .default = "UTF8", .read_only = true, .category = preset, .desc = "Shows the server (database) character set encoding." },
    .{ .name = "integer_datetimes", .default = "on", .read_only = true, .vartype = "bool", .category = preset, .desc = "Shows whether datetimes are integer based." },
    .{ .name = "is_superuser", .default = "on", .read_only = true, .vartype = "bool", .category = preset, .desc = "Shows whether the current user is a superuser." },
    .{ .name = "in_hot_standby", .default = "off", .read_only = true, .vartype = "bool", .category = preset, .desc = "Shows whether hot standby is currently active." },
    .{ .name = "max_identifier_length", .default = "63", .read_only = true, .vartype = "integer", .category = preset, .desc = "Shows the maximum identifier length." },
    .{ .name = "max_index_keys", .default = "32", .read_only = true, .vartype = "integer", .category = preset, .desc = "Shows the maximum number of index keys." },
    .{ .name = "max_function_args", .default = "100", .read_only = true, .vartype = "integer", .category = preset, .desc = "Shows the maximum number of function arguments." },
    .{ .name = "block_size", .default = "8192", .read_only = true, .vartype = "integer", .category = preset, .desc = "Shows the size of a disk block." },
    .{ .name = "lc_collate", .default = "C", .read_only = true, .category = preset, .desc = "Shows the collation order locale." },
    .{ .name = "lc_ctype", .default = "C", .read_only = true, .category = preset, .desc = "Shows the character classification and case conversion locale." },
    .{ .name = "data_checksums", .default = "off", .read_only = true, .vartype = "bool", .category = preset, .desc = "Shows whether data checksums are turned on for this cluster." },
    .{ .name = "max_connections", .default = "100", .read_only = true, .vartype = "integer", .category = "Connections and Authentication / Connection Settings", .desc = "Sets the maximum number of concurrent connections." },
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
            if (eql(name, "timezone") and ps.isKw("interval") and ps.peekAt(1).kind == .string) {
                // SET TIME ZONE INTERVAL '+00:00' HOUR TO MINUTE: the offset.
                _ = ps.advance();
                value = ps.advance().text;
                while (ps.peek().kind == .ident) _ = ps.advance();
            } else if (eql(name, "timezone") and ps.eatKw("local")) {} else if (ps.eatKw("default")) {} else {
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
                if (n > 0 and !(p_ != null and p_.?.list)) return ps.failState(ps.peek().start, .of("22023"), "SET {s} takes only one argument", .{name});
                value = out.items;
            }
        }
    }
    if (ps.peek().kind != .eof) return ps.syntaxError();
    const prm = findParam(name) orelse return ps.failState(0, .of("42704"), "unrecognized configuration parameter \"{s}\"", .{name});
    if (prm.read_only) return ps.failState(0, .of("55P02"), "parameter \"{s}\" cannot be changed", .{prm.name});
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
/// the parameter; SHOW ALL: pg_settings' names, values and descriptions.
fn show(ps: *Parser) Error!void {
    const a = ps.arena;
    _ = ps.advance(); // SHOW
    var name = (try ps.anyName()).text;
    if (eql(name, "time") and ps.eatKw("zone")) name = "timezone";
    if (eql(name, "transaction") and ps.eatKw("isolation")) {
        try ps.expectKw("level");
        name = "transaction_isolation";
    }
    if (eql(name, "session") and ps.eatKw("authorization")) name = "session_authorization";
    if (ps.peek().kind != .eof) return ps.syntaxError();
    if (eql(name, "all")) return lowerPg(ps, "SELECT name, setting, short_desc AS description FROM pg_catalog.pg_settings ORDER BY 1");
    const prm = findParam(name) orelse return ps.failState(0, .of("42704"), "unrecognized configuration parameter \"{s}\"", .{name});
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "SELECT current_setting(");
    try literal(&q, a, prm.name);
    try q.appendSlice(a, ") AS ");
    try quoteIdent(&q, a, prm.shown());
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
        error.ParseFailed => return ps.failState(0, sub.err_state, "{s}", .{sub.err_msg}),
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
    dfunc.scalar("xq_pg_startup_setting", 2, .{ .unsafe = true, .direct_only = true }, startupSettingFunc),
};

/// xq_pg_startup_setting(name, value): a setting of the client's startup
/// packet (the wire server's), the value RESET goes back to.
fn startupSettingFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const value = api.valueText(argv[1]) orelse "";
    const prm = findParam(name) orelse {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
    };
    db.xq.postgres.setReset(db.gpa, prm.name, value) catch return api.resultErrorNomem(ctx);
    if (prm.list) expire(db);
    api.resultText(ctx, value, .transient);
}

fn expire(db: *int.Sqlite3) void {
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
}

/// set_config(name, value, is_local): set a parameter (NULL: its
/// default; name 'all' with NULL: every one) and return its value.
fn setConfigFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultErrorState(ctx, .of("22004"), "NULL value not allowed for parameter name");
    if (api.valueType(argv[2]) != vi.SQLITE_NULL and api.valueInt64(argv[2]) != 0) {
        return api.resultErrorState(ctx, .of("0A000"), "xqlite: SET LOCAL is not supported");
    }
    const value: ?[]const u8 = if (api.valueType(argv[1]) == vi.SQLITE_NULL) null else api.valueText(argv[1]) orelse "";
    const st = &db.xq.postgres;
    if (std.ascii.eqlIgnoreCase(name, "all") and value == null) {
        st.resetParams(db.gpa);
        expire(db);
        return api.resultNull(ctx);
    }
    const prm = findParam(name) orelse {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
    };
    if (prm.read_only) {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("55P02"), std.fmt.bufPrint(&buf, "parameter \"{s}\" cannot be changed", .{prm.name}) catch "parameter cannot be changed");
    }
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
        return api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
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
