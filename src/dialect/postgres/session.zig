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
const ddl = @import("ddl.zig");
const ir = @import("../../ir/ir.zig");
const lower = @import("../../ir/lower.zig");
const catalog = @import("../../catalog/catalog.zig");
const nsp = catalog.schemas;
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const parser = @import("parser.zig");
const state = @import("state.zig");
const main_mod = @import("../../sql/main.zig");

const Parser = parser.Parser;
const Name = @import("../../ir/tree.zig").Name;
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const Error = parser.Error || lower.Error;

/// Compile the statement if it is one of this file's; false if not.
pub fn statement(ps: *Parser) Error!bool {
    const t = ps.c.peek();
    if (try @import("enums.zig").statement(ps)) return true;
    if (t.isKw("create") and ps.c.isKwAt(1, "schema")) {
        try createSchema(ps);
        return true;
    }
    if (t.isKw("drop") and ps.c.isKwAt(1, "schema")) {
        try dropSchema(ps);
        return true;
    }
    if (t.isKw("set") or t.isKw("reset")) {
        try set(ps);
        return true;
    }
    if (t.isKw("drop") and ps.c.isKwAt(1, "extension")) {
        try dropExtension(ps);
        return true;
    }
    if (t.isKw("show")) {
        try show(ps);
        return true;
    }
    if (t.isKw("comment") and ps.c.isKwAt(1, "on")) {
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
    ps.c.skip(); // COMMENT
    ps.c.skip(); // ON
    const kind = ps.c.peek();
    const is_column = kind.isKw("column");
    if (!(is_column or kind.isKw("table") or kind.isKw("view"))) {
        return ps.c.fail(kind.start, "xqlite: COMMENT ON {s} is not supported", .{ps.val(kind)});
    }
    ps.c.skip();
    var names: std.ArrayList(Name) = .empty;
    try names.append(ps.arena, try ps.colId());
    while (ps.c.eat(.dot)) try names.append(ps.arena, try ps.anyName());
    const n = names.items;
    var col: []const u8 = "";
    var q: parser.QName = undefined;
    if (is_column) {
        if (n.len < 2 or n.len > 3) return ps.c.syntaxError();
        col = n[n.len - 1].text;
        q = if (n.len == 3) .{ .schema = n[0], .name = n[1] } else .{ .name = n[0] };
    } else {
        if (n.len > 2) return ps.c.syntaxError();
        q = if (n.len == 2) .{ .schema = n[0], .name = n[1] } else .{ .name = n[0] };
    }
    try ps.c.expectKw("is");
    var value: ?[]const u8 = null;
    const v = ps.c.peek();
    if (v.kind == .string) {
        value = ps.val(v);
        ps.c.skip();
    } else if (!ps.c.eatKw("null")) return ps.c.syntaxError();
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    const p = ps.p.?;
    try ps.readSchema();
    const r = try ps.lookup(q, .relation);
    const db_name: ?[]const u8 = if (r.q.schema) |sc| sc.text else null;
    const tab = @import("../../sql/build.zig").findTable(p.db, r.q.name.text, db_name) orelse
        return ps.c.failState(q.name.pos, .of("42P01"), "relation \"{s}\" does not exist", .{q.name.text});
    if (is_column) {
        const found = for (tab.cols) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name(), col)) break c.name();
        } else return ps.c.failState(n[n.len - 1].pos, .of("42703"), "column \"{s}\" of relation \"{s}\" does not exist", .{ col, q.name.text });
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
    const t = ps.c.peek();
    if (t.isAnyKw(&.{ "current_user", "current_role", "session_user" })) {
        ps.c.skip();
        return state.user;
    }
    const n = try ps.anyName();
    if (!eql(n.text, state.user)) return ps.c.failState(n.pos, .of("42704"), "role \"{s}\" does not exist", .{n.text});
    return n.text;
}

fn createSchema(ps: *Parser) Error!void {
    ps.c.skip(); // CREATE
    ps.c.skip(); // SCHEMA
    const if_not_exists = try ps.c.ifNotExists();
    var name: Name = undefined;
    var owner: []const u8 = state.user;
    if (ps.c.isKw("authorization")) {
        ps.c.skip();
        const at = ps.c.peek().start;
        owner = try role(ps);
        name = .{ .text = owner, .pos = at };
    } else {
        name = try ps.colId();
        if (ps.c.isKw("authorization")) {
            ps.c.skip();
            owner = try role(ps);
        }
    }
    if (ps.c.peek().kind != .eof) {
        if (ps.c.isKw("create") or ps.c.isKw("grant")) {
            if (if_not_exists) return ps.c.failState(ps.c.peek().start, .of("0A000"), "CREATE SCHEMA IF NOT EXISTS cannot include schema elements", .{});
            return ps.c.fail(ps.c.peek().start, "xqlite: CREATE SCHEMA with schema elements is not supported", .{});
        }
        return ps.c.syntaxError();
    }
    const n = name.text;
    if (std.mem.startsWith(u8, n, "pg_")) return ps.failFields(name.pos, .of("42939"), .{ .message = try std.fmt.allocPrint(ps.arena, "unacceptable schema name \"{s}\"", .{n}), .detail = "The prefix \"pg_\" is reserved for system schemas." });
    if (!nsp.validName(n)) return ps.c.fail(name.pos, "xqlite: a schema name cannot contain \".\"", .{});
    const p = ps.p.?;
    try ps.readSchema();
    const taken = isSystemSchema(n) or nsp.find(try ps.registered(), n) != null or
        @import("../../sql/build.zig").findDbName(p.db, n) != null;
    if (taken) {
        if (if_not_exists) return ddl.notice(p, "42P06", "schema \"{s}\" already exists, skipping", .{n});
        return ps.c.failState(name.pos, .of("42P06"), "schema \"{s}\" already exists", .{n});
    }
    nsp.codeCreate(p, n, owner);
    if (p.n_err > 0) return error.Failed;
}

/// DROP EXTENSION [IF EXISTS] name, ...: none is installed but plpgsql
/// (pg_extension), which cannot be dropped here.
fn dropExtension(ps: *Parser) Error!void {
    ps.c.skip(); // DROP
    ps.c.skip(); // EXTENSION
    const if_exists = try ps.c.ifExists();
    const names = try ps.nameList();
    if (ps.c.eatKw("cascade")) {} else _ = ps.c.eatKw("restrict");
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    const p = ps.p.?;
    for (names) |n| {
        if (std.mem.eql(u8, n.text, "plpgsql")) return ps.c.failState(n.pos, .of("0A000"), "xqlite: extension \"plpgsql\" cannot be dropped", .{});
        if (!if_exists) return ps.c.failState(n.pos, .of("42704"), "extension \"{s}\" does not exist", .{n.text});
        ddl.notice(p, "00000", "extension \"{s}\" does not exist, skipping", .{n.text});
    }
}

fn dropSchema(ps: *Parser) Error!void {
    ps.c.skip(); // DROP
    ps.c.skip(); // SCHEMA
    const if_exists = try ps.c.ifExists();
    const names = try ps.nameList();
    var cascade = false;
    if (ps.c.eatKw("cascade")) cascade = true else _ = ps.c.eatKw("restrict");
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    const p = ps.p.?;
    try ps.readSchema();
    const schemas = try ps.registered();
    var drops: std.ArrayList(struct { name: []const u8, objs: []const nsp.Object }) = .empty;
    for (names) |n| {
        const s = nsp.find(schemas, n.text) orelse {
            if (eql(n.text, "pg_catalog") or eql(n.text, "information_schema") or eql(n.text, "pg_toast")) {
                return ps.c.failState(n.pos, .of("2BP01"), "cannot drop schema {s} because it is required by the database system", .{n.text});
            }
            if (eql(n.text, "public")) return ps.c.fail(n.pos, "xqlite: schema public cannot be dropped", .{});
            if (@import("../../sql/build.zig").findDbName(p.db, n.text) != null) {
                return ps.c.fail(n.pos, "xqlite: schema \"{s}\" is an attached database (use DETACH)", .{n.text});
            }
            if (if_exists) {
                ddl.notice(p, "00000", "schema \"{s}\" does not exist, skipping", .{n.text});
                continue;
            }
            return ps.c.failState(n.pos, .of("3F000"), "schema \"{s}\" does not exist", .{n.text});
        };
        const objs = nsp.objects(p.db, ps.arena, s.name) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return ps.failFrom(n.pos, p.db),
        };
        if (objs.len > 0 and !cascade) {
            // PostgreSQL's DETAIL: a line for each object that depends on
            // the schema (reportDependentObjects()).
            var detail: std.ArrayList(u8) = .empty;
            for (objs, 0..) |o, i| {
                if (i > 0) try detail.append(ps.arena, '\n');
                try detail.print(ps.arena, "{s} {s}.{s} depends on schema {s}", .{ o.kind.word(), s.name, o.bare(), s.name });
            }
            const msg = if (names.len > 1) "cannot drop desired object(s) because other objects depend on them" else try std.fmt.allocPrint(ps.arena, "cannot drop schema {s} because other objects depend on it", .{s.name});
            return ps.failFields(n.pos, .of("2BP01"), .{ .message = msg, .detail = detail.items, .hint = "Use DROP ... CASCADE to drop the dependent objects too." });
        }
        try drops.append(ps.arena, .{ .name = s.name, .objs = objs });
    }
    if (drops.items.len == 0) return emptyStatement(p);
    try cascadeNotice(p, ps.arena, drops.items);
    for (drops.items) |d| nsp.codeDrop(p, d.name, d.objs) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Failed, error.AutoVacuum => return error.Failed,
    };
}

/// The lowest level of notice the client is sent: client_min_messages
/// (debug5 ... debug1, log, notice, warning, error; notice by default).
pub fn noticeLevel(db: *const int.Sqlite3) int.Notice.Level {
    return db.xq.postgres.notice_level;
}

/// PostgreSQL's NOTICE of DROP SCHEMA ... CASCADE (reportDependentObjects()):
/// `drop cascades to table s.t`, or for several objects `drop cascades to
/// 2 other objects` with a DETAIL line for each.
fn cascadeNotice(p: *int.Parse, a: std.mem.Allocator, drops: anytype) Error!void {
    var n: usize = 0;
    var detail: std.ArrayList(u8) = .empty;
    for (drops) |d| for (d.objs) |o| {
        if (n > 0) try detail.append(a, '\n');
        try detail.print(a, "drop cascades to {s} {s}.{s}", .{ o.kind.word(), d.name, o.bare() });
        n += 1;
    };
    if (n == 0) return;
    if (n == 1) return @import("../../sql/util.zig").notice(p, .{ .fields = .{ .message = detail.items } });
    @import("../../sql/util.zig").notice(p, .{ .fields = .{ .message = try std.fmt.allocPrint(a, "drop cascades to {d} other objects", .{n}), .detail = detail.items } });
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
    /// The values SET, set_config() and the startup packet may give it,
    /// and the text SHOW prints of them.
    check: Check = .text,
    /// The client is told its value, and told again when it changes
    /// (PostgreSQL's GUC_REPORT: the wire server's ParameterStatus).
    report: bool = false,

    pub fn shown(p: *const Param) []const u8 {
        return p.display orelse p.name;
    }

    pub fn context(p: *const Param) []const u8 {
        return if (p.read_only) "internal" else "user";
    }
};

pub const Check = union(enum) {
    /// Any text, as given.
    text,
    /// An enum: one of `names` (any case), SHOW printing it as listed.
    choices: Choices,
    /// A Boolean (parse_bool(): on, off, true, no, 1 ...): SHOW prints
    /// on or off.
    boolean,
};

pub const Choices = struct {
    names: []const []const u8,
    /// Names taken too but not listed in the HINT of an invalid value
    /// (PostgreSQL's hidden ones), and the value each is.
    aliases: []const struct { []const u8, []const u8 } = &.{},
};

/// IntervalStyle's values: interval.Style's.
const interval_styles: Choices = .{ .names = blk: {
    const tags = std.meta.tags(state.IntervalStyle);
    var names: [tags.len][]const u8 = undefined;
    for (tags, &names) |t, *n| n.* = @tagName(t);
    const final = names;
    break :blk &final;
} };

/// client_min_messages' values (state.zig reads them).
const message_levels: Choices = .{
    .names = &.{ "debug5", "debug4", "debug3", "debug2", "debug1", "log", "notice", "warning", "error" },
    .aliases = &.{ .{ "debug", "debug2" }, .{ "info", "info" } },
};

const preset = "Preset Options";
const stmt_defaults = "Client Connection Defaults / Statement Behavior";
const compat = "Version and Platform Compatibility / Previous PostgreSQL Versions";

/// The parameters SET and SHOW know (the ones drivers set or read when
/// they connect, and the read-only ones the server reports); SET of the
/// others is accepted and changes nothing but what SHOW prints.
pub const params = [_]Param{
    .{ .name = "search_path", .default = state.default_search_path, .list = true, .report = true, .category = stmt_defaults, .desc = "Sets the schema search order for names that are not schema-qualified." },
    .{ .name = "application_name", .default = "", .report = true, .category = "Reporting and Logging / What to Log", .desc = "Sets the application name to be reported in statistics and logs." },
    .{ .name = "client_encoding", .default = "UTF8", .desc = "Sets the client's character set encoding." },
    .{ .name = "client_min_messages", .default = "notice", .vartype = "enum", .category = stmt_defaults, .desc = "Sets the message levels that are sent to the client.", .check = .{ .choices = message_levels } },
    .{ .name = "datestyle", .default = "ISO, MDY", .display = "DateStyle", .desc = "Sets the display format for date and time values." },
    .{ .name = "intervalstyle", .default = "postgres", .display = "IntervalStyle", .vartype = "enum", .desc = "Sets the display format for interval values.", .check = .{ .choices = interval_styles }, .report = true },
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
    .{ .name = "standard_conforming_strings", .default = "on", .vartype = "bool", .category = compat, .desc = "Causes '...' strings to treat backslashes literally.", .check = .boolean, .report = true },
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
pub fn literal(out: *std.ArrayList(u8), a: std.mem.Allocator, z: []const u8) !void {
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
    const reset = ps.c.advance().isKw("reset");
    var local = false;
    var name: []const u8 = undefined;
    var value: ?[]const u8 = null;
    if (reset) {
        if (ps.c.eatKw("all")) {
            if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
            return lowerPg(ps, "SELECT 1 WHERE set_config('all', NULL, false) IS NOT NULL");
        }
        name = (try ps.anyName()).text;
        if (eql(name, "time") and ps.c.eatKw("zone")) name = "timezone";
    } else {
        local = ps.c.eatKw("local");
        if (!local) _ = ps.c.eatKw("session");
        if (ps.c.isKw("transaction") or (ps.c.isKw("session") and ps.c.isKwAt(1, "characteristics"))) {
            // Isolation levels: parsed, nothing to do (SQLite is serializable).
            while (ps.c.peek().kind != .eof) ps.c.skip();
            return emptyStatement(ps.p.?);
        }
        if (ps.c.eatKw("schema")) {
            const t = ps.c.peek();
            if (t.kind != .string) return ps.c.syntaxError();
            ps.c.skip();
            name = "search_path";
            var out: std.ArrayList(u8) = .empty;
            try quoteIdent(&out, a, ps.val(t));
            value = out.items;
        } else {
            name = (try ps.anyName()).text;
            if (eql(name, "time") and ps.c.eatKw("zone")) {
                name = "timezone";
            } else if (!ps.c.eatKw("to") and !ps.c.eatOp("=")) return ps.c.syntaxError();
            if (eql(name, "timezone") and ps.c.isKw("interval") and ps.c.peekAt(1).kind == .string) {
                // SET TIME ZONE INTERVAL '+00:00' HOUR TO MINUTE: the offset.
                ps.c.skip();
                value = ps.val(ps.c.advance());
                while (ps.c.peek().kind == .word) ps.c.skip();
            } else if (eql(name, "timezone") and ps.c.eatKw("local")) {} else if (ps.c.eatKw("default")) {} else {
                const p_ = findParam(name);
                var out: std.ArrayList(u8) = .empty;
                var n: usize = 0;
                while (true) : (n += 1) {
                    const t = ps.c.peek();
                    if (n > 0) try out.appendSlice(a, ", ");
                    switch (t.kind) {
                        .word, .quoted_ident => if (p_ != null and p_.?.list) try quoteIdent(&out, a, ps.val(t)) else try out.appendSlice(a, ps.val(t)),
                        .string => if (p_ != null and p_.?.list) try quoteIdent(&out, a, ps.val(t)) else try out.appendSlice(a, ps.val(t)),
                        .integer, .float => try out.appendSlice(a, ps.val(t)),
                        .op => if (eql(ps.val(t), "-") and (ps.c.peekAt(1).kind == .integer or ps.c.peekAt(1).kind == .float)) {
                            ps.c.skip();
                            try out.append(a, '-');
                            try out.appendSlice(a, ps.val(ps.c.peek()));
                        } else return ps.c.syntaxError(),
                        else => return ps.c.syntaxError(),
                    }
                    ps.c.skip();
                    if (!ps.c.eat(.comma)) break;
                }
                if (n > 0 and !(p_ != null and p_.?.list)) return ps.c.failState(ps.c.peek().start, .of("22023"), "SET {s} takes only one argument", .{name});
                value = out.items;
            }
        }
    }
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    const prm = findParam(name) orelse return ps.c.failState(0, .of("42704"), "unrecognized configuration parameter \"{s}\"", .{name});
    if (prm.read_only) return ps.c.failState(0, .of("55P02"), "parameter \"{s}\" cannot be changed", .{prm.name});
    // SET LOCAL outside a transaction block does nothing, with a warning.
    if (local and main_mod.getAutocommit(ps.p.?.db)) {
        @import("../../sql/util.zig").notice(ps.p.?, .{ .level = .warning, .sqlstate = "25P01".*, .fields = .{ .message = "SET LOCAL can only be used in transaction blocks" } });
    }
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "SELECT 1 WHERE set_config(");
    try literal(&q, a, prm.name);
    try q.appendSlice(a, ", ");
    if (value) |v| try literal(&q, a, v) else try q.appendSlice(a, "NULL");
    // set_config() returns the value, never NULL: no row.
    try q.print(a, ", {s}) IS NULL", .{if (local) "true" else "false"});
    try lowerPg(ps, try a.dupeSentinel(u8, q.items, 0));
}

/// SHOW name: the query of current_setting(name), its column named after
/// the parameter; SHOW ALL: pg_settings' names, values and descriptions.
fn show(ps: *Parser) Error!void {
    const a = ps.arena;
    ps.c.skip(); // SHOW
    var name = (try ps.anyName()).text;
    if (eql(name, "time") and ps.c.eatKw("zone")) name = "timezone";
    if (eql(name, "transaction") and ps.c.eatKw("isolation")) {
        try ps.c.expectKw("level");
        name = "transaction_isolation";
    }
    if (eql(name, "session") and ps.c.eatKw("authorization")) name = "session_authorization";
    if (ps.c.peek().kind != .eof) return ps.c.syntaxError();
    if (eql(name, "all")) return lowerPg(ps, "SELECT name, setting, short_desc AS description FROM pg_catalog.pg_settings ORDER BY 1");
    const prm = findParam(name) orelse return ps.c.failState(0, .of("42704"), "unrecognized configuration parameter \"{s}\"", .{name});
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "SELECT current_setting(");
    try literal(&q, a, prm.name);
    try q.appendSlice(a, ") AS ");
    try quoteIdent(&q, a, prm.shown());
    try lowerPg(ps, try a.dupeSentinel(u8, q.items, 0));
}

/// Compile PostgreSQL text `text` (a SELECT) as this statement.
pub fn lowerPg(ps: *Parser, text: [:0]const u8) Error!void {
    var sub = Parser.init(ps.arena, text, 0, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => unreachable,
    };
    sub.p = ps.p;
    const stmt = sub.statement() catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => return ps.c.failState(0, sub.c.diag.state, "{s}", .{sub.c.diag.msg}),
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
    const prm = findParam(name) orelse return unrecognized(ctx, name);
    const value = checked(ctx, prm, api.valueText(argv[1]) orelse "") orelse return;
    apply(db, prm, value, true) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, value, .transient);
}

fn unrecognized(ctx: *Context, name: []const u8) void {
    var buf: [200]u8 = undefined;
    api.resultErrorState(ctx, .of("42704"), std.fmt.bufPrint(&buf, "unrecognized configuration parameter \"{s}\"", .{name[0..@min(name.len, 100)]}) catch "unrecognized configuration parameter");
}

/// Value `v` of `prm` as its parameter keeps it (Param.check: an enum's
/// name as listed, a Boolean's on or off), else null with PostgreSQL's
/// error the result.
fn checked(ctx: *Context, prm: *const Param, v: []const u8) ?[]const u8 {
    var buf: [300]u8 = undefined;
    switch (prm.check) {
        .text => return v,
        .boolean => {
            if (@import("funcs.zig").parseBool(v)) |b| return if (b) "on" else "off";
            const msg = std.fmt.bufPrint(&buf, "parameter \"{s}\" requires a Boolean value", .{prm.shown()}) catch "parameter requires a Boolean value";
            api.resultErrorState(ctx, .of("22023"), msg);
            return null;
        },
        .choices => |choices| {
            for (choices.names) |c| if (std.ascii.eqlIgnoreCase(c, v)) return c;
            for (choices.aliases) |c| if (std.ascii.eqlIgnoreCase(c[0], v)) return c[1];
            var hint: [200]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "invalid value for parameter \"{s}\": \"{s}\"", .{ prm.shown(), v[0..@min(v.len, 100)] }) catch "invalid value for parameter";
            var w: std.Io.Writer = .fixed(&hint);
            w.writeAll("Available values: ") catch {};
            for (choices.names, 0..) |c, i| w.print("{s}{s}", .{ if (i > 0) ", " else "", c }) catch {};
            w.writeAll(".") catch {};
            api.resultErrorFields(ctx, .of("22023"), .{ .message = msg, .hint = w.buffered() });
            return null;
        },
    }
}

/// Set `prm` to `value` (checked(); null: its value at startup or its
/// default), with `startup` the value RESET goes back to too; expire the
/// prepared statements if what they compiled read changed: search_path's
/// names, IntervalStyle sql_standard's reading of a sign (the others'
/// styles write the same code).
fn apply(db: *int.Sqlite3, prm: *const Param, value: ?[]const u8, startup: bool) error{OutOfMemory}!void {
    const st = &db.xq.postgres;
    const sql_standard = st.sqlStandard();
    if (startup) try st.setReset(db.gpa, prm.name, value.?) else try st.set(db.gpa, prm.name, value);
    if (prm.list or st.sqlStandard() != sql_standard) expire(db);
}

fn expire(db: *int.Sqlite3) void {
    @import("../../vdbe/aux.zig").expirePreparedStatements(db, 0);
}

/// The value of `prm` in `db`'s session, as SHOW prints it.
pub fn settingOf(db: *const int.Sqlite3, prm: *const Param) []const u8 {
    return db.xq.postgres.get(prm.name) orelse prm.default;
}

/// The parameters the client is told of (Param.report).
pub const reported = blk: {
    var n: usize = 0;
    for (params) |x| n += @intFromBool(x.report);
    var out: [n]*const Param = undefined;
    var i: usize = 0;
    for (&params) |*x| if (x.report) {
        out[i] = x;
        i += 1;
    };
    const final = out;
    break :blk final;
};

/// set_config(name, value, is_local): set a parameter (NULL: its
/// default; name 'all' with NULL: every one) and return its value.
fn setConfigFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultErrorState(ctx, .of("22004"), "NULL value not allowed for parameter name");
    const local = api.valueType(argv[2]) != vi.SQLITE_NULL and api.valueInt64(argv[2]) != 0;
    const given: ?[]const u8 = if (api.valueType(argv[1]) == vi.SQLITE_NULL) null else api.valueText(argv[1]) orelse "";
    const in_tx = !main_mod.getAutocommit(db);
    if (std.ascii.eqlIgnoreCase(name, "all") and given == null) {
        if (in_tx) {
            // Each value goes back if the transaction rolls back.
            const st = &db.xq.postgres;
            var names = st.params.keyIterator();
            while (names.next()) |k| _ = st.touch(db.gpa, k.*) catch return api.resultErrorNomem(ctx);
            var it = st.tx_saved.valueIterator();
            while (it.next()) |e| e.setCommit(db.gpa, null) catch return api.resultErrorNomem(ctx);
        }
        db.xq.postgres.resetParams(db.gpa);
        expire(db);
        return api.resultNull(ctx);
    }
    const prm = findParam(name) orelse return unrecognized(ctx, name);
    if (prm.read_only) {
        var buf: [200]u8 = undefined;
        return api.resultErrorState(ctx, .of("55P02"), std.fmt.bufPrint(&buf, "parameter \"{s}\" cannot be changed", .{prm.name}) catch "parameter cannot be changed");
    }
    const v = if (given) |g| checked(ctx, prm, g) orelse return else null;
    const st = &db.xq.postgres;
    if (in_tx) {
        // The value it goes back to when the transaction ends: a SET's
        // stays after COMMIT, a SET LOCAL's does not.
        const e = st.touch(db.gpa, prm.name) catch return api.resultErrorNomem(ctx);
        if (!local) e.setCommit(db.gpa, v) catch return api.resultErrorNomem(ctx);
    } else if (local) {
        // Outside a transaction: for the transaction of this statement
        // alone, so nothing (PostgreSQL's set_config(..., true) too).
        return api.resultText(ctx, v orelse prm.default, .transient);
    }
    apply(db, prm, v, false) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, settingOf(db, prm), .transient);
}

/// The transaction ended (dialect.transactionEnded()): the parameters it
/// changed take the value of its last SET (COMMIT; SET LOCAL lasts until
/// here) or the one before it (ROLLBACK), as PostgreSQL's.
pub fn transactionEnded(db: *int.Sqlite3, committed: bool) void {
    const st = &db.xq.postgres;
    if (st.tx_saved.count() == 0) return;
    var m = st.takeSaved();
    defer state.State.freeSaved(db.gpa, &m);
    var it = m.iterator();
    while (it.next()) |e| {
        const prm = findParam(e.key_ptr.*) orelse continue;
        const v = if (committed) e.value_ptr.commit else e.value_ptr.orig;
        const now = st.params.get(prm.name);
        if (v == null and now == null) continue;
        if (v != null and now != null and eql(v.?, now.?)) continue;
        apply(db, prm, v, false) catch {};
    }
}

/// current_setting(name [, missing_ok]).
fn currentSettingFunc(ctx: *Context, argv: []*Mem) void {
    const db = api.contextDbHandle(ctx);
    const name = api.valueText(argv[0]) orelse return api.resultNull(ctx);
    const prm = findParam(name) orelse {
        if (argv.len > 1 and api.valueInt64(argv[1]) != 0) return api.resultNull(ctx);
        return unrecognized(ctx, name);
    };
    api.resultText(ctx, settingOf(db, prm), .transient);
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
