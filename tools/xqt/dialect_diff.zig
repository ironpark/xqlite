//! `xqt dialect-diff pg|mariadb|mssql|oracle [CASES]`: the differential test of a
//! dialect against its real server. Each case of the cases file
//! (tools/dialect/pg-cases.txt, maria-cases.txt, mssql-cases.txt) runs in the server's
//! client and in `xqlite sql` with the dialect on; the rows, the column
//! names (of results with rows) and the "ERROR:" lines must be the same.
//! (Was tools/dialect/pg-diff.sh and maria-diff.sh.)
//!
//! A case starts with a line "-- case: NAME" and runs on an empty
//! database. The cases run in parallel:
//!
//! - PostgreSQL: each worker has a database of its own (xqt_dialect_N,
//!   made before and dropped after the run), and each case starts, as
//!   before, by dropping and making its schema public.
//! - MariaDB: every case runs in the database main, which the cases name
//!   (information_schema queries, main.t) and so do MariaDB's error
//!   messages ("Table 'main.x' doesn't exist"). The server runs one case
//!   at a time (its prelude drops every database a case made); the
//!   xqlite side of the cases runs in parallel.
//!
//! The server is reached with $PG_PSQL / $MARIA_CLIENT, split on blanks
//! as the shell did, by default `podman exec -i` into the containers
//!
//!     podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
//!     podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
//!     podman run -d --name xq-ora -e ORACLE_PASSWORD=xqpass -e APP_USER=xq -e APP_USER_PASSWORD=xqpass gvenzl/oracle-free:23-slim-faststart
//!
//! - Oracle: every case runs in the schema of user XQ ($ORA_SQLPLUS), one
//!   at a time; its prelude drops the user's tables, views and sequences
//!   and sets the date formats to the dialect's ('YYYY-MM-DD HH24:MI:SS').
//!   Errors compare by their ORA- code: xqlite's errors that are SQLite's
//!   (constraint failures found while a statement runs) are mapped to the
//!   code Oracle gives the same failure (normXqOra()).
//!
//! Not part of `zig build check`: it needs a server.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt dialect-diff pg|mariadb|mssql|oracle [CASES-FILE]
    \\
    \\  pg        tools/dialect/pg-cases.txt against PostgreSQL ($PG_PSQL,
    \\            default "podman exec -i xq-pg psql -U postgres")
    \\  mariadb   tools/dialect/maria-cases.txt against MariaDB ($MARIA_CLIENT,
    \\            default "podman exec -i xq-maria mariadb -uroot")
    \\  mssql     tools/dialect/mssql-cases.txt against SQL Server ($MSSQL_CLIENT,
    \\            default "podman exec -i xq-mssql /tmp/sqlcmd -S localhost
    \\            -U sa -P Xq_Passw0rd! -C")
    \\  oracle    tools/dialect/oracle-cases.txt against Oracle Database ($ORA_SQLPLUS,
    \\            default "podman exec -i xq-ora sqlplus -s -L xq/xqpass@FREEPDB1")
    \\
    \\Start the server first:
    \\  podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
    \\  podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
    \\  podman run -d --name xq-mssql -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD=Xq_Passw0rd! \\
    \\    -e MSSQL_MEMORY_LIMIT_MB=2048 mcr.microsoft.com/azure-sql-edge:latest
    \\  podman cp sqlcmd xq-mssql:/tmp/sqlcmd   (go-sqlcmd, linux-arm64: the image has none)
    \\  podman run -d --name xq-ora -e ORACLE_PASSWORD=xqpass -e APP_USER=xq \\
    \\    -e APP_USER_PASSWORD=xqpass gvenzl/oracle-free:23-slim-faststart
    \\
;

const Dialect = struct {
    /// "pg-diff", for the last line.
    tag: []const u8,
    server: []const u8,
    cases: []const u8,
    env: []const u8,
    default_client: []const u8,
    container: []const u8,
    /// Arguments after the client command.
    client_args: []const []const u8,
    /// Sent to the server before each case.
    prelude: []const u8,
    /// Sent to xqlite before each case.
    xq_prelude: []const u8,
    norm_server: *const fn (Allocator, []const u8) Allocator.Error![]u8,
    norm_xq: *const fn (Allocator, []const u8) Allocator.Error![]u8,
    /// Whether each worker gets a database of its own (else all share
    /// the prelude's database and the server runs one case at a time).
    databases: bool,
};

const pg: Dialect = .{
    .tag = "pg-diff",
    .server = "PostgreSQL",
    .cases = "tools/dialect/pg-cases.txt",
    .env = "PG_PSQL",
    .default_client = "podman exec -i xq-pg psql -U postgres",
    .container = "podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine",
    .client_args = &.{ "-q", "-A", "-F|" },
    // Also drops the schemas an earlier case of the worker created.
    .prelude = "SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;" ++
        " DO $$DECLARE r record; BEGIN FOR r IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' AND nspname NOT IN ('public', 'information_schema')" ++
        " LOOP EXECUTE 'DROP SCHEMA ' || quote_ident(r.nspname) || ' CASCADE'; END LOOP; END$$;\n",
    .xq_prelude = ".dialect postgres\n.headers on\n",
    .norm_server = normPg,
    .norm_xq = normXqPg,
    .databases = true,
};

const maria: Dialect = .{
    .tag = "maria-diff",
    .server = "MariaDB",
    .cases = "tools/dialect/maria-cases.txt",
    .env = "MARIA_CLIENT",
    .default_client = "podman exec -i xq-maria mariadb -uroot",
    .container = "podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11",
    .client_args = &.{ "--batch", "--raw", "--force", "--unbuffered" },
    // Every database but the system ones goes (main, and those cases made).
    .prelude = "DELIMITER //\nBEGIN NOT ATOMIC FOR r IN (SELECT SCHEMA_NAME AS n FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')) DO EXECUTE IMMEDIATE CONCAT('DROP DATABASE `', r.n, '`'); END FOR; END//\nDELIMITER ;\n" ++
        "CREATE DATABASE main CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; USE main; SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;\n",
    .xq_prelude = ".dialect mariadb\n.headers on\n.nullvalue NULL\n",
    .norm_server = normMaria,
    .norm_xq = normXqMaria,
    .databases = false,
};

/// SQL Server: Azure SQL Edge (the SQL Server engine, built for arm64 as
/// well) with go-sqlcmd copied in. Every case runs in a new database
/// main, one case at a time.
const mssql: Dialect = .{
    .tag = "mssql-diff",
    .server = "SQL Server",
    .cases = "tools/dialect/mssql-cases.txt",
    .env = "MSSQL_CLIENT",
    .default_client = "podman exec -i xq-mssql /tmp/sqlcmd -S localhost -U sa -P Xq_Passw0rd! -C",
    .container = "podman run -d --name xq-mssql -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD=Xq_Passw0rd! -e MSSQL_MEMORY_LIMIT_MB=2048 mcr.microsoft.com/azure-sql-edge:latest; podman cp sqlcmd xq-mssql:/tmp/sqlcmd",
    .client_args = &.{ "-W", "-s", "|", "-i", "/dev/stdin" },
    .prelude = "SET NOCOUNT ON;\nUSE master;\nDROP DATABASE IF EXISTS main;\nCREATE DATABASE main;\nGO\nUSE main;\nSET NOCOUNT ON;\nGO\n",
    .xq_prelude = ".dialect mssql\n.headers on\n.nullvalue NULL\n",
    .norm_server = normMssql,
    .norm_xq = normXqMssql,
    .databases = false,
};

const ora: Dialect = .{
    .tag = "oracle-diff",
    .server = "Oracle",
    .cases = "tools/dialect/oracle-cases.txt",
    .env = "ORA_SQLPLUS",
    .default_client = "podman exec -i xq-ora sqlplus -s -L xq/xqpass@FREEPDB1",
    .container = "podman run -d --name xq-ora -e ORACLE_PASSWORD=xqpass -e APP_USER=xq -e APP_USER_PASSWORD=xqpass gvenzl/oracle-free:23-slim-faststart",
    .client_args = &.{},
    .prelude = ora_prelude,
    .xq_prelude = ".dialect oracle\n.headers on\n.nullvalue NULL\n",
    .norm_server = normOra,
    .norm_xq = normXqOra,
    .databases = false,
};

/// SQL*Plus settings (unaligned rows with a header, NULL as NULL, no
/// feedback, blank lines kept in statements, no & substitution), the
/// dialect's date formats, and an empty schema. As SYSTEM (the password
/// of the container command), XQ gets DBA, to create and drop the users
/// of the schema cases (named XQ_...), and the users an earlier case
/// left are dropped.
const ora_prelude =
    \\SET MARKUP CSV ON DELIMITER | QUOTE OFF
    \\SET FEEDBACK OFF
    \\SET NULL NULL
    \\SET SQLBLANKLINES ON
    \\SET DEFINE OFF
    \\SET LINESIZE 32767
    \\SET NUMWIDTH 20
    \\CONNECT system/xqpass@FREEPDB1
    \\GRANT DBA TO xq;
    \\BEGIN
    \\  FOR r IN (SELECT username FROM dba_users WHERE username LIKE 'XQ\_%' ESCAPE '\') LOOP
    \\    EXECUTE IMMEDIATE 'DROP USER "' || r.username || '" CASCADE';
    \\  END LOOP;
    \\END;
    \\/
    \\CONNECT xq/xqpass@FREEPDB1
    \\ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
    \\ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF6';
    \\BEGIN
    \\  FOR r IN (SELECT object_name, object_type FROM user_objects
    \\            WHERE object_type IN ('TABLE', 'VIEW', 'SEQUENCE') AND object_name NOT LIKE 'ISEQ$$%') LOOP
    \\    BEGIN
    \\      EXECUTE IMMEDIATE 'DROP ' || r.object_type || ' "' || r.object_name || '"'
    \\        || CASE r.object_type WHEN 'TABLE' THEN ' CASCADE CONSTRAINTS PURGE' END;
    \\    EXCEPTION WHEN OTHERS THEN NULL;
    \\    END;
    \\  END LOOP;
    \\END;
    \\/
    \\
;

/// The most databases a run makes: more workers gain nothing, and each
/// CREATE DATABASE costs a copy of template1.
const max_databases = 8;

const Case = struct {
    name: []const u8,
    sql: []const u8,
    /// The normalized outputs, set by the check.
    server: []const u8 = "",
    xq: []const u8 = "",
};

/// The server's databases, one per worker; a case takes a free one. With
/// one database, the cases take turns.
const Slots = struct {
    names: [][]const u8,
    mutex: Io.Mutex = .init,
    freed: Io.Condition = .init,
    free: std.ArrayList(usize),

    fn acquire(s: *Slots, io: Io) usize {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        while (true) {
            if (s.free.pop()) |i| return i;
            s.freed.waitUncancelable(io, &s.mutex);
        }
    }

    fn release(s: *Slots, io: Io, i: usize) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.free.appendAssumeCapacity(i);
        s.freed.signal(io);
    }
};

const Ctx = struct {
    d: *const Dialect,
    client: []const []const u8,
    slots: *Slots,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (args.len < 1 or args.len > 2) return usageError(out);
    const d: *const Dialect = if (std.mem.eql(u8, args[0], "pg") or std.mem.eql(u8, args[0], "postgres"))
        &pg
    else if (std.mem.eql(u8, args[0], "mariadb") or std.mem.eql(u8, args[0], "maria"))
        &maria
    else if (std.mem.eql(u8, args[0], "mssql") or std.mem.eql(u8, args[0], "sqlserver") or std.mem.eql(u8, args[0], "tsql"))
        &mssql
    else if (std.mem.eql(u8, args[0], "oracle") or std.mem.eql(u8, args[0], "ora"))
        &ora
    else
        return usageError(out);
    const cases_path = if (args.len == 2) args[1] else try std.fs.path.join(arena, &.{ cfg.root, d.cases });
    const text = Io.Dir.cwd().readFileAlloc(io, cases_path, arena, .unlimited) catch |err| {
        try out.print("xqt dialect-diff: cannot read {s}: {t}\n", .{ cases_path, err });
        return 2;
    };
    const cases = try parseCases(arena, text);

    // The client command, split as the shell splits an unquoted variable.
    const client_text = cfg.environ.get(d.env) orelse d.default_client;
    var client: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, client_text, " \t\n");
    while (words.next()) |w| try client.append(arena, w);
    try client.appendSlice(arena, d.client_args);

    // Is the server there?
    const probe = runMerged(arena, io, client.items, "SELECT 1;\n") catch |err|
        Merged{ .ok = false, .out = try std.fmt.allocPrint(arena, "cannot run {s}: {t}", .{ client.items[0], err }) };
    if (!probe.ok) {
        try out.print(
            \\xqt dialect-diff: cannot reach the {s} server with "{s}" (${s}):
            \\{s}
            \\Start it with
            \\  {s}
            \\or set ${s} to a client command that reaches one.
            \\
        , .{ d.server, client_text, d.env, std.mem.trimEnd(u8, probe.out, "\n"), d.container, d.env });
        try out.flush();
        return 1;
    }

    const n_slots = if (d.databases) @max(1, @min(cfg.jobs, cases.len, max_databases)) else 1;
    var slots: Slots = .{
        .names = try arena.alloc([]const u8, n_slots),
        .free = try .initCapacity(arena, n_slots),
    };
    for (0..n_slots) |i| slots.free.appendAssumeCapacity(n_slots - 1 - i);
    if (d.databases) {
        var make: Io.Writer.Allocating = .init(arena);
        var drop: Io.Writer.Allocating = .init(arena);
        for (slots.names, 0..) |*name, i| {
            name.* = try std.fmt.allocPrint(arena, "xqt_dialect_{d}", .{i});
            try make.writer.print("DROP DATABASE IF EXISTS {s};\nCREATE DATABASE {s};\n", .{ name.*, name.* });
            try drop.writer.print("DROP DATABASE IF EXISTS {s};\n", .{name.*});
        }
        const r = try runMerged(arena, io, client.items, make.written());
        if (!r.ok) {
            try out.print("xqt dialect-diff: cannot make the databases of the workers:\n{s}", .{r.out});
            return 1;
        }
        defer _ = runMerged(arena, io, client.items, drop.written()) catch {};
        return runCases(gpa, io, cfg, out, d, client.items, &slots, cases);
    }
    return runCases(gpa, io, cfg, out, d, client.items, &slots, cases);
}

fn runCases(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, d: *const Dialect, client: []const []const u8, slots: *Slots, cases: []Case) !u8 {
    var ctx: Ctx = .{ .d = d, .client = client, .slots = slots };
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "dialect-diff", .show = .failures });
    defer suite.deinit();
    for (cases) |*cs| try suite.add(cs.name, runCase, .{ &ctx, cs });
    suite.run();

    var fail: usize = 0;
    var errors: usize = 0;
    var dw: Io.Writer.Allocating = .init(gpa);
    defer dw.deinit();
    for (cases, 0..) |cs, i| {
        if (suite.outcome(i).status == .failed) {
            errors += 1;
            continue;
        }
        if (std.mem.eql(u8, cs.server, cs.xq)) continue;
        fail += 1;
        try out.print("DIFF {s}\n", .{cs.name});
        dw.clearRetainingCapacity();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try xqt.diff.write(&dw.writer, scratch.allocator(), d.server, "xqlite", cs.server, cs.xq, .{});
        var diff_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, dw.written(), "\n"), '\n');
        var n: usize = 0;
        while (diff_lines.next()) |line| : (n += 1) {
            if (n == 40) break;
            try out.print("  {s}\n", .{line});
        }
    }
    try out.print("{s}: {d}/{d} cases agree", .{ d.tag, cases.len - fail - errors, cases.len });
    if (errors > 0) try out.print(" ({d} could not run)", .{errors});
    try out.writeAll("\n");
    try out.flush();
    return @intFromBool(fail + errors > 0);
}

fn runCase(c: *Check, ctx: *Ctx, cs: *Case) !void {
    const d = ctx.d;
    const server_in = try std.mem.concat(c.arena, u8, &.{ d.prelude, cs.sql });
    const server_raw = blk: {
        const slot = ctx.slots.acquire(c.io);
        defer ctx.slots.release(c.io, slot);
        const argv = if (d.databases)
            try std.mem.concat(c.arena, []const u8, &.{ ctx.client, &.{ "-d", ctx.slots.names[slot] } })
        else
            ctx.client;
        break :blk (try runMerged(c.arena, c.io, argv, server_in)).out;
    };
    const xq_in = try std.mem.concat(c.arena, u8, &.{ d.xq_prelude, cs.sql });
    const xq_raw = (try runMerged(c.arena, c.io, &.{ c.cfg.xq, "sql" }, xq_in)).out;
    cs.server = try d.norm_server(c.keep, server_raw);
    cs.xq = try d.norm_xq(c.keep, xq_raw);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

/// The cases of a cases file: a line "-- case: NAME" starts one, and the
/// lines up to the next are its SQL (each ended by a newline). Lines
/// before the first case are left out.
fn parseCases(arena: Allocator, text: []const u8) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    var sql: std.ArrayList(u8) = .empty;
    var it = lines(text);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "-- case:")) {
            if (cases.items.len > 0) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
            const name = std.mem.trimStart(u8, line["-- case:".len..], " ");
            try cases.append(arena, .{ .name = name, .sql = "" });
        } else if (cases.items.len > 0) {
            try sql.appendSlice(arena, line);
            try sql.append(arena, '\n');
        }
    }
    if (cases.items.len > 0) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
    return cases.items;
}

/// The lines of `text` as awk reads records: a last line without a
/// newline is a line, a final newline does not start one.
fn lines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    if (text.len == 0) it.index = null;
    return it;
}

// ---------------------------------------------------------------- normalizing

/// psql prints a header and "(N rows)" for every result: keep the header
/// only above rows, as the shell does. Errors become "ERROR: message".
/// Booleans print as t/f, which the dialect returns as integers 1/0.
fn normPg(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var skip = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (pgError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            continue;
        }
        if (startsWithLineN(line) or startsWithAny(line, &.{ "DETAIL:", "HINT:", "CONTEXT:", "NOTICE:", "psql:" })) {
            skip = true;
            continue;
        }
        if (skip and std.mem.startsWith(u8, line, " ")) continue;
        skip = false;
        if (rowCount(line)) |n| {
            if (n > 0) try out.appendSlice(gpa, buf.items);
            buf.clearRetainingCapacity();
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try buf.append(gpa, '|');
            first = false;
            try buf.appendSlice(gpa, if (std.mem.eql(u8, f, "t")) "1" else if (std.mem.eql(u8, f, "f")) "0" else f);
        }
        try buf.append(gpa, '\n');
    }
    try out.appendSlice(gpa, buf.items);
    return out.toOwnedSlice(gpa);
}

/// /^(psql:[^ ]* )?ERROR: +/: the message after it.
fn pgError(line: []const u8) ?[]const u8 {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "psql:")) {
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            if (std.mem.startsWith(u8, rest[sp + 1 ..], "ERROR: ")) rest = rest[sp + 1 ..];
        }
    }
    if (!std.mem.startsWith(u8, rest, "ERROR: ")) return null;
    return std.mem.trimStart(u8, rest["ERROR:".len..], " ");
}

/// /^LINE [0-9]+:/
fn startsWithLineN(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "LINE ")) return false;
    var i: usize = 5;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 5 and i < line.len and line[i] == ':';
}

fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

/// /^\([0-9]+ rows?\)$/: N.
fn rowCount(line: []const u8) ?u64 {
    if (line.len < 2 or line[0] != '(' or line[line.len - 1] != ')') return null;
    const inner = line[1 .. line.len - 1];
    const sp = std.mem.indexOfScalar(u8, inner, ' ') orelse return null;
    const word = inner[sp + 1 ..];
    if (!std.mem.eql(u8, word, "row") and !std.mem.eql(u8, word, "rows")) return null;
    const digits = inner[0..sp];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseUnsigned(u64, digits, 10) catch std.math.maxInt(u64);
}

/// xqlite's error lines become "ERROR: message", without the lines of
/// context under them.
fn normXq(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var skip = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (xqError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            skip = true;
            continue;
        }
        if (skip and std.mem.startsWith(u8, line, "  ")) continue;
        skip = false;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// /^(Parse error|Error|Runtime error) near line [0-9]+: /: what follows
/// the first ": ".
fn xqError(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "Parse error", "Error", "Runtime error" }) |p| {
        if (!std.mem.startsWith(u8, line, p)) continue;
        const rest = line[p.len..];
        if (!std.mem.startsWith(u8, rest, " near line ")) continue;
        var i: usize = " near line ".len;
        const start = i;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == start or !std.mem.startsWith(u8, rest[i..], ": ")) continue;
        // sub(/^[^:]*: /, ...): the prefix has no colon before ": ".
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        return line[colon + 2 ..];
    }
    return null;
}

/// The shell shows a boolean column as psql does (t/f) and a boolean
/// expression as 1/0: t/f become 1/0, as in normPg().
fn normXqPg(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const t = try normXq(gpa, text);
    defer gpa.free(t);
    var out: std.ArrayList(u8) = .empty;
    var it = lines(t);
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try out.append(gpa, '|');
            first = false;
            try out.appendSlice(gpa, if (std.mem.eql(u8, f, "t")) "1" else if (std.mem.eql(u8, f, "f")) "0" else f);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn normXqMaria(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const t = try normXq(gpa, text);
    defer gpa.free(t);
    return normNum(gpa, t);
}

/// The client prints tab-separated rows with a header line per result
/// (none for an empty one) and, with --force, the statement that failed
/// between dashed lines; errors become "ERROR: message".
fn normMaria(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var echoed = false;
    var blank = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "--------------")) {
            echoed = !echoed;
            if (!echoed) blank = true;
            continue;
        }
        if (echoed) continue;
        if (blank and line.len == 0) {
            blank = false;
            continue;
        }
        blank = false;
        if (mariaError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            continue;
        }
        for (line) |ch| try out.append(gpa, if (ch == '\t') '|' else ch);
        try out.append(gpa, '\n');
    }
    return normNum(gpa, out.items);
}

/// /^ERROR [0-9]+ \([0-9A-Z]+\)( at line [0-9]+)?: /: what follows.
fn mariaError(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "ERROR ")) return null;
    var i: usize = "ERROR ".len;
    i = digitsEnd(line, i) orelse return null;
    if (!std.mem.startsWith(u8, line[i..], " (")) return null;
    i += 2;
    const start = i;
    while (i < line.len and (std.ascii.isDigit(line[i]) or std.ascii.isUpper(line[i]))) i += 1;
    if (i == start or i >= line.len or line[i] != ')') return null;
    i += 1;
    if (std.mem.startsWith(u8, line[i..], " at line ")) {
        if (digitsEnd(line, i + " at line ".len)) |j| {
            if (std.mem.startsWith(u8, line[j..], ": ")) return line[j + 2 ..];
        }
    }
    if (std.mem.startsWith(u8, line[i..], ": ")) return line[i + 2 ..];
    return null;
}

/// The end of the digits at `i`, null if there are none.
fn digitsEnd(s: []const u8, i: usize) ?usize {
    var j = i;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    return if (j == i) null else j;
}

/// Fields (split on '|') with a fraction lose their trailing zeros, and
/// then a trailing dot: MariaDB's DECIMAL prints 3.5000, the dialect's
/// REAL 3.5.
fn normNum(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = lines(text);
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try out.append(gpa, '|');
            first = false;
            try out.appendSlice(gpa, if (isFraction(f)) trimFraction(f) else f);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// /^-?[0-9]+\.[0-9]+$/
fn isFraction(f: []const u8) bool {
    var i: usize = @intFromBool(std.mem.startsWith(u8, f, "-"));
    const int_end = digitsEnd(f, i) orelse return false;
    if (int_end >= f.len or f[int_end] != '.') return false;
    i = digitsEnd(f, int_end + 1) orelse return false;
    return i == f.len;
}

fn trimFraction(f: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, f, "0");
    return if (std.mem.endsWith(u8, t, ".")) t[0 .. t.len - 1] else t;
}

/// sqlcmd (-W -s '|') prints a header line, a line of dashes and the
/// rows of each result (the header also for an empty one), blank lines
/// between results, and errors as "Msg N, Level L, State S, ..." with the
/// message on the next line, which becomes "ERROR: message". The fields
/// are trimmed (an unnamed column's header is blank) and their numbers
/// lose the trailing zeros of a fraction, as the dialect's REAL prints
/// none (DECIMAL(10,2) is 2.50 in SQL Server, 2.5 in xqlite). sqlcmd
/// cuts NULL to the column's width (NU for a varchar(2)) and prints
/// binary strings in hex: the cases avoid both.
fn normMssql(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(gpa);
    var it = lines(text);
    while (it.next()) |line| try all.append(gpa, std.mem.trimEnd(u8, line, "\r"));
    const ls = all.items;
    var header: ?[]const u8 = null;
    var i: usize = 0;
    while (i < ls.len) : (i += 1) {
        const line = ls[i];
        if (std.mem.startsWith(u8, line, "Msg ") and std.mem.indexOf(u8, line, ", Level ") != null) {
            if (i + 1 < ls.len) {
                try out.appendSlice(gpa, "ERROR: ");
                try out.appendSlice(gpa, ls[i + 1]);
                try out.append(gpa, '\n');
                i += 1;
            }
            header = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Warning: Null value is eliminated")) continue;
        if (std.mem.startsWith(u8, line, "Changed database context to ")) continue;
        if (std.mem.eql(u8, line, "The statement has been terminated.")) continue;
        if (rowsAffected(line)) continue;
        if (line.len == 0) {
            header = null;
            continue;
        }
        if (i + 1 < ls.len and isDashes(ls[i + 1])) {
            header = line;
            i += 1;
            continue;
        }
        if (header) |h| {
            try appendFields(gpa, &out, h);
            header = null;
        }
        try appendFields(gpa, &out, line);
    }
    return normNum(gpa, out.items);
}

/// /^\([0-9]+ rows? affected\)$/
fn rowsAffected(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "(") or !std.mem.endsWith(u8, line, " affected)")) return false;
    return std.mem.indexOf(u8, line, " row") != null;
}

/// A line of dashes (and separators) under a header.
fn isDashes(line: []const u8) bool {
    if (line.len == 0) return false;
    var dash = false;
    for (line) |ch| switch (ch) {
        '-' => dash = true,
        '|', ' ' => {},
        else => return false,
    };
    return dash;
}

/// The fields of a line, trimmed, joined with '|'.
fn appendFields(gpa: Allocator, out: *std.ArrayList(u8), line: []const u8) Allocator.Error!void {
    var fields = std.mem.splitScalar(u8, line, '|');
    var first = true;
    while (fields.next()) |f| {
        if (!first) try out.append(gpa, '|');
        first = false;
        try out.appendSlice(gpa, std.mem.trim(u8, f, " "));
    }
    try out.append(gpa, '\n');
}

fn normXqMssql(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const t = try normXq(gpa, text);
    defer gpa.free(t);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var it = lines(t);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ERROR: ")) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        } else try appendFields(gpa, &out, line);
    }
    return normNum(gpa, out.items);
}

test normMssql {
    const a = std.testing.allocator;
    const got = try normMssql(a, " |ab\n-|--\n2|3.50\n\nx\n-\n\nMsg 208, Level 16, State 1, Server s, Line 2\nInvalid object name 'nope'.\n(1 row affected)\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("|ab\n2|3.5\nERROR: Invalid object name 'nope'.\n", got);
}

/// SQL*Plus prints an error as the line of the statement, a `*` under
/// the place, "ERROR at line N:", the ORA- lines and a "Help:" line:
/// they become "ERROR: ORA-nnnnn" (the code of the first ORA- line).
/// Booleans print as TRUE/FALSE, which the dialect returns as 1/0, and
/// numbers without a leading zero (.5), which the dialect writes 0.5.
fn normOra(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // The start of each line in `out`, to take back the echoed statement.
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    var in_error = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ERROR at line") or std.mem.eql(u8, line, "ERROR:")) {
            // Take back the `*` line and the statement line above it.
            if (starts.items.len > 0) {
                const last = starts.items[starts.items.len - 1];
                const marker = std.mem.trim(u8, out.items[last..], " \n");
                if (std.mem.eql(u8, marker, "*")) {
                    out.shrinkRetainingCapacity(last);
                    starts.items.len -= 1;
                    if (starts.items.len > 0) {
                        out.shrinkRetainingCapacity(starts.items[starts.items.len - 1]);
                        starts.items.len -= 1;
                    }
                }
            }
            in_error = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "ORA-") or std.mem.startsWith(u8, line, "SP2-")) {
            const code_end = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            try starts.append(gpa, out.items.len);
            try out.print(gpa, "ERROR: {s}\n", .{line[0..code_end]});
            // The rest of the message.
            while (it.peek()) |next| {
                if (next.len == 0 or std.mem.startsWith(u8, next, "Help: ")) break;
                _ = it.next();
            }
            in_error = false;
            continue;
        }
        if (in_error) continue;
        if (std.mem.startsWith(u8, line, "Help: ") or line.len == 0) continue;
        try starts.append(gpa, out.items.len);
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try out.append(gpa, '|');
            first = false;
            if (std.mem.eql(u8, f, "TRUE")) {
                try out.append(gpa, '1');
            } else if (std.mem.eql(u8, f, "FALSE")) {
                try out.append(gpa, '0');
            } else if (f.len > 1 and f[0] == '.' and std.ascii.isDigit(f[1])) {
                try out.print(gpa, "0{s}", .{f});
            } else if (f.len > 2 and f[0] == '-' and f[1] == '.' and std.ascii.isDigit(f[2])) {
                try out.print(gpa, "-0{s}", .{f[1..]});
            } else try out.appendSlice(gpa, f);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// xqlite's errors as "ERROR: ORA-nnnnn": the dialect's own carry the
/// code; SQLite's constraint failures get the code Oracle gives them.
/// Reals without a fraction lose their ".0" (Oracle's NUMBER has none).
/// A BOOLEAN column shows TRUE/FALSE (an expression 1/0): 1/0, as in
/// normOra().
fn normXqOra(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const t = try normXq(gpa, text);
    defer gpa.free(t);
    var out: std.ArrayList(u8) = .empty;
    var it = lines(t);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "ERROR: ")) {
            const msg = line["ERROR: ".len..];
            const check = "CHECK constraint failed: ";
            const code: []const u8 = if (std.mem.startsWith(u8, msg, "ORA-"))
                msg[0 .. std.mem.indexOfScalar(u8, msg, ':') orelse msg.len]
            else if (std.mem.startsWith(u8, msg, check ++ "ORA-") and msg.len >= check.len + 9)
                msg[check.len..][0..9]
            else if (std.mem.startsWith(u8, msg, "UNIQUE constraint failed"))
                "ORA-00001"
            else if (std.mem.startsWith(u8, msg, "NOT NULL constraint failed"))
                "ORA-01400"
            else if (std.mem.startsWith(u8, msg, "CHECK constraint failed"))
                "ORA-02290"
            else if (std.mem.startsWith(u8, msg, "FOREIGN KEY constraint failed"))
                "ORA-02291"
            else if (std.mem.startsWith(u8, msg, "no such savepoint"))
                "ORA-01086"
            else
                msg;
            try out.print(gpa, "ERROR: {s}\n", .{code});
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try out.append(gpa, '|');
            first = false;
            if (std.mem.eql(u8, f, "TRUE") or std.mem.eql(u8, f, "FALSE")) {
                try out.append(gpa, if (f[0] == 'T') '1' else '0');
            } else if (f.len > 1 and f[0] == '.' and std.ascii.isDigit(f[1])) {
                // TO_CHAR writes Oracle's .5
                try out.print(gpa, "0{s}", .{f});
            } else if (f.len > 2 and f[0] == '-' and f[1] == '.' and std.ascii.isDigit(f[2])) {
                try out.print(gpa, "-0{s}", .{f[1..]});
            } else try out.appendSlice(gpa, if (std.mem.endsWith(u8, f, ".0") and isFraction(f)) f[0 .. f.len - 2] else f);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- processes

pub const Merged = struct {
    /// It exited with status 0.
    ok: bool,
    /// Standard output and standard error, as one pipe got them (`2>&1`).
    out: []u8,
};

/// Runs `argv` with `input` on its standard input and its standard output
/// and error on one pipe, as `2>&1` in a shell pipeline: the order in
/// which the program wrote them is kept.
pub fn runMerged(gpa: Allocator, io: Io, argv: []const []const u8, input: []const u8) !Merged {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const r: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const w: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer r.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .{ .file = w },
        .stderr = .{ .file = w },
    }) catch |err| {
        w.close(io);
        return err;
    };
    w.close(io);
    defer if (child.id != null) xqt.proc.kill(io, &child);
    const stdin = child.stdin.?;
    child.stdin = null;
    const feeder = try std.Thread.spawn(.{}, feed, .{ io, stdin, input });
    defer feeder.join();
    var buf: [4096]u8 = undefined;
    var reader = r.readerStreaming(io, &buf);
    const out = reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
    const term = try child.wait(io);
    return .{ .ok = term == .exited and term.exited == 0, .out = out };
}

fn feed(io: Io, file: Io.File, input: []const u8) void {
    defer file.close(io);
    file.writeStreamingAll(io, input) catch {};
}

test normPg {
    const a = std.testing.allocator;
    const got = try normPg(a,
        \\a|b
        \\t|x
        \\(1 row)
        \\c
        \\(0 rows)
        \\psql:<stdin>:3: ERROR:  relation "x" does not exist
        \\LINE 1: SELECT * FROM x;
        \\                      ^
        \\f
        \\
    );
    defer a.free(got);
    try std.testing.expectEqualStrings("a|b\n1|x\nERROR: relation \"x\" does not exist\n0\n", got);
}

test normMaria {
    const a = std.testing.allocator;
    const got = try normMaria(a, "a\tb\n3.5000\t10.0\n--------------\nSELECT x\n--------------\n\nERROR 1146 (42S02) at line 3: Table 'main.x' doesn't exist\n-1.50\t1.0x\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("a|b\n3.5|10\nERROR: Table 'main.x' doesn't exist\n-1.5|1.0x\n", got);
}

test normXq {
    const a = std.testing.allocator;
    const got = try normXqMaria(a, "x\nParse error near line 2: no such table: t\n  SELECT * FROM t;\n         ^--- error here\n2.50\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("x\nERROR: no such table: t\n2.5\n", got);
}

test normOra {
    const a = std.testing.allocator;
    const got = try normOra(a, "A|B\n.5|TRUE\nINSERT INTO t VALUES (1)\n                      *\nERROR at line 1:\nORA-00001: unique constraint (XQ.SYS_C0) violated\nHelp: https://x\n\n\n-.25|NULL\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("A|B\n0.5|1\nERROR: ORA-00001\n-0.25|NULL\n", got);
    const xq = try normXqOra(a, "A\n2.0\nError near line 3: UNIQUE constraint failed: T.A\nError near line 4: ORA-01722: invalid number\n");
    defer a.free(xq);
    try std.testing.expectEqualStrings("A\n2\nERROR: ORA-00001\nERROR: ORA-01722\n", xq);
}

test parseCases {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = try parseCases(arena.allocator(), "-- header\n\n-- case: one\nSELECT 1;\n\n-- case:two\nSELECT 2;");
    try std.testing.expectEqual(2, cases.len);
    try std.testing.expectEqualStrings("one", cases[0].name);
    try std.testing.expectEqualStrings("SELECT 1;\n\n", cases[0].sql);
    try std.testing.expectEqualStrings("two", cases[1].name);
    try std.testing.expectEqualStrings("SELECT 2;\n", cases[1].sql);
}
