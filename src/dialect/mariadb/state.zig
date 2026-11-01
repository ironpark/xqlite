//! The per-connection state of the MariaDB dialect: the session's
//! sql_mode, the warnings of the last statement (SHOW WARNINGS), the
//! user variables and the current database (USE).
//!
//! It lives in the connection (dialect.ConnState.mariadb, reached from
//! a Parse as p.db.xq.mariadb and from an SQL function through
//! api.contextDbHandle()), is freed with it (deinit()) and exists in
//! every connection whatever its dialect, so that switching a
//! connection to MariaDB and back keeps the session's settings.
//!
//! When a setting takes effect:
//!  - SET sql_mode is applied when the statement runs (xq_set_sysvar()
//!    in session.zig); the parser-level modes (ANSI_QUOTES,
//!    PIPES_AS_CONCAT, NO_BACKSLASH_ESCAPES, NO_AUTO_VALUE_ON_ZERO,
//!    EMPTY_STRING_IS_NULL) shape the statements compiled after that;
//!  - the data modes (STRICT_TRANS_TABLES, STRICT_ALL_TABLES,
//!    NO_ZERO_DATE, NO_ZERO_IN_DATE, ALLOW_INVALID_DATES) are read when a
//!    statement runs, by the value coercion of INSERT and UPDATE
//!    (types.zig), so a prepared statement follows the current mode;
//!  - USE is applied when the statement runs (xq_maria_use() in
//!    databases.zig) and expires the prepared statements: names are
//!    resolved when a statement is compiled.

const std = @import("std");
const vi = @import("../../vdbe/vdbe_int.zig");
const api = @import("../../vdbe/api.zig");

/// The flags of sql_mode, in MariaDB's order (the order @@sql_mode
/// lists them in). The combination modes (ANSI, TRADITIONAL, ...) are
/// flags too: MariaDB shows them next to the flags they stand for.
pub const Flag = enum(u6) {
    REAL_AS_FLOAT,
    PIPES_AS_CONCAT,
    ANSI_QUOTES,
    IGNORE_SPACE,
    IGNORE_BAD_TABLE_OPTIONS,
    ONLY_FULL_GROUP_BY,
    NO_UNSIGNED_SUBTRACTION,
    NO_DIR_IN_CREATE,
    POSTGRESQL,
    ORACLE,
    MSSQL,
    DB2,
    MAXDB,
    NO_KEY_OPTIONS,
    NO_TABLE_OPTIONS,
    NO_FIELD_OPTIONS,
    MYSQL323,
    MYSQL40,
    ANSI,
    NO_AUTO_VALUE_ON_ZERO,
    NO_BACKSLASH_ESCAPES,
    STRICT_TRANS_TABLES,
    STRICT_ALL_TABLES,
    NO_ZERO_IN_DATE,
    NO_ZERO_DATE,
    ALLOW_INVALID_DATES,
    ERROR_FOR_DIVISION_BY_ZERO,
    TRADITIONAL,
    NO_AUTO_CREATE_USER,
    HIGH_NOT_PRECEDENCE,
    NO_ENGINE_SUBSTITUTION,
    PAD_CHAR_TO_FULL_LENGTH,
    EMPTY_STRING_IS_NULL,
    SIMULTANEOUS_ASSIGNMENT,
    TIME_ROUND_FRACTIONAL,
};

/// A set of sql_mode flags.
pub const SqlMode = struct {
    bits: u64 = 0,

    pub fn has(m: SqlMode, f: Flag) bool {
        return m.bits & bit(f) != 0;
    }

    pub fn with(m: SqlMode, f: Flag) SqlMode {
        return .{ .bits = m.bits | bit(f) };
    }

    fn bit(f: Flag) u64 {
        return @as(u64, 1) << @backingInt(f);
    }

    /// STRICT_TRANS_TABLES or STRICT_ALL_TABLES: every table is
    /// transactional here, so both mean the same.
    pub fn strict(m: SqlMode) bool {
        return m.has(.STRICT_TRANS_TABLES) or m.has(.STRICT_ALL_TABLES);
    }

    /// MariaDB 10.2+'s default (also 11.x's).
    pub const default: SqlMode = fromFlags(&.{ .STRICT_TRANS_TABLES, .ERROR_FOR_DIVISION_BY_ZERO, .NO_AUTO_CREATE_USER, .NO_ENGINE_SUBSTITUTION });

    pub fn fromFlags(fs: []const Flag) SqlMode {
        var m: SqlMode = .{};
        for (fs) |f| m = m.with(f);
        return m;
    }

    /// Parse a comma-separated list of mode names (case-insensitive,
    /// spaces around names ignored, empty items skipped), expanding the
    /// combination modes. Null with `bad` set to the unknown name.
    pub fn parse(text: []const u8, bad: *[]const u8) ?SqlMode {
        var m: SqlMode = .{};
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n");
            if (name.len == 0) continue;
            const f = flagByName(name) orelse {
                bad.* = name;
                return null;
            };
            m = m.with(f);
            for (combination(f)) |g| m = m.with(g);
        }
        return m;
    }

    /// The text of @@sql_mode: the flag names in order, comma-separated.
    pub fn format(m: SqlMode, buf: []u8) []const u8 {
        var n: usize = 0;
        for (std.enums.values(Flag)) |f| {
            if (!m.has(f)) continue;
            const name = @tagName(f);
            if (n > 0) {
                buf[n] = ',';
                n += 1;
            }
            @memcpy(buf[n..][0..name.len], name);
            n += name.len;
        }
        return buf[0..n];
    }

    /// The longest text format() can produce.
    pub const max_text = blk: {
        var n: usize = 0;
        for (std.enums.values(Flag)) |f| n += @tagName(f).len + 1;
        break :blk n;
    };
};

fn flagByName(name: []const u8) ?Flag {
    for (std.enums.values(Flag)) |f| {
        if (std.ascii.eqlIgnoreCase(@tagName(f), name)) return f;
    }
    return null;
}

/// The flags a combination mode stands for (MariaDB's sql_mode docs).
fn combination(f: Flag) []const Flag {
    const ansi_like = [_]Flag{ .PIPES_AS_CONCAT, .ANSI_QUOTES, .IGNORE_SPACE, .NO_KEY_OPTIONS, .NO_TABLE_OPTIONS, .NO_FIELD_OPTIONS };
    return switch (f) {
        .ANSI => &.{ .REAL_AS_FLOAT, .PIPES_AS_CONCAT, .ANSI_QUOTES, .IGNORE_SPACE, .ONLY_FULL_GROUP_BY },
        .TRADITIONAL => &.{ .STRICT_TRANS_TABLES, .STRICT_ALL_TABLES, .NO_ZERO_IN_DATE, .NO_ZERO_DATE, .ERROR_FOR_DIVISION_BY_ZERO, .NO_AUTO_CREATE_USER, .NO_ENGINE_SUBSTITUTION },
        .POSTGRESQL, .ORACLE, .MSSQL, .DB2 => &ansi_like,
        .MAXDB => &(ansi_like ++ [_]Flag{.NO_AUTO_CREATE_USER}),
        .MYSQL323, .MYSQL40 => &.{.HIGH_NOT_PRECEDENCE},
        else => &.{},
    };
}

/// One warning (or note) of SHOW WARNINGS.
pub const Warning = struct {
    level: Level = .warning,
    code: u16 = 0,
    len: u8 = 0,
    buf: [msg_max]u8 = undefined,

    pub const Level = enum { note, warning, @"error" };
    pub const msg_max = 160;

    pub fn message(w: *const Warning) []const u8 {
        return w.buf[0..w.len];
    }

    pub fn levelName(w: *const Warning) []const u8 {
        return switch (w.level) {
            .note => "Note",
            .warning => "Warning",
            .@"error" => "Error",
        };
    }
};

pub const State = struct {
    sql_mode: SqlMode = SqlMode.default,
    /// User variables (@name, lower case): names from the connection's
    /// allocator, values from api.valueDup().
    user_vars: std.StringHashMapUnmanaged(*vi.Mem) = .empty,
    /// The warnings of the last statement compiled in the MariaDB
    /// dialect: the first `stored_max`, and how many there were.
    warnings: [stored_max]Warning = undefined,
    n_warnings: u32 = 0,
    /// The current database (USE): null for main, the default; owned by
    /// the connection's allocator. `no_database` after DROP DATABASE of
    /// the current one (DATABASE() is NULL, unqualified names fail).
    database: ?[]u8 = null,
    no_database: bool = false,
    /// CONNECTION_ID(): the connection id a wire server gave the session
    /// (the MySQL protocol's, for KILL), else 1.
    connection_id: u32 = 1,

    pub const stored_max = 8;

    /// The name of the default database (SQLite's main).
    pub const main_database = "main";

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.database) |z| gpa.free(z);
        var it = s.user_vars.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            api.valueFree(e.value_ptr.*);
        }
        s.user_vars.deinit(gpa);
        s.* = .{};
    }

    /// Set user variable `name` to a copy of `v` (NULL removes it).
    pub fn setUserVar(s: *State, gpa: std.mem.Allocator, name: []const u8, v: *vi.Mem) error{OutOfMemory}!void {
        if (s.user_vars.fetchRemove(name)) |old| {
            gpa.free(old.key);
            api.valueFree(old.value);
        }
        if (api.valueType(v) == vi.SQLITE_NULL) return;
        const copy = api.valueDup(v) orelse return error.OutOfMemory;
        errdefer api.valueFree(copy);
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try s.user_vars.put(gpa, key, copy);
    }

    /// The current database: "main", a database of ATTACH or of CREATE
    /// DATABASE; null if none is selected.
    pub fn currentDatabase(s: *const State) ?[]const u8 {
        if (s.no_database) return null;
        return s.database orelse main_database;
    }

    /// USE `name` (null: no database, as after DROP DATABASE of the
    /// current one).
    pub fn setDatabase(s: *State, gpa: std.mem.Allocator, name: ?[]const u8) error{OutOfMemory}!void {
        const copy: ?[]u8 = if (name) |n|
            (if (std.ascii.eqlIgnoreCase(n, main_database)) null else try gpa.dupe(u8, n))
        else
            null;
        if (s.database) |z| gpa.free(z);
        s.database = copy;
        s.no_database = name == null;
    }

    pub fn userVar(s: *const State, name: []const u8) ?*vi.Mem {
        return s.user_vars.get(name);
    }

    /// Forget the warnings (a new statement starts).
    pub fn clearWarnings(s: *State) void {
        s.n_warnings = 0;
    }

    /// Record a warning: `fmt` formatted, cut to Warning.msg_max bytes.
    pub fn warn(s: *State, level: Warning.Level, code: u16, comptime fmt: []const u8, args: anytype) void {
        if (s.n_warnings < stored_max) {
            const w = &s.warnings[s.n_warnings];
            w.level = level;
            w.code = code;
            var writer: std.Io.Writer = .fixed(&w.buf);
            writer.print(fmt, args) catch {};
            w.len = @intCast(writer.end);
        }
        s.n_warnings +|= 1;
    }

    pub fn storedWarnings(s: *const State) []const Warning {
        return s.warnings[0..@min(s.n_warnings, stored_max)];
    }
};

test "sql_mode parsing and formatting" {
    var bad: []const u8 = "";
    var buf: [SqlMode.max_text]u8 = undefined;
    try std.testing.expectEqualStrings(
        "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION",
        SqlMode.default.format(&buf),
    );
    const ansi = SqlMode.parse("ansi", &bad).?;
    try std.testing.expectEqualStrings("REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI", ansi.format(&buf));
    const m = SqlMode.parse(" no_backslash_escapes , ,PIPES_AS_CONCAT", &bad).?;
    try std.testing.expect(m.has(.NO_BACKSLASH_ESCAPES) and m.has(.PIPES_AS_CONCAT) and !m.strict());
    try std.testing.expect(SqlMode.parse("STRICT,FOO", &bad) == null);
    try std.testing.expectEqualStrings("STRICT", bad);
    try std.testing.expectEqual(@as(u64, 0), SqlMode.parse("", &bad).?.bits);
}
