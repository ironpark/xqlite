//! SQL dialects: which language a connection speaks, and the seams where
//! a dialect changes what the engine does.
//!
//! A dialect is two things (see README.md, "방언 아키텍처"):
//!
//!  - a **frontend** (Frontend): a lexer/parser that reads the text of a
//!    statement and lowers it into the common IR, SQLite's parse tree,
//!    by calling the builders of src/ir/ir.zig. SQLite's own frontend
//!    (sqlite/frontend.zig) is the reference user of that interface;
//!  - **semantic hooks** (Hooks): engine-side behaviour that the IR alone
//!    does not carry: extra built-in functions, extra collations and the
//!    default collation. The SQLite dialect has none, so a connection in
//!    the SQLite dialect behaves (and compiles) exactly as before.
//!
//! The dialect is chosen per connection (ConnState, Sqlite3.xq): with
//! OpenOptions.dialect of the Zig API, main.setDialect(), PRAGMA
//! xq_dialect or the shell's .dialect. A statement remembers the dialect
//! it was compiled in (Vdbe.xq_lang) and is recompiled in it after a
//! schema change. Text the engine itself parses (the schema, nested
//! statements of the code generator, ALTER TABLE rewrites, declared
//! virtual tables) is always SQLite text and always goes through the
//! SQLite frontend.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const ctype = @import("../util/ctype.zig");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const CollSeq = int.CollSeq;

/// The dialects. The values are stable (they are stored by nothing yet,
/// but keep them so); 3 is meant for MSSQL (T-SQL).
pub const Dialect = enum(u8) {
    sqlite = 0,
    postgres = 1,
    mariadb = 2,

    /// The name used by PRAGMA xq_dialect, .dialect and the catalog.
    pub fn name(d: Dialect) [:0]const u8 {
        return @tagName(d);
    }

    /// The dialect called `z` (case-insensitive; "pg", "postgresql" and
    /// "mysql" are accepted as aliases), or null.
    pub fn fromName(z: []const u8) ?Dialect {
        for (std.enums.values(Dialect)) |d| {
            if (ctype.eqlNoCase(z, @tagName(d))) return d;
        }
        const aliases = [_]struct { []const u8, Dialect }{
            .{ "pg", .postgres },
            .{ "postgresql", .postgres },
            .{ "mysql", .mariadb },
        };
        for (aliases) |a| if (ctype.eqlNoCase(z, a[0])) return a[1];
        return null;
    }
};

/// A dialect frontend: compiles SQL text into the Parse by lowering it
/// into the IR (src/ir/ir.zig).
///
/// The contract of `run(p, sql)`, which prepare calls in place of
/// sqlite3RunParser():
///  - compile the *first* statement of `sql` (the caller loops over the
///    rest), finishing it with ir.stmt.finishCoding() (the SQLite grammar
///    does so in its `cmdx ::= cmd` action), which leaves p.rc DONE;
///  - leave in p.tail the text after that statement (a suffix of `sql`);
///    a blank statement (only spaces/comments) codes nothing;
///  - report errors with ir.stmt.errorMsg()/syntaxError() (p.err_msg,
///    p.n_err, p.rc) and fail with error.ParseFailed; error.OutOfMemory
///    only for allocations of the parse tree;
///  - never persist dialect text: whatever ends up in sqlite_schema must
///    be SQLite text (sqlite3 reads it back), see ir.stmt.lowerSqliteText().
pub const Frontend = struct {
    name: [:0]const u8,
    run: *const fn (p: *Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void,
};

/// The engine-side behaviour of a dialect. Every field defaults to what
/// SQLite does.
pub const Hooks = struct {
    /// Built-in functions of the dialect (see func.zig for constructors):
    /// looked up after the application-defined functions and before
    /// SQLite's built-ins, so a dialect can add functions (PostgreSQL's
    /// version(), nextval()) and replace SQLite's (MariaDB's CONCAT(),
    /// which is NULL when an argument is). They are invisible to other
    /// dialects and to the SQL the engine runs itself
    /// (DBFLAG.PreferBuiltin).
    functions: []const FuncDef = &.{},
    /// Collations the dialect adds to BINARY, NOCASE and RTRIM (by name,
    /// case-insensitive; the connection's own come first). A schema that
    /// names one cannot be used by sqlite3, so frontends should prefer
    /// mapping dialect collations to the built-in ones.
    collations: []const CollSeq = &.{},
    /// The collation of a value with none (C: db->pDfltColl): the name of
    /// a built-in, a dialect or a connection collation; null is BINARY.
    /// Indexes keep BINARY for columns without a COLLATE (so the file
    /// stays valid for sqlite3); the planner then does not use them for
    /// comparisons in this collation.
    default_collation: ?[:0]const u8 = null,
};

/// Everything that makes a dialect.
pub const Spec = struct {
    dialect: Dialect,
    frontend: *const Frontend,
    hooks: Hooks,
};

const specs = blk: {
    var s: [std.enums.values(Dialect).len]Spec = undefined;
    for (std.enums.values(Dialect)) |d| {
        const m = module(d);
        s[@backingInt(d)] = .{ .dialect = d, .frontend = &m.frontend, .hooks = m.hooks };
    }
    break :blk s;
};

fn module(comptime d: Dialect) type {
    return switch (d) {
        .sqlite => @import("sqlite/frontend.zig"),
        .postgres => @import("postgres/frontend.zig"),
        .mariadb => @import("mariadb/frontend.zig"),
    };
}

/// The definition of dialect `d`.
pub fn spec(d: Dialect) *const Spec {
    return &specs[@backingInt(d)];
}

/// The language a statement is compiled in: a dialect (its hooks) and a
/// frontend, normally the dialect's own (main.setFrontend() changes it,
/// e.g. to run SQLite's grammar with another dialect's hooks).
pub const Lang = struct {
    dialect: Dialect = .sqlite,
    frontend: *const Frontend = spec(.sqlite).frontend,

    pub fn of(d: Dialect) Lang {
        return .{ .dialect = d, .frontend = spec(d).frontend };
    }

    /// The SQLite dialect with SQLite's grammar: what the engine uses for
    /// its own SQL.
    pub const sqlite: Lang = .{};
};

/// The per-connection state of the dialect layer (Sqlite3.xq).
pub const ConnState = struct {
    lang: Lang = .{},
    /// currval() of the sequences used by this connection (owned names,
    /// from the connection's allocator).
    currval: std.StringHashMapUnmanaged(i64) = .empty,
    /// The sequence nextval() last advanced (lastval()), an owned name.
    last_sequence: ?[]u8 = null,

    pub fn deinit(s: *ConnState, gpa: std.mem.Allocator) void {
        var it = s.currval.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.currval.deinit(gpa);
        if (s.last_sequence) |z| gpa.free(z);
        s.* = .{};
    }
};

/// Switch the connection to Lang.sqlite for SQL the engine generates and
/// runs itself (OP_SqlExec, the pragma virtual tables, sqlite_stat1, the
/// catalog); give the result to leaveEngineSql() afterwards:
///
///     const saved = dialect.enterEngineSql(db);
///     defer dialect.leaveEngineSql(db, saved);
pub fn enterEngineSql(db: *Sqlite3) Lang {
    const saved = db.xq.lang;
    db.xq.lang = .sqlite;
    return saved;
}

pub fn leaveEngineSql(db: *Sqlite3, saved: Lang) void {
    db.xq.lang = saved;
}

/// The hooks of the dialect the connection compiles in.
pub fn hooks(db: *const Sqlite3) *const Hooks {
    return &spec(db.xq.lang.dialect).hooks;
}

/// Compile the first statement of `sql` with the connection's frontend
/// (the dispatch prepare does in place of sqlite3RunParser()). Schema
/// text is always SQLite's: while the schema is read, the SQLite
/// frontend runs whatever the dialect.
pub fn runParser(p: *Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    const f = if (p.db.init.busy) spec(.sqlite).frontend else p.db.xq.lang.frontend;
    return f.run(p, sql);
}

/// The frontend of a dialect whose parser is not written yet: blank text
/// (spaces and comments, as SQLite's tokenizer sees them) is an empty
/// statement, anything else fails with "<name> dialect: parser not
/// implemented" and consumes the rest of the text.
pub fn notImplemented(p: *Parse, sql: [:0]const u8, name: []const u8) int.ParseError!void {
    const tokenize = @import("../parse/tokenize.zig");
    p.rc = int.RC.OK;
    p.tail = sql;
    var i: usize = 0;
    while (sql[i] != 0) {
        const t = tokenize.getToken(sql[i..].ptr);
        if (t.tk != int.TK.SPACE and t.tk != int.TK.COMMENT) {
            @import("../sql/util.zig").errorMsg(p, "{s} dialect: parser not implemented", .{name});
            p.tail = sql[sql.len..];
            return error.ParseFailed;
        }
        i += t.len;
    }
    p.tail = sql[sql.len..];
}

// ============================================================== functions

/// The functions of the connection's dialect named `name`, all of them
/// (in table order), for callback.findFunction(): none in the SQLite
/// dialect and while the engine runs its own SQL (PreferBuiltin).
pub fn functionSearch(db: *const Sqlite3, name: []const u8) []const FuncDef {
    if (db.xq.lang.dialect == .sqlite or db.m_db_flags.PreferBuiltin) return &.{};
    const all = hooks(db).functions;
    // The definitions of one name are next to each other (func.zig).
    for (all, 0..) |*f, i| {
        if (!ctype.eqlNoCase(f.name, name)) continue;
        var j = i + 1;
        while (j < all.len and ctype.eqlNoCase(all[j].name, name)) j += 1;
        return all[i..j];
    }
    return &.{};
}

// ============================================================= collations

/// The dialect collation `name`, or null.
pub fn findCollation(db: *const Sqlite3, name: []const u8) ?*const CollSeq {
    if (db.xq.lang.dialect == .sqlite) return null;
    for (hooks(db).collations) |*c| {
        if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    return null;
}

/// The name of the default collation of the connection's dialect, null
/// for BINARY.
pub fn defaultCollationName(db: *const Sqlite3) ?[:0]const u8 {
    if (db.xq.lang.dialect == .sqlite) return null;
    return hooks(db).default_collation;
}

test {
    _ = @import("func.zig");
    _ = @import("test.zig");
}

test "Dialect names" {
    for (std.enums.values(Dialect)) |d| {
        try std.testing.expectEqual(d, Dialect.fromName(d.name()).?);
        try std.testing.expect(spec(d).dialect == d);
    }
    try std.testing.expectEqual(Dialect.postgres, Dialect.fromName("PG").?);
    try std.testing.expectEqual(Dialect.mariadb, Dialect.fromName("MySQL").?);
    try std.testing.expect(Dialect.fromName("oracle") == null);
}
