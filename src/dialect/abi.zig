//! The engine functions and collations as an ABI: what the schema text a
//! dialect writes may call (docs/extension.md).
//!
//! A frontend renders the schema (CHECK, DEFAULT, generated columns,
//! expression indexes, views, triggers) as SQLite text that calls engine
//! functions (xq_like(), xq_pg_jsonb() ...), dialect functions by their
//! qualified name (xq_<dialect>_<name>, dialect.qualifiedFunctionSearch()),
//! SQLite's built-ins a dialect shadows (xq_sqlite_<name>), the sequence
//! functions (nextval('t_id_seq')) and the dialect collations (COLLATE
//! xq_pg_jsonb). xqlite computes them, and so does sqlite3 with the
//! loadable extension (src/loadable/root.zig), from the same code. Once
//! such a call is in a database file, its meaning is part of the file
//! format: an expression index or a STORED generated column computed by
//! one engine is read by the other, so both must compute the same value
//! today and in every later release.
//!
//! The rule: a function or collation the schema may name never changes
//! meaning (results, errors, NULL handling, comparison order); a change
//! gets a new name, and the old name keeps the old meaning. `version`
//! counts the incompatible changes there were anyway (never, so far): an
//! application can compare xq_ext_version() of the engine and of the
//! extension. The test below keeps `catalogue` and abi.txt (the
//! manifest: every name, argument count and flags) the same, and `xqt
//! interop ext` keeps the results of tools/ext/abi-cases.sql the same as
//! recorded, in xqlite and in sqlite3 with the extension.

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const api = @import("../vdbe/api.zig");
const dfunc = @import("func.zig");
const dialect = @import("dialect.zig");

const FuncDef = int.FuncDef;
const CollSeq = int.CollSeq;
const Dialect = dialect.Dialect;

/// The ABI version of the engine functions and collations, the result
/// of xq_ext_version() in xqlite and in the extension. Raised only for a
/// change of meaning that could not get a new name (see above).
pub const version: i64 = 1;

/// xq_ext_version(): `version`. Hooks.engine_functions of no dialect:
/// dialect.zig adds them, as like.zig's.
pub const engine_functions = [_]FuncDef{
    dfunc.scalar("xq_ext_version", 0, .{ .deterministic = true }, versionFunc),
};

fn versionFunc(ctx: *dfunc.Context, _: []*dfunc.Mem) void {
    api.resultInt64(ctx, version);
}

// ============================================================ catalogue

/// Where a function of the catalogue comes from.
pub const Origin = enum {
    /// An engine function (Hooks.engine_functions, like.zig, this file).
    engine,
    /// A function of a dialect's table (Hooks.functions), called by its
    /// qualified name xq_<dialect>_<name>.
    qualified,
    /// SQLite's built-in a dialect shadows, as xq_sqlite_<name>.
    sqlite,
    /// A sequence function as nextvalExpr() writes it into a DEFAULT
    /// (nextval('name')): catalog/sequence.zig's semantics, which the
    /// extension implements over SQL (src/loadable/sequence.zig).
    sequence,
};

/// What the extension cannot compute, and why.
pub const Unportable = enum {
    /// Reads or changes the state of the xqlite session (settings,
    /// variables, the current schema, currval() of the session ...),
    /// which a sqlite3 connection does not have.
    session,
    /// Reads xqlite's catalog of the connection (the pg_catalog snapshot,
    /// the schemas of SQL Server), which the extension does not keep.
    catalog,
    /// Only usable from top-level SQL (SQLITE_DIRECTONLY): never in the
    /// schema.
    direct_only,
    /// SQLite's built-in is compiled inline (coalesce(), iif() ...) or
    /// reads the connection (changes() ...): sqlite3 has its own under
    /// the plain name.
    inline_builtin,
};

pub const Entry = struct {
    /// The name the schema text calls.
    name: [:0]const u8,
    def: *const FuncDef,
    origin: Origin,
    /// The dialect of a qualified or engine function (null: like.zig's,
    /// this file's, a sequence function's, SQLite's built-in).
    dialect: ?Dialect = null,
    /// Why the extension leaves it out; null: it registers it.
    unportable: ?Unportable = null,
    /// A function on sequences (catalog/sequence.zig's nextval() ...),
    /// which the extension implements over SQL; null for the others.
    sequence: ?Sequence = null,
};

/// The functions on sequences, as catalog/sequence.zig computes them.
pub const Sequence = enum {
    nextval,
    currval,
    setval,
    /// lastval(): the value nextval() last returned on the connection.
    lastval,
    /// MariaDB's LASTVAL(seq): currval() of `seq`, NULL if none.
    lastval_of,

    /// The function of a dialect's table named `name` with `n_arg`
    /// arguments, if it is one (SQL Server's NEXT VALUE FOR is
    /// xq_tsql_next_value()).
    fn of(name: []const u8, n_arg: i16) ?Sequence {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "nextval") or eq(name, "xq_tsql_next_value")) return .nextval;
        if (eq(name, "currval")) return .currval;
        if (eq(name, "setval")) return .setval;
        if (eq(name, "lastval")) return if (n_arg == 0) .lastval else .lastval_of;
        return null;
    }
};

pub const Collation = struct {
    coll: *const CollSeq,
    dialect: Dialect,
};

/// Functions of the dialects' tables that need xqlite's session or
/// catalog, by dialect and name (every argument count): xqlite computes
/// them, the extension leaves them out. None of them is deterministic
/// over the arguments alone, so none can be in an index or a CHECK; a
/// view that calls one is readable by xqlite only.
const unportable_names = [_]struct { Dialect, []const u8, Unportable }{
    // PostgreSQL: settings and the catalog snapshot.
    .{ .postgres, "current_setting", .session },
    .{ .postgres, "current_schema", .session },
    .{ .postgres, "current_schemas", .session },
    .{ .postgres, "current_database", .session },
    .{ .postgres, "set_config", .session },
    .{ .postgres, "pg_backend_pid", .session },
    .{ .postgres, "pg_table_is_visible", .catalog },
    .{ .postgres, "pg_type_is_visible", .catalog },
    .{ .postgres, "pg_get_expr", .catalog },
    .{ .postgres, "pg_get_indexdef", .catalog },
    .{ .postgres, "pg_get_constraintdef", .catalog },
    .{ .postgres, "pg_get_viewdef", .catalog },
    .{ .postgres, "pg_get_serial_sequence", .catalog },
    .{ .postgres, "obj_description", .catalog },
    .{ .postgres, "col_description", .catalog },
    .{ .postgres, "to_regclass", .catalog },
    .{ .postgres, "to_regtype", .catalog },
    .{ .postgres, "to_regnamespace", .catalog },
    .{ .postgres, "to_regrole", .catalog },
    .{ .postgres, "xq_pg_regclass", .catalog },
    .{ .postgres, "xq_pg_regtype", .catalog },
    .{ .postgres, "xq_pg_regnamespace", .catalog },
    .{ .postgres, "xq_pg_regrole", .catalog },
    .{ .postgres, "xq_pg_regproc", .catalog },
    .{ .postgres, "xq_pg_regclass_out", .catalog },
    .{ .postgres, "xq_pg_regtype_out", .catalog },
    .{ .postgres, "xq_pg_regnamespace_out", .catalog },
    .{ .postgres, "xq_pg_regrole_out", .catalog },
    .{ .postgres, "xq_pg_column_default", .catalog },
    // MariaDB: system and user variables, the current database.
    .{ .mariadb, "xq_sysvar", .session },
    .{ .mariadb, "xq_uservar", .session },
    // SQL Server: the session's identity and variables, the schemas.
    .{ .mssql, "scope_identity", .session },
    .{ .mssql, "ident_current", .catalog },
    .{ .mssql, "xq_tsql_getvar", .session },
    .{ .mssql, "xq_tsql_trancount", .session },
    .{ .mssql, "xq_tsql_schema_id", .catalog },
    .{ .mssql, "xq_tsql_schema_name", .catalog },
    .{ .mssql, "xq_tsql_object_name", .catalog },
    .{ .mssql, "xq_tsql_object_schema_name", .catalog },
    .{ .mssql, "xq_tsql_schema_of", .catalog },
    .{ .mssql, "xq_tsql_bare_name", .catalog },
    // Oracle: the session's schema and transaction.
    .{ .oracle, "set_current_schema", .session },
    .{ .oracle, "sys_context", .session },
    .{ .oracle, "xq_ora_autocommit", .session },
};

comptime {
    // Each name is one of its dialect's (when built).
    @setEvalBranchQuota(1_000_000);
    for (unportable_names) |u| {
        if (!u[0].built()) continue;
        const h = &dialect.spec(u[0]).hooks;
        const found = for (h.functions ++ h.engine_functions) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, u[1])) break true;
        } else false;
        if (!found) @compileError("abi.zig: " ++ u[0].name() ++ " has no function " ++ u[1]);
    }
}

/// Every function the schema text may call, in the order of the tables.
pub const catalogue: []const Entry = blk: {
    @setEvalBranchQuota(1_000_000);
    var all: []const Entry = &.{};
    for (dialect.common_engine_functions) |defs| {
        for (defs) |*f| all = all ++ &[_]Entry{.{ .name = f.name, .def = f, .origin = .engine }};
    }
    for (std.enums.values(Dialect)) |d| {
        const h = &dialect.spec(d).hooks;
        for (h.engine_functions) |*f| {
            all = all ++ &[_]Entry{.{ .name = f.name, .def = f, .origin = .engine, .dialect = d, .unportable = unportableOf(d, f) }};
        }
    }
    for (std.enums.values(Dialect)) |d| {
        const h = &dialect.spec(d).hooks;
        for (h.functions) |*f| {
            const q = "xq_" ++ d.name() ++ "_" ++ f.name;
            all = all ++ &[_]Entry{.{ .name = q, .def = f, .origin = .qualified, .dialect = d, .unportable = unportableOf(d, f), .sequence = Sequence.of(f.name, f.n_arg) }};
        }
    }
    // SQLite's built-ins under xq_sqlite_<name>, for the names a dialect
    // shadows (lower.functionName()), each name once.
    const callback = @import("../sql/callback.zig");
    var seen: []const []const u8 = &.{};
    for (std.enums.values(Dialect)) |d| {
        for (dialect.spec(d).hooks.functions) |f| {
            const lname = lower(f.name);
            const defs = callback.functionSearch(callback.funcHash(lname[0], lname.len), lname);
            if (defs.len == 0) continue;
            const dup = for (seen) |x| {
                if (std.mem.eql(u8, x, lname)) break true;
            } else false;
            if (dup) continue;
            seen = seen ++ &[_][]const u8{lname};
            for (defs) |*g| {
                const q = "xq_sqlite_" ++ lname;
                all = all ++ &[_]Entry{.{ .name = q, .def = g, .origin = .sqlite, .unportable = builtinUnportable(g) }};
            }
        }
    }
    // nextval('t_id_seq') of an identity column's DEFAULT (and its kin,
    // for the applications that read such a database).
    if (dialect.Dialect.postgres.built() or dialect.Dialect.mariadb.built() or dialect.Dialect.mssql.built() or dialect.Dialect.oracle.built()) {
        for (&@import("../catalog/sequence.zig").functions) |*f| {
            all = all ++ &[_]Entry{.{ .name = f.name, .def = f, .origin = .sequence, .sequence = Sequence.of(f.name, f.n_arg) }};
        }
    }
    break :blk all;
};

fn lower(comptime z: []const u8) [:0]const u8 {
    var buf: [z.len:0]u8 = undefined;
    for (z, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const final = buf;
    return &final;
}

/// Whether SQLite's built-in `g` is one the extension cannot call as a
/// function: compiled inline, or reading the connection or the VM.
fn builtinUnportable(comptime g: *const FuncDef) ?Unportable {
    const f = g.func_flags;
    if (f.INLINE or f.NEEDCOLL or f.INTERNAL or f.DIRECT or g.x_sfunc == null) return .inline_builtin;
    return null;
}

fn unportableOf(comptime d: Dialect, comptime f: *const FuncDef) ?Unportable {
    if (f.func_flags.DIRECT) return .direct_only;
    for (unportable_names) |u| {
        if (u[0] == d and std.ascii.eqlIgnoreCase(u[1], f.name)) return u[2];
    }
    return null;
}

/// The collations of every dialect built in.
pub const collations: []const Collation = blk: {
    var all: []const Collation = &.{};
    for (std.enums.values(Dialect)) |d| {
        for (dialect.spec(d).hooks.collations) |*c| all = all ++ &[_]Collation{.{ .coll = c, .dialect = d }};
    }
    break :blk all;
};

// ============================================================= manifest

/// One line per function and collation of the catalogue: what abi.txt
/// records.
pub fn writeManifest(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("version {d}\n", .{version});
    for (catalogue) |e| {
        const f = e.def.func_flags;
        try w.print("{s} {d} {s}", .{ e.name, e.def.n_arg, @tagName(e.origin) });
        if (e.def.x_finalize != null) try w.writeAll(if (e.def.x_inverse != null) " window" else " aggregate");
        if (f.CONSTANT) try w.writeAll(" deterministic");
        if (f.UNSAFE) try w.writeAll(" unsafe");
        if (f.DIRECT) try w.writeAll(" direct");
        if (f.SUBTYPE) try w.writeAll(" subtype");
        if (f.RESULT_SUBTYPE) try w.writeAll(" result_subtype");
        if (e.unportable) |u| try w.print(" xqlite-only:{s}", .{@tagName(u)});
        if (e.sequence) |q| try w.print(" sequence:{s}", .{@tagName(q)});
        try w.writeByte('\n');
    }
    for (collations) |k| try w.print("collation {s} {s}\n", .{ k.coll.name, k.dialect.name() });
}

/// abi.txt: the manifest as recorded, for every dialect built in.
const recorded = @embedFile("abi.txt");

test "abi: the functions the schema may call keep their names, arguments and flags" {
    try Dialect.requireBuilt(&.{ .postgres, .mariadb, .mssql, .oracle });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeManifest(&out.writer);
    const now = out.written();
    var failures: usize = 0;
    // A recorded line must still be there: removing or changing one
    // breaks the databases that call it (a new name is the way).
    var it = std.mem.tokenizeScalar(u8, recorded, '\n');
    while (it.next()) |line| {
        if (line[0] == '#') continue;
        if (!hasLine(now, line)) {
            std.debug.print("abi.txt: no longer true: {s}\n", .{line});
            failures += 1;
        }
    }
    // A new one must be recorded (append it to abi.txt).
    var it2 = std.mem.tokenizeScalar(u8, now, '\n');
    while (it2.next()) |line| {
        if (!hasLine(recorded, line)) {
            std.debug.print("abi.txt: not recorded: {s}\n", .{line});
            failures += 1;
        }
    }
    if (failures > 0) {
        std.debug.print("see src/dialect/abi.zig and docs/extension.md: a function the schema may call never changes; a new one is added to abi.txt\n", .{});
        return error.TestUnexpectedResult;
    }
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

test "abi: xq_ext_version()" {
    try std.testing.expectEqual(@as(i64, 1), version);
    try std.testing.expect(dialect.engineFunctionSearch("xq_ext_version").len == 1);
}

// ================================================================ counts

/// The counts docs/extension.md gives by dialect: the functions the
/// extension registers by kind, the ones it leaves out, the collations.
const Counts = struct { engine: usize = 0, qualified: usize = 0, sequence: usize = 0, excluded: usize = 0, collation: usize = 0 };

/// The row of docs/extension.md's table: `d` a dialect, null the
/// functions of every dialect (like.zig's, decimal_sql.zig's, this
/// file's, the sequence functions), `builtins` SQLite's (xq_sqlite_*).
fn countsOf(d: ?Dialect, builtins: bool) Counts {
    var c: Counts = .{};
    for (catalogue) |e| {
        if (e.dialect != d or (e.origin == .sqlite) != builtins) continue;
        if (e.unportable != null) {
            c.excluded += 1;
            continue;
        }
        switch (e.origin) {
            .engine => c.engine += 1,
            .qualified, .sqlite => if (e.sequence != null) {
                c.sequence += 1;
            } else {
                c.qualified += 1;
            },
            .sequence => c.sequence += 1,
        }
    }
    if (d) |x| for (collations) |k| {
        if (k.dialect == x) c.collation += 1;
    };
    return c;
}

/// The leading number of a table cell, 0 for an empty one.
fn cellNumber(cell: []const u8) usize {
    const z = std.mem.trim(u8, cell, " ");
    var n: usize = 0;
    for (z) |ch| {
        if (!std.ascii.isDigit(ch)) break;
        n = n * 10 + (ch - '0');
    }
    return n;
}

test "abi: docs/extension.md counts the functions as the catalogue has them" {
    try Dialect.requireBuilt(&.{ .postgres, .mariadb, .mssql, .oracle });
    const gpa = std.testing.allocator;
    // Read from the build root, as `zig build test` runs (the fuzz tests
    // read ref/ so too); a run elsewhere (wasi) has no docs to check.
    const doc = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/extension.md", gpa, .unlimited) catch return error.SkipZigTest;
    defer gpa.free(doc);
    const rows = [_]struct { []const u8, ?Dialect, bool }{
        .{ "공통", null, false },
        .{ "PostgreSQL", .postgres, false },
        .{ "MariaDB", .mariadb, false },
        .{ "SQL Server", .mssql, false },
        .{ "Oracle", .oracle, false },
        .{ "SQLite 내장", null, true },
    };
    var failures: usize = 0;
    var registered: usize = 0;
    var excluded: usize = 0;
    for (rows) |r| {
        const want = countsOf(r[1], r[2]);
        registered += want.engine + want.qualified + want.sequence;
        excluded += want.excluded;
        var lines = std.mem.tokenizeScalar(u8, doc, '\n');
        const line = while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "| ") and std.mem.startsWith(u8, l[2..], r[0]) and l.len > 2 + r[0].len and (l[2 + r[0].len] == ' ' or l[2 + r[0].len] == '(')) break l;
        } else {
            std.debug.print("docs/extension.md: no row {s}\n", .{r[0]});
            failures += 1;
            continue;
        };
        var cells = std.mem.splitScalar(u8, line[1..], '|');
        _ = cells.next();
        var got: Counts = .{};
        inline for (.{ "engine", "qualified", "sequence", "excluded", "collation" }) |f| @field(got, f) = cellNumber(cells.next() orelse "");
        if (!std.meta.eql(got, want)) {
            std.debug.print("docs/extension.md: row {s} says {any}, the catalogue has {any}\n", .{ r[0], got, want });
            failures += 1;
        }
    }
    const total = try std.fmt.allocPrint(gpa, "모두 {d}개, 빠지는 것 {d}개", .{ registered, excluded });
    defer gpa.free(total);
    if (std.mem.indexOf(u8, doc, total) == null) {
        std.debug.print("docs/extension.md: the totals should read \"{s}\"\n", .{total});
        failures += 1;
    }
    if (failures > 0) return error.TestUnexpectedResult;
}
