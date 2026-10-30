//! SQL dialects: which language a connection speaks, and the seams where
//! a dialect changes what the engine does.
//!
//! A dialect is two things (see docs/architecture.md):
//!
//!  - a **frontend** (Frontend): a lexer/parser that reads the text of a
//!    statement and lowers it into the common IR, SQLite's parse tree,
//!    by calling the builders of src/ir/ir.zig: SQLite's own frontend
//!    (sqlite/frontend.zig, the reference user of that interface)
//!    directly, the others through the syntax tree IR of src/ir/tree.zig
//!    and its one lowering (src/ir/lower.zig) and renderer for the schema
//!    (src/ir/render.zig);
//!  - **semantic hooks** (Hooks): engine-side behaviour that the IR alone
//!    does not carry: extra built-in functions, extra collations and the
//!    default collation. The SQLite dialect has none, so a connection in
//!    the SQLite dialect behaves (and compiles) exactly as before.
//!
//! Every dialect but SQLite's can be left out of the build (`zig build
//! -Ddialects=postgres,oracle`, default all): its name stays known, but
//! choosing it fails (built()) and its frontend (disabled.zig) fails
//! every statement. Its engine functions go with it, so a schema that a
//! dialect wrote with them (MariaDB's column conversions, for one) needs
//! that dialect built in, as it needs xqlite rather than sqlite3.
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
const ctype = @import("xqlite_base").ctype;
const config = @import("xqlite_config");

const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const CollSeq = int.CollSeq;

/// The dialects. The values are stable (they are stored by nothing yet,
/// but keep them so).
pub const Dialect = enum(u8) {
    sqlite = 0,
    postgres = 1,
    mariadb = 2,
    /// Microsoft SQL Server (T-SQL).
    mssql = 3,
    /// Oracle Database.
    oracle = 4,

    /// The name used by PRAGMA xq_dialect, .dialect and the catalog.
    pub fn name(d: Dialect) [:0]const u8 {
        return @tagName(d);
    }

    /// Whether the dialect is in this build (-Ddialects).
    pub fn built(d: Dialect) bool {
        return switch (d) {
            .sqlite => true,
            inline else => |x| @field(config, "dialect_" ++ @tagName(x)),
        };
    }

    /// The dialect called `z` (case-insensitive; "pg", "postgresql",
    /// "mysql", "sqlserver" and "tsql" are accepted as aliases), or null.
    /// It may not be built().
    pub fn fromName(z: []const u8) ?Dialect {
        for (std.enums.values(Dialect)) |d| {
            if (ctype.eqlNoCase(z, @tagName(d))) return d;
        }
        const aliases = [_]struct { []const u8, Dialect }{
            .{ "pg", .postgres },
            .{ "postgresql", .postgres },
            .{ "mysql", .mariadb },
            .{ "sqlserver", .mssql },
            .{ "tsql", .mssql },
        };
        for (aliases) |a| if (ctype.eqlNoCase(z, a[0])) return a[1];
        return null;
    }
};

/// A dialect frontend: compiles SQL text into the Parse by lowering it
/// into the IR (src/ir/ir.zig).
///
/// The contract of `run(p, sql)`, which runParser() calls (prepare's
/// sqlite3RunParser()) with p.rc OK, p.tail `sql` and db.parse `p`:
///  - compile the *first* statement of `sql` (the caller loops over the
///    rest), finishing it with ir.stmt.finishCoding() (the SQLite grammar
///    does so in its `cmdx ::= cmd` action), which leaves p.rc DONE;
///  - leave in p.tail the text after that statement (a suffix of `sql`);
///    a blank statement (only spaces/comments) codes nothing;
///  - report errors with ir.stmt.errorMsg()/syntaxError() (p.err_msg,
///    p.n_err, p.rc), and may fail with error.ParseFailed; error.OutOfMemory
///    only for allocations of the parse tree. runParser() does the rest
///    of what sqlite3RunParser() does (the message of an error without
///    one, the SQL length limit, freeing p.new_table);
///  - never persist dialect text: whatever ends up in sqlite_schema must
///    be SQLite text (sqlite3 reads it back), see ir.stmt.lowerSqliteText().
///
/// The SQLite frontend's run() is sqlite3RunParser() itself.
pub const Frontend = struct {
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
    /// Engine functions: functions a frontend lowers or renders a
    /// semantic node of the IR tree to (xq_like(), xq_pg_bool(),
    /// xq_coerce() ...). Unlike `functions` they are visible in every
    /// dialect, to the SQLite frontend and to the SQL the engine runs
    /// itself, because render.zig writes them into the schema, which any
    /// connection may read. Their names start with "xq_" (so that they
    /// shadow nothing) and are unique across dialects (checked at compile
    /// time). They are looked up after SQLite's built-ins; like those,
    /// they are usable from the schema with trusted_schema off unless
    /// `unsafe`, so they must be innocuous, and deterministic if they may
    /// appear in an index, a CHECK or a generated column.
    engine_functions: []const FuncDef = &.{},
    /// Engine table-valued functions (eponymous virtual tables) a
    /// frontend lowers to, as engine_functions: visible in every dialect,
    /// named "xq_..." and unique across dialects. Registered on a
    /// connection when a statement first names one
    /// (engineModuleRegister()).
    engine_modules: []const EngineModule = &.{},
    /// Like engine_modules, for names that are not fixed (T-SQL's OPENJSON
    /// encodes its WITH columns in the name): build.locateTable() calls it
    /// for an unknown table "xq_..." that no engine_modules entry names;
    /// it registers the module called `name` on `db` and returns it, null
    /// if `name` is not one of its.
    table_function: ?*const fn (db: *Sqlite3, name: []const u8) ?*int.Module = null,
};

pub const EngineModule = struct {
    name: [:0]const u8,
    module: *const @import("../sql/vtab.zig").Module,
};

/// Register the engine module `name` (Hooks.engine_modules) on `db`, for
/// build.locateTable(); null if there is none of that name.
pub fn engineModuleRegister(db: *Sqlite3, name: []const u8) ?*int.Module {
    if (!hasEnginePrefix(name)) return null;
    inline for (comptime std.enums.values(Dialect)) |d| {
        for (module(d).hooks.engine_modules) |m| {
            if (ctype.eqlNoCase(m.name, name)) return @import("../sql/vtab.zig").createModuleInternal(db, m.name, m.module, null, null);
        }
    }
    return null;
}

/// The module of the engine table-valued function `name`
/// (Hooks.table_function of any dialect), registered on `db`; null if
/// there is none.
pub fn tableFunction(db: *Sqlite3, name: []const u8) ?*int.Module {
    inline for (comptime std.enums.values(Dialect)) |d| {
        if (comptime module(d).hooks.table_function) |f| {
            if (f(db, name)) |m| return m;
        }
    }
    return null;
}

/// Everything that makes a dialect.
pub const Spec = struct {
    frontend: *const Frontend,
    hooks: Hooks,
    /// Hooks.functions by name (functionSearch()).
    function_map: FunctionMap,
};

const specs = blk: {
    var s: [std.enums.values(Dialect).len]Spec = undefined;
    for (std.enums.values(Dialect)) |d| {
        const m = module(d);
        s[@backingInt(d)] = .{ .frontend = &m.frontend, .hooks = m.hooks, .function_map = functionMap(m.hooks.functions) };
    }
    break :blk s;
};

/// The error of choosing dialect `d` when it is not built().
pub const not_built_message = blk: {
    var m: [std.enums.values(Dialect).len][]const u8 = undefined;
    for (std.enums.values(Dialect)) |d| {
        m[@backingInt(d)] = "dialect not built in: " ++ @tagName(d);
    }
    break :blk m;
};

fn module(comptime d: Dialect) type {
    if (!d.built()) return @import("disabled.zig").Disabled(d);
    return switch (d) {
        .sqlite => @import("sqlite/frontend.zig"),
        .postgres => @import("postgres/frontend.zig"),
        .mariadb => @import("mariadb/frontend.zig"),
        .mssql => @import("mssql/frontend.zig"),
        .oracle => @import("oracle/frontend.zig"),
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
    /// The MariaDB session: sql_mode, warnings, user variables.
    mariadb: @import("mariadb/state.zig").State = .{},
    /// The T-SQL session: variables, IDENTITY_INSERT, @@IDENTITY.
    mssql: @import("mssql/state.zig").State = .{},
    /// The PostgreSQL session: search_path and the other SET parameters.
    postgres: @import("postgres/state.zig").State = .{},
    /// The Oracle session: the current schema.
    oracle: @import("oracle/state.zig").State = .{},

    pub fn deinit(s: *ConnState, gpa: std.mem.Allocator) void {
        var it = s.currval.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.currval.deinit(gpa);
        if (s.last_sequence) |z| gpa.free(z);
        s.mariadb.deinit(gpa);
        s.mssql.deinit(gpa);
        s.postgres.deinit(gpa);
        s.oracle.deinit(gpa);
        s.* = .{};
    }
};

/// Make `lang` the connection's language and return the one it had, to
/// give back afterwards. Lang.sqlite is for SQL the engine generates and
/// runs itself (OP_SqlExec, the pragma virtual tables, sqlite_stat1, the
/// catalog):
///
///     const saved = dialect.swapLang(db, .sqlite);
///     defer _ = dialect.swapLang(db, saved);
pub fn swapLang(db: *Sqlite3, lang: Lang) Lang {
    const saved = db.xq.lang;
    db.xq.lang = lang;
    return saved;
}

/// The hooks of the dialect the connection compiles in.
pub fn hooks(db: *const Sqlite3) *const Hooks {
    return &spec(db.xq.lang.dialect).hooks;
}

/// Turn PRAGMA foreign_keys back off when the T-SQL dialect turned it on
/// and the connection has moved to another dialect: before a statement
/// the application prepares (not SQL the engine runs for a T-SQL
/// statement, in Lang.sqlite) outside a transaction, as PRAGMA
/// foreign_keys may only change there.
fn restoreForeignKeys(p: *Parse) void {
    const db = p.db;
    if (!db.xq.mssql.foreign_keys_on or db.xq.lang.dialect == .mssql) return;
    if (db.init.busy or p.outer_parse != null or db.n_vdbe_active != 0 or !db.auto_commit) return;
    db.xq.mssql.foreign_keys_on = false;
    if (!db.flags.ForeignKeys) return;
    db.flags.ForeignKeys = false;
    @import("../vdbe/aux.zig").expirePreparedStatements(db, 0);
}

/// Compile the first statement of `sql` with the connection's frontend
/// (the dispatch prepare does in place of sqlite3RunParser()). Schema
/// text is always SQLite's: while the schema is read, the SQLite
/// frontend runs whatever the dialect. So do SQLite's own commands in
/// every dialect (isSqliteCommand()).
pub fn runParser(p: *Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    const db = p.db;
    const sqlite_frontend = spec(.sqlite).frontend;
    restoreForeignKeys(p);
    const f = if (db.init.busy) sqlite_frontend else db.xq.lang.frontend;
    if (f == sqlite_frontend or isSqliteCommand(sql)) return sqlite_frontend.run(p, sql);

    // What sqlite3RunParser() does around its parser.
    if (db.n_vdbe_active == 0) db.is_interrupted.store(false, .monotonic);
    p.rc = int.RC.OK;
    p.tail = sql;
    const parent = db.parse;
    db.parse = p;
    defer db.parse = parent;
    var failed = false;
    f.run(p, sql) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseFailed => failed = true,
    };
    if (!failed and sql.len - p.tail.len > @as(usize, @intCast(db.limit(.sql_length)))) {
        p.rc = int.RC.TOOBIG;
        p.n_err += 1;
    }
    if (failed or p.n_err > 0 or p.err_msg != null or (p.rc != int.RC.OK and p.rc != int.RC.DONE)) {
        if (p.rc == int.RC.OK or p.rc == int.RC.DONE) p.rc = int.RC.ERROR;
        if (p.err_msg == null) p.err_msg = try p.arena.dupeSentinel(u8, @import("../sql/util.zig").errStr(p.rc), 0);
        failed = true;
    }
    if (p.new_table) |t| if (!p.inSpecialParse()) {
        @import("../sql/build.zig").deleteTable(db, t);
        p.new_table = null;
    };
    if (failed) return error.ParseFailed;
}

/// Whether the first statement of `sql` is one of SQLite's commands that
/// every dialect passes to SQLite's grammar as written (xqlite extensions
/// of the dialects): PRAGMA, so that `PRAGMA xq_dialect = 'sqlite'`
/// switches back, ATTACH, DETACH, VACUUM and REINDEX. Spaces, comments
/// and semicolons before it are SQLite's.
fn isSqliteCommand(sql: [:0]const u8) bool {
    const getToken = @import("../parse/tokenize.zig").getToken;
    const TK = int.TK;
    var z: [*:0]const u8 = sql.ptr;
    while (z[0] != 0) {
        const t = getToken(z);
        switch (t.tk) {
            TK.SPACE, TK.COMMENT, TK.SEMI => z += t.len,
            TK.PRAGMA, TK.ATTACH, TK.DETACH, TK.VACUUM, TK.REINDEX => return true,
            else => return false,
        }
    }
    return false;
}

// ================================================================ SQL text

/// `z` between `q` quotes, with the quotes in it doubled, for the SQL
/// text a frontend generates (`{f}`): Quoted('\'') is a string literal,
/// Quoted('"') an SQLite or PostgreSQL identifier, Quoted('`') a MariaDB
/// one.
pub fn Quoted(comptime q: u8) type {
    return struct {
        z: []const u8,

        pub fn format(x: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeByte(q);
            var rest = x.z;
            while (std.mem.indexOfScalar(u8, rest, q)) |i| {
                try w.writeAll(rest[0 .. i + 1]);
                try w.writeByte(q);
                rest = rest[i + 1 ..];
            }
            try w.writeAll(rest);
            try w.writeByte(q);
        }
    };
}

// ============================================================== functions

/// The functions of the connection's dialect named `name`, all of them
/// (in table order), for callback.findFunction(): none in the SQLite
/// dialect and while the engine runs its own SQL (PreferBuiltin).
pub fn functionSearch(db: *const Sqlite3, name: []const u8) []const FuncDef {
    if (db.xq.lang.dialect == .sqlite or db.m_db_flags.PreferBuiltin) return &.{};
    return spec(db.xq.lang.dialect).function_map.get(name) orelse &.{};
}

const FunctionMap = std.StaticStringMapWithEql([]const FuncDef, ctype.eqlNoCase);

/// The engine functions of every dialect (Hooks.engine_functions) named
/// `name`, for callback.findFunction(): visible whatever the connection's
/// dialect.
pub fn engineFunctionSearch(name: []const u8) []const FuncDef {
    if (!hasEnginePrefix(name)) return &.{};
    return engine_function_map.get(name) orelse &.{};
}

fn hasEnginePrefix(name: []const u8) bool {
    return name.len > 3 and ctype.eqlNoCase(name[0..3], "xq_");
}

const engine_function_map = blk: {
    @setEvalBranchQuota(100_000);
    var all: []const FuncDef = &.{};
    for (std.enums.values(Dialect)) |d| {
        const defs = module(d).hooks.engine_functions;
        for (defs, 0..) |f, i| {
            if (!std.mem.startsWith(u8, f.name, "xq_")) @compileError("engine function " ++ f.name ++ ": the name must start with xq_");
            // The overloads of a name are next to each other, in one table.
            if (i > 0 and ctype.eqlNoCase(defs[i - 1].name, f.name)) continue;
            for (all) |g| if (ctype.eqlNoCase(g.name, f.name)) @compileError("engine function " ++ f.name ++ " is defined twice");
        }
        all = all ++ defs;
    }
    break :blk functionMap(all);
};

/// The function a name qualified with a dialect means:
/// xq_<dialect>_<name> is <name> of that dialect's Hooks.functions, in
/// every dialect. render.zig writes a call of a dialect's function so,
/// as the schema may be read by a connection in another dialect.
pub fn qualifiedFunctionSearch(name: []const u8) []const FuncDef {
    if (!hasEnginePrefix(name)) return &.{};
    const rest = name[3..];
    for (std.enums.values(Dialect)) |d| {
        const n = d.name();
        if (rest.len > n.len + 1 and ctype.eqlNoCase(rest[0..n.len], n) and rest[n.len] == '_') {
            return spec(d).function_map.get(rest[n.len + 1 ..]) orelse &.{};
        }
    }
    return &.{};
}

/// xq_<dialect>_<name>: how render.zig calls function `name` of dialect
/// `d` (qualifiedFunctionSearch()), in `arena`.
pub fn qualifiedFunctionName(arena: std.mem.Allocator, d: Dialect, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "xq_{s}_{s}", .{ d.name(), name });
}

/// The overloads of each name of `defs`, which are next to each other
/// (func.checkTable()).
fn functionMap(comptime defs: []const FuncDef) FunctionMap {
    @setEvalBranchQuota(100_000);
    var kvs: [defs.len]struct { []const u8, []const FuncDef } = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < defs.len) {
        var j = i + 1;
        while (j < defs.len and ctype.eqlNoCase(defs[j].name, defs[i].name)) j += 1;
        kvs[n] = .{ defs[i].name, defs[i..j] };
        n += 1;
        i = j;
    }
    return .initComptime(kvs[0..n]);
}

// ============================================================= collations

/// The dialect collation `name`, or null.
pub fn findCollation(db: *const Sqlite3, name: []const u8) ?*const CollSeq {
    if (db.xq.lang.dialect == .sqlite) return null;
    for (hooks(db).collations) |*c| {
        if (ctype.eqlNoCase(c.name, name)) return c;
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
    _ = @import("template.zig");
    _ = @import("test.zig");
}

test "Dialect names" {
    for (std.enums.values(Dialect)) |d| {
        try std.testing.expectEqual(d, Dialect.fromName(d.name()).?);
    }
    try std.testing.expectEqual(Dialect.postgres, Dialect.fromName("PG").?);
    try std.testing.expectEqual(Dialect.mariadb, Dialect.fromName("MySQL").?);
    try std.testing.expectEqual(Dialect.mssql, Dialect.fromName("SQLServer").?);
    try std.testing.expect(Dialect.fromName("db2") == null);
}
