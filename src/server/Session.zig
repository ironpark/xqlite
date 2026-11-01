//! One client's connection to the database, in the client's dialect.
//!
//! A protocol hands the session the SQL its client sent (a query string,
//! a batch) and receives the results as protocol-neutral events, which it
//! encodes in its own messages:
//!
//!     columns([]const Column)   before the rows of a statement that has
//!                               result columns (even when it has no rows)
//!     row(*Row)                 each row
//!     complete(Complete)        each statement that ran
//!     failed(Failure)           the statement that failed; the script
//!                               stops there
//!
//! The session also keeps what the protocols report between statements:
//! whether a transaction is open, and whether it failed (PostgreSQL's
//! "aborted transaction block", Options.abort_failed_transactions).

const std = @import("std");
const xqlite = @import("xqlite");
const types = @import("types.zig");
const errors = @import("errors.zig");
const command = @import("command.zig");

const Allocator = std.mem.Allocator;
const Session = @This();

db: xqlite.Db,
abort_failed_transactions: bool,
/// A statement failed inside the open transaction (only with
/// abort_failed_transactions; cleared when the transaction ends).
aborted: bool = false,
/// The columns of the statement being described.
scratch: std.heap.ArenaAllocator,
/// The declared types of the table columns described so far.
type_cache: TypeCache,

pub const Options = struct {
    /// How to open the database; `dialect` is the client's.
    open: xqlite.OpenOptions = .{},
    /// PostgreSQL's rule: once a statement fails inside a transaction,
    /// every statement but ROLLBACK fails (in_failed_transaction) until
    /// the transaction ends, and COMMIT rolls it back. Without it, a
    /// failed statement undoes only itself, as in SQLite, MySQL and SQL
    /// Server.
    abort_failed_transactions: bool = false,
};

pub const Status = enum {
    /// Not in a transaction (autocommit).
    idle,
    in_transaction,
    /// In a transaction where a statement failed
    /// (abort_failed_transactions).
    aborted,
};

/// A result column.
pub const Column = struct {
    name: []const u8,
    type: types.Type,
    /// The declared type (Stmt.columnTypeAlloc()); null for an
    /// expression.
    type_name: ?[]const u8,
    /// The table column it reads; null for an expression.
    origin: ?xqlite.Origin,
};

/// The current row of a statement. Values are borrowed: valid until the
/// sink returns.
pub const Row = struct {
    stmt: *xqlite.Stmt,

    pub fn len(r: *const Row) usize {
        return r.stmt.columnCount();
    }

    pub fn value(r: *Row, i: usize) xqlite.Error!xqlite.Value {
        return r.stmt.column(xqlite.Value, i);
    }
};

pub const Complete = struct {
    command: command.Command,
    /// The rows the statement returned.
    rows: u64,
    /// The rows it inserted, updated or deleted (Db.changes()); 0 for a
    /// statement that changes none (Stmt.countsChanges()).
    changes: u64,
    /// The rowid of the last row inserted on the connection.
    last_insert_id: i64,
};

pub const Failure = struct {
    /// The SQLSTATE (errors.sqlstate()).
    sqlstate: [5]u8,
    /// The number the dialect gives the error (MySQL's 1146, SQL Server's
    /// 208, Oracle's 942), if it has one.
    number: ?u32,
    /// The engine's extended code (`.error` for errors of the session).
    code: xqlite.ResultCode,
    /// Valid until the sink returns.
    message: []const u8,
    /// The byte offset in the script of the token at fault, if known.
    offset: ?usize,
    /// The command of the statement that failed (what the text says).
    command: command.Command,
};

/// Opened with OpenOptions.column_metadata, as every result is described.
pub fn open(gpa: Allocator, io: std.Io, path: []const u8, options: Options) xqlite.Error!Session {
    var o = options.open;
    o.column_metadata = true;
    return .{
        .db = try xqlite.Db.open(gpa, io, path, o),
        .abort_failed_transactions = options.abort_failed_transactions,
        .scratch = .init(gpa),
        .type_cache = .init(gpa),
    };
}

pub fn close(s: *Session) void {
    s.type_cache.deinit();
    s.scratch.deinit();
    s.db.close();
    s.* = undefined;
}

pub fn dialect(s: *const Session) xqlite.Dialect {
    return s.db.dialect();
}

pub fn status(s: *const Session) Status {
    if (s.aborted) return .aborted;
    return if (s.db.inTransaction()) .in_transaction else .idle;
}

/// Stop the statement running, from any thread (Db.interrupt()): it fails
/// with query_canceled.
pub fn cancel(s: *const Session) void {
    s.db.interrupt();
}

/// Run the script `sql`, one statement at a time, reporting each to
/// `sink` (see the top of the file). A statement that fails ends the
/// script, reported to sink.failed(): it is not an error of run(). The
/// errors are the sink's (a client gone) and OutOfMemory.
pub fn run(s: *Session, sql: []const u8, sink: anytype) !void {
    var it = s.db.script(sql) catch return error.OutOfMemory;
    defer it.deinit();
    while (true) {
        const at = sql.len - it.rest.len;
        const cmd = command.classify(it.rest);
        const verdict = s.admit(cmd);
        if (verdict == .refuse) return sink.failed(.{
            .sqlstate = errors.in_failed_transaction.*,
            .number = null,
            .code = .@"error",
            .message = "current transaction is aborted, commands ignored until end of transaction block",
            .offset = null,
            .command = cmd,
        });
        var stmt = (it.next() catch return s.fail(sink, at, cmd)) orelse return;
        defer stmt.finalize();
        if (verdict == .roll_back) {
            // COMMIT of a failed transaction rolls it back.
            s.db.rollback() catch return s.fail(sink, at, cmd);
            s.aborted = false;
            try sink.complete(.{ .command = .{ .verb = .rollback }, .rows = 0, .changes = 0, .last_insert_id = s.db.lastInsertRowid() });
            continue;
        }
        if (!try s.runOne(&stmt, cmd, sink)) return s.fail(sink, at, cmd);
        // A transaction that ended, or a ROLLBACK TO a savepoint, ends the
        // failure.
        if (!s.db.inTransaction() or cmd.verb == .rollback) s.aborted = false;
    }
}

/// Whether a statement may run in the session's state, decided before
/// compiling it (PostgreSQL does no analysis in a failed transaction):
/// in a failed transaction, only ROLLBACK runs, and COMMIT rolls back.
/// Also for a protocol's other paths (an extended query's Execute).
pub fn admit(s: *const Session, cmd: command.Command) enum { run, refuse, roll_back } {
    if (!s.aborted) return .run;
    return switch (cmd.verb) {
        .rollback => .run,
        .commit => .roll_back,
        else => .refuse,
    };
}

/// Run one statement: false if it failed (its error in the connection).
fn runOne(s: *Session, stmt: *xqlite.Stmt, cmd: command.Command, sink: anytype) !bool {
    var rows: u64 = 0;
    const has_row = stmt.step() catch return false;
    if (stmt.columnCount() > 0) {
        defer _ = s.scratch.reset(.retain_capacity);
        try sink.columns(try s.describe(stmt, has_row));
    }
    if (has_row) {
        var row: Row = .{ .stmt = stmt };
        while (true) {
            try sink.row(&row);
            rows += 1;
            if (!(stmt.step() catch return false)) break;
        }
    }
    try sink.complete(.{
        .command = cmd,
        .rows = rows,
        .changes = if (stmt.countsChanges()) @intCast(@max(s.db.changes(), 0)) else 0,
        .last_insert_id = s.db.lastInsertRowid(),
    });
    return true;
}

/// Report the connection's last error for the statement at `at`, and
/// mark a failed transaction.
fn fail(s: *Session, sink: anytype, at: usize, cmd: command.Command) !void {
    const info = s.db.lastError() orelse xqlite.ErrorInfo{ .code = .@"error", .message = "unknown error", .offset = null };
    if (s.abort_failed_transactions and s.db.inTransaction()) s.aborted = true;
    try sink.failed(.{
        .sqlstate = errors.sqlstate(info.code, info.sqlstate),
        .number = info.dialect_number,
        .code = info.code,
        .message = info.message,
        .offset = if (info.offset) |o| at + o else null,
        .command = cmd,
    });
}

/// The result columns of `stmt`, in the scratch arena. With `has_row`,
/// the statement is on its first row, which gives the types of the
/// expressions; else they are `.unknown`.
fn describe(s: *Session, stmt: *xqlite.Stmt, has_row: bool) ![]Column {
    const cols = try s.scratch.allocator().alloc(Column, stmt.columnCount());
    for (cols, 0..) |*c, i| {
        const origin = stmt.columnOrigin(i);
        const declared: ?TypeCache.Entry = if (origin) |o| try s.type_cache.get(&s.db, stmt, i, o) else null;
        c.* = .{
            .name = stmt.columnName(i),
            .origin = origin,
            .type_name = if (declared) |d| d.name else null,
            .type = if (declared) |d| d.type else if (has_row) types.ofKind(stmt.columnKind(i)) else .{ .logical = .unknown },
        };
    }
    return cols;
}

/// The declared types of table columns, read from the catalog once per
/// schema version: describing a result would otherwise query xq_catalog
/// for each column of each statement.
const TypeCache = struct {
    arena: std.heap.ArenaAllocator,
    /// By "database\x00table\x00column".
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        /// The schema version of the column's database when it was read.
        version: u32,
        type: types.Type,
        name: []const u8,
    };

    fn init(gpa: Allocator) TypeCache {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(c: *TypeCache) void {
        c.arena.deinit();
    }

    /// The declared type of result column `i` of `stmt`, which reads `o`.
    fn get(c: *TypeCache, db: *const xqlite.Db, stmt: *xqlite.Stmt, i: usize, o: xqlite.Origin) !?Entry {
        const version = db.schemaVersion(o.database) orelse return null;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}\x00{s}", .{ o.database, o.table, o.column }) catch return c.read(stmt, i, version);
        if (c.map.get(key)) |e| {
            if (e.version == version) return e;
            // The schema changed: forget everything read before.
            c.map = .empty;
            _ = c.arena.reset(.retain_capacity);
        }
        const e = try c.read(stmt, i, version) orelse return null;
        const a = c.arena.allocator();
        try c.map.put(a, try a.dupe(u8, key), e);
        return e;
    }

    fn read(c: *TypeCache, stmt: *xqlite.Stmt, i: usize, version: u32) !?Entry {
        const t = stmt.columnTypeAlloc(c.arena.allocator(), i) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        } orelse return null;
        return .{ .version = version, .type = types.parse(t.dialect, t.text), .name = t.text };
    }
};

// ================================================================== tests

const testing = std.testing;

/// A sink that writes the events as text.
const Log = struct {
    out: std.ArrayList(u8) = .empty,

    fn columns(l: *Log, cols: []const Column) !void {
        try l.out.appendSlice(testing.allocator, "cols");
        for (cols) |c| try l.out.print(testing.allocator, " {s}:{t}", .{ c.name, c.type.logical });
        try l.out.append(testing.allocator, '\n');
    }

    fn row(l: *Log, r: *Row) !void {
        try l.out.appendSlice(testing.allocator, "row");
        for (0..r.len()) |i| switch (try r.value(i)) {
            .null => try l.out.appendSlice(testing.allocator, " NULL"),
            .integer => |v| try l.out.print(testing.allocator, " {d}", .{v}),
            .float => |v| try l.out.print(testing.allocator, " {d}", .{v}),
            .text => |v| try l.out.print(testing.allocator, " {s}", .{v}),
            .blob => |v| try l.out.print(testing.allocator, " x{x}", .{v}),
        };
        try l.out.append(testing.allocator, '\n');
    }

    fn complete(l: *Log, c: Complete) !void {
        try l.out.print(testing.allocator, "done {f} rows={d} changes={d}\n", .{ c.command, c.rows, c.changes });
    }

    fn failed(l: *Log, f: Failure) !void {
        try l.out.print(testing.allocator, "failed {s} {s}\n", .{ &f.sqlstate, f.message });
    }
};

fn expectRun(s: *Session, sql: []const u8, want: []const u8) !void {
    var log: Log = .{};
    defer log.out.deinit(testing.allocator);
    try s.run(sql, &log);
    try testing.expectEqualStrings(want, log.out.items);
}

test "run: a script's statements, their columns, rows and counts" {
    var s = try Session.open(testing.allocator, testing.io, ":memory:", .{});
    defer s.close();
    try expectRun(&s,
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, name VARCHAR(10));
        \\INSERT INTO t(name) VALUES('a'), ('b');
        \\SELECT id, name, 1.5 AS f, NULL AS n FROM t;
        \\SELECT * FROM t WHERE 0;
        \\UPDATE t SET name = 'c' WHERE id = 2;
    ,
        \\done CREATE TABLE rows=0 changes=0
        \\done INSERT rows=0 changes=2
        \\cols id:int8 name:varchar f:float8 n:unknown
        \\row 1 a 1.5 NULL
        \\row 2 b 1.5 NULL
        \\done SELECT rows=2 changes=0
        \\cols id:int8 name:varchar
        \\done SELECT rows=0 changes=0
        \\done UPDATE rows=0 changes=1
        \\
    );
    // A failing statement stops the script.
    try expectRun(&s, "SELECT 1; SELECT * FROM nope; SELECT 2",
        \\cols 1:int8
        \\row 1
        \\done SELECT rows=1 changes=0
        \\failed 42P01 no such table: nope
        \\
    );
    try testing.expectEqual(Status.idle, s.status());
}

test "run: PostgreSQL's failed transactions" {
    if (!xqlite.Dialect.postgres.built()) return;
    var s = try Session.open(testing.allocator, testing.io, ":memory:", .{
        .open = .{ .dialect = .postgres },
        .abort_failed_transactions = true,
    });
    defer s.close();
    try expectRun(&s, "CREATE TABLE t(id integer PRIMARY KEY, b boolean); BEGIN; INSERT INTO t VALUES(1, true)",
        \\done CREATE TABLE rows=0 changes=0
        \\done BEGIN rows=0 changes=0
        \\done INSERT rows=0 changes=1
        \\
    );
    try expectRun(&s, "INSERT INTO t VALUES(1, false)",
        \\failed 23505 UNIQUE constraint failed: t.id
        \\
    );
    try testing.expectEqual(Status.aborted, s.status());
    try expectRun(&s, "SELECT 1",
        \\failed 25P02 current transaction is aborted, commands ignored until end of transaction block
        \\
    );
    // COMMIT rolls back.
    try expectRun(&s, "COMMIT; SELECT count(*), 1 FROM t",
        \\done ROLLBACK rows=0 changes=0
        \\cols count:int8 ?column?:int8
        \\row 0 1
        \\done SELECT rows=1 changes=0
        \\
    );
    try testing.expectEqual(Status.idle, s.status());
    // The declared types of the dialect.
    try expectRun(&s, "SELECT id, b FROM t",
        \\cols id:int4 b:boolean
        \\done SELECT rows=0 changes=0
        \\
    );
    // The same names after a schema change: the types read again.
    try expectRun(&s, "DROP TABLE t; CREATE TABLE t(id text, b bigint); SELECT id, b FROM t",
        \\done DROP TABLE rows=0 changes=0
        \\done CREATE TABLE rows=0 changes=0
        \\cols id:text b:int8
        \\done SELECT rows=0 changes=0
        \\
    );
}
