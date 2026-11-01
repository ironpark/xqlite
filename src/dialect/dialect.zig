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
/// What arithmetic does where SQLite's yields NULL or a real: the error
/// the dialect raises instead (null keeps SQLite's result). The policy
/// of the dialect a statement was compiled in applies (Vdbe.xq_lang), so
/// a view or CHECK runs with the arithmetic of the statement using it.
pub const Arith = struct {
    /// Division and remainder by zero (SQLite: NULL).
    div_zero: ?Failure = null,
    /// An integer result outside 64 bits (SQLite: a real).
    int_overflow: ?Failure = null,
    /// An integer result outside the range of its type, for arithmetic
    /// whose type (Hooks.typing) is an integer narrower than 64 bits:
    /// int1 (tinyint), int2 (smallint), int4 (integer). Null: no check
    /// (the values compute in 64 bits, as MariaDB's INT arithmetic is a
    /// BIGINT). Code generation marks such an operation with the width
    /// (P5 of OP_Add ... OP_Remainder, arithWidth()), so that the check
    /// costs nothing elsewhere.
    int1: ?Range = null,
    int2: ?Range = null,
    int4: ?Range = null,

    /// The values of an integer type and the error outside them. With
    /// `value`, the message is followed by the result and a period (SQL
    /// Server's "..., value = 256."), when the result fits in 64 bits.
    pub const Range = struct { min: i64, max: i64, failure: Failure, value: bool = false };

    /// The Range of width `w` (P5 of an arithmetic opcode: 1 int1, 2
    /// int2, 3 int4), null for none.
    pub fn range(a: *const Arith, w: u16) ?Range {
        return switch (w) {
            1 => a.int1,
            2 => a.int2,
            3 => a.int4,
            else => null,
        };
    }

    /// The width (P5) of arithmetic of type `l` in a dialect of these
    /// rules, 0 for no check.
    pub fn width(a: *const Arith, l: @import("../sql/types.zig").Logical) u16 {
        const w: u16 = switch (l) {
            .int1 => 1,
            .int2 => 2,
            .int4 => 3,
            else => return 0,
        };
        return if (a.range(w) != null) w else 0;
    }
};

/// An error a dialect raises: its message and what it is.
pub const Failure = struct { msg: []const u8, state: int.ErrorState };

/// What a failed constraint says (Hooks.constraint), decided when the
/// statement is compiled (src/dialect/constraint.zig): the message goes
/// into the program, so the success path costs nothing.
pub const Constraint = struct {
    /// The error of `v` in the dialect's words, from `a` (the statement's
    /// memory); null keeps SQLite's ("UNIQUE constraint failed: t.a").
    /// The message may hold `value_mark` where the values of the key go
    /// when Violation.has_value.
    message: ?*const fn (a: std.mem.Allocator, v: Violation) error{OutOfMemory}!Failure = null,
    /// A foreign key failure whose constraint is unknown: one found at
    /// COMMIT (a deferred constraint), or by DROP TABLE.
    foreign_key: ?Failure = null,
    /// Between the values of a key put at `value_mark`.
    value_separator: []const u8 = ", ",
};

/// Where the values of the duplicate key go in a message of
/// Constraint.message: the program writes them there when it fails.
pub const value_mark = '\x01';

/// A constraint that fails, as Constraint.message sees it. Names are as
/// SQLite holds them: a table of a named schema is "schema.table"
/// (catalog.schemas.split()).
pub const Violation = struct {
    kind: Kind,
    /// The statement that writes the row (CREATE UNIQUE INDEX: a unique
    /// index built on rows that are not unique).
    op: enum { insert, update, delete, create_index },
    /// The SQLite database of the table ("main", "temp", an attached one).
    database: []const u8,
    /// The table; the child table of a foreign key.
    table: []const u8,
    /// The columns of the constraint (of the child, for a foreign key).
    columns: []const []const u8 = &.{},
    /// The constraint's name when the user gave one (recorded in the
    /// catalog, catalog.Key.constraint), the index's of a unique index, a
    /// CHECK's; null: the dialect names it (a CHECK whose SQLite name is
    /// its text, `unnamedCheck`, is unnamed).
    name: ?[]const u8 = null,
    /// A foreign key: the parent table and its columns.
    parent: []const u8 = "",
    parent_columns: []const []const u8 = &.{},
    /// A foreign key: which of the table's, from 1 in the order of CREATE
    /// TABLE (MariaDB's t_ibfk_<n>).
    ordinal: u32 = 0,
    /// The message may put the key's values at value_mark.
    has_value: bool = false,

    pub const Kind = enum {
        not_null,
        /// A UNIQUE constraint.
        unique,
        primary_key,
        /// A unique index (CREATE UNIQUE INDEX).
        unique_index,
        check,
        /// A child row without its parent.
        foreign_key,
        /// A parent row that a child row still refers to (DELETE or
        /// UPDATE of the parent).
        referenced,
    };

    /// Whether the name of a CHECK is SQLite's for an unnamed one: its
    /// text, not an identifier.
    pub fn unnamedCheck(name: []const u8) bool {
        if (name.len == 0 or std.ascii.isDigit(name[0])) return true;
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '#' or c >= 0x80)) return true;
        return false;
    }

    /// The schema of an object of a named schema ("schema.name"), else
    /// null.
    pub fn schemaOf(name: []const u8) ?[]const u8 {
        return if (@import("../catalog/schema.zig").split(name)) |s| s.schema else null;
    }

    /// `name` without the schema schemaOf() finds.
    pub fn bare(name: []const u8) []const u8 {
        return if (@import("../catalog/schema.zig").split(name)) |s| s.name else name;
    }

    /// The columns joined by `sep`, each written `fmt` (`{s}`, `` `{s}` ``).
    pub fn joined(a: std.mem.Allocator, cols: []const []const u8, comptime fmt: []const u8, sep: []const u8) error{OutOfMemory}![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        for (cols, 0..) |c, i| {
            if (i > 0) out.writer.writeAll(sep) catch return error.OutOfMemory;
            out.writer.print(fmt, .{c}) catch return error.OutOfMemory;
        }
        return out.written();
    }
};

pub const Hooks = struct {
    /// Arithmetic errors (Arith).
    arith: Arith = .{},
    /// The errors of failed constraints (Constraint).
    constraint: Constraint = .{},
    /// The dialect's databases enforce foreign keys: the connection turns
    /// PRAGMA foreign_keys on while it compiles in the dialect
    /// (applyForeignKeys()).
    foreign_keys: bool = false,
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
    /// The errors of the CHECK constraints the frontend names after its
    /// type checks (`value too long for type character varying(3)`): a
    /// failed CHECK whose name starts with `prefix` is that error
    /// (checkState()).
    check_errors: []const CheckError = &.{},
    /// The types the dialect gives literals, operators and functions
    /// (sql/typing.zig's Rules), applied after name resolution to the
    /// Exprs of the dialect's statements that the frontend did not type;
    /// null types only what the frontend and the catalog type. The
    /// declared types of result columns, display, the parameters' types;
    /// code generation reads only the width of integer arithmetic (Arith)
    /// and the store functions (Rules.store).
    typing: ?*const @import("../sql/typing.zig").Rules = null,
};

pub const CheckError = struct {
    prefix: []const u8,
    state: int.ErrorState,
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

/// The number a dialect gives the error of an SQLSTATE.
pub const Number = struct { [5]u8, u32 };

/// Give the error of `p` its number in the dialect (from `numbers`, by
/// the SQLSTATE the engine set where it raised it), for a frontend's
/// translateError(). `number` overrides it when the dialect tells two
/// errors of one SQLSTATE apart. An error the dialect raised itself keeps
/// the number it gave it.
pub fn numberError(p: *int.Parse, numbers: []const Number, number: ?u32) void {
    const st = &(p.err_state orelse return);
    if (st.number != 0) return;
    if (number) |n| {
        st.number = n;
        return;
    }
    for (numbers) |e| if (std.mem.eql(u8, &e[0], &st.sqlstate)) {
        st.number = e[1];
        return;
    };
}

/// The ErrorState of the failure of the CHECK constraint `name`, if a
/// dialect named it after one of its errors (Hooks.check_errors). The
/// dialect that made the table need not be the connection's.
pub fn checkState(name: []const u8) ?int.ErrorState {
    inline for (comptime std.enums.values(Dialect)) |d| {
        for (module(d).hooks.check_errors) |c| {
            if (std.mem.startsWith(u8, name, c.prefix)) return c.state;
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
    /// applyForeignKeys(): the dialect of the last application statement
    /// it saw, and whether it turned PRAGMA foreign_keys on.
    foreign_keys: struct { dialect: ?Dialect = null, ours: bool = false } = .{},
    /// Whether the open transaction wrote xq_catalog (catalog/meta.zig):
    /// rolling it back, or part of it, drops the catalog read into
    /// memory, as SQLite's DBFLAG_SchemaChange does the schema.
    catalog_written: bool = false,
    /// The types of expressions beyond the plain ones (Expr.xq_type,
    /// sql/typing.zig): kept as long as the connection, since Exprs of
    /// the schema may hold their ids.
    types: @import("../sql/typing.zig").Interner = .{},
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
        s.types.deinit(gpa);
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

/// PRAGMA foreign_keys for the dialect the connection compiles in
/// (Hooks.foreign_keys): at the first statement the application prepares
/// in a dialect that enforces foreign keys, turn it on; at the first in
/// one that does not, turn it back off if this turned it on. A setting
/// the application made in between (PRAGMA foreign_keys, MariaDB's SET
/// foreign_key_checks) stays. Not for SQL the engine runs while compiling
/// or running a statement (in Lang.sqlite), and only outside a
/// transaction, where PRAGMA foreign_keys may change; otherwise at the
/// next statement.
fn applyForeignKeys(p: *Parse) void {
    const db = p.db;
    const st = &db.xq.foreign_keys;
    const d = db.xq.lang.dialect;
    if (st.dialect == d) return;
    if (db.init.busy or p.outer_parse != null or db.n_vdbe_active != 0 or !db.auto_commit) return;
    st.dialect = d;
    if (spec(d).hooks.foreign_keys) {
        if (db.flags.ForeignKeys) return;
        st.ours = true;
    } else {
        if (!st.ours) return;
        st.ours = false;
        if (!db.flags.ForeignKeys) return;
    }
    db.flags.ForeignKeys = !db.flags.ForeignKeys;
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
    applyForeignKeys(p);
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
    _ = @import("calendar.zig");
    _ = @import("words.zig");
    _ = @import("json_text.zig");
    _ = @import("lex.zig");
    _ = @import("shared_funcs.zig");
    _ = @import("test.zig");
    _ = @import("constraint.zig");
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
